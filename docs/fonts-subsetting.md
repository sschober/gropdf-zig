# gropdf-zig Font Embedding — Development Notes

A conversation covering Type 1 font embedding, subsetting, PFA/PFB formats,
AFM files, Subrs, and OTF font handling for the
[gropdf-zig](https://github.com/sschober/gropdf-zig) project.

---

## Font Embedding Suggestions

### Current Limitation

The README explicitly states: *"We support only a single font, 'Times New
Roman', as that can be referenced very easily in PDF, without the need to embed
it."* This means the output relies on PDF viewer font substitution, which
violates the current PDF standard (ISO 32000-2) and causes inconsistent
rendering across systems.

### The Full Object Graph for One Embedded Font

Embedding requires **four** PDF objects per font:

```
FontFile stream  ←── FontDescriptor ←── Font dict ←── Resources /Font dict
```

**1. The `/FontFile` stream:**

```
<< /Length1  <byte count of segment 1, the ASCII header>
   /Length2  <byte count of segment 2, the binary/encrypted section>
   /Length3  <byte count of segment 3, the ASCII trailer; often 0>
   /Length   <total byte count of the raw concatenated stream data>
>>
stream
...raw bytes of all three segments concatenated, PFB headers stripped...
endstream
```

**2. The `/FontDescriptor`:**

```
<< /Type /FontDescriptor
   /FontName /URWPalladioL-Roma
   /Flags 34
   /FontBBox [-166 -283 1021 943]
   /ItalicAngle 0
   /Ascent 716
   /Descent -266
   /CapHeight 680
   /StemV 84
   /FontFile 42 0 R
>>
```

**3. The `/Font` object:**

```
<< /Type /Font
   /Subtype /Type1
   /BaseFont /URWPalladioL-Roma
   /Encoding /WinAnsiEncoding
   /FirstChar 32
   /LastChar 255
   /Widths [ 250 ... ]
   /FontDescriptor 43 0 R
>>
```

**4. The page `/Resources` dict:**

```
/Resources << /Font << /F3 44 0 R >> >>
```

---

## PFB Binary Embedding — Deep Dive

### The Three-Segment Structure of a PFB File

Each PFB file is divided into three segments, each preceded by a 6-byte binary
header. The first byte is always `0x80` (128). The second byte is the segment
type: `0x01` for ASCII, `0x02` for binary, `0x03` for EOF. The following four
bytes are the segment length in little-endian order.

| # | Type | `0x80` marker | PDF length key | Contents |
|---|------|---------------|----------------|----------|
| 1 | ASCII | `0x80 0x01` | `/Length1` | PostScript preamble |
| 2 | Binary | `0x80 0x02` | `/Length2` | Encrypted charstrings |
| 3 | ASCII | `0x80 0x01` | `/Length3` | Trailer |

In Zig:

```zig
const SegmentKind = enum { ascii, binary, eof };

const Segment = struct {
    kind: SegmentKind,
    data: []const u8,
};

fn parsePfb(allocator: std.mem.Allocator, raw: []const u8) ![]Segment {
    var segments = std.ArrayList(Segment).init(allocator);
    var pos: usize = 0;

    while (pos < raw.len) {
        if (raw[pos] != 0x80) return error.InvalidPfbMarker;
        const kind_byte = raw[pos + 1];
        if (kind_byte == 0x03) break;

        const len = std.mem.readIntLittle(u32, raw[pos+2..][0..4]);
        pos += 6;

        try segments.append(.{
            .kind = if (kind_byte == 0x01) .ascii else .binary,
            .data = raw[pos .. pos + len],
        });
        pos += len;
    }
    return segments.toOwnedSlice();
}
```

**Critical**: the PFB envelope headers are **stripped** — PDF only wants the
raw payload bytes concatenated. The length values from the PFB headers are
copied into `/Length1`, `/Length2`, `/Length3`.

### `/Length3` Notes

`/Length3` is often `0` in practice. Some Type 1 font programs use zero-byte
padding at the end of the binary section rather than a genuine third ASCII
segment. When the EOF marker `0x80 0x03` appears immediately after the binary
segment, there is no third segment and `/Length3` should be `0`.

### `/FontFile` vs `/FontFile2` vs `/FontFile3`

- `/FontFile` — Type 1 fonts
- `/FontFile2` — TrueType fonts
- `/FontFile3` — Type 1C (CFF/OpenType CFF), subtype specified by `/Subtype`
  key in the stream dictionary

---

## Type 1 Font Subsetting

### What Subsetting Means

1. **Track** which glyph names are used in the document
2. **Parse** the encrypted charstrings from segment 2
3. **Keep** only charstrings for used glyphs (plus `.notdef`)
4. **Re-encrypt** the pruned charstring dictionary
5. **Rebuild** segment 1 with updated `/Encoding` and `/FontName` prefix
6. **Rename** the font with a 6-letter prefix: `ABCDEF+URWPalladioL-Roma`
7. **Rewrite** `/Widths` in the Font dict

### Step 1: Track Used Glyphs

```zig
const GlyphSet = std.StringHashMap(void);

const FontUsage = struct {
    glyph_names: GlyphSet,

    pub fn markUsed(self: *FontUsage, name: []const u8) !void {
        try self.glyph_names.put(name, {});
    }
};
```

Always include `.notdef` unconditionally.

### Step 2: The Decryption Algorithm

Type 1 uses a linear congruential generator (LCG) as a stream cipher.

```
R_next = (R_current * 52845 + 22719) mod 65536
keystream_byte = R >> 8
plaintext_byte = ciphertext_byte XOR keystream_byte
R_next = (ciphertext_byte + R) * 52845 + 22719
```

Two layers, two seeds:

| Layer | Seed | Scope |
|---|---|---|
| eexec | `55665` | Whole private dict |
| charstring | `4330` | Each individual charstring |

```zig
fn type1Decrypt(
    allocator: std.mem.Allocator,
    cipher: []const u8,
    seed: u16,
    lenIV: u8,
) ![]u8 {
    var R: u16 = seed;
    const c1: u16 = 52845;
    const c2: u16 = 22719;

    var plain = try allocator.alloc(u8, cipher.len);
    for (cipher, 0..) |c, i| {
        plain[i] = c ^ @as(u8, @truncate(R >> 8));
        R = ((@as(u16, c) +% R) *% c1) +% c2;
    }
    return plain[lenIV..];
}
```

The first `lenIV` bytes (default 4) are random IV — discard them. Some fonts
set `/lenIV 0` — read this from the private dict before decrypting charstrings.

### Subset Tag Generation

```zig
fn generateSubsetTag(used: *GlyphSet, font_name: []const u8, buf: *[128]u8) []u8 {
    var hash: u32 = 0;
    var it = used.keyIterator();
    while (it.next()) |k| {
        for (k.*) |c| hash = hash *% 31 +% c;
    }
    return std.fmt.bufPrint(buf, "{c}{c}{c}{c}{c}{c}+{s}", .{
        'A' + @as(u8, @truncate(hash)),
        'A' + @as(u8, @truncate(hash >> 5)),
        'A' + @as(u8, @truncate(hash >> 10)),
        'A' + @as(u8, @truncate(hash >> 15)),
        'A' + @as(u8, @truncate(hash >> 20)),
        'A' + @as(u8, @truncate(hash >> 25)),
        font_name,
    }) catch unreachable;
}
```

---

## PFA Format — Deep Dive

### Overall File Structure

```postscript
%!PS-AdobeFont-1.0: FontName 1.05
%%Title: FontName
...
/FontName /ActualFontName def
/FontType 1 def
/FontMatrix [0.001 0 0 0.001 0 0] readonly def
/FontBBox {-166 -283 1021 943} readonly def

/Encoding 256 array
0 1 255 {1 index exch /.notdef put} for
dup 65 /A put
...
readonly def

currentfile eexec                    ← BOUNDARY: everything below is encrypted+hex
d4358f0a4e292b840f5e4adab853f742...  ← hex-encoded eexec block
0000000000000000000000000000000000000000000000000000000000000000
cleartomark
```

### The `currentfile eexec` Boundary

After `currentfile eexec`, the data is hex-encoded and eexec-encrypted. After
hex-decoding and eexec-decrypting (seed `55665`, discard 4 IV bytes), you get
the private dict:

```postscript
/lenIV 4 def
/Subrs 5 array
dup 0 7 RD <7 encrypted bytes> NP
...
/CharStrings 228 dict dup begin
/.notdef 18 RD <18 encrypted bytes> ND
/A 98 RD <98 encrypted bytes> ND
...
end
```

### PFA vs PFB Differences

| Aspect | PFB | PFA |
|---|---|---|
| Outer envelope | Binary `0x80` headers | None |
| Segment 2 data | Raw binary bytes | Hex-encoded ASCII |
| Segment boundaries | Length fields in headers | Text markers |
| For PDF embedding | Strip headers, concat | Hex-decode seg 2 first |

For PDF embedding, always convert to raw binary regardless of source format.
The `/FontFile` stream format is identical either way.

### Hex Decoding in Zig

```zig
fn hexDecodeEexec(allocator: std.mem.Allocator, pfa: []const u8) ![]u8 {
    const marker = "currentfile eexec";
    const start = std.mem.indexOf(u8, pfa, marker) orelse return error.NoEexec;
    const hex_start = start + marker.len;

    var hex_chars = std.ArrayList(u8).init(allocator);
    defer hex_chars.deinit();

    for (pfa[hex_start..]) |c| {
        if (std.ascii.isHex(c)) try hex_chars.append(c);
    }

    const bytes = try allocator.alloc(u8, hex_chars.items.len / 2);
    for (bytes, 0..) |*b, i| {
        b.* = try std.fmt.parseUnsigned(u8, hex_chars.items[i*2..][0..2], 16);
    }
    return bytes;
}
```

### Format Detection

```zig
const FontFormat = enum { pfb, pfa };

fn detectFontFormat(data: []const u8) FontFormat {
    if (data.len >= 2 and data[0] == 0x80 and data[1] == 0x01)
        return .pfb;
    return .pfa;
}
```

---

## AFM Files — Deep Dive

### Overall Structure

```
StartFontMetrics 4.1
FontName URWPalladioL-Roma
FontBBox -166 -283 1021 943
CapHeight 680
XHeight 430
Ascender 716
Descender -266
StartCharMetrics 228
C 65 ; WX 722 ; N A ; B 15 0 706 683 ;
C -1 ; WX 500 ; N fi ; B 5 -13 518 691 ;
...
EndCharMetrics
StartKernData
StartKernPairs 519
KPX A V -80
KPX T a -80
...
EndKernPairs
EndKernData
EndFontMetrics
```

### AFM to PDF FontDescriptor Mapping

| AFM field | PDF FontDescriptor key |
|---|---|
| `FontBBox llx lly urx ury` | `/FontBBox [llx lly urx ury]` |
| `Ascender` | `/Ascent` |
| `Descender` | `/Descent` |
| `CapHeight` | `/CapHeight` |
| `XHeight` | `/XHeight` |
| `ItalicAngle` | `/ItalicAngle` |

Note: `/StemV` is **not** in the AFM — it comes from `/StdVW` in the PFB
private dict, or use `84` as a fallback for regular weight fonts.

### `/Flags` Bitmask

```
Bit 1  (2)      — IsFixedPitch
Bit 2  (4)      — has serifs
Bit 6  (32)     — Nonsymbolic (standard Latin)
Bit 7  (64)     — Italic (ItalicAngle != 0)
```

Most Latin text fonts: `32` (Nonsymbolic). Times-Italic: `96`. Courier: `34`.

### CharMetrics Parsing in Zig

```zig
fn parseCharMetricLine(self: *AfmParser, line: []const u8) !void {
    var glyph = GlyphMetrics{};
    var fields = std.mem.splitScalar(u8, line, ';');

    while (fields.next()) |field| {
        const f = std.mem.trim(u8, field, " \t");
        if (f.len == 0) continue;

        if (startsWith(f, "WX ")) {
            glyph.wx = try parseInt(u16, f[3..]);
        } else if (startsWith(f, "N ")) {
            glyph.name = f[2..];
        } else if (startsWith(f, "B ")) {
            var coords = std.mem.splitScalar(u8, f[2..], ' ');
            glyph.llx = try parseInt(i16, coords.next().?);
            glyph.lly = try parseInt(i16, coords.next().?);
            glyph.urx = try parseInt(i16, coords.next().?);
            glyph.ury = try parseInt(i16, coords.next().?);
        }
    }

    if (glyph.name.len > 0)
        try self.metrics.put(glyph.name, glyph);
}
```

### Kern Pairs

Kern pairs are already applied by groff before the `.grout` stream reaches the
device driver — glyph positions in the grout stream already account for
kerning. No need to implement kern pair lookup in the PDF emitter.

---

## Subrs — Deep Dive

### What Subrs Are

Subroutines are reusable chunks of charstring bytecode stored in the private
dict and called by index from within individual glyph charstrings. They exist
purely for compression.

```postscript
/Subrs 5 array
dup 0 7 RD <7 encrypted bytes> NP
dup 1 19 RD <19 encrypted bytes> NP
dup 2 31 RD <31 encrypted bytes> NP
dup 3 7 RD <7 encrypted bytes> NP
dup 4 1 RD <1 encrypted byte> NP
def
```

Inside a charstring, a call looks like: `3 callsubr` (opcode `10`).

### The Four Standard Subrs

Most fonts include four mandatory subroutines at indices 0–3:

- Subr 0 — seac component terminator
- Subr 1 — flex mechanism part 1
- Subr 2 — flex mechanism part 2
- Subr 3 — hint substitution return

These are boilerplate — always keep unconditionally.

### Why You Can't Always Safely Prune Subrs

1. The index can be computed, not just a literal
2. Subrs can call other Subrs (up to 10 levels deep)
3. Hint substitution uses Subrs implicitly

For standard fonts (URW base 35): keep all Subrs, prune only CharStrings.
For FontForge-linearized fonts: reachability analysis required.

### FontForge's Subr Linearization Problem

FontForge aggressively factors glyph outlines into hundreds or thousands of
Subrs. A typical result: 3006 Subrs vs 5 for `tx -t1` output.

Detection heuristic:

```zig
fn needsReachabilityAnalysis(subr_count: usize, glyph_count: usize) bool {
    return subr_count > 20 or subr_count > glyph_count;
}
```

### Reachability Analysis (for FontForge fonts)

```zig
fn walkCharString(
    self: *Reachability,
    encrypted: []const u8,
    all_subrs: []const CharString,
    lenIV: u8,
) !void {
    const plain = try type1Decrypt(encrypted, 4330, lenIV);
    defer allocator.free(plain);

    var i: usize = 0;
    while (i < plain.len) {
        const b = plain[i];
        i += 1;

        if (b >= 32) {
            i += numberArgSize(b, plain[i..]);
            continue;
        }

        switch (b) {
            10 => { // callsubr
                const idx = self.stack.pop();
                if (!self.subrs_needed.isSet(idx)) {
                    self.subrs_needed.set(idx);
                    try self.walkCharString(
                        all_subrs[idx].encrypted_bytes,
                        all_subrs,
                        lenIV,
                    );
                }
            },
            11 => {}, // return
            14 => {}, // endchar
            12 => { i += 1; }, // escape byte
            else => {},
        }
    }
}
```

**Preserving indices with stubs** (Option A — simpler):

```zig
fn writeSubrsPreservingIndices(
    w: anytype,
    all_subrs: []const CharString,
    needed: std.DynamicBitSet,
) !void {
    try w.print("/Subrs {d} array\n", .{all_subrs.len});

    for (all_subrs, 0..) |subr, i| {
        if (needed.isSet(i)) {
            try w.print("dup {d} {d} RD ", .{i, subr.encrypted_bytes.len});
            try w.writeAll(subr.encrypted_bytes);
            try w.writeAll(" NP\n");
        } else {
            const stub = try encryptStubReturn(lenIV);
            try w.print("dup {d} {d} RD ", .{i, stub.len});
            try w.writeAll(stub);
            try w.writeAll(" NP\n");
        }
    }
    try w.writeAll("def\n");
}
```

### What gropdf.pl Actually Does

gropdf.pl does **not** decrypt charstring bytecodes. It works at the PostScript
text level after eexec-decryption, scanning for `callsubr` patterns in the
(still charstring-encrypted) binary data using regex. This is a heuristic that
works for standard URW fonts but may miss calls in FontForge-linearized fonts.

Key constants in gropdf.pl:

```perl
MAGIC1 => 52845,   # c1 for LCG
MAGIC2 => 22719,   # c2 for LCG
C_DEF  => 4330,    # charstring seed
E_DEF  => 55665,   # eexec seed
SUBSET => 1,       # options bitmask
```

Pre-seeded Subrs (always kept):

```perl
push(@subrused, '#0', '#1', '#2', '#3', '#4');
```

---

## URW Fonts

URW++ (German type foundry) released metrically compatible clones of all 35
standard PostScript fonts under the GPL in 1996. These are the fonts groff's
`devpdf` device is built around.

| Adobe Original | URW Clone | groff name |
|---|---|---|
| Times-Roman | URW Palladio L | `TR` |
| Helvetica | URW Nimbus Sans L | `HR` |
| Courier | URW Nimbus Mono PS | `CR` |
| Palatino | URW Palladio L | `PR` |

Typical location on Linux:

```
/usr/share/fonts/type1/urw-base35/
    URWPalladioL-Roma.pfb
    NimbusSanL-Regu.pfb
    NimbusMono-Regular.pfb
    ...
```

URW fonts are well-structured Type 1 with 4–8 boilerplate Subrs — ideal test
cases for font embedding implementation.

---

## Converting OTF to PFA

### Tool Comparison

| Tool | Subr count | Quality | Notes |
|---|---|---|---|
| FontForge | ~3006 | Good outlines, poor hinting | Subr explosion |
| `tx -t1` (AFDKO) | ~5 | Best — preserves hinting | Recommended |
| `fonttools t1` | ~5–10 | Good | Python, easy to script |

### Verifying Subr Count

```sh
# t1disasm decrypts the eexec block first
t1disasm MyFont.pfa | grep "^/Subrs"

# or count individual subr entries
t1disasm MyFont.pfa | grep -c "^\s*dup [0-9]"
```

Note: `grep -c "dup [0-9]* [0-9]* RD" MyFont.pfa` does **not** work on raw
PFA files — the Subrs are inside the encrypted eexec block and not visible as
plain text. Always use `t1disasm` first.

The `RD` operator is also aliased as `-|` in many fonts:

```sh
t1disasm MyFont.pfa | grep -cE "dup [0-9]+ [0-9]+ (RD|-\|)"
```

---

## install-font.bash Analysis

The groff `contrib/install-font/install-font.bash` script uses FontForge for
two purposes:

**For TTF/OTF input:**
```
Open($1);
Generate($fontname + ".pfa");   ← for devpdf embedding
Generate($fontname + ".t42");   ← for devps/ghostscript
```

**For PFB/PFA input:**
```
Open($1);
Generate($fontname + ".pfa");   ← normalise and rename by PS font name
```

### Replacing FontForge

| FontForge use | Replacement | Quality |
|---|---|---|
| PFB → PFA (rename) | `t1ascii` from t1utils | Identical — lossless |
| OTF/TTF → PFA | `tx -t1` from AFDKO | Better — no Subr explosion |
| OTF/TTF → T42 | `ttf2pt1 -b` | Equivalent |
| AFM generation | `tx -afm` from AFDKO | Equivalent or better |

Revised pipeline without FontForge:

```bash
# For OTF/TTF:
tx -t1 "${file}" > "${tmp_dir}/${font}.pfa"      # clean PFA, 5 subrs
tx -afm "${file}" > "${tmp_dir}/${font}.afm"      # metrics for afmtodit
ttf2pt1 -b "${file}" "${tmp_dir}/${font}"         # T42 for devps

# For PFB/PFA:
t1ascii "${file}" "${tmp_dir}/tmp.pfa"
font=$(grep "^/FontName" "${tmp_dir}/tmp.pfa" | awk '{print $2}' | tr -d '/')
mv "${tmp_dir}/tmp.pfa" "${tmp_dir}/${font}.pfa"
tx -afm "${tmp_dir}/${font}.pfa" > "${tmp_dir}/${font}.afm"
```

---

## OTF Direct Embedding (Future Direction)

PDF 1.6+ supports OTF direct embedding without any conversion:

```
<< /Type /FontDescriptor
   /FontName /MyFont
   /FontFile3 X 0 R
>>

FontFile3 stream:
<< /Subtype /OpenType /Length N >>
stream
...raw OTF bytes verbatim...
endstream
```

However, groff itself needs font metric files (glyph widths, kerning,
ligatures) generated from the font **before** typesetting. Currently this
requires either:

- Type 1 conversion pipeline (existing: `afmtodit` reads AFM)
- A new `otftodit` tool reading OTF tables (`hmtx`, `GPOS`, `GSUB`, `cmap`)
- `tx -afm` to generate AFM from OTF → feed existing `afmtodit`

The two-part architecture:

```
groff font files (TR, TI, ...)  →  layout (glyph positions baked into .grout)
OTF/PFA/PFB file                →  PDF embedding only
```

Most pragmatic near-term approach:

```
OTF font
    ├── tx -afm → AFM → afmtodit → groff font file
    └── gropdf-zig OTF embedding → /FontFile3 /OpenType in PDF
```

---

## Key Constants Reference

```zig
// Type 1 LCG cipher
const c1: u16 = 52845;
const c2: u16 = 22719;
const eexec_seed: u16 = 55665;
const charstring_seed: u16 = 4330;
const default_lenIV: u8 = 4;

// PFB segment markers
const PFB_MARKER: u8 = 0x80;
const PFB_ASCII: u8 = 0x01;
const PFB_BINARY: u8 = 0x02;
const PFB_EOF: u8 = 0x03;
```

## Validation

After generating a PDF with embedded fonts:

```sh
pdffonts sample-out.pdf
# emb column should show 'yes'
# sub column shows 'yes' if subsetting is active

t1disasm MyFont.pfa | grep "^/Subrs"
# verify subr count before embedding
```