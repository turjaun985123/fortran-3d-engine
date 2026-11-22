#!/usr/bin/env python3
"""Tests for the Forge3D Wave C post-processing extension.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_post.py
    python3 -m unittest tests.compiler.test_ext_post

Covers the Wave C surface (MASTER-PLAN row 30): every filter's
frozen default, explicit amounts (dict props, token lists and
source-line strings), ordered chains via ``collect_post``, the exact
``post`` emit line and its ``%.6g`` formatting, and the validation
errors for unknown names and out-of-range amounts. Pixel math is out
of scope here by design (it lives in Fortran + JS).
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

import ext_post  # noqa: E402
from ext_post import (  # noqa: E402
    DEFAULTS,
    collect_post,
    extract_post,
    post_line,
    post_lines,
    validate_post,
)


class TestDefaults(unittest.TestCase):
    def test_defaults_dict_frozen(self):
        self.assertEqual(DEFAULTS, {
            "blur": 1, "bloom": 0.5, "vignette": 0.5, "gamma": 2.2,
            "grayscale": 1.0, "sepia": 1.0,
        })

    def test_each_filter_default_from_name_only(self):
        for name, amount in DEFAULTS.items():
            d = extract_post({"name": name})
            self.assertEqual(d, {"name": name, "amount": amount})
            self.assertEqual(validate_post(d), [])

    def test_each_filter_default_from_token_list(self):
        for name, amount in DEFAULTS.items():
            self.assertEqual(extract_post([name]),
                             {"name": name, "amount": amount})
            self.assertEqual(extract_post(["filter", name]),
                             {"name": name, "amount": amount})

    def test_blur_default_is_int(self):
        self.assertIsInstance(extract_post({"name": "blur"})["amount"],
                              int)


class TestExtractExplicitAmounts(unittest.TestCase):
    def test_dict_props(self):
        self.assertEqual(extract_post({"name": "blur", "amount": 3}),
                         {"name": "blur", "amount": 3})
        self.assertEqual(extract_post({"name": "gamma", "amount": 1.8}),
                         {"name": "gamma", "amount": 1.8})
        self.assertEqual(
            extract_post({"name": "grayscale", "amount": 0.25}),
            {"name": "grayscale", "amount": 0.25})

    def test_name_and_amount_spellings(self):
        self.assertEqual(extract_post({"filter": "bloom", "value": 0.8}),
                         {"name": "bloom", "amount": 0.8})
        self.assertEqual(extract_post({"blur": 4}),
                         {"name": "blur", "amount": 4})

    def test_token_list(self):
        self.assertEqual(extract_post(["filter", "blur", "2"]),
                         {"name": "blur", "amount": 2})
        self.assertEqual(extract_post(["sepia", "0.5"]),
                         {"name": "sepia", "amount": 0.5})
        self.assertEqual(extract_post(["vignette", 0.75]),
                         {"name": "vignette", "amount": 0.75})

    def test_source_line_string(self):
        self.assertEqual(extract_post("filter gamma 2.4"),
                         {"name": "gamma", "amount": 2.4})
        self.assertEqual(extract_post("bloom"),
                         {"name": "bloom", "amount": 0.5})

    def test_numeric_strings_and_case(self):
        self.assertEqual(extract_post({"name": "Blur", "amount": "3"}),
                         {"name": "blur", "amount": 3})
        self.assertEqual(
            extract_post({"name": "GAMMA", "amount": "1.8"}),
            {"name": "gamma", "amount": 1.8})

    def test_blur_integral_float_becomes_int(self):
        self.assertEqual(extract_post({"name": "blur", "amount": 2.0}),
                         {"name": "blur", "amount": 2})

    def test_unconvertible_amount_passes_through(self):
        d = extract_post({"name": "gamma", "amount": "fast"})
        self.assertEqual(d["amount"], "fast")

    def test_input_not_mutated(self):
        props = {"name": "blur", "amount": 2}
        snapshot = dict(props)
        extract_post(props)
        self.assertEqual(props, snapshot)
        tokens = ["filter", "blur", "2"]
        extract_post(tokens)
        self.assertEqual(tokens, ["filter", "blur", "2"])


class TestCollectPostChain(unittest.TestCase):
    def test_chain_order_preserved_dicts(self):
        chain = collect_post([
            {"name": "gamma", "amount": 2.2},
            {"name": "blur", "amount": 2},
            {"name": "bloom"},
            {"name": "gamma", "amount": 1.0},
        ])
        self.assertEqual(
            [(d["name"], d["amount"]) for d in chain],
            [("gamma", 2.2), ("blur", 2), ("bloom", 0.5),
             ("gamma", 1.0)])

    def test_chain_order_preserved_lines_and_tokens(self):
        chain = collect_post([
            "filter sepia 0.5",
            ["filter", "blur", "3"],
            {"name": "vignette", "amount": 0.25},
        ])
        self.assertEqual([d["name"] for d in chain],
                         ["sepia", "blur", "vignette"])
        self.assertEqual(post_lines(chain), [
            "post sepia 0.5", "post blur 3", "post vignette 0.25"])

    def test_chain_from_filters_key_dict(self):
        chain = collect_post({"filters": [{"name": "blur"},
                                          {"name": "bloom"}]})
        self.assertEqual([d["name"] for d in chain], ["blur", "bloom"])

    def test_single_statement_is_one_filter_chain(self):
        self.assertEqual(collect_post({"name": "blur", "amount": 2}),
                         [{"name": "blur", "amount": 2}])
        self.assertEqual(collect_post(["blur", "2"]),
                         [{"name": "blur", "amount": 2}])
        self.assertEqual(collect_post("filter bloom 0.7"),
                         [{"name": "bloom", "amount": 0.7}])

    def test_empty_chain(self):
        self.assertEqual(collect_post([]), [])
        self.assertEqual(collect_post(None), [])


class TestPostLine(unittest.TestCase):
    def test_exact_lines_defaults(self):
        self.assertEqual(post_line(extract_post({"name": "blur"})),
                         "post blur 1")
        self.assertEqual(post_line(extract_post({"name": "bloom"})),
                         "post bloom 0.5")
        self.assertEqual(post_line(extract_post({"name": "gamma"})),
                         "post gamma 2.2")
        self.assertEqual(post_line(extract_post({"name": "grayscale"})),
                         "post grayscale 1")
        self.assertEqual(post_line(extract_post({"name": "sepia"})),
                         "post sepia 1")

    def test_exact_lines_explicit(self):
        self.assertEqual(post_line({"name": "blur", "amount": 3}),
                         "post blur 3")
        self.assertEqual(post_line({"name": "vignette", "amount": 0.25}),
                         "post vignette 0.25")
        self.assertEqual(post_line({"name": "gamma", "amount": 1.8}),
                         "post gamma 1.8")

    def test_formatting_is_percent_6g(self):
        # %.6g: trailing zeros dropped, 6 significant digits kept.
        self.assertEqual(post_line({"name": "bloom", "amount": 0.50}),
                         "post bloom 0.5")
        self.assertEqual(
            post_line({"name": "gamma", "amount": 2.2000001}),
            "post gamma 2.2")
        self.assertEqual(
            post_line({"name": "grayscale", "amount": 1 / 3}),
            "post grayscale 0.333333")

    def test_missing_amount_falls_back_to_default(self):
        self.assertEqual(post_line({"name": "gamma"}), "post gamma 2.2")
        self.assertEqual(post_line({"name": "blur"}), "post blur 1")

    def test_post_lines_empty(self):
        self.assertEqual(post_lines([]), [])
        self.assertEqual(post_lines(None), [])


class TestValidatePost(unittest.TestCase):
    def test_valid_boundaries(self):
        for d in ({"name": "blur", "amount": 1},
                  {"name": "gamma", "amount": 0.001},
                  {"name": "grayscale", "amount": 0},
                  {"name": "grayscale", "amount": 1},
                  {"name": "sepia", "amount": 0.5},
                  {"name": "bloom", "amount": 0},
                  {"name": "vignette", "amount": 0}):
            self.assertEqual(validate_post(d), [], d)

    def test_unknown_name(self):
        errors = validate_post(extract_post({"name": "sharpen",
                                             "amount": 1}))
        self.assertEqual(len(errors), 1)
        self.assertIn("sharpen", errors[0])
        self.assertIn("blur", errors[0])

    def test_missing_name(self):
        errors = validate_post({})
        self.assertEqual(len(errors), 1)
        self.assertIn("no name", errors[0])

    def test_blur_zero_and_negative(self):
        for bad in (0, -2):
            errors = validate_post({"name": "blur", "amount": bad})
            self.assertEqual(len(errors), 1)
            self.assertIn("blur", errors[0])
            self.assertIn("at least 1", errors[0])

    def test_blur_non_integer(self):
        errors = validate_post(extract_post({"name": "blur",
                                             "amount": 1.5}))
        self.assertEqual(len(errors), 1)
        self.assertIn("not an integer", errors[0])

    def test_gamma_must_be_positive(self):
        for bad in (0, -1.0):
            errors = validate_post({"name": "gamma", "amount": bad})
            self.assertEqual(len(errors), 1)
            self.assertIn("gamma", errors[0])
            self.assertIn("more than 0", errors[0])

    def test_grayscale_and_sepia_range(self):
        for name in ("grayscale", "sepia"):
            for bad in (-0.1, 1.5):
                errors = validate_post({"name": name, "amount": bad})
                self.assertEqual(len(errors), 1)
                self.assertIn(name, errors[0])
                self.assertIn("0..1", errors[0])

    def test_bloom_and_vignette_negative(self):
        for name in ("bloom", "vignette"):
            errors = validate_post({"name": name, "amount": -0.5})
            self.assertEqual(len(errors), 1)
            self.assertIn(name, errors[0])
            self.assertIn("at least 0", errors[0])

    def test_non_number_and_non_finite_amounts(self):
        errors = validate_post(extract_post({"name": "gamma",
                                             "amount": "fast"}))
        self.assertEqual(len(errors), 1)
        self.assertIn("not a number", errors[0])
        for bad in (math.inf, -math.inf, math.nan):
            errors = validate_post({"name": "bloom", "amount": bad})
            self.assertEqual(len(errors), 1)
            self.assertIn("finite", errors[0])

    def test_missing_amount_is_valid(self):
        self.assertEqual(validate_post({"name": "blur"}), [])
        self.assertEqual(validate_post({"name": "sepia"}), [])

    def test_full_chain_validates_clean(self):
        chain = collect_post([
            "filter blur 2", "filter bloom", "filter vignette 0.4",
            "filter gamma 2.2", "filter grayscale 0.5",
            "filter sepia",
        ])
        for d in chain:
            self.assertEqual(validate_post(d), [], d)
        self.assertEqual(post_lines(chain), [
            "post blur 2", "post bloom 0.5", "post vignette 0.4",
            "post gamma 2.2", "post grayscale 0.5", "post sepia 1"])


if __name__ == "__main__":
    unittest.main()
