# PDF Image Embedding (pdfpic)

This document describes how `gropdf-zig` handles the `pdfpic` grout extension
command, which embeds a PDF image into the output document.

## groff side: the `pdfpic` macro

In groff source files the `.pdfpic` macro (from `pdfpic.tmac`) places a PDF
image at the current position:

```groff
.pdfpic [-L|-C|-R] filename [width [height]]
```

groff compiles this to a device-control escape in the grout intermediate
output:

```
x X pdf: pdfpic <file> [-L|-C|-R] <width>z <height>z
```

`gropdf-zig` intercepts this `x X pdf:` command and handles it natively.

## What gropdf-zig does

When the transpiler encounters `x X pdf: pdfpic`, it:

1. Reads the target PDF file from disk (`pdf_reader.embedFirstPage`).
2. Parses the file's cross-reference table to locate the first page.
3. Copies the page's content stream and all referenced resource objects
   (fonts, images, color spaces, …) into the output document as new
   indirect objects, renumbering their object references to avoid
   collisions.
4. Wraps the content stream in a **Form XObject** (`/Type /XObject
   /Subtype /Form`) whose `/BBox` matches the source page's `/MediaBox`.
5. Registers the Form XObject on the current output page and emits a
   `cm` + `Do` operator pair that scales and positions it to the
   requested `<width>` × `<height>` at the current graphic cursor
   position.

The alignment flags `-L`, `-C`, `-R` are accepted and consumed for
compatibility but currently ignored (the image is always placed at the
current horizontal position as set by groff).

## PDF cross-reference support

The reader (`src/pdf_reader.zig`) handles two xref formats:

| Format | PDF version | Description |
|--------|-------------|-------------|
| Traditional xref table | PDF 1.0–1.4 | Plain-text `xref` section followed by a `trailer` dictionary. |
| Cross-reference stream | PDF 1.5+ | A compressed stream object at the `startxref` offset with `/Type /XRef`. Entry types 0 (free), 1 (byte offset), and 2 (object stream) are all handled. |

For cross-reference streams the reader also resolves **object streams**
(`/Type /ObjStm`): objects stored inside a compressed container stream
(type-2 xref entries) are decompressed, extracted into a synthetic
in-memory buffer, and then processed identically to regular objects.
This covers PDF files produced by tools such as cairo, LibreOffice, and
recent versions of Ghostscript.

## Limitations

- Only the **first page** of the source PDF is embedded, regardless of
  how many pages it contains.
- **Encrypted** PDF files are not supported.
- Object streams that are themselves referenced via `/Extends` (chained
  object streams) are not followed.
- Only `FlateDecode` (zlib) streams are decompressed; other filters
  (`LZWDecode`, `ASCII85Decode`, …) are passed through as-is and will
  likely produce malformed output.

## Implementation files

| File | Role |
|------|------|
| `src/pdf_reader.zig` | Parses the source PDF and copies its objects into the output `pdf.Document`. |
| `src/Transpiler.zig` | `handle_pdfpic` — parses the grout command, calls `pdf_reader.embedFirstPage`, and emits the `cm`/`Do` operators. |
| `src/pdf.zig` | `Document.addXObjectTo`, `GraphicalObject.placeXObject` — low-level PDF object model used by the transpiler. |
