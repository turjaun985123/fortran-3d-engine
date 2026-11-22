#!/usr/bin/env python3
"""Wave E compiler parity tests (seat E11).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_wavee_parity.py

Mirrors the Wave C / Wave D parity harnesses: the compile tests
drive the real pipeline -- ``parser.parse`` -> ``validate.validate``
-> ``emit_fortran.emit_scene_text`` (plus ``emit_json.emit_json_v2``
for the JSON payload) -- for the Wave E surface wired by the
coordinator:

* custom shaders: ``shader <name> expr "<expr>"`` definitions and
  the object prop ``shader <name>``, emitted as ``shaderdef`` /
  ``shaderbind`` .scene lines;
* skinning / morphs: ``morph <target> <kind> <factor>``,
  ``bone <name> [at x,y,z] [rotate rx,ry,rz] [radius r]`` and
  ``skin <target> <bonename>``, emitted as ``morph`` / ``bone`` /
  ``skin`` .scene lines (skins last);
* both ride in ``scene.extensions["wavee"]`` and into the v2 JSON
  payload.

The JS cross-checks shell out to ``node`` (skipped loudly via
``skipUnless`` when node is absent, the pattern from
``test_f3d_raycast_js.py``) and compare ``runtime/f3d-shader.js``
``evalRPN`` and ``runtime/f3d-skin.js`` ``morphApply`` /
``skinApply`` against independent Python reference implementations
of the same RPN / morph / skin semantics written below, within
1e-9 (factor-0 identity is exact).

NOTE on the checker RPN order (verified against the live compiler
on this tree, 2026-11-23): ``c * step(0.5, fract((x + y) * 2))``
compiles to ``c 0.5 x y + 2 * fract step *`` -- the leading ``c``
is the left operand of the outer ``*``, so it comes FIRST in RPN.
(The seat brief's example line listed the tokens in the order for
``step(...) * c`` instead; the tests below assert the line the
compiler actually emits, cross-checked token-for-token against
``ext_shader.to_rpn`` semantics and the JS evaluator grid.)
"""

import json
import math
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "f3dc"))

import emit_fortran  # noqa: E402
import emit_json  # noqa: E402
import parser  # noqa: E402
import validate  # noqa: E402
from errors import ErrorBag  # noqa: E402

NODE = shutil.which("node")
SHADER_JS = str(REPO_ROOT / "runtime" / "f3d-shader.js")
SKIN_JS = str(REPO_ROOT / "runtime" / "f3d-skin.js")

CHECKER_SRC = 'shader checker expr "c * step(0.5, fract((x + y) * 2))"\n'
CHECKER_RPN = ["c", "0.5", "x", "y", "+", "2", "*", "fract", "step", "*"]
# The exact .scene line the compiler emits for CHECKER_SRC (see the
# module docstring note on RPN operand order).
CHECKER_LINE = "shaderdef checker 10 c 0.5 x y + 2 * fract step *"
LIGHTING_RPN = ["c", "0.25", "0.75", "ndl", "*", "+", "*"]


def run(source, base_dir="."):
    """Parse + validate ``source``; return (ir_scene_or_None, error_codes)."""
    bag = ErrorBag()
    program = parser.parse(source, "test.f3d", bag)
    scene = validate.validate(program, bag, base_dir=base_dir)
    codes = [d.code for d in bag.diagnostics if d.severity == "error"]
    return scene, codes


def compile_scene(source):
    scene, codes = run(source)
    if codes or scene is None:
        raise AssertionError("expected a clean compile, got errors %r"
                             % (codes,))
    return scene


def emit_lines(source):
    """Full pipeline to the emitted .scene lines; fails on errors."""
    return emit_fortran.emit_scene_text(compile_scene(source)).splitlines()


def lines_starting(lines, prefix):
    return [ln for ln in lines if ln.startswith(prefix)]


# ----------------------------------------------------------------------
# Independent Python reference: RPN shader semantics
# ----------------------------------------------------------------------

def _safe_pow(a, b):
    if a == 0:
        return 0.0 if b < 0 else math.pow(a, b)  # 0^0 == 1
    if a < 0 and b != math.floor(b):
        return 0.0
    try:
        value = math.pow(a, b)
    except (OverflowError, ValueError):
        return 0.0
    return 0.0 if math.isnan(value) else value


_FUN1 = {
    "sin": math.sin, "cos": math.cos, "tan": math.tan,
    "abs": abs, "floor": lambda a: float(math.floor(a)),
    "ceil": lambda a: float(math.ceil(a)),
    "sqrt": lambda a: 0.0 if a < 0 else math.sqrt(a),
    "fract": lambda a: a - math.floor(a),
    "neg": lambda a: -a,
}
_FUN2 = {
    "min": min, "max": max,
    "step": lambda edge, x: 1.0 if x >= edge else 0.0,
    "pow": _safe_pow,
}
_FUN3 = {
    "clamp": lambda x, lo, hi: min(max(x, lo), hi),
    "mix": lambda a, b, f: a + (b - a) * f,
}
_BINOPS = {
    "+": lambda a, b: a + b, "-": lambda a, b: a - b,
    "*": lambda a, b: a * b,
    "/": lambda a, b: 0.0 if b == 0 else a / b,
    # JS % / Fortran MOD take the sign of the dividend: math.fmod.
    "%": lambda a, b: 0.0 if b == 0 else math.fmod(a, b),
    "^": _safe_pow,
}


def py_eval_rpn(rpn, env):
    """Reference evaluator for the frozen RPN semantics."""
    stack = []
    for tok in rpn:
        if tok == "pi":
            stack.append(math.pi)
        elif tok in _FUN1:
            stack.append(float(_FUN1[tok](stack.pop())))
        elif tok in _FUN2:
            b, a = stack.pop(), stack.pop()
            stack.append(float(_FUN2[tok](a, b)))
        elif tok in _FUN3:
            c, b, a = stack.pop(), stack.pop(), stack.pop()
            stack.append(float(_FUN3[tok](a, b, c)))
        elif tok in _BINOPS:
            b, a = stack.pop(), stack.pop()
            stack.append(float(_BINOPS[tok](a, b)))
        else:
            try:
                stack.append(float(tok))
            except (TypeError, ValueError):
                stack.append(float(env.get(tok, 0.0)))
    if len(stack) != 1:
        raise AssertionError("reference RPN left %d values" % len(stack))
    return stack[0]


# ----------------------------------------------------------------------
# Independent Python reference: morph + skin semantics
# ----------------------------------------------------------------------

def _centroid(verts):
    n = len(verts) // 3
    return [sum(verts[3 * i + k] for i in range(n)) / n for k in range(3)]


def py_morph(verts, kind, factor):
    out = list(verts)
    n = len(verts) // 3
    if n == 0 or factor == 0:
        return out
    c = _centroid(verts)
    if kind == "bulge":
        halfh = max(abs(verts[3 * i + 1] - c[1]) for i in range(n))
        if halfh == 0:
            return out
        for i in range(n):
            q = (verts[3 * i + 1] - c[1]) / halfh
            s = 1 + factor * 0.5 * (1 - q * q)
            out[3 * i] = c[0] + (verts[3 * i] - c[0]) * s
            out[3 * i + 1] = verts[3 * i + 1]
            out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * s
    elif kind == "taper":
        ys = [verts[3 * i + 1] for i in range(n)]
        if max(ys) == min(ys):
            return out
        for i in range(n):
            h = (verts[3 * i + 1] - min(ys)) / (max(ys) - min(ys))
            s = 1 - factor * 0.5 * h
            out[3 * i] = c[0] + (verts[3 * i] - c[0]) * s
            out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * s
    elif kind == "squash":
        for i in range(n):
            out[3 * i] = c[0] + (verts[3 * i] - c[0]) * (1 + 0.25 * factor)
            out[3 * i + 1] = c[1] + (verts[3 * i + 1] - c[1]) * (
                1 - 0.5 * factor)
            out[3 * i + 2] = c[2] + (verts[3 * i + 2] - c[2]) * (
                1 + 0.25 * factor)
    else:
        raise ValueError(kind)
    return out


def py_skin_weight(dist, radius):
    if radius <= 0:
        return 0.0
    s = min(1.0, max(0.0, 1 - dist / radius))
    return s * s * (3 - 2 * s)


def _py_rotate(q, rot_deg):
    """Rz * Ry * Rx * q, math_3d.f90 conventions, degrees."""
    x, y, z = q
    cx, sx = math.cos(math.radians(rot_deg[0])), \
        math.sin(math.radians(rot_deg[0]))
    cy, sy = math.cos(math.radians(rot_deg[1])), \
        math.sin(math.radians(rot_deg[1]))
    cz, sz = math.cos(math.radians(rot_deg[2])), \
        math.sin(math.radians(rot_deg[2]))
    y, z = cx * y - sx * z, sx * y + cx * z          # Rx
    x, z = cy * x + sy * z, -sy * x + cy * z         # Ry (old x in z)
    x, y = cz * x - sz * y, sz * x + cz * y          # Rz
    return [x, y, z]


def py_skin_apply(verts, pivot, rot_deg, radius):
    out = list(verts)
    for i in range(len(verts) // 3):
        p = verts[3 * i:3 * i + 3]
        w = py_skin_weight(math.dist(p, pivot), radius)
        if w == 0:
            continue
        r = _py_rotate([p[k] - pivot[k] for k in range(3)], rot_deg)
        m = [pivot[k] + r[k] for k in range(3)]
        out[3 * i:3 * i + 3] = [(1 - w) * p[k] + w * m[k] for k in range(3)]
    return out


# ----------------------------------------------------------------------
# Node helpers (skipUnless pattern from test_f3d_raycast_js.py)
# ----------------------------------------------------------------------

def run_node_json(js_path, env_key, preamble, snippet, payload=None):
    env = dict(os.environ, F3D_WAVEE_JS=js_path)
    if payload is not None:
        env[env_key] = json.dumps(payload)
    proc = subprocess.run(
        [NODE, "-e", preamble + snippet],
        capture_output=True, text=True, env=env, timeout=30)
    if proc.returncode != 0:
        raise AssertionError("node snippet failed (rc=%d):\n%s\n%s"
                             % (proc.returncode, proc.stdout, proc.stderr))
    return json.loads(proc.stdout.strip().splitlines()[-1])


SHADER_PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_WAVEE_JS, 'utf8'));"
    "const S = globalThis.Forge3DShader;"
)
SKIN_PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_WAVEE_JS, 'utf8'));"
    "const S = globalThis.Forge3DSkin;"
)

# Small vertex sets for the skin cross-checks.
VERTS = [1, 0, 0, -1, 0, 0, 0, 2, 0, 0, -2, 0, 0, 0, 3]
CUBE_VERTS = [x for p in [(-1, -1, -1), (1, -1, -1), (1, 1, -1),
                          (-1, 1, -1), (-1, -1, 1), (1, -1, 1),
                          (1, 1, 1), (-1, 1, 1)] for x in p]


class TestWaveEParity(unittest.TestCase):
    # -- 1. Shader .scene emission, exact -----------------------------

    def test_shaderdef_and_shaderbind_exact(self):
        lines = emit_lines(
            CHECKER_SRC + "cube hero red at 0 0 0 size 2 shader checker\n")
        self.assertEqual(lines_starting(lines, "shaderdef"),
                         [CHECKER_LINE])
        self.assertEqual(lines_starting(lines, "shaderbind"),
                         ["shaderbind hero checker"])

    # -- 2. Second shader coexists; unbound object has no binding -----

    def test_second_shader_coexists_and_unbound_object_absent(self):
        lines = emit_lines(
            'shader half expr "0.5"\n'
            + CHECKER_SRC
            + "cube hero red at 0 0 0 size 2 shader checker\n"
            + "cube plain blue at 4 0 0 size 2\n")
        self.assertEqual(lines_starting(lines, "shaderdef"), [
            "shaderdef half 1 0.5",
            CHECKER_LINE,
        ])
        binds = lines_starting(lines, "shaderbind")
        self.assertEqual(binds, ["shaderbind hero checker"])
        self.assertFalse(any("plain" in b for b in binds))

    # -- 3. Skin .scene emission, exact --------------------------------

    def test_bone_defaults_exact(self):
        lines = emit_lines("cube hero red\nbone spine\n")
        self.assertEqual(lines_starting(lines, "bone"),
                         ["bone spine 0 0 0 0 0 0 2"])

    def test_bone_full_form_morph_and_skin_exact(self):
        lines = emit_lines(
            "cube hero red\n"
            "bone spine\n"
            "bone arm at 1,2,3 rotate 10,20,30 radius 3.5\n"
            "morph hero bulge 0.5\n"
            "skin hero spine\n")
        self.assertEqual(lines_starting(lines, "morph"),
                         ["morph hero bulge 0.5"])
        self.assertEqual(lines_starting(lines, "bone"), [
            "bone spine 0 0 0 0 0 0 2",
            "bone arm 1 2 3 10 20 30 3.5",
        ])
        self.assertEqual(lines_starting(lines, "skin"),
                         ["skin hero spine"])
        # Skins are emitted last among the Wave E lines.
        wavee_lines = [ln for ln in lines if ln.startswith(
            ("shaderdef", "shaderbind", "morph", "bone", "skin"))]
        self.assertEqual(wavee_lines[-1], "skin hero spine")

    # -- 4. JSON payload ------------------------------------------------

    def test_json_payload_wavee_extensions(self):
        source = (
            CHECKER_SRC
            + "cube hero red at 0 0 0 size 2 shader checker\n"
            + "bone spine at 1,2,3 rotate 10,20,30 radius 3.5\n"
            + "morph hero bulge 0.5\n"
            + "skin hero spine\n")
        scene = compile_scene(source)
        wavee = scene.extensions["wavee"]
        self.assertEqual(wavee["shaders"], [{
            "name": "checker", "rpn": CHECKER_RPN,
            "expr": "c * step(0.5, fract((x + y) * 2))",
        }])
        self.assertEqual(wavee["bindings"], {"hero": "checker"})
        self.assertEqual(wavee["morphs"],
                         [{"target": "hero", "kind": "bulge",
                           "factor": 0.5}])
        self.assertEqual(wavee["skins"],
                         [{"target": "hero", "bone": "spine"}])
        self.assertEqual(len(wavee["bones"]), 1)
        bone = wavee["bones"][0]
        self.assertEqual(bone["name"], "spine")
        self.assertEqual([float(v) for v in bone["at"]], [1.0, 2.0, 3.0])
        self.assertEqual([float(v) for v in bone["rotate"]],
                         [10.0, 20.0, 30.0])
        self.assertEqual(float(bone["radius"]), 3.5)

        payload = json.loads(emit_json.emit_json_v2(scene))
        self.assertEqual(payload["format"], "forge3d-scene")
        self.assertEqual(payload["version"], 2)
        jw = payload["extensions"]["wavee"]
        self.assertEqual(jw["shaders"], wavee["shaders"])
        self.assertEqual(jw["bindings"], {"hero": "checker"})
        self.assertEqual(jw["morphs"],
                         [{"target": "hero", "kind": "bulge",
                           "factor": 0.5}])
        self.assertEqual(jw["skins"],
                         [{"target": "hero", "bone": "spine"}])
        self.assertEqual(jw["bones"], [{
            "name": "spine", "at": [1.0, 2.0, 3.0],
            "rotate": [10.0, 20.0, 30.0], "radius": 3.5,
        }])

    # -- 5. Error parity --------------------------------------------------

    def assert_compile_error(self, source, code):
        scene, codes = run(source)
        self.assertIsNone(scene, "expected compile failure for %r" % source)
        self.assertIn(code, codes,
                      "expected %s for %r, got %r" % (code, source, codes))

    def test_error_unknown_shader_binding_e201(self):
        self.assert_compile_error("cube hero red shader nope\n", "E201")

    def test_error_unknown_function_e301(self):
        self.assert_compile_error(
            'shader s expr "c * nosuchfn(x)"\ncube hero red\n', "E301")

    def test_error_morph_unknown_target_e201(self):
        self.assert_compile_error(
            "cube hero red\nmorph ghost bulge 0.5\n", "E201")

    def test_error_skin_unknown_bone_e301(self):
        # Verified on this tree: validate wraps ext_skin's
        # unknown-bone message in E301 (not E201).
        self.assert_compile_error(
            "cube hero red\nskin hero nosuchbone\n", "E301")

    def test_error_bone_negative_radius_e301(self):
        self.assert_compile_error(
            "cube hero red\nbone b radius -1\n", "E301")

    def test_error_morph_factor_out_of_range_e301(self):
        self.assert_compile_error(
            "cube hero red\nmorph hero bulge 3\n", "E301")

    def test_error_unknown_morph_kind_e301(self):
        self.assert_compile_error(
            "cube hero red\nmorph hero wobble 0.5\n", "E301")

    # -- 6. JS cross-checks ----------------------------------------------

    @unittest.skipUnless(
        NODE, "SKIPPED: node not on PATH - f3d-shader.js checks not run")
    def test_js_shader_evalrpn_vs_python_reference(self):
        def env(**kw):
            base = dict(c=0.6, r=0.2, g=0.4, b=0.8, x=0.0, y=0.0,
                        z=0.0, u=0.25, v=0.75, ndl=0.8, t=1.5)
            base.update(kw)
            return base

        cases = []
        # Checker grid: points giving 0 (fract((x+y)*2) < 0.5) and
        # points giving c (fract >= 0.5), incl. the exact edge.
        for x, y in [(0.1, 0.0), (0.0, 0.1), (0.4, 0.0), (0.1, 0.2),
                     (0.25, 0.0), (0.0, 0.0), (0.9, 0.9), (-0.4, 0.0)]:
            cases.append((CHECKER_RPN, env(x=x, y=y)))
        # Lighting grid: c * (0.25 + 0.75 * ndl).
        for ndl in (0.0, 0.25, 0.5, 0.8, 1.0):
            cases.append((LIGHTING_RPN, env(ndl=ndl)))
            cases.append((LIGHTING_RPN, env(ndl=ndl, c=0.3)))
        payload = [{"rpn": rpn, "env": e} for rpn, e in cases]
        got = run_node_json(
            SHADER_JS, "F3D_WAVEE_CASES", SHADER_PREAMBLE,
            "const cases = JSON.parse(process.env.F3D_WAVEE_CASES);"
            "console.log(JSON.stringify("
            "cases.map(cs => S.evalRPN(cs.rpn, cs.env))));",
            payload=payload)
        self.assertEqual(len(got), len(cases))
        for (rpn, e), actual in zip(cases, got):
            self.assertAlmostEqual(
                actual, py_eval_rpn(rpn, e), delta=1e-9,
                msg="rpn=%r env=%r: node=%r python=%r"
                    % (rpn, e, actual, py_eval_rpn(rpn, e)))
        # The checker really does produce both 0 and c on this grid.
        checker_got = got[:8]
        self.assertIn(0.0, checker_got)
        self.assertTrue(any(abs(v - 0.6) <= 1e-9 for v in checker_got))

    @unittest.skipUnless(
        NODE, "SKIPPED: node not on PATH - f3d-skin.js checks not run")
    def test_js_skin_morph_and_skin_vs_python_reference(self):
        morph_cases = [
            {"verts": verts, "kind": kind, "factor": factor}
            for verts in (VERTS, CUBE_VERTS)
            for kind, factor in [("bulge", 0.5), ("bulge", -1.3),
                                 ("taper", 0.8), ("taper", -0.6),
                                 ("squash", 1.2), ("squash", -2.0)]
        ]
        got = run_node_json(
            SKIN_JS, "F3D_WAVEE_CASES", SKIN_PREAMBLE,
            "const cases = JSON.parse(process.env.F3D_WAVEE_CASES);"
            "console.log(JSON.stringify(cases.map(cs =>"
            "  S.morphApply(cs.verts, cs.kind, cs.factor))));",
            payload=morph_cases)
        for case, actual in zip(morph_cases, got):
            want = py_morph(case["verts"], case["kind"], case["factor"])
            self.assertEqual(len(actual), len(want))
            for a, b in zip(actual, want):
                self.assertAlmostEqual(a, b, delta=1e-9, msg=str(case))

        skin_cases = [
            {"verts": VERTS, "pivot": [1, 1, 0], "rot": [0, 0, 90],
             "radius": 2},
            {"verts": VERTS, "pivot": [0, 0, 0], "rot": [30, 45, 60],
             "radius": 4},
            {"verts": CUBE_VERTS, "pivot": [0, 0, 0], "rot": [0, 0, 20],
             "radius": 2.5},
            {"verts": CUBE_VERTS, "pivot": [1, 2, 3],
             "rot": [10, 20, 30], "radius": 3.5},
        ]
        got = run_node_json(
            SKIN_JS, "F3D_WAVEE_CASES", SKIN_PREAMBLE,
            "const cases = JSON.parse(process.env.F3D_WAVEE_CASES);"
            "console.log(JSON.stringify(cases.map(cs =>"
            "  S.skinApply(cs.verts, cs.pivot, cs.rot, cs.radius))));",
            payload=skin_cases)
        for case, actual in zip(skin_cases, got):
            want = py_skin_apply(case["verts"], case["pivot"],
                                 case["rot"], case["radius"])
            self.assertEqual(len(actual), len(want))
            for a, b in zip(actual, want):
                self.assertAlmostEqual(a, b, delta=1e-9, msg=str(case))

    @unittest.skipUnless(
        NODE, "SKIPPED: node not on PATH - f3d-skin.js checks not run")
    def test_js_skin_factor_zero_identity_exact(self):
        got = run_node_json(
            SKIN_JS, "F3D_WAVEE_CASES", SKIN_PREAMBLE,
            "const v = %s;"
            "const out = {};"
            "for (const kind of ['bulge','taper','squash']) {"
            "  const o = S.morphApply(v, kind, 0);"
            "  if (JSON.stringify(o) !== JSON.stringify(v))"
            "    throw new Error(kind + ' factor 0 is not identity');"
            "  out[kind] = o;"
            "}"
            "console.log(JSON.stringify(out));" % json.dumps(VERTS))
        for kind in ("bulge", "taper", "squash"):
            # Exact (==), not within a tolerance.
            self.assertEqual(got[kind], VERTS)
            self.assertEqual(py_morph(VERTS, kind, 0), VERTS)

    # -- 7. Determinism ---------------------------------------------------

    def test_determinism_byte_identical_scene_text(self):
        source = (
            CHECKER_SRC
            + 'shader half expr "0.5"\n'
            + "cube hero red at 0 0 0 size 2 shader checker\n"
            + "cube plain blue at 4 0 0 size 2\n"
            + "bone spine at 1,2,3 rotate 10,20,30 radius 3.5\n"
            + "morph hero bulge 0.5\n"
            + "skin hero spine\n")
        first = emit_fortran.emit_scene_text(compile_scene(source))
        second = emit_fortran.emit_scene_text(compile_scene(source))
        self.assertEqual(first, second)
        self.assertEqual(first.encode("utf-8"), second.encode("utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
