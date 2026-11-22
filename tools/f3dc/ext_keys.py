"""Forge3D Wave B extension: full keyframe tracks.

Stdlib only.  This module is an *extension* (see ``ir_nodes`` plan
rule 4: new features register, they do not edit the frozen IR).  It
owns the semantics of the Wave B keyframe surface; the coordinator
wires ``parser`` / ``validate`` / ``emit`` to call it.  Nothing here
imports the parser or mutates the frozen IR: the functions below work
on plain dicts (the shapes the coordinator produces) and are pure.

User syntax (frozen)::

    keys hero duration 4 loop pingpong
    key hero at 0 pos 0,0,0 rot 0,0,0 scale 1
    key hero at 2 pos 3,1,0 rot 0,90,0 scale 1.5 ease smooth
    key hero at 4 pos 0,0,0 rot 0,180,0 scale 1

Normalised shapes::

    headers: {target: {"duration": float | None, "loop": str}}

    keys: [{"target": str, "time": float, "pos": (x, y, z),
            "rot": (x, y, z), "scale": float, "ease": str}, ...]
          (``pos`` / ``rot`` / ``scale`` / ``ease`` may be missing)

    track: {"duration": float, "loop": str, "keys": [key, ...]}
          (keys sorted by time; a ``duration`` of 0.0 means the
          header gave no duration -- Fortran treats a duration
          <= 0 as the last key's time)

Public API (the compiler coordinator wires these exact names):

    build_tracks(headers, keys) -> dict
    validate_tracks(tracks) -> list[str]
    track_lines(target, track) -> list[str]
"""

from __future__ import annotations

import math

__all__ = [
    "LOOP_MODES",
    "EASES",
    "DEFAULT_LOOP",
    "build_tracks",
    "validate_tracks",
    "track_lines",
]

#: Loop modes a ``keys`` header may name.
LOOP_MODES = ("once", "forever", "pingpong")

#: Easing names a ``key`` may name.
EASES = ("linear", "smooth", "in", "out")

#: Loop mode used when a header (or a whole track) omits one.
DEFAULT_LOOP = "once"

_DEFAULT_POS = (0.0, 0.0, 0.0)
_DEFAULT_ROT = (0.0, 0.0, 0.0)
_DEFAULT_SCALE = 1.0
_DEFAULT_EASE = "linear"


# ---------------------------------------------------------------------------
# Generic value helpers (same tolerant shapes as ext_lights_env.py)
# ---------------------------------------------------------------------------
def _num(value, default=None):
    """Coerce *value* to a float, else *default*.

    Unlike ``ext_lights_env._num`` this keeps non-finite floats
    (``inf`` / ``nan``) as floats: ``build_tracks`` must not silently
    rewrite them, because ``validate_tracks`` is responsible for
    reporting them as non-finite.
    """
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return default
    return default


def _vec3(value, default):
    """Coerce *value* to an ``(x, y, z)`` float tuple, else *default*.

    Accepts a 3-sequence or an ``"x,y,z"`` / ``"x y z"`` string.
    """
    if value is None:
        return tuple(default)
    if isinstance(value, str):
        parts = value.replace(",", " ").split()
        if len(parts) != 3:
            return tuple(default)
        nums = [_num(part) for part in parts]
        return tuple(default) if any(n is None for n in nums) \
            else tuple(nums)
    if isinstance(value, (list, tuple)):
        if len(value) != 3:
            return tuple(default)
        nums = [_num(part) for part in value]
        return tuple(default) if any(n is None for n in nums) \
            else tuple(nums)
    return tuple(default)


def _word(value, default):
    """Normalise a mode/ease word: stripped, lower-cased, or *default*."""
    if value is None:
        return default
    text = str(value).strip().lower()
    return text if text else default


def _fmt(value):
    """Format a number with ``%.6g`` (the .scene float spelling)."""
    number = _num(value, 0.0)
    return "%.6g" % float(number)


def _is_finite_number(value):
    number = _num(value, None)
    return number is not None and math.isfinite(number)


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
def _normalise_key(raw):
    """Normalise one raw key dict, filling the frozen defaults."""
    raw = raw if isinstance(raw, dict) else {}
    return {
        "target": str(raw.get("target") or "").strip(),
        "time": _num(raw.get("time"), 0.0),
        "pos": _vec3(raw.get("pos"), _DEFAULT_POS),
        "rot": _vec3(raw.get("rot"), _DEFAULT_ROT),
        "scale": _num(raw.get("scale"), _DEFAULT_SCALE),
        "ease": _word(raw.get("ease"), _DEFAULT_EASE),
    }


def _header_fields(header):
    """``(duration, loop)`` for one raw header dict (defaults applied)."""
    header = header if isinstance(header, dict) else {}
    duration = _num(header.get("duration"), None)
    if duration is None:
        # No usable duration: 0.0 is the sentinel the Fortran side
        # reads as "use the last key's time".
        duration = 0.0
    return duration, _word(header.get("loop"), DEFAULT_LOOP)


def build_tracks(headers: dict, keys: list) -> dict:
    """Build normalised keyframe tracks from *headers* and *keys*.

    ``headers`` maps a target name to ``{"duration": float | None,
    "loop": str}`` and may be empty (or ``None``): a target with keys
    but no header gets duration 0.0 and loop ``once``.  ``keys`` is a
    list of raw key dicts as described in the module docstring;
    missing ``pos`` / ``rot`` / ``scale`` / ``ease`` fields default to
    ``(0, 0, 0)`` / ``(0, 0, 0)`` / ``1.0`` / ``linear``.

    Returns ``{target: {"duration": float, "loop": str, "keys":
    [...]}}`` with each track's keys sorted by time.  A target named
    only by a header is kept, with an empty key list, so that
    ``validate_tracks`` can report it (a header with no keys is an
    error).  Pure: neither argument is mutated.
    """
    tracks = {}
    if isinstance(headers, dict):
        for target, header in headers.items():
            name = str(target or "").strip()
            if not name:
                continue
            duration, loop = _header_fields(header)
            tracks[name] = {"duration": duration, "loop": loop,
                            "keys": []}
    if isinstance(keys, (list, tuple)):
        for raw in keys:
            key = _normalise_key(raw)
            name = key["target"]
            if not name:
                continue
            track = tracks.get(name)
            if track is None:
                track = {"duration": 0.0, "loop": DEFAULT_LOOP,
                         "keys": []}
                tracks[name] = track
            track["keys"].append(key)
    for track in tracks.values():
        track["keys"] = sorted(track["keys"],
                                key=lambda k: k["time"])
    return tracks


# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
def validate_tracks(tracks) -> list[str]:
    """Return human-readable errors for a normalised tracks dict.

    ``tracks`` is a dict as returned by ``build_tracks``.  Per target
    the checks are: at least one key (so a header with no keys is an
    error, while a target with keys but no header is fine); key times
    are finite, non-negative and -- after the sort ``build_tracks``
    applies -- strictly increasing, i.e. duplicate times are an
    error; every ``ease`` is one of ``linear`` / ``smooth`` / ``in`` /
    ``out``; every ``loop`` is one of ``once`` / ``forever`` /
    ``pingpong``; a duration greater than 0 must be at least the last
    key's time; every ``scale`` is greater than 0; and all numbers
    (duration, times, positions, rotations, scales) are finite.
    Each message names the target and the offending property.
    """
    errors = []
    if not isinstance(tracks, dict):
        return errors
    for target, track in tracks.items():
        name = str(target)
        if not isinstance(track, dict):
            errors.append(
                "track %r is not a track dict: a track must have "
                "'duration', 'loop' and 'keys'" % name)
            continue

        loop = _word(track.get("loop"), DEFAULT_LOOP)
        if loop not in LOOP_MODES:
            errors.append(
                "track %r has loop %r: 'loop' must be one of %s"
                % (name, track.get("loop"), ", ".join(LOOP_MODES)))

        duration = _num(track.get("duration"), None)
        if duration is not None and not math.isfinite(duration):
            errors.append(
                "track %r has duration %r: 'duration' must be finite"
                % (name, track.get("duration")))

        keys = track.get("keys")
        if not isinstance(keys, (list, tuple)) or not keys:
            errors.append(
                "track %r has no keys: a track requires at least 1 "
                "key (a 'keys' header with no 'key' lines is an error)"
                % name)
            continue

        seen_times = set()
        last_time = None
        for key in keys:
            if not isinstance(key, dict):
                errors.append(
                    "track %r has a key that is not a dict: each key "
                    "must have 'time', 'pos', 'rot', 'scale' and "
                    "'ease'" % name)
                continue

            when = _num(key.get("time"), None)
            if when is None or not math.isfinite(when):
                errors.append(
                    "track %r has a key with time %r: 'time' must "
                    "be finite" % (name, key.get("time")))
            else:
                if when < 0.0:
                    errors.append(
                        "track %r has a key at time %s: 'time' must "
                        "not be negative" % (name, _fmt(when)))
                if when in seen_times:
                    errors.append(
                        "track %r has duplicate key time %s: key "
                        "times must be strictly increasing (duplicate "
                        "times are an error)" % (name, _fmt(when)))
                seen_times.add(when)
                if last_time is None or when > last_time:
                    last_time = when

            for field in ("pos", "rot"):
                vec = key.get(field)
                if vec is None:
                    continue
                components = vec if isinstance(vec, (list, tuple)) \
                    else (vec,)
                for component in components:
                    if not _is_finite_number(component):
                        errors.append(
                            "track %r has a key at time %s with %s "
                            "component %r: '%s' values must be finite"
                            % (name, _fmt(when) if when is not None
                               else "?", field, component, field))
                        break

            scale = _num(key.get("scale"), None)
            if scale is None or not math.isfinite(scale):
                errors.append(
                    "track %r has a key at time %s with scale %r: "
                    "'scale' must be finite"
                    % (name, _fmt(when) if when is not None else "?",
                       key.get("scale")))
            elif scale <= 0.0:
                errors.append(
                    "track %r has a key at time %s with scale %s: "
                    "'scale' must be greater than 0"
                    % (name, _fmt(when) if when is not None else "?",
                       _fmt(scale)))

            ease = _word(key.get("ease"), _DEFAULT_EASE)
            if ease not in EASES:
                errors.append(
                    "track %r has a key at time %s with ease %r: "
                    "'ease' must be one of %s"
                    % (name, _fmt(when) if when is not None else "?",
                       key.get("ease"), ", ".join(EASES)))

        if duration is not None and math.isfinite(duration) \
                and duration > 0.0 and last_time is not None \
                and duration < last_time:
            errors.append(
                "track %r has duration %s before its last key at "
                "time %s: 'duration' must be at least the last key "
                "time" % (name, _fmt(duration), _fmt(last_time)))
    return errors


# ---------------------------------------------------------------------------
# Emit lines
# ---------------------------------------------------------------------------
def track_lines(target, track) -> list[str]:
    """Serialise one track to its ``.scene`` lines.

    Formats (floats ``%.6g``)::

        keys TARGET DURATION LOOP NKEYS
        key TIME PX PY PZ RX RY RZ SCALE EASE

    One ``key`` line per key, in the track's stored order (which
    ``build_tracks`` sorts by time).  A missing / ``None`` duration
    is emitted as 0 and a missing loop as ``once``.
    """
    track = track if isinstance(track, dict) else {}
    keys = track.get("keys")
    if not isinstance(keys, (list, tuple)):
        keys = []
    duration = _num(track.get("duration"), None)
    loop = _word(track.get("loop"), DEFAULT_LOOP)
    lines = ["keys %s %s %s %d" % (
        target, _fmt(0.0 if duration is None else duration),
        loop, len(keys))]
    for key in keys:
        key = key if isinstance(key, dict) else {}
        pos = _vec3(key.get("pos"), _DEFAULT_POS)
        rot = _vec3(key.get("rot"), _DEFAULT_ROT)
        scale = _num(key.get("scale"), _DEFAULT_SCALE)
        ease = _word(key.get("ease"), _DEFAULT_EASE)
        lines.append("key %s %s %s %s %s" % (
            _fmt(_num(key.get("time"), 0.0)),
            " ".join(_fmt(c) for c in pos),
            " ".join(_fmt(c) for c in rot),
            _fmt(scale), ease))
    return lines
