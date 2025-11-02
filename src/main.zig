//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");
const FixPoint = @import("FixPoint.zig");

/// helper function translating a groff z position coordinate into a fix point
/// numer scaled by the pdf unit scale
fn fixPointFromZPos(zp: groff.zPosition) FixPoint {
    return FixPoint.from(zp.v, pdf.UNITSCALE);
}

/// reads groff output (groff_out(5)) and produces a PDF 1.1 compatible file
/// reads from stdin and writes to stdout, takes no arguments ATM
pub fn main() !u8 {
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [8096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    var doc: ?pdf.Document = null;
    // maps grout font numbers to pdf font numbers
    var font_map =
        std.AutoHashMap(usize, usize).init(allocator.allocator());
    // maps pdf font numbers to glyph widths maps
    var font_glyph_widths_maps =
        std.AutoHashMap(usize, [257]usize).init(allocator.allocator());
    var cur_pdf_font_num: ?usize = null;
    var cur_font_size: ?usize = null;
    var cur_line_num: usize = 0;
    // we use optionals here, as zig does not allow null pointers
    var cur_page: ?*pdf.Page = null;
    var cur_x: usize = 0;
    var cur_y: usize = 0;
    var cur_text_object: ?*pdf.TextObject = null;
    // read loop to parse and dispatch groff out input
    while (reader.takeDelimiter('\n')) |opt_line| {
        if (opt_line) |line| {
            if (line.len == 0) {
                break;
            }
            cur_line_num += 1;
            if (line[0] == '+') {
                //std.debug.print("{d}: ignoring + line\n", .{lineNum});
                continue;
            }
            const cmd = std.meta.stringToEnum(groff.Out, line[0..1]).?;
            switch (cmd) {
                .p => {
                    // begin new page
                    // sample: p 2
                    cur_page = try doc.?.addPage();
                    if (cur_x > 0) {
                        cur_page.?.x = cur_x;
                    }
                    if (cur_y > 0) {
                        cur_page.?.y = cur_y;
                    }
                    cur_text_object = cur_page.?.contents.textObject;
                },
                .f => {
                    // select font mounted at pos
                    // sample: f5
                    const font_num = try std.fmt.parseUnsigned(usize, line[1..], 10);
                    cur_pdf_font_num = font_map.get(font_num);
                    try doc.?.addFontRefTo(cur_page.?, cur_pdf_font_num.?);
                    try cur_text_object.?.selectFont(cur_pdf_font_num.?, cur_font_size orelse 11);
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
                                doc = try pdf.Document.init(allocator.allocator());
                            },
                            .font => {
                                // mount font position pos
                                // sample: x font 5 TR
                                const font_num = try std.fmt.parseUnsigned(usize, it.next().?, 10);
                                if (font_map.contains(font_num)) {
                                    continue;
                                }
                                const font_name = it.next().?;
                                var pdf_font_num: usize = 0;
                                if (std.mem.eql(u8, "TR", font_name)) {
                                    pdf_font_num = try doc.?.addStandardFont(pdf.StandardFonts.Times_Roman);
                                } else if (std.mem.eql(u8, "TB", font_name)) {
                                    pdf_font_num = try doc.?.addStandardFont(pdf.StandardFonts.Times_Bold);
                                } else if (std.mem.eql(u8, "TI", font_name)) {
                                    pdf_font_num = try doc.?.addStandardFont(pdf.StandardFonts.Times_Italic);
                                } else if (std.mem.eql(u8, "CR", font_name)) {
                                    pdf_font_num = try doc.?.addStandardFont(pdf.StandardFonts.Courier);
                                } else {
                                    std.debug.print("warning: unsupported font: {s}", .{font_name});
                                    continue;
                                }
                                std.debug.print("adding {s} as {d} to font map", .{ font_name, pdf_font_num });
                                try font_map.put(font_num, pdf_font_num);
                                const tr_glyph_map = try groff.readGlyphMap(allocator.allocator(), font_name);
                                try font_glyph_widths_maps.put(pdf_font_num, tr_glyph_map);
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
                                    std.debug.print("error: unexpected output type: {s}", .{arg});
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
                                            if (zPosXScaled.integer != cur_page.?.x) {
                                                cur_page.?.x = zPosXScaled.integer;
                                                cur_x = zPosXScaled.integer;
                                            }
                                            const zY = itZSizes.next().?;
                                            const zPosY = try groff.zPosition.fromString(zY);
                                            const zPosYScaled = fixPointFromZPos(zPosY);
                                            if (zPosYScaled.integer != cur_page.?.y) {
                                                cur_page.?.y = zPosYScaled.integer;
                                                cur_y = zPosYScaled.integer;
                                            }
                                        }
                                    } else {
                                        std.debug.print("{d}: warning: unexpected index: {d}\n", .{ cur_line_num, idxPapersize });
                                    }
                                } else {
                                    std.debug.print("{d}: warning: unkown x X subcommand: {s}\n", .{ cur_line_num, arg });
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
                        try cur_text_object.?.addWordWithoutMove("-");
                    } else if (std.mem.eql(u8, line[1..3], "lq")) {
                        try cur_text_object.?.addWordWithoutMove("\"");
                    } else if (std.mem.eql(u8, line[1..3], "rq")) {
                        try cur_text_object.?.addWordWithoutMove("\"");
                    } else {
                        std.debug.print("{d}: warning: unhandled character sequence: {s}\n", .{ cur_line_num, line[1..3] });
                        try cur_text_object.?.addWordWithoutMove(line[1..]);
                    }
                },
                .s => {
                    // set type size
                    // sample: s11000
                    const fontSize = try std.fmt.parseInt(usize, line[1..], 10);
                    cur_font_size = fontSize / pdf.UNITSCALE;
                    try cur_text_object.?.selectFont(cur_pdf_font_num.?, fontSize / pdf.UNITSCALE);
                },
                .t => {
                    // typeset word
                    // sample: thello
                    const glyph_map = font_glyph_widths_maps.get(cur_pdf_font_num.?).?;
                    try cur_text_object.?.addWord(line[1..], glyph_map, cur_font_size.?);
                },
                .w => {
                    // interword space
                    // sample: wh2750
                    if (line[1] == 'h') {
                        const h = try groff.zPosition.fromString(line[2..]);
                        try cur_text_object.?.addE(fixPointFromZPos(h));
                    }
                },
                .n => {
                    // new line command
                    // sample: n12000 0
                    try cur_text_object.?.newLine();
                },
                .V => {
                    // vertical absolute positioning
                    // sample: V151452
                    const v_z = try groff.zPosition.fromString(line[1..]);
                    var v = fixPointFromZPos(v_z);
                    //try stderr.print("v_y: {d} v: {f} ", .{ v_z.v, v });
                    if (v.integer <= cur_page.?.y) {
                        //-v.integer = curPage.?.y - v.integer;
                        v = v.subtractFrom(cur_page.?.y);
                        //try stderr.print("y - v: {f}\n", .{v});
                        try cur_text_object.?.setF(v);
                    }
                },
                .h => {
                    // horizontal relative positioning
                    // sample: h918
                    const h = try groff.zPosition.fromString(line[1..]);
                    try cur_text_object.?.addE(fixPointFromZPos(h));
                },
                .v => {
                    // we ignore `v` as it seems the absolute positioning commands are enough
                },
                .H => {
                    // horizontal absolute positioning
                    // sample: H72000
                    const h_z = try groff.zPosition.fromString(line[1..]);
                    try cur_text_object.?.setE(fixPointFromZPos(h_z));
                },
                else => {
                    std.debug.print("{d}: warning: unknown command: {s}\n", .{ cur_line_num, line });
                },
            }
            try stdout.flush();
        } else {
            break;
        }
    } else |_| {}
    if (doc) |renderedPdf| {
        try stdout.print("{f}", .{renderedPdf});
    }
    try stdout.flush();
    return 0;
}
