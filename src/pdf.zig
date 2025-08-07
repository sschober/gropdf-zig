//! PDF object model and functions
const std = @import("std");

var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();
/// type alias for strings
const PdfString = []const u8;

/// new type alias for our object dictionaries
const PdfMap = std.StringHashMap(PdfString);

/// all known pdf object types
pub const PdfObjType = enum { Pages, page, font, catalog };

/// basic building block of a pdf document
pub const PdfObject = struct {
    num: u32,
    type: PdfObjType,
    dict: PdfMap,
    stream: ?PdfString,

    pub fn new(num: u32, objType: PdfObjType) !PdfObject {
        var dict =
            PdfMap.init(allocator);
        try dict.put("Type", @tagName(objType));
        return PdfObject{ .num = num, .type = objType, .dict = dict, .stream = "" };
    }

    pub fn print(self: PdfObject) !PdfString {
        var result = std.ArrayList(u8).init(allocator);
        var out = result.writer();
        try out.print("{} 0 obj\n", .{self.num});
        try out.print("<<\n", .{});
        var it = self.dict.iterator();
        while (it.next()) |entry| {
            try out.print("/{s} /{s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try out.print(">>\n", .{});
        return result.items;
    }
};

/// structure of a pdf file
pub const PdfDocument = struct {
    numObjects: u32,
    objs: std.ArrayList(PdfObject),
    pageTreeRoot: PdfObject,

    /// create a new empty pdf document
    pub fn new() !PdfDocument {
        // TODO init catalog
        var objs = std.ArrayList(PdfObject).init(allocator);
        const pageTreeRoot = try PdfObject.new(1, PdfObjType.Pages);
        try objs.append(pageTreeRoot);
        return PdfDocument{ .numObjects = 1, .objs = objs, .pageTreeRoot = pageTreeRoot };
    }

    /// print the pdf document represented by this object
    pub fn print(self: PdfDocument) !PdfString {
        var result = std.ArrayList(u8).init(allocator);
        var out = result.writer();
        // header
        try out.print("%PDF-1.1\n%âãÏÓ\n", .{});
        // objects
        for (self.objs.items) |obj| {
            //try out.print("{} 0 obj\n", .{obj.num});
            const objStr = try obj.print();
            try out.print("{s}", .{objStr});
        }
        // TODO xref table
        // TODO trailer
        return result.items;
    }
};
