#!/usr/bin/env python3
"""
Unit tests for the Type1 eexec decryption and glyph-name extraction
logic in check_pdf_glyphs.py.

Run:
  python3 tests/test_eexec_decryption.py
"""

import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

# Import internals directly.
from check_pdf_glyphs import (
    _eexec_decrypt,
    _charstring_glyph_names,
    _encoding_differences,
    _pfa_cleartext_and_eexec,
)


def _eexec_encrypt(plaintext: bytes, key: int = 55665) -> bytes:
    """Encrypt bytes with the Type1 eexec algorithm (inverse of decrypt)."""
    result = bytearray()
    for b in plaintext:
        cipher = b ^ (key >> 8)
        key = ((cipher + key) * 52845 + 22719) & 0xffff
        result.append(cipher)
    return bytes(result)


def test_eexec_roundtrip():
    """Encrypting then decrypting must recover the original plaintext."""
    # The first 4 bytes are a random seed; prepend four zeros to simulate them.
    seed = b'\x00\x00\x00\x00'
    plaintext = b'/adieresis 40 RD\x01\x02\x03\x04\x05ND\n/notdef 10 RD\xAANDend'
    full = seed + plaintext
    encrypted = _eexec_encrypt(full)
    decrypted = _eexec_decrypt(encrypted)   # skips the 4-byte seed internally
    assert decrypted == plaintext, (
        f'Round-trip failed.\n  expected: {plaintext!r}\n  got:      {decrypted!r}'
    )
    print('PASS test_eexec_roundtrip')


def test_charstring_name_extraction():
    """_charstring_glyph_names must find all glyph names from RD / -| patterns."""
    seed = b'\x00\x00\x00\x00'
    # Simulate a CharStrings block with several glyphs.
    inner = (
        b'/adieresis 5 RD\x01\x02\x03\x04\x05 ND\n'
        b'/odieresis 3 RD\xAA\xBB\xCC ND\n'
        b'/udieresis 4 -|\x01\x02\x03\x04 |-\n'
        b'/germandbls 6 RD\x01\x02\x03\x04\x05\x06 ND\n'
        b'/notdef 2 RD\x00\x01 ND\n'
    )
    full = seed + inner
    encrypted = _eexec_encrypt(full)
    decrypted = _eexec_decrypt(encrypted)
    names = _charstring_glyph_names(decrypted)
    assert 'adieresis'  in names, f'adieresis missing; found: {names}'
    assert 'odieresis'  in names, f'odieresis missing; found: {names}'
    assert 'udieresis'  in names, f'udieresis missing; found: {names}'
    assert 'germandbls' in names, f'germandbls missing; found: {names}'
    assert 'notdef'     in names, f'notdef missing; found: {names}'
    print(f'PASS test_charstring_name_extraction  ({len(names)} glyphs found: {sorted(names)})')


def test_encoding_differences_parser():
    """_encoding_differences must correctly parse a /Differences array.

    Uses the same layout as pdf.zig's latin1_differences (ISO-8859-1 byte
    positions), so the expected byte→glyph mappings are:
      196 → Adieresis  (Ä)
      214 → Odieresis  (Ö)
      220 → Udieresis  (Ü)
      223 → germandbls (ß)
      228 → adieresis  (ä)
      246 → odieresis  (ö)
      252 → udieresis  (ü)
    """
    # Mirror the latin1_differences string from pdf.zig exactly.
    obj = (
        b'<< /Type /Encoding /BaseEncoding /StandardEncoding\n'
        b'/Differences [\n'
        b'150 /endash /emdash\n'
        b'192 /Agrave /Aacute /Acircumflex /Atilde /Adieresis /Aring\n'
        b'/AE /Ccedilla /Egrave /Eacute /Ecircumflex /Edieresis\n'
        b'/Igrave /Iacute /Icircumflex /Idieresis /Eth /Ntilde\n'
        b'/Ograve /Oacute /Ocircumflex /Otilde /Odieresis /multiply\n'
        b'/Oslash /Ugrave /Uacute /Ucircumflex /Udieresis /Yacute\n'
        b'/Thorn /germandbls\n'
        b'/agrave /aacute /acircumflex /atilde /adieresis /aring\n'
        b'/ae /ccedilla /egrave /eacute /ecircumflex /edieresis\n'
        b'/igrave /iacute /icircumflex /idieresis /eth /ntilde\n'
        b'/ograve /oacute /ocircumflex /otilde /odieresis /divide\n'
        b'/oslash /ugrave /uacute /ucircumflex /udieresis /yacute\n'
        b'/thorn /ydieresis\n'
        b'] >>'
    )
    diffs = _encoding_differences(obj)
    assert diffs.get(150) == 'endash',    f'pos 150: {diffs.get(150)}'
    assert diffs.get(151) == 'emdash',    f'pos 151: {diffs.get(151)}'
    # ISO-8859-1 positions for capital umlauts.
    assert diffs.get(196) == 'Adieresis', f'pos 196: {diffs.get(196)}'
    assert diffs.get(214) == 'Odieresis', f'pos 214: {diffs.get(214)}'
    assert diffs.get(220) == 'Udieresis', f'pos 220: {diffs.get(220)}'
    assert diffs.get(223) == 'germandbls',f'pos 223: {diffs.get(223)}'
    # ISO-8859-1 positions for lower-case umlauts.
    assert diffs.get(228) == 'adieresis', f'pos 228: {diffs.get(228)}'
    assert diffs.get(246) == 'odieresis', f'pos 246: {diffs.get(246)}'
    assert diffs.get(252) == 'udieresis', f'pos 252: {diffs.get(252)}'
    print(f'PASS test_encoding_differences_parser  ({len(diffs)} entries, spot-checked 9)')


def test_pfa_cleartext_and_eexec():
    """_pfa_cleartext_and_eexec must split a fake PFA and recover the charstring names."""
    seed = b'\x00\x00\x00\x00'
    inner = b'/adieresis 5 RD\x01\x02\x03\x04\x05 ND\n/germandbls 3 RD\xAA\xBB\xCC ND\n'
    full = seed + inner
    encrypted = _eexec_encrypt(full)
    hex_eexec = encrypted.hex().encode('ascii')

    # Build a fake PFA blob.
    pfa = b'%!PS-AdobeFont-1.0: TestFont 001.000\n'
    pfa += b'/FontName /TestFont def\n'
    pfa += b'currentfile eexec\n'
    pfa += hex_eexec
    pfa += b'\n0000000000000000000000000000000000000000000000000000\ncleartomark\n'

    cleartext, decrypted = _pfa_cleartext_and_eexec(pfa)
    assert b'FontName' in cleartext, 'cleartext not extracted'
    assert decrypted is not None, 'eexec decryption returned None'
    names = _charstring_glyph_names(decrypted)
    assert 'adieresis'  in names, f'adieresis missing; found: {names}'
    assert 'germandbls' in names, f'germandbls missing; found: {names}'
    print(f'PASS test_pfa_cleartext_and_eexec  ({len(names)} glyphs found: {sorted(names)})')


if __name__ == '__main__':
    tests = [
        test_eexec_roundtrip,
        test_charstring_name_extraction,
        test_encoding_differences_parser,
        test_pfa_cleartext_and_eexec,
    ]
    failed = 0
    for t in tests:
        try:
            t()
        except Exception as e:
            print(f'FAIL {t.__name__}: {e}')
            failed += 1
    print()
    print(f'{"OK" if failed == 0 else "FAILED"} — {len(tests) - failed}/{len(tests)} passed')
    sys.exit(0 if failed == 0 else 1)
