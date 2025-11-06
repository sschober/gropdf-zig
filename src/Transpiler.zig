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

// maps grout font numbers to pdf font numbers
font_map: std.AutoHashMap(usize, usize),

// maps pdf font numbers to glyph widths maps
font_glyph_widths_maps: std.AutoHashMap(usize, [257]usize),

// transpilation state we use optionals here, as zig does not allow null pointers
doc: ?pdf.Document = null,
cur_text_object: ?*pdf.TextObject = null,
cur_pdf_font_num: ?usize = null,
cur_font_size: ?usize = null,
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
        .font_map = std.AutoHashMap(usize, usize).init(allocator),
        .font_glyph_widths_maps = std.AutoHashMap(usize, groff.GlyphMap).init(allocator),
    };
}

/// helper function translating a groff z position coordinate into a fix point
/// numer scaled by the pdf unit scale
fn fixPointFromZPos(zp: groff.zPosition) FixPoint {
    return FixPoint.from(zp.v, pdf.UNITSCALE);
}

/// handles a `x font TR 6` or wx font TR 6` command
fn handle_font_cmd(
    self: *Self,
    font_name: String,
    font_num: usize,
) !void {
    if (self.font_map.contains(font_num)) {
        log.dbg("{d}: not adding {s} {d} to font map: already seen...\n", .{ self.cur_line_num, font_name, font_num });
        return;
    }
    var pdf_font_num: usize = 0;
    if (std.mem.eql(u8, "TR", font_name)) {
        pdf_font_num = try self.doc.?.addStandardFont(pdf.StandardFonts.Times_Roman);
    } else if (std.mem.eql(u8, "TB", font_name)) {
        pdf_font_num = try self.doc.?.addStandardFont(pdf.StandardFonts.Times_Bold);
    } else if (std.mem.eql(u8, "TI", font_name)) {
        pdf_font_num = try self.doc.?.addStandardFont(pdf.StandardFonts.Times_Italic);
    } else if (std.mem.eql(u8, "CR", font_name)) {
        pdf_font_num = try self.doc.?.addStandardFont(pdf.StandardFonts.Courier);
    } else {
        log.warn("warning: unsupported font: {s}\n", .{font_name});
        return;
    }
    log.dbg("{d}: adding {s} as pdf font num {d} to font map\n", .{ self.cur_line_num, font_name, pdf_font_num });
    try self.font_map.put(font_num, pdf_font_num);
    const glyph_map = try groff.readGlyphMap(self.allocator, font_name);
    try self.font_glyph_widths_maps.put(pdf_font_num, glyph_map);
}

/// read grout from `reader` and output pdf to `writer`
pub fn transpile(self: *Self) !u8 {
    while (self.reader.takeDelimiter('\n')) |opt_line| {
        if (opt_line) |line| {
            if (line.len == 0) {
                break;
            }
            self.cur_line_num += 1;
            if (line[0] == '+') {
                //std.debug.print("{d}: ignoring + line\n", .{lineNum});
                continue;
            }
            const cmd = std.meta.stringToEnum(groff.Out, line[0..1]).?;
            switch (cmd) {
                .p => {
                    // begin new page
                    // sample: p 2
                    self.cur_page = try self.doc.?.addPage();
                    if (self.cur_x > 0) {
                        self.cur_page.?.x = self.cur_x;
                    }
                    if (self.cur_y > 0) {
                        self.cur_page.?.y = self.cur_y;
                    }
                    self.cur_text_object = self.cur_page.?.contents.textObject;
                },
                .f => {
                    // select font mounted at pos
                    // sample: f5
                    const font_num = try std.fmt.parseUnsigned(usize, line[1..], 10);
                    self.cur_pdf_font_num = self.font_map.get(font_num);
                    try self.doc.?.addFontRefTo(self.cur_page.?, self.cur_pdf_font_num.?);
                    log.dbg("{d}: selecting font {d}, pdf num {d} at size {d}\n", .{ self.cur_line_num, font_num, self.cur_pdf_font_num.?, self.cur_font_size orelse 11 });
                    try self.cur_text_object.?.selectFont(self.cur_pdf_font_num.?, self.cur_font_size orelse 11);
                },
                .x => {
                    // device control command
                    // sample: x X papersize
                    if (line.len > 2) {
                        var it = std.mem.splitScalar(u8, line[2..], ' ');
                        const sub_cmd_enum = std.meta.stringToEnum(groff.XSubCommand, it.next().?).?;
                        switch (sub_cmd_enum) {
                            .init => {
                                // begin document
                                self.doc = try pdf.Document.init(self.allocator);
                            },
                            .font => {
                                // mount font position pos
                                // sample: x font 5 TR
                                const font_num = try std.fmt.parseUnsigned(usize, it.next().?, 10);
                                if (self.font_map.contains(font_num)) {
                                    continue;
                                }
                                const font_name = it.next().?;
                                try self.handle_font_cmd(font_name, font_num);
                            },
                            .res => {
                                // resolution control command
                                // sample:
                                const arg = it.next().?;
                                const res = try std.fmt.parseUnsigned(usize, arg, 10);
                                const unitsize = res / 72;
                                //try stderr.print("setting unit scale to {d}\n", .{unitsize});
                                pdf.UNITSCALE = unitsize;
                            },
                            .T => {
                                // typesetter control command
                                // sample: x T pdf
                                const arg = it.next().?;
                                if (std.mem.indexOf(u8, arg, "pdf") != 0) {
                                    log.dbg("error: unexpected output type: {s}", .{arg});
                                    return 1;
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
                },
                .C => {
                    // typeset glyph of special character id
                    // sample: Chy
                    if (std.mem.eql(u8, line[1..3], "hy")) {
                        // TODO replace `-` with real glyph from font
                        try self.cur_text_object.?.addWordWithoutMove("-");
                    } else if (std.mem.eql(u8, line[1..3], "lq")) {
                        try self.cur_text_object.?.addWordWithoutMove("\"");
                    } else if (std.mem.eql(u8, line[1..3], "rq")) {
                        try self.cur_text_object.?.addWordWithoutMove("\"");
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
                    try self.cur_text_object.?.selectFont(self.cur_pdf_font_num.?, fontSize / pdf.UNITSCALE);
                },
                .t => {
                    // typeset word
                    // sample: thello
                    const glyph_map = self.font_glyph_widths_maps.get(self.cur_pdf_font_num.?).?;
                    try self.cur_text_object.?.addWord(line[1..], glyph_map, self.cur_font_size.?);
                },
                .w => {
                    // interword space
                    // sample: wh2750
                    if (line[1] == 'h') {
                        const h = try groff.zPosition.fromString(line[2..]);
                        try self.cur_text_object.?.addE(fixPointFromZPos(h));
                    } else if (line[1] == 'x') {
                        var it = std.mem.splitScalar(u8, line[3..], ' ');
                        const subCmd = it.next().?;
                        if (std.mem.eql(u8, subCmd, "font")) {
                            // wx font 6 CR
                            const font_num = try std.fmt.parseUnsigned(usize, it.next().?, 10);
                            const font_name = it.next().?;
                            try self.cur_text_object.?.newLine();
                            try self.handle_font_cmd(font_name, font_num);
                        } else {
                            log.warn("{d}: warning: unknown x sub command: {s}", .{ self.cur_line_num, subCmd });
                        }
                    } else if (line[1] == 'f') {
                        // wf5
                        // TODO factor out into function
                        const font_num = try std.fmt.parseUnsigned(usize, line[2..], 10);
                        self.cur_pdf_font_num = self.font_map.get(font_num);
                        try self.cur_text_object.?.newLine();
                        try self.doc.?.addFontRefTo(self.cur_page.?, self.cur_pdf_font_num.?);
                        log.dbg("{d}: selecting font {d}, pdf num {d} at size {d}\n", .{ self.cur_line_num, font_num, self.cur_pdf_font_num.?, self.cur_font_size orelse 11 });
                        try self.cur_text_object.?.selectFont(self.cur_pdf_font_num.?, self.cur_font_size orelse 11);
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
                    //try stderr.print("v_y: {d} v: {f} ", .{ v_z.v, v });
                    if (v.integer <= self.cur_page.?.y) {
                        //-v.integer = curPage.?.y - v.integer;
                        v = v.subtractFrom(self.cur_page.?.y);
                        try self.cur_text_object.?.setF(v);
                    }
                },
                .h => {
                    // horizontal relative positioning
                    // sample: h918
                    const h = try groff.zPosition.fromString(line[1..]);
                    try self.cur_text_object.?.addE(fixPointFromZPos(h));
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
            try self.writer.flush();
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
