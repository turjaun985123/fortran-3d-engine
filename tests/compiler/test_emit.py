"""Forge3D seat B36: emitter tests (emit_fortran / emit_json / emit_js /
emit_html) against the frozen Typed IR.

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_emit.py

The IR under test is built the real way -- ``parser.parse`` +
``validate.validate`` -- from the 3-line contract of P03 section 3::

    cube red
    spin it
    render

which desugars to one red (220, 60, 60) cube auto-named ``cube1``,
a ``spin`` animation on it about ``y`` (speed 90, duration 5, fps 30,
so 150 frames), and the default render output.
"""

import json
import os
import shutil
import sys
import unittest

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        os.pardir,
        os.pardir,
        "tools",
        "f3dc",
    ),
)

import emit_fortran  # noqa: E402
import emit_html  # noqa: E402
import emit_js  # noqa: E402
import emit_json  # noqa: E402
import ir_nodes  # noqa: E402
import parser  # noqa: E402
import validate  # noqa: E402
from errors import ErrorBag  # noqa: E402

CONTRACT = "cube red\nspin it\nrender\n"
RUNTIME_STUB = "/*RT*/"


def _js_scene_payload(js_text):
    """Extract and JSON-parse the ``window.F3D_SCENE = {...};`` payload."""
    marker = "window.F3D_SCENE = "
    start = js_text.index(marker) + len(marker)
    end = js_text.index(";\n", start)
    return json.loads(js_text[start:end])


class TestEmit(unittest.TestCase):
    def setUp(self):
        bag = ErrorBag()
        program = parser.parse(CONTRACT, "contract.f3d", bag)
        self.assertIsNotNone(program)
        self.assertFalse(bag.has_errors(), bag.format_text())
        self.ir = validate.validate(program, bag)
        self.assertIsNotNone(self.ir)
        self.assertFalse(bag.has_errors(), bag.format_text())

    # -- sanity: the contract IR itself --------------------------------
    def test_contract_ir_shape(self):
        self.assertEqual(len(self.ir.objects), 1)
        obj = self.ir.objects[0]
        self.assertEqual((obj.name, obj.prim, obj.material),
                         ("cube1", "cube", "lambert"))
        self.assertEqual(tuple(obj.color), (220, 60, 60))
        self.assertEqual(len(self.ir.animations), 1)
        anim = self.ir.animations[0]
        self.assertEqual((anim.kind, anim.target, anim.axis),
                         ("spin", "cube1", "y"))

    # -- emit_fortran.emit_scene_text ----------------------------------
    def test_scene_text_header_and_object(self):
        text = emit_fortran.emit_scene_text(self.ir)
        self.assertTrue(text.startswith("forge3d-scene 1\n"))
        self.assertIn("forge3d-scene 1", text)
        self.assertIn("object cube cube1 lambert 220 60 60", text)

    def test_scene_text_anim_and_frames(self):
        text = emit_fortran.emit_scene_text(self.ir)
        self.assertIn("anim spin cube1 y", text)
        # duration 5 s * fps 30 = 150 frames.
        self.assertIn("frames 150", text.splitlines())

    # -- emit_json.emit_json_v2 ----------------------------------------
    def test_json_v2_parses_with_format_and_version(self):
        data = json.loads(emit_json.emit_json_v2(self.ir))
        self.assertEqual(data["format"], "forge3d-scene")
        self.assertEqual(data["format"], emit_json.FORMAT_NAME)
        self.assertEqual(data["version"], 2)
        self.assertEqual(data["version"], emit_json.FORMAT_VERSION)
        self.assertEqual(data["objects"][0]["name"], "cube1")
        self.assertEqual(data["objects"][0]["color"], [220, 60, 60])
        self.assertEqual(data["animations"][0]["kind"], "spin")

    def test_json_v2_round_trip_via_from_json(self):
        text = emit_json.emit_json_v2(self.ir)
        parsed = json.loads(text)
        rebuilt = ir_nodes.from_json(text)
        stamped = dict(parsed)
        original = {k: v for k, v in stamped.items()
                    if k not in ("format", "version")}
        # Round-tripped IR serialises back to the original dict content.
        self.assertEqual(ir_nodes.to_dict(rebuilt), original)
        self.assertEqual(ir_nodes.to_dict(rebuilt),
                         ir_nodes.to_dict(self.ir))

    # -- emit_json.emit_json_legacy ------------------------------------
    def test_json_legacy_twelve_triangles_with_palette_colours(self):
        data = json.loads(emit_json.emit_json_legacy(self.ir))
        triangles = data["triangles"]
        self.assertEqual(len(triangles), 12)
        self.assertEqual([t["id"] for t in triangles],
                         list(range(1, 13)))
        palette = [list(c) for c in ir_nodes.PALETTE_FACES]
        for tri in triangles:
            # Every colour is a palette colour; a single-colour cube
            # uses its own colour (palette red, 220 60 60) on all faces.
            self.assertIn(tri["color"], palette)
            self.assertEqual(tri["color"], [220, 60, 60])
            self.assertEqual(len(tri["v"]), 3)
            for vertex in tri["v"]:
                self.assertEqual(len(vertex), 3)
                for coord in vertex:
                    self.assertIsInstance(coord, (int, float))

    # -- emit_js.emit_js ------------------------------------------------
    def test_js_contains_window_scene(self):
        js = emit_js.emit_js(self.ir)
        self.assertIn("window.F3D_SCENE", js)

    def test_js_payload_parses_equal_to_v2(self):
        js = emit_js.emit_js(self.ir)
        self.assertEqual(_js_scene_payload(js),
                         json.loads(emit_json.emit_json_v2(self.ir)))

    # -- emit_html.emit_html -------------------------------------------
    def test_html_inlines_runtime_and_scene_no_placeholders(self):
        doc = emit_html.emit_html(self.ir, runtime_js=RUNTIME_STUB)
        self.assertIn(RUNTIME_STUB, doc)
        self.assertIn("window.F3D_SCENE", doc)
        self.assertEqual(
            _js_scene_payload(doc),
            json.loads(emit_json.emit_json_v2(self.ir)),
        )
        self.assertNotIn("{{", doc)

    # -- determinism ----------------------------------------------------
    def test_determinism_all_emitters(self):
        emitters = [
            ("scene_text", lambda: emit_fortran.emit_scene_text(self.ir)),
            ("fortran_program",
             lambda: emit_fortran.emit_fortran_program(self.ir)),
            ("json_v2", lambda: emit_json.emit_json_v2(self.ir)),
            ("json_legacy", lambda: emit_json.emit_json_legacy(self.ir)),
            ("js", lambda: emit_js.emit_js(self.ir)),
            ("html", lambda: emit_html.emit_html(
                self.ir, runtime_js=RUNTIME_STUB)),
        ]
        for name, emit in emitters:
            with self.subTest(emitter=name):
                self.assertEqual(emit(), emit())

    # -- emit_fortran.emit_fortran_program ------------------------------
    def test_fortran_program_key_substrings(self):
        prog = emit_fortran.emit_fortran_program(self.ir)
        self.assertIn("program", prog)
        self.assertIn("end program", prog)
        self.assertIn("create_cube", prog)
        # Syntax-check: SKIP LOUDLY.  A real `gfortran -fsyntax-only`
        # check needs every src/*.f90 module compiled first (module
        # dependency order, .mod files in a temp dir), which is too
        # heavy / brittle for this emitter unit suite, so it is not
        # attempted here; the substring contract above is asserted
        # instead, whether or not gfortran happens to be installed.
        sys.stderr.write(
            "\n*** SKIP: gfortran -fsyntax-only check for the generated "
            "program NOT RUN in test_emit.py (gfortran %s): compiling "
            "the src modules it `use`s is too heavy for this suite; "
            "key substrings asserted instead. ***\n"
            % ("found at " + shutil.which("gfortran")
               if shutil.which("gfortran") else "not available")
        )


if __name__ == "__main__":
    unittest.main()
