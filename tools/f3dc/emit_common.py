"""Forge3D shared emitter helpers (B11).

Stdlib only. Shared by every ``emit_*`` back end so that number
formatting, colour formatting, header stamps and JSON serialisation
are byte-identical across targets (determinism: same IR -> same text
-> same sha256).

The IR contract, ``NAMED_COLORS`` and ``PALETTE_FACES`` live in
``ir_nodes`` (B08); colours are resolved against those tables, never
re-defined here.
"""

from __future__ import annotations

import hashlib
import html
import json
import math
import re
from dataclasses import is_dataclass

try:  # Sibling module, imported the same way ir_nodes imports errors.
    from ir_nodes import NAMED_COLORS, PALETTE_FACES, parse_color  # type: ignore
except Exception:  # pragma: no cover - package-style import
    try:
        from .ir_nodes import NAMED_COLORS, PALETTE_FACES, parse_color  # type: ignore
    except Exception:
        NAMED_COLORS = {}
        PALETTE_FACES = []
        parse_color = None  # type: ignore

__all__ = [
    "fmt_num",
    "fmt_vec",
    "source_hash",
    "header_stamp",
    "rgb_str",
    "clamp255",
    "html_escape",
    "js_json",
    "NAMED_COLORS",
    "PALETTE_FACES",
]


# ---------------------------------------------------------------------------
# Number formatting
# ---------------------------------------------------------------------------
def fmt_num(x) -> str:
    """Format a number without gratuitous precision.

    Ints and integral floats render without ``.0`` (``2``, not
    ``2.0``); other floats are trimmed (``2.5``, not ``2.500000``);
    ``-0.0`` normalises to ``'0'``.
    """
    if isinstance(x, bool):
        return str(int(x))
    if isinstance(x, int):
        return str(x)
    # Floats (and float-like values such as Decimal).
    try:
        value = float(x)
    except (TypeError, ValueError):
        return str(x)
    if value == 0.0:  # covers 0.0 and -0.0
        return "0"
    if math.isnan(value):
        return "nan"
    if math.isinf(value):
        return "inf" if value > 0 else "-inf"
    if value.is_integer() and abs(value) < 1e16:
        return str(int(value))
    text = repr(value)
    if "e" in text or "E" in text:
        return text
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text if text not in ("", "-0") else "0"


def fmt_vec(t) -> str:
    """Format a vector/tuple as space-separated numbers: ``'x y z'``."""
    return " ".join(fmt_num(v) for v in t)


# ---------------------------------------------------------------------------
# Canonical JSON + hashing
# ---------------------------------------------------------------------------
def _json_safe(value):
    """Recursively convert a value into a plain JSON-safe structure."""
    if is_dataclass(value) and not isinstance(value, type):
        return {
            str(k): _json_safe(v)
            for k, v in vars(value).items()
        }
    if isinstance(value, dict):
        return {str(k): _json_safe(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [_json_safe(v) for v in value]
    if isinstance(value, (set, frozenset)):
        return [_json_safe(v) for v in sorted(value, key=repr)]
    return value


def _canonical_json(obj) -> str:
    return json.dumps(
        _json_safe(obj),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


def source_hash(obj) -> str:
    """Return the sha256 hex digest of ``obj``'s canonical JSON.

    Canonical means sorted keys and compact separators, so equal
    objects hash equally regardless of dict insertion order.
    """
    return hashlib.sha256(_canonical_json(obj).encode("utf-8")).hexdigest()


def js_json(obj) -> str:
    """Serialise ``obj`` as compact JSON suitable for JS/HTML emit."""
    return json.dumps(
        _json_safe(obj),
        separators=(",", ":"),
        ensure_ascii=False,
    )


# ---------------------------------------------------------------------------
# Header stamp
# ---------------------------------------------------------------------------
_HEX64_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def header_stamp(source_name, obj=None, comment="#") -> str:
    """Return the three-line generated-file header stamp.

    Lines (with ``comment`` prefixed to each)::

        # Forge3D generated file - do not edit
        # source: <source_name>
        # sha256: <source_hash(obj)>

    ``comment`` is parameterised so Fortran emitters can pass ``'!'``
    and JS emitters ``'//'``.  If ``obj`` is already a 64-char hex
    digest it is used verbatim instead of being hashed again.
    """
    if isinstance(obj, str) and _HEX64_RE.match(obj):
        digest = obj.lower()
    else:
        digest = source_hash(obj)
    prefix = str(comment)
    lines = [
        "%s Forge3D generated file - do not edit" % prefix,
        "%s source: %s" % (prefix, source_name),
        "%s sha256: %s" % (prefix, digest),
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
def clamp255(v):
    """Clamp a colour channel to an ``int`` in ``0..255``.

    Accepts a single channel value; a tuple/list of values is clamped
    element-wise and returned as a tuple.
    """
    if isinstance(v, (tuple, list)):
        return tuple(clamp255(item) for item in v)
    try:
        value = float(v)
    except (TypeError, ValueError):
        return 0
    if math.isnan(value):
        return 0
    if value <= 0:
        return 0
    if value >= 255:
        return 255
    return int(round(value))


def _resolve_color(color):
    """Resolve a colour spec to an ``(r, g, b)`` tuple, or ``None``."""
    if color is None:
        return None
    if isinstance(color, (tuple, list)):
        if len(color) != 3:
            raise ValueError("expected a 3-component color, got %r" % (color,))
        return tuple(color)
    if isinstance(color, str):
        named = NAMED_COLORS.get(color.strip().lower())
        if named is not None:
            return tuple(named)
        if parse_color is not None:
            parsed = parse_color(color)
            if parsed is not None:
                return tuple(parsed)
        raise ValueError("unknown color %r" % (color,))
    if isinstance(color, int) and not isinstance(color, bool):
        # Palette index into the per-face palette.
        if 0 <= color < len(PALETTE_FACES):
            return tuple(PALETTE_FACES[color])
        raise ValueError("palette index out of range: %r" % (color,))
    raise TypeError("unsupported color value: %r" % (color,))


def rgb_str(color) -> str:
    """Format a colour as ``'r g b'`` with channels clamped to 0..255.

    Accepts an ``(r, g, b)`` tuple/list, a named colour from
    ``NAMED_COLORS`` (or any string ``parse_color`` accepts), or a
    ``PALETTE_FACES`` index.
    """
    resolved = _resolve_color(color)
    if resolved is None:
        raise ValueError("cannot format None as a color")
    return " ".join(str(clamp255(channel)) for channel in resolved)


# ---------------------------------------------------------------------------
# Escaping
# ---------------------------------------------------------------------------
def html_escape(s) -> str:
    """Escape ``s`` for safe inclusion in HTML text/attribute content."""
    return html.escape(str(s), quote=True)
