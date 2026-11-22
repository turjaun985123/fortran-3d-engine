"""Forge3D toolchain driver: locate/build/run the native Fortran engine.

Seat B16 (``docs/plan/MASTER-PLAN.md`` section 2, P20). Stdlib only.

Public API:

    repo_root() -> Path
    find_tool(name) -> Path | None
    ToolchainError  (exception, ``exit_code == 4``)
    ensure_engine(root=None) -> Path
    run_engine(scene_path, cwd, timeout=120) -> (returncode, stdout, stderr)

Design rules (MASTER-PLAN section 2 / P20 / P26):

* Toolchain failures are exit code 4 -- ``ToolchainError.exit_code``.
* Every external command is invoked with an argv list via
  :mod:`subprocess`; a shell is never used.
* All toolchain problems (missing ``make``/``gfortran``, a failed
  build, a missing/unrunnable engine, a timeout) raise
  :class:`ToolchainError` with a friendly, plain-words message --
  never a raw ``OSError``/``TimeoutExpired`` leak.
* A non-zero exit from the engine itself is *not* an exception:
  :func:`run_engine` returns it as ``(returncode, stdout, stderr)``
  so the caller (the CLI) can render the engine's own output.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

__all__ = [
    "ToolchainError",
    "repo_root",
    "find_tool",
    "ensure_engine",
    "run_engine",
]

#: How much build/engine output to keep in an error message.
_TAIL_CHARS = 2000
_TAIL_LINES = 30


class ToolchainError(Exception):
    """A toolchain problem: missing tool, failed build, unrunnable engine.

    ``exit_code`` is the CLI exit code for this family (MASTER-PLAN
    section 2: 0 ok / 1 scene / 2 usage / 3 IO / 4 toolchain /
    70 internal).
    """

    exit_code = 4

    def __init__(self, message: str = "toolchain error") -> None:
        super().__init__(message)
        self.message = message
        # Also available on the instance, for callers that read it there.
        self.exit_code = 4


def repo_root() -> Path:
    """Return the repository root.

    This file lives at ``<root>/tools/f3dc/driver.py``, so the root
    is three levels up from this file.
    """
    return Path(__file__).resolve().parents[2]


def find_tool(name: str) -> Path | None:
    """Return the path of executable ``name`` on ``PATH``, or ``None``.

    Thin wrapper over :func:`shutil.which` that returns a
    :class:`~pathlib.Path` (or ``None`` when the tool is absent)
    instead of a plain string.
    """
    if not name:
        return None
    found = shutil.which(name)
    return Path(found) if found else None


def _output_tail(*texts: str | None) -> str:
    """Return the tail of the combined output texts, for error messages."""
    combined = "\n".join(t for t in texts if t).strip()
    if not combined:
        return ""
    lines = combined.splitlines()
    tail = "\n".join(lines[-_TAIL_LINES:])
    if len(tail) > _TAIL_CHARS:
        tail = tail[-_TAIL_CHARS:]
    return tail


def ensure_engine(root: Path | str | None = None) -> Path:
    """Return the path to ``bin/engine3d``, building it if necessary.

    If ``bin/engine3d`` already exists under ``root`` (default:
    :func:`repo_root`), it is returned as-is. Otherwise ``make`` is
    run (argv list ``['make']``) in ``root``.

    Raises :class:`ToolchainError` if ``root`` does not look usable,
    if ``make`` or ``gfortran`` is missing, if the build fails, or
    if the build finishes without producing the engine.
    """
    root_path = Path(root).resolve() if root is not None else repo_root()
    engine = root_path / "bin" / "engine3d"

    if engine.is_file():
        return engine

    if not root_path.is_dir():
        raise ToolchainError(
            f"cannot build the Forge3D engine: repository root "
            f"'{root_path}' does not exist or is not a directory. "
            f"help: run f3dc from inside a Forge3D checkout, or pass "
            f"the checkout's root directory."
        )

    make = find_tool("make")
    if make is None:
        raise ToolchainError(
            "cannot build the Forge3D engine: 'make' was not found on "
            "your PATH. "
            "help: install make (e.g. 'sudo apt install make' on "
            "Debian/Ubuntu) and try again."
        )

    gfortran = find_tool("gfortran")
    if gfortran is None:
        raise ToolchainError(
            "cannot build the Forge3D engine: 'gfortran' was not found "
            "on your PATH. "
            "help: install gfortran (e.g. 'sudo apt install gfortran' "
            "on Debian/Ubuntu) and try again."
        )

    try:
        proc = subprocess.run(
            ["make"],
            cwd=str(root_path),
            capture_output=True,
            text=True,
            timeout=600,
        )
    except subprocess.TimeoutExpired as exc:
        tail = _output_tail(
            exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else exc.stdout,
            exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else exc.stderr,
        )
        msg = (
            "building the Forge3D engine with 'make' timed out. "
            "help: run 'make' by hand in "
            f"'{root_path}' to see what is happening."
        )
        if tail:
            msg += f"\nlast build output:\n{tail}"
        raise ToolchainError(msg) from exc
    except OSError as exc:
        raise ToolchainError(
            f"cannot build the Forge3D engine: failed to run 'make' "
            f"in '{root_path}': {exc}. "
            f"help: check that 'make' is installed and executable."
        ) from exc

    if proc.returncode != 0:
        tail = _output_tail(proc.stdout, proc.stderr)
        msg = (
            f"building the Forge3D engine failed: 'make' exited with "
            f"code {proc.returncode} in '{root_path}'. "
            f"help: run 'make' by hand there and fix the errors shown, "
            f"then try again."
        )
        if tail:
            msg += f"\nlast build output:\n{tail}"
        raise ToolchainError(msg)

    if not engine.is_file():
        tail = _output_tail(proc.stdout, proc.stderr)
        msg = (
            f"building the Forge3D engine did not produce the expected "
            f"file '{engine}', even though 'make' reported success. "
            f"help: run 'make' by hand in '{root_path}' and check that "
            f"it creates bin/engine3d."
        )
        if tail:
            msg += f"\nlast build output:\n{tail}"
        raise ToolchainError(msg)

    return engine


def run_engine(
    scene_path: Path | str,
    cwd: Path | str | None = None,
    timeout: float = 120,
) -> tuple[int, str, str]:
    """Run the native engine on ``scene_path``.

    Runs ``[engine, scene_path]`` (argv list, never a shell) with
    ``cwd`` as the working directory, and returns
    ``(returncode, stdout, stderr)``. A non-zero engine return code
    is returned, not raised.

    Raises :class:`ToolchainError` if the engine cannot be built or
    found, cannot be executed, or does not finish within
    ``timeout`` seconds.
    """
    engine = ensure_engine()

    workdir = Path(cwd) if cwd is not None else repo_root()
    argv = [str(engine), str(scene_path)]

    try:
        proc = subprocess.run(
            argv,
            cwd=str(workdir),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise ToolchainError(
            f"the Forge3D engine timed out after {timeout} seconds "
            f"while running '{scene_path}'. "
            f"help: try a smaller scene, or increase the timeout."
        ) from exc
    except OSError as exc:
        raise ToolchainError(
            f"cannot run the Forge3D engine '{engine}': {exc}. "
            f"help: check that bin/engine3d exists and is executable; "
            f"delete it and try again to force a rebuild if it is corrupt."
        ) from exc

    return proc.returncode, proc.stdout, proc.stderr
