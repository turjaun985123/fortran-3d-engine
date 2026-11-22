"""Forge3D Wave D extension: extra geometry primitives.

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan rule
4: new features register, they do not edit the frozen IR). It owns the
Wave D geometry surface; ``parser.py`` / ``validate.py`` /
``emit_fortran.py`` / ``cli.py`` wire to it exactly the way they wire
to ``ext_post`` and friends for earlier waves.

User syntax (one word + obvious props; named colours and the generic
``at`` / ``rotate`` / ``scale`` / ``material`` props work through the
ordinary ``ObjectStmt`` path)::

    circle     [radius R] [segments N]                 R=1,   N=32
    ring       [radius|outer R] [inner R] [segments N] R=1, inner=0.5, N=32
    capsule    [radius R] [height H] [segments N]      R=0.5, H=2, N=16
    tube       [radius R] [segments N] path x,y,z ...  R=0.2, N=12
    lathe      [segments N] points x,y ...             N=24
    extrude    [extrude_depth D] shape x,y ...         D=0.5
    icosahedron / octahedron / tetrahedron / dodecahedron [radius R]  R=1
    torusknot  [radius R] [tube R] [segments N]
               [tube_segments N]                       R=1, tube=R*0.3,
                                                         N=48, tube N=max(6, N//4)

List props (``path`` / ``points`` / ``shape``): the parser has no
general list-prop syntax, so these three words are parsed minimally
in ``parser._object_props`` -- after the keyword, consecutive numbers
(comma-separated in the source, commas are ignored by the lexer) are
grouped into triples (``path``) or pairs (``points`` / ``shape``) and
stored in ``props`` under the keyword. Everything else about those
props (defaults, validation, triangle counts, emit payloads) lives
here.

``extrude`` depth: the plain word ``depth`` is NOT free -- it is
already a generic object prop (parser ``OBJECT_PROP_WORDS`` /
``_object_props``, checked in ``validate``), so the extrude spelling
is ``extrude_depth``. A ``depth`` prop on an ``extrude`` line is
still honoured as an alias when ``extrude_depth`` is absent.

Normalised shape (stored by ``validate`` in
``IRObject.extensions["geometry"]`` and on the IR object's own
``size`` / ``radius`` / ``height`` / ``segments`` fields, following
the frozen 20-token ``.scene`` object line)::

    {"prim": str, "radius": float|None, "height": float|None,
     "segments": int|None, "size": float|None,
     "inner": float|None, "outer": float|None,
     "tube": float|None, "tube_segments": int|None,
     "extrude_depth": float|None,
     "path": [(x, y, z), ...]|None, "points": [(x, y), ...]|None,
     "shape": [(x, y), ...]|None}

``.scene`` mapping (tokens 17-20 are SIZE RADIUS HEIGHT SEGMENTS):
circle RADIUS=radius; ring RADIUS=outer, SIZE=inner; capsule
RADIUS + HEIGHT; polyhedra RADIUS; torusknot RADIUS, SIZE=tube;
tube RADIUS + SEGMENTS with the path triples appended as tokens 21+;
lathe SEGMENTS with the point pairs appended as tokens 21+; extrude
HEIGHT=depth with the shape pairs appended as tokens 21+.

Error codes (existing families only, no new codes): unknown words on
an object line are the parser's existing ``E103``; every diagnostic
raised here is ``E301`` (the code ``validate`` already uses for bad
object dimension props -- size / radius / height / segments).
"""

from __future__ import annotations

import math

__all__ = [
    "GEOM_PRIMS",
    "GEOM_PRIM_SET",
    "DEFAULT_SEGMENTS",
    "POLY_PRIMS",
    "normalize_geometry",
    "validate_geometry",
    "estimate_triangles",
    "scene_extra_values",
    "fortran_module",
]

#: The ten Wave D primitives, in declaration order.
GEOM_PRIMS = ("circle", "ring", "capsule", "tube", "lathe", "extrude",
              "icosahedron", "octahedron", "tetrahedron",
              "dodecahedron", "torusknot")
GEOM_PRIM_SET = frozenset(GEOM_PRIMS)

POLY_PRIMS = ("icosahedron", "octahedron", "tetrahedron",
              "dodecahedron")

#: Default segment counts per primitive (polyhedra have none).
DEFAULT_SEGMENTS = {"circle": 32, "ring": 32, "capsule": 16,
                    "tube": 12, "lathe": 24, "torusknot": 48}

#: Fortran module that provides each primitive's ``create_*`` routine.
_FORTRAN_MODULES = {
    "circle": "geo_flat_3d", "ring": "geo_flat_3d",
    "capsule": "geo_capsule_3d", "tube": "geo_tube_3d",
    "lathe": "geo_lathe_3d", "extrude": "geo_extrude_3d",
    "icosahedron": "geo_poly_3d", "octahedron": "geo_poly_3d",
    "tetrahedron": "geo_poly_3d", "dodecahedron": "geo_poly_3d",
    "torusknot": "geo_torusknot_3d",
}

#: Props every object may carry (generic ObjectStmt path + Wave A).
_COMMON_PROPS = frozenset({
    "at", "pos", "position", "rotate", "rot", "scale", "material",
    "segments", "detail", "capped", "open", "texture", "colour",
    "color", "metalness", "roughness", "specular", "shininess",
    "name", "named",
})

#: Extra props allowed per primitive, on top of _COMMON_PROPS.
_PRIM_PROPS = {
    "circle": frozenset({"radius"}),
    "ring": frozenset({"radius", "outer", "inner"}),
    "capsule": frozenset({"radius", "height"}),
    "tube": frozenset({"radius", "path"}),
    "lathe": frozenset({"points"}),
    "extrude": frozenset({"shape", "extrude_depth", "depth"}),
    "icosahedron": frozenset({"radius"}),
    "octahedron": frozenset({"radius"}),
    "tetrahedron": frozenset({"radius"}),
    "dodecahedron": frozenset({"radius"}),
    "torusknot": frozenset({"radius", "tube", "tube_segments",
                            "rings"}),
}


def fortran_module(prim):
    """The Fortran module providing ``prim``'s create routine."""
    return _FORTRAN_MODULES.get(str(prim).lower())


# ---------------------------------------------------------------------------
# Tolerant value helpers
# ---------------------------------------------------------------------------
def _num(value, default=None):
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return default
    return default


def _int(value, default=None):
    number = _num(value, None)
    return default if number is None else int(number)


def _pairs(value, width):
    """Normalise a flat or nested number sequence to width-tuples.

    Returns ``None`` when *value* is not a usable sequence at all; a
    list (possibly empty) otherwise. A flat sequence whose length is
    not a multiple of *width* yields a trailing short tuple, which
    :func:`validate_geometry` reports.
    """
    if value is None:
        return None
    if not isinstance(value, (list, tuple)):
        return None
    items = list(value)
    if items and all(isinstance(it, (list, tuple)) for it in items):
        out = []
        for it in items:
            nums = [_num(c) for c in it]
            out.append(tuple(nums))
        return out
    nums = [_num(c) for c in items]
    return [tuple(nums[i:i + width])
            for i in range(0, len(nums), width)]


def _segments(props, prim):
    seg = _int(props.get("segments"), None)
    if seg is None:
        seg = DEFAULT_SEGMENTS.get(prim)
    return seg


# ---------------------------------------------------------------------------
# Normalisation
# ---------------------------------------------------------------------------
def normalize_geometry(prim, props):
    """Return the normalised geometry dict for *prim* + raw *props*."""
    prim = str(prim).lower()
    props = {str(k).lower(): v for k, v in (props or {}).items()}
    geom = {"prim": prim, "radius": None, "height": None,
            "segments": None, "size": None, "inner": None,
            "outer": None, "tube": None, "tube_segments": None,
            "extrude_depth": None, "path": None, "points": None,
            "shape": None}
    if prim == "circle":
        geom["radius"] = _num(props.get("radius"), 1.0)
        geom["segments"] = _segments(props, prim)
    elif prim == "ring":
        outer = _num(props.get("outer"), None)
        if outer is None:
            outer = _num(props.get("radius"), 1.0)
        geom["outer"] = outer
        geom["radius"] = outer
        geom["inner"] = _num(props.get("inner"), 0.5)
        geom["size"] = geom["inner"]
        geom["segments"] = _segments(props, prim)
    elif prim == "capsule":
        geom["radius"] = _num(props.get("radius"), 0.5)
        geom["height"] = _num(props.get("height"), 2.0)
        geom["segments"] = _segments(props, prim)
    elif prim == "tube":
        geom["radius"] = _num(props.get("radius"), 0.2)
        geom["segments"] = _segments(props, prim)
        geom["path"] = _pairs(props.get("path"), 3)
    elif prim == "lathe":
        geom["segments"] = _segments(props, prim)
        geom["points"] = _pairs(props.get("points"), 2)
    elif prim == "extrude":
        depth = _num(props.get("extrude_depth"), None)
        if depth is None:
            depth = _num(props.get("depth"), 0.5)
        geom["extrude_depth"] = depth
        geom["height"] = depth
        geom["shape"] = _pairs(props.get("shape"), 2)
    elif prim in POLY_PRIMS:
        geom["radius"] = _num(props.get("radius"), 1.0)
    elif prim == "torusknot":
        radius = _num(props.get("radius"), 1.0)
        geom["radius"] = radius
        tube = _num(props.get("tube"), None)
        # round() cleans binary noise (1 * 0.3 -> 0.30000000000000004)
        # so the .scene SIZE token spells the default plainly.
        geom["tube"] = tube if tube is not None else round(radius * 0.3, 10)
        geom["size"] = geom["tube"]
        seg = _segments(props, prim)
        geom["segments"] = seg
        tseg = _int(props.get("tube_segments"), None)
        if tseg is None:
            tseg = _int(props.get("rings"), None)
        if tseg is None:
            tseg = max(6, (seg or 48) // 4)
        geom["tube_segments"] = tseg
    return geom


# ---------------------------------------------------------------------------
# Validation -> list of (code, message); codes are the existing E301
# family validate uses for bad object dimension props.
# ---------------------------------------------------------------------------
def _check_positive(errors, prim, label, value):
    if value is None or not math.isfinite(value) or value <= 0:
        errors.append((
            "E301",
            "%s %s is %s, but it must be more than 0"
            % (prim, label, value)))


def _check_points(errors, prim, label, points, minimum, width):
    """Shared point-list checks; returns True when the list is usable."""
    if not points or len(points) < minimum:
        errors.append((
            "E301",
            "%s needs at least %d %s points, got %d; write e.g. "
            "%s %s" % (prim, minimum, label,
                       0 if not points else len(points), prim,
                       _EXAMPLES[prim])))
        return False
    ok = True
    for point in points:
        if len(point) != width or any(c is None or not math.isfinite(c)
                                      for c in point):
            errors.append((
                "E301",
                "%s %s points must be groups of %d plain numbers"
                % (prim, label, width)))
            ok = False
            break
    return ok


_EXAMPLES = {
    "tube": "path 0,0,0 1,1,0",
    "lathe": "points 0,0 0.5,1",
    "extrude": "shape 0,0 1,0 0,1",
}


def validate_geometry(prim, props, geom=None):
    """Validate raw *props* for *prim*; return [(code, message)]."""
    prim = str(prim).lower()
    if prim not in GEOM_PRIM_SET:
        return []
    props = {str(k).lower(): v for k, v in (props or {}).items()}
    if geom is None:
        geom = normalize_geometry(prim, props)
    errors = []
    allowed = _COMMON_PROPS | _PRIM_PROPS[prim]
    for key in sorted(props):
        if key not in allowed:
            errors.append((
                "E301",
                "%r is not a %s property; %s properties are: %s"
                % (key, prim, prim,
                   ", ".join(sorted(_PRIM_PROPS[prim])))))
    if prim in ("circle", "capsule") or prim in POLY_PRIMS:
        _check_positive(errors, prim, "radius", geom.get("radius"))
    if prim == "capsule":
        _check_positive(errors, prim, "height", geom.get("height"))
    if prim == "ring":
        _check_positive(errors, prim, "outer radius",
                        geom.get("outer"))
        inner = geom.get("inner")
        if inner is None or not math.isfinite(inner) or inner < 0:
            errors.append((
                "E301",
                "ring inner radius is %s, but it must be 0 or more"
                % (inner,)))
        elif geom.get("outer") is not None and inner >= geom["outer"]:
            errors.append((
                "E301",
                "ring inner radius %s must be smaller than the "
                "outer radius %s" % (inner, geom["outer"])))
    if prim == "tube":
        _check_positive(errors, prim, "radius", geom.get("radius"))
        _check_points(errors, prim, "path", geom.get("path"), 2, 3)
    if prim == "lathe":
        if _check_points(errors, prim, "profile", geom.get("points"),
                         2, 2):
            for point in geom["points"]:
                if point[0] < 0:
                    errors.append((
                        "E301",
                        "lathe point %s has a negative radius (%s); "
                        "lathe x values are radii and must be 0 or "
                        "more" % (", ".join("%g" % c for c in point),
                                  point[0])))
                    break
    if prim == "extrude":
        _check_positive(errors, prim, "extrude_depth",
                        geom.get("extrude_depth"))
        _check_points(errors, prim, "shape", geom.get("shape"), 3, 2)
    if prim == "torusknot":
        _check_positive(errors, prim, "radius", geom.get("radius"))
        _check_positive(errors, prim, "tube", geom.get("tube"))
    return errors


# ---------------------------------------------------------------------------
# Triangle estimates (exact formulas, Wave D contract)
# ---------------------------------------------------------------------------
def estimate_triangles(prim, props):
    """Exact per-primitive triangle estimate for the Wave D prims."""
    prim = str(prim).lower()
    props = {str(k).lower(): v for k, v in (props or {}).items()}
    geom = normalize_geometry(prim, props)
    seg = geom.get("segments")
    if prim == "circle":
        return 2 * seg
    if prim == "ring":
        return 4 * seg
    if prim == "capsule":
        rounded = int(math.ceil(seg / 4.0)) * 4
        hr = rounded // 4
        return 2 * rounded + 2 * rounded * (2 * hr - 1)
    if prim == "tube":
        npts = len(geom.get("path") or [])
        if npts < 2:
            return 0
        return (npts - 1) * seg * 2 + 2 * seg
    if prim == "lathe":
        npts = len(geom.get("points") or [])
        if npts < 2:
            return 0
        return (npts - 1) * seg * 2
    if prim == "extrude":
        npts = len(geom.get("shape") or [])
        if npts < 3:
            return 0
        return 4 * npts - 4
    if prim == "tetrahedron":
        return 4
    if prim == "octahedron":
        return 8
    if prim == "icosahedron":
        return 20
    if prim == "dodecahedron":
        return 36
    if prim == "torusknot":
        return seg * geom["tube_segments"] * 2
    return 0


# ---------------------------------------------------------------------------
# .scene trailing tokens (tokens 21+ of the object line)
# ---------------------------------------------------------------------------
def scene_extra_values(prim, geom):
    """Flat numbers appended after SEGMENTS for tube/lathe/extrude."""
    prim = str(prim).lower()
    if not isinstance(geom, dict):
        return []
    key = {"tube": "path", "lathe": "points",
           "extrude": "shape"}.get(prim)
    if key is None:
        return []
    out = []
    for point in geom.get(key) or []:
        out.extend(point)
    return out
