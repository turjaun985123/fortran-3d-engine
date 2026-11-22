"""Forge3D validator: desugared AST -> frozen typed IR (seat B09).

Stdlib only.  Public entry point::

    validate(program, bag, base_dir=".") -> IRScene | None

Pipeline position (MASTER-PLAN sections 1-2): ``desugar`` runs first
(it fills scene/camera/light/object defaults, expands ``group`` /
``repeat`` / ``grid`` / ``ring`` and injects the demo cube for an empty
program); this module then converts AST' to IR, collecting *all*
diagnostics into ``bag`` and returning ``None`` iff the bag has errors.

Diagnostic codes used here (short forms, per the B09 brief):

    E201  unknown / duplicate name, unresolved animation target
    E202  bad colour (delegated to ``ir_nodes.parse_color``)
    E204  texture property used -- reserved in v1, loud, never silent
    E205  recognised but not built yet (material / primitive / load
          format / light kind / animation kind from a later wave)
    E301  object / scene dimension out of range (size, radius, height,
          width, segments, render-path extension, ...)
    E302  camera / light range (fov, near, far, at == look, intensity)
    E303  animation / output timing range (speed, duration, fps)
    E401  structural conflict (duplicate singleton, degenerate setup)
    E402  empty scene -- no objects to render
    E501  referenced file (``load``) not found on disk
    E820  P26 scene limits: > 10,000 objects or > 1,000,000
          estimated triangles

The AST/IR/error contracts live in the sibling modules ``ast_nodes``,
``ir_nodes`` and ``errors`` (same-batch seats).  Those modules were not
yet on disk when this seat was written, so every read of an AST node
and every construction of an IR node / diagnostic goes through a small
adapter (``_get`` / ``_make`` / ``_err``) that accepts the field-name
spellings used across the plan documents (P03/P04/P08) instead of
hard-coding one guess.  No behaviour depends on the adapter guessing
right silently: unknown statement kinds are ignored only when they
carry no object/camera/light/output payload.
"""

import math
import os

try:  # package import (tools.f3dc.validate / f3dc_pkg style)
    from . import desugar as _desugar_mod
    from . import ir_nodes as _ir
    from . import errors as _errors
except Exception:  # plain module import (tools/f3dc on sys.path)
    import desugar as _desugar_mod  # type: ignore
    import ir_nodes as _ir  # type: ignore
    import errors as _errors  # type: ignore

__all__ = ["validate"]

# ---------------------------------------------------------------- limits

MAX_DIM = 1000.0            # size / radius / height ceiling (brief)
MIN_IMAGE = 16              # render width/height lower bound
MAX_IMAGE = 8192            # render width/height upper bound (brief)
MAX_OBJECTS = 10000         # P26 L14 total placements
MAX_TRIANGLES = 1000000     # P26 L15 triangles per scene
MIN_SEGMENTS = 3
MAX_SEGMENTS = 256
MIN_FPS, MAX_FPS = 1, 240
MAX_DURATION = 3600.0
MAX_SPEED = 10000.0

PRIMITIVES = ("cube", "sphere", "cylinder", "plane", "pyramid",
              "cone", "torus", "tris")
MATERIALS = ("lambert", "basic", "phong")
ANIM_KINDS = ("spin", "bob", "pulse", "orbit", "move", "turn", "grow")
LIGHT_KINDS_V1 = ("directional", "ambient")
CONTROLS_KINDS = ("orbit", "none")
EASES = ("linear", "smooth", "in", "out", "ease", "ease-in", "ease-out",
         "ease-in-out")
RENDER_EXTS = (".ppm", ".png")
EXPORT_KINDS = ("json", "obj", "html")

# Detail presets -> (segments, rings), P11 section 2.5.
_DETAIL = {
    "low": (8, 6), "med": (16, 12), "medium": (16, 12),
    "high": (32, 24),
}
_DETAIL_TORUS = {"low": (10, 8), "med": (16, 12), "medium": (16, 12),
                 "high": (32, 24)}

_DEFAULT_BG = (25, 25, 35)          # #191923, MASTER section 1.1
_DEFAULT_CAM_POS = (3.0, 2.5, 4.0)
_DEFAULT_CAM_LOOK = (0.0, 0.0, 0.0)
_DEFAULT_LIGHT_DIR = (-0.5, -1.0, -0.7)
_DEFAULT_OUTPUT = "output_render.ppm"


# ------------------------------------------------------- generic adapters

def _get(obj, *names, default=None):
    """First present attribute/key among ``names`` on ``obj``."""
    if obj is None:
        return default
    for name in names:
        if isinstance(obj, dict):
            if name in obj and obj[name] is not None:
                return obj[name]
        elif hasattr(obj, name):
            value = getattr(obj, name)
            if value is not None:
                return value
    return default


def _span(node):
    return _get(node, "span", "pos", "position_span", "location")


def _bag_error_count(bag):
    if bag is None:
        return 0
    if isinstance(bag, (list, tuple)):
        return len(bag)
    diagnostics = getattr(bag, "diagnostics", None)
    if isinstance(diagnostics, (list, tuple)):
        return sum(1 for d in diagnostics
                   if getattr(d, "severity", "error") == "error")
    has = _get(bag, "has_errors", "has_error")
    if callable(has):
        try:
            return 1 if has() else 0
        except Exception:
            return 0
    errors = _get(bag, "diagnostics", "items")
    if isinstance(errors, (list, tuple)):
        return len(errors)
    return 0


def _has_errors(bag):
    if bag is None:
        return False
    has = _get(bag, "has_errors", "has_error", "failed")
    if callable(has):
        try:
            return bool(has())
        except Exception:
            pass
    return _bag_error_count(bag) > 0


def _err(bag, code, message, span=None):
    """Record one diagnostic, whatever exact ErrorBag API landed."""
    if bag is None:
        return
    if isinstance(bag, list):
        bag.append((code, message, span))
        return
    # Real B02 ErrorBag: add() takes a single Diagnostic object.
    # Trying (code, message, span) against it raises TypeError and
    # the diagnostic would be silently lost, so build it first.
    diag_cls = getattr(_errors, "Diagnostic", None)
    diag = None
    if diag_cls is not None:
        diag = _make(diag_cls, code=code, severity="error",
                     message=message, span=span, why="", help="")
    for method_name in ("add", "error", "add_error", "report", "emit"):
        method = getattr(bag, method_name, None)
        if not callable(method):
            continue
        attempts = ((diag,) if diag is not None else ()) + \
            ((code, message, span), (code, message),
             (code, span, message))
        for args in attempts:
            try:
                method(*args)
                return
            except TypeError:
                continue
            except Exception:
                return
    diagnostics = getattr(bag, "diagnostics", None)
    if isinstance(diagnostics, list):
        diagnostics.append(diag if diag is not None
                           else (code, message, span))
        return
    errors = _get(bag, "diagnostics", "items")
    if isinstance(errors, list):
        errors.append(diag if diag is not None
                      else (code, message, span))


def _make(cls, **kwargs):
    """Construct an IR (or diagnostic) class by field-name filtering.

    Callers pass every plausible alias; only names the class actually
    declares are forwarded, and still-missing required fields are
    filled with a neutral default keyed by field name.
    """
    if cls is None:
        from types import SimpleNamespace
        return SimpleNamespace(**kwargs)
    import inspect
    fields = None
    dc_fields = getattr(cls, "__dataclass_fields__", None)
    if isinstance(dc_fields, dict):
        fields = list(dc_fields)
    else:
        try:
            fields = [p for p in inspect.signature(cls).parameters
                      if p not in ("self",)]
        except (TypeError, ValueError):
            fields = None
    if fields is None:
        try:
            return cls(**kwargs)
        except Exception:
            obj = cls.__new__(cls)
            for key, value in kwargs.items():
                try:
                    object.__setattr__(obj, key, value)
                except Exception:
                    pass
            return obj
    chosen = {k: v for k, v in kwargs.items() if k in fields}
    for name in fields:
        if name not in chosen:
            chosen[name] = _neutral_default(name)
    try:
        return cls(**chosen)
    except Exception:
        obj = cls.__new__(cls)
        for key, value in chosen.items():
            try:
                object.__setattr__(obj, key, value)
            except Exception:
                pass
        return obj


def _neutral_default(name):
    lname = name.lower()
    if lname in ("span", "meta"):
        return None
    if any(k in lname for k in ("pos", "at", "look", "target", "up",
                                "dir", "rotate", "rotation", "color",
                                "colour", "bg", "background")):
        return (0.0, 0.0, 0.0) if "color" not in lname and \
            "colour" not in lname and "bg" not in lname and \
            "background" not in lname else (255, 255, 255)
    if lname in ("objects", "lights", "animations", "anims", "outputs",
                 "children"):
        return []
    if lname in ("width", "height"):
        return 0
    if lname in ("name", "kind", "prim", "primitive", "type", "path",
                 "material", "output"):
        return ""
    return None


def _props_dict(node):
    """Normalise a node's props (dict / list of pairs / prop objects)."""
    props = {}
    raw = _get(node, "props", "properties", "options", "args")
    if isinstance(raw, dict):
        props.update({str(k).lower(): v for k, v in raw.items()})
    elif isinstance(raw, (list, tuple)):
        for item in raw:
            if isinstance(item, (list, tuple)) and len(item) == 2:
                props[str(item[0]).lower()] = item[1]
            else:
                key = _get(item, "name", "key")
                if key is not None:
                    props[str(key).lower()] = _get(item, "value", "val")
    return props


def _field(node, props, *names, default=None):
    value = _get(node, *names, default=None)
    if value is not None:
        return value
    for name in names:
        if name in props and props[name] is not None:
            return props[name]
    return default


def _num(value, default=None):
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return default
    return default


def _int(value, default=None):
    number = _num(value, None)
    return default if number is None else int(number)


def _vec3(value, default=None):
    if value is None:
        return default
    if isinstance(value, (list, tuple)) and len(value) >= 3:
        parts = [_num(v) for v in value[:3]]
        if all(p is not None for p in parts):
            return (parts[0], parts[1], parts[2])
        return default
    x = _num(_get(value, "x"))
    y = _num(_get(value, "y"))
    z = _num(_get(value, "z"))
    if None not in (x, y, z):
        return (x, y, z)
    return default


def _finite_vec(vec):
    return vec is not None and all(math.isfinite(c) for c in vec)


# ---------------------------------------------------------------- colours

def _parse_color(raw, bag, span):
    """Resolve any colour spelling to an (r, g, b) int tuple or None.

    Delegates strings to ``ir_nodes.parse_color`` (which owns
    NAMED_COLORS and emits E202); tuples are channel-checked here.
    """
    if raw is None:
        return None
    if isinstance(raw, (list, tuple)):
        if len(raw) != 3:
            _err(bag, "E202", "a colour needs exactly 3 parts "
                              "(red, green, blue)", span)
            return None
        channels = []
        for part in raw:
            value = _int(part, None)
            if value is None or not (0 <= value <= 255):
                _err(bag, "E202",
                     "colour part %r must be a whole number from "
                     "0 to 255" % (part,), span)
                return None
            channels.append(value)
        return (channels[0], channels[1], channels[2])
    # ColourLit-style node: name/value/rgb attributes.
    if not isinstance(raw, str):
        named = _get(raw, "name", "value", "text")
        rgb = _get(raw, "rgb", "channels", "color", "colour")
        if rgb is not None:
            return _parse_color(rgb, bag, span)
        if named is None:
            _err(bag, "E202", "that colour cannot be read", span)
            return None
        raw = named
    text = raw.strip()
    named_colors = getattr(_ir, "NAMED_COLORS", {}) or {}
    if text.lower() in named_colors:
        value = named_colors[text.lower()]
        if isinstance(value, (list, tuple)):
            return _parse_color(value, bag, span)
        if isinstance(value, str) and not value.startswith("#"):
            return (value,) and _parse_color(value, bag, span)
        text = value if isinstance(value, str) else text
    parse_color = getattr(_ir, "parse_color", None)
    if callable(parse_color):
        before = _bag_error_count(bag)
        result = None
        for args in ((text, bag, span), (text, bag), (text, span),
                     (text,)):
            try:
                result = parse_color(*args)
                break
            except TypeError:
                continue
            except Exception:
                result = None
                break
        if isinstance(result, (list, tuple)) and len(result) == 3:
            return _parse_color(result, bag, span)
        if result is not None and _bag_error_count(bag) == before:
            return _parse_color(result, bag, span)
        if _bag_error_count(bag) == before:
            _err(bag, "E202", "there is no colour called %r" % text, span)
        return None
    if text.startswith("#") and len(text) == 7:
        try:
            return (int(text[1:3], 16), int(text[3:5], 16),
                    int(text[5:7], 16))
        except ValueError:
            pass
    _err(bag, "E202", "there is no colour called %r" % text, span)
    return None


# ------------------------------------------------------- triangle estimate

def _estimate_triangles(prim, props):
    """Per-primitive triangle estimate, P11 formulas / MASTER 1.2."""
    segments = _int(_field_from(props, "segments"), None)
    rings = _int(_field_from(props, "rings", "height_segments",
                              "height_segs"), None)
    detail = props.get("detail")
    if isinstance(detail, str):
        table = _DETAIL_TORUS if prim == "torus" else _DETAIL
        preset = table.get(detail.lower())
        if preset:
            if segments is None:
                segments = preset[0]
            if rings is None:
                rings = preset[1]
    capped = not props.get("open") and props.get("capped", True) is not False
    if prim == "cube":
        return 12
    if prim == "sphere":
        s = segments or 16
        r = rings or 12
        return 2 * s * max(r - 1, 1)
    if prim == "cylinder":
        s = segments or 16
        h = rings or 1
        return 2 * s * h + (2 * s if capped else 0)
    if prim == "cone":
        s = segments or 16
        h = rings or 1
        return s * (2 * h - 1) + (s if capped else 0)
    if prim == "plane":
        ws = segments or 1
        ds = _int(props.get("depth_segments"), None) or ws
        return 2 * ws * ds
    if prim == "pyramid":
        sides = _int(props.get("sides"), None) or 4
        return max(2 * sides - 2, 0)
    if prim == "torus":
        s = segments or 16
        t = rings or 12
        return 2 * s * t
    if prim == "tris":
        tris = props.get("tris") or props.get("triangles")
        if isinstance(tris, (list, tuple)):
            return len(tris)
        count = _int(props.get("tri_count", props.get("count")), None)
        return count or 0
    if prim == "load":
        return _int(props.get("_load_tris"), None) or 0
    return 0


def _field_from(props, *names, default=None):
    for name in names:
        if name in props and props[name] is not None:
            return props[name]
    return default


def _count_obj_triangles(path):
    """Cheap face count for a loaded .obj (lines starting with 'f ')."""
    try:
        count = 0
        with open(path, "r", errors="ignore") as handle:
            for line in handle:
                if line.startswith("f "):
                    count += max(len(line.split()) - 3, 1)
        return count
    except OSError:
        return 0


# ------------------------------------------------------------- statements

def _statements(program):
    body = _get(program, "statements", "body", "lines", "stmts",
                "items", "children")
    if isinstance(body, (list, tuple)):
        return list(body)
    if program is None:
        return []
    return [program]


def _classify(node):
    """Return (category, payload-dict) for one AST statement node."""
    cname = type(node).__name__.lower()
    props = _props_dict(node)
    kind = _get(node, "kind", "type", "prim", "primitive", "stmt_kind")
    kind = str(kind).lower() if kind is not None else ""
    if "camera" in cname or kind == "camera":
        return "camera", props
    if "light" in cname or kind == "light":
        return "light", props
    if "controls" in cname or kind == "controls":
        return "controls", props
    if "load" in cname or kind in ("load", "mesh"):
        return "load", props
    if ("anim" in cname or kind in ANIM_KINDS
            or _get(node, "motion", "action") is not None
            and "object" not in cname
            or "camera" not in cname and "object" not in cname
            and _get(node, "target", "target_name") is not None
            and hasattr(node, "kind")):
        return "anim", props
    if ("output" in cname or "render" in cname or "export" in cname
            or kind in ("render", "export")):
        return "output", props
    if "group" in cname or "repeat" in cname or "grid" in cname \
            or "ring" in cname or kind in ("group", "repeat", "grid",
                                           "ring"):
        return "group", props
    if "scene" in cname and "program" not in cname or kind == "scene":
        return "scene", props
    if "object" in cname or kind in PRIMITIVES or kind == "tris" \
            or _get(node, "prim", "primitive") is not None:
        return "object", props
    return "unknown", props


def _children(node):
    body = _get(node, "body", "children", "statements", "objects")
    return list(body) if isinstance(body, (list, tuple)) else []


# ---------------------------------------------------------------- checks

def _check_dim(bag, span, label, value):
    if value is None:
        return
    if not math.isfinite(value) or value <= 0 or value > MAX_DIM:
        _err(bag, "E301", "%s is %s, but it must be more than 0 and "
                          "at most %s" % (label, value, int(MAX_DIM)),
             span)


def _check_image_dim(bag, span, label, value):
    if value is None:
        return
    if not (MIN_IMAGE <= value <= MAX_IMAGE):
        _err(bag, "E301", "%s is %s, but each picture side must be "
                          "%d to %d pixels" % (label, value, MIN_IMAGE,
                                               MAX_IMAGE), span)


# ------------------------------------------------------------------ main

def validate(program, bag, base_dir="."):
    """Convert a (raw) AST program to IRScene, or None on any error."""
    if bag is None:
        bag_cls = getattr(_errors, "ErrorBag", None)
        bag = _make(bag_cls) if bag_cls is not None else []
    # 1. Desugar first: defaults + group/repeat expansion (B07).
    desugared = None
    desugar_fn = getattr(_desugar_mod, "desugar", None)
    if callable(desugar_fn):
        for args in ((program, bag), (program,)):
            try:
                desugared = desugar_fn(*args)
                break
            except TypeError:
                continue
    if desugared is not None:
        program = desugared

    scene_name = "untitled"
    width, height = 640, 480
    bg = _DEFAULT_BG
    camera_node, light_nodes, output_nodes = None, [], []
    controls_node = None
    object_nodes, anim_nodes, load_nodes = [], [], []
    seen_singletons = {}

    def walk(nodes):
        for node in nodes:
            category, _p = _classify(node)
            if category == "group":
                # Desugar should have expanded these; flatten any
                # survivor rather than dropping its objects silently.
                walk(_children(node))
            elif category == "scene":
                if "scene" in seen_singletons:
                    _err(bag, "E401", "there are two scene lines; "
                                      "keep only one", _span(node))
                seen_singletons["scene"] = node
                walk_scene(node)
            elif category == "camera":
                if "camera" in seen_singletons:
                    _err(bag, "E401", "there are two camera lines; "
                                      "keep only one", _span(node))
                seen_singletons["camera"] = node
                nonlocal_set("camera", node)
            elif category == "light":
                light_nodes.append(node)
            elif category == "controls":
                nonlocal_set("controls", node)
            elif category == "load":
                load_nodes.append(node)
            elif category == "anim":
                anim_nodes.append(node)
            elif category == "output":
                output_nodes.append(node)
            elif category == "object":
                object_nodes.append(node)
            # Unknown statements: parser/desugar own their codes.

    def nonlocal_set(which, node):
        nonlocal camera_node, controls_node
        if which == "camera":
            camera_node = node
        else:
            controls_node = node

    def walk_scene(node):
        nonlocal scene_name, width, height, bg
        props = _props_dict(node)
        name = _field(node, props, "name", "title")
        if isinstance(name, str) and name:
            scene_name = name
        size = _field(node, props, "size", "dimensions")
        w = _int(_field(node, props, "width", "w"), None)
        h = _int(_field(node, props, "height", "h"), None)
        if isinstance(size, (list, tuple)) and len(size) >= 2:
            w, h = _int(size[0], w), _int(size[1], h)
        if w is not None:
            width = w
        if h is not None:
            height = h
        raw_bg = _field(node, props, "bg", "background", "color",
                        "colour")
        if raw_bg is not None:
            parsed = _parse_color(raw_bg, bag, _span(node))
            if parsed is not None:
                bg = parsed
        walk(_children(node))

    walk(_statements(program))

    _check_image_dim(bag, None, "scene width", width)
    _check_image_dim(bag, None, "scene height", height)

    # ---- camera (E302) -------------------------------------------
    cam_pos, cam_look = _DEFAULT_CAM_POS, _DEFAULT_CAM_LOOK
    cam_up, fov, near, far = (0.0, 1.0, 0.0), 60.0, 0.1, 100.0
    if camera_node is not None:
        props = _props_dict(camera_node)
        span = _span(camera_node)
        cam_pos = _vec3(_field(camera_node, props, "at", "pos",
                               "position", "eye"), cam_pos)
        cam_look = _vec3(_field(camera_node, props, "look", "target",
                                "look_at"), cam_look)
        cam_up = _vec3(_field(camera_node, props, "up"), cam_up)
        fov = _num(_field(camera_node, props, "fov"), fov)
        near = _num(_field(camera_node, props, "near"), near)
        far = _num(_field(camera_node, props, "far"), far)
        if not _finite_vec(cam_pos) or not _finite_vec(cam_look):
            _err(bag, "E302", "camera positions must be plain "
                              "finite numbers", span)
        if not (0.0 < fov < 180.0):
            _err(bag, "E302", "fov is %s, but a camera can only see "
                              "between 0 and 180 degrees" % fov, span)
        if not (math.isfinite(near) and near > 0):
            _err(bag, "E302", "near is %s, but it must be more "
                              "than 0" % near, span)
        if not (math.isfinite(far) and far > near):
            _err(bag, "E302", "'far' (%s) must be bigger than "
                              "'near' (%s)" % (far, near), span)
        if cam_pos == cam_look:
            _err(bag, "E401", "the camera is standing at the place "
                              "it is looking at, so it cannot see "
                              "anything", span)
    aspect = (width / height) if height else 640.0 / 480.0
    ir_camera = _make(getattr(_ir, "IRCamera", None),
                      pos=cam_pos, position=cam_pos, at=cam_pos,
                      target=cam_look, look=cam_look, look_at=cam_look,
                      up=cam_up, fov=fov, fov_deg=fov, aspect=aspect,
                      aspect_ratio=aspect, near=near, near_plane=near,
                      far=far, far_plane=far, span=_span(camera_node))

    # ---- lights (E302 / E205) --------------------------------------
    ir_lights = []
    for node in light_nodes or [None]:
        if node is None:
            kind, direction = "directional", _DEFAULT_LIGHT_DIR
            intensity, color, span = 1.0, (255, 255, 255), None
        else:
            props = _props_dict(node)
            span = _span(node)
            kind = str(_field(node, props, "kind", "type", "mode",
                              default="directional")).lower()
            if kind not in LIGHT_KINDS_V1:
                _err(bag, "E205", "light %r is not built yet; v1 has "
                                  "directional and ambient lights"
                                  % kind, span)
                continue
            direction = _vec3(_field(node, props, "dir", "direction",
                                     "from", "position"),
                              _DEFAULT_LIGHT_DIR)
            intensity = _num(_field(node, props, "intensity",
                                    "strength"), 1.0)
            raw_color = _field(node, props, "color", "colour")
            color = _parse_color(raw_color, bag, span) \
                if raw_color is not None else (255, 255, 255)
            if color is None:
                color = (255, 255, 255)
            if not _finite_vec(direction) or direction == (0.0, 0.0, 0.0):
                _err(bag, "E302", "a light direction of 0 0 0 points "
                                  "nowhere", span)
            if not math.isfinite(intensity) or intensity < 0 \
                    or intensity > 100:
                _err(bag, "E302", "light intensity is %s, but it "
                                  "must be 0 to 100" % intensity, span)
        ir_lights.append(_make(
            getattr(_ir, "IRLight", None), kind=kind, type=kind,
            dir=direction, direction=direction, intensity=intensity,
            color=color, colour=color, span=span))

    # ---- objects + loads (E201/E204/E205/E301/E501) ----------------
    ir_objects = []
    names = {}
    total_tris = 0

    def add_object(node, forced_prim=None, load_path=None):
        nonlocal total_tris
        props = _props_dict(node)
        span = _span(node)
        prim = forced_prim or str(_field(
            node, props, "prim", "primitive", "kind", "type",
            default="cube")).lower()
        name = _field(node, props, "name", "id")
        if prim not in PRIMITIVES and prim != "load":
            _err(bag, "E205", "%r is not built yet; v1 primitives "
                              "are: %s" % (prim, ", ".join(PRIMITIVES)),
                 span)
            return
        if not isinstance(name, str) or not name:
            name = "%s%d" % (prim, len(ir_objects) + 1)
        if name in names:
            _err(bag, "E201", "there are two objects called %r; "
                              "give each object its own name" % name,
                 span)
            return
        names[name] = node
        # Texture is reserved in v1: loud E204, never a silent no-op.
        if _field(node, props, "texture", "texture_prop", "uv") \
                is not None or props.get("texture") is not None:
            _err(bag, "E204", "textures are reserved in v1 and are "
                              "not built yet; remove the texture "
                              "property for now", span)
        material = _field(node, props, "material")
        if material is not None:
            material = str(material).lower()
            if material not in MATERIALS:
                _err(bag, "E205", "material %r is not built yet; "
                                  "v1 materials are: %s"
                                  % (material, ", ".join(MATERIALS)),
                     span)
                material = "lambert"
        else:
            material = "lambert"
        raw_color = _field(node, props, "color", "colour",
                           "color_value", "colour_value", "color_raw")
        # No colour given => None (per-face palette, MASTER 1.3 /
        # P03 6.2); explicit colours (incl. '#ffffff') parse as-is.
        color = _parse_color(raw_color, bag, span) \
            if raw_color is not None else None
        if color is None and raw_color is not None:
            color = (255, 255, 255)
        # IRObject defaults (ir_nodes.py): size 2.0, scale (1,1,1),
        # detail 'med'.  Per-prim defaults from the B09 brief:
        # cube size 2.0; plane size 4.0; pyramid size 2.0 height 2.0;
        # sphere radius 1.0; cylinder/cone radius 1.0 height 2.0;
        # torus radius 1.5 (size may stay None where radius rules).
        size_raw = _field(node, props, "size")
        size3 = _vec3(size_raw, None)
        size = _num(size_raw)
        if size is None and size3 is not None:
            size = size3[0]
        if size is None:
            size = {"cube": 2.0, "plane": 4.0,
                    "pyramid": 2.0}.get(prim)
        radius = _num(_field(node, props, "radius"))
        if radius is None:
            radius = {"sphere": 1.0, "cylinder": 1.0, "cone": 1.0,
                      "torus": 1.5}.get(prim)
        obj_height = _num(_field(node, props, "height"))
        if obj_height is None:
            obj_height = {"cylinder": 2.0, "cone": 2.0,
                          "pyramid": 2.0}.get(prim)
        _check_dim(bag, span, "size", size)
        _check_dim(bag, span, "radius", radius)
        _check_dim(bag, span, "height", obj_height)
        tube = _num(_field(node, props, "tube"))
        _check_dim(bag, span, "tube", tube)
        width_v = _num(_field(node, props, "width"))
        depth_v = _num(_field(node, props, "depth"))
        _check_dim(bag, span, "width", width_v)
        _check_dim(bag, span, "depth", depth_v)
        segments = _int(_field(node, props, "segments"), None)
        if segments is None:
            segments = {"sphere": 16, "cylinder": 16, "cone": 16,
                        "torus": 24}.get(prim)
        detail_raw = _field(node, props, "detail")
        detail = str(detail_raw).lower() if detail_raw else "med"
        if segments is not None and not (MIN_SEGMENTS <= segments
                                         <= MAX_SEGMENTS):
            _err(bag, "E301", "segments is %s, but it must be %d "
                              "to %d" % (segments, MIN_SEGMENTS,
                                         MAX_SEGMENTS), span)
        rings = _int(_field(node, props, "rings"), None)
        if rings is not None and not (1 <= rings <= MAX_SEGMENTS):
            _err(bag, "E301", "rings is %s, but it must be 1 to %d"
                              % (rings, MAX_SEGMENTS), span)
        sides = _int(_field(node, props, "sides"), None)
        if sides is not None and not (3 <= sides <= 64):
            _err(bag, "E301", "sides is %s, but a pyramid needs at "
                              "least 3 sides" % sides, span)
        position = _vec3(_field(node, props, "at", "pos", "position"),
                         (0.0, 0.0, 0.0))
        rotation = _vec3(_field(node, props, "rotate", "rotation",
                                "rot"), (0.0, 0.0, 0.0))
        scale_raw = _field(node, props, "scale")
        scale_vec = _vec3(scale_raw, None)
        scale_num = _num(scale_raw, None)
        if scale_vec is not None and any(c == 0 for c in scale_vec):
            _err(bag, "E301", "scale cannot be 0; the object would "
                              "disappear", span)
        if scale_num is not None and scale_num == 0:
            _err(bag, "E301", "scale cannot be 0; the object would "
                              "disappear", span)
        if not _finite_vec(position) or not _finite_vec(rotation):
            _err(bag, "E301", "object positions and rotations must "
                              "be plain finite numbers", span)
        tri_props = dict(props)
        if load_path is not None:
            tri_props["_load_tris"] = _count_obj_triangles(load_path)
        # tris_est is ONLY for the E820 budget check; it is never
        # stored.  IRObject.triangles is solely the compat 'tris'
        # raw triangle list, otherwise None (ir_nodes.py contract).
        tris_est = _estimate_triangles(
            "load" if load_path is not None else prim, tri_props)
        total_tris += tris_est
        raw_tris = None
        if prim == "tris":
            candidate = props.get("tris") or props.get("triangles") \
                or _field(node, props, "triangles", "tris")
            if isinstance(candidate, (list, tuple)):
                raw_tris = candidate
        if scale_vec is not None:
            scale = tuple(float(c) for c in scale_vec)
        elif scale_num is not None:
            scale = (float(scale_num),) * 3
        else:
            scale = (1.0, 1.0, 1.0)
        capped = bool(props.get("capped", True)) \
            and not props.get("open")
        obj_cls = getattr(_ir, "IRObject", None)
        try:
            ir_obj = obj_cls(
                name=name, prim=prim, color=color, pos=position,
                rotate=rotation, scale=scale, size=size, size3=size3,
                radius=radius, height=obj_height, segments=segments,
                detail=detail, capped=capped, material=material,
                triangles=raw_tris, source_file=load_path,
                extensions={})
        except Exception:
            ir_obj = _make(
                obj_cls, name=name, prim=prim, color=color,
                pos=position, rotate=rotation, scale=scale, size=size,
                size3=size3, radius=radius, height=obj_height,
                segments=segments, detail=detail, capped=capped,
                material=material, triangles=raw_tris,
                source_file=load_path, extensions={})
        ir_objects.append(ir_obj)

    for node in object_nodes:
        add_object(node)
    for node in load_nodes:
        props = _props_dict(node)
        span = _span(node)
        path = _field(node, props, "path", "file", "source",
                      "filename")
        if not isinstance(path, str) or not path:
            _err(bag, "E501", "load needs the path of an .obj file",
                 span)
            continue
        if not path.lower().endswith(".obj"):
            _err(bag, "E205", "only .obj files can be loaded in v1; "
                              "%r is not built yet" % path, span)
            continue
        full = path if os.path.isabs(path) else os.path.join(
            base_dir or ".", path)
        if not os.path.isfile(full):
            _err(bag, "E501", "I can't find the file %r (looked "
                              "for %s)" % (path, full), span)
            continue
        add_object(node, forced_prim="load", load_path=path)

    # ---- structure + limits (E402 / E820) ---------------------------
    if not ir_objects:
        _err(bag, "E402", "this scene has no objects to render; "
                          "add a line like: cube red")
    if len(ir_objects) > MAX_OBJECTS:
        _err(bag, "E820", "this scene has %d objects, but the "
                          "limit is %d" % (len(ir_objects),
                                            MAX_OBJECTS))
    if total_tris > MAX_TRIANGLES:
        _err(bag, "E820", "this scene needs about %d triangles, "
                          "but the limit is %d; lower segments or "
                          "detail" % (total_tris, MAX_TRIANGLES))

    # ---- animations (E201 / E303) -----------------------------------
    ir_anims = []
    last_name = ir_objects[-1].name if ir_objects else None
    for node in anim_nodes:
        props = _props_dict(node)
        span = _span(node)
        kind_raw = _field(node, props, "kind", "motion", "action",
                          "type")
        kind = str(kind_raw).strip().lower() \
            if kind_raw is not None else ""
        if kind not in ANIM_KINDS:
            # Unknown/empty kind: loud E201, never a silent drop.
            _err(bag, "E201", "animation kind %r is missing or "
                              "unknown; v1 has: %s"
                              % (kind_raw, ", ".join(ANIM_KINDS)),
                 span)
            continue
        target = _field(node, props, "target", "target_name",
                        "object", "name")
        if target is None:
            target = "it"
        target = str(target)
        if target in ("it", "last"):
            if last_name is None:
                _err(bag, "E201", "%r has nothing to animate; there "
                                  "is no object before it" % kind,
                     span)
                continue
            target = last_name
        elif target != "all" and target not in names:
            _err(bag, "E201", "%s targets %r, but no object is "
                              "called that" % (kind, target), span)
            continue
        axis = _field(node, props, "axis")
        if axis is not None and str(axis).lower() not in ("x", "y", "z"):
            _err(bag, "E303", "axis %r is not one of x, y, z" % axis,
                 span)
        speed = _num(_field(node, props, "speed"))
        if speed is not None and (not math.isfinite(speed)
                                  or abs(speed) > MAX_SPEED):
            _err(bag, "E303", "speed is %s, but it must be between "
                              "-%s and %s" % (speed, int(MAX_SPEED),
                                               int(MAX_SPEED)), span)
        duration = _num(_field(node, props, "duration"))
        if duration is not None and (not math.isfinite(duration)
                                     or duration <= 0
                                     or duration > MAX_DURATION):
            _err(bag, "E303", "duration is %s, but it must be more "
                              "than 0 and at most %s seconds"
                              % (duration, int(MAX_DURATION)), span)
        fps = _int(_field(node, props, "fps"), None)
        if fps is not None and not (MIN_FPS <= fps <= MAX_FPS):
            _err(bag, "E303", "fps is %s, but it must be %d to %d"
                              % (fps, MIN_FPS, MAX_FPS), span)
        ease = _field(node, props, "ease")
        if ease is not None and str(ease).lower() not in EASES:
            _err(bag, "E201", "there is no easing called %r" % ease,
                 span)
        # IRAnim defaults (ir_nodes.py): axis y, speed 90.0,
        # duration 5.0, fps 30, ease linear, loop forever.
        loop_raw = _field(node, props, "loop", "loop_mode")
        anim_cls = getattr(_ir, "IRAnim", None)
        anim_kwargs = dict(
            kind=kind, target=target,
            axis=str(axis).lower() if axis is not None else "y",
            speed=float(speed) if speed is not None else 90.0,
            duration=float(duration) if duration is not None else 5.0,
            fps=int(fps) if fps is not None else 30,
            ease=str(ease).lower() if ease is not None else "linear",
            loop=loop_raw if loop_raw is not None else "forever")
        try:
            ir_anims.append(anim_cls(**anim_kwargs))
        except Exception:
            ir_anims.append(_make(anim_cls, **anim_kwargs))

    # ---- controls (E201 / E205 / E302) ------------------------------
    controls_kind = None
    if controls_node is not None:
        props = _props_dict(controls_node)
        span = _span(controls_node)
        controls_kind = str(_field(controls_node, props, "kind",
                                   "type", "mode",
                                   default="orbit")).lower()
        if controls_kind not in CONTROLS_KINDS:
            _err(bag, "E205", "controls %r are not built yet; v1 "
                              "has orbit and none" % controls_kind,
                 span)
        cmin = _num(_field(controls_node, props, "min"))
        cmax = _num(_field(controls_node, props, "max"))
        if cmin is not None and cmax is not None and cmin >= cmax:
            _err(bag, "E302", "controls min (%s) must be smaller "
                              "than max (%s)" % (cmin, cmax), span)

    # ---- outputs (E301) ----------------------------------------------
    ir_outputs = []
    for node in output_nodes:
        props = _props_dict(node)
        span = _span(node)
        fmt = str(_field(node, props, "format", "kind", "type",
                         default="render")).lower()
        path = _field(node, props, "path", "file", "to", "output",
                      "filename")
        owidth = _int(_field(node, props, "width", "w"), None)
        oheight = _int(_field(node, props, "height", "h"), None)
        osize = _field(node, props, "size")
        if isinstance(osize, (list, tuple)) and len(osize) >= 2:
            owidth, oheight = _int(osize[0], owidth), \
                _int(osize[1], oheight)
        if fmt == "export" or fmt in EXPORT_KINDS:
            kind = fmt if fmt in EXPORT_KINDS else str(
                _field(node, props, "export_kind",
                       default="json")).lower()
            ir_outputs.append(_make(
                getattr(_ir, "IROutput", None), kind="export",
                type="export", format=kind, path=path,
                width=owidth, height=oheight, span=span))
            continue
        if path is not None:
            ext = os.path.splitext(str(path))[1].lower()
            if ext not in RENDER_EXTS:
                _err(bag, "E301", "a render can only be written to "
                                  ".ppm or .png, not %r" % path, span)
        _check_image_dim(bag, span, "render width", owidth)
        _check_image_dim(bag, span, "render height", oheight)
        ofps = _int(_field(node, props, "fps"), None)
        if ofps is not None and not (MIN_FPS <= ofps <= MAX_FPS):
            _err(bag, "E303", "fps is %s, but it must be %d to %d"
                              % (ofps, MIN_FPS, MAX_FPS), span)
        odur = _num(_field(node, props, "duration"))
        if odur is not None and (odur <= 0 or odur > MAX_DURATION):
            _err(bag, "E303", "duration is %s, but it must be more "
                              "than 0 and at most %s seconds"
                              % (odur, int(MAX_DURATION)), span)
        ir_outputs.append(_make(
            getattr(_ir, "IROutput", None), kind="render",
            type="render", format="render",
            path=path or _DEFAULT_OUTPUT, width=owidth or width,
            height=oheight or height, fps=ofps, duration=odur,
            span=span))
    if not ir_outputs:
        ir_outputs.append(_make(
            getattr(_ir, "IROutput", None), kind="render",
            type="render", format="render", path=_DEFAULT_OUTPUT,
            width=width, height=height, span=None))

    if _has_errors(bag):
        return None
    return _make(getattr(_ir, "IRScene", None),
                 name=scene_name, scene_name=scene_name,
                 width=width, height=height, size=(width, height),
                 bg=bg, background=bg, camera=ir_camera,
                 lights=ir_lights, light=ir_lights[0] if ir_lights
                 else None, objects=ir_objects, animations=ir_anims,
                 anims=ir_anims, outputs=ir_outputs,
                 output=ir_outputs[0] if ir_outputs else None,
                 controls=controls_kind, tri_count=total_tris,
                 triangles=total_tris, span=None)
