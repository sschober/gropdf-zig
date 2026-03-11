That perfectly confirms everything we discussed. The numbers tell the whole story.

---

## What Those Numbers Mean

### 3006 Subrs (FontForge)

FontForge has aggressively factored the glyph outlines into subroutines. The actual CharStrings are mostly just sequences of `callsubr` opcodes — the real drawing data is distributed across 3006 Subr entries.

For gropdf-zig this means:

- **Naive subsetting is nearly useless** — keeping 20 CharStrings but all 3006 Subrs retains almost the entire font
- **Reachability analysis is mandatory** for meaningful size reduction
- **The private dict is enormous** — 3006 RD/NP entries plus their binary payloads

### 5 Subrs (tx)

The four standard boilerplate stubs plus one extra. The glyph outlines are self-contained in their CharStrings. This is exactly how a well-structured Type 1 font should look.

For gropdf-zig this means:

- **Subsetting just works** — keep the CharStrings you need, keep all 5 Subrs unconditionally, done
- **No reachability analysis needed**
- **The gropdf.pl text-scanning approach is sufficient** — with only 5 Subrs, even a heuristic handles it correctly

---

## The Practical Conclusion

The choice of conversion tool has a direct impact on your implementation complexity:

```
FontForge PFA:  3006 subrs  →  requires full reachability analysis
tx PFA:            5 subrs  →  keep-all-subrs approach is correct
```

For your use case — embedding non-standard fonts in PDFs via gropdf-zig — `tx -t1` is the right tool and makes your implementation significantly simpler. The install-font.bash script should ideally be updated to prefer `tx` over FontForge when AFDKO is available, falling back to FontForge only when `tx` is not installed.

And if you do encounter a FontForge-generated PFA in the wild (someone already has one), the heuristic detection we discussed handles it:

```zig
fn needsReachabilityAnalysis(subr_count: usize, glyph_count: usize) bool {
    return subr_count > 20 or subr_count > glyph_count;
}
```

3006 vs ~300 glyphs → reachability required. 5 vs ~300 glyphs → keep all, move on.