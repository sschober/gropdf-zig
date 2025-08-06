//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");

var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();
/// type alias for strings
const PdfString = []const u8;

/// new type alias for our object dictionaries
const PdfMap = std.StringHashMap(PdfString);

/// all known pdf object types
pub const PdfObjType = enum { pages, page, font, catalog };

/// basic building block of a pdf document
pub const PdfObject = struct { num: u32, type: PdfObjType, dict: PdfMap, stream: ?PdfString };

/// structure of a pdf file
pub const PdfDocument = struct {
    numObjects: u32,
    objs: std.ArrayList(PdfObject),
    pub fn new() PdfDocument {
        return PdfDocument{
            .numObjects = 1,
            .objs = std.ArrayList(PdfObject).init(allocator),
        };
    }
    pub fn print(self: PdfDocument) !void {
        const stdout_file = std.io.getStdOut().writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const out = bw.writer();
        // TODO header
        try out.print("%PDF-1.1\n%âãÏÓ\n", .{});
        // TODO objects
        for (self.objs.items) |obj| {
            try out.print("{} 0 obj\n", .{obj.num});
        }
        // TODO xref table
        // TODO trailer
        try bw.flush();
    }
};

const testing = std.testing;

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionalitey" {
    try testing.expect(add(3, 7) == 10);
}
