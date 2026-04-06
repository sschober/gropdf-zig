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

/// Byte→glyph-name mapping for positions where groff's devpdf encoding differs
/// from Adobe StandardEncoding.  Covers:
///   • Windows-1252 positions 150/151 (en-dash / em-dash) used by groff
///   • ISO-8859-1 Latin-1 Supplement (0x80–0xFF) for accented characters
///     including all German umlauts (ä ö ü Ä Ö Ü ß) and other diacritics.
///
/// groff's devpdf device assigns byte indices to glyphs using ISO-8859-1
/// compatible positions (as found in the devpdf font description files' charset
/// section).  These positions are NOT in Adobe StandardEncoding, so without
/// this table the subsetting step would silently drop every accented glyph.
const differences_encoding: [256]?[]const u8 = build: {
    var d: [256]?[]const u8 = .{null} ** 256;
    // Windows-1252 extras used by groff (override StandardEncoding 150/177)
    d[150] = "endash";
    d[151] = "emdash";
    // ISO-8859-1 Latin-1 Supplement: 0xC0–0xFF
    d[192] = "Agrave";       d[193] = "Aacute";       d[194] = "Acircumflex";
    d[195] = "Atilde";       d[196] = "Adieresis";    d[197] = "Aring";
    d[198] = "AE";           d[199] = "Ccedilla";     d[200] = "Egrave";
    d[201] = "Eacute";       d[202] = "Ecircumflex";  d[203] = "Edieresis";
    d[204] = "Igrave";       d[205] = "Iacute";       d[206] = "Icircumflex";
    d[207] = "Idieresis";    d[208] = "Eth";          d[209] = "Ntilde";
    d[210] = "Ograve";       d[211] = "Oacute";       d[212] = "Ocircumflex";
    d[213] = "Otilde";       d[214] = "Odieresis";    d[215] = "multiply";
    d[216] = "Oslash";       d[217] = "Ugrave";       d[218] = "Uacute";
    d[219] = "Ucircumflex";  d[220] = "Udieresis";    d[221] = "Yacute";
    d[222] = "Thorn";        d[223] = "germandbls";
    d[224] = "agrave";       d[225] = "aacute";       d[226] = "acircumflex";
    d[227] = "atilde";       d[228] = "adieresis";    d[229] = "aring";
    d[230] = "ae";           d[231] = "ccedilla";     d[232] = "egrave";
    d[233] = "eacute";       d[234] = "ecircumflex";  d[235] = "edieresis";
    d[236] = "igrave";       d[237] = "iacute";       d[238] = "icircumflex";
    d[239] = "idieresis";    d[240] = "eth";           d[241] = "ntilde";
    d[242] = "ograve";       d[243] = "oacute";       d[244] = "ocircumflex";
    d[245] = "otilde";       d[246] = "odieresis";    d[247] = "divide";
    d[248] = "oslash";       d[249] = "ugrave";       d[250] = "uacute";
    d[251] = "ucircumflex";  d[252] = "udieresis";    d[253] = "yacute";
    d[254] = "thorn";        d[255] = "ydieresis";
    break :build d;
};

fn glyphNameForByte(b: u8) ?[]const u8 {
    return differences_encoding[b] orelse standard_encoding[b];
}

/// Decrypt the eexec section of a Type1 font (binary form).
/// Returns the full decrypted stream; the first 4 bytes are the random seed
/// and should be discarded by the caller.
fn decryptEexec(gpa: Allocator, ciphertext: []const u8) ![]u8 {
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

/// Subset a Type1 font to only the glyphs needed for `used_bytes`.
/// Glyph names are resolved through StandardEncoding plus the /Differences
/// [150 /endash /emdash] applied by addEmbeddedFont.  Always retains .notdef.
pub fn subsetType1Font(gpa: Allocator, font_data: Type1FontData, used_bytes: [256]bool) !Type1FontData {
    // Build the set of needed glyph names.
    var needed = std.StringHashMap(void).init(gpa);
    defer needed.deinit();
    try needed.put(".notdef", {});
    for (used_bytes, 0..) |used, b| {
        if (used) {
            if (glyphNameForByte(@intCast(b))) |name| try needed.put(name, {});
        }
    }

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
