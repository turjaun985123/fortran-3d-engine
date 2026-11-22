#!/usr/bin/env python3
"""Wave D end-to-end tests (seat D11): f3dc CLI + the real Fortran engine.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/e2e/test_waved_e2e.py
    python3 -m unittest tests.e2e.test_waved_e2e

Mirrors ``tests/e2e/test_wavec_e2e.py``: scenes are driven in-process
through ``cli.main(["run", ...])`` into a ``tempfile`` tree and the
PPMs are read back with ``tests/golden/check_image.py``.
``setUpClass`` follows the Wave A/B/C pattern: ``make`` runs once
first (when gfortran+make are available) so ``bin/engine3d`` matches
the current sources; the suite skips loudly only when no engine
binary exists and none can be built.

Coverage (MASTER-PLAN row 7, Wave D geometries): a rendered PIXEL
PROOF per primitive family -- for each of the eleven new prims a
minimal single-object scene in a distinct saturated colour is built
and run through f3dc, and the test asserts the PPM exists, that more
than 300 non-background pixels belong to that prim's colour family,
and that the image is not flat (>= 3 distinct colours).  Plus the
shipped showcase ``examples/geometries.f3d`` end to end (>= 8
distinct dominant colours) and a determinism check (the showcase
rendered twice -> identical sha256).

Orientation notes (the known flat-prim trap): circle and ring are
flat discs in the XZ plane facing +Y (``src/geo_flat.f90``), so they
are rotated 90 degrees about X to face the camera head-on instead of
being seen edge-on.  A flat disc has a single face normal, hence a
single shade; those two scenes add a vignette filter, whose radial
falloff is what gives the disc its shading gradient (>= 3 distinct
colours).  Extrude footprints also lie in the XZ plane and grow
along +Y, so the extrude scene uses an elevated camera that sees
the top cap and two sides.
"""

import contextlib
import hashlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "f3dc"))
sys.path.insert(0, str(REPO_ROOT / "tests" / "golden"))

import cli  # noqa: E402
from check_image import read_ppm  # noqa: E402

BG = (25, 25, 35)
MIN_FAMILY_PIXELS = 300


def pixels_of(img):
    """(w, h, bytes) -> list of (r, g, b) tuples."""
    _w, _h, px = img
    return [tuple(px[i:i + 3]) for i in range(0, len(px), 3)]


def non_bg_count(img, bg=BG):
    return sum(1 for c in pixels_of(img) if c != bg)


def family_count(img, predicate):
    return sum(1 for c in pixels_of(img) if predicate(c))


# Colour-family predicates over shaded pixels.  The engine shades by
# scaling the named colour, so each predicate keys on the channel
# relationships of the prim's saturated base colour (see
# ir_nodes.NAMED_COLORS), not on one exact RGB triple.
FAMILIES = {
    "red": lambda c: c[0] > c[1] + 10 and c[0] > c[2] + 10,
    "orange": lambda c: c[0] > c[1] + 10 and c[1] > c[2] + 5,
    "green": lambda c: c[1] > c[0] + 20 and c[1] > c[2] + 20,
    "blue": lambda c: c[2] > c[0] + 20 and c[2] > c[1] + 20,
    "cyan": lambda c: c[1] > c[0] + 20 and c[2] > c[0] + 20,
    "magenta": lambda c: c[0] > c[1] + 15 and c[2] > c[1] + 15,
    "yellow": lambda c: c[0] > c[2] + 20 and c[1] > c[2] + 20,
    "purple": lambda c: c[2] > c[0] + 10 and c[0] > c[1] + 10,
    "pink": lambda c: c[0] > c[1] + 15 and c[0] > c[2] + 10,
    "gray": lambda c: max(c) - min(c) <= 12 and c[0] > 28,
}

CAM = ("scene size 320 240\n"
       "camera at 0 3 10 look 0 0 0\n")

# prim -> (colour family, scene source).  One object per scene, each
# sized/placed so it is genuinely visible from its camera (see the
# module docstring for the flat-prim orientation notes).
PRIM_SCENES = {
    "circle": ("red",
               CAM + "filter vignette 0.6\n"
               "circle red radius 2 rotate 90 0 0\n"
               "render still\n"),
    "ring": ("orange",
             CAM + "filter vignette 0.6\n"
             "ring orange inner 1 outer 2 rotate 90 0 0\n"
             "render still\n"),
    "capsule": ("green",
                CAM + "capsule green radius 1 height 2\n"
                "render still\n"),
    "tube": ("blue",
             CAM + "tube blue radius 0.5 "
             "path -2,0,0 0,1.5,0 2,0,0\n"
             "render still\n"),
    "lathe": ("cyan",
              CAM + "lathe cyan points 0,0 1,0.2 1,1.5 0,2 "
              "at 0 -1 0\n"
              "render still\n"),
    "extrude": ("magenta",
                "scene size 320 240\n"
                "camera at 5 5 9 look 0 0.5 0\n"
                "extrude magenta shape -1,-1 1,-1 1,1 -1,1 "
                "extrude_depth 1\n"
                "render still\n"),
    "tetrahedron": ("yellow",
                    CAM + "tetrahedron yellow radius 2\n"
                    "render still\n"),
    "octahedron": ("purple",
                   CAM + "octahedron purple radius 2\n"
                   "render still\n"),
    "icosahedron": ("pink",
                    CAM + "icosahedron pink radius 2\n"
                    "render still\n"),
    "dodecahedron": ("cyan",
                     CAM + "dodecahedron cyan radius 2\n"
                     "render still\n"),
    "torusknot": ("gray",
                  CAM + "torusknot gray radius 1.5 tube 0.5\n"
                  "render still\n"),
}


class TestWaveDE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        engine = REPO_ROOT / "bin" / "engine3d"
        have_toolchain = (shutil.which("gfortran") is not None
                          and shutil.which("make") is not None)
        if have_toolchain:
            build = subprocess.run(["make"], cwd=REPO_ROOT,
                                   capture_output=True, text=True)
            if build.returncode != 0:
                raise AssertionError("make failed:\n%s\n%s"
                                     % (build.stdout[-2000:],
                                        build.stderr[-2000:]))
        if not engine.is_file():
            raise unittest.SkipTest(
                "bin/engine3d missing and gfortran/make unavailable "
                "to build it: cannot run Wave D e2e")
        cls._tmp = tempfile.TemporaryDirectory(prefix="f3dc-waved-e2e-")
        cls.tmp = Path(cls._tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def run_cli(self, work, scene_path):
        """Run one .f3d file via the CLI into ``work/build``."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            code = cli.main(["run", str(scene_path),
                             "-o", str(work / "build")])
        self.assertEqual(code, 0, err.getvalue())
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
        line names its PPM (``geometries.ppm``), so the path is the
        example stem, not the generic ``output_render.ppm``.
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

    # -- per-primitive pixel proofs ------------------------------------

    def check_prim(self, prim):
        family, source = PRIM_SCENES[prim]
        img, _raw = self.render("prim_%s" % prim, source)
        fam = family_count(img, FAMILIES[family])
        distinct = len(set(pixels_of(img)))
        print("%s (%s): family=%d non-bg=%d distinct=%d"
              % (prim, family, fam, non_bg_count(img), distinct))
        self.assertGreater(
            fam, MIN_FAMILY_PIXELS,
            "%s rendered only %d %s-family pixels (need > %d)"
            % (prim, fam, family, MIN_FAMILY_PIXELS))
        self.assertGreaterEqual(
            distinct, 3,
            "%s image is flat: only %d distinct colours"
            % (prim, distinct))

    def test_circle_pixels(self):
        self.check_prim("circle")

    def test_ring_pixels(self):
        self.check_prim("ring")

    def test_capsule_pixels(self):
        self.check_prim("capsule")

    def test_tube_pixels(self):
        self.check_prim("tube")

    def test_lathe_pixels(self):
        self.check_prim("lathe")

    def test_extrude_pixels(self):
        self.check_prim("extrude")

    def test_tetrahedron_pixels(self):
        self.check_prim("tetrahedron")

    def test_octahedron_pixels(self):
        self.check_prim("octahedron")

    def test_icosahedron_pixels(self):
        self.check_prim("icosahedron")

    def test_dodecahedron_pixels(self):
        self.check_prim("dodecahedron")

    def test_torusknot_pixels(self):
        self.check_prim("torusknot")

    # -- the shipped showcase -------------------------------------------

    def test_geometries_example_end_to_end(self):
        _build, ppm = self.run_example("geometries", "geometries.f3d")
        self.assertTrue(ppm.is_file(), "no geometries.ppm")
        img = read_ppm(ppm)
        cols = pixels_of(img)
        counter = Counter(cols)
        bg = counter.most_common(1)[0][0]
        # A dominant colour = one covering at least 200 pixels; the
        # showcase's eleven distinctly coloured prims must yield at
        # least 8 of them (verified on this tree: 14).
        dominant = [c for c, n in counter.items()
                    if c != bg and n >= 200]
        print("geometries: distinct=%d dominant(>=200px)=%d non-bg=%d"
              % (len(counter), len(dominant),
                 sum(1 for c in cols if c != bg)))
        self.assertGreaterEqual(
            len(dominant), 8,
            "geometries showcase has only %d dominant colours"
            % len(dominant))

    def test_geometries_deterministic(self):
        _b1, ppm1 = self.run_example("geometries_a", "geometries.f3d")
        _b2, ppm2 = self.run_example("geometries_b", "geometries.f3d")
        self.assertTrue(ppm1.is_file())
        self.assertTrue(ppm2.is_file())
        self.assertEqual(hashlib.sha256(ppm1.read_bytes()).hexdigest(),
                         hashlib.sha256(ppm2.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
