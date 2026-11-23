'use strict';
/* Port of test_f3d_ortho_js.py (Forge3D Wave C seat B79) to plain
 * Node.js: tests for the orthographic camera sidecar
 * runtime/f3d-ortho.js (F3DOrtho.ortho / fromSize / project,
 * mirroring mat4_ortho in src/camera_ortho.f90).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_ortho_js.js
 *
 * The size/existence checks always run. The numeric checks load
 * the sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * Every expected matrix entry and projected point is computed
 * INDEPENDENTLY in JS below (jsOrtho / jsProject, translated
 * from the Python original) from the OpenGL-style formulas --
 * the sidecar is never checked against itself:
 *
 *     x_ndc =  2x/(r-l) - (r+l)/(r-l)
 *     y_ndc =  2y/(t-b) - (t+b)/(t-b)
 *     z_ndc = -2z/(f-n) - (f+n)/(f-n)     (view space: front = -z,
 *                                          near at z=-near -> -1,
 *                                          far  at z=-far  -> +1)
 *
 * Matrix layout is the 16-element column-major order shared with
 * mat4_perspective (src/math_3d.f90): index = col*4 + row,
 * so the translation column lands at indices 12, 13, 14 and the
 * homogeneous term at 15.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-ortho.js');
const MAX_BYTES = 6144;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

function jsOrtho(left, right, bottom, top, near, far) {
  // Independent JS ortho matrix, column-major 16-list.
  const rl = right - left, tb = top - bottom, fn = far - near;
  const m = new Array(16).fill(0.0);
  m[0] = 2.0 / rl;
  m[5] = 2.0 / tb;
  m[10] = -2.0 / fn;
  m[12] = -(right + left) / rl;
  m[13] = -(top + bottom) / tb;
  m[14] = -(far + near) / fn;
  m[15] = 1.0;
  return m;
}

function jsProject(m, x, y, z) {
  // Independent JS apply + w-divide (column-major m).
  const cx = m[0] * x + m[4] * y + m[8] * z + m[12];
  const cy = m[1] * x + m[5] * y + m[9] * z + m[13];
  const cz = m[2] * x + m[6] * y + m[10] * z + m[14];
  const w = m[3] * x + m[7] * y + m[11] * z + m[15];
  return [cx / w, cy / w, cz / w];
}

// The Python PREAMBLE: expose `window` and bind the export as `O`,
// plus the near / nearArr helpers. EXPECTED matrices / points are
// computed per-test by the JS helpers above.
let O = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  O = globalThis.F3DOrtho;
} catch (e) { loadError = e; }
function needO() {
  if (loadError) throw loadError;
  return O;
}
const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);
const nearArr = (a, b, e) => a.length === b.length
  && a.every((x, i) => near(x, b[i], e));
function assertAlmostEqual(got, want, places, msg) {
  // Python assertAlmostEqual(places=12): round(|got-want|, 12) == 0.
  assert.ok(Math.abs(got - want) < 0.5 * 10 ** -places,
            (msg || '') + ` ${got} != ${want} within ${places} places`);
}

test('test_file_exists_and_within_size_budget', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  const size = fs.statSync(JS_PATH).size;
  assert.ok(size <= MAX_BYTES,
            `f3d-ortho.js is ${size} B, budget is ${MAX_BYTES} B`);
});

test('test_header_documents_conventions', () => {
  const text = fs.readFileSync(JS_PATH, 'utf8');
  assert.ok(text.includes('camera_ortho.f90'));
  assert.ok(text.includes('F3DOrtho'));
  assert.ok(text.includes('column-major'));
});

test('test_exports', () => {
  needO();
  for (const k of ['ortho', 'fromSize', 'project'])
    assert.strictEqual(typeof O[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.F3DOrtho, O);
  const m = O.ortho(-1, 1, -1, 1, 0.1, 100);
  assert.ok(Array.isArray(m) && m.length === 16,
    'ortho must return 16 elements');
});

test('test_matrix_entries_symmetric_and_asymmetric', () => {
  needO();
  for (const args of [[-4, 4, -3, 3, 0.1, 100],
                      [-2, 6, -1, 3, 0.5, 10],
                      [0, 640, 0, 480, -1, 1]]) {
    const expected = jsOrtho(...args);
    const m = O.ortho(...args);
    assert.ok(nearArr(m, expected, 1e-12), 'matrix=' + m);
  }
});

test('test_centre_projects_to_origin', () => {
  needO();
  // Box centre in view space: ((l+r)/2, (b+t)/2, -(n+f)/2)
  // -- z is negative because front = -z. It must land on
  // the NDC origin.
  const left = -2, right = 6, bottom = -1, top = 3, near_ = 0.5, far = 10;
  const m = jsOrtho(left, right, bottom, top, near_, far);
  const centre = [(left + right) / 2, (bottom + top) / 2,
                  -(near_ + far) / 2];
  for (const got of jsProject(m, ...centre)) {
    assertAlmostEqual(got, 0.0, 12);
  }
  const mJs = O.ortho(-2, 6, -1, 3, 0.5, 10);
  const p = O.project(mJs, ...centre);
  assert.ok(nearArr(p, [0, 0, 0], 1e-12), 'p=' + p);
  // The [x, y, z] array form of project() agrees.
  assert.ok(nearArr(O.project(mJs, centre), p, 1e-12));
});

test('test_corners_project_to_plus_minus_one', () => {
  needO();
  const mArgs = [-4, 4, -3, 3, 0.1, 100];
  const m = jsOrtho(...mArgs);
  const cases = [[-4, -3, -0.1, [-1, -1, -1]],
                 [4, 3, -0.1, [1, 1, -1]],
                 [-4, 3, -100, [-1, 1, 1]],
                 [4, -3, -100, [1, -1, 1]]];
  for (const [x, y, z, want] of cases) {
    const got = jsProject(m, x, y, z);
    for (let i = 0; i < 3; i++) assertAlmostEqual(got[i], want[i], 12);
  }
  const mJs = O.ortho(-4, 4, -3, 3, 0.1, 100);
  cases.forEach(([x, y, z, want], i) => {
    assert.ok(nearArr(O.project(mJs, x, y, z), want, 1e-12),
              'corner ' + i);
  });
});

test('test_near_far_depth_mapping', () => {
  needO();
  // z_view = -near -> z_ndc = -1; z_view = -far -> +1;
  // the depth midpoint -(near+far)/2 -> 0. Sign check
  // against the perspective convention (front = -z).
  const m = O.ortho(-4, 4, -3, 3, 0.1, 100);
  assert.ok(near(O.project(m, 0, 0, -0.1)[2], -1, 1e-12),
    'near plane must map to -1');
  assert.ok(near(O.project(m, 0, 0, -100)[2], 1, 1e-12),
    'far plane must map to +1');
  assert.ok(near(O.project(m, 0, 0, -50.05)[2], 0, 1e-9),
    'depth midpoint must map to 0');
  assert.strictEqual(m[15], 1);
  assert.strictEqual(m[3], 0);
  assert.strictEqual(m[7], 0);
  assert.strictEqual(m[11], 0);
});

test('test_xy_independent_of_distance', () => {
  needO();
  // The defining ortho property (and its difference from
  // perspective): the same view x/y at the near plane and
  // at the far plane project to the SAME NDC x/y.
  const m = jsOrtho(-4, 4, -3, 3, 0.1, 100);
  const pNear = jsProject(m, 1.5, -0.75, -0.1);
  const pFar = jsProject(m, 1.5, -0.75, -100);
  assertAlmostEqual(pNear[0], pFar[0], 12);
  assertAlmostEqual(pNear[1], pFar[1], 12);
  // Python assertNotAlmostEqual(places=6).
  assert.ok(Math.abs(pNear[2] - pFar[2]) >= 0.5 * 10 ** -6,
            'z must differ between near and far');
  const mJs = O.ortho(-4, 4, -3, 3, 0.1, 100);
  const a = O.project(mJs, 1.5, -0.75, -0.1);
  const b = O.project(mJs, 1.5, -0.75, -100);
  assert.ok(near(a[0], b[0], 1e-12)
    && near(a[1], b[1], 1e-12),
    'x/y must not depend on z: ' + a + ' vs ' + b);
  assert.ok(nearArr(a, pNear, 1e-12), 'a=' + a);
  assert.ok(nearArr(b, pFar, 1e-12), 'b=' + b);
});

test('test_from_size', () => {
  needO();
  // size = frustum height 4, aspect 2 -> half_h = 2,
  // half_w = 4: identical to ortho(-4, 4, -2, 2, n, f),
  // and its edges project to +/-1.
  const expected = jsOrtho(-4, 4, -2, 2, 0.1, 50);
  const m = O.fromSize(4, 2, 0.1, 50);
  assert.ok(nearArr(m, expected, 1e-12), 'matrix=' + m);
  assert.ok(nearArr(O.project(m, 4, 2, -0.1),
    [1, 1, -1], 1e-12));
  assert.ok(nearArr(O.project(m, -4, -2, -50),
    [-1, -1, 1], 1e-12));
  assert.ok(nearArr(O.project(m, 0, 0, -25.05),
    [0, 0, 0], 1e-9));
  // Square aspect: half_w == half_h.
  assert.ok(nearArr(O.fromSize(6, 1, 1, 10),
    jsOrtho(-3, 3, -3, 3, 1, 10), 1e-12));
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
