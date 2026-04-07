#!/usr/bin/env bash
# test_font_visibility.sh — end-to-end font visibility test for gropdf-zig
#
# For each font installed by mato-install-fonts.sh this script:
#   1. Generates a minimal grout file that uses that font and contains
#      umlaut / Latin-1 accented characters.
#   2. Processes it through gropdf-zig to produce a PDF.
#   3. Calls check_pdf_glyphs.py, which decrypts the embedded Type1 font's
#      eexec section and verifies the umlaut glyphs are actually present in
#      the embedded CharStrings (not just that the encoding points to them).
#
# Prerequisites:
#   - zig build already run  (or set GROPDF_BIN=/path/to/binary)
#   - groff in PATH
#   - python3 in PATH  (stdlib only, no extra packages)
#
# Usage:
#   cd /path/to/gropdf-zig
#   tests/test_font_visibility.sh
#
# Exit code: 0 = all tested fonts pass, 1 = at least one failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GROPDF_BIN="${GROPDF_BIN:-$REPO_DIR/zig-out/bin/gropdf_zig}"
CHECK_PY="$SCRIPT_DIR/check_pdf_glyphs.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UMLAUTS=(adieresis odieresis udieresis Adieresis Odieresis Udieresis germandbls)

# ── helpers ───────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }

# make_grout FONTNAME OUTFILE
# Create a minimal grout intermediate file that loads FONTNAME and
# outputs the full alphabet plus umlaut/Latin-1 special characters.
# Returns 1 (non-zero) if the font is not installed (groff falls back).
make_grout() {
    local font="$1" out="$2"

    # Build a tiny mom document that explicitly selects the font via .ft.
    # Using named-character escapes (\[adieresis] etc.) avoids needing -k.
    cat > "$WORK/${font}.mom" <<'MOM'
.DOCTYPE DEFAULT
.TITLE "Umlaut test"
.PRINTSTYLE TYPESET
.PAPER A5
.PT_SIZE 12
.START
MOM
    # Append font-specific lines (can't easily use heredoc with variable).
    printf '.ft %s\n' "$font" >> "$WORK/${font}.mom"
    cat >> "$WORK/${font}.mom" <<'MOM'
.nf
ABCDEFGHIJKLMNOPQRSTUVWXYZ
abcdefghijklmnopqrstuvwxyz
0 1 2 3 4 5 6 7 8 9
\[Adieresis] \[Odieresis] \[Udieresis] \[adieresis] \[odieresis] \[udieresis] \[ss]
\[Agrave] \[Aacute] \[Acircumflex] \[Atilde] \[Aring] \[AElig] \[Ccedilla]
\[Egrave] \[Eacute] \[Ecircumflex] \[Edieresis]
\[Igrave] \[Iacute] \[Icircumflex] \[Idieresis]
\[ETH] \[Ntilde] \[Ograve] \[Oacute] \[Ocircumflex] \[Otilde] \[Oslash]
\[Ugrave] \[Uacute] \[Ucircumflex] \[Yacute] \[THORN]
\[agrave] \[aacute] \[acircumflex] \[atilde] \[aring] \[aelig] \[ccedilla]
\[egrave] \[eacute] \[ecircumflex] \[edieresis]
\[igrave] \[iacute] \[icircumflex] \[idieresis]
\[eth] \[ntilde] \[ograve] \[oacute] \[ocircumflex] \[otilde] \[oslash]
\[ugrave] \[uacute] \[ucircumflex] \[yacute] \[thorn] \[ydieresis]
.fi
MOM

    # Run groff to get the intermediate output.
    groff -Tpdf -Z -mom "$WORK/${font}.mom" > "$out" 2>/dev/null || true

    # groff falls back silently when a font is missing; detect by checking
    # whether the font name appears in an 'x font' mount command.
    if ! grep -qF "x font" "$out" 2>/dev/null; then
        return 1
    fi
    if ! grep -qF "$font" "$out" 2>/dev/null; then
        return 1   # font not found — groff used a fallback
    fi
    return 0
}

# test_font FONTNAME → 0 (pass), 1 (fail), 2 (skip)
test_font() {
    local font="$1"
    local grout="$WORK/${font}.grout"
    local pdf="$WORK/${font}.pdf"

    echo ""
    printf '── %-30s ' "$font"

    # Step 1: generate grout.
    if ! make_grout "$font" "$grout"; then
        echo "(SKIP — font not installed)"
        return 2
    fi
    echo ""

    # Step 2: gropdf-zig → PDF.
    if ! "$GROPDF_BIN" < "$grout" > "$pdf" 2>/tmp/gropdf_err; then
        echo "  FAIL: gropdf_zig error:"
        cat /tmp/gropdf_err >&2
        return 1
    fi
    if [[ ! -s "$pdf" ]]; then
        echo "  FAIL: empty PDF output"
        return 1
    fi
    printf '  PDF: %d bytes\n' "$(wc -c < "$pdf")"

    # Step 3: verify glyph presence.
    if python3 "$CHECK_PY" "$pdf" "${UMLAUTS[@]}"; then
        return 0
    else
        return 1
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────

# Sanity checks.
[[ -x "$GROPDF_BIN" ]] || die "gropdf_zig not found at $GROPDF_BIN (run 'zig build' first)"
command -v groff  >/dev/null || die "groff not found in PATH"
command -v python3 >/dev/null || die "python3 not found in PATH"

echo "gropdf-zig font visibility test"
echo "  binary : $GROPDF_BIN"
echo "  workdir: $WORK"
echo ""

# All font variants from mato-install-fonts.sh.
FONTS=(
    AlegreyaR AlegreyaI AlegreyaB AlegreyaBI
    GrenzeGothischR GrenzeGothischI GrenzeGothischB GrenzeGothischBI
    MinionR    MinionI    MinionB    MinionBI
    IosevkaCurlySlabR IosevkaCurlySlabI IosevkaCurlySlabB IosevkaCurlySlabBI
)

PASS=0 FAIL=0 SKIP=0
FAILED_FONTS=()

for font in "${FONTS[@]}"; do
    rc=0
    test_font "$font" || rc=$?
    case $rc in
        0) (( PASS++ )) ;;
        2) (( SKIP++ )) ;;
        *) (( FAIL++ )); FAILED_FONTS+=("$font") ;;
    esac
done

echo ""
echo "════════════════════════════════════════"
printf 'Passed: %d  Skipped: %d  Failed: %d\n' "$PASS" "$SKIP" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
    echo "Failed fonts: ${FAILED_FONTS[*]}"
    exit 1
fi
if [[ $PASS -eq 0 ]]; then
    echo "WARNING: no fonts were tested (none installed)"
    exit 1
fi
echo "OK"
exit 0
