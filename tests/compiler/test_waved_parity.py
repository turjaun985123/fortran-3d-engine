#!/usr/bin/env python3
"""Wave D compiler parity tests (seat D11, MASTER-PLAN row 7).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_waved_parity.py
    python3 -m unittest tests.compiler.test_waved_parity

Mirrors the Wave C parity harness (``test_wavec_parity.py``): the
compile tests drive the real pipeline -- ``parser.parse`` ->
``validate.validate`` -> ``emit_fortran.emit_scene_text`` -- for each
of the eleven Wave D primitives (circle, ring, capsule, tube, lathe,
extrude, tetrahedron, octahedron, icosahedron, dodecahedron,
torusknot) and prove, per primitive:

  (a) the emitted ``.scene`` object line carries the right prim and
      the right dims mapping on the frozen 20-token line
      (SIZE / RADIUS / HEIGHT / SEGMENTS at tokens 17-20, 1-based):
      ring SIZE=inner / RADIUS=outer, torusknot SIZE=tube,
      extrude HEIGHT=depth (canonical prop ``extrude_depth``, the
      plain ``depth`` alias honoured), and the tube path triples /
      lathe + extrude point pairs appended as tokens 21+;
  (b) the validate triangle estimate for the compiled object equals
      the exact Fortran formula for that primitive (the formulas the
      ``geo_*_3d`` builders in ``src/geo_*.f90`` implement, owned on
      the compiler side by ``ext_geometry.estimate_triangles``);
  (c) the ring-repeat regression: ``ring 4 sphere`` still expands as
      the pre-existing repeat statement, while
      ``ring inner 0.5 outer 1`` is the ring primitive.

Token indices below are 0-based on the whitespace-split object line,
exactly as in ``tests/compiler/test_ext_geometry.py``.
"""

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "f3dc"))

import emit_fortran  # noqa: E402
import ext_geometry  # noqa: E402
import parser  # noqa: E402
import validate  # noqa: E402
from errors import ErrorBag  # noqa: E402

# object PRIM NAME MATERIAL CR CG CB px py pz rx ry rz sx sy sz
# SIZE RADIUS HEIGHT SEGMENTS [extras...]
SIZE, RADIUS, HEIGHT, SEGMENTS, EXTRA = 16, 17, 18, 19, 20


def run(source, base_dir="."):
    """Parse + validate ``source``; return (ir_scene_or_None, error_codes)."""
    bag = ErrorBag()
    program = parser.parse(source, "test.f3d", bag)
    scene = validate.validate(program, bag, base_dir=base_dir)
    codes = [d.code for d in bag.diagnostics if d.severity == "error"]
    return scene, codes


def compile_one(source):
    """Compile a 1-object source; return (ir_object, object_line_tokens)."""
    scene, codes = run(source)
    if codes or scene is None:
        raise AssertionError("expected a clean compile, got errors %r"
                             % (codes,))
    if len(scene.objects) != 1:
        raise AssertionError("expected exactly 1 object, got %d"
                             % len(scene.objects))
    lines = [ln.split() for ln in
             emit_fortran.emit_scene_text(scene).splitlines()
             if ln.startswith("object ")]
    if len(lines) != 1:
        raise AssertionError("expected exactly 1 object line, got %r"
                             % (lines,))
    return scene.objects[0], lines[0]


def tri_estimate(obj):
    """The validate triangle estimate for one compiled IR object.

    The props are the object's normalised geometry payload (the same
    dict ``validate`` folds into its E820 estimate), so this is the
    compiler's own estimate for the object as compiled, checked here
    against the closed-form Fortran formula per primitive.  The
    ``ext_geometry`` entry point (which ``validate`` delegates to for
    the Wave D prims) must agree exactly.
    """
    geom = obj.extensions["geometry"]
    via_validate = validate._estimate_triangles(obj.prim, geom)
    via_ext = ext_geometry.estimate_triangles(obj.prim, geom)
    if via_validate != via_ext:
        raise AssertionError("validate estimate %r != ext_geometry "
                             "estimate %r for %s"
                             % (via_validate, via_ext, obj.prim))
    return via_validate


class TestRow07Geometries(unittest.TestCase):
    # -- circle ------------------------------------------------------

    def test_circle_scene_line_and_tri_estimate(self):
        obj, toks = compile_one("circle red radius 2 segments 12\n")
        self.assertEqual(toks[1], "circle")
        self.assertEqual(len(toks), 20)
        self.assertEqual(toks[SIZE], "-1")
        self.assertEqual(toks[RADIUS], "2")
        self.assertEqual(toks[HEIGHT], "-1")
        self.assertEqual(toks[SEGMENTS], "12")
        # Fortran create_circle: 2 * segments.
        self.assertEqual(tri_estimate(obj), 2 * 12)

    # -- ring (primitive) ---------------------------------------------

    def test_ring_scene_line_and_tri_estimate(self):
        obj, toks = compile_one(
            "ring red inner 0.5 outer 1 segments 12\n")
        self.assertEqual(toks[1], "ring")
        self.assertEqual(len(toks), 20)
        # SIZE = inner, RADIUS = outer.
        self.assertEqual(toks[SIZE], "0.5")
        self.assertEqual(toks[RADIUS], "1")
        self.assertEqual(toks[HEIGHT], "-1")
        self.assertEqual(toks[SEGMENTS], "12")
        # Fortran create_ring: 4 * segments.
        self.assertEqual(tri_estimate(obj), 4 * 12)

    # -- capsule -------------------------------------------------------

    def test_capsule_scene_line_and_tri_estimate(self):
        obj, toks = compile_one(
            "capsule yellow radius 0.75 height 3 segments 17\n")
        self.assertEqual(toks[1], "capsule")
        self.assertEqual(len(toks), 20)
        self.assertEqual(toks[RADIUS], "0.75")
        self.assertEqual(toks[HEIGHT], "3")
        self.assertEqual(toks[SEGMENTS], "17")
        # Fortran create_capsule: segments rounded UP to a multiple
        # of 4 (17 -> 20), hr = 20/4 = 5, tris = 2s + 2s(2hr - 1).
        seg, hr = 20, 5
        self.assertEqual(tri_estimate(obj), 2 * seg + 2 * seg * (2 * hr - 1))
        self.assertEqual(tri_estimate(obj), 400)

    # -- tube ----------------------------------------------------------

    def test_tube_scene_line_path_tokens_and_tri_estimate(self):
        obj, toks = compile_one(
            "tube green radius 0.4 segments 10 "
            "path 0,0,0 1,1,0 2,0,0\n")
        self.assertEqual(toks[1], "tube")
        self.assertEqual(toks[RADIUS], "0.4")
        self.assertEqual(toks[SEGMENTS], "10")
        # Path triples appended as tokens 21+, in source order.
        self.assertEqual(toks[EXTRA:],
                         ["0", "0", "0", "1", "1", "0", "2", "0", "0"])
        # Fortran create_tube: (n-1)*2s side + 2s end caps, n = 3.
        self.assertEqual(tri_estimate(obj), (3 - 1) * 2 * 10 + 2 * 10)

    # -- lathe ---------------------------------------------------------

    def test_lathe_scene_line_point_tokens_and_tri_estimate(self):
        obj, toks = compile_one(
            "lathe orange segments 20 "
            "points 0,0 0.6,0.2 0.6,1 0,1.2\n")
        self.assertEqual(toks[1], "lathe")
        self.assertEqual(toks[SEGMENTS], "20")
        # Profile pairs appended as tokens 21+, in source order.
        self.assertEqual(toks[EXTRA:],
                         ["0", "0", "0.6", "0.2", "0.6", "1", "0", "1.2"])
        # Fortran create_lathe: (n-1)*2s, n = 4.
        self.assertEqual(tri_estimate(obj), (4 - 1) * 2 * 20)

    # -- extrude ---------------------------------------------------------

    def test_extrude_scene_line_shape_tokens_and_tri_estimate(self):
        obj, toks = compile_one(
            "extrude blue shape 0,0 1,0 1,1 0,1 extrude_depth 0.75\n")
        self.assertEqual(toks[1], "extrude")
        # HEIGHT = depth (canonical prop `extrude_depth`).
        self.assertEqual(toks[HEIGHT], "0.75")
        # Shape pairs appended as tokens 21+, in source order.
        self.assertEqual(toks[EXTRA:],
                         ["0", "0", "1", "0", "1", "1", "0", "1"])
        # Fortran create_extrude: 4n - 4, n = 4.
        self.assertEqual(tri_estimate(obj), 4 * 4 - 4)

    def test_extrude_depth_alias_is_honoured(self):
        obj, toks = compile_one(
            "extrude blue shape 0,0 1,0 0,1 depth 0.9\n")
        self.assertEqual(toks[1], "extrude")
        self.assertEqual(toks[HEIGHT], "0.9")
        self.assertEqual(toks[EXTRA:], ["0", "0", "1", "0", "0", "1"])
        self.assertEqual(tri_estimate(obj), 4 * 3 - 4)

    # -- Platonic solids -------------------------------------------------

    def _poly(self, prim, expected_tris):
        obj, toks = compile_one("%s cyan radius 2\n" % prim)
        self.assertEqual(toks[1], prim)
        self.assertEqual(len(toks), 20)
        self.assertEqual(toks[RADIUS], "2")
        self.assertEqual(toks[SEGMENTS], "0")
        self.assertEqual(tri_estimate(obj), expected_tris)

    def test_tetrahedron_scene_line_and_tri_estimate(self):
        self._poly("tetrahedron", 4)

    def test_octahedron_scene_line_and_tri_estimate(self):
        self._poly("octahedron", 8)

    def test_icosahedron_scene_line_and_tri_estimate(self):
        self._poly("icosahedron", 20)

    def test_dodecahedron_scene_line_and_tri_estimate(self):
        self._poly("dodecahedron", 36)

    # -- torusknot -------------------------------------------------------

    def test_torusknot_scene_line_and_tri_estimate(self):
        obj, toks = compile_one(
            "torusknot white radius 2 tube 0.4 segments 20 "
            "tube_segments 10\n")
        self.assertEqual(toks[1], "torusknot")
        self.assertEqual(len(toks), 20)
        self.assertEqual(toks[RADIUS], "2")
        # SIZE = tube radius.
        self.assertEqual(toks[SIZE], "0.4")
        self.assertEqual(toks[SEGMENTS], "20")
        # Fortran create_torusknot: segments * tube_segments * 2.
        self.assertEqual(tri_estimate(obj), 20 * 10 * 2)

    def test_torusknot_defaults_tri_estimate(self):
        obj, toks = compile_one("torusknot white\n")
        self.assertEqual(toks[RADIUS], "1")
        self.assertEqual(toks[SIZE], "0.3")  # tube = radius * 0.3
        self.assertEqual(toks[SEGMENTS], "48")
        # Default tube_segments = max(6, 48 // 4) = 12.
        self.assertEqual(tri_estimate(obj), 48 * 12 * 2)

    # -- (c) ring-repeat regression ---------------------------------------

    def test_ring_repeat_form_still_expands_as_repeat(self):
        scene, codes = run("ring 4 sphere green\n")
        self.assertEqual(codes, [])
        self.assertIsNotNone(scene)
        self.assertEqual([o.prim for o in scene.objects],
                         ["sphere"] * 4)
        lines = [ln.split() for ln in
                 emit_fortran.emit_scene_text(scene).splitlines()
                 if ln.startswith("object ")]
        self.assertEqual(len(lines), 4)
        self.assertTrue(all(ln[1] == "sphere" for ln in lines))

    def test_ring_with_inner_outer_is_the_primitive(self):
        scene, codes = run("ring inner 0.5 outer 1 red\n")
        self.assertEqual(codes, [])
        self.assertIsNotNone(scene)
        self.assertEqual([o.prim for o in scene.objects], ["ring"])
        lines = [ln.split() for ln in
                 emit_fortran.emit_scene_text(scene).splitlines()
                 if ln.startswith("object ")]
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0][SIZE], "0.5")   # inner
        self.assertEqual(lines[0][RADIUS], "1")   # outer


if __name__ == "__main__":
    unittest.main(verbosity=2)
