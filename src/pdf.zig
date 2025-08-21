//! PDF object model and functions
//!
//! implements PDF version 1.1 as defined in [Adobe PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf#page412)
//! (pdfref17)
const std = @import("std");
var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const String = []const u8;

/// header bytes which define pdf document version; the second line
/// should actually be binary data, but as zig sources are utf-8, that
/// would mess with byte counting
const PDF_1_1_HEADER =
    \\%PDF-1.1
    \\%abc
    \\
;

/// Standard font name definitions as defined by adobe in (pdfref17)
pub const StandardFonts = enum {
    Times_Roman,
    Times_Bold,
    Times_Italic,
    Times_Bold_Italic,
    Helvetica,
    Helvetica_Bold,
    Helvetica_Oblique,
    Helvetica_Bold_Oblique,
    Courier,
    Courier_Bold,
    Courier_Olbique,
    Courier_Bold_Oblique,
    Symbol,
    Zapf_Dingbats,
    pub fn string(self: StandardFonts) String {
        switch (self) {
            .Times_Roman => return "/BaseFont /Times-Roman\n/Subtype /Type1",
            .Helvetica => return "/BaseFont /Helvetica\n/Subtype /Type1",
            else => return "",
        }
    }
};

/// root node of a tree of pages; contains no content itself, but only points
/// to 'kids'
pub const Pages = struct {
    objNum: usize,
    kids: std.ArrayList(*Page),

    pub fn init(n: usize) !*Pages {
        const result = try allocator.create(Pages);
        result.* = Pages{ .objNum = n, .kids = std.ArrayList(*Page).init(allocator) };
        return result;
    }

    pub fn write(self: Pages, writer: anytype) !void {
        try writer.print(
            \\<<
            \\/Type /Pages
            \\/Kids [
        , .{});
        for (self.kids.items) |kid| {
            try writer.print("{d} 0 R ", .{kid.objNum});
        }
        try writer.print(
            \\]
            \\/Count {d}
            \\>>
            \\
        , .{self.kids.items.len});
    }

    fn addPage(self: *Pages, n: usize, c: *Stream) !*Page {
        const res = try allocator.create(Page);
        res.* = Page.init(n, self.objNum, c);
        try self.kids.append(res);
        return res;
    }

    pub fn pdfObj(self: *Pages) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .pages = self };
        return res;
    }
};

/// contains the actual content of pages, e.g., text objects (BT..ET)
pub const Stream = struct {
    objNum: usize,
    stream: String,
    pub fn init(n: usize, s: String) !*Stream {
        const res = try allocator.create(Stream);
        res.* = Stream{ .objNum = n, .stream = s };
        return res;
    }
    pub fn write(self: Stream, writer: anytype) !void {
        try writer.print(
            \\<<
            \\/Length {d}
            \\>>
            \\stream
            \\{s}
            \\endstream
            \\
        , .{ self.stream.len, self.stream });
    }
    pub fn pdfObj(self: *Stream) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .stream = self };
        return res;
    }
};

/// declares fonts in pdf documents; is referenced in resource dictionaries
/// in pages
pub const Font = struct {
    objNum: usize,
    /// fonts are numbered in a document; the numbers are managed and assign in Document
    fontNum: usize,
    fontDef: String,
    pub fn init(n: usize, l: usize, f: String) !*Font {
        const res = try allocator.create(Font);
        res.* = Font{ .objNum = n, .fontNum = l, .fontDef = f };
        return res;
    }
    pub fn write(self: Font, writer: anytype) !void {
        try writer.print(
            \\<<
            \\/Type /Font
            \\{s}
            \\>>
            \\
        , .{self.fontDef});
    }
    pub fn pdfObj(self: *Font) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .font = self };
        return res;
    }
};

/// envelope around page content; defines media box, font references and content
/// references
pub const Page = struct {
    objNum: usize,
    parentNum: usize,
    /// a stream object encapsulates the actual page contents, e.g., text objects
    contents: *Stream,
    /// fonts have to be referenced as resources by their font and object number:
    /// /F0 3 0 R
    resources: std.ArrayList(usize),
    pub fn init(n: usize, p: usize, c: *Stream) Page {
        return Page{ .objNum = n, .parentNum = p, .contents = c, .resources = std.ArrayList(usize).init(allocator) };
    }
    pub fn resString(self: Page) !String {
        var res = std.ArrayList(u8).init(allocator);
        try res.writer().print("<<\n", .{});
        for (self.resources.items, 0..) |item, i| {
            try res.writer().print("/F{d} {d} 0 R\n", .{ i, item });
        }
        try res.writer().print(">>", .{});
        return res.items;
    }
    pub fn write(self: Page, writer: anytype) !void {
        try writer.print(
            \\<<
            \\/Type /Page
            \\/Parent {d} 0 R
            \\/Contents {d} 0 R
            \\/MediaBox [0 0 612 792]
            \\/Resources
            \\<<
            \\/Font {s}
            \\>>
            \\>>
            \\
        , .{ self.parentNum, self.contents.objNum, try self.resString() });
    }
    pub fn pdfObj(self: *Page) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .page = self };
        return res;
    }
};

/// references the page tree root node; no other purpose
const Catalog = struct {
    objNum: usize,
    pages: String,
    pub fn init(n: usize) !*Catalog {
        const res = try allocator.create(Catalog);
        res.* = Catalog{ .objNum = n, .pages = "1 0 R" };
        return res;
    }
    fn write(self: Catalog, writer: anytype) !void {
        try writer.print(
            \\<<
            \\/Type /Catalog
            \\/Pages {s}
            \\>>
            \\
        , .{self.pages});
    }
    pub fn pdfObj(self: *Catalog) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .catalog = self };
        return res;
    }
};

/// interface of all pdf objects; needed, to be able to add all
/// objects to an ArrayList in Document; later during printing of
/// the document, we iterator over all objects and call the respective
/// print function, which is type specific; in OO languages, this is
/// dynamic dispatch
pub const Object = union(enum) {
    pages: *Pages,
    page: *Page,
    catalog: *Catalog,
    font: *Font,
    stream: *Stream,

    pub fn write(self: Object, writer: anytype) !void {
        switch (self) {
            inline else => |impl| return impl.write(writer),
        }
    }
    pub fn objNum(self: Object) usize {
        switch (self) {
            inline else => |impl| return impl.objNum,
        }
    }
};

pub const Document = struct {
    objs: std.ArrayList(*Object),
    fonts: std.ArrayList(*Font),
    pages: *Pages,
    catalog: *Catalog,

    fn addObj(self: *Document, obj: *Object) !void {
        try self.objs.append(obj);
    }

    pub fn init() !Document {
        var self = Document{ .objs = std.ArrayList(*Object).init(allocator), .pages = try Pages.init(1), .catalog = try Catalog.init(2), .fonts = std.ArrayList(*Font).init((allocator)) };
        try self.addObj(try self.pages.pdfObj());
        try self.addObj(try self.catalog.pdfObj());
        return self;
    }
    /// add an adobe defined standard font to the document
    /// returns the font number
    pub fn addStandardFont(self: *Document, stdFnt: StandardFonts) !usize {
        return self.addFont(stdFnt.string());
    }

    pub fn addFont(self: *Document, f: String) !usize {
        const objIdx = self.objs.items.len + 1;
        const font = try Font.init(objIdx, self.fonts.items.len, f);
        try self.addObj(try font.pdfObj());
        return objIdx;
    }

    pub fn addEmptyPage(self: *Document) !*Page {
        const objIdx = self.objs.items.len + 1;
        const stream = try Stream.init(objIdx + 1, "");
        const page = try self.pages.addPage(objIdx, stream);
        try self.addObj(try page.pdfObj());
        try self.addObj(try stream.pdfObj());
        return page;
    }

    pub fn addPage(self: *Document, s: String) !*Page {
        const objIdx = self.objs.items.len + 1;
        const stream = try Stream.init(objIdx + 1, s);
        const page = try self.pages.addPage(objIdx, stream);
        try self.addObj(try page.pdfObj());
        try self.addObj(try stream.pdfObj());
        return page;
    }

    pub fn print(self: Document, writer: anytype) !void {
        var byteCount: usize = 0;
        var objIndices = std.ArrayList(usize).init(allocator);

        // header
        try writer.print("{s}", .{PDF_1_1_HEADER});
        byteCount += PDF_1_1_HEADER.len + 1;

        // objects
        for (self.objs.items) |obj| {
            try objIndices.append(byteCount);
            var objBytes = std.ArrayList(u8).init(allocator);
            try obj.write(objBytes.writer());
            const objStr = try std.fmt.allocPrint(allocator,
                \\{d} 0 obj
                \\{s}endobj
                \\
            , .{ obj.objNum(), objBytes.items });
            try writer.print("{s}", .{objStr});
            byteCount += objStr.len;
        }

        // xref table
        const startXRef = byteCount;
        try writer.print(
            \\xref
            \\0 {d}
            \\0000000000 65535 f
            \\
        , .{self.objs.items.len + 1});
        for (objIndices.items) |idx| {
            try writer.print("{d:0>10} 00000 n\n", .{idx});
        }

        // trailer
        try writer.print(
            \\trailer
            \\<<
            \\/Root {d} 0 R
            \\/Size {d}
            \\>>
            \\startxref
            \\{d}
            \\
        , .{ self.catalog.objNum, self.objs.items.len + 1, startXRef });
    }
};
