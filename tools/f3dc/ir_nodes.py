"""Forge3D frozen Typed IR (B08, Phase-0 contract, ``ir_version=1``).

Stdlib only. This module is the contract between the compiler front end
(lexer / parser / desugar / validate) and every back end (optimize /
emit_*).  Emitters see only this IR, never the AST or source text.

Field names, defaults and colour values are frozen by the task contract
derived from ``docs/plan/MASTER-PLAN.md`` sections 1-2 and P04 (Typed IR).
Do not add, rename or re-default fields without a new ``ir_version``.

Notes on deliberate choices:
* Dataclasses are not ``frozen=True``: scenes carry mutable lists / dicts
  (``lights``, ``objects``, ``extensions`` ...) and optimiser / extension
  passes mutate or rebuild them.  "Frozen" here means the *contract*
  (shape + defaults + ``ir_version``) is frozen, per the Phase-0 freeze.
* Spans are not carried on IR nodes, except that callers may keep a
  source map elsewhere; ``Span`` is imported from ``errors`` when that
  sibling module (B02) is present, purely for ``parse_color`` callers.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

try:  # B02 sibling module; not required for the IR itself to work.
    from errors import Diagnostic, Span  # type: ignore
except Exception:  # pragma: no cover - B02 may not have landed yet
    try:
        from .errors import Diagnostic, Span  # type: ignore
    except Exception:
        Span = Any  # type: ignore
        Diagnostic = None  # type: ignore

__all__ = [
    "IR_VERSION",
    "IRScene",
    "IRCamera",
    "IRLight",
    "IRObject",
    "IRAnim",
    "IROutput",
    "NAMED_COLORS",
    "PALETTE_FACES",
    "EXTENSION_REGISTRY",
    "register_extension",
    "apply_extensions",
    "parse_color",
    "to_dict",
    "from_dict",
    "to_json",
    "from_json",
]

IR_VERSION = 1

# ---------------------------------------------------------------------------
# Colours -- single source of truth
# ---------------------------------------------------------------------------
# The six saturated values are exactly the per-face colours hard-coded in
# src/mesh.f90 (create_cube).  Object-line colour words mean exactly these
# tuples everywhere (compiler, Fortran emit, JS emit, viewer).
NAMED_COLORS: dict = {
    "red": (220, 60, 60),
    "green": (60, 220, 60),
    "blue": (60, 100, 240),
    "yellow": (240, 220, 50),
    "magenta": (200, 80, 220),
    "cyan": (60, 220, 220),
    "orange": (240, 140, 40),
    "purple": (140, 80, 200),
    "pink": (240, 150, 190),
    "white": (240, 240, 240),
    "black": (20, 20, 25),
    "gray": (140, 140, 145),
    "grey": (140, 140, 145),
}

# Per-face palette in mesh.f90 face order: south, east, north, west, top,
# bottom (two triangles per face in create_cube).
PALETTE_FACES: list = [
    NAMED_COLORS["red"],      # south
    NAMED_COLORS["green"],    # east
    NAMED_COLORS["blue"],     # north
    NAMED_COLORS["yellow"],   # west
    NAMED_COLORS["magenta"],  # top
    NAMED_COLORS["cyan"],     # bottom
]


# ---------------------------------------------------------------------------
# Typed IR dataclasses
# ---------------------------------------------------------------------------
@dataclass
class IRCamera:
    pos: tuple = (3, 2.5, 4)
    target: tuple = (0, 0, 0)
    up: tuple = (0, 1, 0)
    fov: float = 60.0
    near: float = 0.1
    far: float = 100.0


@dataclass
class IRLight:
    kind: str = "directional"
    direction: tuple = (-0.5, -1, -0.7)
    color: tuple = (255, 255, 255)
    intensity: float = 1.0


@dataclass
class IRObject:
    name: str
    prim: str
    color: Optional[tuple] = None  # None = per-face palette (PALETTE_FACES)
    pos: tuple = (0, 0, 0)
    rotate: tuple = (0, 0, 0)  # degrees
    scale: tuple = (1, 1, 1)
    size: float = 2.0
    size3: Optional[tuple] = None
    radius: Optional[float] = None
    height: Optional[float] = None
    segments: Optional[int] = None
    detail: str = "med"
    capped: bool = True
    material: str = "lambert"
    triangles: Any = None  # compat raw triangles, if any
    source_file: Optional[str] = None  # for `load`
    extensions: dict = field(default_factory=dict)


@dataclass
class IRAnim:
    kind: str
    target: str
    axis: str = "y"
    speed: float = 90.0
    duration: float = 5.0
    fps: int = 30
    ease: str = "linear"
    loop: str = "forever"


@dataclass
class IROutput:
    kind: str = "render"
    path: Optional[str] = None
    format: Optional[str] = None
    width: Optional[int] = None
    height: Optional[int] = None


@dataclass
class IRScene:
    name: str = "untitled"
    width: int = 640
    height: int = 480
    bg: tuple = (25, 25, 35)
    camera: IRCamera = field(default_factory=IRCamera)
    lights: list = field(default_factory=list)
    objects: list = field(default_factory=list)
    animations: list = field(default_factory=list)
    outputs: list = field(default_factory=list)
    extensions: dict = field(default_factory=dict)
    # Optional source map (span info kept out of the typed fields above).
    # Not part of the frozen field contract: excluded from to_dict unless
    # explicitly set, so the serialised shape stays exactly as frozen.
    source_map: Any = field(default=None, repr=False, compare=False)


# ---------------------------------------------------------------------------
# Extension hooks (plan rule 4: new features register, they do not edit IR)
# ---------------------------------------------------------------------------
EXTENSION_REGISTRY: dict = {}


def register_extension(name: str, fn: Optional[Callable] = None):
    """Register ``fn`` under ``name``; usable directly or as a decorator.

    An extension function is called as ``fn(scene, bag)`` (falling back to
    ``fn(scene)`` if it accepts only one argument).  It may mutate the
    scene in place and return ``None``, or return a replacement scene.
    """
    if fn is None:
        def _decorator(f):
            EXTENSION_REGISTRY[name] = f
            return f
        return _decorator
    EXTENSION_REGISTRY[name] = fn
    return fn


def apply_extensions(scene: IRScene, bag: Any = None) -> IRScene:
    """Call every registered extension function against ``scene``.

    Extensions run in registration order.  A function returning a scene
    replaces the current one for subsequent extensions and for the
    return value; a function returning ``None`` is assumed to have
    mutated the scene in place.
    """
    for _name, fn in list(EXTENSION_REGISTRY.items()):
        try:
            result = fn(scene, bag)
        except TypeError:
            result = fn(scene)
        if result is not None:
            scene = result
    return scene


# ---------------------------------------------------------------------------
# Colour parsing
# ---------------------------------------------------------------------------
_HEX_RE = re.compile(r"^#([0-9a-fA-F]{6})$")
_RGB_RE = re.compile(
    r"^rgb\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*\)$",
    re.IGNORECASE,
)


def _report_e202(bag: Any, raw: Any, span: Any) -> None:
    """Record an E202 (unknown colour) diagnostic in ``bag``.

    ``bag`` is deliberately duck-typed because the B02 ErrorBag API and
    this module land in parallel: try the plausible bag interfaces in
    order and, if none applies, raise so the error is never silent.
    """
    message = "unknown color %r" % (raw,)
    code = "E202"
    if bag is None:
        raise ValueError("%s: %s" % (code, message))
    # list-like bags (including plain lists used in tests)
    if isinstance(bag, list):
        bag.append("%s: %s" % (code, message))
        return
    # Real B02 ErrorBag: add() takes a single Diagnostic.
    if Diagnostic is not None and callable(getattr(bag, "add", None)):
        try:
            bag.add(
                Diagnostic(
                    code=code,
                    severity="error",
                    message=message,
                    span=span,
                    help="use a named color, #rrggbb, or rgb(r,g,b)",
                )
            )
            return
        except Exception:
            pass
    errors_list = getattr(bag, "diagnostics", None)
    # Bag objects exposing a callable add/error-style method.
    for method_name in ("add", "error", "add_error", "report", "append"):
        method = getattr(bag, method_name, None)
        if not callable(method):
            continue
        for args in (
            (code, message, span),
            (code, span, message),
            (code, message),
            (message,),
        ):
            try:
                method(*args)
                return
            except TypeError:
                continue
            except Exception:
                return
    if isinstance(errors_list, list):
        errors_list.append("%s: %s" % (code, message))
        return
    raise ValueError("%s: %s" % (code, message))


def parse_color(raw: Any, bag: Any = None, span: Any = None):
    """Parse a colour into an ``(r, g, b)`` tuple of ints, or ``None``.

    Accepts named colours (``NAMED_COLORS``, case-insensitive),
    ``'#rrggbb'`` and ``'rgb(r,g,b)'``; a 3-sequence of ints is passed
    through as a tuple.  ``None`` input returns ``None`` (meaning, for an
    object, "use the per-face palette").  Anything unknown / malformed /
    out of range reports E202 through ``bag`` (see ``_report_e202``) and
    returns ``None``.
    """
    if raw is None:
        return None
    if isinstance(raw, (tuple, list)):
        if len(raw) == 3 and all(
            isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 255
            for v in raw
        ):
            return (int(raw[0]), int(raw[1]), int(raw[2]))
        _report_e202(bag, raw, span)
        return None
    if not isinstance(raw, str):
        _report_e202(bag, raw, span)
        return None

    text = raw.strip()
    named = NAMED_COLORS.get(text.lower())
    if named is not None:
        return tuple(named)

    match = _HEX_RE.match(text)
    if match:
        hexpart = match.group(1)
        return (
            int(hexpart[0:2], 16),
            int(hexpart[2:4], 16),
            int(hexpart[4:6], 16),
        )

    match = _RGB_RE.match(text)
    if match:
        values = tuple(int(match.group(i)) for i in (1, 2, 3))
        if all(0 <= v <= 255 for v in values):
            return values
        _report_e202(bag, raw, span)
        return None

    _report_e202(bag, raw, span)
    return None


# ---------------------------------------------------------------------------
# Serialisation: to_dict / from_dict / to_json / from_json (ir_version=1)
# ---------------------------------------------------------------------------
def _json_safe(value: Any) -> Any:
    """Recursively convert tuples to lists so the result is JSON-safe."""
    if isinstance(value, tuple):
        return [_json_safe(v) for v in value]
    if isinstance(value, list):
        return [_json_safe(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _json_safe(v) for k, v in value.items()}
    return value


def _tuple_or_none(value: Any):
    return None if value is None else tuple(value)


def _restore_triangles(value: Any) -> Any:
    """Restore raw compat triangles as closely as JSON allows.

    A list of exactly three numbers becomes a tuple (a vertex / colour);
    other lists keep their list shape with elements restored recursively;
    dicts restore their values recursively.  This makes a scene whose
    ``triangles`` were built from tuples round-trip exactly, while plain
    list-based triangles stay lists of tuples for their leaf triples.
    """
    if isinstance(value, dict):
        return {k: _restore_triangles(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        items = [_restore_triangles(v) for v in value]
        def _is_num(v):
            return isinstance(v, (int, float)) and not isinstance(v, bool)

        def _is_num_tuple(v):
            return isinstance(v, tuple) and len(v) == 3 and all(
                _is_num(x) for x in v
            )

        if len(items) == 3 and (
            all(_is_num(v) for v in items)
            or all(_is_num_tuple(v) for v in items)
        ):
            return tuple(items)
        return items
    return value


def to_dict(scene: IRScene) -> dict:
    """Serialise ``scene`` to a JSON-safe dict stamped ``ir_version: 1``."""
    data = {
        "ir_version": IR_VERSION,
        "name": scene.name,
        "width": scene.width,
        "height": scene.height,
        "bg": _json_safe(scene.bg),
        "camera": {
            "pos": _json_safe(scene.camera.pos),
            "target": _json_safe(scene.camera.target),
            "up": _json_safe(scene.camera.up),
            "fov": scene.camera.fov,
            "near": scene.camera.near,
            "far": scene.camera.far,
        },
        "lights": [
            {
                "kind": light.kind,
                "direction": _json_safe(light.direction),
                "color": _json_safe(light.color),
                "intensity": light.intensity,
            }
            for light in scene.lights
        ],
        "objects": [
            {
                "name": obj.name,
                "prim": obj.prim,
                "color": _json_safe(obj.color),
                "pos": _json_safe(obj.pos),
                "rotate": _json_safe(obj.rotate),
                "scale": _json_safe(obj.scale),
                "size": obj.size,
                "size3": _json_safe(obj.size3),
                "radius": obj.radius,
                "height": obj.height,
                "segments": obj.segments,
                "detail": obj.detail,
                "capped": obj.capped,
                "material": obj.material,
                "triangles": _json_safe(obj.triangles),
                "source_file": obj.source_file,
                "extensions": _json_safe(obj.extensions or {}),
            }
            for obj in scene.objects
        ],
        "animations": [
            {
                "kind": anim.kind,
                "target": anim.target,
                "axis": anim.axis,
                "speed": anim.speed,
                "duration": anim.duration,
                "fps": anim.fps,
                "ease": anim.ease,
                "loop": anim.loop,
            }
            for anim in scene.animations
        ],
        "outputs": [
            {
                "kind": out.kind,
                "path": out.path,
                "format": out.format,
                "width": out.width,
                "height": out.height,
            }
            for out in scene.outputs
        ],
        "extensions": _json_safe(scene.extensions or {}),
    }
    if getattr(scene, "source_map", None) is not None:
        data["source_map"] = _json_safe(scene.source_map)
    return data


def from_dict(d: dict) -> IRScene:
    """Rebuild an ``IRScene`` from ``to_dict`` output (exact round-trip)."""
    if not isinstance(d, dict):
        raise TypeError("from_dict expects a dict, got %s" % type(d).__name__)
    cam = d.get("camera") or {}
    camera = IRCamera(
        pos=tuple(cam.get("pos", (3, 2.5, 4))),
        target=tuple(cam.get("target", (0, 0, 0))),
        up=tuple(cam.get("up", (0, 1, 0))),
        fov=cam.get("fov", 60.0),
        near=cam.get("near", 0.1),
        far=cam.get("far", 100.0),
    )
    lights = [
        IRLight(
            kind=light.get("kind", "directional"),
            direction=tuple(light.get("direction", (-0.5, -1, -0.7))),
            color=tuple(light.get("color", (255, 255, 255))),
            intensity=light.get("intensity", 1.0),
        )
        for light in (d.get("lights") or [])
    ]
    objects = [
        IRObject(
            name=obj["name"],
            prim=obj["prim"],
            color=_tuple_or_none(obj.get("color")),
            pos=tuple(obj.get("pos", (0, 0, 0))),
            rotate=tuple(obj.get("rotate", (0, 0, 0))),
            scale=tuple(obj.get("scale", (1, 1, 1))),
            size=obj.get("size", 2.0),
            size3=_tuple_or_none(obj.get("size3")),
            radius=obj.get("radius"),
            height=obj.get("height"),
            segments=obj.get("segments"),
            detail=obj.get("detail", "med"),
            capped=obj.get("capped", True),
            material=obj.get("material", "lambert"),
            triangles=(
                None
                if obj.get("triangles") is None
                else _restore_triangles(obj.get("triangles"))
            ),
            source_file=obj.get("source_file"),
            extensions=dict(obj.get("extensions") or {}),
        )
        for obj in (d.get("objects") or [])
    ]
    animations = [
        IRAnim(
            kind=anim["kind"],
            target=anim["target"],
            axis=anim.get("axis", "y"),
            speed=anim.get("speed", 90.0),
            duration=anim.get("duration", 5.0),
            fps=anim.get("fps", 30),
            ease=anim.get("ease", "linear"),
            loop=anim.get("loop", "forever"),
        )
        for anim in (d.get("animations") or [])
    ]
    outputs = [
        IROutput(
            kind=out.get("kind", "render"),
            path=out.get("path"),
            format=out.get("format"),
            width=out.get("width"),
            height=out.get("height"),
        )
        for out in (d.get("outputs") or [])
    ]
    scene = IRScene(
        name=d.get("name", "untitled"),
        width=d.get("width", 640),
        height=d.get("height", 480),
        bg=tuple(d.get("bg", (25, 25, 35))),
        camera=camera,
        lights=lights,
        objects=objects,
        animations=animations,
        outputs=outputs,
        extensions=dict(d.get("extensions") or {}),
    )
    if d.get("source_map") is not None:
        scene.source_map = d["source_map"]
    return scene


def to_json(scene: IRScene, **kwargs: Any) -> str:
    """Serialise ``scene`` to a JSON string (see ``to_dict``)."""
    return json.dumps(to_dict(scene), **kwargs)


def from_json(text: Any) -> IRScene:
    """Parse a JSON string (or an already-decoded dict) into an IRScene."""
    if isinstance(text, dict):
        return from_dict(text)
    if isinstance(text, (bytes, bytearray)):
        text = text.decode("utf-8")
    return from_dict(json.loads(text))
