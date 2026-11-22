"""Tests for Forge3D diagnostics (tools/f3dc/errors.py) and CLI check.

Stdlib unittest only; standalone-runnable:

    python3 tests/compiler/test_errors.py
"""

import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "f3dc"))

import cli  # noqa: E402
from errors import Diagnostic, ErrorBag, ForgeError, Span, did_you_mean  # noqa: E402


def make_diag(code="E202", severity="error", message="unknown colour 'gold'",
              why="colours must be known to the renderer",
              help="use a named colour, #rrggbb, or rgb(r,g,b)"):
    return Diagnostic(
        code=code, severity=severity, message=message,
        span=Span("scene.f3d", 3, 6), why=why, help=help,
    )


def run_cli_check(content):
    """Run ``cli.main(['check', file])`` on *content*; return (code, text)."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "scene.f3d"
        path.write_text(content, encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["check", str(path)])
    return code, out.getvalue() + err.getvalue()


class TestDiagnosticFormatting(unittest.TestCase):
    def test_format_text_has_location_code_why_and_help(self):
        bag = ErrorBag([make_diag()])
        text = bag.format_text()
        self.assertIn("scene.f3d:3:6", text)
        self.assertIn("E202", text)
        self.assertIn("unknown colour 'gold'", text)
        self.assertIn("why:", text)
        self.assertIn("colours must be known to the renderer", text)
        self.assertIn("help:", text)
        self.assertIn("use a named colour", text)

    def test_format_json_parses_and_contains_code_and_severity(self):
        bag = ErrorBag([make_diag(),
                        make_diag(code="W101", severity="warning",
                                  message="default injected")])
        records = json.loads(bag.format_json())
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["code"], "E202")
        self.assertEqual(records[0]["severity"], "error")
        self.assertEqual(records[1]["code"], "W101")
        self.assertEqual(records[1]["severity"], "warning")
        for record in records:
            self.assertIn("code", record)
            self.assertIn("severity", record)


class TestDidYouMean(unittest.TestCase):
    CANDIDATES = ["camera", "cube", "sphere", "green", "red", "blue", "scene"]

    def test_transposed_letters_suggest_camera(self):
        self.assertEqual(did_you_mean("camrea", self.CANDIDATES), "camera")

    def test_missing_letter_suggests_green(self):
        self.assertEqual(
            did_you_mean("gren", ["red", "green", "blue", "grey"]), "green")

    def test_gibberish_suggests_nothing(self):
        self.assertIsNone(did_you_mean("zxqwkj", self.CANDIDATES))


class TestErrorBag(unittest.TestCase):
    def test_errors_and_warnings_filtering(self):
        bag = ErrorBag()
        bag.add(make_diag(code="E202", severity="error"))
        bag.add(make_diag(code="W101", severity="warning",
                          message="default injected"))
        bag.add(make_diag(code="E301", severity="error",
                          message="value out of range"))
        self.assertEqual([d.code for d in bag.errors()], ["E202", "E301"])
        self.assertEqual([d.code for d in bag.warnings()], ["W101"])
        self.assertTrue(bag.has_errors())
        self.assertEqual(len(bag.diagnostics), 3)

    def test_raise_if_errors_raises_forge_error_carrying_bag(self):
        bag = ErrorBag([make_diag()])
        with self.assertRaises(ForgeError) as ctx:
            bag.raise_if_errors()
        self.assertIs(ctx.exception.bag, bag)
        self.assertEqual(ctx.exception.bag.errors()[0].code, "E202")

    def test_raise_if_errors_passes_with_only_warnings(self):
        bag = ErrorBag([make_diag(code="W101", severity="warning",
                                  message="default injected")])
        bag.raise_if_errors()  # must not raise
        self.assertFalse(bag.has_errors())


class TestCliCheck(unittest.TestCase):
    def test_unknown_colour_gold_exits_1_with_e202(self):
        code, text = run_cli_check("cube gold\n")
        self.assertEqual(code, 1)
        self.assertIn("E202", text)

    def test_unknown_word_cubee_exits_1_with_did_you_mean_cube(self):
        code, text = run_cli_check("cubee red\n")
        self.assertEqual(code, 1)
        self.assertIn("did you mean", text.lower())
        self.assertIn("cube", text)

    def test_valid_file_exits_0(self):
        code, text = run_cli_check("cube red\n")
        self.assertEqual(code, 0, text)

    def test_error_cap_twenty_bad_lines_stays_bounded(self):
        content = "\n".join(["cube gold"] * 20) + "\n"
        code, text = run_cli_check(content)
        self.assertEqual(code, 1)
        count = len(re.findall(r"\b[EW]\d{3}:", text))
        self.assertGreater(count, 0)
        self.assertLessEqual(count, 30)


if __name__ == "__main__":
    unittest.main()
