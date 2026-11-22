"""Forge3D Wave E seat E04: tests for the custom-shader sidecar
``runtime/f3d-shader.js`` (RPN shader expressions, mirroring
``src/shader.f90`` -- identical RPN, identical results).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_shader_js.py

The existence check always runs. The numeric checks shell out to
``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest
reports them as skipped, with the reason, rather than passing
silently).

The value grid is cross-checked independently in Python with the
``math`` module: every expected value below is written as a plain
Python / ``math`` expression, not derived from the JS. Tolerance
is 1e-9. Two cross-language notes:

* Modulo: Fortran ``MOD(a, b)`` and JS ``%`` both take the sign
  of the dividend (``a``); Python's ``%`` takes the sign of the
  divisor instead, so the negative-modulo expectations use
  ``math.fmod`` (which also takes the sign of the dividend).
* Byte rounding: JS ``Math.round`` is half-up, Fortran ``nint``
  is half-to-even. Test values avoid exact .5 boundaries EXCEPT
  the documented 0.5 case: 0.5 * 255 = 127.5, and both agree
  there -- ``nint(127.5)`` = 128 (127.5 rounds to the even 128)
  and ``Math.round(127.5)`` = 128.
"""

import json
import math
import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-shader.js")
NODE = shutil.which("node")

# Loaded before every snippet: expose `window` (as in a browser
# page that loads the sidecar after f3d.js) and bind the export
# as `S`.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_SHADER, 'utf8'));"
    "const S = globalThis.Forge3DShader;"
    "const assert = require('assert');"
    "const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);"
)


def run_node(snippet, extra_env=None):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_SHADER=JS_PATH)
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run(
        [NODE, "-e", PREAMBLE + snippet],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(
            "node snippet failed (rc=%d):\n%s\n%s"
            % (proc.returncode, proc.stdout, proc.stderr)
        )
    return proc


def env(**kw):
    base = dict(c=0.6, r=0.2, g=0.4, b=0.8, x=0.35, y=-1.25,
                z=2.0, u=0.25, v=0.75, ndl=0.8, t=1.5)
    base.update(kw)
    return base


# (rpn, env, expected) -- expected computed independently here
# with the math module / plain Python arithmetic.
CASES = [
    # Constants and literal forms (string and numeric tokens).
    (["0.5"], env(), 0.5),
    ([0.5], env(), 0.5),
    ([42], env(), 42.0),
    (["-3.25"], env(), -3.25),
    (["pi"], env(), math.pi),
    (["pi", "2", "/"], env(), math.pi / 2),
    # Every variable.
    (["c"], env(), 0.6),
    (["r", "g", "+", "b", "+"], env(), 0.2 + 0.4 + 0.8),
    (["x", "y", "+", "z", "+"], env(), 0.35 + -1.25 + 2.0),
    (["u", "v", "*"], env(), 0.25 * 0.75),
    (["ndl"], env(), 0.8),
    (["t"], env(), 1.5),
    # Binary operators and neg.
    (["3", "4", "+"], env(), 3 + 4),
    (["3", "4", "-"], env(), 3 - 4),
    (["3", "4", "*"], env(), 3 * 4),
    (["7", "2", "/"], env(), 7 / 2),
    (["7", "3", "%"], env(), math.fmod(7, 3)),
    (["9", "0.5", "^"], env(), math.pow(9, 0.5)),
    (["5", "neg"], env(), -5.0),
    (["x", "neg"], env(), -0.35),
    # Lighting expression: c * (0.25 + 0.75 * ndl).
    (["c", "0.25", "0.75", "ndl", "*", "+", "*"], env(),
     0.6 * (0.25 + 0.75 * 0.8)),
    (["c", "0.25", "0.75", "ndl", "*", "+", "*"], env(ndl=0.0),
     0.6 * 0.25),
    (["c", "0.25", "0.75", "ndl", "*", "+", "*"], env(ndl=1.0),
     0.6 * 1.0),
    # Checker expression c * step(0.5, fract(x * 2)): fract(0.2)
    # is below the edge (gives 0), fract(0.8) is above (gives c).
    (["c", "0.5", "x", "2", "*", "fract", "step", "*"],
     env(x=0.1), 0.6 * (1.0 if (0.1 * 2 - math.floor(0.1 * 2))
                        >= 0.5 else 0.0)),
    (["c", "0.5", "x", "2", "*", "fract", "step", "*"],
     env(x=0.4), 0.6 * (1.0 if (0.4 * 2 - math.floor(0.4 * 2))
                        >= 0.5 else 0.0)),
    # Every 1-arg function.
    (["1", "sin"], env(), math.sin(1)),
    (["1", "cos"], env(), math.cos(1)),
    (["0.5", "tan"], env(), math.tan(0.5)),
    (["y", "abs"], env(), abs(-1.25)),
    (["2", "sqrt"], env(), math.sqrt(2)),
    (["1.7", "floor"], env(), math.floor(1.7)),
    (["-1.7", "floor"], env(), math.floor(-1.7)),
    (["1.2", "ceil"], env(), math.ceil(1.2)),
    (["-1.2", "ceil"], env(), math.ceil(-1.2)),
    (["2.75", "fract"], env(), 2.75 - math.floor(2.75)),
    (["-1.25", "fract"], env(), -1.25 - math.floor(-1.25)),
    # Every 2-arg function.
    (["3", "7", "min"], env(), min(3, 7)),
    (["3", "7", "max"], env(), max(3, 7)),
    (["0.5", "0.5", "step"], env(), 1.0),   # x == edge -> 1
    (["0.5", "0.25", "step"], env(), 0.0),  # x < edge -> 0
    (["2", "10", "pow"], env(), math.pow(2, 10)),
    (["5", "3", "pow"], env(), math.pow(5, 3)),
    # Every 3-arg function.
    (["1.5", "0", "1", "clamp"], env(), min(max(1.5, 0), 1)),
    (["-0.5", "0", "1", "clamp"], env(), min(max(-0.5, 0), 1)),
    (["0.3", "0", "1", "clamp"], env(), 0.3),
    (["0", "10", "0.25", "mix"], env(), 0 + (10 - 0) * 0.25),
    (["c", "1", "ndl", "mix"], env(), 0.6 + (1 - 0.6) * 0.8),
    # Semantics guards.
    (["1", "0", "/"], env(), 0.0),          # div by zero -> 0
    (["c", "0", "/"], env(), 0.0),
    (["1", "0", "%"], env(), 0.0),          # mod by zero -> 0
    # Negative modulo: JS % / Fortran MOD take the sign of the
    # dividend, so -7 mod 3 is -1 (Python's % would give 2;
    # math.fmod matches the Fortran/JS convention).
    (["-7", "3", "%"], env(), math.fmod(-7, 3)),
    (["7", "-3", "%"], env(), math.fmod(7, -3)),
    (["-2", "0.5", "pow"], env(), 0.0),     # neg base, frac exp
    (["0", "-1", "pow"], env(), 0.0),       # 0 ^ negative -> 0
    (["0", "0", "pow"], env(), 1.0),        # 0^0 = 1
    (["0", "0", "^"], env(), 1.0),
    (["-4", "sqrt"], env(), 0.0),           # sqrt(negative) -> 0
    (["-8", "0.5", "^"], env(), 0.0),       # ^ shares pow guard
    # A composed expression using several pieces at once.
    (["x", "fract", "y", "abs", "min", "t", "*"], env(),
     min(0.35 - math.floor(0.35), abs(-1.25)) * 1.5),
]


class TestF3DShaderFile(unittest.TestCase):
    def test_file_exists(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        self.assertGreater(os.path.getsize(JS_PATH), 0)


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-shader.js numeric tests not run"
)
class TestF3DShaderNumeric(unittest.TestCase):
    def test_exports(self):
        run_node(
            "for (const k of ['parseRPN','evalRPN','shadeChannel',"
            "  'shadeRGB'])"
            "  assert.strictEqual(typeof S[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.Forge3DShader, S);"
        )

    def test_parse_returns_validated_copy(self):
        run_node(
            "const inp = ['c', '0.5', '+'];"
            "const out = S.parseRPN(inp);"
            "assert.deepStrictEqual(out, inp);"
            "assert.notStrictEqual(out, inp);"
            "assert.deepStrictEqual(S.parseRPN([0.25, 'pi', '*']),"
            "  [0.25, 'pi', '*']);"
        )

    def test_value_grid_cross_check(self):
        payload = [{"rpn": rpn, "env": e} for rpn, e, _ in CASES]
        proc = run_node(
            "const cases = JSON.parse(process.env.F3D_SHADER_CASES);"
            "const out = cases.map(cs => S.evalRPN(cs.rpn, cs.env));"
            "console.log(JSON.stringify(out));",
            extra_env={"F3D_SHADER_CASES": json.dumps(payload)},
        )
        got = json.loads(proc.stdout.strip())
        self.assertEqual(len(got), len(CASES))
        for i, ((rpn, _e, expected), actual) in enumerate(
                zip(CASES, got)):
            self.assertAlmostEqual(
                actual, expected, delta=1e-9,
                msg="case %d rpn=%r: node=%r python=%r"
                    % (i, rpn, actual, expected),
            )

    def test_shade_channel(self):
        run_node(
            # 0.5 * 255 = 127.5 -> 128 (see module docstring:
            # JS Math.round half-up and Fortran nint half-to-even
            # agree on this value). Out-of-range clamps first.
            "assert.strictEqual(S.shadeChannel(['0.5'], {}), 128);"
            "assert.strictEqual(S.shadeChannel(['0'], {}), 0);"
            "assert.strictEqual(S.shadeChannel(['1'], {}), 255);"
            "assert.strictEqual(S.shadeChannel(['2'], {}), 255);"
            "assert.strictEqual(S.shadeChannel(['-1'], {}), 0);"
            "assert.strictEqual(S.shadeChannel(['c'], {c: 0.25}), 64);"
        )

    def test_shade_rgb(self):
        run_node(
            # Constant 0.5 -> 128 on every channel (127.5 case,
            # documented above; both roundings agree).
            "assert.deepStrictEqual(S.shadeRGB(['0.5'], [10, 20, 30], {}),"
            "  [128, 128, 128]);"
            # c alone is the identity on the base colour.
            "assert.deepStrictEqual(S.shadeRGB(['c'], [10, 20, 30], {}),"
            "  [10, 20, 30]);"
            # r is the base red for every channel: 10/255 -> 10.
            "assert.deepStrictEqual(S.shadeRGB(['r'], [10, 20, 30], {}),"
            "  [10, 10, 10]);"
            # Lighting expr at ndl = 1 is also the identity;
            # at ndl = 0 it scales c by 0.25: 200*.25=50,
            # 100*.25=25, 40*.25=10 (no .5 byte boundaries).
            "const lit = ['c', '0.25', '0.75', 'ndl', '*', '+', '*'];"
            "assert.deepStrictEqual("
            "  S.shadeRGB(lit, [200, 100, 40], {ndl: 1}),"
            "  [200, 100, 40]);"
            "assert.deepStrictEqual("
            "  S.shadeRGB(lit, [200, 100, 40], {ndl: 0}),"
            "  [50, 25, 10]);"
            # Clamping through shadeRGB.
            "assert.deepStrictEqual(S.shadeRGB(['2'], [0, 0, 0], {}),"
            "  [255, 255, 255]);"
        )

    def test_parse_errors_throw(self):
        run_node(
            "const bad = ["
            "  [['foo'], /unknown/],"          # unknown variable
            "  [['c', 'bogus', '+'], /unknown/],"  # unknown token
            "  [['nosuchfn'], /unknown/],"     # unknown function
            "  [['+'], /underflow/],"         # arity underflow
            "  [['c', '+'], /underflow/],"
            "  [['1', '2', 'clamp'], /underflow/],"  # 3-arg, 2 given
            "  [['sin'], /underflow/],"
            "  [['c', 'r'], /leftover/],"      # leftover stack 2
            "  [[], /leftover/],"              # leftover stack 0
            "  ['not-an-array', /array/],"
            "];"
            "for (const [rpn, re] of bad) {"
            "  assert.throws(() => S.parseRPN(rpn), re,"
            "    'parseRPN(' + JSON.stringify(rpn) + ')');"
            "}"
            # evalRPN validates too.
            "assert.throws(() => S.evalRPN(['wat'], {}), /unknown/);"
            "assert.throws(() => S.evalRPN(['c', 'r'], {}), /leftover/);"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
