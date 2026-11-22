"""Forge3D Wave B seat B72: tests for the deterministic particle
sidecar ``runtime/f3d-particles.js`` (MASTER-PLAN row 32), the JS
mirror of ``src/particles.f90``.

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_particles_js.py

The size/existence checks always run. The numeric checks shell out
to ``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest reports
them as skipped, with the reason, rather than passing silently).

The expected hash values are derived in Python directly from the
frozen contract recipe (exact integer arithmetic), never copied from
the JS output, so the two implementations cross-check each other.
"""

import math
import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-particles.js")
MAX_BYTES = 7680
NODE = shutil.which("node")
MOD = 2147483648  # 2^31

# Loaded before every snippet: expose `window` (as in a browser page
# that loads the sidecar after f3d.js) and bind the export as `P`.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_PARTICLES, 'utf8'));"
    "const P = globalThis.F3DParticles;"
    "const assert = require('assert');"
    "const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);"
)

# One shared system descriptor (JSON-compatible), used by several
# tests; the Python mirror below computes its states independently.
SYS = {
    "origin": [1.0, 2.0, 3.0], "count": 10, "life": 2.0, "speed": 3.0,
    "size": 0.5, "spread": 0.5, "gravity": 4.0, "seed": 7,
    "color": [255, 128, 0],
}
SYS_JS = (
    "{origin:[1,2,3],count:10,life:2,speed:3,size:0.5,spread:0.5,"
    "gravity:4,seed:7,color:[255,128,0]}"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_PARTICLES=JS_PATH)
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


def hash01_py(seed, i, k):
    """The frozen contract recipe, in exact Python integers."""
    x = (seed * 1103515245 + i * 12345 + k * 67890) % MOD
    x = (x * 1103515245 + 12345) % MOD
    return x / MOD


def state_py(sys_, i, t):
    """The frozen contract state formula, computed in Python."""
    life = sys_["life"]
    count = sys_["count"]
    speed = sys_["speed"]
    spread = sys_.get("spread", 0.5)
    gravity = sys_.get("gravity", 0)
    seed = sys_.get("seed", 1)
    age = ((t + i * (life / count)) % life + life) % life
    h0 = hash01_py(seed, i, 0)
    h1 = hash01_py(seed, i, 1)
    h2 = hash01_py(seed, i, 2)
    vel = [
        (h0 - 0.5) * 2 * spread * speed,
        speed * (0.5 + 0.5 * h1),
        (h2 - 0.5) * 2 * spread * speed,
    ]
    pos = [
        sys_["origin"][0] + vel[0] * age,
        sys_["origin"][1] + vel[1] * age - 0.5 * gravity * age * age,
        sys_["origin"][2] + vel[2] * age,
    ]
    return pos, 1 - age / life


class TestF3DParticlesFile(unittest.TestCase):
    def test_file_exists_and_within_size_budget(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)
        size = os.path.getsize(JS_PATH)
        self.assertLessEqual(
            size, MAX_BYTES,
            "f3d-particles.js is %d B, budget is %d B" % (size, MAX_BYTES),
        )


@unittest.skipUnless(
    NODE,
    "SKIPPED: node not on PATH - f3d-particles.js numeric tests not run",
)
class TestF3DParticlesNumeric(unittest.TestCase):
    def test_exports(self):
        run_node(
            "for (const k of ['hash01','state','positions','quad'])"
            "  assert.ok(P[k] !== undefined, 'missing export ' + k);"
            "assert.strictEqual(window.F3DParticles, P);"
        )

    def test_hash01_matches_contract_recipe(self):
        # Both sides derive from the same integers and the value is
        # the rational x / 2^31, so they must agree to 1e-15 (the JS
        # side computes the second multiply exactly, in split parts,
        # because x * 1103515245 overflows the 2^53 exact range).
        cases = [(1, 0, 0), (1, 0, 1), (1, 0, 2), (0, 0, 0),
                 (42, 7, 1), (7, 3, 2), (100000, 999, 2)]
        checks = "".join(
            "assert.ok(near(P.hash01(%d, %d, %d), %.17g, 1e-15),"
            "  'hash01(%d,%d,%d)=' + P.hash01(%d, %d, %d));"
            % (s, i, k, hash01_py(s, i, k), s, i, k, s, i, k)
            for (s, i, k) in cases
        )
        run_node(
            checks
            + "for (let n = 0; n < 50; n++) {"
              "  const u = P.hash01(3, n, n % 3);"
              "  assert.ok(u >= 0 && u < 1, 'range: ' + u); }"
        )

    def test_state_at_t0_i0_is_origin_full_scale(self):
        run_node(
            "const st = P.state(%s, 0, 0);"
            "assert.deepStrictEqual(st.pos, [1, 2, 3]);"
            "assert.strictEqual(st.scale, 1);" % SYS_JS
        )

    def test_state_matches_python_contract(self):
        pos, scale = state_py(SYS, 3, 0.7)
        run_node(
            "const st = P.state(%s, 3, 0.7);"
            "st.pos.forEach((v, j) => assert.ok("
            "  near(v, [%r, %r, %r][j], 1e-9),"
            "  'pos[' + j + ']=' + v));"
            "assert.ok(near(st.scale, %r, 1e-9), 'scale=' + st.scale);"
            % (SYS_JS, pos[0], pos[1], pos[2], scale)
        )

    def test_defaults_spread_gravity_seed(self):
        # Omitting spread / gravity / seed must behave exactly like
        # the frozen defaults spread 0.5, gravity 0, seed 1.
        run_node(
            "const bare = {origin:[0,0,0],count:4,life:1.5,speed:2,"
            "  size:1,color:[9,9,9]};"
            "const full = {origin:[0,0,0],count:4,life:1.5,speed:2,"
            "  size:1,spread:0.5,gravity:0,seed:1,color:[9,9,9]};"
            "assert.deepStrictEqual(P.state(bare, 2, 0.4),"
            "  P.state(full, 2, 0.4));"
            "assert.deepStrictEqual(P.positions(bare, 0.4),"
            "  P.positions(full, 0.4));"
        )

    def test_determinism(self):
        run_node(
            "assert.deepStrictEqual(P.state(%s, 5, 1.25),"
            "  P.state(%s, 5, 1.25));"
            "assert.deepStrictEqual(P.positions(%s, 1.25),"
            "  P.positions(%s, 1.25));"
            "assert.deepStrictEqual(P.quad(%s, 5, 1.25, [4, 5, 6]),"
            "  P.quad(%s, 5, 1.25, [4, 5, 6]));"
            % (SYS_JS, SYS_JS, SYS_JS, SYS_JS, SYS_JS, SYS_JS)
        )

    def test_positions_count(self):
        run_node(
            "const all = P.positions(%s, 0.3);"
            "assert.strictEqual(all.length, 10);"
            "all.forEach((st, i) => assert.deepStrictEqual(st,"
            "  P.state(%s, i, 0.3)));"
            "assert.deepStrictEqual(P.positions({origin:[0,0,0],"
            "  count:0,life:1,speed:1,size:1}, 0.3), []);"
            % (SYS_JS, SYS_JS)
        )

    def test_quad_corner_distance(self):
        # Every corner sits size*scale*sqrt(2)/2 from the particle
        # centre, and adjacent corners are exactly size*scale apart.
        pos, scale = state_py(SYS, 2, 0.9)
        want = SYS["size"] * scale * math.sqrt(2) / 2
        run_node(
            "const sys = %s;"
            "const st = P.state(sys, 2, 0.9);"
            "const q = P.quad(sys, 2, 0.9, [10, 3, -4]);"
            "assert.strictEqual(q.length, 4);"
            "q.forEach((c) => {"
            "  const d = Math.hypot(c[0]-st.pos[0], c[1]-st.pos[1],"
            "    c[2]-st.pos[2]);"
            "  assert.ok(near(d, %r, 1e-9), 'corner dist=' + d); });"
            "for (let j = 0; j < 4; j++) {"
            "  const a = q[j], b = q[(j + 1) %% 4];"
            "  const e = Math.hypot(a[0]-b[0], a[1]-b[1], a[2]-b[2]);"
            "  assert.ok(near(e, %r, 1e-9), 'edge=' + e); }"
            # Camera looking straight down -y at the particle: the
            # |dot| > 0.999 up-hint switch must still give a finite,
            # correctly-sized quad.
            "const q2 = P.quad(sys, 2, 0.9,"
            "  [st.pos[0], st.pos[1] + 5, st.pos[2]]);"
            "q2.forEach((c) => {"
            "  const d = Math.hypot(c[0]-st.pos[0], c[1]-st.pos[1],"
            "    c[2]-st.pos[2]);"
            "  assert.ok(near(d, %r, 1e-9), 'down-view dist=' + d); });"
            % (SYS_JS, want, SYS["size"] * scale, want)
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
