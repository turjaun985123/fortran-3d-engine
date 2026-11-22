"""Forge3D Wave C extension: ``camera ortho`` statements.

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan rule
4: new features register, they do not edit the frozen IR). It owns the
Wave C orthographic-camera surface (MASTER-PLAN parity row 3); the
compiler coordinator wires ``parser.py`` / ``validate.py`` / ``emit``
to call it.

User syntax (frozen)::

    camera ortho [size N] [at x,y,z] [look x,y,z] [fov ignored]

``ortho`` is a camera type modifier. ``size`` is the orthographic
frustum height in world units: it defaults to 5.0 and must be more
than 0. Perspective remains the default camera type (a plain
``camera ...`` line with no ``ortho``) and is representable in the
normalised shape too. ``fov`` is a perspective concept: on an ortho
line it is accepted by the existing camera parser and simply ignored
here (it is not carried into the normalised dict).

How the existing compiler handles ``camera`` today (read-only study):
``parser.py::_parse_camera`` already accepts the bare word ``ortho``
and stores ``props["ortho"] = True``, alongside ``at`` / ``look`` /
``up`` vec3 props and ``fov`` / ``near`` / ``far`` number props.
``validate.py`` then builds the ``IRCamera`` from ``at`` / ``look``
(with its own defaults) through that existing path. This extension
therefore only adds the *type + size* layer on top of those props:
``at`` / ``look`` continue through the existing camera path
unchanged, and :func:`camera_lines` emits only the extra ``.scene``
line the Fortran scene reader needs for an ortho camera.

Public API (the exact names the coordinator wires to)::

    extract_camera(props) -> dict
    validate_camera(d) -> list[str]
    camera_lines(d) -> list[str]
    DEFAULT_SIZE = 5.0

Normalised shape::

    {"type": "ortho" | "perspective", "size": float,
     "at": (x, y, z) | None, "look": (x, y, z) | None}

``size`` is always present (``DEFAULT_SIZE`` when the line gave
none); it is meaningful for ortho cameras and simply carried (unused)
for perspective ones. ``at`` / ``look`` are ``None`` when absent, so
the existing camera path keeps applying its own defaults.

All functions are defensive, pure and side-effect free. Error strings
are plain human-readable messages (no diagnostic codes): ``validate``
wraps them in diagnostics, exactly as for ``ext_particles`` /
``ext_materials`` / ``ext_lights_env`` / ``ext_sprites_text``.
"""

from __future__ import annotations

import math

__all__ = [
    "DEFAULT_SIZE",
    "CAMERA_TYPES",
    "extract_camera",
    "validate_camera",
    "camera_lines",
]

# ---------------------------------------------------------------------------
# Defaults (frozen by the Wave C seat brief)
# ---------------------------------------------------------------------------
DEFAULT_SIZE = 5.0

CAMERA_TYPES = ("ortho", "perspective")

# Spellings that name the orthographic type in a type-ish prop.
_ORTHO_WORDS = ("ortho", "orthographic")
_PERSPECTIVE_WORDS = ("perspective", "persp")


# ---------------------------------------------------------------------------
# Generic value helpers (same tolerant shapes as ext_particles)
# ---------------------------------------------------------------------------
def _lower_keys(props):
    """Return a copy of *props* with string keys lower-cased."""
    if not isinstance(props, dict):
        return {}
    return {str(k).lower(): v for k, v in props.items()}


def _first(props, *names):
    """First non-None value among *names* in *props*, else ``None``."""
    for name in names:
        if name in props and props[name] is not None:
            return props[name]
    return None


def _as_number(value):
    """Best-effort float conversion; unconvertible values pass through.

    Non-finite floats are kept as-is (instead of being silently
    defaulted) so ``validate_camera`` can report them, mirroring
    ``ext_particles._as_number``.
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return value
    return value


def _vec3(value):
    """Coerce *value* to an ``(x, y, z)`` tuple, else ``None``.

    Accepts a 3-sequence, an ``"x,y,z"`` / ``"x y z"`` string, a dict
    with ``x``/``y``/``z`` keys, or an object with ``x``/``y``/``z``
    attributes. Components are float-converted where possible and
    otherwise passed through unchanged, so validation can name them.
    (Same helper as ``ext_particles._vec3``.)
    """
    if value is None:
        return None
    if isinstance(value, str):
        parts = value.replace(",", " ").split()
        if len(parts) != 3:
            return None
        return tuple(_as_number(p) for p in parts)
    if isinstance(value, dict):
        lowered = _lower_keys(value)
        if any(axis not in lowered for axis in ("x", "y", "z")):
            return None
        return tuple(_as_number(lowered[axis]) for axis in ("x", "y", "z"))
    if isinstance(value, (list, tuple)):
        if len(value) < 3:
            return None
        return tuple(_as_number(v) for v in value[:3])
    if any(hasattr(value, axis) for axis in ("x", "y", "z")):
        return tuple(_as_number(getattr(value, axis, None))
                     for axis in ("x", "y", "z"))
    return None


def _fmt(value):
    """Format a number with ``%.6g`` (the .scene float spelling)."""
    number = _as_number(value)
    if isinstance(number, bool) or not isinstance(number, (int, float)):
        return "0"
    return "%.6g" % float(number)


def _float_or(value, default):
    number = _as_number(value)
    if isinstance(number, bool) or not isinstance(number, (int, float)):
        return default
    return float(number)


# ---------------------------------------------------------------------------
# Input normalisation: props dict, token sequence, or camera node
# ---------------------------------------------------------------------------
def _props_from_tokens(tokens):
    """Parse a raw token sequence / line string into a props dict.

    Accepts spellings such as ``["camera", "ortho", "size", "8",
    "at", "0,2,0", "look", "0,0,0"]``, ``["ortho", "size=8"]`` or the
    whole line as one string. Unknown words are ignored (the frozen
    parser owns diagnosing them); ``fov`` / ``near`` / ``far`` values
    are consumed so they cannot be mistaken for something else, then
    dropped -- ``fov`` is ignored for cameras, per the frozen syntax.
    """
    if isinstance(tokens, str):
        tokens = tokens.replace(",", " , ").split()
        # Re-join "x , y , z" triples back into single vec tokens.
        joined, i = [], 0
        while i < len(tokens):
            if i + 4 < len(tokens) and tokens[i + 1] == "," \
                    and tokens[i + 3] == ",":
                joined.append("%s,%s,%s" % (tokens[i], tokens[i + 2],
                                            tokens[i + 4]))
                i += 5
            else:
                joined.append(tokens[i])
                i += 1
        tokens = joined
    props = {}
    words = [str(t) for t in tokens]
    i = 0
    while i < len(words):
        word = words[i].strip().lower()
        key, eq, inline = word.partition("=")
        if eq and key in ("size", "at", "look", "fov", "near", "far",
                          "type"):
            props[key] = inline
            i += 1
        elif word in _ORTHO_WORDS:
            props["ortho"] = True
            i += 1
        elif word in _PERSPECTIVE_WORDS:
            props["type"] = "perspective"
            i += 1
        elif word in ("size", "at", "look"):
            if i + 1 < len(words):
                props[word] = words[i + 1]
                i += 2
            else:
                i += 1
        elif word in ("fov", "near", "far"):
            i += 2 if i + 1 < len(words) else 1
        else:
            # "camera" itself and anything unrecognised: skip.
            i += 1
    return props


def _props_from(source):
    """Best-effort raw props dict from any accepted input shape."""
    if source is None:
        return {}
    if isinstance(source, dict):
        return _lower_keys(source)
    if isinstance(source, (list, tuple, str)):
        return _props_from_tokens(source)
    # Duck-typed camera node: prefer its raw props dict (the shape
    # parser.py stores on CameraStmt), else read attributes.
    inner = getattr(source, "props", None)
    if isinstance(inner, dict):
        props = _lower_keys(inner)
    else:
        props = {}
    for name in ("ortho", "perspective", "type", "camera_type", "kind",
                 "size", "at", "position", "pos", "look", "target",
                 "look_at"):
        value = getattr(source, name, None)
        if value is not None and name not in props:
            props[name] = value
    return props


def _camera_type(props):
    """Resolve the camera type from raw *props* (default perspective)."""
    for name in ("type", "camera_type", "kind", "mode", "projection"):
        raw = props.get(name)
        if isinstance(raw, str):
            word = raw.strip().strip("\"'").strip().lower()
            if word in _ORTHO_WORDS:
                return "ortho"
            if word in _PERSPECTIVE_WORDS:
                return "perspective"
    ortho = props.get("ortho")
    if isinstance(ortho, str):
        if ortho.strip().lower() not in ("", "false", "no", "0"):
            return "ortho"
    elif ortho:
        return "ortho"
    if props.get("perspective"):
        return "perspective"
    return "perspective"


def _position(props, *names):
    """Vec3 for the first present name, else ``None``.

    A present-but-malformed value is passed through unchanged so
    ``validate_camera`` can report it rather than losing it here.
    """
    for name in names:
        if name in props and props[name] is not None:
            vec = _vec3(props[name])
            return vec if vec is not None else props[name]
    return None


# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------
def extract_camera(props) -> dict:
    """Normalise raw camera props into a camera dict. Pure.

    ``props`` is the raw property dict ``validate.py`` builds for one
    ``camera`` statement -- the shape ``parser.py::_parse_camera``
    produces, e.g. ``{"ortho": True, "size": 8, "at": (0, 2, 0),
    "look": (0, 0, 0), "fov": 60}`` (``at`` / ``look`` may also be
    ``"x,y,z"`` strings and ``size`` a numeric string). A raw token
    sequence or line string (``["camera", "ortho", "size", "8"]``)
    and a duck-typed camera node are accepted too, in the tolerant
    style of the other ``ext_*`` modules.

    Returns::

        {"type": "ortho" | "perspective", "size": float,
         "at": (x, y, z) | None, "look": (x, y, z) | None}

    The type is ``"ortho"`` when the ``ortho`` modifier is present
    (``props["ortho"]`` truthy, or a type-ish prop naming it) and
    ``"perspective"`` otherwise -- perspective is the default.
    ``size`` defaults to ``DEFAULT_SIZE`` (5.0); an unconvertible or
    non-finite size is passed through unchanged so validation can
    report it rather than losing it here. ``fov`` (and ``near`` /
    ``far`` / ``up``) are *not* carried into the dict: ``fov`` is
    ignored per the frozen syntax and the rest stay owned by the
    existing camera path. ``props`` is never mutated.
    """
    props = _props_from(props)
    cam_type = _camera_type(props)
    size = _as_number(_first(props, "size", "ortho_size"))
    if size is None:
        # Spelling ``ortho 8``: a numeric ortho prop carries the size.
        ortho_value = _as_number(props.get("ortho"))
        if isinstance(ortho_value, (int, float)) \
                and not isinstance(ortho_value, bool):
            size = ortho_value
    if size is None:
        size = DEFAULT_SIZE
    return {
        "type": cam_type,
        "size": size,
        "at": _position(props, "at", "position", "pos", "eye"),
        "look": _position(props, "look", "target", "look_at"),
    }


# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
def _validate_position(errors, d, key):
    if key not in d or d[key] is None:
        return
    vec = _vec3(d[key])
    if vec is None:
        errors.append(
            "%s %r is not a position: '%s' must be three finite "
            "coordinates (x, y, z)" % (key, d[key], key))
        return
    for axis, component in zip(("x", "y", "z"), vec):
        number = _as_number(component)
        if isinstance(number, bool) \
                or not isinstance(number, (int, float)):
            errors.append(
                "%s %s %r is not a number: '%s' coordinates must be "
                "finite" % (key, axis, component, key))
        elif not math.isfinite(float(number)):
            errors.append(
                "%s %s is %s, but '%s' coordinates must be finite"
                % (key, axis, "%.6g" % float(number), key))


def validate_camera(d) -> list[str]:
    """Return human-readable errors for a normalised camera dict.

    Checks: ``type``, when present, is ``"ortho"`` or
    ``"perspective"``; ``size``, when present, is a finite number
    more than 0 (the ortho frustum height in world units -- there is
    no frozen upper bound); and every ``at`` / ``look`` coordinate,
    when the position is present, is finite. Each message names the
    offending property. An empty list means valid.
    """
    errors = []
    if not isinstance(d, dict):
        return errors
    cam_type = d.get("type")
    if cam_type is None and d.get("ortho"):
        cam_type = "ortho"
    if cam_type is not None:
        word = str(cam_type).strip().lower()
        if word in _ORTHO_WORDS:
            word = "ortho"
        elif word in _PERSPECTIVE_WORDS:
            word = "perspective"
        if word not in CAMERA_TYPES:
            errors.append(
                "type %r is not a camera type: 'type' must be 'ortho' "
                "or 'perspective'" % (cam_type,))
    if "size" in d and d["size"] is not None:
        value = _as_number(d["size"])
        if isinstance(value, bool) \
                or not isinstance(value, (int, float)):
            errors.append(
                "size %r is not a number: 'size' must be more than 0"
                % (d["size"],))
        else:
            number = float(value)
            if not math.isfinite(number) or number <= 0.0:
                errors.append(
                    "size is %s, but 'size' must be more than 0"
                    % ("%.6g" % number,))
    _validate_position(errors, d, "at")
    _validate_position(errors, d, "look")
    return errors


# ---------------------------------------------------------------------------
# Emit lines
# ---------------------------------------------------------------------------
def camera_lines(d) -> list[str]:
    """Serialise a camera dict to its extra ``.scene`` lines.

    For an ortho camera this is the single line the Fortran scene
    reader will consume::

        ortho SIZE

    with ``SIZE`` formatted ``%.6g`` (the float spelling every other
    ``ext_*`` module uses), falling back to ``DEFAULT_SIZE`` when the
    dict carries no usable size. For a perspective camera it is
    ``[]``: perspective is the reader's default and needs no line.

    Only the ortho line is emitted here. ``at`` / ``look`` are *not*
    repeated: they continue through the existing camera path (the
    ``camera ...`` line ``validate.py`` / ``emit`` already produce
    from the same statement), so emitting them again would duplicate
    them.
    """
    if not isinstance(d, dict):
        return []
    cam_type = d.get("type")
    if cam_type is None:
        # Tolerate a raw props dict that never went through extract.
        cam_type = _camera_type(_lower_keys(d))
    if str(cam_type).strip().lower() not in _ORTHO_WORDS:
        return []
    return ["ortho %s" % _fmt(_float_or(d.get("size"), DEFAULT_SIZE))]
