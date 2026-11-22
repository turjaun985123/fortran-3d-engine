#!/usr/bin/env python3
"""Tests for tools/f3dc/optimize.py (Forge3D seat B35).

Stdlib unittest only, standalone-runnable:

    python3 tests/compiler/test_optimize.py

Scenes are built directly from the real IR classes in ir_nodes.py
(IRScene / IRObject / IRAnim) and optimised through the real API:
``optimize(scene, bag, level=1)``, the ``PASSES`` registry and
``register_pass(name, fn)``.
"""

import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(
    0, str(Path(__file__).resolve().parents[2] / "tools" / "f3dc")
)

from ir_nodes import IRAnim, IRObject, IRScene  # noqa: E402
from optimize import PASSES, optimize, register_pass  # noqa: E402

GOOD_TRI = ((0, 0, 0), (2, 0, 0), (0, 2, 0))
# Collinear points -> cross product is exactly (0, 0, 0) -> zero area.
ZERO_AREA_TRI = ((0, 0, 0), (1, 1, 1), (2, 2, 2))


def scene_with(*objects, animations=None):
    return IRScene(
        name="test-scene",
        objects=list(objects),
        animations=list(animations or []),
    )


class TestOptimizeLevel0(unittest.TestCase):
    def test_level0_returns_equal_copy(self):
        scene = scene_with(
            IRObject(name="box", prim="cube", color=(10, 20, 30)),
            IRObject(name="ball", prim="sphere"),
        )
        result = optimize(scene, [], level=0)
        self.assertIsNot(result, scene)
        self.assertEqual(result, scene)
        # A copy, not the same objects.
        self.assertIsNot(result.objects[0], scene.objects[0])
        # No passes ran: no annotations / hints were added.
        self.assertEqual(result.extensions, {})
        self.assertEqual(result.objects[0].extensions, {})


class TestO1DropDegenerate(unittest.TestCase):
    def test_o1_drops_zero_scale_object(self):
        scene = scene_with(
            IRObject(name="flat", prim="cube", scale=(0, 1, 1)),
            IRObject(name="solid", prim="cube", scale=(1, 1, 1)),
        )
        result = optimize(scene, [], level=1)
        self.assertEqual([obj.name for obj in result.objects], ["solid"])


class TestO2DedupCandidates(unittest.TestCase):
    def test_o2_keeps_duplicates_but_records_candidates(self):
        kwargs = dict(prim="cube", color=(220, 60, 60), pos=(1, 2, 3),
                      rotate=(0, 45, 0), scale=(1, 1, 1), size=2.0)
        scene = scene_with(
            IRObject(name="dup_a", **kwargs),
            IRObject(name="dup_b", **kwargs),
            IRObject(name="other", prim="sphere", color=(60, 220, 60)),
        )
        result = optimize(scene, [], level=1)
        # Record-only pass: nothing is removed.
        self.assertEqual(len(result.objects), 3)
        self.assertGreaterEqual(
            result.extensions.get("dedup_candidates", 0), 1)


class TestO3DegenerateCull(unittest.TestCase):
    def test_o3_drops_zero_area_triangle_from_tris_object(self):
        scene = scene_with(
            IRObject(name="mesh", prim="tris",
                     triangles=[GOOD_TRI, ZERO_AREA_TRI]),
        )
        result = optimize(scene, [], level=1)
        self.assertEqual(len(result.objects), 1)
        self.assertEqual(result.objects[0].triangles, [GOOD_TRI])


class TestO5Palette(unittest.TestCase):
    def test_o5_cube_color_none_stays_none(self):
        scene = scene_with(IRObject(name="box", prim="cube", color=None))
        result = optimize(scene, [], level=1)
        self.assertIsNone(result.objects[0].color)

    def test_o5_sphere_color_none_becomes_neutral_default(self):
        scene = scene_with(IRObject(name="ball", prim="sphere", color=None))
        result = optimize(scene, [], level=1)
        self.assertEqual(result.objects[0].color, (200, 200, 205))


class TestO6TransformBake(unittest.TestCase):
    def test_o6_animated_not_annotated_unanimated_is(self):
        scene = scene_with(
            IRObject(name="spinner", prim="cube", rotate=(0, 30, 0)),
            IRObject(name="still", prim="cube", rotate=(10, 20, 30)),
            animations=[IRAnim(kind="rotate", target="spinner")],
        )
        result = optimize(scene, [], level=1)
        by_name = {obj.name: obj for obj in result.objects}
        self.assertNotIn("baked_rotation_deg",
                         by_name["spinner"].extensions)
        self.assertEqual(
            by_name["still"].extensions.get("baked_rotation_deg"),
            (10, 20, 30))


class TestNoInputMutation(unittest.TestCase):
    def test_input_scene_not_mutated(self):
        scene = scene_with(
            IRObject(name="flat", prim="cube", scale=(0, 1, 1)),
            IRObject(name="ball", prim="sphere", color=None),
        )
        snapshot = copy.deepcopy(scene)
        result = optimize(scene, [], level=1)
        # The optimised copy changed (O1 dropped, O5 filled) ...
        self.assertEqual([obj.name for obj in result.objects], ["ball"])
        self.assertEqual(result.objects[0].color, (200, 200, 205))
        # ... but the caller's scene is exactly as it was.
        self.assertEqual(scene, snapshot)
        self.assertEqual(len(scene.objects), 2)
        self.assertIsNone(scene.objects[1].color)
        self.assertEqual(scene.extensions, {})


class TestRegisterPass(unittest.TestCase):
    def test_register_pass_adds_a_pass_that_runs(self):
        original = list(PASSES)
        self.addCleanup(lambda: PASSES.__setitem__(
            slice(None), original))

        def marker_pass(scene, bag):
            scene.extensions["custom_marker"] = True
            return scene

        register_pass("X-test-marker", marker_pass)
        self.assertIn("X-test-marker", [name for name, _ in PASSES])

        result = optimize(scene_with(IRObject(name="box", prim="cube")),
                          [], level=1)
        self.assertTrue(result.extensions.get("custom_marker"))


if __name__ == "__main__":
    unittest.main()
