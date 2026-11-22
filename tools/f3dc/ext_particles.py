"""Forge3D Wave B extension: deterministic ``particles`` statements.

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan rule
4: new features register, they do not edit the frozen IR). It owns the
Wave B particle surface (MASTER-PLAN row 32); the compiler coordinator
wires ``parser.py`` / ``validate.py`` / ``emit`` to call it.

It is also the Python mirror of the particle math in
``src/particles.f90`` (and of the JS mirror, seat B72): the integer
hash and the particle state below follow the frozen determinism
contract *exactly*, so the same seed and the same ``t`` give the same
frame on every backend. A particle's state is a pure function of
(system, index, t): there is no simulation state, no accumulation and
no wall clock.

User syntax::

    particles sparks at 0,2,0 count 100 life 2 speed 3 size 0.2 \
        color orange spread 0.5 gravity 9 seed 7

``.scene`` line emitted::

    particles NAME PX PY PZ COUNT LIFE SPEED SIZE R G B SPREAD GRAVITY SEED

Public API (the exact names the coordinator wires to)::

    extract_particles(props) -> dict
    validate_particles(d) -> list[str]
    particles_line(name, d) -> str
    particle_hash01(seed, i, k) -> float
    particle_state(d, i, t) -> (pos_tuple, scale)

Normalised shape::

    {"origin": (x, y, z), "count": int, "life": float,
     "speed": float, "size": float, "color": (r, g, b),
     "spread": float, "gravity": float, "seed": int}

with defaults origin (0, 0, 0) [from the ``at`` prop], count 100,
life 2.0, speed 3.0, size 0.2, color (255, 180, 60), spread 0.5,
gravity 0.0 and seed 1 -- exactly the frozen defaults of
``ParticleSystem`` in ``particles.f90`` (gravity is opt-in, so the
default motion is a clean fountain with vy positive).

All functions are defensive, pure and side-effect free. Error strings
are plain human-readable messages (no diagnostic codes): ``validate``
wraps them in diagnostics, exactly as for ``ext_materials`` /
``ext_lights_env`` / ``ext_sprites_text``.
"""

from __future__ import annotations

import math
import re

__all__ = [
    "NAMED_COLORS",
    "DEFAULT_ORIGIN",
    "DEFAULT_COUNT",
    "DEFAULT_LIFE",
    "DEFAULT_SPEED",
    "DEFAULT_SIZE",
    "DEFAULT_COLOR",
    "DEFAULT_SPREAD",
    "DEFAULT_GRAVITY",
    "DEFAULT_SEED",
    "HASH_MOD",
    "extract_particles",
    "validate_particles",
    "particles_line",
    "particle_hash01",
    "particle_state",
]

# ---------------------------------------------------------------------------
# Defaults / limits (frozen: particles.f90 ParticleSystem)
# ---------------------------------------------------------------------------
DEFAULT_ORIGIN = (0.0, 0.0, 0.0)
DEFAULT_COUNT = 100
DEFAULT_LIFE = 2.0
DEFAULT_SPEED = 3.0
DEFAULT_SIZE = 0.2
DEFAULT_COLOR = (255, 180, 60)
DEFAULT_SPREAD = 0.5
DEFAULT_GRAVITY = 0.0
DEFAULT_SEED = 1

# 2^31, the hash modulus (frozen).
HASH_MOD = 2147483648

# Validation ranges (seed's upper bound is the JS exactness bound
# from B72: beyond it the JS mirror's integer arithmetic would lose
# exactness, so the surface is capped where all mirrors agree).
_MIN_COUNT, _MAX_COUNT = 1, 10000
_MAX_LIFE = 3600.0
_MAX_SPEED = 1000.0
_MAX_SIZE = 10.0
_MAX_SPREAD = 10.0
_MIN_GRAVITY, _MAX_GRAVITY = -100.0, 100.0
_MIN_SEED, _MAX_SEED = 0, 100000

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
# Generic value helpers (same tolerant shapes as ext_sprites_text)
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
    defaulted) so ``validate_particles`` can report them, mirroring
    ``ext_materials._as_number``.
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
    anything else is returned unchanged so ``validate_particles``
    can report it rather than losing it here.
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
# Extract
# ---------------------------------------------------------------------------
def extract_particles(props: dict) -> dict:
    """Normalise raw particle props into a particles dict. Pure.

    ``props`` is the raw property dict ``validate.py`` builds for one
    statement -- a plain dict of raw values such as
    ``{"at": (0, 2, 0), "count": 100, "life": 2, "speed": 3,
    "size": 0.2, "color": "orange", "spread": 0.5, "gravity": 9,
    "seed": 7}`` (``at`` may also be an ``"x,y,z"`` string, the
    numerics numeric strings, and ``color`` / ``colour`` a named
    colour, ``'#rrggbb'``, ``'rgb(r,g,b)'`` or an ``(r, g, b)``
    sequence).

    Returns::

        {"origin": (x, y, z), "count": int, "life": float,
         "speed": float, "size": float, "color": (r, g, b),
         "spread": float, "gravity": float, "seed": int}

    with the frozen defaults origin (0, 0, 0), count 100, life 2.0,
    speed 3.0, size 0.2, color (255, 180, 60), spread 0.5,
    gravity 0.0 and seed 1. The origin is read from the ``at`` prop
    (``origin`` / ``position`` / ``pos`` are accepted spellings too).
    Unconvertible / non-finite values are passed through unchanged
    so validation can report them rather than losing them here.
    ``props`` is never mutated.
    """
    props = _lower_keys(props)
    origin = _vec3(_first(props, "at", "origin", "position", "pos"))
    if origin is None and any(k in props for k in ("x", "y", "z")):
        origin = _vec3({axis: props.get(axis) for axis in ("x", "y", "z")})
    if origin is None:
        origin = DEFAULT_ORIGIN
    count = _as_int(_first(props, "count"))
    if count is None:
        count = DEFAULT_COUNT
    life = _as_number(_first(props, "life"))
    if life is None:
        life = DEFAULT_LIFE
    speed = _as_number(_first(props, "speed"))
    if speed is None:
        speed = DEFAULT_SPEED
    size = _as_number(_first(props, "size"))
    if size is None:
        size = DEFAULT_SIZE
    color = _parse_color(_first(
        props, "color", "colour", "color_raw", "colour_raw",
        "color_value", "colour_value"))
    if color is None:
        color = DEFAULT_COLOR
    spread = _as_number(_first(props, "spread"))
    if spread is None:
        spread = DEFAULT_SPREAD
    gravity = _as_number(_first(props, "gravity"))
    if gravity is None:
        gravity = DEFAULT_GRAVITY
    seed = _as_int(_first(props, "seed"))
    if seed is None:
        seed = DEFAULT_SEED
    return {
        "origin": origin,
        "count": count,
        "life": life,
        "speed": speed,
        "size": size,
        "color": color,
        "spread": spread,
        "gravity": gravity,
        "seed": seed,
    }


# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
def _validate_int(errors, d, key, low, high):
    if key not in d or d[key] is None:
        return
    value = _as_int(d[key])
    if isinstance(value, bool) or not isinstance(value, int):
        errors.append(
            "%s %r is not an integer: '%s' must be in the range "
            "%d..%d" % (key, d[key], key, low, high))
    elif not (low <= value <= high):
        errors.append(
            "%s %d is out of range: '%s' must be in the range %d..%d"
            % (key, value, key, low, high))


def _validate_float(errors, d, key, low, high, low_inclusive):
    if key not in d or d[key] is None:
        return
    value = _as_number(d[key])
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        errors.append(
            "%s %r is not a number: '%s' must be in the range "
            "%g..%g" % (key, d[key], key, low, high))
        return
    number = float(value)
    in_range = (low <= number if low_inclusive else low < number) \
        and number <= high
    if not math.isfinite(number) or not in_range:
        errors.append(
            "%s is %s, but '%s' must be %s %g and at most %g"
            % (key, "%.6g" % number, key,
               "at least" if low_inclusive else "more than",
               low, high))


def validate_particles(d) -> list[str]:
    """Return human-readable errors for a normalised particles dict.

    Checks: ``count`` in 1..10000; ``life`` more than 0 and at most
    3600; ``speed`` in 0..1000; ``size`` more than 0 and at most 10;
    ``spread`` in 0..10; ``gravity`` in -100..100; ``seed`` in
    0..100000 (the JS exactness bound from B72); and every ``origin``
    coordinate finite. Each message names the offending property and
    its allowed range. An empty list means valid.
    """
    errors = []
    if not isinstance(d, dict):
        return errors
    origin = d.get("origin")
    if origin is None:
        origin = d.get("at")
    if origin is not None:
        vec = _vec3(origin)
        if vec is None:
            errors.append(
                "origin %r is not a position: 'origin' must be three "
                "finite coordinates (x, y, z)" % (origin,))
        else:
            for axis, component in zip(("x", "y", "z"), vec):
                number = _as_number(component)
                if isinstance(number, bool) \
                        or not isinstance(number, (int, float)):
                    errors.append(
                        "origin %s %r is not a number: 'origin' "
                        "coordinates must be finite" % (axis, component))
                elif not math.isfinite(float(number)):
                    errors.append(
                        "origin %s is %s, but 'origin' coordinates "
                        "must be finite"
                        % (axis, "%.6g" % float(number)))
    _validate_int(errors, d, "count", _MIN_COUNT, _MAX_COUNT)
    _validate_float(errors, d, "life", 0.0, _MAX_LIFE, False)
    _validate_float(errors, d, "speed", 0.0, _MAX_SPEED, True)
    _validate_float(errors, d, "size", 0.0, _MAX_SIZE, False)
    _validate_float(errors, d, "spread", 0.0, _MAX_SPREAD, True)
    _validate_float(errors, d, "gravity", _MIN_GRAVITY, _MAX_GRAVITY, True)
    _validate_int(errors, d, "seed", _MIN_SEED, _MAX_SEED)
    return errors


# ---------------------------------------------------------------------------
# Emit line
# ---------------------------------------------------------------------------
def particles_line(name, d) -> str:
    """Serialise a particles dict to its ``.scene`` line::

        particles NAME PX PY PZ COUNT LIFE SPEED SIZE R G B SPREAD GRAVITY SEED

    Floats are formatted ``%.6g``; ``count`` / ``seed`` and the colour
    channels are ints. Missing fields fall back to the frozen
    defaults.
    """
    d = d if isinstance(d, dict) else {}
    origin = _vec3(d.get("origin"))
    if origin is None:
        origin = _vec3(d.get("at"))
    if origin is None:
        origin = DEFAULT_ORIGIN
    return "particles %s %s %d %s %s %s %s %s %s %d" % (
        str(name),
        _fmt_vec(origin),
        _int_or(d.get("count"), DEFAULT_COUNT),
        _fmt(_float_or(d.get("life"), DEFAULT_LIFE)),
        _fmt(_float_or(d.get("speed"), DEFAULT_SPEED)),
        _fmt(_float_or(d.get("size"), DEFAULT_SIZE)),
        _fmt_color(d.get("color")),
        _fmt(_float_or(d.get("spread"), DEFAULT_SPREAD)),
        _fmt(_float_or(d.get("gravity"), DEFAULT_GRAVITY)),
        _int_or(d.get("seed"), DEFAULT_SEED),
    )


# ---------------------------------------------------------------------------
# Particle math (Python mirror of src/particles.f90 -- frozen contract)
# ---------------------------------------------------------------------------
def particle_hash01(seed, i, k) -> float:
    """Frozen integer hash -> [0, 1). Exact mirror of particles.f90.

    ``seed`` is the system seed, ``i`` the 0-based particle index and
    ``k`` the channel (0, 1, 2). Python ints are exact, so the recipe
    needs no overflow care::

        x = (seed*1103515245 + i*12345 + k*67890) % 2147483648
        x = (x*1103515245 + 12345) % 2147483648
        return x / 2147483648
    """
    x = (int(seed) * 1103515245 + int(i) * 12345
         + int(k) * 67890) % HASH_MOD
    x = (x * 1103515245 + 12345) % HASH_MOD
    return x / HASH_MOD


def particle_state(d, i, t):
    """State of particle *i* (0-based) at time *t*. Mirror of f90.

    ``d`` is a normalised particles dict as returned by
    ``extract_particles`` (any dict with the same keys works; missing
    fields fall back to the frozen defaults). Returns
    ``(pos, scale)`` where ``pos`` is an ``(x, y, z)`` tuple::

        age   = (t + i * (life / max(count, 1))) % life
        vel   = ((h0-.5)*2*spread*speed, speed*(0.5+0.5*h1),
                 (h2-.5)*2*spread*speed)   hk = hash01(seed, i, k)
        pos   = origin + vel*age + (0, -0.5*gravity*age^2, 0)
        scale = 1 - age/life

    If ``life`` <= 0 the particle is dead: ``pos`` is the origin and
    ``scale`` is 0.
    """
    d = d if isinstance(d, dict) else {}
    origin = _vec3(d.get("origin"))
    if origin is None:
        origin = _vec3(d.get("at"))
    if origin is None:
        origin = DEFAULT_ORIGIN
    origin = tuple(_float_or(c, 0.0) for c in origin)
    life = _float_or(d.get("life"), DEFAULT_LIFE)
    if life <= 0.0:
        return origin, 0.0
    count = _int_or(d.get("count"), DEFAULT_COUNT)
    n = max(count, 1)
    speed = _float_or(d.get("speed"), DEFAULT_SPEED)
    spread = _float_or(d.get("spread"), DEFAULT_SPREAD)
    gravity = _float_or(d.get("gravity"), DEFAULT_GRAVITY)
    seed = _int_or(d.get("seed"), DEFAULT_SEED)
    idx = int(i)
    age = (float(t) + idx * (life / n)) % life
    h0 = particle_hash01(seed, idx, 0)
    h1 = particle_hash01(seed, idx, 1)
    h2 = particle_hash01(seed, idx, 2)
    vel = (
        (h0 - 0.5) * 2.0 * spread * speed,
        speed * (0.5 + 0.5 * h1),
        (h2 - 0.5) * 2.0 * spread * speed,
    )
    pos = (
        origin[0] + vel[0] * age,
        origin[1] + vel[1] * age - 0.5 * gravity * age * age,
        origin[2] + vel[2] * age,
    )
    scale = 1.0 - age / life
    return pos, scale
