//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");
const String = []const u8;
const Allocator = std.mem.Allocator;
const Transpiler = @import("Transpiler.zig");

fn handle_font_cmd(
    allocator: Allocator,
    font_map: *std.AutoHashMap(usize, usize),
    font_glyph_widths_maps: *std.AutoHashMap(usize, groff.GlyphMap),
    doc: *pdf.Document,
    font_name: String,
    font_num: usize,
) !void {
    var pdf_font_num: usize = 0;
    if (std.mem.eql(u8, "TR", font_name)) {
        pdf_font_num = try doc.addStandardFont(pdf.StandardFonts.Times_Roman);
    } else if (std.mem.eql(u8, "TB", font_name)) {
        pdf_font_num = try doc.addStandardFont(pdf.StandardFonts.Times_Bold);
    } else if (std.mem.eql(u8, "TI", font_name)) {
        pdf_font_num = try doc.addStandardFont(pdf.StandardFonts.Times_Italic);
    } else if (std.mem.eql(u8, "CR", font_name)) {
        pdf_font_num = try doc.addStandardFont(pdf.StandardFonts.Courier);
    } else {
        std.debug.print("warning: unsupported font: {s}\n", .{font_name});
        return;
    }
    std.debug.print("adding {s} as pdf font num {d} to font map\n", .{ font_name, pdf_font_num });
    try font_map.put(font_num, pdf_font_num);
    const glyph_map = try groff.readGlyphMap(allocator, font_name);
    try font_glyph_widths_maps.put(pdf_font_num, glyph_map);
}

/// reads groff output (groff_out(5)) and produces a PDF 1.1 compatible file
/// reads from stdin and writes to stdout, takes no arguments ATM
pub fn main() !u8 {
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [8096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const reader = &stdin_reader.interface;

    var transpiler = Transpiler.init(allocator.allocator(), reader, stdout);
    const result = try transpiler.transpile();
    return result;
}
