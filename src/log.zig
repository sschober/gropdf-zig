const std = @import("std");

pub var is_debug: bool = false;
pub var is_warn: bool = false;

pub fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (is_debug) {
        std.debug.print(fmt, args);
    }
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (is_warn) {
        std.debug.print(fmt, args);
    }
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
