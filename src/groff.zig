const std = @import("std");
const log = @import("log.zig");
const common = @import("common.zig");
pub const Type1FontData = common.Type1FontData;

const String = common.String;
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
    /// type-set word with track kerning
    u,
    /// inter-word whitespace
    w,
    /// type-set glyph/character
    C,
    /// next line
    n,
};
/// select stroke color
pub const MSubCommand = enum {
    /// use default color
    d,
    /// use color R G B
    r,
};
/// drawing sub commands
pub const DSubCommand = enum {
    /// thickness
    t,
    /// line to
    l,
    Fd,
    Fr,
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
        if (input.len >= 2 and input[input.len - 1] == 'z') {
            result.v = try std.fmt.parseUnsigned(usize, input[0 .. input.len - 1], 10);
        } else {
            result.v = try std.fmt.parseUnsigned(usize, input[0..], 10);
        }
        return result;
    }
};

pub const RgbColorMax = 65535;
pub const RgbColor = struct {
    r: usize = 0, //
    g: usize = 0,
    b: usize = 0,
    pub fn from_string(s: String) !RgbColor {
        var it = std.mem.splitScalar(u8, s, ' ');
        return RgbColor.from_iterator(&it);
    }
    pub fn from_iterator(it: *common.U8SplitIterator) !RgbColor {
        return RgbColor.from_strings(it.next().?, it.next().?, it.next().?);
    }
    pub fn from_strings(r: String, g: String, b: String) !RgbColor {
        return RgbColor{
            .r = try std.fmt.parseUnsigned(usize, r, 10),
            .g = try std.fmt.parseUnsigned(usize, g, 10),
            .b = try std.fmt.parseUnsigned(usize, b, 10),
        };
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
                log.dbg("groff: found {s}\n", .{path});
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

/// groff_out(5) font reference
/// sample: TR 5
pub const FontRef = struct {
    name: String,
    idx: usize,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("grout.FontRef: {s} {d}", .{ self.name, self.idx });
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// Type1 font embedding support
// ──────────────────────────────────────────────────────────────────────────────

/// Candidate font file names (no path) for a groff font name, in priority order.
/// Derived from the groff devpdf/Foundry file.
fn getFontFileCandidates(groff_name: String) []const String {
    // zig fmt: off
    if (std.mem.eql(u8, groff_name, "TR"))  return &.{ "NimbusRoman-Regular",      "NimbusRomNo9L-Regu",     "n021003l.pfb" };
    if (std.mem.eql(u8, groff_name, "TB"))  return &.{ "NimbusRoman-Bold",          "NimbusRomNo9L-Medi",     "n021004l.pfb" };
    if (std.mem.eql(u8, groff_name, "TI"))  return &.{ "NimbusRoman-Italic",        "NimbusRomNo9L-ReguItal", "n021023l.pfb" };
    if (std.mem.eql(u8, groff_name, "TBI")) return &.{ "NimbusRoman-BoldItalic",    "NimbusRomNo9L-MediItal", "n021024l.pfb" };
    if (std.mem.eql(u8, groff_name, "HR") or
        std.mem.eql(u8, groff_name, "H"))   return &.{ "NimbusSans-Regular",        "NimbusSanL-Regu",        "n019003l.pfb" };
    if (std.mem.eql(u8, groff_name, "HB"))  return &.{ "NimbusSans-Bold",           "NimbusSanL-Bold",        "n019004l.pfb" };
    if (std.mem.eql(u8, groff_name, "HI"))  return &.{ "NimbusSans-Italic",         "NimbusSans-Oblique",     "NimbusSanL-ReguItal", "n019023l.pfb" };
    if (std.mem.eql(u8, groff_name, "HBI")) return &.{ "NimbusSans-BoldItalic",     "NimbusSans-BoldOblique", "NimbusSanL-BoldItal", "n019024l.pfb" };
    if (std.mem.eql(u8, groff_name, "CR"))  return &.{ "NimbusMonoPS-Regular",      "NimbusMonL-Regu",        "n022003l.pfb" };
    if (std.mem.eql(u8, groff_name, "CB"))  return &.{ "NimbusMonoPS-Bold",         "NimbusMonL-Bold",        "n022004l.pfb" };
    if (std.mem.eql(u8, groff_name, "CI"))  return &.{ "NimbusMonoPS-Italic",       "NimbusMonL-ReguObli",    "n022023l.pfb" };
    if (std.mem.eql(u8, groff_name, "CBI")) return &.{ "NimbusMonoPS-BoldItalic",   "NimbusMonL-BoldObli",    "n022024l.pfb" };
    if (std.mem.eql(u8, groff_name, "S"))   return &.{ "StandardSymbolsPS",         "StandardSymL",           "s050000l.pfb" };
    if (std.mem.eql(u8, groff_name, "ZD"))  return &.{ "D050000L",                  "Dingbats",               "d050000l.pfb" };
    // zig fmt: on
    return &.{};
}

/// Directories to search for Type1 font files, in priority order.
/// Tries versioned ghostscript installs via iteration, then static fallbacks.
fn buildFontSearchDirs(gpa: Allocator) !std.array_list.Managed(String) {
    var dirs = std.array_list.Managed(String).init(gpa);

    // Versioned ghostscript installs: try to find "Resource/Font" under any
    // version sub-directory of known base paths.
    const gs_bases = [_]String{
        "/opt/homebrew/share/ghostscript",
        "/usr/local/share/ghostscript",
        "/usr/share/ghostscript",
    };
    for (gs_bases) |base| {
        var base_dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch continue;
        defer base_dir.close();
        var it = base_dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const candidate = try std.fmt.allocPrint(gpa, "{s}/{s}/Resource/Font", .{ base, entry.name });
            std.fs.accessAbsolute(candidate, .{}) catch {
                gpa.free(candidate);
                continue;
            };
            try dirs.append(candidate);
        }
        // Also try base/Resource/Font (some installs omit the version dir)
        const no_ver = try std.fmt.allocPrint(gpa, "{s}/Resource/Font", .{base});
        std.fs.accessAbsolute(no_ver, .{}) catch {
            gpa.free(no_ver);
            continue;
        };
        try dirs.append(no_ver);
    }

    // Static fallbacks for system font locations
    for ([_]String{
        "/usr/share/fonts/type1/gsfonts",
        "/usr/share/fonts/default/Type1",
        "/usr/local/share/fonts/ghostscript",
    }) |p| {
        try dirs.append(p);
    }

    return dirs;
}

/// Parse a Type1 PFA font file (binary or hex eexec) into a `Type1FontData`.
/// Determines Length1/Length2/Length3 split and extracts font metadata from
/// the clear-text header.
fn parseType1FontData(gpa: Allocator, data: []const u8) !Type1FontData {
    // ── Length1: clear-text up to and including the newline after "currentfile eexec" ──
    const eexec_marker = "currentfile eexec";
    const eexec_idx = std.mem.indexOf(u8, data, eexec_marker) orelse return error.InvalidType1Font;
    const nl_idx = std.mem.indexOfPos(u8, data, eexec_idx + eexec_marker.len, "\n") orelse return error.InvalidType1Font;
    const length1 = nl_idx + 1;

    // ── Length3: zeros+cleartomark trailer at the very end ──
    const cm_marker = "cleartomark";
    const cm_idx = std.mem.lastIndexOf(u8, data, cm_marker) orelse return error.InvalidType1Font;
    // Walk backwards from cleartomark over '0', '\r', '\n' to find where the
    // zero-padding section begins.
    var zero_start: usize = cm_idx;
    var i: usize = cm_idx;
    while (i > length1) {
        i -= 1;
        const c = data[i];
        if (c == '0' or c == '\n' or c == '\r') {
            zero_start = i;
        } else {
            break;
        }
    }
    const length3 = data.len - zero_start;
    const length2 = data.len - length1 - length3;

    // ── Metadata from the clear-text header ──
    const header = data[0..length1];

    const font_name: String = blk: {
        const marker = "/FontName /";
        if (std.mem.indexOf(u8, header, marker)) |idx| {
            const start = idx + marker.len;
            const len = std.mem.indexOfAny(u8, header[start..], " \n\r\t") orelse break :blk "Unknown";
            break :blk try gpa.dupe(u8, header[start .. start + len]);
        }
        break :blk "Unknown";
    };

    const font_bbox: [4]i64 = blk: {
        const marker = "/FontBBox {";
        if (std.mem.indexOf(u8, header, marker)) |idx| {
            const start = idx + marker.len;
            const end = std.mem.indexOf(u8, header[start..], "}") orelse break :blk .{ 0, -200, 1000, 900 };
            var it2 = std.mem.tokenizeScalar(u8, header[start .. start + end], ' ');
            var bbox: [4]i64 = undefined;
            var n: usize = 0;
            while (it2.next()) |s| {
                if (n >= 4) break;
                bbox[n] = std.fmt.parseInt(i64, s, 10) catch break :blk .{ 0, -200, 1000, 900 };
                n += 1;
            }
            if (n == 4) break :blk bbox;
        }
        break :blk .{ 0, -200, 1000, 900 };
    };

    const italic_angle: i64 = blk: {
        const marker = "/ItalicAngle ";
        if (std.mem.indexOf(u8, header, marker)) |idx| {
            const start = idx + marker.len;
            const len = std.mem.indexOfAny(u8, header[start..], " \n\r\t") orelse break :blk 0;
            const s = header[start .. start + len];
            // Value is a float like "0.0" or "-12.0"; take the integer part.
            const dot = std.mem.indexOf(u8, s, ".");
            const int_str = if (dot) |d| s[0..d] else s;
            break :blk std.fmt.parseInt(i64, int_str, 10) catch 0;
        }
        break :blk 0;
    };

    const is_fixed = std.mem.indexOf(u8, header, "/isFixedPitch true") != null;
    const is_italic = @abs(italic_angle) > 5;
    // PDF font flags: bit 1=FixedPitch, bit 2=Serif, bit 6=NonSymbolic, bit 7=Italic
    var flags: u32 = 32; // NonSymbolic baseline
    if (is_fixed) flags |= 1;
    if (!is_fixed and !is_italic) flags |= 2; // Serif for upright proportional fonts
    if (is_italic) flags |= 64;

    return Type1FontData{
        .data = data,
        .length1 = length1,
        .length2 = length2,
        .length3 = length3,
        .font_name = font_name,
        .font_bbox = font_bbox,
        .italic_angle = italic_angle,
        .flags = flags,
    };
}

/// Try to find, read, and parse a Type1 font for the given groff font name.
/// Returns `null` if no font file is found in the search paths.
pub fn findAndLoadFont(gpa: Allocator, groff_name: String) !?Type1FontData {
    const candidates = getFontFileCandidates(groff_name);
    if (candidates.len == 0) return null;

    const search_dirs = try buildFontSearchDirs(gpa);

    for (search_dirs.items) |dir| {
        for (candidates) |name| {
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
            const data = std.fs.cwd().readFileAlloc(gpa, path, 20 * 1024 * 1024) catch {
                gpa.free(path);
                continue;
            };
            gpa.free(path);
            return parseType1FontData(gpa, data) catch |err| {
                log.warn("warning: could not parse Type1 font {s}: {}\n", .{ name, err });
                continue;
            };
        }
    }
    return null;
}
