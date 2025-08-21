//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");

pub fn main() !void {
    var doc = try pdf.Document.init();
    const fontNumHv = try doc.addStandardFont(pdf.StandardFonts.Helvetica);
    const fontNumTi = try doc.addStandardFont(pdf.StandardFonts.Times_Roman);
    // TODO add text object support
    // const text = page.addText() // handle BT...ET parentheses
    // text.setFont(font); // refrences font if not already
    // text.addLine("...")
    const page = try doc.addPage(
        \\BT
        \\/F0 36. Tf
        \\1 0 0 1 120 700 Tm
        \\50 TL
        \\(Hello, World! This is a very long head line) Tj T*
        \\/F1 12. Tf
        \\(This is a second sentence!) Tj
        \\ET
        \\
    );
    try page.resources.append(fontNumHv);
    try page.resources.append(fontNumTi);
    const page2 = try doc.addEmptyPage();
    try page2.resources.append(fontNumHv);
    page2.contents.stream =
        \\BT
        \\/F0 36. Tf
        \\1 0 0 1 120 700 Tm
        \\50 TL
        \\(Hello, World! This is a very long head line) Tj T*
        \\ET
        \\
    ;
    const writer = std.io.getStdOut().writer();
    try doc.print(writer);
}
