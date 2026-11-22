// Forge3D WebXR runtime sidecar - OPTIONAL module, load AFTER
// runtime/f3d.js (or standalone: it has no dependencies).
// Exposes window.Forge3DXR: the WebXR surface this engine needs
// (immersive-vr session, reference space, stereo views), behind
// feature detection with graceful degradation: every method
// NEVER throws; failures resolve to false / null / [] and
// shouldFallback() tells the app to use its normal Canvas2D /
// WebGL2 render path instead.
//
// HONESTY / VERIFICATION STATUS: this file is proven HEADLESSLY
// ONLY, with mock navigator.xr / session / frame objects under
// Node (tests/compiler/test_f3d_xr_js.py). A real immersive
// session on XR hardware is UNVERIFIED: this machine has no XR
// device and no browser, so no claim is made that a headset
// session, tracking, or presentation works until a user checks
// it on a real device. Plain script, zero deps, no modules.
'use strict';
(function (g) {
var current = null; // active XRSession, or null

function getXR() {
  try {
    var nav = (typeof navigator !== 'undefined') ? navigator
      : g.navigator;
    return (nav && nav.xr) ? nav.xr : null;
  } catch (e) { return null; }
}

// Correct 4x4 inverse for a column-major matrix (the WebXR /
// DOMMatrix layout: m[c*4 + r] is row r, column c). Gauss-Jordan
// elimination on the augmented matrix with partial pivoting.
// Returns a new Float32Array(16), or null when singular.
function invert4(m) {
  var a = [], r, c, i;
  for (r = 0; r < 4; r++) {
    a[r] = [];
    for (c = 0; c < 4; c++) a[r][c] = m[c * 4 + r];
    for (i = 0; i < 4; i++) a[r][4 + i] = (i === r) ? 1 : 0;
  }
  for (c = 0; c < 4; c++) {
    var piv = c;
    for (r = c + 1; r < 4; r++)
      if (Math.abs(a[r][c]) > Math.abs(a[piv][c])) piv = r;
    if (Math.abs(a[piv][c]) < 1e-12) return null; // singular
    if (piv !== c) { var t = a[piv]; a[piv] = a[c]; a[c] = t; }
    var d = a[c][c];
    for (i = 0; i < 8; i++) a[c][i] /= d;
    for (r = 0; r < 4; r++) {
      if (r === c) continue;
      var f = a[r][c];
      if (f) for (i = 0; i < 8; i++) a[r][i] -= f * a[c][i];
    }
  }
  var out = new Float32Array(16);
  for (r = 0; r < 4; r++)
    for (c = 0; c < 4; c++) out[c * 4 + r] = a[r][4 + c];
  return out;
}

async function isSupported() {
  try {
    var xr = getXR();
    if (!xr || typeof xr.isSessionSupported !== 'function')
      return false;
    return !!(await xr.isSessionSupported('immersive-vr'));
  } catch (e) { return false; }
}

async function requestVRSession(options) {
  try {
    var xr = getXR();
    if (!xr || typeof xr.requestSession !== 'function')
      return null;
    if (!(await isSupported())) return null;
    var opts = {}, k;
    if (options) for (k in options) opts[k] = options[k];
    var feats = ['local-floor', 'bounded-floor'];
    if (opts.optionalFeatures) {
      for (var i = 0; i < opts.optionalFeatures.length; i++)
        if (feats.indexOf(opts.optionalFeatures[i]) < 0)
          feats.push(opts.optionalFeatures[i]);
    }
    opts.optionalFeatures = feats;
    var session = await xr.requestSession('immersive-vr', opts);
    if (!session) return null;
    current = session;
    try {
      if (typeof session.addEventListener === 'function')
        session.addEventListener('end', function () {
          if (current === session) current = null;
        });
    } catch (e) { /* listener is best-effort; state still set */ }
    return session;
  } catch (e) { return null; }
}

async function requestReferenceSpace(session) {
  try {
    if (!session ||
        typeof session.requestReferenceSpace !== 'function')
      return null;
    var types = ['local-floor', 'local', 'viewer'];
    for (var i = 0; i < types.length; i++) {
      try {
        var space = await session.requestReferenceSpace(types[i]);
        if (space) return space;
      } catch (e) { /* try the next type */ }
    }
    return null;
  } catch (e) { return null; }
}

// One entry per view of the viewer pose. viewMatrix approach
// (the ONE approach used here): prefer
// view.transform.inverse.matrix when the platform supplies it;
// otherwise compute the inverse of view.transform.matrix with
// invert4() above. viewport is view.viewport when the view (or
// a mock) carries one, else null -- in a real app the viewport
// comes from XRWebGLLayer.getViewport(view) at present time.
function stereoViews(frame, refSpace) {
  try {
    if (!frame || typeof frame.getViewerPose !== 'function' ||
        !refSpace) return [];
    var pose = frame.getViewerPose(refSpace);
    if (!pose || !pose.views || !pose.views.length) return [];
    var out = [];
    for (var i = 0; i < pose.views.length; i++) {
      var view = pose.views[i];
      if (!view || !view.projectionMatrix || !view.transform)
        continue;
      var vm = null;
      if (view.transform.inverse && view.transform.inverse.matrix)
        vm = new Float32Array(view.transform.inverse.matrix);
      else if (view.transform.matrix)
        vm = invert4(view.transform.matrix);
      if (!vm) continue;
      out.push({
        projectionMatrix: new Float32Array(view.projectionMatrix),
        viewMatrix: vm,
        viewport: view.viewport || null
      });
    }
    return out;
  } catch (e) { return []; }
}

function currentSession() { return current; }

async function endSession() {
  try {
    var session = current;
    current = null;
    if (!session || typeof session.end !== 'function')
      return false;
    await session.end();
    return true;
  } catch (e) { current = null; return false; }
}

function shouldFallback() { return !current; }

g.Forge3DXR = {
  isSupported: isSupported,
  requestVRSession: requestVRSession,
  requestReferenceSpace: requestReferenceSpace,
  stereoViews: stereoViews,
  currentSession: currentSession,
  endSession: endSession,
  shouldFallback: shouldFallback,
  _invert4: invert4
};
if (typeof window !== 'undefined') window.Forge3DXR = g.Forge3DXR;
})(typeof globalThis !== 'undefined' ? globalThis : this);
