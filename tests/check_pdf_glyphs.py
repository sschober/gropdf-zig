#!/usr/bin/env python3
"""
check_pdf_glyphs.py — Verify glyph presence in embedded Type1 fonts.

For each font embedded in the PDF:
  1. Decompress the /FontFile stream (FlateDecode).
  2. Locate the Type1 eexec-encrypted section (PFA: hex-encoded; PFB: binary).
  3. Decrypt with the standard eexec algorithm (key=55665, c1=52845, c2=22719).
  4. Search the decrypted text for /glyphname patterns in CharStrings.
  5. Also parse /Encoding /Differences to check byte→glyph mapping.

Exit code:
  0 — all requested glyphs found in all checked fonts
  1 — one or more glyphs missing

Usage:
  python3 check_pdf_glyphs.py <pdf> [glyph ...]

If no glyphs are given, defaults to the seven German umlaut glyphs:
  adieresis odieresis udieresis Adieresis Odieresis Udieresis germandbls
"""

import re
import sys
import zlib


# ── Type1 eexec decryption ────────────────────────────────────────────────────

def _eexec_decrypt(data: bytes) -> bytes:
    """Decrypt a block of Type1 eexec binary data."""
    key = 55665
    result = bytearray(len(data))
    for i, b in enumerate(data):
        result[i] = b ^ (key >> 8)
        key = ((b + key) * 52845 + 22719) & 0xffff
    # First 4 bytes are a random seed; skip them.
    return bytes(result[4:])


def _pfa_cleartext_and_eexec(font_data: bytes):
    """Split a PFA font into (cleartext, decrypted_eexec).  Returns (bytes, bytes|None)."""
    marker = b'currentfile eexec'
    idx = font_data.find(marker)
    if idx == -1:
        return font_data, None
    cleartext = font_data[:idx]
    idx += len(marker)
    # Skip one whitespace character (the newline after 'eexec').
    if idx < len(font_data) and font_data[idx] in b' \t\r\n':
        idx += 1
    # The eexec section ends at 'cleartomark'; restrict the search window so
    # that the 'c' in 'cleartomark' is never mistaken for a hex nibble.
    cm = font_data.find(b'cleartomark', idx)
    section = font_data[idx:cm] if cm != -1 else font_data[idx:]
    # Collect ASCII hex digits; whitespace between digit pairs is ignored.
    hex_chars = bytearray()
    for b in section:
        if b in b'0123456789abcdefABCDEF':
            hex_chars.append(b)
        elif b not in b' \t\r\n':
            break  # unexpected non-hex character — stop
    if len(hex_chars) % 2:
        hex_chars = hex_chars[:-1]  # trim stray trailing nibble
    if not hex_chars:
        return cleartext, None
    try:
        encrypted = bytes.fromhex(hex_chars.decode('ascii'))
    except ValueError:
        return cleartext, None
    return cleartext, _eexec_decrypt(encrypted)


def _pfb_cleartext_and_eexec(font_data: bytes):
    """Split a PFB font into (cleartext, decrypted_eexec).  Returns (bytes, bytes|None)."""
    i = 0
    cleartext = bytearray()
    eexec = None
    while i + 6 <= len(font_data):
        if font_data[i] != 0x80:
            break
        seg_type = font_data[i + 1]
        if seg_type == 3:
            break
        length = int.from_bytes(font_data[i + 2:i + 6], 'little')
        segment = font_data[i + 6:i + 6 + length]
        if seg_type == 1:
            cleartext.extend(segment)
        elif seg_type == 2:
            eexec = _eexec_decrypt(segment)
        i += 6 + length
    return bytes(cleartext), eexec


def _charstring_glyph_names(decrypted: bytes) -> set:
    """Return the set of glyph names defined in a decrypted CharStrings section."""
    # After eexec decryption the CharStrings block looks like:
    #   /glyphname N RD <binary> ND
    # or the older:
    #   /glyphname N -| <binary> |-
    pattern = re.compile(rb'/([A-Za-z][A-Za-z0-9._-]*)\s+\d+\s+(?:RD|-\|)')
    return {m.group(1).decode('ascii', errors='replace')
            for m in pattern.finditer(decrypted)}


# ── PDF object / stream helpers ───────────────────────────────────────────────

def _find_objects(pdf: bytes) -> dict:
    """Map object number → byte offset for every indirect object."""
    return {int(m.group(1)): m.start()
            for m in re.finditer(rb'(\d+)\s+0\s+obj\b', pdf)}


def _object_bytes(pdf: bytes, offset: int) -> bytes:
    """Return the raw bytes of one indirect object starting at *offset*."""
    end = re.search(rb'\bendobj\b', pdf[offset:])
    return pdf[offset:offset + end.end()] if end else pdf[offset:]


def _resolve_ref(pdf: bytes, objects: dict, ref_num: int) -> bytes:
    """Return the bytes of the indirect object referenced by *ref_num*."""
    offset = objects.get(ref_num)
    if offset is None:
        return b''
    return _object_bytes(pdf, offset)


def _stream_data(obj_bytes: bytes) -> bytes | None:
    """Decompress and return the stream payload of a PDF stream object."""
    m = re.search(rb'stream\r?\n', obj_bytes)
    if not m:
        return None
    # Resolve /Length (only handles direct integer, not indirect ref).
    lm = re.search(rb'/Length\s+(\d+)', obj_bytes[:m.start()])
    if not lm:
        return None
    length = int(lm.group(1))
    raw = obj_bytes[m.end():m.end() + length]
    if b'/FlateDecode' in obj_bytes[:m.start()]:
        try:
            return zlib.decompress(raw)
        except zlib.error:
            return raw
    return raw


# ── /Encoding /Differences parser ────────────────────────────────────────────

def _encoding_differences(obj_bytes: bytes) -> dict:
    """Parse /Encoding << … /Differences [ … ] >> and return {byte_pos: glyph_name}."""
    enc_m = re.search(rb'/Encoding\s*<<([^>]*(?:>[^>][^>]*)*)>>', obj_bytes, re.DOTALL)
    if not enc_m:
        # Fallback: might be a ref.  Skip — we check via the dict key directly.
        diffs_m = re.search(rb'/Differences\s*\[([^\]]*)\]', obj_bytes, re.DOTALL)
    else:
        diffs_m = re.search(rb'/Differences\s*\[([^\]]*)\]', enc_m.group(1), re.DOTALL)
    if not diffs_m:
        return {}
    result = {}
    pos = None
    for tok in re.finditer(rb'(\d+)|(/[A-Za-z][A-Za-z0-9._-]*)', diffs_m.group(1)):
        s = tok.group()
        if s[0:1].isdigit():
            pos = int(s)
        elif pos is not None:
            result[pos] = s[1:].decode('ascii')
            pos += 1
    return result


# ── Main logic ────────────────────────────────────────────────────────────────

_DEFAULT_GLYPHS = [
    'adieresis', 'odieresis', 'udieresis',
    'Adieresis', 'Odieresis', 'Udieresis',
    'germandbls',
]


def check(pdf_path: str, wanted: list[str]) -> bool:
    """
    Check *pdf_path* for all *wanted* glyph names.
    Prints a report and returns True if every glyph was found.
    """
    with open(pdf_path, 'rb') as f:
        pdf = f.read()

    objects = _find_objects(pdf)
    all_ok = True

    # Find every object that contains /FontFile (Type1 embedded font).
    font_file_refs = {}   # font_name → (ff_obj_num, font_obj_bytes)
    for num, offset in objects.items():
        ob = _object_bytes(pdf, offset)
        # FontDescriptor has /FontFile <N> 0 R
        m = re.search(rb'/FontFile\s+(\d+)\s+0\s+R', ob)
        if not m:
            continue
        ff_num = int(m.group(1))
        name_m = re.search(rb'/FontName\s*/([^\s/\[<(]+)', ob)
        font_name = name_m.group(1).decode('ascii', errors='replace') if name_m else f'obj{num}'
        font_file_refs[font_name] = (ff_num, ob)

    if not font_file_refs:
        print('  [!] No embedded Type1 fonts (/FontFile) found.')
        return False

    for font_name, (ff_num, desc_bytes) in sorted(font_file_refs.items()):
        print(f'\n  Font: {font_name}')

        # ── /Encoding /Differences check ──────────────────────────────────────
        # The Font dict (not FontDescriptor) holds /Encoding.
        # Find the Font object that references this FontDescriptor.
        enc_diffs: dict = {}
        for num, offset in objects.items():
            ob = _object_bytes(pdf, offset)
            if (f'/FontDescriptor {ff_num} 0 R').encode() in ob and b'/Differences' in ob:
                enc_diffs = _encoding_differences(ob)
                break
            if b'/Differences' in ob and b'/Subtype /Type1' in ob:
                enc_diffs = _encoding_differences(ob)
                # Don't break — keep looking for a better match.

        if enc_diffs:
            # Build reverse map: glyph_name → [byte_positions]
            rev: dict[str, list[int]] = {}
            for pos, gname in enc_diffs.items():
                rev.setdefault(gname, []).append(pos)
            print('    /Encoding /Differences:')
            for g in wanted:
                positions = rev.get(g)
                if positions:
                    print(f'      OK  /{g} → byte(s) {positions}')
                else:
                    print(f'      --  /{g} not in /Differences')
        else:
            print('    /Encoding /Differences: (not found in this scope)')

        # ── CharStrings check via eexec decryption ───────────────────────────
        ff_bytes = _resolve_ref(pdf, objects, ff_num)
        font_data = _stream_data(ff_bytes)
        if font_data is None:
            print('    [!] Could not extract font stream data.')
            all_ok = False
            continue

        # Detect PFB (starts 0x80) vs PFA (starts %!)
        if font_data[:2] == b'\x80\x01':
            cleartext, decrypted = _pfb_cleartext_and_eexec(font_data)
        else:
            cleartext, decrypted = _pfa_cleartext_and_eexec(font_data)

        if decrypted is None:
            print('    [!] Could not decrypt eexec section.')
            all_ok = False
            continue

        glyph_names = _charstring_glyph_names(decrypted)
        print(f'    CharStrings ({len(glyph_names)} glyphs embedded):')
        font_ok = True
        for g in wanted:
            if g in glyph_names:
                print(f'      OK  /{g}')
            else:
                print(f'      MISSING /{g}  ← glyph not in embedded font!')
                font_ok = False
                all_ok = False
        if font_ok:
            print(f'      All {len(wanted)} glyph(s) present.')

    return all_ok


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <pdf-file> [glyph ...]', file=sys.stderr)
        sys.exit(1)
    pdf_path = sys.argv[1]
    wanted = sys.argv[2:] if len(sys.argv) > 2 else _DEFAULT_GLYPHS
    print(f'Checking: {pdf_path}')
    print(f'Glyphs:   {", ".join(wanted)}')
    ok = check(pdf_path, wanted)
    print()
    print('Result: PASS' if ok else 'Result: FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
