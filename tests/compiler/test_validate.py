#!/usr/bin/env python3
"""Tests for the Forge3D validator (tools/f3dc/validate.py).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_validate.py

Programs are built through the real front end -- ``parser.parse`` feeds
``validate.validate(program, bag, base_dir='.')``, which returns an
``IRScene`` on success and ``None`` iff the error bag holds an error.
Error-code families follow validate.py: E201 names/targets, E202 colour,
E204 texture, E205 not-built-yet, E301 object/scene dimensions,
E302 camera/light ranges, E303 animation/output timing, E501 missing file.
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


class TestValidateValid(unittest.TestCase):
    def test_three_line_contract_defaults(self):
        # The P03 contract: 3 lines, everything else defaulted.
        scene, codes = run("cube red\nspin it\nrender\n")
        self.assertEqual(codes, [])
        self.assertIsNotNone(scene)
        # Scene defaults.
        self.assertEqual(scene.bg, (25, 25, 35))
        self.assertEqual((scene.width, scene.height), (640, 480))
        # Camera defaults.
        self.assertEqual(tuple(scene.camera.pos), (3.0, 2.5, 4.0))
        self.assertEqual(tuple(scene.camera.target), (0.0, 0.0, 0.0))
        self.assertEqual(scene.camera.fov, 60.0)
        self.assertEqual(scene.camera.near, 0.1)
        self.assertEqual(scene.camera.far, 100.0)
        # The one object: a red cube of size 2.
        self.assertEqual(len(scene.objects), 1)
        cube = scene.objects[0]
        self.assertEqual(cube.prim, "cube")
        self.assertEqual(cube.size, 2.0)
        self.assertEqual(cube.color, (220, 60, 60))
        # Animation defaults for `spin it`.
        self.assertEqual(len(scene.animations), 1)
        anim = scene.animations[0]
        self.assertEqual(anim.kind, "spin")
        self.assertEqual(anim.target, cube.name)
        self.assertEqual(anim.axis, "y")
        self.assertEqual(anim.speed, 90.0)
        self.assertEqual(anim.duration, 5.0)
        self.assertEqual(anim.fps, 30)
        self.assertEqual(anim.ease, "linear")
        self.assertEqual(anim.loop, "forever")
        # Default render output.
        self.assertEqual(scene.outputs[0].path, "output_render.ppm")

    def test_sphere_defaults(self):
        scene, codes = run("sphere blue\n")
        self.assertEqual(codes, [])
        self.assertIsNotNone(scene)
        self.assertEqual(len(scene.objects), 1)
        sphere = scene.objects[0]
        self.assertEqual(sphere.prim, "sphere")
        self.assertEqual(sphere.radius, 1.0)
        self.assertEqual(sphere.segments, 16)
        self.assertEqual(sphere.color, (60, 100, 240))


class TestValidateErrors(unittest.TestCase):
    def assert_rejected(self, source, expected_codes, base_dir="."):
        scene, codes = run(source, base_dir=base_dir)
        self.assertIsNone(scene)
        for code in expected_codes:
            self.assertIn(code, codes)
        return codes

    def test_unknown_colour_gold_e202(self):
        self.assert_rejected("cube gold\n", ["E202"])

    def test_fov_out_of_range(self):
        # Camera range family: validate.py emits E302 for fov.
        codes = self.assert_rejected(
            "camera at 3 2.5 4 look 0 0 0 fov 200\ncube red\n", [])
        self.assertTrue(set(codes) & {"E302", "E303", "E301"}, codes)

    def test_size_zero(self):
        # Dimension family: validate.py emits E301 for a non-positive size.
        codes = self.assert_rejected("cube red size 0\n", [])
        self.assertTrue(set(codes) & {"E301", "E302"}, codes)

    def test_far_not_greater_than_near(self):
        self.assert_rejected(
            "camera at 3 2.5 4 look 0 0 0 near 10 far 5\ncube red\n",
            ["E302"])

    def test_duplicate_object_names_e201(self):
        self.assert_rejected("cube hero red\ncube hero blue\n", ["E201"])

    def test_spin_unknown_target_e201(self):
        self.assert_rejected("cube red\nspin ghost\n", ["E201"])

    def test_texture_property_wavea(self):
        # Wave A: textures are real now (ext_materials replaces the
        # v1 E204 reservation).  A .ppm texture validates clean and
        # lands in the IR object's material extension (resolved to an
        # absolute path when the file exists under base_dir); a .png
        # texture is rejected by ext validation with E501.
        with tempfile.TemporaryDirectory() as tmp:
            checker = os.path.join(tmp, "checker.ppm")
            with open(checker, "w", encoding="ascii") as fh:
                fh.write("P3\n2 2\n255\n0 0 0 255 255 255\n"
                         "255 255 255 0 0 0\n")
            scene, codes = run('cube red texture "checker.ppm"\n',
                               base_dir=tmp)
            self.assertEqual(codes, [])
            self.assertIsNotNone(scene)
            ext = scene.objects[0].extensions["material"]
            self.assertEqual(ext["texture"], os.path.abspath(checker))
        self.assert_rejected('cube red texture "wood.png"\n', ["E501"])

    def test_material_standard_wavea(self):
        # Wave A: `material standard` is built (PBR).  It validates
        # clean (no E205) and the IR material extension carries the
        # metalness/roughness defaults (0.0 / 1.0).
        scene, codes = run("cube red material standard\n")
        self.assertEqual(codes, [])
        self.assertIsNotNone(scene)
        self.assertEqual(scene.objects[0].material, "standard")
        ext = scene.objects[0].extensions["material"]
        self.assertEqual(ext["metalness"], 0.0)
        self.assertEqual(ext["roughness"], 1.0)

    def test_load_missing_file_e501(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assert_rejected('load "definitely_missing.obj"\n',
                                 ["E501"], base_dir=tmp)

    def test_render_to_gif_e301(self):
        self.assert_rejected('cube red\nrender to "out.gif"\n', ["E301"])


if __name__ == "__main__":
    unittest.main()
