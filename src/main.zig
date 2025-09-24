//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");

/// reads groff_out(5) and produces PDF 1.1
/// reads from stdin and writes to stdout, takes no arguments ATM
pub fn main() !void {
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
                            doc = try pdf.Document.init();
                        },
                        .font => {
                            fontNumTi = try doc.?.addStandardFont(pdf.StandardFonts.Times_Roman);
                        },
                        .T => {
                            // TODO x T
                        },
                        .X => {
                            // x X papersize=421000z,595000z
                            const arg = it.next().?;
                            // try stderr.print("x X {s}\n", .{arg});
                            if (std.mem.indexOf(u8, arg, "papersize")) |idxPapersize| {
                                if (0 == idxPapersize) {
                                    // we found a `papersize` argument
                                    if (std.mem.indexOf(u8, arg, "=")) |idxEqual| {
                                        var itZSizes = std.mem.splitScalar(u8, arg[idxEqual + 1 ..], ',');
                                        const zX = itZSizes.next().?;
                                        const zY = itZSizes.next().?;
                                        try stderr.print("media box {s} {s}\n", .{ zX, zY });
                                        if (zX.len > 3 and zX[zX.len - 1] == 'z') {
                                            const x = try std.fmt.parseUnsigned(usize, zX[0 .. zX.len - 1], 10);
                                            curPage.?.x = x / pdf.UNITSCALE;
                                        }

                                        if (zY.len > 2 and zY[zY.len - 1] == 'z') {
                                            const y = try std.fmt.parseUnsigned(usize, zY[0 .. zY.len - 1], 10);
                                            curPage.?.y = y / pdf.UNITSCALE;
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
                    // try stderr.print("h: {d}\n", .{h});
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
                const v_z = try std.fmt.parseUnsigned(usize, line[1..], 10);
                const v = v_z / pdf.UNITSCALE;
                try stderr.print("V {d} => {d}\n", .{ v_z, v });
                if (v <= curPage.?.y) {
                    curTextObject.?.setF(curPage.?.y - v);
                }
            },
            .h => {
                // we ignore `h` at the moment, as PDF already increases the position with each glyph
                // and we replace C glyphs with concret chars.
            },
            .H => {
                // horizontal absolute positioning
                // H72000
                // H97000
                const h_z = try std.fmt.parseUnsigned(usize, line[1..], 10);
                try curTextObject.?.setE(pdf.zPosition{ .v = h_z });
            },
            else => {
                try stderr.print("{d}: unknown command: {s}\n", .{ lineNum, line });
            },
        }
        try stdout.flush();
    } else |_| {}
    try doc.?.print(stdout);
    try stdout.flush();
}
