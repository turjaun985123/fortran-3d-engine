#!/usr/bin/env python3
"""Forge3D test orchestrator (stdlib only).

Run from the repository root:

    python3 tests/run_tests.py

Layers (each is discovered at runtime; nothing is hardcoded beyond the
conventional locations below):

  a) Native-compiler black-box suites under ``tests/native/`` -- drive
     the ``bin/f3dc`` binary (built by ``make f3dc`` if missing) via
     subprocess against expectations baked from the pre-replacement
     Python compiler, plus the remaining Python unittest suites under
     ``tests/compiler/`` (JS runtime sidecars + parity governance,
     which never imported the compiler) and ``tests/e2e/`` (converted
     to subprocess drives of ``bin/f3dc``) -- all run with
     ``python -m unittest discover`` in a subprocess.
  b) Fortran tests under ``tests/fortran/*.f90`` -- test *programs*
     (files containing a ``program`` statement) are compiled together
     with the support sources in the same directory and the module
     sources under ``src/`` (files under ``src/`` that contain a
     ``program`` statement, e.g. a demo ``main``, are excluded) into a
     temporary directory and executed.  If ``gfortran`` is not on PATH
     this layer is skipped loudly.
  c) Golden-image check via ``tests/golden/check_image.py`` if present.

Every layer reports PASS, FAIL or SKIP.  A missing/empty layer is a
SKIP (with a reason), never a failure.  The process exits non-zero if
and only if at least one layer FAILs.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = Path(__file__).resolve().parent

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"

# Timeouts (seconds).  Generous enough for CI, finite so a hung test
# fails its layer instead of hanging the whole run forever.
PY_TIMEOUT = 600
FORTRAN_COMPILE_TIMEOUT = 300
FORTRAN_RUN_TIMEOUT = 120
GOLDEN_TIMEOUT = 600

_PROGRAM_RE = re.compile(r"^\s*program\s+\w+", re.IGNORECASE | re.MULTILINE)
_MODULE_RE = re.compile(r"^\s*module\s+(?!procedure\b)(\w+)", re.IGNORECASE | re.MULTILINE)
_USE_RE = re.compile(r"^\s*use\s*(?:,\s*\w+\s*)?(?:::)?\s*(\w+)", re.IGNORECASE | re.MULTILINE)


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _run(cmd, cwd, env=None, timeout=PY_TIMEOUT):
    """Run *cmd*, echo its output, return (exit_code, output); 124 on timeout."""
    print("    $ " + " ".join(str(c) for c in cmd), flush=True)
    try:
        proc = subprocess.run(
            [str(c) for c in cmd],
            cwd=str(cwd),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        output, code = proc.stdout or "", proc.returncode
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        if output:
            for line in output.rstrip("\n").splitlines():
                print("    " + line)
        print(f"    !! timed out after {timeout}s")
        return 124, output
    except OSError as exc:
        print(f"    !! could not start: {exc}")
        return 127, ""
    if output:
        for line in output.rstrip("\n").splitlines():
            print("    " + line)
    return code, output


def _python_env():
    """Environment for Python test subprocesses (repo root + tests dir)."""
    env = dict(os.environ)
    extra = [REPO_ROOT, TESTS_DIR]
    parts = [str(p) for p in extra if p.is_dir()]
    if env.get("PYTHONPATH"):
        parts.append(env["PYTHONPATH"])
    env["PYTHONPATH"] = os.pathsep.join(parts)
    env.setdefault("NO_COLOR", "1")
    return env


def _has_tests(directory):
    """True if *directory* holds files unittest discovery would pick up."""
    if not directory.is_dir():
        return False
    return any(
        p.is_file() and (p.name.startswith("test") or p.name.endswith("_test.py"))
        for p in directory.rglob("*.py")
    )


# --------------------------------------------------------------------------
# (a) Python unittest layers: tests/compiler/ and tests/e2e/
# --------------------------------------------------------------------------

def run_unittest_layer(name, directory):
    if not directory.is_dir():
        return SKIP, f"directory {directory.relative_to(REPO_ROOT)} does not exist yet"
    if not _has_tests(directory):
        return SKIP, f"no test_*.py / *_test.py files under {directory.relative_to(REPO_ROOT)}"
    # Try the conventional test_*.py pattern first, then *_test.py;
    # a pass that ran zero tests is not a pass.
    for pattern in ("test_*.py", "*_test.py"):
        code, output = _run(
            [sys.executable, "-m", "unittest", "discover",
             "-s", str(directory), "-p", pattern, "-v"],
            cwd=REPO_ROOT, env=_python_env(), timeout=PY_TIMEOUT,
        )
        if "Ran 0 tests" in output:
            continue
        if code != 0:
            return FAIL, f"unittest discover ({pattern}) exited {code}"
        return PASS, f"unittest suites passed ({pattern})"
    return FAIL, "test files present but unittest discovery ran 0 tests"


# --------------------------------------------------------------------------
# (a2) Native compiler layer: tests/native/ (black-box, bin/f3dc)
# --------------------------------------------------------------------------

def run_native_layer():
    """Ensure bin/f3dc exists (build it if not), then run tests/native/."""
    f3dc = REPO_ROOT / "bin" / "f3dc"
    if not f3dc.is_file():
        print("    bin/f3dc missing -- building via `make f3dc`")
        code, _ = _run(["make", "f3dc"], cwd=REPO_ROOT,
                       timeout=FORTRAN_COMPILE_TIMEOUT * 2)
        if code != 0 or not f3dc.is_file():
            return FAIL, "bin/f3dc missing and `make f3dc` failed"
    return run_unittest_layer("native", TESTS_DIR / "native")


# --------------------------------------------------------------------------
# (b) Fortran layer: tests/fortran/*.f90
# --------------------------------------------------------------------------

def _contains_program(path):
    try:
        return bool(_PROGRAM_RE.search(path.read_text(errors="replace")))
    except OSError:
        return False


def _topo_order(sources):
    """Order Fortran sources so providers of a `use`d module come first."""
    defines, uses = {}, {}
    for src in sources:
        try:
            text = src.read_text(errors="replace")
        except OSError:
            text = ""
        for mod in _MODULE_RE.findall(text):
            defines[mod.lower()] = src
        uses[src] = {u.lower() for u in _USE_RE.findall(text)}
    ordered, done, remaining = [], set(), list(sources)
    while remaining:
        progressed = False
        for src in list(remaining):
            deps = {defines[u] for u in uses.get(src, set())
                    if u in defines and defines[u] != src}
            if deps <= done:
                ordered.append(src)
                done.add(src)
                remaining.remove(src)
                progressed = True
        if not progressed:  # cycle / unresolved: keep the rest as-is
            ordered.extend(remaining)
            break
    return ordered


def run_fortran_layer():
    directory = TESTS_DIR / "fortran"
    if not directory.is_dir():
        return SKIP, "directory tests/fortran does not exist yet"
    sources = sorted(directory.glob("*.f90")) + sorted(directory.glob("*.f95")) \
        + sorted(directory.glob("*.f03")) + sorted(directory.glob("*.f08"))
    if not sources:
        return SKIP, "no .f90 test sources under tests/fortran"
    programs = [p for p in sources if _contains_program(p)]
    support = [p for p in sources if p not in programs]
    if not programs:
        return SKIP, "no Fortran test programs (no 'program' statement) under tests/fortran"

    gfortran = shutil.which("gfortran")
    if not gfortran:
        print("    " + "!" * 60)
        print("    SKIP: gfortran not available")
        print("    " + "!" * 60)
        return SKIP, "gfortran not available"

    src_dir = REPO_ROOT / "src"
    modules = []
    if src_dir.is_dir():
        for cand in sorted(src_dir.glob("*.f90")):
            if not _contains_program(cand):  # skip the demo main program
                modules.append(cand)
    module_sources = _topo_order(modules + support)

    failures = []
    with tempfile.TemporaryDirectory(prefix="forge3d-fortran-tests-") as tmp:
        tmpdir = Path(tmp)
        for program in programs:
            exe = tmpdir / program.stem
            cmd = [gfortran, "-O2", "-Wall", "-Wextra", "-fcheck=all",
                   f"-J{tmpdir}", f"-I{tmpdir}",
                   *module_sources, program, "-o", exe]
            code, _ = _run(cmd, cwd=tmpdir, timeout=FORTRAN_COMPILE_TIMEOUT)
            if code != 0:
                failures.append(f"{program.name}: compile exited {code}")
                continue
            code, _ = _run([exe], cwd=tmpdir, timeout=FORTRAN_RUN_TIMEOUT)
            if code != 0:
                failures.append(f"{program.name}: run exited {code}")
    if failures:
        return FAIL, "; ".join(failures)
    return PASS, f"{len(programs)} Fortran test program(s) compiled and passed"


# --------------------------------------------------------------------------
# (c) Golden layer: tests/golden/check_image.py
# --------------------------------------------------------------------------

def run_golden_layer():
    checker = TESTS_DIR / "golden" / "check_image.py"
    if not checker.is_file():
        return SKIP, "tests/golden/check_image.py does not exist yet"
    golden_env = os.environ.get("FORGE3D_GOLDEN")
    if golden_env:
        golden = Path(golden_env)
        if not golden.is_absolute():
            golden = REPO_ROOT / golden
    else:
        golden = TESTS_DIR / "golden" / "golden.ppm"
    if not golden.is_file():
        return SKIP, "no golden image committed (generated at integration)"
    code, _ = _run([sys.executable, str(checker), str(golden), "--expect-nonflat"],
                cwd=REPO_ROOT, env=_python_env(), timeout=GOLDEN_TIMEOUT)
    if code != 0:
        return FAIL, f"check_image.py exited {code}"
    return PASS, "golden image check passed"


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    print(f"Forge3D test run -- repo root: {REPO_ROOT}")
    layers = [
        ("native compiler (black-box, tests/native/)", run_native_layer),
        ("compiler-js + governance (Python unittest, tests/compiler/)",
         lambda: run_unittest_layer("compiler", TESTS_DIR / "compiler")),
        ("e2e (native subprocess, tests/e2e/)",
         lambda: run_unittest_layer("e2e", TESTS_DIR / "e2e")),
        ("fortran (tests/fortran/*.f90)", run_fortran_layer),
        ("golden (tests/golden/check_image.py)", run_golden_layer),
    ]
    results = []
    for label, runner in layers:
        print(f"\n== {label} ==")
        try:
            status, detail = runner()
        except Exception as exc:  # a broken layer is a FAIL, not a crash
            status, detail = FAIL, f"orchestrator error: {exc!r}"
        print(f"-- {label}: {status} ({detail})")
        results.append((label, status, detail))

    print("\n================ SUMMARY ================")
    for label, status, detail in results:
        print(f"{status:4}  {label} -- {detail}")
    failed = [r for r in results if r[1] == FAIL]
    skipped = [r for r in results if r[1] == SKIP]
    passed = [r for r in results if r[1] == PASS]
    print(f"Layers: {len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped")
    if failed:
        print("RESULT: FAIL")
        return 1
    print("RESULT: PASS (no layer failed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
