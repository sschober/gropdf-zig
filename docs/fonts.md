# Font Handling: Embedding, Subsetting, and Compression

This document describes how gropdf.zig selects, embeds, subsets, and compresses
fonts when generating PDF output from groff intermediate format.

## Font Selection

Groff names fonts by short identifiers such as `TR` (Times Roman), `TB` (Times
Bold), `CR` (Courier), or custom names for user-defined fonts.  When the
transpiler encounters an `x font` command it must map that name to a PDF font
object.  The selection follows a priority order:

1. **Standard PDF font** — if the groff font name appears in the built-in
   `groff_to_pdf_font_map` table (e.g. `TR` → `Times-Roman`, `TB` →
   `Times-Bold`, `CR` → `Courier`), a standard font reference is used.  No
   font data is embedded in the file; the viewer supplies the glyphs from its
   own built-in font engine.  This matches what `groff -Tpdf` does and keeps
   output files small (~10 KB for typical documents).

2. **Embedded Type1 font** — for font names that have no standard PDF
   equivalent the transpiler searches the system font directories for a
   matching PFA file (see `groff.findAndLoadFont`).  When found the font is
   parsed, subsetted to the glyphs actually used, and embedded directly in the
   PDF stream.

3. **Unsupported font** — if neither mapping nor font file is found a warning
   is emitted and the font command is skipped.

The full mapping from groff names to PDF standard fonts is the
`groff_to_pdf_font_map` compile-time table in `src/Transpiler.zig`.

## Character Encoding

All fonts — both standard references and embedded Type1 — use
`/BaseEncoding /StandardEncoding` with a single `/Differences` override:

```
/Encoding << /Type /Encoding
             /BaseEncoding /StandardEncoding
             /Differences [150 /endash /emdash] >>
```

The reason for this override is a mismatch between Adobe StandardEncoding and
the byte values groff uses for dashes:

| Glyph   | StandardEncoding position | groff byte value | Source |
|---------|--------------------------|-----------------|--------|
| endash  | 177 (0xB1)               | 150 (0x96)      | Windows-1252 |
| emdash  | 208 (0xD0)               | 151 (0x97)      | Windows-1252 |

All other special characters in `glyph_map` (fi=174, fl=175, quoteleft=96,
quotedblright=186, …) already sit at their correct StandardEncoding positions
so no further differences are required.

## Font Embedding

When a font must be embedded (step 2 above) three PDF objects are created by
`pdf.Document.addEmbeddedFont`:

```
FontFileStream  ──►  raw Type1 PFA bytes (Length1/Length2/Length3)
FontDescriptor  ──►  metrics: BBox, Ascent, Descent, ItalicAngle, Flags, …
                     references FontFileStream via /FontFile
Font dictionary ──►  /BaseFont, /Subtype /Type1, /Encoding, /FontDescriptor
```

### Type1 PFA format

A PFA font file has three sections whose byte lengths map directly to the PDF
`Length1`, `Length2`, `Length3` keys:

```
Length1  clear-text PostScript header, ending after "currentfile eexec\n"
Length2  binary eexec-encrypted section (CharStrings, Private dict, …)
Length3  zero-padding + "cleartomark" trailer
```

The boundary between Length1 and Length2 is located by scanning for
`"currentfile eexec"` and then skipping the line terminator (which may be
`\r`, `\n`, or `\r\n`).  The boundary between Length2 and Length3 is
located by searching backwards from `"cleartomark"` over all `0`, `\r`, and
`\n` bytes.

## Font Subsetting

Embedding a complete Type1 font for a document that uses only a few dozen
glyphs wastes space.  After the full document has been transpiled each
embedded font is subsetted to include only the glyphs that were actually
output.

### Glyph tracking

The transpiler maintains two parallel maps indexed by document font index:

- `used_chars` — a `[256]bool` array recording every byte value sent to the
  PDF text stream for that font (updated by `trackBytes` on every `t`, `u`,
  and `C` command).
- `embedded_font_data` — the original `Type1FontData` parsed from disk.

### Subsetting algorithm (`groff.subsetType1Font`)

1. **Build needed-glyph set** — convert each used byte code to a PostScript
   glyph name via `glyphNameForByte`, which first checks the
   `/Differences [150 /endash /emdash]` override and then falls back to
   Adobe StandardEncoding.  `.notdef` is always included.

2. **Decrypt eexec section** — the encrypted section is decrypted with the
   eexec cipher (`r=55665`, `c1=52845`, `c2=22719`; `plain[i] = cipher[i] XOR (r>>8)`,
   `r = (cipher[i] + r) * c1 + c2 mod 65536`).  The first four decrypted
   bytes are the random seed and are discarded.

3. **Parse CharStrings** — the decrypted plaintext is scanned for the
   `/CharStrings N dict dup begin` block.  Each entry has the form:
   ```
   /name count RD <count binary bytes> ND\n
   ```
   where `RD` may also appear as `-|` and `ND` as `|-` depending on the font.
   The operator names are auto-detected from the Private dict preamble.

4. **Rebuild plaintext** — a new plaintext is assembled from:
   - everything before `/CharStrings` (Private dict, subroutines, etc.)
   - a new `/CharStrings K dict dup begin` header with the reduced count K
   - only the glyph entries whose names appear in the needed set
   - `end\n`
   - everything after the original CharStrings `end`

5. **Re-encrypt** — the new plaintext is re-encrypted with the eexec cipher,
   prepending four null seed bytes (encrypting `0x00` four times with the
   initial register value produces a deterministic four-byte prefix).

6. **Reassemble** — the original clear-text header (Length1 bytes) and the
   original trailer (Length3 bytes) are concatenated with the new encrypted
   section to produce the subsetted font file.

Typical subsetting ratios for the demo document:

| Font                  | Original  | Subsetted | Glyphs kept |
|-----------------------|-----------|-----------|-------------|
| NimbusRoman-Regular   | 133 527 B |  10 442 B | 55 / 855    |
| NimbusRoman-Bold      | 133 004 B |   6 837 B | 30 / 855    |
| NimbusRoman-Italic    | 142 085 B |   4 186 B | 11 / 855    |
| NimbusMonoPS-Regular  | 140 353 B |   9 181 B | 45 / 855    |

## Stream Compression

All PDF streams — page content streams and font file streams — are compressed
with zlib (FlateDecode) before being written.  This is indicated by adding
`/Filter /FlateDecode` to the stream dictionary, with `/Length` set to the
compressed byte count.

For embedded fonts the `Length1`, `Length2`, `Length3` keys describe the
**uncompressed** byte layout of the decoded font data, as required by the PDF
specification (§3.3, "Embedded Font Programs").

Compression is performed by `pdf.zlibCompress` using the system `libz`
(`compress2` at level 6).  The Zig 0.15.2 standard library ships an
incomplete flate compressor (`std.compress.flate.Compress`) whose
`BlockWriter` references fields that do not exist in the current API; it
cannot be used.  Linking system libz (`exe.linkSystemLibrary("z")`) is
therefore required in `build.zig`.

Typical compression ratios:

| Stream type           | Uncompressed | Compressed | Reduction |
|-----------------------|-------------|------------|-----------|
| Page content (text)   | ~11 000 B   | ~2 750 B   | ~75 %     |
| Embedded font (clear-text header) | ~3 000 B | ~1 000 B | ~65 % |
| Embedded font (encrypted eexec)   | ~7 000 B | ~6 200 B |  ~10 % |

The encrypted eexec section compresses poorly because the eexec cipher
produces pseudo-random output.

## File Size Comparison

For the three-page demo document (`input.mom`):

| Configuration                          | File size |
|----------------------------------------|-----------|
| `groff -Tpdf` (standard fonts, FlateDecode) | 7.8 KB |
| gropdf.zig standard fonts, FlateDecode | 9.8 KB    |
| gropdf.zig embedded fonts, FlateDecode | 44 KB     |
| gropdf.zig embedded fonts, uncompressed | 72 KB    |

The remaining ~2 KB gap between gropdf.zig and native groff is due to the
explicit `/Encoding` dictionary that gropdf.zig adds to every font (groff
uses a more compact per-font `/Differences`-only encoding object and packs
all font metadata into a single compressed `/Type /ObjStm` object stream).
