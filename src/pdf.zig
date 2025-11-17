//! PDF object model and functions
//!
//! implements PDF version 1.1 as defined increase
//! [Adobe PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf#page412)
//! (pdfref17)
const std = @import("std");
const FixPoint = @import("FixPoint.zig");
const log = @import("log.zig");

/// alias to shorten usages below
const Allocator = std.mem.Allocator;
const String = []const u8;
const ArrayList = std.array_list.Managed;

// TODO read unitscale from device DESC file
/// device dependent scaling factor for measures like page dimensions and font
/// sizes
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
            .Times_Bold => return "/BaseFont /Times-Bold\n/Subtype /Type1",
            .Times_Italic => return "/BaseFont /Times-Italic\n/Subtype /Type1",
            .Helvetica => return "/BaseFont /Helvetica\n/Subtype /Type1",
            .Courier => return "/BaseFont /Courier\n/Subtype /Type1",
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

    /// init a new Page object and add it to this Pages collection and return the Page object
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

pub const GraphicalObject = struct {
    allocator: Allocator,
    cur_line: ArrayList(u8),
    lines: ArrayList(String),
    cur_x: FixPoint = FixPoint{},
    cur_y: FixPoint = FixPoint{},
    cur_thicknes: FixPoint = FixPoint{},
    pub fn init(allocator: Allocator) !*GraphicalObject {
        const res = try allocator.create(GraphicalObject);
        res.* = GraphicalObject{
            .allocator = allocator, //
            .cur_line = ArrayList(u8).init(allocator),
            .lines = ArrayList(String).init(allocator),
        };
        return res;
    }
    pub fn setX(self: *GraphicalObject, x: FixPoint) !void {
        self.cur_x = x;
    }
    pub fn setY(self: *GraphicalObject, y: FixPoint) !void {
        self.cur_y = y;
    }
    /// append `s` to the internal lines array list
    fn flushLine(self: *GraphicalObject, s: String) !void {
        try self.lines.append(s);
    }
    /// flush the current line and initialize a new one
    fn newLine(self: *GraphicalObject) !void {
        if (self.cur_line.items.len > 0) {
            try self.flushLine(self.cur_line.items);
            self.cur_line = ArrayList(u8).init(self.allocator);
        }
    }
    /// draw a line from current position to given
    pub fn lineTo(self: *GraphicalObject, d_x: FixPoint, d_y: FixPoint) !void {
        try self.newLine();
        const x = self.cur_x.addTo(d_x);
        const y = self.cur_y.addTo(d_y);
        log.dbg("pdf: line from {f} {f} to {f} {f}\n", .{ self.cur_x, self.cur_y, x, y });
        try self.lines.append(try std.fmt.allocPrint(self.allocator, //
            "{f} {f} m {f} {f} l S", .{ self.cur_x, self.cur_y, x, y }));
    }
    /// set line width for drawing
    pub fn lineWidth(self: *GraphicalObject, t: FixPoint) !void {
        try self.newLine();
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "{f} w", .{t}));
    }
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        for (self.lines.items) |line| {
            try writer.print("{s}\n", .{line});
        }
    }
};
/// pdf text object api - acts like a buffer, saving commands in its state
/// which are rendered out when the object is formatted. internally, it uses
/// an array of lines, and a current line buffer. implements relative positioning.
///
/// relative positioning would not strictly be necessary, as PDF computes word
/// lengths automatically, but groff uses relative positioning and we cannot
/// query the current x position of the text matrix. thus, we are forced to
/// keep count ourselves.
pub const TextObject = struct {
    allocator: Allocator,
    curLine: ArrayList(u8),
    /// buffers the lines of this text object. they are filled line after line,
    /// according to the grout output.
    /// TODO text object: save commands instead of lines
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
    pub fn selectFont(self: *TextObject, page_font_ref: Page.FontRef, fSize: usize) !void {
        try self.newLine();
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "/F{d} {d}. Tf", .{ page_font_ref.idx, fSize }));
    }
    /// issue Tm command with saved and latest positions (e and f)
    pub fn flushPos(self: *TextObject) !void {
        const newTm = try std.fmt.allocPrint(self.allocator, "1 0 0 1 {f} {f} Tm", //
            .{ self.e, self.f });
        // only append new Tm command if the last line is not identical
        // this case happens quite often with the grout input
        if (self.lines.items.len == 0 or !std.mem.eql(u8, self.lines.items[self.lines.items.len - 1], newTm)) {
            try self.lines.append(newTm);
        }
    }
    /// set `e` position - aka x coordinate - also issues a Tm command
    pub fn setE(self: *TextObject, h: FixPoint) !void {
        try self.newLine();
        self.e = h;
        //try self.addComment(try std.fmt.allocPrint(self.allocator, "H: {f} ", .{h}));
        try self.flushPos();
    }
    /// increment x position by h, flush current line and init a new one
    pub fn addE(self: *TextObject, h: FixPoint) !void {
        self.e = self.e.addTo(h);
        try self.newLine();
        try self.flushPos();
    }
    /// set `f` position - aka y coordinate
    pub fn setF(self: *TextObject, f: FixPoint) !void {
        try self.newLine();
        self.f = f;
        try self.flushPos();
    }
    /// add a word to the current text object and increase the internal x coordinate by a computed length.
    /// that's why we need the glyph width map for the current font and the current font size
    pub fn addWord(self: *TextObject, s: String, glyph_widths: [257]usize, font_size: usize) !void {
        try self.curLine.appendSlice(s);
        var word_length = FixPoint{};
        for (s) |c| {
            const glyph_width = glyph_widths[c];
            const adjusted = FixPoint.from(glyph_width * font_size, UNITSCALE);
            word_length = word_length.addTo(adjusted);
        }
        self.e = self.e.addTo(word_length);
    }
    /// add a word to the current text object, but do not increase the internal
    /// x coordinate. this is handy for C commands, which are always followed
    /// by `w h` commands with enough space increment.
    pub fn addWordWithoutMove(self: *TextObject, s: String) !void {
        try self.curLine.appendSlice(s);
    }
    fn addComment(self: *TextObject, s: String) !void {
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "% {s}", .{s}));
    }
    /// append `s` to the internal lines array list
    fn flushLine(self: *TextObject, s: String) !void {
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "({s}) Tj", .{s}));
    }

    /// flush the current line and initialize a new one
    pub fn newLine(self: *TextObject) !void {
        if (self.curLine.items.len > 0) {
            try self.flushLine(self.curLine.items);
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
    graphicalObject: *GraphicalObject,

    pub fn init(allocator: Allocator, n: usize) !*Stream {
        const res = try allocator.create(Stream);
        res.* = Stream{
            .allocator = allocator, //
            .objNum = n,
            .textObject = try TextObject.init(allocator),
            .graphicalObject = try GraphicalObject.init(allocator),
        };
        return res;
    }
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const stream = std.fmt.allocPrint(self.allocator, //
            "{f}\n{f}", .{ self.graphicalObject, self.textObject }) catch "";
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

    /// Fonts registered on a page are assigned an index. This struct
    /// captures the index and the fact, that the font was
    /// registered.
    pub const FontRef = struct {
        idx: usize,
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("Page.FontRef: {d}", .{self.idx});
        }
    };

    pub fn init(allocator: Allocator, n: usize, p: usize, c: *Stream) Page {
        return Page{ .allocator = allocator, .objNum = n, .parentNum = p, .contents = c, .resources = ArrayList(usize).init(allocator) };
    }
    /// iterates over resources list and renders /Fn k 0 R pdf object references
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

    /// a font that is registered on a document is assigned an index
    pub const FontRef = struct {
        idx: usize,
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("Doc.FontRef: {d}", .{self.idx});
        }
    };

    /// add an adobe defined standard font to the document
    /// returns the font number
    pub fn addStandardFont(self: *Document, stdFnt: StandardFonts) !FontRef {
        return self.addFont(stdFnt.string());
    }

    /// add a font to the document by specifing its name returns the index of
    /// the font into our internal font list
    pub fn addFont(self: *Document, f: String) !FontRef {
        const objIdx = self.objs.items.len + 1;
        const fontNum = self.fonts.items.len;
        const font = try Font.init(self.allocator, objIdx, self.fonts.items.len, f);
        try self.addObj(try font.pdfObj());
        try self.fonts.append(font);
        const result = FontRef{ .idx = fontNum };
        log.dbg("pdf: added font as {f} with idx {d}:\n{s}\n", .{ result, objIdx, f });
        return result;
    }

    /// once a font was added to the document, use this to add a reference to a page
    pub fn addFontRefTo(self: *Document, page: *Page, doc_font_ref: Document.FontRef) !Page.FontRef {
        const font = self.fonts.items[doc_font_ref.idx];
        if (doc_font_ref.idx >= page.resources.items.len) {
            log.dbg("pdf: adding {f} as obj num {d} to page {d}\n", .{ doc_font_ref, font.objNum, page.objNum });
            try page.resources.append(font.objNum);
            return Page.FontRef{ .idx = page.resources.items.len - 1 };
        } else {
            log.dbg("pdf: assuming already seen {f}. not adding to page {d}...\n", .{ doc_font_ref, page.objNum });
            return Page.FontRef{ .idx = doc_font_ref.idx };
        }
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

    /// renders the pdf coument to the given writer
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var byteCount: usize = 0;
        var objIndices = ArrayList(usize).init(self.allocator);

        // header
        try writer.print("{s}", .{PDF_1_1_HEADER});
        byteCount += PDF_1_1_HEADER.len + 1;

        // objects
        for (self.objs.items) |obj| {
            objIndices.append(byteCount) catch {};
            const objBytes = std.fmt.allocPrint(self.allocator, "{f}", .{obj}) catch "";
            const objStr = std.fmt.allocPrint(self.allocator,
                \\{d} 0 obj
                \\{s}endobj
                \\
            , .{ obj.objNum(), objBytes }) catch "";
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
