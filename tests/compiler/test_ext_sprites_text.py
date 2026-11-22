#!/usr/bin/env python3
"""Tests for the Forge3D Wave B sprites + text extension.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_sprites_text.py
    python3 -m unittest tests.compiler.test_ext_sprites_text

Covers the Wave B surface: sprite / text defaults, named + hex +
tuple colours, the exact ``sprite`` / ``text`` emit lines, and the
validation errors (size range, finite coordinates, empty / over-long
text, unsupported characters).
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

import ext_sprites_text  # noqa: E402
from ext_sprites_text import (  # noqa: E402
    extract_sprite,
    extract_text,
    sprite_line,
    text_line,
    validate_sprite,
    validate_text,
)


class TestSpriteExtract(unittest.TestCase):
    def test_defaults(self):
        d = extract_sprite({})
        self.assertEqual(d["at"], (0.0, 0.0, 0.0))
        self.assertEqual(d["size"], 1.0)
        self.assertEqual(d["color"], (255, 255, 255))

    def test_full_props(self):
        d = extract_sprite({"at": (2, 3, 0), "size": 1,
                            "color": "yellow"})
        self.assertEqual(d["at"], (2.0, 3.0, 0.0))
        self.assertEqual(d["size"], 1.0)
        self.assertEqual(d["color"], (240, 220, 50))

    def test_at_string_and_size_string(self):
        d = extract_sprite({"at": "2,3,0", "size": "2.5"})
        self.assertEqual(d["at"], (2.0, 3.0, 0.0))
        self.assertEqual(d["size"], 2.5)

    def test_named_colour(self):
        # Frozen ir_nodes palette: white is (240, 240, 240).
        self.assertEqual(extract_sprite({"color": "white"})["color"],
                         (240, 240, 240))
        self.assertEqual(extract_sprite({"color": "red"})["color"],
                         (220, 60, 60))

    def test_colour_spelling_key(self):
        self.assertEqual(extract_sprite({"colour": "blue"})["color"],
                         (60, 100, 240))

    def test_hex_colour(self):
        self.assertEqual(extract_sprite({"color": "#ff8000"})["color"],
                         (255, 128, 0))
        self.assertEqual(extract_sprite({"color": "#AABBCC"})["color"],
                         (170, 187, 204))

    def test_tuple_colour(self):
        self.assertEqual(extract_sprite({"color": (10, 20, 30)})["color"],
                         (10, 20, 30))

    def test_input_not_mutated(self):
        props = {"at": (2, 3, 0), "size": 1, "color": "red"}
        snapshot = dict(props)
        extract_sprite(props)
        self.assertEqual(props, snapshot)


class TestSpriteLine(unittest.TestCase):
    def test_exact_line_hex(self):
        d = extract_sprite({"at": (2, 3, 0), "size": 1,
                            "color": "#ff8000"})
        self.assertEqual(sprite_line("star", d),
                         "sprite star 2 3 0 1 255 128 0")

    def test_exact_line_defaults(self):
        self.assertEqual(sprite_line("dot", extract_sprite({})),
                         "sprite dot 0 0 0 1 255 255 255")

    def test_exact_line_fractional(self):
        d = {"at": (0.5, -1.25, 3), "size": 2.5, "color": (1, 2, 3)}
        self.assertEqual(sprite_line("s", d),
                         "sprite s 0.5 -1.25 3 2.5 1 2 3")


class TestSpriteValidate(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(validate_sprite(extract_sprite(
            {"at": (2, 3, 0), "size": 1, "color": "white"})), [])

    def test_size_boundary_100_valid(self):
        self.assertEqual(validate_sprite({"size": 100}), [])

    def test_size_zero(self):
        errors = validate_sprite(extract_sprite({"size": 0}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])
        self.assertIn("100", errors[0])

    def test_size_101(self):
        errors = validate_sprite(extract_sprite({"size": 101}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])

    def test_size_negative(self):
        errors = validate_sprite({"size": -1})
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])

    def test_non_finite_coord(self):
        for bad in (math.inf, -math.inf, math.nan):
            errors = validate_sprite(
                extract_sprite({"at": (bad, 0, 0)}))
            self.assertEqual(len(errors), 1)
            self.assertIn("at", errors[0])
            self.assertIn("finite", errors[0])


class TestTextExtract(unittest.TestCase):
    def test_defaults(self):
        d = extract_text({"text": "HI"})
        self.assertEqual(d["at"], (0.0, 0.0, 0.0))
        self.assertEqual(d["size"], 1.0)
        self.assertEqual(d["color"], (255, 255, 255))
        self.assertEqual(d["text"], "HI")
        self.assertEqual(d["content"], "HI")

    def test_content_key_and_quotes_stripped(self):
        d = extract_text({"content": '"GAME OVER"'})
        self.assertEqual(d["text"], "GAME OVER")

    def test_whitespace_collapsed_case_preserved(self):
        d = extract_text({"text": "  Game   Over  now "})
        self.assertEqual(d["text"], "Game Over now")

    def test_named_and_hex_colours(self):
        self.assertEqual(extract_text({"text": "X",
                                       "color": "white"})["color"],
                         (240, 240, 240))
        self.assertEqual(extract_text({"text": "X",
                                       "color": "#00ff00"})["color"],
                         (0, 255, 0))


class TestTextLine(unittest.TestCase):
    def test_exact_multiword(self):
        d = extract_text({"text": "GAME OVER", "at": (0, 4, 0),
                          "size": 1, "color": "white"})
        self.assertEqual(text_line("label", d),
                         "text label 0 4 0 1 240 240 240 GAME OVER")

    def test_exact_single_word_defaults(self):
        d = extract_text({"text": "READY"})
        self.assertEqual(text_line("msg", d),
                         "text msg 0 0 0 1 255 255 255 READY")


class TestTextValidate(unittest.TestCase):
    def test_valid_full_charset_and_lowercase(self):
        d = extract_text({"text": "Score: 100! You're 1 - ok?"})
        self.assertEqual(validate_text(d), [])

    def test_size_zero(self):
        errors = validate_text(extract_text({"text": "HI", "size": 0}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])

    def test_size_101(self):
        errors = validate_text(extract_text({"text": "HI",
                                             "size": 101}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])

    def test_non_finite_coord(self):
        errors = validate_text(
            extract_text({"text": "HI", "at": (0, math.inf, 0)}))
        self.assertEqual(len(errors), 1)
        self.assertIn("finite", errors[0])

    def test_empty_text(self):
        for props in ({"text": ""}, {"text": "   "}, {}):
            errors = validate_text(extract_text(props))
            self.assertEqual(len(errors), 1)
            self.assertIn("empty", errors[0])

    def test_bad_char_hash(self):
        errors = validate_text(extract_text({"text": "C# WIN"}))
        self.assertEqual(len(errors), 1)
        self.assertIn("#", errors[0])
        self.assertIn("unsupported character", errors[0])

    def test_text_201_chars(self):
        errors = validate_text(extract_text({"text": "A" * 201}))
        self.assertEqual(len(errors), 1)
        self.assertIn("201", errors[0])
        self.assertIn("200", errors[0])

    def test_text_200_chars_valid(self):
        self.assertEqual(
            validate_text(extract_text({"text": "A" * 200})), [])


if __name__ == "__main__":
    unittest.main()
