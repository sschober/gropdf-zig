//! gropdf-zig is a groff pdf output device

const std = @import("std");
const lib = @import("pdf.zig");

pub fn main() !void {
    var pdfDoc = try lib.PdfDocument.new();
    _ = try pdfDoc.addPage("1. 0. 0. 1. 50. 700. cm\nBT\n  /F0 36. Tf\n  (Hello, World!) Tj \nET\n");
    //_ = try pdfDoc.addPage();
    const docStr = try pdfDoc.print();
    _ = try std.io.getStdOut().write(docStr);
}
