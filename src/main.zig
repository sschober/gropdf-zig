//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    // put empty buffer into stderr writer to make it unbuffered
    var stderr_buffer: [0]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var doc = try pdf.Document.init();
    // const fontNumHv = try doc.addStandardFont(pdf.StandardFonts.Helvetica);
    // TODO add real font support
    const fontNumTi = try doc.addStandardFont(pdf.StandardFonts.Times_Roman);

    // read loop to parse and dispatch groff out input
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var reader = &stdin_reader.interface;
    var lineNum: usize = 0;
    var curPage: ?*pdf.Page = null;
    var curTextObject: ?*pdf.TextObject = null;
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
                curPage = try doc.addPage();
                curTextObject = curPage.?.contents.textObject;
            },
            .f => {
                try doc.addFontRefTo(curPage.?, fontNumTi);
                try curTextObject.?.selectFont(fontNumTi, 12);
            },
            .x => {
                // TODO x: implement sub-command parsing
            },
            .C => {
                try curTextObject.?.addWord(line[1..]);
            },
            .t => {
                try curTextObject.?.addWord(line[1..]);
            },
            .w => {
                if (line[1] == 'h') {
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
                const v = v_z / (72 * 12);
                try stderr.print("V {d} => {d}\n", .{ v_z, v });
                curTextObject.?.setF(v);
            },
            .H => {
                // vertical absolute positioning
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
    try doc.print(stdout);
    try stdout.flush();
}
