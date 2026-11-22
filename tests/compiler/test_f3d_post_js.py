"""Forge3D Wave C seat B76: tests for the post-processing sidecar
``runtime/f3d-post.js`` (MASTER-PLAN parity row 30), the JS mirror
of ``src/postprocess.f90`` (seat B75).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_post_js.py

The size/existence checks always run. The numeric checks shell out
to ``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest reports
them as skipped, with the reason, rather than passing silently).

The expected pixel values are computed in Python directly from the
filter formulas in the sidecar header / Fortran spec (never copied
from the JS output), so the two implementations cross-check each
other. Rounding mirrors JS ``Math.round`` (half up, via
``floor(v + 0.5)``), NOT Python's banker's ``round``.
"""

import json
import math
import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-post.js")
MAX_BYTES = 6144
NODE = shutil.which("node")

# Loaded before every snippet: expose `window` (as in a browser page
# that loads the sidecar after f3d.js) and bind the export as `P`.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_POST, 'utf8'));"
    "const P = globalThis.F3DPost;"
    "const assert = require('assert');"
)

# A varied 3x3 RGB image (row-major triplets).
IMG3 = [
    255, 0, 0,     0, 255, 0,     0, 0, 255,
    10, 20, 30,    100, 110, 120, 200, 210, 220,
    50, 60, 70,    80, 90, 100,   130, 140, 150,
]
W3 = H3 = 3


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_POST=JS_PATH)
    proc = subprocess.run(
        [NODE, "-e", PREAMBLE + snippet],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(
            "node snippet failed (rc=%d):\n%s\n%s"
            % (proc.returncode, proc.stdout, proc.stderr)
        )
    return proc


def check_apply(pixels, w, h, chain, expected, stride=3):
    """Assert JS apply() on `pixels` yields exactly `expected`."""
    run_node(
        "const px = new Uint8ClampedArray(%s);"
        "const out = P.apply(px, %d, %d, %s);"
        "assert.strictEqual(out, px, 'apply must return its input');"
        "assert.deepStrictEqual(Array.from(px), %s);"
        % (json.dumps(list(pixels)), w, h, json.dumps(chain),
           json.dumps(list(expected)))
    )


# --- Python mirror of the spec (independent of the JS) -------------

def fix(v):
    """JS Math.round (half up) then clamp to 0..255."""
    return max(0, min(255, math.floor(v + 0.5)))


def lum(r, g, b):
    return 0.299 * r + 0.587 * g + 0.114 * b


def _blur_pass(px, w, h):
    src = list(px)
    for y in range(h):
        for x in range(w):
            for c in range(3):
                total = 0.0
                for dy in (-1, 0, 1):
                    yy = min(h - 1, max(0, y + dy))
                    for dx in (-1, 0, 1):
                        xx = min(w - 1, max(0, x + dx))
                        total += src[(yy * w + xx) * 3 + c]
                px[(y * w + x) * 3 + c] = total / 9


def apply_py(pixels, w, h, chain):
    """The filter spec, in Python, on an RGB triplet list."""
    px = [float(v) for v in pixels]
    for step in chain:
        name = step["name"].lower()  # names are case-insensitive
        amount = step.get("amount", 1)
        if name == "blur":
            for _ in range(max(0, int(amount))):  # int() truncates
                _blur_pass(px, w, h)
                px = [float(fix(v)) for v in px]
        elif name == "bloom":
            for i in range(0, len(px), 3):
                add = max(0.0, lum(*px[i:i + 3]) / 255 - 0.75) \
                    * amount * 255
                px[i] += add
                px[i + 1] += add
                px[i + 2] += add
        elif name == "vignette":
            for y in range(h):
                ny = 2 * y / (h - 1) - 1 if h > 1 else 0.0
                for x in range(w):
                    nx = 2 * x / (w - 1) - 1 if w > 1 else 0.0
                    s = 1 - amount * (nx * nx + ny * ny) / 2
                    i = (y * w + x) * 3
                    px[i] *= s
                    px[i + 1] *= s
                    px[i + 2] *= s
        elif name == "gamma":
            if amount > 0:
                px = [255 * (v / 255) ** (1 / amount) for v in px]
        elif name == "grayscale":
            a = min(1.0, max(0.0, amount))
            for i in range(0, len(px), 3):
                grey = lum(*px[i:i + 3])
                for c in range(3):
                    px[i + c] = (1 - a) * px[i + c] + a * grey
        elif name == "sepia":
            a = min(1.0, max(0.0, amount))
            for i in range(0, len(px), 3):
                r, g, b = px[i:i + 3]
                target = [
                    min(255.0, 0.393 * r + 0.769 * g + 0.189 * b),
                    min(255.0, 0.349 * r + 0.686 * g + 0.168 * b),
                    min(255.0, 0.272 * r + 0.534 * g + 0.131 * b),
                ]
                orig = [r, g, b]
                for c in range(3):
                    px[i + c] = (1 - a) * orig[c] + a * target[c]
        # Unknown names: no-op, mirroring the Fortran.
        px = [float(fix(v)) for v in px]
    return [fix(v) for v in px]


class TestF3DPostFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-post.js is %d B, budget is %d B" % (size, MAX_BYTES),
        )


@unittest.skipUnless(
    NODE,
    "SKIPPED: node not on PATH - f3d-post.js numeric tests not run",
)
class TestF3DPostNumeric(unittest.TestCase):
    def test_exports(self):
        run_node(
            "assert.strictEqual(typeof P.apply, 'function');"
            "assert.strictEqual(window.F3DPost, P);"
        )

    def test_blur_one_pass(self):
        chain = [{"name": "blur", "amount": 1}]
        check_apply(IMG3, W3, H3, chain, apply_py(IMG3, W3, H3, chain))

    def test_blur_pass_count_and_truncation(self):
        # amount 2 = two passes; 1.9 truncates to one pass (int());
        # 0 passes is a no-op.
        two = [{"name": "blur", "amount": 2}]
        check_apply(IMG3, W3, H3, two, apply_py(IMG3, W3, H3, two))
        frac = [{"name": "blur", "amount": 1.9}]
        one = [{"name": "blur", "amount": 1}]
        check_apply(IMG3, W3, H3, frac, apply_py(IMG3, W3, H3, one))
        zero = [{"name": "blur", "amount": 0}]
        check_apply(IMG3, W3, H3, zero, IMG3)

    def test_bloom_threshold_and_amount(self):
        # First pixel is above the 0.75 luminance threshold, the
        # second is below it and must stay untouched.
        img = [200, 200, 200, 100, 50, 20]
        for amount in (1, 2.5):
            chain = [{"name": "bloom", "amount": amount}]
            check_apply(img, 2, 1, chain, apply_py(img, 2, 1, chain))

    def test_vignette(self):
        chain = [{"name": "vignette", "amount": 0.6}]
        expected = apply_py(IMG3, W3, H3, chain)
        # Centre pixel (index 1,1) has d2 = 0: unchanged by hand.
        self.assertEqual(expected[12:15], IMG3[12:15])
        check_apply(IMG3, W3, H3, chain, expected)

    def test_gamma(self):
        img = [0, 64, 255, 16, 128, 200]
        for amount in (2.0, 0.5):
            chain = [{"name": "gamma", "amount": amount}]
            check_apply(img, 2, 1, chain, apply_py(img, 2, 1, chain))

    def test_grayscale_full_and_partial(self):
        for amount in (1, 0.5, 0):
            chain = [{"name": "grayscale", "amount": amount}]
            check_apply(IMG3, W3, H3, chain,
                        apply_py(IMG3, W3, H3, chain))

    def test_sepia_full_and_partial(self):
        for amount in (1, 0.4):
            chain = [{"name": "sepia", "amount": amount}]
            check_apply(IMG3, W3, H3, chain,
                        apply_py(IMG3, W3, H3, chain))

    def test_amount_clamping_and_gamma_guard(self):
        # grayscale / sepia blend factors clamp to [0, 1] in the
        # Fortran, so amount 2 behaves as 1 and -1 as 0 (a no-op);
        # gamma with amount <= 0 is a no-op.
        for name in ("grayscale", "sepia"):
            over = [{"name": name, "amount": 2}]
            full = [{"name": name, "amount": 1}]
            check_apply(IMG3, W3, H3, over,
                        apply_py(IMG3, W3, H3, full))
            under = [{"name": name, "amount": -1}]
            check_apply(IMG3, W3, H3, under, IMG3)
        for amount in (0, -2.0):
            chain = [{"name": "gamma", "amount": amount}]
            check_apply(IMG3, W3, H3, chain, IMG3)

    def test_filter_names_case_insensitive(self):
        chain = [{"name": "GrAyScAlE", "amount": 1},
                 {"name": "GAMMA", "amount": 2.0}]
        check_apply(IMG3, W3, H3, chain, apply_py(IMG3, W3, H3, chain))

    def test_missing_amount_defaults_to_one(self):
        bare = [{"name": "grayscale"}]
        full = [{"name": "grayscale", "amount": 1}]
        check_apply(IMG3, W3, H3, bare, apply_py(IMG3, W3, H3, full))

    def test_chain_order_sensitivity(self):
        # gamma-then-grayscale must differ from grayscale-then-gamma
        # (both expectations derived in Python; sanity-checked to
        # actually differ before the JS is asked to match them).
        img = [200, 30, 60]
        fwd = [{"name": "gamma", "amount": 2.0},
               {"name": "grayscale", "amount": 1}]
        rev = [{"name": "grayscale", "amount": 1},
               {"name": "gamma", "amount": 2.0}]
        exp_fwd = apply_py(img, 1, 1, fwd)
        exp_rev = apply_py(img, 1, 1, rev)
        self.assertNotEqual(exp_fwd, exp_rev)
        check_apply(img, 1, 1, fwd, exp_fwd)
        check_apply(img, 1, 1, rev, exp_rev)

    def test_chain_applies_sequentially(self):
        chain = [{"name": "blur", "amount": 1},
                 {"name": "sepia", "amount": 0.7},
                 {"name": "vignette", "amount": 0.5}]
        check_apply(IMG3, W3, H3, chain, apply_py(IMG3, W3, H3, chain))

    def test_unknown_filter_is_noop(self):
        unknown = [{"name": "sharpen", "amount": 5}]
        check_apply(IMG3, W3, H3, unknown, IMG3)
        # An unknown name in the middle of a chain must not disturb
        # the filters around it.
        mixed = [{"name": "grayscale", "amount": 1},
                 {"name": "nope", "amount": 3},
                 {"name": "gamma", "amount": 2.0}]
        plain = [mixed[0], mixed[2]]
        check_apply(IMG3, W3, H3, mixed, apply_py(IMG3, W3, H3, plain))

    def test_empty_chain_and_rgba_alpha_preserved(self):
        check_apply(IMG3, W3, H3, [], IMG3)
        rgba = [200, 30, 60, 77]
        chain = [{"name": "grayscale", "amount": 1}]
        expected = apply_py(rgba[:3], 1, 1, chain) + [77]
        check_apply(rgba, 1, 1, chain, expected, stride=4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
