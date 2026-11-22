"""Forge3D Wave A material extension: ``standard`` material + PPM textures.

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan rule 4:
new features register, they do not edit the frozen IR). It owns the
Wave A material surface that ``validate.py`` used to reserve:

* ``material standard`` with optional ``metalness`` (default 0.0) and
  ``roughness`` (default 1.0), each in the range 0..1;
* the existing ``phong`` props ``specular`` (default 0.5, range 0..1)
  and ``shininess`` (default 32.0, range 0..1000);
* a ``texture "path.ppm"`` property on any object. Wave A supports
  PPM textures only (the Fortran side loads P3/P6 PPM files).

Public API (the compiler coordinator wires ``validate`` / ``cli`` to
these exact names):

    WAVEA_MATERIALS
    DEFAULTS
    extract_material_ext(props) -> dict
    validate_material_ext(material, ext) -> list[str]
    objmat_line(name, material, ext) -> str | None
    apply_to_ir_object(obj) -> None

All functions are defensive and side-effect free except
``apply_to_ir_object``, whose only effect is setting
``obj.extensions["material"]`` when a Wave A feature is in use.
"""

import os

__all__ = [
    "WAVEA_MATERIALS",
    "DEFAULTS",
    "extract_material_ext",
    "validate_material_ext",
    "objmat_line",
    "apply_to_ir_object",
]

# Materials introduced by Wave A (earlier materials -- lambert, basic,
# phong -- remain owned by validate.py).
WAVEA_MATERIALS = ("standard",)

# Defaults for every numeric material-extension property.
DEFAULTS = {
    "metalness": 0.0,
    "roughness": 1.0,
    "specular": 0.5,
    "shininess": 32.0,
}

# Allowed (low, high) range per numeric property.
_RANGES = {
    "metalness": (0.0, 1.0),
    "roughness": (0.0, 1.0),
    "specular": (0.0, 1.0),
    "shininess": (0.0, 1000.0),
}

# Which numeric properties are *relevant* (and therefore defaulted)
# for each material, even when the property itself is absent.
_RELEVANT = {
    "standard": ("metalness", "roughness"),
    "phong": ("specular", "shininess"),
}

_NUMERIC_KEYS = ("metalness", "roughness", "specular", "shininess")

# Texture file extensions supported in Wave A.
_TEXTURE_EXTS = (".ppm",)


# ---------------------------------------------------------------- helpers

def _material_of(props):
    """Normalised material name from a raw props dict, or ``None``."""
    if not isinstance(props, dict):
        return None
    raw = props.get("material")
    if raw is None:
        return None
    text = str(raw).strip().strip("\"'").strip().lower()
    return text or None


def _as_number(value):
    """Best-effort float conversion; unconvertible values pass through.

    Keeping an unconvertible value unchanged (instead of raising or
    silently defaulting) lets ``validate_material_ext`` report it as
    out of range rather than losing it here.
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


def _clean_texture(value):
    """Pass a texture path through, stripping surrounding quotes."""
    if value is None:
        return None
    if not isinstance(value, str):
        # Duck-typed token/node spellings: prefer a textual payload.
        for attr in ("value", "text", "path", "name"):
            inner = getattr(value, attr, None)
            if isinstance(inner, str):
                value = inner
                break
        else:
            value = str(value)
    text = value.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("\"", "'"):
        text = text[1:-1].strip()
    return text


# ---------------------------------------------------------------- extract

def extract_material_ext(props):
    """Normalise a raw object props dict into a material extension dict.

    ``props`` is the parser's raw property dict for one object (keys
    seen in the wild include ``material``, ``texture``, ``metalness``,
    ``roughness``, ``specular`` and ``shininess``). Returns a new dict::

        {"metalness": ..., "roughness": ..., "specular": ...,
         "shininess": ..., "texture": str | None}

    Defaults from ``DEFAULTS`` are filled *only* for keys that are
    relevant: the properties belonging to the declared material
    (``metalness`` / ``roughness`` for ``standard``, ``specular`` /
    ``shininess`` for ``phong``). A key that is present in ``props``
    always keeps its own (float-converted) value. Irrelevant, absent
    keys are ``None``. ``texture`` is passed through with any
    surrounding quotes stripped (``None`` when absent).

    Pure: ``props`` is never mutated.
    """
    if not isinstance(props, dict):
        props = {}
    material = _material_of(props)
    relevant = _RELEVANT.get(material, ())
    ext = {}
    for key in _NUMERIC_KEYS:
        if key in props and props[key] is not None:
            ext[key] = _as_number(props[key])
        elif key in relevant:
            ext[key] = DEFAULTS[key]
        else:
            ext[key] = None
    ext["texture"] = _clean_texture(props.get("texture"))
    return ext


# ---------------------------------------------------------------- validate

def validate_material_ext(material, ext):
    """Validate a material extension dict; return a list of errors.

    ``material`` is the object's material name and ``ext`` a dict as
    returned by ``extract_material_ext`` (any dict with the same keys
    works). The result is a list of human-readable error strings;
    an empty list means the extension is valid.

    Checks: ``metalness``, ``roughness`` and ``specular`` must lie in
    0..1 and ``shininess`` in 0..1000 (each message names the property
    and its allowed range), and a texture path, when present, must be
    non-empty and carry a supported extension -- only ``.ppm`` is
    supported in Wave A.
    """
    errors = []
    if not isinstance(ext, dict):
        return errors
    for key in _NUMERIC_KEYS:
        if key not in ext or ext[key] is None:
            continue
        low, high = _RANGES[key]
        value = _as_number(ext[key])
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            errors.append(
                "%s %r is not a number: %s must be in the range %g..%g"
                % (key, ext[key], key, low, high))
        elif not (low <= float(value) <= high):
            errors.append(
                "%s %g is out of range: %s must be in the range %g..%g"
                % (key, float(value), key, low, high))
    texture = ext.get("texture")
    if texture is not None:
        if not isinstance(texture, str) or not texture.strip():
            errors.append(
                "texture path is empty: texture must name a .ppm file "
                "(only .ppm textures are supported in Wave A)")
        else:
            suffix = os.path.splitext(texture.strip())[1].lower()
            if suffix not in _TEXTURE_EXTS:
                errors.append(
                    "texture %r has unsupported extension %r: only .ppm "
                    "textures are supported in Wave A"
                    % (texture, suffix or "(none)"))
    return errors


# ---------------------------------------------------------------- emit line

def _fmt(value, key):
    """Format one numeric field for an ``objmat`` line (``%g`` style)."""
    number = _as_number(value)
    if isinstance(number, bool) or not isinstance(number, (int, float)):
        number = DEFAULTS[key]
    return "%g" % float(number)


def _value_or_default(ext, key):
    value = ext.get(key)
    return DEFAULTS[key] if value is None else value


def _is_non_default(ext, key):
    value = ext.get(key)
    if value is None:
        return False
    number = _as_number(value)
    if isinstance(number, bool) or not isinstance(number, (int, float)):
        return True
    return float(number) != DEFAULTS[key]


def objmat_line(name, material, ext):
    """Return the ``.scene`` ``objmat`` line for one object, or ``None``.

    ``None`` is returned unless the object actually needs a line: its
    material is ``standard``, or it carries a texture, or its
    ``specular`` / ``shininess`` differ from the defaults. Otherwise
    the line is exactly::

        objmat <name> <material> <metalness> <roughness> <specular> <shininess> <texture-or-dash>

    with floats formatted ``%g``-style and ``-`` for no texture.
    Missing / ``None`` numeric fields fall back to ``DEFAULTS``.
    """
    if not isinstance(ext, dict):
        ext = {}
    material_text = str(material).strip().lower() if material else "lambert"
    texture = ext.get("texture")
    if isinstance(texture, str):
        texture = texture.strip() or None
    elif texture is not None:
        texture = str(texture)
    needs_line = (
        material_text in WAVEA_MATERIALS
        or bool(texture)
        or _is_non_default(ext, "specular")
        or _is_non_default(ext, "shininess")
    )
    if not needs_line:
        return None
    return "objmat %s %s %s %s %s %s %s" % (
        name,
        material_text,
        _fmt(_value_or_default(ext, "metalness"), "metalness"),
        _fmt(_value_or_default(ext, "roughness"), "roughness"),
        _fmt(_value_or_default(ext, "specular"), "specular"),
        _fmt(_value_or_default(ext, "shininess"), "shininess"),
        texture if texture else "-",
    )


# ---------------------------------------------------------------- IR apply

def apply_to_ir_object(obj):
    """Attach the material extension to one IR object, in place.

    Duck-typed and defensive: the raw props are read from
    ``obj.extensions["raw_props"]`` when that is a dict, and the
    attributes ``metalness`` / ``roughness`` / ``specular`` /
    ``shininess`` / ``texture`` are honoured when present on the
    object itself (as is ``obj.material``). When anything Wave A is
    relevant -- a ``standard`` material, a texture, or any of the
    numeric properties being set -- the normalised extension is
    stored as ``obj.extensions["material"]``.

    A plain ``lambert`` object with nothing set is a strict no-op:
    its ``extensions`` dict is left untouched.
    """
    if obj is None:
        return
    extensions = getattr(obj, "extensions", None)
    if not isinstance(extensions, dict):
        extensions = None

    props = {}
    if extensions is not None:
        raw_props = extensions.get("raw_props")
        if isinstance(raw_props, dict):
            props.update(raw_props)

    material = props.get("material")
    if material is None:
        material = getattr(obj, "material", None)
        if material is not None:
            props["material"] = material

    for key in _NUMERIC_KEYS + ("texture",):
        if props.get(key) is None:
            value = getattr(obj, key, None)
            if value is not None:
                props[key] = value

    material_text = _material_of(props)
    relevant = (
        material_text in WAVEA_MATERIALS
        or props.get("texture") is not None
        or any(props.get(key) is not None for key in _NUMERIC_KEYS)
    )
    if not relevant:
        return

    if extensions is None:
        extensions = {}
        try:
            obj.extensions = extensions
        except Exception:
            return
    extensions["material"] = extract_material_ext(props)
