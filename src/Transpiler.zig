//! Transpiler has the logic to interpret grout and render it to pdf
//!
const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const FixPoint = @import("FixPoint.zig");

const String = []const u8;
const Self = @This();

allocator: Allocator,

/// could be stdin or a file
reader: *std.Io.Reader,
/// could be stdout or a file
writer: *std.Io.Writer,

// maps grout font numbers to pdf page font references
page_font_map: std.AutoHashMap(usize, pdf.Page.FontRef),
// maps grout font numbers to pdf dox font references
doc_font_map: std.AutoHashMap(usize, pdf.Document.FontRef),

// maps pdf font numbers to glyph widths maps
font_glyph_widths_maps: std.AutoHashMap(usize, [257]usize),

// transpilation state we use optionals here, as zig does not allow null pointers
doc: ?pdf.Document = null,
cur_text_object: ?*pdf.TextObject = null,
cur_pdf_page_font_ref: ?pdf.Page.FontRef = null,
cur_groff_font_num: ?usize = null,
cur_font_size: usize = 11,
cur_line_num: usize = 0,
cur_page: ?*pdf.Page = null,
cur_x: usize = 0,
cur_y: usize = 0,

/// initialize a Transpiler object, provide a `Reader` object for grout input and
/// a `Writer` for writing pdf to
pub fn init(allocator: Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) Self {
    return Self{
        .allocator = allocator, //
        .reader = reader,
        .writer = writer,
        .page_font_map = std.AutoHashMap(usize, pdf.Page.FontRef).init(allocator),
        .doc_font_map = std.AutoHashMap(usize, pdf.Document.FontRef).init(allocator),
        .font_glyph_widths_maps = std.AutoHashMap(usize, groff.GlyphMap).init(allocator),
    };
}

/// translate a groff z position coordinate into a fix point
/// number scaled by the pdf unit scale
fn fixPointFromZPos(zp: groff.zPosition) FixPoint {
    return FixPoint.from(zp.v, pdf.UNITSCALE);
}

/// compile time font mapping from groff names like `TR` and `CR` to pdf known
/// names like `Times_Roman` and `Courier`
const groff_to_pdf_font_map =
    std.StaticStringMap(pdf.StandardFonts).initComptime(.{ //
        .{ "TR", pdf.StandardFonts.Times_Roman }, //
        .{ "TB", pdf.StandardFonts.Times_Bold }, //
        .{ "TI", pdf.StandardFonts.Times_Italic }, //
        .{ "CR", pdf.StandardFonts.Courier },
    });

/// handles a `x font TR 6` command
fn handle_x_font(self: *Self, it: *std.mem.SplitIterator(u8, .scalar)) !void {
    const font_num = try std.fmt.parseUnsigned(usize, it.next().?, 10);
    const font_name = it.next().?;
    const grout_font_ref = groff.FontRef{ .name = font_name, .idx = font_num };
    var doc_font_ref: pdf.Document.FontRef = pdf.Document.FontRef{ .idx = 0 };
    // we need to decide, if we need to register the font at the document level, or if we already did
    if (self.doc_font_map.contains(grout_font_ref.idx)) {
        log.dbg("{d}: not adding {f} to pdf doc: already seen...\n", .{ self.cur_line_num, grout_font_ref });
        doc_font_ref = self.doc_font_map.get(grout_font_ref.idx).?;
    } else {
        // this is a new font, we did not see up until now...
        if (groff_to_pdf_font_map.get(grout_font_ref.name)) |pdf_std_font| {
            doc_font_ref = try self.doc.?.addStandardFont(pdf_std_font);
        } else {
            log.warn("warning: unsupported font: {s}\n", .{grout_font_ref.name});
            return;
        }
        // the glyph map helps us move the X position in PDF text objects forward
        const glyph_widths_map = try groff.readGlyphMap(self.allocator, grout_font_ref.name);
        try self.font_glyph_widths_maps.put(grout_font_ref.idx, glyph_widths_map);
    }
    const page_font_ref = try self.doc.?.addFontRefTo(self.cur_page.?, doc_font_ref);
    log.dbg("{d}: adding {s} as {f} to page font map\n", .{ self.cur_line_num, grout_font_ref.name, doc_font_ref });
    try self.page_font_map.put(grout_font_ref.idx, page_font_ref);
}

/// handle grout fN command - parses N usize argument, selects font from page
/// font map and selects the font in the current text object
/// sample: f5
fn handle_f(self: *Self, line: []u8) !void {
    const font_num = try std.fmt.parseUnsigned(usize, line, 10);
    self.cur_groff_font_num = font_num;
    self.cur_pdf_page_font_ref = self.page_font_map.get(font_num);
    log.dbg("{d}: selecting font {d}, {f} at size {d}\n", .{ self.cur_line_num, font_num, self.cur_pdf_page_font_ref.?, self.cur_font_size });
    try self.cur_text_object.?.selectFont(self.cur_pdf_page_font_ref.?, self.cur_font_size);
}

/// begin a new page in pdf document, copy over the page dimensions from previous page
/// sample: p 2
fn handle_p(self: *Self) !void {
    self.cur_page = try self.doc.?.addPage();
    if (self.cur_x > 0) {
        self.cur_page.?.x = self.cur_x;
    }
    if (self.cur_y > 0) {
        self.cur_page.?.y = self.cur_y;
    }
    self.cur_text_object = self.cur_page.?.contents.textObject;
}
const XCommandError = error{WrongDevice} || Allocator.Error;

/// relative horizontal positioning
fn handle_h(self: *Self, line: []u8) !void {
    const h = try groff.zPosition.fromString(line);
    try self.cur_text_object.?.addE(fixPointFromZPos(h));
}

/// device control command
/// sample: x X papersize
fn handle_x(self: *Self, line: []u8) !void {
    if (line.len > 2) {
        var it = std.mem.splitScalar(u8, line[2..], ' ');
        const sub_cmd_enum = std.meta.stringToEnum(groff.XSubCommand, it.next().?).?;
        switch (sub_cmd_enum) {
            .init => {
                // begin document
                self.doc = try pdf.Document.init(self.allocator);
            },
            .font => try self.handle_x_font(&it),
            .res => {
                // resolution control command
                // sample:
                const arg = it.next().?;
                const res = try std.fmt.parseUnsigned(usize, arg, 10);
                const unitsize = res / 72;
                pdf.UNITSCALE = unitsize;
            },
            .T => {
                // typesetter control command
                // sample: x T pdf
                const arg = it.next().?;
                if (std.mem.indexOf(u8, arg, "pdf") != 0) {
                    log.dbg("error: unexpected output type: {s}", .{arg});
                    return XCommandError.WrongDevice;
                }
            },
            .X => {
                // X escape control command
                // sample: x X papersize=421000z,595000z
                const arg = it.next().?;
                if (std.mem.indexOf(u8, arg, "papersize")) |idxPapersize| {
                    if (0 == idxPapersize) {
                        // we found a `papersize` argument
                        if (std.mem.indexOf(u8, arg, "=")) |idxEqual| {
                            var itZSizes = std.mem.splitScalar(u8, arg[idxEqual + 1 ..], ',');
                            const zX = itZSizes.next().?;
                            const zPosX = try groff.zPosition.fromString(zX);
                            const zPosXScaled = fixPointFromZPos(zPosX);
                            if (zPosXScaled.integer != self.cur_page.?.x) {
                                self.cur_page.?.x = zPosXScaled.integer;
                                self.cur_x = zPosXScaled.integer;
                            }
                            const zY = itZSizes.next().?;
                            const zPosY = try groff.zPosition.fromString(zY);
                            const zPosYScaled = fixPointFromZPos(zPosY);
                            if (zPosYScaled.integer != self.cur_page.?.y) {
                                self.cur_page.?.y = zPosYScaled.integer;
                                self.cur_y = zPosYScaled.integer;
                            }
                        }
                    } else {
                        log.warn("{d}: warning: unexpected index: {d}\n", .{ self.cur_line_num, idxPapersize });
                    }
                } else {
                    log.warn("{d}: warning: unkown x X subcommand: {s}\n", .{ self.cur_line_num, arg });
                }
            },
            else => {},
        }
    }
}

/// maps groff out character names to ascii/pdf standard encoding codes
const glyph_map = std.StaticStringMap(u8).initComptime(.{ //
    .{ "fi", 174 }, //
    .{ "fl", 175 },
    .{ "hy", 45 },
    .{ "lq", 141 },
    .{ "rq", 142 },
    .{ "cq", 0o251 },
});

/// read grout from `reader` and output pdf to `writer`
pub fn transpile(self: *Self) !u8 {
    while (self.reader.takeDelimiter('\n')) |opt_line| {
        if (opt_line) |line| {
            if (line.len == 0) {
                break;
            }
            self.cur_line_num += 1;
            if (line[0] == '+') {
                log.dbg("{d}: ignoring + line\n", .{self.cur_line_num});
                continue;
            }
            const cmd = std.meta.stringToEnum(groff.Out, line[0..1]).?;
            switch (cmd) {
                .p => try self.handle_p(),
                .f => try self.handle_f(line[1..]),
                .x => try self.handle_x(line),
                .C => {
                    // typeset glyph of special character id
                    // sample: Chy
                    if (glyph_map.get(line[1..3])) |code| {
                        try self.cur_text_object.?.addWordWithoutMove(&.{code});
                    } else {
                        log.warn("{d}: warning: unhandled character sequence: {s}\n", .{ self.cur_line_num, line[1..3] });
                        try self.cur_text_object.?.addWordWithoutMove(line[1..]);
                    }
                },
                .s => {
                    // set type size
                    // sample: s11000
                    const fontSize = try std.fmt.parseInt(usize, line[1..], 10);
                    self.cur_font_size = fontSize / pdf.UNITSCALE;
                    try self.cur_text_object.?.selectFont(self.cur_pdf_page_font_ref.?, fontSize / pdf.UNITSCALE);
                },
                .t => {
                    // typeset word
                    // sample: thello
                    const glyph_widths_map = self.font_glyph_widths_maps.get(self.cur_groff_font_num.?).?;
                    try self.cur_text_object.?.addWord(line[1..], glyph_widths_map, self.cur_font_size);
                },
                .w => {
                    // interword space
                    // sample: wh2750
                    if (line[1] == 'h') {
                        try self.handle_h(line[2..]);
                    } else if (line[1] == 'x') {
                        try self.handle_x(line[1..]);
                    } else if (line[1] == 'f') {
                        // wf5
                        try self.handle_f(line[2..]);
                    }
                },
                .n => {
                    // new line command
                    // sample: n12000 0
                    try self.cur_text_object.?.newLine();
                },
                .V => {
                    // vertical absolute positioning
                    // sample: V151452
                    const v_z = try groff.zPosition.fromString(line[1..]);
                    var v = fixPointFromZPos(v_z);
                    if (v.integer <= self.cur_page.?.y) {
                        v = v.subtractFrom(self.cur_page.?.y);
                        try self.cur_text_object.?.setF(v);
                    }
                },
                .h => {
                    // horizontal relative positioning
                    // sample: h918
                    try self.handle_h(line[1..]);
                },
                .v => {
                    // we ignore `v` as it seems the absolute positioning commands are enough
                },
                .H => {
                    // horizontal absolute positioning
                    // sample: H72000
                    const h_z = try groff.zPosition.fromString(line[1..]);
                    try self.cur_text_object.?.setE(fixPointFromZPos(h_z));
                },
                else => {
                    log.warn("{d}: warning: unknown command: {s}\n", .{ self.cur_line_num, line });
                },
            }
        } else {
            break;
        }
    } else |_| {
        // nothing left to read any more
    }
    if (self.doc) |renderedPdf| {
        try self.writer.print("{f}", .{renderedPdf});
    }
    try self.writer.flush();
    return 0;
}
