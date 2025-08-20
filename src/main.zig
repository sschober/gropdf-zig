//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");

pub fn main() !void {
    var doc = try pdf.Document.init();
    const fontNumHv = try doc.addStandardFont(pdf.StandardFonts.Helvetica);
    const fontNumTi = try doc.addStandardFont(pdf.StandardFonts.Times_Roman);
    const page = try doc.addPage("BT\n/F0 36. Tf\n1 0 0 1 120 700 Tm\n50 TL\n(Hello, World!) Tj T*\n/F1 12. Tf\n(This is a second sentence!) Tj\nET");
    try page.resources.append(fontNumHv);
    try page.resources.append(fontNumTi);
    const writer = std.io.getStdOut().writer();
    try doc.print(writer);
}
