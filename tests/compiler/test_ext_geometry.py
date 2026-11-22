#!/usr/bin/env python3
"""Tests for the Forge3D Wave D geometry extension (seat D08).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_geometry.py
    python3 -m unittest tests.compiler.test_ext_geometry

Covers the ten Wave D primitives (circle, ring, capsule, tube,
lathe, extrude, icosahedron, octahedron, tetrahedron, dodecahedron,
torusknot): parse + validate + the frozen 20-token ``.scene``
object line (SIZE / RADIUS / HEIGHT / SEGMENTS at tokens 17-20,
point lists appended as tokens 21+), the exact triangle-estimate
formulas, the direct Fortran ``create_*`` calls, the defaults, and
the friendly error cases. Fortran geometry math is out of scope
here by design (it lives in the geo_*_3d modules).
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

import emit_fortran  # noqa: E402
import ext_geometry  # noqa: E402
import parser  # noqa: E402
import validate  # noqa: E402
from errors import ErrorBag  # noqa: E402


def compile_src(src):
    """Parse + validate *src*; return (ir_or_None, bag)."""
    bag = ErrorBag()
    prog = parser.parse(src, "test.f3d", bag)
    if bag.has_errors():
        return None, bag
    return validate.validate(prog, bag), bag


def error_codes(bag):
    return [d.code for d in bag.diagnostics if d.severity == "error"]


def object_lines(ir):
    return [line.split() for line in
            emit_fortran.emit_scene_text(ir).splitlines()
            if line.startswith("object ")]


def object_line(ir, prim):
    for tokens in object_lines(ir):
        if tokens[1] == prim:
            return tokens
    raise AssertionError("no object line for %s" % prim)


# Token positions (0-based) of the frozen 20-token object line:
# object PRIM NAME MATERIAL CR CG CB px py pz rx ry rz sx sy sz
# SIZE RADIUS HEIGHT SEGMENTS [extras...]
SIZE, RADIUS, HEIGHT, SEGMENTS, EXTRA = 16, 17, 18, 19, 20


class TestParseValidateScene(unittest.TestCase):
    def test_circle_defaults(self):
        ir, bag = compile_src("circle red\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "circle")
        self.assertEqual(len(toks), 20)
        self.assertEqual(toks[RADIUS], "1")
        self.assertEqual(toks[SEGMENTS], "32")
        self.assertEqual(toks[SIZE], "-1")
        self.assertEqual(toks[HEIGHT], "-1")

    def test_circle_explicit_and_generic_props(self):
        ir, bag = compile_src(
            "circle disc orange radius 2 segments 8 "
            "at 1 2 3 rotate 0 90 0\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "circle")
        self.assertEqual(toks[2], "disc")            # positional name
        self.assertEqual(toks[RADIUS], "2")
        self.assertEqual(toks[SEGMENTS], "8")
        self.assertEqual(toks[7:10], ["1", "2", "3"])     # at
        self.assertEqual(toks[10:13], ["0", "90", "0"])   # rotate
        obj = ir.objects[0]
        self.assertEqual(obj.color, (240, 140, 40))       # orange

    def test_ring_defaults_and_spellings(self):
        ir, bag = compile_src("ring blue\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "ring")
        self.assertEqual(toks[RADIUS], "1")     # outer via radius
        self.assertEqual(toks[SIZE], "0.5")     # inner in SIZE
        self.assertEqual(toks[SEGMENTS], "32")
        ir, bag = compile_src("ring green outer 3 inner 0.25\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "ring")
        self.assertEqual(toks[RADIUS], "3")     # outer via `outer`
        self.assertEqual(toks[SIZE], "0.25")
        ir, bag = compile_src("ring green radius 2 inner 0.25\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "ring")
        self.assertEqual(toks[RADIUS], "2")
        self.assertEqual(toks[SIZE], "0.25")

    def test_ring_repeat_form_still_works(self):
        # `ring <count> <prim> ...` is the pre-existing repeat
        # statement, not the ring primitive.
        ir, bag = compile_src("ring 4 sphere green\n")
        self.assertIsNotNone(ir, bag.format_text())
        self.assertEqual([o.prim for o in ir.objects],
                         ["sphere"] * 4)

    def test_capsule_defaults_and_explicit(self):
        ir, bag = compile_src("capsule yellow\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "capsule")
        self.assertEqual(toks[RADIUS], "0.5")
        self.assertEqual(toks[HEIGHT], "2")
        self.assertEqual(toks[SEGMENTS], "16")
        ir, bag = compile_src("capsule red radius 1 height 3 "
                              "segments 20\n")
        toks = object_line(ir, "capsule")
        self.assertEqual((toks[RADIUS], toks[HEIGHT], toks[SEGMENTS]),
                         ("1", "3", "20"))

    def test_tube_defaults_and_path_tokens(self):
        ir, bag = compile_src(
            "tube green path 0,0,0 1,1,0 2,0,0\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "tube")
        self.assertEqual(toks[RADIUS], "0.2")
        self.assertEqual(toks[SEGMENTS], "12")
        self.assertEqual(toks[EXTRA:],
                         ["0", "0", "0", "1", "1", "0", "2", "0", "0"])
        geom = ir.objects[0].extensions["geometry"]
        self.assertEqual(geom["path"],
                         [(0, 0, 0), (1, 1, 0), (2, 0, 0)])

    def test_lathe_defaults_and_point_tokens(self):
        ir, bag = compile_src(
            "lathe orange points 0,0 0.6,0.2 0.6,1 0,1.2\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "lathe")
        self.assertEqual(toks[SEGMENTS], "24")
        self.assertEqual(toks[EXTRA:],
                         ["0", "0", "0.6", "0.2", "0.6", "1", "0",
                          "1.2"])

    def test_extrude_defaults_and_shape_tokens(self):
        ir, bag = compile_src(
            "extrude magenta shape 0,0 1,0 1,1 0,1\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "extrude")
        # `depth` was already a generic prop, so the spelling is
        # `extrude_depth`; its value rides in HEIGHT (token 19).
        self.assertEqual(toks[HEIGHT], "0.5")
        self.assertEqual(toks[EXTRA:],
                         ["0", "0", "1", "0", "1", "1", "0", "1"])
        ir, bag = compile_src(
            "extrude magenta shape 0,0 1,0 0,1 extrude_depth 0.75\n")
        self.assertIsNotNone(ir, bag.format_text())
        self.assertEqual(object_line(ir, "extrude")[HEIGHT], "0.75")

    def test_polyhedra_defaults(self):
        for prim in ("icosahedron", "octahedron", "tetrahedron",
                     "dodecahedron"):
            ir, bag = compile_src("%s cyan radius 2\n" % prim)
            self.assertIsNotNone(ir, bag.format_text())
            toks = object_line(ir, prim)
            self.assertEqual(toks[RADIUS], "2")
            self.assertEqual(toks[SEGMENTS], "0")
            ir, bag = compile_src("%s cyan\n" % prim)
            self.assertEqual(object_line(ir, prim)[RADIUS], "1")

    def test_torusknot_defaults_and_explicit(self):
        ir, bag = compile_src("torusknot white\n")
        self.assertIsNotNone(ir, bag.format_text())
        toks = object_line(ir, "torusknot")
        self.assertEqual(toks[RADIUS], "1")
        self.assertEqual(toks[SIZE], "0.3")     # tube = radius * 0.3
        self.assertEqual(toks[SEGMENTS], "48")
        ir, bag = compile_src(
            "torusknot white radius 2 tube 0.4 tube_segments 10\n")
        toks = object_line(ir, "torusknot")
        self.assertEqual((toks[RADIUS], toks[SIZE]), ("2", "0.4"))
        geom = ir.objects[0].extensions["geometry"]
        self.assertEqual(geom["tube_segments"], 10)

    def test_all_ten_in_one_scene(self):
        ir, bag = compile_src(
            "circle red\nring blue\ncapsule yellow\n"
            "tube green path 0,0,0 1,0,0\n"
            "lathe orange points 0,0 0.5,1\n"
            "extrude magenta shape 0,0 1,0 0,1\n"
            "icosahedron cyan\noctahedron white\n"
            "tetrahedron black\ndodecahedron purple\n"
            "torusknot pink\n")
        self.assertIsNotNone(ir, bag.format_text())
        self.assertEqual(
            [o.prim for o in ir.objects],
            ["circle", "ring", "capsule", "tube", "lathe", "extrude",
             "icosahedron", "octahedron", "tetrahedron",
             "dodecahedron", "torusknot"])


class TestTriangleEstimates(unittest.TestCase):
    def est(self, prim, props):
        return validate._estimate_triangles(prim, props)

    def test_circle_and_ring(self):
        self.assertEqual(self.est("circle", {}), 2 * 32)
        self.assertEqual(self.est("circle", {"segments": 10}), 20)
        self.assertEqual(self.est("ring", {}), 4 * 32)
        self.assertEqual(self.est("ring", {"segments": 10}), 40)

    def test_capsule_segment_rounding(self):
        # seg rounded up to a multiple of 4; hr = seg/4;
        # tris = 2*seg + 2*seg*(2*hr - 1).
        self.assertEqual(self.est("capsule", {}), 256)          # 16
        self.assertEqual(self.est("capsule", {"segments": 16}), 256)
        self.assertEqual(self.est("capsule", {"segments": 17}), 400)
        self.assertEqual(self.est("capsule", {"segments": 18}), 400)
        self.assertEqual(self.est("capsule", {"segments": 20}), 400)

    def test_tube(self):
        path3 = [(0, 0, 0), (1, 1, 0), (2, 0, 0)]
        self.assertEqual(
            self.est("tube", {"path": path3, "segments": 12}),
            (3 - 1) * 12 * 2 + 2 * 12)
        self.assertEqual(self.est("tube", {"path": path3[:2]}),
                         (2 - 1) * 12 * 2 + 2 * 12)

    def test_lathe(self):
        pts4 = [(0, 0), (0.6, 0.2), (0.6, 1), (0, 1.2)]
        self.assertEqual(
            self.est("lathe", {"points": pts4, "segments": 24}),
            (4 - 1) * 24 * 2)
        self.assertEqual(self.est("lathe", {"points": pts4}),
                         (4 - 1) * 24 * 2)

    def test_extrude(self):
        self.assertEqual(
            self.est("extrude", {"shape": [(0, 0), (1, 0), (0, 1)]}),
            4 * 3 - 4)
        self.assertEqual(
            self.est("extrude",
                     {"shape": [(0, 0), (1, 0), (1, 1), (0, 1)]}),
            4 * 4 - 4)

    def test_polyhedra(self):
        self.assertEqual(self.est("tetrahedron", {}), 4)
        self.assertEqual(self.est("octahedron", {}), 8)
        self.assertEqual(self.est("icosahedron", {}), 20)
        self.assertEqual(self.est("dodecahedron", {}), 36)

    def test_torusknot(self):
        # default tube_segments = max(6, 48 // 4) = 12
        self.assertEqual(self.est("torusknot", {}), 48 * 12 * 2)
        self.assertEqual(
            self.est("torusknot",
                     {"segments": 10, "tube_segments": 5}),
            10 * 5 * 2)
        self.assertEqual(
            ext_geometry.estimate_triangles("torusknot", {}),
            48 * 12 * 2)


class TestFortranDirectPath(unittest.TestCase):
    def program(self, src):
        ir, bag = compile_src(src)
        self.assertIsNotNone(ir, bag.format_text())
        return emit_fortran.emit_fortran_program(ir)

    def test_create_calls(self):
        prog = self.program(
            "circle red\nring blue radius 2 inner 0.25\n"
            "capsule yellow\n"
            "tube green path 0,0,0 1,1,0 2,0,0\n"
            "lathe orange points 0,0 0.6,0.2 0.6,1 0,1.2\n"
            "extrude magenta shape 0,0 1,0 1,1 0,1\n"
            "tetrahedron cyan\noctahedron white\n"
            "icosahedron black\ndodecahedron purple\n"
            "torusknot pink\n")
        for call in (
                "call create_circle(msh, 1.0_dp, 32)",
                "call create_ring(msh, 2.0_dp, 0.25_dp, 32)",
                "call create_capsule(msh, 0.5_dp, 2.0_dp, 16)",
                "call create_tube(msh, 0.2_dp, 12, "
                "[0.0_dp, 0.0_dp, 0.0_dp, 1.0_dp, 1.0_dp, 0.0_dp, "
                "2.0_dp, 0.0_dp, 0.0_dp], 3)",
                "call create_lathe(msh, 24, "
                "[0.0_dp, 0.0_dp, 0.6_dp, 0.2_dp, 0.6_dp, 1.0_dp, "
                "0.0_dp, 1.2_dp], 4)",
                "call create_extrude(msh, 0.5_dp, "
                "[0.0_dp, 0.0_dp, 1.0_dp, 0.0_dp, 1.0_dp, 1.0_dp, "
                "0.0_dp, 1.0_dp], 4)",
                "call create_tetrahedron(msh, 1.0_dp)",
                "call create_octahedron(msh, 1.0_dp)",
                "call create_icosahedron(msh, 1.0_dp)",
                "call create_dodecahedron(msh, 1.0_dp)",
                "call create_torusknot(msh, 1.0_dp, 0.3_dp, 48, 12)",
        ):
            self.assertIn(call, prog)

    def test_use_modules(self):
        prog = self.program(
            "circle red\ncapsule red\n"
            "tube red path 0,0,0 1,0,0\n"
            "lathe red points 0,0 0.5,1\n"
            "extrude red shape 0,0 1,0 0,1\n"
            "icosahedron red\ntorusknot red\n")
        for mod in ("geo_flat_3d", "geo_capsule_3d", "geo_tube_3d",
                    "geo_lathe_3d", "geo_extrude_3d", "geo_poly_3d",
                    "geo_torusknot_3d"):
            self.assertIn("use %s" % mod, prog)

    def test_no_geo_modules_for_v1_scene(self):
        prog = self.program("cube red\ntorus blue\n")
        self.assertNotIn("geo_", prog)
        self.assertIn("call create_torus", prog)


class TestErrors(unittest.TestCase):
    def check(self, src, code):
        ir, bag = compile_src(src)
        self.assertIsNone(ir)
        self.assertIn(code, error_codes(bag), bag.format_text())
        return bag

    def test_tube_too_few_path_points(self):
        self.check("tube red path 0,0,0\n", "E301")
        self.check("tube red\n", "E301")

    def test_lathe_too_few_points(self):
        self.check("lathe red points 0,0\n", "E301")
        self.check("lathe red\n", "E301")

    def test_extrude_too_few_shape_points(self):
        self.check("extrude red shape 0,0 1,0\n", "E301")
        self.check("extrude red\n", "E301")

    def test_lathe_negative_radius(self):
        bag = self.check("lathe red points -0.5,0 0.5,1\n", "E301")
        self.assertIn("negative radius", bag.format_text())

    def test_unknown_geometry_prop(self):
        # A real geometry prop, but not one this primitive takes:
        # validate reports it in the E301 bad-dimension style.
        bag = self.check("circle red tube 2\n", "E301")
        self.assertIn("'tube' is not a circle property",
                      bag.format_text())
        # A word the parser does not know at all: existing E103.
        self.check("circle red radius 1 wibble 2\n", "E103")

    def test_malformed_path_grouping(self):
        self.check("tube red path 0,0 1,1,0\n", "E102")

    def test_ring_inner_must_be_smaller_than_outer(self):
        self.check("ring red radius 1 inner 2\n", "E301")


if __name__ == "__main__":
    unittest.main()
