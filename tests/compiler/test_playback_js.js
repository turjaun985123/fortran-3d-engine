'use strict';
/* Wave 4 Slice S4 -- preview PLAYBACK tests (compiler-js layer).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_playback_js.js
 *
 * Also discovered automatically by tests/run_tests.sh (the
 * compiler-js layer globs tests/compiler/test_*.js and counts the
 * "PASS (N tests)" line).
 *
 * What is tested, and at which level (stated honestly -- there is
 * no browser and no GPU in this harness):
 *
 *   PLAYER LEVEL (real code, headless): runtime/f3d.js's
 *   F3D.create() is driven on the tiny software Canvas2D from
 *   test_f3d_mirror_js.js (fillRect + path fills rasterized into
 *   a pixel buffer). api.seek / api.timeline / api.frame are the
 *   real S1 functions; a "frame hash" below is the sha256 of that
 *   pixel buffer after a seek. This proves same-t-twice and
 *   seek-away-and-back determinism of the actual player.
 *
 *   EVALUATOR LEVEL (real code): runtime/f3d-timeline.js's
 *   F3DTimeline (the Wave-3 evaluator the preview transport is
 *   specified to reuse -- ANIM-PLAN 4.4: "no second timing
 *   implementation") is evaluated over the compiled
 *   examples/anim-golden.f3d timeline (built here with the real
 *   bin/f3dc into a temp dir, the tests/ir pattern).
 *
 *   SCRUB-PARITY SUBSTITUTION (named, per the S4 brief): the Wave 4
 *   exit criterion asks for scrub-to-t frame hash parity with the
 *   G3d golden frame at the same t. A true pixel comparison
 *   against the native PPM pins (docs/V4-GOLDENS.md) is NOT
 *   feasible headlessly here: the preview player is the JS
 *   Canvas2D/WebGL stack, not the Fortran film renderer, and no
 *   existing harness renders the film through it. The honest
 *   headless form asserted instead: at the G3d pinned timestamps
 *   (timeline frames 0, 9, 23, 31, 34, 47 == files 0001, 0010,
 *   0024, 0032, 0035, 0048) the JS-evaluated frame STATE (every
 *   character's channels + camera + live dialogue, canonically
 *   serialized) hashes to pinned literals, the jump-apex values
 *   behind golden frame 0035 are asserted exactly, and the same
 *   state hash derived from tests/fixtures/timeline_vectors.json
 *   expectations matches the evaluator's. The native pixel pins
 *   themselves stay enforced by CI gates G3d/G3e.
 *
 *   PENDING SLICES: S1 (runtime seek/timeline/frame) and S3
 *   (preview page/route) have landed in the tree this suite was
 *   written against. S2 (timeline descriptor emitted into the
 *   compiled viewer bootstrap) landed in source while this suite
 *   was written but is not in the prebuilt bin/f3dc this suite
 *   builds with: the one test depending on it is named
 *   test_pending_s2_* and passes once f3dc is rebuilt (its
 *   descriptor is per-scene: 28 + 20 frames for the golden film,
 *   summing to the IR's 48). The player-level
 *   tests supply the descriptor through scene.timeline, which is
 *   exactly the surface S1 reads it from (scene.timeline /
 *   scene.viewer.timeline / F3D_TIMELINE).
 */
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const REPO = path.join(__dirname, '..', '..');
const CORE_PATH = path.join(REPO, 'runtime', 'f3d.js');
const TIMELINE_PATH = path.join(REPO, 'runtime', 'f3d-timeline.js');
const VECTORS_PATH = path.join(REPO, 'tests', 'fixtures',
                                'timeline_vectors.json');
const SAMPLE_PATH = path.join(REPO, 'tests', 'fixtures',
                              'sample.timeline.json');
const GOLDEN_SRC = path.join(REPO, 'examples', 'anim-golden.f3d');
const F3DC = path.join(REPO, 'bin', 'f3dc');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// ---- canonical state hash (the serialization is part of the pin:
// sorted object keys, arrays in order, JSON scalars) ----
function canon(v) {
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  if (v && typeof v === 'object')
    return '{' + Object.keys(v).sort().map(
      k => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
  return JSON.stringify(v);
}
function stateHash(o) {
  return crypto.createHash('sha256').update(canon(o)).digest('hex');
}
function fbHash(fb) {
  return crypto.createHash('sha256').update(Buffer.from(fb)).digest('hex');
}

// ---- software Canvas2D (same rasterizer as test_f3d_mirror_js) ----
function makeCanvas(W, H) {
  const fb = new Uint8Array(W * H * 3);
  let pathPts = [], style = [0, 0, 0];
  const ctx = {
    set fillStyle(s) {
      const m = /rgb\((\d+),(\d+),(\d+)\)/.exec(s);
      style = [+m[1], +m[2], +m[3]];
    },
    get fillStyle() { return ''; },
    fillRect(x, y, w, h) {
      for (let yy = y; yy < y + h; yy++)
        for (let xx = x; xx < x + w; xx++) {
          const i = (yy * W + xx) * 3;
          fb[i] = style[0]; fb[i + 1] = style[1]; fb[i + 2] = style[2];
        }
    },
    beginPath() { pathPts = []; },
    moveTo(x, y) { pathPts.push([x, y]); },
    lineTo(x, y) { pathPts.push([x, y]); },
    closePath() {},
    fill() {
      if (pathPts.length < 3) return;
      const [a, b, c] = pathPts;
      const edge = (p, q, x, y) =>
        (x - p[0]) * (q[1] - p[1]) - (y - p[1]) * (q[0] - p[0]);
      const x0 = Math.max(0, Math.floor(Math.min(a[0], b[0], c[0])));
      const x1 = Math.min(W - 1, Math.ceil(Math.max(a[0], b[0], c[0])));
      const y0 = Math.max(0, Math.floor(Math.min(a[1], b[1], c[1])));
      const y1 = Math.min(H - 1, Math.ceil(Math.max(a[1], b[1], c[1])));
      for (let yy = y0; yy <= y1; yy++)
        for (let xx = x0; xx <= x1; xx++) {
          const px = xx + 0.5, py = yy + 0.5;
          const d0 = edge(a, b, px, py), d1 = edge(b, c, px, py),
            d2 = edge(c, a, px, py), E = 1e-6;
          if ((d0 >= -E && d1 >= -E && d2 >= -E) ||
              (d0 <= E && d1 <= E && d2 <= E)) {
            const i = (yy * W + xx) * 3;
            fb[i] = style[0]; fb[i + 1] = style[1]; fb[i + 2] = style[2];
          }
        }
    },
  };
  const canvas = { tagName: 'CANVAS', width: W, height: H,
    clientWidth: W, clientHeight: H,
    getContext() { return ctx; } };
  return { canvas, fb };
}

// ---- load the real runtime modules ----
let F3D = null, T = null, loadError = null;
try {
  global.window = globalThis;
  global.requestAnimationFrame = () => 0;   // play() must not loop
  global.cancelAnimationFrame = () => {};
  require(CORE_PATH);
  F3D = globalThis.F3D;
  require(TIMELINE_PATH);
  T = globalThis.F3DTimeline;
} catch (e) { loadError = e; }
function need() { if (loadError) throw loadError; }

// Player scene: one spinning cube + the S2-shaped timeline
// descriptor S1 consumes ({duration_frames, fps:{num,den}}).
function makePlayer() {
  need();
  const { canvas, fb } = makeCanvas(96, 96);
  const api = F3D.create(canvas, {
    objects: [{ prim: 'cube', name: 'cube1', color: 'red', size: 2 }],
    camera: { pos: [0, 3, 10], target: [0, 1, 0], fov: 60 },
    lights: [{ direction: [-0.5, -1, -0.7] }],
    width: 96, height: 96, bg: [25, 25, 35],
    animations: [{ kind: 'spin', target: 'cube1', speed: 90,
                   duration: 5, ease: 'linear', loop: 'forever',
                   axis: 'y' }],
    timeline: { duration_frames: 48, fps: { num: 24, den: 1 } },
  });
  return { api, fb };
}

// ---- compiled golden film (real bin/f3dc, tests/ir pattern) ----
let goldenDir = null, goldenTl = null, goldenError = null;
function needGolden() {
  if (goldenTl) return goldenTl;
  if (goldenError) throw goldenError;
  try {
    goldenDir = fs.mkdtempSync(path.join(os.tmpdir(), 'forge3d-playback-'));
    fs.copyFileSync(GOLDEN_SRC, path.join(goldenDir, 'anim-golden.f3d'));
    execFileSync(F3DC, ['build', 'anim-golden.f3d'],
                 { cwd: goldenDir, stdio: 'pipe' });
    goldenTl = JSON.parse(fs.readFileSync(
      path.join(goldenDir, 'build', 'anim-golden.timeline.json'), 'utf8'));
    return goldenTl;
  } catch (e) { goldenError = e; throw e; }
}
function goldenState(tl, frame) {
  const state = {};
  for (const ch of tl.characters)
    state[ch.id] = T.evalChannels(tl, ch.id, frame);
  const cam = tl.tracks.find(t => t.kind === 'camera');
  if (cam) state['@camera'] = T.evalCamera(cam, frame);
  state['@dialogue'] = T.activeDialogue(tl, frame);
  return state;
}

// G3d pinned timeline frames (docs/V4-GOLDENS.md): file NNNN is
// timeline frame NNNN-1.
const G3D_FRAMES = [0, 9, 23, 31, 34, 47];
const G3D_STATE_HASH = {
  0:  'ab7334408a274ab1ea170ec0699914909e525eabd6a578b60108c30e9fdb69b5',
  9:  'b864234e8cd07188787b18449ba45e6548246b1eda0275f4a8da7a8acb5e046b',
  23: 'ef9e9a12d1502d7df636337be1293c56e205eb9032d95a6506e2ec1fff0707af',
  31: '719aa7b302d6576783708ebc856b63a5f797ed90f1b650583aa78ba02a1910de',
  34: '5023a575850b7588fc54326a9842b56f6bb2c2f27359191da567d5704b720250',
  47: 'e11ea8b29e2191434afef4b3c5c93492517c2d8653b69d5d70a8ec96e4d11663',
};

// ------------------------------------------------------------------
// S1 player level (real F3D.create + api.seek/timeline/frame)
// ------------------------------------------------------------------

test('test_s1_api_surface_seek_timeline_frame', () => {
  const { api } = makePlayer();
  assert.strictEqual(typeof api.seek, 'function', 'api.seek(t)');
  assert.strictEqual(typeof api.frame, 'function', 'api.frame()');
  assert.strictEqual(typeof api.time, 'function', 'api.time()');
  assert.ok(api.timeline, 'api.timeline descriptor present');
  assert.strictEqual(api.timeline.duration_frames, 48);
  assert.deepStrictEqual(api.timeline.fps, { num: 24, den: 1 });
  assert.strictEqual(api.frame(), 0, 'fresh player is at frame 0');
});

test('test_s1_seek_sets_time_and_frame_at_g3d_timestamps', () => {
  const { api } = makePlayer();
  // t = frame / fps at the G3d pins: frame 9 (file 0010, mid-walk)
  // and frame 34 (file 0035, jump apex).
  api.seek(9 / 24);
  assert.ok(Math.abs(api.time() - 9 / 24) < 1e-12, 'time after seek');
  assert.strictEqual(api.frame(), 9);
  api.seek(34 / 24);
  assert.strictEqual(api.frame(), 34);
  api.seek(0);
  assert.strictEqual(api.frame(), 0);
});

test('test_s1_seek_twice_identical_frame_hash', () => {
  const { api, fb } = makePlayer();
  api.seek(34 / 24);
  const h1 = fbHash(fb);
  api.seek(34 / 24);                       // same t requested twice
  assert.strictEqual(fbHash(fb), h1, 'second seek to same t differs');
  api.seek(0.5);                           // seek away...
  assert.notStrictEqual(fbHash(fb), h1, 'frame at t=0.5 should differ');
  api.seek(34 / 24);                       // ...and back: pure f(t)
  assert.strictEqual(fbHash(fb), h1, 'seek back to same t differs');
});

test('test_s1_seek_clamps_to_descriptor_duration', () => {
  const { api } = makePlayer();
  api.seek(99);                            // duration = 48/24 = 2 s
  assert.strictEqual(api.time(), 2);
  assert.strictEqual(api.frame(), 48);
  api.seek(-1);
  assert.strictEqual(api.time(), 0);
  assert.strictEqual(api.frame(), 0);
});

test('test_s1_seek_wiring_is_the_paused_render_path', () => {
  // Static level: the api object wires seek/timeline/frame to the
  // S1 helpers, and frame() derives via round(t * fps) (the repo's
  // nint rule), not a second timing implementation.
  const src = fs.readFileSync(CORE_PATH, 'utf8');
  assert.ok(/seek:seek/.test(src), 'api wires seek:seek');
  assert.ok(/timeline:tlDesc/.test(src), 'api wires timeline:tlDesc');
  assert.ok(/frame:frameNow/.test(src), 'api wires frame:frameNow');
  assert.ok(/Math\.round\(time\s*\*\s*fpsNow\(\)\)/.test(src),
            'frameNow is round(t * fps)');
});

// ------------------------------------------------------------------
// Evaluator level: seek determinism + scrub-parity anchor
// ------------------------------------------------------------------

test('test_seek_determinism_golden_state_hashes', () => {
  need();
  const tl = needGolden();
  for (const f of G3D_FRAMES) {
    const h1 = stateHash(goldenState(tl, f));
    const h2 = stateHash(goldenState(tl, f));   // same t twice
    assert.strictEqual(h2, h1, 'frame ' + f + ': re-evaluation differs');
    for (const other of G3D_FRAMES) goldenState(tl, other);
    assert.strictEqual(stateHash(goldenState(tl, f)), h1,
      'frame ' + f + ': evaluation after other frames differs');
  }
});

test('test_scrub_parity_anchor_g3d_frame34_jump_apex', () => {
  need();
  const tl = needGolden();
  // Frame 34 is the jump track's peak root.y key -- the state
  // behind G3d golden file 0035 (native sha256 e2ca3534...).
  const ada = T.evalChannels(tl, 'ada', 34);
  assert.strictEqual(ada['root.y'], 0.55);
  assert.strictEqual(ada['arm.r.upper'], 150);
  assert.strictEqual(ada['arm.l.upper'], -150);
  assert.strictEqual(ada['leg.l.shin'], 55);
  assert.strictEqual(stateHash(goldenState(tl, 34)), G3D_STATE_HASH[34]);
  // Mid-walk pin (file 0010, frame 9) and the full pinned set.
  assert.strictEqual(T.evalChannels(tl, 'ada', 9)['leg.l.shin'], 40);
  for (const f of G3D_FRAMES)
    assert.strictEqual(stateHash(goldenState(tl, f)), G3D_STATE_HASH[f],
      'state hash pin, frame ' + f);
});

test('test_scrub_parity_anchor_vectors_derived_hash', () => {
  need();
  // For every channel_eval vector: the hash of the evaluator's
  // {channel: value} at the vector's frame must equal the hash of
  // {channel: expected} taken from the fixture itself -- the
  // vectors both engines already assert (tests/fixtures/
  // timeline_vectors.json), i.e. the hash is DERIVED from the
  // fixture, not from the JS evaluator.
  const vectors = JSON.parse(fs.readFileSync(VECTORS_PATH, 'utf8'));
  const cases = vectors.filter(c => c.kind === 'channel_eval');
  assert.strictEqual(cases.length, 8, 'channel_eval vector count');
  for (const c of cases) {
    const track = {
      kind: 'action', character: 'mira', action: 'vec',
      start_frame: c.track_start, end_frame: c.track_end,
      keys: c.frames.map((f, i) => ({
        frame: f, channel: c.channel,
        value: (c.value_strs ? c.value_strs[i] : c.values[i]),
        ease: c.eases[i] || 'linear',
      })),
    };
    const tl = { format: 'forge3d-timeline', ir_version: 1,
      fps: { num: 24, den: 1 }, duration_frames: 96,
      characters: [{ id: 'mira', name: 'Mira' }],
      tracks: [track], dialogue: [] };
    const got = T.evalChannels(tl, 'mira', c.frame)[c.channel];
    assert.strictEqual(stateHash({ [c.channel]: got }),
                       stateHash({ [c.channel]: c.expected }),
      'vector ' + c.name + ': state hash from fixture expectation');
  }
});

test('test_dialogue_overlay_data_at_t', () => {
  need();
  // The subtitle overlay's data level: F3DTimeline.activeDialogue
  // over the shared sample timeline (speaker + text + half-open
  // span), the same lookup the S3 page script performs per frame.
  const sample = JSON.parse(fs.readFileSync(SAMPLE_PATH, 'utf8'));
  for (const f of [12, 24, 47]) {
    const live = T.activeDialogue(sample, f);
    assert.strictEqual(live.length, 1, 'one live cue at frame ' + f);
    assert.strictEqual(live[0].speaker, 'mira');
    assert.strictEqual(live[0].text, 'Finn — over here!');
  }
  assert.strictEqual(T.activeDialogue(sample, 11).length, 0);
  assert.strictEqual(T.activeDialogue(sample, 48).length, 0);
});

// ------------------------------------------------------------------
// S2 (PENDING when written): descriptor in the compiled viewer
// ------------------------------------------------------------------

test('test_pending_s2_timeline_descriptor_in_built_viewer', () => {
  // The compiled viewer bootstrap (a built .html or .js artifact,
  // NOT the .timeline.json sidecar) must carry the timeline
  // descriptor {duration_frames, fps: {num, den}} in the shape
  // api.timeline publishes. S2's descriptor is PER SCENE (it is a
  // sibling key of each scene blob): the golden film's two scene
  // viewers must carry 28 and 20 frames at fps {num: 24, den: 1},
  // summing to the film's 48 (the total lives in the IR).
  needGolden();
  const buildDir = path.join(goldenDir, 'build');
  const viewers = fs.readdirSync(buildDir)
    .filter(n => /\.(html|js)$/.test(n));
  assert.ok(viewers.length > 0, 'built viewer artifacts exist');
  const framesFound = new Set();
  for (const n of viewers) {
    const s = fs.readFileSync(path.join(buildDir, n), 'utf8');
    if (!/["']?num["']?\s*:\s*24/.test(s) ||
        !/["']?den["']?\s*:\s*1(?![0-9])/.test(s)) continue;
    for (const m of s.matchAll(/["']?duration_frames["']?\s*:\s*(\d+)/g))
      framesFound.add(+m[1]);
  }
  assert.deepStrictEqual([...framesFound].sort((a, b) => a - b), [20, 28],
    'per-scene duration_frames in built viewers (awaiting S2); ' +
    'scanned: ' + viewers.join(', '));
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
