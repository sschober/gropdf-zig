//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");

pub fn main() !void {
    var doc = try pdf.Document.init();
    const fontNumHv = try doc.addStandardFont(pdf.StandardFonts.Helvetica);
    _ = try doc.addStandardFont(pdf.StandardFonts.Times_Roman);
    _ = try doc.addPage(fontNumHv, "BT\n/F0 36. Tf\n1 0 0 1 120 700 Tm\n50 TL\n(Hello, World!) Tj T*\n/F0 12. Tf\n(This is a second sentence!) Tj\nET");
    const writer = std.io.getStdOut().writer();
    try doc.print(writer);
}
