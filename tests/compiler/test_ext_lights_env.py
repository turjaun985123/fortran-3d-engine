#!/usr/bin/env python3
"""Tests for the Forge3D Wave A lights/environment extension.

Covers ``tools/f3dc/ext_lights_env.py``: point/spot light extraction,
validation and ``.scene`` lines, plus scene fog / tonemap / shadow
extraction, validation and lines.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_lights_env.py
"""

import copy
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

import ext_lights_env  # noqa: E402
from ext_lights_env import (  # noqa: E402
    WAVEA_LIGHT_KINDS,
    env_lines,
    extract_env,
    extract_light_ext,
    light_line,
    validate_env,
    validate_light_ext,
)


class TestExtractLightExt(unittest.TestCase):
    def test_wavea_kinds_constant(self):
        self.assertEqual(WAVEA_LIGHT_KINDS, ("point", "spot"))

    def test_defaults_on_empty_props(self):
        ext = extract_light_ext({})
        self.assertIsNone(ext["position"])
        self.assertIsNone(ext["target"])
        self.assertEqual(ext["distance"], 0.0)
        self.assertEqual(ext["decay"], 2.0)
        self.assertEqual(ext["angle"], 45.0)
        self.assertEqual(ext["penumbra"], 0.0)

    def test_point_full_props(self):
        # `light point at 2,3,4 ... distance 10 decay 2`
        ext = extract_light_ext(
            {"at": (2, 3, 4), "distance": 10, "decay": 2})
        self.assertEqual(ext["position"], (2.0, 3.0, 4.0))
        self.assertEqual(ext["distance"], 10.0)
        self.assertEqual(ext["decay"], 2.0)

    def test_position_key(self):
        ext = extract_light_ext({"position": (1, 2, 3)})
        self.assertEqual(ext["position"], (1.0, 2.0, 3.0))

    def test_from_is_position_not_negated(self):
        # For point/spot, `from` IS the position (never negated,
        # unlike a directional light's direction).
        ext = extract_light_ext({"from": (2, 3, 4)})
        self.assertEqual(ext["position"], (2.0, 3.0, 4.0))

    def test_at_wins_over_from(self):
        ext = extract_light_ext({"at": (1, 1, 1), "from": (9, 9, 9)})
        self.assertEqual(ext["position"], (1.0, 1.0, 1.0))

    def test_spot_target_via_look_and_target(self):
        self.assertEqual(
            extract_light_ext({"look": (0, 0, 0)})["target"],
            (0.0, 0.0, 0.0))
        self.assertEqual(
            extract_light_ext({"target": (5, 6, 7)})["target"],
            (5.0, 6.0, 7.0))

    def test_spot_angle_penumbra(self):
        ext = extract_light_ext({"angle": 30, "penumbra": 0.5})
        self.assertEqual(ext["angle"], 30.0)
        self.assertEqual(ext["penumbra"], 0.5)

    def test_string_values(self):
        ext = extract_light_ext(
            {"at": "2,3,4", "distance": "10", "angle": "30"})
        self.assertEqual(ext["position"], (2.0, 3.0, 4.0))
        self.assertEqual(ext["distance"], 10.0)
        self.assertEqual(ext["angle"], 30.0)

    def test_pure_does_not_mutate_props(self):
        props = {"at": (2, 3, 4), "distance": 10}
        snapshot = copy.deepcopy(props)
        extract_light_ext(props)
        self.assertEqual(props, snapshot)


class TestValidateLightExt(unittest.TestCase):
    def assert_error_mentions(self, kind, ext, prop):
        errors = validate_light_ext(kind, ext)
        self.assertTrue(errors, "expected errors for %r" % (ext,))
        self.assertTrue(
            any(prop in message for message in errors),
            "no error mentions %r: %r" % (prop, errors))
        return errors

    def test_point_without_position(self):
        self.assert_error_mentions(
            "point", extract_light_ext({}), "position")

    def test_spot_without_position(self):
        self.assert_error_mentions(
            "spot", extract_light_ext({"look": (0, 0, 0)}), "position")

    def test_spot_without_target(self):
        self.assert_error_mentions(
            "spot", extract_light_ext({"at": (0, 5, 0)}), "target")

    def test_valid_point_and_spot(self):
        self.assertEqual(validate_light_ext(
            "point", extract_light_ext({"at": (2, 3, 4)})), [])
        self.assertEqual(validate_light_ext(
            "spot", extract_light_ext(
                {"at": (0, 5, 0), "look": (0, 0, 0)})), [])

    def test_angle_outside_open_interval(self):
        base = {"at": (0, 5, 0), "look": (0, 0, 0)}
        for bad in (0, 180, 200, -5):
            ext = extract_light_ext(dict(base, angle=bad))
            self.assert_error_mentions("spot", ext, "angle")
        for good in (0.5, 45, 179.9):
            ext = extract_light_ext(dict(base, angle=good))
            self.assertEqual(validate_light_ext("spot", ext), [])

    def test_penumbra_outside_unit_interval(self):
        base = {"at": (0, 5, 0), "look": (0, 0, 0)}
        for bad in (-0.1, 1.5):
            ext = extract_light_ext(dict(base, penumbra=bad))
            self.assert_error_mentions("spot", ext, "penumbra")
        for good in (0, 0.5, 1):
            ext = extract_light_ext(dict(base, penumbra=good))
            self.assertEqual(validate_light_ext("spot", ext), [])

    def test_negative_distance(self):
        ext = extract_light_ext({"at": (2, 3, 4), "distance": -1})
        self.assert_error_mentions("point", ext, "distance")

    def test_negative_decay(self):
        ext = extract_light_ext({"at": (2, 3, 4), "decay": -0.5})
        self.assert_error_mentions("point", ext, "decay")

    def test_zero_distance_and_decay_are_valid(self):
        ext = extract_light_ext(
            {"at": (2, 3, 4), "distance": 0, "decay": 0})
        self.assertEqual(validate_light_ext("point", ext), [])


class TestLightLine(unittest.TestCase):
    def test_point_line_exact(self):
        ext = extract_light_ext(
            {"at": (2, 3, 4), "distance": 10, "decay": 2})
        self.assertEqual(
            light_line("point", ext, (220, 60, 60), 1.5),
            "light point 2 3 4 220 60 60 1.5 10 2")

    def test_point_line_defaults(self):
        ext = extract_light_ext({"at": (2, 3, 4)})
        self.assertEqual(
            light_line("point", ext, (255, 255, 255), 1.0),
            "light point 2 3 4 255 255 255 1 0 2")

    def test_spot_line_direction_normalised_down(self):
        # pos (0,5,0), target origin -> direction (0,-1,0).
        ext = extract_light_ext(
            {"at": (0, 5, 0), "look": (0, 0, 0),
             "angle": 30, "penumbra": 0.5})
        self.assertEqual(
            light_line("spot", ext, (255, 255, 255), 2),
            "light spot 0 5 0 0 -1 0 255 255 255 2 0 2 30 0.5")

    def test_spot_line_direction_normalised_diagonal(self):
        # target - position = (3,0,4), length 5 -> (0.6, 0, 0.8).
        ext = extract_light_ext(
            {"at": (0, 0, 0), "target": (3, 0, 4), "distance": 10})
        self.assertEqual(
            light_line("spot", ext, (220, 60, 60), 1.5),
            "light spot 0 0 0 0.6 0 0.8 220 60 60 1.5 10 2 45 0")

    def test_spot_without_target_returns_none(self):
        ext = extract_light_ext({"at": (0, 5, 0)})
        self.assertIsNone(light_line("spot", ext, (255, 255, 255), 1))

    def test_point_without_position_returns_none(self):
        self.assertIsNone(light_line(
            "point", extract_light_ext({}), (255, 255, 255), 1))

    def test_spot_target_equals_position_returns_none(self):
        ext = extract_light_ext({"at": (1, 1, 1), "look": (1, 1, 1)})
        self.assertIsNone(light_line("spot", ext, (255, 255, 255), 1))

    def test_non_wavea_kind_returns_none(self):
        ext = extract_light_ext({"at": (2, 3, 4)})
        self.assertIsNone(
            light_line("directional", ext, (255, 255, 255), 1))
        self.assertIsNone(
            light_line("ambient", ext, (255, 255, 255), 1))


class TestExtractEnv(unittest.TestCase):
    def test_defaults(self):
        self.assertEqual(extract_env({}), {
            "fog": None,
            "tonemap": {"mode": "none", "exposure": 1.0},
            "shadow": {"mode": "off", "size": 512},
        })

    def test_fog_linear_flat_keys(self):
        env = extract_env({"fog": "linear", "fog_near": 5,
                           "fog_far": 20, "fog_color": "#aabbcc"})
        self.assertEqual(env["fog"], {
            "mode": "linear", "near": 5.0, "far": 20.0,
            "color": (170, 187, 204)})

    def test_fog_linear_clause_string(self):
        env = extract_env({"fog": "linear near 5 far 20 color #aabbcc"})
        self.assertEqual(env["fog"], {
            "mode": "linear", "near": 5.0, "far": 20.0,
            "color": (170, 187, 204)})

    def test_fog_exp2(self):
        env = extract_env({"fog": "exp2", "fog_density": 0.05})
        self.assertEqual(env["fog"]["mode"], "exp2")
        self.assertEqual(env["fog"]["density"], 0.05)
        self.assertEqual(env["fog"]["color"], (255, 255, 255))

    def test_fog_color_tuple_and_named(self):
        env = extract_env({"fog": "linear", "fog_near": 1,
                           "fog_far": 9, "fog_color": (1, 2, 3)})
        self.assertEqual(env["fog"]["color"], (1, 2, 3))
        env = extract_env({"fog": "exp2", "fog_color": "red"})
        self.assertEqual(env["fog"]["color"], (220, 60, 60))

    def test_fog_none_is_no_fog(self):
        self.assertIsNone(extract_env({"fog": "none"})["fog"])
        self.assertIsNone(extract_env({"fog": "off"})["fog"])

    def test_tonemap_modes_and_exposure(self):
        self.assertEqual(
            extract_env({"tonemap": "aces", "exposure": 1.2})["tonemap"],
            {"mode": "aces", "exposure": 1.2})
        self.assertEqual(
            extract_env({"tonemap": "reinhard"})["tonemap"],
            {"mode": "reinhard", "exposure": 1.0})
        self.assertEqual(
            extract_env({"tonemap": "none"})["tonemap"],
            {"mode": "none", "exposure": 1.0})
        # `tone` is the alias key.
        self.assertEqual(
            extract_env({"tone": "aces"})["tonemap"]["mode"], "aces")

    def test_shadow_modes_and_size(self):
        self.assertEqual(extract_env({"shadow": "on"})["shadow"],
                         {"mode": "on", "size": 512})
        self.assertEqual(extract_env({"shadow": "soft"})["shadow"],
                         {"mode": "soft", "size": 512})
        self.assertEqual(extract_env({"shadow": "off"})["shadow"],
                         {"mode": "off", "size": 512})
        self.assertEqual(
            extract_env({"shadow": "on", "shadow_size": 1024})["shadow"],
            {"mode": "on", "size": 1024})

    def test_pure_does_not_mutate_props(self):
        props = {"fog": "linear", "fog_near": 5, "fog_far": 20}
        snapshot = copy.deepcopy(props)
        extract_env(props)
        self.assertEqual(props, snapshot)


class TestShadowClauseStringSize(unittest.TestCase):
    """Regression: a trailing bare integer in a shadow clause string
    is the map size (``scene shadow on 1024`` must not fall back to
    the 512 default)."""

    def test_shadow_clause_string_on_1024(self):
        self.assertEqual(extract_env({"shadow": "on 1024"})["shadow"],
                         {"mode": "on", "size": 1024})

    def test_shadow_clause_string_soft_256(self):
        self.assertEqual(extract_env({"shadow": "soft 256"})["shadow"],
                         {"mode": "soft", "size": 256})

    def test_shadow_clause_string_on_default(self):
        self.assertEqual(extract_env({"shadow": "on"})["shadow"],
                         {"mode": "on", "size": 512})

    def test_shadow_clause_string_off(self):
        self.assertEqual(extract_env({"shadow": "off"})["shadow"],
                         {"mode": "off", "size": 512})

    def test_shadow_clause_string_invalid_size_still_validated(self):
        # 100 is not a power of two: extract must surface it so
        # validate_env reports it, not silently accept/default it.
        env = extract_env({"shadow": "on 100"})
        self.assertEqual(env["shadow"], {"mode": "on", "size": 100})
        errors = validate_env(env)
        self.assertTrue(
            any("size" in message for message in errors),
            "no error mentions 'size': %r" % (errors,))

    def test_shadow_clause_string_env_lines_round_trip(self):
        env = extract_env({"shadow": "on 1024"})
        self.assertEqual(validate_env(env), [])
        self.assertEqual(env_lines(env), ["shadow on 1024"])


class TestValidateEnv(unittest.TestCase):
    def assert_error_mentions(self, env, prop):
        errors = validate_env(env)
        self.assertTrue(errors, "expected errors for %r" % (env,))
        self.assertTrue(
            any(prop in message for message in errors),
            "no error mentions %r: %r" % (prop, errors))
        return errors

    def test_default_env_is_valid(self):
        self.assertEqual(validate_env(extract_env({})), [])

    def test_full_env_is_valid(self):
        env = extract_env({
            "fog": "linear", "fog_near": 5, "fog_far": 20,
            "tonemap": "aces", "exposure": 1.2, "shadow": "soft"})
        self.assertEqual(validate_env(env), [])

    def test_linear_fog_near_must_be_below_far(self):
        env = extract_env({"fog": "linear", "fog_near": 20,
                           "fog_far": 5})
        self.assert_error_mentions(env, "near")
        self.assert_error_mentions(env, "far")
        env = extract_env({"fog": "linear", "fog_near": 5,
                           "fog_far": 5})
        self.assert_error_mentions(env, "near")

    def test_linear_fog_missing_near_or_far(self):
        env = {"fog": {"mode": "linear", "color": (255, 255, 255)},
               "tonemap": {"mode": "none", "exposure": 1.0},
               "shadow": {"mode": "off", "size": 512}}
        self.assert_error_mentions(env, "near")

    def test_exp2_negative_density(self):
        env = extract_env({"fog": "exp2", "fog_density": -0.1})
        self.assert_error_mentions(env, "density")

    def test_exposure_must_be_positive(self):
        for bad in (0, -1.2):
            env = extract_env({"tonemap": "aces", "exposure": bad})
            self.assert_error_mentions(env, "exposure")

    def test_shadow_size_power_of_two_range(self):
        for bad in (500, 32, 8192, 0):
            env = {"fog": None,
                   "tonemap": {"mode": "none", "exposure": 1.0},
                   "shadow": {"mode": "on", "size": bad}}
            self.assert_error_mentions(env, "size")
        for good in (64, 512, 1024, 4096):
            env = {"fog": None,
                   "tonemap": {"mode": "none", "exposure": 1.0},
                   "shadow": {"mode": "on", "size": good}}
            self.assertEqual(validate_env(env), [])


class TestEnvLines(unittest.TestCase):
    def test_defaults_produce_no_lines(self):
        self.assertEqual(env_lines(extract_env({})), [])

    def test_full_env_lines_exact(self):
        env = extract_env({
            "fog": "linear", "fog_near": 5, "fog_far": 20,
            "fog_color": "#aabbcc",
            "tonemap": "aces", "exposure": 1.2, "shadow": "soft"})
        self.assertEqual(env_lines(env), [
            "fog linear 5 20 170 187 204",
            "tonemap aces 1.2",
            "shadow soft 512",
        ])

    def test_exp2_line_exact(self):
        env = extract_env({"fog": "exp2", "fog_density": 0.05})
        self.assertEqual(env_lines(env), ["fog exp2 0.05 255 255 255"])

    def test_fog_none_line_for_explicit_none_mode(self):
        env = {"fog": {"mode": "none"},
               "tonemap": {"mode": "none", "exposure": 1.0},
               "shadow": {"mode": "off", "size": 512}}
        self.assertEqual(env_lines(env), ["fog none"])

    def test_tonemap_and_shadow_lines(self):
        env = extract_env({"tonemap": "reinhard"})
        self.assertEqual(env_lines(env), ["tonemap reinhard 1"])
        env = extract_env({"shadow": "on", "shadow_size": 1024})
        self.assertEqual(env_lines(env), ["shadow on 1024"])
        # Default entries stay silent even when spelled out.
        env = extract_env({"tonemap": "none", "shadow": "off"})
        self.assertEqual(env_lines(env), [])


class TestRoundTrip(unittest.TestCase):
    def test_light_round_trip_point(self):
        props = {"at": (2, 3, 4), "distance": 10, "decay": 2}
        ext = extract_light_ext(props)
        self.assertEqual(validate_light_ext("point", ext), [])
        self.assertEqual(
            light_line("point", ext, (220, 60, 60), 1.5),
            "light point 2 3 4 220 60 60 1.5 10 2")

    def test_light_round_trip_spot(self):
        props = {"at": (0, 5, 0), "look": (0, 0, 0),
                 "angle": 30, "penumbra": 0.5}
        ext = extract_light_ext(props)
        self.assertEqual(validate_light_ext("spot", ext), [])
        self.assertEqual(
            light_line("spot", ext, (255, 255, 255), 2),
            "light spot 0 5 0 0 -1 0 255 255 255 2 0 2 30 0.5")

    def test_env_round_trip(self):
        props = {"fog": "linear", "fog_near": 5, "fog_far": 20,
                 "fog_color": "#aabbcc", "tonemap": "aces",
                 "exposure": 1.2, "shadow": "soft"}
        env = extract_env(props)
        self.assertEqual(validate_env(env), [])
        self.assertEqual(env_lines(env), [
            "fog linear 5 20 170 187 204",
            "tonemap aces 1.2",
            "shadow soft 512",
        ])

    def test_module_exports(self):
        for name in ("WAVEA_LIGHT_KINDS", "extract_light_ext",
                     "validate_light_ext", "light_line", "extract_env",
                     "validate_env", "env_lines"):
            self.assertTrue(hasattr(ext_lights_env, name), name)


if __name__ == "__main__":
    unittest.main()
