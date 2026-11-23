// Forge3D module "f3d-instanced" -- instancing sidecar.
// Role: OPTIONAL module, load AFTER runtime/f3d.js. JS mirror of
// the Fortran instancing data model (src/instancing.f90, seat B81;
// MASTER-PLAN parity row 22): ONE shared base geometry plus a list
// of per-instance transforms.
// ES module (Phase 7): the public names are declared with named
// exports below. A classic (non-module) bundle is produced from
// this module by tools/build_runtime.mjs; the compatibility
// footer at the bottom preserves the legacy globals for classic
// consumers.
// Imports: none. This module uses no sibling-runtime globals --
// the core helpers in runtime/f3d.js are not exported individually
// and this file defines its own num / v3 / matrix helpers, exactly
// as the classic script did. Zero deps.
//
// Parity with B81 (verified against src/instancing.f90):
// InstanceSet is { base, transforms(:), count } and
// instancing_build_mesh loops instances in order, appending
// mesh_add_transformed(out, base, transforms(i)) each time -- so
// the baked mesh has count * base triangles, instance-major, base
// vertex order preserved. expand()/buildPositions() below produce
// exactly that vertex stream.
// ONE deliberate divergence, per this seat's spec: Fortran's
// instancing_init DEEP-COPIES the base mesh (derived-type
// assignment), while create() here holds the geometry by
// REFERENCE (the JS shared-geometry idiom -- one geometry object
// reused by every instance, as in P16's JS backend ruling), so
// mutating the base geometry after create() is reflected in the
// expansion. The transform list semantics are identical either
// way: instancing_add appends a copy of the matrix, as does add().
//
// Set shape (returned by create):
//   { geometry: <the exact object passed in, NOT a copy>,
//     transforms: [<16 numbers>, ...] }
// Because the geometry is held by reference and is only read when
// matrices()/buildPositions()/expand() is called, mutating the
// base geometry object after create() is reflected in the output.
//
// Geometry shapes accepted (read at expansion time):
//   - a build() result from f3d.js: { tris: [[a, b, c, ...], ...] }
//     where a/b/c are [x, y, z] vertices (extra per-tri entries,
//     e.g. face index / colour, are ignored)
//   - { triangles: [{ v: [a, b, c] }, ...] } or { triangles:
//     [[a, b, c], ...] } (mesh JSON / scene form)
//   - { positions: [...] } flat [x, y, z, ...], optionally with
//     { indices: [...] } picking the vertex order (P16 v2 mesh)
//   - { vertices: [...] } / a bare vertex list [[x, y, z], ...]
//   - a bare triangle list [[a, b, c], ...] or a flat number list
//
// Matrices: flat 16-element arrays in COLUMN-MAJOR order -- the
// layout P16 sec. 7.3 specifies for v2 instance transforms
// ("t": [16 column-major floats]) and the order Fortran's own
// mat4 m(4,4) takes in memory: element (row, col) lives at
// m[col*4 + row], so the translation sits at indices 12, 13, 14
// and a point transforms as
//   x' = m[0]*x + m[4]*y + m[8]*z  + m[12]
//   y' = m[1]*x + m[5]*y + m[9]*z  + m[13]
//   z' = m[2]*x + m[6]*y + m[10]*z + m[14]
//
// TRS / rotation conventions -- checked against src/math_3d.f90
// AND f3d.js, no discrepancy found:
//   compose() builds T * Ry * Rx * Rz * S, exactly
//   mat4_compose_trs in math_3d.f90; f3d.js's xform() applies the
//   same transform point-wise (scale, then Rz, then Rx, then Ry,
//   then translate) with identical per-axis formulas:
//     Rx: y' = y*c - z*s,  z' = y*s + z*c
//     Ry: x' = x*c + z*s,  z' = -x*s + z*c
//     Rz: x' = x*c - y*s,  y' = x*s + y*c
//   The only difference is at the API surface, not in the math:
//   math_3d.f90's mat4_rotate_x/y/z take RADIANS, while
//   mat4_compose_trs (rot_deg), mat4_axis_angle and everything in
//   f3d.js take DEGREES. compose() here takes degrees.
var D2R = Math.PI / 180;

function num(v, d) { return v == null ? d : (+v || 0); }
function v3(v, d) {
  if (v == null) return d.slice();
  if (typeof v === 'number') return [v, v, v];
  return [num(v[0], d[0]), num(v[1], d[1]), num(v[2], d[2])];
}

// ---- 4x4 matrices, flat column-major (see header) ----
// mult(a, b) = a * b, mirroring mat4_mult in math_3d.f90:
// (a*b)(row, col) = sum_k a(row, k) * b(k, col).
function mult(a, b) {
  var out = new Array(16), col, row, k, s;
  for (col = 0; col < 4; col++) for (row = 0; row < 4; row++) {
    s = 0;
    for (k = 0; k < 4; k++) s += a[k * 4 + row] * b[col * 4 + k];
    out[col * 4 + row] = s;
  }
  return out;
}
function identity() {
  return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
}
function translation(tx, ty, tz) {
  var m = identity(); m[12] = tx; m[13] = ty; m[14] = tz; return m;
}
function scaling(sx, sy, sz) {
  var m = identity(); m[0] = sx; m[5] = sy; m[10] = sz; return m;
}
// mat4_rotate_x/y/z in math_3d.f90 (radians there, degrees here).
function rotateX(deg) {
  var c = Math.cos(deg * D2R), s = Math.sin(deg * D2R), m = identity();
  m[5] = c; m[9] = -s; m[6] = s; m[10] = c; return m;
}
function rotateY(deg) {
  var c = Math.cos(deg * D2R), s = Math.sin(deg * D2R), m = identity();
  m[0] = c; m[8] = s; m[2] = -s; m[10] = c; return m;
}
function rotateZ(deg) {
  var c = Math.cos(deg * D2R), s = Math.sin(deg * D2R), m = identity();
  m[0] = c; m[4] = -s; m[1] = s; m[5] = c; return m;
}

// compose(px, py, pz, rx, ry, rz, scale) -> flat column-major 16.
// Rotation angles are in DEGREES; scale is a number (uniform) or
// [sx, sy, sz]. Mirrors mat4_compose_trs: T * Ry * Rx * Rz * S.
function compose(px, py, pz, rx, ry, rz, scale) {
  var s = v3(scale == null ? 1 : scale, [1, 1, 1]);
  var m = mult(translation(num(px, 0), num(py, 0), num(pz, 0)),
               rotateY(num(ry, 0)));
  m = mult(m, rotateX(num(rx, 0)));
  m = mult(m, rotateZ(num(rz, 0)));
  m = mult(m, scaling(s[0], s[1], s[2]));
  return m;
}

// Build a matrix from a TRS descriptor:
//   { pos|position: [x,y,z], rot|rotate|rotation: [rx,ry,rz]
//     (degrees), scale|scl: number | [sx,sy,sz] }
// Missing fields default to identity (pos 0, rot 0, scale 1).
function fromTRS(trs) {
  var pos = v3(trs.pos != null ? trs.pos : trs.position, [0, 0, 0]);
  var rot = v3(trs.rot != null ? trs.rot
               : (trs.rotate != null ? trs.rotate : trs.rotation),
               [0, 0, 0]);
  var scl = trs.scale != null ? trs.scale : trs.scl;
  return compose(pos[0], pos[1], pos[2], rot[0], rot[1], rot[2], scl);
}

function asMatrix(matrixOrTRS) {
  var i, out;
  if (matrixOrTRS == null) return identity();
  if (Array.isArray(matrixOrTRS)) { // flat 16, column-major
    out = identity();
    for (i = 0; i < 16 && i < matrixOrTRS.length; i++)
      out[i] = num(matrixOrTRS[i], i % 5 === 0 ? 1 : 0);
    return out;
  }
  if (Array.isArray(matrixOrTRS.matrix)) return asMatrix(matrixOrTRS.matrix);
  if (Array.isArray(matrixOrTRS.t)) return asMatrix(matrixOrTRS.t);
  return fromTRS(matrixOrTRS);
}

// Apply a flat column-major matrix to one [x, y, z] point (w = 1;
// affine matrices only, so no perspective divide, matching
// mat4_transform_vec3 with is_point for the TRS matrices here).
function apply(m, p) {
  var x = p[0], y = p[1], z = p[2];
  return [m[0] * x + m[4] * y + m[8] * z + m[12],
          m[1] * x + m[5] * y + m[9] * z + m[13],
          m[2] * x + m[6] * y + m[10] * z + m[14]];
}

// ---- instance sets ----

// create(geometry) -> a new, empty instance set holding ONE
// shared reference to geometry (never copied).
function create(geometry) {
  return { geometry: geometry == null ? null : geometry,
           transforms: [] };
}

// add(set, matrixOrTRS) -> appends one instance and returns the
// set (chainable). matrixOrTRS is a flat 16-element column-major
// matrix, a { matrix } / { t } wrapper, a TRS descriptor (see
// fromTRS), or null/omitted for the identity instance. The matrix
// is copied into the set, so later edits to the caller's array do
// not move an already-placed instance.
function add(set, matrixOrTRS) {
  set.transforms.push(asMatrix(matrixOrTRS));
  return set;
}

// count(set) -> number of instances in the set.
function count(set) {
  return set && set.transforms ? set.transforms.length : 0;
}

// matrices(set) -> the per-instance matrices, in insertion order:
// an array of fresh 16-element column-major arrays (copies, so
// mutating the result does not disturb the set).
function matrices(set) {
  return (set.transforms || []).map(function (m) { return m.slice(); });
}

// ---- geometry reading (at call time, so shared-geometry
// mutations are seen) ----

function isVertex(v) {
  return Array.isArray(v) && typeof v[0] === 'number';
}
function pushTriVerts(out, tri) {
  var vs = null, i;
  if (Array.isArray(tri)) vs = tri;
  else if (tri) vs = tri.v || tri.verts || tri.vertices;
  if (!vs) return;
  for (i = 0; i < 3 && i < vs.length; i++)
    if (isVertex(vs[i])) out.push([+vs[i][0] || 0, +vs[i][1] || 0,
                                   +vs[i][2] || 0]);
}
function pushVertList(out, list) {
  var i;
  if (!list) return;
  if (typeof list[0] === 'number') { // flat [x, y, z, ...]
    for (i = 0; i + 2 < list.length; i += 3)
      out.push([+list[i] || 0, +list[i + 1] || 0, +list[i + 2] || 0]);
    return;
  }
  for (i = 0; i < list.length; i++) {
    if (isVertex(list[i])) out.push([+list[i][0] || 0,
      +list[i][1] || 0, +list[i][2] || 0]);
    else pushTriVerts(out, list[i]); // triangle entry in a list
  }
}

// Ordered base vertex stream of a geometry (see header for the
// accepted shapes). With indices, the stream follows the indices.
function baseVertices(geometry) {
  var out = [], src = null, idx = null, i;
  if (geometry == null) return out;
  if (Array.isArray(geometry)) { pushVertList(out, geometry); return out; }
  if (Array.isArray(geometry.tris)) src = geometry.tris;
  else if (Array.isArray(geometry.triangles)) src = geometry.triangles;
  if (src) {
    for (i = 0; i < src.length; i++) pushTriVerts(out, src[i]);
    return out;
  }
  var pos = geometry.positions || geometry.vertices
    || geometry.verts || geometry.points;
  if (Array.isArray(pos)) {
    var verts = []; pushVertList(verts, pos);
    idx = geometry.indices || geometry.index;
    if (Array.isArray(idx)) {
      for (i = 0; i < idx.length; i++)
        if (verts[idx[i]]) out.push(verts[idx[i]]);
    } else out = verts;
  }
  return out;
}

// expand(set) -> the baked vertex stream as [[x, y, z], ...]:
// for each instance, in order, every base vertex transformed by
// that instance's matrix, in base order. This is the stream
// instancing_build_mesh / mesh_add_transformed produce in the
// Fortran engine.
function expand(set) {
  var base = baseVertices(set.geometry), out = [], i, j, m;
  for (i = 0; i < set.transforms.length; i++) {
    m = set.transforms[i];
    for (j = 0; j < base.length; j++) out.push(apply(m, base[j]));
  }
  return out;
}

// buildPositions(set) -> the same baked stream as expand(), as
// one flat [x, y, z, x, y, z, ...] array of plain numbers.
function buildPositions(set) {
  var verts = expand(set), out = new Array(verts.length * 3), i;
  for (i = 0; i < verts.length; i++) {
    out[i * 3] = verts[i][0];
    out[i * 3 + 1] = verts[i][1];
    out[i * 3 + 2] = verts[i][2];
  }
  return out;
}

// expandTriangles(set) -> the baked stream grouped back into
// triangles [[[x,y,z] x3], ...], consecutive triples of expand().
function expandTriangles(set) {
  var verts = expand(set), out = [], i;
  for (i = 0; i + 2 < verts.length; i += 3)
    out.push([verts[i], verts[i + 1], verts[i + 2]]);
  return out;
}

export { create, add, count, matrices, compose, compose as trs,
  fromTRS, apply, baseVertices, expand, buildPositions,
  expandTriangles };

// Compatibility footer: preserve the classic-script globals --
// the exported names are attached onto globalThis.F3D (as
// globalThis.F3D.instanced) as well as the legacy
// globalThis.F3DInstanced.
const F3DInstanced = { create: create, add: add, count: count,
  matrices: matrices, compose: compose, trs: compose,
  fromTRS: fromTRS, apply: apply, baseVertices: baseVertices,
  expand: expand, buildPositions: buildPositions,
  expandTriangles: expandTriangles };
globalThis.F3DInstanced = F3DInstanced;
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.instanced = F3DInstanced;
if (typeof window !== 'undefined') window.F3DInstanced = F3DInstanced;
