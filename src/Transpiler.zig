//! Transpiler has the logic to interpret grout and render it to pdf
//!
const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const FixPoint = @import("FixPoint.zig");

const Self = @This();

allocator: Allocator,

/// where to read grout input from - could be stdin or a file
reader: *std.Io.Reader,

/// where to write the rendered PDF output to - could be stdout or a file
writer: *std.Io.Writer,

// maps grout font numbers to pdf page font references
page_font_map: std.AutoHashMap(usize, pdf.Page.FontRef),
// maps grout font numbers to pdf doc font references
doc_font_map: std.AutoHashMap(usize, pdf.Document.FontRef),

// maps pdf font numbers to glyph widths maps
font_glyph_widths_maps: std.AutoHashMap(usize, [257]usize),

// transpilation state - we use optionals here, as zig does not allow null pointers
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
/// names like `Times_Roman` and `Courier` - we have captured the latter in a
/// pdf standard fonts enum
const groff_to_pdf_font_map =
    std.StaticStringMap(pdf.StandardFonts).initComptime(.{ //
        .{ "TR", pdf.StandardFonts.Times_Roman }, //
        .{ "TB", pdf.StandardFonts.Times_Bold }, //
        .{ "TI", pdf.StandardFonts.Times_Italic }, //
        .{ "TBI", pdf.StandardFonts.Times_Bold_Italic }, //
        .{ "HR", pdf.StandardFonts.Helvetica }, //
        .{ "H", pdf.StandardFonts.Helvetica }, //
        .{ "HB", pdf.StandardFonts.Helvetica_Bold }, //
        .{ "HI", pdf.StandardFonts.Helvetica_Oblique }, //
        .{ "HBI", pdf.StandardFonts.Helvetica_Bold_Oblique }, //
        .{ "CR", pdf.StandardFonts.Courier }, //
        .{ "CB", pdf.StandardFonts.Courier_Bold }, //
        .{ "CI", pdf.StandardFonts.Courier_Olbique }, //
        .{ "CBI", pdf.StandardFonts.Courier_Bold_Oblique }, //
        .{ "S", pdf.StandardFonts.Symbol }, //
        .{ "ZD", pdf.StandardFonts.Zapf_Dingbats },
    });

/// handles a `x font TR 6` command
fn handle_x_font(self: *Self, it: *std.mem.SplitIterator(u8, .scalar)) !void {
    const font_num_str = it.next() orelse return TranspileError.MissingArgument;
    const font_num = try std.fmt.parseUnsigned(usize, font_num_str, 10);
    const font_name = it.next() orelse return TranspileError.MissingArgument;
    const grout_font_ref = groff.FontRef{ .name = font_name, .idx = font_num };
    var doc_font_ref: pdf.Document.FontRef = pdf.Document.FontRef{ .idx = 0 };
    // did we already register the font at the document level, or do we need to do it?
    if (self.doc_font_map.contains(grout_font_ref.idx)) {
        log.dbg("{d}: not adding {f} to pdf doc: already seen...\n", .{ self.cur_line_num, grout_font_ref });
        // safe: we just verified the key exists via contains()
        doc_font_ref = self.doc_font_map.get(grout_font_ref.idx) orelse unreachable;
    } else {
        // this is a new font, we did not see up until now...
        const doc = self.doc orelse return TranspileError.StateError;
        if (groff_to_pdf_font_map.get(grout_font_ref.name)) |pdf_std_font| {
            doc_font_ref = try doc.addStandardFont(pdf_std_font);
        } else {
            log.warn("warning: unsupported font: {s}\n", .{grout_font_ref.name});
            return;
        }
        // the glyph map helps us move the x position in PDF text objects forward
        const glyph_widths_map = try groff.readGlyphMap(self.allocator, grout_font_ref.name);
        try self.font_glyph_widths_maps.put(grout_font_ref.idx, glyph_widths_map);
    }
    const doc = self.doc orelse return TranspileError.StateError;
    const cur_page = self.cur_page orelse return TranspileError.StateError;
    const page_font_ref = try doc.addFontRefTo(cur_page, doc_font_ref);
    log.dbg("{d}: adding {s} as {f} to page font map\n", .{ self.cur_line_num, grout_font_ref.name, doc_font_ref });
    try self.page_font_map.put(grout_font_ref.idx, page_font_ref);
}

/// handle grout `fN` command - parses N as usize argument, selects font from page
/// font map and selects the font in the current text object
/// sample: `f5`
fn handle_f(self: *Self, line: []u8) !void {
    const font_num = try std.fmt.parseUnsigned(usize, line, 10);
    self.cur_groff_font_num = font_num;
    self.cur_pdf_page_font_ref = self.page_font_map.get(font_num);
    const page_font_ref = self.cur_pdf_page_font_ref orelse {
        log.warn("{d}: warning: font {d} not registered, skipping font select\n", .{ self.cur_line_num, font_num });
        return;
    };
    log.dbg("{d}: selecting font {d}, {f} at size {d}\n", .{ self.cur_line_num, font_num, page_font_ref, self.cur_font_size });
    const text_obj = self.cur_text_object orelse return TranspileError.StateError;
    try text_obj.selectFont(page_font_ref, self.cur_font_size);
}

/// begin a new page in pdf document, copy over the page dimensions from previous page
/// sample: `p2`
fn handle_p(self: *Self) !void {
    const doc = self.doc orelse return TranspileError.StateError;
    self.cur_page = try doc.addPage();
    const cur_page = self.cur_page orelse unreachable;
    if (self.cur_x > 0) {
        cur_page.x = self.cur_x;
    }
    if (self.cur_y > 0) {
        cur_page.y = self.cur_y;
    }
    self.cur_text_object = cur_page.contents.textObject;
}

/// relative horizontal positioning
fn handle_h(self: *Self, line: []u8) !void {
    const h = try groff.zPosition.fromString(line);
    const text_obj = self.cur_text_object orelse return TranspileError.StateError;
    try text_obj.addE(fixPointFromZPos(h));
}

fn handle_v(self: *Self, line: []u8) !void {
    const v = try groff.zPosition.fromString(line);
    const text_obj = self.cur_text_object orelse return TranspileError.StateError;
    try text_obj.addF(fixPointFromZPos(v));
}

/// error type for communicating invalid input or unexpected state back to the caller
const TranspileError = error{
    /// a required command argument was absent
    MissingArgument,
    /// the command or sub-command token was not recognised
    UnknownCommand,
    /// an operation was attempted before the required state was initialised
    /// (e.g. typesetting before a page or font has been selected)
    StateError,
} || Allocator.Error;

/// our custom error type for communicating situations back up to the caller,
/// which we cannot ignore or handle other wise
const XCommandError = error{WrongDevice} || TranspileError;

/// device control command
/// sample: `x X papersize`
fn handle_x(self: *Self, line: []u8) !void {
    if (line.len > 2) {
        var it = std.mem.splitScalar(u8, line[2..], ' ');
        const sub_cmd_str = it.next() orelse return;
        const sub_cmd_enum = std.meta.stringToEnum(groff.XSubCommand, sub_cmd_str) orelse {
            log.warn("{d}: warning: unknown x sub-command: {s}\n", .{ self.cur_line_num, sub_cmd_str });
            return;
        };
        switch (sub_cmd_enum) {
            .init => {
                // begin document
                self.doc = try pdf.Document.init(self.allocator);
            },
            .font => try self.handle_x_font(&it),
            .res => {
                // resolution control command
                // sample: x res 72000 1 1
                const arg = it.next() orelse return TranspileError.MissingArgument;
                const res = try std.fmt.parseUnsigned(usize, arg, 10);
                const unitsize = res / 72;
                pdf.UNITSCALE = unitsize;
            },
            .T => {
                // typesetter control command
                // sample: x T pdf
                const arg = it.next() orelse return TranspileError.MissingArgument;
                if (std.mem.indexOf(u8, arg, "pdf") != 0) {
                    log.dbg("error: unexpected output type: {s}", .{arg});
                    return XCommandError.WrongDevice;
                }
            },
            .X => {
                // X escape control command
                // sample: x X papersize=421000z,595000z
                const arg = it.next() orelse return;
                if (std.mem.indexOf(u8, arg, "papersize")) |idxPapersize| {
                    if (0 == idxPapersize) {
                        // we found a `papersize` argument
                        if (std.mem.indexOf(u8, arg, "=")) |idxEqual| {
                            const cur_page = self.cur_page orelse return TranspileError.StateError;
                            var itZSizes = std.mem.splitScalar(u8, arg[idxEqual + 1 ..], ',');
                            const zX = itZSizes.next() orelse return TranspileError.MissingArgument;
                            const zPosX = try groff.zPosition.fromString(zX);
                            const zPosXScaled = fixPointFromZPos(zPosX);
                            if (zPosXScaled.integer != cur_page.x) {
                                cur_page.x = zPosXScaled.integer;
                                self.cur_x = zPosXScaled.integer;
                            }
                            const zY = itZSizes.next() orelse return TranspileError.MissingArgument;
                            const zPosY = try groff.zPosition.fromString(zY);
                            const zPosYScaled = fixPointFromZPos(zPosY);
                            if (zPosYScaled.integer != cur_page.y) {
                                cur_page.y = zPosYScaled.integer;
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
const glyph_map = std.StaticStringMap(u8).initComptime(.{
    // ligatures
    .{ "fi", 174 },
    .{ "fl", 175 },
    // hyphens and dashes
    .{ "hy", 45 },    // hyphen
    .{ "mi", 45 },    // minus sign
    .{ "em", 151 },   // em-dash
    .{ "en", 150 },   // en-dash
    // quotes
    .{ "lq", 141 },   // left double quote
    .{ "rq", 142 },   // right double quote
    .{ "cq", 0o251 }, // close quote (right single)
    .{ "oq", 0o140 }, // open quote (left single)
    .{ "dq", 34 },    // double quote
    .{ "aq", 39 },    // apostrophe
    // punctuation and symbols
    .{ "bu", 0o267 }, // bullet
    .{ "de", 0o260 }, // degree
    .{ "sc", 0o247 }, // section sign
    .{ "dg", 0o262 }, // dagger
    .{ "dd", 0o263 }, // double dagger
    .{ "ct", 0o242 }, // cent sign
    .{ "rs", 92 },    // backslash (reverse solidus)
    .{ "sl", 47 },    // slash
    // math operators
    .{ "pl", 43 },    // plus
    .{ "eq", 61 },    // equals
    .{ "mu", 0o264 }, // multiply
    .{ "**", 42 },    // asterisk
});

fn handle_D(self: *Self, line: []u8) !void {
    var it = std.mem.splitScalar(u8, line, ' ');
    const sub_cmd = it.next() orelse return TranspileError.MissingArgument;
    const sub_cmd_enum = std.meta.stringToEnum(groff.DSubCommand, sub_cmd) orelse {
        log.warn("{d}: warning: unknown D sub-command: {s}\n", .{ self.cur_line_num, sub_cmd });
        return;
    };
    const cur_page = self.cur_page orelse return TranspileError.StateError;
    switch (sub_cmd_enum) {
        .l => {
            const zX = it.next() orelse return TranspileError.MissingArgument;
            log.dbg("{d}: Dl: x:{s}", .{ self.cur_line_num, zX });
            const zPosX = try groff.zPosition.fromString(zX);
            const x = fixPointFromZPos(zPosX);
            const zY = it.next() orelse return TranspileError.MissingArgument;
            log.dbg(" y: {s}\n", .{zY});
            const zPosY = try groff.zPosition.fromString(zY);
            const y = fixPointFromZPos(zPosY);
            try cur_page.contents.graphicalObject.lineTo(x, y);
        },
        .t => {
            const zT = it.next() orelse return TranspileError.MissingArgument;
            log.dbg("{d}: Dt{s}\n", .{ self.cur_line_num, zT });
            const zTNum = try std.fmt.parseUnsigned(usize, zT, 10);
            const zTScaled = FixPoint.from(zTNum, pdf.UNITSCALE);
            try cur_page.contents.graphicalObject.lineWidth(zTScaled);
        },
        .Fd => {
            // filled drawing with default color - collect coordinate pairs
            var points = std.array_list.Managed(FixPoint).init(self.allocator);
            while (it.next()) |z| {
                const zPos = try groff.zPosition.fromString(z);
                try points.append(fixPointFromZPos(zPos));
            }
            try cur_page.contents.graphicalObject.fillPath(points.items);
        },
        .Fr => {
            // color filled drawing - first 3 args are R G B, then coordinate pairs
            const groff_rgb = try groff.RgbColor.from_iterator(&it);
            const pdf_rgb = try groffRgbToPdfRgbColor(groff_rgb);
            try cur_page.contents.graphicalObject.setFillColor(pdf_rgb);
            var points = std.array_list.Managed(FixPoint).init(self.allocator);
            while (it.next()) |z| {
                const zPos = try groff.zPosition.fromString(z);
                try points.append(fixPointFromZPos(zPos));
            }
            try cur_page.contents.graphicalObject.fillPath(points.items);
        },
    }
}

/// transform groff_out RGB color into pdf RGB color by scaling each dimension
/// from a 0..65535 range to 0..1
fn groffRgbToPdfRgbColor(gc: groff.RgbColor) !pdf.RgbColor {
    return pdf.RgbColor{
        .r = FixPoint.from(gc.r, groff.RgbColorMax), //
        .g = FixPoint.from(gc.g, groff.RgbColorMax),
        .b = FixPoint.from(gc.b, groff.RgbColorMax),
    };
}

fn handle_m(self: *Self, line: []u8) !void {
    if (line.len < 1) return TranspileError.MissingArgument;
    const sub_cmd = std.meta.stringToEnum(groff.MSubCommand, line[0..1]) orelse {
        log.warn("{d}: warning: unknown m sub-command: {s}\n", .{ self.cur_line_num, line[0..1] });
        return;
    };
    const text_obj = self.cur_text_object orelse return TranspileError.StateError;
    switch (sub_cmd) {
        .d => {
            try text_obj.setFillColorBlack();
        },
        .r => {
            if (line.len < 3) return TranspileError.MissingArgument;
            const groff_rgb = try groff.RgbColor.from_string(line[2..]);
            const pdf_rgb = try groffRgbToPdfRgbColor(groff_rgb);
            log.dbg("setting fill color: {f}\n", .{pdf_rgb});
            try text_obj.setFillColor(pdf_rgb);
        },
    }
}

/// handle a groff out command
/// tries to convert the first character of line to a groff.Out enum and
/// dispatches to the handler functions
fn handle_cmd(self: *Self, line: []u8) !void {
    if (line.len == 0) return;
    const cmd = std.meta.stringToEnum(groff.Out, line[0..1]) orelse {
        log.warn("{d}: warning: unknown command: {s}\n", .{ self.cur_line_num, line[0..1] });
        return;
    };
    switch (cmd) {
        .p => try self.handle_p(),
        .f => try self.handle_f(line[1..]),
        .x => try self.handle_x(line),
        .C => {
            // typeset glyph of special character id
            // sample: Chy
            if (line.len < 3) {
                log.warn("{d}: warning: C command too short: {s}\n", .{ self.cur_line_num, line });
                return;
            }
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            if (glyph_map.get(line[1..3])) |code| {
                try text_obj.addWordWithoutMove(&.{code});
            } else {
                log.warn("{d}: warning: unhandled character sequence: {s}\n", .{ self.cur_line_num, line[1..3] });
                try text_obj.addWordWithoutMove(line[1..]);
            }
        },
        .D => {
            // samples:
            // Dl 277000 0
            // Dt 500 0
            try self.handle_D(line[1..]);
        },
        .m => try self.handle_m(line[1..]),
        .s => {
            // set type size
            // sample: s11000
            const fontSize = try std.fmt.parseInt(usize, line[1..], 10);
            self.cur_font_size = fontSize / pdf.UNITSCALE;
            const page_font_ref = self.cur_pdf_page_font_ref orelse {
                log.warn("{d}: warning: no font selected for size change, skipping\n", .{self.cur_line_num});
                return;
            };
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            try text_obj.selectFont(page_font_ref, fontSize / pdf.UNITSCALE);
        },
        .t => {
            // typeset word
            // sample: thello
            const font_num = self.cur_groff_font_num orelse {
                log.warn("{d}: warning: no font active for 't' command, skipping\n", .{self.cur_line_num});
                return;
            };
            const glyph_widths_map = self.font_glyph_widths_maps.get(font_num) orelse {
                log.warn("{d}: warning: no glyph map for font {d}, skipping\n", .{ self.cur_line_num, font_num });
                return;
            };
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            try text_obj.addWord(line[1..], glyph_widths_map, self.cur_font_size);
        },
        .u => {
            var it = std.mem.splitScalar(u8, line[1..], ' ');
            _ = it.next();
            const word = it.next() orelse return TranspileError.MissingArgument;
            const font_num = self.cur_groff_font_num orelse {
                log.warn("{d}: warning: no font active for 'u' command, skipping\n", .{self.cur_line_num});
                return;
            };
            const glyph_widths_map = self.font_glyph_widths_maps.get(font_num) orelse {
                log.warn("{d}: warning: no glyph map for font {d}, skipping\n", .{ self.cur_line_num, font_num });
                return;
            };
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            try text_obj.addWord(word, glyph_widths_map, self.cur_font_size);
        },
        .w => {
            // interword space - has no function and is immediately followed by
            // another command; so we skip one character in line and recurse
            // sample: wh2750
            try self.handle_cmd(line[1..]);
        },
        .n => {
            // new line command
            // sample: n12000 0
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            try text_obj.newLine();
        },
        .V => {
            // vertical absolute positioning
            // sample: V151452
            const cur_page = self.cur_page orelse return TranspileError.StateError;
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            const v_z = try groff.zPosition.fromString(line[1..]);
            var v = fixPointFromZPos(v_z);
            if (v.integer <= cur_page.y) {
                v = v.subtractFrom(cur_page.y);
                try text_obj.setF(v);
                try cur_page.contents.graphicalObject.setY(v);
            }
        },
        .h => {
            // horizontal relative positioning
            // sample: h918
            try self.handle_h(line[1..]);
        },
        .v => {
            // vertical relative positioning
            // sample: v619
            try self.handle_v(line[1..]);
        },
        .H => {
            // horizontal absolute positioning
            // sample: H72000
            const cur_page = self.cur_page orelse return TranspileError.StateError;
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            const h_z = try groff.zPosition.fromString(line[1..]);
            const fp_h = fixPointFromZPos(h_z);
            try text_obj.setE(fp_h);
            try cur_page.contents.graphicalObject.setX(fp_h);
        },
    }
}
/// read groff out from `reader` and output pdf to `writer`
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
            try self.handle_cmd(line);
        } else {
            break;
        }
    } else |_| {
        // nothing left to read any more
    }
    if (self.doc) |pdf_doc| {
        try self.writer.print("{f}", .{pdf_doc});
    }
    try self.writer.flush();
    return 0;
}
