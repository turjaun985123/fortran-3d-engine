'use strict';
/* Port of test_f3d_xr_js.py (Forge3D Wave E seat E09) to plain
 * Node.js: tests for the WebXR runtime sidecar runtime/f3d-xr.js
 * (window.Forge3DXR: immersive-vr session, reference-space
 * fallback, stereo views, graceful degradation).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_xr_js.js
 *
 * The size/existence checks always run. The behavioural checks
 * load the sidecar in-process with a MOCK navigator.xr /
 * session / frame (the Python original shelled out to `node -e`
 * snippets doing the same, wrapping async snippets in an async
 * IIFE; here the test functions themselves are async).
 *
 * HONESTY: everything here is verified HEADLESSLY with mocks
 * only. A real immersive session on XR hardware remains
 * UNVERIFIED -- this machine has no XR device and no browser;
 * that check needs a user device.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-xr.js');
const MAX_BYTES = 8192;

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window`, bind the export as `X`,
// provide setNav() (Node's global navigator is replaced via
// defineProperty, which is the reliable route on Node 24), a
// mock-session factory, and a column-major matrix multiply.
let X = null;
let loadError = null;
try {
  global.window = globalThis;
  require(JS_PATH);
  X = globalThis.Forge3DXR;
} catch (e) { loadError = e; }
function needX() {
  if (loadError) throw loadError;
  return X;
}
function setNav(v) { Object.defineProperty(globalThis,
  'navigator', {value: v, configurable: true,
  writable: true}); }
function makeSession(refImpl) {
  const listeners = {};
  return { ended: false,
    addEventListener(t, f) {
      (listeners[t] = listeners[t] || []).push(f); },
    fire(t) { (listeners[t] || []).forEach(f => f({})); },
    async end() { this.ended = true; this.fire('end'); },
    requestReferenceSpace: refImpl ||
      (async t => ({type: t})) }; }
function mul(a, b) { const o = new Array(16).fill(0);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++)
    for (let k = 0; k < 4; k++)
      o[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k]; return o; }
const IDENT = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

test('test_file_exists_and_within_size_budget', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  const size = fs.statSync(JS_PATH).size;
  assert.ok(size <= MAX_BYTES,
            `f3d-xr.js is ${size} B, budget is ${MAX_BYTES} B`);
});

test('test_exports', () => {
  needX();
  for (const k of ['isSupported', 'requestVRSession',
                   'requestReferenceSpace', 'stereoViews',
                   'currentSession', 'endSession', 'shouldFallback'])
    assert.strictEqual(typeof X[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.Forge3DXR, X);
});

test('test_1_no_navigator_xr_graceful', async () => {
  needX();
  setNav({});  // navigator present, xr undefined
  assert.strictEqual(await X.isSupported(), false);
  assert.strictEqual(await X.requestVRSession(), null);
  assert.strictEqual(X.shouldFallback(), true);
  assert.strictEqual(X.currentSession(), null);
  assert.strictEqual(
    await X.requestReferenceSpace(null), null);
  assert.deepStrictEqual(X.stereoViews(null, null), []);
  assert.strictEqual(await X.endSession(), false);
});

test('test_2_unsupported_or_throwing_xr_graceful', async () => {
  needX();
  let reqCalls = 0;
  setNav({xr: {
    isSessionSupported: async () => false,
    requestSession: async () => { reqCalls++; }}});
  assert.strictEqual(await X.isSupported(), false);
  assert.strictEqual(await X.requestVRSession(), null);
  assert.strictEqual(reqCalls, 0,
    'requestSession must not be called when unsupported');
  assert.strictEqual(X.shouldFallback(), true);
  // An isSessionSupported that throws also degrades.
  setNav({xr: {isSessionSupported: async () => {
    throw new Error('boom'); }}});
  assert.strictEqual(await X.isSupported(), false);
  assert.strictEqual(await X.requestVRSession(), null);
});

test('test_3_supported_mock_session', async () => {
  needX();
  const sess = makeSession();
  let gotMode = null, gotOpts = null;
  setNav({xr: {
    isSessionSupported: async m => m === 'immersive-vr',
    requestSession: async (m, o) => {
      gotMode = m; gotOpts = o; return sess; }}});
  assert.strictEqual(await X.isSupported(), true);
  const s = await X.requestVRSession({
    optionalFeatures: ['hand-tracking'],
    requiredFeatures: []});
  assert.strictEqual(s, sess);
  assert.strictEqual(gotMode, 'immersive-vr');
  assert.ok(gotOpts.optionalFeatures.includes(
    'local-floor'), JSON.stringify(gotOpts));
  assert.ok(gotOpts.optionalFeatures.includes(
    'bounded-floor'));
  assert.ok(gotOpts.optionalFeatures.includes(
    'hand-tracking'), 'caller options must merge');
  assert.deepStrictEqual(gotOpts.requiredFeatures, []);
  assert.strictEqual(X.currentSession(), sess);
  assert.strictEqual(X.shouldFallback(), false);
});

test('test_4_reference_space_fallback_order', async () => {
  needX();
  const attempts = [];
  const sess = makeSession(async t => {
    attempts.push(t);
    if (t === 'local') return {type: 'local'};
    throw new Error('no ' + t); });
  const sp = await X.requestReferenceSpace(sess);
  assert.ok(sp && sp.type === 'local',
    'space=' + JSON.stringify(sp));
  assert.deepStrictEqual(attempts,
    ['local-floor', 'local']);
  const attempts2 = [];
  const sess2 = makeSession(async t => {
    attempts2.push(t); throw new Error('no'); });
  assert.strictEqual(
    await X.requestReferenceSpace(sess2), null);
  assert.deepStrictEqual(attempts2,
    ['local-floor', 'local', 'viewer']);
  assert.strictEqual(
    await X.requestReferenceSpace(null), null);
});

test('test_5_stereo_views_two_and_empty', () => {
  needX();
  // View 0: NO transform.inverse -> invert4() fallback.
  // Its transform is translation (2,3,4), column-major,
  // so the view matrix must be translation (-2,-3,-4).
  // View 1: transform.inverse supplied -> used verbatim.
  const proj = new Float32Array(IDENT);
  const v0 = { projectionMatrix: proj,
    transform: { matrix: new Float32Array([
      1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2, 3, 4, 1]) },
    viewport: {x: 0, y: 0, width: 100, height: 100} };
  const inv1 = new Float32Array([
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -5, 0, 0, 1]);
  const v1 = { projectionMatrix: proj,
    transform: { matrix: new Float32Array(IDENT),
      inverse: { matrix: inv1 } },
    viewport: {x: 100, y: 0, width: 100, height: 100} };
  const ref = {type: 'local'};
  const frame = { getViewerPose: rs => {
    assert.strictEqual(rs, ref);
    return {views: [v0, v1]}; } };
  const out = X.stereoViews(frame, ref);
  assert.strictEqual(out.length, 2);
  for (const e of out) {
    assert.ok(e.projectionMatrix instanceof
      Float32Array);
    assert.strictEqual(e.projectionMatrix.length, 16);
    assert.ok(e.viewMatrix instanceof Float32Array);
    assert.strictEqual(e.viewMatrix.length, 16); }
  assert.deepStrictEqual(
    Array.from(out[0].viewMatrix),
    [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -2, -3, -4, 1]);
  assert.deepStrictEqual(
    Array.from(out[1].viewMatrix), Array.from(inv1));
  assert.strictEqual(out[0].viewport.width, 100);
  assert.strictEqual(out[1].viewport.x, 100);
  assert.deepStrictEqual(X.stereoViews(
    {getViewerPose: () => ({views: []})}, ref), []);
  assert.deepStrictEqual(X.stereoViews(
    {getViewerPose: () => null}, ref), []);
  assert.deepStrictEqual(X.stereoViews(null, ref), []);
  assert.deepStrictEqual(X.stereoViews(frame, null), []);
});

test('test_invert4_is_a_true_inverse', () => {
  needX();
  // Rotation about Z by 30 deg + translation (5,-2,7),
  // column-major: m * invert4(m) == identity (1e-5,
  // Float32 rounding).
  const c = Math.cos(Math.PI / 6), s = Math.sin(Math.PI / 6);
  const m = new Float32Array([
    c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 5, -2, 7, 1]);
  const inv = X._invert4(m);
  assert.ok(inv, 'expected an inverse');
  const prod = mul(Array.from(m), Array.from(inv));
  for (let i = 0; i < 16; i++)
    assert.ok(Math.abs(prod[i] - IDENT[i]) < 1e-5,
      'prod[' + i + ']=' + prod[i]);
  assert.strictEqual(X._invert4(new Float32Array(16)),
    null, 'singular matrix must return null');
});

test('test_6_end_session_and_end_event_clear_state', async () => {
  needX();
  const sess = makeSession();
  setNav({xr: {
    isSessionSupported: async () => true,
    requestSession: async () => sess }});
  await X.requestVRSession();
  assert.strictEqual(X.currentSession(), sess);
  assert.strictEqual(await X.endSession(), true);
  assert.strictEqual(sess.ended, true);
  assert.strictEqual(X.currentSession(), null);
  assert.strictEqual(X.shouldFallback(), true);
  assert.strictEqual(await X.endSession(), false,
    'second endSession has nothing to end');
  // The session's own 'end' event also clears state.
  const sess2 = makeSession();
  setNav({xr: {
    isSessionSupported: async () => true,
    requestSession: async () => sess2 }});
  await X.requestVRSession();
  assert.strictEqual(X.currentSession(), sess2);
  sess2.fire('end');
  assert.strictEqual(X.currentSession(), null);
  assert.strictEqual(X.shouldFallback(), true);
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
