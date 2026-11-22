"""Compatibility readers: legacy ``scene.json`` (v1) and Wavefront OBJ -> AST.

Seat B06 (``docs/plan/MASTER-PLAN.md`` sections 2 and 4).  Stdlib only.

Both readers produce the *same* synthetic shape, documented here as a
compat-only contract (it is NOT part of the ``.f3d`` grammar):

* a :class:`~ast_nodes.Program` holding exactly one
  :class:`~ast_nodes.ObjectStmt` with ``prim='tris'`` -- ``'tris'`` is
  deliberately not one of the grammar primitives (``cube|sphere|...``),
  so no parser-produced program can collide with it;
* that statement's ``props`` is exactly ``{'triangles': [...]}``, where
  each triangle is ``{'v': [[x, y, z], [x, y, z], [x, y, z]],
  'color': [r, g, b]}`` for legacy JSON (per-triangle colours are kept
  in the data; the statement's ``color_raw`` stays ``None``), or
  ``{'v': [[x, y, z], [x, y, z], [x, y, z]]}`` for OBJ (OBJ carries no
  colour here, so ``color_raw`` is ``None`` = default);
* ``validate.py`` is expected to pass a ``prim='tris'`` statement
  through to the IR as a raw-triangles object, with transforms already
  baked into the vertices (both source formats are world-space soups).

Synthetic nodes carry ``span=None`` (see ``ast_nodes`` module docstring:
``None`` for synthetic nodes when no source location exists).
Diagnostics, by contrast, do get spans (against a synthetic source
name) so a bad line in an OBJ file can be pointed at.

Errors are collected into the caller's ``ErrorBag`` (never raised):
malformed content -> ``E101``/``E301``; OBJ security limits
(MASTER-PLAN section 2 / P26: OBJ <= 64 MB, <= 500k faces) -> ``E820``.
On a limit breach the reader returns an empty ``Program`` rather than
a partial, oversized triangle soup.
"""

from __future__ import annotations

import json

try:  # package import (tools.f3dc as a package)
    from .ast_nodes import ObjectStmt, Program
    from .errors import Diagnostic, ErrorBag, Span
except ImportError:  # flat module layout: tools/f3dc on sys.path
    from ast_nodes import ObjectStmt, Program
    from errors import Diagnostic, ErrorBag, Span

__all__ = [
    "MAX_OBJ_BYTES",
    "MAX_OBJ_FACES",
    "is_legacy_json",
    "ast_from_legacy_json",
    "ast_from_obj",
]

#: OBJ size limit in bytes (64 MiB, MASTER-PLAN section 2 security limits).
MAX_OBJ_BYTES = 64 * 1024 * 1024

#: OBJ face limit, counted pre-triangulation (``f`` lines).
MAX_OBJ_FACES = 500_000

_JSON_SOURCE = "<scene.json>"
_OBJ_SOURCE = "<model.obj>"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _error(bag, code: str, message: str, span: Span | None = None,
           why: str = "", help: str = "") -> None:
    """Append one diagnostic to *bag* (a private bag is used if None)."""
    if bag is None:
        bag = ErrorBag()
    bag.add(Diagnostic(code=code, severity="error", message=message,
                       span=span, why=why, help=help))


def _tris_program(triangles: list) -> Program:
    """Wrap *triangles* in the compat-only ``prim='tris'`` program."""
    stmt = ObjectStmt(prim="tris", name=None, color_raw=None,
                      props={"triangles": triangles}, span=None)
    return Program(statements=[stmt], span=None)


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _as_vec3(value):
    """Return ``[x, y, z]`` floats for a 3-number sequence, else None."""
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        return None
    if not all(_is_number(c) for c in value):
        return None
    return [float(value[0]), float(value[1]), float(value[2])]


# ---------------------------------------------------------------------------
# legacy scene.json (v1)
# ---------------------------------------------------------------------------


def is_legacy_json(text) -> bool:
    """True iff *text* parses as legacy v1 scene JSON.

    Legacy v1 shape: a JSON object with a ``triangles`` list whose
    entries are objects carrying ``v`` and ``color``.  v2 JSON (which
    has ``ir_version`` / ``objects``) is explicitly not legacy.
    """
    if not isinstance(text, str):
        return False
    try:
        data = json.loads(text)
    except ValueError:
        return False
    if not isinstance(data, dict):
        return False
    if "ir_version" in data or "objects" in data:
        return False
    triangles = data.get("triangles")
    if not isinstance(triangles, list):
        return False
    return all(
        isinstance(t, dict) and "v" in t and "color" in t for t in triangles
    )


def ast_from_legacy_json(text, bag) -> Program:
    """Parse legacy v1 ``scene.json`` text into a compat ``Program``.

    One ``prim='tris'`` ObjectStmt holds every triangle (see module
    docstring).  Malformed triangles are reported and skipped; valid
    ones are kept, in file order.
    """
    span = Span(_JSON_SOURCE, 1, 1)
    try:
        data = json.loads(text)
    except ValueError as exc:
        _error(bag, "E101", f"legacy scene JSON is not valid JSON: {exc}",
               span=span, why="the compat reader only accepts the v1 "
               "{triangles: [...]} shape",
               help="export the scene again, or convert it to .f3d")
        return Program(statements=[], span=None)
    if not isinstance(data, dict) or not isinstance(data.get("triangles"), list):
        _error(bag, "E101", "legacy scene JSON has no 'triangles' list",
               span=span, why="the v1 format is {triangles: [{v, color}, ...]}",
               help="check the file is a v1 scene.json, not a v2 export")
        return Program(statements=[], span=None)

    triangles = []
    for idx, entry in enumerate(data["triangles"], start=1):
        where = f"triangle {entry.get('id', idx) if isinstance(entry, dict) else idx}"
        if not isinstance(entry, dict):
            _error(bag, "E101", f"{where}: not an object", span=span)
            continue
        verts_raw = entry.get("v")
        if not isinstance(verts_raw, (list, tuple)) or len(verts_raw) != 3:
            _error(bag, "E101", f"{where}: 'v' must have exactly 3 vertices",
                   span=span)
            continue
        verts = [_as_vec3(v) for v in verts_raw]
        if any(v is None for v in verts):
            _error(bag, "E101", f"{where}: each vertex must be [x, y, z] numbers",
                   span=span)
            continue
        color_raw = entry.get("color")
        if (not isinstance(color_raw, (list, tuple)) or len(color_raw) != 3
                or not all(_is_number(c) for c in color_raw)):
            _error(bag, "E101", f"{where}: 'color' must be [r, g, b] numbers",
                   span=span)
            continue
        color = [int(c) for c in color_raw]
        if any(c < 0 or c > 255 for c in color):
            _error(bag, "E301", f"{where}: colour channels must be 0-255, "
                   f"got {color}", span=span)
            continue
        tri = {"v": verts, "color": color}
        if isinstance(entry.get("id"), int):
            tri["id"] = entry["id"]
        triangles.append(tri)
    return _tris_program(triangles)


# ---------------------------------------------------------------------------
# Wavefront OBJ
# ---------------------------------------------------------------------------


def ast_from_obj(text, bag) -> Program:
    """Parse Wavefront OBJ text into a compat ``Program``.

    Supports ``v`` and ``f`` lines (plus silently ignoring comments,
    ``vt``/``vn``/``o``/``g``/``s``/``usemtl``/``mtllib`` -- the material
    library is never opened).  Face corners may be ``i``, ``i/j``,
    ``i//k`` or ``i/j/k``; indices are 1-based, negative indices are
    relative to the most recent vertex.  Polygons are fan-triangulated
    (``c0, ci, ci+1``).  Same ``prim='tris'`` shape as the JSON reader,
    with ``color_raw=None`` (default colour downstream).

    Limits (checked from the text itself): > 64 MB or > 500k faces
    -> ``E820`` and an empty ``Program``.
    """
    size = len(text.encode("utf-8", "surrogatepass"))
    if size > MAX_OBJ_BYTES:
        _error(bag, "E820", f"OBJ input is {size} bytes, over the "
               f"{MAX_OBJ_BYTES}-byte (64 MB) limit",
               span=Span(_OBJ_SOURCE, 1, 1),
               why="oversized assets are a security/resource limit, "
               "not a scene the compiler will de-index",
               help="split or simplify the model and try again")
        return Program(statements=[], span=None)

    lines = text.splitlines()
    face_count = sum(
        1 for line in lines if line.split(None, 1)[:1] == ["f"]
    )
    if face_count > MAX_OBJ_FACES:
        _error(bag, "E820", f"OBJ input has {face_count} faces, over the "
               f"{MAX_OBJ_FACES}-face limit",
               span=Span(_OBJ_SOURCE, 1, 1),
               why="oversized assets are a security/resource limit, "
               "not a scene the compiler will de-index",
               help="split or simplify the model and try again")
        return Program(statements=[], span=None)

    vertices: list[list[float]] = []
    triangles: list[dict] = []
    for lineno, raw in enumerate(lines, start=1):
        parts = raw.split()
        if not parts or parts[0].startswith("#"):
            continue
        keyword, args = parts[0], parts[1:]
        span = Span(_OBJ_SOURCE, lineno, 1)
        if keyword == "v":
            if len(args) < 3:
                _error(bag, "E101", f"line {lineno}: 'v' needs 3 coordinates",
                       span=span)
                continue
            try:
                vertices.append([float(args[0]), float(args[1]), float(args[2])])
            except ValueError:
                _error(bag, "E101", f"line {lineno}: bad vertex number "
                       f"in {' '.join(args[:3])!r}", span=span)
        elif keyword == "f":
            if len(args) < 3:
                _error(bag, "E101", f"line {lineno}: face needs at least "
                       "3 corners", span=span)
                continue
            corners: list[int] | None = []
            for token in args:
                fields = token.split("/")
                if len(fields) > 3 or fields[0] == "":
                    corners = None
                    break
                try:
                    index = int(fields[0])
                except ValueError:
                    corners = None
                    break
                if index == 0:
                    corners = None
                    break
                # OBJ: positive = 1-based absolute; negative = relative
                # to the most recently defined vertex.
                resolved = index - 1 if index > 0 else len(vertices) + index
                if resolved < 0 or resolved >= len(vertices):
                    _error(bag, "E301", f"line {lineno}: vertex index {index} "
                           f"out of range (1..{len(vertices)})", span=span)
                    corners = None
                    break
                corners.append(resolved)
            if corners is None:
                continue
            # Fan triangulation: (c0, ci, ci+1) for i = 1 .. n-2.
            for i in range(1, len(corners) - 1):
                tri_verts = [list(vertices[corners[0]]),
                             list(vertices[corners[i]]),
                             list(vertices[corners[i + 1]])]
                triangles.append({"v": tri_verts})
        # Everything else (vt/vn/o/g/s/usemtl/mtllib/unknown) is ignored;
        # in particular mtllib is never opened (P26: declarative only).
    return _tris_program(triangles)
