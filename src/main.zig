//! gropdf-zig is a groff pdf output device

const std = @import("std");
const lib = @import("pdf.zig");

pub fn main() !void {
    var pdfDoc = try lib.PdfDocument.new();
    _ = try pdfDoc.addPage("BT\n/F0 36. Tf\n1 0 0 1 120 700 Tm\n50 TL\n(Hello, World!) Tj T*\n/F0 12. Tf\n(This is a second sentence!) Tj\nET\n");
    const writer = std.io.getStdOut().writer();
    try pdfDoc.print(writer);
}
