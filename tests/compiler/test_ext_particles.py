#!/usr/bin/env python3
"""Tests for the Forge3D Wave B deterministic-particles extension.

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_particles.py
    python3 -m unittest tests.compiler.test_ext_particles

Covers the Wave B surface (MASTER-PLAN row 32): particle defaults,
named + hex + tuple colours, the exact ``particles`` emit line, the
validation errors, and the Python mirror of the frozen particle math
from ``src/particles.f90`` -- including the cross-language hash anchor
``hash01(1, 0, 0) == 0.5205930033698678`` hardcoded by Fortran seat
B71, and a state check whose expected value is computed in the test
directly from the frozen recipe (never via the module under test).
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

import ext_particles  # noqa: E402
from ext_particles import (  # noqa: E402
    extract_particles,
    particle_hash01,
    particle_state,
    particles_line,
    validate_particles,
)

MOD = 2147483648  # 2^31, the frozen hash modulus


def recipe_hash01(seed, i, k):
    """The frozen contract recipe, written out independently here."""
    x = (seed * 1103515245 + i * 12345 + k * 67890) % MOD
    x = (x * 1103515245 + 12345) % MOD
    return x / MOD


def recipe_state(origin, count, life, speed, spread, gravity, seed, i, t):
    """The frozen contract state formula, computed independently."""
    age = (t + i * (life / count)) % life
    h0 = recipe_hash01(seed, i, 0)
    h1 = recipe_hash01(seed, i, 1)
    h2 = recipe_hash01(seed, i, 2)
    vel = ((h0 - 0.5) * 2 * spread * speed,
           speed * (0.5 + 0.5 * h1),
           (h2 - 0.5) * 2 * spread * speed)
    pos = (origin[0] + vel[0] * age,
           origin[1] + vel[1] * age - 0.5 * gravity * age * age,
           origin[2] + vel[2] * age)
    return pos, 1 - age / life


class TestExtractParticles(unittest.TestCase):
    def test_defaults(self):
        d = extract_particles({})
        self.assertEqual(d["origin"], (0.0, 0.0, 0.0))
        self.assertEqual(d["count"], 100)
        self.assertEqual(d["life"], 2.0)
        self.assertEqual(d["speed"], 3.0)
        self.assertEqual(d["size"], 0.2)
        self.assertEqual(d["color"], (255, 180, 60))
        self.assertEqual(d["spread"], 0.5)
        self.assertEqual(d["gravity"], 0.0)
        self.assertEqual(d["seed"], 1)

    def test_full_props_frozen_surface(self):
        d = extract_particles({
            "at": (0, 2, 0), "count": 100, "life": 2, "speed": 3,
            "size": 0.2, "color": "orange", "spread": 0.5,
            "gravity": 9, "seed": 7,
        })
        self.assertEqual(d["origin"], (0.0, 2.0, 0.0))
        self.assertEqual(d["count"], 100)
        self.assertEqual(d["life"], 2.0)
        self.assertEqual(d["speed"], 3.0)
        self.assertEqual(d["size"], 0.2)
        # Frozen ir_nodes palette spelling of "orange".
        self.assertEqual(d["color"], (240, 140, 40))
        self.assertEqual(d["spread"], 0.5)
        self.assertEqual(d["gravity"], 9.0)
        self.assertEqual(d["seed"], 7)

    def test_at_string_and_numeric_strings(self):
        d = extract_particles({"at": "1,2,3", "count": "50",
                               "life": "1.5", "seed": "42"})
        self.assertEqual(d["origin"], (1.0, 2.0, 3.0))
        self.assertEqual(d["count"], 50)
        self.assertEqual(d["life"], 1.5)
        self.assertEqual(d["seed"], 42)

    def test_hex_colour(self):
        self.assertEqual(
            extract_particles({"color": "#ff8000"})["color"],
            (255, 128, 0))

    def test_tuple_colour(self):
        self.assertEqual(
            extract_particles({"color": (10, 20, 30)})["color"],
            (10, 20, 30))

    def test_colour_spelling_key(self):
        self.assertEqual(
            extract_particles({"colour": "blue"})["color"],
            (60, 100, 240))

    def test_input_not_mutated(self):
        props = {"at": (0, 2, 0), "count": 5, "color": "red"}
        snapshot = dict(props)
        extract_particles(props)
        self.assertEqual(props, snapshot)


class TestParticlesLine(unittest.TestCase):
    def test_exact_line_frozen_surface(self):
        d = extract_particles({
            "at": (0, 2, 0), "count": 100, "life": 2, "speed": 3,
            "size": 0.2, "color": "orange", "spread": 0.5,
            "gravity": 9, "seed": 7,
        })
        self.assertEqual(
            particles_line("sparks", d),
            "particles sparks 0 2 0 100 2 3 0.2 240 140 40 0.5 9 7")

    def test_exact_line_defaults(self):
        self.assertEqual(
            particles_line("p", extract_particles({})),
            "particles p 0 0 0 100 2 3 0.2 255 180 60 0.5 0 1")

    def test_exact_line_known_input(self):
        d = {"origin": (1, 2, 3), "count": 10, "life": 2.0,
             "speed": 3.0, "size": 0.5, "color": (255, 128, 0),
             "spread": 0.5, "gravity": 4.0, "seed": 7}
        self.assertEqual(
            particles_line("burst", d),
            "particles burst 1 2 3 10 2 3 0.5 255 128 0 0.5 4 7")


class TestValidateParticles(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(validate_particles(extract_particles({
            "at": (0, 2, 0), "count": 100, "life": 2, "speed": 3,
            "size": 0.2, "color": "orange", "spread": 0.5,
            "gravity": 9, "seed": 7})), [])
        self.assertEqual(validate_particles(extract_particles({})), [])

    def test_count_zero(self):
        errors = validate_particles(extract_particles({"count": 0}))
        self.assertEqual(len(errors), 1)
        self.assertIn("count", errors[0])
        self.assertIn("10000", errors[0])

    def test_count_10001(self):
        errors = validate_particles(extract_particles({"count": 10001}))
        self.assertEqual(len(errors), 1)
        self.assertIn("count", errors[0])

    def test_life_zero(self):
        errors = validate_particles(extract_particles({"life": 0}))
        self.assertEqual(len(errors), 1)
        self.assertIn("life", errors[0])
        self.assertIn("3600", errors[0])

    def test_size_zero(self):
        errors = validate_particles(extract_particles({"size": 0}))
        self.assertEqual(len(errors), 1)
        self.assertIn("size", errors[0])

    def test_seed_100001(self):
        errors = validate_particles(extract_particles({"seed": 100001}))
        self.assertEqual(len(errors), 1)
        self.assertIn("seed", errors[0])
        self.assertIn("100000", errors[0])

    def test_spread_negative(self):
        errors = validate_particles(extract_particles({"spread": -1}))
        self.assertEqual(len(errors), 1)
        self.assertIn("spread", errors[0])

    def test_speed_and_gravity_out_of_range(self):
        errors = validate_particles({"speed": 1001})
        self.assertEqual(len(errors), 1)
        self.assertIn("speed", errors[0])
        errors = validate_particles({"gravity": -101})
        self.assertEqual(len(errors), 1)
        self.assertIn("gravity", errors[0])

    def test_non_finite_coord(self):
        for bad in (math.inf, -math.inf, math.nan):
            errors = validate_particles(
                extract_particles({"at": (bad, 0, 0)}))
            self.assertEqual(len(errors), 1)
            self.assertIn("origin", errors[0])
            self.assertIn("finite", errors[0])

    def test_boundary_values_valid(self):
        self.assertEqual(validate_particles({
            "count": 10000, "life": 3600, "speed": 1000, "size": 10,
            "spread": 10, "gravity": -100, "seed": 100000}), [])
        self.assertEqual(validate_particles({
            "count": 1, "speed": 0, "spread": 0, "gravity": 100,
            "seed": 0}), [])


class TestParticleHash01(unittest.TestCase):
    def test_cross_language_anchor(self):
        # Fortran seat B71's hardcoded value for hash01(1, 0, 0).
        self.assertAlmostEqual(
            particle_hash01(1, 0, 0), 0.5205930033698678, delta=1e-15)

    def test_matches_recipe(self):
        for seed, i, k in ((1, 0, 0), (1, 0, 1), (1, 0, 2), (0, 0, 0),
                           (42, 7, 1), (7, 3, 2), (100000, 999, 2)):
            self.assertEqual(particle_hash01(seed, i, k),
                             recipe_hash01(seed, i, k))

    def test_range_sweep(self):
        for seed in (0, 1, 7, 12345, 100000):
            for i in range(50):
                for k in range(3):
                    u = particle_hash01(seed, i, k)
                    self.assertGreaterEqual(u, 0.0)
                    self.assertLess(u, 1.0)


class TestParticleState(unittest.TestCase):
    SYS = {"origin": (1.0, 2.0, 3.0), "count": 10, "life": 2.0,
           "speed": 3.0, "size": 0.5, "color": (255, 128, 0),
           "spread": 0.5, "gravity": 4.0, "seed": 7}

    def test_t0_i0_is_origin_full_scale(self):
        pos, scale = particle_state(self.SYS, 0, 0.0)
        self.assertEqual(pos, (1.0, 2.0, 3.0))
        self.assertEqual(scale, 1.0)

    def test_matches_hand_computed(self):
        # Expected value computed in this test directly from the
        # frozen recipe (recipe_state above), tolerance 1e-12.
        for i, t in ((3, 0.7), (0, 1.25), (9, 0.0), (5, 1.999)):
            pos, scale = particle_state(self.SYS, i, t)
            want_pos, want_scale = recipe_state(
                (1.0, 2.0, 3.0), 10, 2.0, 3.0, 0.5, 4.0, 7, i, t)
            for got, want in zip(pos, want_pos):
                self.assertAlmostEqual(got, want, delta=1e-12)
            self.assertAlmostEqual(scale, want_scale, delta=1e-12)

    def test_deterministic(self):
        self.assertEqual(particle_state(self.SYS, 5, 1.25),
                         particle_state(self.SYS, 5, 1.25))

    def test_scale_in_range_and_wraps_by_life(self):
        for i in range(10):
            _pos, scale = particle_state(self.SYS, i, 0.3)
            self.assertGreater(scale, 0.0)
            self.assertLessEqual(scale, 1.0)
        # t and t + life are the same frame.
        pos_a, scale_a = particle_state(self.SYS, 4, 0.3)
        pos_b, scale_b = particle_state(self.SYS, 4, 0.3 + 2.0)
        for a, b in zip(pos_a, pos_b):
            self.assertAlmostEqual(a, b, delta=1e-12)
        self.assertAlmostEqual(scale_a, scale_b, delta=1e-12)

    def test_defaults_match_explicit_defaults(self):
        bare = {"origin": (0.0, 0.0, 0.0), "count": 4, "life": 1.5,
                "speed": 2.0, "size": 1.0}
        self.assertEqual(
            particle_state(bare, 2, 0.4),
            particle_state(extract_particles({
                "at": (0, 0, 0), "count": 4, "life": 1.5, "speed": 2,
                "size": 1}), 2, 0.4))

    def test_nonpositive_life_is_dead_at_origin(self):
        d = dict(self.SYS, life=0.0)
        pos, scale = particle_state(d, 3, 0.7)
        self.assertEqual(pos, (1.0, 2.0, 3.0))
        self.assertEqual(scale, 0.0)


if __name__ == "__main__":
    unittest.main()
