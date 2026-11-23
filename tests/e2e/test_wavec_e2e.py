#!/usr/bin/env python3
"""Wave C end-to-end tests (seat B83): f3dc CLI + the real Fortran engine.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/e2e/test_wavec_e2e.py

Mirrors ``tests/e2e/test_waveb_e2e.py``: scenes are driven via
subprocess through the native ``bin/f3dc`` binary
(``f3dc run ...``) into a ``tempfile`` tree and the
PPMs are read back with ``tests/golden/check_image.py``.
``setUpClass`` follows the Wave A/B pattern: ``make`` runs once first
(when gfortran+make are available) so ``bin/engine3d`` matches the
current sources; the suite skips loudly only when no engine binary
exists and none can be built.

Coverage (MASTER-PLAN section 3, Wave C):

    rows 30+3+22  examples/post-ortho.f3d end to end (the shipped
                  showcase: ortho camera, bloom/vignette/gamma chain,
                  instanced cube row, three depth spheres)
    row 26        examples/multi-scene.f3d run -> two distinct PPMs
    housekeeping  lone-plane regression (clip-space clipping fix):
                  plane size 8 and size 15 both render, and the
                  larger plane covers more pixels (B98 repro)
    golden        the two byte-identical legacy regressions
    determinism   post-ortho rendered twice -> identical sha256

Verified numbers on this tree (2026-11-23): post-ortho renders 106
distinct colours with 4981 red-dominant / 4991 green-dominant /
3671 blue-dominant pixels (the three identical depth spheres);
multi-scene outputs are 320x240 (dark bg) and 640x480 (white bg);
lone planes cover 36023 (size 8) and 58655 (size 15) non-background
pixels at 320x240.
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


def pixels_of(img):
    """(w, h, bytes) -> list of (r, g, b) tuples."""
    _w, _h, px = img
    return [tuple(px[i:i + 3]) for i in range(0, len(px), 3)]


def non_bg_count(img, bg=BG):
    return sum(1 for c in pixels_of(img) if c != bg)


def dominant_count(img, channel):
    """Pixels where ``channel`` (0/1/2) beats both others by > 20."""
    others = [i for i in range(3) if i != channel]
    return sum(1 for c in pixels_of(img)
               if c[channel] > c[others[0]] + 20
               and c[channel] > c[others[1]] + 20)


class TestWaveCE2E(unittest.TestCase):
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
                "to build it: cannot run Wave C e2e")
        if not F3DC.is_file():
            raise unittest.SkipTest(
                "native f3dc binary missing (looked for $F3DC, "
                "bin/f3dc, compiler/f3dc): cannot run Wave C e2e")
        cls._tmp = tempfile.TemporaryDirectory(prefix="f3dc-wavec-e2e-")
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

    def render(self, name, source, extra_files=None):
        """Compile+render one inline .f3d; return (img, raw_ppm_bytes)."""
        work = self.tmp / name
        work.mkdir(parents=True, exist_ok=True)
        for fname, content in (extra_files or {}).items():
            (work / fname).write_text(content, encoding="ascii")
        scene = work / "scene.f3d"
        scene.write_text(source, encoding="utf-8")
        build = self.run_cli(work, scene)
        ppm = build / "output_render.ppm"
        self.assertTrue(ppm.is_file(), "no output_render.ppm for %s" % name)
        return read_ppm(ppm), ppm.read_bytes()

    def run_example(self, name, example_name):
        """Copy a shipped example into a work dir and run it.

        Returns (build_dir, output_render_ppm_path).  The example
        keeps its own filename so multi-scene artifact stems match
        the shipped names.
        """
        work = self.tmp / name
        work.mkdir(parents=True, exist_ok=True)
        scene = work / example_name
        scene.write_text(
            (REPO_ROOT / "examples" / example_name).read_text(
                encoding="utf-8"),
            encoding="utf-8")
        build = self.run_cli(work, scene)
        return build, build / "output_render.ppm"

    # -- rows 30 + 3 + 22: the post-ortho showcase ----------------------

    def test_post_ortho_example_end_to_end(self):
        _build, ppm = self.run_example("post_ortho", "post-ortho.f3d")
        self.assertTrue(ppm.is_file(), "no output_render.ppm")
        img = read_ppm(ppm)
        cols = pixels_of(img)
        # The ordered bloom/vignette/gamma chain over a lit scene is
        # anything but flat (verified: 106 distinct colours).
        self.assertGreater(len(set(cols)), 20)
        # The three identical depth spheres (red / green / blue at
        # z = -6 / 0 / 6) must each render a meaningful number of
        # dominant-colour pixels under the ortho camera -- verified
        # 4981 / 4991 / 3671, so 500 is a conservative floor, not a
        # weakened assertion.
        for channel, label in ((0, "red/near"), (1, "green/mid"),
                               (2, "blue/far")):
            self.assertGreater(
                dominant_count(img, channel), 500,
                "%s depth sphere barely visible: %d dominant pixels"
                % (label, dominant_count(img, channel)))

    def test_post_ortho_deterministic(self):
        _b1, ppm1 = self.run_example("post_ortho_a", "post-ortho.f3d")
        _b2, ppm2 = self.run_example("post_ortho_b", "post-ortho.f3d")
        self.assertEqual(hashlib.sha256(ppm1.read_bytes()).hexdigest(),
                         hashlib.sha256(ppm2.read_bytes()).hexdigest())

    # -- row 26: multi-scene ---------------------------------------------

    def test_multi_scene_run_produces_two_distinct_outputs(self):
        build, _ppm = self.run_example("multi_scene", "multi-scene.f3d")
        one = build / "multi-scene-multi-scene-one.ppm"
        two = build / "multi-scene-multi-scene-two.ppm"
        self.assertTrue(one.is_file(), "missing %s" % one)
        self.assertTrue(two.is_file(), "missing %s" % two)
        img1, img2 = read_ppm(one), read_ppm(two)
        # Different sizes: scene 1 is 320x240, scene 2 is 640x480.
        self.assertEqual((img1[0], img1[1]), (320, 240))
        self.assertEqual((img2[0], img2[1]), (640, 480))
        # Different backgrounds: scene 1's most frequent colour is
        # dark (black background, shaded), scene 2's is its white
        # background (240,240,240).
        bg1 = Counter(pixels_of(img1)).most_common(1)[0][0]
        bg2 = Counter(pixels_of(img2)).most_common(1)[0][0]
        self.assertLess(sum(bg1), 100, "scene 1 bg not dark: %r" % (bg1,))
        self.assertGreater(sum(bg2), 600,
                           "scene 2 bg not light: %r" % (bg2,))
        self.assertNotEqual(one.read_bytes(), two.read_bytes())

    # -- housekeeping: lone-plane regression (B98 repro) ------------------

    def test_plane_regression_lone_plane_sizes_render(self):
        # A lone plane from the default camera: before the clip-space
        # clipping fix these could vanish entirely.  Both sizes must
        # render, and coverage grows with size (verified 36023 px at
        # size 8, 58655 px at size 15, 320x240).
        counts = {}
        for size in (8, 15):
            src = ("scene size 320 240\n"
                   "plane ground gray at 0 -2 0 size %d\n"
                   "render still\n" % size)
            img, _raw = self.render("plane_%d" % size, src)
            counts[size] = non_bg_count(img)
            self.assertGreater(counts[size], 0,
                               "lone plane size %d rendered nothing"
                               % size)
        self.assertGreater(counts[15], counts[8])

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
