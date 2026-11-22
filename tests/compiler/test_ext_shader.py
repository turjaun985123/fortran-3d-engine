#!/usr/bin/env python3
"""Tests for the Forge3D Wave E custom-shader extension (compiler side).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_shader.py
    python3 -m unittest tests.compiler.test_ext_shader

Covers the frozen C2 surface: the expression tokeniser, the
shunting-yard compiler to RPN (precedence, associativity, parens,
unary minus, every function at its frozen arity), every error class
``to_rpn`` must raise on, ``validate_shader`` stack simulation, and
the exact ``shaderdef`` / ``shaderbind`` emit lines. Per-pixel
evaluation (and its semantics guards) is out of scope here by
design: it lives in Fortran + JS.
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

import ext_shader  # noqa: E402
from ext_shader import (  # noqa: E402
    EXPR_FUNCS,
    EXPR_VARS,
    binding_line,
    scene_lines,
    to_rpn,
    tokenize_expr,
    validate_shader,
)


def compile_src(src):
    return to_rpn(tokenize_expr(src))


class TestVocabulary(unittest.TestCase):
    def test_vars_frozen(self):
        self.assertEqual(set(EXPR_VARS), {
            "c", "r", "g", "b", "x", "y", "z", "u", "v", "ndl",
            "t", "pi",
        })

    def test_funcs_frozen(self):
        self.assertEqual(EXPR_FUNCS, {
            "sin": 1, "cos": 1, "tan": 1, "abs": 1, "sqrt": 1,
            "floor": 1, "ceil": 1, "fract": 1,
            "min": 2, "max": 2, "step": 2, "pow": 2,
            "clamp": 3, "mix": 3,
        })


class TestTokenize(unittest.TestCase):
    def test_simple(self):
        self.assertEqual(tokenize_expr("c * 0.5 + ndl"),
                         ["c", "*", "0.5", "+", "ndl"])

    def test_no_spaces_needed(self):
        self.assertEqual(tokenize_expr("step(0.5,fract(x))"),
                         ["step", "(", "0.5", ",", "fract", "(",
                          "x", ")", ")"])

    def test_number_spellings_verbatim(self):
        self.assertEqual(tokenize_expr("0.50 2 .5 10. 007"),
                         ["0.50", "2", ".5", "10.", "007"])

    def test_all_operators(self):
        self.assertEqual(tokenize_expr("+-*/%^(),"),
                         ["+", "-", "*", "/", "%", "^", "(", ")",
                          ","])

    def test_empty_source(self):
        self.assertEqual(tokenize_expr(""), [])
        self.assertEqual(tokenize_expr("   "), [])

    def test_invalid_character(self):
        for src in ("x $ y", "x & y", "c = 1", "x; y"):
            with self.assertRaises(ValueError, msg=src):
                tokenize_expr(src)

    def test_malformed_number(self):
        with self.assertRaises(ValueError):
            tokenize_expr("1.2.3")

    def test_non_string(self):
        with self.assertRaises(ValueError):
            tokenize_expr(None)
        with self.assertRaises(ValueError):
            tokenize_expr(42)


class TestRpnBasics(unittest.TestCase):
    def test_single_operands(self):
        self.assertEqual(compile_src("c"), ["c"])
        self.assertEqual(compile_src("0.5"), ["0.5"])
        self.assertEqual(compile_src("pi"), ["pi"])

    def test_every_variable(self):
        for var in sorted(EXPR_VARS):
            self.assertEqual(compile_src(var), [var])

    def test_numbers_verbatim_in_rpn(self):
        self.assertEqual(compile_src("0.50 + 2"), ["0.50", "2", "+"])

    def test_precedence_mul_over_add(self):
        self.assertEqual(compile_src("1 + 2 * 3"),
                         ["1", "2", "3", "*", "+"])
        self.assertEqual(compile_src("1 * 2 + 3"),
                         ["1", "2", "*", "3", "+"])

    def test_left_associativity(self):
        self.assertEqual(compile_src("10 - 4 - 3"),
                         ["10", "4", "-", "3", "-"])
        self.assertEqual(compile_src("x / y % z"),
                         ["x", "y", "/", "z", "%"])

    def test_power_binds_tightest_and_is_right_associative(self):
        self.assertEqual(compile_src("2 + 3 ^ 2"),
                         ["2", "3", "2", "^", "+"])
        self.assertEqual(compile_src("2 ^ 3 ^ 2"),
                         ["2", "3", "2", "^", "^"])

    def test_parens_override_precedence(self):
        self.assertEqual(compile_src("(1 + 2) * 3"),
                         ["1", "2", "+", "3", "*"])

    def test_spec_example(self):
        self.assertEqual(compile_src("c * (0.25 + 0.75 * ndl)"),
                         ["c", "0.25", "0.75", "ndl", "*", "+", "*"])

    def test_modulo(self):
        self.assertEqual(compile_src("x % 2"), ["x", "2", "%"])


class TestUnaryMinus(unittest.TestCase):
    def test_leading(self):
        self.assertEqual(compile_src("-x"), ["x", "neg"])
        self.assertEqual(compile_src("-x + y"), ["x", "neg", "y", "+"])

    def test_before_group(self):
        self.assertEqual(compile_src("-(x + y)"), ["x", "y", "+", "neg"])

    def test_after_binary_operator(self):
        self.assertEqual(compile_src("2 * -3"), ["2", "3", "neg", "*"])
        self.assertEqual(compile_src("x - -y"), ["x", "y", "neg", "-"])
        self.assertEqual(compile_src("2 ^ -1"), ["2", "1", "neg", "^"])

    def test_double_negation(self):
        self.assertEqual(compile_src("--x"), ["x", "neg", "neg"])

    def test_neg_binds_looser_than_power(self):
        self.assertEqual(compile_src("-2 ^ 2"), ["2", "2", "^", "neg"])

    def test_before_function_call(self):
        self.assertEqual(compile_src("-sin(x)"), ["x", "sin", "neg"])


class TestFunctions(unittest.TestCase):
    def test_every_1arg_function(self):
        for name in ("sin", "cos", "tan", "abs", "sqrt", "floor",
                     "ceil", "fract"):
            self.assertEqual(compile_src("%s(x)" % name),
                             ["x", name], name)

    def test_every_2arg_function(self):
        for name in ("min", "max", "step", "pow"):
            self.assertEqual(compile_src("%s(x, y)" % name),
                             ["x", "y", name], name)

    def test_every_3arg_function(self):
        for name in ("clamp", "mix"):
            self.assertEqual(compile_src("%s(x, 0, 1)" % name),
                             ["x", "0", "1", name], name)

    def test_nested_calls(self):
        self.assertEqual(compile_src("sin(cos(x))"),
                         ["x", "cos", "sin"])
        self.assertEqual(compile_src("min(max(x, y), z)"),
                         ["x", "y", "max", "z", "min"])

    def test_call_args_are_full_expressions(self):
        self.assertEqual(compile_src("clamp(c * ndl, 0.0, 1.0)"),
                         ["c", "ndl", "*", "0.0", "1.0", "clamp"])
        self.assertEqual(compile_src("pow(x, 1 + 2)"),
                         ["x", "1", "2", "+", "pow"])

    def test_checker_expression_from_spec(self):
        self.assertEqual(
            compile_src("step(0.5, fract((x + y) * 2)) * c"),
            ["0.5", "x", "y", "+", "2", "*", "fract", "step",
             "c", "*"])

    def test_fract_identity_shape(self):
        # fract(x) is a single call here; the x - floor(x) expansion
        # is the evaluators' business, not the compiler's.
        self.assertEqual(compile_src("fract(u)"), ["u", "fract"])


class TestToRpnErrors(unittest.TestCase):
    def assert_bad(self, src, *needles):
        with self.assertRaises(ValueError, msg=src) as ctx:
            compile_src(src)
        message = str(ctx.exception)
        for needle in needles:
            self.assertIn(needle, message, src)

    def test_empty_input(self):
        with self.assertRaises(ValueError) as ctx:
            to_rpn([])
        self.assertIn("empty", str(ctx.exception))
        self.assert_bad("", "empty")
        self.assert_bad("   ", "empty")

    def test_unknown_variable(self):
        self.assert_bad("q + 1", "unknown variable", "q")
        self.assert_bad("colour", "unknown variable", "colour")

    def test_unknown_function(self):
        self.assert_bad("blur(x)", "unknown function", "blur")

    def test_wrong_arity_too_few(self):
        self.assert_bad("sin()", "sin", "0")
        self.assert_bad("min(x)", "min", "1")
        self.assert_bad("clamp(x, 0)", "clamp", "2")

    def test_wrong_arity_too_many(self):
        self.assert_bad("sin(x, y)", "sin", "2")
        self.assert_bad("max(x, y, z)", "max", "3")
        self.assert_bad("mix(x, y, z, t)", "mix", "4")

    def test_unbalanced_parens_open(self):
        self.assert_bad("(x + y", "unbalanced")
        self.assert_bad("sin(x", "unbalanced")
        self.assert_bad("((x)", "unbalanced")

    def test_unbalanced_parens_close(self):
        self.assert_bad("x + y)", "unbalanced")
        self.assert_bad(")x(", "unbalanced")

    def test_trailing_operator(self):
        self.assert_bad("x +", "trailing operator", "+")
        self.assert_bad("c * ndl *", "trailing operator", "*")
        self.assert_bad("x ^", "trailing operator", "^")

    def test_leading_binary_operator(self):
        self.assert_bad("* x", "missing operand")
        self.assert_bad("+ x", "missing operand")

    def test_missing_operator_between_operands(self):
        self.assert_bad("x y", "missing operator")
        self.assert_bad("2 3", "missing operator")
        self.assert_bad("x (y)", "missing operator")

    def test_missing_operand_in_call(self):
        self.assert_bad("min(, x)", "missing operand")
        self.assert_bad("min(x, )", "missing operand")
        self.assert_bad("(x + )", "missing operand")

    def test_comma_outside_function(self):
        self.assert_bad("(x, y)", "function")
        self.assert_bad("x, y", "unbalanced")

    def test_function_without_parens(self):
        self.assert_bad("sin x", "sin", "'('")
        self.assert_bad("sin", "sin")

    def test_empty_parens(self):
        with self.assertRaises(ValueError):
            compile_src("()")
        with self.assertRaises(ValueError):
            compile_src("c * ()")

    def test_malformed_number_token(self):
        with self.assertRaises(ValueError):
            to_rpn(["1.2.3"])


class TestValidateShader(unittest.TestCase):
    def test_valid_definitions(self):
        self.assertEqual(validate_shader("glow", compile_src("c")), [])
        self.assertEqual(
            validate_shader(
                "checker",
                compile_src("step(0.5, fract((x + y) * 2)) * c")),
            [])
        self.assertEqual(
            validate_shader("shade",
                            compile_src("c * (0.25 + 0.75 * ndl)")),
            [])

    def test_missing_name(self):
        errors = validate_shader("", ["c"])
        self.assertEqual(len(errors), 1)
        self.assertIn("no name", errors[0])
        errors = validate_shader(None, ["c"])
        self.assertEqual(len(errors), 1)
        self.assertIn("no name", errors[0])

    def test_invalid_name(self):
        errors = validate_shader("9bad", ["c"])
        self.assertEqual(len(errors), 1)
        self.assertIn("9bad", errors[0])
        self.assertIn("identifier", errors[0])
        errors = validate_shader("has space", ["c"])
        self.assertEqual(len(errors), 1)
        self.assertIn("identifier", errors[0])

    def test_empty_or_missing_rpn(self):
        for bad in ([], None, "c"):
            errors = validate_shader("glow", bad)
            self.assertEqual(len(errors), 1, bad)
            self.assertIn("glow", errors[0])

    def test_unknown_variable_in_rpn(self):
        errors = validate_shader("glow", ["q"])
        self.assertEqual(len(errors), 1)
        self.assertIn("glow", errors[0])
        self.assertIn("q", errors[0])
        self.assertIn("unknown variable", errors[0])

    def test_unknown_token_in_rpn(self):
        errors = validate_shader("glow", ["c", "$"])
        self.assertTrue(any("unknown token" in e for e in errors),
                        errors)

    def test_stack_underflow(self):
        errors = validate_shader("glow", ["c", "+"])
        self.assertTrue(any("operator" in e for e in errors), errors)
        errors = validate_shader("glow", ["neg"])
        self.assertTrue(any("unary minus" in e for e in errors),
                        errors)
        errors = validate_shader("glow", ["c", "clamp"])
        self.assertTrue(any("clamp" in e for e in errors), errors)

    def test_leftover_values(self):
        errors = validate_shader("glow", ["c", "r"])
        self.assertEqual(len(errors), 1)
        self.assertIn("2 values", errors[0])

    def test_neg_and_functions_balance(self):
        self.assertEqual(
            validate_shader("glow", ["x", "neg", "sin"]), [])
        self.assertEqual(
            validate_shader("glow", ["x", "0", "1", "clamp"]), [])


class TestSceneLines(unittest.TestCase):
    def test_exact_single_line(self):
        defs = [("shade", compile_src("c * (0.25 + 0.75 * ndl)"))]
        self.assertEqual(
            scene_lines(defs),
            ["shaderdef shade 7 c 0.25 0.75 ndl * + *"])

    def test_checker_line_exact(self):
        defs = [("checker",
                 compile_src("step(0.5, fract((x + y) * 2)) * c"))]
        self.assertEqual(
            scene_lines(defs),
            ["shaderdef checker 10 0.5 x y + 2 * fract step c *"])

    def test_numbers_verbatim(self):
        defs = [("n", compile_src("0.50 + 2"))]
        self.assertEqual(scene_lines(defs), ["shaderdef n 3 0.50 2 +"])

    def test_order_preserved(self):
        defs = [("a", ["c"]), ("b", ["r", "neg"])]
        self.assertEqual(scene_lines(defs),
                         ["shaderdef a 1 c", "shaderdef b 2 r neg"])

    def test_empty_defs(self):
        self.assertEqual(scene_lines([]), [])
        self.assertEqual(scene_lines(None), [])

    def test_empty_rpn_line(self):
        self.assertEqual(scene_lines([("blank", [])]),
                         ["shaderdef blank 0"])


class TestBindingLine(unittest.TestCase):
    def test_exact(self):
        self.assertEqual(binding_line("cube1", "checker"),
                         "shaderbind cube1 checker")
        self.assertEqual(binding_line("hero", "shade"),
                         "shaderbind hero shade")


class TestRoundTrip(unittest.TestCase):
    def test_compiled_defs_validate_and_emit(self):
        sources = {
            "flat": "c",
            "shade": "c * (0.25 + 0.75 * ndl)",
            "checker": "step(0.5, fract((x + y) * 2)) * c",
            "pulse": "mix(r, b, 0.5 + 0.5 * sin(t * pi))",
            "wrap": "fract(u * 4) + fract(v * 4)",
        }
        defs = []
        for name, src in sources.items():
            rpn = compile_src(src)
            self.assertEqual(validate_shader(name, rpn), [], name)
            defs.append((name, rpn))
        lines = scene_lines(defs)
        self.assertEqual(len(lines), len(sources))
        for line, (name, rpn) in zip(lines, defs):
            parts = line.split()
            self.assertEqual(parts[0], "shaderdef")
            self.assertEqual(parts[1], name)
            self.assertEqual(int(parts[2]), len(rpn))
            self.assertEqual(parts[3:], rpn)

    def test_module_exports(self):
        for name in ext_shader.__all__:
            self.assertTrue(hasattr(ext_shader, name), name)


if __name__ == "__main__":
    unittest.main()
