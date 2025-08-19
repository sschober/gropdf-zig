//! gropdf-zig is a groff pdf output device

const std = @import("std");
const lib = @import("pdf.zig");
const pdf = @import("pdf2.zig");

pub fn main() !void {
    // var pdfDoc = try lib.PdfDocument.new();
    // _ = try pdfDoc.addPage("BT\n/F0 36. Tf\n1 0 0 1 120 700 Tm\n50 TL\n(Hello, World!) Tj T*\n/F0 12. Tf\n(This is a second sentence!) Tj\nET\n");
    var doc = try pdf.Document.init();
    const fontNum = try doc.addFont("/BaseFont /Times-Roman\n/Subtype /Type1\n/Type /Font");
    _ = try doc.addPage(fontNum, "BT\n/F13 36. Tf\n1 0 0 1 120 700 Tm\n50 TL\n(Hello, World!) Tj T*\n/F0 12. Tf\n(This is a second sentence!) Tj\nET");
    const writer = std.io.getStdOut().writer();
    try doc.print(writer);
}
