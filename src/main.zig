//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");
const String = []const u8;
const Allocator = std.mem.Allocator;
const Transpiler = @import("Transpiler.zig");

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
