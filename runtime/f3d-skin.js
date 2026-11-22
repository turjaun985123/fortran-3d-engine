// Forge3D skinning + morph sidecar - OPTIONAL module, load
// AFTER runtime/f3d.js (or standalone: it has no dependencies).
// C1 skinning + morph contract, operating on FLAT vertex arrays
// (number[], xyz triples, triangle soup -- the layout the other
// sidecars use). Plain script, zero deps, no modules.
//
// Morphs (centroid = mean of all vertices):
//   bulge: barrel profile — x/z scale s = 1 + factor*0.5*(1 - q^2), q = (y - cy)/halfh, strongest at the middle height, poles unchanged
//           (halfh = max |y - cy|; 0 -> copy); y unchanged.
//   taper:  h = (y-ymin)/(ymax-ymin) (flat -> copy);
//           s = 1 - factor*0.5*h; x,z scaled about centroid
//           x,z; y unchanged.
//   squash: y' = cy + (y-cy)*(1-0.5*factor); x',z' scaled about
//           the centroid by (1+0.25*factor).
// factor 0 is an exact copy for every kind; an unknown kind
// throws. Every function returns a NEW array and never mutates
// its input.
//
// Skinning: skinWeight is the smoothstep falloff
// s*s*(3-2*s) of s = clamp(1-dist/radius, 0, 1) (radius <= 0
// gives 0). skinApply blends each vertex toward its image under
// the bone matrix M = T(pivot) * Rz * Ry * Rx * T(-pivot), with
// angles in DEGREES and the rotation conventions of
// src/math_3d.f90 mat4_rotate_x/y/z:
//   Rx: y' = c*y - s*z,  z' = s*y + c*z
//   Ry: x' = c*x + s*z,  z' = -s*x + c*z
//   Rz: x' = c*x - s*y,  y' = s*x + c*y
// p' = (1-w)*p + w*(M*p) with w = skinWeight(|p-pivot|, radius);
// vertices at dist >= radius are bit-identical to the input.
'use strict';
(function (g) {
var D2R = Math.PI / 180;

function centroid(verts) {
  var n = Math.floor(verts.length / 3), i;
  var cx = 0, cy = 0, cz = 0;
  for (i = 0; i < n; i++) {
    cx += verts[3*i]; cy += verts[3*i+1]; cz += verts[3*i+2];
  }
  return n > 0 ? [cx / n, cy / n, cz / n] : [0, 0, 0];
}

function morphApply(verts, kind, factor) {
  if (kind !== 'bulge' && kind !== 'taper' && kind !== 'squash') {
    throw new Error('Forge3DSkin.morphApply: unknown kind ' +
      JSON.stringify(kind));
  }
  var out = verts.slice();
  var n = Math.floor(verts.length / 3), i;
  if (n === 0 || factor === 0) return out; // factor 0: exact copy
  var c = centroid(verts);
  if (kind === 'bulge') {
    var halfh = 0;
    for (i = 0; i < n; i++) {
      var dy = Math.abs(verts[3*i+1] - c[1]);
      if (dy > halfh) halfh = dy;
    }
    if (halfh === 0) return out;
    for (i = 0; i < n; i++) {
      var q = (verts[3*i+1] - c[1]) / halfh;
      var s = 1 + factor * 0.5 * (1 - q * q);
      out[3*i]   = c[0] + (verts[3*i]   - c[0]) * s;
      out[3*i+1] = verts[3*i+1]; // y unchanged
      out[3*i+2] = c[2] + (verts[3*i+2] - c[2]) * s;
    }
  } else if (kind === 'taper') {
    var ymin = Infinity, ymax = -Infinity;
    for (i = 0; i < n; i++) {
      if (verts[3*i+1] < ymin) ymin = verts[3*i+1];
      if (verts[3*i+1] > ymax) ymax = verts[3*i+1];
    }
    if (ymax === ymin) return out; // flat in y: copy
    for (i = 0; i < n; i++) {
      var h = (verts[3*i+1] - ymin) / (ymax - ymin);
      var ts = 1 - factor * 0.5 * h;
      out[3*i]   = c[0] + (verts[3*i]   - c[0]) * ts;
      out[3*i+1] = verts[3*i+1]; // y unchanged
      out[3*i+2] = c[2] + (verts[3*i+2] - c[2]) * ts;
    }
  } else { // squash
    var ys = 1 - 0.5 * factor, xzs = 1 + 0.25 * factor;
    for (i = 0; i < n; i++) {
      out[3*i]   = c[0] + (verts[3*i]   - c[0]) * xzs;
      out[3*i+1] = c[1] + (verts[3*i+1] - c[1]) * ys;
      out[3*i+2] = c[2] + (verts[3*i+2] - c[2]) * xzs;
    }
  }
  return out;
}

function skinWeight(dist, radius) {
  if (!(radius > 0)) return 0;
  var s = 1 - dist / radius;
  if (s < 0) s = 0; else if (s > 1) s = 1;
  return s * s * (3 - 2 * s);
}

// Rotate q = [x, y, z] by Rx then Ry then Rz (i.e. Rz*Ry*Rx*q),
// angles in degrees, math_3d.f90 conventions (see header).
function rotateXYZ(q, rotDeg) {
  var cx = Math.cos(rotDeg[0] * D2R), sx = Math.sin(rotDeg[0] * D2R);
  var cy = Math.cos(rotDeg[1] * D2R), sy = Math.sin(rotDeg[1] * D2R);
  var cz = Math.cos(rotDeg[2] * D2R), sz = Math.sin(rotDeg[2] * D2R);
  var x = q[0], y = q[1], z = q[2], t;
  t = cx * y - sx * z; z = sx * y + cx * z; y = t;   // Rx
  t = cy * x + sy * z; z = -sy * x + cy * z; x = t;  // Ry
  t = cz * x - sz * y; y = sz * x + cz * y; x = t;   // Rz
  return [x, y, z];
}

function skinApply(verts, pivot, rotDeg, radius) {
  var out = verts.slice();
  var n = Math.floor(verts.length / 3), i;
  for (i = 0; i < n; i++) {
    var px = verts[3*i], py = verts[3*i+1], pz = verts[3*i+2];
    var dx = px - pivot[0], dy = py - pivot[1], dz = pz - pivot[2];
    var w = skinWeight(Math.hypot(dx, dy, dz), radius);
    if (w === 0) continue; // dist >= radius: bit-identical copy
    var r = rotateXYZ([dx, dy, dz], rotDeg);
    var mx = pivot[0] + r[0], my = pivot[1] + r[1],
        mz = pivot[2] + r[2];
    out[3*i]   = (1 - w) * px + w * mx;
    out[3*i+1] = (1 - w) * py + w * my;
    out[3*i+2] = (1 - w) * pz + w * mz;
  }
  return out;
}

g.Forge3DSkin = { morphApply: morphApply, skinWeight: skinWeight,
                  skinApply: skinApply };
if (typeof window !== 'undefined') window.Forge3DSkin = g.Forge3DSkin;
})(typeof globalThis !== 'undefined' ? globalThis : this);
