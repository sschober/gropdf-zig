# A groff PDF device written in zig

The original UNIX typesetting software `roff` (from 'runoff') has a GNU
implementation called `groff`, which you will very likely have installed on
your system if you use MacOS, a Linux distribution, or Windows with MinGW or
WSL. It is used today mainly to typeset man pages in the terminal, but actually
it's much more powerful. Using macro packages like, `ms` or `mom`, you can
produce beautifully typeset documents in `dvi`, `ps` or `pdf` format.

To produce the mentioned output formats `groff` uses so called devices. These
devices encapsulate the implementation details for producing a format and
decouple this logic from the rest of `groff`'s functionality. The front-end
talks to the device in a language called `groff_out(5)` (`grout` for short).

I was happily using the PDF output device, `gropdf.pl` for quite some time now,
but its implementation language `perl` always gave my an itch. Not, that I
don't like `perl` - I've written my fair share in it in the past - it's just
not the first language I would think of, when thinking about speed.

Motivated by the approachability of `gropdf.pl` (
[sources](https://cgit.git.savannah.gnu.org/cgit/groff.git/tree/src/devices/gropdf/gropdf.pl), 
[man page](https://man7.org/linux/man-pages/man1/gropdf.1.html)
and the PDF spec, or to be exact, adobe's 
[pdf reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf), I started this little experiment to see
if I could implement a reasonable subset of `groff_out(5)`.

> [!WARNING]
> This is **very experimental** software. No guarantee is provided, that it will
> produce sensible output, will not crash and or stay stable in its behaviour.

At the moment, we implement a small subset of the `grout` language only:

* We support only a single font, "Times New Roman", as that can be referenced very
easily in PDF, without the need to embed it.
* No drawing commands are interpreted.

The resulting PDF has some, let's call them inefficiencies. A lot of similar
commands are issued in sequence, which could be compacted. As a lot of this is
already present in the input, I chose to ignore it at the moment.

We could reduce the resulting PDF file size by using zflate compression, but at
the moment I do not see any need for this.

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

and inspect it, using any PDF viewer. On macos this might be:

```bash
$ open sample-out.pdf
```

### Pipelines

You can also avoid the intermediate file and issue a pipeline command:

```bash
$ groff -Tpdf -Z -mom input.mom | ./zig-out/bin/gropdf_zig > sample-out.pdf
```


## Performance

Currently, the performance looks promising:

```bash
$ termgraph measures.lst

gropdf.pl     : ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇ 185.00
gropdf_zig    : ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇ 101.00
gropdf_zig_rel: ▇▇ 9.00
```

Seems like a factor of `2` quicker for debug builds and a factor of about `20`
for release builds!

The release binary is only `42k` on linux, which I find quite impressive:

```bash
$ ls zig-out/bin/
Permissions Size User Date Modified Name
.rwxr-xr-x   42k sven 25 Oct 16:57  󰡯 gropdf_zig
```

