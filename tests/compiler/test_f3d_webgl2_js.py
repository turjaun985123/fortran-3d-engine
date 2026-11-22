"""Forge3D Wave E seat E08: tests for the WebGL2 sidecar
``runtime/f3d-webgl2.js`` (window.Forge3DWebGL2).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_webgl2_js.py

The file checks always run. The behavioural checks shell out to
``node -e`` snippets that load the sidecar against a MOCK WebGL2
context object which records every GL call; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless``.

The mock is the headless proof: real GPU rasterization requires
a browser, so no test here claims pixel output -- only that the
sidecar issues the exact shader sources, buffer uploads,
uniform upload and draw call a real WebGL2 context would need,
and that projectPoint() matches Python-computed expectations
under the Fortran mat4 convention (column-major flat layout,
element (row, col) at m[col*4 + row], perspective divide when
|w| > 1e-12, mirroring mat4_transform_vec3 in src/math_3d.f90)
to within 1e-9.
"""

import math
import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-webgl2.js")
NODE = shutil.which("node")

# Loaded before every snippet: expose `window`, bind the export
# as `W`, and define a recording mock WebGL2 context + canvas.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_WEBGL2, 'utf8'));"
    "const W = globalThis.Forge3DWebGL2;"
    "const assert = require('assert');"
    "const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);"
    "const near3 = (a, b, e) => a.length === 3"
    "  && a.every((x, i) => near(x, b[i], e));"
    "class MockGL {"
    "  constructor(opts) { opts = opts || {};"
    "    this.calls = [];"
    "    this.compileOk = opts.compileOk !== false;"
    "    this.linkOk = opts.linkOk !== false;"
    "    this.VERTEX_SHADER = 0x8B31; this.FRAGMENT_SHADER = 0x8B30;"
    "    this.COMPILE_STATUS = 0x8B81; this.LINK_STATUS = 0x8B82;"
    "    this.ARRAY_BUFFER = 0x8892; this.STATIC_DRAW = 0x88E4;"
    "    this.FLOAT = 0x1406; this.TRIANGLES = 0x0004;"
    "    this.DEPTH_TEST = 0x0B71; this.COLOR_BUFFER_BIT = 0x4000;"
    "    this.DEPTH_BUFFER_BIT = 0x0100; }"
    "  rec(name, args) { this.calls.push({ name: name,"
    "    args: Array.from(args) }); }"
    "  find(name) { return this.calls.filter(c => c.name === name); }"
    "  createShader(t) { this.rec('createShader', arguments);"
    "    return { shader: true, type: t }; }"
    "  shaderSource(s, src) { this.rec('shaderSource', arguments); }"
    "  compileShader(s) { this.rec('compileShader', arguments); }"
    "  getShaderParameter(s, p) { this.rec('getShaderParameter',"
    "    arguments); return this.compileOk; }"
    "  createProgram() { this.rec('createProgram', arguments);"
    "    return { program: true }; }"
    "  attachShader(p, s) { this.rec('attachShader', arguments); }"
    "  linkProgram(p) { this.rec('linkProgram', arguments); }"
    "  getProgramParameter(p, q) { this.rec('getProgramParameter',"
    "    arguments); return this.linkOk; }"
    "  createBuffer() { this.rec('createBuffer', arguments);"
    "    return { buffer: true, id: this.calls.length }; }"
    "  getAttribLocation(p, n) { this.rec('getAttribLocation',"
    "    arguments); return n === 'aPos' ? 0 : 1; }"
    "  getUniformLocation(p, n) { this.rec('getUniformLocation',"
    "    arguments); return { uniform: n }; }"
    "  useProgram(p) { this.rec('useProgram', arguments); }"
    "  enable(c) { this.rec('enable', arguments); }"
    "  clearColor(r, g, b, a) { this.rec('clearColor', arguments); }"
    "  clear(m) { this.rec('clear', arguments); }"
    "  bindBuffer(t, b) { this.rec('bindBuffer', arguments); }"
    "  bufferData(t, d, u) { this.rec('bufferData', arguments); }"
    "  vertexAttribPointer(...a) { this.rec('vertexAttribPointer', a); }"
    "  enableVertexAttribArray(i) {"
    "    this.rec('enableVertexAttribArray', arguments); }"
    "  uniformMatrix4fv(l, t, d) {"
    "    this.rec('uniformMatrix4fv', arguments); }"
    "  drawArrays(m, f, c) { this.rec('drawArrays', arguments); }"
    "}"
    "function makeCanvas(glOrFn) {"
    "  return { getContext(kind) {"
    "    if (typeof glOrFn === 'function') return glOrFn(kind);"
    "    return kind === 'webgl2' ? glOrFn : null; } }; }"
    # Two triangles in the f3d.js build() element shape:
    # [[a, b, c, faceIdx, [r, g, b] 0..255], ...]
    "const TRIS = ["
    "  [[0,0,0],[1,0,0],[0,1,0],0,[255,0,0]],"
    "  [[0,0,1],[1,0,1],[0,1,1],1,[0,128,255]]];"
    "const IDENT = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];"
)


def run_node(snippet):
    env = dict(os.environ, F3D_WEBGL2=JS_PATH)
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


def fortran_transform(m_flat_col_major, p):
    """mat4_transform_vec3 (is_point=true) on a flat column-major
    matrix, computed in Python as the independent expectation."""
    m = m_flat_col_major
    x, y, z = p
    rx = m[0] * x + m[4] * y + m[8] * z + m[12]
    ry = m[1] * x + m[5] * y + m[9] * z + m[13]
    rz = m[2] * x + m[6] * y + m[10] * z + m[14]
    w = m[3] * x + m[7] * y + m[11] * z + m[15]
    if abs(w) > 1e-12:
        rx, ry, rz = rx / w, ry / w, rz / w
    return [rx, ry, rz]


def js_num(v):
    return repr(float(v))


def _norm(v):
    length = math.hypot(v[0], v[1], v[2])
    if length > 1e-12:
        return [x / length for x in v]
    return [0.0, 0.0, 0.0]


def lambert_intensity(verts, light_dir=(-0.5, -1.0, -0.7), ambient=0.25):
    """Python mirror of runtime/f3d.js Lambert shading.

    f3d.js: ld = norm(lightDir) (default [-0.5, -1, -0.7]),
    n = norm(cross(w1 - w0, w2 - w0)) over the triangle's
    positions, inten = 0.25 + 0.75 * max(0, -dot(n, ld)) --
    i.e. ambient + (1 - ambient) * max(0, dot(n, -ld)) with
    ambient 0.25 by default.
    """
    w0, w1, w2 = verts
    e1 = [w1[i] - w0[i] for i in range(3)]
    e2 = [w2[i] - w0[i] for i in range(3)]
    cross = [
        e1[1] * e2[2] - e1[2] * e2[1],
        e1[2] * e2[0] - e1[0] * e2[2],
        e1[0] * e2[1] - e1[1] * e2[0],
    ]
    n = _norm(cross)
    ld = _norm(list(light_dir))
    diffuse = max(0.0, -sum(n[i] * ld[i] for i in range(3)))
    return ambient + (1.0 - ambient) * diffuse


def shaded_colour(base_rgb_0_255, intensity):
    """Base colour (0..255) -> uploaded 0..1 shaded channel values."""
    return [c / 255.0 * intensity for c in base_rgb_0_255]


def js_array(values):
    return "[" + ",".join(js_num(v) for v in values) + "]"


class TestF3DWebGL2File(unittest.TestCase):
    def test_file_exists_and_states_browser_requirement(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        with open(JS_PATH, encoding="utf-8") as fh:
            text = fh.read()
        # The header must state plainly that real GPU
        # rasterization requires a browser and that headless
        # verification is mock-GL + math parity.
        self.assertIn("real GPU rasterization", text)
        self.assertIn("requires a browser", text)
        self.assertIn("mock-GL", text)


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-webgl2.js tests not run"
)
class TestF3DWebGL2Exports(unittest.TestCase):
    def test_exports_and_shader_sources(self):
        run_node(
            "for (const k of ['isAvailable','create','renderScene',"
            "  'projectPoint','attach'])"
            "  assert.strictEqual(typeof W[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.Forge3DWebGL2, W);"
            "assert.strictEqual(typeof W.VERT_SRC, 'string');"
            "assert.strictEqual(typeof W.FRAG_SRC, 'string');"
            "assert.strictEqual(W.VERT_SRC.split('\\n')[0],"
            "  '#version 300 es');"
            "assert.strictEqual(W.FRAG_SRC.split('\\n')[0],"
            "  '#version 300 es');"
            "for (const s of ['in vec3 aPos;','in vec3 aColor;',"
            "  'uniform mat4 uMVP;','out vec3 vColor;',"
            "  'gl_Position = uMVP * vec4(aPos, 1.0);'])"
            "  assert.ok(W.VERT_SRC.includes(s), 'VERT_SRC: ' + s);"
            "for (const s of ['precision mediump float;',"
            "  'in vec3 vColor;','out vec4 outColor;'])"
            "  assert.ok(W.FRAG_SRC.includes(s), 'FRAG_SRC: ' + s);"
        )

    def test_is_available_false_on_null_and_throw(self):
        run_node(
            "assert.strictEqual(W.isAvailable(makeCanvas(null)), false);"
            "assert.strictEqual(W.isAvailable(makeCanvas(() => {"
            "  throw new Error('no gl'); })), false);"
            "assert.strictEqual(W.isAvailable({}), false);"
            "assert.strictEqual(W.isAvailable(null), false);"
            "const gl = new MockGL();"
            "assert.strictEqual(W.isAvailable(makeCanvas(gl)), true);"
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-webgl2.js tests not run"
)
class TestF3DWebGL2Create(unittest.TestCase):
    def test_create_compiles_links_and_makes_buffers(self):
        run_node(
            "const gl = new MockGL();"
            "const r = W.create(makeCanvas(gl));"
            "assert.ok(r, 'create must return a renderer');"
            "assert.strictEqual(r.gl, gl);"
            "assert.ok(r.program);"
            "assert.ok(r.buffers.position && r.buffers.color);"
            # Shaders compiled with the exact exported sources.
            "const srcs = gl.find('shaderSource');"
            "assert.strictEqual(srcs.length, 2);"
            "assert.strictEqual(srcs[0].args[1], W.VERT_SRC);"
            "assert.strictEqual(srcs[1].args[1], W.FRAG_SRC);"
            "assert.ok(srcs[0].args[1].startsWith('#version 300 es'));"
            "assert.strictEqual(gl.find('createShader').length, 2);"
            "assert.strictEqual(gl.find('compileShader').length, 2);"
            "assert.strictEqual(gl.find('attachShader').length, 2);"
            "assert.strictEqual(gl.find('linkProgram').length, 1);"
            "assert.strictEqual(gl.find('createBuffer').length, 2);"
            "const attrs = gl.find('getAttribLocation')"
            "  .map(c => c.args[1]);"
            "assert.deepStrictEqual(attrs, ['aPos', 'aColor']);"
            "assert.strictEqual("
            "  gl.find('getUniformLocation')[0].args[1], 'uMVP');"
        )

    def test_create_null_on_unavailable_compile_and_link_failure(self):
        run_node(
            "assert.strictEqual(W.create(makeCanvas(null)), null);"
            "assert.strictEqual(W.create(makeCanvas(() => {"
            "  throw new Error('x'); })), null);"
            "assert.strictEqual(W.create(null), null);"
            "assert.strictEqual(W.create(makeCanvas("
            "  new MockGL({ compileOk: false }))), null);"
            "assert.strictEqual(W.create(makeCanvas("
            "  new MockGL({ linkOk: false }))), null);"
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-webgl2.js tests not run"
)
class TestF3DWebGL2Render(unittest.TestCase):
    def test_render_scene_gl_calls(self):
        # Both PREAMBLE TRIS share the (0,0,0),(1,0,0),(0,1,0)
        # orientation, so both get the same Python-computed
        # Lambert intensity by default (no longer flat).
        inten = lambert_intensity([[0, 0, 0], [1, 0, 0], [0, 1, 0]])
        exp0 = js_array(shaded_colour([255, 0, 0], inten))
        exp1 = js_array(shaded_colour([0, 128, 255], inten))
        run_node(
            "const gl = new MockGL();"
            "const r = W.create(makeCanvas(gl));"
            "gl.calls.length = 0;"
            "const n = W.renderScene(r, TRIS, IDENT);"
            "assert.strictEqual(n, 2);"
            # DEPTH_TEST enabled, cleared.
            "const en = gl.find('enable');"
            "assert.strictEqual(en.length, 1);"
            "assert.strictEqual(en[0].args[0], gl.DEPTH_TEST);"
            "assert.strictEqual(gl.find('clear').length, 1);"
            "assert.strictEqual(gl.find('clear')[0].args[0],"
            "  gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);"
            # Default clear colour = f3d.js bg [25,25,35] / 255.
            "const cc = gl.find('clearColor')[0].args;"
            "assert.ok(near(cc[0], 25/255) && near(cc[1], 25/255)"
            "  && near(cc[2], 35/255) && near(cc[3], 1),"
            "  'clearColor=' + cc);"
            # bufferData: positions tris*9, colours tris*9 in 0..1.
            "const bd = gl.find('bufferData');"
            "assert.strictEqual(bd.length, 2);"
            "assert.ok(bd[0].args[1] instanceof Float32Array);"
            "assert.ok(bd[1].args[1] instanceof Float32Array);"
            "assert.strictEqual(bd[0].args[1].length, TRIS.length * 9);"
            "assert.strictEqual(bd[1].args[1].length, TRIS.length * 9);"
            "assert.deepStrictEqual(Array.from(bd[0].args[1]),"
            "  [0,0,0, 1,0,0, 0,1,0, 0,0,1, 1,0,1, 0,1,1]);"
            "const cols = Array.from(bd[1].args[1]);"
            "assert.ok(cols.every(v => v >= 0 && v <= 1),"
            "  'colours out of 0..1: ' + cols);"
            # 1e-6 here: colours pass through a Float32Array, so
            # the shaded values are only float32-exact.
            "assert.ok(near3(cols.slice(0, 3), " + exp0 + ", 1e-6),"
            "  'tri0 shaded colour=' + cols.slice(0, 3));"
            "assert.ok(near3(cols.slice(9, 12), " + exp1 + ", 1e-6),"
            "  'tri1 shaded colour=' + cols.slice(9, 12));"
            # MVP uniform: 16 elements, untransposed.
            "const um = gl.find('uniformMatrix4fv');"
            "assert.strictEqual(um.length, 1);"
            "assert.strictEqual(um[0].args[1], false);"
            "assert.strictEqual(um[0].args[2].length, 16);"
            "assert.deepStrictEqual(Array.from(um[0].args[2]), IDENT);"
            # Draw call covers every vertex.
            "const da = gl.find('drawArrays');"
            "assert.strictEqual(da.length, 1);"
            "assert.strictEqual(da[0].args[0], gl.TRIANGLES);"
            "assert.strictEqual(da[0].args[1], 0);"
            "assert.strictEqual(da[0].args[2], TRIS.length * 3);"
        )

    def test_render_scene_flat_and_object_payloads(self):
        # The object payload below has the same orientation as
        # in test_render_scene_gl_calls, so its green channel is
        # shaded by the Python-computed Lambert intensity.
        inten = lambert_intensity([[0, 0, 0], [1, 0, 0], [0, 1, 0]])
        exp_green = js_array(shaded_colour([0, 255, 0], inten))
        run_node(
            # Flat soup (raycast form) and scene-object triangles
            # upload the same counts as the f3d.js build() shape.
            "const gl = new MockGL();"
            "const r = W.create(makeCanvas(gl));"
            "gl.calls.length = 0;"
            "assert.strictEqual(W.renderScene(r,"
            "  [0,0,0, 1,0,0, 0,1,0], IDENT), 1);"
            "let bd = gl.find('bufferData');"
            "assert.strictEqual(bd[0].args[1].length, 9);"
            "assert.strictEqual(bd[1].args[1].length, 9);"
            "assert.strictEqual(gl.find('drawArrays')[0].args[2], 3);"
            "gl.calls.length = 0;"
            "assert.strictEqual(W.renderScene(r,"
            "  [{v: [[0,0,0],[1,0,0],[0,1,0]], color: [0,255,0]}],"
            "  IDENT), 1);"
            "bd = gl.find('bufferData');"
            "assert.ok(near3(Array.from(bd[1].args[1]).slice(0, 3),"
            "  " + exp_green + ", 1e-6),"
            "  'object payload shaded colour='"
            "  + Array.from(bd[1].args[1]).slice(0, 3));"
            "assert.strictEqual(W.renderScene(null, TRIS, IDENT), 0);"
            "assert.strictEqual(W.renderScene(r, [], IDENT), 0);"
        )

    def test_render_scene_uses_renderer_clear_color(self):
        run_node(
            "const gl = new MockGL();"
            "const r = W.create(makeCanvas(gl));"
            "r.clearColor = [255, 0, 0];"
            "gl.calls.length = 0;"
            "W.renderScene(r, TRIS, IDENT);"
            "const cc = gl.find('clearColor')[0].args;"
            "assert.ok(near(cc[0], 1) && near(cc[1], 0)"
            "  && near(cc[2], 0) && near(cc[3], 1),"
            "  'clearColor=' + cc);"
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-webgl2.js tests not run"
)
class TestF3DWebGL2ProjectPoint(unittest.TestCase):
    def _check(self, m, p):
        exp = fortran_transform(m, p)
        snippet = (
            "const got = W.projectPoint(%s, %s);"
            "assert.ok(near3(got, %s, 1e-9),"
            "  'got=' + got + ' expected=' + %s);"
            % (
                "[" + ",".join(js_num(v) for v in m) + "]",
                "[" + ",".join(js_num(v) for v in p) + "]",
                "[" + ",".join(js_num(v) for v in exp) + "]",
                "[" + ",".join(js_num(v) for v in exp) + "]",
            )
        )
        run_node(snippet)

    def test_identity(self):
        ident = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        self._check(ident, [1.5, -2.25, 3.75])
        self._check(ident, [0, 0, 0])

    def test_translation(self):
        # Column-major: translation at indices 12, 13, 14.
        m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 20, 30, 1]
        self._check(m, [1, 2, 3])
        self._check(m, [-10, -20, -30])

    def test_perspective_divide(self):
        # Fortran mat4_perspective(fov=90deg, aspect=1, near=1,
        # far=10): (1,1)=(2,2)=1, (3,3)=-11/9, (3,4)=-20/9,
        # (4,3)=-1 -- flattened column-major below.
        m = [1, 0, 0, 0,
             0, 1, 0, 0,
             0, 0, -11.0 / 9.0, -1,
             0, 0, -20.0 / 9.0, 0]
        self._check(m, [1, 2, -5])   # w = 5, z/w = 7/9
        self._check(m, [0, 0, -1])   # near plane -> z = -1
        self._check(m, [0, 0, -10])  # far plane -> z = +1


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-webgl2.js tests not run"
)
class TestF3DWebGL2Lambert(unittest.TestCase):
    # Front-facing: normal (0,0,1) from this winding.
    FRONT = [[0, 0, 0], [1, 0, 0], [0, 1, 0]]
    # Back-facing: reversed winding, normal (0,0,-1).
    BACK = [[0, 0, 0], [0, 1, 0], [1, 0, 0]]

    def _colour_snippet(self, tris_js, opts_js, expected):
        return (
            "const gl = new MockGL();"
            "const r = W.create(makeCanvas(gl));"
            "gl.calls.length = 0;"
            "assert.strictEqual(W.renderScene(r, " + tris_js + ","
            "  IDENT, " + opts_js + "), 1);"
            "const bd = gl.find('bufferData');"
            "assert.strictEqual(bd.length, 2);"
            "const cols = Array.from(bd[1].args[1]);"
            # Every vertex of the tri carries the same per-tri
            # colour, matching the Python Lambert expectation
            # within 1e-6 (float32 colour buffer).
            "for (let k = 0; k < 3; k++)"
            "  assert.ok(near3(cols.slice(k * 3, k * 3 + 3), "
            + js_array(expected) + ", 1e-6),"
            "    'vertex ' + k + ' colour='"
            "    + cols.slice(k * 3, k * 3 + 3)"
            "    + ' expected=' + " + js_array(expected) + ");"
        )

    def test_front_facing_tri_matches_python_lambert(self):
        base = [200, 100, 50]
        inten = lambert_intensity(self.FRONT)
        # This orientation really does face the light.
        self.assertGreater(inten, 0.25)
        self.assertLess(inten, 1.0)
        tris_js = ("[[[0,0,0],[1,0,0],[0,1,0],0,"
                   + js_array(base) + "]]")
        run_node(self._colour_snippet(
            tris_js, "undefined", shaded_colour(base, inten)))

    def test_back_facing_tri_gets_exactly_ambient_times_colour(self):
        base = [200, 100, 50]
        inten = lambert_intensity(self.BACK)
        # Diffuse clamps to 0, so intensity is exactly ambient.
        self.assertEqual(inten, 0.25)
        tris_js = ("[[[0,0,0],[0,1,0],[1,0,0],0,"
                   + js_array(base) + "]]")
        run_node(self._colour_snippet(
            tris_js, "undefined",
            shaded_colour(base, 0.25)))
        # A custom ambient is honoured the same way.
        run_node(self._colour_snippet(
            tris_js, "{ambient: 0.5}",
            shaded_colour(base, lambert_intensity(
                self.BACK, ambient=0.5))))

    def test_flat_true_reproduces_raw_colour_over_255(self):
        # The PREAMBLE TRIS under flat:true upload exactly the
        # pre-Lambert (E08) values: raw colour / 255.
        run_node(
            "const gl = new MockGL();"
            "const r = W.create(makeCanvas(gl));"
            "gl.calls.length = 0;"
            "assert.strictEqual(W.renderScene(r, TRIS, IDENT,"
            "  {flat: true}), 2);"
            "const cols = Array.from("
            "  gl.find('bufferData')[1].args[1]);"
            "assert.ok(near3(cols.slice(0, 3), [1, 0, 0], 1e-6),"
            "  'flat tri0 colour=' + cols.slice(0, 3));"
            "assert.ok(near3(cols.slice(9, 12),"
            "  [0, 128/255, 1], 1e-6),"
            "  'flat tri1 colour=' + cols.slice(9, 12));"
            # attach() passes opts through: flat via attach too.
            "const gl2 = new MockGL();"
            "assert.strictEqual(W.attach(makeCanvas(gl2), TRIS,"
            "  IDENT, {flat: true}), 'webgl2');"
            "const cols2 = Array.from("
            "  gl2.find('bufferData')[1].args[1]);"
            "assert.ok(near3(cols2.slice(0, 3), [1, 0, 0], 1e-6),"
            "  'attach flat tri0 colour=' + cols2.slice(0, 3));"
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-webgl2.js tests not run"
)
class TestF3DWebGL2Attach(unittest.TestCase):
    def test_attach_reports_backend(self):
        run_node(
            "assert.strictEqual(W.attach(makeCanvas(null),"
            "  TRIS, IDENT), 'canvas2d');"
            "assert.strictEqual(W.attach(makeCanvas(() => {"
            "  throw new Error('x'); }), TRIS, IDENT), 'canvas2d');"
            "const gl = new MockGL();"
            "assert.strictEqual(W.attach(makeCanvas(gl),"
            "  TRIS, IDENT), 'webgl2');"
            "assert.strictEqual(gl.find('drawArrays').length, 1);"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
