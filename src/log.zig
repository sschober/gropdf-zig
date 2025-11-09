const std = @import("std");

pub var is_debug: bool = false;
pub var is_warn: bool = false;

/// log unconditionally
pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// only log, if debugging is enabled
pub fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (is_debug) {
        std.debug.print(fmt, args);
    }
}

/// only log, if warning is enbaled
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (is_warn) {
        std.debug.print(fmt, args);
    }
}

/// log error unconditionally
pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
