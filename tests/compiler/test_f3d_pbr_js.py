"""Forge3D Wave A seat B59: tests for the OPTIONAL PBR sidecar
``runtime/f3d-pbr.js`` (MeshStandard-style PBR + point/spot shading,
mirroring ``src/material_pbr.f90`` / ``src/lighting.f90``).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_pbr_js.py

The size/existence checks always run. The numeric checks shell out
to ``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest reports
them as skipped, with the reason, rather than passing silently).
"""

import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-pbr.js")
MAX_BYTES = 7680
NODE = shutil.which("node")

# Loaded before every snippet: expose `window` (as in a browser page
# that loads the sidecar after f3d.js) and bind the export as `P`.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_PBR, 'utf8'));"
    "const P = globalThis.F3DPBR;"
    "const assert = require('assert');"
    "const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_PBR=JS_PATH)
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


class TestF3DPbrFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-pbr.js is %d B, budget is %d B" % (size, MAX_BYTES),
        )


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-pbr.js numeric tests not run"
)
class TestF3DPbrNumeric(unittest.TestCase):
    def test_exports_and_default_material(self):
        run_node(
            "for (const k of ['attenuate','spotFactor','fresnelSchlick',"
            "'ggxD','specularBRDF','shadePoint','DEFAULT_MATERIAL'])"
            "  assert.ok(P[k] !== undefined, 'missing export ' + k);"
            "assert.strictEqual(window.F3DPBR, P);"
            "assert.deepStrictEqual(P.DEFAULT_MATERIAL,"
            "  {metalness:0, roughness:1, specular:0.5, shininess:32});"
        )

    def test_attenuate(self):
        run_node(
            # decay 2 at distance 1, no cutoff distance: exactly 1.
            "assert.strictEqual(P.attenuate(1, 0, 2), 1);"
            # decay 0 -> 1 at any distance.
            "assert.strictEqual(P.attenuate(7, 0, 0), 1);"
            # inverse-square falloff without a cutoff.
            "assert.ok(near(P.attenuate(10, 0, 2), 0.01, 1e-12));"
            # at and beyond the cutoff distance: exactly 0.
            "assert.strictEqual(P.attenuate(4, 4, 2), 0);"
            "assert.strictEqual(P.attenuate(5, 4, 2), 0);"
        )

    def test_fresnel_at_cos1_equals_f0(self):
        run_node(
            # At cos(theta) = 1 the (1-cos)**5 term vanishes: F == F0.
            "assert.ok(near(P.fresnelSchlick(1, 0.04), 0.04, 1e-12));"
            "assert.deepStrictEqual("
            "  P.fresnelSchlick(1, [0.04, 0.04, 0.04]),"
            "  [0.04, 0.04, 0.04]);"
            # F0 = mix(0.04, baseColor, metalness): pure metal red.
            "assert.deepStrictEqual(P.fresnelSchlick(1, [1, 0, 0], 1),"
            "  [1, 0, 0]);"
            # At cos(theta) = 0 everything reflects: F == 1.
            "assert.ok(near(P.fresnelSchlick(0, 0.04), 1, 1e-12));"
        )

    def test_ggx_and_spot_factor(self):
        run_node(
            # roughness 1 -> alpha 1 -> D(ndoth=1) = 1/pi.
            "assert.ok(near(P.ggxD(1, 1), 1 / Math.PI, 1e-12));"
            # roughness is clamped to >= 0.05, so ggxD stays finite.
            "assert.ok(Number.isFinite(P.ggxD(1, 0)));"
            # Spot cone (Fortran spot_factor: smoothstep on the
            # ANGLE IN DEGREES): on axis -> 1, outside -> 0.
            "assert.strictEqual(P.spotFactor(1, 30, 0.5), 1);"
            "assert.strictEqual(P.spotFactor("
            "  Math.cos(40 * Math.PI / 180), 30, 0.5), 0);"
            # Exact angle-space penumbra value: outer 30 deg,
            # penumbra 0.5 -> inner 15 deg; a fragment at 22.5 deg
            # gives t = (30 - 22.5) / (30 - 15) = 0.5 and the
            # smoothstep t*t*(3-2t) = 0.5 exactly. (The old
            # cos-space smoothstep gave ~0.618 here, so this
            # assertion pins the Fortran angle-space behaviour.)
            "const mid = P.spotFactor("
            "  Math.cos(22.5 * Math.PI / 180), 30, 0.5);"
            "assert.ok(near(mid, 0.5, 1e-9), 'penumbra mid=' + mid);"
            # Cone boundaries: at the inner angle -> 1, at the
            # outer angle -> 0; a non-positive outer angle -> 0.
            "assert.ok(near(P.spotFactor("
            "  Math.cos(15 * Math.PI / 180), 30, 0.5), 1, 1e-9));"
            "assert.ok(near(P.spotFactor("
            "  Math.cos(30 * Math.PI / 180), 30, 0.5), 0, 1e-9));"
            "assert.strictEqual(P.spotFactor(1, 0, 0.5), 0);"
            # Fortran edge case: a spot light with a ZERO spot_dir
            # contributes nothing -- shadePoint keeps only ambient
            # (default 0.25 * base 100 = 25 per channel).
            "assert.deepStrictEqual(P.shadePoint({"
            "  base: [100, 100, 100], normal: [0, 0, 1],"
            "  worldPos: [0, 0, 0], camPos: [5, 0, 0],"
            "  lights: [{kind: 'spot', pos: [0, 0, 2],"
            "    spotDir: [0, 0, 0], angleDeg: 30, penumbra: 0.5,"
            "    color: [255, 255, 255], intensity: 1, decay: 0}]}),"
            "  [25, 25, 25]);"
        )

    def test_shade_point_lambert_equivalence(self):
        # Stated geometry: base [220,60,60], surface at the origin
        # with normal [0,0,1]; one white directional light with
        # dir [0,0,-1] (travelling -z), so L = [0,0,1] and
        # diffuse = dot(normal, L) = 1. Camera at [5,0,0], so
        # viewDir = [1,0,0]: ndotv = 0 makes the Smith G term 0,
        # hence the PBR specular contributes exactly 0 and the
        # result must reduce to the Fortran legacy Lambert shade
        # int(base * (0.25 + 0.75 * diffuse)) with ambient 0.25.
        run_node(
            "const base = [220, 60, 60];"
            "const out = P.shadePoint({base, normal: [0, 0, 1],"
            "  worldPos: [0, 0, 0], camPos: [5, 0, 0], ambient: 0.25,"
            "  lights: [{kind: 'directional', dir: [0, 0, -1],"
            "    color: [255, 255, 255], intensity: 1}]});"
            "const diffuse = 1;"
            "base.forEach((b, i) => {"
            "  const legacy = Math.trunc(b * (0.25 + 0.75 * diffuse));"
            "  assert.ok(Math.abs(out[i] - legacy) <= 1,"
            "    'channel ' + i + ': got ' + out[i]"
            "    + ', legacy ' + legacy);});"
            # Shadow 0 leaves only the ambient term: base * 0.25.
            "const sh = P.shadePoint({base, normal: [0, 0, 1],"
            "  worldPos: [0, 0, 0], camPos: [5, 0, 0], ambient: 0.25,"
            "  shadow: 0, lights: [{kind: 'directional',"
            "    dir: [0, 0, -1]}]});"
            "base.forEach((b, i) => assert.ok("
            "  Math.abs(sh[i] - Math.round(b * 0.25)) <= 1));"
        )

    def test_metal_red_specular_is_red_dominant(self):
        run_node(
            # Metalness 1 -> F0 = base colour, so a red metal's
            # specular reflection is red-dominant (r > g, g == b).
            "const s = P.specularBRDF([0, 0, 1], [0, 0, 1], [0, 0, 1],"
            "  {metalness: 1, roughness: 0.5, specular: 0.5,"
            "   shininess: 32}, [1, 0, 0]);"
            "assert.ok(s[0] > s[1], 'spec=' + s);"
            "assert.ok(near(s[1], s[2], 1e-12), 'spec=' + s);"
            "assert.ok(s[0] > 0, 'spec=' + s);"
            # Back-facing light gives no specular at all.
            "assert.deepStrictEqual(P.specularBRDF([0, 0, 1],"
            "  [0, 0, 1], [0, 0, -1], {metalness: 1}, [1, 0, 0]),"
            "  [0, 0, 0]);"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
