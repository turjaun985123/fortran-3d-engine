'use strict';
/* JS consumer of the shared timeline test vectors
 * tests/fixtures/timeline_vectors.json (Wave 3 Slice S5) -- the
 * Fortran consumer is tests/fortran/test_timeline_vectors.f90 and
 * asserts the SAME file with the SAME tolerances:
 *
 *     scalars / positions / joints ........... 1e-9
 *     quaternions (sign-aligned, q ~ -q) ..... 1e-12
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_timeline_vectors_js.js
 *
 * It is also discovered automatically by tests/run_tests.sh (the
 * compiler-js layer globs tests/compiler/test_*.js).
 *
 * Entry points driven (the real runtime modules, no re-implementation):
 *   channel_eval -> F3DTimeline.evalChannels (runtime/f3d-timeline.js)
 *     over a single action track whose trapezoid weight is 1 at the
 *     probe frame, so the blend returns the scalar key evaluation
 *     (film_eval_scalar on the Fortran side) unchanged.
 *   blend        -> F3DTimeline.evalChannels (the trapezoid blend).
 *   pose_keys    -> F3DTimeline.evalPoseKeys; the fps entry goes
 *     through F3DKeys.evalTrackQ (runtime/f3d-keys.js), mirroring
 *     key_eval_q's fps conversion (key times are frame numbers,
 *     the probe t is in seconds).
 *   camera       -> F3DTimeline.evalCamera.
 *   fk           -> F3DTimeline.figureJoints (+ proportionsFor).
 *   dialogue     -> F3DTimeline.activeDialogue.
 *
 * Expected values in the fixture were derived by hand from the
 * shared formulas (ends-at easing, trapezoid ramp min(6, span/4),
 * blend (sum w*v + w_rest*rest)/max(1, sum w + w_rest), the adult
 * proportions table with H0 = 1.83, limb dir (sin a, -cos a)).
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const FIXTURE_PATH = path.join(REPO, 'tests', 'fixtures',
                               'timeline_vectors.json');
const TIMELINE_PATH = path.join(REPO, 'runtime', 'f3d-timeline.js');
const KEYS_PATH = path.join(REPO, 'runtime', 'f3d-keys.js');

const TOL = 1e-9;
const TOL_QUAT = 1e-12;

const EXPECTED_TOTAL = 26;
const EXPECTED_KINDS = {
  channel_eval: 8, blend: 3, pose_keys: 4,
  camera: 3, fk: 6, dialogue: 2,
};

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

let cases = null;
let loadError = null;
try {
  cases = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
  if (!Array.isArray(cases)) throw new Error('fixture root is not an array');
} catch (e) { loadError = e; }
function needCases() {
  if (loadError) throw loadError;
  return cases;
}
function casesOfKind(kind) {
  return needCases().filter(c => c.kind === kind);
}

let T = null;
let K = null;
let modError = null;
try {
  global.window = globalThis;
  require(TIMELINE_PATH);
  T = globalThis.F3DTimeline;
  require(KEYS_PATH);
  K = globalThis.F3DKeys;
} catch (e) { modError = e; }
function needT() { if (modError) throw modError; return T; }
function needK() { if (modError) throw modError; return K; }

function near(got, exp, tol, msg) {
  assert.ok(Math.abs(got - exp) <= tol,
    msg + ': got ' + got + ' want ' + exp + ' (tol ' + tol + ')');
}
function nearArr(got, exp, tol, msg) {
  assert.strictEqual(got.length, exp.length, msg + ': length');
  for (let i = 0; i < exp.length; i++)
    near(got[i], exp[i], tol, msg + ' [' + i + ']');
}
function nearQuat(got, exp, msg) {
  let dot = 0;
  for (let i = 0; i < 4; i++) dot += got[i] * exp[i];
  const s = dot < 0 ? -1 : 1;
  for (let i = 0; i < 4; i++)
    near(got[i], s * exp[i], TOL_QUAT, msg + ' [' + 'xyzw'[i] + ']');
}

function actionTrack(c, tr) {
  return {
    kind: 'action', character: 'mira', action: 'vec',
    start_frame: tr.start, end_frame: tr.end,
    keys: tr.frames.map((f, i) => ({
      frame: f, channel: c.channel,
      value: (tr.value_strs ? tr.value_strs[i] : tr.values[i]),
      ease: tr.eases[i] || 'linear',
    })),
  };
}
function timelineWith(tracks, dialogue) {
  return {
    format: 'forge3d-timeline', ir_version: 1,
    fps: { num: 24, den: 1 }, duration_frames: 96,
    characters: [{ id: 'mira', name: 'Mira' }],
    tracks: tracks, dialogue: dialogue || [],
  };
}

// ------------------------------------------------------------------
// Per-kind checks
// ------------------------------------------------------------------

function checkChannelEval(c) {
  const tl = timelineWith([actionTrack(c, {
    start: c.track_start, end: c.track_end,
    frames: c.frames, values: c.values, eases: c.eases,
  })]);
  const pose = needT().evalChannels(tl, 'mira', c.frame);
  near(pose[c.channel], c.expected, TOL,
    'fixture ' + c.name + ': evalChannels ' + c.channel);
}

function checkBlend(c) {
  const tl = timelineWith(c.tracks.map(tr => actionTrack(c, tr)));
  const pose = needT().evalChannels(tl, 'mira', c.frame);
  if (c.channel === 'face.expr') {
    assert.strictEqual(pose[c.channel], c.expected_expr,
      'fixture ' + c.name + ': face.expr winner');
  } else {
    near(pose[c.channel], c.expected, TOL,
      'fixture ' + c.name + ': blend ' + c.channel);
  }
}

function checkPoseKeys(c) {
  let out;
  if (c.fps != null) {
    const track = {
      fps: c.fps, loop: 'once',
      keys: c.keys.map(k => ({
        time: k.frame, pos: k.pos, rot_deg: k.rot_deg,
        scale3: k.scale3, ease: k.ease,
      })),
    };
    out = needK().evalTrackQ(track, c.t_seconds);
  } else {
    out = needT().evalPoseKeys({ kind: 'pose_keys', keys: c.keys },
                               c.frame);
  }
  nearArr(out.pos, c.expected_pos, TOL,
    'fixture ' + c.name + ': pos');
  nearQuat(out.quat, c.expected_quat,
    'fixture ' + c.name + ': quat');
  nearArr(out.scale3, c.expected_scale3, TOL,
    'fixture ' + c.name + ': scale3');
}

function checkCamera(c) {
  const cam = needT().evalCamera({ kind: 'camera', keys: c.keys },
                                 c.frame);
  nearArr(cam.pos, c.expected_pos, TOL,
    'fixture ' + c.name + ': cam pos');
  nearArr(cam.target, c.expected_target, TOL,
    'fixture ' + c.name + ': cam target');
  near(cam.fov, c.expected_fov, TOL,
    'fixture ' + c.name + ': cam fov');
}

function checkFk(c) {
  const pose = {};
  for (const pc of c.pose_channels) pose[pc.channel] = pc.value;
  const j = needT().figureJoints(pose, c.proportions,
                                 c.height == null ? undefined
                                                  : c.height);
  for (const chk of c.checks) {
    assert.ok(j[chk.joint], 'fixture ' + c.name +
              ': joint exists: ' + chk.joint);
    nearArr(j[chk.joint], chk.uv, TOL,
      'fixture ' + c.name + ': joint ' + chk.joint);
  }
}

function checkDialogue(c) {
  const tl = timelineWith([], c.cues.map(q => ({
    id: 'd', scene: 's1', start_frame: q.start, end_frame: q.end,
    speaker: q.speaker, text: q.text,
  })));
  const live = needT().activeDialogue(tl, c.frame);
  assert.strictEqual(live.length, c.expected_count,
    'fixture ' + c.name + ': live cue count');
  if (c.expected_count > 0) {
    assert.strictEqual(live[0].speaker, c.expected_speaker,
      'fixture ' + c.name + ': live cue speaker');
  }
}

const CASE_CHECKS = {
  channel_eval: checkChannelEval,
  blend: checkBlend,
  pose_keys: checkPoseKeys,
  camera: checkCamera,
  fk: checkFk,
  dialogue: checkDialogue,
};

// ------------------------------------------------------------------
// Fixture-level tests
// ------------------------------------------------------------------

test('test_fixture_file_exists', () => {
  assert.ok(fs.existsSync(FIXTURE_PATH) &&
            fs.statSync(FIXTURE_PATH).isFile(), FIXTURE_PATH);
});

test('test_runtime_modules_load', () => {
  needT(); needK();
  assert.strictEqual(typeof T.evalChannels, 'function');
  assert.strictEqual(typeof K.evalTrackQ, 'function');
});

test('test_fixture_case_count', () => {
  assert.strictEqual(needCases().length, EXPECTED_TOTAL);
});

test('test_fixture_kind_counts', () => {
  for (const kind of Object.keys(EXPECTED_KINDS)) {
    assert.strictEqual(casesOfKind(kind).length, EXPECTED_KINDS[kind],
      'kind count: ' + kind);
  }
});

test('test_fixture_channel_coverage', () => {
  const used = new Set();
  for (const c of needCases()) {
    if (c.channel) used.add(c.channel);
    for (const pc of c.pose_channels || []) used.add(pc.channel);
  }
  assert.ok(used.size >= 8,
    'at least 8 distinct channels, got ' + used.size +
    ': ' + [...used].join(', '));
});

if (cases) {
  for (const c of cases) {
    test('test_fixture_' + c.name, () => {
      const check = CASE_CHECKS[c.kind];
      assert.ok(check, 'fixture case has a known kind: ' + c.name +
                ' (kind ' + c.kind + ')');
      check(c);
    });
  }
} else {
  test('test_fixture_cases_generated', () => { needCases(); });
}

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
