//! Transpiler has the logic to interpret grout and render it to pdf
//!
const std = @import("std");
const pdf = @import("pdf.zig");
const pdf_reader = @import("pdf_reader.zig");
const groff = @import("groff.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const FixPoint = @import("FixPoint.zig");

const Self = @This();

const OverflowSlot = struct {
    doc_font_ref: pdf.Document.FontRef,
    enc: groff.FontEncoding,
};
const OverflowLoc = struct { slot_idx: usize, byte_code: u8 };

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
// maps grout font numbers to glyph name -> byte code maps (for C commands)
font_glyph_name_maps: std.AutoHashMap(usize, groff.GlyphNameMap),

// maps doc_font_ref.idx -> set of used byte codes (only for embedded fonts)
used_chars: std.AutoHashMap(usize, [256]bool),
// maps doc_font_ref.idx -> original Type1FontData (for subsetting)
embedded_font_data: std.AutoHashMap(usize, groff.Type1FontData),
// maps doc_font_ref.idx -> per-font encoding (for correct glyph name lookup in subsetter)
font_encodings: std.AutoHashMap(usize, groff.FontEncoding),

// --- overflow re-encoding state (for code > 255 glyphs) ---
// maps grout_font_idx -> ps_name for code > 255 glyphs (populated from FontMaps.high_glyphs)
high_glyph_maps: std.AutoHashMap(usize, groff.HighGlyphMap),
// maps grout_font_idx -> font name string (for addReEncodedFont)
embedded_font_names: std.AutoHashMap(usize, []const u8),
// maps grout_font_idx -> list of overflow encoding slots
overflow_encodings: std.AutoHashMap(usize, std.array_list.Managed(OverflowSlot)),
// maps grout_font_idx -> groff_name -> (slot_idx, byte_code)
overflow_name_map: std.AutoHashMap(usize, std.StringHashMap(OverflowLoc)),

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
        .font_glyph_name_maps = std.AutoHashMap(usize, groff.GlyphNameMap).init(allocator),
        .used_chars = std.AutoHashMap(usize, [256]bool).init(allocator),
        .embedded_font_data = std.AutoHashMap(usize, groff.Type1FontData).init(allocator),
        .font_encodings = std.AutoHashMap(usize, groff.FontEncoding).init(allocator),
        .high_glyph_maps = std.AutoHashMap(usize, groff.HighGlyphMap).init(allocator),
        .embedded_font_names = std.AutoHashMap(usize, []const u8).init(allocator),
        .overflow_encodings = std.AutoHashMap(usize, std.array_list.Managed(OverflowSlot)).init(allocator),
        .overflow_name_map = std.AutoHashMap(usize, std.StringHashMap(OverflowLoc)).init(allocator),
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
        if (self.doc) |*doc| {
            // Prefer standard PDF font references (no embedding needed); only embed
            // when there is no standard equivalent for this groff font name.
            if (groff_to_pdf_font_map.get(grout_font_ref.name)) |pdf_std_font| {
                doc_font_ref = try doc.addStandardFont(pdf_std_font);
                // Override the encoding with the full charset from the groff font descriptor.
                // The descriptor maps many special characters (bullet, quotes, dashes, …) to
                // positions that differ from PDF's built-in StandardEncoding, so we must list
                // them in /Differences to make the PDF viewer pick the right glyph.
                if (groff.readFontEncodingDiffs(self.allocator, grout_font_ref.name)) |diffs| {
                    defer self.allocator.free(diffs);
                    try doc.setFontEncoding(doc_font_ref, pdf_std_font.psName(), diffs);
                } else |_| {}  // if the descriptor is missing, keep the default encoding
            } else if (try groff.findAndLoadFont(self.allocator, grout_font_ref.name)) |font_data| {
                log.dbg("{d}: embedding Type1 font {s} for groff font {s}\n", .{
                    self.cur_line_num, font_data.font_name, grout_font_ref.name,
                });
                // buildFontMaps reads the descriptor once and produces a consistent
                // encoding + name map, remapping code > 255 glyphs (e.g. oldstyle
                // figures) to free slots in 0-255.
                const font_maps = groff.buildFontMaps(self.allocator, grout_font_ref.name) catch groff.FontMaps{
                    .encoding = .{null} ** 256,
                    .name_map = groff.GlyphNameMap.init(self.allocator),
                    .high_glyphs = groff.HighGlyphMap.init(self.allocator),
                };
                const enc_diffs = groff.fontEncodingToDiffs(self.allocator, font_maps.encoding) catch null;
                doc_font_ref = try doc.addEmbeddedFont(font_data, enc_diffs);
                try self.used_chars.put(doc_font_ref.idx, .{false} ** 256);
                try self.embedded_font_data.put(doc_font_ref.idx, font_data);
                try self.font_encodings.put(doc_font_ref.idx, font_maps.encoding);
                // Store the name map keyed by grout font number for C command lookup
                try self.font_glyph_name_maps.put(grout_font_ref.idx, font_maps.name_map);
                // Store overflow data for on-demand re-encoding
                try self.high_glyph_maps.put(grout_font_ref.idx, font_maps.high_glyphs);
                try self.embedded_font_names.put(grout_font_ref.idx, try self.allocator.dupe(u8, font_data.font_name));
            } else {
                log.err("error: could not find font file for: {s}\n", .{grout_font_ref.name});
                return;
            }
        } else return TranspileError.StateError;
        // register in doc_font_map so subsequent x font commands for the same
        // groff font number reuse the existing PDF font object instead of
        // embedding another copy
        try self.doc_font_map.put(grout_font_ref.idx, doc_font_ref);
        // the glyph map helps us move the x position in PDF text objects forward
        const glyph_widths_map = try groff.readGlyphMap(self.allocator, grout_font_ref.name);
        try self.font_glyph_widths_maps.put(grout_font_ref.idx, glyph_widths_map);
        // for non-embedded fonts, still build the glyph name map for C commands
        if (!self.font_glyph_name_maps.contains(grout_font_ref.idx)) {
            const glyph_name_map = groff.readGlyphNameMap(self.allocator, grout_font_ref.name) catch groff.GlyphNameMap.init(self.allocator);
            try self.font_glyph_name_maps.put(grout_font_ref.idx, glyph_name_map);
        }
    }
    if (self.doc) |*doc| {
        const cur_page = self.cur_page orelse return TranspileError.StateError;
        const page_font_ref = try doc.addFontRefTo(cur_page, doc_font_ref);
        log.dbg("{d}: adding {s} as {f} to page font map\n", .{ self.cur_line_num, grout_font_ref.name, doc_font_ref });
        try self.page_font_map.put(grout_font_ref.idx, page_font_ref);
    } else return TranspileError.StateError;
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
    if (self.doc) |*doc| {
        self.cur_page = try doc.addPage();
    } else return TranspileError.StateError;
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

/// relative vertical positioning
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

/// Handle `x X pdf: pdfpic <file> [-L|-C|-R] <width>z <height>z`
/// Embeds the first page of the given PDF as a Form XObject at the current
/// graphic position.
fn handle_pdfpic(self: *Self, it: *std.mem.SplitIterator(u8, .scalar)) !void {
    const cur_page = self.cur_page orelse return TranspileError.StateError;
    const doc = if (self.doc) |*d| d else return TranspileError.StateError;

    const file_path = it.next() orelse return TranspileError.MissingArgument;

    // optional alignment flag (-L, -C, -R) — consume and ignore
    var maybe_w = it.next() orelse return TranspileError.MissingArgument;
    if (std.mem.startsWith(u8, maybe_w, "-")) maybe_w = it.next() orelse return TranspileError.MissingArgument;

    const width_z = try groff.zPosition.fromString(maybe_w);
    const height_z = try groff.zPosition.fromString(it.next() orelse return TranspileError.MissingArgument);
    const target_w = fixPointFromZPos(width_z);
    const target_h = fixPointFromZPos(height_z);

    const embed = pdf_reader.embedFirstPage(self.allocator, doc, file_path) catch |err| {
        log.warn("{d}: warning: pdfpic: could not embed {s}: {}\n", .{ self.cur_line_num, file_path, err });
        return;
    };

    const xobj_idx = try doc.addXObjectTo(cur_page, embed.obj_num);

    const go = cur_page.contents.graphicalObject;
    const src_w = embed.bbox[2] - embed.bbox[0];
    const src_h = embed.bbox[3] - embed.bbox[1];
    // bottom-left y = current y position minus image height
    const y = go.cur_y.sub(target_h);
    try go.placeXObject(xobj_idx, go.cur_x, y, target_w, target_h, src_w, src_h);

    log.dbg("{d}: pdfpic: placed {s} as /Xo{d} at ({f},{f}) size {f}x{f}\n", .{
        self.cur_line_num, file_path, xobj_idx, go.cur_x, y, target_w, target_h,
    });
}

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
                // sample: x X pdf: pdfpic file.pdf -L 160000z 120000z
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
                } else if (std.mem.eql(u8, arg, "pdf:")) {
                    const sub = it.next() orelse return;
                    if (std.mem.eql(u8, sub, "pdfpic")) {
                        try self.handle_pdfpic(&it);
                    }
                    // marksuspend, markrestart, pagenumbering → silently ignored
                } else {
                    log.warn("{d}: warning: unkown x X subcommand: {s}\n", .{ self.cur_line_num, arg });
                }
            },
            else => {},
        }
    }
}

/// Find or assign an overflow slot for a code > 255 glyph.
/// Creates a new overflow re-encoding font object when the current one is full.
/// Returns null if the glyph is not in this font's high_glyph_map.
fn resolveOverflowGlyph(self: *Self, grout_font_num: usize, glyph_name: []const u8) !?OverflowLoc {
    // Already assigned?
    if (self.overflow_name_map.getPtr(grout_font_num)) |nm| {
        if (nm.get(glyph_name)) |loc| return loc;
    }
    // Known code > 255 glyph for this font?
    const hm = self.high_glyph_maps.getPtr(grout_font_num) orelse return null;
    const ps_name = hm.get(glyph_name) orelse return null;
    // Get or create the overflow slot list for this font.
    const primary_ref = self.doc_font_map.get(grout_font_num) orelse return null;
    const font_name = self.embedded_font_names.get(grout_font_num) orelse return null;
    const ov_entry = try self.overflow_encodings.getOrPut(grout_font_num);
    if (!ov_entry.found_existing) {
        ov_entry.value_ptr.* = std.array_list.Managed(OverflowSlot).init(self.allocator);
    }
    const ov_list = ov_entry.value_ptr;
    // Find a free byte slot in the last overflow encoding.
    var slot_idx: usize = 0;
    var byte_code: ?u8 = null;
    if (ov_list.items.len > 0) {
        slot_idx = ov_list.items.len - 1;
        for (ov_list.items[slot_idx].enc, 0..) |e, i| {
            if (e == null) { byte_code = @intCast(i); break; }
        }
    }
    if (byte_code == null) {
        // Current slot is full (or no slots yet) — create a new re-encoding.
        const new_ref = try self.doc.?.addReEncodedFont(primary_ref, font_name);
        try self.used_chars.put(new_ref.idx, .{false} ** 256);
        try ov_list.append(OverflowSlot{ .doc_font_ref = new_ref, .enc = .{null} ** 256 });
        slot_idx = ov_list.items.len - 1;
        byte_code = 0;
    }
    const bc = byte_code.?;
    ov_list.items[slot_idx].enc[bc] = ps_name;
    // Record assignment.
    const nm_entry = try self.overflow_name_map.getOrPut(grout_font_num);
    if (!nm_entry.found_existing) {
        nm_entry.value_ptr.* = std.StringHashMap(OverflowLoc).init(self.allocator);
    }
    const loc = OverflowLoc{ .slot_idx = slot_idx, .byte_code = bc };
    try nm_entry.value_ptr.put(try self.allocator.dupe(u8, glyph_name), loc);
    return loc;
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
    .{ "lq", 170 },   // left double quote = quotedblleft in StandardEncoding
    .{ "rq", 186 },   // right double quote = quotedblright in StandardEncoding
    .{ "cq", 169 },   // close quote (right single) = quotesingle in StandardEncoding
    .{ "oq", 96 },    // open quote (left single) = quoteleft in StandardEncoding
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

/// Record which byte codes are output for the current font (used for subsetting).
fn trackBytes(self: *Self, bytes: []const u8) void {
    const font_num = self.cur_groff_font_num orelse return;
    const doc_ref = self.doc_font_map.get(font_num) orelse return;
    if (self.used_chars.getPtr(doc_ref.idx)) |set| {
        for (bytes) |b| set[b] = true;
    }
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
            // typeset named glyph (special character)
            // sample: Cfi  Cem  C~A  Csix.oldstyle
            if (line.len < 2) {
                log.warn("{d}: warning: C command too short: {s}\n", .{ self.cur_line_num, line });
                return;
            }
            const glyph_name = line[1..]; // full name — may exceed 2 chars
            const text_obj = self.cur_text_object orelse return TranspileError.StateError;
            // look up in per-font name map first, then fall back to static glyph_map
            const code_opt: ?u8 = code_blk: {
                if (self.cur_groff_font_num) |fn_| {
                    if (self.font_glyph_name_maps.getPtr(fn_)) |nm| {
                        if (nm.get(glyph_name)) |c| break :code_blk c;
                    }
                }
                break :code_blk glyph_map.get(glyph_name);
            };
            if (code_opt) |code| {
                self.trackBytes(&.{code});
                // C commands do NOT auto-advance; the following `h` command provides the advance.
                try text_obj.addWordWithoutMove(&.{code});
            } else if (self.cur_groff_font_num) |fn_| {
                // Try overflow re-encoding for code > 255 glyphs.
                if (try self.resolveOverflowGlyph(fn_, glyph_name)) |loc| {
                    const ov_slot = self.overflow_encodings.get(fn_).?.items[loc.slot_idx];
                    const cur_page = self.cur_page orelse return TranspileError.StateError;
                    const ov_page_ref = try self.doc.?.addFontRefTo(cur_page, ov_slot.doc_font_ref);
                    const primary_page_ref = self.cur_pdf_page_font_ref orelse return TranspileError.StateError;
                    // Switch to overflow font, render, switch back — no cursor advance.
                    try text_obj.selectFont(ov_page_ref, self.cur_font_size);
                    try text_obj.addWordWithoutMove(&.{loc.byte_code});
                    try text_obj.selectFont(primary_page_ref, self.cur_font_size);
                    if (self.used_chars.getPtr(ov_slot.doc_font_ref.idx)) |set| set[loc.byte_code] = true;
                } else {
                    log.warn("{d}: warning: unhandled glyph name: {s}\n", .{ self.cur_line_num, glyph_name });
                    try text_obj.addWordWithoutMove(glyph_name);
                }
            } else {
                log.warn("{d}: warning: unhandled glyph name: {s}\n", .{ self.cur_line_num, glyph_name });
                try text_obj.addWordWithoutMove(glyph_name);
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
            self.trackBytes(line[1..]);
            try text_obj.addWord(line[1..], glyph_widths_map, self.cur_font_size);
        },
        .u => {
            // track-kerned word: uN word
            // N is in basic device units; added between each adjacent character pair
            var it = std.mem.splitScalar(u8, line[1..], ' ');
            const n_str = it.next() orelse return TranspileError.MissingArgument;
            const tracking_units = std.fmt.parseUnsigned(usize, n_str, 10) catch 0;
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
            self.trackBytes(word);
            if (tracking_units == 0) {
                try text_obj.addWord(word, glyph_widths_map, self.cur_font_size);
            } else {
                try text_obj.addWordWithTracking(word, glyph_widths_map, self.cur_font_size, tracking_units);
            }
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
    if (self.doc) |*doc| {
        // Finalise overflow re-encoding font dictionaries before output.
        var ov_it = self.overflow_encodings.iterator();
        while (ov_it.next()) |entry| {
            const grout_idx = entry.key_ptr.*;
            const font_name = self.embedded_font_names.get(grout_idx) orelse continue;
            for (entry.value_ptr.items) |*ov| {
                const diffs = try groff.fontEncodingToDiffs(self.allocator, ov.enc);
                try doc.setFontEncoding(ov.doc_font_ref, font_name, diffs);
            }
        }
        // Subset each embedded font to only the glyphs actually used, merging
        // usage across the primary encoding and all overflow re-encodings.
        var grout_it = self.doc_font_map.iterator();
        while (grout_it.next()) |entry| {
            const grout_idx = entry.key_ptr.*;
            const primary_ref = entry.value_ptr.*;
            const font_data = self.embedded_font_data.get(primary_ref.idx) orelse continue;
            if (doc.getFontFileStream(primary_ref.idx)) |ffs| {
                var needed = std.StringHashMap(void).init(self.allocator);
                defer needed.deinit();
                try needed.put(".notdef", {});
                // Primary encoding.
                if (self.used_chars.get(primary_ref.idx)) |primary_used| {
                    const primary_enc = self.font_encodings.get(primary_ref.idx) orelse .{null} ** 256;
                    for (primary_used, 0..) |used, b| {
                        if (used) {
                            const name = primary_enc[b] orelse groff.glyphNameForByte(@intCast(b));
                            if (name) |n| try needed.put(n, {});
                        }
                    }
                }
                // Overflow encodings.
                if (self.overflow_encodings.get(grout_idx)) |ov_list| {
                    for (ov_list.items) |*ov| {
                        const ov_used = self.used_chars.get(ov.doc_font_ref.idx) orelse continue;
                        for (ov_used, 0..) |used, b| {
                            if (used) {
                                if (ov.enc[b]) |n| try needed.put(n, {});
                            }
                        }
                    }
                }
                const subset = try groff.subsetType1Font(self.allocator, font_data, needed);
                ffs.data = subset.data;
                ffs.length1 = subset.length1;
                ffs.length2 = subset.length2;
                ffs.length3 = subset.length3;
            }
        }
        try doc.format(self.writer);
    }
    try self.writer.flush();
    return 0;
}
