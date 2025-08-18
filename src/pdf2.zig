const std = @import("std");
var gpa = std.heap.DebugAllocator(.{}){};
const allocator = gpa.allocator();

const String = []const u8;

pub const Pdf2Pages = struct {
    objNum: usize,
    kids: std.ArrayList(*Pdf2Page),

    pub fn init(n: usize) !*Pdf2Pages {
        const result = try allocator.create(Pdf2Pages);
        result.* = Pdf2Pages{ .objNum = n, .kids = std.ArrayList(*Pdf2Page).init(allocator) };
        return result;
    }

    pub fn print(self: Pdf2Pages) !String {
        var result = std.ArrayList(u8).init(allocator);
        var writer = result.writer();
        try writer.print("/Type /Pages\n/Kids [", .{});
        for (self.kids.items) |kid| {
            try writer.print("{d} 0 R", .{kid.objNum});
        }
        try writer.print("]\n/Count {d}\n", .{self.kids.items.len});
        return result.items;
    }

    fn addPage(self: *Pdf2Pages, n: usize, s: String) !*Pdf2Page {
        const res = try allocator.create(Pdf2Page);
        res.* = Pdf2Page.init(n, s);
        try self.kids.append(res);
        return res;
    }

    pub fn pdfObj(self: *Pdf2Pages) !*Pdf2Object {
        const res = try allocator.create(Pdf2Object);
        res.* = Pdf2Object{ .pages = self };
        return res;
    }
};

pub const Pdf2Page = struct {
    objNum: usize,
    resource: String,
    pub fn init(n: usize, s: String) Pdf2Page {
        return Pdf2Page{ .objNum = n, .resource = s };
    }
    pub fn print(self: Pdf2Page) !String {
        var result = std.ArrayList(u8).init(allocator);
        var writer = result.writer();
        try writer.print("/Type /Page\n{s}\n", .{self.resource});
        return result.items;
    }
    pub fn pdfObj(self: *Pdf2Page) !*Pdf2Object {
        const res = try allocator.create(Pdf2Object);
        res.* = Pdf2Object{ .page = self };
        return res;
    }
};

/// interface of all pdf objects
pub const Pdf2Object = union(enum) {
    pages: *Pdf2Pages,
    page: *Pdf2Page,
    catalog: *Catalog,

    pub fn print(self: Pdf2Object) !String {
        switch (self) {
            inline else => |impl| return impl.print(),
        }
    }
    pub fn objNum(self: Pdf2Object) usize {
        switch (self) {
            .pages => |pages| return pages.objNum,
            .page => |page| return page.objNum,
            .catalog => |catalog| return catalog.objNum,
        }
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
    fn print(self: Catalog) !String {
        var result = std.ArrayList(u8).init(allocator);
        var writer = result.writer();
        try writer.print("/Type /Catalog\n/Pages {s}\n", .{self.pages});
        return result.items;
    }
    pub fn pdfObj(self: *Catalog) !*Pdf2Object {
        const res = try allocator.create(Pdf2Object);
        res.* = Pdf2Object{ .catalog = self };
        return res;
    }
};

const PDF_1_1_HEADER = "%PDF-1.1\n%abc\n";

pub const Pdf2Document = struct {
    objs: std.ArrayList(*Pdf2Object),
    pages: *Pdf2Pages,
    catalog: *Catalog,

    fn addObj(self: *Pdf2Document, obj: *Pdf2Object) !usize {
        try self.objs.append(obj);
        return self.objs.items.len;
    }

    pub fn init() !Pdf2Document {
        var self = Pdf2Document{ .objs = std.ArrayList(*Pdf2Object).init(allocator), .pages = try Pdf2Pages.init(1), .catalog = try Catalog.init(2) };
        _ = try self.addObj(try self.pages.pdfObj());
        _ = try self.addObj(try self.catalog.pdfObj());
        return self;
    }

    pub fn addPage(self: *Pdf2Document, s: String) !*Pdf2Page {
        const objIdx = self.objs.items.len + 1;
        const page = try self.pages.addPage(objIdx, s);
        _ = try self.addObj(try page.pdfObj());
        return page;
    }

    pub fn print(self: Pdf2Document, writer: anytype) !void {
        var byteCount: usize = 0;
        var objIndices = std.ArrayList(usize).init(allocator);
        // header
        try writer.print("{s}", .{PDF_1_1_HEADER});
        byteCount += PDF_1_1_HEADER.len + 1;
        // objects
        for (self.objs.items) |obj| {
            try objIndices.append(byteCount);
            const objStr = try obj.print();
            try writer.print("{d} 0 obj\n{s}endobj\n", .{ obj.objNum(), objStr });
            byteCount += objStr.len;
        }
        const startXRef = byteCount;
        // xref table
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
