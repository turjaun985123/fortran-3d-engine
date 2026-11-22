"""Forge3D Wave C seat B79: tests for the orthographic camera
sidecar ``runtime/f3d-ortho.js`` (``F3DOrtho.ortho`` /
``fromSize`` / ``project``, mirroring ``mat4_ortho`` in
``src/camera_ortho.f90``).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_ortho_js.py

The size/existence checks always run. The numeric checks shell
out to ``node -e`` snippets that load the sidecar; when ``node``
is not on PATH they are SKIPPED LOUDLY via ``skipUnless``
(unittest reports them as skipped, with the reason, rather than
passing silently).

Every expected matrix entry and projected point is computed
INDEPENDENTLY in Python below (``py_ortho`` / ``py_project``)
from the OpenGL-style formulas, then passed into the node
snippets -- the JS is never checked against itself:

    x_ndc =  2x/(r-l) - (r+l)/(r-l)
    y_ndc =  2y/(t-b) - (t+b)/(t-b)
    z_ndc = -2z/(f-n) - (f+n)/(f-n)     (view space: front = -z,
                                         near at z=-near -> -1,
                                         far  at z=-far  -> +1)

Matrix layout is the 16-element column-major order shared with
``mat4_perspective`` (``src/math_3d.f90``): index = col*4 + row,
so the translation column lands at indices 12, 13, 14 and the
homogeneous term at 15.
"""

import json
import os
import shutil
import subprocess
import sys
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-ortho.js")
MAX_BYTES = 6144
NODE = shutil.which("node")


def py_ortho(left, right, bottom, top, near, far):
    """Independent Python ortho matrix, column-major 16-list."""
    rl, tb, fn = right - left, top - bottom, far - near
    m = [0.0] * 16
    m[0] = 2.0 / rl
    m[5] = 2.0 / tb
    m[10] = -2.0 / fn
    m[12] = -(right + left) / rl
    m[13] = -(top + bottom) / tb
    m[14] = -(far + near) / fn
    m[15] = 1.0
    return m


def py_project(m, x, y, z):
    """Independent Python apply + w-divide (column-major m)."""
    cx = m[0] * x + m[4] * y + m[8] * z + m[12]
    cy = m[1] * x + m[5] * y + m[9] * z + m[13]
    cz = m[2] * x + m[6] * y + m[10] * z + m[14]
    w = m[3] * x + m[7] * y + m[11] * z + m[15]
    return [cx / w, cy / w, cz / w]


# Loaded before every snippet: expose `window` (as in a browser
# page that loads the sidecar after f3d.js) and bind the export
# as `O`. EXPECTED matrices / points are injected per-test as
# JSON literals computed by the Python helpers above.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_ORTHO, 'utf8'));"
    "const O = globalThis.F3DOrtho;"
    "const assert = require('assert');"
    "const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);"
    "const nearArr = (a, b, e) => a.length === b.length"
    "  && a.every((x, i) => near(x, b[i], e));"
)


def js_num_list(values):
    return json.dumps([float(v) for v in values])


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_ORTHO=JS_PATH)
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


class TestF3DOrthoFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-ortho.js is %d B, budget is %d B" % (size, MAX_BYTES),
        )

    def test_header_documents_conventions(self):
        with open(JS_PATH, "r", encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("camera_ortho.f90", text)
        self.assertIn("F3DOrtho", text)
        self.assertIn("column-major", text)


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-ortho.js numeric tests not run"
)
class TestF3DOrthoNumeric(unittest.TestCase):
    def test_exports(self):
        run_node(
            "for (const k of ['ortho','fromSize','project'])"
            "  assert.strictEqual(typeof O[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.F3DOrtho, O);"
            "const m = O.ortho(-1, 1, -1, 1, 0.1, 100);"
            "assert.ok(Array.isArray(m) && m.length === 16,"
            "  'ortho must return 16 elements');"
        )

    def test_matrix_entries_symmetric_and_asymmetric(self):
        for args in [(-4, 4, -3, 3, 0.1, 100),
                     (-2, 6, -1, 3, 0.5, 10),
                     (0, 640, 0, 480, -1, 1)]:
            expected = js_num_list(py_ortho(*args))
            run_node(
                "const m = O.ortho(%s);"
                "assert.ok(nearArr(m, %s, 1e-12),"
                "  'matrix=' + m);" % (
                    ", ".join(repr(float(a)) for a in args), expected)
            )

    def test_centre_projects_to_origin(self):
        # Box centre in view space: ((l+r)/2, (b+t)/2, -(n+f)/2)
        # -- z is negative because front = -z. It must land on
        # the NDC origin.
        left, right, bottom, top, near_, far = -2, 6, -1, 3, 0.5, 10
        m = py_ortho(left, right, bottom, top, near_, far)
        centre = [(left + right) / 2, (bottom + top) / 2,
                  -(near_ + far) / 2]
        for got in py_project(m, *centre):
            self.assertAlmostEqual(got, 0.0, places=12)
        run_node(
            "const m = O.ortho(-2, 6, -1, 3, 0.5, 10);"
            "const p = O.project(m, %s);"
            "assert.ok(nearArr(p, [0, 0, 0], 1e-12), 'p=' + p);"
            # The [x, y, z] array form of project() agrees.
            "assert.ok(nearArr(O.project(m, [%s]), p, 1e-12));"
            % (", ".join(repr(c) for c in centre),
               ", ".join(repr(c) for c in centre))
        )

    def test_corners_project_to_plus_minus_one(self):
        m_args = (-4, 4, -3, 3, 0.1, 100)
        m = py_ortho(*m_args)
        cases = [(-4, -3, -0.1, [-1, -1, -1]),
                 (4, 3, -0.1, [1, 1, -1]),
                 (-4, 3, -100, [-1, 1, 1]),
                 (4, -3, -100, [1, -1, 1])]
        for x, y, z, want in cases:
            got = py_project(m, x, y, z)
            for g, w in zip(got, want):
                self.assertAlmostEqual(g, w, places=12)
        run_node(
            "const m = O.ortho(-4, 4, -3, 3, 0.1, 100);"
            + "".join(
                "assert.ok(nearArr(O.project(m, %r, %r, %r), %s,"
                " 1e-12), 'corner %d');"
                % (x, y, z, js_num_list(want), i)
                for i, (x, y, z, want) in enumerate(cases))
        )

    def test_near_far_depth_mapping(self):
        # z_view = -near -> z_ndc = -1; z_view = -far -> +1;
        # the depth midpoint -(near+far)/2 -> 0. Sign check
        # against the perspective convention (front = -z).
        run_node(
            "const m = O.ortho(-4, 4, -3, 3, 0.1, 100);"
            "assert.ok(near(O.project(m, 0, 0, -0.1)[2], -1, 1e-12),"
            "  'near plane must map to -1');"
            "assert.ok(near(O.project(m, 0, 0, -100)[2], 1, 1e-12),"
            "  'far plane must map to +1');"
            "assert.ok(near(O.project(m, 0, 0, -50.05)[2], 0, 1e-9),"
            "  'depth midpoint must map to 0');"
            "assert.strictEqual(m[15], 1);"
            "assert.strictEqual(m[3], 0);"
            "assert.strictEqual(m[7], 0);"
            "assert.strictEqual(m[11], 0);"
        )

    def test_xy_independent_of_distance(self):
        # The defining ortho property (and its difference from
        # perspective): the same view x/y at the near plane and
        # at the far plane project to the SAME NDC x/y.
        m = py_ortho(-4, 4, -3, 3, 0.1, 100)
        p_near = py_project(m, 1.5, -0.75, -0.1)
        p_far = py_project(m, 1.5, -0.75, -100)
        self.assertAlmostEqual(p_near[0], p_far[0], places=12)
        self.assertAlmostEqual(p_near[1], p_far[1], places=12)
        self.assertNotAlmostEqual(p_near[2], p_far[2], places=6)
        run_node(
            "const m = O.ortho(-4, 4, -3, 3, 0.1, 100);"
            "const a = O.project(m, 1.5, -0.75, -0.1);"
            "const b = O.project(m, 1.5, -0.75, -100);"
            "assert.ok(near(a[0], b[0], 1e-12)"
            "  && near(a[1], b[1], 1e-12),"
            "  'x/y must not depend on z: ' + a + ' vs ' + b);"
            "assert.ok(nearArr(a, %s, 1e-12), 'a=' + a);"
            "assert.ok(nearArr(b, %s, 1e-12), 'b=' + b);"
            % (js_num_list(p_near), js_num_list(p_far))
        )

    def test_from_size(self):
        # size = frustum height 4, aspect 2 -> half_h = 2,
        # half_w = 4: identical to ortho(-4, 4, -2, 2, n, f),
        # and its edges project to +/-1.
        expected = js_num_list(py_ortho(-4, 4, -2, 2, 0.1, 50))
        run_node(
            "const m = O.fromSize(4, 2, 0.1, 50);"
            "assert.ok(nearArr(m, %s, 1e-12), 'matrix=' + m);"
            "assert.ok(nearArr(O.project(m, 4, 2, -0.1),"
            "  [1, 1, -1], 1e-12));"
            "assert.ok(nearArr(O.project(m, -4, -2, -50),"
            "  [-1, -1, 1], 1e-12));"
            "assert.ok(nearArr(O.project(m, 0, 0, -25.05),"
            "  [0, 0, 0], 1e-9));"
            # Square aspect: half_w == half_h.
            "assert.ok(nearArr(O.fromSize(6, 1, 1, 10),"
            "  %s, 1e-12));"
            % (expected, js_num_list(py_ortho(-3, 3, -3, 3, 1, 10)))
        )


if shutil.which("node") is None:
    sys.stderr.write(
        "\n*** SKIP LOUDLY: node NOT FOUND -- the numeric "
        "f3d-ortho.js assertions in test_f3d_ortho_js.py are "
        "SKIPPED; only the existence/size/header checks ran. "
        "Install node and re-run to verify the ortho "
        "formulas. ***\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
