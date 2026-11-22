"""Forge3D Wave B seat B95: tests for the keyframe sidecar
``runtime/f3d-keys.js`` (JS mirror of ``src/keyframe.f90`` key_eval).

Stdlib ``unittest`` only, standalone-runnable::

    python3 tests/compiler/test_f3d_keys_js.py

The existence check always runs. The numeric checks shell out to
``node -e`` snippets that load the sidecar; when ``node`` is not
on PATH they are SKIPPED LOUDLY via ``skipUnless`` (unittest reports
them as skipped, with the reason, rather than passing silently).

Every expected pose is RECOMPUTED IN PYTHON below (``ref_eval`` is
an independent Python implementation of the frozen key_eval
semantics) and compared against the JS result with tolerance
1e-12; the headline numbers (midpoint (2, 1, 0), smooth factor
0.15625, rot mid 45, scale mid 1.5) are also asserted directly in
Python so the reference itself is pinned.
"""

import json
import os
import shutil
import subprocess
import unittest

REPO = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir
)
JS_PATH = os.path.join(REPO, "runtime", "f3d-keys.js")
NODE = shutil.which("node")
TOL = 1e-12

# Loaded before every snippet: expose `window` (as in a browser page
# that loads the sidecar after f3d.js) and bind the export as `K`.
PREAMBLE = (
    "global.window = globalThis;"
    "eval(require('fs').readFileSync(process.env.F3D_KEYS, 'utf8'));"
    "const K = globalThis.F3DKeys;"
    "const assert = require('assert');"
    "const near = (a, b) => Math.abs(a - b) <= 1e-12;"
    "const checkPose = (got, exp) => {"
    "  for (let j = 0; j < 3; j++) {"
    "    assert.ok(near(got.pos[j], exp.pos[j]),"
    "      'pos[' + j + '] got ' + got.pos[j] + ' want ' + exp.pos[j]);"
    "    assert.ok(near(got.rot[j], exp.rot[j]),"
    "      'rot[' + j + '] got ' + got.rot[j] + ' want ' + exp.rot[j]); }"
    "  assert.ok(near(got.scale, exp.scale),"
    "    'scale got ' + got.scale + ' want ' + exp.scale); };"
)


def run_node(snippet):
    """Run one node -e snippet against the sidecar; fail on error."""
    env = dict(os.environ, F3D_KEYS=JS_PATH)
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


def check_track(track, t, expected):
    """Assert JS evalTrack(track, t) == expected (Python-computed)."""
    run_node(
        "checkPose(K.evalTrack(%s, %s), %s);"
        % (json.dumps(track), json.dumps(t), json.dumps(expected))
    )


# ------------------------------------------------------------------
# Independent Python recomputation of the frozen key_eval semantics.
# ------------------------------------------------------------------

def ref_ease(name, p):
    u = max(0.0, min(1.0, p))
    if name == "smooth":
        return u * u * (3.0 - 2.0 * u)
    if name == "in":
        return u * u
    if name == "out":
        return 1.0 - (1.0 - u) ** 2
    return u  # 'linear' and anything unknown


def _pose(key):
    return {
        "pos": [float(c) for c in key["pos"]],
        "rot": [float(c) for c in key["rot"]],
        "scale": float(key["scale"]),
    }


def ref_eval(track, t):
    keys = track.get("keys") or []
    if not keys:
        return {"pos": [0.0, 0.0, 0.0], "rot": [0.0, 0.0, 0.0],
                "scale": 1.0}
    first, last = keys[0], keys[-1]
    duration = track.get("duration") or 0
    d = duration if duration > 0 else last["time"]
    if d <= 0:
        return _pose(first)
    loop = track.get("loop")
    if loop == "forever":
        te = max(t, 0.0) % d
    elif loop == "pingpong":
        cyc = max(t, 0.0) % (2.0 * d)
        te = cyc if cyc <= d else 2.0 * d - cyc
    else:  # 'once' and anything unknown
        te = max(0.0, min(t, d))
    if te <= first["time"]:
        return _pose(first)
    if te >= last["time"]:
        return _pose(last)
    for i in range(len(keys) - 1):
        a, b = keys[i], keys[i + 1]
        if te > b["time"] and i < len(keys) - 2:
            continue
        span = b["time"] - a["time"]
        p = 0.0 if span == 0 else (te - a["time"]) / span
        e = ref_ease(b.get("ease"), p)
        pa, pb = _pose(a), _pose(b)
        return {
            "pos": [pa["pos"][j] + (pb["pos"][j] - pa["pos"][j]) * e
                    for j in range(3)],
            "rot": [pa["rot"][j] + (pb["rot"][j] - pa["rot"][j]) * e
                    for j in range(3)],
            "scale": pa["scale"] + (pb["scale"] - pa["scale"]) * e,
        }
    return _pose(last)


def two_key_track(loop="once", ease_name="linear", duration=2,
                  t0=0, t1=2):
    """The Fortran seat's base track: (0,0,0)/rot 0/scale 1 at t0 to
    (4,2,0)/rot (0,90,0)/scale 2 at t1."""
    return {
        "target": "cube", "duration": duration, "loop": loop,
        "keys": [
            {"time": t0, "pos": [0, 0, 0], "rot": [0, 0, 0],
             "scale": 1, "ease": "linear"},
            {"time": t1, "pos": [4, 2, 0], "rot": [0, 90, 0],
             "scale": 2, "ease": ease_name},
        ],
    }


class TestF3DKeysFile(unittest.TestCase):
    def test_file_exists(self):
        self.assertTrue(os.path.isfile(JS_PATH), JS_PATH)


@unittest.skipUnless(
    NODE, "SKIPPED: node not on PATH - f3d-keys.js numeric tests not run"
)
class TestF3DKeysNumeric(unittest.TestCase):
    def test_exports(self):
        run_node(
            "for (const k of ['ease', 'evalTrack'])"
            "  assert.strictEqual(typeof K[k], 'function',"
            "    'missing export ' + k);"
            "assert.strictEqual(window.F3DKeys, K);"
        )

    def test_ease_values(self):
        # Factors recomputed in Python; smooth at p=0.25 is the
        # pinned headline value 0.15625.
        self.assertAlmostEqual(ref_ease("smooth", 0.25), 0.15625,
                               delta=TOL)
        for name in ("linear", "smooth", "in", "out", "bogus", None):
            for p in (-0.5, 0.0, 0.25, 0.5, 0.75, 1.0, 1.5):
                run_node(
                    "assert.ok(near(K.ease(%s, %s), %s),"
                    "  'ease ' + %s + ' @ ' + %s);"
                    % (json.dumps(name), json.dumps(p),
                       json.dumps(ref_ease(name, p)),
                       json.dumps(name), json.dumps(p))
                )

    def test_two_key_linear_midpoint(self):
        track = two_key_track()
        expected = ref_eval(track, 1)
        # Pinned headline: midpoint pos is exactly (2, 1, 0).
        self.assertEqual(expected["pos"], [2.0, 1.0, 0.0])
        check_track(track, 1, expected)

    def test_smooth_segment_uses_destination_key_ease(self):
        track = two_key_track(ease_name="smooth")
        expected = ref_eval(track, 0.5)  # p = 0.25, factor 0.15625
        self.assertAlmostEqual(expected["pos"][0], 4 * 0.15625,
                               delta=TOL)
        self.assertAlmostEqual(expected["pos"][1], 2 * 0.15625,
                               delta=TOL)
        check_track(track, 0.5, expected)

    def test_rot_midpoint_is_45(self):
        track = two_key_track()
        expected = ref_eval(track, 1)
        self.assertEqual(expected["rot"], [0.0, 45.0, 0.0])
        check_track(track, 1, expected)

    def test_scale_midpoint_is_1_5(self):
        track = two_key_track()
        expected = ref_eval(track, 1)
        self.assertEqual(expected["scale"], 1.5)
        check_track(track, 1, expected)

    def test_once_clamps_past_end(self):
        track = two_key_track(loop="once")
        expected = ref_eval(track, 5)
        self.assertEqual(expected, _pose(track["keys"][-1]))
        check_track(track, 5, expected)
        # 'once' also clamps negative t to the first pose.
        check_track(track, -3, ref_eval(track, -3))

    def test_forever_wraps_to_midpoint(self):
        track = two_key_track(loop="forever")  # D = 2
        expected = ref_eval(track, 3)  # te = mod(3, 2) = 1: midpoint
        self.assertEqual(expected["pos"], [2.0, 1.0, 0.0])
        check_track(track, 3, expected)

    def test_pingpong_midpoint_on_the_way_back(self):
        track = two_key_track(loop="pingpong")  # D = 2
        expected = ref_eval(track, 3)  # cyc 3 > D -> te = 4-3 = 1
        self.assertEqual(expected["pos"], [2.0, 1.0, 0.0])
        check_track(track, 3, expected)

    def test_pingpong_at_duration_is_the_end_pose(self):
        track = two_key_track(loop="pingpong")
        expected = ref_eval(track, 2)  # cyc 2 <= D -> te = 2: end
        self.assertEqual(expected, _pose(track["keys"][-1]))
        check_track(track, 2, expected)

    def test_empty_track_is_identity(self):
        track = {"target": "cube", "duration": 2, "loop": "once",
                 "keys": []}
        expected = ref_eval(track, 1)
        self.assertEqual(expected, {"pos": [0.0, 0.0, 0.0],
                                    "rot": [0.0, 0.0, 0.0],
                                    "scale": 1.0})
        check_track(track, 1, expected)

    def test_before_first_key_gives_first_pose(self):
        track = two_key_track(t0=1, t1=3)
        # First key sits at time 1 with the base pose shifted so the
        # first pose is distinguishable from the identity pose.
        track["keys"][0].update(
            {"pos": [1, 2, 3], "rot": [10, 20, 30], "scale": 0.5})
        expected = ref_eval(track, 0)
        self.assertEqual(expected, _pose(track["keys"][0]))
        check_track(track, 0, expected)
        check_track(track, 0.5, ref_eval(track, 0.5))

    def test_duration_fallback_and_nonpositive_duration(self):
        # duration <= 0 in the track -> D falls back to the last
        # key time (2 here), so t=1 is still the midpoint.
        track = two_key_track(duration=0)
        expected = ref_eval(track, 1)
        self.assertEqual(expected["pos"], [2.0, 1.0, 0.0])
        check_track(track, 1, expected)
        # Last key time <= 0 too -> D <= 0 -> first key pose.
        flat = two_key_track(duration=0, t0=0, t1=0)
        check_track(flat, 1, ref_eval(flat, 1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
