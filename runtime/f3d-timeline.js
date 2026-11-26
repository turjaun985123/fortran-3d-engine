// Forge3D module "f3d-timeline" -- Timeline IR evaluator sidecar.
// Role: OPTIONAL module, load AFTER runtime/f3d.js. Mirrors
// src/timeline_eval.f90 + src/char_figure.f90 (Wave 3): pure
// evaluation of a parsed Timeline IR object (docs/TIMELINE-FORMAT.md,
// format "forge3d-timeline") at an integer frame -- channel poses
// with trapezoid blending across action tracks, pose_keys / camera
// key evaluation, stick-figure forward kinematics in the character
// plane, and dialogue interval lookup. Every function is a pure
// function of its arguments: no accumulated state, no frame
// stepping (ANIM-PLAN section 4.2 house principle).
// ES module: the public names are declared with named exports
// below. A classic (non-module) bundle is produced from this
// module by tools/build_runtime.mjs; the compatibility footer at
// the bottom preserves the legacy globals for classic consumers.
// Imports: none. Runtime modules are dependency-free sidecars, so
// the small helpers this module shares with runtime/f3d-keys.js
// (clamp / ease / quaternion slerp / the key_eval_q skeleton) are
// DUPLICATED here with mirror comments, exactly as f3d-keys.js
// duplicates the core helpers of f3d.js. Keep the copies in sync:
// both mirror the same Fortran sources (src/animation.f90
// ease_value, src/math_3d.f90 quat_slerp / quat_from_euler,
// src/keyframe.f90 key_eval_q).
//
// Timeline IR shapes consumed (all times are integer FRAMES):
//   timeline = { format, ir_version, fps: {num, den},
//     duration_frames, characters: [{id, name, color, face?,
//       proportions?, at?|pos?}],
//     tracks: [ actionTrack | poseKeysTrack | cameraTrack ],
//     dialogue: [{id, scene, start_frame, end_frame, speaker,
//       text}] }
//   actionTrack   = { kind: 'action', character, action,
//     start_frame, end_frame,
//     keys: [{frame, channel, value|value_deg, ease}] }
//   poseKeysTrack = { kind: 'pose_keys', character|target,
//     keys: [{frame, pos, rot_deg|rot, scale, ease}] }
//   cameraTrack   = { kind: 'camera',
//     keys: [{frame, pos, target, fov, ease}] }
// Easing belongs to the key a segment ENDS at; the first key's
// ease is ignored; unknown ease names evaluate as linear.
function clamp(x, a, b) { return x < a ? a : (x > b ? b : x); }
function v3(v, d) { return v == null ? d.slice()
  : [ +v[0] || 0, +v[1] || 0, +v[2] || 0 ]; }

// --- ease: mirror of ease() in runtime/f3d-keys.js (which mirrors
// ease_value in src/animation.f90). See that file for the full
// formula table, the bezier solver and its parsing rules.
function bezierCoord(c1, c2, t) {
  var mt = 1 - t;
  return 3 * mt * mt * t * c1 + 3 * mt * t * t * c2 + t * t * t;
}
function bezierCoordDt(c1, c2, t) {
  var mt = 1 - t;
  return 3 * mt * mt * c1 + 6 * mt * t * (c2 - c1) +
    3 * t * t * (1 - c2);
}
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
    case 'hold': return 0; // step: segment holds its START value
    default: return u; // 'linear' and anything unknown
  }
}

// --- quaternions: mirror of the helpers in runtime/f3d-keys.js
// (src/math_3d.f90 quat_from_euler / quat_slerp). [x, y, z, w].
function quatNormalize(q) {
  var l = Math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] +
    q[3] * q[3]);
  if (l > 1e-12) return [q[0] / l, q[1] / l, q[2] / l, q[3] / l];
  return [0, 0, 0, 1];
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
  var s = Math.sin(deg * Math.PI / 360);
  return [ax / l * s, ay / l * s, az / l * s,
    Math.cos(deg * Math.PI / 360)];
}
function quatFromEuler(rot) { // q = qy (x) qx (x) qz
  var qx = quatFromAxisAngle(1, 0, 0, rot[0]);
  var qy = quatFromAxisAngle(0, 1, 0, rot[1]);
  var qz = quatFromAxisAngle(0, 0, 1, rot[2]);
  return quatMultiply(qy, quatMultiply(qx, qz));
}
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

// --- key_eval_q over frame-space keys: mirror of evalTrackQ in
// runtime/f3d-keys.js (src/keyframe.f90 key_eval_q), specialised
// to loop 'once' in frame coordinates (tt = frame, fps = 0).
// Keys carry `frame` instead of `time`.
function keyQuat(key) {
  if (key.quat != null) {
    return [+key.quat[0] || 0, +key.quat[1] || 0, +key.quat[2] || 0,
      +key.quat[3] || 0];
  }
  return quatFromEuler(v3(key.rot_deg != null ? key.rot_deg
    : key.rot, [0, 0, 0]));
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

// evalPoseKeys(track, frame) -> { pos, quat, scale3 } for a
// pose_keys track (or any track whose keys are frame-keyed TRS
// keys). Empty keys -> identity pose; outside the keyed range the
// end poses are returned (loop 'once' clamp semantics).
function evalPoseKeys(track, frame) {
  var keys = (track && track.keys) || [];
  if (!keys.length) {
    return { pos: [0, 0, 0], quat: [0, 0, 0, 1], scale3: [1, 1, 1] };
  }
  var first = keys[0], last = keys[keys.length - 1];
  var te = +frame || 0;
  if (te <= first.frame) return poseQ(first);
  if (te >= last.frame) return poseQ(last);
  var i, a, b, p, e, pa, pb, out;
  for (i = 0; i < keys.length - 1; i++) {
    a = keys[i]; b = keys[i + 1];
    if (!(a.frame <= te && te <= b.frame)) continue;
    p = b.frame > a.frame ? (te - a.frame) / (b.frame - a.frame) : 0;
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

// Scalar channel keys [{frame, value, ease}] at a frame: clamp
// outside the key range to the end values; inside, the segment
// progress is eased by the END key's ease ('hold' = start value,
// because ease('hold', p) = 0). Non-numeric values (e.g. a
// face.expr string) cannot lerp: the value steps at each key --
// the last key at or before the frame wins, else the first key's.
function evalScalarKeys(keys, frame) {
  var first = keys[0], last = keys[keys.length - 1];
  var te = +frame || 0;
  if (te <= first.frame) return first.value;
  if (te >= last.frame) return last.value;
  var i, a, b;
  for (i = 0; i < keys.length - 1; i++) {
    a = keys[i]; b = keys[i + 1];
    if (!(a.frame <= te && te < b.frame)) continue;
    if (typeof a.value !== 'number' || typeof b.value !== 'number') {
      return a.value;
    }
    var p = b.frame > a.frame ? (te - a.frame) / (b.frame - a.frame) : 0;
    return a.value + (b.value - a.value) * ease(b.ease, p);
  }
  return last.value;
}

// evalCamera(track, frame) -> { pos, target, fov }: pos / target
// lerp componentwise and fov lerps as a scalar, all eased by the
// segment's END key. Missing components default to pos / target
// [0,0,0] and fov 60. Empty keys -> that default camera.
function evalCamera(track, frame) {
  var keys = (track && track.keys) || [];
  if (!keys.length) return { pos: [0, 0, 0], target: [0, 0, 0], fov: 60 };
  function comp(get) {
    return evalScalarKeys(keys.map(function (k) {
      return { frame: k.frame, value: get(k), ease: k.ease };
    }), frame);
  }
  var pos = [], target = [], j;
  for (j = 0; j < 3; j++) {
    (function (jj) {
      pos[jj] = comp(function (k) { return v3(k.pos, [0, 0, 0])[jj]; });
      target[jj] = comp(function (k) {
        return v3(k.target, [0, 0, 0])[jj]; });
    })(j);
  }
  var fov = comp(function (k) { return k.fov == null ? 60 : +k.fov; });
  return { pos: pos, target: target, fov: fov };
}

// The rig channels of the stick figure (versioned vocabulary,
// ANIM-PLAN section 3.5 / 4.2). All are angles in degrees except
// root.x/y/z (world units) and face.expr (an expression name).
var CHANNELS = ['root.x', 'root.y', 'root.z', 'root.face', 'torso',
  'head.pitch', 'head.yaw', 'arm.l.upper', 'arm.l.fore',
  'arm.r.upper', 'arm.r.fore', 'leg.l.thigh', 'leg.l.shin',
  'leg.r.thigh', 'leg.r.shin', 'face.expr'];

// Trapezoid weight of one action instance over [start, end):
// ramp = min(6, span/4) frames, linear in and out, w in [0,1].
function trapWeight(start, end, frame) {
  var span = end - start;
  if (!(span > 0)) return 1;
  var ramp = Math.min(6, span / 4);
  if (!(ramp > 0)) return 1;
  return clamp(Math.min((frame - start) / ramp, (end - frame) / ramp,
    1), 0, 1);
}

function findCharacter(timeline, characterId) {
  var chars = (timeline && timeline.characters) || [];
  for (var i = 0; i < chars.length; i++) {
    if (chars[i].id === characterId) return chars[i];
  }
  return null;
}

// evalChannels(timeline, characterId, frame, restPose) -> the
// character's pose at `frame` as {channel: value} over CHANNELS.
// Rest pose: angles 0; face.expr = the character's declared face
// ('neutral' when undeclared); root = the character's pose_keys
// root at this frame, else its declared at/pos. `restPose`, when
// given, overrides individual rest channels. Each action track of
// the character covering the frame (start_frame <= frame <
// end_frame) contributes its channel value with trapezoid weight
// w_i; the blend is (sum w_i*v_i + w_rest*rest) /
// max(1, sum w_i + w_rest) with w_rest = max(0, 1 - sum w_i).
// face.expr is not numeric: the covering instance with the
// largest weight wins, else the rest expression.
function evalChannels(timeline, characterId, frame, restPose) {
  var tracks = (timeline && timeline.tracks) || [];
  var ch = findCharacter(timeline, characterId);
  var rest = {};
  var i, c;
  for (i = 0; i < CHANNELS.length; i++) rest[CHANNELS[i]] = 0;
  rest['face.expr'] = (ch && (ch.face_expr || ch.face)) || 'neutral';
  var decl = ch && (ch.at != null ? ch.at : ch.pos);
  if (decl != null) {
    var dv = v3(decl, [0, 0, 0]);
    rest['root.x'] = dv[0]; rest['root.y'] = dv[1]; rest['root.z'] = dv[2];
  }
  for (i = 0; i < tracks.length; i++) {
    var tr = tracks[i];
    if (tr.kind !== 'pose_keys') continue;
    if ((tr.character || tr.target) !== characterId) continue;
    var pq = evalPoseKeys(tr, frame);
    rest['root.x'] = pq.pos[0]; rest['root.y'] = pq.pos[1];
    rest['root.z'] = pq.pos[2];
  }
  if (restPose) {
    for (c in restPose) rest[c] = restPose[c];
  }
  var pose = {};
  for (i = 0; i < CHANNELS.length; i++) {
    c = CHANNELS[i];
    var sumW = 0, sumWV = 0, bestW = -1, bestV = null;
    for (var k = 0; k < tracks.length; k++) {
      var at = tracks[k];
      if (at.kind !== 'action') continue;
      if (at.character !== characterId) continue;
      var start = at.start_frame, end = at.end_frame;
      var chanKeys = [];
      var m;
      for (m = 0; m < (at.keys || []).length; m++) {
        var key = at.keys[m];
        if (key.channel !== c) continue;
        chanKeys.push({ frame: key.frame,
          value: key.value != null ? key.value : key.value_deg,
          ease: key.ease });
        if (start == null || key.frame < start) start = key.frame;
        if (end == null || key.frame > end) end = key.frame;
      }
      if (!chanKeys.length || start == null || end == null) continue;
      if (!(start <= frame && frame < end)) continue;
      var w = trapWeight(start, end, frame);
      var v = evalScalarKeys(chanKeys, frame);
      if (typeof v === 'number') { sumW += w; sumWV += w * v; }
      if (w > bestW) { bestW = w; bestV = v; }
    }
    if (c === 'face.expr') {
      pose[c] = bestV != null ? bestV : rest[c];
    } else if (bestV == null) {
      pose[c] = rest[c];
    } else {
      var wRest = Math.max(0, 1 - sumW);
      pose[c] = (sumWV + wRest * rest[c]) /
        Math.max(1, sumW + wRest);
    }
  }
  return pose;
}

// Proportions (src/char_figure.f90): the adult table, in world
// units; H0 = 1.83 is the adult total height (feet to head top).
var H0 = 1.83;
var ADULT = { thigh: 0.45, shin: 0.45, torso: 0.55, upper_arm: 0.30,
  fore_arm: 0.28, head_r: 0.16, line_r: 0.035, shoulder_half: 0.19,
  hip_half: 0.11, neck: 0.06 };
var LENGTH_KEYS = ['thigh', 'shin', 'torso', 'upper_arm', 'fore_arm',
  'line_r', 'shoulder_half', 'hip_half', 'neck'];

// proportionsFor(word): 'tall' scales lengths x1.12 and head_r
// x1.05; 'short' scales everything x0.88; 'kid' scales lengths
// x0.62 and head_r x0.806; anything else (incl. null) is adult.
function proportionsFor(word) {
  var p = {}, i, k;
  for (k in ADULT) p[k] = ADULT[k];
  if (word === 'tall') {
    for (i = 0; i < LENGTH_KEYS.length; i++) p[LENGTH_KEYS[i]] *= 1.12;
    p.head_r *= 1.05;
  } else if (word === 'short') {
    for (k in p) p[k] *= 0.88;
  } else if (word === 'kid') {
    for (i = 0; i < LENGTH_KEYS.length; i++) p[LENGTH_KEYS[i]] *= 0.62;
    p.head_r *= 0.806;
  }
  return p;
}

// figureJoints(pose, proportionsWord, height) -> {joint: [u, v]}
// plane positions (u right, v up) by forward kinematics, mirroring
// src/char_figure.f90. When `height` is given the figure is scaled
// uniformly so its total height is exactly `height` (for the adult
// proportions that is the scale height / H0). The world transform
// (root placement, billboard yaw) is a Wave 4 concern; root.x /
// root.y here only offset the plane position.
//   hipC = (0, thigh + shin); hips = hipC +/- hip_half along the
//   torso-perpendicular (cos tilt, sin tilt); neck = hipC +
//   torso * dir(tilt); shoulders = neck +/- shoulder_half along
//   the same perpendicular; head centre = neck + (neck + head_r)
//   * dir(tilt), dir(a) = (sin a, cos a). Limb direction
//   d(a) = (sin a, -cos a); elbow / knee chain from shoulder / hip
//   with cumulative angles (upper + fore, thigh + shin). Angles
//   are the pose channels in DEGREES; missing channels are 0.
//   '.l' joints sit at -u, '.r' joints at +u in the plane.
function figureJoints(pose, proportionsWord, height) {
  var p = proportionsFor(proportionsWord);
  var total = p.thigh + p.shin + p.torso + p.neck + 2 * p.head_r;
  var s = height != null && total > 0 ? height / total : 1;
  function P(k) { return p[k] * s; }
  function ang(name) { return (pose && +pose[name]) || 0; }
  var D2R = Math.PI / 180;
  var tilt = ang('torso') * D2R;
  var tdir = [Math.sin(tilt), Math.cos(tilt)];
  var tperp = [Math.cos(tilt), Math.sin(tilt)];
  var ox = ang('root.x'), oy = ang('root.y');
  function pt(u, v) { return [u + ox, v + oy]; }
  function dir(aDeg) {
    var a = aDeg * D2R;
    return [Math.sin(a), -Math.cos(a)];
  }
  function chain(from, len, aDeg) {
    var d = dir(aDeg);
    return [from[0] + len * d[0], from[1] + len * d[1]];
  }
  var hipC = pt(0, P('thigh') + P('shin'));
  function side(base, half, sign, key) {
    return pt(base[0] - ox + sign * half * tperp[0],
      base[1] - oy + sign * half * tperp[1]);
  }
  var hipL = side(hipC, P('hip_half'), -1);
  var hipR = side(hipC, P('hip_half'), 1);
  var neck = pt(hipC[0] - ox + P('torso') * tdir[0],
    hipC[1] - oy + P('torso') * tdir[1]);
  var shoL = side(neck, P('shoulder_half'), -1);
  var shoR = side(neck, P('shoulder_half'), 1);
  var head = pt(neck[0] - ox + (P('neck') + P('head_r')) * tdir[0],
    neck[1] - oy + (P('neck') + P('head_r')) * tdir[1]);
  var elbL = chain(shoL, P('upper_arm'), ang('arm.l.upper'));
  var elbR = chain(shoR, P('upper_arm'), ang('arm.r.upper'));
  var kneeL = chain(hipL, P('thigh'), ang('leg.l.thigh'));
  var kneeR = chain(hipR, P('thigh'), ang('leg.r.thigh'));
  return {
    root: pt(0, 0),
    hip: hipC,
    'hip.l': hipL, 'hip.r': hipR,
    neck: neck,
    'shoulder.l': shoL, 'shoulder.r': shoR,
    head: head,
    'head.top': pt(head[0] - ox + P('head_r') * tdir[0],
      head[1] - oy + P('head_r') * tdir[1]),
    'elbow.l': elbL,
    'hand.l': chain(elbL, P('fore_arm'),
      ang('arm.l.upper') + ang('arm.l.fore')),
    'elbow.r': elbR,
    'hand.r': chain(elbR, P('fore_arm'),
      ang('arm.r.upper') + ang('arm.r.fore')),
    'knee.l': kneeL,
    'foot.l': chain(kneeL, P('shin'),
      ang('leg.l.thigh') + ang('leg.l.shin')),
    'knee.r': kneeR,
    'foot.r': chain(kneeR, P('shin'),
      ang('leg.r.thigh') + ang('leg.r.shin'))
  };
}

// activeDialogue(timeline, frame) -> the dialogue cues live at
// `frame`: start_frame <= frame < end_frame (half-open, matching
// SubtitleCue::is_live_at on the host side).
function activeDialogue(timeline, frame) {
  var cues = (timeline && timeline.dialogue) || [];
  var out = [];
  for (var i = 0; i < cues.length; i++) {
    if (cues[i].start_frame <= frame && frame < cues[i].end_frame) {
      out.push(cues[i]);
    }
  }
  return out;
}

export { ease, evalChannels, evalPoseKeys, evalCamera, figureJoints,
  activeDialogue, proportionsFor, CHANNELS };

// Compatibility footer: preserve the classic-script globals --
// the exported names are attached onto globalThis.F3D (as
// globalThis.F3D.timeline) as well as the legacy
// globalThis.F3DTimeline.
const F3DTimeline = { ease: ease, evalChannels: evalChannels,
  evalPoseKeys: evalPoseKeys, evalCamera: evalCamera,
  figureJoints: figureJoints, activeDialogue: activeDialogue,
  proportionsFor: proportionsFor, CHANNELS: CHANNELS };
globalThis.F3DTimeline = F3DTimeline;
globalThis.F3D = globalThis.F3D || {};
globalThis.F3D.timeline = F3DTimeline;
if (typeof window !== 'undefined') window.F3DTimeline = F3DTimeline;
