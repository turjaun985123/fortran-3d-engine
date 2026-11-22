#!/usr/bin/env python3
"""Wave A compiler parity tests (seat B61, MASTER-PLAN section 3).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_wavea_parity.py

Every test drives the real pipeline -- ``parser.parse`` ->
``validate.validate`` -> ``emit_fortran.emit_scene_text`` -- and is
named for the MASTER-PLAN section 3 row it proves:

    row 11  MeshStandardMaterial (PBR)     material standard objmat line
    row 13  Point / Spot lights            light point / light spot lines
    row 14  Fog                            fog linear / exp2 scene lines
    row 15  Textures / UV                  texture objmat line (PPM)
    row 16  Shadows                        shadow scene lines
    row 25  Tone mapping / colour space    tonemap scene lines

Plus the v1 stability contract: a plain ``cube`` scene emits exactly
the v1 .scene shape -- no Wave A lines at all.
"""

import os
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
import parser  # noqa: E402
import validate  # noqa: E402
from errors import ErrorBag  # noqa: E402


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


class TestRow11PBR(unittest.TestCase):
    def test_row11_pbr_objmat_line_exact_fields(self):
        lines = emit_lines(
            "cube red material standard metalness 0 roughness 0.5\n")
        # objmat NAME standard METALNESS ROUGHNESS SPECULAR SHININESS TEX
        self.assertEqual(lines_starting(lines, "objmat"),
                         ["objmat cube1 standard 0 0.5 0.5 32 -"])

    def test_row11_pbr_defaults(self):
        lines = emit_lines("cube red material standard\n")
        self.assertEqual(lines_starting(lines, "objmat"),
                         ["objmat cube1 standard 0 1 0.5 32 -"])


class TestRow13PointSpotLights(unittest.TestCase):
    def test_row13_point_light_line(self):
        lines = emit_lines("light point at 3,4,3 intensity 2\ncube red\n")
        # light point px py pz R G B intensity distance decay
        self.assertEqual(lines_starting(lines, "light point"),
                         ["light point 3 4 3 255 255 255 2 0 2"])

    def test_row13_spot_light_line_normalised_dir(self):
        lines = emit_lines(
            "light spot at 0,5,0 look 0,0,0 angle 30 penumbra 0.5\n"
            "cube red\n")
        # Direction is normalise(target - position) = (0,-1,0);
        # intensity defaults to 1, distance 0 (no cutoff), decay 2.
        self.assertEqual(
            lines_starting(lines, "light spot"),
            ["light spot 0 5 0 0 -1 0 255 255 255 1 0 2 30 0.5"])


class TestRow14Fog(unittest.TestCase):
    def test_row14_fog_linear_line(self):
        lines = emit_lines("scene fog linear near 8 far 30\ncube red\n")
        self.assertEqual(lines_starting(lines, "fog"),
                         ["fog linear 8 30 255 255 255"])

    def test_row14_fog_exp2_line(self):
        lines = emit_lines("scene fog exp2 density 0.05\ncube red\n")
        self.assertEqual(lines_starting(lines, "fog"),
                         ["fog exp2 0.05 255 255 255"])

    def test_row14_fog_linear_near_not_below_far_is_error(self):
        scene, codes = run("scene fog linear near 20 far 5\ncube red\n")
        self.assertIsNone(scene)
        self.assertIn("E302", codes)


class TestRow15Texture(unittest.TestCase):
    def test_row15_texture_objmat_line_resolved_absolute_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            checker = os.path.join(tmp, "checker.ppm")
            with open(checker, "w", encoding="ascii") as fh:
                fh.write("P3\n2 2\n255\n0 0 0 255 255 255\n"
                         "255 255 255 0 0 0\n")
            lines = emit_lines('cube red texture "checker.ppm"\n',
                               base_dir=tmp)
            # The texture exists under the .f3d dir, so validate
            # resolves it to an absolute path in the objmat line.
            self.assertEqual(
                lines_starting(lines, "objmat"),
                ["objmat cube1 lambert 0 1 0.5 32 %s"
                 % os.path.abspath(checker)])

    def test_row15_texture_missing_file_still_compiles(self):
        # Actual behaviour (validate.py + ext_materials): the compiler
        # checks the texture *extension* (.ppm) but not its existence
        # -- unlike `load`, a missing texture is not E501.  The path
        # passes through to the objmat line as written and the engine
        # warns at load time (scene.f90: "cannot load texture").
        with tempfile.TemporaryDirectory() as tmp:
            lines = emit_lines('cube red texture "missing.ppm"\n',
                               base_dir=tmp)
            self.assertEqual(
                lines_starting(lines, "objmat"),
                ["objmat cube1 lambert 0 1 0.5 32 missing.ppm"])


class TestRow16Shadow(unittest.TestCase):
    def test_row16_shadow_soft_line_default_size(self):
        lines = emit_lines("scene shadow soft\ncube red\n")
        self.assertEqual(lines_starting(lines, "shadow"),
                         ["shadow soft 512"])

    def test_row16_shadow_on_1024_size_honoured(self):
        lines = emit_lines("scene shadow on 1024\ncube red\n")
        self.assertEqual(lines_starting(lines, "shadow"),
                         ["shadow on 1024"])


class TestRow25Tonemap(unittest.TestCase):
    def test_row25_tonemap_aces_line(self):
        lines = emit_lines("scene tonemap aces\ncube red\n")
        self.assertEqual(lines_starting(lines, "tonemap"),
                         ["tonemap aces 1"])

    def test_row25_tonemap_reinhard_line(self):
        lines = emit_lines("scene tonemap reinhard\ncube red\n")
        self.assertEqual(lines_starting(lines, "tonemap"),
                         ["tonemap reinhard 1"])

    def test_row25_default_scene_has_no_wavea_lines(self):
        # v1 .scene stability: a plain `cube` scene must emit the v1
        # shape only -- no fog / tonemap / shadow / objmat lines.
        lines = emit_lines("cube\n")
        for prefix in ("fog", "tonemap", "shadow", "objmat"):
            self.assertEqual(lines_starting(lines, prefix), [],
                             "unexpected Wave A line for %r" % prefix)
        # The v1 lines are all present, in order.
        self.assertEqual(lines[0], "forge3d-scene 1")
        self.assertIn("size 640 480", lines)
        self.assertIn("bg 25 25 35", lines)
        self.assertIn("light directional -0.5 -1 -0.7 255 255 255 1",
                      lines)
        self.assertTrue(any(ln.startswith("object cube cube1 lambert")
                            for ln in lines))


class TestWaveAErrors(unittest.TestCase):
    def test_error_spot_without_look(self):
        scene, codes = run("light spot at 0 5 0\ncube red\n")
        self.assertIsNone(scene)
        self.assertIn("E302", codes)

    def test_error_metalness_out_of_range(self):
        scene, codes = run(
            "cube red material standard metalness 1.5\n")
        self.assertIsNone(scene)
        self.assertTrue(codes, "expected a validation error")
        # ext_materials range errors are mapped to E301 by validate.
        self.assertIn("E301", codes)


if __name__ == "__main__":
    unittest.main()
