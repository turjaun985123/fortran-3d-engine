#!/usr/bin/env python3
"""Forge3D desugar pass (seat B07) — stdlib only.

desugar(program, bag) -> Program (a NEW, flattened Program):

  1. GroupStmt expansion (P12): a group's transform props are composed
     into each child (at added, rotate added componentwise, scale
     multiplied), named children are prefixed ``group.name``, and the
     group statement itself disappears.
  2. RepeatStmt expansion (P16): ``repeat n`` lays n copies along X,
     ``grid a x b`` lays a*b copies in an XZ grid, ``ring n`` lays n
     copies on a circle in the XZ plane (each rotated about Y by its
     angle). Copies are auto-named ``name_1..name_n`` (unnamed bases:
     ``prim+i``). Expansion past 10,000 placements is E820.
  3. Defaults injection (MASTER-PLAN section 1.3, P03 sections 3/6/7):
     missing scene/camera/light statements are injected with the demo
     defaults (one W101 warning each), object props get ``at`` /
     ``rotate`` filled (a lone object gets the demo pose 20,35,0),
     unnamed objects are auto-named ``prim+index``, animation targets
     ``None``/``it``/``last`` resolve to the most recent object and
     animation props get their defaults, a missing output statement
     becomes ``render``, and an empty program gains a default cube.

Field access is duck-typed (attribute synonyms + a ``props`` dict) so
this pass works against the ast_nodes contract in MASTER-PLAN section 1
regardless of which synonym a node uses for a field.
"""

import copy
import inspect
import math

# ---------------------------------------------------------------------------
# AST / error types: prefer the real modules (B04/B02); fall back to local
# minimal dataclasses so this module is importable and smoke-testable alone.
# ---------------------------------------------------------------------------
try:  # flat layout: tools/f3dc on sys.path
    from ast_nodes import (AnimStmt, CameraStmt, ControlsStmt, GroupStmt,
                           LightStmt, LoadStmt, ObjectStmt, OutputStmt,
                           Program, RepeatStmt, SceneStmt)
except ImportError:  # package layout
    try:
        from .ast_nodes import (AnimStmt, CameraStmt, ControlsStmt, GroupStmt,
                                LightStmt, LoadStmt, ObjectStmt, OutputStmt,
                                Program, RepeatStmt, SceneStmt)
    except ImportError:
        from dataclasses import dataclass, field

        @dataclass
        class _Node:
            span: object = None
            props: dict = field(default_factory=dict)

        @dataclass
        class Program(_Node):
            statements: list = field(default_factory=list)

        @dataclass
        class SceneStmt(_Node):
            name: object = None
            width: int = 640
            height: int = 480
            bg: str = "#191923"

        @dataclass
        class CameraStmt(_Node):
            pos: tuple = (3, 2.5, 4)
            target: tuple = (0, 0, 0)
            up: tuple = (0, 1, 0)
            fov: float = 60
            near: float = 0.1
            far: float = 100

        @dataclass
        class LightStmt(_Node):
            kind: str = "directional"
            dir: tuple = (-0.5, -1, -0.7)
            intensity: float = 1.0

        @dataclass
        class ObjectStmt(_Node):
            prim: str = "cube"
            name: object = None
            color: object = None

        @dataclass
        class GroupStmt(_Node):
            name: object = None
            children: list = field(default_factory=list)

        @dataclass
        class AnimStmt(_Node):
            kind: str = "spin"
            target: object = None

        @dataclass
        class LoadStmt(_Node):
            path: str = ""
            name: object = None

        @dataclass
        class RepeatStmt(_Node):
            mode: str = "repeat"
            count: int = 1
            a: object = None
            b: object = None
            body: object = None

        @dataclass
        class ControlsStmt(_Node):
            kind: str = "orbit"

        @dataclass
        class OutputStmt(_Node):
            kind: str = "render"

try:
    from errors import Diagnostic
except ImportError:
    try:
        from .errors import Diagnostic
    except ImportError:
        Diagnostic = None

# ---------------------------------------------------------------------------
# Defaults (MASTER-PLAN section 1.3 / P03 sections 6-7 — the demo in main.f90)
# ---------------------------------------------------------------------------
MAX_PLACEMENTS = 10000
DEFAULT_SCENE = {"width": 640, "height": 480, "bg": "#191923"}
DEFAULT_CAMERA = {"pos": (3, 2.5, 4), "target": (0, 0, 0), "up": (0, 1, 0),
                  "fov": 60, "near": 0.1, "far": 100}
DEFAULT_LIGHT = {"kind": "directional", "dir": (-0.5, -1, -0.7),
                 "intensity": 1.0}
DEMO_POSE = (20, 35, 0)
ANIM_DEFAULTS = {"axis": "y", "speed": 90, "duration": 5, "fps": 30,
                 "ease": "linear"}

# Field-name synonyms, in priority order, for duck-typed access.
_SYNONYMS = {
    "statements": ("statements", "body", "stmts", "lines"),
    "children": ("children", "body", "statements", "members", "objects"),
    "props": ("props", "properties"),
    "name": ("name",),
    "prim": ("prim", "primitive", "kind", "type"),
    "kind": ("kind", "type", "mode", "action", "motion", "verb"),
    "mode": ("mode", "kind", "type", "pattern"),
    "target": ("target", "target_name"),
    "pos": ("pos", "position", "at"),
    "dir": ("dir", "direction"),
    "bg": ("bg", "background", "bg_color", "background_color"),
    "width": ("width", "w"),
    "height": ("height", "h"),
    "count": ("count", "n", "times", "repeat_count"),
    "body1": ("body", "obj", "object", "child", "stmt", "statement",
              "template", "object_stmt"),
}


def _get(obj, key, default=None):
    """Read field ``key`` (or a synonym / props entry) from a node."""
    if obj is None:
        return default
    for attr in _SYNONYMS.get(key, (key,)):
        if isinstance(obj, dict):
            if attr in obj and obj[attr] is not None:
                return obj[attr]
        elif hasattr(obj, attr):
            val = getattr(obj, attr)
            if val is not None:
                return val
    props = obj.get("props") if isinstance(obj, dict) else getattr(
        obj, "props", None)
    if isinstance(props, dict) and key in props and props[key] is not None:
        return props[key]
    return default


def _set(obj, key, value):
    """Write field ``key`` via its first existing synonym attribute."""
    for attr in _SYNONYMS.get(key, (key,)):
        if hasattr(obj, attr):
            try:
                setattr(obj, attr, value)
                return True
            except Exception:
                return False
    try:
        setattr(obj, _SYNONYMS.get(key, (key,))[0], value)
        return True
    except Exception:
        return False


def _props(stmt, create=True):
    """Return the node's mutable props dict (creating one if needed)."""
    props = getattr(stmt, "props", None)
    if isinstance(props, dict):
        return props
    if create:
        props = {}
        try:
            stmt.props = props
        except Exception:
            pass
        return props
    return {}


def _type_name(stmt):
    return type(stmt).__name__


def _is(stmt, cls, name):
    return isinstance(stmt, cls) or _type_name(stmt) == name


# ---------------------------------------------------------------------------
# Diagnostics: talk to whatever ErrorBag shape B02 shipped.
# ---------------------------------------------------------------------------
def _make_diagnostic(code, severity, message, span):
    if Diagnostic is None:
        return {"code": code, "severity": severity, "message": message,
                "span": span}
    kwargs = {"code": code, "severity": severity, "message": message,
              "span": span, "hint": None}
    try:
        params = inspect.signature(Diagnostic).parameters
        if not any(p.kind == inspect.Parameter.VAR_KEYWORD
                   for p in params.values()):
            kwargs = {k: v for k, v in kwargs.items() if k in params}
            for name in params:
                if name not in kwargs:
                    kwargs[name] = "" if name in ("why", "help") else None
        return Diagnostic(**kwargs)
    except Exception:
        return {"code": code, "severity": severity, "message": message,
                "span": span}


def _emit(bag, code, severity, message, span=None):
    if bag is None:
        return
    diag = _make_diagnostic(code, severity, message, span)
    # Preferred: a dedicated warn/error style method.
    names = ("add_warning", "warn", "warning") if severity == "warning" \
        else ("add_error", "error")
    for name in names:
        fn = getattr(bag, name, None)
        if callable(fn):
            for args in ((code, message, span), (code, message),
                         (message, span), (message,), (diag,)):
                try:
                    fn(*args)
                    return
                except TypeError:
                    continue
                except Exception:
                    return
    # Generic collectors: add/append/report taking a Diagnostic or fields.
    for name in ("add", "append", "report", "emit", "add_diagnostic"):
        fn = getattr(bag, name, None)
        if callable(fn):
            for args in ((diag,), (code, severity, message, span),
                         (code, message, span), (code, message)):
                try:
                    fn(*args)
                    return
                except TypeError:
                    continue
                except Exception:
                    return
    if isinstance(bag, list):
        bag.append(diag)


def _warn(bag, code, message, span=None):
    _emit(bag, code, "warning", message, span)


# ---------------------------------------------------------------------------
# Node construction tolerant of the real constructor signatures.
# ---------------------------------------------------------------------------
def _make(cls, span=None, **fields):
    """Construct ``cls`` passing only the kwargs its signature accepts,
    mapping canonical field names onto synonym parameter names."""
    try:
        params = inspect.signature(cls).parameters
        has_var_kw = any(p.kind == inspect.Parameter.VAR_KEYWORD
                         for p in params.values())
    except (TypeError, ValueError):
        params, has_var_kw = {}, True
    kwargs = {}
    used = set()
    for key, value in fields.items():
        placed = False
        for cand in _SYNONYMS.get(key, (key,)):
            if cand not in used and (has_var_kw or cand in params):
                kwargs[cand] = value
                used.add(cand)
                placed = True
                break
        if not placed and key == "props" and isinstance(value, dict):
            # Merge unconsumed scalar fields into props for prop-driven nodes.
            pass
    if span is not None and ("span" in params or has_var_kw) \
            and "span" not in kwargs:
        kwargs["span"] = span
    for name, param in params.items():
        if name not in kwargs and param.default is inspect.Parameter.empty \
                and param.kind not in (inspect.Parameter.VAR_POSITIONAL,
                                       inspect.Parameter.VAR_KEYWORD):
            kwargs[name] = span if name == "span" else None
    try:
        node = cls(**kwargs)
    except Exception:
        node = cls.__new__(cls)
    # Best-effort: expose canonical values as attributes too. A props
    # dict is only merged when the node type actually has a props field
    # (SceneStmt/CameraStmt/LightStmt in ast_nodes do not).
    for key, value in fields.items():
        if key == "props":
            if isinstance(getattr(node, "props", None), dict):
                getattr(node, "props").update(value)
            elif "props" in params:
                try:
                    node.props = dict(value)
                except Exception:
                    pass
        elif not hasattr(node, key):
            try:
                setattr(node, key, value)
            except Exception:
                pass
    return node


# ---------------------------------------------------------------------------
# Small vec helpers (values stay plain tuples).
# ---------------------------------------------------------------------------
def _vec3(value, default=(0, 0, 0)):
    if value is None:
        return tuple(default)
    if isinstance(value, (int, float)):
        return (value, value, value)
    try:
        seq = list(value)
    except TypeError:
        return tuple(default)
    out = [seq[i] if i < len(seq) else default[i] for i in range(3)]
    return tuple(out)


def _add(a, b):
    return tuple(x + y for x, y in zip(_vec3(a), _vec3(b)))


def _scale_mul(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a * b
    av = (a, a, a) if isinstance(a, (int, float)) else _vec3(a, (1, 1, 1))
    bv = (b, b, b) if isinstance(b, (int, float)) else _vec3(b, (1, 1, 1))
    return tuple(x * y for x, y in zip(av, bv))


# ---------------------------------------------------------------------------
# Group expansion (P12 section 5/9.2: compile-time flattening, simple
# composition as specified for this pass).
# ---------------------------------------------------------------------------
def _apply_group(child, g_name, g_props):
    props = _props(child)
    if "at" in g_props or "pos" in g_props:
        g_at = g_props.get("at", g_props.get("pos"))
        base = props.get("at", props.get("pos", (0, 0, 0)))
        props["at"] = _add(g_at, base)
    if "rotate" in g_props or "rot" in g_props:
        g_rot = g_props.get("rotate", g_props.get("rot"))
        base = props.get("rotate", props.get("rot", (0, 0, 0)))
        props["rotate"] = _add(g_rot, base)
    if "scale" in g_props:
        if "scale" in props:
            props["scale"] = _scale_mul(g_props["scale"], props["scale"])
        else:
            props["scale"] = g_props["scale"]
    name = _get(child, "name")
    if name and g_name:
        _set(child, "name", "%s.%s" % (g_name, name))


def _expand_group(stmt):
    g_name = _get(stmt, "name")
    g_props = _props(stmt, create=False)
    children = _get(stmt, "children") or []
    if not isinstance(children, (list, tuple)):
        children = [children]
    out = []
    for child in children:
        if _is(child, GroupStmt, "GroupStmt"):  # defensive: flatten deeper
            out.extend(_expand_group(child))
            continue
        if _is(child, RepeatStmt, "RepeatStmt"):
            child = copy.deepcopy(child)
            body = _get(child, "body1")
            templates = body if isinstance(body, (list, tuple)) else [body]
            for tpl in templates:
                if tpl is not None:
                    _apply_group(tpl, g_name, g_props)
            out.append(child)
            continue
        _apply_group(child, g_name, g_props)
        out.append(child)
    return out


# ---------------------------------------------------------------------------
# Repeat / grid / ring expansion (P16).
# ---------------------------------------------------------------------------
def _repeat_mode(stmt):
    mode = _get(stmt, "mode")
    if isinstance(mode, str) and mode.lower() in ("repeat", "grid", "ring"):
        return mode.lower()
    props = _props(stmt, create=False)
    if isinstance(props.get("mode"), str):
        return props["mode"].lower()
    if _get(stmt, "a") is not None or _get(stmt, "b") is not None \
            or isinstance(_get(stmt, "count"), (list, tuple)):
        return "grid"
    return "repeat"


def _grid_dims(stmt):
    # ast_nodes contract: a = grid width, b = grid height (None -> 1).
    a = getattr(stmt, "a", None) or _get(stmt, "a", None)
    b = getattr(stmt, "b", None) or _get(stmt, "b", None)
    if not a:
        a = _get(stmt, "nx", None) or _get(stmt, "cols", None) \
            or _get(stmt, "x", None)
    if not b:
        b = _get(stmt, "nz", None) or _get(stmt, "rows", None) \
            or _get(stmt, "z", None)
    count = _get(stmt, "count")
    if (not a or not b) and isinstance(count, (list, tuple)) \
            and len(count) >= 2:
        a, b = count[0], count[1]
    props = _props(stmt, create=False)
    if not a:
        a = props.get("a", props.get("nx", 1))
    if not b:
        b = props.get("b", props.get("nz", 1))
    return int(a), int(b)


def _expand_repeat(stmt, bag, budget):
    """Return (statements, placements_used). ``budget`` is the number of
    placements still allowed before the 10,000 scene cap (E820)."""
    mode = _repeat_mode(stmt)
    body = _get(stmt, "body1")
    templates = list(body) if isinstance(body, (list, tuple)) else [body]
    templates = [t for t in templates if t is not None]
    if not templates:
        return [], 0
    # A grouped template flattens first, then is repeated.
    flat = []
    for tpl in templates:
        if _is(tpl, GroupStmt, "GroupStmt"):
            flat.extend(_expand_group(copy.deepcopy(tpl)))
        else:
            flat.append(tpl)
    templates = flat

    # Repeat-level props: RepeatStmt itself carries none in ast_nodes;
    # spacing/radius/size live on the replicated object's props. A props
    # dict on the repeat statement, if a producer supplies one, wins.
    rprops = {}
    for tpl in templates:
        rprops.update(_props(tpl, create=False))
    rprops.update(_props(stmt, create=False))

    if mode == "grid":
        ga, gb = _grid_dims(stmt)
        total = ga * gb
    else:
        # ast_nodes contract: a = repeat count / ring count.
        total = int(getattr(stmt, "a", None) or _get(stmt, "count", 1)
                    or 1)
    placements = total * len(templates)
    span = getattr(stmt, "span", None)
    if placements > budget:
        _emit(bag, "E820", "error",
              "expansion of %d placements would exceed the %d-placement "
              "limit" % (placements, MAX_PLACEMENTS), span)
        # Keep one unexpanded copy of each template; the error aborts the
        # build downstream, and the scene stays bounded meanwhile.
        return [copy.deepcopy(t) for t in templates], len(templates)

    # Spacing: explicit prop wins; else 1.5x the template size (default 2).
    spacing = rprops.get("spacing")
    if spacing is None:
        size = None
        for tpl in templates:
            size = _props(tpl, create=False).get("size", size)
        if isinstance(size, (list, tuple)):
            size = size[0] if size else 2
        spacing = (size if size is not None else 2) * 1.5
    if isinstance(spacing, (list, tuple)):
        spacing_x = spacing[0]
        spacing_z = spacing[2] if len(spacing) > 2 else spacing[-1]
    else:
        spacing_x = spacing_z = spacing
    radius = rprops.get("radius", 5.0)

    out = []
    index = 0
    for tpl in templates:
        base_name = _get(tpl, "name")
        prim = _get(tpl, "prim", "object")
        for i in range(total):
            index += 1
            clone = copy.deepcopy(tpl)
            props = _props(clone)
            base_at = _vec3(props.get("at", props.get("pos", (0, 0, 0))))
            if mode == "repeat":
                offset = ((i - (total - 1) / 2.0) * spacing_x, 0, 0)
                rot_y = None
            elif mode == "grid":
                col, row = i % ga, i // ga
                offset = ((col - (ga - 1) / 2.0) * spacing_x, 0,
                          (row - (gb - 1) / 2.0) * spacing_z)
                rot_y = None
            else:  # ring: XZ circle, placement 0 at +Z (P16 section 4.2)
                angle = 360.0 * i / total if total else 0.0
                theta = math.radians(angle)
                offset = (radius * math.sin(theta), 0,
                          radius * math.cos(theta))
                rot_y = angle
            props["at"] = _add(base_at, offset)
            if rot_y is not None:
                rot = _vec3(props.get("rotate", props.get("rot", (0, 0, 0))))
                props["rotate"] = (rot[0], rot[1] + rot_y, rot[2])
            if base_name:
                _set(clone, "name", "%s_%d" % (base_name, i + 1))
            else:
                _set(clone, "name", "%s%d" % (prim, i + 1))
            out.append(clone)
    return out, placements


# ---------------------------------------------------------------------------
# The pass.
# ---------------------------------------------------------------------------
def desugar(program, bag=None):
    """Return a new, flattened Program with defaults injected."""
    if program is None:
        program = _make(Program, statements=[])
    try:
        work = copy.deepcopy(program)
    except Exception:
        work = program
    stmts_in = _get(work, "statements") or []
    stmts = list(stmts_in)
    span0 = getattr(work, "span", None) or (
        getattr(stmts[0], "span", None) if stmts else None)
    was_empty = not stmts

    # 1-2. Expand groups and repeats, in source order.
    flat = []
    budget = MAX_PLACEMENTS
    for stmt in stmts:
        if _is(stmt, GroupStmt, "GroupStmt"):
            flat.extend(_expand_group(stmt))
        elif _is(stmt, RepeatStmt, "RepeatStmt"):
            expanded, used = _expand_repeat(stmt, bag, budget)
            budget -= used
            flat.extend(expanded)
        else:
            flat.append(stmt)
    stmts = flat

    # Empty program: the render path still shows the demo cube (MASTER 1.3).
    objects = [s for s in stmts if _is(s, ObjectStmt, "ObjectStmt")]
    if was_empty and not objects:
        cube = _make(ObjectStmt, span=span0, prim="cube", name=None,
                     props={"size": 2})
        stmts.insert(0, cube)
        objects = [cube]
        _warn(bag, "W101", "empty program: injecting a default cube",
              span0)

    # 3a. Object defaults + auto-names.
    single = len(objects) == 1
    used_names = set()
    for s in stmts:
        n = _get(s, "name")
        if n:
            used_names.add(n)
    counters = {}
    for obj in objects:
        props = _props(obj)
        if "at" not in props and "pos" not in props:
            # Honour an at/pos held as a plain attribute instead of props.
            if _get(obj, "pos") is None:
                props["at"] = (0, 0, 0)
        if "rotate" not in props and "rot" not in props \
                and getattr(obj, "rotate", None) is None:
            props["rotate"] = DEMO_POSE if single else (0, 0, 0)
        if not _get(obj, "name"):
            prim = _get(obj, "prim", "object")
            counters[prim] = counters.get(prim, 0) + 1
            candidate = "%s%d" % (prim, counters[prim])
            while candidate in used_names:
                counters[prim] += 1
                candidate = "%s%d" % (prim, counters[prim])
            used_names.add(candidate)
            _set(obj, "name", candidate)

    # 3b. Animation target resolution + defaults.
    last_object = None
    for stmt in stmts:
        if _is(stmt, ObjectStmt, "ObjectStmt") or \
                _is(stmt, LoadStmt, "LoadStmt"):
            name = _get(stmt, "name")
            if name:
                last_object = name
            continue
        if not _is(stmt, AnimStmt, "AnimStmt"):
            continue
        props = _props(stmt)
        target = _get(stmt, "target")
        if target is None and "target" in props:
            target = props["target"]
        if target is None or (isinstance(target, str)
                              and target.lower() in ("it", "last")):
            if last_object is not None:
                _set(stmt, "target", last_object)
        for key, value in ANIM_DEFAULTS.items():
            if key not in props and getattr(stmt, key, None) is None:
                props[key] = value
        kind = _get(stmt, "kind")
        if isinstance(kind, str) and kind.lower() == "spin" \
                and "loop" not in props \
                and getattr(stmt, "loop", None) is None:
            props["loop"] = "forever"

    # 3c. Inject missing scene / camera / light statements.
    def _has(cls, name):
        return any(_is(s, cls, name) for s in stmts)

    injected = []
    if not _has(SceneStmt, "SceneStmt"):
        injected.append(_make(
            SceneStmt, span=span0, name=None,
            width=DEFAULT_SCENE["width"], height=DEFAULT_SCENE["height"],
            bg=DEFAULT_SCENE["bg"],
            props={"size": (640, 480), "bg": "#191923"}))
        _warn(bag, "W101",
              "no scene statement: injecting default scene "
              "640x480 bg #191923", span0)
    if not _has(CameraStmt, "CameraStmt"):
        injected.append(_make(
            CameraStmt, span=span0, pos=DEFAULT_CAMERA["pos"],
            target=DEFAULT_CAMERA["target"], up=DEFAULT_CAMERA["up"],
            fov=DEFAULT_CAMERA["fov"], near=DEFAULT_CAMERA["near"],
            far=DEFAULT_CAMERA["far"], props=dict(DEFAULT_CAMERA)))
        _warn(bag, "W101",
              "no camera statement: injecting default camera at "
              "(3, 2.5, 4) looking at (0, 0, 0), fov 60", span0)
    if not _has(LightStmt, "LightStmt"):
        injected.append(_make(
            LightStmt, span=span0, kind=DEFAULT_LIGHT["kind"],
            dir=DEFAULT_LIGHT["dir"], intensity=DEFAULT_LIGHT["intensity"],
            props=dict(DEFAULT_LIGHT)))
        _warn(bag, "W101",
              "no light statement: injecting default directional light "
              "dir (-0.5, -1, -0.7) intensity 1.0", span0)
    stmts = injected + stmts

    # 3d. Missing output defaults to a plain render.
    if not _has(OutputStmt, "OutputStmt"):
        stmts.append(_make(OutputStmt, span=span0, kind="render",
                           props={"kind": "render"}))

    # Rebuild a new Program, carrying over any other original fields.
    fields = {}
    try:
        params = inspect.signature(Program).parameters
    except (TypeError, ValueError):
        params = {}
    for name in params:
        if name in ("statements", "body", "stmts", "lines", "span"):
            continue
        if hasattr(work, name):
            fields[name] = getattr(work, name)
    fields["statements"] = stmts
    return _make(Program, span=span0, **fields)
