# A groff PDF device in zig

Motivated by the approachability of `gropdf.pl` and the PDF spec,
or to be exact, adobe's [pdf reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf), I started this little experiment to see
if I could implement a reasonable subset of `groff_out(5)`.

At the moment, all this implementation does is print a PDF with
a classic "Hello World!" message. It does not yet read or interpret
any `grout`.

My `zig` skills are, let's say, "developing".

## Usage

```bash
$ zig build run > sample-out.pdf
$ open sample-out.pdf
```
