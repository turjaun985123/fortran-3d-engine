// f3d-raycast -- Forge3D raycasting / picking sidecar:
// Moeller-Trumbore ray/triangle intersection and pixel picking.
// ES module (Phase 7): public names are the named exports at
// the bottom of this file; the classic bundle is built from
// the ES modules by tools/build_runtime.mjs. No sibling
// imports: this module is standalone (it uses no globals from
// runtime/f3d.js; its vec helpers are local copies).
// OPTIONAL module, load AFTER runtime/f3d.js (or standalone:
// it has no dependencies).
// Mirrors the Fortran module src/raycast.f90 EXACTLY: ray/triangle
// intersection by Moeller-Trumbore, with the shared tolerance
// contract eps = 1e-9 -- a ray is parallel / a triangle is
// degenerate when |det| < eps, and a hit is accepted only for
// t > eps (1e-9). Both windings are accepted (no back-face
// culling: det is used signed, never culled on its sign), bary-
// centric u / v must lie in the triangle, and when several
// triangles are hit the nearest t wins (the first triangle wins
// an exact tie). Zero dependencies.
var EPS = 1e-9;
var D2R = Math.PI / 180;
function sub(a, b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
function cross(a, b) { return [a[1]*b[2]-a[2]*b[1],
  a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]; }
function dot(a, b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
function norm(a) { var l = Math.hypot(a[0], a[1], a[2]);
  return l > 0 ? [a[0]/l, a[1]/l, a[2]/l] : [0, 0, 0]; }

// Moeller-Trumbore ray/triangle intersection, mirroring
// src/raycast.f90 step for step. o, d, v1, v2, v3 are [x, y, z];
// d need not be normalised (t is measured in units of d).
// Returns {t, u, v} -- the hit point is o + d*t and its bary-
// centric coordinates are [1-u-v, u, v] for [v1, v2, v3] --
// or null when there is no accepted hit.
function rayTriangle(o, d, v1, v2, v3) {
  var edge1 = sub(v2, v1), edge2 = sub(v3, v1);
  var pvec = cross(d, edge2);
  var det = dot(edge1, pvec);
  if (Math.abs(det) < EPS) return null; // parallel / degenerate
  var invDet = 1 / det;
  var tvec = sub(o, v1);
  var u = dot(tvec, pvec) * invDet;
  if (u < 0 || u > 1) return null;
  var qvec = cross(tvec, edge1);
  var v = dot(d, qvec) * invDet;
  if (v < 0 || u + v > 1) return null;
  var t = dot(edge2, qvec) * invDet;
  if (t <= EPS) return null; // behind the origin, or on it
  return { t: t, u: u, v: v };
}

// Cast a ray against a flat triangle soup:
// triangles = [x1,y1,z1, x2,y2,z2, x3,y3,z3, ...].
// Returns the NEAREST hit as {t, index, point, bary}, where
// index is the 0-based triangle index, point = o + d*t and
// bary = [w0, w1, w2] = [1-u-v, u, v]; or null on no hit.
function cast(o, d, triangles) {
  var best = null, bestT = Infinity, i, hit;
  for (i = 0; i + 9 <= triangles.length; i += 9) {
    hit = rayTriangle(o, d,
      [triangles[i], triangles[i+1], triangles[i+2]],
      [triangles[i+3], triangles[i+4], triangles[i+5]],
      [triangles[i+6], triangles[i+7], triangles[i+8]]);
    if (hit && hit.t < bestT) { // strict: first wins an exact tie
      bestT = hit.t;
      best = { t: hit.t, index: i / 9,
        point: [o[0] + d[0]*hit.t, o[1] + d[1]*hit.t,
                o[2] + d[2]*hit.t],
        bary: [1 - hit.u - hit.v, hit.u, hit.v] };
    }
  }
  return best;
}

// Pick through pixel (px, py) -- pixel coordinates, origin at the
// TOP-LEFT -- of a width x height view. Builds the ray with the
// same perspective math as runtime/f3d.js / src/camera.f90:
// forward = normalize(target - pos),
// right = normalize(cross(forward, up)),
// trueUp = cross(right, forward),
// ndcX = 2*(px+0.5)/width - 1, ndcY = 1 - 2*(py+0.5)/height,
// dir = normalize(forward + right * (ndcX * tan(fov/2) * aspect)
//                        + trueUp * (ndcY * tan(fov/2))),
// aspect = width / height, fovDeg the vertical field of view.
// Returns the same nearest-hit object as cast(), or null.
function pick(px, py, width, height, camPos, camTarget, camUp,
    fovDeg, triangles) {
  var forward = norm(sub(camTarget, camPos));
  var right = norm(cross(forward, camUp));
  var trueUp = cross(right, forward);
  var aspect = width / height;
  var tanHalf = Math.tan(fovDeg * D2R / 2);
  var ndcX = 2 * (px + 0.5) / width - 1;
  var ndcY = 1 - 2 * (py + 0.5) / height;
  var sx = ndcX * tanHalf * aspect, sy = ndcY * tanHalf;
  var dir = norm([
    forward[0] + right[0]*sx + trueUp[0]*sy,
    forward[1] + right[1]*sx + trueUp[1]*sy,
    forward[2] + right[2]*sx + trueUp[2]*sy]);
  return cast(camPos, dir, triangles);
}

export { rayTriangle, cast, pick };

// Compatibility footer: attach the exported names onto
// globalThis.F3D (as F3D.Ray) and keep the legacy F3DRay
// global for classic-bundle consumers.
var api = { rayTriangle: rayTriangle, cast: cast, pick: pick };
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.Ray = api;
globalThis.F3DRay = api;
if (typeof window !== 'undefined') window.F3DRay = api;
