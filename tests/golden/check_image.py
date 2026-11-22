#!/usr/bin/env python3
"""Golden-image checker for P3 (ASCII) PPM files. Stdlib only.

CLI:
    check_image.py IMAGE.ppm [--expect-nonflat] [--expect-bg R G B]
                             [--min-distinct N] [--hash] [--psnr OTHER.ppm]

Importable:
    read_ppm(path) -> (w, h, bytes)     raw RGB bytes, row-major
    image_stats(path) -> dict
    psnr(a, b) -> float                 a/b: paths or (w, h, bytes) tuples

Canonical pixel bytes (for --hash): struct '>II' (w, h) + raw RGB bytes;
the printed hash is the sha256 hex digest of those bytes.

Definitions:
    distinct  -- number of distinct RGB colours in the image.
    bg        -- background colour: the most frequent colour (ties broken
                 by first occurrence).
    non-flat  -- distinct >= 2 and not all pixels equal the background
                 colour (--expect-bg's colour when given, else `bg`).

Exit codes: 0 = all requested expectations pass, 1 = an expectation
failed, 2 = usage / IO / format error (including PSNR dimension mismatch).
"""
import argparse
import hashlib
import math
import struct
import sys
from collections import Counter


def _tokens(text):
    """Yield whitespace-separated tokens, stripping '#' comments."""
    for line in text.splitlines():
        hash_at = line.find("#")
        if hash_at != -1:
            line = line[:hash_at]
        for tok in line.split():
            yield tok


def read_ppm(path):
    """Parse a P3 PPM at *path* and return (width, height, rgb_bytes)."""
    with open(path, "r", encoding="ascii", errors="strict") as fh:
        toks = list(_tokens(fh.read()))
    if len(toks) < 4:
        raise ValueError("PPM too short: missing header")
    if toks[0] != "P3":
        raise ValueError("not a P3 PPM (magic %r)" % toks[0])
    try:
        w, h, maxval = int(toks[1]), int(toks[2]), int(toks[3])
    except ValueError:
        raise ValueError("non-integer width/height/maxval in PPM header")
    if w <= 0 or h <= 0:
        raise ValueError("PPM dimensions must be positive")
    if maxval <= 0 or maxval > 65535:
        raise ValueError("PPM maxval out of range: %d" % maxval)
    values = toks[4:]
    expected = w * h * 3
    if len(values) < expected:
        raise ValueError(
            "PPM truncated: expected %d samples, got %d" % (expected, len(values)))
    if len(values) > expected:
        raise ValueError(
            "PPM has extra data: expected %d samples, got %d" % (expected, len(values)))
    out = bytearray(expected)
    for i, tok in enumerate(values):
        try:
            v = int(tok)
        except ValueError:
            raise ValueError("non-integer sample %r in PPM" % tok)
        if v < 0 or v > maxval:
            raise ValueError("sample %d out of range 0..%d" % (v, maxval))
        out[i] = v if maxval == 255 else round(v * 255 / maxval)
    return w, h, bytes(out)


def _canonical_bytes(w, h, pixels):
    return struct.pack(">II", w, h) + bytes(pixels)


def _colours(pixels):
    return [tuple(pixels[i:i + 3]) for i in range(0, len(pixels), 3)]


def _stats(w, h, pixels, bg=None):
    colours = _colours(pixels)
    counter = Counter(colours)
    most_common = counter.most_common(1)[0][0] if counter else None
    effective_bg = tuple(bg) if bg is not None else most_common
    distinct = len(counter)
    all_bg = effective_bg is not None and all(c == effective_bg for c in colours)
    nonflat = distinct >= 2 and not all_bg
    return {
        "width": w,
        "height": h,
        "w": w,
        "h": h,
        "pixels": pixels,
        "distinct": distinct,
        "distinct_colors": distinct,
        "bg": most_common,
        "background": most_common,
        "nonflat": nonflat,
        "is_flat": not nonflat,
        "sha256": hashlib.sha256(_canonical_bytes(w, h, pixels)).hexdigest(),
        "hash": hashlib.sha256(_canonical_bytes(w, h, pixels)).hexdigest(),
    }


def image_stats(path):
    """Return a stats dict for the PPM at *path* (see module docstring)."""
    w, h, pixels = read_ppm(path)
    return _stats(w, h, pixels)


def _as_image(obj):
    if isinstance(obj, tuple) and len(obj) == 3:
        return obj[0], obj[1], bytes(obj[2])
    return read_ppm(obj)  # otherwise treat as a path


def psnr(a, b):
    """Peak signal-to-noise ratio (dB) between two PPMs; inf if identical.

    *a* and *b* may each be a path or a (w, h, rgb_bytes) tuple.
    Raises ValueError on dimension mismatch.
    """
    wa, ha, pa = _as_image(a)
    wb, hb, pb = _as_image(b)
    if (wa, ha) != (wb, hb):
        raise ValueError("dimension mismatch: %dx%d vs %dx%d" % (wa, ha, wb, hb))
    if pa == pb:
        return float("inf")
    mse = sum((x - y) ** 2 for x, y in zip(pa, pb)) / len(pa)
    if mse == 0:
        return float("inf")
    return 10.0 * math.log10((255.0 ** 2) / mse)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="check_image.py",
        description="Check a P3 PPM golden image.")
    parser.add_argument("image", help="IMAGE.ppm to check")
    parser.add_argument("--expect-nonflat", action="store_true",
                        help="fail unless the image is non-flat")
    parser.add_argument("--expect-bg", nargs=3, type=int, metavar=("R", "G", "B"),
                        default=None,
                        help="fail unless the background (most frequent) colour is R G B")
    parser.add_argument("--min-distinct", type=int, default=None, metavar="N",
                        help="fail unless there are at least N distinct colours")
    parser.add_argument("--hash", action="store_true",
                        help="print sha256 of the canonical pixel bytes")
    parser.add_argument("--psnr", default=None, metavar="OTHER.ppm",
                        help="print PSNR (dB) against OTHER.ppm")
    args = parser.parse_args(argv)  # argparse exits 2 on usage errors

    if args.expect_bg is not None and any(
            v < 0 or v > 255 for v in args.expect_bg):
        parser.error("--expect-bg values must be in 0..255")  # exits 2
    if args.min_distinct is not None and args.min_distinct < 0:
        parser.error("--min-distinct must be >= 0")  # exits 2

    try:
        w, h, pixels = read_ppm(args.image)
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2

    stats = _stats(w, h, pixels, bg=args.expect_bg)
    print("size: %dx%d" % (w, h))
    print("distinct: %d" % stats["distinct"])
    print("nonflat: %s" % ("yes" if stats["nonflat"] else "no"))
    if args.hash:
        print("sha256: %s" % stats["sha256"])

    failures = []
    if args.expect_nonflat and not stats["nonflat"]:
        failures.append("expected non-flat image")
    if args.expect_bg is not None and tuple(args.expect_bg) != stats["bg"]:
        failures.append("expected bg %s, got %s"
                        % (tuple(args.expect_bg), stats["bg"]))
    if args.min_distinct is not None and stats["distinct"] < args.min_distinct:
        failures.append("expected >= %d distinct colours, got %d"
                        % (args.min_distinct, stats["distinct"]))

    if args.psnr is not None:
        try:
            value = psnr((w, h, pixels), args.psnr)
        except (OSError, ValueError, UnicodeDecodeError) as exc:
            print("error: %s" % exc, file=sys.stderr)
            return 2
        print("psnr: %s" % ("inf" if math.isinf(value) else "%.4f" % value))

    for failure in failures:
        print("FAIL: %s" % failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
