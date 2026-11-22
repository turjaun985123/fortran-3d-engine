"""Forge3D Wave C extension: post-processing ``filter`` statements.

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan rule
4: new features register, they do not edit the frozen IR). It owns the
Wave C post-processing surface (MASTER-PLAN row 30); the compiler
coordinator wires ``parser.py`` / ``validate.py`` / ``emit`` to call
it.

Scope is parsing / validation / emit only, exactly like the other
``ext_*`` modules: the per-pixel math lives in the Fortran passes
(``src/postprocess.f90``) and its JS mirror, never here.

User syntax (frozen)::

    filter <name> [amount]

where ``name`` is one of ``blur``, ``bloom``, ``vignette``,
``gamma``, ``grayscale`` or ``sepia``. Multiple ``filter`` lines form
an ordered chain: the filters apply in the order the lines appear,
so chain order is preserved end to end (see ``collect_post``).

Amounts (frozen defaults and ranges)::

    blur       integer passes, at least 1        default 1
    bloom      strength, at least 0              default 0.5
    vignette   strength, at least 0              default 0.5
    gamma      exponent, more than 0             default 2.2
    grayscale  mix, in 0..1                      default 1.0
    sepia      mix, in 0..1                      default 1.0

(No upper bound is frozen for bloom / vignette / gamma, so none is
invented here; every amount must still be a finite number.)

``.scene`` line emitted::

    post NAME AMOUNT

Public API (the exact names the coordinator wires to)::

    extract_post(props) -> dict
    validate_post(d) -> list[str]
    post_line(d) -> str
    collect_post(items) -> list[dict]
    post_lines(chain) -> list[str]

Normalised shape::

    {"name": str, "amount": int | float}

with ``amount`` an ``int`` for ``blur`` (a pass count) and a
``float`` for every other filter.

All functions are defensive, pure and side-effect free. Error strings
are plain human-readable messages (no diagnostic codes): ``validate``
wraps them in diagnostics, exactly as for ``ext_materials`` /
``ext_lights_env`` / ``ext_particles``.
"""

from __future__ import annotations

import math

__all__ = [
    "FILTERS",
    "FILTER_NAMES",
    "DEFAULTS",
    "DEFAULT_BLUR",
    "DEFAULT_BLOOM",
    "DEFAULT_VIGNETTE",
    "DEFAULT_GAMMA",
    "DEFAULT_GRAYSCALE",
    "DEFAULT_SEPIA",
    "extract_post",
    "validate_post",
    "post_line",
    "collect_post",
    "post_lines",
]

# ---------------------------------------------------------------------------
# Defaults (frozen)
# ---------------------------------------------------------------------------
DEFAULT_BLUR = 1
DEFAULT_BLOOM = 0.5
DEFAULT_VIGNETTE = 0.5
DEFAULT_GAMMA = 2.2
DEFAULT_GRAYSCALE = 1.0
DEFAULT_SEPIA = 1.0

#: Filter names in declaration order.
FILTERS = ("blur", "bloom", "vignette", "gamma", "grayscale", "sepia")

#: Same names as a set, for membership checks.
FILTER_NAMES = frozenset(FILTERS)

#: Default amount per filter (``blur`` is an int pass count).
DEFAULTS = {
    "blur": DEFAULT_BLUR,
    "bloom": DEFAULT_BLOOM,
    "vignette": DEFAULT_VIGNETTE,
    "gamma": DEFAULT_GAMMA,
    "grayscale": DEFAULT_GRAYSCALE,
    "sepia": DEFAULT_SEPIA,
}

# Amount keys accepted in a props dict, in priority order.
_AMOUNT_KEYS = ("amount", "value", "passes", "strength", "factor",
                "intensity")

# Name keys accepted in a props dict, in priority order.
_NAME_KEYS = ("name", "filter", "type", "kind", "effect")


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
    defaulted) so ``validate_post`` can report them, mirroring
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


def _as_int(value):
    """Best-effort int conversion; unconvertible values pass through.

    Ints, integral floats and integral numeric strings convert;
    anything else is returned unchanged so ``validate_post`` can
    report it rather than losing it here (same contract as
    ``ext_particles._as_int``).
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        if math.isfinite(value) and float(value).is_integer():
            return int(value)
        return value
    if isinstance(value, str):
        text = value.strip()
        try:
            return int(text)
        except ValueError:
            try:
                number = float(text)
            except ValueError:
                return value
            if math.isfinite(number) and number.is_integer():
                return int(number)
            return value
    return value


def _word(value):
    """Normalise a filter-name word: stripped, lower-cased string.

    Accepts a plain string / number, or a token-ish object carrying
    the word in a ``text`` / ``value`` / ``name`` attribute (the
    lexer's ``Token.text`` shape). Anything else gives ``""``.
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip().strip("\"'").strip().lower()
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value).strip().lower()
    for attr in ("text", "value", "name"):
        inner = getattr(value, attr, None)
        if isinstance(inner, str) and inner.strip():
            return inner.strip().strip("\"'").strip().lower()
    return ""


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


def _int_or(value, default):
    number = _as_int(value)
    if isinstance(number, bool) or not isinstance(number, int):
        return default
    return int(number)


# ---------------------------------------------------------------------------
# Input shaping: dict-ish props, a token list, or one source line
# ---------------------------------------------------------------------------
def _props_dict(props):
    """Coerce dict-ish *props* to a lower-cased-key dict.

    A plain dict is copied with lower-cased keys. Any other object
    contributes the attributes named in ``_NAME_KEYS`` /
    ``_AMOUNT_KEYS`` when it carries them. Everything else gives
    ``{}``.
    """
    if isinstance(props, dict):
        return _lower_keys(props)
    out = {}
    for key in _NAME_KEYS + _AMOUNT_KEYS:
        value = getattr(props, key, None)
        if value is not None:
            out[key] = value
    return out


def _tokens_of(props):
    """Token words for a token-list / source-line input, else ``None``.

    A string is split on whitespace and commas. A list / tuple keeps
    its scalar items and token-ish objects (via ``_word`` / their
    ``text``). A leading ``filter`` (or ``post``) keyword token is
    dropped, so both ``["blur", "2"]`` and ``["filter", "blur",
    "2"]`` -- and the source line ``"filter blur 2"`` -- shape the
    same way.
    """
    if isinstance(props, str):
        raw = props.replace(",", " ").split()
    elif isinstance(props, (list, tuple)):
        raw = []
        for item in props:
            if isinstance(item, str):
                raw.extend(item.replace(",", " ").split())
            elif isinstance(item, (int, float)) \
                    and not isinstance(item, bool):
                raw.append(item)
            else:
                word = _word(item)
                if word:
                    raw.append(word)
    else:
        return None
    tokens = list(raw)
    if tokens and isinstance(tokens[0], str) \
            and tokens[0].strip().lower() in ("filter", "post"):
        tokens = tokens[1:]
    return tokens


def _convert_amount(name, raw):
    """Convert *raw* for filter *name*; pass bad values through.

    ``blur`` amounts are pass counts and convert as ints; every other
    filter (and an unknown name, generically) converts as a number.
    """
    if name == "blur":
        return _as_int(raw)
    return _as_number(raw)


def _default_amount(name, raw):
    """The amount for *name* when *raw* is ``None``: its default."""
    if name in DEFAULTS:
        return DEFAULTS[name]
    return raw


# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------
def extract_post(props) -> dict:
    """Normalise one raw ``filter`` statement into a post dict. Pure.

    ``props`` is either the raw property dict the coordinator builds
    for one statement -- such as ``{"name": "blur", "amount": 2}``
    (``filter`` / ``type`` / ``kind`` / ``effect`` are accepted name
    spellings; ``value`` / ``passes`` / ``strength`` / ``factor`` /
    ``intensity`` are accepted amount spellings; a single-key dict
    such as ``{"gamma": 1.8}`` also works) -- or the statement's
    tokens, as a list / tuple (``["filter", "blur", "2"]`` or
    ``["blur", "2"]``, lexer tokens included) or as one source-line
    string (``"filter blur 2"``).

    Returns ``{"name": str, "amount": int | float}`` with the name
    lower-cased and the frozen per-filter default filled in when no
    amount is given (blur 1, bloom 0.5, vignette 0.5, gamma 2.2,
    grayscale 1.0, sepia 1.0). Unconvertible / non-finite amounts are
    passed through unchanged so validation can report them rather
    than losing them here. An unknown name is kept as written (so
    validation can name it) with its amount converted generically, or
    ``None`` when it gave none. ``props`` is never mutated.
    """
    tokens = None
    if isinstance(props, (str, list, tuple)):
        tokens = _tokens_of(props)
    if tokens is not None:
        if not tokens:
            return {"name": "", "amount": None}
        name = _word(tokens[0])
        raw = tokens[1] if len(tokens) > 1 else None
        if raw is None:
            return {"name": name, "amount": _default_amount(name, None)}
        return {"name": name, "amount": _convert_amount(name, raw)}

    shaped = _props_dict(props)
    name = _word(_first(shaped, *_NAME_KEYS))
    raw = _first(shaped, *_AMOUNT_KEYS)
    if not name:
        # Single-key spelling: {"blur": 3} / {"gamma": 1.8}.
        for key, value in shaped.items():
            if key in FILTER_NAMES:
                name = key
                if raw is None:
                    raw = value
                break
    if raw is None:
        return {"name": name, "amount": _default_amount(name, None)}
    return {"name": name, "amount": _convert_amount(name, raw)}


def collect_post(items) -> list[dict]:
    """Normalise an ordered chain of ``filter`` statements. Pure.

    ``items`` is an iterable of raw statements, each in any shape
    ``extract_post`` accepts (props dict, token list, or source-line
    string); a dict carrying a ``filters`` / ``chain`` / ``post``
    list is read as that list, and a single statement (one dict, one
    string, or one scalar token list such as ``["blur", "2"]``) is
    read as a one-filter chain.

    Returns ``[extract_post(item), ...]`` in the original order --
    chain order is the order filters apply in, so it is preserved
    exactly, duplicates included. ``None`` / empty input gives ``[]``.
    """
    if items is None:
        return []
    if isinstance(items, dict):
        for key in ("filters", "chain", "post"):
            inner = items.get(key)
            if isinstance(inner, (list, tuple)):
                return [extract_post(item) for item in inner]
        return [extract_post(items)]
    if isinstance(items, str):
        return [extract_post(items)]
    if isinstance(items, (list, tuple)):
        if items and all(isinstance(item, (str, int, float))
                         and not isinstance(item, bool)
                         for item in items):
            # One statement's token list, not a chain of statements.
            first = _word(items[0])
            if first in ("filter", "post") or first in FILTER_NAMES:
                return [extract_post(items)]
        return [extract_post(item) for item in items]
    return [extract_post(items)]


# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
def validate_post(d) -> list[str]:
    """Return human-readable errors for a normalised post dict.

    Checks: ``name`` is one of blur / bloom / vignette / gamma /
    grayscale / sepia; ``blur`` amount is an integer at least 1;
    ``bloom`` / ``vignette`` amounts are at least 0; ``gamma`` amount
    is more than 0; ``grayscale`` / ``sepia`` amounts are in 0..1;
    and every amount is a finite number. Each message names the
    filter and its allowed range. A missing ``amount`` is not an
    error (the frozen default applies). An empty list means valid.
    """
    errors = []
    if not isinstance(d, dict):
        return ["post %r is not a filter dict: a filter must have "
                "'name' and 'amount'" % (d,)]
    name = _word(d.get("name"))
    if not name:
        errors.append(
            "filter has no name: 'filter' must name one of %s"
            % ", ".join(FILTERS))
        return errors
    if name not in FILTER_NAMES:
        errors.append(
            "unknown filter %r: 'filter' must name one of %s"
            % (d.get("name"), ", ".join(FILTERS)))

    amount = d.get("amount")
    if amount is None:
        return errors

    if name == "blur":
        value = _as_int(amount)
        if isinstance(value, bool) or not isinstance(value, int):
            errors.append(
                "blur amount %r is not an integer: 'blur' amount "
                "must be an integer number of passes at least 1"
                % (amount,))
        elif value < 1:
            errors.append(
                "blur amount %d is out of range: 'blur' amount must "
                "be an integer number of passes at least 1" % value)
        return errors

    value = _as_number(amount)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        errors.append(
            "%s amount %r is not a number: '%s' amount must be a "
            "finite number" % (name, amount, name))
        return errors
    number = float(value)
    if not math.isfinite(number):
        errors.append(
            "%s amount is %s, but '%s' amount must be finite"
            % (name, "%.6g" % number, name))
        return errors
    if name in ("grayscale", "sepia"):
        if not (0.0 <= number <= 1.0):
            errors.append(
                "%s amount is %s, but '%s' amount must be in the "
                "range 0..1" % (name, "%.6g" % number, name))
    elif name == "gamma":
        if number <= 0.0:
            errors.append(
                "gamma amount is %s, but 'gamma' amount must be "
                "more than 0" % ("%.6g" % number,))
    elif name in ("bloom", "vignette"):
        if number < 0.0:
            errors.append(
                "%s amount is %s, but '%s' amount must be at "
                "least 0" % (name, "%.6g" % number, name))
    return errors


# ---------------------------------------------------------------------------
# Emit line
# ---------------------------------------------------------------------------
def post_line(d) -> str:
    """Serialise a post dict to its ``.scene`` line::

        post NAME AMOUNT

    The amount is formatted ``%.6g`` (the .scene float spelling, as
    in ``ext_particles.particles_line``); a ``blur`` pass count is
    emitted as an int. A missing amount falls back to the filter's
    frozen default.
    """
    d = d if isinstance(d, dict) else {}
    name = _word(d.get("name"))
    raw = d.get("amount")
    if raw is None:
        raw = DEFAULTS.get(name)
    if name == "blur":
        return "post %s %d" % (
            name, _int_or(raw, DEFAULT_BLUR))
    return "post %s %s" % (name, _fmt(_float_or(raw, 0.0)))


def post_lines(chain) -> list[str]:
    """Serialise an ordered filter chain to its ``.scene`` lines.

    ``chain`` is a list of post dicts as returned by ``extract_post``
    / ``collect_post``; one ``post`` line is emitted per filter, in
    chain order.
    """
    if not isinstance(chain, (list, tuple)):
        return []
    return [post_line(d) for d in chain]
