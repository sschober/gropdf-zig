//! PDF object model and functions
//!
//! implements PDF version 1.1 as defined in [Adobe PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf#page412)
//! (pdfref17)
const std = @import("std");

/// alias to shorten usages below
const Allocator = std.mem.Allocator;
const String = []const u8;
const ArrayList = std.array_list.Managed;

// TODO read unitscale from device DESC file
pub var UNITSCALE: usize = 1000;

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
    allocator: Allocator,
    objNum: usize,
    kids: ArrayList(*Page),

    pub fn init(allocator: Allocator, n: usize) !*Pages {
        const result = try allocator.create(Pages);
        result.* = Pages{ .allocator = allocator, .objNum = n, .kids = ArrayList(*Page).init(allocator) };
        return result;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
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
        const res = try self.allocator.create(Page);
        res.* = Page.init(self.allocator, n, self.objNum, c);
        try self.kids.append(res);
        return res;
    }

    pub fn pdfObj(self: *Pages) !*Object {
        const res = try self.allocator.create(Object);
        res.* = Object{ .pages = self };
        return res;
    }
};

/// 3 digit exact point decimal - why? because, I think, we do not need
/// floating points precision behavior - we only need three digits and these
/// I want to be exact.
pub const FixPoint = struct {
    integer: usize = 0,
    fraction: usize = 0,
    /// custom format function to make this struct easily printable
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}", .{ self.integer, self.fraction });
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

/// pdf text object api - internally, it uses an array of lines
pub const TextObject = struct {
    allocator: Allocator,
    curLine: ArrayList(u8),
    lines: ArrayList(String),
    /// x coordinate, actually, but as pdf does matrix multiplication, we call it `e`
    e: FixPoint = FixPoint{},
    /// y coordinate, actually, but as pdf does matrix multiplication, we call it `f`
    f: FixPoint = FixPoint{},
    /// inter-word whitespace
    w: FixPoint = FixPoint{},
    /// initialze a new text object and its members
    pub fn init(allocator: Allocator) !*TextObject {
        const res = try allocator.create(TextObject);
        res.* = TextObject{
            .allocator = allocator,
            .curLine = ArrayList(u8).init(allocator),
            .lines = ArrayList(String).init(allocator),
        };
        return res;
    }
    /// issue Tf command
    pub fn selectFont(self: *TextObject, fNum: usize, fSize: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "/F{d} {d}. Tf", .{ fNum, fSize }));
    }
    /// issue Tm command with saved and latest positions (e and f)
    pub fn flushPos(self: *TextObject) !void {
        try self.lines.append( //
            try std.fmt.allocPrint(self.allocator, "1 0 0 1 {f} {f} Tm", //
                .{ self.e, self.f }));
    }
    /// set `e` position - aka x coordinate - also issues a Tm command
    pub fn setE(self: *TextObject, h: FixPoint) !void {
        try self.newLine();
        self.e = h;
        try self.flushPos();
    }
    /// set `f` position - aka y coordinate
    pub fn setF(self: *TextObject, f: FixPoint) void {
        self.f = f;
    }
    pub fn setLeading(self: *TextObject, l: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "{d} TL", .{l}));
    }
    pub fn setInterwordSpace(self: *TextObject, h: usize) !void {
        // TODO read space_width from font
        const space_width = 2765;
        const delta = @min(h, space_width);
        self.w = FixPoint.from(h - delta, UNITSCALE);
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "{d}.{d} Tw", .{ self.w.integer, self.w.fraction }));
    }
    pub fn addHorizontalSpace(self: *TextObject, h: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "{d} 0 Td", .{h}));
    }
    pub fn addVerticalSpace(self: *TextObject, v: usize) !void {
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "0 {d} Td", .{v}));
    }
    pub fn addWord(self: *TextObject, s: String) !void {
        try self.curLine.appendSlice(s);
    }
    pub fn addText(self: *TextObject, s: String) !void {
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "({s}) Tj", .{s}));
    }

    pub fn newLine(self: *TextObject) !void {
        if (self.curLine.items.len > 0) {
            // try self.flushPos();
            try self.addText(self.curLine.items);
            self.curLine = ArrayList(u8).init(self.allocator);
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("BT\n", .{});
        for (self.lines.items) |line| {
            try writer.print("{s}\n", .{line});
        }
        try writer.print("ET\n", .{});
    }
};

/// contains the actual content of pages, e.g., text objects (BT..ET)
pub const Stream = struct {
    allocator: Allocator,
    objNum: usize,
    textObject: *TextObject,

    pub fn init(allocator: Allocator, n: usize) !*Stream {
        const res = try allocator.create(Stream);
        res.* = Stream{ .allocator = allocator, .objNum = n, .textObject = try TextObject.init(allocator) };
        return res;
    }
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const stream = std.fmt.allocPrint(self.allocator, "{f}", .{self.textObject}) catch "";
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
        const res = try self.allocator.create(Object);
        res.* = Object{ .stream = self };
        return res;
    }
};

/// declares fonts in pdf documents; is referenced in resource dictionaries
/// in pages
pub const Font = struct {
    allocator: Allocator,
    objNum: usize,
    /// fonts are numbered in a document; the numbers are managed and assign in Document
    fontNum: usize,
    fontDef: String,
    pub fn init(allocator: Allocator, n: usize, l: usize, f: String) !*Font {
        const res = try allocator.create(Font);
        res.* = Font{ .allocator = allocator, .objNum = n, .fontNum = l, .fontDef = f };
        return res;
    }
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            \\<<
            \\/Type /Font
            \\{s}
            \\>>
            \\
        , .{self.fontDef});
    }
    pub fn pdfObj(self: *Font) !*Object {
        const res = try self.allocator.create(Object);
        res.* = Object{ .font = self };
        return res;
    }
};

/// envelope around page content; defines media box, font references and content
/// references
pub const Page = struct {
    allocator: Allocator,
    objNum: usize,
    parentNum: usize,
    /// a stream object encapsulates the actual page contents, e.g., text objects
    contents: *Stream,
    /// fonts have to be referenced as resources by their font and object number:
    /// /F0 3 0 R
    resources: ArrayList(usize),
    x: usize = 612,
    y: usize = 792,
    pub fn init(allocator: Allocator, n: usize, p: usize, c: *Stream) Page {
        return Page{ .allocator = allocator, .objNum = n, .parentNum = p, .contents = c, .resources = ArrayList(usize).init(allocator) };
    }
    pub fn resString(self: Page) !String {
        var res = ArrayList(u8).init(self.allocator);
        try res.writer().print("<<\n", .{});
        for (self.resources.items, 0..) |item, i| {
            try res.writer().print("/F{d} {d} 0 R\n", .{ i, item });
        }
        try res.writer().print(">>", .{});
        return res.items;
    }
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
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
        , .{ self.parentNum, self.contents.objNum, self.x, self.y, self.resString() catch "" });
    }
    pub fn pdfObj(self: *Page) !*Object {
        const res = try self.allocator.create(Object);
        res.* = Object{ .page = self };
        return res;
    }
};

/// references the page tree root node; no other purpose
const Catalog = struct {
    allocator: Allocator,
    objNum: usize,
    pages: String,

    pub fn init(allocator: Allocator, n: usize) !*Catalog {
        const res = try allocator.create(Catalog);
        res.* = Catalog{ .allocator = allocator, .objNum = n, .pages = "1 0 R" };
        return res;
    }
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            \\<<
            \\/Type /Catalog
            \\/Pages {s}
            \\>>
            \\
        , .{self.pages});
    }
    pub fn pdfObj(self: *Catalog) !*Object {
        const res = try self.allocator.create(Object);
        res.* = Object{ .catalog = self };
        return res;
    }
};

/// interface of all pdf objects; needed, to be able to add all objects to an
/// ArrayList in Document; later during printing of the document, we iterate
/// over all objects and call the respective write() function, which ahs type
/// specific implementations; in OO languages, this would be dynamic dispatch
pub const Object = union(enum) {
    pages: *Pages,
    page: *Page,
    catalog: *Catalog,
    font: *Font,
    stream: *Stream,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |impl| return impl.format(writer),
        }
    }
    pub fn objNum(self: Object) usize {
        switch (self) {
            inline else => |impl| return impl.objNum,
        }
    }
};

/// pdf document object - main interaction point, use this to add fonts, pages
/// and print the document.
pub const Document = struct {
    allocator: Allocator,
    /// linear sequence of objects, that together form the document
    objs: ArrayList(*Object),
    fonts: ArrayList(*Font),
    pages: *Pages,
    catalog: *Catalog,

    /// internal helper method to add a new object to the array list, which is
    /// later needed to print the document.
    fn addObj(self: *Document, obj: *Object) !void {
        try self.objs.append(obj);
    }

    /// initialze new document - starts out without fonts or pages
    pub fn init(allocator: Allocator) !Document {
        var self = Document{
            .allocator = allocator, //
            .objs = ArrayList(*Object).init(allocator), //
            .pages = try Pages.init(allocator, 1), //
            .catalog = try Catalog.init(allocator, 2), //
            .fonts = ArrayList(*Font).init((allocator)),
        };
        try self.addObj(try self.pages.pdfObj());
        try self.addObj(try self.catalog.pdfObj());
        return self;
    }

    /// add an adobe defined standard font to the document
    /// returns the font number
    pub fn addStandardFont(self: *Document, stdFnt: StandardFonts) !usize {
        return self.addFont(stdFnt.string());
    }

    /// add a font to the document by specifing its name
    pub fn addFont(self: *Document, f: String) !usize {
        const objIdx = self.objs.items.len + 1;
        const fontNum = self.fonts.items.len;
        const font = try Font.init(self.allocator, objIdx, self.fonts.items.len, f);
        try self.addObj(try font.pdfObj());
        try self.fonts.append(font);
        return fontNum;
    }

    /// once a font was added to the document, use this to add a reference to a page
    pub fn addFontRefTo(self: *Document, page: *Page, fNum: usize) !void {
        const font = self.fonts.items[fNum];
        try page.resources.append(font.objNum);
    }

    /// add a new and empty page to the document and return a pointer to it
    pub fn addPage(self: *Document) !*Page {
        const objIdx = self.objs.items.len + 1;
        const stream = try Stream.init(self.allocator, objIdx + 1);
        const page = try self.pages.addPage(objIdx, stream);
        try self.addObj(try page.pdfObj());
        try self.addObj(try stream.pdfObj());
        return page;
    }

    pub fn print(self: Document, writer: anytype) !void {
        var byteCount: usize = 0;
        var objIndices = ArrayList(usize).init(self.allocator);

        // header
        try writer.print("{s}", .{PDF_1_1_HEADER});
        byteCount += PDF_1_1_HEADER.len + 1;

        // objects
        for (self.objs.items) |obj| {
            try objIndices.append(byteCount);
            const objBytes = try std.fmt.allocPrint(self.allocator, "{f}", .{obj});
            const objStr = try std.fmt.allocPrint(self.allocator,
                \\{d} 0 obj
                \\{s}endobj
                \\
            , .{ obj.objNum(), objBytes });
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
