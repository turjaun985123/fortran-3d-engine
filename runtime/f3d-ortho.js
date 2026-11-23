// f3d-ortho -- Forge3D orthographic camera sidecar:
// orthographic projection matrices mirroring
// src/camera_ortho.f90 (mat4_ortho).
// ES module (Phase 7): public names are the named exports at
// the bottom of this file; the classic bundle is built from
// the ES modules by tools/build_runtime.mjs. No sibling
// imports: this module is standalone (it uses no globals from
// runtime/f3d.js).
// OPTIONAL module, load AFTER runtime/f3d.js (or standalone:
// it has no dependencies).
// Mirrors the Fortran module src/camera_ortho.f90 (mat4_ortho),
// built with the same matrix conventions as mat4_perspective in
// src/math_3d.f90 and as the inline projection in runtime/f3d.js.
//
// MATRIX LAYOUT (16-element plain Array, column-major):
//   out[col*4 + row] = m(row, col) of the Fortran mat4, i.e. the
//   Fortran m(4,4) storage order and the WebGL/gl-matrix order.
//   For mat4_perspective that puts 1/(aspect*tan(fov/2)) at [0],
//   1/tan(fov/2) at [5], -(far+near)/(far-near) at [10], the
//   m(4,3) = -1 term at [11] and -2*far*near/(far-near) at [14].
//   Applying a matrix to a point (see project) is the Fortran
//   mat4_transform_vec3 row rule: clip_i = sum_j m(i, j) * v_j,
//   read through the column-major indices above, then divide
//   by w (perspective) -- for ortho w is always 1.
//
// SIGN CONVENTIONS (verified against f3d.js / mat4_perspective):
//   View space looks down -z: f3d.js computes vz = -dot(f, rel)
//   ("front = -z"), so visible points have z_view < 0, the near
//   plane sits at z_view = -near and the far plane at -far.
//   OpenGL-style NDC in -1..1 on every axis:
//     x_ndc =  2*x/(right-left)   - (right+left)/(right-left)
//     y_ndc =  2*y/(top-bottom)   - (top+bottom)/(top-bottom)
//     z_ndc = -2*z/(far-near)    - (far+near)/(far-near)
//   Hence z_view = -near -> z_ndc = -1 and z_view = -far -> +1,
//   exactly as mat4_perspective maps them; the leading minus on
//   z is what flips view-space -z-forward into NDC +z-away.
//   Unlike perspective there is NO depth-dependent divide for
//   x/y: an ortho x/y NDC depends only on x/y, never on z.
// Zero dependencies.

// Orthographic projection for the view-space box
// [left, right] x [bottom, top] x [-near, -far].
// Returns the 16-element column-major matrix described above:
// only [0], [5], [10], [12], [13], [14] and [15] are non-zero.
function ortho(left, right, bottom, top, near, far) {
  var rl = right - left, tb = top - bottom, fn = far - near;
  var m = new Array(16).fill(0);
  m[0] = 2 / rl;              // m(1,1)
  m[5] = 2 / tb;              // m(2,2)
  m[10] = -2 / fn;            // m(3,3)
  m[12] = -(right + left) / rl;   // m(1,4)
  m[13] = -(top + bottom) / tb;   // m(2,4)
  m[14] = -(far + near) / fn;     // m(3,4)
  m[15] = 1;                  // m(4,4)
  return m;
}

// Ortho frustum from a world-space height `size` and a viewport
// aspect (width / height): half_h = size/2, half_w = half_h *
// aspect, centred on the view axis. Same near/far meaning as
// ortho().
function fromSize(size, aspect, near, far) {
  var halfH = size / 2, halfW = halfH * aspect;
  return ortho(-halfW, halfW, -halfH, halfH, near, far);
}

// Apply matrix m (16 elements, layout above) to the view-space
// point (x, y, z) -- or to a single [x, y, z] array -- and
// divide by w, mirroring mat4_transform_vec3 with is_point.
// For an ortho matrix w = 1, so the divide is a no-op; it is
// kept so project() also works for a perspective matrix in
// the same layout. Returns [x_ndc, y_ndc, z_ndc].
function project(m, x, y, z) {
  if (Array.isArray(x)) { z = x[2]; y = x[1]; x = x[0]; }
  var cx = m[0]*x + m[4]*y + m[8]*z + m[12];
  var cy = m[1]*x + m[5]*y + m[9]*z + m[13];
  var cz = m[2]*x + m[6]*y + m[10]*z + m[14];
  var w = m[3]*x + m[7]*y + m[11]*z + m[15];
  if (w !== 0 && w !== 1) { cx /= w; cy /= w; cz /= w; }
  return [cx, cy, cz];
}

export { ortho, fromSize, project };

// Compatibility footer: attach the exported names onto
// globalThis.F3D (as F3D.Ortho) and keep the legacy F3DOrtho
// global for classic-bundle consumers.
var api = { ortho: ortho, fromSize: fromSize, project: project };
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.Ortho = api;
globalThis.F3DOrtho = api;
if (typeof window !== 'undefined') window.F3DOrtho = api;
if (typeof module !== 'undefined' && module.exports) {
  module.exports = api;
}
