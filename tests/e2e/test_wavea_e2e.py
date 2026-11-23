#!/usr/bin/env python3
"""Wave A end-to-end tests (seat B61): f3dc CLI + the real Fortran engine.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/e2e/test_wavea_e2e.py

Like ``tests/e2e/test_cli.py``, every scene drives the native
``bin/f3dc`` binary via subprocess (``["run", ...]``) into a
``tempfile`` tree and the PPM is read back with
``tests/golden/check_image.py``.  Scenes render at 160x120 (the
golden regression is the exception: it is the 640x480 default by
definition).  ``setUpClass`` follows test_cli's pattern: the native
driver reuses an existing ``bin/engine3d`` as-is, so when
``gfortran``+``make`` are available ``make`` runs once first to keep
the binary matched to the current sources; the suite skips loudly
only when no engine binary exists and none can be built.

Verified-render notes (160x120, this engine, 2026-11-23): the
engine's screen-space culling keeps the far-side faces of a cube
(the v1 convention behind the byte-identical golden), so the
point/spot tests place their lights on the far side of the cube,
where the visible faces actually receive diffuse light.
"""

import hashlib
import os
import shutil
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


def mean_brightness(img):
    cols = pixels_of(img)
    return sum(sum(c) for c in cols) / (len(cols) * 3)


def pixel_at(img, x, y):
    w, _h, px = img
    i = (y * w + x) * 3
    return tuple(px[i:i + 3])


class TestWaveAE2E(unittest.TestCase):
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
                "to build it: cannot run Wave A e2e")
        cls._tmp = tempfile.TemporaryDirectory(prefix="f3dc-wavea-e2e-")
        cls.tmp = Path(cls._tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def render(self, name, source, extra_files=None):
        """Compile+render one .f3d via the CLI; return (w, h, bytes)."""
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
        ppm = work / "build" / "output_render.ppm"
        self.assertTrue(ppm.is_file(), "no output_render.ppm for %s" % name)
        return read_ppm(ppm), ppm.read_bytes()

    # -- row 13: attenuation ------------------------------------------

    def test_attenuation_point_light_near_vs_far(self):
        # Same cube, same point light (placed behind the cube, on the
        # side its camera-visible faces point to): near must be
        # brighter than far.  Verified: mean 30.81 (near) vs 28.39.
        src = ("scene size 160 120\n"
               "camera at 3 2.5 4 look 0 0 0\n"
               "light point at %s intensity 5\n"
               "cube hero red at 0 0 0 size 2\n"
               "render still\n")
        near, _ = self.render("att_near", src % "-2 -2 -2")
        far, _ = self.render("att_far", src % "-9 -9 -9")
        self.assertGreater(mean_brightness(near), mean_brightness(far))

    def test_spot_cone_inside_vs_outside(self):
        # Cube at the cone axis (inside) vs displaced outside the
        # 25-degree cone (ambient + the default directional only).
        # Verified: mean 30.71 vs 28.50, max 146 vs 94.
        src = ("scene size 160 120\n"
               "camera at 3 2.5 4 look 0 0 0\n"
               "light spot at -4 -4 -4 look 0 0 0 angle 25 penumbra 0 "
               "intensity 20\n"
               "light ambient strength 0.25\n"
               "cube hero red at %s size 2\n"
               "render still\n")
        inside, _ = self.render("spot_in", src % "0 0 0")
        outside, _ = self.render("spot_out", src % "4 -2 0")
        self.assertGreater(mean_brightness(inside),
                           mean_brightness(outside))
        self.assertGreater(max(inside[2]), max(outside[2]))

    # -- row 14: fog ----------------------------------------------------

    def test_fog_moves_object_pixels_toward_fog_colour(self):
        # Default fog colour is white (255,255,255).  Verified over
        # object pixels: mean channel distance to white 679.9 (plain)
        # -> 405.8 (fogged); mean brightness 28.4 -> 119.7.
        plain_src = ("scene size 160 120\n"
                     "camera at 3 2.5 4 look 0 0 0\n"
                     "light directional\n"
                     "cube hero red at 0 0 0 size 2\n"
                     "render still\n")
        fog_src = plain_src.replace(
            "scene size 160 120\n",
            "scene size 160 120 fog linear near 2 far 12\n")
        plain, _ = self.render("fog_plain", plain_src)
        fogged, _ = self.render("fog_fogged", fog_src)

        def dist_to_fog(img):
            obj = [c for c in pixels_of(img) if c != BG]
            self.assertTrue(obj)
            return (sum(sum(abs(ch - 255) for ch in c) for c in obj)
                    / len(obj))

        self.assertLess(dist_to_fog(fogged), dist_to_fog(plain))
        self.assertGreater(mean_brightness(fogged),
                           mean_brightness(plain))

    # -- row 25: tonemapping ---------------------------------------------

    def test_tonemap_aces_differs_and_caps_white(self):
        # A white basic (unlit) cube: no tonemap -> brightest pixel
        # 255; ACES(1.0) ~= 0.8 -> 205 +/- 3.  Verified: 204.
        src = ("scene size 160 120%s\n"
               "camera at 3 2.5 4 look 0 0 0\n"
               "cube #FFFFFF material basic\n"
               "render still\n")
        plain, plain_raw = self.render("tm_plain", src % "")
        aces, aces_raw = self.render("tm_aces", src % " tonemap aces")
        self.assertNotEqual(plain_raw, aces_raw)
        self.assertEqual(max(plain[2]), 255)
        self.assertLessEqual(abs(max(aces[2]) - 205), 3)

    # -- row 11: PBR ------------------------------------------------------

    def test_pbr_metalness_changes_render(self):
        src = ("scene size 160 120\n"
               "camera at 3 2.5 4 look 0 0 0\n"
               "light point at 3 4 3 intensity 3\n"
               "sphere gray at 0 0 0 radius 1 material standard "
               "metalness %s roughness 0.3\n"
               "render still\n")
        dielectric, raw0 = self.render("pbr_m0", src % "0")
        metal, raw1 = self.render("pbr_m1", src % "1")
        self.assertNotEqual(raw0, raw1)
        self.assertTrue(
            mean_brightness(dielectric) != mean_brightness(metal)
            or max(dielectric[2]) != max(metal[2]))

    # -- row 15: texture ---------------------------------------------------

    def test_texture_checker_card_colours_present(self):
        # 4x4 black/white checker PPM written by the test.  The
        # rendered cube must contain BOTH texel colours (near-black
        # and near-white, after shading) and at least 4 distinct
        # greys.  Verified: (0,0,0) present, max channel 254, >100
        # distinct colours.
        checker = "P3\n4 4\n255\n" + "\n".join(
            " ".join("255 255 255" if (x + y) % 2 == 0 else "0 0 0"
                     for x in range(4))
            for y in range(4)) + "\n"
        src = ("scene size 160 120\n"
               "camera at 3 2.5 4 look 0 0 0\n"
               "light point at -2 -2 -2 intensity 5\n"
               "cube hero white at 0 0 0 size 2 "
               "texture \"checker.ppm\"\n"
               "render still\n")
        img, _ = self.render("texture", src, {"checker.ppm": checker})
        cols = pixels_of(img)
        self.assertIn((0, 0, 0), cols)
        self.assertGreaterEqual(max(img[2]), 250)
        greys = {c for c in cols if c[0] == c[1] == c[2]}
        self.assertGreaterEqual(len(greys), 4)

    # -- row 16: shadows ----------------------------------------------------

    # Verified 160x120 renders of the scene below (deterministic,
    # identical sha256 across separate tmp dirs): with `shadow soft`
    # the ground-plane pixels (104,59) and (105,59) -- on the plane
    # in the metal ball's shadow footprint -- are (17,17,19), vs
    # (19,19,19) with `shadow off`, and the region mean over
    # x 100..110, y 55..65 drops 35.132 -> 35.063.  The comparison is
    # on-vs-off at the same pixels because shadow_factor only scales
    # the diffuse term (the ambient term is never shadowed), so the
    # cast-shadow signal is small and a single-render lit/unlit
    # comparison would be confounded by spot-cone falloff.
    SHADOW_SRC = (
        "scene \"shadowtest\" size 160 120 background black "
        "fog linear near 14 far 34 tonemap aces shadow %s\n"
        "camera at 6 4 9 look 0 -1 0\n"
        "light spot at 2 7 5 look 0 -1 0 angle 38 penumbra 0.5 "
        "intensity 45 decay 2\n"
        "light point orange at -6 2 5 intensity 30 distance 0 decay 2\n"
        "light ambient strength 0.12\n"
        "plane ground gray at 0 -2 0 size 18 material standard "
        "metalness 0 roughness 0.95\n"
        "cube hero white at -3.2 -1 0 size 2 material standard "
        "metalness 0 roughness 0.8\n"
        "sphere ball blue at 0 -1 0 radius 1 material standard "
        "metalness 0 roughness 0.15\n"
        "sphere metal gray at 2.8 -1.1 0 radius 0.9 material standard "
        "metalness 1 roughness 0.3\n"
        "render still\n")

    def test_shadow_soft_darkens_plane_pixels(self):
        soft, soft_raw = self.render("shadow_soft",
                                     self.SHADOW_SRC % "soft")
        off, off_raw = self.render("shadow_off",
                                   self.SHADOW_SRC % "off")
        self.assertNotEqual(soft_raw, off_raw)
        for coord in ((104, 59), (105, 59)):
            self.assertLess(sum(pixel_at(soft, *coord)),
                            sum(pixel_at(off, *coord)),
                            "plane pixel %r not darkened by shadow"
                            % (coord,))

        def region_mean(img):
            vals = [sum(pixel_at(img, x, y))
                    for x in range(100, 111) for y in range(55, 66)]
            return sum(vals) / len(vals)

        self.assertLess(region_mean(soft), region_mean(off))

    # -- golden regression ---------------------------------------------------

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
