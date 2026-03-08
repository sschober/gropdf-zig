# Using gropdf-zig with groff

`gropdf-zig` is a PDF output device for [GNU roff (groff)](https://www.gnu.org/software/groff/).
It reads groff's intermediate output language (`grout`) from stdin and writes a PDF to stdout,
acting as a faster drop-in replacement for the built-in `gropdf.pl` Perl device.

## How it fits into the groff pipeline

groff works in two stages:

```
source file  →  groff front-end  →  grout  →  output device  →  PDF
```

Normally `groff -Tpdf` runs both stages in one go using `gropdf.pl` as the device.
To use `gropdf-zig` instead, you split the pipeline at the `grout` stage using groff's
`-Z` flag, which tells groff to emit `grout` rather than calling any device itself.

## Building

```bash
zig build                    # debug build  (~100 ms, for development)
zig build -Doptimize=ReleaseFast   # release build (~9 ms, ~42 KB binary)
```

The binary ends up at `zig-out/bin/gropdf_zig`.

## Basic usage

### One-shot pipeline (recommended)

Pipe groff's intermediate output directly into `gropdf-zig`:

```bash
groff -Tpdf -Z -mom input.mom | ./zig-out/bin/gropdf_zig > output.pdf
```

The `-Tpdf` flag tells groff to use its PDF device settings (paper size, font paths, etc.)
while `-Z` stops it from actually running the device, emitting `grout` to stdout instead.
`gropdf-zig` then takes over and writes the PDF.

### Via an intermediate file

Useful when you want to inspect the `grout` output or re-render without re-running groff:

```bash
# Step 1: produce the grout intermediate file
groff -Tpdf -Z -mom input.mom > input.grout

# Step 2: render to PDF
./zig-out/bin/gropdf_zig < input.grout > output.pdf
```

### During development (using `zig build run`)

```bash
zig build run < input.grout > output.pdf
```

## Macro packages

`gropdf-zig` works with any groff macro package — the choice of macro package
affects only what groff emits, not how the device processes it.

| Package | Flag       | Good for                        |
|---------|------------|---------------------------------|
| `mom`   | `-mom`     | General documents, books        |
| `ms`    | `-ms`      | Traditional academic papers     |
| `me`    | `-me`      | Classic Unix documents          |
| `man`   | `-man`     | Man pages                       |

Example with `ms`:

```bash
groff -Tpdf -Z -ms paper.ms | ./zig-out/bin/gropdf_zig > paper.pdf
```

## Paper size

Pass the paper size through groff's `-d` option or set it in your source file.
With `mom`, for example:

```groff
.PAPER A4
```

or on the command line:

```bash
groff -Tpdf -Z -dpaper=a4 -P-pa4 -ms paper.ms | ./zig-out/bin/gropdf_zig > paper.pdf
```

`gropdf-zig` reads the paper dimensions from the `x X papersize=…` command in the
`grout` stream and applies them automatically.

## Command-line flags

```
-d          Enable debug output (written to stderr)
-w          Enable warning output (written to stderr)
-h, --help  Show help and exit
```

Debug mode is useful for tracing how grout commands are being interpreted:

```bash
groff -Tpdf -Z -mom input.mom | ./zig-out/bin/gropdf_zig -w 2>warnings.txt > output.pdf
```

## Supported grout commands

`gropdf-zig` currently implements a practical subset of `groff_out(5)`:

| Command | Description                        |
|---------|------------------------------------|
| `t`     | Typeset word                       |
| `u`     | Typeset word with track kerning    |
| `C`     | Typeset special glyph (ligatures, dashes, quotes, …) |
| `f`     | Select font                        |
| `s`     | Set type size                      |
| `H`     | Set horizontal position (absolute) |
| `V`     | Set vertical position (absolute)   |
| `h`     | Move horizontal (relative)         |
| `v`     | Move vertical (relative)           |
| `p`     | Begin new page                     |
| `n`     | New line                           |
| `w`     | Inter-word space                   |
| `m`     | Set stroke/fill colour (r, d)      |
| `Dl`    | Draw line                          |
| `Dt`    | Set line thickness                 |
| `DFd`   | Filled polygon (default colour)    |
| `DFr`   | Filled polygon (RGB colour)        |
| `x T`   | Device type check                  |
| `x res` | Set resolution / unit scale        |
| `x init`| Begin document                     |
| `x font`| Mount font                         |
| `x X`   | Escape channel (paper size, etc.)  |

Unknown commands produce a warning on stderr (with `-w`) and are skipped rather
than crashing — so documents using unsupported features still render partially.

## Supported fonts

The 14 standard PDF fonts are supported without embedding:

| groff name | PDF font                |
|------------|-------------------------|
| `TR`       | Times Roman             |
| `TB`       | Times Bold              |
| `TI`       | Times Italic            |
| `TBI`      | Times Bold Italic       |
| `HR` / `H` | Helvetica               |
| `HB`       | Helvetica Bold          |
| `HI`       | Helvetica Oblique       |
| `HBI`      | Helvetica Bold Oblique  |
| `CR`       | Courier                 |
| `CB`       | Courier Bold            |
| `CI`       | Courier Oblique         |
| `CBI`      | Courier Bold Oblique    |
| `S`        | Symbol                  |
| `ZD`       | Zapf Dingbats           |

Fonts not in this list fall back gracefully with a warning.

## Viewing the output

On **macOS**:
```bash
open output.pdf
```

On **Linux** (most desktops):
```bash
xdg-open output.pdf
# or directly:
evince output.pdf
zathura output.pdf
```

## Comparing with the built-in device

To compare `gropdf-zig`'s output against the standard `gropdf.pl`:

```bash
# Standard device
groff -Tpdf -mom input.mom > orig.pdf

# gropdf-zig
groff -Tpdf -Z -mom input.mom | ./zig-out/bin/gropdf_zig > ours.pdf

# Side-by-side in a viewer that supports it, e.g. diffpdf
diffpdf orig.pdf ours.pdf
```

## Performance

Release builds are roughly 20× faster than `gropdf.pl` and produce a ~42 KB binary:

```
gropdf.pl       185 ms
gropdf-zig      101 ms  (debug build)
gropdf-zig        9 ms  (release build)
```

## Troubleshooting

**No output / empty PDF**
- Make sure you passed `-Z` to groff. Without it, groff runs its own device and
  produces no `grout` for `gropdf-zig` to read.
- Check that `-Tpdf` is also present so groff uses PDF-appropriate settings.

**Font not found warning**
- `gropdf-zig` reads glyph widths from groff's font description files under
  `/usr/share/groff/current/font/devpdf/` (or the equivalent path on your system).
  Make sure groff is installed and that path exists.

**Garbled positions / text overlap**
- Run with `-w` to see any positioning warnings. This often points to an unsupported
  grout command being silently skipped.

**Debug the grout stream itself**
- Inspect `input.grout` directly — it is plain text and each line is one command.
  Cross-reference with `man groff_out` for the full language reference.

## Further reading

- [`groff_out(5)` man page](https://man7.org/linux/man-pages/man5/groff_out.5.html) — the full `grout` language specification
- [`gropdf(1)` man page](https://man7.org/linux/man-pages/man1/gropdf.1.html) — the reference Perl implementation
- [Adobe PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf) — underlying PDF spec
- `dev-diary.md` in this repo — design notes and implementation decisions
