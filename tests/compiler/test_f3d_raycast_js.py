"""Forge3D Wave B seat B66: tests for the raycasting / picking
sidecar ``runtime/f3d-raycast.js`` (Moeller-Trumbore ray/triangle,
ray casting and pixel picking, mirroring ``src/raycast.f90``).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_raycast_js.py

The size/existence checks always run. The numeric checks shell out
to ``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest reports
them as skipped, with the reason, rather than passing silently).

The numeric cases match the Fortran seat's cases: a cube built as
12 triangles (size 2, centred on the origin, in the vertex / face
order of ``create_cube`` in ``src/mesh.f90``, which is also the
order used by ``runtime/f3d.js``). Tolerances are 1e-9 where the
expected value is exact, else 1e-6.
"""

import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-raycast.js")
MAX_BYTES = 7680
NODE = shutil.which("node")

# Loaded before every snippet: expose `window` (as in a browser page
# that loads the sidecar after f3d.js), bind the export as `R`, and
# build the size-2 cube as a flat 12-triangle array `CUBE`
# (hardcoded verts + face list, Fortran create_cube order).
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_RAYCAST, 'utf8'));"
    "const R = globalThis.F3DRay;"
    "const assert = require('assert');"
    "const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);"
    "const near3 = (a, b, e) => a.length === 3"
    "  && a.every((x, i) => near(x, b[i], e));"
    "const P = [[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],"
    "  [-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]];"
    "const F = [[0,2,1],[0,3,2],[1,6,5],[1,2,6],[5,7,4],[5,6,7],"
    "  [4,3,0],[4,7,3],[3,6,2],[3,7,6],[4,1,5],[4,0,1]];"
    "const CUBE = [];"
    "for (const f of F) for (const i of f) CUBE.push(...P[i]);"
    "assert.strictEqual(CUBE.length, 12 * 9);"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_RAYCAST=JS_PATH)
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


class TestF3DRaycastFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-raycast.js is %d B, budget is %d B" % (size, MAX_BYTES),
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-raycast.js numeric tests not run"
)
class TestF3DRaycastNumeric(unittest.TestCase):
    def test_exports(self):
        run_node(
            "for (const k of ['rayTriangle','cast','pick'])"
            "  assert.strictEqual(typeof R[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.F3DRay, R);"
        )

    def test_cube_front_hit_exact(self):
        run_node(
            # Ray (0,0,5) -> (0,0,-1) at the size-2 cube: the front
            # (z = +1) face is exactly 4 units away, hit at the
            # face centre (0,0,1), which lies on the shared diagonal
            # of front triangles 4 and 5 -- the first one (index 4)
            # wins the exact tie.
            "const h = R.cast([0, 0, 5], [0, 0, -1], CUBE);"
            "assert.ok(h, 'expected a hit');"
            "assert.ok(near(h.t, 4, 1e-9), 't=' + h.t);"
            "assert.strictEqual(h.index, 4);"
            "assert.ok(near3(h.point, [0, 0, 1], 1e-9),"
            "  'point=' + h.point);"
            "assert.ok(near(h.point[2], 1, 1e-9));"
            "assert.ok(near(h.bary[0] + h.bary[1] + h.bary[2], 1, 1e-9));"
        )

    def test_miss_returns_null(self):
        run_node(
            # Ray passing above the cube, and a ray pointing away
            # from it: both miss. A single triangle off to the side
            # of the ray also misses.
            "assert.strictEqual(R.cast([0, 5, 5], [0, 0, -1], CUBE), null);"
            "assert.strictEqual(R.cast([0, 0, 5], [0, 0, 1], CUBE), null);"
            "assert.strictEqual(R.rayTriangle([0, 0, 1], [0, 0, -1],"
            "  [2, 0, 0], [3, 0, 0], [2, 1, 0]), null);"
            "assert.strictEqual(R.cast([0, 0, 5], [0, 0, -1], []), null);"
        )

    def test_centre_of_triangle_bary(self):
        run_node(
            # Ray through the centroid (1/3, 1/3) of the triangle
            # (0,0,0),(1,0,0),(0,1,0) from z=1: t == 1 exactly and
            # every barycentric coordinate is ~1/3.
            "const o = [1/3, 1/3, 1], d = [0, 0, -1];"
            "const tri = [[0, 0, 0], [1, 0, 0], [0, 1, 0]];"
            "const h = R.rayTriangle(o, d, ...tri);"
            "assert.ok(h, 'expected a hit');"
            "assert.ok(near(h.t, 1, 1e-9), 't=' + h.t);"
            "assert.ok(near(h.u, 1/3, 1e-9), 'u=' + h.u);"
            "assert.ok(near(h.v, 1/3, 1e-9), 'v=' + h.v);"
            "const c = R.cast(o, d, tri.flat());"
            "assert.ok(c && c.index === 0, 'cast=' + JSON.stringify(c));"
            "assert.ok(near(c.t, 1, 1e-9));"
            "assert.ok(near3(c.bary, [1/3, 1/3, 1/3], 1e-6),"
            "  'bary=' + c.bary);"
            "assert.ok(near3(c.point, [1/3, 1/3, 0], 1e-9));"
        )

    def test_both_windings_parallel_and_behind(self):
        run_node(
            # Both windings accepted: reversing v2/v3 gives the same
            # hit (with u/v swapped). A ray parallel to the triangle
            # plane (|det| < eps) and a triangle behind the ray
            # origin (t <= eps) both return null.
            "const o = [1/3, 1/3, 1], d = [0, 0, -1];"
            "const a = R.rayTriangle(o, d, [0,0,0], [1,0,0], [0,1,0]);"
            "const b = R.rayTriangle(o, d, [0,0,0], [0,1,0], [1,0,0]);"
            "assert.ok(a && b, 'both windings must hit');"
            "assert.ok(near(b.t, a.t, 1e-9));"
            "assert.ok(near(b.u, a.v, 1e-9) && near(b.v, a.u, 1e-9));"
            "assert.strictEqual(R.rayTriangle([0, 0, 1], [1, 0, 0],"
            "  [0, 0, 0], [1, 0, 0], [0, 1, 0]), null);"
            "assert.strictEqual(R.rayTriangle([0, 0, -5], [0, 0, -1],"
            "  [-1, -1, 0], [1, -1, 0], [0, 1, 0]), null);"
        )

    def test_nearest_t_wins(self):
        run_node(
            # Two triangles on the ray path, the FAR one first in
            # the array (z=0, t=5) and the NEAR one second (z=2,
            # t=3): the nearest t wins, with its own index.
            "const tris = ["
            "  -1,-1,0,  1,-1,0,  0,1,0,"
            "  -1,-1,2,  1,-1,2,  0,1,2];"
            "const h = R.cast([0, 0, 5], [0, 0, -1], tris);"
            "assert.ok(h, 'expected a hit');"
            "assert.ok(near(h.t, 3, 1e-9), 't=' + h.t);"
            "assert.strictEqual(h.index, 1);"
            "assert.ok(near3(h.point, [0, 0, 2], 1e-9));"
        )

    def test_pick_centre_hits_corner_misses(self):
        run_node(
            # Default camera (3,2.5,4) -> (0,0,0), up (0,1,0),
            # fov 60, 640x480 view of the size-2 cube: a pick
            # through the centre pixel (320,240) hits the cube
            # (on its z=+1 face), a pick through the corner pixel
            # (2,2) misses it entirely.
            "const cam = [[3, 2.5, 4], [0, 0, 0], [0, 1, 0]];"
            "const h = R.pick(320, 240, 640, 480,"
            "  cam[0], cam[1], cam[2], 60, CUBE);"
            "assert.ok(h, 'centre pick must hit the cube');"
            "assert.ok(h.t > 0);"
            "assert.ok(near(h.point[2], 1, 1e-6),"
            "  'point=' + h.point);"
            "assert.strictEqual(R.pick(2, 2, 640, 480,"
            "  cam[0], cam[1], cam[2], 60, CUBE), null);"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
