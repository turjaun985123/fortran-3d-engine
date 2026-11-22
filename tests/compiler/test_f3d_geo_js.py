"""Forge3D Wave D seat D09: tests for the geometry sidecar
``runtime/f3d-geo.js``, the JS mirror of the Wave D Fortran
geometry builders.

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_geo_js.py

The existence check always runs. The numeric checks shell out to
``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest
reports them as skipped, with the reason, rather than passing
silently).

Expected triangle counts are the exact formulas from the
sidecar header (computed in Python here, never copied from the
JS output), so the two sides cross-check each other:

    circle       2*seg                       (double-sided fan)
    ring         4*seg                       (double-sided quads)
    capsule      2*seg + 2*seg*(2*hr - 1)    (seg rounded up to
                                              a multiple of 4,
                                              hr = seg/4)
    tube         (n-1)*seg*2 + 2*seg         (n path points)
    lathe        (n-1)*seg*2                 (n profile points)
    extrude      4*n - 4                     (n shape points)
    tetrahedron  4, octahedron 8, icosahedron 20, dodecahedron 36
    torusknot    seg*tseg*2                  ((p, q) = (2, 3))
"""

import json
import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-geo.js")
NODE = shutil.which("node")

BUILDERS = [
    "circle", "ring", "capsule", "tube", "lathe", "extrude",
    "tetrahedron", "octahedron", "icosahedron", "dodecahedron",
    "torusknot",
]

# Loaded before every snippet: expose `window` (as in a browser
# page that loads the sidecar after f3d.js) and bind the export
# as `G`. Note f3d.js itself is NOT loaded: the sidecar must
# stand alone.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_GEO, 'utf8'));"
    "const G = globalThis.Forge3DGeo;"
    "const assert = require('assert');"
)

# JS helpers shared by the numeric snippets: structural format
# check plus a finiteness sweep over every coordinate.
HELPERS = (
    "function checkTris(tris) {"
    "  assert.ok(Array.isArray(tris), 'builder must return array');"
    "  tris.forEach(function (t) {"
    "    assert.strictEqual(t.length, 4, 'tri is [a,b,c,faceIdx]');"
    "    for (let i = 0; i < 3; i++) {"
    "      assert.strictEqual(t[i].length, 3, 'vertex is [x,y,z]');"
    "      t[i].forEach(function (x) {"
    "        assert.ok(Number.isFinite(x), 'coordinate not finite');"
    "      });"
    "    }"
    "    assert.ok(Number.isInteger(t[3]), 'faceIdx is an integer');"
    "  });"
    "}"
    "function count(name, args) {"
    "  const tris = G.builders[name].apply(null, args);"
    "  checkTris(tris);"
    "  assert.strictEqual(tris.length,"
    "    G.triCount[name].apply(null, args),"
    "    name + ': builder/triCount disagree');"
    "  return tris.length;"
    "}"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_GEO=JS_PATH)
    proc = subprocess.run(
        [NODE, "-e", PREAMBLE + HELPERS + snippet],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(
            "node snippet failed (rc=%d):\n%s\n%s"
            % (proc.returncode, proc.stdout, proc.stderr)
        )
    return proc


def capsule_count(seg):
    seg = max(4, -(-max(1, seg) // 4) * 4)  # round up to mult of 4
    hr = seg // 4
    return 2 * seg + 2 * seg * (2 * hr - 1)


class TestF3DGeoFile(unittest.TestCase):
    def test_file_exists(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)


@unittest.skipUnless(
    NODE,
    "SKIPPED: node not on PATH - f3d-geo.js numeric tests not run",
)
class TestF3DGeoNumeric(unittest.TestCase):
    def test_exports_all_builders(self):
        run_node(
            "assert.strictEqual(window.Forge3DGeo, G);"
            "assert.strictEqual(typeof G.builders, 'object');"
            "assert.strictEqual(typeof G.triCount, 'object');"
            + "".join(
                "assert.strictEqual(typeof G.builders.%s, 'function',"
                " '%s builder missing');"
                "assert.strictEqual(typeof G.triCount.%s, 'function',"
                " '%s triCount missing');" % (b, b, b, b)
                for b in BUILDERS
            )
        )

    def test_default_tri_counts_exact(self):
        expected = {
            "circle": 2 * 16,
            "ring": 4 * 16,
            "capsule": capsule_count(16),
            "tube": (2 - 1) * 8 * 2 + 2 * 8,
            "lathe": (4 - 1) * 16 * 2,
            "extrude": 4 * 4 - 4,
            "tetrahedron": 4,
            "octahedron": 8,
            "icosahedron": 20,
            "dodecahedron": 36,
            "torusknot": 48 * 12 * 2,
        }
        for name, want in expected.items():
            run_node(
                "assert.strictEqual(count(%s, []), %d);"
                % (json.dumps(name), want)
            )

    def test_parametric_tri_counts_exact(self):
        cases = [
            ("circle", [2, 7], 2 * 7),
            ("circle", [0.5, 3], 2 * 3),
            ("ring", [0.25, 1.5, 9], 4 * 9),
            ("capsule", [1, 2, 16], capsule_count(16)),
            ("capsule", [0.5, 1, 5], capsule_count(5)),
            ("capsule", [1, 3, 18], capsule_count(18)),
            ("tube", [0.2, 10, [[0, 0, 0], [1, 0, 0], [1, 1, 0],
                                [1, 1, 1]]], (4 - 1) * 10 * 2 + 2 * 10),
            ("tube", [0.1, 6, [[0, 0, 0], [0, 2, 0]]],
             (2 - 1) * 6 * 2 + 2 * 6),
            ("lathe", [12, [[0.5, -1], [1, -0.3], [0.8, 0.4],
                            [0.6, 0.8], [0.4, 1]]], (5 - 1) * 12 * 2),
            ("extrude", [2, [[0, 0], [1, 0], [0, 1]]], 4 * 3 - 4),
            ("extrude", [1, [[0, 0], [2, 0], [2, 1], [1, 2],
                             [0, 1]]], 4 * 5 - 4),
            ("tetrahedron", [2], 4),
            ("octahedron", [0.5], 8),
            ("icosahedron", [3], 20),
            ("dodecahedron", [1.5], 36),
            ("torusknot", [2, 0.3, 30, 10], 30 * 10 * 2),
            ("torusknot", [1, 0.2, 16, 8], 16 * 8 * 2),
        ]
        for name, args, want in cases:
            run_node(
                "assert.strictEqual(count(%s, %s), %d);"
                % (json.dumps(name), json.dumps(args), want)
            )

    def test_no_nan_or_degenerate_anywhere(self):
        # checkTris (in count) already asserts finite coordinates;
        # here every triangle must also have positive area.
        run_node(
            "function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}"
            "function cross(a,b){return[a[1]*b[2]-a[2]*b[1],"
            "a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];}"
            "const calls = ["
            " ['circle',[1,16]], ['ring',[0.5,1,16]],"
            " ['capsule',[1,2,16]], ['capsule',[0.3,0.7,8]],"
            " ['tube',[0.2,10,[[0,0,0],[1,0,0],[1,1,0],[1,1,1]]]],"
            " ['lathe',[16,[[0.5,-1],[1,-0.3],[0.8,0.4],[0.4,1]]]],"
            " ['extrude',[1,[[0,0],[2,0],[2,1],[0,1]]]],"
            " ['tetrahedron',[1]], ['octahedron',[1]],"
            " ['icosahedron',[1]], ['dodecahedron',[1]],"
            " ['torusknot',[1,0.35,48,12]]];"
            "calls.forEach(function (c) {"
            "  const tris = G.builders[c[0]].apply(null, c[1]);"
            "  checkTris(tris);"
            "  tris.forEach(function (t) {"
            "    const n = cross(sub(t[1],t[0]), sub(t[2],t[0]));"
            "    assert.ok(Math.hypot(n[0],n[1],n[2]) > 1e-12,"
            "      c[0] + ': degenerate triangle');"
            "  });"
            "});"
        )

    def test_polyhedra_vertices_at_circumradius(self):
        run_node(
            "['tetrahedron','octahedron','icosahedron',"
            " 'dodecahedron'].forEach(function (name) {"
            "  [1, 2].forEach(function (r) {"
            "    const seen = new Set();"
            "    G.builders[name](r).forEach(function (t) {"
            "      for (let i = 0; i < 3; i++) {"
            "        const v = t[i];"
            "        assert.ok(Math.abs(Math.hypot(v[0],v[1],v[2]) - r)"
            "          < 1e-6, name + ': vertex off circumradius');"
            "        seen.add(v.map(function (x) {"
            "          return x.toFixed(6); }).join(','));"
            "      }"
            "    });"
            "    const want = {tetrahedron: 4, octahedron: 6,"
            "      icosahedron: 12, dodecahedron: 20}[name];"
            "    assert.strictEqual(seen.size, want,"
            "      name + ': unique vertex count');"
            "  });"
            "});"
        )

    def test_polyhedra_outward_winding(self):
        # For a convex solid centred on the origin, every face
        # normal must point away from the centre:
        # dot(normal, centroid) > 0.
        run_node(
            "function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}"
            "function cross(a,b){return[a[1]*b[2]-a[2]*b[1],"
            "a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];}"
            "function dot(a,b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}"
            "['tetrahedron','octahedron','icosahedron',"
            " 'dodecahedron'].forEach(function (name) {"
            "  G.builders[name](1).forEach(function (t) {"
            "    const n = cross(sub(t[1],t[0]), sub(t[2],t[0]));"
            "    const c = [0,1,2].map(function (i) {"
            "      return (t[0][i]+t[1][i]+t[2][i]) / 3; });"
            "    assert.ok(dot(n, c) > 0,"
            "      name + ': inward-wound face');"
            "  });"
            "});"
        )

    def test_circle_and_ring_lie_in_xz_plane(self):
        run_node(
            "G.builders.circle(2, 8).forEach(function (t) {"
            "  t.slice(0, 3).forEach(function (v) {"
            "    assert.strictEqual(v[1], 0, 'circle off XZ plane');"
            "    assert.ok(Math.hypot(v[0], v[2]) === 0 ||"
            "      Math.abs(Math.hypot(v[0], v[2]) - 2) < 1e-9);"
            "  }); });"
            "G.builders.ring(0.5, 1.5, 8).forEach(function (t) {"
            "  t.slice(0, 3).forEach(function (v) {"
            "    assert.strictEqual(v[1], 0, 'ring off XZ plane');"
            "    const d = Math.hypot(v[0], v[2]);"
            "    assert.ok(Math.abs(d - 0.5) < 1e-9 ||"
            "      Math.abs(d - 1.5) < 1e-9, 'ring radius wrong');"
            "  }); });"
        )

    def test_extrude_winding_normalised(self):
        # The same shape in CW and CCW order must produce the
        # same outward geometry: top cap normal +Y, bottom -Y,
        # and identical triangle counts.
        run_node(
            "function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}"
            "function cross(a,b){return[a[1]*b[2]-a[2]*b[1],"
            "a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];}"
            "const ccw = [[0,0],[2,0],[2,1],[0,1]];"
            "const cw = ccw.slice().reverse();"
            "[ccw, cw].forEach(function (shape) {"
            "  const tris = G.builders.extrude(1, shape);"
            "  assert.strictEqual(tris.length, 12);"
            "  tris.forEach(function (t) {"
            "    const n = cross(sub(t[1],t[0]), sub(t[2],t[0]));"
            "    if (t[3] === 1) assert.ok(n[1] > 0, 'top cap not +Y');"
            "    if (t[3] === 2) assert.ok(n[1] < 0, 'bottom cap not -Y');"
            "    t.slice(0, 3).forEach(function (v) {"
            "      assert.ok(v[1] === 0 || v[1] === 1);"
            "    });"
            "  });"
            "});"
        )

    def test_capsule_extents(self):
        # radius 1, height 2: total Y extent is +/-(1 + 1) = +/-2,
        # and every vertex is within radius 1 of the Y axis in XZ.
        run_node(
            "let mx = 0;"
            "G.builders.capsule(1, 2, 16).forEach(function (t) {"
            "  t.slice(0, 3).forEach(function (v) {"
            "    mx = Math.max(mx, Math.abs(v[1]));"
            "    assert.ok(Math.hypot(v[0], v[2]) <= 1 + 1e-9);"
            "  }); });"
            "assert.ok(Math.abs(mx - 2) < 1e-9,"
            "  'capsule half-height must be height/2 + radius');"
        )

    def test_registry_hook_is_guarded(self):
        # With an F3D host present the sidecar registers its
        # builders into it; the main PREAMBLE loads without any
        # host at all, which the other tests already prove safe.
        run_node(
            "globalThis.F3D = {};"
            "eval(require('fs').readFileSync("
            "  process.env.F3D_GEO, 'utf8'));"
            "assert.strictEqual(typeof globalThis.F3D.builders"
            "  .circle, 'function');"
            "assert.strictEqual(globalThis.F3D.builders.torusknot,"
            "  globalThis.Forge3DGeo.builders.torusknot);"
            "assert.strictEqual(globalThis.F3D.geo,"
            "  globalThis.Forge3DGeo);"
            "delete globalThis.F3D;"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
