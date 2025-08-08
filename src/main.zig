//! gropdf-zig is a groff pdf output device

const std = @import("std");
const lib = @import("pdf.zig");

pub fn main() !void {
    var pdfDoc = try lib.PdfDocument.new();
    var page = try pdfDoc.addPage();
    try page.pdfObj.dict.put("Hallo", "Welt");
    //_ = try pdfDoc.addPage();
    const docStr = try pdfDoc.print();
    _ = try std.io.getStdOut().write(docStr);
}
