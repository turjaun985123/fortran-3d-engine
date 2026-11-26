'use strict';
/* Port of test_f3d_keys_js.py (Forge3D Wave B seat B95) to plain
 * Node.js: tests for the keyframe sidecar runtime/f3d-keys.js
 * (JS mirror of src/keyframe.f90 key_eval).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_keys_js.js
 *
 * The existence check always runs. The numeric checks load the
 * sidecar in-process (the Python original shelled out to
 * `node -e` snippets).
 *
 * Every expected pose is RECOMPUTED IN JS below (refEval is an
 * independent JS implementation of the frozen key_eval
 * semantics, translated from the Python original) and compared
 * against the sidecar result with tolerance 1e-12; the headline
 * numbers (midpoint (2, 1, 0), smooth factor 0.15625, rot mid
 * 45, scale mid 1.5) are also asserted directly so the
 * reference itself is pinned.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-keys.js');
const TOL = 1e-12;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window` and bind the export as `K`,
// plus the near / checkPose helpers.
let K = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  K = globalThis.F3DKeys;
} catch (e) { loadError = e; }
function needK() {
  if (loadError) throw loadError;
  return K;
}
const near = (a, b) => Math.abs(a - b) <= 1e-12;
const checkPose = (got, exp) => {
  for (let j = 0; j < 3; j++) {
    assert.ok(near(got.pos[j], exp.pos[j]),
      'pos[' + j + '] got ' + got.pos[j] + ' want ' + exp.pos[j]);
    assert.ok(near(got.rot[j], exp.rot[j]),
      'rot[' + j + '] got ' + got.rot[j] + ' want ' + exp.rot[j]); }
  assert.ok(near(got.scale, exp.scale),
    'scale got ' + got.scale + ' want ' + exp.scale); };

function checkTrack(track, t, expected) {
  // Assert JS evalTrack(track, t) == expected (JS-computed).
  needK();
  checkPose(K.evalTrack(track, t), expected);
}

// ------------------------------------------------------------------
// Independent JS recomputation of the frozen key_eval semantics.
// ------------------------------------------------------------------

function refEase(name, p) {
  const u = Math.max(0.0, Math.min(1.0, p));
  if (name === 'smooth') return u * u * (3.0 - 2.0 * u);
  if (name === 'in') return u * u;
  if (name === 'out') return 1.0 - (1.0 - u) ** 2;
  return u;  // 'linear' and anything unknown
}

function poseOf(key) {
  return {
    pos: key.pos.map(c => Number(c)),
    rot: key.rot.map(c => Number(c)),
    scale: Number(key.scale),
  };
}

function refEval(track, t) {
  const keys = track.keys || [];
  if (!keys.length) {
    return {pos: [0.0, 0.0, 0.0], rot: [0.0, 0.0, 0.0], scale: 1.0};
  }
  const first = keys[0], last = keys[keys.length - 1];
  const duration = track.duration || 0;
  const d = duration > 0 ? duration : last.time;
  if (d <= 0) return poseOf(first);
  const loop = track.loop;
  let te;
  if (loop === 'forever') {
    te = Math.max(t, 0.0) % d;
  } else if (loop === 'pingpong') {
    const cyc = Math.max(t, 0.0) % (2.0 * d);
    te = cyc <= d ? cyc : 2.0 * d - cyc;
  } else {  // 'once' and anything unknown
    te = Math.max(0.0, Math.min(t, d));
  }
  if (te <= first.time) return poseOf(first);
  if (te >= last.time) return poseOf(last);
  for (let i = 0; i < keys.length - 1; i++) {
    const a = keys[i], b = keys[i + 1];
    if (te > b.time && i < keys.length - 2) continue;
    const span = b.time - a.time;
    const p = span === 0 ? 0.0 : (te - a.time) / span;
    const e = refEase(b.ease, p);
    const pa = poseOf(a), pb = poseOf(b);
    return {
      pos: [0, 1, 2].map(j => pa.pos[j] + (pb.pos[j] - pa.pos[j]) * e),
      rot: [0, 1, 2].map(j => pa.rot[j] + (pb.rot[j] - pa.rot[j]) * e),
      scale: pa.scale + (pb.scale - pa.scale) * e,
    };
  }
  return poseOf(last);
}

function twoKeyTrack({loop = 'once', easeName = 'linear', duration = 2,
                      t0 = 0, t1 = 2} = {}) {
  // The Fortran seat's base track: (0,0,0)/rot 0/scale 1 at t0 to
  // (4,2,0)/rot (0,90,0)/scale 2 at t1.
  return {
    target: 'cube', duration: duration, loop: loop,
    keys: [
      {time: t0, pos: [0, 0, 0], rot: [0, 0, 0],
       scale: 1, ease: 'linear'},
      {time: t1, pos: [4, 2, 0], rot: [0, 90, 0],
       scale: 2, ease: easeName},
    ],
  };
}

test('test_file_exists', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
});

test('test_exports', () => {
  needK();
  for (const k of ['ease', 'evalTrack'])
    assert.strictEqual(typeof K[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.F3DKeys, K);
});

test('test_ease_values', () => {
  needK();
  // Factors recomputed in JS; smooth at p=0.25 is the
  // pinned headline value 0.15625.
  assert.ok(Math.abs(refEase('smooth', 0.25) - 0.15625) <= TOL);
  for (const name of ['linear', 'smooth', 'in', 'out', 'bogus', null]) {
    for (const p of [-0.5, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5]) {
      assert.ok(near(K.ease(name, p), refEase(name, p)),
        'ease ' + name + ' @ ' + p);
    }
  }
});

test('test_two_key_linear_midpoint', () => {
  const track = twoKeyTrack();
  const expected = refEval(track, 1);
  // Pinned headline: midpoint pos is exactly (2, 1, 0).
  assert.deepStrictEqual(expected.pos, [2.0, 1.0, 0.0]);
  checkTrack(track, 1, expected);
});

test('test_smooth_segment_uses_destination_key_ease', () => {
  const track = twoKeyTrack({easeName: 'smooth'});
  const expected = refEval(track, 0.5);  // p = 0.25, factor 0.15625
  assert.ok(Math.abs(expected.pos[0] - 4 * 0.15625) <= TOL);
  assert.ok(Math.abs(expected.pos[1] - 2 * 0.15625) <= TOL);
  checkTrack(track, 0.5, expected);
});

test('test_rot_midpoint_is_45', () => {
  const track = twoKeyTrack();
  const expected = refEval(track, 1);
  assert.deepStrictEqual(expected.rot, [0.0, 45.0, 0.0]);
  checkTrack(track, 1, expected);
});

test('test_scale_midpoint_is_1_5', () => {
  const track = twoKeyTrack();
  const expected = refEval(track, 1);
  assert.strictEqual(expected.scale, 1.5);
  checkTrack(track, 1, expected);
});

test('test_once_clamps_past_end', () => {
  const track = twoKeyTrack({loop: 'once'});
  const expected = refEval(track, 5);
  assert.deepStrictEqual(expected, poseOf(track.keys[track.keys.length - 1]));
  checkTrack(track, 5, expected);
  // 'once' also clamps negative t to the first pose.
  checkTrack(track, -3, refEval(track, -3));
});

test('test_forever_wraps_to_midpoint', () => {
  const track = twoKeyTrack({loop: 'forever'});  // D = 2
  const expected = refEval(track, 3);  // te = mod(3, 2) = 1: midpoint
  assert.deepStrictEqual(expected.pos, [2.0, 1.0, 0.0]);
  checkTrack(track, 3, expected);
});

test('test_pingpong_midpoint_on_the_way_back', () => {
  const track = twoKeyTrack({loop: 'pingpong'});  // D = 2
  const expected = refEval(track, 3);  // cyc 3 > D -> te = 4-3 = 1
  assert.deepStrictEqual(expected.pos, [2.0, 1.0, 0.0]);
  checkTrack(track, 3, expected);
});

test('test_pingpong_at_duration_is_the_end_pose', () => {
  const track = twoKeyTrack({loop: 'pingpong'});
  const expected = refEval(track, 2);  // cyc 2 <= D -> te = 2: end
  assert.deepStrictEqual(expected, poseOf(track.keys[track.keys.length - 1]));
  checkTrack(track, 2, expected);
});

test('test_empty_track_is_identity', () => {
  const track = {target: 'cube', duration: 2, loop: 'once', keys: []};
  const expected = refEval(track, 1);
  assert.deepStrictEqual(expected, {pos: [0.0, 0.0, 0.0],
                                    rot: [0.0, 0.0, 0.0],
                                    scale: 1.0});
  checkTrack(track, 1, expected);
});

test('test_before_first_key_gives_first_pose', () => {
  const track = twoKeyTrack({t0: 1, t1: 3});
  // First key sits at time 1 with the base pose shifted so the
  // first pose is distinguishable from the identity pose.
  Object.assign(track.keys[0],
                {pos: [1, 2, 3], rot: [10, 20, 30], scale: 0.5});
  const expected = refEval(track, 0);
  assert.deepStrictEqual(expected, poseOf(track.keys[0]));
  checkTrack(track, 0, expected);
  checkTrack(track, 0.5, refEval(track, 0.5));
});

test('test_duration_fallback_and_nonpositive_duration', () => {
  // duration <= 0 in the track -> D falls back to the last
  // key time (2 here), so t=1 is still the midpoint.
  const track = twoKeyTrack({duration: 0});
  const expected = refEval(track, 1);
  assert.deepStrictEqual(expected.pos, [2.0, 1.0, 0.0]);
  checkTrack(track, 1, expected);
  // Last key time <= 0 too -> D <= 0 -> first key pose.
  const flat = twoKeyTrack({duration: 0, t0: 0, t1: 0});
  checkTrack(flat, 1, refEval(flat, 1));
});

// ------------------------------------------------------------------
// Wave 3 extensions: the Phase 5 ease names (cubic-*, bezier,
// hold) and evalTrackQ (key_eval_q mirror: quat slerp, per-axis
// scale, per-track fps). Added additively; the tests above are
// unchanged.
// ------------------------------------------------------------------

test('test_exports_eval_track_q', () => {
  needK();
  assert.strictEqual(typeof K.evalTrackQ, 'function');
});

test('test_ease_cubic_and_hold_values', () => {
  needK();
  assert.ok(near(K.ease('cubic-in', 0.5), 0.125));
  assert.ok(near(K.ease('cubic-out', 0.5), 0.875));
  assert.ok(near(K.ease('cubic-in-out', 0.25), 0.0625));
  assert.ok(near(K.ease('cubic-in-out', 0.75), 0.9375));
  assert.strictEqual(K.ease('hold', 0.5), 0);
  assert.strictEqual(K.ease('hold', 1), 0);
});

test('test_ease_bezier_identity_and_malformed', () => {
  needK();
  for (const p of [0.13, 0.37, 0.5, 0.91])
    assert.ok(Math.abs(K.ease('bezier(0,0,1,1)', p) - p) <= 1e-6,
      'bezier identity @ ' + p);
  assert.ok(Math.abs(K.ease('bezier(0.25,0.1,0.25,1)', 0.5) -
                     0.8024) <= 1e-3);
  assert.ok(near(K.ease('bezier(1,2)', 0.3), 0.3)); // malformed
});

test('test_eval_track_q_slerp_midpoint', () => {
  needK();
  const track = { target: 'cube', duration: 2, loop: 'once',
    keys: [{ time: 0, pos: [0, 0, 0], rot: [0, 0, 0], scale: 1,
             ease: 'linear' },
           { time: 2, pos: [4, 2, 0], rot: [0, 90, 0],
             scale3: [2, 3, 4], ease: 'linear' }] };
  const mid = K.evalTrackQ(track, 1);
  assert.ok(near(mid.pos[0], 2) && near(mid.pos[1], 1));
  assert.ok(near(mid.quat[1], Math.sin(Math.PI / 8)));
  assert.ok(near(mid.quat[3], Math.cos(Math.PI / 8)));
  assert.ok(near(mid.scale3[0], 1.5) && near(mid.scale3[1], 2) &&
            near(mid.scale3[2], 2.5));
});

test('test_eval_track_q_slerp_shortest_path_wrap', () => {
  needK();
  // 350 -> 10 degrees about Y must pass through 0, not 180.
  const track = { target: 'cube', duration: 2, loop: 'once',
    keys: [{ time: 0, pos: [0, 0, 0], rot: [0, 350, 0], scale: 1,
             ease: 'linear' },
           { time: 2, pos: [0, 0, 0], rot: [0, 10, 0], scale: 1,
             ease: 'linear' }] };
  const mid = K.evalTrackQ(track, 1);
  assert.ok(Math.abs(mid.quat[1]) <= 1e-9, 'quat y ' + mid.quat[1]);
  assert.ok(near(Math.abs(mid.quat[3]), 1));
});

test('test_eval_track_q_fps_frames', () => {
  needK();
  // fps 24: key times are frames; t = 1 s -> frame 24 = midpoint.
  const track = { target: 'cube', duration: 48, loop: 'once',
    fps: 24,
    keys: [{ time: 0, pos: [0, 0, 0], rot: [0, 0, 0], scale: 1,
             ease: 'linear' },
           { time: 48, pos: [4, 2, 0], rot: [0, 0, 0], scale: 2,
             ease: 'linear' }] };
  const mid = K.evalTrackQ(track, 1);
  assert.ok(near(mid.pos[0], 2) && near(mid.pos[1], 1));
  assert.ok(near(mid.scale3[0], 1.5));
});

test('test_eval_track_q_empty_is_identity', () => {
  needK();
  const out = K.evalTrackQ({ target: 'x', keys: [] }, 1);
  assert.deepStrictEqual(out, { pos: [0, 0, 0], quat: [0, 0, 0, 1],
    scale3: [1, 1, 1] });
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
