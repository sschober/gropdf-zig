//! gropdf-zig is a groff pdf output device

const std = @import("std");
const pdf = @import("pdf.zig");
const groff = @import("groff.zig");
const log = @import("log.zig");
const String = []const u8;
const Allocator = std.mem.Allocator;
const Transpiler = @import("Transpiler.zig");

/// reads groff output (groff_out(5)) and produces a PDF 1.1 compatible file
/// reads from stdin and writes to stdout, takes no arguments ATM
pub fn main() !u8 {
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();

    const args = try std.process.argsAlloc(allocator.allocator());
    if (args.len > 1) {
        // we have some command line arguments
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "-d")) {
                std.debug.print("enabling debugging output\n", .{});
                log.is_debug = true;
            } else if (std.mem.eql(u8, arg, "-w")) {
                log.is_warn = true;
            } else {
                std.debug.print("warning: unknown argument: {s}\n", .{arg});
            }
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [8096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const reader = &stdin_reader.interface;

    var transpiler =
        Transpiler.init(allocator.allocator(), //
            reader, stdout);
    const result = try transpiler.transpile();
    return result;
}
