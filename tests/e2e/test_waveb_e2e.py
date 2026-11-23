#!/usr/bin/env python3
"""Wave B end-to-end tests (seat B74): f3dc CLI + the real Fortran engine.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/e2e/test_waveb_e2e.py

Mirrors ``tests/e2e/test_wavea_e2e.py``: every scene drives the
native ``bin/f3dc`` binary via subprocess (``["run", ...]``) into a
``tempfile`` tree and the PPM is read back with
``tests/golden/check_image.py``.
Scenes are SMALL (160x120 or 320x240) and stills only, except the
Row 17 keyframe scene, which renders a short 2 s / 2 fps animation.
``setUpClass`` follows the Wave A pattern: ``make`` runs once first
(when gfortran+make are available) so ``bin/engine3d`` matches the
current sources; the suite skips loudly only when no engine binary
exists and none can be built.
"""

import base64
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tests" / "golden"))

from check_image import read_ppm  # noqa: E402


def _resolve_f3dc():
    """Locate the native compiler binary to test."""
    env = os.environ.get("F3DC")
    if env:
        return env
    candidate = REPO_ROOT / "bin" / "f3dc"
    if candidate.exists():
        return str(candidate)
    return str(REPO_ROOT / "compiler" / "f3dc")


F3DC = _resolve_f3dc()

GOLDEN_SHA256 = ("28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56"
                 "fa90e05ac7697cec1")
BG = (25, 25, 35)


def pixels_of(img):
    """(w, h, bytes) -> list of (r, g, b) tuples."""
    _w, _h, px = img
    return [tuple(px[i:i + 3]) for i in range(0, len(px), 3)]


def pixel_at(img, x, y):
    w, _h, px = img
    i = (y * w + x) * 3
    return tuple(px[i:i + 3])


def non_bg_count(img, bg=BG):
    return sum(1 for c in pixels_of(img) if c != bg)


def build_quad_gltf_text():
    """A red indexed quad (-3..3 x -2..2, XY plane) as .gltf text.

    Single data-URI buffer, no node transform; the material's
    baseColorFactor makes every triangle red.
    """
    positions = [-3.0, -2.0, 0.0,
                 3.0, -2.0, 0.0,
                 3.0, 2.0, 0.0,
                 -3.0, 2.0, 0.0]
    indices = [0, 1, 2, 0, 2, 3]
    pos_bytes = struct.pack("<%df" % len(positions), *positions)
    idx_bytes = struct.pack("<%dH" % len(indices), *indices)
    idx_bytes += b"\x00" * (-len(idx_bytes) % 4)
    buffer = pos_bytes + idx_bytes
    doc = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{
            "attributes": {"POSITION": 0},
            "indices": 1,
            "mode": 4,
            "material": 0,
        }]}],
        "materials": [{"pbrMetallicRoughness": {
            "baseColorFactor": [1.0, 0.0, 0.0, 1.0]}}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0,
             "byteLength": len(pos_bytes), "target": 34962},
            {"buffer": 0, "byteOffset": len(pos_bytes),
             "byteLength": len(idx_bytes), "target": 34963},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "type": "VEC3",
             "count": len(positions) // 3},
            {"bufferView": 1, "componentType": 5123, "type": "SCALAR",
             "count": len(indices)},
        ],
        "buffers": [{
            "byteLength": len(buffer),
            "uri": ("data:application/octet-stream;base64,"
                    + base64.b64encode(buffer).decode("ascii")),
        }],
    }
    return json.dumps(doc)


class TestWaveBE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        engine = REPO_ROOT / "bin" / "engine3d"
        have_toolchain = (shutil.which("gfortran") is not None
                          and shutil.which("make") is not None)
        if have_toolchain:
            # Freshen the binary once (the native driver would
            # otherwise reuse a stale one as-is).
            build = subprocess.run(["make"], cwd=REPO_ROOT,
                                   capture_output=True, text=True)
            if build.returncode != 0:
                raise AssertionError("make failed:\n%s\n%s"
                                     % (build.stdout[-2000:],
                                        build.stderr[-2000:]))
        if not engine.is_file():
            raise unittest.SkipTest(
                "bin/engine3d missing and gfortran/make unavailable "
                "to build it: cannot run Wave B e2e")
        cls._tmp = tempfile.TemporaryDirectory(prefix="f3dc-waveb-e2e-")
        cls.tmp = Path(cls._tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def render_full(self, name, source, extra_files=None):
        """Compile+render one .f3d via the CLI.

        Returns (img, raw_ppm_bytes, build_dir).
        """
        work = self.tmp / name
        work.mkdir(parents=True, exist_ok=True)
        for fname, content in (extra_files or {}).items():
            (work / fname).write_text(content, encoding="ascii")
        scene = work / "scene.f3d"
        scene.write_text(source, encoding="utf-8")
        proc = subprocess.run(
            [F3DC, "run", str(scene), "-o", str(work / "build")],
            cwd=REPO_ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        build = work / "build"
        ppm = build / "output_render.ppm"
        self.assertTrue(ppm.is_file(), "no output_render.ppm for %s" % name)
        return read_ppm(ppm), ppm.read_bytes(), build

    def render(self, name, source, extra_files=None):
        """Wave A-shaped helper: return (img, raw_ppm_bytes)."""
        img, raw, _build = self.render_full(name, source, extra_files)
        return img, raw

    # -- row 19: glTF -------------------------------------------------

    def test_row19_gltf_quad_renders_nonflat(self):
        src = ("scene size 160 120\n"
               "camera at 0 0 10 look 0 0 0\n"
               'load "quad.gltf" quad at 0,0,0\n'
               "render still\n")
        img, _raw = self.render("gltf_quad", src,
                                {"quad.gltf": build_quad_gltf_text()})
        cols = pixels_of(img)
        self.assertGreaterEqual(len(set(cols)), 2)
        self.assertGreater(non_bg_count(img), 100)

    # -- rows 23 / 24 / 29: sprite + text ------------------------------

    def test_rows23_24_29_sprite_and_text_render(self):
        # The coordinator's verified smoke shape at 320x240.
        src = ("scene size 320 240\n"
               "camera at 6 4 9 look 0 0 0\n"
               "cube hero red at 0 0 0 size 2\n"
               "sphere ball blue at 3 0 0 radius 1\n"
               "sprite star at 0,3,0 size 1 color yellow\n"
               'text label "FORGE 3D" at -3,2,0 size 1 color white\n'
               "render still\n")
        img, _raw = self.render("sprite_text", src)
        cols = pixels_of(img)
        self.assertGreaterEqual(len(set(cols)), 10)
        self.assertGreater(non_bg_count(img), 1000)

    # -- row 32: particles ----------------------------------------------

    PARTICLES_SRC = (
        "scene size 160 120\n"
        "camera at 6 4 9 look 0 0 0\n"
        "cube hero red at 0 0 0 size 2\n"
        "particles fountain at 0,2,0 count 100 life 2 speed 3 "
        "size 0.2 color orange spread 0.5 gravity 9 seed 7\n"
        "render still\n")

    def test_row32_particles_fountain_nonflat_and_deterministic(self):
        img, raw1 = self.render("particles_a", self.PARTICLES_SRC)
        _img2, raw2 = self.render("particles_b", self.PARTICLES_SRC)
        cols = pixels_of(img)
        self.assertGreaterEqual(len(set(cols)), 2)
        self.assertGreater(non_bg_count(img), 100)
        # Deterministic: the same scene renders byte-identically.
        self.assertEqual(hashlib.sha256(raw1).hexdigest(),
                         hashlib.sha256(raw2).hexdigest())

    # -- row 17: keyframes ------------------------------------------------

    def test_row17_keys_animation_frames_differ(self):
        # Hero is keyframed; the spinning ball drives the frame
        # count (2 s at 2 fps), so the render is an animation, not
        # a still.
        src = ("scene size 160 120\n"
               "camera at 0 2 8 look 0 0 0\n"
               "cube hero red at -2,0,0 size 1\n"
               "sphere ball blue at 3,0,0 radius 1\n"
               "keys hero duration 2 loop pingpong\n"
               "key hero at 0 pos -2,0,0 rot 0,0,0 scale 1\n"
               "key hero at 2 pos -2,1,0 rot 0,90,0 scale 1.5 "
               "ease smooth\n"
               "spin ball duration 2 fps 2\n"
               "render duration 2 fps 2\n")
        _img, _raw, build = self.render_full("keys_anim", src)
        frames = sorted(build.glob("output_render_*.ppm"))
        self.assertGreaterEqual(len(frames), 3,
                                "frames: %r" % [f.name for f in frames])
        self.assertNotEqual(frames[0].read_bytes(),
                            frames[-1].read_bytes())

    # -- row 16: directional shadow ---------------------------------------

    # The PROVEN scene (coordinator-verified at 160x120): with
    # `shadow on` the ground pixel (76,68) is (35,35,36) vs
    # (114,114,118) with shadow off, and 322 pixels differ overall.
    SHADOW_SRC = (
        'scene "dctl" size 160 120 background black shadow %s\n'
        "camera at 0 -6 12 look 0 -1 0\n"
        "plane ground gray at 0 -2 0 size 12 material standard "
        "metalness 0 roughness 0.95\n"
        "cube hero white at 0 0 0 size 2 material standard "
        "metalness 0 roughness 0.8\n"
        "render still\n")

    def test_row16_directional_shadow_darkens_ground(self):
        on, _raw_on = self.render("dshadow_on", self.SHADOW_SRC % "on")
        off, _raw_off = self.render("dshadow_off",
                                    self.SHADOW_SRC % "off")
        differing = sum(1 for a, b in zip(pixels_of(on), pixels_of(off))
                        if a != b)
        self.assertGreaterEqual(differing, 100)
        self.assertLess(sum(pixel_at(on, 76, 68)),
                        sum(pixel_at(off, 76, 68)) - 100)

    # -- golden regression -------------------------------------------------

    def test_golden_legacy_no_arg_engine(self):
        work = self.tmp / "golden_noarg"
        work.mkdir(parents=True, exist_ok=True)
        proc = subprocess.run([str(REPO_ROOT / "bin" / "engine3d")],
                              cwd=work, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        ppm = work / "output_render.ppm"
        self.assertTrue(ppm.is_file())
        self.assertEqual(hashlib.sha256(ppm.read_bytes()).hexdigest(),
                         GOLDEN_SHA256)

    def test_golden_one_line_cube_cli_render(self):
        _img, raw = self.render("golden_cube", "cube\n")
        self.assertEqual(hashlib.sha256(raw).hexdigest(), GOLDEN_SHA256)


if __name__ == "__main__":
    unittest.main(verbosity=2)
