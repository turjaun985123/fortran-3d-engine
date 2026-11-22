"""Forge3D Wave B seat B69: tests for the OPTIONAL sprites+text
sidecar ``runtime/f3d-sprites-text.js`` (billboards + 5x7 bitmap
text, mirroring ``src/sprite.f90`` / ``src/text_render.f90``).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_sprites_text_js.py

The size/existence checks always run. The numeric checks shell out
to ``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest reports
them as skipped, with the reason, rather than passing silently).
"""

import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-sprites-text.js")
MAX_BYTES = 7680
NODE = shutil.which("node")

# Loaded before every snippet: expose `window` (as in a browser page
# that loads the sidecar after f3d.js) and bind the export as `S`.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_SPRITES_TEXT,"
    " 'utf8'));"
    "const S = globalThis.F3DSpritesText;"
    "const assert = require('assert');"
    "const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);"
    "const dot = (a, b) => a[0]*b[0] + a[1]*b[1] + a[2]*b[2];"
    "const len = (a) => Math.hypot(a[0], a[1], a[2]);"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_SPRITES_TEXT=JS_PATH)
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


class TestF3DSpritesTextFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-sprites-text.js is %d B, budget is %d B"
            % (size, MAX_BYTES),
        )


@unittest.skipUnless(
    NODE,
    "SKIPPED: node not on PATH - f3d-sprites-text.js numeric tests"
    " not run",
)
class TestF3DSpritesTextNumeric(unittest.TestCase):
    def test_exports_charset_and_glyph_table_shape(self):
        run_node(
            "for (const k of ['spriteBasis','spriteQuad','glyphRows',"
            "'textTriangles','textWidth','CHARSET','GLYPHS'])"
            "  assert.ok(S[k] !== undefined, 'missing export ' + k);"
            "assert.strictEqual(window.F3DSpritesText, S);"
            "assert.strictEqual(S.CHARSET,"
            "  \" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'\");"
            "assert.strictEqual(S.CHARSET.length, 43);"
            "assert.strictEqual(S.GLYPHS.length, 43);"
            "for (const g of S.GLYPHS) {"
            "  assert.strictEqual(g.length, 7);"
            "  for (const row of g)"
            "    assert.ok(Number.isInteger(row)"
            "      && row >= 0 && row <= 31, 'row ' + row); }"
        )

    def test_basis_orthonormal(self):
        run_node(
            # Ordinary camera and the degenerate straight-down view
            # (centre at the origin, camera on +Y): in both cases
            # right/up must be unit, mutually perpendicular, and
            # perpendicular to view_dir = normalize(center-camPos).
            "for (const cam of [[3, 2.5, 4], [0, 10, 0]]) {"
            "  const b = S.spriteBasis([0, 0, 0], cam);"
            "  assert.ok(near(len(b.right), 1, 1e-12),"
            "    'cam ' + cam + ' right=' + b.right);"
            "  assert.ok(near(len(b.up), 1, 1e-12),"
            "    'cam ' + cam + ' up=' + b.up);"
            "  assert.ok(near(dot(b.right, b.up), 0, 1e-12),"
            "    'cam ' + cam + ' right.up != 0');"
            "  const vd = [-cam[0], -cam[1], -cam[2]];"
            "  const l = len(vd); vd.forEach((v, i) => vd[i] = v / l);"
            "  assert.ok(near(dot(b.right, vd), 0, 1e-12));"
            "  assert.ok(near(dot(b.up, vd), 0, 1e-12)); }"
        )

    def test_sprite_quad_corner_distance(self):
        run_node(
            # Every corner is size/sqrt(2) from the centre, adjacent
            # corners are `size` apart, opposite corners 2*that.
            "const c = [1, 2, 3], size = 4;"
            "const q = S.spriteQuad(c, size, [3, 2.5, 4]);"
            "assert.strictEqual(q.length, 4);"
            "for (const p of q) {"
            "  const d = Math.hypot(p[0]-c[0], p[1]-c[1], p[2]-c[2]);"
            "  assert.ok(near(d, size / Math.SQRT2, 1e-12),"
            "    'corner dist ' + d); }"
            "const adj = Math.hypot(q[1][0]-q[0][0], q[1][1]-q[0][1],"
            "  q[1][2]-q[0][2]);"
            "assert.ok(near(adj, size, 1e-12), 'adjacent ' + adj);"
            "const opp = Math.hypot(q[2][0]-q[0][0], q[2][1]-q[0][1],"
            "  q[2][2]-q[0][2]);"
            "assert.ok(near(opp, size * Math.SQRT2, 1e-12),"
            "  'opposite ' + opp);"
        )

    def test_glyph_rows(self):
        run_node(
            # Classic 5x7 'A': top row 0b01110.
            "assert.strictEqual(S.glyphRows('A')[0], 0b01110);"
            "assert.strictEqual(S.glyphRows('A')[0], 14);"
            "assert.strictEqual(S.glyphRows('A').length, 7);"
            # Lowercase folds to uppercase.
            "assert.deepStrictEqual(S.glyphRows('a'),"
            "  S.glyphRows('A'));"
            # Unknown characters map to '?'.
            "assert.deepStrictEqual(S.glyphRows('@'),"
            "  S.glyphRows('?'));"
            "assert.deepStrictEqual(S.glyphRows('~'),"
            "  S.glyphRows('?'));"
            # Returned rows are a copy, not the frozen table.
            "const r = S.glyphRows('A'); r[0] = 99;"
            "assert.strictEqual(S.glyphRows('A')[0], 14);"
        )

    def test_text_triangles_a(self):
        run_node(
            # 2 triangles (6 vertices) per ON pixel of 'A'.
            "const rows = S.glyphRows('A');"
            "let pop = 0;"
            "for (const row of rows)"
            "  for (let c = 0; c < 5; c++)"
            "    pop += (row >> (4 - c)) & 1;"
            "assert.ok(pop > 0);"
            "const v = S.textTriangles('A', [0, 0, 0], 7);"
            "assert.strictEqual(v.length % 3, 0);"
            "assert.strictEqual(v.length / 3, 2 * 3 * pop);"
            # All vertices lie in the XY plane at the origin's z,
            # inside the glyph block [0,5] x [0,7] for size 7.
            "for (let i = 0; i < v.length; i += 3) {"
            "  assert.strictEqual(v[i + 2], 0);"
            "  assert.ok(v[i] >= 0 && v[i] <= 5, 'x=' + v[i]);"
            "  assert.ok(v[i + 1] >= 0 && v[i + 1] <= 7,"
            "    'y=' + v[i + 1]); }"
            # First triangle's normal faces +Z (CCW winding).
            "const a = [v[0], v[1], v[2]], b = [v[3], v[4], v[5]],"
            "  d = [v[6], v[7], v[8]];"
            "const u = [b[0]-a[0], b[1]-a[1], b[2]-a[2]],"
            "  w = [d[0]-a[0], d[1]-a[1], d[2]-a[2]];"
            "assert.ok(u[0]*w[1] - u[1]*w[0] > 0, 'normal not +Z');"
            # Empty text emits nothing.
            "assert.deepStrictEqual(S.textTriangles('', [0, 0, 0], 7),"
            "  []);"
        )

    def test_text_width(self):
        run_node(
            # len*6*(size/7) - size/7: 'AB' at size 7 -> 12 - 1.
            "assert.strictEqual(S.textWidth('AB', 7), 11);"
            "assert.strictEqual(S.textWidth('A', 7), 5);"
            "assert.strictEqual(S.textWidth('', 7), 0);"
            "assert.ok(near(S.textWidth('ABC', 14),"
            "  3 * 6 * 2 - 2, 1e-12));"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
