// Forge3D Geometry sidecar - OPTIONAL module, load AFTER
// runtime/f3d.js. JS mirror of the Wave D geometry builders:
// ten additional primitives in the exact output format of the
// f3d.js builders -- each builder returns a flat array of
// triangles [[a, b, c, faceIdx], ...] where a/b/c are plain
// [x, y, z] vertex arrays and faceIdx is an integer part index
// (0 unless a builder says otherwise), matching the convention
// of the `tri(o, a, b, c, f)` helper in f3d.js.
// Plain script, zero deps, no modules. Loading it without
// f3d.js is safe: the registry hook at the bottom is guarded.
//
// Builders and EXACT triangle counts (seg is clamped to >= 3
// unless noted; counts are after the stated normalisation):
//   circle(radius=1, seg=16)          2*seg
//     Flat disc in the XZ plane (y = 0), double-sided centre fan.
//   ring(inner=0.5, outer=1, seg=16)   4*seg
//     Flat annulus in the XZ plane (y = 0), double-sided quads.
//   capsule(radius=1, height=2, seg=16)
//     seg is rounded UP to a multiple of 4; with hr = seg/4 the
//     count is 2*seg + 2*seg*(2*hr-1). Y axis: a cylinder band of
//     the given height between two hemisphere caps of `radius`
//     (total height = height + 2*radius).
//   tube(radius=0.25, seg=8, pathPts=[[0,-1,0],[0,1,0]])
//     (n-1)*seg*2 + 2*seg for n = pathPts.length >= 2: a swept
//     circle along the path with parallel-transport frames and
//     a centre fan cap at each end.
//   lathe(seg=16, profilePts=[[0,-1],[1,-1],[1,1],[0,1]])
//     (n-1)*seg*2 for n = profilePts.length: the profile
//     ([radius, y] pairs, ordered bottom to top) revolved
//     around the Y axis. No caps.
//   extrude(depth=1, shapePts=[[-1,-1],[1,-1],[1,1],[-1,1]])
//     4*n-4 for n = shapePts.length >= 3: the shape ([x, y]
//     pairs) is mapped to world (x, 0, y), extruded +Y by
//     `depth`, with fan caps; the point order is winding-
//     normalised first, so either input order gives outward
//     faces (top cap +Y, bottom cap -Y).
//   tetrahedron(r=1)   4      octahedron(r=1)    8
//   icosahedron(r=1)   20     dodecahedron(r=1)  36
//     Platonic solids with circumradius r (every vertex lies at
//     distance r from the origin) and outward winding; the
//     dodecahedron's 12 pentagons are fan-triangulated (3 each).
//   torusknot(radius=1, tube=0.35, seg=48, tseg=12)
//     seg*tseg*2. (p, q) = (2, 3) torus knot: centreline
//     x = R*(2+cos(3u))*cos(2u)/2, y = R*(2+cos(3u))*sin(2u)/2,
//     z = R*sin(3u)/2 for u in [0, 2*pi), swept with
//     parallel-transport frames, wrapping in both directions.
//
// `triCount` mirrors each builder's signature (minus nothing)
// and returns the exact triangle count the builder produces
// for the same arguments, applying the same normalisation.
'use strict';
(function (g) {

function tri(o, a, b, c, f) { o.push([a, b, c, f || 0]); }
function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
function cross(a, b) {
  return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
          a[0] * b[1] - a[1] * b[0]];
}
function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
function norm(a) {
  var l = Math.hypot(a[0], a[1], a[2]);
  return l > 1e-12 ? [a[0] / l, a[1] / l, a[2] / l] : [0, 0, 0];
}
function segMin(s, d) { s = s == null ? d : (s | 0); return Math.max(3, s); }

// Parallel-transport frames for a polyline: tangents T[i] from
// successive points (closed loops wrap), one normal N[i] carried
// along by projection onto the plane perpendicular to T[i] (the
// rotation-free transport step), B[i] = T[i] x N[i].
function ptFrames(pts, closed) {
  var n = pts.length, T = [], N = [], B = [], i, d, a;
  for (i = 0; i < n; i++) {
    if (closed) d = sub(pts[(i + 1) % n], pts[(i - 1 + n) % n]);
    else if (i === 0) d = sub(pts[1], pts[0]);
    else if (i === n - 1) d = sub(pts[n - 1], pts[n - 2]);
    else d = sub(pts[i + 1], pts[i - 1]);
    T.push(norm(d));
  }
  a = Math.abs(T[0][1]) < 0.9 ? [0, 1, 0] : [1, 0, 0];
  N.push(norm(sub(a, T[0].map(function (v) {
    return v * dot(a, T[0]);
  }))));
  for (i = 1; i < n; i++) {
    var p = N[i - 1], pr = sub(p, T[i].map(function (v) {
      return v * dot(p, T[i]);
    }));
    if (Math.hypot(pr[0], pr[1], pr[2]) < 1e-9) {
      a = Math.abs(T[i][1]) < 0.9 ? [0, 1, 0] : [1, 0, 0];
      pr = sub(a, T[i].map(function (v) { return v * dot(a, T[i]); }));
    }
    N.push(norm(pr));
  }
  for (i = 0; i < n; i++) B.push(cross(N[i], T[i]));
  return { T: T, N: N, B: B };
}
function ringPt(c, fr, i, radius, th) {
  var co = Math.cos(th) * radius, si = Math.sin(th) * radius;
  return [c[0] + fr.N[i][0] * co + fr.B[i][0] * si,
          c[1] + fr.N[i][1] * co + fr.B[i][1] * si,
          c[2] + fr.N[i][2] * co + fr.B[i][2] * si];
}

// ---- builders -------------------------------------------------

function circle(radius, seg) {
  radius = radius == null ? 1 : +radius; seg = segMin(seg, 16);
  var o = [], c = [0, 0, 0], i;
  function pt(ii) {
    var th = 2 * Math.PI * ii / seg;
    return [radius * Math.cos(th), 0, radius * Math.sin(th)];
  }
  for (i = 0; i < seg; i++) { // +Y face, then mirrored -Y face
    tri(o, c, pt(i + 1), pt(i), 0);
    tri(o, c, pt(i), pt(i + 1), 1);
  }
  return o;
}

function ring(inner, outer, seg) {
  inner = inner == null ? 0.5 : +inner;
  outer = outer == null ? 1 : +outer; seg = segMin(seg, 16);
  var o = [], i;
  function pt(r, ii) {
    var th = 2 * Math.PI * ii / seg;
    return [r * Math.cos(th), 0, r * Math.sin(th)];
  }
  for (i = 0; i < seg; i++) {
    var i1 = pt(inner, i), i2 = pt(inner, i + 1),
        o1 = pt(outer, i), o2 = pt(outer, i + 1);
    tri(o, i1, i2, o2, 0); tri(o, i1, o2, o1, 0); // +Y
    tri(o, i1, o2, i2, 1); tri(o, i1, o1, o2, 1); // -Y
  }
  return o;
}

function capsuleSeg(seg) { // round up to a multiple of 4, min 4
  seg = seg == null ? 16 : Math.ceil(Math.max(1, seg) / 4) * 4;
  return Math.max(4, seg);
}
function capsule(radius, height, seg) {
  radius = radius == null ? 1 : +radius;
  height = height == null ? 2 : +height; seg = capsuleSeg(seg);
  var hr = seg / 4, hh = height / 2, o = [], i, j;
  // Point on the capsule surface: jj in [0, 2*hr] runs over the
  // top hemisphere (jj < hr), the equator join (jj = hr is the
  // top equator; the band below it is the cylinder) -- built
  // instead as top hemi rings, cylinder band, bottom hemi rings.
  function hemiPt(cy, jj, ii) { // jj in [0, hr]: pole -> equator
    var ph = (Math.PI / 2) * jj / hr, th = 2 * Math.PI * ii / seg;
    return [radius * Math.sin(ph) * Math.cos(th),
            cy + radius * Math.cos(ph),
            radius * Math.sin(ph) * Math.sin(th)];
  }
  function botPt(jj, ii) { // jj in [0, hr]: equator -> pole
    var ph = (Math.PI / 2) * jj / hr, th = 2 * Math.PI * ii / seg;
    return [radius * Math.cos(ph) * Math.cos(th),
            -hh - radius * Math.sin(ph),
            radius * Math.cos(ph) * Math.sin(th)];
  }
  var top = [0, hh + radius, 0], bot = [0, -hh - radius, 0];
  for (i = 0; i < seg; i++) // top fan
    tri(o, top, hemiPt(hh, 1, (i + 1) % seg), hemiPt(hh, 1, i), 0);
  for (j = 1; j < hr; j++) for (i = 0; i < seg; i++) { // top bands
    var a = hemiPt(hh, j, i), b = hemiPt(hh, j, (i + 1) % seg),
        c = hemiPt(hh, j + 1, (i + 1) % seg), d = hemiPt(hh, j + 1, i);
    tri(o, a, b, c, 0); tri(o, a, c, d, 0);
  }
  for (i = 0; i < seg; i++) { // cylinder band, f3d.js winding
    var b1 = botPt(0, i), b2 = botPt(0, (i + 1) % seg),
        t1 = hemiPt(hh, hr, i), t2 = hemiPt(hh, hr, (i + 1) % seg);
    tri(o, b1, t2, b2, 1); tri(o, b1, t1, t2, 1);
  }
  for (j = 0; j < hr - 1; j++) for (i = 0; i < seg; i++) { // bot bands
    var a2 = botPt(j, i), b3 = botPt(j, (i + 1) % seg),
        c2 = botPt(j + 1, (i + 1) % seg), d2 = botPt(j + 1, i);
    tri(o, a2, b3, c2, 2); tri(o, a2, c2, d2, 2);
  }
  for (i = 0; i < seg; i++) // bottom fan
    tri(o, bot, botPt(hr - 1, i), botPt(hr - 1, (i + 1) % seg), 2);
  return o;
}

function tube(radius, seg, pathPts) {
  radius = radius == null ? 0.25 : +radius; seg = segMin(seg, 8);
  pathPts = pathPts || [[0, -1, 0], [0, 1, 0]];
  var n = pathPts.length, o = [], i, k;
  if (n < 2) return o;
  var fr = ptFrames(pathPts, false);
  function rp(kk, ii) {
    return ringPt(pathPts[kk], fr, kk, radius,
                  2 * Math.PI * ii / seg);
  }
  for (k = 0; k < n - 1; k++) for (i = 0; i < seg; i++) {
    var b1 = rp(k, i), b2 = rp(k, (i + 1) % seg),
        t1 = rp(k + 1, i), t2 = rp(k + 1, (i + 1) % seg);
    tri(o, b1, t2, b2, 0); tri(o, b1, t1, t2, 0);
  }
  for (i = 0; i < seg; i++) { // start cap (-T) and end cap (+T)
    tri(o, pathPts[0].slice(), rp(0, i), rp(0, (i + 1) % seg), 1);
    tri(o, pathPts[n - 1].slice(), rp(n - 1, (i + 1) % seg),
        rp(n - 1, i), 2);
  }
  return o;
}

function lathe(seg, profilePts) {
  seg = segMin(seg, 16);
  profilePts = profilePts || [[0, -1], [1, -1], [1, 1], [0, 1]];
  var n = profilePts.length, o = [], i, j;
  if (n < 2) return o;
  function pt(jj, ii) {
    var th = 2 * Math.PI * ii / seg, p = profilePts[jj];
    return [p[0] * Math.cos(th), p[1], p[0] * Math.sin(th)];
  }
  for (j = 0; j < n - 1; j++) for (i = 0; i < seg; i++) {
    var a = pt(j, i), b = pt(j, (i + 1) % seg),
        c = pt(j + 1, (i + 1) % seg), d = pt(j + 1, i);
    tri(o, a, c, b, 0); tri(o, a, d, c, 0);
  }
  return o;
}

function extrude(depth, shapePts) {
  depth = depth == null ? 1 : +depth;
  shapePts = shapePts || [[-1, -1], [1, -1], [1, 1], [-1, 1]];
  var n = shapePts.length, o = [], i, area = 0;
  if (n < 3) return o;
  var pts = shapePts.map(function (p) { return [+p[0], +p[1]]; });
  for (i = 0; i < n; i++) { // signed area in world (x, z) coords
    var p = pts[i], q = pts[(i + 1) % n];
    area += p[0] * q[1] - q[0] * p[1];
  }
  if (area > 0) pts.reverse(); // normalise: area < 0 (see header)
  function B(ii) { var p = pts[ii]; return [p[0], 0, p[1]]; }
  function T(ii) { var p = pts[ii]; return [p[0], depth, p[1]]; }
  for (i = 0; i < n; i++) { // sides
    var i2 = (i + 1) % n;
    tri(o, B(i), B(i2), T(i2), 0); tri(o, B(i), T(i2), T(i), 0);
  }
  for (i = 1; i < n - 1; i++) { // fan caps: top +Y, bottom -Y
    tri(o, T(0), T(i), T(i + 1), 1);
    tri(o, B(0), B(i + 1), B(i), 2);
  }
  return o;
}

function platonic(verts, faces, r) {
  var o = [], s = r / Math.hypot(verts[0][0], verts[0][1],
                                 verts[0][2]);
  var V = verts.map(function (v) {
    return [v[0] * s, v[1] * s, v[2] * s];
  });
  faces.forEach(function (f, fi) {
    tri(o, V[f[0]], V[f[1]], V[f[2]], fi);
  });
  return o;
}
function tetrahedron(r) {
  return platonic(
    [[1, 1, 1], [1, -1, -1], [-1, 1, -1], [-1, -1, 1]],
    [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]],
    r == null ? 1 : +r);
}
function octahedron(r) {
  return platonic(
    [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1],
     [0, 0, -1]],
    [[0, 2, 4], [0, 5, 2], [0, 4, 3], [0, 3, 5], [1, 4, 2],
     [1, 2, 5], [1, 3, 4], [1, 5, 3]],
    r == null ? 1 : +r);
}
function icosahedron(r) {
  var t = (1 + Math.sqrt(5)) / 2;
  return platonic(
    [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t],
     [0, 1, t], [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1],
     [-t, 0, -1], [-t, 0, 1]],
    [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
     [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
     [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
     [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]],
    r == null ? 1 : +r);
}
function dodecahedron(r) {
  var t = (1 + Math.sqrt(5)) / 2, p = 1 / t;
  return platonic(
    [[1, 1, 1], [1, 1, -1], [1, -1, 1], [1, -1, -1], [-1, 1, 1],
     [-1, 1, -1], [-1, -1, 1], [-1, -1, -1], [0, t, p], [0, t, -p],
     [0, -t, p], [0, -t, -p], [p, 0, t], [p, 0, -t], [-p, 0, t],
     [-p, 0, -t], [t, p, 0], [t, -p, 0], [-t, p, 0], [-t, -p, 0]],
    [[8, 0, 16], [8, 16, 1], [8, 1, 9], [2, 17, 16], [2, 16, 0],
     [2, 0, 12], [14, 12, 0], [14, 0, 8], [14, 8, 4], [1, 16, 17],
     [1, 17, 3], [1, 3, 13], [5, 9, 1], [5, 1, 13], [5, 13, 15],
     [11, 3, 17], [11, 17, 2], [11, 2, 10], [6, 10, 2],
     [6, 2, 12], [6, 12, 14], [15, 13, 3], [15, 3, 11],
     [15, 11, 7], [4, 8, 9], [4, 9, 5], [4, 5, 18], [19, 6, 14],
     [19, 14, 4], [19, 4, 18], [18, 5, 15], [18, 15, 7],
     [18, 7, 19], [7, 11, 10], [7, 10, 6], [7, 6, 19]],
    r == null ? 1 : +r);
}

function torusknot(radius, tube, seg, tseg) {
  radius = radius == null ? 1 : +radius;
  tube = tube == null ? 0.35 : +tube;
  seg = segMin(seg, 48); tseg = segMin(tseg, 12);
  var o = [], i, j, pts = [];
  function centre(u) {
    var w = 2 + Math.cos(3 * u);
    return [radius * w * Math.cos(2 * u) / 2,
            radius * w * Math.sin(2 * u) / 2,
            radius * Math.sin(3 * u) / 2];
  }
  for (i = 0; i < seg; i++) pts.push(centre(2 * Math.PI * i / seg));
  var fr = ptFrames(pts, true);
  function pt(ii, jj) {
    return ringPt(pts[ii % seg], fr, ii % seg, tube,
                  2 * Math.PI * jj / tseg);
  }
  for (i = 0; i < seg; i++) for (j = 0; j < tseg; j++) {
    var a = pt(i, j), b = pt(i + 1, j), c = pt(i + 1, j + 1),
        d = pt(i, j + 1);
    tri(o, a, c, d, 0); tri(o, a, b, c, 0); // tube-sweep winding
  }
  return o;
}

// ---- tri counts (same signatures, same normalisation) ---------

var triCount = {
  circle: function (radius, seg) { return 2 * segMin(seg, 16); },
  ring: function (inner, outer, seg) { return 4 * segMin(seg, 16); },
  capsule: function (radius, height, seg) {
    seg = capsuleSeg(seg); var hr = seg / 4;
    return 2 * seg + 2 * seg * (2 * hr - 1);
  },
  tube: function (radius, seg, pathPts) {
    seg = segMin(seg, 8);
    var n = (pathPts || [[0, -1, 0], [0, 1, 0]]).length;
    return n < 2 ? 0 : (n - 1) * seg * 2 + 2 * seg;
  },
  lathe: function (seg, profilePts) {
    seg = segMin(seg, 16);
    var n = (profilePts || [[0, -1], [1, -1], [1, 1], [0, 1]]).length;
    return n < 2 ? 0 : (n - 1) * seg * 2;
  },
  extrude: function (depth, shapePts) {
    var n = (shapePts || [[-1, -1], [1, -1], [1, 1], [-1, 1]]).length;
    return n < 3 ? 0 : 4 * n - 4;
  },
  tetrahedron: function (r) { return 4; },
  octahedron: function (r) { return 8; },
  icosahedron: function (r) { return 20; },
  dodecahedron: function (r) { return 36; },
  torusknot: function (radius, tube, seg, tseg) {
    return segMin(seg, 48) * segMin(tseg, 12) * 2;
  }
};

var builders = {
  circle: circle, ring: ring, capsule: capsule, tube: tube,
  lathe: lathe, extrude: extrude, tetrahedron: tetrahedron,
  octahedron: octahedron, icosahedron: icosahedron,
  dodecahedron: dodecahedron, torusknot: torusknot
};

var api = { builders: builders, triCount: triCount };
g.Forge3DGeo = api;
if (typeof window !== 'undefined') window.Forge3DGeo = api;

// Registry hook: if f3d.js (or another host) exposes a builder
// registry, extend it -- guarded so this sidecar never throws
// when f3d.js is absent or has no registry.
try {
  var host = g.F3D || g.Forge3D || null;
  if (host) {
    host.builders = host.builders || {};
    Object.keys(builders).forEach(function (k) {
      host.builders[k] = builders[k];
    });
    host.geo = api;
  }
} catch (e) { /* no registry: the sidecar stands alone */ }
})(typeof globalThis !== 'undefined' ? globalThis : this);
