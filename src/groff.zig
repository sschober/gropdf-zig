const std = @import("std");

const String = []const u8;
/// a glyph map maps indices corresponding to ascii codes to glyph widths. each
/// font has its separate map
pub const GlyphMap = [257]usize;
const Allocator = std.mem.Allocator;

/// groff out language elements - all single characters, some take
pub const Out = enum {
    /// device control command - see XSubCommand
    x,
    /// new page
    p,
    /// select font
    f,
    /// set font size
    s,
    /// set vertical position absolute
    V,
    /// set horizontal position absolute
    H,
    /// set horizontal position relative
    h,
    /// set vertical position relative
    v,
    /// set stroke color
    m,
    /// graphic copmmands
    D,
    /// type-set word
    t,
    /// inter-word whitespace
    w,
    /// type-set glyph/character
    C,
    /// next line
    n,
};

/// sub commands for x/device control commands
pub const XSubCommand = enum {
    /// typesetter control command - choses which type of output should be
    /// produced (ps, pdf, or latin1) - we only support `pdf` obviously
    T,
    /// resolution control command
    /// sample: x X res 72000 1 1
    res,
    /// init control command
    init,
    /// mount font at position
    font,
    /// escape control - side channel to us from groff, used to communicate
    /// meta data like papersize
    X,
    trailer,
    stop,
};

/// type for z-position of grout
pub const zPosition = struct {
    v: usize = 0,
    pub fn fromString(input: String) !zPosition {
        var result = zPosition{};
        if (input.len > 3 and input[input.len - 1] == 'z') {
            result.v = try std.fmt.parseUnsigned(usize, input[0 .. input.len - 1], 10);
        } else {
            result.v = try std.fmt.parseUnsigned(usize, input[0..], 10);
        }
        return result;
    }
};

/// custom error for groff path problems
const GroffPathError = error{FontNotFound} || Allocator.Error;

/// try to locate given font under a given set of search candidate paths
pub fn locateFont(gpa: Allocator, font_name: String) GroffPathError!String {
    const search_paths =
        [_]String{
            "/usr/share/groff/current", // standard unix and linux path
            "/usr/local/share/groff/current", // standard source install unix and linux path
            "/opt/homebrew/share/groff/current", // macos homebrew install path
        };
    var search_path: String = "";
    for (search_paths) |path| {
        const stat = std.fs.cwd().statFile(path) catch {
            continue;
        };
        switch (stat.kind) {
            .directory => {
                std.debug.print("found: {s}\n", .{path});
                search_path = path;
                break;
            },
            else => {},
        }
    }
    if (search_path.len > 0) {
        // TODO look if font is really there, not only dir
        return std.fmt.allocPrint(gpa, "{s}/font/devpdf/{s}", .{ search_path, font_name });
    }
    return GroffPathError.FontNotFound;
}
/// reads the groff font descriptor file as defined in `groff_font(5)`. parses
/// the charset section of that file to extract the width of each glyph. uses
/// the index column to store the width in an array.
pub fn readGlyphMap(gpa: Allocator, font_name: String) !GlyphMap {
    const groff_path = try locateFont(gpa, font_name);
    var font_desc_TR =
        try std.fs.openFileAbsolute(groff_path, .{ .mode = .read_only });
    defer font_desc_TR.close();
    var read_buf: [4096]u8 = undefined;
    var font_desc_TR_reader = font_desc_TR.reader(&read_buf);
    var font_desc_TR_reader_ifc = &font_desc_TR_reader.interface;
    var in_charset = false;
    var glyph_widths: [257]usize = undefined;
    @memset(&glyph_widths, 0);
    while (try font_desc_TR_reader_ifc.takeDelimiter('\n')) |line| {
        if (!in_charset) {
            if (std.mem.eql(u8, line, "charset")) {
                in_charset = true;
            }
            continue;
        }
        // we are in the charset section
        var it_glyph = std.mem.splitScalar(u8, line, '\t');
        _ = it_glyph.next().?;
        const metrics = it_glyph.next().?;
        if (std.mem.eql(u8, metrics, "\"")) {
            continue;
        }
        var it_metrics = std.mem.splitScalar(u8, metrics, ',');
        const glyph_width = it_metrics.next().?;
        const glyph_width_usize = try std.fmt.parseUnsigned(usize, glyph_width, 10);
        _ = it_glyph.next().?; //type
        const index = it_glyph.next().?;
        const index_usize = try std.fmt.parseUnsigned(usize, index, 10);
        _ = it_glyph.next().?;
        glyph_widths[index_usize] = glyph_width_usize;
    }
    return glyph_widths;
}
