// Forge3D keyframe sidecar - OPTIONAL module, load AFTER
// runtime/f3d.js. Mirrors the Fortran module src/keyframe.f90
// (key_eval): keyframed pos / rot / scale tracks with named easing
// and once / forever / pingpong looping. Plain script, zero deps,
// no modules.
//
// Track shape:
//   { target, duration, loop,
//     keys: [{ time, pos: [x, y, z], rot: [x, y, z], scale, ease }] }
// The ease named on a key drives the segment ENDING at that key.
// evalTrack(track, t) -> { pos: [3], rot: [3], scale }.
'use strict';
(function (g) {
function clamp(x, a, b) { return x < a ? a : (x > b ? b : x); }
function v3(v, d) { return v == null ? d.slice()
  : [ +v[0] || 0, +v[1] || 0, +v[2] || 0 ]; }
function pose(key) { return { pos: v3(key.pos, [0, 0, 0]),
  rot: v3(key.rot, [0, 0, 0]),
  scale: key.scale == null ? 1 : +key.scale }; }

// Easing on normalised progress p (clamped to [0,1] here), exactly
// as ease_value in src/animation.f90:
//   'linear' -> p                 'smooth' -> p*p*(3-2p)
//   'in'     -> p*p               'out'    -> 1-(1-p)^2
// Unknown names fall back to linear.
function ease(name, p) {
  var u = clamp(+p || 0, 0, 1);
  switch (name) {
    case 'smooth': return u * u * (3 - 2 * u);
    case 'in': return u * u;
    case 'out': return 1 - (1 - u) * (1 - u);
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

g.F3DKeys = { ease: ease, evalTrack: evalTrack };
if (typeof window !== 'undefined') window.F3DKeys = g.F3DKeys;
})(typeof globalThis !== 'undefined' ? globalThis : this);
