'use strict';
/* JS mirror of tests/fortran/test_math_quat.f90 (Forge3D v3.0
 * Phase 7): the shared Fortran<->JS math test vectors.
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_math_vectors_js.js
 *
 * It is also discovered automatically by tests/run_tests.sh: the
 * compiler-js layer globs tests/compiler/test_*.js and runs each
 * file with node, so no registration edit is needed.
 *
 * This test loads the SAME fixture file the Fortran side consumes,
 * tests/fixtures/math_vectors.json (17 cases: euler_quat_euler,
 * axis_angle_mat4_vec3, slerp, mat4_inverse, mat3_inverse), and
 * asserts every case with the SAME tolerances test_math_quat.f90
 * uses:
 *
 *     quaternions (sign-aligned, q ~ -q) ......... 1e-12
 *     slerp result is unit ....................... 1e-12
 *     euler_out components ....................... 1e-9
 *     rotated vectors ............................ 1e-9
 *     mat4 / mat3 inverses (max abs diff) ........ 1e-9
 *     M * Minv == I (max abs diff) ............... 1e-9
 *     mat3 determinant ........................... 1e-9
 *
 * The JS math below is an independent implementation of the
 * conventions in src/math_3d.f90 (Phase 5 section header + the
 * quat / inverse function bodies), NOT a port of any runtime
 * sidecar:
 *
 *   * Matrices are flat ROW-MAJOR arrays (m[row * n + col]),
 *     acting on COLUMN vectors (v' = M v); translation lives in
 *     column 4.  The fixture files store matrices row-major too:
 *     test_math_quat.f90 fills m%m(i, j) = flat[(i-1)*n + j].
 *   * Quaternions are [x, y, z, w], SCALAR PART LAST.
 *   * quatMultiply(a, b) is the Hamilton product a (x) b and
 *     APPLIES b FIRST, then a (like mat4 multiplication).
 *   * Euler angles are DEGREES, [x, y, z] = [pitch, yaw, roll],
 *     with R = Ry(yaw) * Rx(pitch) * Rz(roll), i.e.
 *     quatFromEuler(e) = qy (x) qx (x) qz.
 *   * quatToEuler: pitch x = asin(clamp(-R(2,3))); when
 *     |sin x| < 1 - 1e-12, yaw = atan2(R(1,3), R(3,3)) and
 *     roll = atan2(R(2,1), R(2,2)).  At the gimbal singularity
 *     (pitch = +/-90 deg) roll is returned as 0 and the combined
 *     yaw is folded into yaw: atan2(R(1,2), R(1,1)) for pitch
 *     +90, atan2(-R(1,2), R(1,1)) for pitch -90.  So
 *     euler -> quat -> euler -> quat is the identity on
 *     rotations even when the Euler triple itself changes.
 *   * quatSlerp takes the SHORTEST PATH (dot < 0 negates the
 *     second quaternion first), falls back to normalised lerp
 *     when dot > 0.9995, clamps t to [0, 1], returns the (unit)
 *     endpoints themselves at t = 0 / 1, and normalises.
 *   * Singular-inverse policy (mat3Inverse / mat4Inverse): a
 *     determinant of exactly 0 yields the IDENTITY and ok=false;
 *     otherwise ok=true.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const FIXTURE_PATH = path.join(REPO, 'tests', 'fixtures',
                               'math_vectors.json');

// Tolerances: identical to tests/fortran/test_math_quat.f90.
const TOL_QUAT = 1e-12;
const TOL_EULER = 1e-9;
const TOL_VEC = 1e-9;
const TOL_MAT = 1e-9;
const TOL_DET = 1e-9;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// ------------------------------------------------------------------
// Fixture loading (always attempted; failures surface per-test).
// ------------------------------------------------------------------

let cases = null;
let loadError = null;
try {
  cases = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
  if (!Array.isArray(cases)) throw new Error('fixture root is not an array');
} catch (e) { loadError = e; }
function needCases() {
  if (loadError) throw loadError;
  return cases;
}
function casesOfKind(kind) {
  return needCases().filter(c => c.kind === kind);
}

// ------------------------------------------------------------------
// JS math mirroring src/math_3d.f90.  Quats are [x, y, z, w];
// matrices are flat row-major (4x4 length 16, 3x3 length 9).
// ------------------------------------------------------------------

const deg2rad = d => d * Math.PI / 180.0;
const rad2deg = r => r * 180.0 / Math.PI;
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

function vec3Normalize(v) {
  const l = Math.hypot(v[0], v[1], v[2]);
  return l > 1e-12 ? v.map(c => c / l) : [0, 0, 0];
}
const vec3Cross = (a, b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];

const quatIdentity = () => [0, 0, 0, 1];
const quatDot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
const quatNegate = q => q.map(c => -c);
const quatScale = (q, s) => q.map(c => c * s);
const quatAdd = (a, b) => a.map((c, i) => c + b[i]);
const quatSub = (a, b) => a.map((c, i) => c - b[i]);

function quatNormalize(q) {
  const l = Math.sqrt(quatDot(q, q));
  return l > 1e-12 ? quatScale(q, 1 / l) : quatIdentity();
}

// Hamilton product a (x) b: applies b first, then a.
function quatMultiply(a, b) {
  return [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
  ];
}

function quatFromAxisAngle(axis, angleDeg) {
  const a = vec3Normalize(axis);
  if (Math.hypot(a[0], a[1], a[2]) <= 1e-12) return quatIdentity();
  const half = deg2rad(angleDeg) * 0.5;
  const s = Math.sin(half);
  return [a[0] * s, a[1] * s, a[2] * s, Math.cos(half)];
}

// R = Ry * Rx * Rz, so q = qy (x) qx (x) qz.
function quatFromEuler(eulerDeg) {
  const qx = quatFromAxisAngle([1, 0, 0], eulerDeg[0]);
  const qy = quatFromAxisAngle([0, 1, 0], eulerDeg[1]);
  const qz = quatFromAxisAngle([0, 0, 1], eulerDeg[2]);
  return quatMultiply(qy, quatMultiply(qx, qz));
}

// Flat row-major 3x3, from the normalised quaternion.
function quatToMat3(q) {
  const [x, y, z, w] = quatNormalize(q);
  return [
    1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w),
    2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
    2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y),
  ];
}

function quatToMat4(q) {
  const r = quatToMat3(q);
  return [
    r[0], r[1], r[2], 0,
    r[3], r[4], r[5], 0,
    r[6], r[7], r[8], 0,
    0,    0,    0,    1,
  ];
}

// Inverse of quatFromEuler, with the documented gimbal policy
// (see the header): pitch +/-90 deg -> roll 0, yaw folded.
function quatToEuler(q) {
  const r = quatToMat3(q);  // r[row * 3 + col], 0-based
  const sx = clamp(-r[1 * 3 + 2], -1, 1);  // -R(2,3)
  const x = rad2deg(Math.asin(sx));
  if (Math.abs(sx) < 1 - 1e-12) {
    return [
      x,
      rad2deg(Math.atan2(r[0 * 3 + 2], r[2 * 3 + 2])),  // R(1,3), R(3,3)
      rad2deg(Math.atan2(r[1 * 3 + 0], r[1 * 3 + 1])),  // R(2,1), R(2,2)
    ];
  }
  const y = sx >= 0
    ? rad2deg(Math.atan2(r[0 * 3 + 1], r[0 * 3 + 0]))   // R(1,2), R(1,1)
    : rad2deg(Math.atan2(-r[0 * 3 + 1], r[0 * 3 + 0]));
  return [x, y, 0];
}

// v' = v + 2 * cross(u, cross(u, v) + w v), q normalised first.
function quatRotateVec3(q, v) {
  const u = quatNormalize(q);
  const uv = [u[0], u[1], u[2]];
  const inner = vec3Cross(uv, v).map((c, i) => c + v[i] * u[3]);
  const corr = vec3Cross(uv, inner);
  return v.map((c, i) => c + 2 * corr[i]);
}

// Shortest path + nlerp fallback at dot > 0.9995 (see header).
function quatSlerp(q1, q2, t) {
  const tt = clamp(t, 0, 1);
  const a = quatNormalize(q1);
  let b = quatNormalize(q2);
  if (tt <= 0) return a;
  if (tt >= 1) return b;
  let d = quatDot(a, b);
  if (d < 0) { b = quatNegate(b); d = -d; }
  if (d > 0.9995) {
    return quatNormalize(quatAdd(a, quatScale(quatSub(b, a), tt)));
  }
  const theta = Math.acos(Math.min(d, 1));
  const s = Math.sin(theta);
  const wa = Math.sin((1 - tt) * theta) / s;
  const wb = Math.sin(tt * theta) / s;
  return quatNormalize(quatAdd(quatScale(a, wa), quatScale(b, wb)));
}

// Direction transform (mat4_transform_vec3 with is_point=.false.):
// no translation column, no w divide.
function mat4TransformVec3(m, v) {
  return [0, 1, 2].map(i =>
    m[i * 4 + 0] * v[0] + m[i * 4 + 1] * v[1] + m[i * 4 + 2] * v[2]);
}

function matMult(a, b, n) {
  const c = new Array(n * n).fill(0);
  for (let i = 0; i < n; i++)
    for (let j = 0; j < n; j++)
      for (let k = 0; k < n; k++)
        c[i * n + j] += a[i * n + k] * b[k * n + j];
  return c;
}
const mat4Mult = (a, b) => matMult(a, b, 4);
const mat3Mult = (a, b) => matMult(a, b, 3);

function mat3Determinant(m) {
  return m[0] * (m[4] * m[8] - m[5] * m[7])
       - m[1] * (m[3] * m[8] - m[5] * m[6])
       + m[2] * (m[3] * m[7] - m[4] * m[6]);
}

// Adjugate inverse; det exactly 0 -> {inv: identity, ok: false}.
function mat3Inverse(m) {
  const det = mat3Determinant(m);
  if (!(Math.abs(det) > 0)) {
    return {inv: [1, 0, 0, 0, 1, 0, 0, 0, 1], ok: false};
  }
  const id = 1 / det;  // m[row * 3 + col] below is R(row+1, col+1)
  return {ok: true, inv: [
    (m[4] * m[8] - m[5] * m[7]) * id,
    -(m[1] * m[8] - m[2] * m[7]) * id,
    (m[1] * m[5] - m[2] * m[4]) * id,
    -(m[3] * m[8] - m[5] * m[6]) * id,
    (m[0] * m[8] - m[2] * m[6]) * id,
    -(m[0] * m[5] - m[2] * m[3]) * id,
    (m[3] * m[7] - m[4] * m[6]) * id,
    -(m[0] * m[7] - m[1] * m[6]) * id,
    (m[0] * m[4] - m[1] * m[3]) * id,
  ]};
}

// Determinant of the 3x3 minor with row ri / column cj removed.
function mat4MinorDet(m, ri, cj) {
  const a = [];
  for (let i = 0; i < 4; i++) {
    if (i === ri) continue;
    for (let j = 0; j < 4; j++) {
      if (j === cj) continue;
      a.push(m[i * 4 + j]);
    }
  }
  return mat3Determinant(a);
}

// General adjugate / determinant inverse; det exactly 0 ->
// {inv: identity, ok: false}.
function mat4Inverse(m) {
  const cof = new Array(16);
  for (let i = 0; i < 4; i++) {
    for (let j = 0; j < 4; j++) {
      let c = mat4MinorDet(m, i, j);
      if ((i + j) % 2 === 1) c = -c;
      cof[i * 4 + j] = c;
    }
  }
  const det = m[0] * cof[0] + m[1] * cof[1] + m[2] * cof[2] + m[3] * cof[3];
  if (!(Math.abs(det) > 0)) {
    return {inv: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            ok: false};
  }
  const id = 1 / det;
  const inv = new Array(16);
  for (let i = 0; i < 4; i++)
    for (let j = 0; j < 4; j++)
      inv[i * 4 + j] = cof[j * 4 + i] * id;  // adjugate = transpose
  return {inv, ok: true};
}

// ------------------------------------------------------------------
// Assertion helpers (mirroring test_math_quat.f90's helpers).
// ------------------------------------------------------------------

// Quaternions are compared up to sign: q and -q are the same
// rotation, so the expected value is sign-aligned first.
function assertQuatClose(got, exp, tol, msg) {
  const e = quatDot(got, exp) < 0 ? quatNegate(exp) : exp;
  for (let i = 0; i < 4; i++) {
    assert.ok(Math.abs(got[i] - e[i]) <= tol,
      msg + ' [' + 'xyzw'[i] + '] got ' + got[i] + ' want ' + e[i]);
  }
}

function assertVecClose(got, exp, tol, msg) {
  assert.strictEqual(got.length, exp.length, msg + ': length');
  for (let i = 0; i < exp.length; i++) {
    assert.ok(Math.abs(got[i] - exp[i]) <= tol,
      msg + ' [' + i + '] got ' + got[i] + ' want ' + exp[i]);
  }
}

function maxDiff(a, b) {
  let d = 0;
  for (let i = 0; i < b.length; i++) d = Math.max(d, Math.abs(a[i] - b[i]));
  return d;
}

function maxDiffIdentity(m, n) {
  let d = 0;
  for (let i = 0; i < n; i++)
    for (let j = 0; j < n; j++)
      d = Math.max(d, Math.abs(m[i * n + j] - (i === j ? 1 : 0)));
  return d;
}

function assertMatClose(got, exp, tol, msg) {
  const d = maxDiff(got, exp);
  assert.ok(d <= tol, msg + ': max diff ' + d + ' > ' + tol);
}

// ------------------------------------------------------------------
// Fixture-level tests.
// ------------------------------------------------------------------

test('test_fixture_file_exists', () => {
  assert.ok(fs.existsSync(FIXTURE_PATH) && fs.statSync(FIXTURE_PATH).isFile(),
            FIXTURE_PATH);
});

test('test_fixture_case_count_is_17', () => {
  assert.strictEqual(needCases().length, 17);
});

test('test_fixture_kind_counts', () => {
  // Same per-kind counts test_math_quat.f90 asserts.
  assert.strictEqual(casesOfKind('euler_quat_euler').length, 6);
  assert.strictEqual(casesOfKind('axis_angle_mat4_vec3').length, 3);
  assert.strictEqual(casesOfKind('slerp').length, 4);
  assert.strictEqual(casesOfKind('mat4_inverse').length, 2);
  assert.strictEqual(casesOfKind('mat3_inverse').length, 2);
});

// ------------------------------------------------------------------
// One test per fixture case, generated from the loaded fixture so
// this file and test_math_quat.f90 can never drift on coverage.
// (If the fixture failed to load, a single failing test reports it
// instead of generating the per-case tests.)
// ------------------------------------------------------------------

function checkEulerCase(c) {
  const q = quatFromEuler(c.euler_deg);
  assertQuatClose(q, c.quat, TOL_QUAT,
    'fixture ' + c.name + ': quatFromEuler');
  const e2 = quatToEuler(q);
  assertVecClose(e2, c.euler_out_deg, TOL_EULER,
    'fixture ' + c.name + ': euler_out');
  assertQuatClose(quatFromEuler(e2), q, TOL_QUAT,
    'fixture ' + c.name + ': euler->quat->euler->quat identity');
}

function checkAxisAngleCase(c) {
  const q = quatFromAxisAngle(c.axis, c.angle_deg);
  assertQuatClose(q, c.quat, TOL_QUAT,
    'fixture ' + c.name + ': quatFromAxisAngle');
  assertVecClose(quatRotateVec3(q, c.vec), c.rotated, TOL_VEC,
    'fixture ' + c.name + ': quatRotateVec3');
  assertVecClose(mat4TransformVec3(quatToMat4(q), c.vec), c.rotated,
    TOL_VEC, 'fixture ' + c.name + ': quatToMat4 applied');
}

function checkSlerpCase(c) {
  const q = quatSlerp(quatFromEuler(c.euler1_deg),
                      quatFromEuler(c.euler2_deg), c.t);
  assertQuatClose(q, c.quat, TOL_QUAT,
    'fixture ' + c.name + ': quatSlerp');
  assert.ok(Math.abs(Math.sqrt(quatDot(q, q)) - 1) <= TOL_QUAT,
    'fixture ' + c.name + ': slerp result is unit');
}

function checkMat4InverseCase(c) {
  const {inv, ok} = mat4Inverse(c.matrix);
  assert.ok(ok, 'fixture ' + c.name + ': mat4Inverse ok');
  assertMatClose(inv, c.inverse, TOL_MAT,
    'fixture ' + c.name + ': inverse matches fixture');
  const d = maxDiffIdentity(mat4Mult(c.matrix, inv), 4);
  assert.ok(d <= TOL_MAT,
    'fixture ' + c.name + ': M * Minv == I (max diff ' + d + ')');
}

function checkMat3InverseCase(c) {
  const {inv, ok} = mat3Inverse(c.matrix);
  assert.ok(ok, 'fixture ' + c.name + ': mat3Inverse ok');
  assertMatClose(inv, c.inverse, TOL_MAT,
    'fixture ' + c.name + ': inverse matches fixture');
  const d = maxDiffIdentity(mat3Mult(c.matrix, inv), 3);
  assert.ok(d <= TOL_MAT,
    'fixture ' + c.name + ': A * Ainv == I (max diff ' + d + ')');
  if (Object.prototype.hasOwnProperty.call(c, 'det')) {
    const det = mat3Determinant(c.matrix);
    assert.ok(Math.abs(det - c.det) <= TOL_DET,
      'fixture ' + c.name + ': determinant got ' + det +
      ' want ' + c.det);
  }
}

const CASE_CHECKS = {
  euler_quat_euler: checkEulerCase,
  axis_angle_mat4_vec3: checkAxisAngleCase,
  slerp: checkSlerpCase,
  mat4_inverse: checkMat4InverseCase,
  mat3_inverse: checkMat3InverseCase,
};

if (cases) {
  for (const c of cases) {
    test('test_fixture_' + c.name, () => {
      const check = CASE_CHECKS[c.kind];
      assert.ok(check, 'fixture case has a known kind: ' + c.name +
                ' (kind ' + c.kind + ')');
      check(c);
    });
  }
} else {
  test('test_fixture_cases_generated', () => { needCases(); });
}

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
