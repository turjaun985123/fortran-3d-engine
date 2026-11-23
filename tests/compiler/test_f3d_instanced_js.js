'use strict';
/* Port of test_f3d_instanced_js.py (Forge3D Wave C seat B82) to
 * plain Node.js: tests for the instancing sidecar
 * runtime/f3d-instanced.js (JS mirror of the Fortran instancing
 * data model, seat B81 / MASTER-PLAN parity row 22: ONE shared
 * base geometry plus a list of per-instance transforms).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_instanced_js.js
 *
 * The existence check always runs. The numeric checks load the
 * sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * Every expected value is RECOMPUTED IN JS below: the cube's
 * base vertex stream from the corner/face tables in src/mesh.f90
 * (identical in f3d.js's cube builder), TRS application by the
 * sequential scale -> Rz -> Rx -> Ry -> translate formulas of
 * f3d.js's xform(), and compose matrices by an independent JS
 * 4x4 multiply of T * Ry * Rx * Rz * S (mat4_compose_trs in
 * src/math_3d.f90), flattened column-major (the P16 sec. 7.3
 * layout: translation at indices 12, 13, 14).
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-instanced.js');
const TOL = 1e-12;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window` and bind the export as `I`.
// (`out` printed JSON for the Python side; in-process the values
// are used directly.)
let I = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  I = globalThis.F3DInstanced;
} catch (e) { loadError = e; }
function needI() {
  if (loadError) throw loadError;
  return I;
}

// ------------------------------------------------------------------
// Independent JS reference: cube geometry + TRS math.
// ------------------------------------------------------------------

// create_cube in src/mesh.f90 (size 2, h = 1): 8 corners, 12 tris.
// Face table is 0-based here; mesh.f90's 1-based table and f3d.js's
// F table agree exactly.
const CORNERS = [
  [-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, -1.0],
  [-1.0, 1.0, -1.0], [-1.0, -1.0, 1.0], [1.0, -1.0, 1.0],
  [1.0, 1.0, 1.0], [-1.0, 1.0, 1.0],
];
const FACES = [
  [0, 2, 1], [0, 3, 2], [1, 6, 5], [1, 2, 6],
  [5, 7, 4], [5, 6, 7], [4, 3, 0], [4, 7, 3],
  [3, 6, 2], [3, 7, 6], [4, 1, 5], [4, 0, 1],
];

function cubeGeometry() {
  // f3d.js build()-shaped cube: {tris: [[a, b, c, faceIdx], ...]}.
  return {tris: FACES.map(([a, b, c], i) =>
    [[...CORNERS[a]], [...CORNERS[b]], [...CORNERS[c]], i >> 1])};
}

function baseVertices() {
  // The cube's baked base stream: 36 vertices, face order.
  const out = [];
  for (const face of FACES) for (const i of face) out.push([...CORNERS[i]]);
  return out;
}

function flat(verts) {
  const out = [];
  for (const v of verts) for (const c of v) out.push(c);
  return out;
}

function refApplyTrs(p, pos, rot, scl) {
  // f3d.js xform(): scale, Rz, Rx, Ry, translate (degrees).
  if (typeof scl === 'number') scl = [scl, scl, scl];
  let x = p[0] * scl[0], y = p[1] * scl[1], z = p[2] * scl[2];
  let c = Math.cos(rot[2] * Math.PI / 180),
      s = Math.sin(rot[2] * Math.PI / 180);
  [x, y] = [x * c - y * s, x * s + y * c];               // Rz
  c = Math.cos(rot[0] * Math.PI / 180);
  s = Math.sin(rot[0] * Math.PI / 180);
  [y, z] = [y * c - z * s, y * s + z * c];               // Rx
  c = Math.cos(rot[1] * Math.PI / 180);
  s = Math.sin(rot[1] * Math.PI / 180);
  [x, z] = [x * c + z * s, -x * s + z * c];              // Ry
  return [x + pos[0], y + pos[1], z + pos[2]];
}

function matmul(a, b) {
  const out = [];
  for (let r = 0; r < 4; r++) {
    const row = [];
    for (let c = 0; c < 4; c++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) sum += a[r][k] * b[k][c];
      row.push(sum);
    }
    out.push(row);
  }
  return out;
}

function refCompose(pos, rot, scl) {
  // T * Ry * Rx * Rz * S as a flat COLUMN-MAJOR 16 (row-major
  // matrices built and multiplied independently in JS).
  if (typeof scl === 'number') scl = [scl, scl, scl];
  const cx = Math.cos(rot[0] * Math.PI / 180),
        sx = Math.sin(rot[0] * Math.PI / 180);
  const cy = Math.cos(rot[1] * Math.PI / 180),
        sy = Math.sin(rot[1] * Math.PI / 180);
  const cz = Math.cos(rot[2] * Math.PI / 180),
        sz = Math.sin(rot[2] * Math.PI / 180);
  const t = [[1, 0, 0, pos[0]], [0, 1, 0, pos[1]], [0, 0, 1, pos[2]],
             [0, 0, 0, 1]];
  const ry = [[cy, 0, sy, 0], [0, 1, 0, 0], [-sy, 0, cy, 0], [0, 0, 0, 1]];
  const rx = [[1, 0, 0, 0], [0, cx, -sx, 0], [0, sx, cx, 0], [0, 0, 0, 1]];
  const rz = [[cz, -sz, 0, 0], [sz, cz, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]];
  const s = [[scl[0], 0, 0, 0], [0, scl[1], 0, 0], [0, 0, scl[2], 0],
             [0, 0, 0, 1]];
  const m = matmul(matmul(matmul(matmul(t, ry), rx), rz), s);
  const out = [];  // column-major
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) out.push(m[r][c]);
  return out;
}

function refApplyMatrix(m16, p) {
  // Apply a flat column-major matrix to a point.
  const [x, y, z] = p;
  return [
    m16[0] * x + m16[4] * y + m16[8] * z + m16[12],
    m16[1] * x + m16[5] * y + m16[9] * z + m16[13],
    m16[2] * x + m16[6] * y + m16[10] * z + m16[14],
  ];
}

function assertFlatClose(got, expected) {
  assert.strictEqual(got.length, expected.length,
                     `length ${got.length} != ${expected.length}`);
  for (let i = 0; i < got.length; i++) {
    assert.ok(Math.abs(got[i] - expected[i]) <= TOL,
              `index ${i}: ${got[i]} != ${expected[i]}`);
  }
}

test('test_file_exists', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
});

test('test_exports', () => {
  needI();
  for (const k of ['create', 'add', 'count', 'matrices',
                   'compose', 'buildPositions', 'expand'])
    assert.strictEqual(typeof I[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.F3DInstanced, I);
});

test('test_identity_instance_reproduces_base_vertices', () => {
  needI();
  {
    const s = I.create(cubeGeometry()); I.add(s);
    const got = I.buildPositions(s);
    // Exact, not just close: identity must reproduce the input.
    assert.deepStrictEqual(got, flat(baseVertices()));
  }
  {
    const s = I.create(cubeGeometry()); I.add(s, null);
    const gotExpand = I.expand(s);
    assert.deepStrictEqual(gotExpand, baseVertices());
  }
});

test('test_translation_offsets_exactly', () => {
  needI();
  const got = (() => {
    const s = I.create(cubeGeometry());
    I.add(s, I.compose(10, -2, 3.5, 0, 0, 0, 1));
    return I.buildPositions(s);
  })();
  const expected = flat(baseVertices().map(
    v => refApplyTrs(v, [10, -2, 3.5], [0, 0, 0], 1)));
  assert.deepStrictEqual(got, expected);  // pure offsets: exact
  // And via the TRS-descriptor form of add().
  const gotTrs = (() => {
    const s = I.create(cubeGeometry());
    I.add(s, {pos: [10, -2, 3.5]});
    return I.buildPositions(s);
  })();
  assert.deepStrictEqual(gotTrs, expected);
});

test('test_three_instances_expand_to_36_tris', () => {
  needI();
  const got = (() => {
    const s = I.create(cubeGeometry());
    I.add(s, {pos: [0, 0, 0]});
    I.add(s, {pos: [5, 0, 0]});
    I.add(s, I.compose(-5, 2, 0, 0, 90, 0, 2));
    return {count: I.count(s), pos: I.buildPositions(s),
            verts: I.expand(s), tris: I.expandTriangles(s)};
  })();
  assert.strictEqual(got.count, 3);
  assert.strictEqual(got.tris.length, 36);        // 3 x 12 tris
  assert.strictEqual(got.verts.length, 36 * 3);   // 108 vertices
  assert.strictEqual(got.pos.length, 36 * 3 * 3); // 324 numbers
  // Instance-major order, each block independently expected.
  const trss = [[[0, 0, 0], [0, 0, 0], 1], [[5, 0, 0], [0, 0, 0], 1],
                [[-5, 2, 0], [0, 90, 0], 2]];
  let expected = [];
  for (const [pos, rot, scl] of trss) {
    expected = expected.concat(baseVertices().map(
      v => refApplyTrs(v, pos, rot, scl)));
  }
  assertFlatClose(got.pos, flat(expected));
  assertFlatClose(flat(got.verts), flat(expected));
});

test('test_shared_geometry_invariant', () => {
  needI();
  // The set holds a REFERENCE: in-place coordinate edits, a
  // replaced vertex and a pushed triangle must all show up.
  const got = (() => {
    const geo = cubeGeometry();
    const s = I.create(geo);
    assert.strictEqual(s.geometry, geo, 'not a reference');
    I.add(s);
    const before = I.buildPositions(s);
    geo.tris[0][0][0] = 7.25;        // mutate in place
    geo.tris[0][1] = [9, 8, 7];      // replace a vertex
    geo.tris.push([[1, 2, 3], [4, 5, 6], [7, 8, 10], 0]);
    return {before: before, after: I.buildPositions(s)};
  })();
  assert.deepStrictEqual(got.before, flat(baseVertices()));
  const expectedGeo = cubeGeometry();
  expectedGeo.tris[0][0][0] = 7.25;
  expectedGeo.tris[0][1] = [9, 8, 7];
  expectedGeo.tris.push([[1, 2, 3], [4, 5, 6], [7, 8, 10], 0]);
  const expected = [];
  for (const tri of expectedGeo.tris) for (const v of tri.slice(0, 3)) {
    expected.push([...v]);
  }
  assert.deepStrictEqual(got.after, flat(expected));
  assert.strictEqual(got.after.length, (36 + 3) * 3);
});

test('test_compose_matches_python_matrix', () => {
  needI();
  // (Named for the Python original: the reference matrix is the
  // JS translation of ref_compose above.)
  const cases = [
    [[0, 0, 0], [0, 0, 0], 1],
    [[1, 2, 3], [0, 90, 0], 1],
    [[-4, 0.5, 7], [30, 45, 60], [2, 3, 0.5]],
    [[0, -1, 0], [90, 0, 0], 2],
    [[3, 3, 3], [0, 0, -90], [1, 0.25, 1]],
  ];
  for (const [pos, rot, scl] of cases) {
    // Python passed json.dumps(scl) as the single 7th argument:
    // a scalar stays a scalar, a list becomes one array argument.
    const got = I.compose(pos[0], pos[1], pos[2],
                          rot[0], rot[1], rot[2], scl);
    assertFlatClose(got, refCompose(pos, rot, scl));
  }
});

test('test_matrix_layout_is_column_major', () => {
  needI();
  let m = I.compose(10, 20, 30, 0, 0, 0, 1);
  // Translation lives at 12/13/14; diagonal is the scale.
  assert.deepStrictEqual(m.slice(12), [10, 20, 30, 1]);
  assert.deepStrictEqual([m[0], m[5], m[10]], [1, 1, 1]);
  // Ry(+90deg): +X axis maps to -Z (Fortran mat4_rotate_y:
  // x' = x*c + z*s, z' = -x*s + z*c), pinned via the matrix.
  m = I.compose(0, 0, 0, 0, 90, 0, 1);
  assertFlatClose(refApplyMatrix(m, [1, 0, 0]), [0.0, 0.0, -1.0]);
  assertFlatClose(m, refCompose([0, 0, 0], [0, 90, 0], 1));
});

test('test_add_raw_matrix_and_matrices_roundtrip', () => {
  needI();
  const m = refCompose([2, -3, 4], [15, 25, 35], [1.5, 1, 0.75]);
  const got = (() => {
    const s = I.create(cubeGeometry()); I.add(s, m); I.add(s);
    return {count: I.count(s), mats: I.matrices(s),
            pos: I.buildPositions(s)};
  })();
  assert.strictEqual(got.count, 2);
  assertFlatClose(got.mats[0], m);
  assertFlatClose(got.mats[1], refCompose([0, 0, 0], [0, 0, 0], 1));
  const expected = baseVertices().map(v => refApplyMatrix(m, v))
    .concat(baseVertices());
  assertFlatClose(got.pos, flat(expected));
});

test('test_matrices_returns_copies', () => {
  needI();
  const s = I.create(cubeGeometry()); I.add(s, {pos: [1, 2, 3]});
  const ms = I.matrices(s); ms[0][12] = 999;
  assert.strictEqual(I.matrices(s)[0][12], 1);
  // The caller's matrix array is copied at add() time too.
  const raw = I.compose(4, 5, 6, 0, 0, 0, 1); I.add(s, raw);
  raw[12] = 999;
  assert.strictEqual(I.matrices(s)[1][12], 4);
  assert.strictEqual(I.count(s), 2);
});

test('test_empty_set_and_empty_geometry', () => {
  needI();
  const got = (() => {
    const s = I.create(cubeGeometry());
    return {count: I.count(s), mats: I.matrices(s),
            pos: I.buildPositions(s),
            none: I.buildPositions(I.create(null))};
  })();
  assert.deepStrictEqual(got, {count: 0, mats: [], pos: [], none: []});
});

test('test_geometry_shape_variants', () => {
  needI();
  // Bare triangle list, flat positions, and positions+indices
  // all yield the same base stream for a single triangle.
  const tri = [[0, 0, 0], [2, 0, 0], [0, 2, 0]];
  const expected = flat(tri.map(
    v => refApplyTrs(v, [1, 1, 1], [0, 0, 0], 1)));
  for (const geo of [[tri], {positions: flat(tri)},
                     {positions: flat(tri), indices: [0, 1, 2]},
                     {triangles: [{v: tri}]}]) {
    const got = (() => {
      const s = I.create(geo); I.add(s, {pos: [1, 1, 1]});
      return I.buildPositions(s);
    })();
    assert.deepStrictEqual(got, expected);
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
