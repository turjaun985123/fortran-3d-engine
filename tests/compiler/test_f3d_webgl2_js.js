'use strict';
/* Port of test_f3d_webgl2_js.py (Forge3D Wave E seat E08) to
 * plain Node.js: tests for the WebGL2 sidecar
 * runtime/f3d-webgl2.js (window.Forge3DWebGL2).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_webgl2_js.js
 *
 * The file checks always run. The behavioural checks load the
 * sidecar in-process against a MOCK WebGL2 context object which
 * records every GL call (the Python original shelled out to
 * `node -e` snippets doing the same).
 *
 * The mock is the headless proof: real GPU rasterization
 * requires a browser, so no test here claims pixel output --
 * only that the sidecar issues the exact shader sources, buffer
 * uploads, uniform upload and draw call a real WebGL2 context
 * would need, and that projectPoint() matches JS-computed
 * expectations under the Fortran mat4 convention (column-major
 * flat layout, element (row, col) at m[col*4 + row], perspective
 * divide when |w| > 1e-12, mirroring mat4_transform_vec3 in
 * src/math_3d.f90) to within 1e-9.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const JS_PATH = path.join(REPO, 'runtime', 'f3d-webgl2.js');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// The Python PREAMBLE: expose `window`, bind the export as `W`,
// and define a recording mock WebGL2 context + canvas.
let W = null;
let loadError = null;
try {
  global.window = globalThis;
  eval(fs.readFileSync(JS_PATH, 'utf8'));
  W = globalThis.Forge3DWebGL2;
} catch (e) { loadError = e; }
function needW() {
  if (loadError) throw loadError;
  return W;
}
const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);
const near3 = (a, b, e) => a.length === 3
  && a.every((x, i) => near(x, b[i], e));
class MockGL {
  constructor(opts) { opts = opts || {};
    this.calls = [];
    this.compileOk = opts.compileOk !== false;
    this.linkOk = opts.linkOk !== false;
    this.VERTEX_SHADER = 0x8B31; this.FRAGMENT_SHADER = 0x8B30;
    this.COMPILE_STATUS = 0x8B81; this.LINK_STATUS = 0x8B82;
    this.ARRAY_BUFFER = 0x8892; this.STATIC_DRAW = 0x88E4;
    this.FLOAT = 0x1406; this.TRIANGLES = 0x0004;
    this.DEPTH_TEST = 0x0B71; this.COLOR_BUFFER_BIT = 0x4000;
    this.DEPTH_BUFFER_BIT = 0x0100; }
  rec(name, args) { this.calls.push({ name: name,
    args: Array.from(args) }); }
  find(name) { return this.calls.filter(c => c.name === name); }
  createShader(t) { this.rec('createShader', arguments);
    return { shader: true, type: t }; }
  shaderSource(s, src) { this.rec('shaderSource', arguments); }
  compileShader(s) { this.rec('compileShader', arguments); }
  getShaderParameter(s, p) { this.rec('getShaderParameter',
    arguments); return this.compileOk; }
  createProgram() { this.rec('createProgram', arguments);
    return { program: true }; }
  attachShader(p, s) { this.rec('attachShader', arguments); }
  linkProgram(p) { this.rec('linkProgram', arguments); }
  getProgramParameter(p, q) { this.rec('getProgramParameter',
    arguments); return this.linkOk; }
  createBuffer() { this.rec('createBuffer', arguments);
    return { buffer: true, id: this.calls.length }; }
  getAttribLocation(p, n) { this.rec('getAttribLocation',
    arguments); return n === 'aPos' ? 0 : n === 'aColor' ? 1 : 2; }
  getUniformLocation(p, n) { this.rec('getUniformLocation',
    arguments); return { uniform: n }; }
  useProgram(p) { this.rec('useProgram', arguments); }
  enable(c) { this.rec('enable', arguments); }
  clearColor(r, g, b, a) { this.rec('clearColor', arguments); }
  clear(m) { this.rec('clear', arguments); }
  bindBuffer(t, b) { this.rec('bindBuffer', arguments); }
  bufferData(t, d, u) { this.rec('bufferData', arguments); }
  vertexAttribPointer(...a) { this.rec('vertexAttribPointer', a); }
  enableVertexAttribArray(i) {
    this.rec('enableVertexAttribArray', arguments); }
  uniformMatrix4fv(l, t, d) {
    this.rec('uniformMatrix4fv', arguments); }
  uniform3f(l, x, y, z) { this.rec('uniform3f', arguments); }
  uniform1f(l, v) { this.rec('uniform1f', arguments); }
  drawArrays(m, f, c) { this.rec('drawArrays', arguments); }
}
function makeCanvas(glOrFn) {
  return { getContext(kind) {
    if (typeof glOrFn === 'function') return glOrFn(kind);
    return kind === 'webgl2' ? glOrFn : null; } }; }
// Two triangles in the f3d.js build() element shape:
// [[a, b, c, faceIdx, [r, g, b] 0..255], ...]
const TRIS = [
  [[0, 0, 0], [1, 0, 0], [0, 1, 0], 0, [255, 0, 0]],
  [[0, 0, 1], [1, 0, 1], [0, 1, 1], 1, [0, 128, 255]]];
const IDENT = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

function fortranTransform(mFlatColMajor, p) {
  // mat4_transform_vec3 (is_point=true) on a flat column-major
  // matrix, computed in JS as the independent expectation.
  const m = mFlatColMajor;
  const [x, y, z] = p;
  let rx = m[0] * x + m[4] * y + m[8] * z + m[12];
  let ry = m[1] * x + m[5] * y + m[9] * z + m[13];
  let rz = m[2] * x + m[6] * y + m[10] * z + m[14];
  const w = m[3] * x + m[7] * y + m[11] * z + m[15];
  if (Math.abs(w) > 1e-12) {
    rx /= w; ry /= w; rz /= w;
  }
  return [rx, ry, rz];
}

function norm(v) {
  const length = Math.hypot(v[0], v[1], v[2]);
  if (length > 1e-12) return v.map(x => x / length);
  return [0.0, 0.0, 0.0];
}

function lambertIntensity(verts, lightDir, ambient) {
  // JS mirror of runtime/f3d.js Lambert shading.
  //
  // f3d.js: ld = norm(lightDir) (default [-0.5, -1, -0.7]),
  // n = norm(cross(w1 - w0, w2 - w0)) over the triangle's
  // positions, inten = 0.25 + 0.75 * max(0, -dot(n, ld)) --
  // i.e. ambient + (1 - ambient) * max(0, dot(n, -ld)) with
  // ambient 0.25 by default.
  if (lightDir === undefined) lightDir = [-0.5, -1.0, -0.7];
  if (ambient === undefined) ambient = 0.25;
  const [w0, w1, w2] = verts;
  const e1 = [0, 1, 2].map(i => w1[i] - w0[i]);
  const e2 = [0, 1, 2].map(i => w2[i] - w0[i]);
  const cross = [
    e1[1] * e2[2] - e1[2] * e2[1],
    e1[2] * e2[0] - e1[0] * e2[2],
    e1[0] * e2[1] - e1[1] * e2[0],
  ];
  const n = norm(cross);
  const ld = norm([...lightDir]);
  const diffuse = Math.max(0.0,
    -[0, 1, 2].reduce((sum, i) => sum + n[i] * ld[i], 0));
  return ambient + (1.0 - ambient) * diffuse;
}

function shadedColour(baseRgb0255, intensity) {
  // Base colour (0..255) -> uploaded 0..1 shaded channel values.
  return baseRgb0255.map(c => c / 255.0 * intensity);
}

test('test_file_exists_and_states_browser_requirement', () => {
  assert.ok(fs.existsSync(JS_PATH) && fs.statSync(JS_PATH).isFile(),
            JS_PATH);
  const text = fs.readFileSync(JS_PATH, 'utf8');
  // The header must state plainly that real GPU
  // rasterization requires a browser and that headless
  // verification is mock-GL + math parity.
  assert.ok(text.includes('real GPU rasterization'));
  assert.ok(text.includes('requires a browser'));
  assert.ok(text.includes('mock-GL'));
});

test('test_exports_and_shader_sources', () => {
  needW();
  for (const k of ['isAvailable', 'create', 'renderScene',
                   'projectPoint', 'attach'])
    assert.strictEqual(typeof W[k], 'function',
      'missing export ' + k);
  assert.strictEqual(window.Forge3DWebGL2, W);
  assert.strictEqual(typeof W.VERT_SRC, 'string');
  assert.strictEqual(typeof W.FRAG_SRC, 'string');
  assert.strictEqual(W.VERT_SRC.split('\n')[0],
    '#version 300 es');
  assert.strictEqual(W.FRAG_SRC.split('\n')[0],
    '#version 300 es');
  for (const s of ['in vec3 aPos;', 'in vec3 aColor;',
    'uniform mat4 uMVP;', 'out vec3 vColor;',
    'gl_Position = uMVP * vec4(aPos, 1.0);'])
    assert.ok(W.VERT_SRC.includes(s), 'VERT_SRC: ' + s);
  for (const s of ['precision mediump float;',
    'in vec3 vColor;', 'out vec4 outColor;'])
    assert.ok(W.FRAG_SRC.includes(s), 'FRAG_SRC: ' + s);
});

test('test_is_available_false_on_null_and_throw', () => {
  needW();
  assert.strictEqual(W.isAvailable(makeCanvas(null)), false);
  assert.strictEqual(W.isAvailable(makeCanvas(() => {
    throw new Error('no gl'); })), false);
  assert.strictEqual(W.isAvailable({}), false);
  assert.strictEqual(W.isAvailable(null), false);
  const gl = new MockGL();
  assert.strictEqual(W.isAvailable(makeCanvas(gl)), true);
});

test('test_create_compiles_links_and_makes_buffers', () => {
  needW();
  const gl = new MockGL();
  const r = W.create(makeCanvas(gl));
  assert.ok(r, 'create must return a renderer');
  assert.strictEqual(r.gl, gl);
  assert.ok(r.program);
  assert.ok(r.buffers.position && r.buffers.color
    && r.buffers.normal);
  // Shaders compiled with the exact exported sources.
  const srcs = gl.find('shaderSource');
  assert.strictEqual(srcs.length, 2);
  assert.strictEqual(srcs[0].args[1], W.VERT_SRC);
  assert.strictEqual(srcs[1].args[1], W.FRAG_SRC);
  assert.ok(srcs[0].args[1].startsWith('#version 300 es'));
  assert.strictEqual(gl.find('createShader').length, 2);
  assert.strictEqual(gl.find('compileShader').length, 2);
  assert.strictEqual(gl.find('attachShader').length, 2);
  assert.strictEqual(gl.find('linkProgram').length, 1);
  assert.strictEqual(gl.find('createBuffer').length, 3);
  const attrs = gl.find('getAttribLocation')
    .map(c => c.args[1]);
  assert.deepStrictEqual(attrs, ['aPos', 'aColor', 'aNorm']);
  const uniforms = gl.find('getUniformLocation')
    .map(c => c.args[1]);
  assert.deepStrictEqual(uniforms,
    ['uMVP', 'uLight', 'uAmbient']);
});

test('test_create_null_on_unavailable_compile_and_link_failure', () => {
  needW();
  assert.strictEqual(W.create(makeCanvas(null)), null);
  assert.strictEqual(W.create(makeCanvas(() => {
    throw new Error('x'); })), null);
  assert.strictEqual(W.create(null), null);
  assert.strictEqual(W.create(makeCanvas(
    new MockGL({ compileOk: false }))), null);
  assert.strictEqual(W.create(makeCanvas(
    new MockGL({ linkOk: false }))), null);
});

test('test_render_scene_gl_calls', () => {
  needW();
  // Both TRIS share the (0,0,0),(1,0,0),(0,1,0)
  // orientation. Since P1 the colour buffer holds the
  // UNSHADED base colours (shading moved into the vertex
  // shader), and the third buffer holds each tri's face
  // normal (0,0,1) for all three vertices (flat payload),
  // so the shader reproduces the old Lambert result.
  const exp0 = [1, 0, 0];
  const exp1 = [0, 128 / 255, 1];
  const gl = new MockGL();
  const r = W.create(makeCanvas(gl));
  gl.calls.length = 0;
  const n = W.renderScene(r, TRIS, IDENT);
  assert.strictEqual(n, 2);
  // DEPTH_TEST enabled, cleared.
  const en = gl.find('enable');
  assert.strictEqual(en.length, 1);
  assert.strictEqual(en[0].args[0], gl.DEPTH_TEST);
  assert.strictEqual(gl.find('clear').length, 1);
  assert.strictEqual(gl.find('clear')[0].args[0],
    gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  // Default clear colour = f3d.js bg [25,25,35] / 255.
  const cc = gl.find('clearColor')[0].args;
  assert.ok(near(cc[0], 25 / 255) && near(cc[1], 25 / 255)
    && near(cc[2], 35 / 255) && near(cc[3], 1),
    'clearColor=' + cc);
  // bufferData: positions, colours and normals, each
  // tris*9 (colours in 0..1).
  const bd = gl.find('bufferData');
  assert.strictEqual(bd.length, 3);
  assert.ok(bd[0].args[1] instanceof Float32Array);
  assert.ok(bd[1].args[1] instanceof Float32Array);
  assert.ok(bd[2].args[1] instanceof Float32Array);
  assert.strictEqual(bd[0].args[1].length, TRIS.length * 9);
  assert.strictEqual(bd[1].args[1].length, TRIS.length * 9);
  assert.strictEqual(bd[2].args[1].length, TRIS.length * 9);
  assert.deepStrictEqual(Array.from(bd[0].args[1]),
    [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1]);
  const cols = Array.from(bd[1].args[1]);
  assert.ok(cols.every(v => v >= 0 && v <= 1),
    'colours out of 0..1: ' + cols);
  // 1e-6 here: colours pass through a Float32Array, so
  // the values are only float32-exact.
  assert.ok(near3(cols.slice(0, 3), exp0, 1e-6),
    'tri0 unshaded colour=' + cols.slice(0, 3));
  assert.ok(near3(cols.slice(9, 12), exp1, 1e-6),
    'tri1 unshaded colour=' + cols.slice(9, 12));
  // Normals buffer: both tris are flat payloads facing
  // +Z, so every vertex normal is the face normal (0,0,1).
  const nors = Array.from(bd[2].args[1]);
  for (let k = 0; k < TRIS.length * 3; k++)
    assert.ok(near3(nors.slice(k * 3, k * 3 + 3), [0, 0, 1],
      1e-6), 'vertex ' + k + ' normal=' + nors.slice(k * 3,
      k * 3 + 3));
  // Light uniforms for the shader Lambert: uLight is the
  // normalised default light direction, uAmbient 0.25.
  const u3 = gl.find('uniform3f');
  assert.strictEqual(u3.length, 1);
  assert.strictEqual(u3[0].args[0].uniform, 'uLight');
  const expLd = norm([-0.5, -1.0, -0.7]);
  assert.ok(near3(Array.from(u3[0].args.slice(1)), expLd,
    1e-6), 'uLight=' + u3[0].args.slice(1));
  const u1 = gl.find('uniform1f');
  assert.strictEqual(u1.length, 1);
  assert.strictEqual(u1[0].args[0].uniform, 'uAmbient');
  assert.ok(near(u1[0].args[1], 0.25), 'uAmbient='
    + u1[0].args[1]);
  // MVP uniform: 16 elements, untransposed.
  const um = gl.find('uniformMatrix4fv');
  assert.strictEqual(um.length, 1);
  assert.strictEqual(um[0].args[1], false);
  assert.strictEqual(um[0].args[2].length, 16);
  assert.deepStrictEqual(Array.from(um[0].args[2]), IDENT);
  // Draw call covers every vertex.
  const da = gl.find('drawArrays');
  assert.strictEqual(da.length, 1);
  assert.strictEqual(da[0].args[0], gl.TRIANGLES);
  assert.strictEqual(da[0].args[1], 0);
  assert.strictEqual(da[0].args[2], TRIS.length * 3);
});

test('test_render_scene_flat_and_object_payloads', () => {
  needW();
  // Since P1 the colour buffer holds the UNSHADED base
  // colour (shading moved into the vertex shader): green
  // [0,255,0] uploads as exactly (0,1,0). The normals
  // buffer holds the tri's face normal (0,0,1) for all
  // three vertices (flat payload), so the shader
  // reproduces the old Lambert result for this
  // front-facing tri.
  // Flat soup (raycast form) and scene-object triangles
  // upload the same counts as the f3d.js build() shape.
  const gl = new MockGL();
  const r = W.create(makeCanvas(gl));
  gl.calls.length = 0;
  assert.strictEqual(W.renderScene(r,
    [0, 0, 0, 1, 0, 0, 0, 1, 0], IDENT), 1);
  let bd = gl.find('bufferData');
  assert.strictEqual(bd[0].args[1].length, 9);
  assert.strictEqual(bd[1].args[1].length, 9);
  assert.strictEqual(bd[2].args[1].length, 9);
  assert.strictEqual(gl.find('drawArrays')[0].args[2], 3);
  gl.calls.length = 0;
  assert.strictEqual(W.renderScene(r,
    [{v: [[0, 0, 0], [1, 0, 0], [0, 1, 0]], color: [0, 255, 0]}],
    IDENT), 1);
  bd = gl.find('bufferData');
  assert.ok(near3(Array.from(bd[1].args[1]).slice(0, 3),
    [0, 1, 0], 1e-6),
    'object payload unshaded colour='
    + Array.from(bd[1].args[1]).slice(0, 3));
  const objNors = Array.from(bd[2].args[1]);
  for (let k = 0; k < 3; k++)
    assert.ok(near3(objNors.slice(k * 3, k * 3 + 3),
      [0, 0, 1], 1e-6),
      'object payload vertex ' + k + ' normal='
      + objNors.slice(k * 3, k * 3 + 3));
  assert.strictEqual(W.renderScene(null, TRIS, IDENT), 0);
  assert.strictEqual(W.renderScene(r, [], IDENT), 0);
});

test('test_render_scene_uses_renderer_clear_color', () => {
  needW();
  const gl = new MockGL();
  const r = W.create(makeCanvas(gl));
  r.clearColor = [255, 0, 0];
  gl.calls.length = 0;
  W.renderScene(r, TRIS, IDENT);
  const cc = gl.find('clearColor')[0].args;
  assert.ok(near(cc[0], 1) && near(cc[1], 0)
    && near(cc[2], 0) && near(cc[3], 1),
    'clearColor=' + cc);
});

function checkProjectPoint(m, p) {
  needW();
  const exp = fortranTransform(m, p);
  const got = W.projectPoint(m, p);
  assert.ok(near3(got, exp, 1e-9),
    'got=' + got + ' expected=' + exp);
}

test('test_identity', () => {
  const ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  checkProjectPoint(ident, [1.5, -2.25, 3.75]);
  checkProjectPoint(ident, [0, 0, 0]);
});

test('test_translation', () => {
  // Column-major: translation at indices 12, 13, 14.
  const m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 20, 30, 1];
  checkProjectPoint(m, [1, 2, 3]);
  checkProjectPoint(m, [-10, -20, -30]);
});

test('test_perspective_divide', () => {
  // Fortran mat4_perspective(fov=90deg, aspect=1, near=1,
  // far=10): (1,1)=(2,2)=1, (3,3)=-11/9, (3,4)=-20/9,
  // (4,3)=-1 -- flattened column-major below.
  const m = [1, 0, 0, 0,
             0, 1, 0, 0,
             0, 0, -11.0 / 9.0, -1,
             0, 0, -20.0 / 9.0, 0];
  checkProjectPoint(m, [1, 2, -5]);   // w = 5, z/w = 7/9
  checkProjectPoint(m, [0, 0, -1]);   // near plane -> z = -1
  checkProjectPoint(m, [0, 0, -10]);  // far plane -> z = +1
});

// Front-facing: normal (0,0,1) from this winding.
const FRONT = [[0, 0, 0], [1, 0, 0], [0, 1, 0]];
// Back-facing: reversed winding, normal (0,0,-1).
const BACK = [[0, 0, 0], [0, 1, 0], [1, 0, 0]];

function colourCheck(tris, opts, base, expectedNormal,
                     expectedIntensity) {
  needW();
  // A mock GL cannot run GLSL, so verify the INPUTS to
  // the vertex shader instead of shaded output colours:
  // the colour buffer (UNSHADED base colour / 255), the
  // normals buffer (the tri's face normal at every
  // vertex, flat payload), and the uLight / uAmbient
  // uniforms. Feeding the recorded normal and uniforms
  // through the shader's Lambert formula must reproduce
  // expectedIntensity (the old CPU Lambert result).
  const gl = new MockGL();
  const r = W.create(makeCanvas(gl));
  gl.calls.length = 0;
  assert.strictEqual(W.renderScene(r, tris, IDENT, opts), 1);
  const bd = gl.find('bufferData');
  assert.strictEqual(bd.length, 3);
  const cols = Array.from(bd[1].args[1]);
  const nors = Array.from(bd[2].args[1]);
  const expBase = base.map(c => c / 255.0);
  for (let k = 0; k < 3; k++) {
    assert.ok(near3(cols.slice(k * 3, k * 3 + 3),
      expBase, 1e-6),
      'vertex ' + k + ' unshaded colour='
      + cols.slice(k * 3, k * 3 + 3)
      + ' expected=' + expBase);
    assert.ok(near3(nors.slice(k * 3, k * 3 + 3),
      expectedNormal, 1e-6),
      'vertex ' + k + ' normal='
      + nors.slice(k * 3, k * 3 + 3)
      + ' expected=' + expectedNormal);
  }
  // uLight: the normalised light direction (default
  // [-0.5,-1,-0.7], or opts.lightDir when given).
  const u3 = gl.find('uniform3f');
  assert.strictEqual(u3.length, 1);
  assert.strictEqual(u3[0].args[0].uniform, 'uLight');
  const ld = Array.from(u3[0].args.slice(1));
  const expLd = norm((opts && opts.lightDir)
    || [-0.5, -1.0, -0.7]);
  assert.ok(near3(ld, expLd, 1e-6), 'uLight=' + ld);
  // uAmbient: opts.ambient or the 0.25 default.
  const u1 = gl.find('uniform1f');
  assert.strictEqual(u1.length, 1);
  assert.strictEqual(u1[0].args[0].uniform, 'uAmbient');
  const ambient = u1[0].args[1];
  assert.ok(near(ambient, (opts && opts.ambient != null)
    ? opts.ambient : 0.25), 'uAmbient=' + ambient);
  // The shader formula on the recorded inputs:
  // intensity = ambient + (1 - ambient) * max(0, -dot(n, ld)).
  // Front-facing n gives full diffuse (intensity ==
  // expectedIntensity > ambient); back-facing n clamps
  // diffuse to 0, giving exactly ambient.
  const diffuse = Math.max(0,
    -[0, 1, 2].reduce((s, i) => s + expectedNormal[i]
      * ld[i], 0));
  const inten = ambient + (1 - ambient) * diffuse;
  assert.ok(near(inten, expectedIntensity, 1e-6),
    'shader-input intensity=' + inten
    + ' expected=' + expectedIntensity);
  // And intensity * base colour is the old shaded colour.
  const shaded = shadedColour(base, inten);
  const expShaded = shadedColour(base, expectedIntensity);
  assert.ok(near3(shaded, expShaded, 1e-6),
    'reconstructed shaded colour=' + shaded
    + ' expected=' + expShaded);
}

test('test_front_facing_tri_matches_python_lambert', () => {
  // (Named for the Python original: the Lambert expectation
  // is lambertIntensity above, translated from Python.)
  const base = [200, 100, 50];
  const inten = lambertIntensity(FRONT);
  // This orientation really does face the light.
  assert.ok(inten > 0.25);
  assert.ok(inten < 1.0);
  const tris = [[[0, 0, 0], [1, 0, 0], [0, 1, 0], 0, base]];
  // Face normal (0,0,1): the shader inputs must reproduce
  // the full-diffuse Lambert intensity.
  colourCheck(tris, undefined, base, [0, 0, 1], inten);
});

test('test_back_facing_tri_gets_exactly_ambient_times_colour', () => {
  const base = [200, 100, 50];
  const inten = lambertIntensity(BACK);
  // Diffuse clamps to 0, so intensity is exactly ambient.
  assert.strictEqual(inten, 0.25);
  const tris = [[[0, 0, 0], [0, 1, 0], [1, 0, 0], 0, base]];
  // Face normal (0,0,-1): with the recorded uLight the
  // diffuse term clamps to 0, so the shader intensity is
  // exactly the uAmbient value (ambient-only shading).
  colourCheck(tris, undefined, base, [0, 0, -1], 0.25);
  // A custom ambient is honoured the same way.
  colourCheck(tris, {ambient: 0.5}, base, [0, 0, -1],
    lambertIntensity(BACK, undefined, 0.5));
});

test('test_flat_true_reproduces_raw_colour_over_255', () => {
  needW();
  // The TRIS under flat:true upload exactly the
  // pre-Lambert (E08) values: raw colour / 255.
  const gl = new MockGL();
  const r = W.create(makeCanvas(gl));
  gl.calls.length = 0;
  assert.strictEqual(W.renderScene(r, TRIS, IDENT,
    {flat: true}), 2);
  const cols = Array.from(
    gl.find('bufferData')[1].args[1]);
  assert.ok(near3(cols.slice(0, 3), [1, 0, 0], 1e-6),
    'flat tri0 colour=' + cols.slice(0, 3));
  assert.ok(near3(cols.slice(9, 12),
    [0, 128 / 255, 1], 1e-6),
    'flat tri1 colour=' + cols.slice(9, 12));
  // attach() passes opts through: flat via attach too.
  const gl2 = new MockGL();
  assert.strictEqual(W.attach(makeCanvas(gl2), TRIS,
    IDENT, {flat: true}), 'webgl2');
  const cols2 = Array.from(
    gl2.find('bufferData')[1].args[1]);
  assert.ok(near3(cols2.slice(0, 3), [1, 0, 0], 1e-6),
    'attach flat tri0 colour=' + cols2.slice(0, 3));
});

test('test_attach_reports_backend', () => {
  needW();
  assert.strictEqual(W.attach(makeCanvas(null),
    TRIS, IDENT), 'canvas2d');
  assert.strictEqual(W.attach(makeCanvas(() => {
    throw new Error('x'); }), TRIS, IDENT), 'canvas2d');
  const gl = new MockGL();
  assert.strictEqual(W.attach(makeCanvas(gl),
    TRIS, IDENT), 'webgl2');
  assert.strictEqual(gl.find('drawArrays').length, 1);
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
