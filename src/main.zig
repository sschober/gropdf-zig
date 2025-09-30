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
    // put empty buffer into stderr writer to make it unbuffered
    var stderr_buffer: [0]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;

    var doc: ?pdf.Document = null;
    // const fontNumHv = try doc.addStandardFont(pdf.StandardFonts.Helvetica);
    // TODO add font support
    var fontNumTi: ?usize = null;
    var lineNum: usize = 0;
    // we use optionals here, as zig does not allow null pointers
    var curPage: ?*pdf.Page = null;
    var curTextObject: ?*pdf.TextObject = null;
    // read loop to parse and dispatch groff out input
    while (reader.takeDelimiterExclusive('\n')) |line| {
        if (line.len == 0) {
            break;
        }
        lineNum += 1;
        //try stderr.print("{d}\n", .{lineNum});
        if (line[0] == '+') {
            continue;
        }
        const cmdStr = line[0..1];
        const cmd = std.meta.stringToEnum(groff.Out, cmdStr).?;
        switch (cmd) {
            .p => {
                curPage = try doc.?.addPage();
                curTextObject = curPage.?.contents.textObject;
            },
            .f => {
                try doc.?.addFontRefTo(curPage.?, fontNumTi.?);
                try curTextObject.?.selectFont(fontNumTi.?, 12);
            },
            .x => {
                // x X papersize
                if (line.len > 2) {
                    var it = std.mem.splitScalar(u8, line[2..], ' ');
                    const subCmd = std.meta.stringToEnum(groff.XSubCommand, it.next().?).?;
                    switch (subCmd) {
                        .init => {
                            doc = try pdf.Document.init(allocator.allocator());
                        },
                        .font => {
                            fontNumTi = try doc.?.addStandardFont(pdf.StandardFonts.Times_Roman);
                        },
                        .res => {
                            const arg = it.next().?;
                            const res = try std.fmt.parseUnsigned(usize, arg, 10);
                            const unitsize = res / 72;
                            try stderr.print("setting unit scale to {d}\n", .{unitsize});
                            pdf.UNITSCALE = unitsize;
                        },
                        .T => {
                            const arg = it.next().?;
                            if (std.mem.indexOf(u8, arg, "pdf") != 0) {
                                try stderr.print("unexpected output type: {s}", .{arg});
                                return 1;
                            }
                        },
                        .X => {
                            // x X papersize=421000z,595000z
                            const arg = it.next().?;
                            if (std.mem.indexOf(u8, arg, "papersize")) |idxPapersize| {
                                if (0 == idxPapersize) {
                                    // we found a `papersize` argument
                                    if (std.mem.indexOf(u8, arg, "=")) |idxEqual| {
                                        var itZSizes = std.mem.splitScalar(u8, arg[idxEqual + 1 ..], ',');
                                        const zX = itZSizes.next().?;
                                        const zPosX = try groff.zPosition.fromString(zX);
                                        const zPosXScaled = fixPointFromZPos(zPosX);
                                        if (zPosXScaled.integer != curPage.?.x) {
                                            try stderr.print("setting x width from {d} to {d}\n", .{ curPage.?.x, zPosXScaled.integer });
                                            curPage.?.x = zPosXScaled.integer;
                                        }
                                        const zY = itZSizes.next().?;
                                        const zPosY = try groff.zPosition.fromString(zY);
                                        const zPosYScaled = fixPointFromZPos(zPosY);
                                        if (zPosYScaled.integer != curPage.?.y) {
                                            try stderr.print("setting y width from {d} to {d}\n", .{ curPage.?.y, zPosYScaled.integer });
                                            curPage.?.y = zPosYScaled.integer;
                                        }
                                    }
                                } else {
                                    try stderr.print("unexpected index: {d}", .{idxPapersize});
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            .C => {
                if (std.mem.eql(u8, line[1..3], "hy")) {
                    // TODO replace `-` with real glyph from font
                    try curTextObject.?.addWord("-");
                } else {
                    try curTextObject.?.addWord(line[1..]);
                }
            },
            .s => {
                const fontSize = try std.fmt.parseInt(usize, line[1..], 10);
                try curTextObject.?.selectFont(fontNumTi.?, fontSize / pdf.UNITSCALE);
            },
            .t => {
                try curTextObject.?.addWord(line[1..]);
            },
            .w => {
                if (line[1] == 'h') {
                    const h = try std.fmt.parseInt(usize, line[2..], 10);
                    try curTextObject.?.setInterwordSpace(h);
                    try curTextObject.?.addWord(" ");
                }
            },
            .n => {
                try curTextObject.?.newLine();
            },
            .V => {
                // vertical absolute positioning
                // V151452
                const v_z = try groff.zPosition.fromString(line[1..]);
                var v = fixPointFromZPos(v_z);
                if (v.integer <= curPage.?.y) {
                    v.integer = curPage.?.y - v.integer;
                    curTextObject.?.setF(v);
                }
            },
            .h => {
                // we ignore `h` at the moment, as PDF already increases the position with each glyph
                // and we replace C glyphs with concrete chars.
            },
            .v => {
                // we ignore `v` as it seems the absolute positioning commands are enough
            },
            .H => {
                // horizontal absolute positioning
                // H72000
                // H97000
                const h_z = try groff.zPosition.fromString(line[1..]);
                try curTextObject.?.setE(fixPointFromZPos(h_z));
            },
            else => {
                try stderr.print("{d}: unknown command: {s}\n", .{ lineNum, line });
            },
        }
        try stdout.flush();
    } else |_| {}
    try stdout.print("{f}", .{doc.?});
    try stdout.flush();
    return 0;
}
