#!/usr/bin/env python3
"""Tests for the Forge3D Wave B keyframe-track extension.

Covers ``tools/f3dc/ext_keys.py``: building normalised tracks from
``keys`` headers + ``key`` dicts, validation, and ``.scene`` lines.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_keys.py
"""

import copy
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

import ext_keys  # noqa: E402
from ext_keys import build_tracks, track_lines, validate_tracks  # noqa: E402


# The frozen example from the brief:
#
#     keys hero duration 4 loop pingpong
#     key hero at 0 pos 0,0,0 rot 0,0,0 scale 1
#     key hero at 2 pos 3,1,0 rot 0,90,0 scale 1.5 ease smooth
#     key hero at 4 pos 0,0,0 rot 0,180,0 scale 1
EXAMPLE_HEADERS = {"hero": {"duration": 4, "loop": "pingpong"}}
EXAMPLE_KEYS = [
    {"target": "hero", "time": 0, "pos": (0, 0, 0), "rot": (0, 0, 0),
     "scale": 1},
    {"target": "hero", "time": 2, "pos": (3, 1, 0), "rot": (0, 90, 0),
     "scale": 1.5, "ease": "smooth"},
    {"target": "hero", "time": 4, "pos": (0, 0, 0), "rot": (0, 180, 0),
     "scale": 1},
]
EXAMPLE_LINES = [
    "keys hero 4 pingpong 3",
    "key 0 0 0 0 0 0 0 1 linear",
    "key 2 3 1 0 0 90 0 1.5 smooth",
    "key 4 0 0 0 0 180 0 1 linear",
]


class TestBuildTracks(unittest.TestCase):
    def test_example_build_exact(self):
        tracks = build_tracks(copy.deepcopy(EXAMPLE_HEADERS),
                              copy.deepcopy(EXAMPLE_KEYS))
        self.assertEqual(list(tracks), ["hero"])
        track = tracks["hero"]
        self.assertEqual(track["duration"], 4.0)
        self.assertEqual(track["loop"], "pingpong")
        self.assertEqual(track["keys"], [
            {"target": "hero", "time": 0.0, "pos": (0.0, 0.0, 0.0),
             "rot": (0.0, 0.0, 0.0), "scale": 1.0, "ease": "linear"},
            {"target": "hero", "time": 2.0, "pos": (3.0, 1.0, 0.0),
             "rot": (0.0, 90.0, 0.0), "scale": 1.5, "ease": "smooth"},
            {"target": "hero", "time": 4.0, "pos": (0.0, 0.0, 0.0),
             "rot": (0.0, 180.0, 0.0), "scale": 1.0, "ease": "linear"},
        ])

    def test_defaults_no_header(self):
        # A target with keys but no header: duration 0.0 (the Fortran
        # "<= 0 means last key time" sentinel), loop 'once', and the
        # per-key defaults pos/rot (0,0,0), scale 1.0, ease linear.
        tracks = build_tracks({}, [{"target": "hero", "time": 0}])
        track = tracks["hero"]
        self.assertEqual(track["duration"], 0.0)
        self.assertEqual(track["loop"], "once")
        self.assertEqual(track["keys"], [
            {"target": "hero", "time": 0.0, "pos": (0.0, 0.0, 0.0),
             "rot": (0.0, 0.0, 0.0), "scale": 1.0, "ease": "linear"},
        ])

    def test_header_duration_none_and_loop_missing(self):
        tracks = build_tracks(
            {"hero": {"duration": None}},
            [{"target": "hero", "time": 1}])
        self.assertEqual(tracks["hero"]["duration"], 0.0)
        self.assertEqual(tracks["hero"]["loop"], "once")

    def test_keys_sorted_by_time(self):
        shuffled = [EXAMPLE_KEYS[2], EXAMPLE_KEYS[0], EXAMPLE_KEYS[1]]
        tracks = build_tracks(copy.deepcopy(EXAMPLE_HEADERS),
                              copy.deepcopy(shuffled))
        self.assertEqual(
            [key["time"] for key in tracks["hero"]["keys"]],
            [0.0, 2.0, 4.0])
        self.assertEqual(track_lines("hero", tracks["hero"]),
                         EXAMPLE_LINES)

    def test_header_only_target_kept_with_no_keys(self):
        tracks = build_tracks({"hero": {"duration": 4,
                                        "loop": "once"}}, [])
        self.assertEqual(tracks, {"hero": {"duration": 4.0,
                                           "loop": "once",
                                           "keys": []}})

    def test_multiple_targets_are_independent(self):
        tracks = build_tracks(
            {"villain": {"duration": 2, "loop": "forever"}},
            [{"target": "hero", "time": 0},
             {"target": "villain", "time": 1, "pos": (1, 2, 3)}])
        self.assertEqual(tracks["hero"]["loop"], "once")
        self.assertEqual(tracks["hero"]["duration"], 0.0)
        self.assertEqual(tracks["villain"]["loop"], "forever")
        self.assertEqual(tracks["villain"]["keys"][0]["pos"],
                         (1.0, 2.0, 3.0))

    def test_pure_does_not_mutate_inputs(self):
        headers = copy.deepcopy(EXAMPLE_HEADERS)
        keys = copy.deepcopy(EXAMPLE_KEYS)
        build_tracks(headers, keys)
        self.assertEqual(headers, EXAMPLE_HEADERS)
        self.assertEqual(keys, EXAMPLE_KEYS)


class TestValidateTracks(unittest.TestCase):
    def assert_error_mentions(self, tracks, *words):
        errors = validate_tracks(tracks)
        self.assertTrue(errors, "expected errors for %r" % (tracks,))
        for word in words:
            self.assertTrue(
                any(word in message for message in errors),
                "no error mentions %r: %r" % (word, errors))
        return errors

    def test_example_is_valid(self):
        tracks = build_tracks(copy.deepcopy(EXAMPLE_HEADERS),
                              copy.deepcopy(EXAMPLE_KEYS))
        self.assertEqual(validate_tracks(tracks), [])

    def test_single_key_track_is_valid(self):
        tracks = build_tracks({}, [{"target": "hero", "time": 0}])
        self.assertEqual(validate_tracks(tracks), [])

    def test_no_header_target_is_valid(self):
        tracks = build_tracks({}, [{"target": "hero", "time": 3,
                                    "ease": "in"}])
        self.assertEqual(validate_tracks(tracks), [])

    def test_duration_equal_to_last_key_is_valid(self):
        tracks = build_tracks(
            {"hero": {"duration": 4, "loop": "once"}},
            [{"target": "hero", "time": 4}])
        self.assertEqual(validate_tracks(tracks), [])

    def test_duplicate_time_is_error(self):
        tracks = build_tracks({}, [{"target": "hero", "time": 1},
                                   {"target": "hero", "time": 1}])
        self.assert_error_mentions(tracks, "duplicate", "time")

    def test_negative_time_is_error(self):
        tracks = build_tracks({}, [{"target": "hero", "time": -1}])
        self.assert_error_mentions(tracks, "negative", "time")

    def test_bad_ease_is_error(self):
        tracks = build_tracks({}, [{"target": "hero", "time": 0,
                                    "ease": "bounce"}])
        self.assert_error_mentions(tracks, "ease", "bounce")

    def test_bad_loop_is_error(self):
        tracks = build_tracks(
            {"hero": {"duration": 4, "loop": "sideways"}},
            [{"target": "hero", "time": 0}])
        self.assert_error_mentions(tracks, "loop", "sideways")

    def test_duration_before_last_key_is_error(self):
        tracks = build_tracks(
            {"hero": {"duration": 3, "loop": "once"}},
            [{"target": "hero", "time": 0},
             {"target": "hero", "time": 4}])
        self.assert_error_mentions(tracks, "duration")

    def test_scale_zero_is_error(self):
        tracks = build_tracks({}, [{"target": "hero", "time": 0,
                                    "scale": 0}])
        self.assert_error_mentions(tracks, "scale")

    def test_negative_scale_is_error(self):
        tracks = build_tracks({}, [{"target": "hero", "time": 0,
                                    "scale": -2}])
        self.assert_error_mentions(tracks, "scale")

    def test_header_without_keys_is_error(self):
        tracks = build_tracks({"hero": {"duration": 4,
                                        "loop": "pingpong"}}, [])
        self.assert_error_mentions(tracks, "no keys")

    def test_non_finite_numbers_are_errors(self):
        tracks = build_tracks({}, [{"target": "hero",
                                    "time": math.inf}])
        self.assert_error_mentions(tracks, "finite")
        tracks = build_tracks({}, [{"target": "hero", "time": 0,
                                    "scale": math.nan}])
        self.assert_error_mentions(tracks, "finite")
        tracks = build_tracks({}, [{"target": "hero", "time": 0,
                                    "pos": (0, math.inf, 0)}])
        self.assert_error_mentions(tracks, "finite")


class TestTrackLines(unittest.TestCase):
    def test_example_lines_exact(self):
        tracks = build_tracks(copy.deepcopy(EXAMPLE_HEADERS),
                              copy.deepcopy(EXAMPLE_KEYS))
        self.assertEqual(track_lines("hero", tracks["hero"]),
                         EXAMPLE_LINES)

    def test_defaults_lines_exact(self):
        # No header: duration %.6g of 0.0 is '0', loop 'once'.
        tracks = build_tracks({}, [{"target": "hero", "time": 0}])
        self.assertEqual(track_lines("hero", tracks["hero"]), [
            "keys hero 0 once 1",
            "key 0 0 0 0 0 0 0 1 linear",
        ])

    def test_floats_use_six_significant_digits(self):
        tracks = build_tracks(
            {"hero": {"duration": 1.23456789, "loop": "forever"}},
            [{"target": "hero", "time": 0.123456789,
              "scale": 2.5, "ease": "out"}])
        self.assertEqual(track_lines("hero", tracks["hero"]), [
            "keys hero 1.23457 forever 1",
            "key 0.123457 0 0 0 0 0 0 2.5 out",
        ])

    def test_module_exports(self):
        for name in ("build_tracks", "validate_tracks", "track_lines"):
            self.assertTrue(hasattr(ext_keys, name), name)


if __name__ == "__main__":
    unittest.main()
