# A groff PDF device in zig

Motivated by the approachability of `gropdf.pl` and the PDF spec,
or to be exact, adobe's [pdf reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf), I started this little experiment to see
if I could implement a reasonable subset of `groff_out(5)`.

## Usage

I provide a sample input file, `input.mom`, which contains `groff` source
code using the `mom` package.

This input file can be rendered to a PDF using the following `groff` command:

```bash
groff -Tpdf -mom input.mom > orig.pdf
```

This is using the vanilla pdf device `gropdf.pl`, which comes with `groff`.

As our device needs `grout` as input language, we need to get to it using the
following command:

```bash
groff -Tpdf -Z -mom input.mom > input.grout
```

Then, we can render it 

```bash
$ zig build run < input.grout > sample-out.pdf
```

and inspect it, using any PDF viewer. On mac os this might be:

```bash
$ open sample-out.pdf
```
