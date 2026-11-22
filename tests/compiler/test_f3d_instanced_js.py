"""Forge3D Wave C seat B82: tests for the instancing sidecar
``runtime/f3d-instanced.js`` (JS mirror of the Fortran instancing
data model, seat B81 / MASTER-PLAN parity row 22: ONE shared base
geometry plus a list of per-instance transforms).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_instanced_js.py

The existence check always runs. The numeric checks shell out to
``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless``.

Every expected value is RECOMPUTED IN PYTHON below: the cube's
base vertex stream from the corner/face tables in src/mesh.f90
(identical in f3d.js's cube builder), TRS application by the
sequential scale -> Rz -> Rx -> Ry -> translate formulas of
f3d.js's xform(), and compose matrices by an independent Python
4x4 multiply of T * Ry * Rx * Rz * S (mat4_compose_trs in
src/math_3d.f90), flattened column-major (the P16 sec. 7.3 layout:
translation at indices 12, 13, 14).
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
JS_PATH = os.path.join(REPO, "runtime", "f3d-instanced.js")
NODE = shutil.which("node")
TOL = 1e-12

PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_INSTANCED, 'utf8'));"
    "const I = globalThis.F3DInstanced;"
    "const assert = require('assert');"
    "const out = (x) => console.log(JSON.stringify(x));"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; return stdout."""
    env = dict(os.environ, F3D_INSTANCED=JS_PATH)
    proc = subprocess.run(
        [NODE, "-e", PREAMBLE + snippet],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(
            "node snippet failed (rc=%d):\n%s\n%s"
            % (proc.returncode, proc.stdout, proc.stderr)
        )
    return proc.stdout.strip()


def run_json(snippet):
    return json.loads(run_node(snippet))


# ------------------------------------------------------------------
# Independent Python reference: cube geometry + TRS math.
# ------------------------------------------------------------------

# create_cube in src/mesh.f90 (size 2, h = 1): 8 corners, 12 tris.
# Face table is 0-based here; mesh.f90's 1-based table and f3d.js's
# F table agree exactly.
CORNERS = [
    [-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, -1.0],
    [-1.0, 1.0, -1.0], [-1.0, -1.0, 1.0], [1.0, -1.0, 1.0],
    [1.0, 1.0, 1.0], [-1.0, 1.0, 1.0],
]
FACES = [
    [0, 2, 1], [0, 3, 2], [1, 6, 5], [1, 2, 6],
    [5, 7, 4], [5, 6, 7], [4, 3, 0], [4, 7, 3],
    [3, 6, 2], [3, 7, 6], [4, 1, 5], [4, 0, 1],
]


def cube_geometry():
    """f3d.js build()-shaped cube: {tris: [[a, b, c, faceIdx], ...]}."""
    return {"tris": [[list(CORNERS[a]), list(CORNERS[b]),
                      list(CORNERS[c]), i >> 1]
                     for i, (a, b, c) in enumerate(FACES)]}


def base_vertices():
    """The cube's baked base stream: 36 vertices, face order."""
    return [list(CORNERS[i]) for face in FACES for i in face]


def flat(verts):
    return [c for v in verts for c in v]


def ref_apply_trs(p, pos, rot, scl):
    """f3d.js xform(): scale, Rz, Rx, Ry, translate (degrees)."""
    if isinstance(scl, (int, float)):
        scl = [scl, scl, scl]
    x, y, z = p[0] * scl[0], p[1] * scl[1], p[2] * scl[2]
    c, s = math.cos(math.radians(rot[2])), math.sin(math.radians(rot[2]))
    x, y = x * c - y * s, x * s + y * c               # Rz
    c, s = math.cos(math.radians(rot[0])), math.sin(math.radians(rot[0]))
    y, z = y * c - z * s, y * s + z * c               # Rx
    c, s = math.cos(math.radians(rot[1])), math.sin(math.radians(rot[1]))
    x, z = x * c + z * s, -x * s + z * c              # Ry
    return [x + pos[0], y + pos[1], z + pos[2]]


def _matmul(a, b):
    return [[sum(a[r][k] * b[k][c] for k in range(4))
             for c in range(4)] for r in range(4)]


def ref_compose(pos, rot, scl):
    """T * Ry * Rx * Rz * S as a flat COLUMN-MAJOR 16 (row-major
    matrices built and multiplied independently in Python)."""
    if isinstance(scl, (int, float)):
        scl = [scl, scl, scl]
    cx, sx = math.cos(math.radians(rot[0])), math.sin(math.radians(rot[0]))
    cy, sy = math.cos(math.radians(rot[1])), math.sin(math.radians(rot[1]))
    cz, sz = math.cos(math.radians(rot[2])), math.sin(math.radians(rot[2]))
    t = [[1, 0, 0, pos[0]], [0, 1, 0, pos[1]], [0, 0, 1, pos[2]],
         [0, 0, 0, 1]]
    ry = [[cy, 0, sy, 0], [0, 1, 0, 0], [-sy, 0, cy, 0], [0, 0, 0, 1]]
    rx = [[1, 0, 0, 0], [0, cx, -sx, 0], [0, sx, cx, 0], [0, 0, 0, 1]]
    rz = [[cz, -sz, 0, 0], [sz, cz, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    s = [[scl[0], 0, 0, 0], [0, scl[1], 0, 0], [0, 0, scl[2], 0],
         [0, 0, 0, 1]]
    m = _matmul(_matmul(_matmul(_matmul(t, ry), rx), rz), s)
    return [m[r][c] for c in range(4) for r in range(4)]  # column-major


def ref_apply_matrix(m16, p):
    """Apply a flat column-major matrix to a point."""
    x, y, z = p
    return [
        m16[0] * x + m16[4] * y + m16[8] * z + m16[12],
        m16[1] * x + m16[5] * y + m16[9] * z + m16[13],
        m16[2] * x + m16[6] * y + m16[10] * z + m16[14],
    ]


def assert_flat_close(tc, got, expected):
    tc.assertEqual(len(got), len(expected),
                   "length %d != %d" % (len(got), len(expected)))
    for i, (g, e) in enumerate(zip(got, expected)):
        tc.assertAlmostEqual(g, e, delta=TOL,
                             msg="index %d: %r != %r" % (i, g, e))


GEO_JSON = json.dumps(cube_geometry())


class TestF3DInstancedFile(unittest.TestCase):
    def test_file_exists(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)


@unittest.skipUnless(
    NODE,
    "SKIPPED: node not on PATH - f3d-instanced.js numeric tests not run",
)
class TestF3DInstancedNumeric(unittest.TestCase):
    def test_exports(self):
        run_node(
            "for (const k of ['create', 'add', 'count', 'matrices',"
            "  'compose', 'buildPositions', 'expand'])"
            "  assert.strictEqual(typeof I[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.F3DInstanced, I);"
        )

    def test_identity_instance_reproduces_base_vertices(self):
        got = run_json(
            "const s = I.create(%s); I.add(s); out(I.buildPositions(s));"
            % GEO_JSON
        )
        # Exact, not just close: identity must reproduce the input.
        self.assertEqual(got, flat(base_vertices()))
        got_expand = run_json(
            "const s = I.create(%s); I.add(s, null); out(I.expand(s));"
            % GEO_JSON
        )
        self.assertEqual(got_expand, base_vertices())

    def test_translation_offsets_exactly(self):
        got = run_json(
            "const s = I.create(%s);"
            "I.add(s, I.compose(10, -2, 3.5, 0, 0, 0, 1));"
            "out(I.buildPositions(s));" % GEO_JSON
        )
        expected = flat([ref_apply_trs(v, [10, -2, 3.5], [0, 0, 0], 1)
                         for v in base_vertices()])
        self.assertEqual(got, expected)  # pure offsets: exact
        # And via the TRS-descriptor form of add().
        got_trs = run_json(
            "const s = I.create(%s);"
            "I.add(s, {pos: [10, -2, 3.5]}); out(I.buildPositions(s));"
            % GEO_JSON
        )
        self.assertEqual(got_trs, expected)

    def test_three_instances_expand_to_36_tris(self):
        got = run_json(
            "const s = I.create(%s);"
            "I.add(s, {pos: [0, 0, 0]});"
            "I.add(s, {pos: [5, 0, 0]});"
            "I.add(s, I.compose(-5, 2, 0, 0, 90, 0, 2));"
            "out({count: I.count(s), pos: I.buildPositions(s),"
            "     verts: I.expand(s), tris: I.expandTriangles(s)});"
            % GEO_JSON
        )
        self.assertEqual(got["count"], 3)
        self.assertEqual(len(got["tris"]), 36)        # 3 x 12 tris
        self.assertEqual(len(got["verts"]), 36 * 3)   # 108 vertices
        self.assertEqual(len(got["pos"]), 36 * 3 * 3)  # 324 numbers
        # Instance-major order, each block independently expected.
        trss = [([0, 0, 0], [0, 0, 0], 1), ([5, 0, 0], [0, 0, 0], 1),
                ([-5, 2, 0], [0, 90, 0], 2)]
        expected = []
        for pos, rot, scl in trss:
            expected += [ref_apply_trs(v, pos, rot, scl)
                         for v in base_vertices()]
        assert_flat_close(self, got["pos"], flat(expected))
        assert_flat_close(self, flat(got["verts"]), flat(expected))

    def test_shared_geometry_invariant(self):
        # The set holds a REFERENCE: in-place coordinate edits, a
        # replaced vertex and a pushed triangle must all show up.
        got = run_json(
            "const geo = %s;"
            "const s = I.create(geo);"
            "assert.strictEqual(s.geometry, geo, 'not a reference');"
            "I.add(s);"
            "const before = I.buildPositions(s);"
            "geo.tris[0][0][0] = 7.25;"        # mutate in place
            "geo.tris[0][1] = [9, 8, 7];"      # replace a vertex
            "geo.tris.push([[1, 2, 3], [4, 5, 6], [7, 8, 10], 0]);"
            "out({before: before, after: I.buildPositions(s)});"
            % GEO_JSON
        )
        self.assertEqual(got["before"], flat(base_vertices()))
        expected_geo = cube_geometry()
        expected_geo["tris"][0][0][0] = 7.25
        expected_geo["tris"][0][1] = [9, 8, 7]
        expected_geo["tris"].append([[1, 2, 3], [4, 5, 6], [7, 8, 10], 0])
        expected = [list(v) for tri in expected_geo["tris"]
                    for v in tri[:3]]
        self.assertEqual(got["after"], flat(expected))
        self.assertEqual(len(got["after"]), (36 + 3) * 3)

    def test_compose_matches_python_matrix(self):
        cases = [
            ([0, 0, 0], [0, 0, 0], 1),
            ([1, 2, 3], [0, 90, 0], 1),
            ([-4, 0.5, 7], [30, 45, 60], [2, 3, 0.5]),
            ([0, -1, 0], [90, 0, 0], 2),
            ([3, 3, 3], [0, 0, -90], [1, 0.25, 1]),
        ]
        for pos, rot, scl in cases:
            got = run_json(
                "out(I.compose(%s, %s, %s, %s, %s, %s, %s));"
                % (json.dumps(pos[0]), json.dumps(pos[1]),
                   json.dumps(pos[2]), json.dumps(rot[0]),
                   json.dumps(rot[1]), json.dumps(rot[2]),
                   json.dumps(scl))
            )
            assert_flat_close(self, got, ref_compose(pos, rot, scl))

    def test_matrix_layout_is_column_major(self):
        m = run_json("out(I.compose(10, 20, 30, 0, 0, 0, 1));")
        # Translation lives at 12/13/14; diagonal is the scale.
        self.assertEqual(m[12:], [10, 20, 30, 1])
        self.assertEqual([m[0], m[5], m[10]], [1, 1, 1])
        # Ry(+90deg): +X axis maps to -Z (Fortran mat4_rotate_y:
        # x' = x*c + z*s, z' = -x*s + z*c), pinned via the matrix.
        m = run_json("out(I.compose(0, 0, 0, 0, 90, 0, 1));")
        assert_flat_close(self, ref_apply_matrix(m, [1, 0, 0]),
                          [0.0, 0.0, -1.0])
        assert_flat_close(self, m, ref_compose([0, 0, 0], [0, 90, 0], 1))

    def test_add_raw_matrix_and_matrices_roundtrip(self):
        m = ref_compose([2, -3, 4], [15, 25, 35], [1.5, 1, 0.75])
        got = run_json(
            "const s = I.create(%s); I.add(s, %s); I.add(s);"
            "out({count: I.count(s), mats: I.matrices(s),"
            "     pos: I.buildPositions(s)});"
            % (GEO_JSON, json.dumps(m))
        )
        self.assertEqual(got["count"], 2)
        assert_flat_close(self, got["mats"][0], m)
        assert_flat_close(self, got["mats"][1],
                          ref_compose([0, 0, 0], [0, 0, 0], 1))
        expected = ([ref_apply_matrix(m, v) for v in base_vertices()]
                    + base_vertices())
        assert_flat_close(self, got["pos"], flat(expected))

    def test_matrices_returns_copies(self):
        run_node(
            "const s = I.create(%s); I.add(s, {pos: [1, 2, 3]});"
            "const ms = I.matrices(s); ms[0][12] = 999;"
            "assert.strictEqual(I.matrices(s)[0][12], 1);"
            # The caller's matrix array is copied at add() time too.
            "const raw = I.compose(4, 5, 6, 0, 0, 0, 1); I.add(s, raw);"
            "raw[12] = 999;"
            "assert.strictEqual(I.matrices(s)[1][12], 4);"
            "assert.strictEqual(I.count(s), 2);" % GEO_JSON
        )

    def test_empty_set_and_empty_geometry(self):
        got = run_json(
            "const s = I.create(%s);"
            "out({count: I.count(s), mats: I.matrices(s),"
            "     pos: I.buildPositions(s),"
            "     none: I.buildPositions(I.create(null))});" % GEO_JSON
        )
        self.assertEqual(got, {"count": 0, "mats": [], "pos": [],
                               "none": []})

    def test_geometry_shape_variants(self):
        # Bare triangle list, flat positions, and positions+indices
        # all yield the same base stream for a single triangle.
        tri = [[0, 0, 0], [2, 0, 0], [0, 2, 0]]
        expected = flat([ref_apply_trs(v, [1, 1, 1], [0, 0, 0], 1)
                         for v in tri])
        for geo in ([tri], {"positions": flat(tri)},
                    {"positions": flat(tri), "indices": [0, 1, 2]},
                    {"triangles": [{"v": tri}]}):
            got = run_json(
                "const s = I.create(%s); I.add(s, {pos: [1, 1, 1]});"
                "out(I.buildPositions(s));" % json.dumps(geo)
            )
            self.assertEqual(got, expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
