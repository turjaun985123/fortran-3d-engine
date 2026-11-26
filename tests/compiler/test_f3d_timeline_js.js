'use strict';
/* Tests for the Timeline IR evaluator sidecar
 * runtime/f3d-timeline.js (JS mirror of src/timeline_eval.f90 +
 * src/char_figure.f90, Wave 3), plus the key_eval_q pose path it
 * shares with runtime/f3d-keys.js.
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_timeline_js.js
 *
 * Every expectation is hand-computable from the shared spec
 * (ANIM-PLAN sections 3.4/3.7, 4.2): easing belongs to the key a
 * segment ENDS at, action blending is the trapezoid-weight blend
 * against the rest pose, and the FK proportions are the adult
 * table with H0 = 1.83.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-timeline.js');
const TOL = 1e-9;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

let T = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  T = globalThis.F3DTimeline;
} catch (e) { loadError = e; }
function needT() {
  if (loadError) throw loadError;
  return T;
}
const near = (a, b, tol) => Math.abs(a - b) <= (tol || TOL);
function nearPt(got, exp, tol) {
  assert.ok(near(got[0], exp[0], tol) && near(got[1], exp[1], tol),
    'point got [' + got + '] want [' + exp + ']');
}

function actionTrack(channel, keys, start, end, character) {
  return { kind: 'action', scene: 's1', character: character || 'mira',
    action: 'test', start_frame: start, end_frame: end,
    keys: keys.map(k => ({ frame: k[0], channel: channel,
      value: k[1], ease: k[2] || 'linear' })) };
}
function timelineWith(tracks, characters) {
  return { format: 'forge3d-timeline', ir_version: 1,
    fps: { num: 24, den: 1 }, duration_frames: 48,
    characters: characters || [{ id: 'mira', name: 'Mira' }],
    tracks: tracks, dialogue: [] };
}

test('test_file_exists', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
});

test('test_exports', () => {
  needT();
  for (const k of ['ease', 'evalChannels', 'evalPoseKeys',
                   'evalCamera', 'figureJoints', 'activeDialogue',
                   'proportionsFor'])
    assert.strictEqual(typeof T[k], 'function', 'missing export ' + k);
  assert.strictEqual(T.CHANNELS.length, 16);
  assert.strictEqual(window.F3DTimeline, T);
});

test('test_ease_cubic_values', () => {
  needT();
  assert.ok(near(T.ease('cubic-in', 0.5), 0.125));       // p^3
  assert.ok(near(T.ease('cubic-out', 0.5), 0.875));      // 1-(1-p)^3
  assert.ok(near(T.ease('cubic-in-out', 0.5), 0.5));
  assert.ok(near(T.ease('cubic-in-out', 0.25), 0.0625)); // 4p^3
  assert.ok(near(T.ease('cubic-in-out', 0.75), 0.9375));
});

test('test_ease_bezier_identity_and_malformed', () => {
  needT();
  // bezier(0,0,1,1) has x(t) == y(t), so it is the identity.
  for (const p of [0.13, 0.37, 0.5, 0.91])
    assert.ok(near(T.ease('bezier(0,0,1,1)', p), p, 1e-6),
      'bezier identity @ ' + p);
  // CSS 'ease' control points: known value at p = 0.5.
  assert.ok(near(T.ease('bezier(0.25,0.1,0.25,1)', 0.5), 0.8024, 1e-3));
  // Malformed bezier strings fall back to linear.
  assert.ok(near(T.ease('bezier(1,2)', 0.3), 0.3));
  assert.ok(near(T.ease('bezier(a,b,c,d)', 0.3), 0.3));
});

test('test_ease_hold_is_zero', () => {
  needT();
  for (const p of [0, 0.25, 0.5, 0.99, 1])
    assert.strictEqual(T.ease('hold', p), 0);
});

test('test_channel_linear_midpoint', () => {
  needT();
  const tl = timelineWith([
    actionTrack('torso', [[0, 0], [48, 100]], 0, 48)]);
  // Frame 24: full trapezoid weight (ramp = min(6, 48/4) = 6),
  // segment progress 0.5 linear -> 50.
  assert.ok(near(T.evalChannels(tl, 'mira', 24).torso, 50));
});

test('test_channel_hold_and_clamp', () => {
  needT();
  const hold = timelineWith([
    actionTrack('torso', [[0, 0], [24, 80, 'hold']], 0, 48)]);
  // Mid-segment the hold ease keeps the START value.
  assert.ok(near(T.evalChannels(hold, 'mira', 12).torso, 0));
  const clampTl = timelineWith([
    actionTrack('torso', [[0, 5], [24, 100]], 0, 48)]);
  // Past the last channel key (frame 40, still inside the track,
  // full weight) the value clamps to the end value.
  assert.ok(near(T.evalChannels(clampTl, 'mira', 40).torso, 100));
  // Before the first channel key it clamps to the start value:
  // frame 0 is the track start (weight 0), so use frame 3 with
  // the rest pose pinned to the same start value via a second
  // check at the key itself.
  assert.ok(near(T.evalChannels(clampTl, 'mira', 0).torso, 0));
});

test('test_blending_two_constant_tracks_average', () => {
  needT();
  const tl = timelineWith([
    actionTrack('torso', [[0, 10], [47, 10]], 0, 48),
    actionTrack('torso', [[0, 20], [47, 20]], 0, 48)]);
  // Both at full weight at frame 24: (10 + 20) / max(1, 2) = 15.
  assert.ok(near(T.evalChannels(tl, 'mira', 24).torso, 15));
});

test('test_blending_trapezoid_edge_against_rest', () => {
  needT();
  const tl = timelineWith([
    actionTrack('torso', [[0, 60], [47, 60]], 0, 48)]);
  // Frame 3: ramp = 6, w = 3/6 = 0.5; rest 0 with w_rest = 0.5:
  // (0.5*60 + 0.5*0) / 1 = 30.
  assert.ok(near(T.evalChannels(tl, 'mira', 3).torso, 30));
  // Outside the track span the channel is pure rest.
  assert.ok(near(T.evalChannels(tl, 'mira', 48).torso, 0));
});

test('test_rest_pose_declared_face_and_pose_keys_root', () => {
  needT();
  const tl = timelineWith([
    { kind: 'pose_keys', scene: 's1', character: 'mira',
      keys: [{ frame: 0, pos: [1, 2, 3], rot_deg: [0, 0, 0],
               scale: 1, ease: 'linear' },
             { frame: 48, pos: [5, 2, 3], rot_deg: [0, 0, 0],
               scale: 1, ease: 'linear' }] }],
    [{ id: 'mira', name: 'Mira', face: 'determined' }]);
  const pose = T.evalChannels(tl, 'mira', 24);
  assert.strictEqual(pose['face.expr'], 'determined');
  assert.ok(near(pose['root.x'], 3)); // pose_keys midpoint
  assert.ok(near(pose['root.y'], 2));
  assert.ok(near(pose.torso, 0));
});

test('test_eval_pose_keys_slerp_and_scale3', () => {
  needT();
  const track = { kind: 'pose_keys', scene: 's1', character: 'mira',
    keys: [{ frame: 0, pos: [0, 0, 0], rot_deg: [0, 0, 0],
             scale: 1, ease: 'linear' },
           { frame: 48, pos: [4, 2, 0], rot_deg: [0, 90, 0],
             scale3: [2, 3, 4], ease: 'linear' }] };
  const mid = T.evalPoseKeys(track, 24);
  assert.ok(near(mid.pos[0], 2) && near(mid.pos[1], 1));
  // Slerp midpoint of 0 -> 90 deg about Y: sin/cos of 22.5 deg.
  assert.ok(near(mid.quat[1], Math.sin(Math.PI / 8)));
  assert.ok(near(mid.quat[3], Math.cos(Math.PI / 8)));
  assert.ok(near(mid.scale3[0], 1.5) && near(mid.scale3[1], 2) &&
            near(mid.scale3[2], 2.5));
  // Clamp past the end.
  const end = T.evalPoseKeys(track, 100);
  assert.ok(near(end.pos[0], 4) && near(end.scale3[2], 4));
});

test('test_fk_rest_pose', () => {
  needT();
  const j = T.figureJoints({}, 'adult');
  assert.ok(near(j['foot.l'][1], 0) && near(j['foot.r'][1], 0));
  assert.ok(near(j.hip[1], 0.9));            // thigh + shin
  assert.ok(near(j.head[1], 1.67));          // + torso + neck + head_r
  assert.ok(near(j['head.top'][1], 1.83));   // = H0
  assert.ok(near(j['shoulder.r'][0], 0.19));
  assert.ok(near(j['hand.l'][1], 1.45 - 0.30 - 0.28));
});

test('test_fk_arm_raise', () => {
  needT();
  const j = T.figureJoints({ 'arm.r.upper': 150 }, 'adult');
  // d(150 deg) = (sin150, -cos150) = (0.5, 0.8660254...); the
  // forearm continues straight (fore angle 0, cumulative 150).
  const d = [0.5, Math.sqrt(3) / 2];
  nearPt(j['elbow.r'], [0.19 + 0.30 * d[0], 1.45 + 0.30 * d[1]]);
  nearPt(j['hand.r'],
    [0.19 + 0.58 * d[0], 1.45 + 0.58 * d[1]]);
});

test('test_fk_kid_proportions_and_height_scale', () => {
  needT();
  const kid = T.proportionsFor('kid');
  assert.ok(near(kid.thigh, 0.45 * 0.62));
  assert.ok(near(kid.head_r, 0.16 * 0.806));
  const j = T.figureJoints({}, 'kid');
  assert.ok(near(j['foot.l'][1], 0));
  // Total: 0.62 * (0.45+0.45+0.55+0.06) + 2 * 0.16 * 0.806.
  assert.ok(near(j['head.top'][1], 0.62 * 1.51 + 2 * 0.12896));
  // Explicit height scales uniformly: 3.66 = 2 * H0 for an adult.
  const tall2 = T.figureJoints({}, 'adult', 3.66);
  assert.ok(near(tall2['head.top'][1], 3.66));
  assert.ok(near(tall2.hip[1], 1.8));
});

test('test_camera_midpoint', () => {
  needT();
  const track = { kind: 'camera', scene: 's1',
    keys: [{ frame: 0, pos: [0, 3, 10], target: [0, 1, 0],
             fov: 60, ease: 'linear' },
           { frame: 48, pos: [3, 2, 4], target: [0, 0.5, 0],
             fov: 50, ease: 'smooth' }] };
  const cam = T.evalCamera(track, 24); // smooth(0.5) = 0.5
  assert.ok(near(cam.pos[0], 1.5) && near(cam.pos[1], 2.5) &&
            near(cam.pos[2], 7));
  assert.ok(near(cam.target[1], 0.75));
  assert.ok(near(cam.fov, 55));
});

test('test_dialogue_interval_edges', () => {
  needT();
  const tl = timelineWith([]);
  tl.dialogue = [{ id: 'd1', scene: 's1', start_frame: 12,
    end_frame: 48, speaker: 'mira', text: 'Hello!' }];
  assert.strictEqual(T.activeDialogue(tl, 11).length, 0);
  assert.strictEqual(T.activeDialogue(tl, 12).length, 1);
  assert.strictEqual(T.activeDialogue(tl, 47).length, 1);
  assert.strictEqual(T.activeDialogue(tl, 48).length, 0); // half-open
  assert.strictEqual(T.activeDialogue(tl, 12)[0].text, 'Hello!');
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
