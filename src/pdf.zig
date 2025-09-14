//! PDF object model and functions
//!
//! implements PDF version 1.1 as defined in [Adobe PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf#page412)
//! (pdfref17)
const std = @import("std");
var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const String = []const u8;
const ArrayList = std.array_list.Managed;

// TODO read unitscale from device DESC file
pub const UNITSCALE = 1000;

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
/// to 'kids' objects of type `Page`
pub const Pages = struct {
    objNum: usize,
    kids: ArrayList(*Page),

    pub fn init(n: usize) !*Pages {
        const result = try allocator.create(Pages);
        result.* = Pages{ .objNum = n, .kids = ArrayList(*Page).init(allocator) };
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

/// 3 digit exact point decimal
pub const FixPoint = struct {
    integer: usize = 0,
    fraction: usize = 0,
    pub fn toString(self: FixPoint) !String {
        var res = ArrayList(u8).init(allocator);
        try res.writer().print("{d}.{d}", .{ self.integer, self.fraction });
        return res.items;
    }
    pub fn from(n: usize, d: usize) FixPoint {
        var result = FixPoint{};
        result.integer = n / d;
        var rest = n % d;
        for (0..3) |_| {
            // we also scale the prvious rest
            const scaled_rest = 10 * rest;
            // update rest with what remains now
            rest = scaled_rest % d;
            if (scaled_rest == 0 and rest == 0) {
                // we can skip trailing `0`s: 7.5 == 7.50 === 7.500
                break;
            }
            // we `shift` previous result by one digti to the left
            result.fraction *= 10;
            // and add the new digit
            result.fraction += scaled_rest / d;
        }
        return result;
    }
};

const expect = std.testing.expect;
test "FixPoint" {
    const fp = FixPoint.from(15, 2);
    std.debug.print("fp {d}.{d}\n", .{ fp.integer, fp.fraction });
    try expect(fp.integer == 7);
    try expect(fp.fraction == 5);
    const fp1 = FixPoint.from(10, 3);
    std.debug.print("fp {d}.{d}\n", .{ fp1.integer, fp1.fraction });
    try expect(fp1.integer == 3);
    try expect(fp1.fraction == 333);
}

pub const zPosition = struct {
    v: usize = 0,
    pub fn toUserSpace(self: zPosition) FixPoint {
        // return FixPoint{ .n = self.v / self.unitsize, .d = self.v % self.unitsize };
        return FixPoint.from(self.v, UNITSCALE);
    }
};

/// pdf text object api above an array of lines
pub const TextObject = struct {
    curLine: ArrayList(u8) = ArrayList(u8).init(allocator),
    lines: ArrayList(String) = ArrayList(String).init(allocator),
    e: FixPoint = FixPoint{},
    f: usize = 0,
    w: FixPoint = FixPoint{},
    pub fn init() !*TextObject {
        const res = try allocator.create(TextObject);
        res.* = TextObject{};
        return res;
    }
    pub fn selectFont(self: *TextObject, fNum: usize, fSize: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(allocator, "/F{d} {d}. Tf", .{ fNum, fSize }));
    }
    pub fn flushPos(self: *TextObject) !void {
        try self.lines.append(try std.fmt.allocPrint(allocator, "1 0 0 1 {s} {d} Tm", .{ try self.e.toString(), self.f }));
    }
    pub fn setE(self: *TextObject, h: zPosition) !void {
        try self.newLine();
        self.e = h.toUserSpace();
        try self.flushPos();
    }
    pub fn setF(self: *TextObject, f: usize) void {
        self.f = f;
    }
    pub fn setLeading(self: *TextObject, l: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(allocator, "{d} TL", .{l}));
    }
    pub fn setInterwordSpace(self: *TextObject, h: usize) !void {
        // TODO read space_width from font
        const space_width = 2765;
        const delta = @min(h, space_width);
        self.w = FixPoint.from(h - delta, UNITSCALE);
        try self.lines.append(try std.fmt.allocPrint(allocator, "{d}.{d} Tw", .{ self.w.integer, self.w.fraction }));
    }
    pub fn addHorizontalSpace(self: *TextObject, h: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(allocator, "{d} 0 Td", .{h}));
    }
    pub fn addVerticalSpace(self: *TextObject, v: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(allocator, "0 {d} Td", .{v}));
    }
    pub fn addWord(self: *TextObject, s: String) !void {
        try self.curLine.appendSlice(s);
    }
    pub fn addText(self: *TextObject, s: String) !void {
        try self.lines.append(try std.fmt.allocPrint(allocator, "({s}) Tj", .{s}));
    }

    pub fn newLine(self: *TextObject) !void {
        if (self.curLine.items.len > 0) {
            // try self.flushPos();
            try self.addText(self.curLine.items);
            self.curLine = ArrayList(u8).init(allocator);
        }
    }

    pub fn write(self: TextObject, writer: anytype) !void {
        try writer.print("BT\n", .{});
        for (self.lines.items) |line| {
            try writer.print("{s}\n", .{line});
        }
        try writer.print("ET\n", .{});
    }
};

/// contains the actual content of pages, e.g., text objects (BT..ET)
pub const Stream = struct {
    objNum: usize,
    textObject: *TextObject,

    pub fn init(n: usize) !*Stream {
        const res = try allocator.create(Stream);
        res.* = Stream{ .objNum = n, .textObject = try TextObject.init() };
        return res;
    }
    pub fn write(self: Stream, writer: anytype) !void {
        var objBytes = ArrayList(u8).init(allocator);
        try self.textObject.write(objBytes.writer());
        const stream = objBytes.items;
        try writer.print(
            \\<<
            \\/Length {d}
            \\>>
            \\stream
            \\{s}
            \\endstream
            \\
        , .{ stream.len, stream });
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
    resources: ArrayList(usize),
    x: usize = 612,
    y: usize = 792,
    pub fn init(n: usize, p: usize, c: *Stream) Page {
        return Page{ .objNum = n, .parentNum = p, .contents = c, .resources = ArrayList(usize).init(allocator) };
    }
    pub fn resString(self: Page) !String {
        var res = ArrayList(u8).init(allocator);
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
            \\/MediaBox [0 0 {d} {d}]
            \\/Resources
            \\<<
            \\/Font {s}
            \\>>
            \\>>
            \\
        , .{ self.parentNum, self.contents.objNum, self.x, self.y, try self.resString() });
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
    objs: ArrayList(*Object),
    fonts: ArrayList(*Font),
    pages: *Pages,
    catalog: *Catalog,

    fn addObj(self: *Document, obj: *Object) !void {
        try self.objs.append(obj);
    }

    pub fn init() !Document {
        var self = Document{ .objs = ArrayList(*Object).init(allocator), .pages = try Pages.init(1), .catalog = try Catalog.init(2), .fonts = ArrayList(*Font).init((allocator)) };
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
        const fontNum = self.fonts.items.len;
        const font = try Font.init(objIdx, self.fonts.items.len, f);
        try self.addObj(try font.pdfObj());
        try self.fonts.append(font);
        return fontNum;
    }

    pub fn addFontRefTo(self: *Document, page: *Page, fNum: usize) !void {
        const font = self.fonts.items[fNum];
        try page.resources.append(font.objNum);
    }

    pub fn addPage(self: *Document) !*Page {
        const objIdx = self.objs.items.len + 1;
        const stream = try Stream.init(objIdx + 1);
        const page = try self.pages.addPage(objIdx, stream);
        try self.addObj(try page.pdfObj());
        try self.addObj(try stream.pdfObj());
        return page;
    }

    pub fn print(self: Document, writer: anytype) !void {
        var byteCount: usize = 0;
        var objIndices = ArrayList(usize).init(allocator);

        // header
        try writer.print("{s}", .{PDF_1_1_HEADER});
        byteCount += PDF_1_1_HEADER.len + 1;

        // objects
        for (self.objs.items) |obj| {
            try objIndices.append(byteCount);
            var objBytes = ArrayList(u8).init(allocator);
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
