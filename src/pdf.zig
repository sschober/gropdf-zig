//! PDF object model and functions
const std = @import("std");

var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();
/// type alias for strings
const PdfString = []const u8;

/// new type alias for our object dictionaries
const PdfMap = std.StringHashMap(PdfString);

const PdfObjList = std.ArrayList(PdfObject);

/// all known pdf object types
pub const PdfObjType = enum { Pages, Page, Catalog, Font, Stream };

/// basic building block of a pdf document
pub const PdfObject = struct {
    num: usize,
    type: PdfObjType,
    dict: PdfMap,
    stream: ?PdfString,

    pub fn new(num: usize, objType: PdfObjType) !PdfObject {
        var dict =
            PdfMap.init(allocator);
        const typeString = try std.fmt.allocPrint(allocator, "/{s}", .{@tagName(objType)});
        try dict.put("Type", typeString);
        return PdfObject{ .num = num, .type = objType, .dict = dict, .stream = "" };
    }

    pub fn ref(self: PdfObject) !PdfString {
        return try std.fmt.allocPrint(allocator, "{d} 0 R", .{self.num});
    }

    pub fn print(self: PdfObject) !PdfString {
        var result = std.ArrayList(u8).init(allocator);
        var out = result.writer();
        try out.print("{!s}\n", .{self.ref()});
        try out.print("<<\n", .{});
        if (self.type == PdfObjType.Stream) {
            try out.print("/Length {d}\n", .{self.stream.?.len});
            try out.print(">>\n", .{});
            try out.print("{s}", .{self.stream.?});
        } else {
            var it = self.dict.iterator();
            while (it.next()) |entry| {
                try out.print("/{s} {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
            try out.print(">>\n", .{});
        }
        try out.print("endobj\n", .{});
        return result.items;
    }
};

pub const PdfPage = struct {
    pdfObj: PdfObject,
    resources: PdfObject,
    contents: PdfObject,

    pub fn new(parent: PdfObject, num: usize) !PdfPage {
        var obj = try PdfObject.new(num, PdfObjType.Page);
        try obj.dict.put("Parent", try parent.ref());
        var res = try PdfObject.new(num + 1, PdfObjType.Font);
        try res.dict.put("Font", "\n<<\n/F0\n<<\n/BaseFont /Times\n/Subtype /Type1\n/Type /Font \n>>\n>>");
        try obj.dict.put("Resources", try res.ref());
        var contents = try PdfObject.new(num + 2, PdfObjType.Stream);
        try obj.dict.put("MediaBox", "[0 0 612 792]");
        try obj.dict.put("Contents", try contents.ref());
        return PdfPage{ .pdfObj = obj, .resources = res, .contents = contents };
    }
};

pub const PdfPages = struct {
    // prefer encapsulation over inheritance... poor man's OO
    pdfObj: PdfObject,
    kids: PdfObjList,

    pub fn new() !PdfPages {
        var obj = try PdfObject.new(1, PdfObjType.Pages);
        try obj.dict.put("Kids", "[]");
        try obj.dict.put("Count", "0");
        return PdfPages{ .pdfObj = obj, .kids = PdfObjList.init(allocator) };
    }

    pub fn addPage(self: *PdfPages, page: PdfPage) !void {
        try self.kids.append(page.pdfObj);
        var kidsString = std.ArrayList(u8).init(allocator);
        try kidsString.writer().print("[ ", .{});
        for (self.kids.items) |kid| {
            try kidsString.writer().print("{s} ", .{try kid.ref()});
        }
        try kidsString.writer().print("]", .{});
        try self.pdfObj.dict.put("Kids", kidsString.items);
        try self.pdfObj.dict.put("Count", try std.fmt.allocPrint(allocator, "{d}", .{self.kids.items.len}));
    }
};

const PDF_1_1_HEADER = "%PDF-1.1\n%âãÏÓ\n";

/// structure of a pdf file
pub const PdfDocument = struct {
    objs: std.ArrayList(PdfObject),
    pages: PdfPages,
    catalog: PdfObject,

    /// create a new empty pdf document
    pub fn new() !PdfDocument {
        var objs = std.ArrayList(PdfObject).init(allocator);
        const pages = try PdfPages.new();
        try objs.append(pages.pdfObj);
        var catalog = try PdfObject.new(2, PdfObjType.Catalog);
        try catalog.dict.put("Pages", try pages.pdfObj.ref());
        try objs.append(catalog);
        return PdfDocument{ .objs = objs, .pages = pages, .catalog = catalog };
    }

    pub fn addPage(self: *PdfDocument) !PdfPage {
        const objNum = self.objs.items.len;
        const page = try PdfPage.new(self.pages.pdfObj, objNum + 1);
        try self.objs.append(page.pdfObj);
        try self.objs.append(page.contents);
        try self.objs.append(page.resources);
        try self.pages.addPage(page);
        return page;
    }

    /// print the pdf document represented by this object
    pub fn print(self: PdfDocument) !PdfString {
        var byteCount: usize = 0;
        var objIndices = std.ArrayList(usize).init(allocator);
        var result = std.ArrayList(u8).init(allocator);
        var out = result.writer();
        // header
        try out.print("{s}", .{PDF_1_1_HEADER});
        byteCount += PDF_1_1_HEADER.len;
        // objects
        for (self.objs.items) |obj| {
            try objIndices.append(byteCount);
            const objStr = try obj.print();
            try out.print("{s}", .{objStr});
            byteCount += objStr.len;
        }
        const startXRef = byteCount;
        // xref table
        try out.print("xref\n0 {d}\n0000000000 65535 f\n", .{self.objs.items.len + 1});
        for (objIndices.items) |idx| {
            try out.print("{d:0>10} 00000 n\n", .{idx});
        }
        // trailer
        try out.print("trailer\n", .{});
        try out.print("<<\n/Root {s}\n/Size {d}\n>>\n", .{ try self.catalog.ref(), self.objs.items.len + 1 });
        try out.print("startxref\n{d}\n", .{startXRef});
        return result.items;
    }
};
