'use strict';
/* run_ir_tests.js -- Forge3D Timeline IR contract test layer
 * (Animation Compiler Wave 2, slice B2; ANIM-PLAN SS5.5 + SS3.7
 * conformance kit). Standalone-runnable:
 *
 *     node tests/ir/run_ir_tests.js
 *
 * Prints "run_ir_tests.js: PASS (N tests)" and exits 0 on success,
 * mirroring the tests/compiler/ house style. Wired into
 * tests/run_tests.sh as the "ir" layer.
 *
 * What is covered:
 *   - Golden fixtures: every fixtures/*.f3d is built with the REAL
 *     bin/f3dc and the emitted .timeline.json must byte-match the
 *     committed, spec-reviewed fixtures/*.timeline.json; the
 *     emitted file must also pass validate_ir.js.
 *   - Host simulation: host_sim.js (a spec-only consumer) extracts
 *     the expected performance data from each golden fixture --
 *     spot values per fixture (spans, dialogue text byte-equal,
 *     easing attachment, cast unions).
 *   - Conformance/adversarial cases (SS3.7 kit): 24000/1001 fps,
 *     ir_version 99 rejection naming the version, missing format
 *     rejection, unknown track kind skipped with a diagnostic,
 *     unknown keys tolerated, -0 / whole-float raw-byte hygiene,
 *     byte determinism (same source built twice -> same sha256).
 *   - Validator negative tests: each cross-field rule in
 *     timeline_schema.json is shown to actually fire.
 *   - Corpus sweep: every tests/native/corpus.json anim case that
 *     performs a build is rebuilt; any emitted .timeline.json must
 *     validate, and stills must emit none.
 *
 * Zero Python; Node + fixtures only.
 */
const assert = require('assert');
const { execFileSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HERE = __dirname;
const REPO = path.join(HERE, '..', '..');
const F3DC = path.join(REPO, 'bin', 'f3dc');
const FIXTURES = path.join(HERE, 'fixtures');
const ADV = path.join(HERE, 'adversarial');
const { validateText } = require('./validate_ir');
const { extractTimeline } = require('./host_sim');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

function buildSource(f3dPath, label) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'forge3d-ir-'));
  const base = path.basename(f3dPath);
  fs.copyFileSync(f3dPath, path.join(dir, base));
  execFileSync(F3DC, ['build', '-o', 'out', base], { cwd: dir, stdio: 'pipe' });
  const stem = base.replace(/\.f3d$/, '');
  const tl = path.join(dir, 'out', stem + '.timeline.json');
  return { dir, timelinePath: fs.existsSync(tl) ? tl : null, label };
}

function buildInline(src, name) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'forge3d-ir-'));
  fs.writeFileSync(path.join(dir, name + '.f3d'), src);
  execFileSync(F3DC, ['build', '-o', 'out', name + '.f3d'], { cwd: dir, stdio: 'pipe' });
  const tl = path.join(dir, 'out', name + '.timeline.json');
  return { dir, timelinePath: fs.existsSync(tl) ? tl : null };
}

const GOLDEN = fs.readdirSync(FIXTURES)
  .filter((f) => f.endsWith('.timeline.json'))
  .map((f) => f.replace(/\.timeline\.json$/, ''))
  .sort();

/* ------------------------------------------------------------------ */
/* Golden fixtures: byte equality + validation                        */
/* ------------------------------------------------------------------ */

for (const name of GOLDEN) {
  test('golden ' + name + ': emitted IR byte-matches the reviewed fixture', () => {
    const { timelinePath } = buildSource(path.join(FIXTURES, name + '.f3d'), name);
    assert.ok(timelinePath, name + ': build emitted no .timeline.json');
    const emitted = fs.readFileSync(timelinePath);
    const expected = fs.readFileSync(path.join(FIXTURES, name + '.timeline.json'));
    assert.ok(emitted.equals(expected),
      name + ': emitted bytes differ from fixtures/' + name + '.timeline.json');
  });
  test('golden ' + name + ': emitted IR passes validate_ir', () => {
    const raw = fs.readFileSync(path.join(FIXTURES, name + '.timeline.json'), 'utf8');
    assert.deepStrictEqual(validateText(raw), [],
      name + ': validator failures: ' + validateText(raw).join(' | '));
  });
}

test('still fixture emits no timeline file (absence = still)', () => {
  const { timelinePath } = buildSource(path.join(FIXTURES, 'still.f3d'), 'still');
  assert.strictEqual(timelinePath, null);
});

/* ------------------------------------------------------------------ */
/* Host simulation: spot values per golden fixture                    */
/* ------------------------------------------------------------------ */

function extractFixture(name) {
  return extractTimeline(
    fs.readFileSync(path.join(FIXTURES, name + '.timeline.json'), 'utf8'));
}
const actionSpan = (data, character, action) => {
  const t = data.tracks.find((x) => x.kind === 'action' &&
    x.character === character && x.action === action);
  assert.ok(t, 'no action track ' + character + '/' + action);
  return [t.start_frame, t.end_frame];
};

test('host_sim saturday-market: duration, wave span, dialogue d1 byte-equal', () => {
  const { data, unmapped } = extractFixture('saturday-market');
  assert.strictEqual(data.duration_frames, 360);
  assert.deepStrictEqual(data.characters.map((c) => c.id), ['lloyd', 'mira']);
  assert.deepStrictEqual(actionSpan(data, 'mira', 'wave'), [96, 144]);
  assert.deepStrictEqual(actionSpan(data, 'lloyd', 'walk'), [0, 96]);
  const d1 = data.dialogue.find((d) => d.id === 'd1');
  assert.ok(Buffer.from(d1.text, 'utf8').equals(
    Buffer.from('Good morning, Mira!', 'utf8')), 'd1 text not byte-equal');
  assert.strictEqual(d1.speaker, 'lloyd');
  assert.strictEqual(data.tracks.filter((t) => t.kind === 'camera').length, 1);
  assert.ok(unmapped.length > 0, 'unresolved sentence actions must be reported unmapped');
});

test('host_sim the-lost-key: two-scene partition, cast union, together spans', () => {
  const { data } = extractFixture('the-lost-key');
  assert.strictEqual(data.duration_frames, 360);
  assert.deepStrictEqual(data.characters.map((c) => c.id), ['lloyd', 'mira']);
  assert.deepStrictEqual(data.scenes.map((s) => [s.id, s.start_frame, s.end_frame]),
    [['park', 0, 192], ['home', 192, 360]]);
  assert.deepStrictEqual(actionSpan(data, 'lloyd', 'dance'), [240, 312]);
  assert.deepStrictEqual(actionSpan(data, 'mira', 'dance'), [240, 312]);
  const d2 = data.dialogue.find((d) => d.id === 'd2');
  assert.strictEqual(d2.speaker, 'mira');
  assert.strictEqual(d2.text, 'You found it!');
  assert.deepStrictEqual(Object.keys(data.scenes[0].bindings), ['lloyd'],
    'mira is off-stage in park (absent from bindings)');
});

test('host_sim the-bus-is-late: custom action expands, verb + dialogue spans', () => {
  const { data, unmapped } = extractFixture('the-bus-is-late');
  assert.deepStrictEqual(actionSpan(data, 'rafi', 'jump'), [264, 280]);
  assert.deepStrictEqual(actionSpan(data, 'rafi', 'spin'), [296, 312]);
  const verb = data.tracks.find((t) => t.kind === 'verb');
  assert.strictEqual(verb.target, 'bus');
  assert.deepStrictEqual([verb.start_frame, verb.end_frame], [120, 216]);
  assert.strictEqual(data.dialogue[0].text, 'Finally!');
  assert.deepStrictEqual([data.dialogue[0].start_frame, data.dialogue[0].end_frame], [216, 264]);
  assert.ok(unmapped.some((u) => u.action === 'jump' && u.character === 'rafi'),
    'custom-action sub-actions are resolved:false and must be unmapped');
});

test('host_sim gate-scene: em-dash dialogue byte-equal, camera zoom keys', () => {
  const { data } = extractFixture('gate-scene');
  assert.strictEqual(data.duration_frames, 144);
  assert.ok(Buffer.from(data.dialogue[0].text, 'utf8').equals(
    Buffer.from('Finn — over here!', 'utf8')), 'em-dash text not byte-equal');
  const cam = data.tracks.find((t) => t.kind === 'camera');
  const last = cam.keys[cam.keys.length - 1];
  assert.strictEqual(last.frame, 144);
  assert.strictEqual(last.fov, 40);
  assert.strictEqual(last.ease, 'smooth');
});

test('host_sim two-rooms: fps 30, scene partition, cast union across scenes', () => {
  const { data } = extractFixture('two-rooms');
  assert.deepStrictEqual(data.fps, { den: 1, num: 30 });
  assert.deepStrictEqual(data.scenes.map((s) => [s.id, s.start_frame, s.end_frame]),
    [['kitchen', 0, 30], ['garden', 30, 120]]);
  assert.deepStrictEqual(data.characters.map((c) => c.id), ['rafi', 'mira']);
});

test('host_sim bhor-bangla: Bangla dialogue byte-equal, no normalisation', () => {
  const { data } = extractFixture('bhor-bangla');
  assert.ok(Buffer.from(data.dialogue[0].text, 'utf8').equals(
    Buffer.from('শুভ সকাল, মীরা!', 'utf8')), 'Bangla d1 not byte-equal');
  assert.ok(Buffer.from(data.dialogue[1].text, 'utf8').equals(
    Buffer.from('আমগুলো দেখো!', 'utf8')), 'Bangla d2 not byte-equal');
  assert.deepStrictEqual([data.dialogue[0].start_frame, data.dialogue[0].end_frame], [0, 48]);
});

test('host_sim legacy-keys: pose_keys on target, ease rides the END key', () => {
  const { data } = extractFixture('legacy-keys');
  const t = data.tracks[0];
  assert.strictEqual(t.kind, 'pose_keys');
  assert.strictEqual(t.target, 'box');
  assert.deepStrictEqual(t.keys.map((k) => k.frame), [0, 60]);
  assert.strictEqual(t.keys[0].ease, 'linear', 'first key ease is the ignored linear');
  assert.strictEqual(t.keys[1].ease, 'smooth', 'segment ease lives on the key it ENDS at');
  assert.deepStrictEqual(t.keys[1].pos, [3, 0, 0]);
});

test('host_sim legacy-verb: closed-form verb span + params verbatim', () => {
  const { data } = extractFixture('legacy-verb');
  const t = data.tracks[0];
  assert.strictEqual(t.kind, 'verb');
  assert.strictEqual(t.verb, 'spin');
  assert.deepStrictEqual([t.start_frame, t.end_frame], [0, 60]);
  assert.strictEqual(t.params.speed, 90);
  assert.strictEqual(t.params.axis, 'y');
});

test('host_sim character-keys: non-film character pose_keys', () => {
  const { data } = extractFixture('character-keys');
  const t = data.tracks[0];
  assert.strictEqual(t.kind, 'pose_keys');
  assert.strictEqual(t.character, 'lloyd');
  assert.deepStrictEqual(t.keys[1].pos, [5, 0, 2]);
  assert.strictEqual(t.keys[1].ease, 'smooth');
});

test('host_sim easing-boundary: alias canonicalised, ease on END key only', () => {
  const { data } = extractFixture('easing-boundary');
  const keys = data.tracks[0].keys;
  assert.deepStrictEqual(keys.map((k) => k.frame), [0, 30, 60]);
  assert.strictEqual(keys[0].ease, 'linear');
  assert.strictEqual(keys[1].ease, 'cubic-in-out',
    'source alias "ease-in-out" must be normalised to the canonical spelling');
  assert.strictEqual(keys[2].ease, 'smooth');
});

test('host_sim camera-move: pan eases into its END key, zoom widens fov', () => {
  const { data } = extractFixture('camera-move');
  const cam = data.tracks[0];
  assert.strictEqual(cam.kind, 'camera');
  assert.deepStrictEqual(cam.keys.map((k) => k.frame), [0, 72, 96]);
  assert.strictEqual(cam.keys[1].ease, 'smooth');
  assert.deepStrictEqual(cam.keys[1].target, [5, 0, 0]);
  assert.strictEqual(cam.keys[2].fov, 80);
});

test('host_sim duet-together: parallel tracks share one span', () => {
  const { data } = extractFixture('duet-together');
  assert.strictEqual(data.duration_frames, 48);
  assert.deepStrictEqual(actionSpan(data, 'lloyd', 'dance'), [0, 48]);
  assert.deepStrictEqual(actionSpan(data, 'mira', 'dance'), [0, 48]);
});

test('host_sim custom-action: every sub-action unresolved and reported', () => {
  const { data, unmapped } = extractFixture('custom-action');
  assert.deepStrictEqual(data.tracks.map((t) => t.action), ['jump', 'wave', 'spin']);
  assert.ok(data.tracks.every((t) => t.resolved === false));
  assert.strictEqual(unmapped.length, 3);
});

test('host_sim whole-floats: whole values arrive as JSON integers', () => {
  const { data } = extractFixture('whole-floats');
  const k = data.tracks[0].keys[1];
  assert.strictEqual(k.pos[0], 60);
  assert.strictEqual(k.scale, 2);
  assert.deepStrictEqual(data.tracks[0].keys[0].pos, [0, 0, 0]);
});

/* ------------------------------------------------------------------ */
/* Conformance / adversarial cases (ANIM-PLAN SS3.7 kit)              */
/* ------------------------------------------------------------------ */

test('adversarial (a): fps 24000/1001 accepted, frame arithmetic stays integer', () => {
  const raw = fs.readFileSync(path.join(ADV, 'fps-24000-1001.timeline.json'), 'utf8');
  assert.deepStrictEqual(validateText(raw), []);
  const { data } = extractTimeline(raw);
  assert.deepStrictEqual(data.fps, { den: 1001, num: 24000 });
  const cue = data.dialogue[0];
  assert.ok(Number.isInteger(cue.end_frame - cue.start_frame));
  assert.strictEqual(cue.end_frame - cue.start_frame, 36);
  assert.strictEqual(data.scenes[0].end_frame, 48);
});

test('adversarial (b): ir_version 99 rejected NAMING the version', () => {
  const raw = fs.readFileSync(path.join(ADV, 'ir-version-99.timeline.json'), 'utf8');
  assert.throws(() => extractTimeline(raw), /ir_version 99/);
});

test('adversarial (b): missing format rejected', () => {
  const raw = fs.readFileSync(path.join(ADV, 'missing-format.timeline.json'), 'utf8');
  assert.throws(() => extractTimeline(raw), /missing "format"/);
});

test('adversarial (b): host_sim CLI exits 1 and names 99 on stderr', () => {
  let err = null;
  try {
    execFileSync(process.execPath,
      [path.join(HERE, 'host_sim.js'), path.join(ADV, 'ir-version-99.timeline.json')],
      { stdio: 'pipe' });
  } catch (e) { err = e; }
  assert.ok(err, 'host_sim CLI should fail on ir_version 99');
  assert.strictEqual(err.status, 1);
  assert.ok(String(err.stderr).includes('99'),
    'CLI error must name the version found, got: ' + err.stderr);
});

test('adversarial (c): unknown track kind skipped WITH diagnostic, rest extracted', () => {
  const raw = fs.readFileSync(path.join(ADV, 'unknown-track-kind.timeline.json'), 'utf8');
  const { data, diagnostics } = extractTimeline(raw);
  assert.deepStrictEqual(data.tracks.map((t) => t.kind), ['pose_keys']);
  assert.ok(diagnostics.some((d) => d.includes('hologram')),
    'a diagnostic naming the skipped kind is required, got: ' + diagnostics.join(' | '));
  assert.strictEqual(data.dialogue[0].text, 'Still extracted.');
});

test('adversarial: unknown keys tolerated by validator and host_sim', () => {
  const raw = fs.readFileSync(path.join(ADV, 'unknown-keys.timeline.json'), 'utf8');
  assert.deepStrictEqual(validateText(raw), []);
  const { data } = extractTimeline(raw);
  const vis = data.tracks.find((t) => t.kind === 'visibility');
  assert.deepStrictEqual([vis.start_frame, vis.end_frame, vis.visible], [24, 48, false]);
  assert.strictEqual(data.markers[0].kind, 'chapter');
  assert.deepStrictEqual(data.scenes[0].bindings, { ada: 'ada' });
});

test('adversarial (d): whole-float / -0 source emits clean raw bytes', () => {
  const src = fs.readFileSync(path.join(FIXTURES, 'whole-floats.f3d'), 'utf8');
  assert.ok(src.includes('60.0') && src.includes('-0'),
    'fixture source must actually contain whole floats and a -0 producer');
  const { timelinePath } = buildSource(path.join(FIXTURES, 'whole-floats.f3d'), 'wf');
  const raw = fs.readFileSync(timelinePath, 'utf8');
  assert.deepStrictEqual(validateText(raw), [],
    'raw-byte hygiene failures: ' + validateText(raw).join(' | '));
  assert.ok(!raw.includes('"-0'), 'no -0 string/number leak');
});

test('adversarial (e): byte determinism -- Script A built twice, identical sha256', () => {
  const a = buildSource(path.join(FIXTURES, 'saturday-market.f3d'), 'det-a');
  const b = buildSource(path.join(FIXTURES, 'saturday-market.f3d'), 'det-b');
  const hash = (p) => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
  assert.strictEqual(hash(a.timelinePath), hash(b.timelinePath));
  const fixtureHash = crypto.createHash('sha256')
    .update(fs.readFileSync(path.join(FIXTURES, 'saturday-market.timeline.json')))
    .digest('hex');
  assert.strictEqual(hash(a.timelinePath), fixtureHash);
});

/* ------------------------------------------------------------------ */
/* Validator negative tests: every cross-field rule fires             */
/* ------------------------------------------------------------------ */

function mutated(fixture, fn) {
  const doc = JSON.parse(fs.readFileSync(path.join(FIXTURES, fixture), 'utf8'));
  fn(doc);
  return JSON.stringify(doc);
}
function expectFailure(name, raw, needle) {
  test('validator negative: ' + name, () => {
    const failures = validateText(raw);
    assert.ok(failures.some((f) => f.includes(needle)),
      'expected a "' + needle + '" failure, got: ' + (failures.join(' | ') || '(none)'));
  });
}

expectFailure('fps not gcd-reduced',
  mutated('gate-scene.timeline.json', (d) => { d.fps = { den: 2, num: 48 }; }),
  'fps-reduced');
expectFailure('empty dialogue text',
  mutated('gate-scene.timeline.json', (d) => { d.dialogue[0].text = ''; }),
  'dialogue-text');
expectFailure('dialogue end <= start',
  mutated('gate-scene.timeline.json', (d) => { d.dialogue[0].end_frame = d.dialogue[0].start_frame; }),
  'span-positive');
expectFailure('unknown ease spelling',
  mutated('legacy-keys.timeline.json', (d) => { d.tracks[0].keys[1].ease = 'bounce'; }),
  'ease-spelling');
expectFailure('tracks out of sort order',
  mutated('the-lost-key.timeline.json', (d) => { d.tracks.reverse(); }),
  'tracks-sorted');
expectFailure('scene partition gap',
  mutated('the-lost-key.timeline.json', (d) => { d.scenes[1].start_frame = 200; }),
  'scene-partition');
expectFailure('missing required character field',
  mutated('gate-scene.timeline.json', (d) => { delete d.characters[0].plugin; }),
  'missing-field');
expectFailure('unknown track kind in an emitted-style file',
  mutated('gate-scene.timeline.json', (d) => { d.tracks[0].kind = 'hologram'; }),
  'track-kind');
expectFailure('alphabetical key order',
  (() => {
    const doc = JSON.parse(fs.readFileSync(path.join(FIXTURES, 'gate-scene.timeline.json'), 'utf8'));
    const reversed = {};
    for (const k of Object.keys(doc).reverse()) reversed[k] = doc[k];
    return JSON.stringify(reversed);
  })(),
  'key-order');
expectFailure('whole-valued float in raw bytes',
  fs.readFileSync(path.join(FIXTURES, 'legacy-keys.timeline.json'), 'utf8')
    .replace('"scale":2', '"scale":2.0'),
  'whole-float');
expectFailure('negative zero in raw bytes',
  fs.readFileSync(path.join(FIXTURES, 'legacy-keys.timeline.json'), 'utf8')
    .replace('"pos":[0,0,0]', '"pos":[-0,0,0]'),
  'negative-zero');

/* ------------------------------------------------------------------ */
/* Corpus sweep (tests/native/corpus.json, anim section)              */
/* ------------------------------------------------------------------ */

test('corpus sweep: every anim build case validates its emitted IR; stills emit none', () => {
  const corpus = JSON.parse(fs.readFileSync(
    path.join(REPO, 'tests', 'native', 'corpus.json'), 'utf8'));
  const cases = corpus.anim_cases.cases.filter((c) => c.build);
  assert.ok(cases.length > 0, 'no anim build cases found');
  let emitted = 0;
  let stills = 0;
  const problems = [];
  cases.forEach((c, i) => {
    const { timelinePath } = buildInline(c.src, 'scene');
    if (!timelinePath) { stills++; return; }
    emitted++;
    const failures = validateText(fs.readFileSync(timelinePath, 'utf8'));
    if (failures.length) {
      problems.push('anim build case #' + i + ': ' + failures.join(' | '));
    }
  });
  assert.deepStrictEqual(problems, []);
  assert.ok(emitted > 0, 'sweep emitted no timelines at all -- sweep is not exercising the emitter');
  console.log('    corpus sweep: ' + cases.length + ' build cases, ' +
              emitted + ' emitted IR (all valid), ' + stills + ' stills (no IR)');
});

/* ------------------------------------------------------------------ */

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
  console.log(path.basename(__filename) + ': PASS (' + tests.length + ' tests)');
})();
