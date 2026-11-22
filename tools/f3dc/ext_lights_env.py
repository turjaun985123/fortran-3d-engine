"""Forge3D Wave A extension: point/spot lights + scene environment.

Stdlib only.  This module owns the *semantics* of the Wave A light and
environment clauses; the coordinator wires ``validate`` / ``emit`` to
call it (validate.py still rejects non-directional/ambient lights with
E205 until that wiring lands).  Nothing here imports the parser or
mutates the frozen IR in ``ir_nodes.py``: the functions below work on
plain ``props`` dicts (the shape the parser produces for a statement)
and on plain normalised dicts, and they are pure.

User syntax (P03-style)::

    light point at 2,3,4 intensity 1.5 color red distance 10 decay 2
    light spot at 0,5,0 look 0,0,0 angle 30 penumbra 0.5 intensity 2

    fog linear near 5 far 20 color #aabbcc
    fog exp2 density 0.05
    tonemap aces exposure 1.2      |  tonemap reinhard  |  tonemap none
    shadow on  |  shadow soft  |  shadow off     (soft = PCF, size 512)

Notes on the light props:

* For point/spot lights ``from <vec3>`` IS the position -- unlike a
  directional light, whose ``from`` is negated into a direction by the
  parser, a point/spot position must never be negated.
* A spot's direction is not stored: it is derived at emit time as
  ``normalise(target - position)``.

Normalised shapes::

    light ext: {"position": (x, y, z) | None, "target": (x, y, z) | None,
                "distance": float, "decay": float,
                "angle": float (degrees), "penumbra": float}

    env: {"fog": None
                 | {"mode": "linear", "near": float, "far": float,
                    "color": (r, g, b)}
                 | {"mode": "exp2", "density": float,
                    "color": (r, g, b)},
          "tonemap": {"mode": "none" | "reinhard" | "aces",
                      "exposure": float},
          "shadow": {"mode": "off" | "on" | "soft", "size": int}}
"""

from __future__ import annotations

import math
import re

__all__ = [
    "WAVEA_LIGHT_KINDS",
    "extract_light_ext",
    "validate_light_ext",
    "light_line",
    "extract_env",
    "validate_env",
    "env_lines",
]

#: Light kinds made real by Wave A (v1 already has directional/ambient).
WAVEA_LIGHT_KINDS = ("point", "spot")

# Light-ext defaults (Three.js punctual-light defaults, per the brief).
_DEFAULT_DISTANCE = 0.0     # 0 = no distance cutoff
_DEFAULT_DECAY = 2.0        # physically-correct falloff exponent
_DEFAULT_ANGLE = 45.0       # spot cone half-angle, degrees
_DEFAULT_PENUMBRA = 0.0     # hard cone edge

# Environment defaults.
_DEFAULT_FOG_COLOR = (255, 255, 255)
_DEFAULT_FOG_NEAR = 0.0
_DEFAULT_FOG_FAR = 100.0    # matches the camera far-plane default
_DEFAULT_FOG_DENSITY = 0.05
_DEFAULT_EXPOSURE = 1.0
_DEFAULT_SHADOW_SIZE = 512

_TONEMAP_ALIASES = {
    "": "none",
    "off": "none",
    "none": "none",
    "reinhard": "reinhard",
    "aces": "aces",
    "acesfilmic": "aces",
    "aces_filmic": "aces",
    "aces-filmic": "aces",
}

_SHADOW_MODES = ("off", "on", "soft")


# ---------------------------------------------------------------------------
# Generic value helpers (same tolerant shapes as validate.py's adapters)
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


def _num(value, default=None):
    """Coerce *value* to a finite float, else *default*."""
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        try:
            number = float(value.strip())
        except ValueError:
            return default
    else:
        return default
    return number if math.isfinite(number) else default


def _vec3(value):
    """Coerce *value* to an ``(x, y, z)`` float tuple, else ``None``.

    Accepts a 3-sequence, an ``"x,y,z"`` / ``"x y z"`` string, a dict
    with ``x``/``y``/``z`` keys, or an object with ``x``/``y``/``z``
    attributes.
    """
    if value is None:
        return None
    if isinstance(value, str):
        parts = value.replace(",", " ").split()
        if len(parts) != 3:
            return None
        nums = [_num(p) for p in parts]
        return None if any(n is None for n in nums) else tuple(nums)
    if isinstance(value, dict):
        nums = [_num(value.get(axis)) for axis in ("x", "y", "z")]
        return None if any(n is None for n in nums) else tuple(nums)
    if isinstance(value, (list, tuple)):
        if len(value) < 3:
            return None
        nums = [_num(v) for v in value[:3]]
        return None if any(n is None for n in nums) else tuple(nums)
    nums = [_num(getattr(value, axis, None)) for axis in ("x", "y", "z")]
    return None if any(n is None for n in nums) else tuple(nums)


_NAMED_COLORS = {
    "red": (220, 60, 60), "green": (60, 220, 60), "blue": (60, 100, 240),
    "yellow": (240, 220, 50), "magenta": (200, 80, 220),
    "cyan": (60, 220, 220), "orange": (240, 140, 40),
    "purple": (140, 80, 200), "pink": (240, 150, 190),
    "white": (240, 240, 240), "black": (20, 20, 25),
    "gray": (140, 140, 145), "grey": (140, 140, 145),
}

_HEX_RE = re.compile(r"^#([0-9a-fA-F]{6})$")
_RGB_RE = re.compile(
    r"^rgb\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*\)$",
    re.IGNORECASE,
)


def _parse_color(value):
    """Resolve *value* to an ``(r, g, b)`` int tuple, else ``None``.

    Accepts a 3-sequence of channels, a named colour, ``'#rrggbb'`` or
    ``'rgb(r,g,b)'``.  Prefers the frozen table/parser in ``ir_nodes``
    when it is importable; the local fallback covers the same spellings
    so this module also works standalone.
    """
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        if len(value) != 3:
            return None
        channels = []
        for part in value:
            number = _num(part)
            if number is None or not (0.0 <= number <= 255.0):
                return None
            channels.append(int(round(number)))
        return tuple(channels)
    if not isinstance(value, str):
        return None
    try:  # frozen colour contract lives in ir_nodes (B08)
        try:
            from ir_nodes import parse_color as _ir_parse_color
        except Exception:
            from .ir_nodes import parse_color as _ir_parse_color
        parsed = _ir_parse_color(value)
        if parsed is not None:
            return tuple(int(c) for c in parsed)
        return None
    except Exception:
        pass
    text = value.strip()
    named = _NAMED_COLORS.get(text.lower())
    if named is not None:
        return tuple(named)
    match = _HEX_RE.match(text)
    if match:
        hexpart = match.group(1)
        return (int(hexpart[0:2], 16), int(hexpart[2:4], 16),
                int(hexpart[4:6], 16))
    match = _RGB_RE.match(text)
    if match:
        channels = tuple(int(match.group(i)) for i in (1, 2, 3))
        return channels if all(0 <= c <= 255 for c in channels) else None
    return None


def _fmt(value):
    """Format a number with ``%g`` (the .scene float spelling)."""
    return "%g" % float(value)


def _fmt_vec(vec):
    return " ".join(_fmt(c) for c in vec)


def _fmt_color(color):
    parsed = _parse_color(color)
    if parsed is None:
        parsed = (255, 255, 255)
    return "%d %d %d" % parsed


# ---------------------------------------------------------------------------
# Point / spot lights
# ---------------------------------------------------------------------------
def extract_light_ext(props: dict) -> dict:
    """Extract the Wave A light extension fields from *props*.  Pure.

    Position comes from ``at`` / ``position`` / ``from`` (in that
    order); for point/spot lights ``from`` IS the position and is
    never negated.  Target comes from ``look`` / ``target`` /
    ``look_at``.  Missing numerics fall back to the defaults:
    ``distance`` 0.0 (no cutoff), ``decay`` 2.0, ``angle`` 45.0
    degrees, ``penumbra`` 0.0.
    """
    props = _lower_keys(props)
    # A coordinator may nest the extension dict; flat keys win.
    nested = props.get("ext") or props.get("light_ext")
    if isinstance(nested, dict):
        merged = _lower_keys(nested)
        merged.update(props)
        props = merged
    return {
        "position": _vec3(_first(props, "at", "position", "from")),
        "target": _vec3(_first(props, "look", "target", "look_at")),
        "distance": _num(_first(props, "distance", "range"),
                         _DEFAULT_DISTANCE),
        "decay": _num(_first(props, "decay"), _DEFAULT_DECAY),
        "angle": _num(_first(props, "angle"), _DEFAULT_ANGLE),
        "penumbra": _num(_first(props, "penumbra"), _DEFAULT_PENUMBRA),
    }


def validate_light_ext(kind: str, ext: dict) -> list[str]:
    """Return human-readable errors for a light extension dict.

    Each message names the offending property.  Intensity is validated
    elsewhere (validate.py, E302) and is not checked here.
    """
    errors = []
    kind = str(kind or "").strip().lower()
    ext = ext if isinstance(ext, dict) else {}

    if kind in WAVEA_LIGHT_KINDS and ext.get("position") is None:
        errors.append(
            "%s light requires a position: 'position' must be given "
            "(via 'at' or 'from')" % kind)
    if kind == "spot" and ext.get("target") is None:
        errors.append(
            "spot light requires a target: 'target' must be given "
            "(via 'look' or 'target')")

    angle = _num(ext.get("angle"), None)
    if angle is not None and not (0.0 < angle < 180.0):
        errors.append(
            "angle is %s, but 'angle' must be between 0 and 180 "
            "degrees (exclusive)" % _fmt(angle))
    penumbra = _num(ext.get("penumbra"), None)
    if penumbra is not None and not (0.0 <= penumbra <= 1.0):
        errors.append(
            "penumbra is %s, but 'penumbra' must be between 0 and 1"
            % _fmt(penumbra))
    distance = _num(ext.get("distance"), None)
    if distance is not None and distance < 0.0:
        errors.append(
            "distance is %s, but 'distance' must be 0 or more "
            "(0 means no cutoff)" % _fmt(distance))
    decay = _num(ext.get("decay"), None)
    if decay is not None and decay < 0.0:
        errors.append(
            "decay is %s, but 'decay' must be 0 or more" % _fmt(decay))
    return errors


def light_line(kind: str, ext: dict, color: tuple, intensity: float):
    """Serialise a point/spot light to its ``.scene`` line, or ``None``.

    Formats (floats ``%g``, colour channels as ints)::

        light point px py pz R G B intensity distance decay
        light spot px py pz dx dy dz R G B intensity distance decay \\
            angle penumbra

    The spot direction ``d`` is ``normalise(target - position)``.
    Returns ``None`` for non-Wave-A kinds, when the position is
    missing, when a spot has no target, or when the spot target equals
    its position (direction undefined).
    """
    kind = str(kind or "").strip().lower()
    if kind not in WAVEA_LIGHT_KINDS:
        return None
    ext = ext if isinstance(ext, dict) else {}
    position = _vec3(ext.get("position"))
    if position is None:
        return None
    distance = _num(ext.get("distance"), _DEFAULT_DISTANCE)
    decay = _num(ext.get("decay"), _DEFAULT_DECAY)
    head = "light %s %s %s %s" % (
        kind, _fmt_vec(position), _fmt_color(color), _fmt(intensity))
    if kind == "point":
        return "%s %s %s" % (head, _fmt(distance), _fmt(decay))
    # spot
    target = _vec3(ext.get("target"))
    if target is None:
        return None
    delta = tuple(t - p for t, p in zip(target, position))
    length = math.sqrt(sum(c * c for c in delta))
    if length == 0.0 or not math.isfinite(length):
        return None
    direction = tuple(c / length for c in delta)
    angle = _num(ext.get("angle"), _DEFAULT_ANGLE)
    penumbra = _num(ext.get("penumbra"), _DEFAULT_PENUMBRA)
    return "%s %s %s %s %s %s" % (
        "light spot %s" % _fmt_vec(position),
        _fmt_vec(direction), _fmt_color(color), _fmt(intensity),
        "%s %s" % (_fmt(distance), _fmt(decay)),
        "%s %s" % (_fmt(angle), _fmt(penumbra)))


# ---------------------------------------------------------------------------
# Scene environment: fog / tonemap / shadow
# ---------------------------------------------------------------------------
def _clause_words(value):
    """Split a clause string like ``'linear near 5 far 20'`` to a dict.

    Bare words become ``True`` flags; ``key value`` pairs (where the
    value is numeric or a colour) are consumed as pairs.  Only used
    for string-valued fog/tonemap/shadow props; dict and flat-key
    forms are the primary contract.
    """
    if not isinstance(value, str):
        return {}
    tokens = value.replace(",", " ").split()
    out = {}
    i = 0
    while i < len(tokens):
        word = tokens[i].lower()
        if i + 1 < len(tokens):
            nxt = tokens[i + 1]
            if _num(nxt) is not None or _parse_color(nxt) is not None:
                out[word] = nxt
                i += 2
                continue
        out[word] = True
        i += 1
    return out


def _mode_word(value, *dict_keys):
    """Extract a mode word from a str / dict / bool prop value."""
    if isinstance(value, str):
        text = value.strip().lower()
        if not text:
            return None
        return text.split()[0]
    if isinstance(value, dict):
        lowered = _lower_keys(value)
        for key in dict_keys:
            word = lowered.get(key)
            if isinstance(word, str) and word.strip():
                return word.strip().lower()
        return None
    if isinstance(value, bool):
        return "on" if value else "off"
    return None


def _sub_props(props, primary, *aliases):
    """Merged sub-prop dict for a clause: string words + dict + flats.

    Flat scene-level keys (handled by the caller) override these.
    """
    merged = {}
    for key in (primary,) + aliases:
        value = props.get(key)
        if isinstance(value, dict):
            merged.update(_lower_keys(value))
        elif isinstance(value, str):
            merged.update(_clause_words(value))
    return merged


def _extract_fog(props):
    raw = _first(props, "fog")
    if raw is False:
        return None
    sub = _sub_props(props, "fog")
    mode = _first(props, "fog_mode")
    if not (isinstance(mode, str) and mode.strip()):
        mode = _mode_word(raw, "mode", "kind")
    if mode is None:
        # A bare colour word / hex in the fog slot is not a mode.
        if isinstance(raw, str) and _parse_color(raw) is not None:
            mode = None
        elif raw is True:
            mode = "linear"
    # Any fog_* detail key implies fog even without an explicit mode.
    detail_keys = ("fog_near", "fog_far", "fog_density", "fog_color",
                   "near", "far", "density")
    has_detail = any(k in props and props[k] is not None
                     for k in detail_keys) or any(
                         k in sub and sub[k] is not None
                         for k in ("near", "far", "density", "color"))
    if mode is None and has_detail:
        density_hint = _first(props, "fog_density", "density")
        if density_hint is None:
            density_hint = sub.get("density")
        mode = "exp2" if density_hint is not None else "linear"
    if mode is None:
        return None
    mode = str(mode).strip().lower()
    if mode in ("none", "off", ""):
        return None
    if mode in ("exp", "exp2", "fogexp2", "fog_exp2"):
        mode = "exp2"
    elif mode != "linear":
        # Unknown fog mode: keep it verbatim so validate/emit see
        # exactly what was asked for rather than a silent rewrite.
        return {"mode": mode}
    color = _parse_color(_first(props, "fog_color"))
    if color is None:
        color = _parse_color(_first(sub, "color", "colour"))
    if color is None and isinstance(raw, str) \
            and _parse_color(raw) is not None:
        color = _parse_color(raw)
    if color is None:
        color = _DEFAULT_FOG_COLOR
    if mode == "linear":
        near = _num(_first(props, "fog_near"), None)
        if near is None:
            near = _num(sub.get("near"), _DEFAULT_FOG_NEAR)
        far = _num(_first(props, "fog_far"), None)
        if far is None:
            far = _num(sub.get("far"), _DEFAULT_FOG_FAR)
        return {"mode": "linear", "near": near, "far": far,
                "color": color}
    density = _num(_first(props, "fog_density"), None)
    if density is None:
        density = _num(sub.get("density"), _DEFAULT_FOG_DENSITY)
    return {"mode": "exp2", "density": density, "color": color}


def _extract_tonemap(props):
    sub = _sub_props(props, "tonemap", "tone")
    mode = _mode_word(_first(props, "tonemap", "tone"), "mode", "kind")
    if mode is None:
        mode = "none"
    mode = _TONEMAP_ALIASES.get(mode, mode)
    exposure = _num(_first(props, "exposure", "tonemap_exposure",
                           "tone_exposure"), None)
    if exposure is None:
        exposure = _num(sub.get("exposure"), _DEFAULT_EXPOSURE)
    return {"mode": mode, "exposure": exposure}


def _extract_shadow(props):
    sub = _sub_props(props, "shadow", "shadows")
    raw = _first(props, "shadow", "shadows")
    mode = _mode_word(raw, "mode", "kind")
    if mode is None:
        mode = _first(props, "shadow_mode")
        mode = str(mode).strip().lower() if isinstance(mode, str) else None
    if mode is None:
        mode = "off"
    if mode in ("none", ""):
        mode = "off"
    elif mode in ("pcf", "soft_pcf", "soft-pcf"):
        mode = "soft"  # soft shadows = PCF filtering
    elif mode not in _SHADOW_MODES:
        mode = str(mode).strip().lower()
    size = _num(_first(props, "shadow_size", "shadow_map_size"), None)
    if size is None:
        size = _num(_first(sub, "size", "map_size", "shadow_size"), None)
    if size is None:
        # Clause-string form: ``shadow on 1024`` / ``shadow soft 256``.
        # ``_clause_words`` consumes the trailing bare integer as the
        # value of the mode word, yielding e.g. ``{"on": "1024"}``, so
        # look under the mode word (and its pre-alias spellings) and,
        # failing that, at a trailing bare-integer token of the raw
        # clause string itself.  A bare mode word (``shadow on``)
        # parses to ``True`` there, which ``_num`` rejects, so the
        # default below still applies.  The parsed size is *not*
        # range-checked here: ``validate_env`` must see e.g. 100 and
        # report it, not have it silently replaced by the default.
        for key in (mode, "on", "soft", "off", "pcf", "soft_pcf",
                    "soft-pcf"):
            size = _num(sub.get(key), None)
            if size is not None:
                break
    if size is None and isinstance(raw, str):
        tokens = raw.replace(",", " ").split()
        if len(tokens) >= 2 and re.fullmatch(r"[+-]?\d+", tokens[-1]):
            size = _num(tokens[-1], None)
    if size is None:
        size = _DEFAULT_SHADOW_SIZE
    # A bare integer shadow prop reads as a map size with shadows on.
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        size = _num(raw, _DEFAULT_SHADOW_SIZE)
        if mode == "off":
            mode = "on"
    return {"mode": mode, "size": int(size)}


def extract_env(props: dict) -> dict:
    """Normalise scene-level environment props.  Pure.

    Reads the flat keys ``fog`` / ``fog_mode`` / ``fog_near`` /
    ``fog_far`` / ``fog_density`` / ``fog_color``, ``tonemap`` /
    ``tone`` / ``exposure`` and ``shadow`` (plus dict / clause-string
    forms of the three clause values).  Defaults: no fog (``None``),
    tonemap ``none`` at exposure 1.0, shadow ``off`` at size 512.
    """
    props = _lower_keys(props)
    return {
        "fog": _extract_fog(props),
        "tonemap": _extract_tonemap(props),
        "shadow": _extract_shadow(props),
    }


def validate_env(env: dict) -> list[str]:
    """Return human-readable errors for a normalised env dict.

    Checks: linear fog requires ``near < far``; exp2 fog ``density``
    must be >= 0; tonemap ``exposure`` must be > 0; a shadow ``size``,
    when present, must be a power of two between 64 and 4096.
    Each message names the offending property.
    """
    errors = []
    if not isinstance(env, dict):
        return errors

    fog = env.get("fog")
    if isinstance(fog, dict):
        mode = str(fog.get("mode") or "").strip().lower()
        if mode == "linear":
            near = _num(fog.get("near"), None)
            far = _num(fog.get("far"), None)
            if near is None or far is None:
                errors.append(
                    "linear fog requires 'near' and 'far': fog near "
                    "and fog far must both be given")
            elif not near < far:
                errors.append(
                    "fog near is %s, but 'near' must be smaller than "
                    "'far' (%s) for linear fog"
                    % (_fmt(near), _fmt(far)))
        elif mode == "exp2":
            density = _num(fog.get("density"), None)
            if density is None:
                errors.append(
                    "exp2 fog requires a 'density': fog density must "
                    "be given")
            elif density < 0.0:
                errors.append(
                    "fog density is %s, but 'density' must be 0 or "
                    "more" % _fmt(density))

    tonemap = env.get("tonemap")
    if isinstance(tonemap, dict) and tonemap.get("exposure") is not None:
        exposure = _num(tonemap.get("exposure"), None)
        if exposure is None or exposure <= 0.0:
            errors.append(
                "exposure is %s, but 'exposure' must be more than 0"
                % (tonemap.get("exposure"),))

    shadow = env.get("shadow")
    if isinstance(shadow, dict) and shadow.get("size") is not None:
        size = _num(shadow.get("size"), None)
        if size is None or size != int(size) \
                or not (64 <= int(size) <= 4096) \
                or (int(size) & (int(size) - 1)) != 0:
            errors.append(
                "shadow size is %s, but 'size' must be a power of "
                "two between 64 and 4096" % (shadow.get("size"),))
    return errors


def env_lines(env: dict) -> list[str]:
    """Serialise a normalised env dict to ``.scene`` lines.

    Only non-default entries produce a line (fog ``None`` -> no line,
    tonemap ``none`` -> no line, shadow ``off`` -> no line)::

        fog linear near far R G B
        fog exp2 density R G B
        fog none                      (explicit none-mode fog dict)
        tonemap <mode> <exposure>
        shadow <mode> <size>
    """
    lines = []
    if not isinstance(env, dict):
        return lines

    fog = env.get("fog")
    if isinstance(fog, dict):
        mode = str(fog.get("mode") or "").strip().lower()
        if mode == "linear":
            near = _num(fog.get("near"), _DEFAULT_FOG_NEAR)
            far = _num(fog.get("far"), _DEFAULT_FOG_FAR)
            lines.append("fog linear %s %s %s" % (
                _fmt(near), _fmt(far), _fmt_color(fog.get("color"))))
        elif mode == "exp2":
            density = _num(fog.get("density"), _DEFAULT_FOG_DENSITY)
            lines.append("fog exp2 %s %s" % (
                _fmt(density), _fmt_color(fog.get("color"))))
        elif mode in ("none", "off"):
            lines.append("fog none")
        elif mode:
            lines.append("fog %s" % mode)

    tonemap = env.get("tonemap")
    if isinstance(tonemap, dict):
        mode = str(tonemap.get("mode") or "none").strip().lower()
        mode = _TONEMAP_ALIASES.get(mode, mode)
        if mode != "none":
            exposure = _num(tonemap.get("exposure"), _DEFAULT_EXPOSURE)
            lines.append("tonemap %s %s" % (mode, _fmt(exposure)))

    shadow = env.get("shadow")
    if isinstance(shadow, dict):
        mode = str(shadow.get("mode") or "off").strip().lower()
        if mode in ("none", ""):
            mode = "off"
        if mode != "off":
            size = _num(shadow.get("size"), _DEFAULT_SHADOW_SIZE)
            lines.append("shadow %s %d" % (mode, int(size)))
    return lines
