#!/usr/bin/env python3
"""Tests for the Forge3D Wave A material extension (ext_materials.py).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_materials.py
    python3 -m unittest tests.compiler.test_ext_materials

Covers the Wave A surface: the ``standard`` material defaults
(metalness 0.0 / roughness 1.0), the phong ``specular`` / ``shininess``
defaults, range validation messages, PPM-only texture extraction and
validation, the exact ``objmat`` emit line, and ``apply_to_ir_object``.
"""

import os
import sys
import unittest

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))),
        "tools", "f3dc",
    ),
)

import ext_materials  # noqa: E402
from ext_materials import (  # noqa: E402
    DEFAULTS,
    WAVEA_MATERIALS,
    apply_to_ir_object,
    extract_material_ext,
    objmat_line,
    validate_material_ext,
)


class TestConstants(unittest.TestCase):
    def test_wavea_materials(self):
        self.assertEqual(WAVEA_MATERIALS, ("standard",))

    def test_defaults(self):
        self.assertEqual(DEFAULTS, {"metalness": 0.0, "roughness": 1.0,
                                    "specular": 0.5, "shininess": 32.0})


class TestExtract(unittest.TestCase):
    def test_standard_defaults(self):
        ext = extract_material_ext({"material": "standard"})
        self.assertEqual(ext["metalness"], 0.0)
        self.assertEqual(ext["roughness"], 1.0)
        self.assertIsNone(ext["texture"])

    def test_phong_defaults(self):
        ext = extract_material_ext({"material": "phong"})
        self.assertEqual(ext["specular"], 0.5)
        self.assertEqual(ext["shininess"], 32.0)

    def test_present_values_override_defaults(self):
        ext = extract_material_ext({"material": "standard",
                                    "metalness": 0.8, "roughness": 0.25})
        self.assertEqual(ext["metalness"], 0.8)
        self.assertEqual(ext["roughness"], 0.25)

    def test_present_key_kept_for_any_material(self):
        ext = extract_material_ext({"material": "lambert",
                                    "metalness": 0.3})
        self.assertEqual(ext["metalness"], 0.3)

    def test_irrelevant_absent_keys_not_defaulted(self):
        # Defaults are filled only for keys relevant to the material
        # (or present); a plain lambert object invents nothing.
        ext = extract_material_ext({"material": "lambert"})
        self.assertIsNone(ext["metalness"])
        self.assertIsNone(ext["roughness"])
        self.assertIsNone(ext["specular"])
        self.assertIsNone(ext["shininess"])
        self.assertIsNone(ext["texture"])

    def test_empty_props(self):
        ext = extract_material_ext({})
        self.assertIsNone(ext["metalness"])
        self.assertIsNone(ext["texture"])

    def test_texture_quoted(self):
        ext = extract_material_ext({"texture": '"wood.ppm"'})
        self.assertEqual(ext["texture"], "wood.ppm")

    def test_texture_single_quoted(self):
        ext = extract_material_ext({"texture": "'wood.ppm'"})
        self.assertEqual(ext["texture"], "wood.ppm")

    def test_texture_bare_ident(self):
        ext = extract_material_ext({"texture": "wood.ppm"})
        self.assertEqual(ext["texture"], "wood.ppm")

    def test_input_not_mutated(self):
        props = {"material": "standard", "metalness": 0.4,
                 "texture": '"a.ppm"'}
        snapshot = dict(props)
        extract_material_ext(props)
        self.assertEqual(props, snapshot)


class TestValidate(unittest.TestCase):
    def test_valid_standard(self):
        ext = extract_material_ext({"material": "standard",
                                    "metalness": 0.5, "roughness": 0.5})
        self.assertEqual(validate_material_ext("standard", ext), [])

    def test_valid_texture_ppm(self):
        ext = extract_material_ext({"texture": "wood.ppm"})
        self.assertEqual(validate_material_ext("lambert", ext), [])

    def test_no_texture_is_valid(self):
        self.assertEqual(
            validate_material_ext("lambert", {"texture": None}), [])

    def test_metalness_out_of_range(self):
        errors = validate_material_ext(
            "standard", {"metalness": 1.5, "texture": None})
        self.assertEqual(len(errors), 1)
        self.assertIn("metalness", errors[0])
        self.assertIn("0..1", errors[0])

    def test_roughness_out_of_range(self):
        errors = validate_material_ext(
            "standard", {"roughness": -0.1, "texture": None})
        self.assertEqual(len(errors), 1)
        self.assertIn("roughness", errors[0])
        self.assertIn("0..1", errors[0])

    def test_specular_out_of_range(self):
        errors = validate_material_ext(
            "phong", {"specular": 2.0, "texture": None})
        self.assertEqual(len(errors), 1)
        self.assertIn("specular", errors[0])
        self.assertIn("0..1", errors[0])

    def test_shininess_out_of_range(self):
        errors = validate_material_ext(
            "phong", {"shininess": 1001.0, "texture": None})
        self.assertEqual(len(errors), 1)
        self.assertIn("shininess", errors[0])
        self.assertIn("0..1000", errors[0])

    def test_boundary_values_are_valid(self):
        ext = {"metalness": 0.0, "roughness": 1.0, "specular": 1.0,
               "shininess": 1000.0, "texture": None}
        self.assertEqual(validate_material_ext("standard", ext), [])

    def test_multiple_errors_all_reported(self):
        ext = {"metalness": 2.0, "roughness": -1.0, "texture": None}
        self.assertEqual(
            len(validate_material_ext("standard", ext)), 2)

    def test_png_texture_rejected(self):
        errors = validate_material_ext(
            "lambert", {"texture": "wood.png"})
        self.assertEqual(len(errors), 1)
        self.assertIn("texture", errors[0])
        self.assertIn(".ppm", errors[0])
        self.assertIn("only", errors[0])

    def test_empty_texture_rejected(self):
        errors = validate_material_ext("lambert", {"texture": ""})
        self.assertEqual(len(errors), 1)
        self.assertIn("texture", errors[0])
        self.assertIn(".ppm", errors[0])

    def test_extensionless_texture_rejected(self):
        errors = validate_material_ext("lambert", {"texture": "wood"})
        self.assertEqual(len(errors), 1)
        self.assertIn(".ppm", errors[0])

    def test_uppercase_ppm_accepted(self):
        self.assertEqual(
            validate_material_ext("lambert", {"texture": "WOOD.PPM"}),
            [])


class TestObjmatLine(unittest.TestCase):
    def test_standard_defaults_exact(self):
        ext = extract_material_ext({"material": "standard"})
        self.assertEqual(objmat_line("hero", "standard", ext),
                         "objmat hero standard 0 1 0.5 32 -")

    def test_standard_full_exact(self):
        ext = {"metalness": 0.8, "roughness": 0.25, "specular": 0.5,
               "shininess": 32.0, "texture": "wood.ppm"}
        self.assertEqual(
            objmat_line("hero", "standard", ext),
            "objmat hero standard 0.8 0.25 0.5 32 wood.ppm")

    def test_none_for_plain_lambert(self):
        ext = extract_material_ext({"material": "lambert"})
        self.assertIsNone(objmat_line("hero", "lambert", ext))

    def test_none_for_lambert_with_default_phong_props(self):
        ext = {"metalness": None, "roughness": None, "specular": 0.5,
               "shininess": 32.0, "texture": None}
        self.assertIsNone(objmat_line("hero", "lambert", ext))

    def test_none_for_empty_ext(self):
        self.assertIsNone(objmat_line("hero", "basic", {}))

    def test_texture_forces_line(self):
        ext = extract_material_ext({"material": "lambert",
                                    "texture": '"wood.ppm"'})
        self.assertEqual(objmat_line("hero", "lambert", ext),
                         "objmat hero lambert 0 1 0.5 32 wood.ppm")

    def test_non_default_specular_forces_line(self):
        ext = {"specular": 0.9, "texture": None}
        self.assertEqual(objmat_line("hero", "phong", ext),
                         "objmat hero phong 0 1 0.9 32 -")

    def test_non_default_shininess_forces_line(self):
        ext = {"shininess": 128.0, "texture": None}
        self.assertEqual(objmat_line("hero", "phong", ext),
                         "objmat hero phong 0 1 0.5 128 -")


class FakeObject:
    """Tiny duck-typed stand-in for ir_nodes.IRObject."""

    def __init__(self, material="lambert", extensions=None, **attrs):
        self.name = "fake"
        self.material = material
        self.extensions = {} if extensions is None else extensions
        for key, value in attrs.items():
            setattr(self, key, value)


class TestApplyToIrObject(unittest.TestCase):
    def test_standard_from_raw_props(self):
        obj = FakeObject(
            material="standard",
            extensions={"raw_props": {"material": "standard",
                                      "metalness": 0.7}})
        apply_to_ir_object(obj)
        self.assertIn("material", obj.extensions)
        ext = obj.extensions["material"]
        self.assertEqual(ext["metalness"], 0.7)
        self.assertEqual(ext["roughness"], 1.0)

    def test_standard_from_material_attribute_only(self):
        obj = FakeObject(material="standard")
        apply_to_ir_object(obj)
        self.assertEqual(obj.extensions["material"]["metalness"], 0.0)
        self.assertEqual(obj.extensions["material"]["roughness"], 1.0)

    def test_plain_lambert_is_noop(self):
        obj = FakeObject(material="lambert")
        apply_to_ir_object(obj)
        self.assertEqual(obj.extensions, {})

    def test_lambert_with_raw_props_texture(self):
        obj = FakeObject(
            material="lambert",
            extensions={"raw_props": {"texture": '"wood.ppm"'}})
        apply_to_ir_object(obj)
        self.assertEqual(
            obj.extensions["material"]["texture"], "wood.ppm")

    def test_texture_attribute(self):
        obj = FakeObject(material="lambert", texture="wood.ppm")
        apply_to_ir_object(obj)
        self.assertEqual(
            obj.extensions["material"]["texture"], "wood.ppm")

    def test_metalness_attribute(self):
        obj = FakeObject(material="lambert", metalness=0.2)
        apply_to_ir_object(obj)
        self.assertEqual(
            obj.extensions["material"]["metalness"], 0.2)

    def test_none_object_is_noop(self):
        apply_to_ir_object(None)  # must not raise


if __name__ == "__main__":
    unittest.main()
