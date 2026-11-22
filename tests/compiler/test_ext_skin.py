#!/usr/bin/env python3
"""Tests for the Forge3D Wave E skinning + morph extension (C1).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_skin.py
    python3 -m unittest tests.compiler.test_ext_skin

Covers the frozen surface ``morph <target> <kind> <factor>`` /
``bone <name> [at x,y,z] [rotate rx,ry,rz] [radius r]`` /
``skin <target> <bonename>``: each validator's valid case and every
error case (unknown morph kind, factor out of range / not a number,
bad vec3 arity, radius <= 0, skin referencing an unknown bone,
duplicate bone name), the bone defaults filled in, and the exact
``scene_lines`` strings with ordering preserved. Per-vertex morph /
skinning math is out of scope here by design (it lives in Fortran +
JS).
"""

import math
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

import ext_skin  # noqa: E402
from ext_skin import (  # noqa: E402
    MORPH_KINDS,
    bone_line,
    extract_bone,
    extract_morph,
    extract_skin,
    morph_line,
    scene_lines,
    skin_line,
    validate_bone,
    validate_morph,
    validate_skin,
)


class TestMorphKinds(unittest.TestCase):
    def test_kinds_frozen(self):
        self.assertEqual(MORPH_KINDS, ("bulge", "taper", "squash"))
        self.assertEqual(ext_skin.MORPH_KINDS, MORPH_KINDS)


class TestExtract(unittest.TestCase):
    def test_extract_morph(self):
        self.assertEqual(
            extract_morph({"target": "hero", "kind": "Bulge",
                           "factor": "0.5"}),
            {"target": "hero", "kind": "bulge", "factor": 0.5})

    def test_extract_skin(self):
        self.assertEqual(extract_skin({"target": "hero", "bone": "arm"}),
                         {"target": "hero", "bone": "arm"})
        self.assertEqual(
            extract_skin({"obj": "hero", "bonename": "arm"}),
            {"target": "hero", "bone": "arm"})

    def test_bone_defaults_filled(self):
        d = extract_bone({"name": "spine"})
        self.assertEqual(d, {"name": "spine", "at": (0.0, 0.0, 0.0),
                             "rotate": (0.0, 0.0, 0.0), "radius": 2.0})

    def test_bone_explicit_values(self):
        d = extract_bone({"name": "arm", "at": (1, 0, 0),
                          "rotate": (0, 0, 45), "radius": 2})
        self.assertEqual(d, {"name": "arm", "at": (1.0, 0.0, 0.0),
                             "rotate": (0.0, 0.0, 45.0), "radius": 2.0})

    def test_bone_vec3_string_spelling(self):
        d = extract_bone({"name": "arm", "at": "1,2,3",
                          "rotate": "0, 90, 0"})
        self.assertEqual(d["at"], (1.0, 2.0, 3.0))
        self.assertEqual(d["rotate"], (0.0, 90.0, 0.0))

    def test_extract_input_not_mutated(self):
        props = {"name": "arm", "at": (1, 0, 0)}
        snapshot = dict(props)
        extract_bone(props)
        self.assertEqual(props, snapshot)


class TestValidateMorph(unittest.TestCase):
    def test_valid_each_kind(self):
        for kind in MORPH_KINDS:
            self.assertEqual(
                validate_morph({"target": "hero", "kind": kind,
                                "factor": 0.5}), [], kind)

    def test_valid_factor_boundaries(self):
        for factor in (-2, -2.0, 0, 2, 2.0):
            self.assertEqual(
                validate_morph({"target": "hero", "kind": "squash",
                                "factor": factor}), [], factor)

    def test_valid_numeric_string_factor(self):
        self.assertEqual(
            validate_morph({"target": "hero", "kind": "taper",
                            "factor": "-1.5"}), [])

    def test_unknown_kind(self):
        errors = validate_morph({"target": "hero", "kind": "twist",
                                 "factor": 0.5})
        self.assertEqual(len(errors), 1)
        self.assertIn("twist", errors[0])
        self.assertIn("bulge", errors[0])

    def test_missing_kind(self):
        errors = validate_morph({"target": "hero", "factor": 0.5})
        self.assertEqual(len(errors), 1)
        self.assertIn("kind", errors[0])

    def test_missing_target(self):
        errors = validate_morph({"kind": "bulge", "factor": 0.5})
        self.assertEqual(len(errors), 1)
        self.assertIn("target", errors[0])

    def test_factor_out_of_range(self):
        for bad in (-2.5, -3, 2.001, 5):
            errors = validate_morph({"target": "hero", "kind": "bulge",
                                     "factor": bad})
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("-2..2", errors[0])

    def test_factor_not_a_number(self):
        for bad in ("strong", "lots", object()):
            errors = validate_morph({"target": "hero", "kind": "bulge",
                                     "factor": bad})
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("not a number", errors[0])

    def test_factor_bool_is_not_a_number(self):
        errors = validate_morph({"target": "hero", "kind": "bulge",
                                 "factor": True})
        self.assertEqual(len(errors), 1)
        self.assertIn("not a number", errors[0])

    def test_factor_non_finite(self):
        for bad in (math.inf, -math.inf, math.nan):
            errors = validate_morph({"target": "hero", "kind": "bulge",
                                     "factor": bad})
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("factor", errors[0])

    def test_factor_missing(self):
        errors = validate_morph({"target": "hero", "kind": "bulge"})
        self.assertEqual(len(errors), 1)
        self.assertIn("factor", errors[0])

    def test_not_a_dict(self):
        errors = validate_morph("hero bulge 0.5")
        self.assertEqual(len(errors), 1)
        self.assertIn("not a morph dict", errors[0])


class TestValidateBone(unittest.TestCase):
    def test_valid_defaults_only(self):
        # Missing at / rotate / radius fall back to the frozen
        # defaults, so a bare name is valid.
        self.assertEqual(validate_bone({"name": "spine"}), [])
        self.assertEqual(validate_bone(extract_bone({"name": "spine"})),
                         [])

    def test_valid_full(self):
        self.assertEqual(
            validate_bone({"name": "arm", "at": (1, 0, 0),
                           "rotate": (0, 0, 45), "radius": 2}), [])

    def test_valid_small_positive_radius(self):
        self.assertEqual(
            validate_bone({"name": "arm", "radius": 0.001}), [])

    def test_missing_name(self):
        errors = validate_bone({"at": (0, 0, 0)})
        self.assertEqual(len(errors), 1)
        self.assertIn("no name", errors[0])

    def test_duplicate_name(self):
        errors = validate_bone({"name": "arm"}, {"arm", "spine"})
        self.assertEqual(len(errors), 1)
        self.assertIn("duplicate", errors[0])
        self.assertIn("arm", errors[0])

    def test_duplicate_check_passes_for_new_name(self):
        self.assertEqual(validate_bone({"name": "leg"}, {"arm"}), [])
        self.assertEqual(validate_bone({"name": "leg"}, set()), [])

    def test_radius_zero_and_negative(self):
        for bad in (0, 0.0, -1, -2.5):
            errors = validate_bone({"name": "arm", "radius": bad})
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("radius", errors[0])
            self.assertIn("more than 0", errors[0])

    def test_radius_not_a_number(self):
        errors = validate_bone({"name": "arm", "radius": "wide"})
        self.assertEqual(len(errors), 1)
        self.assertIn("radius", errors[0])
        self.assertIn("not a number", errors[0])

    def test_radius_non_finite(self):
        for bad in (math.inf, math.nan):
            errors = validate_bone({"name": "arm", "radius": bad})
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("radius", errors[0])

    def test_at_bad_arity(self):
        for bad in ((1, 0), (1, 0, 0, 0), "1,2", [1], 5):
            errors = validate_bone({"name": "arm", "at": bad})
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("at", errors[0])
            self.assertIn("three", errors[0])

    def test_rotate_bad_arity(self):
        for bad in ((0, 45), (0, 0, 0, 0), "0,45"):
            errors = validate_bone({"name": "arm", "rotate": bad})
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("rotate", errors[0])

    def test_vec3_non_numeric_component(self):
        errors = validate_bone({"name": "arm", "at": (1, "up", 0)})
        self.assertEqual(len(errors), 1)
        self.assertIn("at", errors[0])
        self.assertIn("not a number", errors[0])
        errors = validate_bone({"name": "arm", "rotate": (0, None, 0)})
        self.assertEqual(len(errors), 1)
        self.assertIn("rotate", errors[0])

    def test_vec3_non_finite_component(self):
        errors = validate_bone({"name": "arm", "at": (math.inf, 0, 0)})
        self.assertEqual(len(errors), 1)
        self.assertIn("at", errors[0])
        self.assertIn("finite", errors[0])
        errors = validate_bone(
            {"name": "arm", "rotate": (0, math.nan, 0)})
        self.assertEqual(len(errors), 1)
        self.assertIn("rotate", errors[0])

    def test_not_a_dict(self):
        errors = validate_bone("arm")
        self.assertEqual(len(errors), 1)
        self.assertIn("not a bone dict", errors[0])


class TestValidateSkin(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(
            validate_skin({"target": "hero", "bone": "arm"}, {"arm"}),
            [])
        self.assertEqual(
            validate_skin({"target": "hero", "bone": "arm"},
                          {"arm", "spine"}), [])

    def test_valid_known_bones_as_bone_dicts(self):
        known = [extract_bone({"name": "arm"}),
                 extract_bone({"name": "spine"})]
        self.assertEqual(
            validate_skin({"target": "hero", "bone": "arm"}, known), [])

    def test_unknown_bone(self):
        errors = validate_skin({"target": "hero", "bone": "leg"},
                               {"arm", "spine"})
        self.assertEqual(len(errors), 1)
        self.assertIn("unknown bone", errors[0])
        self.assertIn("leg", errors[0])

    def test_unknown_bone_empty_known_set(self):
        errors = validate_skin({"target": "hero", "bone": "arm"}, set())
        self.assertEqual(len(errors), 1)
        self.assertIn("unknown bone", errors[0])

    def test_missing_bone(self):
        errors = validate_skin({"target": "hero"}, {"arm"})
        self.assertEqual(len(errors), 1)
        self.assertIn("bone", errors[0])

    def test_missing_target(self):
        errors = validate_skin({"bone": "arm"}, {"arm"})
        self.assertEqual(len(errors), 1)
        self.assertIn("target", errors[0])

    def test_not_a_dict(self):
        errors = validate_skin("hero arm", {"arm"})
        self.assertEqual(len(errors), 1)
        self.assertIn("not a skin dict", errors[0])


class TestSceneLines(unittest.TestCase):
    def test_full_example_exact_strings(self):
        lines = scene_lines(
            [{"target": "hero", "kind": "bulge", "factor": 0.5}],
            [{"name": "arm", "at": (1, 0, 0), "rotate": (0, 0, 45),
              "radius": 2}],
            [{"target": "hero", "bone": "arm"}],
        )
        self.assertEqual(lines, [
            "morph hero bulge 0.5",
            "bone arm 1 0 0 0 0 45 2",
            "skin hero arm",
        ])

    def test_full_example_via_extract(self):
        lines = scene_lines(
            [extract_morph({"target": "hero", "kind": "bulge",
                            "factor": 0.5})],
            [extract_bone({"name": "arm", "at": (1, 0, 0),
                           "rotate": (0, 0, 45), "radius": 2})],
            [extract_skin({"target": "hero", "bone": "arm"})],
        )
        self.assertEqual(lines, [
            "morph hero bulge 0.5",
            "bone arm 1 0 0 0 0 45 2",
            "skin hero arm",
        ])

    def test_bone_defaults_in_line(self):
        self.assertEqual(bone_line({"name": "spine"}),
                         "bone spine 0 0 0 0 0 0 2")
        self.assertEqual(scene_lines([], [{"name": "spine"}], []),
                         ["bone spine 0 0 0 0 0 0 2"])

    def test_individual_lines(self):
        self.assertEqual(
            morph_line({"target": "hero", "kind": "taper",
                        "factor": -1}),
            "morph hero taper -1")
        self.assertEqual(skin_line({"target": "hero", "bone": "arm"}),
                         "skin hero arm")

    def test_formatting_is_percent_6g(self):
        self.assertEqual(
            morph_line({"target": "hero", "kind": "bulge",
                        "factor": 1.0 / 3.0}),
            "morph hero bulge 0.333333")
        self.assertEqual(
            bone_line({"name": "arm", "at": (0.25, 0, 0),
                       "radius": 2.5}),
            "bone arm 0.25 0 0 0 0 0 2.5")

    def test_ordering_preserved(self):
        lines = scene_lines(
            [{"target": "b", "kind": "squash", "factor": 1},
             {"target": "a", "kind": "bulge", "factor": -0.5}],
            [{"name": "spine"}, {"name": "arm", "at": (1, 0, 0)}],
            [{"target": "hero", "bone": "arm"},
             {"target": "hero", "bone": "spine"}],
        )
        self.assertEqual(lines, [
            "morph b squash 1",
            "morph a bulge -0.5",
            "bone spine 0 0 0 0 0 0 2",
            "bone arm 1 0 0 0 0 0 2",
            "skin hero arm",
            "skin hero spine",
        ])

    def test_empty_groups(self):
        self.assertEqual(scene_lines([], [], []), [])
        self.assertEqual(scene_lines(None, None, None), [])
        self.assertEqual(
            scene_lines([], [], [{"target": "hero", "bone": "arm"}]),
            ["skin hero arm"])


if __name__ == "__main__":
    unittest.main()
