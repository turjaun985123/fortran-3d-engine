"""Forge3D Wave E extension: skinning + morph statements (C1).

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan rule
4: new features register, they do not edit the frozen IR). It owns the
Wave E skinning / morph surface; the compiler coordinator wires
``parser.py`` / ``validate.py`` / ``emit`` to call it.

Scope is parsing / validation / emit only, exactly like the other
``ext_*`` modules: the per-vertex math lives in the Fortran skinning
pass (``src/skinning.f90``) and its JS mirror, never here. This module
only documents that math (below), validates the statements that ask
for it, and emits the ``.scene`` lines the runtime consumes.

User syntax (frozen, ``.f3d``)::

    morph <target> <kind> <factor>
    bone <name> [at x,y,z] [rotate rx,ry,rz] [radius r]
    skin <target> <bonename>

Grammar summary:

* ``morph`` -- deform the object / group named ``<target>``.
  ``<kind>`` is one of ``bulge``, ``taper`` or ``squash`` (see
  ``MORPH_KINDS``). ``<factor>`` is a number in the range -2..2.
  There is no default factor: a morph line must give one.
* ``bone`` -- declare a named skinning pivot. ``at`` is the pivot
  position (default ``0,0,0``), ``rotate`` is the pivot rotation in
  degrees (default ``0,0,0``) and ``radius`` is the influence radius
  (default ``2``); ``radius`` must be more than 0. Bone names must be
  unique within a scene.
* ``skin`` -- bind the object / group named ``<target>`` to the bone
  named ``<bonename>``. The bone must already be known (declared by a
  ``bone`` statement); binding to an unknown bone is an error.

Morph semantics (implemented by Fortran ``skinning.f90`` + JS mirror;
documented here so the compiler surface and the runtimes agree):

* ``bulge``: barrel profile — x/z scale s = 1 + factor*0.5*(1 - q^2), q = (y - cy)/halfh, strongest at the middle height, poles unchanged
  (``cy`` is the centroid y and ``halfh`` is the largest
  ``|y - cy|`` over all vertices; y itself is unchanged).
* ``taper``: scales x/z by ``1 - factor * 0.5 * h``, where ``h`` is
  the normalised height of the vertex (0 at the base, 1 at the top).
* ``squash``: scales y by ``1 - 0.5 * factor`` and x/z by
  ``1 + 0.25 * factor`` (a volume-ish squash / stretch).

Skinning semantics (same owners as above): for each vertex the weight
is ``smoothstep(clamp(1 - dist_to_pivot / radius))`` -- 1 at the
bone's pivot, falling smoothly to 0 at ``radius`` -- and the vertex
is blended toward the bone's pivot-rotation transform by that weight.

``.scene`` lines emitted::

    morph OBJ KIND FACTOR
    bone NAME px py pz rx ry rz radius
    skin OBJ BONENAME

Public API (the exact names the coordinator wires to)::

    MORPH_KINDS = ('bulge', 'taper', 'squash')
    validate_morph(d) -> list[str]
    validate_bone(d, existing_names=None) -> list[str]
    validate_skin(d, known_bones=None) -> list[str]
    scene_lines(morphs, bones, skins) -> list[str]

plus the usual ``ext_*`` helpers ``extract_morph`` / ``extract_bone``
/ ``extract_skin`` and the per-statement ``morph_line`` /
``bone_line`` / ``skin_line`` emitters.

Normalised shapes (plain dicts in, like ``ext_post``)::

    morph  {"target": str, "kind": str, "factor": float}
    bone   {"name": str, "at": (x, y, z), "rotate": (rx, ry, rz),
            "radius": float}
    skin   {"target": str, "bone": str}

For a bone, ``at`` / ``rotate`` / ``radius`` are always present in
the normalised shape: the frozen defaults (``0,0,0`` / ``0,0,0`` /
``2``) are filled in by ``extract_bone`` when the statement gave none,
and ``bone_line`` / ``scene_lines`` apply the same defaults when
handed a raw dict directly.

All functions are defensive, pure and side-effect free. Error strings
are plain human-readable messages (no diagnostic codes):
``validate`` wraps them in E301-family diagnostics, exactly as for
``ext_post`` / ``ext_cameras`` / ``ext_materials``.
"""

from __future__ import annotations

import math

__all__ = [
    "MORPH_KINDS",
    "MORPH_KIND_NAMES",
    "FACTOR_MIN",
    "FACTOR_MAX",
    "DEFAULT_AT",
    "DEFAULT_ROTATE",
    "DEFAULT_RADIUS",
    "extract_morph",
    "extract_bone",
    "extract_skin",
    "validate_morph",
    "validate_bone",
    "validate_skin",
    "morph_line",
    "bone_line",
    "skin_line",
    "scene_lines",
]

# ---------------------------------------------------------------------------
# Frozen surface
# ---------------------------------------------------------------------------
#: Morph kinds in declaration order.
MORPH_KINDS = ("bulge", "taper", "squash")

#: Same kinds as a set, for membership checks.
MORPH_KIND_NAMES = frozenset(MORPH_KINDS)

#: Frozen factor range for every morph kind.
FACTOR_MIN = -2.0
FACTOR_MAX = 2.0

#: Frozen bone defaults.
DEFAULT_AT = (0.0, 0.0, 0.0)
DEFAULT_ROTATE = (0.0, 0.0, 0.0)
DEFAULT_RADIUS = 2.0

# Accepted dict spellings, in priority order.
_TARGET_KEYS = ("target", "object", "obj", "name")
_KIND_KEYS = ("kind", "type")
_FACTOR_KEYS = ("factor", "amount", "value")
_BONE_NAME_KEYS = ("name", "bone", "bonename", "bone_name")
_SKIN_BONE_KEYS = ("bone", "bonename", "bone_name", "name")
_AT_KEYS = ("at", "position", "pos", "pivot")
_ROTATE_KEYS = ("rotate", "rotation", "rot")
_RADIUS_KEYS = ("radius", "influence")


# ---------------------------------------------------------------------------
# Generic value helpers (same tolerant shapes as ext_cameras / ext_post)
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
    defaulted) so the validators can report them, mirroring
    ``ext_cameras._as_number``.
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


def _word(value):
    """Normalise a name word: stripped string (case preserved).

    Accepts a plain string / number, or a token-ish object carrying
    the word in a ``text`` / ``value`` / ``name`` attribute (the
    lexer's ``Token.text`` shape). Anything else gives ``""``.
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip().strip("\"'").strip()
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value).strip()
    for attr in ("text", "value", "name"):
        inner = getattr(value, attr, None)
        if isinstance(inner, str) and inner.strip():
            return inner.strip().strip("\"'").strip()
    return ""


def _kind(value):
    """Normalise a morph kind: stripped, lower-cased string."""
    return _word(value).lower()


def _vec3(value):
    """Coerce *value* to an ``(x, y, z)`` tuple, else ``None``.

    Accepts a 3-sequence, an ``"x,y,z"`` / ``"x y z"`` string, a dict
    with ``x``/``y``/``z`` keys, or an object with ``x``/``y``/``z``
    attributes. Components are float-converted where possible and
    otherwise passed through unchanged, so validation can name them.
    A sequence / string of any other arity gives ``None`` (bad vec3
    arity), exactly as in ``ext_cameras``.
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
        if len(value) != 3:
            return None
        return tuple(_as_number(v) for v in value)
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


def _vec_or(value, default):
    vec = _vec3(value)
    if vec is None:
        return tuple(default)
    return tuple(_float_or(component, 0.0) for component in vec)


def _known_bone_names(known_bones):
    """Normalise a known-bones collection to a set of name strings.

    Accepts a set / list / tuple of bone-name strings, of bone dicts
    (their ``name`` is read), or a single name / dict. ``None`` gives
    ``None`` (no known set was supplied, so no unknown-bone check).
    """
    if known_bones is None:
        return None
    if isinstance(known_bones, (str, dict)):
        known_bones = [known_bones]
    names = set()
    if isinstance(known_bones, (set, frozenset, list, tuple)):
        for item in known_bones:
            if isinstance(item, dict):
                name = _word(_first(_lower_keys(item), *_BONE_NAME_KEYS))
            else:
                name = _word(item)
            if name:
                names.add(name)
    return names


# ---------------------------------------------------------------------------
# Extract (raw props -> normalised dicts; bone defaults filled here)
# ---------------------------------------------------------------------------
def extract_morph(props) -> dict:
    """Normalise one raw ``morph`` statement into a morph dict. Pure.

    ``props`` is a plain dict such as ``{"target": "hero", "kind":
    "bulge", "factor": 0.5}`` (``object`` / ``obj`` are accepted
    target spellings, ``type`` a kind spelling, ``amount`` / ``value``
    factor spellings). Returns ``{"target": str, "kind": str,
    "factor": float}`` with the kind lower-cased. An unconvertible /
    non-finite factor and an unknown kind are passed through unchanged
    so validation can report them rather than losing them here.
    ``props`` is never mutated.
    """
    shaped = _lower_keys(props)
    return {
        "target": _word(_first(shaped, *_TARGET_KEYS)),
        "kind": _kind(_first(shaped, *_KIND_KEYS)),
        "factor": _as_number(_first(shaped, *_FACTOR_KEYS)),
    }


def extract_bone(props) -> dict:
    """Normalise one raw ``bone`` statement into a bone dict. Pure.

    ``props`` is a plain dict such as ``{"name": "arm", "at": (1, 0,
    0), "rotate": (0, 0, 45), "radius": 2}`` (``at`` / ``rotate`` may
    also be ``"x,y,z"`` strings; ``position`` / ``rotation`` are
    accepted spellings). Returns ``{"name": str, "at": (x, y, z),
    "rotate": (rx, ry, rz), "radius": float}`` with the frozen
    defaults filled in for anything absent: ``at`` ``(0, 0, 0)``,
    ``rotate`` ``(0, 0, 0)``, ``radius`` ``2``. A present-but-malformed
    ``at`` / ``rotate`` / ``radius`` is passed through unchanged so
    validation can report it rather than losing it here. ``props`` is
    never mutated.
    """
    shaped = _lower_keys(props)
    at_raw = _first(shaped, *_AT_KEYS)
    rotate_raw = _first(shaped, *_ROTATE_KEYS)
    radius_raw = _first(shaped, *_RADIUS_KEYS)
    at = _vec3(at_raw)
    rotate = _vec3(rotate_raw)
    return {
        "name": _word(_first(shaped, *_BONE_NAME_KEYS)),
        "at": DEFAULT_AT if at_raw is None
        else (at if at is not None else at_raw),
        "rotate": DEFAULT_ROTATE if rotate_raw is None
        else (rotate if rotate is not None else rotate_raw),
        "radius": DEFAULT_RADIUS if radius_raw is None
        else _as_number(radius_raw),
    }


def extract_skin(props) -> dict:
    """Normalise one raw ``skin`` statement into a skin dict. Pure.

    ``props`` is a plain dict such as ``{"target": "hero", "bone":
    "arm"}`` (``object`` / ``obj`` are accepted target spellings;
    ``bonename`` / ``bone_name`` are accepted bone spellings).
    Returns ``{"target": str, "bone": str}``. ``props`` is never
    mutated.
    """
    shaped = _lower_keys(props)
    target = _word(_first(shaped, *_TARGET_KEYS))
    # "name" names the target in a skin dict, never the bone, so the
    # bone lookup uses only the unambiguous spellings when a target
    # spelling was present; fall back to "name" only if nothing else
    # identifies the target.
    bone_raw = _first(shaped, "bone", "bonename", "bone_name")
    if bone_raw is None and not target:
        bone_raw = shaped.get("name")
    return {"target": target, "bone": _word(bone_raw)}


# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
def _validate_vec3(errors, owner, key, value):
    """Append errors for a present vec3 prop *value* of bone *owner*."""
    if value is None:
        return
    vec = _vec3(value)
    if vec is None:
        errors.append(
            "bone %r %s %r is not a vec3: '%s' must be three finite "
            "coordinates (x, y, z)" % (owner, key, value, key))
        return
    for axis, component in zip(("x", "y", "z"), vec):
        number = _as_number(component)
        if isinstance(number, bool) \
                or not isinstance(number, (int, float)):
            errors.append(
                "bone %r %s %s %r is not a number: '%s' coordinates "
                "must be finite numbers" % (owner, key, axis, component,
                                            key))
        elif not math.isfinite(float(number)):
            errors.append(
                "bone %r %s %s is %s, but '%s' coordinates must be "
                "finite" % (owner, key, axis, "%.6g" % float(number),
                            key))


def validate_morph(d) -> list[str]:
    """Return human-readable errors for a morph dict.

    Checks: ``target`` names an object / group; ``kind`` is one of
    bulge / taper / squash; and ``factor`` is a finite number in the
    range -2..2. Each message names the offending property. An empty
    list means valid.
    """
    errors = []
    if not isinstance(d, dict):
        return ["morph %r is not a morph dict: a morph must have "
                "'target', 'kind' and 'factor'" % (d,)]
    shaped = _lower_keys(d)
    target = _word(_first(shaped, *_TARGET_KEYS))
    if not target:
        errors.append(
            "morph has no target: 'morph' must name an object or "
            "group to deform")
    kind_raw = _first(shaped, *_KIND_KEYS)
    kind = _kind(kind_raw)
    if not kind:
        errors.append(
            "morph %r has no kind: 'morph' kind must be one of %s"
            % (target or "?", ", ".join(MORPH_KINDS)))
    elif kind not in MORPH_KIND_NAMES:
        errors.append(
            "morph %r kind %r is unknown: 'morph' kind must be one "
            "of %s" % (target or "?", kind_raw, ", ".join(MORPH_KINDS)))
    factor_raw = _first(shaped, *_FACTOR_KEYS)
    if factor_raw is None:
        errors.append(
            "morph %r has no factor: 'morph' factor must be a number "
            "in the range -2..2" % (target or "?",))
        return errors
    factor = _as_number(factor_raw)
    if isinstance(factor, bool) or not isinstance(factor, (int, float)):
        errors.append(
            "morph %r factor %r is not a number: 'morph' factor must "
            "be a number in the range -2..2" % (target or "?", factor_raw))
    elif not math.isfinite(float(factor)):
        errors.append(
            "morph %r factor is %s, but 'morph' factor must be a "
            "finite number in the range -2..2"
            % (target or "?", "%.6g" % float(factor)))
    elif not (FACTOR_MIN <= float(factor) <= FACTOR_MAX):
        errors.append(
            "morph %r factor is %s, but 'morph' factor must be in "
            "the range -2..2" % (target or "?", "%.6g" % float(factor)))
    return errors


def validate_bone(d, existing_names=None) -> list[str]:
    """Return human-readable errors for a bone dict.

    Checks: ``name`` names the bone and, when *existing_names* (a set
    of bone names already declared) is given, is not a duplicate of
    one of them; ``at`` / ``rotate``, when present, are vec3s of three
    finite numbers (bad vec3 arity and non-numeric / non-finite
    components are reported); and ``radius``, when present, is a
    finite number more than 0. Missing ``at`` / ``rotate`` /
    ``radius`` are not errors: the frozen defaults (``0,0,0`` /
    ``0,0,0`` / ``2``) apply. Each message names the offending
    property. An empty list means valid.
    """
    errors = []
    if not isinstance(d, dict):
        return ["bone %r is not a bone dict: a bone must have a "
                "'name'" % (d,)]
    shaped = _lower_keys(d)
    name = _word(_first(shaped, *_BONE_NAME_KEYS))
    if not name:
        errors.append("bone has no name: 'bone' must name the bone")
        owner = "?"
    else:
        owner = name
        existing = _known_bone_names(existing_names)
        if existing is not None and name in existing:
            errors.append(
                "bone %r is a duplicate: a bone named %r already "
                "exists" % (name, name))
    _validate_vec3(errors, owner, "at", _first(shaped, *_AT_KEYS))
    _validate_vec3(errors, owner, "rotate",
                   _first(shaped, *_ROTATE_KEYS))
    radius_raw = _first(shaped, *_RADIUS_KEYS)
    if radius_raw is not None:
        radius = _as_number(radius_raw)
        if isinstance(radius, bool) \
                or not isinstance(radius, (int, float)):
            errors.append(
                "bone %r radius %r is not a number: 'radius' must be "
                "more than 0" % (owner, radius_raw))
        elif not math.isfinite(float(radius)):
            errors.append(
                "bone %r radius is %s, but 'radius' must be a finite "
                "number more than 0" % (owner, "%.6g" % float(radius)))
        elif float(radius) <= 0.0:
            errors.append(
                "bone %r radius is %s, but 'radius' must be more "
                "than 0" % (owner, "%.6g" % float(radius)))
    return errors


def validate_skin(d, known_bones=None) -> list[str]:
    """Return human-readable errors for a skin dict.

    Checks: ``target`` names an object / group; ``bone`` names a bone;
    and, when *known_bones* is given (a set / list of known bone
    names, or of bone dicts), that bone is among them -- a skin
    binding referencing an unknown bone is an error. Each message
    names the offending property. An empty list means valid.
    """
    errors = []
    if not isinstance(d, dict):
        return ["skin %r is not a skin dict: a skin binding must have "
                "'target' and 'bone'" % (d,)]
    shaped = _lower_keys(d)
    target = _word(_first(shaped, *_TARGET_KEYS))
    if not target:
        errors.append(
            "skin has no target: 'skin' must name an object or group "
            "to bind")
    bone_raw = _first(shaped, "bone", "bonename", "bone_name")
    if bone_raw is None and not target:
        bone_raw = shaped.get("name")
    bone = _word(bone_raw)
    if not bone:
        errors.append(
            "skin %r has no bone: 'skin' must name a bone to bind to"
            % (target or "?",))
        return errors
    known = _known_bone_names(known_bones)
    if known is not None and bone not in known:
        errors.append(
            "skin %r references unknown bone %r: 'skin' bone must be "
            "a declared bone" % (target or "?", bone))
    return errors


# ---------------------------------------------------------------------------
# Emit lines
# ---------------------------------------------------------------------------
def morph_line(d) -> str:
    """Serialise a morph dict to its ``.scene`` line::

        morph OBJ KIND FACTOR

    The factor is formatted ``%.6g`` (the .scene float spelling every
    other ``ext_*`` emitter uses); a missing / unusable factor emits
    as ``0``.
    """
    d = extract_morph(d) if isinstance(d, dict) else {}
    return "morph %s %s %s" % (
        d["target"], d["kind"], _fmt(_float_or(d["factor"], 0.0)))


def bone_line(d) -> str:
    """Serialise a bone dict to its ``.scene`` line::

        bone NAME px py pz rx ry rz radius

    All numbers are formatted ``%.6g``. Missing ``at`` / ``rotate`` /
    ``radius`` fall back to the frozen defaults (``0,0,0`` /
    ``0,0,0`` / ``2``), so a bare ``{"name": ...}`` dict emits a
    complete line.
    """
    d = extract_bone(d) if isinstance(d, dict) else {}
    at = _vec_or(d.get("at"), DEFAULT_AT)
    rotate = _vec_or(d.get("rotate"), DEFAULT_ROTATE)
    radius = _float_or(d.get("radius"), DEFAULT_RADIUS)
    return "bone %s %s %s %s" % (
        d["name"],
        " ".join(_fmt(c) for c in at),
        " ".join(_fmt(c) for c in rotate),
        _fmt(radius),
    )


def skin_line(d) -> str:
    """Serialise a skin dict to its ``.scene`` line::

        skin OBJ BONENAME
    """
    d = extract_skin(d) if isinstance(d, dict) else {}
    return "skin %s %s" % (d["target"], d["bone"])


def _as_list(items):
    """A list of statement dicts from *items* (single dict wrapped)."""
    if items is None:
        return []
    if isinstance(items, dict):
        return [items]
    if isinstance(items, (list, tuple)):
        return list(items)
    return [items]


def scene_lines(morphs, bones, skins) -> list[str]:
    """Serialise morphs, bones and skins to their ``.scene`` lines.

    Each argument is a list of plain dicts as shaped by
    ``extract_morph`` / ``extract_bone`` / ``extract_skin`` (raw dicts
    work too: bone defaults are filled in here). Lines are emitted in
    argument order -- every morph, then every bone, then every skin --
    preserving the input order within each group, so bones are always
    declared before the skins that bind to them. ``None`` / empty
    groups contribute no lines.
    """
    lines = []
    lines.extend(morph_line(d) for d in _as_list(morphs))
    lines.extend(bone_line(d) for d in _as_list(bones))
    lines.extend(skin_line(d) for d in _as_list(skins))
    return lines
