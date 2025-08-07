//! gropdf-zig is a groff pdf output device

const std = @import("std");
const lib = @import("pdf.zig");

pub fn main() !void {
    const pdfDoc = try lib.PdfDocument.new();
    const docStr = try pdfDoc.print();
    _ = try std.io.getStdOut().write(docStr);
}
