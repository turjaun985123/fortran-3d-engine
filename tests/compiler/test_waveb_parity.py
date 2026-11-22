#!/usr/bin/env python3
"""Wave B compiler parity tests (seat B74, MASTER-PLAN section 3).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_waveb_parity.py

Mirrors the Wave A parity harness (``test_wavea_parity.py``): every
compile test drives the real pipeline -- ``parser.parse`` ->
``validate.validate`` -> ``emit_fortran.emit_scene_text`` -- and is
named for the MASTER-PLAN section 3 row it proves:

    row 19  glTF loading                   tris .scene lines
    row 20  Raycasting / picking           Fortran + JS sidecar, cast
    row 23  Sprites (billboards)           sprite .scene line
    row 24  Text (5x7 bitmap)              text .scene line + the
                                           Fortran/JS font cross-check
    row 32  Particles (deterministic)      hash anchor + .scene line
    row 17  Keyframe animation             keys/key .scene lines + the
                                           JS evalTrack midpoint
    row 16  Shadows (directional level)    shadow on 512 .scene line

The JS numeric checks shell out to ``node -e`` snippets that load
the runtime sidecars; when ``node`` is not on PATH they are SKIPPED
LOUDLY via ``skipUnless``, mirroring the other JS sidecar tests.
"""

import base64
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))),
        "tools", "f3dc",
    ),
)

import emit_fortran  # noqa: E402
import ext_gltf  # noqa: E402
import ext_particles  # noqa: E402
import parser  # noqa: E402
import validate  # noqa: E402
from errors import ErrorBag  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
NODE = shutil.which("node")
CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'"


def run(source, base_dir="."):
    """Parse + validate ``source``; return (ir_scene_or_None, error_codes)."""
    bag = ErrorBag()
    program = parser.parse(source, "test.f3d", bag)
    scene = validate.validate(program, bag, base_dir=base_dir)
    codes = [d.code for d in bag.diagnostics if d.severity == "error"]
    return scene, codes


def emit_lines(source, base_dir="."):
    """Full pipeline to the emitted .scene lines; fails the test on errors."""
    scene, codes = run(source, base_dir=base_dir)
    if codes or scene is None:
        raise AssertionError("expected a clean compile, got errors %r"
                             % (codes,))
    return emit_fortran.emit_scene_text(scene).splitlines()


def lines_starting(lines, prefix):
    return [ln for ln in lines if ln.startswith(prefix)]


def run_node(js_path, env_name, preamble, snippet):
    """Run one node -e snippet against a sidecar; fail on error."""
    env = dict(os.environ, **{env_name: js_path})
    proc = subprocess.run(
        [NODE, "-e", preamble + snippet],
        capture_output=True, text=True, env=env, timeout=30)
    if proc.returncode != 0:
        raise AssertionError(
            "node snippet failed (rc=%d):\n%s\n%s"
            % (proc.returncode, proc.stdout, proc.stderr))
    return proc


# ----------------------------------------------------------------------
# glTF fixture: an indexed quad (2 triangles, 4 vertices) in a single
# data-URI buffer, on a node translated by (10, 20, 30) -- built in
# code (struct / base64 / json), like tests/compiler/test_ext_gltf.py.
# ----------------------------------------------------------------------

QUAD_POSITIONS = [0.0, 0.0, 0.0,
                  1.0, 0.0, 0.0,
                  1.0, 1.0, 0.0,
                  0.0, 1.0, 0.0]
QUAD_INDICES = [0, 1, 2, 0, 2, 3]
QUAD_NODE_TRANSLATION = [10.0, 20.0, 30.0]
# The quad after the node translation is applied by ext_gltf, in the
# engine winding order: ext_gltf converts each glTF triangle
# (v1, v2, v3) to (v1, v3, v2) so it survives the rasteriser's
# winding cull (see ext_gltf's module docstring).
QUAD_TRIS = [
    [(10.0, 20.0, 30.0), (11.0, 21.0, 30.0), (11.0, 20.0, 30.0)],
    [(10.0, 20.0, 30.0), (10.0, 21.0, 30.0), (11.0, 21.0, 30.0)],
]


def build_quad_gltf_text():
    """Return the .gltf JSON text for the translated indexed quad."""
    pos_bytes = struct.pack("<%df" % len(QUAD_POSITIONS),
                            *QUAD_POSITIONS)
    idx_bytes = struct.pack("<%dH" % len(QUAD_INDICES), *QUAD_INDICES)
    idx_bytes += b"\x00" * (-len(idx_bytes) % 4)
    buffer = pos_bytes + idx_bytes
    doc = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "translation": QUAD_NODE_TRANSLATION}],
        "meshes": [{"primitives": [{
            "attributes": {"POSITION": 0},
            "indices": 1,
            "mode": 4,
        }]}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0,
             "byteLength": len(pos_bytes), "target": 34962},
            {"buffer": 0, "byteOffset": len(pos_bytes),
             "byteLength": len(idx_bytes), "target": 34963},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "type": "VEC3",
             "count": len(QUAD_POSITIONS) // 3},
            {"bufferView": 1, "componentType": 5123, "type": "SCALAR",
             "count": len(QUAD_INDICES)},
        ],
        "buffers": [{
            "byteLength": len(buffer),
            "uri": ("data:application/octet-stream;base64,"
                    + base64.b64encode(buffer).decode("ascii")),
        }],
    }
    return json.dumps(doc)


class TestRow19GlTF(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name
        self.gltf_path = os.path.join(self.dir, "quad.gltf")
        with open(self.gltf_path, "w", encoding="ascii") as fh:
            fh.write(build_quad_gltf_text())

    def test_row19_ext_gltf_loads_translated_indexed_quad(self):
        data = ext_gltf.load_gltf(self.gltf_path)
        self.assertEqual(data["count"], 2)
        self.assertEqual(len(data["triangles"]), 2)
        for (colour, verts), want in zip(data["triangles"], QUAD_TRIS):
            self.assertEqual(colour, (255, 255, 255))
            self.assertEqual(verts, want)

    def test_row19_compile_emits_tris_header_and_tri_lines(self):
        lines = emit_lines('load "quad.gltf" quad at 0,0,0\n',
                           base_dir=self.dir)
        self.assertIn("tris quad 2", lines)
        tri_lines = lines_starting(lines, "tri ")
        self.assertEqual(tri_lines, [
            "tri 255 255 255 10 20 30 11 21 30 11 20 30",
            "tri 255 255 255 10 20 30 10 21 30 11 21 30",
        ])

    def test_row19_placed_load_emits_tris_header_with_transform(self):
        lines = emit_lines('load "quad.gltf" quad at 5,0,0\n',
                           base_dir=self.dir)
        # tris NAME COUNT PX PY PZ RX RY RZ SX SY SZ: the v1 3-word
        # header plus the 9 transform numbers for a placed load.
        headers = lines_starting(lines, "tris ")
        self.assertEqual(headers,
                         ["tris quad 2 5 0 0 0 0 0 1 1 1"])
        self.assertEqual(len(headers[0].split()), 12)
        self.assertEqual(len(lines_starting(lines, "tri ")), 2)


class TestRow20Raycast(unittest.TestCase):
    def test_row20_raycast_sources_exist(self):
        self.assertTrue(os.path.isfile(
            os.path.join(REPO_ROOT, "src", "raycast.f90")))
        self.assertTrue(os.path.isfile(
            os.path.join(REPO_ROOT, "runtime", "f3d-raycast.js")))

    @unittest.skipUnless(
        NODE,
        "SKIPPED: node not on PATH - f3d-raycast.js cast test not run")
    def test_row20_js_cast_cube_t_equals_4(self):
        js_path = os.path.join(REPO_ROOT, "runtime", "f3d-raycast.js")
        # The size-2 cube as a flat 12-triangle array, in the
        # Fortran create_cube vertex / face order (mirrors
        # tests/compiler/test_f3d_raycast_js.py).
        preamble = (
            "global.window = globalThis;"
            "eval(require('fs').readFileSync(process.env.F3D_RAYCAST,"
            " 'utf8'));"
            "const R = globalThis.F3DRay;"
            "const assert = require('assert');"
            "const P = [[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],"
            "  [-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]];"
            "const F = [[0,2,1],[0,3,2],[1,6,5],[1,2,6],[5,7,4],"
            "  [5,6,7],[4,3,0],[4,7,3],[3,6,2],[3,7,6],[4,1,5],"
            "  [4,0,1]];"
            "const CUBE = [];"
            "for (const f of F) for (const i of f) CUBE.push(...P[i]);"
        )
        run_node(
            js_path, "F3D_RAYCAST", preamble,
            # Ray (0,0,5) -> (0,0,-1) at the size-2 cube: the front
            # (z = +1) face is exactly 4 units away.
            "const h = R.cast([0, 0, 5], [0, 0, -1], CUBE);"
            "assert.ok(h, 'expected a hit');"
            "assert.ok(Math.abs(h.t - 4) <= 1e-9, 't=' + h.t);"
            "assert.ok(Math.abs(h.point[2] - 1) <= 1e-9,"
            "  'point=' + h.point);"
        )


class TestRow23SpriteLine(unittest.TestCase):
    def test_row23_sprite_line_exact(self):
        lines = emit_lines(
            "sprite star at 0,3,0 size 1 color yellow\ncube red\n")
        self.assertEqual(lines_starting(lines, "sprite"),
                         ["sprite star 0 3 0 1 240 220 50"])


class TestRow24TextLine(unittest.TestCase):
    def test_row24_text_line_exact(self):
        lines = emit_lines(
            'text label "FORGE 3D" at -3,2,0 size 1 color white\n'
            "cube red\n")
        self.assertEqual(
            lines_starting(lines, "text"),
            ["text label -3 2 0 1 240 240 240 FORGE 3D"])


class TestRow24FontCrossCheck(unittest.TestCase):
    """The Fortran font (src/text_render.f90 GLYPH_MASKS) is
    authoritative; the JS sidecar (runtime/f3d-sprites-text.js
    GLYPHS) must encode exactly the same 43 glyphs."""

    def _fortran_masks(self):
        path = os.path.join(REPO_ROOT, "src", "text_render.f90")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        start = src.index("GLYPH_MASKS(0:42) = [")
        block = src[start:src.index("]", start)]
        return [int(v) for v in re.findall(r"(\d+)_8", block)]

    def _js_masks(self):
        path = os.path.join(REPO_ROOT, "runtime", "f3d-sprites-text.js")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        start = src.index("var GLYPHS = [")
        block = src[start:src.index("];", start)]
        glyphs = []
        for rows_text in re.findall(r"\[([0-9,\s]+)\]", block):
            rows = [int(v) for v in rows_text.split(",") if v.strip()]
            self.assertEqual(len(rows), 7)
            mask = 0
            for row in range(7):
                for col in range(5):
                    if rows[row] >> (4 - col) & 1:
                        mask |= 1 << (34 - (row * 5 + col))
            glyphs.append(mask)
        return glyphs

    def test_row24_all_43_glyph_masks_match_fortran(self):
        fortran = self._fortran_masks()
        js = self._js_masks()
        self.assertEqual(len(fortran), 43)
        self.assertEqual(len(js), 43)
        differing = [i for i in range(43) if fortran[i] != js[i]]
        self.assertEqual(
            js, fortran,
            "JS GLYPHS differ from Fortran GLYPH_MASKS at glyph "
            "indices %r (%s)"
            % (differing,
               ", ".join("%d %r" % (i, CHARSET[i]) for i in differing)))


class TestRow32Particles(unittest.TestCase):
    def test_row32_particle_hash01_anchor(self):
        self.assertAlmostEqual(
            ext_particles.particle_hash01(1, 0, 0),
            0.5205930033698678, delta=1e-15)

    def test_row32_particles_line_exact(self):
        lines = emit_lines(
            "particles sparks at 0,2,0 count 100 life 2 speed 3 "
            "size 0.2 color orange spread 0.5 gravity 9 seed 7\n"
            "cube red\n")
        self.assertEqual(
            lines_starting(lines, "particles"),
            ["particles sparks 0 2 0 100 2 3 0.2 240 140 40 0.5 9 7"])


# The Row 17 track, shared by the compile test and the JS eval test:
# hero keyed from (-2,0,0) to (-2,1,0) / rot y 90 / scale 1.5 over
# 2 s, pingpong, the destination key easing smooth.
KEYS_SOURCE = (
    "cube hero red at -2,0,0\n"
    "keys hero duration 2 loop pingpong\n"
    "key hero at 0 pos -2,0,0 rot 0,0,0 scale 1\n"
    "key hero at 2 pos -2,1,0 rot 0,90,0 scale 1.5 ease smooth\n")
KEYS_TRACK = {
    "target": "hero", "duration": 2, "loop": "pingpong",
    "keys": [
        {"time": 0, "pos": [-2, 0, 0], "rot": [0, 0, 0],
         "scale": 1, "ease": "linear"},
        {"time": 2, "pos": [-2, 1, 0], "rot": [0, 90, 0],
         "scale": 1.5, "ease": "smooth"},
    ],
}


def smooth(p):
    return p * p * (3.0 - 2.0 * p)


class TestRow17Keys(unittest.TestCase):
    def test_row17_keys_lines_exact(self):
        lines = emit_lines(KEYS_SOURCE)
        self.assertIn("keys hero 2 pingpong 2", lines)
        idx = lines.index("keys hero 2 pingpong 2")
        self.assertEqual(lines[idx + 1:idx + 3], [
            "key 0 -2 0 0 0 0 0 1 linear",
            "key 2 -2 1 0 0 90 0 1.5 smooth",
        ])

    @unittest.skipUnless(
        NODE,
        "SKIPPED: node not on PATH - f3d-keys.js evalTrack test not run")
    def test_row17_js_eval_track_smooth_eased_midpoint(self):
        # Expected pose at t=1, computed here in Python: the segment
        # progress is p = 1/2, the destination key's ease is smooth,
        # and smooth(0.5) == 0.5, so the pose is the midpoint of the
        # two keys on every channel.
        e = smooth(0.5)
        self.assertEqual(e, 0.5)
        expected = {
            "pos": [-2.0 + (0.0) * e, 0.0 + 1.0 * e, 0.0],
            "rot": [0.0, 0.0 + 90.0 * e, 0.0],
            "scale": 1.0 + (1.5 - 1.0) * e,
        }
        self.assertEqual(expected["pos"], [-2.0, 0.5, 0.0])
        self.assertEqual(expected["scale"], 1.25)
        js_path = os.path.join(REPO_ROOT, "runtime", "f3d-keys.js")
        preamble = (
            "global.window = globalThis;"
            "eval(require('fs').readFileSync(process.env.F3D_KEYS,"
            " 'utf8'));"
            "const K = globalThis.F3DKeys;"
        )
        proc = run_node(
            js_path, "F3D_KEYS", preamble,
            "console.log(JSON.stringify(K.evalTrack(%s, 1)));"
            % json.dumps(KEYS_TRACK))
        got = json.loads(proc.stdout.strip())
        for channel in ("pos", "rot"):
            for j in range(3):
                self.assertAlmostEqual(got[channel][j],
                                       expected[channel][j],
                                       delta=1e-12)
        self.assertAlmostEqual(got["scale"], expected["scale"],
                               delta=1e-12)


class TestRow16DirectionalShadow(unittest.TestCase):
    def test_row16_shadow_on_default_size_line(self):
        # Parity level: a directional-only scene (the default light)
        # with `shadow on` emits the shadow line at the default
        # 512 map size.
        lines = emit_lines("scene shadow on\ncube red\n")
        self.assertEqual(lines_starting(lines, "shadow"),
                         ["shadow on 512"])
        self.assertIn(
            "light directional -0.5 -1 -0.7 255 255 255 1", lines)


if __name__ == "__main__":
    unittest.main(verbosity=2)
