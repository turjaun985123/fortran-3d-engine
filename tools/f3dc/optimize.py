#!/usr/bin/env python3
"""Forge3D optimization passes O1-O7 (seat B10) -- SAFE passes only.

Contract (docs/plan/MASTER-PLAN.md SS2, docs/plan/P07-optimization-passes.md,
docs/plan/P04-compiler-pipeline.md SS4.4):

    optimize(scene, bag, level=1) -> IRScene

Safety law: no pass in this module may change the rendered image.  The only
pass that touches a render-relevant field at all is O5 (palette), and it is
an identity there: a ``color is None`` cube stays ``None`` (both the Fortran
renderer and the JS runtime implement the shared palette/default for cubes),
and any other primitive with ``color is None`` is filled with the neutral
default ``(200, 200, 205)`` that those renderers already fall back to.

Everything else is either a provably-invisible removal (zero scale / zero
size / exactly zero-area triangles render no pixels), an annotation in an
``extensions`` dict, or an explicit no-op documented as such (O4).

Implementation notes:
  * Stdlib only.
  * Deterministic: passes run in registry order, iterate objects in scene
    order, and use no randomness, time, or hash-order-dependent output.
  * No mutation surprises: ``optimize`` deep-copies the input scene first;
    every pass mutates (and returns) only that copy.  The caller's scene is
    never modified.
  * Duck-typed on purpose: the IR is frozen (B08 ``ir_nodes.py``) but fields
    are read via ``getattr`` and written via a helper that also works on
    ``frozen=True`` dataclasses, so this module does not depend on one exact
    spelling of optional fields (``prim``/``kind``, ``transform`` dict or
    object, ``params`` dict, direct ``scale``/``size``/``rotate`` attrs).
"""

import copy
import inspect

__all__ = ["optimize", "PASSES", "register_pass", "DEFAULT_COLOR"]

#: Neutral fallback colour for non-cube primitives whose color is None.
#: This is the value the renderers already use, so filling it in is an
#: identity transformation (see module docstring / O5).
DEFAULT_COLOR = (200, 200, 205)

#: Warning code emitted when O1 drops a degenerate object.  Validate should
#: already have caught these (E3xx range checks); O1 is the belt-and-braces
#: pass, so it warns instead of erroring (P04 SS4.4: optimize never fails,
#: warnings W5xx only).
W_DROPPED_OBJECT = "W510"
W_DEGENERATE_TRI = "W511"


# --------------------------------------------------------------------------
# Small field-access helpers (frozen-dataclass friendly, dict friendly)
# --------------------------------------------------------------------------

_MISSING = object()


def _get(obj, *names, default=None):
    """First present attribute/key among ``names`` on ``obj``, else default."""
    for name in names:
        if isinstance(obj, dict):
            if name in obj:
                return obj[name]
        else:
            value = getattr(obj, name, _MISSING)
            if value is not _MISSING:
                return value
    return default


def _set(obj, name, value):
    """Set attribute/key, working on frozen dataclasses too.  Returns bool."""
    if isinstance(obj, dict):
        obj[name] = value
        return True
    try:
        setattr(obj, name, value)
        return True
    except Exception:
        try:
            object.__setattr__(obj, name, value)
            return True
        except Exception:
            return False


def _extensions(owner):
    """Return owner's mutable ``extensions`` dict, creating it if possible."""
    ext = _get(owner, "extensions", default=None)
    if isinstance(ext, dict):
        return ext
    if ext is None:
        new = {}
        if _set(owner, "extensions", new):
            return new
    return None


def _warn(bag, code, message):
    """Best-effort warning delivery to an ErrorBag of unknown exact shape.

    Tries the plausible ErrorBag spellings in order; if none exists the
    warning is still recorded by the caller in ``scene.extensions`` so it is
    never silently lost.  Never raises: optimize must not fail (P04 SS4.4).
    """
    if bag is None:
        return
    if isinstance(bag, list):
        bag.append("%s: %s" % (code, message))
        return
    for method_name in ("warn", "warning", "add_warning", "report_warning",
                        "add", "append", "emit"):
        method = getattr(bag, method_name, None)
        if not callable(method):
            continue
        for args in ((code, message), (message,), ("%s: %s" % (code, message),)):
            try:
                method(*args)
                return
            except TypeError:
                continue
            except Exception:
                return


def _record_warning(scene, code, message):
    ext = _extensions(scene)
    if ext is not None:
        ext.setdefault("optimize_warnings", []).append(
            "%s: %s" % (code, message))


def _objects(scene):
    objs = _get(scene, "objects", default=None)
    return list(objs) if objs is not None else []


def _set_objects(scene, objs):
    _set(scene, "objects", list(objs))


def _freeze(value):
    """Canonical hashable form of a value, for dedup keys (deterministic)."""
    if isinstance(value, dict):
        return ("dict", tuple(sorted(
            (str(k), _freeze(v)) for k, v in value.items())))
    if isinstance(value, (list, tuple)):
        return ("seq", tuple(_freeze(v) for v in value))
    if isinstance(value, (set, frozenset)):
        return ("set", tuple(sorted((_freeze(v) for v in value), key=repr)))
    if value is None or isinstance(value, (str, int, float, bool)):
        return ("atom", value)
    if hasattr(value, "__dict__"):
        return ("obj", type(value).__name__, _freeze(vars(value)))
    return ("repr", repr(value))


def _vec3(value):
    """Normalise a scalar-or-sequence scale/rotate/size-ish value to a tuple."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return (value,)
    try:
        return tuple(value)
    except TypeError:
        return None


# --------------------------------------------------------------------------
# O1 -- drop degenerate objects
# --------------------------------------------------------------------------

def _pass_o1_drop(scene, bag):
    """O1 drop: remove objects with any scale component == 0 or size <= 0.

    Such an object collapses to a point/line/plane of zero volume and can
    rasterize no pixels, so dropping it cannot change the image.  Validate
    should already reject these; if one reaches here we still drop it and
    emit a W-code rather than failing (optimize never fails).
    """
    kept = []
    for obj in _objects(scene):
        transform = _get(obj, "transform", default=None)
        params = _get(obj, "params", default=None)
        scale = _vec3(_get(transform, "scale", default=None)) or \
            _vec3(_get(obj, "scale", default=None)) or \
            _vec3(_get(params, "scale", default=None))
        size = _get(obj, "size", default=None)
        if size is None:
            size = _get(params, "size", default=None)
        name = _get(obj, "name", "id", default="?")
        if scale is not None and any(c == 0 for c in scale):
            msg = "dropped object %r: zero scale component in %r" % (name, scale)
            _warn(bag, W_DROPPED_OBJECT, msg)
            _record_warning(scene, W_DROPPED_OBJECT, msg)
            continue
        if isinstance(size, (int, float)) and size <= 0:
            msg = "dropped object %r: size %r <= 0" % (name, size)
            _warn(bag, W_DROPPED_OBJECT, msg)
            _record_warning(scene, W_DROPPED_OBJECT, msg)
            continue
        kept.append(obj)
    _set_objects(scene, kept)
    return scene


# --------------------------------------------------------------------------
# O2 -- dedup candidates (record only, never remove)
# --------------------------------------------------------------------------

def _pass_o2_dedup(scene, bag):
    """O2 dedup: count identical objects, but KEEP all of them.

    Identical objects (same prim/params/transform/color/material) appearing
    more than once are *not* removed.  Why: correctness first -- duplicates
    may overlap intentionally (e.g. repeat/grid expansions, coincident
    surfaces whose draw order/depth interaction the author relied on), and
    P07 SS4.5 only permits duplicate removal when the duplicates are also
    provably unexported/unnamed, which this pass cannot prove from the IR
    alone.  So O2 is an accounting pass: it records how many objects are
    extra copies beyond the first of each identical group in
    ``scene.extensions['dedup_candidates']`` for the opt report / a future
    provably-safe pass, and changes nothing else.
    """
    seen = {}
    extra = 0
    for obj in _objects(scene):
        key = (
            _freeze(_get(obj, "prim", "kind", "primitive", default=None)),
            _freeze(_get(obj, "params", default=None)),
            _freeze(_get(obj, "transform", default=None)),
            _freeze(_get(obj, "color", default=None)),
            _freeze(_get(obj, "material", "material_ref", default=None)),
        )
        if key in seen:
            extra += 1
        else:
            seen[key] = obj
    ext = _extensions(scene)
    if ext is not None:
        ext["dedup_candidates"] = extra
    return scene


# --------------------------------------------------------------------------
# O3 -- degenerate-triangle cull for compat 'tris' objects
# --------------------------------------------------------------------------

def _tri_points(tri, verts):
    """Resolve a triangle to three (x, y, z) points, or None if unresolvable.

    Handles raw coordinate triples, dicts with a ``v`` key, index triples
    into ``verts``, and index-carrying objects (``a``/``b``/``c`` or
    ``v``/``indices``/``verts`` attributes).
    """
    raw = None
    if isinstance(tri, dict):
        raw = _get(tri, "v", "verts", "vertices", "indices", default=None)
    elif isinstance(tri, (list, tuple)):
        raw = tri
    else:
        raw = _get(tri, "v", "verts", "vertices", "indices", default=None)
        if raw is None:
            a = _get(tri, "a", default=None)
            b = _get(tri, "b", default=None)
            c = _get(tri, "c", default=None)
            if a is not None and b is not None and c is not None:
                raw = (a, b, c)
    if raw is None or len(raw) != 3:
        return None
    points = []
    for item in raw:
        if isinstance(item, (list, tuple)) and len(item) == 3:
            points.append(tuple(item))
        elif isinstance(item, int) and verts is not None and 0 <= item < len(verts):
            v = verts[item]
            if isinstance(v, (list, tuple)) and len(v) == 3:
                points.append(tuple(v))
            else:
                return None
        else:
            return None
    return points


def _is_zero_area(points):
    (ax, ay, az), (bx, by, bz), (cx, cy, cz) = points
    ux, uy, uz = bx - ax, by - ay, bz - az
    vx, vy, vz = cx - ax, cy - ay, cz - az
    cross = (uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
    # Exactly zero only: a merely tiny triangle may still cover a pixel
    # centre, so anything non-zero is kept (never change the image).
    return cross == (0, 0, 0) or cross == (0.0, 0.0, 0.0)


def _pass_o3_degenerate_cull(scene, bag):
    """O3 degenerate-cull: drop exactly zero-area triangles of 'tris' objects.

    Compat-loaded objects (``prim == 'tris'``, e.g. from legacy JSON/OBJ)
    carry raw triangle lists that may contain collapsed triangles.  A
    zero-area triangle covers no pixel centre and the rasterizer's own
    degenerate check discards it, so dropping it is image-identical.
    Parametric primitives are left alone: their triangles are generated by
    the renderers, not stored here.
    """
    dropped = 0
    for obj in _objects(scene):
        prim = _get(obj, "prim", "kind", "primitive", default=None)
        tris = _get(obj, "tris", "triangles", default=None)
        if tris is None:
            continue
        is_tris_obj = (isinstance(prim, str) and prim.lower() == "tris") or (
            prim is None and any(
                isinstance(t, (list, tuple)) and len(t) == 3 and
                isinstance(t[0], (list, tuple)) for t in tris))
        if not is_tris_obj:
            continue
        verts = _get(obj, "verts", "vertices", default=None)
        kept = []
        for tri in tris:
            points = _tri_points(tri, verts)
            if points is not None and _is_zero_area(points):
                dropped += 1
                continue
            kept.append(tri)
        if len(kept) != len(tris):
            _set(obj, "tris" if _get(obj, "tris", default=None) is not None
                 else "triangles", kept)
    if dropped:
        msg = "dropped %d zero-area triangle(s) from 'tris' objects" % dropped
        _warn(bag, W_DEGENERATE_TRI, msg)
        _record_warning(scene, W_DEGENERATE_TRI, msg)
    return scene


# --------------------------------------------------------------------------
# O4 -- static backface cull: NO-OP in v1 (documented, never faked)
# --------------------------------------------------------------------------

def _pass_o4_static_backface(scene, bag):
    """O4 static backface: no-op in v1.

    A triangle's facing is a function of the camera, so compile-time
    backface removal needs per-face camera math (world normal vs. view
    direction for the one fixed camera) plus proof that the object is
    closed, statically transformed, single-sided and unanimated
    (P07 SS4.4).  That proof machinery does not exist in v1, and faking it
    (e.g. dropping faces by stored normal alone) would change the image
    for other cameras/exports.  The renderer's screen-space signed-area
    cull remains the authoritative test.  This pass therefore deliberately
    does nothing and is kept in the registry so the pass order/report stay
    stable when a proven implementation lands.
    """
    return scene


# --------------------------------------------------------------------------
# O5 -- palette / default colour normalisation (identity)
# --------------------------------------------------------------------------

def _pass_o5_palette(scene, bag):
    """O5 palette: normalise ``color is None`` without changing any pixel.

    * ``prim == 'cube'`` with color None: leave None.  Both the Fortran
      renderer and the JS runtime implement the shared palette default for
      cubes, so None already has one agreed meaning.
    * Any other primitive with color None: set ``color = (200, 200, 205)``,
      the neutral default those same renderers fall back to -- writing it
      explicitly is an identity, and makes the IR fully defaulted for the
      emitters that do not implement the fallback.

    Objects with an explicit color, and objects with no color field at all,
    are untouched.
    """
    for obj in _objects(scene):
        if _get(obj, "color", default=_MISSING) is not None:
            continue  # explicit colour, or no colour field on this IR shape
        prim = _get(obj, "prim", "kind", "primitive", default=None)
        if isinstance(prim, str) and prim.lower() == "cube":
            continue  # palette-implemented in both renderers; keep None
        _set(obj, "color", DEFAULT_COLOR)
    return scene


# --------------------------------------------------------------------------
# O6 -- transform bake (informational annotation only)
# --------------------------------------------------------------------------

def _animated_targets(scene):
    """Names/ids targeted by any animation in the scene (empty if none)."""
    targets = set()
    anims = _get(scene, "animations", "anims", "timeline", default=None) or []
    for anim in anims:
        target = _get(anim, "target", "target_name", "object", "object_name",
                      "name", default=None)
        if target is not None:
            targets.add(target)
    return targets


def _pass_o6_transform_bake(scene, bag):
    """O6 transform-bake: annotate, never alter geometry in the IR.

    For each object with NO animation targeting it, record its rotation in
    the object's ``extensions['baked_rotation_deg']``.  This is purely
    informational: the actual baking happens at render time in Fortran
    (which composes the model matrix per object), so the IR transform and
    geometry are deliberately left byte-for-byte as authored.  Animated
    objects are skipped entirely -- their rotation is a function of time,
    so any baked value would be wrong.  Semantically a no-op.
    """
    targets = _animated_targets(scene)
    for obj in _objects(scene):
        name = _get(obj, "name", "id", default=None)
        own_anims = _get(obj, "animations", "animation", default=None)
        if own_anims or (name is not None and name in targets):
            continue
        transform = _get(obj, "transform", default=None)
        params = _get(obj, "params", default=None)
        rotate = _get(transform, "rotate", "rotation", default=None)
        if rotate is None:
            rotate = _get(obj, "rotate", "rotation", default=None)
        if rotate is None:
            rotate = _get(params, "rotate", "rotation", default=None)
        rotate = _vec3(rotate)
        ext = _extensions(obj)
        if ext is not None:
            ext["baked_rotation_deg"] = tuple(rotate) if rotate else (0, 0, 0)
    return scene


# --------------------------------------------------------------------------
# O7 -- JS depth-sort hint
# --------------------------------------------------------------------------

def _pass_o7_depth_sort_hint(scene, bag):
    """O7 JS depth-sort hint: set ``scene.extensions['depth_sort'] = True``.

    The Fortran renderer has a Z-buffer, so object/triangle order is
    irrelevant there.  The JS/HTML viewer uses the painter's algorithm
    (no Z-buffer), where emit order *is* the depth correctness input, so
    the JS emitter needs to depth-sort.  This pass only raises the hint
    flag; it reorders nothing in the IR itself, so it cannot change the
    native render and does not presume the JS emitter's sort key.
    """
    ext = _extensions(scene)
    if ext is not None:
        ext["depth_sort"] = True
    return scene


# --------------------------------------------------------------------------
# Pass registry (P29 rule 4: passes are named, ordered, register-able)
# --------------------------------------------------------------------------

#: Ordered registry of (name, pass_fn).  Each pass_fn takes (scene, bag)
#: (a 1-argument fn(scene) is also accepted) and returns the scene.
PASSES = []


def register_pass(name, fn):
    """Register ``fn`` under ``name``; re-registering a name replaces it
    in place, preserving registry order.  Returns ``fn``."""
    for i, (existing, _) in enumerate(PASSES):
        if existing == name:
            PASSES[i] = (name, fn)
            return fn
    PASSES.append((name, fn))
    return fn


register_pass("O1-drop", _pass_o1_drop)
register_pass("O2-dedup", _pass_o2_dedup)
register_pass("O3-degenerate-cull", _pass_o3_degenerate_cull)
register_pass("O4-static-backface", _pass_o4_static_backface)
register_pass("O5-palette", _pass_o5_palette)
register_pass("O6-transform-bake", _pass_o6_transform_bake)
register_pass("O7-depth-sort-hint", _pass_o7_depth_sort_hint)


def _run_pass(fn, scene, bag):
    try:
        arity = len(inspect.signature(fn).parameters)
    except (TypeError, ValueError):
        arity = 2
    result = fn(scene, bag) if arity >= 2 else fn(scene)
    # A pass that returns None is treated as having mutated in place.
    return scene if result is None else result


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def optimize(scene, bag, level=1):
    """Apply the safe O1-O7 passes to ``scene`` and return a new IRScene.

    ``bag`` is the diagnostics ErrorBag (may be None).  ``level`` <= 0
    returns an unmodified deep copy (the golden-reference configuration);
    level >= 1 runs every registered pass in registry order.  The input
    scene is never mutated.
    """
    result = copy.deepcopy(scene)
    if level is None or level < 1:
        return result
    for _name, fn in list(PASSES):
        result = _run_pass(fn, result, bag)
    return result
