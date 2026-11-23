'use strict';
/* Port of test_f3d_skin_js.py (Forge3D Wave E seat E07) to plain
 * Node.js: tests for the skinning + morph sidecar
 * runtime/f3d-skin.js (C1: morphApply bulge / taper / squash,
 * the smoothstep skinWeight falloff, and skinApply blending
 * toward a bone matrix M = T(pivot) * Rz * Ry * Rx * T(-pivot),
 * angles in degrees, rotations mirroring src/math_3d.f90
 * mat4_rotate_x/y/z).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_skin_js.js
 *
 * The size/existence checks always run. The numeric checks load
 * the sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * Expected values are computed INDEPENDENTLY in JS below
 * (jsMorph / jsSkinWeight / jsSkinApply, translated from the
 * Python original, written straight from the contract
 * formulas) and compared against the sidecar results within
 * 1e-9.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-skin.js');
const MAX_BYTES = 7680;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window` and bind the export as `S`.
let S = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  S = globalThis.Forge3DSkin;
} catch (e) { loadError = e; }
function needS() {
  if (loadError) throw loadError;
  return S;
}

// ------------------------------------------------------------------
// Independent JS reference implementations (contract formulas).
// ------------------------------------------------------------------

function centroid(verts) {
  const n = verts.length / 3;
  return [0, 1, 2].map(k => {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += verts[3 * i + k];
    return sum / n;
  });
}

function jsMorph(verts, kind, factor) {
  const out = [...verts];
  const n = verts.length / 3;
  if (n === 0 || factor === 0) return out;
  const c = centroid(verts);
  if (kind === 'bulge') {
    let halfh = 0;
    for (let i = 0; i < n; i++) {
      halfh = Math.max(halfh, Math.abs(verts[3 * i + 1] - c[1]));
    }
    if (halfh === 0) return out;
    for (let i = 0; i < n; i++) {
      const q = (verts[3 * i + 1] - c[1]) / halfh;
      const s = 1 + factor * 0.5 * (1 - q * q);
      out[3 * i] = c[0] + (verts[3 * i] - c[0]) * s;
      out[3 * i + 1] = verts[3 * i + 1];
      out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * s;
    }
  } else if (kind === 'taper') {
    const ys = [];
    for (let i = 0; i < n; i++) ys.push(verts[3 * i + 1]);
    const ymin = Math.min(...ys), ymax = Math.max(...ys);
    if (ymax === ymin) return out;
    for (let i = 0; i < n; i++) {
      const h = (verts[3 * i + 1] - ymin) / (ymax - ymin);
      const s = 1 - factor * 0.5 * h;
      out[3 * i] = c[0] + (verts[3 * i] - c[0]) * s;
      out[3 * i + 1] = verts[3 * i + 1];
      out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * s;
    }
  } else if (kind === 'squash') {
    for (let i = 0; i < n; i++) {
      out[3 * i] = c[0] + (verts[3 * i] - c[0]) * (1 + 0.25 * factor);
      out[3 * i + 1] = c[1] + (verts[3 * i + 1] - c[1]) * (
        1 - 0.5 * factor);
      out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * (
        1 + 0.25 * factor);
    }
  } else {
    throw new Error(kind);
  }
  return out;
}

function jsSkinWeight(dist, radius) {
  if (radius <= 0) return 0.0;
  const s = Math.min(1.0, Math.max(0.0, 1 - dist / radius));
  return s * s * (3 - 2 * s);
}

function jsRotate(q, rotDeg) {
  // Rz * Ry * Rx * q, math_3d.f90 conventions, degrees.
  let [x, y, z] = q;
  const cx = Math.cos(rotDeg[0] * Math.PI / 180),
        sx = Math.sin(rotDeg[0] * Math.PI / 180);
  const cy = Math.cos(rotDeg[1] * Math.PI / 180),
        sy = Math.sin(rotDeg[1] * Math.PI / 180);
  const cz = Math.cos(rotDeg[2] * Math.PI / 180),
        sz = Math.sin(rotDeg[2] * Math.PI / 180);
  [y, z] = [cx * y - sx * z, sx * y + cx * z];          // Rx
  [x, z] = [cy * x + sy * z, -sy * x + cy * z];         // Ry
  [x, y] = [cz * x - sz * y, sz * x + cz * y];          // Rz
  return [x, y, z];
}

function dist3(a, b) {
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}

function jsSkinApply(verts, pivot, rotDeg, radius) {
  const out = [...verts];
  for (let i = 0; i < verts.length / 3; i++) {
    const p = verts.slice(3 * i, 3 * i + 3);
    const q = [0, 1, 2].map(k => p[k] - pivot[k]);
    const w = jsSkinWeight(dist3(p, pivot), radius);
    if (w === 0) continue;
    const r = jsRotate(q, rotDeg);
    const m = [0, 1, 2].map(k => pivot[k] + r[k]);
    for (let k = 0; k < 3; k++) {
      out[3 * i + k] = (1 - w) * p[k] + w * m[k];
    }
  }
  return out;
}

// Known vertex sets: the 8 corners of the size-2 cube, and an
// asymmetric 5-point set (centroid / half-height not at the origin).
const CUBE = [];
for (const p of [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
                 [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]) {
  CUBE.push(...p);
}
const ASYM = [1, 0, 0, -1, 0, 0, 0, 2, 0, 0, -2, 0, 0, 0, 3];
// Sphere-like set: 4 equator vertices (y == cy, q == 0) and the
// 2 pole vertices (y == cy +/- halfh, q == +/-1); centroid origin.
const SPHERE_LIKE = [1, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, -1,
                     0, 1, 0, 0, -1, 0];

function assertFlatNear(got, want, eps) {
  const e = eps === undefined ? 1e-9 : eps;
  assert.strictEqual(got.length, want.length);
  for (let i = 0; i < got.length; i++) {
    assert.ok(Math.abs(got[i] - want[i]) <= e,
              `index ${i}: ${got[i]} != ${want[i]}`);
  }
}

test('test_file_exists_and_within_size_budget', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  const size = fs.statSync(JS_PATH).size;
  assert.ok(size <= MAX_BYTES,
            `f3d-skin.js is ${size} B, budget is ${MAX_BYTES} B`);
});

test('test_exports', () => {
  needS();
  for (const k of ['morphApply', 'skinWeight', 'skinApply'])
    assert.strictEqual(typeof S[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.Forge3DSkin, S);
});

test('test_factor_zero_identity_all_kinds', () => {
  needS();
  const v = [...ASYM];
  for (const kind of ['bulge', 'taper', 'squash']) {
    const o = S.morphApply(v, kind, 0);
    assert.notStrictEqual(o, v, 'must return a NEW array');
    assert.deepStrictEqual(o, v, kind + ' factor 0');
  }
  assert.deepStrictEqual(v, ASYM, 'input must not mutate');
});

test('test_unknown_kind_throws', () => {
  needS();
  assert.throws(() => S.morphApply([0, 0, 0], 'twist', 1));
  assert.throws(() => S.morphApply([0, 0, 0], '', 1));
});

test('test_bulge_analytic', () => {
  needS();
  for (const [verts, factor] of [[CUBE, 0.7], [ASYM, -1.3],
                                 [ASYM, 2.0]]) {
    const got = S.morphApply(verts, 'bulge', factor);
    assertFlatNear(got, jsMorph(verts, 'bulge', factor));
  }
});

test('test_bulge_barrel_profile_explicit', () => {
  needS();
  // Equator vertices (q == 0) scale by exactly
  // (1 + 0.5 * factor) in x/z, y unchanged; pole vertices
  // (q == +/-1) are unchanged.
  const factor = 0.8;
  const scale = 1 + 0.5 * factor;
  const got = S.morphApply(SPHERE_LIKE, 'bulge', factor);
  const want = [scale, 0, 0, -scale, 0, 0, 0, 0, scale,
                0, 0, -scale, 0, 1, 0, 0, -1, 0];
  assertFlatNear(got, want);
  assertFlatNear(got, jsMorph(SPHERE_LIKE, 'bulge', factor));
  // Pole vertices explicitly unchanged.
  assert.deepStrictEqual(got.slice(12, 18), SPHERE_LIKE.slice(12, 18));
});

test('test_bulge_cube_corners_at_poles_unchanged', () => {
  needS();
  // Every cube corner has q == +/-1, so bulge is identity.
  const got = S.morphApply(CUBE, 'bulge', 1.7);
  assert.deepStrictEqual(got, CUBE);
  assert.deepStrictEqual(jsMorph(CUBE, 'bulge', 1.7), CUBE);
});

test('test_bulge_degenerate_all_points_equal', () => {
  needS();
  const verts = [2, 3, 4, 2, 3, 4, 2, 3, 4, 2, 3, 4];
  const got = S.morphApply(verts, 'bulge', 1.5);
  assert.deepStrictEqual(got, verts);  // halfh == 0 -> exact copy
});

test('test_taper_analytic', () => {
  needS();
  for (const [verts, factor] of [[CUBE, 0.8], [ASYM, -0.6],
                                 [CUBE, 2.0]]) {
    const got = S.morphApply(verts, 'taper', factor);
    assertFlatNear(got, jsMorph(verts, 'taper', factor));
  }
});

test('test_taper_flat_y_is_copy', () => {
  needS();
  const verts = [0, 5, 0, 3, 5, -2, -4, 5, 7];
  const got = S.morphApply(verts, 'taper', 1.5);
  assert.deepStrictEqual(got, verts);  // ymax == ymin -> exact copy
});

test('test_squash_analytic', () => {
  needS();
  for (const [verts, factor] of [[CUBE, 1.2], [ASYM, 0.4],
                                 [CUBE, -2.0]]) {
    const got = S.morphApply(verts, 'squash', factor);
    assertFlatNear(got, jsMorph(verts, 'squash', factor));
  }
});

test('test_skin_weight_endpoints_and_midpoint', () => {
  needS();
  const near = (a, b) => Math.abs(a - b) <= 1e-9;
  assert.ok(near(S.skinWeight(0, 4), 1));
  assert.ok(near(S.skinWeight(4, 4), 0));
  assert.ok(near(S.skinWeight(2, 4), 0.5));
  assert.ok(near(S.skinWeight(1, 4), 0.84375));
  assert.ok(near(S.skinWeight(9, 4), 0), 'past radius');
  assert.strictEqual(S.skinWeight(0, 0), 0);
  assert.strictEqual(S.skinWeight(1, -3), 0);
  for (const [dist, radius] of [[0.3, 2.5], [1.7, 2.5], [2.5, 2.5]]) {
    const got = S.skinWeight(dist, radius);
    assert.ok(Math.abs(got - jsSkinWeight(dist, radius)) <= 1e-9,
              `skinWeight(${dist}, ${radius}): ${got}`);
  }
});

test('test_skin_apply_vertex_at_pivot_z90', () => {
  needS();
  // A vertex AT the pivot has w = 1 and is fixed by any
  // rotation about that pivot: Rz(90) maps it to itself,
  // exactly the analytic image M * pivot == pivot.
  const o = S.skinApply([1, 1, 0, 5, 5, 5],
    [1, 1, 0], [0, 0, 90], 2);
  assert.deepStrictEqual(o.slice(0, 3), [1, 1, 0]);
  // The rotated image itself, recovered via the blend at a
  // known weight: pivot (1,1,0), vertex (2,1,0), radius 2
  // gives w = skinWeight(1, 2) = 0.5 and Rz(90) maps
  // (2,1,0) -> (1,2,0), so the blend is (1.5, 1.5, 0).
  const got = S.skinApply([2, 1, 0], [1, 1, 0], [0, 0, 90], 2);
  assertFlatNear(got, [1.5, 1.5, 0]);
  assertFlatNear(
    got, jsSkinApply([2, 1, 0], [1, 1, 0], [0, 0, 90], 2));
});

test('test_skin_apply_far_vertex_bit_identical', () => {
  needS();
  const verts = [0.1, -2.5, 3.75, 100, 200, -300];
  const got = S.skinApply(verts, [0, 0, 0], [30, 45, 60], 5);
  assertFlatNear(
    got, jsSkinApply(verts, [0, 0, 0], [30, 45, 60], 5));
  // dist >= radius (and radius <= 0): strict identity.
  const v = [...verts];
  const o = S.skinApply(v, [0, 0, 0], [0, 0, 90], 5);
  assert.notStrictEqual(o, v);
  assert.deepStrictEqual(o.slice(3), v.slice(3));
  assert.deepStrictEqual(
    S.skinApply(v, [0, 0, 0], [0, 0, 90], 0), v);
  assert.deepStrictEqual(v, verts, 'input must not mutate');
});

test('test_skin_apply_partial_blend_manual_mix', () => {
  needS();
  // (2,0,0) about the origin, Rz(90), radius 4: dist 2,
  // w = skinWeight(2, 4) = 0.5, rotated image (0,2,0), so
  // the manual mix (1-w)*p + w*(M*p) is exactly (1,1,0).
  const got = S.skinApply([2, 0, 0], [0, 0, 0], [0, 0, 90], 4);
  assertFlatNear(got, [1, 1, 0]);
});

test('test_skin_apply_rotation_conventions_and_order', () => {
  needS();
  // Rx / Ry single-axis blends and a combined Rz*Ry*Rx case,
  // all against the independent JS reference (which
  // applies Rx first, then Ry, then Rz).
  const cases = [
    [[3, 1, -2], [1, 2, 3], [90, 0, 0], 6.0],
    [[3, 1, -2], [1, 2, 3], [0, 90, 0], 6.0],
    [[3, 1, -2], [1, 2, 3], [0, 0, 90], 6.0],
    [[-2, 4, 1], [0, -1, 2], [90, 90, 90], 8.0],
    [CUBE, [0, 0, 0], [25, -40, 130], 3.0],
  ];
  for (const [verts, pivot, rot, radius] of cases) {
    const got = S.skinApply(verts, pivot, rot, radius);
    assertFlatNear(
      got, jsSkinApply(verts, pivot, rot, radius));
  }
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
