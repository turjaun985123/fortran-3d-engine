// Forge3D module "f3d-keys" -- keyframe sidecar.
// Role: OPTIONAL module, load AFTER runtime/f3d.js. Mirrors the
// Fortran module src/keyframe.f90 (key_eval, and the Phase 5
// key_eval_q via evalTrackQ below): keyframed pos / rot /
// scale tracks with named easing and once / forever / pingpong
// looping.
// ES module (Phase 7): the public names are declared with named
// exports below. A classic (non-module) bundle is produced from
// this module by tools/build_runtime.mjs; the compatibility
// footer at the bottom preserves the legacy globals for classic
// consumers.
// Imports: none. This module uses no sibling-runtime globals --
// the core helpers in runtime/f3d.js are not exported individually
// and this file defines its own clamp / v3 / pose helpers, exactly
// as the classic script did. Zero deps.
//
// Track shape:
//   { target, duration, loop,
//     keys: [{ time, pos: [x, y, z], rot: [x, y, z], scale, ease }] }
// The ease named on a key drives the segment ENDING at that key.
// evalTrack(track, t) -> { pos: [3], rot: [3], scale }.
function clamp(x, a, b) { return x < a ? a : (x > b ? b : x); }
function v3(v, d) { return v == null ? d.slice()
  : [ +v[0] || 0, +v[1] || 0, +v[2] || 0 ]; }
function pose(key) { return { pos: v3(key.pos, [0, 0, 0]),
  rot: v3(key.rot, [0, 0, 0]),
  scale: key.scale == null ? 1 : +key.scale }; }

// One coordinate of the cubic Bezier with endpoints 0 and 1 and
// control values c1, c2, at parameter t (bezier_coord in
// src/animation.f90), and its derivative (bezier_coord_dt).
function bezierCoord(c1, c2, t) {
  var mt = 1 - t;
  return 3 * mt * mt * t * c1 + 3 * mt * t * t * c2 + t * t * t;
}
function bezierCoordDt(c1, c2, t) {
  var mt = 1 - t;
  return 3 * mt * mt * c1 + 6 * mt * t * (c2 - c1) +
    3 * t * t * (1 - c2);
}

// Cubic-bezier easing (bezier_ease in src/animation.f90): solve
// x(t) = p for t (Newton from t = p, 8 iterations; bisection
// fallback, 40 iterations), return y(t).
function bezierEase(x1, y1, x2, y2, p) {
  if (p <= 0) return 0;
  if (p >= 1) return 1;
  var t = p, err, der, i, lo, hi;
  for (i = 0; i < 8; i++) {
    err = bezierCoord(x1, x2, t) - p;
    if (Math.abs(err) < 1e-12) break;
    der = bezierCoordDt(x1, x2, t);
    if (Math.abs(der) < 1e-9) break;
    t = t - err / der;
    if (t < 0 || t > 1) break;
  }
  if (t < 0 || t > 1 || Math.abs(bezierCoord(x1, x2, t) - p) >= 1e-9) {
    lo = 0; hi = 1; t = p;
    for (i = 0; i < 40; i++) {
      err = bezierCoord(x1, x2, t) - p;
      if (Math.abs(err) < 1e-12) break;
      if (err > 0) hi = t; else lo = t;
      t = 0.5 * (lo + hi);
    }
  }
  return bezierCoord(y1, y2, t);
}

// Parse 'bezier(x1,y1,x2,y2)': exactly 4 numeric arguments, the
// closing ')' as the last character; x values clamped to [0,1].
// Returns [x1, y1, x2, y2] or null when malformed (the Fortran
// parse_bezier_args / parse_decimal accept only strict decimals;
// Number() is the JS analogue used here).
function parseBezier(name) {
  if (typeof name !== 'string') return null;
  var nm = name.trim();
  if (nm.slice(0, 7) !== 'bezier(' || nm[nm.length - 1] !== ')') {
    return null;
  }
  var parts = nm.slice(7, nm.length - 1).split(',');
  if (parts.length !== 4) return null;
  var vals = [], i, s;
  for (i = 0; i < 4; i++) {
    s = parts[i].trim();
    if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(s)) return null;
    vals.push(Number(s));
  }
  vals[0] = clamp(vals[0], 0, 1);
  vals[2] = clamp(vals[2], 0, 1);
  return vals;
}

// Easing on normalised progress p (clamped to [0,1] here), exactly
// as ease_value in src/animation.f90:
//   'linear' -> p                 'smooth' -> p*p*(3-2p)
//   'in'     -> p*p               'out'    -> 1-(1-p)^2
//   'cubic-in'     -> p^3
//   'cubic-out'    -> 1-(1-p)^3
//   'cubic-in-out' -> 4p^3 for p < 0.5, else 1-(-2p+2)^3/2
//   'bezier(x1,y1,x2,y2)' -> cubic Bezier (see bezierEase above);
//       a malformed bezier string falls back to linear.
//   'hold'   -> 0 (step: the segment holds its START value until
//       the end key; the eased factor is 0 at every progress).
// Unknown names fall back to linear.
function ease(name, p) {
  var u = clamp(+p || 0, 0, 1);
  var bez = parseBezier(name);
  if (bez) return bezierEase(bez[0], bez[1], bez[2], bez[3], u);
  if (typeof name === 'string' &&
      name.trim().slice(0, 7) === 'bezier(') return u; // malformed
  switch (name) {
    case 'smooth': return u * u * (3 - 2 * u);
    case 'in': return u * u;
    case 'out': return 1 - (1 - u) * (1 - u);
    case 'cubic-in': return u * u * u;
    case 'cubic-out': return 1 - (1 - u) * (1 - u) * (1 - u);
    case 'cubic-in-out':
      return u < 0.5 ? 4 * u * u * u
        : 1 - Math.pow(-2 * u + 2, 3) / 2;
    case 'hold': return 0;
    default: return u; // 'linear' and anything unknown
  }
}

// Evaluate a track at global time t -> { pos, rot, scale }.
//   empty keys -> identity pose { pos 0, rot 0, scale 1 }.
//   D = duration > 0 ? duration : last key time; D <= 0 -> first
//   key pose. Loop map on t:
//     'once'     -> te = clamp(t, 0, D)
//     'forever'  -> te = mod(max(t, 0), D)
//     'pingpong' -> cyc = mod(max(t, 0), 2D),
//                   te = cyc <= D ? cyc : 2D - cyc
//   Unknown loop modes behave as 'once'. te at/before the first
//   key time gives the first pose, at/after the last key time the
//   last pose; between keys i and i+1 the pose is lerped by
//   e = ease(keys[i+1].ease, p), p = (te - t_i) / (t_{i+1} - t_i)
//   (p = 0 for a zero-length segment).
function evalTrack(track, t) {
  var keys = (track && track.keys) || [];
  if (!keys.length) return { pos: [0, 0, 0], rot: [0, 0, 0], scale: 1 };
  var first = keys[0], last = keys[keys.length - 1];
  var D = track.duration > 0 ? +track.duration : +last.time;
  if (!(D > 0)) return pose(first);
  var te;
  if (track.loop === 'forever') {
    te = Math.max(+t || 0, 0) % D;
  } else if (track.loop === 'pingpong') {
    var cyc = Math.max(+t || 0, 0) % (2 * D);
    te = cyc <= D ? cyc : 2 * D - cyc;
  } else { // 'once' and anything unknown
    te = clamp(+t || 0, 0, D);
  }
  if (te <= first.time) return pose(first);
  if (te >= last.time) return pose(last);
  var i, a, b, span, p, e, out;
  for (i = 0; i < keys.length - 1; i++) {
    a = keys[i]; b = keys[i + 1];
    if (te > b.time && i < keys.length - 2) continue;
    span = b.time - a.time;
    p = span === 0 ? 0 : (te - a.time) / span;
    e = ease(b.ease, p);
    a = pose(a); b = pose(b);
    out = { pos: [], rot: [], scale: a.scale + (b.scale - a.scale) * e };
    for (var j = 0; j < 3; j++) {
      out.pos[j] = a.pos[j] + (b.pos[j] - a.pos[j]) * e;
      out.rot[j] = a.rot[j] + (b.rot[j] - a.rot[j]) * e;
    }
    return out;
  }
  return pose(last); // single-key track (first pose == last pose)
}

// ------------------------------------------------------------------
// key_eval_q mirror (src/keyframe.f90, Phase 5): same loop-map /
// segment / easing skeleton as evalTrack (including the fps time
// conversion tt = t * fps when track.fps > 0), but rotation is
// interpolated with quaternion slerp and scale is per-axis.
// Quaternions are plain [x, y, z, w] arrays. A key's rotation is
// its `quat` when present, else its Euler `rot` (degrees)
// converted with quatFromEuler; its per-axis scale is `scale3`
// when present, else an array `scale`, else the uniform `scale`
// broadcast to all three axes.
// ------------------------------------------------------------------

function quatNormalize(q) {
  var l = Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] +
    q[3] * q[3]);
  if (l > 1e-12) return [q[0] / l, q[1] / l, q[2] / l, q[3] / l];
  return [0, 0, 0, 1]; // identity (quat_normalize in math_3d.f90)
}
function quatMultiply(a, b) { // Hamilton product a (x) b
  return [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
}
function quatFromAxisAngle(ax, ay, az, deg) {
  var l = Math.sqrt(ax * ax + ay * ay + az * az);
  if (l <= 1e-12) return [0, 0, 0, 1];
  var s = Math.sin(deg * Math.PI / 360); // sin(half angle)
  return [ax / l * s, ay / l * s, az / l * s,
    Math.cos(deg * Math.PI / 360)];
}
// Euler degrees (x, y, z) = (pitch, yaw, roll), order
// q = qy (x) qx (x) qz (quat_from_euler in src/math_3d.f90).
function quatFromEuler(rot) {
  var qx = quatFromAxisAngle(1, 0, 0, rot[0]);
  var qy = quatFromAxisAngle(0, 1, 0, rot[1]);
  var qz = quatFromAxisAngle(0, 0, 1, rot[2]);
  return quatMultiply(qy, quatMultiply(qx, qz));
}
// Spherical linear interpolation, SHORTEST PATH (quat_slerp in
// src/math_3d.f90): dot < 0 negates the second quaternion;
// dot > 0.9995 falls back to normalised lerp; t clamped to [0,1];
// endpoints return the normalised inputs.
function quatSlerp(q1, q2, t) {
  var tt = clamp(+t || 0, 0, 1);
  var a = quatNormalize(q1), b = quatNormalize(q2), i;
  if (tt <= 0) return a;
  if (tt >= 1) return b;
  var d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
  if (d < 0) { b = [-b[0], -b[1], -b[2], -b[3]]; d = -d; }
  if (d > 0.9995) {
    var r = [];
    for (i = 0; i < 4; i++) r.push(a[i] + (b[i] - a[i]) * tt);
    return quatNormalize(r);
  }
  var theta = Math.acos(Math.min(d, 1)), s = Math.sin(theta);
  var wa = Math.sin((1 - tt) * theta) / s, wb = Math.sin(tt * theta) / s;
  var out = [];
  for (i = 0; i < 4; i++) out.push(a[i] * wa + b[i] * wb);
  return quatNormalize(out);
}

function keyQuat(key) {
  if (key.quat != null) {
    return [+key.quat[0] || 0, +key.quat[1] || 0, +key.quat[2] || 0,
      +key.quat[3] || 0];
  }
  return quatFromEuler(v3(key.rot != null ? key.rot : key.rot_deg,
    [0, 0, 0]));
}
function keyScale3(key) {
  if (key.scale3 != null) return v3(key.scale3, [1, 1, 1]);
  if (Array.isArray(key.scale)) return v3(key.scale, [1, 1, 1]);
  var s = key.scale == null ? 1 : +key.scale;
  return [s, s, s];
}
function poseQ(key) {
  return { pos: v3(key.pos, [0, 0, 0]), quat: keyQuat(key),
    scale3: keyScale3(key) };
}

// Evaluate a track at time t -> { pos: [3], quat: [4], scale3: [3] }.
// Mirrors key_eval_q: empty keys -> identity; D <= 0 -> first key
// pose; loop map and end clamps as in evalTrack; between keys the
// pose is pos-lerped, quat-slerped and scale3-lerped by
// e = ease(keys[i+1].ease, p).
function evalTrackQ(track, t) {
  var keys = (track && track.keys) || [];
  if (!keys.length) {
    return { pos: [0, 0, 0], quat: [0, 0, 0, 1], scale3: [1, 1, 1] };
  }
  var first = keys[0], last = keys[keys.length - 1];
  var tt = track.fps > 0 ? (+t || 0) * track.fps : +t || 0;
  var D = track.duration > 0 ? +track.duration : +last.time;
  if (!(D > 0)) return poseQ(first);
  var te;
  if (track.loop === 'forever') {
    te = Math.max(tt, 0) % D;
  } else if (track.loop === 'pingpong') {
    var cyc = Math.max(tt, 0) % (2 * D);
    te = cyc <= D ? cyc : 2 * D - cyc;
  } else { // 'once' and anything unknown
    te = clamp(tt, 0, D);
  }
  if (te <= first.time) return poseQ(first);
  if (te >= last.time) return poseQ(last);
  var i, a, b, p, e, pa, pb, out;
  for (i = 0; i < keys.length - 1; i++) {
    a = keys[i]; b = keys[i + 1];
    if (!(a.time <= te && te <= b.time)) continue;
    p = b.time > a.time ? (te - a.time) / (b.time - a.time) : 0;
    e = ease(b.ease, p);
    pa = poseQ(a); pb = poseQ(b);
    out = { pos: [], quat: quatSlerp(pa.quat, pb.quat, e), scale3: [] };
    for (var j = 0; j < 3; j++) {
      out.pos[j] = pa.pos[j] + (pb.pos[j] - pa.pos[j]) * e;
      out.scale3[j] = pa.scale3[j] + (pb.scale3[j] - pa.scale3[j]) * e;
    }
    return out;
  }
  return poseQ(last);
}

export { ease, evalTrack, evalTrackQ };

// Compatibility footer: preserve the classic-script globals --
// the exported names are attached onto globalThis.F3D (as
// globalThis.F3D.keys) as well as the legacy globalThis.F3DKeys.
const F3DKeys = { ease: ease, evalTrack: evalTrack, evalTrackQ: evalTrackQ };
globalThis.F3DKeys = F3DKeys;
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.keys = F3DKeys;
if (typeof window !== 'undefined') window.F3DKeys = F3DKeys;
