"""Parser tests for the Forge3D .f3d compiler (seat B33).

Stdlib unittest only, standalone-runnable:

    python3 tests/compiler/test_parser.py

Covers the real APIs in tools/f3dc: ``parser.parse(text, source_name)``
returning a ``Program`` whose ``errors`` attribute holds
``(code, message, line, col)`` tuples, the node classes in
``ast_nodes``, and ``desugar.desugar(program)`` for group/repeat
flattening and defaults injection.
"""

import os
import sys
import unittest

sys.path.insert(
    0,
    os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", "tools", "f3dc")
    ),
)

from ast_nodes import (  # noqa: E402
    AnimStmt,
    CameraStmt,
    GroupStmt,
    LightStmt,
    ObjectStmt,
    OutputStmt,
    SceneStmt,
)
from desugar import desugar  # noqa: E402
from parser import parse  # noqa: E402

PRIMITIVES = ("cube", "sphere", "cylinder", "plane", "pyramid", "cone", "torus")


def codes(program):
    """Error codes recorded on a parsed Program, in order."""
    return [entry[0] for entry in getattr(program, "errors", [])]


def objects(program):
    return [s for s in program.statements if isinstance(s, ObjectStmt)]


class TestParser(unittest.TestCase):
    def test_three_line_contract(self):
        # P03 section 9.2: the rotating-cube contract.
        prog = parse("cube red\nspin it\nrender\n", "contract.f3d")
        self.assertEqual(codes(prog), [])
        self.assertEqual(len(prog.statements), 3)
        obj, anim, out = prog.statements
        self.assertIsInstance(obj, ObjectStmt)
        self.assertEqual(obj.prim, "cube")
        self.assertEqual(obj.color_raw, "red")
        self.assertEqual(obj.props.get("colour"), "red")
        self.assertIsInstance(anim, AnimStmt)
        self.assertEqual(anim.kind, "spin")
        self.assertEqual(anim.target, "it")
        self.assertIsInstance(out, OutputStmt)
        self.assertEqual(out.kind, "render")

    def test_p03_example_9_3(self):
        prog = parse(
            "scene size 800 600 background black\n"
            "camera at 4 3 6 look 0 0 0\n"
            "cube hero blue at 1 0 0 size 3 rotate 0 45 0\n"
            'render to "hero.ppm"\n',
            "hero.f3d",
        )
        self.assertEqual(codes(prog), [])
        self.assertEqual(len(prog.statements), 4)
        scene, camera, hero, out = prog.statements
        self.assertIsInstance(scene, SceneStmt)
        self.assertEqual((scene.width, scene.height), (800, 600))
        self.assertEqual(scene.props.get("size"), (800, 600))
        self.assertEqual(scene.bg, "black")
        self.assertIsInstance(camera, CameraStmt)
        self.assertEqual(camera.props.get("at"), (4, 3, 6))
        self.assertEqual(camera.props.get("look"), (0, 0, 0))
        self.assertEqual(camera.target, (0, 0, 0))
        self.assertIsInstance(hero, ObjectStmt)
        self.assertEqual(hero.prim, "cube")
        self.assertEqual(hero.name, "hero")
        self.assertEqual(hero.color_raw, "blue")
        self.assertEqual(hero.props.get("at"), (1, 0, 0))
        self.assertEqual(hero.props.get("size"), 3)
        self.assertEqual(hero.props.get("rotate"), (0, 45, 0))
        self.assertIsInstance(out, OutputStmt)
        self.assertEqual(out.kind, "render")
        # The STRING path arrives quote-free.
        self.assertEqual(out.path, "hero.ppm")
        self.assertNotIn('"', out.path)

    def test_all_seven_primitives_parse(self):
        for prim in PRIMITIVES:
            with self.subTest(prim=prim):
                prog = parse("%s red\n" % prim, "prim.f3d")
                self.assertEqual(codes(prog), [])
                self.assertEqual(len(prog.statements), 1)
                stmt = prog.statements[0]
                self.assertIsInstance(stmt, ObjectStmt)
                self.assertEqual(stmt.prim, prim)
                self.assertEqual(stmt.color_raw, "red")

    def test_group_block_flattens_via_desugar_with_prefixed_names(self):
        prog = parse(
            "group duo at 10 0 0\n"
            "cube a red at 1 0 0\n"
            "sphere b blue\n"
            "end\n",
            "group.f3d",
        )
        self.assertEqual(codes(prog), [])
        self.assertEqual(len(prog.statements), 1)
        self.assertIsInstance(prog.statements[0], GroupStmt)
        flat = desugar(prog)
        self.assertFalse(
            any(isinstance(s, GroupStmt) for s in flat.statements)
        )
        objs = objects(flat)
        self.assertEqual([o.name for o in objs], ["duo.a", "duo.b"])
        # The group's `at` is composed into each child.
        self.assertEqual(objs[0].props.get("at"), (11, 0, 0))
        self.assertEqual(objs[1].props.get("at"), (10, 0, 0))

    def test_repeat_expansion_count_via_desugar(self):
        prog = parse("repeat 3 cube red\n", "repeat.f3d")
        self.assertEqual(codes(prog), [])
        objs = objects(desugar(prog))
        self.assertEqual(len(objs), 3)
        self.assertEqual([o.name for o in objs], ["cube1", "cube2", "cube3"])
        self.assertTrue(all(o.prim == "cube" for o in objs))

    def test_grid_expansion_count_via_desugar(self):
        prog = parse("grid 2 x 3 cube blue\n", "grid.f3d")
        self.assertEqual(codes(prog), [])
        objs = objects(desugar(prog))
        self.assertEqual(len(objs), 6)
        self.assertEqual(len({o.name for o in objs}), 6)
        self.assertTrue(all(o.prim == "cube" for o in objs))

    def test_ring_expansion_count_via_desugar(self):
        prog = parse("ring 4 sphere green\n", "ring.f3d")
        self.assertEqual(codes(prog), [])
        objs = objects(desugar(prog))
        self.assertEqual(len(objs), 4)
        self.assertEqual(
            [o.name for o in objs],
            ["sphere1", "sphere2", "sphere3", "sphere4"],
        )
        self.assertTrue(all(o.prim == "sphere" for o in objs))

    def test_defaults_injection_via_desugar(self):
        prog = parse("cube red\n", "defaults.f3d")
        self.assertEqual(codes(prog), [])
        flat = desugar(prog)
        kinds = [type(s) for s in flat.statements]
        self.assertIn(SceneStmt, kinds)
        self.assertIn(CameraStmt, kinds)
        self.assertIn(LightStmt, kinds)
        self.assertIn(OutputStmt, kinds)
        scene = next(s for s in flat.statements if isinstance(s, SceneStmt))
        self.assertEqual((scene.width, scene.height), (640, 480))
        camera = next(s for s in flat.statements if isinstance(s, CameraStmt))
        self.assertEqual(camera.pos, (3, 2.5, 4))
        self.assertEqual(camera.target, (0, 0, 0))
        objs = objects(flat)
        self.assertEqual(len(objs), 1)
        # A lone object gets the demo pose.
        self.assertEqual(objs[0].props.get("rotate"), (20, 35, 0))
        self.assertEqual(objs[0].props.get("at"), (0, 0, 0))

    def test_duplicate_prop_is_e110(self):
        prog = parse("cube red at 0 0 0 at 1 1 1\n", "dup.f3d")
        self.assertIn("E110", codes(prog))

    def test_unknown_statement_is_e104(self):
        prog = parse("frobnicate hello\n", "unknown.f3d")
        self.assertIn("E104", codes(prog))

    def test_nested_group_is_e401(self):
        prog = parse(
            "group outer\n"
            "group inner\n"
            "cube red\n"
            "end\n"
            "end\n",
            "nested.f3d",
        )
        self.assertIn("E401", codes(prog))

    def test_animate_it_spin_x_speed_45_form(self):
        # P03 section 9.5 block style: target, verb, bare axis, speed.
        prog = parse("animate it spin x speed 45\n", "anim.f3d")
        self.assertEqual(codes(prog), [])
        self.assertEqual(len(prog.statements), 1)
        anim = prog.statements[0]
        self.assertIsInstance(anim, AnimStmt)
        self.assertEqual(anim.kind, "spin")
        self.assertEqual(anim.target, "it")
        self.assertEqual(anim.props.get("axis"), "x")
        self.assertEqual(anim.props.get("speed"), 45)

    def test_rgb_parenthesised_colour_form(self):
        prog = parse("cube rgb(10,20,30)\n", "rgb.f3d")
        self.assertEqual(codes(prog), [])
        stmt = prog.statements[0]
        self.assertIsInstance(stmt, ObjectStmt)
        self.assertEqual(stmt.color_raw, "rgb(10,20,30)")
        self.assertEqual(stmt.props.get("colour"), (10, 20, 30))

    def test_rgb_spaced_colour_form(self):
        prog = parse("cube rgb 10 20 30\n", "rgb2.f3d")
        self.assertEqual(codes(prog), [])
        stmt = prog.statements[0]
        self.assertIsInstance(stmt, ObjectStmt)
        self.assertEqual(stmt.color_raw, "rgb(10,20,30)")
        self.assertEqual(stmt.props.get("colour"), (10, 20, 30))


if __name__ == "__main__":
    unittest.main()
