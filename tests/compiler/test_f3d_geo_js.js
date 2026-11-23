'use strict';
/* Port of test_f3d_geo_js.py (Forge3D Wave D seat D09) to plain
 * Node.js: tests for the geometry sidecar runtime/f3d-geo.js, the
 * JS mirror of the Wave D Fortran geometry builders.
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_geo_js.js
 *
 * The existence check always runs. The numeric checks load the
 * sidecar in-process (the Python original shelled out to `node -e`
 * snippets).
 *
 * Expected triangle counts are the exact formulas from the
 * sidecar header (computed in JS here, never copied from the
 * JS output), so the two sides cross-check each other:
 *
 *     circle       2*seg                       (double-sided fan)
 *     ring         4*seg                       (double-sided quads)
 *     capsule      2*seg + 2*seg*(2*hr - 1)    (seg rounded up to
 *                                               a multiple of 4,
 *                                               hr = seg/4)
 *     tube         (n-1)*seg*2 + 2*seg         (n path points)
 *     lathe        (n-1)*seg*2                 (n profile points)
 *     extrude      4*n - 4                     (n shape points)
 *     tetrahedron  4, octahedron 8, icosahedron 20, dodecahedron 36
 *     torusknot    seg*tseg*2                  ((p, q) = (2, 3))
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-geo.js');

const BUILDERS = [
  'circle', 'ring', 'capsule', 'tube', 'lathe', 'extrude',
  'tetrahedron', 'octahedron', 'icosahedron', 'dodecahedron',
  'torusknot',
];

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// Loaded before every numeric test (the Python PREAMBLE): expose
// `window` (as in a browser page that loads the sidecar after
// f3d.js) and bind the export as `G`. Note f3d.js itself is NOT
// loaded: the sidecar must stand alone.
let G = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  G = globalThis.Forge3DGeo;
} catch (e) { loadError = e; }
function needG() {
  if (loadError) throw loadError;
  return G;
}

// JS helpers shared by the numeric snippets (the Python HELPERS):
// structural format check plus a finiteness sweep over every
// coordinate.
const CURVED_ALL_NORMALS = ['capsule', 'lathe', 'torusknot'];
const FLAT_NO_NORMALS = ['circle', 'ring', 'extrude', 'tetrahedron',
  'octahedron', 'icosahedron', 'dodecahedron'];
function checkTris(tris, name, args) {
  assert.ok(Array.isArray(tris), 'builder must return array');
  tris.forEach(function (t, ti) {
    assert.ok(t.length === 4 || t.length === 6,
      'tri is [a,b,c,faceIdx] or [a,b,c,faceIdx,,normals]');
    for (let i = 0; i < 3; i++) {
      assert.strictEqual(t[i].length, 3, 'vertex is [x,y,z]');
      t[i].forEach(function (x) {
        assert.ok(Number.isFinite(x), 'coordinate not finite');
      });
    }
    assert.ok(Number.isInteger(t[3]), 'faceIdx is an integer');
    if (t.length === 6) {
      // Index 5: [na, nb, nc] per-vertex normals, each a
      // unit-length [x,y,z].
      assert.ok(Array.isArray(t[5]), 'normals element is an array');
      assert.strictEqual(t[5].length, 3,
        'normals element holds 3 vertex normals');
      t[5].forEach(function (n) {
        assert.strictEqual(n.length, 3, 'normal is [x,y,z]');
        n.forEach(function (x) {
          assert.ok(Number.isFinite(x), 'normal not finite');
        });
        assert.ok(Math.abs(Math.hypot(n[0], n[1], n[2]) - 1)
          < 1e-6, 'normal is unit length: ' + n);
      });
    }
    // Presence of normals by builder class: curved builders
    // carry them, flat builders never do. Tube is the mixed
    // case: its swept side tris carry normals, its two end-cap
    // fans (the last 2*seg tris) do not.
    if (name && CURVED_ALL_NORMALS.includes(name))
      assert.strictEqual(t.length, 6,
        name + ': curved tri must carry index-5 normals');
    if (name && FLAT_NO_NORMALS.includes(name))
      assert.strictEqual(t.length, 4,
        name + ': flat tri must not carry normals');
    if (name === 'tube') {
      const seg = Math.max(3, (args && args[1] != null
        ? args[1] : 8) | 0);
      const isCap = ti >= tris.length - 2 * seg;
      assert.strictEqual(t.length, isCap ? 4 : 6,
        'tube: side tris carry normals, cap tris do not');
    }
  });
}
function count(name, args) {
  const tris = G.builders[name].apply(null, args);
  checkTris(tris, name, args);
  assert.strictEqual(tris.length,
    G.triCount[name].apply(null, args),
    name + ': builder/triCount disagree');
  return tris.length;
}

function capsuleCount(seg) {
  // Python: seg = max(4, -(-max(1, seg) // 4) * 4)  # round up to
  // a multiple of 4; hr = seg // 4.
  seg = Math.max(4, Math.ceil(Math.max(1, seg) / 4) * 4);
  const hr = Math.floor(seg / 4);
  return 2 * seg + 2 * seg * (2 * hr - 1);
}

test('test_file_exists', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
});

test('test_exports_all_builders', () => {
  needG();
  assert.strictEqual(window.Forge3DGeo, G);
  assert.strictEqual(typeof G.builders, 'object');
  assert.strictEqual(typeof G.triCount, 'object');
  for (const b of BUILDERS) {
    assert.strictEqual(typeof G.builders[b], 'function',
                       b + ' builder missing');
    assert.strictEqual(typeof G.triCount[b], 'function',
                       b + ' triCount missing');
  }
});

test('test_default_tri_counts_exact', () => {
  needG();
  const expected = {
    circle: 2 * 16,
    ring: 4 * 16,
    capsule: capsuleCount(16),
    tube: (2 - 1) * 8 * 2 + 2 * 8,
    lathe: (4 - 1) * 16 * 2,
    extrude: 4 * 4 - 4,
    tetrahedron: 4,
    octahedron: 8,
    icosahedron: 20,
    dodecahedron: 36,
    torusknot: 48 * 12 * 2,
  };
  for (const name of Object.keys(expected)) {
    assert.strictEqual(count(name, []), expected[name]);
  }
});

test('test_parametric_tri_counts_exact', () => {
  needG();
  const cases = [
    ['circle', [2, 7], 2 * 7],
    ['circle', [0.5, 3], 2 * 3],
    ['ring', [0.25, 1.5, 9], 4 * 9],
    ['capsule', [1, 2, 16], capsuleCount(16)],
    ['capsule', [0.5, 1, 5], capsuleCount(5)],
    ['capsule', [1, 3, 18], capsuleCount(18)],
    ['tube', [0.2, 10, [[0, 0, 0], [1, 0, 0], [1, 1, 0],
                        [1, 1, 1]]], (4 - 1) * 10 * 2 + 2 * 10],
    ['tube', [0.1, 6, [[0, 0, 0], [0, 2, 0]]],
     (2 - 1) * 6 * 2 + 2 * 6],
    ['lathe', [12, [[0.5, -1], [1, -0.3], [0.8, 0.4],
                    [0.6, 0.8], [0.4, 1]]], (5 - 1) * 12 * 2],
    ['extrude', [2, [[0, 0], [1, 0], [0, 1]]], 4 * 3 - 4],
    ['extrude', [1, [[0, 0], [2, 0], [2, 1], [1, 2],
                     [0, 1]]], 4 * 5 - 4],
    ['tetrahedron', [2], 4],
    ['octahedron', [0.5], 8],
    ['icosahedron', [3], 20],
    ['dodecahedron', [1.5], 36],
    ['torusknot', [2, 0.3, 30, 10], 30 * 10 * 2],
    ['torusknot', [1, 0.2, 16, 8], 16 * 8 * 2],
  ];
  for (const [name, args, want] of cases) {
    assert.strictEqual(count(name, args), want);
  }
});

test('test_no_nan_or_degenerate_anywhere', () => {
  needG();
  // checkTris (in count) already asserts finite coordinates;
  // here every triangle must also have positive area.
  function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function cross(a, b) { return [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
  const calls = [
    ['circle', [1, 16]], ['ring', [0.5, 1, 16]],
    ['capsule', [1, 2, 16]], ['capsule', [0.3, 0.7, 8]],
    ['tube', [0.2, 10, [[0, 0, 0], [1, 0, 0], [1, 1, 0], [1, 1, 1]]]],
    ['lathe', [16, [[0.5, -1], [1, -0.3], [0.8, 0.4], [0.4, 1]]]],
    ['extrude', [1, [[0, 0], [2, 0], [2, 1], [0, 1]]]],
    ['tetrahedron', [1]], ['octahedron', [1]],
    ['icosahedron', [1]], ['dodecahedron', [1]],
    ['torusknot', [1, 0.35, 48, 12]]];
  calls.forEach(function (c) {
    const tris = G.builders[c[0]].apply(null, c[1]);
    checkTris(tris);
    tris.forEach(function (t) {
      const n = cross(sub(t[1], t[0]), sub(t[2], t[0]));
      assert.ok(Math.hypot(n[0], n[1], n[2]) > 1e-12,
        c[0] + ': degenerate triangle');
    });
  });
});

test('test_polyhedra_vertices_at_circumradius', () => {
  needG();
  ['tetrahedron', 'octahedron', 'icosahedron',
   'dodecahedron'].forEach(function (name) {
    [1, 2].forEach(function (r) {
      const seen = new Set();
      G.builders[name](r).forEach(function (t) {
        for (let i = 0; i < 3; i++) {
          const v = t[i];
          assert.ok(Math.abs(Math.hypot(v[0], v[1], v[2]) - r)
            < 1e-6, name + ': vertex off circumradius');
          seen.add(v.map(function (x) {
            return x.toFixed(6); }).join(','));
        }
      });
      const want = {tetrahedron: 4, octahedron: 6,
        icosahedron: 12, dodecahedron: 20}[name];
      assert.strictEqual(seen.size, want,
        name + ': unique vertex count');
    });
  });
});

test('test_polyhedra_outward_winding', () => {
  needG();
  // For a convex solid centred on the origin, every face
  // normal must point away from the centre:
  // dot(normal, centroid) > 0.
  function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function cross(a, b) { return [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
  function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
  ['tetrahedron', 'octahedron', 'icosahedron',
   'dodecahedron'].forEach(function (name) {
    G.builders[name](1).forEach(function (t) {
      const n = cross(sub(t[1], t[0]), sub(t[2], t[0]));
      const c = [0, 1, 2].map(function (i) {
        return (t[0][i] + t[1][i] + t[2][i]) / 3; });
      assert.ok(dot(n, c) > 0,
        name + ': inward-wound face');
    });
  });
});

test('test_circle_and_ring_lie_in_xz_plane', () => {
  needG();
  G.builders.circle(2, 8).forEach(function (t) {
    t.slice(0, 3).forEach(function (v) {
      assert.strictEqual(v[1], 0, 'circle off XZ plane');
      assert.ok(Math.hypot(v[0], v[2]) === 0 ||
        Math.abs(Math.hypot(v[0], v[2]) - 2) < 1e-9);
    }); });
  G.builders.ring(0.5, 1.5, 8).forEach(function (t) {
    t.slice(0, 3).forEach(function (v) {
      assert.strictEqual(v[1], 0, 'ring off XZ plane');
      const d = Math.hypot(v[0], v[2]);
      assert.ok(Math.abs(d - 0.5) < 1e-9 ||
        Math.abs(d - 1.5) < 1e-9, 'ring radius wrong');
    }); });
});

test('test_extrude_winding_normalised', () => {
  needG();
  // The same shape in CW and CCW order must produce the
  // same outward geometry: top cap normal +Y, bottom -Y,
  // and identical triangle counts.
  function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function cross(a, b) { return [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
  const ccw = [[0, 0], [2, 0], [2, 1], [0, 1]];
  const cw = ccw.slice().reverse();
  [ccw, cw].forEach(function (shape) {
    const tris = G.builders.extrude(1, shape);
    assert.strictEqual(tris.length, 12);
    tris.forEach(function (t) {
      const n = cross(sub(t[1], t[0]), sub(t[2], t[0]));
      if (t[3] === 1) assert.ok(n[1] > 0, 'top cap not +Y');
      if (t[3] === 2) assert.ok(n[1] < 0, 'bottom cap not -Y');
      t.slice(0, 3).forEach(function (v) {
        assert.ok(v[1] === 0 || v[1] === 1);
      });
    });
  });
});

test('test_capsule_extents', () => {
  needG();
  // radius 1, height 2: total Y extent is +/-(1 + 1) = +/-2,
  // and every vertex is within radius 1 of the Y axis in XZ.
  let mx = 0;
  G.builders.capsule(1, 2, 16).forEach(function (t) {
    t.slice(0, 3).forEach(function (v) {
      mx = Math.max(mx, Math.abs(v[1]));
      assert.ok(Math.hypot(v[0], v[2]) <= 1 + 1e-9);
    }); });
  assert.ok(Math.abs(mx - 2) < 1e-9,
    'capsule half-height must be height/2 + radius');
});

test('test_registry_hook_is_guarded', () => {
  needG();
  // With an F3D host present the sidecar registers its
  // builders into it; the main load above (without any host
  // at all) already proves the un-hosted load is safe.
  globalThis.F3D = {};
  // Fresh execution against the new host: Node caches ESM-syntax
  // modules separately from require.cache, so a second require()
  // would not re-run the module. Re-run the source with its export
  // statements stripped (the pre-ESM loading mechanism); the
  // compatibility footer performs the registration.
  eval(fs.readFileSync(JS_PATH, 'utf8')
    .replace(/^export \{[\s\S]*?\};[ \t]*$/gm, ''));
  assert.strictEqual(typeof globalThis.F3D.builders
    .circle, 'function');
  assert.strictEqual(globalThis.F3D.builders.torusknot,
    globalThis.Forge3DGeo.builders.torusknot);
  assert.strictEqual(globalThis.F3D.geo,
    globalThis.Forge3DGeo);
  delete globalThis.F3D;
});

(async () => {
  let failures = 0;
  for (const [name, fn] of tests) {
    try { await fn(); }
    catch (e) {
      failures++;
      console.error('FAIL ' + name + ': ' + (e && e.stack || e));
    }
  }
  if (failures) {
    console.error(path.basename(__filename) + ': FAIL (' +
                  failures + ' of ' + tests.length + ' tests failed)');
    process.exit(1);
  }
  console.log(path.basename(__filename) + ': PASS (' + tests.length +
              ' tests)');
})();
