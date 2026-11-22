"""Forge3D Wave E seat E07: tests for the skinning + morph
sidecar ``runtime/f3d-skin.js`` (C1: morphApply bulge / taper /
squash, the smoothstep ``skinWeight`` falloff, and ``skinApply``
blending toward a bone matrix M = T(pivot) * Rz * Ry * Rx *
T(-pivot), angles in degrees, rotations mirroring
``src/math_3d.f90`` mat4_rotate_x/y/z).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_skin_js.py

The size/existence checks always run. The numeric checks shell out
to ``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest reports
them as skipped, with the reason, rather than passing silently).

Expected values are computed INDEPENDENTLY in Python below
(``py_morph`` / ``py_skin_weight`` / ``py_skin_apply``, written
straight from the contract formulas) and compared against the JS
results within 1e-9.
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
JS_PATH = os.path.join(REPO, "runtime", "f3d-skin.js")
MAX_BYTES = 7680
NODE = shutil.which("node")

PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_SKIN, 'utf8'));"
    "const S = globalThis.Forge3DSkin;"
    "const assert = require('assert');"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_SKIN=JS_PATH)
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


def run_node_json(snippet):
    """Run a snippet whose last act prints one JSON value; parse it."""
    return json.loads(run_node(snippet).stdout.strip().splitlines()[-1])


# ------------------------------------------------------------------
# Independent Python reference implementations (contract formulas).
# ------------------------------------------------------------------

def _centroid(verts):
    n = len(verts) // 3
    return [sum(verts[3 * i + k] for i in range(n)) / n for k in range(3)]


def py_morph(verts, kind, factor):
    out = list(verts)
    n = len(verts) // 3
    if n == 0 or factor == 0:
        return out
    c = _centroid(verts)
    if kind == "bulge":
        halfh = max(abs(verts[3 * i + 1] - c[1]) for i in range(n))
        if halfh == 0:
            return out
        for i in range(n):
            q = (verts[3 * i + 1] - c[1]) / halfh
            s = 1 + factor * 0.5 * (1 - q * q)
            out[3 * i] = c[0] + (verts[3 * i] - c[0]) * s
            out[3 * i + 1] = verts[3 * i + 1]
            out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * s
    elif kind == "taper":
        ys = [verts[3 * i + 1] for i in range(n)]
        ymin, ymax = min(ys), max(ys)
        if ymax == ymin:
            return out
        for i in range(n):
            h = (verts[3 * i + 1] - ymin) / (ymax - ymin)
            s = 1 - factor * 0.5 * h
            out[3 * i] = c[0] + (verts[3 * i] - c[0]) * s
            out[3 * i + 1] = verts[3 * i + 1]
            out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * s
    elif kind == "squash":
        for i in range(n):
            out[3 * i] = c[0] + (verts[3 * i] - c[0]) * (1 + 0.25 * factor)
            out[3 * i + 1] = c[1] + (verts[3 * i + 1] - c[1]) * (
                1 - 0.5 * factor)
            out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * (
                1 + 0.25 * factor)
    else:
        raise ValueError(kind)
    return out


def py_skin_weight(dist, radius):
    if radius <= 0:
        return 0.0
    s = min(1.0, max(0.0, 1 - dist / radius))
    return s * s * (3 - 2 * s)


def _py_rotate(q, rot_deg):
    """Rz * Ry * Rx * q, math_3d.f90 conventions, degrees."""
    x, y, z = q
    cx, sx = math.cos(math.radians(rot_deg[0])), \
        math.sin(math.radians(rot_deg[0]))
    cy, sy = math.cos(math.radians(rot_deg[1])), \
        math.sin(math.radians(rot_deg[1]))
    cz, sz = math.cos(math.radians(rot_deg[2])), \
        math.sin(math.radians(rot_deg[2]))
    y, z = cx * y - sx * z, sx * y + cx * z          # Rx
    x, z = cy * x + sy * z, -sy * x + cy * z         # Ry
    x, y = cz * x - sz * y, sz * x + cz * y          # Rz
    return [x, y, z]


def py_skin_apply(verts, pivot, rot_deg, radius):
    out = list(verts)
    for i in range(len(verts) // 3):
        p = verts[3 * i:3 * i + 3]
        q = [p[k] - pivot[k] for k in range(3)]
        w = py_skin_weight(math.dist(p, pivot), radius)
        if w == 0:
            continue
        r = _py_rotate(q, rot_deg)
        m = [pivot[k] + r[k] for k in range(3)]
        out[3 * i:3 * i + 3] = [(1 - w) * p[k] + w * m[k]
                                for k in range(3)]
    return out


# Known vertex sets: the 8 corners of the size-2 cube, and an
# asymmetric 5-point set (centroid / half-height not at the origin).
CUBE = [x for p in [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                    (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
        for x in p]
ASYM = [1, 0, 0, -1, 0, 0, 0, 2, 0, 0, -2, 0, 0, 0, 3]
# Sphere-like set: 4 equator vertices (y == cy, q == 0) and the
# 2 pole vertices (y == cy +/- halfh, q == +/-1); centroid origin.
SPHERE_LIKE = [1, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1, 0, 0, -1, 0]


class SkinCase(unittest.TestCase):
    def assertFlatNear(self, got, want, eps=1e-9):
        self.assertEqual(len(got), len(want))
        for a, b in zip(got, want):
            self.assertAlmostEqual(a, b, delta=eps)


class TestF3DSkinFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-skin.js is %d B, budget is %d B" % (size, MAX_BYTES),
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-skin.js numeric tests not run"
)
class TestF3DSkinNumeric(SkinCase):
    def test_exports(self):
        run_node(
            "for (const k of ['morphApply','skinWeight','skinApply'])"
            "  assert.strictEqual(typeof S[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.Forge3DSkin, S);"
        )

    def test_factor_zero_identity_all_kinds(self):
        run_node(
            "const v = %s;"
            "for (const kind of ['bulge','taper','squash']) {"
            "  const o = S.morphApply(v, kind, 0);"
            "  assert.notStrictEqual(o, v, 'must return a NEW array');"
            "  assert.deepStrictEqual(o, v, kind + ' factor 0');"
            "}"
            "assert.deepStrictEqual(v, %s, 'input must not mutate');"
            % (json.dumps(ASYM), json.dumps(ASYM))
        )

    def test_unknown_kind_throws(self):
        run_node(
            "assert.throws(() => S.morphApply([0,0,0], 'twist', 1));"
            "assert.throws(() => S.morphApply([0,0,0], '', 1));"
        )

    def test_bulge_analytic(self):
        for verts, factor in ((CUBE, 0.7), (ASYM, -1.3), (ASYM, 2.0)):
            got = run_node_json(
                "console.log(JSON.stringify("
                "S.morphApply(%s, 'bulge', %r)));"
                % (json.dumps(verts), factor)
            )
            self.assertFlatNear(got, py_morph(verts, "bulge", factor))

    def test_bulge_barrel_profile_explicit(self):
        # Equator vertices (q == 0) scale by exactly
        # (1 + 0.5 * factor) in x/z, y unchanged; pole vertices
        # (q == +/-1) are unchanged.
        factor = 0.8
        scale = 1 + 0.5 * factor
        got = run_node_json(
            "console.log(JSON.stringify("
            "S.morphApply(%s, 'bulge', %r)));"
            % (json.dumps(SPHERE_LIKE), factor)
        )
        want = [scale, 0, 0, -scale, 0, 0, 0, 0, scale,
                0, 0, -scale, 0, 1, 0, 0, -1, 0]
        self.assertFlatNear(got, want)
        self.assertFlatNear(
            got, py_morph(SPHERE_LIKE, "bulge", factor))
        # Pole vertices explicitly unchanged.
        self.assertEqual(got[12:18], SPHERE_LIKE[12:18])

    def test_bulge_cube_corners_at_poles_unchanged(self):
        # Every cube corner has q == +/-1, so bulge is identity.
        got = run_node_json(
            "console.log(JSON.stringify("
            "S.morphApply(%s, 'bulge', 1.7)));" % json.dumps(CUBE)
        )
        self.assertEqual(got, CUBE)
        self.assertEqual(py_morph(CUBE, "bulge", 1.7), CUBE)

    def test_bulge_degenerate_all_points_equal(self):
        verts = [2, 3, 4] * 4
        got = run_node_json(
            "console.log(JSON.stringify("
            "S.morphApply(%s, 'bulge', 1.5)));" % json.dumps(verts)
        )
        self.assertEqual(got, verts)  # halfh == 0 -> exact copy

    def test_taper_analytic(self):
        for verts, factor in ((CUBE, 0.8), (ASYM, -0.6), (CUBE, 2.0)):
            got = run_node_json(
                "console.log(JSON.stringify("
                "S.morphApply(%s, 'taper', %r)));"
                % (json.dumps(verts), factor)
            )
            self.assertFlatNear(got, py_morph(verts, "taper", factor))

    def test_taper_flat_y_is_copy(self):
        verts = [0, 5, 0, 3, 5, -2, -4, 5, 7]
        got = run_node_json(
            "console.log(JSON.stringify("
            "S.morphApply(%s, 'taper', 1.5)));" % json.dumps(verts)
        )
        self.assertEqual(got, verts)  # ymax == ymin -> exact copy

    def test_squash_analytic(self):
        for verts, factor in ((CUBE, 1.2), (ASYM, 0.4), (CUBE, -2.0)):
            got = run_node_json(
                "console.log(JSON.stringify("
                "S.morphApply(%s, 'squash', %r)));"
                % (json.dumps(verts), factor)
            )
            self.assertFlatNear(got, py_morph(verts, "squash", factor))

    def test_skin_weight_endpoints_and_midpoint(self):
        run_node(
            "const near = (a, b) => Math.abs(a - b) <= 1e-9;"
            "assert.ok(near(S.skinWeight(0, 4), 1));"
            "assert.ok(near(S.skinWeight(4, 4), 0));"
            "assert.ok(near(S.skinWeight(2, 4), 0.5));"
            "assert.ok(near(S.skinWeight(1, 4), 0.84375));"
            "assert.ok(near(S.skinWeight(9, 4), 0), 'past radius');"
            "assert.strictEqual(S.skinWeight(0, 0), 0);"
            "assert.strictEqual(S.skinWeight(1, -3), 0);"
        )
        for dist, radius in ((0.3, 2.5), (1.7, 2.5), (2.5, 2.5)):
            got = run_node_json(
                "console.log(JSON.stringify(S.skinWeight(%r, %r)));"
                % (dist, radius)
            )
            self.assertAlmostEqual(
                got, py_skin_weight(dist, radius), delta=1e-9)

    def test_skin_apply_vertex_at_pivot_z90(self):
        # A vertex AT the pivot has w = 1 and is fixed by any
        # rotation about that pivot: Rz(90) maps it to itself,
        # exactly the analytic image M * pivot == pivot.
        run_node(
            "const o = S.skinApply([1, 1, 0, 5, 5, 5],"
            "  [1, 1, 0], [0, 0, 90], 2);"
            "assert.deepStrictEqual(o.slice(0, 3), [1, 1, 0]);"
        )
        # The rotated image itself, recovered via the blend at a
        # known weight: pivot (1,1,0), vertex (2,1,0), radius 2
        # gives w = skinWeight(1, 2) = 0.5 and Rz(90) maps
        # (2,1,0) -> (1,2,0), so the blend is (1.5, 1.5, 0).
        got = run_node_json(
            "console.log(JSON.stringify(S.skinApply("
            "[2, 1, 0], [1, 1, 0], [0, 0, 90], 2)));"
        )
        self.assertFlatNear(got, [1.5, 1.5, 0])
        self.assertFlatNear(
            got, py_skin_apply([2, 1, 0], [1, 1, 0], [0, 0, 90], 2))

    def test_skin_apply_far_vertex_bit_identical(self):
        verts = [0.1, -2.5, 3.75, 100, 200, -300]
        got = run_node_json(
            "console.log(JSON.stringify(S.skinApply(%s,"
            "  [0, 0, 0], [30, 45, 60], 5)));" % json.dumps(verts)
        )
        self.assertFlatNear(
            got, py_skin_apply(verts, [0, 0, 0], [30, 45, 60], 5))
        run_node(
            # dist >= radius (and radius <= 0): strict identity.
            "const v = %s;"
            "const o = S.skinApply(v, [0, 0, 0], [0, 0, 90], 5);"
            "assert.notStrictEqual(o, v);"
            "assert.deepStrictEqual(o.slice(3), v.slice(3));"
            "assert.deepStrictEqual("
            "  S.skinApply(v, [0, 0, 0], [0, 0, 90], 0), v);"
            "assert.deepStrictEqual(v, %s, 'input must not mutate');"
            % (json.dumps(verts), json.dumps(verts))
        )

    def test_skin_apply_partial_blend_manual_mix(self):
        # (2,0,0) about the origin, Rz(90), radius 4: dist 2,
        # w = skinWeight(2, 4) = 0.5, rotated image (0,2,0), so
        # the manual mix (1-w)*p + w*(M*p) is exactly (1,1,0).
        got = run_node_json(
            "console.log(JSON.stringify(S.skinApply("
            "[2, 0, 0], [0, 0, 0], [0, 0, 90], 4)));"
        )
        self.assertFlatNear(got, [1, 1, 0])

    def test_skin_apply_rotation_conventions_and_order(self):
        # Rx / Ry single-axis blends and a combined Rz*Ry*Rx case,
        # all against the independent Python reference (which
        # applies Rx first, then Ry, then Rz).
        cases = [
            ([3, 1, -2], [1, 2, 3], [90, 0, 0], 6.0),
            ([3, 1, -2], [1, 2, 3], [0, 90, 0], 6.0),
            ([3, 1, -2], [1, 2, 3], [0, 0, 90], 6.0),
            ([-2, 4, 1], [0, -1, 2], [90, 90, 90], 8.0),
            (CUBE, [0, 0, 0], [25, -40, 130], 3.0),
        ]
        for verts, pivot, rot, radius in cases:
            got = run_node_json(
                "console.log(JSON.stringify(S.skinApply(%s, %s,"
                " %s, %r)));"
                % (json.dumps(verts), json.dumps(pivot),
                   json.dumps(rot), radius)
            )
            self.assertFlatNear(
                got, py_skin_apply(verts, pivot, rot, radius))


if __name__ == "__main__":
    unittest.main(verbosity=2)
