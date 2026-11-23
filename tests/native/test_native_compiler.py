#!/usr/bin/env python3
"""Black-box tests for the NATIVE Forge3D compiler (bin/f3dc).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/native/test_native_compiler.py

These tests replace the old in-process Python-compiler unit suites
(tests/compiler/test_*.py, deleted with tools/f3dc in the 2026-11-23
replacement).  They never import compiler internals: every check goes
through the ``bin/f3dc`` binary as a subprocess.

Coverage:

* ``TestCorpus`` -- the 896 scene inputs extracted from the old test
  files' string constants (the compiler/PARITY.md sweep-1 corpus).
  Expectations (exit code, stdout/stderr SHA-256, diagnostic codes,
  and for the 91 valid inputs every build artifact's SHA-256) were
  baked from the Python oracle into ``corpus.json`` before its
  deletion; the 4 inputs where the oracle itself crashed (exit 70,
  E9000) carry expectations baked from the native compiler's proper
  diagnostics instead and are flagged ``oracle_crash``.
* ``TestExamples`` -- every ``examples/*.f3d``: ``check`` output and
  all ``build`` artifact hashes (``examples.json``).
* ``TestCliBattery`` -- the CLI surface: --version/--help/subcommand
  helps, unknown command, no-args, check in text/--json/--explain
  forms, fmt, build, new (``cli_battery.json``).  ``doctor`` is
  asserted loosely (exit 0 + structure) because its text names the
  locally found tool versions.
* ``TestPreview`` -- the native preview server: page, /__version,
  edit -> version bump, broken scene -> error state, fix -> recovery
  (the 5 core checks of the old tests/compiler/test_preview.py).
* ``TestDeterminism`` -- hello-cube builds byte-identically twice.

The binary under test: ``$F3DC`` if set, else ``bin/f3dc``, else
``compiler/f3dc`` (all relative to the repo root).
"""

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = Path(__file__).resolve().parent


def _find_f3dc():
    env = os.environ.get("F3DC")
    if env:
        return Path(env)
    for cand in (REPO_ROOT / "bin" / "f3dc", REPO_ROOT / "compiler" / "f3dc"):
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand
    return REPO_ROOT / "bin" / "f3dc"


F3DC = _find_f3dc()
CODE_RE = re.compile(rb"[EW][0-9]{3}")
_SHA_RE = re.compile(rb"sha256: [0-9a-f]{64}")


def canon(data: bytes) -> bytes:
    """Machine-independence canonicalization for the examples layer
    (identical to the one used when examples.json was baked): the
    repo-root absolute path becomes <REPO> and embedded
    ``sha256: <hex>`` header lines become ``sha256: <EMBEDDED>`` --
    those hashes cover content that contains the machine's path."""
    return _SHA_RE.sub(b"sha256: <EMBEDDED>",
                       data.replace(str(REPO_ROOT).encode(), b"<REPO>"))


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def run_f3dc(argv, cwd, timeout=120):
    proc = subprocess.run([str(F3DC), *[str(a) for a in argv]],
                          cwd=str(cwd), capture_output=True, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


def check_capture(case, rc, out, err, label):
    """Compare one (rc, stdout, stderr) against a baked capture dict."""
    exp = case
    problems = []
    if rc != exp["exit"]:
        problems.append(f"exit {rc} != baked {exp['exit']}")
    if sha(out) != exp["stdout_sha256"]:
        problems.append("stdout sha256 differs")
    if sha(err) != exp["stderr_sha256"]:
        problems.append("stderr sha256 differs")
    codes = [c.decode() for c in CODE_RE.findall(err)]
    if codes != exp["codes"]:
        problems.append(f"diagnostic codes {codes} != baked {exp['codes']}")
    if problems:
        detail = "; ".join(problems)
        if exp.get("stderr_text"):
            detail += f"\n  baked stderr: {exp['stderr_text'][:600]!r}"
        detail += f"\n  actual stderr: {err[:600]!r}"
        raise AssertionError(f"{label}: {detail}")


def load_json(name):
    return json.loads((DATA_DIR / name).read_text(encoding="utf-8"))


@unittest.skipUnless(F3DC.is_file(), f"native compiler not built: {F3DC}")
class TestCorpus(unittest.TestCase):
    """896 baked scene inputs through `f3dc check` (+ `build`)."""

    @classmethod
    def setUpClass(cls):
        cls.data = load_json("corpus.json")

    def test_corpus(self):
        cases = self.data["cases"]
        self.assertEqual(len(cases), self.data["kept"])
        failures = []
        with tempfile.TemporaryDirectory(prefix="f3dc-corpus-") as tmp:
            work = Path(tmp)
            scene = work / "scene.f3d"
            for idx, case in enumerate(cases):
                scene.write_bytes(case["src"].encode("utf-8"))
                try:
                    rc, out, err = run_f3dc(["check", "scene.f3d"], work)
                    check_capture(case["check"], rc, out, err,
                                  f"corpus[{idx}] check")
                    if "build" in case:
                        outdir = work / "out"
                        if outdir.exists():
                            shutil.rmtree(outdir)
                        brc, bout, berr = run_f3dc(
                            ["build", "-o", "out", "scene.f3d"], work)
                        if brc != 0:
                            raise AssertionError(
                                f"corpus[{idx}] build exit {brc}: {berr[:300]!r}")
                        got = {}
                        for p in sorted(outdir.rglob("*")):
                            if p.is_file():
                                got[str(p.relative_to(outdir))] = sha(p.read_bytes())
                        if got != case["build"]["artifacts"]:
                            raise AssertionError(
                                f"corpus[{idx}] build artifacts differ: "
                                f"got {sorted(got)} baked "
                                f"{sorted(case['build']['artifacts'])} "
                                f"(hash mismatches: "
                                f"{[k for k in got if k in case['build']['artifacts'] and got[k] != case['build']['artifacts'][k]]})")
                except AssertionError as exc:
                    failures.append(str(exc))
        if failures:
            shown = "\n".join(failures[:10])
            self.fail(f"{len(failures)}/{len(cases)} corpus cases failed:\n{shown}")


@unittest.skipUnless(F3DC.is_file(), f"native compiler not built: {F3DC}")
class TestExamples(unittest.TestCase):
    """examples/*.f3d: check output + build artifact hashes."""

    @classmethod
    def setUpClass(cls):
        cls.data = load_json("examples.json")

    def test_examples(self):
        # Absolute scene paths (the parity-sweep discipline): under a
        # relative path the documented register-11 divergence appears
        # (Python abspaths relative texture paths; native joins them
        # to the scene dir as written).  Captures and artifacts are
        # compared after canon(), exactly as baked.
        with tempfile.TemporaryDirectory(prefix="f3dc-examples-") as tmp:
            outbase = Path(tmp)
            for name, scene in self.data["scenes"].items():
                abspath = str(REPO_ROOT / "examples" / name)
                with self.subTest(example=name):
                    rc, out, err = run_f3dc(["check", abspath], REPO_ROOT)
                    check_capture(scene["check"], rc, canon(out), canon(err),
                                  f"example {name} check")
                    outdir = outbase / Path(name).stem
                    brc, bout, berr = run_f3dc(
                        ["build", "-o", str(outdir), abspath], REPO_ROOT)
                    self.assertEqual(brc, 0, berr[:400])
                    got = {}
                    for p in sorted(outdir.rglob("*")):
                        if p.is_file():
                            got[str(p.relative_to(outdir))] = sha(
                                canon(p.read_bytes()))
                    self.assertEqual(got, scene["build"]["artifacts"],
                                     f"example {name} build artifacts differ")


@unittest.skipUnless(F3DC.is_file(), f"native compiler not built: {F3DC}")
class TestCliBattery(unittest.TestCase):
    """Baked CLI surface cases (sweep-2 list, relative-path form)."""

    @classmethod
    def setUpClass(cls):
        cls.data = load_json("cli_battery.json")

    def test_battery(self):
        for case in self.data["cases"]:
            with self.subTest(case=case["name"]):
                with tempfile.TemporaryDirectory(prefix="f3dc-cli-") as tmp:
                    work = Path(tmp)
                    for relname, text in case["setup"].items():
                        (work / relname).write_text(text, encoding="utf-8")
                    rc, out, err = run_f3dc(case["argv"], work)
                    exp = case["expect"]
                    if case["kind"] == "doctor":
                        self.assertEqual(rc, 0, err[:400])
                        self.assertTrue(out or err,
                                        "doctor produced no output")
                        continue
                    check_capture(exp, rc, out, err, f"cli case {case['name']}")
                    if case.get("build_artifacts"):
                        got = {}
                        outdir = work / "out"
                        for p in sorted(outdir.rglob("*")):
                            if p.is_file():
                                got[str(p.relative_to(outdir))] = sha(p.read_bytes())
                        self.assertEqual(got, exp["artifacts"],
                                         f"cli case {case['name']} artifacts")
                    if case["kind"] == "new":
                        created = work / "myscene.f3d"
                        self.assertTrue(created.is_file(),
                                        "f3dc new did not create myscene.f3d")
                        self.assertEqual(sha(created.read_bytes()),
                                         exp["created_sha256"])


@unittest.skipUnless(F3DC.is_file(), f"native compiler not built: {F3DC}")
class TestDeterminism(unittest.TestCase):
    def test_hello_cube_builds_byte_identically_twice(self):
        with tempfile.TemporaryDirectory(prefix="f3dc-det-") as tmp:
            hashes = []
            for label in ("a", "b"):
                outdir = Path(tmp) / label
                rc, out, err = run_f3dc(
                    ["build", "-o", str(outdir), "examples/hello-cube.f3d"],
                    REPO_ROOT)
                self.assertEqual(rc, 0, err[:400])
                scene = outdir / "hello-cube.scene"
                self.assertTrue(scene.is_file())
                hashes.append(sha(scene.read_bytes()))
            self.assertEqual(hashes[0], hashes[1])


@unittest.skipUnless(F3DC.is_file(), f"native compiler not built: {F3DC}")
class TestPreview(unittest.TestCase):
    """Native preview: page / version / edit-bump / error / recovery."""

    def test_preview_live_reload_cycle(self):
        with tempfile.TemporaryDirectory(prefix="f3dc-preview-") as tmp:
            work = Path(tmp)
            scene = work / "scene.f3d"
            scene.write_text("cube red\nspin it\nrender\n", encoding="utf-8")
            log_path = work / "preview.log"
            with open(log_path, "wb") as log:
                proc = subprocess.Popen(
                    [str(F3DC), "preview", "--port", "0", "--no-browser",
                     "scene.f3d"],
                    cwd=str(work), stdout=log, stderr=subprocess.STDOUT)
            try:
                base = None
                deadline = time.time() + 20
                while time.time() < deadline:
                    if proc.poll() is not None:
                        break
                    text = log_path.read_text(errors="replace")
                    m = re.search(r"http://127\.0\.0\.1:(\d+)/", text)
                    if m:
                        base = f"http://127.0.0.1:{m.group(1)}"
                        break
                    time.sleep(0.2)
                self.assertIsNotNone(
                    base, f"preview did not print a URL; log: "
                          f"{log_path.read_text(errors='replace')[:500]}")

                def get(path):
                    with urllib.request.urlopen(base + path, timeout=5) as resp:
                        return resp.status, resp.read().decode(
                            "utf-8", errors="replace")

                def wait_version(gt, timeout=15):
                    dl = time.time() + timeout
                    last = None
                    while time.time() < dl:
                        _, body = get("/__version")
                        last = json.loads(body)
                        if last["version"] > gt:
                            return last
                        time.sleep(0.15)
                    raise AssertionError(f"version did not pass {gt}: {last}")

                status, body = get("/")
                self.assertEqual(status, 200)
                self.assertIn("f3d-preview-bar", body)
                self.assertIn("Forge3D Preview", body)
                self.assertNotIn("__VERSION__", body)

                _, body = get("/__version")
                v = json.loads(body)
                self.assertTrue(v["ok"])
                self.assertEqual(v["errors"], 0)
                v0 = v["version"]
                self.assertGreaterEqual(v0, 1)

                scene.write_text("sphere blue\nrender\n", encoding="utf-8")
                data = wait_version(v0)
                self.assertTrue(data["ok"])
                v1 = data["version"]

                scene.write_text("cubee red\nrender\n", encoding="utf-8")
                data = wait_version(v1)
                self.assertFalse(data["ok"])
                self.assertGreaterEqual(data["errors"], 1)
                _, page = get("/")
                self.assertIn("Scene error", page)
                _, sbody = get("/__status")
                sdata = json.loads(sbody)
                self.assertFalse(sdata["ok"])
                self.assertTrue(sdata["diagnostics"])
                v2 = data["version"]

                scene.write_text("cube green\nrender\n", encoding="utf-8")
                data = wait_version(v2)
                self.assertTrue(data["ok"])
            finally:
                proc.send_signal(signal.SIGINT)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()


if __name__ == "__main__":
    unittest.main()
