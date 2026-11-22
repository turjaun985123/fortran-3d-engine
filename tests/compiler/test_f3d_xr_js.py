"""Forge3D Wave E seat E09: tests for the WebXR runtime sidecar
``runtime/f3d-xr.js`` (window.Forge3DXR: immersive-vr session,
reference-space fallback, stereo views, graceful degradation).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_xr_js.py

The size/existence checks always run. The behavioural checks
shell out to ``node -e`` snippets that load the sidecar with a
MOCK ``navigator.xr`` / session / frame; when ``node`` is not on
PATH they are SKIPPED LOUDLY via ``skipUnless``.

HONESTY: everything here is verified HEADLESSLY with mocks only.
A real immersive session on XR hardware remains UNVERIFIED --
this machine has no XR device and no browser; that check needs
a user device.
"""

import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-xr.js")
MAX_BYTES = 8192
NODE = shutil.which("node")

# Loaded before every snippet: expose `window`, bind the export
# as `X`, provide setNav() (Node's global navigator is replaced
# via defineProperty, which is the reliable route on Node 24),
# a mock-session factory, and a column-major matrix multiply.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_XR, 'utf8'));"
    "const X = globalThis.Forge3DXR;"
    "const assert = require('assert');"
    "function setNav(v) { Object.defineProperty(globalThis,"
    "  'navigator', {value: v, configurable: true,"
    "  writable: true}); }"
    "function makeSession(refImpl) {"
    "  const listeners = {};"
    "  return { ended: false,"
    "    addEventListener(t, f) {"
    "      (listeners[t] = listeners[t] || []).push(f); },"
    "    fire(t) { (listeners[t] || []).forEach(f => f({})); },"
    "    async end() { this.ended = true; this.fire('end'); },"
    "    requestReferenceSpace: refImpl ||"
    "      (async t => ({type: t})) }; }"
    "function mul(a, b) { const o = new Array(16).fill(0);"
    "  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++)"
    "    for (let k = 0; k < 4; k++)"
    "      o[c*4+r] += a[k*4+r] * b[c*4+k]; return o; }"
    "const IDENT = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];"
)


def run_node(snippet, is_async=False):
    """Run one node -e snippet against the sidecar; fail on error."""
    if is_async:
        snippet = (
            "(async () => {" + snippet + "})().catch(e => {"
            "console.error(e && e.stack || e); process.exit(1); });"
        )
    env = dict(os.environ, F3D_XR=JS_PATH)
    proc = subprocess.run(
        [NODE, "-e", PREAMBLE + snippet],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(
            "node snippet failed (rc=%d):\n%s\n%s"
            % (proc.returncode, proc.stdout, proc.stderr)
        )
    return proc


class TestF3DXRFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-xr.js is %d B, budget is %d B" % (size, MAX_BYTES),
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-xr.js tests not run"
)
class TestF3DXRMocked(unittest.TestCase):
    def test_exports(self):
        run_node(
            "for (const k of ['isSupported','requestVRSession',"
            "  'requestReferenceSpace','stereoViews',"
            "  'currentSession','endSession','shouldFallback'])"
            "  assert.strictEqual(typeof X[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.Forge3DXR, X);"
        )

    def test_1_no_navigator_xr_graceful(self):
        run_node(
            "setNav({});"  # navigator present, xr undefined
            "assert.strictEqual(await X.isSupported(), false);"
            "assert.strictEqual(await X.requestVRSession(), null);"
            "assert.strictEqual(X.shouldFallback(), true);"
            "assert.strictEqual(X.currentSession(), null);"
            "assert.strictEqual("
            "  await X.requestReferenceSpace(null), null);"
            "assert.deepStrictEqual(X.stereoViews(null, null), []);"
            "assert.strictEqual(await X.endSession(), false);",
            is_async=True,
        )

    def test_2_unsupported_or_throwing_xr_graceful(self):
        run_node(
            "let reqCalls = 0;"
            "setNav({xr: {"
            "  isSessionSupported: async () => false,"
            "  requestSession: async () => { reqCalls++; }}});"
            "assert.strictEqual(await X.isSupported(), false);"
            "assert.strictEqual(await X.requestVRSession(), null);"
            "assert.strictEqual(reqCalls, 0,"
            "  'requestSession must not be called when unsupported');"
            "assert.strictEqual(X.shouldFallback(), true);"
            # An isSessionSupported that throws also degrades.
            "setNav({xr: {isSessionSupported: async () => {"
            "  throw new Error('boom'); }}});"
            "assert.strictEqual(await X.isSupported(), false);"
            "assert.strictEqual(await X.requestVRSession(), null);",
            is_async=True,
        )

    def test_3_supported_mock_session(self):
        run_node(
            "const sess = makeSession();"
            "let gotMode = null, gotOpts = null;"
            "setNav({xr: {"
            "  isSessionSupported: async m => m === 'immersive-vr',"
            "  requestSession: async (m, o) => {"
            "    gotMode = m; gotOpts = o; return sess; }}});"
            "assert.strictEqual(await X.isSupported(), true);"
            "const s = await X.requestVRSession({"
            "  optionalFeatures: ['hand-tracking'],"
            "  requiredFeatures: []});"
            "assert.strictEqual(s, sess);"
            "assert.strictEqual(gotMode, 'immersive-vr');"
            "assert.ok(gotOpts.optionalFeatures.includes("
            "  'local-floor'), JSON.stringify(gotOpts));"
            "assert.ok(gotOpts.optionalFeatures.includes("
            "  'bounded-floor'));"
            "assert.ok(gotOpts.optionalFeatures.includes("
            "  'hand-tracking'), 'caller options must merge');"
            "assert.deepStrictEqual(gotOpts.requiredFeatures, []);"
            "assert.strictEqual(X.currentSession(), sess);"
            "assert.strictEqual(X.shouldFallback(), false);",
            is_async=True,
        )

    def test_4_reference_space_fallback_order(self):
        run_node(
            "const attempts = [];"
            "const sess = makeSession(async t => {"
            "  attempts.push(t);"
            "  if (t === 'local') return {type: 'local'};"
            "  throw new Error('no ' + t); });"
            "const sp = await X.requestReferenceSpace(sess);"
            "assert.ok(sp && sp.type === 'local',"
            "  'space=' + JSON.stringify(sp));"
            "assert.deepStrictEqual(attempts,"
            "  ['local-floor', 'local']);"
            "const attempts2 = [];"
            "const sess2 = makeSession(async t => {"
            "  attempts2.push(t); throw new Error('no'); });"
            "assert.strictEqual("
            "  await X.requestReferenceSpace(sess2), null);"
            "assert.deepStrictEqual(attempts2,"
            "  ['local-floor', 'local', 'viewer']);"
            "assert.strictEqual("
            "  await X.requestReferenceSpace(null), null);",
            is_async=True,
        )

    def test_5_stereo_views_two_and_empty(self):
        run_node(
            # View 0: NO transform.inverse -> invert4() fallback.
            # Its transform is translation (2,3,4), column-major,
            # so the view matrix must be translation (-2,-3,-4).
            # View 1: transform.inverse supplied -> used verbatim.
            "const proj = new Float32Array(IDENT);"
            "const v0 = { projectionMatrix: proj,"
            "  transform: { matrix: new Float32Array(["
            "    1,0,0,0, 0,1,0,0, 0,0,1,0, 2,3,4,1]) },"
            "  viewport: {x: 0, y: 0, width: 100, height: 100} };"
            "const inv1 = new Float32Array(["
            "  1,0,0,0, 0,1,0,0, 0,0,1,0, -5,0,0,1]);"
            "const v1 = { projectionMatrix: proj,"
            "  transform: { matrix: new Float32Array(IDENT),"
            "    inverse: { matrix: inv1 } },"
            "  viewport: {x: 100, y: 0, width: 100, height: 100} };"
            "const ref = {type: 'local'};"
            "const frame = { getViewerPose: rs => {"
            "  assert.strictEqual(rs, ref);"
            "  return {views: [v0, v1]}; } };"
            "const out = X.stereoViews(frame, ref);"
            "assert.strictEqual(out.length, 2);"
            "for (const e of out) {"
            "  assert.ok(e.projectionMatrix instanceof"
            "    Float32Array);"
            "  assert.strictEqual(e.projectionMatrix.length, 16);"
            "  assert.ok(e.viewMatrix instanceof Float32Array);"
            "  assert.strictEqual(e.viewMatrix.length, 16); }"
            "assert.deepStrictEqual("
            "  Array.from(out[0].viewMatrix),"
            "  [1,0,0,0, 0,1,0,0, 0,0,1,0, -2,-3,-4,1]);"
            "assert.deepStrictEqual("
            "  Array.from(out[1].viewMatrix), Array.from(inv1));"
            "assert.strictEqual(out[0].viewport.width, 100);"
            "assert.strictEqual(out[1].viewport.x, 100);"
            "assert.deepStrictEqual(X.stereoViews("
            "  {getViewerPose: () => ({views: []})}, ref), []);"
            "assert.deepStrictEqual(X.stereoViews("
            "  {getViewerPose: () => null}, ref), []);"
            "assert.deepStrictEqual(X.stereoViews(null, ref), []);"
            "assert.deepStrictEqual(X.stereoViews(frame, null), []);"
        )

    def test_invert4_is_a_true_inverse(self):
        run_node(
            # Rotation about Z by 30 deg + translation (5,-2,7),
            # column-major: m * invert4(m) == identity (1e-5,
            # Float32 rounding).
            "const c = Math.cos(Math.PI/6), s = Math.sin(Math.PI/6);"
            "const m = new Float32Array(["
            "  c,s,0,0, -s,c,0,0, 0,0,1,0, 5,-2,7,1]);"
            "const inv = X._invert4(m);"
            "assert.ok(inv, 'expected an inverse');"
            "const prod = mul(Array.from(m), Array.from(inv));"
            "for (let i = 0; i < 16; i++)"
            "  assert.ok(Math.abs(prod[i] - IDENT[i]) < 1e-5,"
            "    'prod[' + i + ']=' + prod[i]);"
            "assert.strictEqual(X._invert4(new Float32Array(16)),"
            "  null, 'singular matrix must return null');"
        )

    def test_6_end_session_and_end_event_clear_state(self):
        run_node(
            "const sess = makeSession();"
            "setNav({xr: {"
            "  isSessionSupported: async () => true,"
            "  requestSession: async () => sess }});"
            "await X.requestVRSession();"
            "assert.strictEqual(X.currentSession(), sess);"
            "assert.strictEqual(await X.endSession(), true);"
            "assert.strictEqual(sess.ended, true);"
            "assert.strictEqual(X.currentSession(), null);"
            "assert.strictEqual(X.shouldFallback(), true);"
            "assert.strictEqual(await X.endSession(), false,"
            "  'second endSession has nothing to end');"
            # The session's own 'end' event also clears state.
            "const sess2 = makeSession();"
            "setNav({xr: {"
            "  isSessionSupported: async () => true,"
            "  requestSession: async () => sess2 }});"
            "await X.requestVRSession();"
            "assert.strictEqual(X.currentSession(), sess2);"
            "sess2.fire('end');"
            "assert.strictEqual(X.currentSession(), null);"
            "assert.strictEqual(X.shouldFallback(), true);",
            is_async=True,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
