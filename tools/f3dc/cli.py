"""Forge3D command-line interface: ``f3dc`` (seat B17).

Stdlib only (argparse).  Pipeline and command surface follow
``docs/plan/MASTER-PLAN.md`` section 2 and ``docs/plan/P20-cli-ux.md``:

    f3dc <file.f3d>          same as ``f3dc run <file.f3d>``
    f3dc run <file>          build, compile the engine, render, report
    f3dc build <file>        compile to ``build/`` (or ``-o DIR``)
    f3dc check <file>        validate only -- no files written
    f3dc new <name>          write ``<name>.f3d`` (the 3-line contract)
    f3dc fmt <file>          print the canonical ``.f3d`` form to stdout
    f3dc doctor              report python / toolchain / repo status

Exit codes: 0 ok, 1 scene errors, 2 usage (argparse), 3 IO,
4 toolchain, 70 unexpected internal error (traceback only when the
``F3DC_DEBUG`` environment variable is set).

Sibling compiler modules (errors, lexer, parser, desugar, validate,
optimize, emit_*, driver, compat) are imported by their real public
APIs.  The emit_* / driver seats land in parallel with this one, so
those imports are lazy and go through small adapters that try the
documented function names first; where an emitter is not on disk yet
a minimal local fallback keeps ``build`` usable, and a missing
``driver`` is a clean toolchain failure (exit 4), never a traceback.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import traceback
from pathlib import Path

try:  # package import (tools.f3dc as a package)
    from . import compat, desugar, optimize, parser as _parser_mod
    from . import validate as _validate_mod
    from .errors import Diagnostic, ErrorBag, Span
    from . import ir_nodes
except ImportError:  # flat module layout: tools/f3dc on sys.path (f3dc.py shim)
    import compat  # type: ignore
    import desugar  # type: ignore
    import optimize  # type: ignore
    import parser as _parser_mod  # type: ignore
    import validate as _validate_mod  # type: ignore
    from errors import Diagnostic, ErrorBag, Span  # type: ignore
    import ir_nodes  # type: ignore

__all__ = ["main", "compile_pipeline"]

VERSION = "0.1.0"
_COMMANDS = ("run", "build", "check", "new", "fmt", "doctor")
_INPUT_EXTS = (".f3d", ".json", ".obj")
# State from the most recent compile_pipeline() call, for --explain.
_LAST: dict = {}


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def _repo_root() -> Path:
    """Repo root: tools/f3dc/cli.py -> parents[2]."""
    return Path(__file__).resolve().parents[2]


def _get(obj, *names, default=None):
    if obj is None:
        return default
    for name in names:
        if isinstance(obj, dict):
            if name in obj and obj[name] is not None:
                return obj[name]
        elif hasattr(obj, name):
            value = getattr(obj, name)
            if value is not None:
                return value
    return default


def _fmt_num(value) -> str:
    """Canonical number spelling: 2.0 -> '2', 2.5 -> '2.5'."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else repr(value)
    return str(value)


def _fmt_vec(value) -> str:
    if isinstance(value, (list, tuple)):
        return " ".join(_fmt_num(v) for v in value)
    return _fmt_num(value)


def _print_diagnostics(bag: ErrorBag, as_json: bool = False) -> None:
    if as_json:
        print(bag.format_json())
    else:
        text = bag.format_text()
        if text:
            print(text, file=sys.stderr)


def _call_flex(fn, arg_sets):
    """Call *fn* with the first argument set it accepts."""
    last_exc = None
    for args, kwargs in arg_sets:
        try:
            return fn(*args, **kwargs)
        except TypeError as exc:  # wrong shape: try the next spelling
            last_exc = exc
            continue
    if last_exc is not None:
        raise last_exc
    return fn()


# ---------------------------------------------------------------------------
# Triangle estimate (mirrors validate._estimate_triangles / P11 formulas)
# ---------------------------------------------------------------------------

def _tri_estimate(ir) -> int:
    estimator = getattr(_validate_mod, "_estimate_triangles", None)
    total = 0
    for obj in _get(ir, "objects", default=[]) or []:
        tris = _get(obj, "triangles")
        if isinstance(tris, (list, tuple)):
            total += len(tris)
            continue
        prim = _get(obj, "prim", "primitive", default="")
        if estimator is not None:
            props = {
                "segments": _get(obj, "segments"),
                "detail": _get(obj, "detail"),
                "capped": _get(obj, "capped"),
            }
            try:
                total += int(estimator(prim, props))
                continue
            except Exception:
                pass
        total += {
            "cube": 12, "sphere": 352, "cylinder": 64, "plane": 2,
            "pyramid": 6, "cone": 32, "torus": 384,
        }.get(str(prim), 0)
    return total


# ---------------------------------------------------------------------------
# The compile pipeline
# ---------------------------------------------------------------------------

def compile_pipeline(path, bag: ErrorBag):
    """Compile *path* to an optimized IRScene, or ``None`` on failure.

    Missing file -> E501 in *bag* (callers map that to exit 3).
    ``.json`` / ``.obj`` inputs go through :mod:`compat`; everything
    else through ``parser.parse``.  Then ``validate.validate`` (which
    desugars internally) and ``optimize.optimize``.
    """
    path = Path(path)
    _LAST.clear()
    if not path.is_file():
        bag.add(Diagnostic(
            code="E501", severity="error",
            message=f"file not found: {path}",
            span=Span(str(path), 1, 1),
            why="f3dc can only compile a file that exists",
            help=f"check the path, or create a scene with:  f3dc new {path.stem}",
        ))
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        bag.add(Diagnostic(
            code="E501", severity="error",
            message=f"cannot read {path}: {exc}",
            span=Span(str(path), 1, 1),
            help="check the file permissions and try again",
        ))
        return None
    if hasattr(bag, "set_source"):
        bag.set_source(text)
    _LAST["path"] = path
    _LAST["text"] = text

    ext = path.suffix.lower()
    try:
        if ext == ".obj":
            prog = compat.ast_from_obj(text, bag)
        elif ext == ".json":
            if not compat.is_legacy_json(text):
                try:  # a v2 IR dump: load it directly, still optimize it
                    data = json.loads(text)
                except ValueError:
                    data = None
                if isinstance(data, dict) and "ir_version" in data:
                    ir = ir_nodes.from_json(text)
                    if bag.has_errors():
                        return None
                    _LAST["program"] = None
                    return optimize.optimize(ir, bag)
            prog = compat.ast_from_legacy_json(text, bag)
        else:
            prog = _parser_mod.parse(text, source_name=str(path), bag=bag)
    except Exception:
        raise
    _LAST["program"] = prog
    if bag.has_errors():
        return None
    ir = _validate_mod.validate(prog, bag, base_dir=str(path.parent))
    if ir is None or bag.has_errors():
        return None
    return optimize.optimize(ir, bag)


def _explain_text() -> str:
    """Desugared program summary (objects with defaults) for --explain."""
    prog = _LAST.get("program")
    if prog is None:
        return ""
    try:
        desugared = desugar.desugar(prog, ErrorBag())
    except Exception:
        return ""
    lines = ["desugared program:"]
    for stmt in _get(desugared, "statements", default=[]) or []:
        lines.append("  " + _format_stmt(stmt))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Canonical .f3d formatting (fmt)
# ---------------------------------------------------------------------------

_PROP_ORDER = ("at", "pos", "position", "size", "radius", "height",
               "rotate", "rot", "scale", "material", "segments", "detail",
               "capped", "open", "texture")


def _format_props(props: dict) -> list[str]:
    parts: list[str] = []
    if not isinstance(props, dict):
        return parts
    # The parser stores alias duplicates in props (at/pos, colour/color);
    # canonical form keeps one spelling and drops colour (it is printed
    # positionally by the object/light formatters).
    aliases = {"pos": "at", "position": "at", "rot": "rotate",
               "colour": None, "color": None}
    effective: dict = {}
    for key, value in props.items():
        canonical = aliases.get(key, key)
        if canonical is None or canonical in effective:
            continue
        effective[canonical] = value
    props = effective
    keys = [k for k in _PROP_ORDER if k in props]
    keys += [k for k in props if k not in _PROP_ORDER]
    for key in keys:
        value = props[key]
        if value is None:
            continue
        if isinstance(value, bool):
            if value:
                parts.append(str(key))
        elif key in ("at", "pos", "position", "rotate", "rot", "scale") \
                and isinstance(value, (list, tuple)):
            parts.append(f"{key} {_fmt_vec(value)}")
        elif isinstance(value, (list, tuple)):
            parts.append(f"{key} {_fmt_vec(value)}")
        else:
            parts.append(f"{key} {_fmt_num(value)}")
    return parts


def _format_stmt(stmt) -> str:
    kind = type(stmt).__name__
    props = _get(stmt, "props", default={}) or {}
    if kind == "ObjectStmt":
        parts = [str(_get(stmt, "prim", default="cube"))]
        name = _get(stmt, "name")
        if name:
            parts.append(str(name))
        colour = _get(stmt, "color_raw", "color")
        if colour:
            parts.append(str(colour))
        parts.extend(_format_props(props))
        return " ".join(parts)
    if kind == "SceneStmt":
        parts = ["scene"]
        if _get(stmt, "name"):
            parts.append(str(_get(stmt, "name")))
        width, height = _get(stmt, "width"), _get(stmt, "height")
        if width is not None and height is not None:
            parts.append(f"size {_fmt_num(width)}x{_fmt_num(height)}")
        if _get(stmt, "bg"):
            parts.append(f"bg {_get(stmt, 'bg')}")
        parts.extend(_format_props(
            {k: v for k, v in props.items() if k not in ("size", "bg")}))
        return " ".join(parts)
    if kind == "CameraStmt":
        parts = ["camera"]
        if _get(stmt, "pos") is not None:
            parts.append(f"at {_fmt_vec(_get(stmt, 'pos'))}")
        if _get(stmt, "target") is not None:
            parts.append(f"look {_fmt_vec(_get(stmt, 'target'))}")
        if _get(stmt, "up") is not None:
            parts.append(f"up {_fmt_vec(_get(stmt, 'up'))}")
        for key in ("fov", "near", "far"):
            if _get(stmt, key) is not None:
                parts.append(f"{key} {_fmt_num(_get(stmt, key))}")
        return " ".join(parts)
    if kind == "LightStmt":
        parts = ["light", str(_get(stmt, "kind", default="directional"))]
        direction = _get(stmt, "direction", "dir")
        if direction is not None:
            parts.append(_fmt_vec(direction))
        if _get(stmt, "color", "color_raw"):
            parts.append(str(_get(stmt, "color", "color_raw")))
        if _get(stmt, "intensity") is not None:
            parts.append(f"intensity {_fmt_num(_get(stmt, 'intensity'))}")
        return " ".join(parts)
    if kind == "AnimStmt":
        parts = [str(_get(stmt, "kind", default="spin"))]
        if _get(stmt, "target"):
            parts.append(str(_get(stmt, "target")))
        parts.extend(_format_props(props))
        return " ".join(parts)
    if kind == "LoadStmt":
        parts = ["load", f'"{_get(stmt, "path", default="")}"']
        if _get(stmt, "name"):
            parts.append(str(_get(stmt, "name")))
        parts.extend(_format_props(props))
        return " ".join(parts)
    if kind == "RepeatStmt":
        mode = str(_get(stmt, "mode", default="repeat"))
        a, b = _get(stmt, "a", default=0), _get(stmt, "b")
        head = f"grid {_fmt_num(a)}x{_fmt_num(b)}" if mode == "grid" and b \
            else f"{mode} {_fmt_num(a)}"
        obj = _get(stmt, "obj")
        return f"{head} {_format_stmt(obj)}" if obj is not None else head
    if kind == "GroupStmt":
        parts = ["group"]
        if _get(stmt, "name"):
            parts.append(str(_get(stmt, "name")))
        parts.extend(_format_props(props))
        body = [_format_stmt(s) for s in _get(stmt, "body", default=[]) or []]
        return "\n".join([" ".join(parts), *("  " + b for b in body), "end"])
    if kind == "ControlsStmt":
        parts = ["controls", str(_get(stmt, "kind", default="orbit"))]
        parts.extend(_format_props(props))
        return " ".join(parts)
    if kind == "OutputStmt":
        okind = str(_get(stmt, "kind", default="render"))
        if okind == "export":
            parts = ["export", str(_get(stmt, "format", default="json"))]
        else:
            parts = ["render"]
        if _get(stmt, "path"):
            parts.append(str(_get(stmt, "path")))
        width, height = _get(stmt, "width"), _get(stmt, "height")
        if width is not None and height is not None:
            parts.append(f"size {_fmt_num(width)}x{_fmt_num(height)}")
        return " ".join(parts)
    # Unknown statement kind: best-effort one-line rendering.
    parts = [kind]
    parts.extend(_format_props(props))
    return " ".join(parts)


# ---------------------------------------------------------------------------
# Emitters (real emit_* APIs when present, minimal fallbacks otherwise)
# ---------------------------------------------------------------------------

def _import_sibling(name):
    try:
        return __import__(name if __package__ in (None, "") else f".{name}",
                          globals(), locals(), ["*"],
                          1 if __package__ else 0)
    except Exception:
        return None


def _emit_call(module_name, fn_names, ir, *extra):
    mod = _import_sibling(module_name)
    if mod is None:
        return None
    for fn_name in fn_names:
        fn = getattr(mod, fn_name, None)
        if callable(fn):
            result = _call_flex(fn, [((ir,) + extra, {}), ((ir,), {})])
            if result is not None:
                return result if isinstance(result, str) else str(result)
    return None


def _scene_text(ir, stem: str) -> str:
    text = _emit_call("emit_fortran",
                      ("emit_scene_text", "scene_text", "emit_scene", "emit"),
                      ir)
    if text is not None:
        return text
    lines = [f"scene {_get(ir, 'name', default=stem)} "
             f"{_fmt_num(_get(ir, 'width', default=640))}x"
             f"{_fmt_num(_get(ir, 'height', default=480))}"]
    bg = _get(ir, "bg", default=(25, 25, 35))
    lines.append(f"bg {_fmt_vec(bg)}")
    cam = _get(ir, "camera")
    if cam is not None:
        lines.append(f"camera {_fmt_vec(_get(cam, 'pos', default=(3, 2.5, 4)))} "
                     f"{_fmt_vec(_get(cam, 'target', default=(0, 0, 0)))} "
                     f"{_fmt_num(_get(cam, 'fov', default=60))}")
    for light in _get(ir, "lights", default=[]) or []:
        lines.append(f"light {_get(light, 'kind', default='directional')} "
                     f"{_fmt_vec(_get(light, 'direction', default=(-0.5, -1, -0.7)))}")
    for obj in _get(ir, "objects", default=[]) or []:
        lines.append(f"object {_get(obj, 'name', default='')} "
                     f"{_get(obj, 'prim', default='cube')} "
                     f"{_fmt_vec(_get(obj, 'pos', default=(0, 0, 0)))} "
                     f"{_fmt_num(_get(obj, 'size', default=2))}")
    lines.append(f"output {stem}.ppm")
    return "\n".join(lines) + "\n"


def _fortran_program_text(ir, stem: str) -> str:
    text = _emit_call("emit_fortran",
                      ("emit_fortran_program", "emit_program",
                       "fortran_program", "emit_fortran"),
                      ir)
    if text is not None:
        return text
    return (f"! generated by f3dc {VERSION} from {stem}.f3d -- do not edit\n"
            f"program {stem}_scene\n"
            f"  ! scene: {_get(ir, 'name', default=stem)} "
            f"({len(_get(ir, 'objects', default=[]) or [])} objects)\n"
            f"end program {stem}_scene\n")


def _json_v2_text(ir) -> str:
    text = _emit_call("emit_json",
                      ("emit_v2", "emit_json_v2", "emit_json", "to_json",
                       "emit"), ir)
    if text is not None:
        return text
    return ir_nodes.to_json(ir, indent=2) + "\n"


def _json_legacy_text(ir) -> str:
    text = _emit_call("emit_json",
                      ("emit_json_legacy", "emit_legacy", "emit_legacy_json",
                       "emit_v1", "emit_json_v1", "legacy_json"), ir)
    if text is not None:
        return text
    triangles = []
    tid = 1
    for obj in _get(ir, "objects", default=[]) or []:
        for tri in _get(obj, "triangles") or []:
            if isinstance(tri, dict):
                triangles.append({"id": tid, "v": tri.get("v"),
                                  "color": tri.get("color", [200, 200, 205])})
                tid += 1
    return json.dumps({"triangles": triangles}, indent=2) + "\n"


def _js_text(ir) -> str:
    text = _emit_call("emit_js", ("emit_js", "emit", "to_js"), ir)
    if text is not None:
        return text
    return (f"// generated by f3dc {VERSION} -- do not edit\n"
            f"export const SCENE = {ir_nodes.to_json(ir)};\n"
            f"export const TRIANGLES = "
            f"{json.loads(_json_legacy_text(ir))['triangles']!r};\n".replace("'", '"'))


def _html_text(ir, stem: str) -> str:
    runtime = ""
    runtime_path = _repo_root() / "runtime" / "f3d.js"
    if runtime_path.is_file():
        try:
            runtime = runtime_path.read_text(encoding="utf-8")
        except OSError:
            runtime = ""
    mod = _import_sibling("emit_html")
    if mod is not None:
        for fn_name in ("emit_html", "emit", "to_html"):
            fn = getattr(mod, fn_name, None)
            if callable(fn):
                text = _call_flex(fn, [((ir,), {"runtime_js": runtime or None}),
                                       ((ir,), {})])
                if text is not None:
                    return text if isinstance(text, str) else str(text)
    text = _emit_call("emit_html", ("emit_html", "emit", "to_html"), ir)
    if text is not None:
        return text
    title = _get(ir, "name", default=stem)
    return ("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
            f"<title>{title}</title></head><body>\n"
            f"<canvas id=\"f3d\" width=\"{_fmt_num(_get(ir, 'width', default=640))}\" "
            f"height=\"{_fmt_num(_get(ir, 'height', default=480))}\"></canvas>\n"
            f"<script>const SCENE = {ir_nodes.to_json(ir)};</script>\n"
            f"<script>\n{runtime}\n</script>\n</body></html>\n")


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def _fail_code(bag: ErrorBag) -> int:
    """Exit code for a failed compile: E5xx IO -> 3, else scene errors -> 1."""
    if any(d.code.startswith("E5") for d in bag.errors()):
        return 3
    return 1


def _do_check(path, as_json=False, explain=False) -> int:
    bag = ErrorBag()
    ir = compile_pipeline(path, bag)
    if ir is None:
        _print_diagnostics(bag, as_json=as_json)
        return _fail_code(bag)
    if bag.diagnostics:
        _print_diagnostics(bag, as_json=as_json)
    elif as_json:
        print(bag.format_json())
    if explain:
        summary = _explain_text()
        if summary:
            print(summary, file=sys.stderr)
    print(f"OK: {path} ({len(ir.objects)} objects, "
          f"{_tri_estimate(ir)} triangles est.)")
    return 0


def _do_build(path, out_dir=None, explain=False):
    """Build all artifacts; return (exit_code, out_dir, ir, stem)."""
    bag = ErrorBag()
    ir = compile_pipeline(path, bag)
    if ir is None:
        _print_diagnostics(bag)
        return _fail_code(bag), None, None, None
    if bag.diagnostics:
        _print_diagnostics(bag)
    out = Path(out_dir) if out_dir else Path("build")
    stem = Path(path).stem
    artifacts = {
        f"{stem}.scene": _scene_text(ir, stem),
        f"{stem}.json": _json_v2_text(ir),
        f"{stem}.legacy.json": _json_legacy_text(ir),
        f"{stem}.js": _js_text(ir),
        f"{stem}.html": _html_text(ir, stem),
        f"{stem}_scene.f90": _fortran_program_text(ir, stem),
    }
    protected = {_repo_root() / "scene.json", _repo_root() / "viewer.html"}
    for name in artifacts:
        if (out / name).resolve() in protected:
            print(f"error E502: refusing to write {(out / name)} -- "
                  "f3dc never overwrites the repo-root scene.json/viewer.html; "
                  "use the default build/ output directory", file=sys.stderr)
            return 3, None, None, None
    try:
        out.mkdir(parents=True, exist_ok=True)
        written = []
        for name, content in artifacts.items():
            target = out / name
            target.write_text(content, encoding="utf-8")
            written.append(target)
    except OSError as exc:
        print(f"error E502: cannot write output: {exc}", file=sys.stderr)
        return 3, None, None, None
    if explain:
        summary = _explain_text()
        if summary:
            print(summary, file=sys.stderr)
    for target in written:
        print(str(target))
    return 0, out, ir, stem


def _render_output_name(ir, stem: str, scene_path: Path) -> str:
    """The engine's output file name, per the .scene 'output' line."""
    try:
        for line in scene_path.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "output":
                return parts[1]
    except OSError:
        pass
    for out in _get(ir, "outputs", default=[]) or []:
        if _get(out, "kind", default="render") == "render" and _get(out, "path"):
            return Path(str(_get(out, "path"))).name
    return f"{stem}.ppm"


def _do_run(path, out_dir=None) -> int:
    code, out, ir, stem = _do_build(path, out_dir=out_dir)
    if code != 0:
        return code
    driver = _import_sibling("driver")
    if driver is None or not callable(getattr(driver, "run_engine", None)):
        print("error: toolchain failure -- the f3dc driver module "
              "(tools/f3dc/driver.py) is not available, so the Fortran "
              "engine cannot be built or run; try 'f3dc doctor'",
              file=sys.stderr)
        return 4
    # The engine runs with cwd=out (the build dir) so its outputs land
    # there, so a relative scene path like ``build/<stem>.scene`` would
    # be resolved by the engine as ``build/build/<stem>.scene`` and not
    # found.  Resolve the scene path to an absolute path before handing
    # it to the driver; keep cwd=out unchanged.
    # Limitation (audited, not redesigned): ``loadobj`` paths embedded
    # inside the .scene file are likewise resolved by the Fortran
    # engine relative to its cwd (the build dir), not relative to the
    # source .f3d file or the caller's cwd -- OBJ assets referenced by
    # a scene must therefore be reachable relative to the build dir.
    scene_path = (out / f"{stem}.scene").resolve()
    try:
        ensure = getattr(driver, "ensure_engine", None)
        if callable(ensure):
            result = _call_flex(ensure, [((), {}),
                                         ((_repo_root(),), {}),
                                         ((out,), {})])
            if result is False:
                print("error: toolchain failure -- the Fortran engine "
                      "could not be built; try 'f3dc doctor'",
                      file=sys.stderr)
                return 4
        result = _call_flex(driver.run_engine,
                            [((scene_path,), {"cwd": out}),
                             ((scene_path,), {"cwd": str(out)}),
                             ((str(scene_path),), {"cwd": str(out)}),
                             ((scene_path, out), {}),
                             ((scene_path,), {})])
    except Exception as exc:
        print(f"error: toolchain failure -- engine run failed: {exc}",
              file=sys.stderr)
        return 4
    # driver.run_engine returns (returncode, stdout, stderr).
    if isinstance(result, (tuple, list)) and result and \
            isinstance(result[0], int):
        if result[0] != 0:
            tail = ""
            if len(result) > 2 and result[2]:
                tail = ": " + str(result[2]).strip().splitlines()[-1] \
                    if str(result[2]).strip() else ""
            print(f"error: toolchain failure -- engine exited with "
                  f"status {result[0]}{tail}", file=sys.stderr)
            return 4
        result = None  # success; the output name comes from the .scene
    if isinstance(result, int) and result != 0:
        print(f"error: toolchain failure -- engine exited with status "
              f"{result}", file=sys.stderr)
        return 4
    if result is False:
        print("error: toolchain failure -- engine run failed",
              file=sys.stderr)
        return 4

    output_name = _render_output_name(ir, stem, scene_path)
    is_png = output_name.lower().endswith(".png")
    ppm_name = output_name[:-4] + ".ppm" if is_png else output_name
    if isinstance(result, (str, Path)) and Path(result).suffix == ".ppm":
        ppm_path = Path(result)
        if not ppm_path.is_absolute():
            ppm_path = out / ppm_path.name
    else:
        ppm_path = out / Path(ppm_name).name
    if ppm_path.is_file():
        print(str(ppm_path))
    else:
        print(f"error: toolchain failure -- the engine reported success "
              f"but produced no output file at {ppm_path}", file=sys.stderr)
        return 4

    animations = _get(ir, "animations", default=[]) or []
    if animations:
        frames = 0
        for anim in animations:
            duration = _get(anim, "duration", default=5) or 5
            fps = _get(anim, "fps", default=30) or 30
            try:
                frames = max(frames, int(float(duration) * int(fps)))
            except (TypeError, ValueError):
                pass
        if frames > 1:
            frame_files = sorted(out.glob(f"{Path(ppm_name).stem}_*.ppm"))
            if frame_files:
                for frame in frame_files:
                    print(str(frame))
                print(f"animation: {len(frame_files)} frame files "
                      f"for {frames} frames")
            else:
                print(f"animation: {frames} frames expected as "
                      f"{out / (Path(ppm_name).stem + '_%04d.ppm')}")

    if is_png:
        png_path = out / Path(output_name).name
        convert = shutil.which("convert")
        if convert is None:
            print(f"error: PNG output '{output_name}' was requested but "
                  f"ImageMagick 'convert' was not found on PATH, so the "
                  f"PNG cannot be written. The full-quality PPM render "
                  f"is at: {ppm_path}", file=sys.stderr)
            return 1
        try:
            proc = subprocess.run([convert, str(ppm_path), str(png_path)],
                                  capture_output=True, text=True)
        except OSError as exc:
            print(f"error: could not run 'convert': {exc}; the PPM "
                  f"render is at: {ppm_path}", file=sys.stderr)
            return 1
        if proc.returncode != 0:
            print(f"error: 'convert' failed ({proc.returncode}): "
                  f"{proc.stderr.strip()}; the PPM render is at: "
                  f"{ppm_path}", file=sys.stderr)
            return 1
        print(str(png_path))
    return 0


def _do_new(name: str) -> int:
    target = Path(name)
    if target.suffix.lower() != ".f3d":
        target = target.with_name(target.name + ".f3d")
    if target.exists():
        print(f"error: {target} already exists -- f3dc new never "
              "overwrites an existing file", file=sys.stderr)
        return 3
    try:
        if str(target.parent) not in ("", "."):
            target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("cube red\nspin it\nrender\n", encoding="utf-8")
    except OSError as exc:
        print(f"error E502: cannot write {target}: {exc}", file=sys.stderr)
        return 3
    print(f"created {target} -- next: f3dc run {target}")
    return 0


def _do_fmt(path) -> int:
    path = Path(path)
    if not path.is_file():
        bag = ErrorBag()
        bag.add(Diagnostic(code="E501", severity="error",
                           message=f"file not found: {path}",
                           span=Span(str(path), 1, 1),
                           help="check the path and try again"))
        _print_diagnostics(bag)
        return 3
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"error E501: cannot read {path}: {exc}", file=sys.stderr)
        return 3
    bag = ErrorBag()
    if hasattr(bag, "set_source"):
        bag.set_source(text)
    ext = path.suffix.lower()
    if ext == ".obj":
        prog = compat.ast_from_obj(text, bag)
    elif ext == ".json":
        prog = compat.ast_from_legacy_json(text, bag)
    else:
        prog = _parser_mod.parse(text, source_name=str(path), bag=bag)
    if bag.has_errors():
        _print_diagnostics(bag)
        return 1
    lines = [_format_stmt(stmt)
             for stmt in _get(prog, "statements", default=[]) or []]
    print("\n".join(lines))
    return 0


def _do_doctor() -> int:
    root = _repo_root()
    print(f"f3dc {VERSION}")
    print(f"python: {sys.version.split()[0]} ({sys.executable})")
    missing_required = []
    for tool in ("gfortran", "make", "convert"):
        found = shutil.which(tool)
        label = "required" if tool in ("gfortran", "make") else "optional"
        if found:
            print(f"{tool}: {found}")
        else:
            print(f"{tool}: MISSING ({label})")
            if label == "required":
                missing_required.append(tool)
    print(f"repo root: {root}")
    print(f"engine sources: {root / 'src'} "
          f"({'present' if (root / 'src').is_dir() else 'MISSING'})")
    if len(missing_required) == 2:  # gfortran AND make both missing
        print("error: neither gfortran nor make was found -- 'f3dc run' "
              "cannot work; install a Fortran toolchain and re-run "
              "'f3dc doctor'", file=sys.stderr)
        return 4
    return 0


# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="f3dc", description="Forge3D compiler -- compile and run "
        ".f3d scenes, the easy way")
    parser.add_argument("--version", action="version",
                        version=f"f3dc {VERSION}")
    sub = parser.add_subparsers(dest="command")

    for name, help_text in (("run", "build, compile the engine and render"),
                            ("build", "compile to build/ (Fortran + JSON "
                                      "+ JS + HTML)"),
                            ("check", "validate only -- no files written")):
        sp = sub.add_parser(name, help=help_text)
        sp.add_argument("file", help="scene file (.f3d, .json or .obj)")
        if name in ("run", "build"):
            sp.add_argument("-o", "--out", default=None,
                            help="output directory (default: build/)")
        if name in ("build", "check"):
            sp.add_argument("--explain", action="store_true",
                            help="also print the desugared program summary")
        if name == "check":
            sp.add_argument("--json", action="store_true",
                            help="print diagnostics as JSON")
    sp = sub.add_parser("new", help="create <name>.f3d from the starter "
                                    "template")
    sp.add_argument("name", help="scene name, with or without .f3d")
    sp = sub.add_parser("fmt", help="print the canonical .f3d form to stdout")
    sp.add_argument("file", help="scene file (.f3d, .json or .obj)")
    sub.add_parser("doctor", help="check python / gfortran / make / "
                                  "convert and print fixes")
    return parser


def _discover_scene() -> Path | None:
    cwd = Path.cwd()
    for preferred in ("scene.f3d", "main.f3d"):
        if (cwd / preferred).is_file():
            return cwd / preferred
    scenes = sorted(cwd.glob("*.f3d"))
    return scenes[0] if len(scenes) == 1 else None


def _dispatch(argv: list[str]) -> int:
    parser = _build_arg_parser()
    if not argv:
        scene = _discover_scene()
        if scene is None:
            parser.print_help(sys.stderr)
            print("error: no .f3d file here -- create one:  f3dc new hello",
                  file=sys.stderr)
            return 2
        return _do_run(str(scene))
    if argv[0] not in _COMMANDS and not argv[0].startswith("-"):
        # Bare form: f3dc file.f3d == f3dc run file.f3d
        if argv[0].lower().endswith(_INPUT_EXTS) or Path(argv[0]).is_file():
            run_parser = argparse.ArgumentParser(prog="f3dc run")
            run_parser.add_argument("file")
            run_parser.add_argument("-o", "--out", default=None)
            args = run_parser.parse_args(argv)
            return _do_run(args.file, out_dir=args.out)
        parser.error(f"unknown command {argv[0]!r} "
                     f"(commands: {', '.join(_COMMANDS)}; or pass a scene "
                     "file to run it)")
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0
    if args.command == "check":
        return _do_check(args.file, as_json=args.json, explain=args.explain)
    if args.command == "build":
        code, _out, _ir, _stem = _do_build(args.file, out_dir=args.out,
                                           explain=args.explain)
        return code
    if args.command == "run":
        return _do_run(args.file, out_dir=args.out)
    if args.command == "new":
        return _do_new(args.name)
    if args.command == "fmt":
        return _do_fmt(args.file)
    if args.command == "doctor":
        return _do_doctor()
    parser.error(f"unknown command {args.command!r}")
    return 2


def main(argv=None) -> int:
    """Entry point.  ``argv`` excludes the program name (default sys.argv)."""
    if argv is None:
        argv = sys.argv[1:]
    try:
        return _dispatch(list(argv))
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except SystemExit:
        raise
    except Exception:
        if os.environ.get("F3DC_DEBUG"):
            traceback.print_exc()
        else:
            print("error E9000: internal f3dc error -- please report it "
                  "with 'f3dc --version' and the scene file "
                  "(set F3DC_DEBUG=1 for a traceback)", file=sys.stderr)
        return 70


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
