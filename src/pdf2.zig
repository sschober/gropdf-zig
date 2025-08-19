const std = @import("std");
var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const String = []const u8;

pub const Pages = struct {
    objNum: usize,
    kids: std.ArrayList(*Page),

    pub fn init(n: usize) !*Pages {
        const result = try allocator.create(Pages);
        result.* = Pages{ .objNum = n, .kids = std.ArrayList(*Page).init(allocator) };
        return result;
    }

    pub fn write(self: Pages, writer: anytype) !void {
        try writer.print("<<\n/Type /Pages\n/Kids [", .{});
        for (self.kids.items) |kid| {
            try writer.print("{d} 0 R", .{kid.objNum});
        }
        try writer.print("]\n/Count {d}\n>>\n", .{self.kids.items.len});
    }

    fn addPage(self: *Pages, n: usize, c: usize, f: usize) !*Page {
        const res = try allocator.create(Page);
        res.* = Page.init(n, self.objNum, c, f);
        try self.kids.append(res);
        return res;
    }

    pub fn pdfObj(self: *Pages) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .pages = self };
        return res;
    }
};

pub const Stream = struct {
    objNum: usize,
    stream: String,
    pub fn init(n: usize, s: String) !*Stream {
        const res = try allocator.create(Stream);
        res.* = Stream{ .objNum = n, .stream = s };
        return res;
    }
    pub fn write(self: Stream, writer: anytype) !void {
        try writer.print("<<\n/Length {d}\n>>\nstream\n{s}\nendstream\n", .{ self.stream.len, self.stream });
    }
    pub fn pdfObj(self: *Stream) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .stream = self };
        return res;
    }
};

pub const Font = struct {
    objNum: usize,
    fontNum: usize,
    fontDef: String,
    pub fn init(n: usize, l: usize, f: String) !*Font {
        const res = try allocator.create(Font);
        res.* = Font{ .objNum = n, .fontNum = l, .fontDef = f };
        return res;
    }
    pub fn write(self: Font, writer: anytype) !void {
        try writer.print("<</Type Font\n/Font\n<</F{d}\n<<\n<<\n{s}\n>>\n>>\n>>\n", .{ self.fontNum, self.fontDef });
    }
    pub fn pdfObj(self: *Font) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .font = self };
        return res;
    }
};

pub const Page = struct {
    objNum: usize,
    parentNum: usize,
    contentsNum: usize,
    /// fonts are referenced as resources
    resourceNum: usize,
    pub fn init(n: usize, p: usize, c: usize, r: usize) Page {
        return Page{ .objNum = n, .parentNum = p, .contentsNum = c, .resourceNum = r };
    }
    pub fn write(self: Page, writer: anytype) !void {
        try writer.print("<<\n/Type /Page\n/Parent {d} 0 R\n/Contents {d} 0 R\n/MediaBox [0 0 612 792]\n/Resources {d} 0 R\n>>\n", .{ self.parentNum, self.contentsNum, self.resourceNum });
    }
    pub fn pdfObj(self: *Page) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .page = self };
        return res;
    }
};

const Catalog = struct {
    objNum: usize,
    pages: String,
    pub fn init(n: usize) !*Catalog {
        const res = try allocator.create(Catalog);
        res.* = Catalog{ .objNum = n, .pages = "1 0 R" };
        return res;
    }
    fn write(self: Catalog, writer: anytype) !void {
        try writer.print("<<\n/Type /Catalog\n/Pages {s}\n>>\n", .{self.pages});
    }
    pub fn pdfObj(self: *Catalog) !*Object {
        const res = try allocator.create(Object);
        res.* = Object{ .catalog = self };
        return res;
    }
};

/// interface of all pdf objects
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

const PDF_1_1_HEADER = "%PDF-1.1\n%abc\n";

pub const Document = struct {
    objs: std.ArrayList(*Object),
    fonts: std.ArrayList(*Font),
    pages: *Pages,
    catalog: *Catalog,

    fn addObj(self: *Document, obj: *Object) !usize {
        try self.objs.append(obj);
        return self.objs.items.len;
    }

    pub fn init() !Document {
        var self = Document{ .objs = std.ArrayList(*Object).init(allocator), .pages = try Pages.init(1), .catalog = try Catalog.init(2), .fonts = std.ArrayList(*Font).init((allocator)) };
        _ = try self.addObj(try self.pages.pdfObj());
        _ = try self.addObj(try self.catalog.pdfObj());
        return self;
    }

    pub fn addFont(self: *Document, f: String) !usize {
        const objIdx = self.objs.items.len + 1;
        const font = try allocator.create(Font);
        font.* = Font{ .objNum = objIdx, .fontNum = self.fonts.items.len, .fontDef = f };
        try self.fonts.append(font);
        _ = try self.addObj(try font.pdfObj());
        return objIdx;
    }

    pub fn addPage(self: *Document, f: usize, s: String) !*Page {
        const objIdx = self.objs.items.len + 1;
        const stream = try Stream.init(objIdx + 1, s);
        const page = try self.pages.addPage(objIdx, stream.objNum, f);
        _ = try self.addObj(try page.pdfObj());
        _ = try self.addObj(try stream.pdfObj());
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
            try writer.print("{d} 0 obj\n{s}endobj\n", .{ obj.objNum(), objBytes.items });
            byteCount += objBytes.items.len;
        }

        // xref table
        const startXRef = byteCount;
        try writer.print("xref\n0 {d}\n0000000000 65535 f\n", .{self.objs.items.len + 1});
        for (objIndices.items) |idx| {
            try writer.print("{d:0>10} 00000 n\n", .{idx});
        }

        // trailer
        try writer.print("trailer\n", .{});
        try writer.print("<<\n/Root {d} 0 R\n/Size {d}\n>>\n", .{ self.catalog.objNum, self.objs.items.len + 1 });
        try writer.print("startxref\n{d}\n", .{startXRef});
    }
};
