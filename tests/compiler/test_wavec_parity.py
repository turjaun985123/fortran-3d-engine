#!/usr/bin/env python3
"""Wave C compiler parity tests (seat B83, MASTER-PLAN section 3).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_wavec_parity.py

Mirrors the Wave B parity harness (``test_waveb_parity.py``): the
compile tests drive the real pipeline -- ``parser.parse`` ->
``validate.validate`` -> ``emit_fortran.emit_scene_text`` -- and are
named for the MASTER-PLAN section 3 row they prove:

    row 30  Post-processing     filter lines -> ordered post lines
                                (src/postprocess.f90, ext_post.py)
    row  3  Orthographic cam.   camera ortho -> ortho .scene line
                                (src/camera_ortho.f90, ext_cameras.py)
    row 22  True instancing     instance lines (scene.f90 appends a
                                copy of the source object)
    row 26  Multi-scene files   cli check/build split a 2-scene .f3d
                                into per-scene outputs

Three of the rows also carry a *rendered* assertion (gamma changes
pixels, ortho equalises sphere sizes, instances are visible), so --
unlike the pure-compile Wave B file -- this harness also renders
small scenes (320x240 stills) through ``cli.main(["run", ...])``
exactly like the e2e suites, reading PPMs back with
``tests/golden/check_image.py``.  ``make`` runs once (module level)
when gfortran+make are available so ``bin/engine3d`` matches the
current sources; the render tests skip loudly only when no engine
binary exists and none can be built.

Verified numbers on this tree (2026-11-23, 320x240): the ortho
sphere pair renders exactly 2764 red-dominant and 2764
blue-dominant pixels (perspective: 721 vs 4041); base cube alone
489 non-background pixels vs 1858 with its 3 instances.
"""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "f3dc"))
sys.path.insert(0, str(REPO_ROOT / "tests" / "golden"))

import cli  # noqa: E402
import emit_fortran  # noqa: E402
import parser  # noqa: E402
import validate  # noqa: E402
from check_image import read_ppm  # noqa: E402
from errors import ErrorBag  # noqa: E402

BG = (25, 25, 35)


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


# ----------------------------------------------------------------------
# Render support (for the rows whose parity claim is about pixels)
# ----------------------------------------------------------------------

_engine_ready = None


def ensure_engine():
    """Build bin/engine3d once if a toolchain is available.

    Returns True when a usable engine binary exists afterwards.
    """
    global _engine_ready
    if _engine_ready is not None:
        return _engine_ready
    engine = REPO_ROOT / "bin" / "engine3d"
    if (shutil.which("gfortran") is not None
            and shutil.which("make") is not None):
        build = subprocess.run(["make"], cwd=REPO_ROOT,
                               capture_output=True, text=True)
        if build.returncode != 0:
            raise AssertionError("make failed:\n%s\n%s"
                                 % (build.stdout[-2000:],
                                    build.stderr[-2000:]))
    _engine_ready = engine.is_file()
    return _engine_ready


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


class RenderMixin:
    """cli.main(["run", ...]) into a per-class temp tree (e2e pattern)."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._tmp = tempfile.TemporaryDirectory(prefix="f3dc-wavec-parity-")
        cls.tmp = Path(cls._tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()
        super().tearDownClass()

    def render(self, name, source):
        """Compile+render one .f3d via the CLI; return (img, raw_bytes)."""
        if not ensure_engine():
            self.skipTest("bin/engine3d missing and gfortran/make "
                          "unavailable to build it")
        work = self.tmp / name
        work.mkdir(parents=True, exist_ok=True)
        scene = work / "scene.f3d"
        scene.write_text(source, encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            code = cli.main(["run", str(scene), "-o", str(work / "build")])
        self.assertEqual(code, 0, err.getvalue())
        ppm = work / "build" / "output_render.ppm"
        self.assertTrue(ppm.is_file(), "no output_render.ppm for %s" % name)
        return read_ppm(ppm), ppm.read_bytes()


# ----------------------------------------------------------------------
# Row 30: post-processing filter chain
# ----------------------------------------------------------------------

class TestRow30Post(RenderMixin, unittest.TestCase):
    def test_row30_filter_lines_compile_to_post_lines_in_order(self):
        lines = emit_lines(
            "filter bloom 0.6\n"
            "filter vignette 0.4\n"
            "filter gamma 1.2\n"
            "cube red\n")
        self.assertEqual(lines_starting(lines, "post"), [
            "post bloom 0.6",
            "post vignette 0.4",
            "post gamma 1.2",
        ])

    def test_row30_all_six_filters_with_defaults_in_order(self):
        lines = emit_lines(
            "filter blur\n"
            "filter bloom\n"
            "filter vignette\n"
            "filter gamma\n"
            "filter grayscale\n"
            "filter sepia\n"
            "cube red\n")
        self.assertEqual(lines_starting(lines, "post"), [
            "post blur 1",
            "post bloom 0.5",
            "post vignette 0.5",
            "post gamma 2.2",
            "post grayscale 1",
            "post sepia 1",
        ])

    def test_row30_unknown_filter_is_a_compile_error(self):
        scene, codes = run("filter sharpen 1\ncube red\n")
        self.assertIsNone(scene)
        self.assertIn("E301", codes)

    def test_row30_gamma_changes_pixels_vs_no_filter(self):
        base = ("scene size 320 240\n"
                "camera at 6 4 9 look 0 0 0\n"
                "cube hero red at 0 0 0 size 2\n"
                "sphere ball blue at 3 0 0 radius 1\n"
                "render still\n")
        filtered = base.replace(
            "scene size 320 240\n",
            "scene size 320 240\nfilter gamma 0.5\n")
        _img_plain, raw_plain = self.render("post_plain", base)
        _img_gamma, raw_gamma = self.render("post_gamma", filtered)
        self.assertNotEqual(raw_plain, raw_gamma)


# ----------------------------------------------------------------------
# Row 3: orthographic camera
# ----------------------------------------------------------------------

# Two identical radius-1 spheres at very different depths: the red
# one far from the camera (z=-4, camera at z=10), the blue one near
# (z=4).  Perspective draws the near one much larger; ortho must not.
SPHERE_PAIR = (
    "scene size 320 240\n"
    "camera %s\n"
    "sphere far_sphere red at -2,0,-4 radius 1\n"
    "sphere near_sphere blue at 2,0,4 radius 1\n"
    "render still\n")


class TestRow03Ortho(RenderMixin, unittest.TestCase):
    def test_row03_ortho_line_in_scene(self):
        lines = emit_lines("camera ortho size 12\ncube red\n")
        self.assertEqual(lines_starting(lines, "ortho"), ["ortho 12"])

    def test_row03_ortho_default_size_line(self):
        lines = emit_lines("camera ortho\ncube red\n")
        self.assertEqual(lines_starting(lines, "ortho"), ["ortho 5"])

    def test_row03_perspective_scene_has_no_ortho_line(self):
        lines = emit_lines(
            "camera at 0 0 10 look 0 0 0\ncube red\n")
        self.assertEqual(lines_starting(lines, "ortho"), [])

    def test_row03_ortho_equalises_sphere_sizes(self):
        persp, _raw = self.render(
            "ortho_pair_persp", SPHERE_PAIR % "at 0 0 10 look 0 0 0")
        ortho, _raw = self.render(
            "ortho_pair_ortho",
            SPHERE_PAIR % "ortho size 8 at 0,0,10 look 0,0,0")
        p_red, p_blue = dominant_count(persp, 0), dominant_count(persp, 2)
        o_red, o_blue = dominant_count(ortho, 0), dominant_count(ortho, 2)
        # Both spheres are really rendered in both projections.
        for count in (p_red, p_blue, o_red, o_blue):
            self.assertGreater(count, 100)
        # Perspective: clearly different sizes (verified 721 vs 4041).
        self.assertGreater(max(p_red, p_blue),
                           3 * min(p_red, p_blue))
        # Ortho: near-equal sizes (verified exactly 2764 vs 2764).
        self.assertLess(max(o_red, o_blue),
                        1.5 * min(o_red, o_blue))


# ----------------------------------------------------------------------
# Row 22: true instancing
# ----------------------------------------------------------------------

class TestRow22Instancing(RenderMixin, unittest.TestCase):
    def test_row22_instance_lines_in_scene(self):
        lines = emit_lines(
            "cube base yellow at -4,-1.5,4 size 1\n"
            "instance c1 of base at -2,-1.5,4\n"
            "instance c2 of base at 0,-1.5,4 rotate 0,45,0\n"
            "instance c3 of base at 2,-1.5,4 scale 0.7\n")
        self.assertEqual(lines_starting(lines, "instance"), [
            "instance c1 base -2 -1.5 4 0 0 0 1",
            "instance c2 base 0 -1.5 4 0 45 0 1",
            "instance c3 base 2 -1.5 4 0 0 0 0.7",
        ])

    def test_row22_instance_of_unknown_source_is_e201(self):
        scene, codes = run(
            "cube base yellow at 0,0,0 size 1\n"
            "instance c1 of nope at 1,0,0\n")
        self.assertIsNone(scene)
        self.assertIn("E201", codes)

    def test_row22_rendered_instance_copies_are_visible(self):
        base = ("scene size 320 240\n"
                "camera at 0 2 12 look 0 0 0\n"
                "cube base yellow at -6,0,0 size 1\n"
                "%s"
                "render still\n")
        instances = ("instance i1 of base at -2,0,0\n"
                     "instance i2 of base at 2,0,0\n"
                     "instance i3 of base at 6,0,0\n")
        img_base, _raw = self.render("inst_base", base % "")
        img_full, _raw = self.render("inst_full", base % instances)
        base_px = non_bg_count(img_base)
        full_px = non_bg_count(img_full)
        self.assertGreater(base_px, 0)
        # Verified: 489 (base alone) vs 1858 (base + 3 instances).
        self.assertGreater(full_px, base_px)
        self.assertGreater(full_px, int(1.5 * base_px))


# ----------------------------------------------------------------------
# Row 26: multi-scene files
# ----------------------------------------------------------------------

class TestRow26MultiScene(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.work = Path(self._tmp.name)
        # Work on a copy so the check/build chunk temp files never
        # touch the repo's examples/ tree.
        self.example = self.work / "multi-scene.f3d"
        self.example.write_text(
            (REPO_ROOT / "examples" / "multi-scene.f3d").read_text(
                encoding="utf-8"),
            encoding="utf-8")

    def test_row26_check_succeeds_and_reports_2_scenes(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            code = cli.main(["check", str(self.example)])
        self.assertEqual(code, 0, err.getvalue())
        text = out.getvalue()
        self.assertIn("scene 1/2: multi-scene-one", text)
        self.assertIn("scene 2/2: multi-scene-two", text)
        self.assertIn("multi-scene: 2 scenes", text)

    def test_row26_build_produces_both_scene_artifacts(self):
        out_dir = self.work / "build"
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            code = cli.main(["build", str(self.example),
                             "-o", str(out_dir)])
        self.assertEqual(code, 0, err.getvalue())
        one = out_dir / "multi-scene-multi-scene-one.scene"
        two = out_dir / "multi-scene-multi-scene-two.scene"
        self.assertTrue(one.is_file(), "missing %s" % one)
        self.assertTrue(two.is_file(), "missing %s" % two)
        # Each block kept its own size: the scenes really are split.
        self.assertIn("size 320 240", one.read_text(encoding="utf-8"))
        self.assertIn("size 640 480", two.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
