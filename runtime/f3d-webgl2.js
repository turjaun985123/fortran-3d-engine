// Forge3D WebGL2 sidecar - OPTIONAL module, load AFTER
// runtime/f3d.js (or standalone: it has no dependencies).
// GPU rasterisation path for the same scene triangles the
// Canvas2D core (runtime/f3d.js) draws with the painter's
// algorithm. This sidecar replaces painter sorting with a real
// depth buffer (DEPTH_TEST). Shading here is the same Lambert
// as the core runtime (see shadeIntensity() below, mirroring
// f3d.js): intensity = ambient + (1 - ambient) * diffuse with
// ambient 0.25 by default, diffuse = max(0, -dot(normal,
// normalize(lightDir))) and lightDir [-0.5, -1, -0.7] by
// default. Since P1 the intensity is computed PER-VERTEX in
// the vertex shader from the aNorm attribute and the uLight /
// uAmbient uniforms, and interpolated (Gouraud): a triangle
// carrying the index-5 per-vertex normals element shades
// smoothly, while a triangle without one uploads its face
// normal -- norm(cross(v1 - v0, v2 - v0)) over the triangle's
// positions -- for all three vertices, reproducing the old
// flat Lambert colours. Colours are uploaded UNshaded (base
// colour / 255); the fragment shader outputs the interpolated
// intensity times the colour. Pass opts.flat = true to
// renderScene() / attach() to force intensity 1 (the raw base
// colours), and opts.shading = 'flat' to force face normals
// even for triangles that carry vertex normals.
//
// HONEST VERIFICATION STATEMENT: real GPU rasterization
// requires a browser. This sidecar is verified headlessly via
// mock-GL call verification + transform math parity (see
// tests/compiler/test_f3d_webgl2_js.py): the tests substitute a
// recording mock WebGL2 context and assert every GL call, and
// projectPoint() is checked against Fortran-convention
// expectations. No real GPU, framebuffer, or pixel output is
// exercised by the headless tests.
//
// Triangle payload -- the exact element shape runtime/f3d.js
// consumes / produces. f3d.js build() yields per-object tris as
//   [[a, b, c, faceIdx, colour?], ...]
// where a/b/c are [x, y, z] vertices and colour (index 4, when
// present) is [r, g, b] with components in 0..255 (the same
// range f3d.js color() returns). renderScene() accepts that
// shape, plus these equivalent forms, all documented here:
//   - flat soup: [x1,y1,z1, x2,y2,z2, x3,y3,z3, ...]
//     (the flat form runtime/f3d-raycast.js cast() consumes;
//     colour defaults to white)
//   - per-tri flat: [[x1,y1,z1, ..., x3,y3,z3, colour?], ...]
//     where colour is an optional [r, g, b] (0..255) as the
//     10th element, or r, g, b as elements 9, 10, 11
//   - scene triangles: [{v: [a, b, c], color: [r, g, b]}, ...]
//     (also verts/vertices for v, colour for color), the
//     legacy v1 / prim:'tris' element shape of f3d.js scenes
// Colours are uploaded normalised to 0..1 (value / 255),
// multiplied by the Lambert intensity above unless flat.
//
// Matrix convention: mvp is a flat 16-element array in
// COLUMN-MAJOR order -- element (row, col) of the Fortran
// mat4 m(4,4) (src/math_3d.f90) lives at mvp[col*4 + row], so
// the translation sits at indices 12, 13, 14 and a point
// transforms exactly as mat4_transform_vec3 computes it:
//   x' = m[0]*x + m[4]*y + m[8]*z  + m[12]
//   y' = m[1]*x + m[5]*y + m[9]*z  + m[13]
//   z' = m[2]*x + m[6]*y + m[10]*z + m[14]
//   w  = m[3]*x + m[7]*y + m[11]*z + m[15]
// This is the order WebGL expects, so renderScene() passes the
// array to uniformMatrix4fv(loc, false, ...) untransposed.
// Plain script, zero deps, no modules.
'use strict';
(function (g) {
var VERT_SRC = [
  '#version 300 es',
  'in vec3 aPos;',
  'in vec3 aColor;',
  'in vec3 aNorm;',
  'uniform mat4 uMVP;',
  'uniform vec3 uLight;',
  'uniform float uAmbient;',
  'out vec3 vColor;',
  'out float vI;',
  'void main() {',
  '  vColor = aColor;',
  '  vI = uAmbient + (1.0 - uAmbient) * max(0.0, -dot(normalize(aNorm), uLight));',
  '  gl_Position = uMVP * vec4(aPos, 1.0);',
  '}'
].join('\n');
var FRAG_SRC = [
  '#version 300 es',
  'precision mediump float;',
  'in vec3 vColor;',
  'in float vI;',
  'out vec4 outColor;',
  'void main() {',
  '  outColor = vec4(vColor * vI, 1.0);',
  '}'
].join('\n');
var IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
// f3d.js scene background default: color(scene.bg, [25,25,35]).
var DEFAULT_CLEAR = [25, 25, 35];

function isAvailable(canvas) {
  try {
    var c = canvas;
    if (!c) {
      if (typeof document === 'undefined' || !document.createElement)
        return false;
      c = document.createElement('canvas');
    }
    if (!c.getContext) return false;
    return !!c.getContext('webgl2');
  } catch (e) {
    return false;
  }
}

function create(canvas) {
  try {
    if (!canvas || !canvas.getContext) return null;
    var gl = canvas.getContext('webgl2');
    if (!gl) return null;
    function shader(type, src) {
      var s = gl.createShader(type);
      if (!s) return null;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) return null;
      return s;
    }
    var vs = shader(gl.VERTEX_SHADER, VERT_SRC);
    if (!vs) return null;
    var fs = shader(gl.FRAGMENT_SHADER, FRAG_SRC);
    if (!fs) return null;
    var program = gl.createProgram();
    if (!program) return null;
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
    var posBuf = gl.createBuffer();
    var colBuf = gl.createBuffer();
    var norBuf = gl.createBuffer();
    if (!posBuf || !colBuf || !norBuf) return null;
    return {
      canvas: canvas,
      gl: gl,
      program: program,
      buffers: { position: posBuf, color: colBuf, normal: norBuf },
      aPos: gl.getAttribLocation(program, 'aPos'),
      aColor: gl.getAttribLocation(program, 'aColor'),
      aNorm: gl.getAttribLocation(program, 'aNorm'),
      uMVP: gl.getUniformLocation(program, 'uMVP'),
      uLight: gl.getUniformLocation(program, 'uLight'),
      uAmbient: gl.getUniformLocation(program, 'uAmbient'),
      // Scene background, [r, g, b] 0..255 (alpha optional 4th,
      // 0..1 or 0..255); callers may replace it before render.
      clearColor: DEFAULT_CLEAR.slice()
    };
  } catch (e) {
    return null;
  }
}

// ---- Lambert shading, mirroring runtime/f3d.js exactly ----
// f3d.js: ld = norm(v3(L.direction || L.dir, [-0.5, -1, -0.7]));
// per face n = norm(cross(sub(w1, w0), sub(w2, w0))) over the
// (world) vertex positions, and the intensity is
//   inten = 0.25 + 0.75 * Math.max(0, -dot(n, ld))
// (for material 'lambert'; 'basic' is unshaded there -- here
// opts.flat = true is the equivalent opt-out). The helpers
// below copy f3d.js's sub/cross/dot/norm, including norm's
// 1e-12 zero guard.
var DEFAULT_LIGHT_DIR = [-0.5, -1, -0.7];
var DEFAULT_AMBIENT = 0.25;
function vsub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
function vcross(a, b) {
  return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
          a[0] * b[1] - a[1] * b[0]];
}
function vdot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
function vnorm(a) {
  var l = Math.hypot(a[0], a[1], a[2]);
  return l > 1e-12 ? [a[0] / l, a[1] / l, a[2] / l] : [0, 0, 0];
}
function vclean(v) { return [+v[0] || 0, +v[1] || 0, +v[2] || 0]; }
// Resolve renderScene() opts into a shading descriptor:
// { flat: boolean, ld: normalized lightDir, ambient: number,
//   flatNorm: boolean }. flatNorm (opts.shading === 'flat')
// forces per-face normals even when a tri carries the index-5
// per-vertex normals element (the P1 smooth-shading contract:
// explicit object shading wins). The intensity itself is now
// computed per-vertex in the vertex shader from aNorm and the
// uLight / uAmbient uniforms; shadeIntensity() below is kept
// as the CPU reference of the same formula.
function resolveShade(opts) {
  var o = opts || {};
  var ambient = o.ambient != null ? +o.ambient : DEFAULT_AMBIENT;
  if (!(ambient >= 0)) ambient = DEFAULT_AMBIENT;
  var ld = DEFAULT_LIGHT_DIR;
  if (o.lightDir && o.lightDir.length === 3) ld = vclean(o.lightDir);
  return { flat: !!o.flat, ld: vnorm(ld), ambient: ambient,
           flatNorm: o.shading === 'flat' };
}
function shadeIntensity(verts, shade) {
  if (shade.flat) return 1;
  var w0 = vclean(verts[0]), w1 = vclean(verts[1]),
    w2 = vclean(verts[2]);
  var n = vnorm(vcross(vsub(w1, w0), vsub(w2, w0)));
  var diffuse = Math.max(0, -vdot(n, shade.ld));
  return shade.ambient + (1 - shade.ambient) * diffuse;
}

// Normalise the accepted triangle shapes (see header) into
// {positions, colors, normals: Float32Array, count} with count
// triangles, each array length count*9: positions, per-vertex
// base colors in 0..1 (UNSHADED -- the vertex shader applies
// the Lambert intensity), and per-vertex normals. A tri's
// index-5 normals element ([na, nb, nc], local space) is used
// verbatim unless shade.flatNorm forces face normals; tris
// without normals get their face normal (computed exactly as
// shadeIntensity does) uploaded for all three vertices, which
// reproduces the old flat Lambert result through the shader.
//
// Mirror (P3): opts.mirror is 'x' | 'y' | 'z' (or an array of
// axes) and mirrors the CORE runtime's treatment of a scene
// object's mirror field: vertices and index-5 normals are
// reflected across the named axis through the local origin
// here, in the upload path, i.e. in local space before the
// caller's MVP applies the object transform. A single-axis
// reflection has negative determinant, so vertex order b/c --
// and the normals entries likewise -- are swapped (an even
// number of axes swaps back), keeping face normals, aNorm
// shading and winding at the unmirrored outward convention.
// Callers whose tris already came from the core build() (which
// bakes mirror itself) must NOT pass opts.mirror again.
function parseMirror(mirror) {
  if (!mirror) return [];
  var list = Array.isArray(mirror) ? mirror : [mirror];
  var axes = [];
  for (var k = 0; k < list.length; k++) {
    var ax = 'xyz'.indexOf(String(list[k]).toLowerCase());
    if (ax >= 0) axes.push(ax);
  }
  return axes;
}
function normalizeTris(tris, shade, mirrorAxes) {
  var pos = [], col = [], nor = [], i, j;
  shade = shade || resolveShade(null);
  var mAxes = mirrorAxes || [];
  function pushVert(v) {
    pos.push(+v[0] || 0, +v[1] || 0, +v[2] || 0);
  }
  function faceNormal(verts) {
    var w0 = vclean(verts[0]), w1 = vclean(verts[1]),
      w2 = vclean(verts[2]);
    return vnorm(vcross(vsub(w1, w0), vsub(w2, w0)));
  }
  function pushTri(verts, color, normals) {
    if (mAxes.length) {
      var refl = function (v) {
        var w = vclean(v);
        for (var k = 0; k < mAxes.length; k++) w[mAxes[k]] = -w[mAxes[k]];
        return w;
      };
      verts = verts.map(refl);
      if (normals && normals.length === 3) normals = normals.map(refl);
      if (mAxes.length % 2 === 1) { // negative determinant
        verts = [verts[0], verts[2], verts[1]];
        if (normals && normals.length === 3)
          normals = [normals[0], normals[2], normals[1]];
      }
    }
    var c = color || [255, 255, 255];
    var r = Math.min(255, Math.max(0, +c[0] || 0)) / 255;
    var gg = Math.min(255, Math.max(0, +c[1] || 0)) / 255;
    var b = Math.min(255, Math.max(0, +c[2] || 0)) / 255;
    var useN = normals && normals.length === 3 && !shade.flatNorm;
    var fn = useN ? null : faceNormal(verts);
    for (j = 0; j < 3; j++) {
      pushVert(verts[j]); col.push(r, gg, b);
      var nv = useN ? vclean(normals[j]) : fn;
      nor.push(nv[0], nv[1], nv[2]);
    }
  }
  if (!tris) return null;
  if (typeof tris[0] === 'number') { // flat soup
    for (i = 0; i + 9 <= tris.length; i += 9)
      pushTri([[tris[i], tris[i + 1], tris[i + 2]],
               [tris[i + 3], tris[i + 4], tris[i + 5]],
               [tris[i + 6], tris[i + 7], tris[i + 8]]], null);
  } else {
    for (i = 0; i < tris.length; i++) {
      var t = tris[i];
      if (!t) continue;
      if (typeof t[0] === 'number') { // per-tri flat, 9+ numbers
        var color = null;
        if (Array.isArray(t[9])) color = t[9];
        else if (t.length >= 12) color = [t[9], t[10], t[11]];
        pushTri([[t[0], t[1], t[2]], [t[3], t[4], t[5]],
                 [t[6], t[7], t[8]]], color);
      } else if (Array.isArray(t[0])) { // f3d.js build() shape
        pushTri([t[0], t[1], t[2]], t[4], t[5]);
      } else { // scene triangle object {v|verts|vertices, color}
        var vs = t.v || t.verts || t.vertices;
        if (vs && vs.length === 3)
          pushTri(vs, t.color || t.colour, t.normals);
      }
    }
  }
  return { positions: new Float32Array(pos),
           colors: new Float32Array(col),
           normals: new Float32Array(nor),
           count: pos.length / 9 };
}

function clearRGBA(renderer) {
  var c = renderer.clearColor || DEFAULT_CLEAR;
  function ch(v, dflt) {
    if (v == null) return dflt;
    v = +v || 0;
    return v > 1 ? v / 255 : v;
  }
  return [ch(c[0], 25 / 255), ch(c[1], 25 / 255), ch(c[2], 35 / 255),
          c.length > 3 ? ch(c[3], 1) : 1];
}

// renderScene(renderer, tris, mvp, opts?) -> number of
// triangles drawn (0 when the renderer / payload is unusable;
// never throws). opts: { lightDir = [-0.5, -1, -0.7],
// ambient = 0.25, flat = false, mirror = 'x'|'y'|'z' } --
// see the Lambert note above and the Mirror note at
// normalizeTris().
function renderScene(renderer, tris, mvp, opts) {
  try {
    if (!renderer || !renderer.gl || !renderer.program) return 0;
    var shade = resolveShade(opts);
    var data = normalizeTris(tris, shade,
      parseMirror(opts && opts.mirror));
    if (!data || data.count === 0) return 0;
    var gl = renderer.gl;
    gl.useProgram(renderer.program);
    gl.enable(gl.DEPTH_TEST);
    var cc = clearRGBA(renderer);
    gl.clearColor(cc[0], cc[1], cc[2], cc[3]);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffers.position);
    gl.bufferData(gl.ARRAY_BUFFER, data.positions, gl.STATIC_DRAW);
    gl.vertexAttribPointer(renderer.aPos, 3, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(renderer.aPos);
    gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffers.color);
    gl.bufferData(gl.ARRAY_BUFFER, data.colors, gl.STATIC_DRAW);
    gl.vertexAttribPointer(renderer.aColor, 3, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(renderer.aColor);
    gl.bindBuffer(gl.ARRAY_BUFFER, renderer.buffers.normal);
    gl.bufferData(gl.ARRAY_BUFFER, data.normals, gl.STATIC_DRAW);
    gl.vertexAttribPointer(renderer.aNorm, 3, gl.FLOAT, false, 0, 0);
    gl.enableVertexAttribArray(renderer.aNorm);
    var m = (mvp && mvp.length === 16) ? mvp : IDENTITY;
    gl.uniformMatrix4fv(renderer.uMVP, false, new Float32Array(m));
    // Light uniforms for the shader Lambert: flat opts out by
    // pinning ambient to 1 (intensity is then exactly 1).
    // Guarded so recording mock GLs without uniform3f /
    // uniform1f still exercise the rest of the call sequence.
    if (gl.uniform3f) gl.uniform3f(renderer.uLight,
      shade.ld[0], shade.ld[1], shade.ld[2]);
    if (gl.uniform1f) gl.uniform1f(renderer.uAmbient,
      shade.flat ? 1 : shade.ambient);
    gl.drawArrays(gl.TRIANGLES, 0, data.count * 3);
    return data.count;
  } catch (e) {
    return 0;
  }
}

// projectPoint(mvp, p) -> [x, y, z] after perspective divide,
// mirroring mat4_transform_vec3(m, p, is_point=true) in
// src/math_3d.f90 under the column-major convention above:
// the divide happens only when |w| > 1e-12, as in Fortran.
function projectPoint(mvp, p) {
  var m = (mvp && mvp.length === 16) ? mvp : IDENTITY;
  var x = p[0], y = p[1], z = p[2];
  var rx = m[0] * x + m[4] * y + m[8] * z + m[12];
  var ry = m[1] * x + m[5] * y + m[9] * z + m[13];
  var rz = m[2] * x + m[6] * y + m[10] * z + m[14];
  var w = m[3] * x + m[7] * y + m[11] * z + m[15];
  if (Math.abs(w) > 1e-12) { rx /= w; ry /= w; rz /= w; }
  return [rx, ry, rz];
}

// attach(canvas, tris, mvp, opts?) -> 'webgl2' when create() +
// renderScene() succeeded, else 'canvas2d'. opts is passed
// through to renderScene() (Lambert lightDir / ambient / flat).
// attach() itself only reports: on 'canvas2d' the caller falls
// back to the Canvas2D core runtime (runtime/f3d.js), which
// owns fallback drawing; attach() does not draw anything in
// 2D itself. opts is passed through to renderScene()
// (Lambert lightDir / ambient / flat, mirror).
function attach(canvas, tris, mvp, opts) {
  try {
    var renderer = create(canvas);
    if (!renderer) return 'canvas2d';
    return renderScene(renderer, tris, mvp, opts) > 0
      ? 'webgl2' : 'canvas2d';
  } catch (e) {
    return 'canvas2d';
  }
}

g.Forge3DWebGL2 = { VERT_SRC: VERT_SRC, FRAG_SRC: FRAG_SRC,
  isAvailable: isAvailable, create: create,
  renderScene: renderScene, projectPoint: projectPoint,
  attach: attach };
if (typeof window !== 'undefined') window.Forge3DWebGL2 = g.Forge3DWebGL2;
})(typeof globalThis !== 'undefined' ? globalThis : this);
