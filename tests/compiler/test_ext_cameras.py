#!/usr/bin/env python3
"""Tests for the Forge3D Wave C orthographic-camera extension.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_cameras.py
    python3 -m unittest tests.compiler.test_ext_cameras

Covers the Wave C surface (MASTER-PLAN parity row 3): the frozen
syntax ``camera ortho [size N] [at x,y,z] [look x,y,z] [fov ignored]``,
the defaults (bare ``camera ortho`` -> size 5.0), explicit size,
at/look pass-through, invalid-size errors, perspective emitting no
lines, and the ``ortho SIZE`` line formatted with ``%.6g`` like the
other ``ext_*`` modules.
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

import ext_cameras  # noqa: E402
from ext_cameras import (  # noqa: E402
    DEFAULT_SIZE,
    camera_lines,
    extract_camera,
    validate_camera,
)


class TestExtractCamera(unittest.TestCase):
    def test_default_size_constant(self):
        self.assertEqual(DEFAULT_SIZE, 5.0)
        self.assertEqual(ext_cameras.DEFAULT_SIZE, 5.0)

    def test_bare_ortho_defaults(self):
        # Bare `camera ortho`: the parser stores {"ortho": True}.
        d = extract_camera({"ortho": True})
        self.assertEqual(d, {"type": "ortho", "size": 5.0,
                             "at": None, "look": None})

    def test_bare_camera_is_perspective(self):
        d = extract_camera({})
        self.assertEqual(d, {"type": "perspective", "size": 5.0,
                             "at": None, "look": None})

    def test_explicit_size(self):
        d = extract_camera({"ortho": True, "size": 8})
        self.assertEqual(d["type"], "ortho")
        self.assertEqual(d["size"], 8.0)
        self.assertIsInstance(d["size"], float)

    def test_explicit_size_numeric_string(self):
        d = extract_camera({"ortho": True, "size": "2.5"})
        self.assertEqual(d["size"], 2.5)

    def test_type_prop_spellings(self):
        self.assertEqual(
            extract_camera({"type": "ortho"})["type"], "ortho")
        self.assertEqual(
            extract_camera({"type": "orthographic"})["type"], "ortho")
        self.assertEqual(
            extract_camera({"type": "perspective"})["type"],
            "perspective")

    def test_at_look_pass_through(self):
        d = extract_camera({"ortho": True, "size": 8,
                            "at": (0, 2, 0), "look": (0, 0, 0)})
        self.assertEqual(d["at"], (0.0, 2.0, 0.0))
        self.assertEqual(d["look"], (0.0, 0.0, 0.0))

    def test_at_look_string_spelling(self):
        d = extract_camera({"at": "1,2,3", "look": "0,0,0"})
        self.assertEqual(d["at"], (1.0, 2.0, 3.0))
        self.assertEqual(d["look"], (0.0, 0.0, 0.0))

    def test_at_look_aliases(self):
        d = extract_camera({"position": (1, 1, 1),
                            "target": (2, 2, 2)})
        self.assertEqual(d["at"], (1.0, 1.0, 1.0))
        self.assertEqual(d["look"], (2.0, 2.0, 2.0))

    def test_fov_is_ignored(self):
        d = extract_camera({"ortho": True, "size": 8, "fov": 30})
        self.assertEqual(set(d), {"type", "size", "at", "look"})
        self.assertEqual(d["size"], 8.0)

    def test_token_sequence_input(self):
        d = extract_camera(
            ["camera", "ortho", "size", "8",
             "at", "0,2,0", "look", "0,0,0", "fov", "30"])
        self.assertEqual(d, {"type": "ortho", "size": 8.0,
                             "at": (0.0, 2.0, 0.0),
                             "look": (0.0, 0.0, 0.0)})

    def test_line_string_input(self):
        d = extract_camera("camera ortho size 3 at 1,2,3 look 0,0,0")
        self.assertEqual(d["type"], "ortho")
        self.assertEqual(d["size"], 3.0)
        self.assertEqual(d["at"], (1.0, 2.0, 3.0))
        self.assertEqual(d["look"], (0.0, 0.0, 0.0))

    def test_input_not_mutated(self):
        props = {"ortho": True, "size": 8, "at": (0, 2, 0)}
        snapshot = dict(props)
        extract_camera(props)
        self.assertEqual(props, snapshot)


class TestValidateCamera(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(validate_camera(extract_camera(
            {"ortho": True})), [])
        self.assertEqual(validate_camera(extract_camera(
            {"ortho": True, "size": 8, "at": (0, 2, 0),
             "look": (0, 0, 0)})), [])
        self.assertEqual(validate_camera(extract_camera({})), [])
        self.assertEqual(validate_camera({}), [])

    def test_size_zero(self):
        errors = validate_camera(extract_camera(
            {"ortho": True, "size": 0}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])
        self.assertIn("more than 0", errors[0])

    def test_size_negative(self):
        errors = validate_camera(extract_camera(
            {"ortho": True, "size": -2.5}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])

    def test_size_non_numeric(self):
        errors = validate_camera(extract_camera(
            {"ortho": True, "size": "big"}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])
        self.assertIn("not a number", errors[0])

    def test_size_non_finite(self):
        for bad in (math.inf, -math.inf, math.nan):
            errors = validate_camera({"type": "ortho", "size": bad})
            self.assertEqual(len(errors), 1)
            self.assertIn("size", errors[0])

    def test_small_positive_size_valid(self):
        self.assertEqual(validate_camera(
            {"type": "ortho", "size": 0.001}), [])

    def test_unknown_type(self):
        errors = validate_camera({"type": "fisheye", "size": 5.0})
        self.assertEqual(len(errors), 1)
        self.assertIn("type", errors[0])

    def test_non_finite_at_look(self):
        errors = validate_camera(
            {"type": "ortho", "size": 5.0, "at": (math.inf, 0, 0)})
        self.assertEqual(len(errors), 1)
        self.assertIn("at", errors[0])
        self.assertIn("finite", errors[0])
        errors = validate_camera(
            {"type": "perspective", "look": (0, math.nan, 0)})
        self.assertEqual(len(errors), 1)
        self.assertIn("look", errors[0])


class TestCameraLines(unittest.TestCase):
    def test_ortho_default_line(self):
        self.assertEqual(
            camera_lines(extract_camera({"ortho": True})),
            ["ortho 5"])

    def test_ortho_explicit_size_line(self):
        self.assertEqual(
            camera_lines(extract_camera({"ortho": True, "size": 8})),
            ["ortho 8"])
        self.assertEqual(
            camera_lines(extract_camera({"ortho": True, "size": 2.5})),
            ["ortho 2.5"])

    def test_ortho_line_float_formatting(self):
        # %.6g, the spelling the other ext modules use for reals.
        self.assertEqual(camera_lines({"type": "ortho", "size": 0.2}),
                         ["ortho 0.2"])
        self.assertEqual(
            camera_lines({"type": "ortho", "size": 1.0 / 3.0}),
            ["ortho 0.333333"])

    def test_ortho_line_missing_size_defaults(self):
        self.assertEqual(camera_lines({"type": "ortho"}), ["ortho 5"])

    def test_perspective_emits_no_lines(self):
        self.assertEqual(camera_lines(extract_camera({})), [])
        self.assertEqual(
            camera_lines({"type": "perspective", "size": 5.0}), [])
        self.assertEqual(camera_lines({}), [])
        self.assertEqual(camera_lines(None), [])

    def test_at_look_not_repeated_in_lines(self):
        # at/look continue through the existing camera path; the
        # extension emits only the ortho line.
        lines = camera_lines(extract_camera(
            {"ortho": True, "size": 8, "at": (0, 2, 0),
             "look": (0, 0, 0)}))
        self.assertEqual(lines, ["ortho 8"])


if __name__ == "__main__":
    unittest.main()
