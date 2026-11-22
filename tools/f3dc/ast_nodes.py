"""AST nodes for the Forge3D ``.f3d`` language (seat B04).

Implements the node set in ``docs/plan/MASTER-PLAN.md`` section 1
(synthesising P03 section 4's EBNF, as amended by the later plans).

Design rules
------------
* Stdlib only.
* The AST keeps *source fidelity*: a field the user omitted is ``None``
  (never a default value).  Injecting defaults is desugar's job
  (B07), not the parser's, so diagnostics and ``--emit ast`` show what
  the user actually wrote.
* Every node is a plain (mutable) :func:`dataclasses.dataclass` and
  carries ``span: Span | None`` -- ``None`` for synthetic nodes built
  by e.g. ``compat.py`` when no source location exists.
* Collection / mapping fields default to empty (``[]`` / ``{}`` via
  ``field(default_factory=...)``), scalar fields default to ``None``,
  so the parser can construct a node incrementally.

Colour representation
---------------------
Colours are **not** resolved in the AST.  A colour field holds the
*raw* string, normalised by the parser to one of three spellings:

* a named colour, lower-cased:          ``'red'``
* a hex literal, lower-cased:           ``'#3cdc3c'``
* an ``rgb()`` literal, no spaces:      ``'rgb(60,220,60)'``

Resolving a raw string to an ``(r, g, b)`` triple (named palette,
range checks) happens later (validate / emit_common).  Use
:func:`colour_raw` to build the canonical ``rgb()`` raw form from
channel values.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Union

try:  # package import (tools.f3dc as a package / f3dc_pkg layout)
    from .errors import Span
except ImportError:  # flat module layout: tools/f3dc on sys.path
    from errors import Span

__all__ = [
    "Vec3",
    "Stmt",
    "colour_raw",
    "Program",
    "SceneStmt",
    "CameraStmt",
    "LightStmt",
    "ObjectStmt",
    "GroupStmt",
    "AnimStmt",
    "LoadStmt",
    "RepeatStmt",
    "ControlsStmt",
    "OutputStmt",
]

#: A 3-component vector as written in source, e.g. ``(1.0, 2.0, 3.0)``.
Vec3 = tuple[float, float, float]


def colour_raw(r: int, g: int, b: int) -> str:
    """Return the canonical raw colour string for channels *r*, *g*, *b*.

    >>> colour_raw(60, 220, 60)
    'rgb(60,220,60)'

    This is a pure formatter: it does not range-check the channels
    (0-255 validation is a later stage's diagnostic, not the AST's).
    """
    return f"rgb({r},{g},{b})"


@dataclass
class Program:
    """Root node: a whole ``.f3d`` file, statements in source order."""

    statements: list = field(default_factory=list)
    span: Span | None = None


@dataclass
class SceneStmt:
    """``scene [name] [size WxH] [bg colour]``.

    ``bg`` is the raw colour text (see module docstring); it is
    resolved to RGB later, not here.
    """

    name: str | None = None
    width: int | None = None
    height: int | None = None
    bg: str | None = None
    span: Span | None = None


@dataclass
class CameraStmt:
    """``camera at <vec3> look <vec3> up <vec3> fov <num> near <num> far <num>``.

    Every field is ``None`` when omitted in source.
    """

    pos: Vec3 | None = None
    target: Vec3 | None = None
    up: Vec3 | None = None
    fov: float | None = None
    near: float | None = None
    far: float | None = None
    span: Span | None = None


@dataclass
class LightStmt:
    """``light directional|ambient [direction] [colour] [intensity n]``.

    ``color`` is the raw colour text (see module docstring), or
    ``None`` when omitted.
    """

    kind: str = "directional"  # 'directional' | 'ambient'
    direction: Vec3 | None = None
    color: str | None = None
    intensity: float | None = None
    span: Span | None = None

    @property
    def color_raw(self) -> str | None:
        """Alias for :attr:`color` (raw colour text, unresolved)."""
        return self.color

    @color_raw.setter
    def color_raw(self, value: str | None) -> None:
        self.color = value


@dataclass
class ObjectStmt:
    """``<prim> [name] [colour] {prop}`` -- the only geometry creator.

    ``prim`` is one of ``cube|sphere|cylinder|plane|pyramid|cone|torus``.
    ``color_raw`` is the raw colour text, or ``None`` when omitted.
    ``props`` holds the remaining properties as written; known keys:

    ``at`` (Vec3), ``size`` (float | Vec3), ``radius`` (float),
    ``height`` (float), ``rotate`` (Vec3), ``scale`` (float | Vec3),
    ``material`` (str), ``segments`` (int), ``detail`` (str),
    ``capped`` (bool), ``texture`` (str | None).
    """

    prim: str = ""
    name: str | None = None
    color_raw: str | None = None
    props: dict[str, Any] = field(default_factory=dict)
    span: Span | None = None


@dataclass
class GroupStmt:
    """``group <name> {prop}`` ... object statements ... ``end`` (one level).

    ``props`` uses the same keys as :class:`ObjectStmt` ``props``
    (group transform etc., flattened into children by desugar).
    ``body`` contains only :class:`ObjectStmt` nodes in v1.
    """

    name: str | None = None
    props: dict[str, Any] = field(default_factory=dict)
    body: list = field(default_factory=list)
    span: Span | None = None


@dataclass
class AnimStmt:
    """An animation verb applied to a target.

    ``kind`` is one of ``spin|bob|pulse|orbit|move|turn|grow``.
    ``target`` is an object/group name, ``'it'`` / ``'all'``, or
    ``None`` when omitted (parser/desugar resolves it to the most
    recent object).  ``props`` may hold ``axis`` (str | Vec3),
    ``speed`` (float), ``duration`` (float), ``fps`` (int),
    ``ease`` (str) and ``loop`` (str | int -- e.g. ``'once'``,
    ``'forever'``, ``'pingpong'`` or a repeat count).
    """

    kind: str = ""
    target: str | None = None
    props: dict[str, Any] = field(default_factory=dict)
    span: Span | None = None


@dataclass
class LoadStmt:
    """``load "<path>" [name] {prop}`` -- load an external model (OBJ in v1).

    ``props`` uses the same keys as :class:`ObjectStmt` ``props``.
    """

    path: str = ""
    name: str | None = None
    props: dict[str, Any] = field(default_factory=dict)
    span: Span | None = None


@dataclass
class RepeatStmt:
    """``repeat N <obj>`` | ``grid AxB <obj>`` | ``ring N <obj>`` (one object).

    ``a`` is the repeat count / grid width / ring count; ``b`` is the
    grid height, otherwise ``None``.  ``obj`` is the single
    :class:`ObjectStmt` being replicated (expanded by desugar).
    """

    mode: str = "repeat"  # 'repeat' | 'grid' | 'ring'
    a: int = 0
    b: int | None = None
    obj: ObjectStmt | None = None
    span: Span | None = None


@dataclass
class ControlsStmt:
    """``controls orbit|none {autorotate|min n|max n}``.

    ``props`` may hold ``autorotate`` (bool), ``min`` (float) and
    ``max`` (float).
    """

    kind: str = "orbit"  # 'orbit' | 'none'
    props: dict[str, Any] = field(default_factory=dict)
    span: Span | None = None


@dataclass
class OutputStmt:
    """``render [path] [size WxH]`` | ``export <format> [path]``.

    ``kind`` is ``'render'`` or ``'export'``; ``format`` is the export
    format (``'json'`` | ``'obj'`` | ``'html'``) or ``None`` for a
    render.  ``width`` / ``height`` are ``None`` when no ``size`` was
    given.
    """

    kind: str = "render"  # 'render' | 'export'
    path: str | None = None
    format: str | None = None
    width: int | None = None
    height: int | None = None
    span: Span | None = None


#: Any statement node that may appear in :attr:`Program.statements`.
Stmt = Union[
    SceneStmt,
    CameraStmt,
    LightStmt,
    ObjectStmt,
    GroupStmt,
    AnimStmt,
    LoadStmt,
    RepeatStmt,
    ControlsStmt,
    OutputStmt,
]
