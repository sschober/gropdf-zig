//! PDF object model and functions
//!
//! implements PDF version 1.1 as defined increase
//! [Adobe PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf#page412)
//! (pdfref17)
const std = @import("std");
const FixPoint = @import("FixPoint.zig");
const log = @import("log.zig");
const common = @import("common.zig");
const zlib = @cImport(@cInclude("zlib.h"));

/// alias to shorten usages below
const Allocator = std.mem.Allocator;
const String = []const u8;
const ArrayList = std.array_list.Managed;

/// Compress `data` with zlib (FlateDecode) using system libz.
fn zlibCompress(allocator: Allocator, data: []const u8) ![]u8 {
    const bound = zlib.compressBound(@intCast(data.len));
    const buf = try allocator.alloc(u8, @intCast(bound));
    errdefer allocator.free(buf);
    var dest_len: zlib.uLongf = @intCast(bound);
    const ret = zlib.compress2(buf.ptr, &dest_len, data.ptr, @intCast(data.len), 6);
    if (ret != zlib.Z_OK) return error.CompressionFailed;
    return allocator.realloc(buf, @intCast(dest_len));
}

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
            .Times_Bold_Italic => return "/BaseFont /Times-BoldItalic\n/Subtype /Type1",
            .Helvetica => return "/BaseFont /Helvetica\n/Subtype /Type1",
            .Helvetica_Bold => return "/BaseFont /Helvetica-Bold\n/Subtype /Type1",
            .Helvetica_Oblique => return "/BaseFont /Helvetica-Oblique\n/Subtype /Type1",
            .Helvetica_Bold_Oblique => return "/BaseFont /Helvetica-BoldOblique\n/Subtype /Type1",
            .Courier => return "/BaseFont /Courier\n/Subtype /Type1",
            .Courier_Bold => return "/BaseFont /Courier-Bold\n/Subtype /Type1",
            .Courier_Olbique => return "/BaseFont /Courier-Oblique\n/Subtype /Type1",
            .Courier_Bold_Oblique => return "/BaseFont /Courier-BoldOblique\n/Subtype /Type1",
            .Symbol => return "/BaseFont /Symbol\n/Subtype /Type1",
            .Zapf_Dingbats => return "/BaseFont /ZapfDingbats\n/Subtype /Type1",
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
    /// draw a filled polygon/path - uses 'f' operator to fill
    pub fn fillPath(self: *GraphicalObject, points: []const FixPoint) !void {
        try self.newLine();
        if (points.len >= 2) {
            var path = ArrayList(u8).init(self.allocator);
            // Move to first point (current position)
            try path.writer().print("{f} {f} m", .{ self.cur_x, self.cur_y });
            var cur_x = self.cur_x;
            var cur_y = self.cur_y;
            var i: usize = 0;
            while (i + 1 < points.len) : (i += 2) {
                cur_x = cur_x.addTo(points[i]);
                cur_y = cur_y.addTo(points[i + 1]);
                try path.writer().print(" {f} {f} l", .{ cur_x, cur_y });
            }
            try path.writer().print(" f", .{});
            try self.lines.append(path.items);
        }
    }
    /// set fill color for graphical objects (non-stroking color in RGB)
    pub fn setFillColor(self: *GraphicalObject, c: RgbColor) !void {
        try self.newLine();
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "{f} rg", .{c}));
    }
    /// set fill color to default (black)
    pub fn setFillColorBlack(self: *GraphicalObject) !void {
        try self.newLine();
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "0.0 g", .{}));
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

/// pdf RGB color - each dimension is a value from 0 to 1
pub const RgbColor = struct {
    r: FixPoint = FixPoint{},
    g: FixPoint = FixPoint{},
    b: FixPoint = FixPoint{},
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f} {f} {f}", .{ self.r, self.g, self.b });
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
    pub fn setFillColorBlack(self: *TextObject) !void {
        try self.newLine();
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "0.0 g", .{}));
    }
    pub fn setFillColor(self: *TextObject, c: RgbColor) !void {
        try self.newLine();
        try self.lines.append(try std.fmt.allocPrint(self.allocator, "{f} rg", .{c}));
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
    /// increment y position by v, flush current line and init a new one note
    /// the PDF's y axis starts at the lower left corner of the page, so we
    /// need to subtract v from the current position.
    pub fn addF(self: *TextObject, v: FixPoint) !void {
        self.f = self.f.sub(v);
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
    ) (std.Io.Writer.Error || error{ OutOfMemory, CompressionFailed })!void {
        // pre-render content, then compress
        const plain = try std.fmt.allocPrint(self.allocator,
            "{f}\n{f}", .{ self.graphicalObject, self.textObject });
        defer self.allocator.free(plain);
        const compressed = try zlibCompress(self.allocator, plain);
        defer self.allocator.free(compressed);
        try writer.print(
            \\<<
            \\/Filter /FlateDecode
            \\/Length {d}
            \\>>
            \\stream
            \\
        , .{compressed.len});
        try writer.writeAll(compressed);
        try writer.print(
            \\
            \\endstream
            \\
        , .{});
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
    /// when set, a /FontDescriptor entry is added pointing to an embedded font descriptor
    font_descriptor_obj_num: ?usize = null,
    pub fn init(allocator: Allocator, n: usize, l: usize, f: String) !*Font {
        const res = try allocator.create(Font);
        res.* = Font{ .allocator = allocator, .objNum = n, .fontNum = l, .fontDef = f };
        return res;
    }
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("<<\n/Type /Font\n{s}\n", .{self.fontDef});
        if (self.font_descriptor_obj_num) |desc_num| {
            try writer.print("/FontDescriptor {d} 0 R\n", .{desc_num});
        }
        try writer.print(">>\n", .{});
    }
    pub fn pdfObj(self: *Font) !*Object {
        const res = try self.allocator.create(Object);
        res.* = Object{ .font = self };
        return res;
    }
};

/// Holds the raw bytes of an embedded Type1 font program as a PDF stream object.
pub const FontFileStream = struct {
    allocator: Allocator,
    objNum: usize,
    data: []const u8,
    length1: usize,
    length2: usize,
    length3: usize,

    pub fn init(allocator: Allocator, n: usize, font_data: common.Type1FontData) !*FontFileStream {
        const res = try allocator.create(FontFileStream);
        res.* = .{
            .allocator = allocator,
            .objNum = n,
            .data = font_data.data,
            .length1 = font_data.length1,
            .length2 = font_data.length2,
            .length3 = font_data.length3,
        };
        return res;
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) (std.Io.Writer.Error || error{ OutOfMemory, CompressionFailed })!void {
        const compressed = try zlibCompress(self.allocator, self.data);
        defer self.allocator.free(compressed);
        try writer.print(
            "<<\n/Filter /FlateDecode\n/Length {d}\n/Length1 {d}\n/Length2 {d}\n/Length3 {d}\n>>\nstream\n",
            .{ compressed.len, self.length1, self.length2, self.length3 },
        );
        try writer.writeAll(compressed);
        try writer.print("\nendstream\n", .{});
    }

    pub fn pdfObj(self: *FontFileStream) !*Object {
        const res = try self.allocator.create(Object);
        res.* = Object{ .font_file_stream = self };
        return res;
    }
};

/// PDF FontDescriptor object — font metrics and reference to the embedded font file.
pub const FontDescriptor = struct {
    allocator: Allocator,
    objNum: usize,
    font_name: String,
    font_bbox: [4]i64,
    flags: u32,
    italic_angle: i64,
    ascent: i64,
    descent: i64,
    cap_height: i64,
    stem_v: i64,
    font_file_obj_num: usize,

    pub fn init(allocator: Allocator, n: usize, font_data: common.Type1FontData, ff_obj_num: usize) !*FontDescriptor {
        const res = try allocator.create(FontDescriptor);
        const bbox = font_data.font_bbox;
        res.* = .{
            .allocator = allocator,
            .objNum = n,
            .font_name = font_data.font_name,
            .font_bbox = bbox,
            .flags = font_data.flags,
            .italic_angle = font_data.italic_angle,
            .ascent = if (bbox[3] > 0) bbox[3] else 700,
            .descent = if (bbox[1] < 0) bbox[1] else -200,
            .cap_height = if (bbox[3] > 0) @divTrunc(bbox[3] * 7, 10) else 680,
            .stem_v = if (font_data.flags & 1 != 0) 100 else 80, // heavier stem for monospace
            .font_file_obj_num = ff_obj_num,
        };
        return res;
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            \\<<
            \\/Type /FontDescriptor
            \\/FontName /{s}
            \\/Flags {d}
            \\/FontBBox [{d} {d} {d} {d}]
            \\/ItalicAngle {d}
            \\/Ascent {d}
            \\/Descent {d}
            \\/CapHeight {d}
            \\/StemV {d}
            \\/FontFile {d} 0 R
            \\>>
            \\
        , .{
            self.font_name,
            self.flags,
            self.font_bbox[0], self.font_bbox[1], self.font_bbox[2], self.font_bbox[3],
            self.italic_angle,
            self.ascent,
            self.descent,
            self.cap_height,
            self.stem_v,
            self.font_file_obj_num,
        });
    }

    pub fn pdfObj(self: *FontDescriptor) !*Object {
        const res = try self.allocator.create(Object);
        res.* = Object{ .font_descriptor = self };
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
    ) (std.Io.Writer.Error || error{ OutOfMemory, CompressionFailed })!void {
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
    font_file_stream: *FontFileStream,
    font_descriptor: *FontDescriptor,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) (std.Io.Writer.Error || error{ OutOfMemory, CompressionFailed })!void {
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
    /// parallel to fonts; non-null only for embedded fonts
    font_file_streams: ArrayList(?*FontFileStream),
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
            .fonts = ArrayList(*Font).init(allocator),
            .font_file_streams = ArrayList(?*FontFileStream).init(allocator),
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

    /// Embed a Type1 font program in the document.
    /// Creates FontFileStream + FontDescriptor + Font objects and wires them together.
    pub fn addEmbeddedFont(self: *Document, font_data: common.Type1FontData) !FontRef {
        // 1. Font file stream (raw Type1 bytes)
        const ff_obj_num = self.objs.items.len + 1;
        const ff = try FontFileStream.init(self.allocator, ff_obj_num, font_data);
        try self.addObj(try ff.pdfObj());

        // 2. Font descriptor (metrics + reference to font file stream)
        const fd_obj_num = self.objs.items.len + 1;
        const fd = try FontDescriptor.init(self.allocator, fd_obj_num, font_data, ff_obj_num);
        try self.addObj(try fd.pdfObj());

        // 3. Font dictionary using StandardEncoding as base, matching the byte
        // values in Transpiler's glyph_map (fi=174, fl=175, quoteleft=96, etc.
        // are all StandardEncoding positions). The only /Differences needed are
        // for em-dash (151) and en-dash (150), whose groff byte values come from
        // Windows-1252 but whose glyph names exist in all Type1 fonts.
        const font_def = try std.fmt.allocPrint(
            self.allocator,
            "/BaseFont /{s}\n/Subtype /Type1\n/Encoding << /Type /Encoding /BaseEncoding /StandardEncoding /Differences [150 /endash /emdash] >>",
            .{font_data.font_name},
        );
        const font_obj_num = self.objs.items.len + 1;
        const fontNum = self.fonts.items.len;
        const font = try Font.init(self.allocator, font_obj_num, fontNum, font_def);
        font.font_descriptor_obj_num = fd_obj_num;
        try self.addObj(try font.pdfObj());
        try self.fonts.append(font);
        try self.font_file_streams.append(ff);

        const result = FontRef{ .idx = fontNum };
        log.dbg("pdf: embedded font {s} as {f} (ff={d} fd={d} font={d})\n", .{
            font_data.font_name, result, ff_obj_num, fd_obj_num, font_obj_num,
        });
        return result;
    }

    /// add a font to the document by specifing its name returns the index of
    /// the font into our internal font list
    pub fn addFont(self: *Document, f: String) !FontRef {
        const objIdx = self.objs.items.len + 1;
        const fontNum = self.fonts.items.len;
        const font = try Font.init(self.allocator, objIdx, self.fonts.items.len, f);
        try self.addObj(try font.pdfObj());
        try self.fonts.append(font);
        try self.font_file_streams.append(null);
        const result = FontRef{ .idx = fontNum };
        log.dbg("pdf: added font as {f} with idx {d}:\n{s}\n", .{ result, objIdx, f });
        return result;
    }

    /// Returns the FontFileStream for an embedded font, or null for standard fonts.
    pub fn getFontFileStream(self: *Document, font_idx: usize) ?*FontFileStream {
        if (font_idx >= self.font_file_streams.items.len) return null;
        return self.font_file_streams.items[font_idx];
    }

    /// once a font was added to the document, use this to add a reference to a page
    pub fn addFontRefTo(self: *Document, page: *Page, doc_font_ref: Document.FontRef) !Page.FontRef {
        const font = self.fonts.items[doc_font_ref.idx];
        // Search for the font already registered on this page by object number.
        for (page.resources.items, 0..) |objNum, i| {
            if (objNum == font.objNum) {
                log.dbg("pdf: assuming already seen {f}. not adding to page {d}...\n", .{ doc_font_ref, page.objNum });
                return Page.FontRef{ .idx = i };
            }
        }
        // Not found on this page — register it.
        log.dbg("pdf: adding {f} as obj num {d} to page {d}\n", .{ doc_font_ref, font.objNum, page.objNum });
        try page.resources.append(font.objNum);
        return Page.FontRef{ .idx = page.resources.items.len - 1 };
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

    /// renders the pdf document to the given writer
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) (std.Io.Writer.Error || error{ OutOfMemory, CompressionFailed })!void {
        var byteCount: usize = 0;
        var objIndices = ArrayList(usize).init(self.allocator);

        // header
        try writer.print("{s}", .{PDF_1_1_HEADER});
        byteCount += PDF_1_1_HEADER.len;

        // objects
        for (self.objs.items) |obj| {
            try objIndices.append(byteCount);
            var aw = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
            defer aw.deinit();
            try obj.format(&aw.writer);
            const objBytes = try aw.toOwnedSlice();
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

const expect = std.testing.expect;

test "xref offsets match actual object positions" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var doc = try Document.init(allocator);

    // format the document into a buffer
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try doc.format(&writer);
    try writer.flush();
    const output = buf[0..writer.end];

    // find the xref table
    const xref_pos = std.mem.indexOf(u8, output, "xref\n") orelse return error.XrefNotFound;

    // parse object count from "0 <count>\n"
    const count_line_start = xref_pos + "xref\n".len;
    const count_line_end = std.mem.indexOfPos(u8, output, count_line_start, "\n") orelse return error.ParseError;
    const count_line = output[count_line_start..count_line_end];

    // parse "0 <n>" to get n
    var it = std.mem.splitScalar(u8, count_line, ' ');
    _ = it.next(); // skip "0"
    const n = try std.fmt.parseInt(usize, it.next() orelse return error.ParseError, 10);

    // skip the free entry, then check each "in use" entry
    var pos = count_line_end + 1; // after count line
    pos = (std.mem.indexOfPos(u8, output, pos, "\n") orelse return error.ParseError) + 1; // skip free entry

    // verify each xref offset points to "<objnum> 0 obj\n"
    for (1..n) |obj_idx| {
        const line_end = std.mem.indexOfPos(u8, output, pos, "\n") orelse return error.ParseError;
        const offset = try std.fmt.parseInt(usize, output[pos .. pos + 10], 10);

        const expected_prefix = try std.fmt.allocPrint(
            allocator,
            "{d} 0 obj\n",
            .{obj_idx},
        );

        const actual = output[offset..@min(offset + expected_prefix.len, output.len)];
        try expect(std.mem.eql(u8, actual, expected_prefix));

        pos = line_end + 1; // next entry
    }
}
