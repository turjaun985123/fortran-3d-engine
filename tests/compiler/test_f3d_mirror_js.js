'use strict';
/* Forge3D v2.0 P3-D: JS-runtime tests for the scene-object
 * `mirror: "x"|"y"|"z"` field (runtime/f3d.js core player +
 * runtime/f3d-webgl2.js sidecar).
 *
 * Standalone-runnable:
 *
 *     node tests/compiler/test_f3d_mirror_js.js
 *
 * Core proof is a REAL pixel comparison: a tiny software
 * Canvas2D rasterizer (fillRect + path fill recorded into a
 * pixel buffer) lets F3D.create() render headlessly. Mirror
 * reflects through the object's LOCAL origin (before its
 * pos/rotate), so the flip tests use objects centred on the
 * scene origin: one `tris` object holding an asymmetric
 * cluster of three different spheres. With flat shading its
 * mirror:"x" render must equal the plain render flipped
 * horizontally, pixel for pixel -- and mirror:"y" the
 * vertical flip. The light direction is [0,0,-1] so Lambert
 * shading is itself symmetric under both mirrors; with a
 * tilted light the flipped-shading difference would be the
 * light's, not the mirror's. A rotated-cone test pins the
 * composition order (mirror BEFORE rotation), and a smooth-
 * shaded sphere test covers the index-5 vertex-normals path
 * (tolerance-based: the player's Gouraud subdivision grid
 * re-orients when b/c swap, so smooth pixels can differ by
 * a couple of RGB steps -- the flat path is exact).
 *
 * WebGL2 proof is the mock-GL style of test_f3d_webgl2_js.js:
 * a real GPU needs a browser, so this asserts the uploaded
 * buffers instead -- with opts.mirror the positions and aNorm
 * entries must be reflected and b/c-swapped (negative
 * determinant), and a flat tri's uploaded face normal must
 * keep the unmirrored outward direction.
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const CORE_PATH = path.join(REPO, 'runtime', 'f3d.js');
const GL2_PATH = path.join(REPO, 'runtime', 'f3d-webgl2.js');

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

// ---- software Canvas2D: rasterizes the player's fills ----
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

let F3D = null, W2 = null, loadError = null;
try {
  global.window = globalThis;
  eval(fs.readFileSync(CORE_PATH, 'utf8'));
  F3D = globalThis.F3D;
  eval(fs.readFileSync(GL2_PATH, 'utf8'));
  W2 = globalThis.Forge3DWebGL2;
} catch (e) { loadError = e; }
function need() { if (loadError) throw loadError; }

const W = 96, H = 96;
// Independent sphere soup for the cluster object: lat/long
// grid, outward winding, per-tri colour, no shared code with
// the runtime builders.
function sphereSoup(cx, cy, cz, r, color, seg, rings) {
  const tris = [];
  const pt = (j, i) => {
    const ph = Math.PI * j / rings, th = 2 * Math.PI * i / seg;
    return [cx + r * Math.sin(ph) * Math.cos(th), cy + r * Math.cos(ph),
            cz + r * Math.sin(ph) * Math.sin(th)];
  };
  for (let i = 0; i < seg; i++) {
    tris.push({ v: [pt(0, i), pt(1, (i + 1) % seg), pt(1, i)], color });
    for (let j = 1; j < rings - 1; j++) {
      const a = pt(j, i), b = pt(j, (i + 1) % seg),
        c = pt(j + 1, (i + 1) % seg), d = pt(j + 1, i);
      tris.push({ v: [a, b, c], color }, { v: [a, c, d], color });
    }
    tris.push({ v: [pt(rings, i), pt(rings - 1, i),
                     pt(rings - 1, (i + 1) % seg)], color });
  }
  return tris;
}
function clusterObj(mirror) {
  const tris = [].concat(
    sphereSoup(-1.05, 0, 0, 1, [220, 60, 60], 14, 10),
    sphereSoup(1.25, 0.45, 0, 0.55, [60, 220, 220], 12, 8),
    sphereSoup(0.9, -0.95, 0.3, 0.35, [240, 220, 50], 10, 7));
  const o = { prim: 'tris', triangles: tris, shading: 'flat' };
  if (mirror) o.mirror = mirror;
  return o;
}
function renderObjs(objs) {
  const { canvas, fb } = makeCanvas(W, H);
  F3D.create(canvas, { objects: objs,
    camera: { pos: [0, 0, 7], target: [0, 0, 0], fov: 55 },
    lights: [{ direction: [0, 0, -1] }],
    width: W, height: H, bg: [10, 10, 20] });
  return fb;
}
function renderScene(mirror) { return renderObjs([clusterObj(mirror)]); }
function assertFlip(plain, mir, flipX, label) {
  let diff = 0, first = -1;
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      const sx = flipX ? W - 1 - x : x, sy = flipX ? y : H - 1 - y;
      const a = (y * W + x) * 3, b = (sy * W + sx) * 3;
      if (plain[b] !== mir[a] || plain[b + 1] !== mir[a + 1] ||
          plain[b + 2] !== mir[a + 2]) { diff++; if (first < 0) first = a / 3; }
    }
  assert.strictEqual(diff, 0,
    label + ': ' + diff + ' pixels differ, first at index ' + first);
}

test('test_core_mirror_x_render_is_horizontal_flip', () => {
  need();
  const plain = renderScene(null);
  // The scene must actually draw something asymmetric and lit.
  let nonBg = 0, lit = 0;
  for (let i = 0; i < plain.length; i += 3) {
    if (plain[i] !== 10 || plain[i + 1] !== 10 || plain[i + 2] !== 20) nonBg++;
    if (plain[i] > 150) lit++;
  }
  assert.ok(nonBg > 500, 'scene too empty: ' + nonBg);
  assert.ok(lit > 100, 'scene not lit (winding?): lit=' + lit);
  assertFlip(plain, renderScene('x'), true, 'mirror x');
});

test('test_core_mirror_y_render_is_vertical_flip', () => {
  need();
  assertFlip(renderScene(null), renderScene('y'), false, 'mirror y');
});

test('test_core_mirror_applies_before_rotation', () => {
  need();
  // Mirror is local, BEFORE rotate: mirror-x of a cone
  // rotated +30 about z, flipped horizontally, must equal
  // the plain cone rotated -30 (Mx * Rz(-t) == Rz(t) * Mx).
  const mir = renderObjs([{ prim: 'cone', radius: 0.9, height: 2.4,
    segments: 16, shading: 'flat', rotate: [0, 0, 30], mirror: 'x',
    color: 'orange' }]);
  const plain = renderObjs([{ prim: 'cone', radius: 0.9, height: 2.4,
    segments: 16, shading: 'flat', rotate: [0, 0, -30],
    color: 'orange' }]);
  assertFlip(plain, mir, true, 'mirror-before-rotate');
});

test('test_core_no_mirror_render_is_deterministic', () => {
  need();
  assert.deepStrictEqual(renderScene(null), renderScene(null));
});

test('test_core_smooth_sphere_mirror_in_place_within_tolerance', () => {
  need();
  // A sphere centred on its local origin maps onto itself
  // under mirror x; with the index-5 normals reflected and
  // swapped, the smooth render must match the plain render
  // almost exactly. Exact equality is NOT expected: the
  // player's Gouraud subdivision grid re-orients when b/c
  // swap, shifting sub-triangle centroids by a cell, which
  // moves a few pixels by a couple of RGB steps.
  const base = { prim: 'sphere', radius: 1.5, segments: 12,
    color: 'red' };
  const plain = renderObjs([base]);
  const mir = renderObjs([Object.assign({}, base, { mirror: 'x' })]);
  let diff = 0, maxd = 0;
  for (let i = 0; i < plain.length; i++) {
    const d = Math.abs(plain[i] - mir[i]);
    if (d > 0) { diff++; if (d > maxd) maxd = d; }
  }
  // Measured max delta for this scene: 11 (at the terminator,
  // where the intensity gradient is steepest).
  assert.ok(maxd <= 16, 'smooth mirror max channel delta ' + maxd);
  assert.ok(diff < plain.length * 0.1,
    'smooth mirror differing channels ' + diff);
});

// ---- WebGL2 mock-GL upload checks ----
class MockGL {
  constructor() {
    this.calls = [];
    this.VERTEX_SHADER = 0x8B31; this.FRAGMENT_SHADER = 0x8B30;
    this.COMPILE_STATUS = 0x8B81; this.LINK_STATUS = 0x8B82;
    this.ARRAY_BUFFER = 0x8892; this.STATIC_DRAW = 0x88E4;
    this.FLOAT = 0x1406; this.TRIANGLES = 0x0004;
    this.DEPTH_TEST = 0x0B71; this.COLOR_BUFFER_BIT = 0x4000;
    this.DEPTH_BUFFER_BIT = 0x0100;
  }
  rec(n, a) { this.calls.push({ name: n, args: Array.from(a) }); }
  find(n) { return this.calls.filter(c => c.name === n); }
  createShader(t) { this.rec('createShader', arguments); return { type: t }; }
  shaderSource(s, src) { this.rec('shaderSource', arguments); }
  compileShader(s) { this.rec('compileShader', arguments); }
  getShaderParameter(s, p) { this.rec('getShaderParameter', arguments); return true; }
  createProgram() { this.rec('createProgram', arguments); return { program: true }; }
  attachShader(p, s) { this.rec('attachShader', arguments); }
  linkProgram(p) { this.rec('linkProgram', arguments); }
  getProgramParameter(p, q) { this.rec('getProgramParameter', arguments); return true; }
  createBuffer() { this.rec('createBuffer', arguments); return { buffer: true }; }
  getAttribLocation(p, n) { this.rec('getAttribLocation', arguments); return 0; }
  getUniformLocation(p, n) { this.rec('getUniformLocation', arguments); return { uniform: n }; }
  useProgram(p) { this.rec('useProgram', arguments); }
  enable(c) { this.rec('enable', arguments); }
  clearColor(r, g, b, a) { this.rec('clearColor', arguments); }
  clear(m) { this.rec('clear', arguments); }
  bindBuffer(t, b) { this.rec('bindBuffer', arguments); }
  bufferData(t, d, u) { this.rec('bufferData', arguments); }
  vertexAttribPointer(...a) { this.rec('vertexAttribPointer', a); }
  enableVertexAttribArray(i) { this.rec('enableVertexAttribArray', arguments); }
  uniformMatrix4fv(l, t, d) { this.rec('uniformMatrix4fv', arguments); }
  uniform3f(l, x, y, z) { this.rec('uniform3f', arguments); }
  uniform1f(l, v) { this.rec('uniform1f', arguments); }
  drawArrays(m, f, c) { this.rec('drawArrays', arguments); }
}
const IDENT = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
function upload(tris, opts) {
  const gl = new MockGL();
  const canvas = { getContext: k => (k === 'webgl2' ? gl : null) };
  const r = W2.create(canvas);
  gl.calls.length = 0;
  assert.strictEqual(W2.renderScene(r, tris, IDENT, opts), 1);
  const bd = gl.find('bufferData');
  assert.strictEqual(bd.length, 3);
  // v + 0 normalises -0 (a reflected zero) to 0 for comparison.
  return { pos: Array.from(bd[0].args[1]).map(v => v + 0),
           nor: Array.from(bd[2].args[1]).map(v => v + 0) };
}
const TRI_N = [[[0, 0, 0], [2, 0, 0], [0, 1, 0], 0, [200, 100, 50],
                [[1, 0, 0], [0, 1, 0], [0, 0, 1]]]];

test('test_webgl2_no_mirror_upload_unchanged', () => {
  need();
  const u = upload(TRI_N, undefined);
  assert.deepStrictEqual(u.pos, [0, 0, 0, 2, 0, 0, 0, 1, 0]);
  assert.deepStrictEqual(u.nor, [1, 0, 0, 0, 1, 0, 0, 0, 1]);
});

test('test_webgl2_mirror_x_reflects_and_swaps_b_c', () => {
  need();
  const u = upload(TRI_N, { mirror: 'x' });
  // Vertices reflected in x, order b/c swapped: [a, c', b'].
  assert.deepStrictEqual(u.pos, [0, 0, 0, 0, 1, 0, -2, 0, 0]);
  // aNorm entries reflected and swapped the same way:
  // [na', nc', nb'] = [(-1,0,0), (0,0,1), (0,1,0)].
  assert.deepStrictEqual(u.nor, [-1, 0, 0, 0, 0, 1, 0, 1, 0]);
});

test('test_webgl2_mirror_flat_tri_face_normal_stays_outward', () => {
  need();
  // No index-5 normals: the face normal of the mirrored,
  // winding-swapped tri must still be +z, as unmirrored.
  const flat = [[[0, 0, 0], [2, 0, 0], [0, 1, 0], 0, [200, 100, 50]]];
  const u = upload(flat, { mirror: 'x' });
  assert.deepStrictEqual(u.pos, [0, 0, 0, 0, 1, 0, -2, 0, 0]);
  assert.deepStrictEqual(u.nor, [0, 0, 1, 0, 0, 1, 0, 0, 1]);
});

test('test_webgl2_mirror_two_axes_no_winding_swap', () => {
  need();
  // Two reflections: determinant positive, order kept,
  // both axes negated.
  const u = upload(TRI_N, { mirror: ['x', 'y'] });
  assert.deepStrictEqual(u.pos, [0, 0, 0, -2, 0, 0, 0, -1, 0]);
  assert.deepStrictEqual(u.nor, [-1, 0, 0, 0, -1, 0, 0, 0, 1]);
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
