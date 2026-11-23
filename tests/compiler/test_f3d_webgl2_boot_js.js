'use strict';
/* Forge3D v2.0 P5-B: tests for the WebGL2-default viewer boot.
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_webgl2_boot_js.js
 *
 * Covers, headlessly (no browser, no real GPU):
 *   1. F3D.worldTris() in runtime/f3d.js returns the expected
 *      world-space triangles (positions + resolved colours +
 *      carried index-5 normals) for a known tiny scene at
 *      t = 0 and at an animated t (spin), using the same
 *      build/animState/xform paths as the Canvas2D player.
 *   2. The viewer boot's pure helpers (window.F3DBoot, extracted
 *      from the live compiler/viewer_template.html boot script):
 *      canUseWebGL2 decision logic, and mvpForCamera -- a known
 *      point projected through the sidecar's projectPoint()
 *      lands where the core player's own projection puts it.
 *   3. File checks: the emit_html Fortran source and the live
 *      viewer template both carry the {{WEBGL2_JS}} slot and
 *      the v2 boot.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }
const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);
const near3 = (a, b, e) => a.length === 3
  && a.every((x, i) => near(x, b[i], e));

// ---- load the core runtime + the WebGL2 sidecar ----
global.window = globalThis;
eval(fs.readFileSync(path.join(REPO, 'runtime', 'f3d.js'), 'utf8'));
eval(fs.readFileSync(path.join(REPO, 'runtime', 'f3d-webgl2.js'),
  'utf8'));
const F3D = globalThis.F3D;
const W = globalThis.Forge3DWebGL2;

// ---- extract + eval the boot script from the live template ----
// document stub: no canvas / no scene, so the boot registers
// F3DBoot and returns without touching any renderer.
global.document = {
  getElementById() { return null; },
  createElement() { return {}; }
};
const templateHtml = fs.readFileSync(
  path.join(REPO, 'compiler', 'viewer_template.html'), 'utf8');
const bootMatch = templateHtml.match(
  /<script>\n(\(function \(\) \{[\s\S]*?F3DBoot[\s\S]*?\}\)\(\);\n)<\/script>/);
assert(bootMatch, 'boot script not found in viewer_template.html');
eval(bootMatch[1]);
const Boot = globalThis.F3DBoot;
delete global.document;

// ----------------------------------------------------------------
test('test_worldtris_exported', () => {
  assert.strictEqual(typeof F3D.worldTris, 'function');
  assert.strictEqual(typeof F3D.create, 'function');
  assert.strictEqual(typeof F3D.auto, 'function');
});

const CUBE_SCENE = {
  objects: [{ prim: 'cube', name: 'cube1', color: 'red',
    pos: [1, 0, 0], size: 2 }],
  camera: { pos: [3, 2.5, 4], target: [0, 0, 0], up: [0, 1, 0],
    fov: 60, near: 0.1, far: 100 }
};

test('test_worldtris_cube_t0', () => {
  const tris = F3D.worldTris(CUBE_SCENE, 0);
  assert.strictEqual(tris.length, 12);
  // First cube face (mesh.f90 winding [0,2,1] over the size-2
  // corners), translated by pos [1,0,0].
  assert(near3(tris[0][0], [0, -1, -1]));
  assert(near3(tris[0][1], [2, 1, -1]));
  assert(near3(tris[0][2], [2, -1, -1]));
  assert.strictEqual(tris[0][3], 0);
  // Colour resolved from the named object colour 'red'.
  assert.deepStrictEqual(tris[0][4], [220, 60, 60]);
  // Flat cube tris carry no index-5 normals element.
  assert.strictEqual(tris[0].length, 5);
});

test('test_worldtris_default_time_is_zero', () => {
  const a = F3D.worldTris(CUBE_SCENE);
  const b = F3D.worldTris(CUBE_SCENE, 0);
  assert.deepStrictEqual(a, b);
});

test('test_worldtris_spin_animated_t', () => {
  const scene = JSON.parse(JSON.stringify(CUBE_SCENE));
  scene.animations = [{ kind: 'spin', axis: 'y', speed: 90,
    duration: 5, ease: 'linear', loop: 'forever',
    target: 'cube1' }];
  const tris = F3D.worldTris(scene, 1);
  // spin forever+linear: rot.y += 90 * t = 90 deg at t = 1.
  // Local [-1,-1,-1] --Ry(90)--> [-1,-1,1], + pos [1,0,0].
  assert(near3(tris[0][0], [0, -1, 1], 1e-9));
  assert(near3(tris[0][1], [0, 1, -1], 1e-9));
  // Local [1,-1,-1] --Ry(90)--> [-1,-1,-1], + pos [1,0,0].
  assert(near3(tris[0][2], [0, -1, -1], 1e-9));
});

test('test_worldtris_smooth_normals_carried', () => {
  const scene = { objects: [{ prim: 'sphere', name: 's',
    radius: 1, segments: 8, pos: [0, 0, 0] }] };
  const tris = F3D.worldTris(scene, 0);
  assert(tris.length > 0);
  assert(Array.isArray(tris[0][5]),
    'sphere tri must carry index-5 normals');
  // Top vertex normal is +Y, unrotated at t = 0.
  assert(near3(tris[0][5][0], [0, 1, 0]));
  // No object colour: non-cube default is white.
  assert.deepStrictEqual(tris[0][4], [255, 255, 255]);
});

test('test_worldtris_legacy_triangles_scene', () => {
  const scene = { triangles: [{ v: [[0, 0, 0], [1, 0, 0],
    [0, 1, 0]], color: [10, 20, 30] }] };
  const tris = F3D.worldTris(scene, 0);
  assert.strictEqual(tris.length, 1);
  assert(near3(tris[0][1], [1, 0, 0]));
  assert.deepStrictEqual(tris[0][4], [10, 20, 30]);
});

// ----------------------------------------------------------------
test('test_boot_decision_logic', () => {
  assert(Boot, 'window.F3DBoot not exposed by the boot script');
  const gl = {};
  const withTris = { worldTris() { return []; } };
  assert.strictEqual(Boot.canUseWebGL2(
    { camera: {} }, gl, withTris), true);
  // A scene declaring controls belongs to the interactive
  // core player.
  assert.strictEqual(Boot.canUseWebGL2(
    { camera: {}, controls: 'orbit' }, gl, withTris), false);
  // No camera -> no WebGL2 fast path.
  assert.strictEqual(Boot.canUseWebGL2({}, gl, withTris), false);
  // Missing sidecar / missing worldTris -> Canvas2D.
  assert.strictEqual(Boot.canUseWebGL2(
    { camera: {} }, null, withTris), false);
  assert.strictEqual(Boot.canUseWebGL2(
    { camera: {} }, gl, {}), false);
  assert.strictEqual(Boot.canUseWebGL2(
    null, gl, withTris), false);
});

// The core player's projection, recomputed independently from
// runtime/f3d.js render(): basis f/r/u from eye/target/up,
// view coords vx/vy/vz, NDC = (vx/(asp*th*cw), vy/(th*cw))
// with cw = -vz and th = tan(fov/2).
function coreProject(cam, aspect, p) {
  const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const norm = (a) => {
    const l = Math.hypot(a[0], a[1], a[2]);
    return [a[0] / l, a[1] / l, a[2] / l];
  };
  const eye = cam.pos, f = norm(sub(cam.target, eye));
  const r = norm(cross(f, cam.up)), u = cross(r, f);
  const rel = sub(p, eye);
  const vx = dot(r, rel), vy = dot(u, rel), vz = -dot(f, rel);
  const th = Math.tan((cam.fov || 60) * Math.PI / 360);
  const cw = Math.max(-vz, cam.near || 0.1);
  return [vx / (aspect * th) / cw, vy / th / cw];
}

test('test_mvp_matches_core_projection', () => {
  const cam = { pos: [3, 2.5, 4], target: [0, 0, 0],
    up: [0, 1, 0], fov: 60, near: 0.1, far: 100 };
  const aspect = 640 / 480;
  const mvp = Boot.mvpForCamera(cam, aspect);
  assert.strictEqual(mvp.length, 16);
  for (const p of [[0, 0, 0], [1, 0.5, -1], [-2, 1, 2],
                   [0.5, -0.5, 0.5]]) {
    const ndc = W.projectPoint(mvp, p);
    const exp = coreProject(cam, aspect, p);
    assert(near(ndc[0], exp[0], 1e-9),
      'ndc x for ' + p + ': ' + ndc[0] + ' vs ' + exp[0]);
    assert(near(ndc[1], exp[1], 1e-9),
      'ndc y for ' + p + ': ' + ndc[1] + ' vs ' + exp[1]);
    assert(ndc[2] > -1 && ndc[2] < 1,
      'ndc z in clip range for ' + p + ': ' + ndc[2]);
  }
});

test('test_mvp_defaults_match_core', () => {
  // No fov/near/far/up/target: boot defaults must be the core
  // player's (fov 60, near 0.1, far 100, up +Y, target origin).
  const mvp = Boot.mvpForCamera({ pos: [0, 0, 5] }, 1);
  const ndc = W.projectPoint(mvp, [0, 0, 0]);
  assert(near(ndc[0], 0) && near(ndc[1], 0));
});

// ----------------------------------------------------------------
test('test_webgl2_slot_wired_in_sources', () => {
  const fort = fs.readFileSync(
    path.join(REPO, 'compiler', 'src', 'f3dc_emit_html.f90'),
    'utf8');
  assert(fort.includes('{{WEBGL2_JS}}'),
    'emit_html missing {{WEBGL2_JS}} slot');
  assert(fort.includes('emit_html_webgl2_js'),
    'emit_html missing the sidecar loader');
  assert(fort.includes('F3DBoot'),
    'builtin template missing the v2 boot');
  assert(templateHtml.includes('{{WEBGL2_JS}}'),
    'viewer_template.html missing {{WEBGL2_JS}} slot');
  assert(templateHtml.includes('Forge3DWebGL2'),
    'viewer_template.html boot does not use the sidecar');
  assert(templateHtml.includes('F3D.create'),
    'viewer_template.html boot lost the Canvas2D fallback');
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
  console.log(path.basename(__filename) + ': PASS (' +
    tests.length + ' tests)');
})();
