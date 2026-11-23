'use strict';
/* Port of test_f3d_raycast_js.py (Forge3D Wave B seat B66) to
 * plain Node.js: tests for the raycasting / picking sidecar
 * runtime/f3d-raycast.js (Moeller-Trumbore ray/triangle, ray
 * casting and pixel picking, mirroring src/raycast.f90).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_raycast_js.js
 *
 * The size/existence checks always run. The numeric checks load
 * the sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * The numeric cases match the Fortran seat's cases: a cube built
 * as 12 triangles (size 2, centred on the origin, in the vertex /
 * face order of create_cube in src/mesh.f90, which is also the
 * order used by runtime/f3d.js). Tolerances are 1e-9 where the
 * expected value is exact, else 1e-6.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-raycast.js');
const MAX_BYTES = 7680;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window`, bind the export as `R`,
// and build the size-2 cube as a flat 12-triangle array `CUBE`
// (hardcoded verts + face list, Fortran create_cube order).
let R = null;
let loadError = null;
let CUBE = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  R = globalThis.F3DRay;
  const P = [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
    [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]];
  const F = [[0, 2, 1], [0, 3, 2], [1, 6, 5], [1, 2, 6], [5, 7, 4],
    [5, 6, 7], [4, 3, 0], [4, 7, 3], [3, 6, 2], [3, 7, 6], [4, 1, 5],
    [4, 0, 1]];
  CUBE = [];
  for (const f of F) for (const i of f) CUBE.push(...P[i]);
  assert.strictEqual(CUBE.length, 12 * 9);
} catch (e) { loadError = e; }
function needR() {
  if (loadError) throw loadError;
  return R;
}
const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);
const near3 = (a, b, e) => a.length === 3
  && a.every((x, i) => near(x, b[i], e));

test('test_file_exists_and_within_size_budget', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  const size = fs.statSync(JS_PATH).size;
  assert.ok(size <= MAX_BYTES,
            `f3d-raycast.js is ${size} B, budget is ${MAX_BYTES} B`);
});

test('test_exports', () => {
  needR();
  for (const k of ['rayTriangle', 'cast', 'pick'])
    assert.strictEqual(typeof R[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.F3DRay, R);
});

test('test_cube_front_hit_exact', () => {
  needR();
  // Ray (0,0,5) -> (0,0,-1) at the size-2 cube: the front
  // (z = +1) face is exactly 4 units away, hit at the
  // face centre (0,0,1), which lies on the shared diagonal
  // of front triangles 4 and 5 -- the first one (index 4)
  // wins the exact tie.
  const h = R.cast([0, 0, 5], [0, 0, -1], CUBE);
  assert.ok(h, 'expected a hit');
  assert.ok(near(h.t, 4, 1e-9), 't=' + h.t);
  assert.strictEqual(h.index, 4);
  assert.ok(near3(h.point, [0, 0, 1], 1e-9),
    'point=' + h.point);
  assert.ok(near(h.point[2], 1, 1e-9));
  assert.ok(near(h.bary[0] + h.bary[1] + h.bary[2], 1, 1e-9));
});

test('test_miss_returns_null', () => {
  needR();
  // Ray passing above the cube, and a ray pointing away
  // from it: both miss. A single triangle off to the side
  // of the ray also misses.
  assert.strictEqual(R.cast([0, 5, 5], [0, 0, -1], CUBE), null);
  assert.strictEqual(R.cast([0, 0, 5], [0, 0, 1], CUBE), null);
  assert.strictEqual(R.rayTriangle([0, 0, 1], [0, 0, -1],
    [2, 0, 0], [3, 0, 0], [2, 1, 0]), null);
  assert.strictEqual(R.cast([0, 0, 5], [0, 0, -1], []), null);
});

test('test_centre_of_triangle_bary', () => {
  needR();
  // Ray through the centroid (1/3, 1/3) of the triangle
  // (0,0,0),(1,0,0),(0,1,0) from z=1: t == 1 exactly and
  // every barycentric coordinate is ~1/3.
  const o = [1 / 3, 1 / 3, 1], d = [0, 0, -1];
  const tri = [[0, 0, 0], [1, 0, 0], [0, 1, 0]];
  const h = R.rayTriangle(o, d, ...tri);
  assert.ok(h, 'expected a hit');
  assert.ok(near(h.t, 1, 1e-9), 't=' + h.t);
  assert.ok(near(h.u, 1 / 3, 1e-9), 'u=' + h.u);
  assert.ok(near(h.v, 1 / 3, 1e-9), 'v=' + h.v);
  const c = R.cast(o, d, tri.flat());
  assert.ok(c && c.index === 0, 'cast=' + JSON.stringify(c));
  assert.ok(near(c.t, 1, 1e-9));
  assert.ok(near3(c.bary, [1 / 3, 1 / 3, 1 / 3], 1e-6),
    'bary=' + c.bary);
  assert.ok(near3(c.point, [1 / 3, 1 / 3, 0], 1e-9));
});

test('test_both_windings_parallel_and_behind', () => {
  needR();
  // Both windings accepted: reversing v2/v3 gives the same
  // hit (with u/v swapped). A ray parallel to the triangle
  // plane (|det| < eps) and a triangle behind the ray
  // origin (t <= eps) both return null.
  const o = [1 / 3, 1 / 3, 1], d = [0, 0, -1];
  const a = R.rayTriangle(o, d, [0, 0, 0], [1, 0, 0], [0, 1, 0]);
  const b = R.rayTriangle(o, d, [0, 0, 0], [0, 1, 0], [1, 0, 0]);
  assert.ok(a && b, 'both windings must hit');
  assert.ok(near(b.t, a.t, 1e-9));
  assert.ok(near(b.u, a.v, 1e-9) && near(b.v, a.u, 1e-9));
  assert.strictEqual(R.rayTriangle([0, 0, 1], [1, 0, 0],
    [0, 0, 0], [1, 0, 0], [0, 1, 0]), null);
  assert.strictEqual(R.rayTriangle([0, 0, -5], [0, 0, -1],
    [-1, -1, 0], [1, -1, 0], [0, 1, 0]), null);
});

test('test_nearest_t_wins', () => {
  needR();
  // Two triangles on the ray path, the FAR one first in
  // the array (z=0, t=5) and the NEAR one second (z=2,
  // t=3): the nearest t wins, with its own index.
  const tris = [
    -1, -1, 0,  1, -1, 0,  0, 1, 0,
    -1, -1, 2,  1, -1, 2,  0, 1, 2];
  const h = R.cast([0, 0, 5], [0, 0, -1], tris);
  assert.ok(h, 'expected a hit');
  assert.ok(near(h.t, 3, 1e-9), 't=' + h.t);
  assert.strictEqual(h.index, 1);
  assert.ok(near3(h.point, [0, 0, 2], 1e-9));
});

test('test_pick_centre_hits_corner_misses', () => {
  needR();
  // Default camera (3,2.5,4) -> (0,0,0), up (0,1,0),
  // fov 60, 640x480 view of the size-2 cube: a pick
  // through the centre pixel (320,240) hits the cube
  // (on its z=+1 face), a pick through the corner pixel
  // (2,2) misses it entirely.
  const cam = [[3, 2.5, 4], [0, 0, 0], [0, 1, 0]];
  const h = R.pick(320, 240, 640, 480,
    cam[0], cam[1], cam[2], 60, CUBE);
  assert.ok(h, 'centre pick must hit the cube');
  assert.ok(h.t > 0);
  assert.ok(near(h.point[2], 1, 1e-6),
    'point=' + h.point);
  assert.strictEqual(R.pick(2, 2, 640, 480,
    cam[0], cam[1], cam[2], 60, CUBE), null);
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
