"""Forge3D JSON emission: native v2 scene dump + legacy v1 triangles.

Seat B13 (``docs/plan/MASTER-PLAN.md`` / P04 section 6.2).  Stdlib only.

Two dialects:

* **v2** -- :func:`emit_json_v2`: the frozen IR serialisation from
  ``ir_nodes.to_dict`` plus a format stamp
  ``{'format': 'forge3d-scene', 'version': 2}``, pretty-printed with
  ``indent=1`` and sorted keys, so the output is deterministic
  (byte-identical for equal IR).  It round-trips through
  ``ir_nodes.from_json`` (which ignores the stamp keys).

* **legacy v1** -- :func:`emit_json_legacy`: exactly the flat shape the
  original Fortran ``export_mesh_json`` (``src/mesh.f90``) wrote and the
  current viewer consumes::

      {"triangles": [{"id": n, "v": [[x, y, z], [x, y, z], [x, y, z]],
                      "color": [r, g, b]}]}

  with 1-based sequential ``id`` across the whole scene.  v1 has no
  transform / camera fields, so supported objects are flattened to
  world-space triangles:

  - ``prim == 'tris'`` objects contribute their raw triangles with **no
    transform applied** -- compat data (legacy JSON / OBJ, see
    ``compat.py``) is already in world form, with transforms baked into
    the vertices by construction, so applying the object's
    scale/rotate/pos again would double-transform it.
  - ``prim == 'cube'`` objects are tessellated here in Python (12
    triangles, mirroring ``create_cube`` in ``src/mesh.f90``) and their
    scale / rotate / translate *is* applied (see :func:`_transform`).
  - Any other primitive is skipped, with one ``W202`` warning per
    object reported through ``bag`` when a bag is provided.

``emit_common.py`` (seat B11) had not landed when this module was
written, so the small helpers needed here (matrix math, warning
reporting) are self-contained in this file rather than imported.
"""

from __future__ import annotations

import json
import math

try:  # package import (tools.f3dc as a package)
    from .ir_nodes import PALETTE_FACES, to_dict
except ImportError:  # flat module layout: tools/f3dc on sys.path
    from ir_nodes import PALETTE_FACES, to_dict  # type: ignore

try:
    from .errors import Diagnostic
except Exception:  # pragma: no cover - flat layout fallback
    try:
        from errors import Diagnostic  # type: ignore
    except Exception:
        Diagnostic = None  # type: ignore

__all__ = [
    "FORMAT_NAME",
    "FORMAT_VERSION",
    "emit_json",
    "emit_json_v2",
    "emit_json_legacy",
]

FORMAT_NAME = "forge3d-scene"
FORMAT_VERSION = 2

#: Fallback colour for raw 'tris' triangles that carry no colour of
#: their own and whose object has none set (validate.py's default).
_DEFAULT_COLOR = (255, 255, 255)


# ---------------------------------------------------------------------------
# v2 -- native IR dump
# ---------------------------------------------------------------------------
def emit_json_v2(ir) -> str:
    """Serialise *ir* as a stamped, deterministic v2 JSON string."""
    data = to_dict(ir)
    data["format"] = FORMAT_NAME
    data["version"] = FORMAT_VERSION
    return json.dumps(data, indent=1, sort_keys=True)


#: Alias: plain ``emit_json`` means the current (v2) dialect.
def emit_json(ir) -> str:
    return emit_json_v2(ir)


# ---------------------------------------------------------------------------
# Small 3x3 matrix helpers (degrees; Fortran compose order T*Ry*Rx*Rz*S)
# ---------------------------------------------------------------------------
def _mat_mul(a, b):
    return [
        [sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)]
        for i in range(3)
    ]


def _mat_vec(m, v):
    return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]


def _rot_x(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[1.0, 0.0, 0.0], [0.0, c, -s], [0.0, s, c]]


def _rot_y(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]]


def _rot_z(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]]


def _transform(obj, point):
    """Apply an object's scale -> rotate -> translate to *point*.

    Rotation composition matches the Fortran ``mat4_compose_trs``
    order ``T * Ry * Rx * Rz * S``: the point is scaled first, then
    rotated about Z, then X, then Y, then translated by ``pos``.
    """
    scale = _vec3(getattr(obj, "scale", None), (1.0, 1.0, 1.0))
    rotate = _vec3(getattr(obj, "rotate", None),
                   getattr(obj, "rotation", (0.0, 0.0, 0.0)))
    pos = _vec3(getattr(obj, "pos", None),
                getattr(obj, "position", (0.0, 0.0, 0.0)))
    scaled = [point[i] * scale[i] for i in range(3)]
    rot = _mat_mul(_rot_y(rotate[1]),
                   _mat_mul(_rot_x(rotate[0]), _rot_z(rotate[2])))
    out = _mat_vec(rot, scaled)
    return [out[i] + pos[i] for i in range(3)]


def _vec3(value, default):
    if value is None:
        return [float(c) for c in default]
    if isinstance(value, (int, float)):
        return [float(value)] * 3
    seq = list(value)
    return [float(seq[i]) for i in range(3)]


# ---------------------------------------------------------------------------
# W202 warning reporting (duck-typed bag, mirroring ir_nodes' approach)
# ---------------------------------------------------------------------------
def _warn_w202(bag, obj) -> None:
    if bag is None:
        return
    message = (
        "legacy JSON emit: skipping object %r with unsupported "
        "primitive %r (only 'cube' and 'tris' can be flattened to "
        "legacy triangles)" % (getattr(obj, "name", "?"),
                               getattr(obj, "prim", "?"))
    )
    if isinstance(bag, list):
        bag.append("W202: %s" % message)
        return
    if Diagnostic is not None and callable(getattr(bag, "add", None)):
        try:
            bag.add(Diagnostic(code="W202", severity="warning",
                               message=message, span=None))
            return
        except Exception:
            pass
    for method_name in ("add", "warning", "warn", "report", "append"):
        method = getattr(bag, method_name, None)
        if callable(method):
            for args in (("W202", message), (message,)):
                try:
                    method(*args)
                    return
                except TypeError:
                    continue
                except Exception:
                    return
    diagnostics = getattr(bag, "diagnostics", None)
    if isinstance(diagnostics, list):
        diagnostics.append("W202: %s" % message)


# ---------------------------------------------------------------------------
# Legacy v1 -- 'tris' objects (raw, already world-space: NO transform)
# ---------------------------------------------------------------------------
def _tris_triangles(obj):
    """Yield ``(verts, color)`` for a ``prim == 'tris'`` object's raw data.

    Raw triangles are dicts ``{'v': [[x, y, z] x3], 'color': [r, g, b]}``
    (colour optional, e.g. OBJ-sourced data), bare 3-vertex sequences,
    or ``(verts, color)`` pairs.  No transform is applied: compat data
    is already in world form (see module docstring).
    """
    raw = getattr(obj, "triangles", None)
    if raw is None:
        raw = getattr(obj, "tris", None)
    obj_color = getattr(obj, "color", None)
    for tri in raw or []:
        color = None
        verts = tri
        if isinstance(tri, dict):
            verts = tri.get("v", tri.get("verts", tri.get("vertices")))
            color = tri.get("color", tri.get("c"))
        elif (isinstance(tri, (list, tuple)) and len(tri) == 2
              and isinstance(tri[0], (list, tuple)) and tri[0]
              and isinstance(tri[0][0], (list, tuple))):
            verts, color = tri
        if verts is None or len(verts) != 3:
            continue
        if color is None:
            color = obj_color if obj_color is not None else _DEFAULT_COLOR
        yield (
            [[c for c in vertex] for vertex in verts],
            [int(c) for c in color],
        )


# ---------------------------------------------------------------------------
# Legacy v1 -- 'cube' objects (tessellated, transform applied)
# ---------------------------------------------------------------------------
# Face corner indices (0-based) in src/mesh.f90 create_cube order:
# south, east, north, west, top, bottom -- two triangles per face.
_CUBE_FACES = (
    (0, 2, 1), (0, 3, 2),    # south: (1,3,2) (1,4,3) 1-based
    (1, 6, 5), (1, 2, 6),    # east:  (2,7,6) (2,3,7)
    (5, 7, 4), (5, 6, 7),    # north: (6,8,5) (6,7,8)
    (4, 3, 0), (4, 7, 3),    # west:  (5,4,1) (5,8,4)
    (3, 6, 2), (3, 7, 6),    # top:   (4,7,3) (4,8,7)
    (4, 1, 5), (4, 0, 1),    # bottom:(5,2,6) (5,1,2)
)


def _cube_triangles(obj):
    """Yield ``(verts, color)`` for a cube, transform applied.

    Corners ``p1..p8`` match ``create_cube`` in ``src/mesh.f90``:
    ``(-h,-h,-h), (h,-h,-h), (h,h,-h), (-h,h,-h), (-h,-h,h),
    (h,-h,h), (h,h,h), (-h,h,h)`` -- with per-axis half extents from
    ``size3`` when set, else the scalar ``size`` for every axis.
    Face colours are the object's colour if set, else
    ``PALETTE_FACES`` in mesh.f90 order (south, east, north, west,
    top, bottom).
    """
    size3 = getattr(obj, "size3", None)
    if size3 is not None:
        half = [float(size3[i]) * 0.5 for i in range(3)]
    else:
        size = getattr(obj, "size", None)
        h = (2.0 if size is None else float(size)) * 0.5
        half = [h, h, h]
    hx, hy, hz = half
    corners = [
        (-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
        (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz),
    ]
    obj_color = getattr(obj, "color", None)
    for idx, face in enumerate(_CUBE_FACES):
        color = obj_color if obj_color is not None \
            else PALETTE_FACES[idx // 2]
        verts = [_transform(obj, corners[corner]) for corner in face]
        yield verts, [int(c) for c in color]


# ---------------------------------------------------------------------------
# Legacy v1 -- scene
# ---------------------------------------------------------------------------
def emit_json_legacy(ir, bag=None) -> str:
    """Serialise *ir* as a legacy v1 ``{"triangles": [...]}`` string.

    Only ``prim == 'tris'`` (raw, untransformed -- already world form)
    and ``prim == 'cube'`` (tessellated, transform applied) objects are
    emitted; any other primitive is skipped with a ``W202`` warning
    through *bag* if one is provided.  Triangle ``id`` values are
    1-based and sequential across the whole scene.
    """
    triangles = []
    for obj in getattr(ir, "objects", []) or []:
        prim = str(getattr(obj, "prim", "")).lower()
        if prim == "tris":
            source = _tris_triangles(obj)
        elif prim == "cube":
            source = _cube_triangles(obj)
        else:
            _warn_w202(bag, obj)
            continue
        for verts, color in source:
            triangles.append({
                "id": len(triangles) + 1,
                "v": verts,
                "color": color,
            })
    return json.dumps({"triangles": triangles}, indent=1)
