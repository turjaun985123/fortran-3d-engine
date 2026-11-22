"""Forge3D Wave B extension: ``sprite`` + ``text`` statements.

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan rule
4: new features register, they do not edit the frozen IR). It owns the
Wave B sprite / text surface (MASTER-PLAN rows 23 / 24 / 29); the
compiler coordinator wires ``parser.py`` / ``validate.py`` /
``emit_fortran.py`` to call it.

User syntax::

    sprite star at 2,3,0 size 1 color gold
    text label "GAME OVER" at 0,4,0 size 1 color white

``.scene`` lines emitted::

    sprite NAME PX PY PZ SIZE R G B
    text NAME PX PY PZ SIZE R G B CONTENT

where CONTENT is the text with single spaces (everything after the
colour fields, case preserved exactly as typed).

Public API (the exact names the coordinator wires to)::

    extract_sprite(props) -> dict
    validate_sprite(d) -> list[str]
    sprite_line(name, d) -> str
    extract_text(props) -> dict
    validate_text(d) -> list[str]
    text_line(name, d) -> str

Normalised shapes::

    sprite: {"at": (x, y, z), "size": float, "color": (r, g, b)}
    text:   {"at": (x, y, z), "size": float, "color": (r, g, b),
             "text": str, "content": str}

(``text`` and ``content`` in a text dict are two spellings of the same
normalised string; both are always set so callers may use either.)

All functions are defensive, pure and side-effect free. Error strings
are plain human-readable messages (no diagnostic codes): ``validate``
wraps them in diagnostics, exactly as for ``ext_materials`` /
``ext_lights_env``.
"""

from __future__ import annotations

import math
import re

__all__ = [
    "NAMED_COLORS",
    "TEXT_CHARSET",
    "DEFAULT_AT",
    "DEFAULT_SIZE",
    "DEFAULT_COLOR",
    "MAX_SIZE",
    "MAX_TEXT_LEN",
    "extract_sprite",
    "validate_sprite",
    "sprite_line",
    "extract_text",
    "validate_text",
    "text_line",
]

# ---------------------------------------------------------------------------
# Defaults / limits
# ---------------------------------------------------------------------------
DEFAULT_AT = (0.0, 0.0, 0.0)
DEFAULT_SIZE = 1.0
DEFAULT_COLOR = (255, 255, 255)
MAX_SIZE = 100.0
MAX_TEXT_LEN = 200

# Characters the native bitmap font can draw, besides lowercase letters
# (which the font uppercases). Anything else is a validation error.
TEXT_CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'"
_ALLOWED_TEXT_CHARS = frozenset(
    TEXT_CHARSET + "abcdefghijklmnopqrstuvwxyz")

# ---------------------------------------------------------------------------
# Named colours: the frozen palette owned by ir_nodes.NAMED_COLORS.
# Import it when importable; the embedded copy below is exactly the
# same table, so this module also works standalone.
# ---------------------------------------------------------------------------
_FALLBACK_NAMED_COLORS = {
    "red": (220, 60, 60), "green": (60, 220, 60), "blue": (60, 100, 240),
    "yellow": (240, 220, 50), "magenta": (200, 80, 220),
    "cyan": (60, 220, 220), "orange": (240, 140, 40),
    "purple": (140, 80, 200), "pink": (240, 150, 190),
    "white": (240, 240, 240), "black": (20, 20, 25),
    "gray": (140, 140, 145), "grey": (140, 140, 145),
}

try:  # frozen colour contract lives in ir_nodes (B08)
    try:
        from ir_nodes import NAMED_COLORS as _IR_NAMED_COLORS
    except Exception:
        from .ir_nodes import NAMED_COLORS as _IR_NAMED_COLORS
    NAMED_COLORS = dict(_IR_NAMED_COLORS) if _IR_NAMED_COLORS \
        else dict(_FALLBACK_NAMED_COLORS)
except Exception:
    NAMED_COLORS = dict(_FALLBACK_NAMED_COLORS)

_HEX_RE = re.compile(r"^#([0-9a-fA-F]{6})$")
_RGB_RE = re.compile(
    r"^rgb\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*\)$",
    re.IGNORECASE,
)


# ---------------------------------------------------------------------------
# Generic value helpers (same tolerant shapes as ext_lights_env)
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
    defaulted) so ``validate_sprite`` / ``validate_text`` can report
    them, mirroring ``ext_materials._as_number``.
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


def _parse_color(value):
    """Resolve *value* to an ``(r, g, b)`` int tuple, else ``None``.

    Accepts a 3-sequence of channels, a named colour (the frozen
    ``ir_nodes`` palette), ``'#rrggbb'`` or ``'rgb(r,g,b)'``. Prefers
    the frozen parser in ``ir_nodes`` for strings when importable;
    the local path covers exactly the same spellings standalone.
    An unknown / malformed colour returns ``None`` (the caller then
    falls back to ``DEFAULT_COLOR``; reporting an unknown colour by
    name is ``validate.py``'s E202 job, as elsewhere in the compiler).
    """
    if value is None:
        return None
    # ColourLit-style node: name/value/text/rgb attributes.
    if not isinstance(value, (str, list, tuple)):
        for attr in ("rgb", "channels"):
            inner = getattr(value, attr, None)
            if inner is not None:
                return _parse_color(inner)
        for attr in ("name", "value", "text"):
            inner = getattr(value, attr, None)
            if isinstance(inner, str):
                return _parse_color(inner)
        return None
    if isinstance(value, (list, tuple)):
        if len(value) != 3:
            return None
        channels = []
        for part in value:
            number = _as_number(part)
            if isinstance(number, bool) \
                    or not isinstance(number, (int, float)) \
                    or not (0.0 <= float(number) <= 255.0):
                return None
            channels.append(int(round(float(number))))
        return tuple(channels)
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
    text = value.strip().strip("\"'").strip()
    named = NAMED_COLORS.get(text.lower())
    if named is not None:
        return tuple(int(c) for c in named)
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
    """Format a number with ``%.6g`` (the .scene float spelling)."""
    number = _as_number(value)
    if isinstance(number, bool) or not isinstance(number, (int, float)):
        return "0"
    return "%.6g" % float(number)


def _fmt_vec(vec):
    return " ".join(_fmt(c) for c in vec)


def _fmt_color(color):
    parsed = _parse_color(color)
    if parsed is None:
        parsed = DEFAULT_COLOR
    return "%d %d %d" % parsed


# ---------------------------------------------------------------------------
# Shared extraction: at / size / color
# ---------------------------------------------------------------------------
def _extract_common(props):
    props = _lower_keys(props)
    at = _vec3(_first(props, "at", "position", "pos"))
    if at is None and any(k in props for k in ("x", "y", "z")):
        at = _vec3({axis: props.get(axis) for axis in ("x", "y", "z")})
    if at is None:
        at = DEFAULT_AT
    size = _as_number(_first(props, "size"))
    if size is None:
        size = DEFAULT_SIZE
    color = _parse_color(_first(
        props, "color", "colour", "color_raw", "colour_raw",
        "color_value", "colour_value"))
    if color is None:
        color = DEFAULT_COLOR
    return {"at": at, "size": size, "color": color}


def _clean_text(value):
    """Normalise raw text content: unquote, single-space, keep case."""
    if value is None:
        return ""
    if not isinstance(value, str):
        for attr in ("value", "text", "content"):
            inner = getattr(value, attr, None)
            if isinstance(inner, str):
                value = inner
                break
        else:
            value = str(value)
    text = value.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("\"", "'"):
        text = text[1:-1]
    return " ".join(text.split())


def _text_of(d):
    """The content string of a normalised text dict (either spelling)."""
    if not isinstance(d, dict):
        return ""
    for key in ("content", "text"):
        value = d.get(key)
        if isinstance(value, str):
            return value
        if value is not None:
            return str(value)
    return ""


# ---------------------------------------------------------------------------
# Shared validation: at / size
# ---------------------------------------------------------------------------
def _validate_common(d):
    errors = []
    if not isinstance(d, dict):
        return errors
    at = d.get("at")
    if at is not None:
        vec = _vec3(at)
        if vec is None:
            errors.append(
                "at %r is not a position: 'at' must be three finite "
                "coordinates (x, y, z)" % (at,))
        else:
            for axis, component in zip(("x", "y", "z"), vec):
                number = _as_number(component)
                if isinstance(number, bool) \
                        or not isinstance(number, (int, float)):
                    errors.append(
                        "at %s %r is not a number: 'at' coordinates "
                        "must be finite" % (axis, component))
                elif not math.isfinite(float(number)):
                    errors.append(
                        "at %s is %s, but 'at' coordinates must be "
                        "finite" % (axis, "%.6g" % float(number)))
    size = d.get("size")
    if size is not None:
        number = _as_number(size)
        if isinstance(number, bool) \
                or not isinstance(number, (int, float)):
            errors.append(
                "size %r is not a number: 'size' must be more than "
                "0 and at most %g" % (size, MAX_SIZE))
        elif not math.isfinite(float(number)) \
                or not (0.0 < float(number) <= MAX_SIZE):
            errors.append(
                "size is %s, but 'size' must be more than 0 and at "
                "most %g" % ("%.6g" % float(number), MAX_SIZE))
    return errors


# ---------------------------------------------------------------------------
# Sprites
# ---------------------------------------------------------------------------
def extract_sprite(props: dict) -> dict:
    """Normalise raw sprite props into a sprite dict. Pure.

    ``props`` is the raw property dict ``validate.py`` builds for one
    statement -- a plain dict of raw values such as
    ``{"at": (2, 3, 0), "size": 1, "color": "gold"}`` (``at`` may
    also be an ``"x,y,z"`` string, ``size`` a numeric string, and
    ``color`` / ``colour`` a named colour, ``'#rrggbb'``,
    ``'rgb(r,g,b)'`` or an ``(r, g, b)`` sequence).

    Returns ``{"at": (x, y, z), "size": float, "color": (r, g, b)}``
    with defaults ``at`` (0, 0, 0), ``size`` 1.0 and ``color``
    (255, 255, 255). Unconvertible / non-finite ``at`` and ``size``
    values are passed through unchanged so validation can report
    them rather than losing them here. ``props`` is never mutated.
    """
    return _extract_common(props)


def validate_sprite(d) -> list[str]:
    """Return human-readable errors for a normalised sprite dict.

    Checks: ``size`` must be more than 0 and at most 100, and every
    ``at`` coordinate must be finite. An empty list means valid.
    """
    return _validate_common(d)


def sprite_line(name, d) -> str:
    """Serialise a sprite dict to its ``.scene`` line::

        sprite NAME PX PY PZ SIZE R G B

    Floats are formatted ``%.6g``; colour channels are ints. Missing
    fields fall back to the defaults.
    """
    d = d if isinstance(d, dict) else {}
    at = _vec3(d.get("at")) or DEFAULT_AT
    size = _as_number(d.get("size"))
    if isinstance(size, bool) or not isinstance(size, (int, float)):
        size = DEFAULT_SIZE
    return "sprite %s %s %s %s" % (
        str(name), _fmt_vec(at), _fmt(size), _fmt_color(d.get("color")))


# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------
def extract_text(props: dict) -> dict:
    """Normalise raw text props into a text dict. Pure.

    As ``extract_sprite`` for ``at`` / ``size`` / ``color``, plus the
    text content, read from the first present of ``content``,
    ``text``, ``label``, ``value``, ``string`` or ``caption`` in
    *props*. The content is unquoted (when quoted) and collapsed to
    single spaces; its case is preserved exactly as typed. The
    normalised string is stored under both ``"text"`` and
    ``"content"``. Missing content yields ``""`` (validation then
    reports it). ``props`` is never mutated.
    """
    lowered = _lower_keys(props)
    d = _extract_common(lowered)
    content = _clean_text(_first(
        lowered, "content", "text", "label", "value", "string",
        "caption", "text_content"))
    d["text"] = content
    d["content"] = content
    return d


def validate_text(d) -> list[str]:
    """Return human-readable errors for a normalised text dict.

    The ``at`` / ``size`` checks of ``validate_sprite``, plus: the
    text content is required (non-empty after stripping), must be at
    most 200 characters, and may contain only printable ASCII the
    native font can draw -- the charset
    ``" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'"`` plus lowercase
    letters (which the font uppercases). Any other character is
    reported by name. An empty list means valid.
    """
    errors = _validate_common(d)
    content = _text_of(d)
    if not content.strip():
        errors.append(
            "text is empty: text content must not be empty "
            "(a quoted string is required)")
        return errors
    if len(content) > MAX_TEXT_LEN:
        errors.append(
            "text is %d characters, but 'text' must be at most %d "
            "characters" % (len(content), MAX_TEXT_LEN))
    seen = []
    for char in content:
        if char not in _ALLOWED_TEXT_CHARS and char not in seen:
            seen.append(char)
    for char in seen:
        errors.append(
            "text contains unsupported character %r: the text font "
            "supports only %r plus lowercase letters"
            % (char, TEXT_CHARSET))
    return errors


def text_line(name, d) -> str:
    """Serialise a text dict to its ``.scene`` line::

        text NAME PX PY PZ SIZE R G B CONTENT

    Floats are formatted ``%.6g``; colour channels are ints. CONTENT
    is the text collapsed to single spaces, case preserved as typed,
    and is everything after the colour fields. (With no content the
    line simply ends after the colour fields.)
    """
    d = d if isinstance(d, dict) else {}
    at = _vec3(d.get("at")) or DEFAULT_AT
    size = _as_number(d.get("size"))
    if isinstance(size, bool) or not isinstance(size, (int, float)):
        size = DEFAULT_SIZE
    head = "text %s %s %s %s" % (
        str(name), _fmt_vec(at), _fmt(size), _fmt_color(d.get("color")))
    content = " ".join(_text_of(d).split())
    return "%s %s" % (head, content) if content else head
