# A groff PDF device in zig

Motivated by the approachability of `gropdf.pl` and the PDF spec,
or to be exact, adobe's [pdf reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf), I started this little experiment to see
if I could implement a reasonable subset of `groff_out(5)`.

At the moment, we implement a small subset of the `grout` language only:

* We support only a single font, "Times New Roman", as that can be referenced very
easily in PDF, without the need to embed it.
* No drawing commands are interpreted.

The resulting PDF has some, let's call them inefficiencies. A lot of similar commands
are issued in sequence, which could be compacted. As a lot of this is already present
in the input, I chose to ignore it at the moment.

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

## Performance

Currently, the performance looks promising:

```bash
$ time ./zig-out/bin/gropdf_zig < input.grout > sample-out.pdf
...
________________________________________________________
Executed in   17.63 millis    fish           external
   usr time    7.26 millis    0.14 millis    7.11 millis
   sys time    6.84 millis    1.28 millis    5.56 millis
```

`17.63ms` vs about `700ms` with the `perl` implementation is looking good.
