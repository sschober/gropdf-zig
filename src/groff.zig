const std = @import("std");
const log = @import("log.zig");
const common = @import("common.zig");
pub const Type1FontData = common.Type1FontData;

const String = common.String;
/// a glyph map maps indices corresponding to ascii codes to glyph widths. each
/// font has its separate map
pub const GlyphMap = [257]usize;
/// maps glyph names (e.g. "fi", "~A") to their byte code (0-255),
/// built from the charset section of a groff font descriptor file.
pub const GlyphNameMap = std.StringHashMap(u8);
/// maps groff glyph names to their PostScript names for code > 255 glyphs
/// (i.e. glyphs that have no natural byte slot and need dynamic assignment).
pub const HighGlyphMap = std.StringHashMap([]const u8);
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

/// try to locate given font under a given set of search candidate paths.
/// Searches site-font dirs (for user-installed fonts) before the standard
/// groff installation dirs.
pub fn locateFont(gpa: Allocator, font_name: String) GroffPathError!String {
    // Candidate base directories, searched in priority order.
    // site-font comes first so user-installed fonts override built-ins.
    const search_bases =
        [_]String{
            "/opt/homebrew/etc/groff/site-font", // homebrew site-font (user-installed)
            "/usr/local/etc/groff/site-font", // source-install site-font
            "/etc/groff/site-font", // system-wide site-font on linux
            "/usr/share/groff/current/font", // standard unix/linux
            "/usr/local/share/groff/current/font", // source-install
            "/opt/homebrew/share/groff/current/font", // macos homebrew
        };
    for (search_bases) |base| {
        const path = try std.fmt.allocPrint(gpa, "{s}/devpdf/{s}", .{ base, font_name });
        std.fs.accessAbsolute(path, .{}) catch {
            gpa.free(path);
            continue;
        };
        log.dbg("groff: located font {s} at {s}\n", .{ font_name, path });
        return path;
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
        // Code -1 means the glyph has no byte code; skip it
        const index_usize = std.fmt.parseUnsigned(usize, index, 10) catch continue;
        _ = it_glyph.next().?;
        if (index_usize < glyph_widths.len) {
            glyph_widths[index_usize] = glyph_width_usize;
        }
    }
    return glyph_widths;
}

/// Parsed entry from a groff font descriptor charset line.
const CharsetEntry = struct { code: u8, groff_name: String, ps_name: String };

/// Parse one charset line into a CharsetEntry. Returns null for lines with
/// code -1, code > 255, or that cannot be parsed.
fn parseCharsetLine(line: String) ?CharsetEntry {
    var it = std.mem.splitScalar(u8, line, '\t');
    const groff_name = it.next() orelse return null;
    _ = it.next() orelse return null; // metrics (may be `"`)
    _ = it.next() orelse return null; // type
    const code_str = it.next() orelse return null;
    const ps_name_raw = it.next() orelse return null;
    const ps_name = std.mem.trim(u8, ps_name_raw, " \t\r");
    const code_usize = std.fmt.parseUnsigned(usize, code_str, 10) catch return null;
    if (code_usize > 255) return null;
    return .{ .code = @intCast(code_usize), .groff_name = groff_name, .ps_name = ps_name };
}

/// reads the groff font descriptor file and builds a map from glyph name to
/// byte code. only entries with code in 0..255 are included. entries with
/// code -1 or code > 255 are skipped. the caller owns the returned map and
/// all keys (which are duped into gpa).
pub fn readGlyphNameMap(gpa: Allocator, font_name: String) !GlyphNameMap {
    const groff_path = try locateFont(gpa, font_name);
    defer gpa.free(groff_path);
    var file = try std.fs.openFileAbsolute(groff_path, .{ .mode = .read_only });
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(&read_buf);
    var ifc = &reader.interface;
    var in_charset = false;
    var map = GlyphNameMap.init(gpa);
    while (try ifc.takeDelimiter('\n')) |line| {
        if (!in_charset) {
            if (std.mem.eql(u8, line, "charset")) in_charset = true;
            continue;
        }
        const entry = parseCharsetLine(line) orelse continue;
        const key = try gpa.dupe(u8, entry.groff_name);
        try map.put(key, entry.code);
    }
    return map;
}

/// Combined result of one descriptor read: encoding + name map for code ≤ 255
/// glyphs, plus a high_glyphs map for code > 255 glyphs that need dynamic slot
/// assignment via overflow re-encodings.
pub const FontMaps = struct {
    encoding: FontEncoding,
    name_map: GlyphNameMap,
    /// groff_name → ps_name for code > 255 glyphs (excluding unicode-escape and
    /// math-symbol names).  Used to populate overflow re-encodings on demand.
    high_glyphs: HighGlyphMap,
};

/// Build the per-font encoding (code ≤ 255 glyphs) and the glyph name map from
/// a single read of the groff font descriptor. Code > 255 glyphs are collected
/// into `high_glyphs` for on-demand assignment to overflow re-encodings.
///
/// Caller owns encoding (free with freeFontEncoding), name_map, and high_glyphs.
pub fn buildFontMaps(gpa: Allocator, font_name: String) !FontMaps {
    const groff_path = try locateFont(gpa, font_name);
    defer gpa.free(groff_path);
    var file = try std.fs.openFileAbsolute(groff_path, .{ .mode = .read_only });
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(&read_buf);
    var ifc = &reader.interface;
    var in_charset = false;
    var enc: FontEncoding = .{null} ** 256;
    var name_map = GlyphNameMap.init(gpa);
    var high_glyphs = HighGlyphMap.init(gpa);
    while (try ifc.takeDelimiter('\n')) |line| {
        if (!in_charset) {
            if (std.mem.eql(u8, line, "charset")) in_charset = true;
            continue;
        }
        var it = std.mem.splitScalar(u8, line, '\t');
        const groff_name = it.next() orelse continue;
        if (std.mem.eql(u8, groff_name, "---")) continue;
        const metrics = it.next() orelse continue;
        if (std.mem.eql(u8, metrics, "\"")) continue;
        _ = it.next() orelse continue; // type
        const code_str = it.next() orelse continue;
        const ps_name_raw = it.next() orelse continue;
        const ps_name = std.mem.trim(u8, ps_name_raw, " \t\r");
        if (ps_name.len == 0) continue;
        const code_int = std.fmt.parseInt(i64, code_str, 10) catch continue;
        if (code_int < 0) continue;
        const code_usize: usize = @intCast(code_int);
        if (code_usize < 256) {
            const byte_code: u8 = @intCast(code_usize);
            if (enc[byte_code] == null) enc[byte_code] = try gpa.dupe(u8, ps_name);
            if (!name_map.contains(groff_name)) {
                try name_map.put(try gpa.dupe(u8, groff_name), byte_code);
            }
        } else {
            // Skip unicode-escape names (u0041_0306) and math-symbol names (*A);
            // they're unlikely to appear in C commands and would crowd out slots.
            const is_unicode = groff_name.len >= 5 and groff_name[0] == 'u' and
                std.ascii.isHex(groff_name[1]) and std.ascii.isHex(groff_name[2]) and
                std.ascii.isHex(groff_name[3]) and std.ascii.isHex(groff_name[4]);
            const is_math = groff_name.len >= 2 and groff_name[0] == '*';
            if (is_unicode or is_math) continue;
            if (!high_glyphs.contains(groff_name)) {
                try high_glyphs.put(try gpa.dupe(u8, groff_name), try gpa.dupe(u8, ps_name));
            }
        }
    }
    return .{ .encoding = enc, .name_map = name_map, .high_glyphs = high_glyphs };
}

/// reads the groff font descriptor charset and returns a PDF /Differences
/// array string (e.g. "[164 /currency 195 /Atilde ...]") for use in the
/// font's /Encoding dictionary. covers all code 0-255 entries found.
/// caller owns the returned string.
/// Per-font encoding: maps byte code (0-255) to PostScript glyph name.
/// Entries are heap-allocated; free with `freeFontEncoding`.
pub const FontEncoding = [256]?[]const u8;

/// Build the per-font encoding array from the groff font descriptor charset.
/// Caller frees with `freeFontEncoding`.
pub fn buildFontEncoding(gpa: Allocator, font_name: String) !FontEncoding {
    const groff_path = try locateFont(gpa, font_name);
    defer gpa.free(groff_path);
    var file = try std.fs.openFileAbsolute(groff_path, .{ .mode = .read_only });
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(&read_buf);
    var ifc = &reader.interface;
    var in_charset = false;
    var enc: FontEncoding = .{null} ** 256;
    while (try ifc.takeDelimiter('\n')) |line| {
        if (!in_charset) {
            if (std.mem.eql(u8, line, "charset")) in_charset = true;
            continue;
        }
        const entry = parseCharsetLine(line) orelse continue;
        if (entry.ps_name.len == 0) continue;
        if (enc[entry.code] == null) {
            enc[entry.code] = try gpa.dupe(u8, entry.ps_name);
        }
    }
    return enc;
}

pub fn freeFontEncoding(gpa: Allocator, enc: FontEncoding) void {
    for (enc) |maybe_name| {
        if (maybe_name) |n| gpa.free(n);
    }
}

/// Format a FontEncoding as a PDF /Differences array string.
/// Caller frees the returned slice.
pub fn fontEncodingToDiffs(gpa: Allocator, enc: FontEncoding) !String {
    var buf = std.array_list.Managed(u8).init(gpa);
    try buf.appendSlice("[");
    var any = false;
    for (enc, 0..) |maybe_name, code| {
        const name = maybe_name orelse continue;
        if (any) try buf.append(' ');
        try buf.writer().print("{d} /{s}", .{ code, name });
        any = true;
    }
    try buf.appendSlice("]");
    return buf.toOwnedSlice();
}

pub fn readFontEncodingDiffs(gpa: Allocator, font_name: String) !String {
    const enc = try buildFontEncoding(gpa, font_name);
    defer freeFontEncoding(gpa, enc);
    return fontEncodingToDiffs(gpa, enc);
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

    // Groff site-font devpdf dirs — where custom Type1 fonts installed for groff live
    for ([_]String{
        "/opt/homebrew/etc/groff/site-font/devpdf",
        "/usr/local/etc/groff/site-font/devpdf",
        "/etc/groff/site-font/devpdf",
    }) |p| {
        std.fs.accessAbsolute(p, .{}) catch continue;
        try dirs.append(p);
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
    // ── Length1: clear-text up to and including the separator after "currentfile eexec" ──
    // Fonts use \r, \n, or \r\n as the separator. We must NOT search for \n
    // generically because the binary encrypted data can contain \n bytes.
    const eexec_marker = "currentfile eexec";
    const eexec_idx = std.mem.indexOf(u8, data, eexec_marker) orelse return error.InvalidType1Font;
    var length1 = eexec_idx + eexec_marker.len;
    if (length1 < data.len and data[length1] == '\r') length1 += 1;
    if (length1 < data.len and data[length1] == '\n') length1 += 1;

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

// ──────────────────────────────────────────────────────────────────────────────
// Font subsetting
// ──────────────────────────────────────────────────────────────────────────────

/// Adobe StandardEncoding: maps byte position to PostScript glyph name.
const standard_encoding: [256]?[]const u8 = build: {
    var enc: [256]?[]const u8 = .{null} ** 256;
    enc[32]  = "space";        enc[33]  = "exclam";       enc[34]  = "quotedbl";
    enc[35]  = "numbersign";   enc[36]  = "dollar";       enc[37]  = "percent";
    enc[38]  = "ampersand";    enc[39]  = "quoteright";   enc[40]  = "parenleft";
    enc[41]  = "parenright";   enc[42]  = "asterisk";     enc[43]  = "plus";
    enc[44]  = "comma";        enc[45]  = "hyphen";       enc[46]  = "period";
    enc[47]  = "slash";
    enc[48]  = "zero";    enc[49]  = "one";    enc[50]  = "two";   enc[51]  = "three";
    enc[52]  = "four";    enc[53]  = "five";   enc[54]  = "six";   enc[55]  = "seven";
    enc[56]  = "eight";   enc[57]  = "nine";
    enc[58]  = "colon";        enc[59]  = "semicolon";    enc[60]  = "less";
    enc[61]  = "equal";        enc[62]  = "greater";      enc[63]  = "question";
    enc[64]  = "at";
    enc[65]  = "A"; enc[66]  = "B"; enc[67]  = "C"; enc[68]  = "D"; enc[69]  = "E";
    enc[70]  = "F"; enc[71]  = "G"; enc[72]  = "H"; enc[73]  = "I"; enc[74]  = "J";
    enc[75]  = "K"; enc[76]  = "L"; enc[77]  = "M"; enc[78]  = "N"; enc[79]  = "O";
    enc[80]  = "P"; enc[81]  = "Q"; enc[82]  = "R"; enc[83]  = "S"; enc[84]  = "T";
    enc[85]  = "U"; enc[86]  = "V"; enc[87]  = "W"; enc[88]  = "X"; enc[89]  = "Y";
    enc[90]  = "Z";
    enc[91]  = "bracketleft";  enc[92]  = "backslash";    enc[93]  = "bracketright";
    enc[94]  = "asciicircum";  enc[95]  = "underscore";   enc[96]  = "quoteleft";
    enc[97]  = "a"; enc[98]  = "b"; enc[99]  = "c"; enc[100] = "d"; enc[101] = "e";
    enc[102] = "f"; enc[103] = "g"; enc[104] = "h"; enc[105] = "i"; enc[106] = "j";
    enc[107] = "k"; enc[108] = "l"; enc[109] = "m"; enc[110] = "n"; enc[111] = "o";
    enc[112] = "p"; enc[113] = "q"; enc[114] = "r"; enc[115] = "s"; enc[116] = "t";
    enc[117] = "u"; enc[118] = "v"; enc[119] = "w"; enc[120] = "x"; enc[121] = "y";
    enc[122] = "z";
    enc[123] = "braceleft";    enc[124] = "bar";           enc[125] = "braceright";
    enc[126] = "asciitilde";
    enc[161] = "exclamdown";    enc[162] = "cent";          enc[163] = "sterling";
    enc[164] = "fraction";      enc[165] = "yen";           enc[166] = "florin";
    enc[167] = "section";       enc[168] = "currency";      enc[169] = "quotesingle";
    enc[170] = "quotedblleft";  enc[171] = "guillemotleft"; enc[172] = "guilsinglleft";
    enc[173] = "guilsinglright";enc[174] = "fi";            enc[175] = "fl";
    enc[177] = "endash";        enc[178] = "dagger";        enc[179] = "daggerdbl";
    enc[180] = "periodcentered";enc[182] = "paragraph";     enc[183] = "bullet";
    enc[184] = "quotesinglbase";enc[185] = "quotedblbase";  enc[186] = "quotedblright";
    enc[187] = "guillemotright";enc[188] = "ellipsis";      enc[189] = "perthousand";
    enc[191] = "questiondown";
    enc[193] = "grave";         enc[194] = "acute";         enc[195] = "circumflex";
    enc[196] = "tilde";         enc[197] = "macron";        enc[198] = "breve";
    enc[199] = "dotaccent";     enc[200] = "dieresis";      enc[202] = "ring";
    enc[203] = "cedilla";       enc[205] = "hungarumlaut";  enc[206] = "ogonek";
    enc[207] = "caron";         enc[208] = "emdash";
    enc[225] = "AE";            enc[227] = "ordfeminine";   enc[232] = "Lslash";
    enc[233] = "Oslash";        enc[234] = "OE";            enc[235] = "ordmasculine";
    enc[241] = "ae";            enc[245] = "dotlessi";      enc[248] = "lslash";
    enc[249] = "oslash";        enc[250] = "oe";            enc[251] = "germandbls";
    break :build enc;
};

/// /Differences overrides applied by addEmbeddedFont: [150 /endash /emdash].
const differences_encoding: [256]?[]const u8 = build: {
    var d: [256]?[]const u8 = .{null} ** 256;
    d[150] = "endash";
    d[151] = "emdash";
    break :build d;
};

pub fn glyphNameForByte(b: u8) ?[]const u8 {
    return differences_encoding[b] orelse standard_encoding[b];
}

/// Decode a PFA hex-encoded eexec section to binary.
/// PFA fonts encode the encrypted bytes as ASCII hex pairs, possibly split
/// across lines with whitespace.  Returns allocated binary slice.
fn decodePfaHex(gpa: Allocator, hex_data: []const u8) ![]u8 {
    // Count non-whitespace bytes to size output
    var n_hex: usize = 0;
    for (hex_data) |b| {
        if (b != ' ' and b != '\t' and b != '\r' and b != '\n') n_hex += 1;
    }
    if (n_hex % 2 != 0) return error.InvalidType1Font;
    const out = try gpa.alloc(u8, n_hex / 2);
    var i: usize = 0;
    var nibble: u8 = 0;
    var nibble_idx: u1 = 0;
    for (hex_data) |b| {
        if (b == ' ' or b == '\t' or b == '\r' or b == '\n') continue;
        const digit: u8 = switch (b) {
            '0'...'9' => b - '0',
            'a'...'f' => b - 'a' + 10,
            'A'...'F' => b - 'A' + 10,
            else => return error.InvalidType1Font,
        };
        if (nibble_idx == 0) {
            nibble = digit << 4;
            nibble_idx = 1;
        } else {
            out[i] = nibble | digit;
            i += 1;
            nibble_idx = 0;
        }
    }
    return out;
}

/// Detect whether a Type1 eexec section is PFA (ASCII hex) or PFB (binary).
/// Checks the first non-whitespace byte: PFA hex sections only contain
/// hex digits and whitespace, PFB sections contain arbitrary binary bytes.
fn isPfaHex(data: []const u8) bool {
    for (data) |b| {
        if (b == ' ' or b == '\t' or b == '\r' or b == '\n') continue;
        return switch (b) {
            '0'...'9', 'a'...'f', 'A'...'F' => true,
            else => false,
        };
    }
    return false;
}

/// Decrypt the eexec section of a Type1 font.
/// Handles both binary PFB form and ASCII hex PFA form automatically.
/// Returns the full decrypted stream; the first 4 bytes are the random seed
/// and should be discarded by the caller.
fn decryptEexec(gpa: Allocator, ciphertext: []const u8) ![]u8 {
    if (isPfaHex(ciphertext)) {
        const binary = try decodePfaHex(gpa, ciphertext);
        defer gpa.free(binary);
        return decryptEexecBinary(gpa, binary);
    }
    return decryptEexecBinary(gpa, ciphertext);
}

fn decryptEexecBinary(gpa: Allocator, ciphertext: []const u8) ![]u8 {
    const plain = try gpa.alloc(u8, ciphertext.len);
    var r: u16 = 55665;
    const c1: u32 = 52845;
    const c2: u32 = 22719;
    for (ciphertext, 0..) |b, i| {
        plain[i] = b ^ @as(u8, @truncate(r >> 8));
        r = @truncate((@as(u32, b) +% @as(u32, r)) *% c1 +% c2);
    }
    return plain;
}

/// Re-encrypt plaintext using the eexec cipher, prepending 4 null seed bytes.
fn encryptEexec(gpa: Allocator, plaintext: []const u8) ![]u8 {
    const cipher = try gpa.alloc(u8, 4 + plaintext.len);
    var r: u16 = 55665;
    const c1: u32 = 52845;
    const c2: u32 = 22719;
    for (0..4) |i| {
        // encrypt a null seed byte: cipher = 0 XOR (r >> 8) = high byte of r
        const c: u8 = @truncate(r >> 8);
        cipher[i] = c;
        r = @truncate((@as(u32, c) +% @as(u32, r)) *% c1 +% c2);
    }
    for (plaintext, 0..) |p, i| {
        const c: u8 = p ^ @as(u8, @truncate(r >> 8));
        cipher[4 + i] = c;
        r = @truncate((@as(u32, c) +% @as(u32, r)) *% c1 +% c2);
    }
    return cipher;
}

/// Subset a Type1 font to only the glyphs in `needed_names`.
/// The caller is responsible for building the set from all encodings (primary
/// and any overflow re-encodings) that share this font's font file stream.
/// Always retains .notdef even if not in `needed_names`.
pub fn subsetType1Font(gpa: Allocator, font_data: Type1FontData, needed_names: std.StringHashMap(void)) !Type1FontData {
    var needed = needed_names;

    // Decrypt eexec section and skip the 4-byte random seed.
    const encrypted = font_data.data[font_data.length1 .. font_data.length1 + font_data.length2];
    const decrypted_full = try decryptEexec(gpa, encrypted);
    defer gpa.free(decrypted_full);
    if (decrypted_full.len < 4) return error.InvalidType1Font;
    const plain = decrypted_full[4..];

    // Locate /CharStrings dict.
    const cs_kw = "/CharStrings ";
    const cs_kw_pos = std.mem.indexOf(u8, plain, cs_kw) orelse return error.NoCharStrings;

    // Find the start of the /CharStrings line (for verbatim copy of everything before it).
    var cs_line_start = cs_kw_pos;
    while (cs_line_start > 0 and plain[cs_line_start - 1] != '\n') cs_line_start -= 1;

    // Find "begin" marker and the first glyph entry.
    const begin_kw = "begin";
    const begin_pos = std.mem.indexOfPos(u8, plain, cs_kw_pos, begin_kw) orelse return error.NoCharStrings;
    var entries_start = begin_pos + begin_kw.len;
    while (entries_start < plain.len and
        (plain[entries_start] == '\n' or plain[entries_start] == '\r' or plain[entries_start] == ' '))
        entries_start += 1;

    // Detect the readstring operator name (RD or -|) and end operator (ND or |-).
    const private_section = plain[0..cs_kw_pos];
    const rd_op: []const u8 = if (std.mem.indexOf(u8, private_section, " RD ") != null or
        std.mem.indexOf(u8, private_section, "\nRD ") != null) "RD" else "-|";
    const nd_op: []const u8 = if (std.mem.indexOf(u8, private_section, " ND\n") != null or
        std.mem.indexOf(u8, private_section, "\nND\n") != null) "ND" else "|-";

    // Parse all glyph entries.  Each entry has the form:
    //   /name count RD <count binary bytes>ND\n
    const GlyphEntry = struct {
        name: []const u8,
        bytes: []const u8, // verbatim slice of plain from '/' to end of '\n'
    };
    var all_glyphs = std.array_list.Managed(GlyphEntry).init(gpa);
    defer all_glyphs.deinit();

    var pos = entries_start;
    while (pos < plain.len) {
        // skip any whitespace between entries (some fonts have space or blank lines)
        while (pos < plain.len and plain[pos] != '/') {
            if (plain[pos] == 'e') break; // hit "end"
            pos += 1;
        }
        if (pos >= plain.len or plain[pos] != '/') break;
        const entry_start = pos;
        pos += 1; // skip '/'

        const name_end = std.mem.indexOfScalarPos(u8, plain, pos, ' ') orelse break;
        const glyph_name = plain[pos..name_end];
        pos = name_end + 1;

        const count_end = std.mem.indexOfScalarPos(u8, plain, pos, ' ') orelse break;
        const count = std.fmt.parseUnsigned(usize, plain[pos..count_end], 10) catch break;
        pos = count_end + 1;

        pos += rd_op.len + 1; // skip "RD "
        if (pos + count > plain.len) break;
        pos += count; // skip binary charstring data
        pos += nd_op.len; // skip "ND"

        // skip line ending
        while (pos < plain.len and (plain[pos] == '\n' or plain[pos] == '\r')) pos += 1;

        try all_glyphs.append(.{ .name = glyph_name, .bytes = plain[entry_start..pos] });
    }

    // Skip the "end" that closes the CharStrings dict.
    var after_cs = pos;
    if (std.mem.startsWith(u8, plain[after_cs..], "end")) {
        after_cs += 3;
        while (after_cs < plain.len and (plain[after_cs] == '\n' or plain[after_cs] == '\r'))
            after_cs += 1;
    }

    // Count kept glyphs and build new plaintext.
    var kept: usize = 0;
    for (all_glyphs.items) |g| {
        if (needed.contains(g.name)) kept += 1;
    }

    var new_plain = std.array_list.Managed(u8).init(gpa);
    defer new_plain.deinit();
    try new_plain.appendSlice(plain[0..cs_line_start]);
    try new_plain.writer().print("/CharStrings {d} dict dup begin\n", .{kept});
    for (all_glyphs.items) |g| {
        if (needed.contains(g.name)) try new_plain.appendSlice(g.bytes);
    }
    try new_plain.appendSlice("end\n");
    try new_plain.appendSlice(plain[after_cs..]);

    // Re-encrypt (prepends 4-byte seed) and reassemble around the original header/trailer.
    const new_encrypted = try encryptEexec(gpa, new_plain.items);
    errdefer gpa.free(new_encrypted);

    const header = font_data.data[0..font_data.length1];
    const trailer = font_data.data[font_data.length1 + font_data.length2 ..];
    const new_data = try std.mem.concat(gpa, u8, &.{ header, new_encrypted, trailer });

    log.dbg("groff: subset font {s}: {d} -> {d} bytes ({d}/{d} glyphs)\n", .{
        font_data.font_name, font_data.data.len, new_data.len, kept, all_glyphs.items.len,
    });
    return Type1FontData{
        .data = new_data,
        .length1 = font_data.length1,
        .length2 = new_encrypted.len,
        .length3 = font_data.length3,
        .font_name = font_data.font_name,
        .font_bbox = font_data.font_bbox,
        .italic_angle = font_data.italic_angle,
        .flags = font_data.flags,
    };
}

/// Read the `internalname` field from a groff font descriptor file.
/// Returns null if the file cannot be opened or has no internalname line.
fn readInternalName(gpa: Allocator, groff_name: String) !?String {
    const groff_path = locateFont(gpa, groff_name) catch return null;
    defer gpa.free(groff_path);
    var file = std.fs.openFileAbsolute(groff_path, .{}) catch return null;
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(&read_buf);
    const ifc = &reader.interface;
    const prefix = "internalname ";
    while (try ifc.takeDelimiter('\n')) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            const name = std.mem.trim(u8, line[prefix.len..], " \t\r");
            return try gpa.dupe(u8, name);
        }
        // Stop at the charset section — internalname is always in the header
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "charset")) break;
    }
    return null;
}

/// Try to find, read, and parse a Type1 font for the given groff font name.
/// Returns `null` if no font file is found in the search paths.
pub fn findAndLoadFont(gpa: Allocator, groff_name: String) !?Type1FontData {
    const known_candidates = getFontFileCandidates(groff_name);
    // For fonts not in the static map, read the groff font descriptor to get
    // the internalname (e.g. MinionR -> MinionPro-Regular), then fall back to
    // the groff name itself if there is no descriptor or no internalname field.
    var internal_name_buf: ?String = null;
    defer if (internal_name_buf) |s| gpa.free(s);
    const candidates: []const String = if (known_candidates.len > 0)
        known_candidates
    else blk: {
        if (try readInternalName(gpa, groff_name)) |internal| {
            internal_name_buf = internal;
            break :blk @as([]const String, &[1]String{internal});
        }
        break :blk &[1]String{groff_name};
    };

    const search_dirs = try buildFontSearchDirs(gpa);

    for (search_dirs.items) |dir| {
        for (candidates) |name| {
            // Try without extension, then common Type1 extensions
            for ([_]String{ "", ".pfa", ".pfb" }) |ext| {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, name, ext });
                const data = std.fs.cwd().readFileAlloc(gpa, path, 20 * 1024 * 1024) catch {
                    gpa.free(path);
                    continue;
                };
                gpa.free(path);
                return parseType1FontData(gpa, data) catch |err| {
                    log.warn("warning: could not parse Type1 font {s}{s}: {}\n", .{ name, ext, err });
                    continue;
                };
            }
        }
    }
    return null;
}
