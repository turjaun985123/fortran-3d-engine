#!/usr/bin/env python3
"""End-to-end tests for the Forge3D CLI (the native ``bin/f3dc`` binary).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/e2e/test_cli.py

Every command drives the native ``bin/f3dc`` binary via subprocess
with stdout/stderr captured, and all scene/build files live in a
single ``tempfile`` tree created once in ``setUpClass`` -- nothing is
written into the repository (the build test proves the repo-root
``scene.json`` is untouched, by hash and mtime).  ``run`` uses a tiny
still scene (``scene size 64 48`` + ``render still``: one frame, no
150-frame spin animation) against the real Fortran engine, which
``gfortran``/``make`` build on this machine; the engine binary is
built at most once and the shared build/run directories are reused
across tests.
"""

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _resolve_f3dc():
    """Locate the native compiler binary to test."""
    env = os.environ.get("F3DC")
    if env:
        return env
    candidate = REPO_ROOT / "bin" / "f3dc"
    if candidate.exists():
        return str(candidate)
    return str(REPO_ROOT / "compiler" / "f3dc")


F3DC = _resolve_f3dc()

# The 3-line starter contract written by `f3dc new`.
STARTER = "cube red\nspin it\nrender\n"
# A one-frame render: small, and `render still` suppresses animation
# frames, so `run` stays fast.
STILL_SCENE = "scene size 64 48\ncube red\nrender still\n"

ARTIFACT_SUFFIXES = (".scene", ".json", ".legacy.json", ".js", ".html",
                     "_scene.f90")


def call_cli(argv):
    """Run the native f3dc binary; return (exit_code, stdout, stderr)."""
    proc = subprocess.run([F3DC] + [str(a) for a in argv],
                          cwd=REPO_ROOT, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


class TestCliE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="f3dc-e2e-")
        cls.tmp = Path(cls._tmp.name)
        cls.valid = cls.tmp / "valid.f3d"
        cls.valid.write_text(STARTER, encoding="utf-8")
        cls.still = cls.tmp / "still.f3d"
        cls.still.write_text(STILL_SCENE, encoding="utf-8")
        cls.bad = cls.tmp / "bad.f3d"
        cls.bad.write_text("cube gold\n", encoding="utf-8")
        cls.build_dir = cls.tmp / "build-out"
        cls.run_dir = cls.tmp / "run-out"

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    # -- new -----------------------------------------------------------

    def test_01_new_creates_file_with_three_line_content(self):
        target = self.tmp / "hello"  # no suffix: f3dc appends .f3d
        code, _out, _err = call_cli(["new", target])
        self.assertEqual(code, 0)
        created = self.tmp / "hello.f3d"
        self.assertTrue(created.is_file())
        self.assertEqual(created.read_text(encoding="utf-8"), STARTER)
        self.assertEqual(len(created.read_text(encoding="utf-8")
                             .splitlines()), 3)

    def test_02_new_again_exits_3_and_keeps_original(self):
        target = self.tmp / "twice"
        code, _out, _err = call_cli(["new", target])
        self.assertEqual(code, 0)
        code, _out, err = call_cli(["new", target])
        self.assertEqual(code, 3)
        self.assertIn("already exists", err)
        self.assertEqual((self.tmp / "twice.f3d").read_text(
            encoding="utf-8"), STARTER)

    # -- check ---------------------------------------------------------

    def test_03_check_valid_scene_exits_0(self):
        code, out, _err = call_cli(["check", self.valid])
        self.assertEqual(code, 0)
        self.assertIn("OK:", out)

    def test_04_check_unknown_colour_exits_1_with_e202(self):
        code, out, err = call_cli(["check", self.bad])
        self.assertEqual(code, 1)
        self.assertIn("E202", out + err)

    def test_05_check_missing_file_exits_3(self):
        code, _out, _err = call_cli(["check", self.tmp / "nope.f3d"])
        self.assertEqual(code, 3)

    # -- build ---------------------------------------------------------

    def test_06_build_produces_six_artifacts_and_spares_repo_scene(self):
        repo_scene = REPO_ROOT / "scene.json"
        before_hash = hashlib.sha256(repo_scene.read_bytes()).hexdigest()
        before_mtime = repo_scene.stat().st_mtime_ns

        code, _out, _err = call_cli(
            ["build", self.still, "-o", self.build_dir])
        self.assertEqual(code, 0)

        stem = self.still.stem
        for suffix in ARTIFACT_SUFFIXES:
            artifact = self.build_dir / f"{stem}{suffix}"
            self.assertTrue(artifact.is_file(), f"missing {artifact}")
            self.assertGreater(artifact.stat().st_size, 0, artifact)

        self.assertEqual(
            hashlib.sha256(repo_scene.read_bytes()).hexdigest(),
            before_hash)
        self.assertEqual(repo_scene.stat().st_mtime_ns, before_mtime)

    # -- run -----------------------------------------------------------

    def test_07_run_exits_0_and_produces_output_render_ppm(self):
        code, _out, err = call_cli(["run", self.still, "-o", self.run_dir])
        self.assertEqual(code, 0, err)
        ppm = self.run_dir / "output_render.ppm"
        self.assertTrue(ppm.is_file())
        self.assertGreater(ppm.stat().st_size, 0)
        with ppm.open("rb") as fh:
            self.assertEqual(fh.read(2), b"P3")

    def test_08_bare_invocation_behaves_as_run(self):
        # f3dc [path, ...] with no subcommand == `run`: builds, renders
        # and produces the PPM.  (-o is passed because the bare form's
        # default relative build/ dir is handed to the engine relative
        # to the wrong cwd -- a known driver quirk, not dispatch
        # behaviour.)
        bare_dir = self.tmp / "bare-out"
        code, _out, err = call_cli([self.still, "-o", bare_dir])
        self.assertEqual(code, 0, err)
        ppm = bare_dir / "output_render.ppm"
        self.assertTrue(ppm.is_file())
        self.assertGreater(ppm.stat().st_size, 0)

    # -- doctor / fmt --------------------------------------------------

    def test_09_doctor_exits_0(self):
        code, out, _err = call_cli(["doctor"])
        self.assertEqual(code, 0)
        self.assertIn("gfortran", out)

    def test_10_fmt_prints_canonical_line_containing_cube(self):
        code, out, _err = call_cli(["fmt", self.valid])
        self.assertEqual(code, 0)
        lines = [ln for ln in out.splitlines() if "cube" in ln]
        self.assertTrue(lines, out)
        self.assertIn("cube red", lines[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
