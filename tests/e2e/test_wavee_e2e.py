#!/usr/bin/env python3
"""Wave E end-to-end tests (seat E12): f3dc CLI + the real Fortran engine.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/e2e/test_wavee_e2e.py

Mirrors ``tests/e2e/test_wavec_e2e.py`` / ``test_waved_e2e.py``:
scenes are driven via subprocess through the native ``bin/f3dc``
binary (``f3dc run ...``)
into a ``tempfile`` tree and the PPMs are read back with
``tests/golden/check_image.py``.  ``setUpClass`` follows the
Wave A/B/C/D pattern: ``make`` runs once first (when gfortran+make
are available) so ``bin/engine3d`` matches the current sources;
the suite skips loudly only when no engine binary exists and none
can be built.

Coverage (Wave E: custom shaders, morph targets, skinning):

    shaders   a constant shader (``0.5``) renders every covered
              pixel exactly (128,128,128); shader ``c`` vs ``0``
              vs no shader are pairwise different, and ``0`` covers
              in pure black; the shipped checker expression yields
              exactly two covered colours, one of them black;
              shader ``c`` is byte-identical to ``material basic``
              (verified on this tree -- the strong form, not a
              centre-pixel approximation)
    morphs    factor 0 is a byte-identical identity on a sphere;
              bulge 1 changes both the hash and the covered-pixel
              count (on a cone -- see the note in
              test_morph_changes_render for why not a sphere)
    skinning  a zero-rotation bone is a byte-identical identity on
              a cylinder; a 30-degree bone bends it (hash differs)
    showcase  examples/wavee-showcase.f3d renders deterministically
              (two runs, identical sha256), with > 5000 non-bg
              pixels and >= 8 distinct colours
    golden    the no-arg legacy engine render is unchanged

Verified numbers on this tree (2026-11-23), all at 320x240 with
background (25, 25, 35) unless noted: the constant/checker/identity
cube scenes each cover 2757 pixels; the checker cube's covered
colours are exactly {(0,0,0), (220,60,60)}; the cone covers 1331
pixels plain and 2118 with ``morph s bulge 1``; the cylinder
covers 2692 pixels plain and 2543 skinned at 30 degrees; the
showcase (800x600, background (20,20,25)) covers 20031 non-bg
pixels with 397 distinct colours.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tests" / "golden"))

from check_image import read_ppm  # noqa: E402


def _resolve_f3dc():
    """Native compiler binary: $F3DC, else bin/f3dc, else compiler/f3dc."""
    env = os.environ.get("F3DC")
    if env:
        return Path(env)
    bin_f3dc = REPO_ROOT / "bin" / "f3dc"
    if bin_f3dc.is_file():
        return bin_f3dc
    return REPO_ROOT / "compiler" / "f3dc"


F3DC = _resolve_f3dc()

GOLDEN_SHA256 = ("28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56"
                 "fa90e05ac7697cec1")
BG = (25, 25, 35)

CAM = ("scene size 320 240\n"
       "camera at 0 3 10 look 0 0 0\n")
CUBE = "cube red at 0 0 0 size 2"


def pixels_of(img):
    """(w, h, bytes) -> list of (r, g, b) tuples."""
    _w, _h, px = img
    return [tuple(px[i:i + 3]) for i in range(0, len(px), 3)]


def covered(img, bg=BG):
    """Pixels that are not the background colour."""
    return [c for c in pixels_of(img) if c != bg]


def non_bg_count(img, bg=BG):
    return len(covered(img, bg))


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


class TestWaveEE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        engine = REPO_ROOT / "bin" / "engine3d"
        have_toolchain = (shutil.which("gfortran") is not None
                          and shutil.which("make") is not None)
        if have_toolchain:
            # Freshen the binary once so it matches the current
            # sources.
            build = subprocess.run(["make"], cwd=REPO_ROOT,
                                   capture_output=True, text=True)
            if build.returncode != 0:
                raise AssertionError("make failed:\n%s\n%s"
                                     % (build.stdout[-2000:],
                                        build.stderr[-2000:]))
        if not engine.is_file():
            raise unittest.SkipTest(
                "bin/engine3d missing and gfortran/make unavailable "
                "to build it: cannot run Wave E e2e")
        if not F3DC.is_file():
            raise unittest.SkipTest(
                "native f3dc binary missing (looked for $F3DC, "
                "bin/f3dc, compiler/f3dc): cannot run Wave E e2e")
        cls._tmp = tempfile.TemporaryDirectory(prefix="f3dc-wavee-e2e-")
        cls.tmp = Path(cls._tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def run_cli(self, work, scene_path):
        """Run one .f3d file via the native f3dc binary into ``work/build``."""
        proc = subprocess.run(
            [str(F3DC), "run", str(scene_path),
             "-o", str(work / "build")],
            cwd=REPO_ROOT, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0,
                         proc.stdout + proc.stderr)
        return work / "build"

    def render(self, name, source):
        """Compile+render one inline .f3d; return (img, raw_ppm_bytes)."""
        work = self.tmp / name
        work.mkdir(parents=True, exist_ok=True)
        scene = work / "scene.f3d"
        scene.write_text(source, encoding="utf-8")
        build = self.run_cli(work, scene)
        ppm = build / "output_render.ppm"
        self.assertTrue(ppm.is_file(), "no output_render.ppm for %s" % name)
        return read_ppm(ppm), ppm.read_bytes()

    def run_example(self, name, example_name):
        """Copy a shipped example into a work dir and run it.

        Returns (build_dir, ppm_path).  The example's own render
        line names its PPM (``wavee-showcase.ppm``), so the path is
        the example stem, not the generic ``output_render.ppm``.
        """
        work = self.tmp / name
        work.mkdir(parents=True, exist_ok=True)
        scene = work / example_name
        scene.write_text(
            (REPO_ROOT / "examples" / example_name).read_text(
                encoding="utf-8"),
            encoding="utf-8")
        build = self.run_cli(work, scene)
        stem = example_name[:-len(".f3d")]
        return build, build / ("%s.ppm" % stem)

    # -- custom shaders ---------------------------------------------------

    def test_shader_constant_exact(self):
        src = (CAM + 'shader half expr "0.5"\n'
               + CUBE + " shader half\n"
               "render still\n")
        img, _raw = self.render("shader_const", src)
        cov = covered(img)
        self.assertGreater(len(cov), 0, "constant-shader cube covered "
                                        "no pixels")
        self.assertEqual(set(cov), {(128, 128, 128)},
                         "every covered pixel must be exactly "
                         "(128,128,128); got %r" % (set(cov),))

    def test_two_shaders_differ(self):
        _img_c, raw_c = self.render(
            "shader_c", CAM + 'shader ident expr "c"\n'
            + CUBE + " shader ident\nrender still\n")
        img_0, raw_0 = self.render(
            "shader_0", CAM + 'shader zero expr "0"\n'
            + CUBE + " shader zero\nrender still\n")
        _img_n, raw_none = self.render(
            "shader_none", CAM + CUBE + "\nrender still\n")
        hashes = {sha256(raw_c), sha256(raw_0), sha256(raw_none)}
        self.assertEqual(len(hashes), 3,
                         "shader c / shader 0 / no shader must be "
                         "pairwise different renders")
        cov0 = covered(img_0)
        self.assertGreater(len(cov0), 0, "zero-shader cube covered "
                                         "no pixels")
        self.assertEqual(set(cov0), {(0, 0, 0)},
                         "shader 0 covered pixels must all be "
                         "(0,0,0); got %r" % (set(cov0),))

    def test_checker_pattern_two_values(self):
        src = (CAM + 'shader checker expr '
               '"c * step(0.5, fract((x + y) * 2))"\n'
               + CUBE + " shader checker\n"
               "render still\n")
        img, _raw = self.render("shader_checker", src)
        distinct = set(covered(img))
        self.assertGreaterEqual(len(distinct), 2,
                                "checker must produce >= 2 distinct "
                                "covered colours; got %r" % (distinct,))
        self.assertIn((0, 0, 0), distinct,
                      "one checker colour must be (0,0,0); got %r"
                      % (distinct,))

    def test_shader_identity_matches_unlit(self):
        # Shader "c" returns the channel unchanged, so it must match
        # the unlit `material basic` render of the same cube.  On
        # this tree the match is EXACT (verified: identical sha256),
        # so this asserts the strong form -- byte-identical PPMs --
        # not the centre-pixel / covered-set fallback.
        _img_s, raw_shader = self.render(
            "shader_ident", CAM + 'shader ident expr "c"\n'
            + CUBE + " shader ident\nrender still\n")
        _img_b, raw_basic = self.render(
            "shader_basic", CAM + CUBE + " material basic\n"
            "render still\n")
        self.assertEqual(raw_shader, raw_basic,
                         "shader 'c' render is not byte-identical to "
                         "the material basic render")

    # -- morph targets ------------------------------------------------------

    def test_morph_factor_zero_is_identity(self):
        plain = CAM + "sphere s green at 0 0 0 radius 1\nrender still\n"
        morphed = (CAM + "sphere s green at 0 0 0 radius 1\n"
                   "morph s bulge 0\nrender still\n")
        _img_p, raw_plain = self.render("morph_plain", plain)
        _img_m, raw_morph = self.render("morph_zero", morphed)
        self.assertEqual(raw_plain, raw_morph,
                         "morph bulge 0 must be a byte-identical "
                         "identity")

    def test_morph_changes_render(self):
        # A cone, not the sphere of the identity test: in
        # src/skinning.f90 the bulge scale is
        # 1 + factor*0.5*(1 - (dist/maxr)^2), and every vertex of a
        # sphere (likewise a cube or a capped cylinder) sits at
        # dist == maxr, so bulge is an exact no-op on those meshes
        # at ANY factor.  A cone's vertices span a range of dist,
        # so bulge genuinely reshapes it (verified: 1331 -> 2118
        # covered pixels at factor 1).
        plain = CAM + "cone s orange at 0 0 0 radius 1 height 3\nrender still\n"
        bulged = (CAM + "cone s orange at 0 0 0 radius 1 height 3\n"
                  "morph s bulge 1\nrender still\n")
        img_p, raw_plain = self.render("morph_cone_plain", plain)
        img_b, raw_bulge = self.render("morph_cone_bulge", bulged)
        self.assertNotEqual(sha256(raw_plain), sha256(raw_bulge),
                            "bulge 1 must change the render")
        self.assertNotEqual(non_bg_count(img_p), non_bg_count(img_b),
                            "bulge 1 must change the covered-pixel "
                            "count (%d vs %d)"
                            % (non_bg_count(img_p), non_bg_count(img_b)))

    # -- skinning -----------------------------------------------------------

    CYL = "cylinder p yellow at 0 0 0 radius 1 height 3"

    def test_skin_zero_rotation_is_identity(self):
        plain = CAM + self.CYL + "\nrender still\n"
        skinned = (CAM + self.CYL + "\n"
                   "bone b at 0,0,0 rotate 0,0,0 radius 3\n"
                   "skin p b\nrender still\n")
        _img_p, raw_plain = self.render("skin_plain", plain)
        _img_s, raw_skin = self.render("skin_zero", skinned)
        self.assertEqual(raw_plain, raw_skin,
                         "skin with a zero-rotation bone must be a "
                         "byte-identical identity")

    def test_skin_bends_render(self):
        plain = CAM + self.CYL + "\nrender still\n"
        bent = (CAM + self.CYL + "\n"
                "bone b at 0,0,0 rotate 0,0,30 radius 3\n"
                "skin p b\nrender still\n")
        _img_p, raw_plain = self.render("skin_plain_bend", plain)
        _img_b, raw_bent = self.render("skin_bent", bent)
        self.assertNotEqual(sha256(raw_plain), sha256(raw_bent),
                            "a 30-degree bone must bend the render")

    # -- the shipped showcase ----------------------------------------------

    def test_showcase_renders_and_deterministic(self):
        _b1, ppm1 = self.run_example("showcase_a", "wavee-showcase.f3d")
        _b2, ppm2 = self.run_example("showcase_b", "wavee-showcase.f3d")
        self.assertTrue(ppm1.is_file(), "no wavee-showcase.ppm")
        self.assertTrue(ppm2.is_file(), "no wavee-showcase.ppm")
        raw1, raw2 = ppm1.read_bytes(), ppm2.read_bytes()
        self.assertEqual(sha256(raw1), sha256(raw2),
                         "showcase must render deterministically")
        img = read_ppm(ppm1)
        cols = pixels_of(img)
        # The showcase's background is its most frequent colour
        # (verified (20,20,25) at 800x600), not the 320x240 default.
        bg = Counter(cols).most_common(1)[0][0]
        n_non_bg = sum(1 for c in cols if c != bg)
        self.assertGreater(n_non_bg, 5000,
                           "showcase covers only %d non-bg pixels"
                           % n_non_bg)
        self.assertGreaterEqual(len(set(cols)), 8,
                                "showcase has only %d distinct colours"
                                % len(set(cols)))

    # -- golden regression ----------------------------------------------------

    def test_golden_unchanged(self):
        engine = REPO_ROOT / "bin" / "engine3d"
        if not engine.is_file():
            self.skipTest("bin/engine3d missing: cannot run the "
                          "golden no-arg regression")
        work = self.tmp / "golden_noarg"
        work.mkdir(parents=True, exist_ok=True)
        proc = subprocess.run([str(engine)], cwd=work,
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        ppm = work / "output_render.ppm"
        self.assertTrue(ppm.is_file())
        self.assertEqual(hashlib.sha256(ppm.read_bytes()).hexdigest(),
                         GOLDEN_SHA256)


if __name__ == "__main__":
    unittest.main(verbosity=2)
