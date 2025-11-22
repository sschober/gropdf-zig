const std = @import("std");
pub const String = []const u8;
pub const U8SplitIterator = std.mem.SplitIterator(u8, .scalar);
