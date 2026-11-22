"""Forge3D Fortran back ends (B12, MASTER-PLAN section 2).

Stdlib only.  Two outputs are produced from the frozen Typed IR
(``ir_nodes.py``, ``ir_version=1``); emitters see only the IR, never
the AST or the source text:

1. :func:`emit_scene_text` -- the ``.scene`` text format that the
   Fortran back end (``src/scene.f90``, seat B23) parses.  The format
   is EXACT, one statement per line::

       forge3d-scene 1
       # <header stamp lines start with '#'>
       size W H
       bg R G B
       camera px py pz tx ty tz ux uy uz fov near far
       light directional dx dy dz R G B intensity
       light ambient intensity
       frames N
       output <path>
       object PRIM NAME MATERIAL CR CG CB px py pz rx ry rz sx sy sz SIZE RADIUS HEIGHT SEGMENTS
       tris NAME COUNT            (followed by COUNT 'tri ...' lines)
       loadobj NAME MATERIAL R G B px py pz rx ry rz sx sy sz PATH
       anim KIND TARGET AXIS SPEED DURATION FPS EASE LOOP

   Colour sentinels: an object whose IR ``color`` is ``None`` (the
   per-face palette) is written as ``-1 -1 -1``; a missing ``radius`` /
   ``height`` is written ``-1`` and a missing ``segments`` as ``0``.
   ``frames`` is ``max(round(duration * fps))`` over the animations
   when there is at least one animation and the render output is not
   a still, otherwise ``1``.  All non-integer numbers go through
   ``emit_common.fmt_num``.

2. :func:`emit_fortran_program` -- a standalone, compilable Fortran
   program (``<stem>_scene.f90`` style) built only on the public
   runtime APIs ``math_3d`` / ``mesh_3d`` / ``camera_3d`` /
   ``material_3d`` / ``renderer_3d``.  It renders STATIC FRAME 0
   ONLY: animation is rendered through the ``.scene`` path above
   (the Fortran scene reader owns the frame loop), never by this
   generated program.
"""

from __future__ import annotations

import re

try:  # flat module layout: tools/f3dc on sys.path
    from emit_common import fmt_num, header_stamp  # type: ignore
except Exception:  # pragma: no cover - package layout / B11 not landed
    try:
        from .emit_common import fmt_num, header_stamp  # type: ignore
    except Exception:
        header_stamp = None  # type: ignore
        def fmt_num(value):  # local fallback, same contract as B11
            """Format a number: ints plainly, floats trimmed to 6 dp."""
            if isinstance(value, bool):
                return str(int(value))
            if isinstance(value, int):
                return str(value)
            number = float(value)
            if number == 0.0:
                return "0"
            if number.is_integer() and abs(number) < 1e15:
                return str(int(number))
            text = ("%.6f" % number).rstrip("0").rstrip(".")
            return text if text not in ("", "-0") else "0"

__all__ = [
    "emit_scene_text",
    "emit_fortran_program",
    "emit_scene",
    "emit_fortran",
]

_DEFAULT_OUTPUT = "output_render.ppm"


def _stamp(ir, comment):
    """Header stamp lines (emit_common.header_stamp, with fallback)."""
    name = str(_get(ir, "name", default="untitled"))
    if header_stamp is not None:
        try:
            return header_stamp(name, ir, comment).splitlines()
        except Exception:
            pass
    return ["%s Forge3D generated file - do not edit" % comment,
            "%s source: %s" % (comment, name)]


# ---------------------------------------------------------------------------
# Small duck-typed accessors (IR dataclasses, or validate's fallback objects)
# ---------------------------------------------------------------------------

def _get(obj, *names, default=None):
    for name in names:
        if obj is None:
            break
        if isinstance(obj, dict):
            value = obj.get(name)
        else:
            value = getattr(obj, name, None)
        if value is not None:
            return value
    return default


def _vec3(value, default=(0.0, 0.0, 0.0)):
    if isinstance(value, (list, tuple)) and len(value) >= 3:
        return (value[0], value[1], value[2])
    return default


def _fmt_vec(vec):
    return " ".join(fmt_num(v) for v in vec)


def _color_ints(color):
    """(r, g, b) ints for a colour sequence, else None."""
    if isinstance(color, (list, tuple)) and len(color) >= 3:
        try:
            return (int(color[0]), int(color[1]), int(color[2]))
        except (TypeError, ValueError):
            return None
    return None


def _color_text(color):
    ints = _color_ints(color)
    if ints is None:
        return "-1 -1 -1"  # palette sentinel
    return "%d %d %d" % ints


def _num_or(value, sentinel):
    return fmt_num(value) if value is not None else sentinel


def _scalar(value):
    """Collapse a sequence size (size3-style) to its first component."""
    if isinstance(value, (list, tuple)):
        return value[0] if value else None
    return value


def _render_output(ir):
    """The first render output (kind == 'render'), or None."""
    outputs = _get(ir, "outputs", default=[]) or []
    for out in outputs:
        if str(_get(out, "kind", default="")).lower() == "render":
            return out
    return None


def _any_output(ir):
    outputs = _get(ir, "outputs", default=[]) or []
    return outputs[0] if outputs else None


def _is_still(ir):
    """True when the render output forces a still (1 frame)."""
    candidates = []
    render = _render_output(ir)
    if render is not None:
        candidates.append(render)
    for out in (_get(ir, "outputs", default=[]) or []):
        if str(_get(out, "kind", default="")).lower() == "still":
            candidates.append(out)
    for out in candidates:
        if _get(out, "still", default=False):
            return True
        for field in ("kind", "format", "mode"):
            if str(_get(out, field, default="")).lower() == "still":
                return True
    return False


def _output_path(ir):
    render = _render_output(ir)
    path = _get(render, "path") if render is not None else None
    if not path:
        return _DEFAULT_OUTPUT
    return str(path)


def _frame_count(ir):
    animations = _get(ir, "animations", "anims", default=[]) or []
    if not animations or _is_still(ir):
        return 1
    frames = 1
    for anim in animations:
        duration = _get(anim, "duration", default=5.0)
        fps = _get(anim, "fps", default=30)
        try:
            frames = max(frames, int(round(float(duration) * float(fps))))
        except (TypeError, ValueError):
            continue
    return max(1, frames)


# ---------------------------------------------------------------------------
# Raw triangle soups (prim == 'tris', compat readers)
# ---------------------------------------------------------------------------

def _tri_parts(tri, obj_color):
    """Normalise one raw triangle to ((r, g, b), [v1, v2, v3])."""
    color = None
    verts = None
    if isinstance(tri, dict):
        verts = None
        for key in ("v", "verts", "vertices", "points"):
            if isinstance(tri.get(key), (list, tuple)):
                verts = tri[key]
                break
        color = _color_ints(tri.get("color", tri.get("colour")))
    elif isinstance(tri, (list, tuple)):
        items = list(tri)
        seqs = [it for it in items
                if isinstance(it, (list, tuple)) and len(it) == 3
                and all(isinstance(c, (int, float))
                        and not isinstance(c, bool) for c in it)]
        if len(items) == 3 and len(seqs) == 3:
            verts = items
        elif len(items) == 4 and len(seqs) == 4:
            # (color, v1, v2, v3) or (v1, v2, v3, color): the colour is
            # the triple whose values are all in 0..255 integer range
            # AND the remaining three still parse as vertices; prefer
            # a trailing/leading explicit colour only when ambiguous
            # shapes carry one -- default: first triple is the colour
            # for the 4-sequence compat shape (v..., color) is rare.
            verts = items[1:]
            color = _color_ints(items[0])
        elif len(seqs) >= 3:
            verts = seqs[:3]
    if verts is None or len(verts) < 3:
        return None
    points = []
    for vertex in verts[:3]:
        if not (isinstance(vertex, (list, tuple)) and len(vertex) >= 3):
            return None
        points.append((vertex[0], vertex[1], vertex[2]))
    if color is None:
        color = _color_ints(obj_color) or (255, 255, 255)
    return color, points


def _triangles(obj):
    raw = _get(obj, "triangles", "tris", default=None)
    if not isinstance(raw, (list, tuple)):
        return []
    parts = []
    for tri in raw:
        parsed = _tri_parts(tri, _get(obj, "color"))
        if parsed is not None:
            parts.append(parsed)
    return parts


# ---------------------------------------------------------------------------
# 1. The .scene text format (B23 parses exactly this)
# ---------------------------------------------------------------------------

def emit_scene_text(ir) -> str:
    """Serialise *ir* to the Fortran back-end ``.scene`` text format."""
    lines = []
    lines.append("forge3d-scene 1")
    lines.extend(_stamp(ir, "#"))

    width = _get(ir, "width", default=640)
    height = _get(ir, "height", default=480)
    lines.append("size %d %d" % (int(width), int(height)))

    bg = _color_ints(_get(ir, "bg", "background", default=(25, 25, 35)))
    if bg is None:
        bg = (25, 25, 35)
    lines.append("bg %d %d %d" % bg)

    camera = _get(ir, "camera", default=None)
    cam_pos = _vec3(_get(camera, "pos", "position", default=(3, 2.5, 4)))
    cam_target = _vec3(_get(camera, "target", default=(0, 0, 0)))
    cam_up = _vec3(_get(camera, "up", default=(0, 1, 0)))
    lines.append(
        "camera %s %s %s %s %s %s" % (
            _fmt_vec(cam_pos),
            _fmt_vec(cam_target),
            _fmt_vec(cam_up),
            fmt_num(_get(camera, "fov", default=60.0)),
            fmt_num(_get(camera, "near", default=0.1)),
            fmt_num(_get(camera, "far", default=100.0)),
        )
    )

    for light in (_get(ir, "lights", default=[]) or []):
        kind = str(_get(light, "kind", default="directional")).lower()
        intensity = fmt_num(_get(light, "intensity", default=1.0))
        if kind == "ambient":
            lines.append("light ambient %s" % intensity)
        else:
            direction = _vec3(
                _get(light, "direction", "dir", default=(-0.5, -1, -0.7)))
            lcolor = _color_ints(
                _get(light, "color", "colour", default=(255, 255, 255)))
            if lcolor is None:
                lcolor = (255, 255, 255)
            lines.append(
                "light %s %s %d %d %d %s" % (
                    kind, _fmt_vec(direction),
                    lcolor[0], lcolor[1], lcolor[2], intensity,
                )
            )

    lines.append("frames %d" % _frame_count(ir))
    lines.append("output %s" % _output_path(ir))

    for obj in (_get(ir, "objects", default=[]) or []):
        name = str(_get(obj, "name", default="object"))
        prim = str(_get(obj, "prim", "primitive", default="cube")).lower()
        material = str(_get(obj, "material", default="lambert")).lower()
        color = _get(obj, "color", "colour")
        pos = _vec3(_get(obj, "pos", "position", default=(0, 0, 0)))
        rotate = _vec3(_get(obj, "rotate", "rotation", default=(0, 0, 0)))
        scale = _vec3(_get(obj, "scale", default=(1, 1, 1)), (1, 1, 1))
        transform = "%s %s %s" % (
            _fmt_vec(pos), _fmt_vec(rotate), _fmt_vec(scale))

        if prim == "tris":
            tris = _triangles(obj)
            lines.append("tris %s %d" % (name, len(tris)))
            for tri_color, points in tris:
                coords = " ".join(_fmt_vec(p) for p in points)
                lines.append(
                    "tri %d %d %d %s" % (
                        tri_color[0], tri_color[1], tri_color[2], coords))
        elif prim == "load":
            path = _get(obj, "source_file", "path", "file",
                        default=None) or "model.obj"
            lines.append(
                "loadobj %s %s %s %s %s" % (
                    name, material, _color_text(color),
                    transform, str(path),
                )
            )
        else:
            size = _scalar(_get(obj, "size"))
            if size is None:
                size = _scalar(_get(obj, "size3"))
            radius = _get(obj, "radius")
            obj_height = _get(obj, "height")
            segments = _get(obj, "segments")
            lines.append(
                "object %s %s %s %s %s %s %s %s %s" % (
                    prim, name, material, _color_text(color), transform,
                    _num_or(size, "-1"),
                    _num_or(radius, "-1"),
                    _num_or(obj_height, "-1"),
                    "%d" % int(segments) if segments is not None else "0",
                )
            )

    for anim in (_get(ir, "animations", "anims", default=[]) or []):
        lines.append(
            "anim %s %s %s %s %s %s %s %s" % (
                str(_get(anim, "kind", default="spin")).lower(),
                str(_get(anim, "target", default="all")),
                str(_get(anim, "axis", default="y")).lower(),
                fmt_num(_get(anim, "speed", default=90.0)),
                fmt_num(_get(anim, "duration", default=5.0)),
                "%d" % int(_get(anim, "fps", default=30)),
                str(_get(anim, "ease", default="linear")).lower(),
                str(_get(anim, "loop", default="forever")).lower(),
            )
        )

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 2. Standalone Fortran program (static frame 0 only)
# ---------------------------------------------------------------------------

def _f(value):
    """A Fortran ``real(dp)`` literal, e.g. ``2.5_dp``."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = 0.0
    text = ("%.6f" % number).rstrip("0").rstrip(".")
    if text in ("", "-0"):
        text = "0"
    if "." not in text:
        text += ".0"
    return "%s_dp" % text


def _f_vec(vec):
    return "vec3_create(%s, %s, %s)" % (_f(vec[0]), _f(vec[1]), _f(vec[2]))


def _f_str(text):
    return "'" + str(text).replace("'", "''") + "'"


def _program_name(ir):
    raw = str(_get(ir, "name", default="untitled") or "untitled")
    stem = re.sub(r"[^A-Za-z0-9_]", "_", raw).strip("_") or "forge3d"
    if stem[0].isdigit():
        stem = "s_" + stem
    return stem.lower() + "_scene"


def _extension(obj, *keys, default=None):
    ext = _get(obj, "extensions", default={})
    if isinstance(ext, dict):
        for key in keys:
            if ext.get(key) is not None:
                return ext[key]
    for key in keys:
        value = getattr(obj, key, None)
        if value is not None:
            return value
    return default


def _rgb_array(ints):
    """A Fortran ``real(dp)`` array literal for 0..255 colour ints."""
    if ints is None:
        return "[%s, %s, %s]" % (_f(1.0), _f(1.0), _f(1.0))
    return "[%s, %s, %s]" % (
        _f(ints[0] / 255.0), _f(ints[1] / 255.0), _f(ints[2] / 255.0))


def _material_call(obj):
    """A constructor call matching the real ``src/material.f90`` API.

    ``material_lambert(rgb(3), use_tri)``, ``material_basic(rgb(3))``
    and ``material_phong(rgb(3), shininess)`` all take a ``real(dp)``
    array, never three scalar colour arguments.
    """
    material = str(_get(obj, "material", default="lambert")).lower()
    ints = _color_ints(_get(obj, "color", "colour"))
    rgb = _rgb_array(ints)
    if material == "basic":
        # material_basic hard-codes use_tri_color=.false.
        return "material_basic(%s)" % rgb
    if material == "phong":
        # 32.0_dp is the Material type's default shininess.
        return "material_phong(%s, %s)" % (rgb, _f(32.0))
    if ints is None:
        # Palette object: white material, per-face mesh colours show.
        return "material_lambert(%s, .true.)" % rgb
    return "material_lambert(%s, .false.)" % rgb


def _material_needs_palette_comment(obj):
    """True for palette (colour ``None``) basic/phong objects.

    Those constructors hard-code ``use_tri_color=.false.``, so the
    per-face palette colours cannot show through them; the generated
    program says so in a comment and falls back to white.
    """
    material = str(_get(obj, "material", default="lambert")).lower()
    return material in ("basic", "phong") and \
        _color_ints(_get(obj, "color", "colour")) is None


def _build_call(obj):
    """The ``create_*`` call building this object's mesh, or None."""
    prim = str(_get(obj, "prim", "primitive", default="cube")).lower()
    size = _scalar(_get(obj, "size"))
    size3 = _get(obj, "size3")
    if isinstance(size3, (list, tuple)) and len(size3) >= 3:
        size3 = (size3[0], size3[1], size3[2])
    else:
        size3 = None
    if size is None and size3 is not None:
        size = size3[0]
    radius = _get(obj, "radius")
    height = _get(obj, "height")
    segments = _get(obj, "segments")
    seg = int(segments) if segments is not None else None
    capped = ".true." if _get(obj, "capped", default=True) else ".false."

    if prim == "cube":
        if size3 is not None:
            return "call create_box(msh, %s, %s, %s)" % (
                _f(size3[0]), _f(size3[1]), _f(size3[2]))
        return "call create_cube(msh, %s)" % _f(
            size if size is not None else 2.0)
    if prim == "box":
        if size3 is not None:
            return "call create_box(msh, %s, %s, %s)" % (
                _f(size3[0]), _f(size3[1]), _f(size3[2]))
        edge = size if size is not None else 2.0
        return "call create_box(msh, %s, %s, %s)" % (
            _f(edge), _f(edge), _f(edge))
    if prim == "sphere":
        return "call create_sphere(msh, %s, %d)" % (
            _f(radius if radius is not None else 1.0), seg or 16)
    if prim == "cylinder":
        return "call create_cylinder(msh, %s, %s, %d, %s)" % (
            _f(radius if radius is not None else 1.0),
            _f(height if height is not None else 2.0), seg or 16, capped)
    if prim == "cone":
        return "call create_cone(msh, %s, %s, %d, %s)" % (
            _f(radius if radius is not None else 1.0),
            _f(height if height is not None else 2.0), seg or 16, capped)
    if prim == "plane":
        if size3 is not None:
            width, depth = size3[0], size3[2]
        else:
            width = depth = size if size is not None else 4.0
        return "call create_plane(msh, %s, %s)" % (_f(width), _f(depth))
    if prim == "pyramid":
        return "call create_pyramid(msh, %s, %s)" % (
            _f(size if size is not None else 2.0),
            _f(height if height is not None else 2.0))
    if prim == "torus":
        major = radius if radius is not None else 1.5
        tube = _extension(obj, "tube", "tube_radius", "minor_radius")
        if tube is None:
            tube = major / 3.0
        ring_seg = seg or 24
        tube_seg = _extension(obj, "tube_segments", "rings")
        tube_seg = int(tube_seg) if tube_seg is not None \
            else max(3, ring_seg // 2)
        return "call create_torus(msh, %s, %s, %d, %d)" % (
            _f(major), _f(tube), ring_seg, tube_seg)
    return None


_MAX_LINE = 120


def _commas_outside_quotes(text):
    """Indices of commas in *text* that are not inside a string."""
    indices = []
    in_string = False
    i = 0
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 1
                else:
                    in_string = False
        elif ch == "'":
            in_string = True
        elif ch == ",":
            indices.append(i)
        i += 1
    return indices


def _wrap_fortran_line(line, limit=_MAX_LINE):
    """Wrap one generated line to at most *limit* columns.

    Code lines break only after a comma (an argument boundary) and
    use the free-form continuation marker ``&``; comment lines are
    re-flowed as further comment lines, with no ``&``.
    """
    if len(line) <= limit:
        return [line]
    stripped = line.lstrip()
    indent = line[:len(line) - len(stripped)]
    if stripped.startswith("!"):
        words = stripped[1:].split()
        wrapped = []
        current = indent + "!"
        for word in words:
            candidate = current + " " + word
            if len(candidate) > limit and current.strip("! "):
                wrapped.append(current)
                current = indent + "! " + word
            else:
                current = candidate
        wrapped.append(current)
        return wrapped
    cont_indent = indent + "    "
    wrapped = []
    remaining = line
    while len(remaining) > limit:
        # Reserve space for the comma itself plus the trailing " &":
        # the kept prefix is remaining[:i+1], then " &" is appended.
        commas = [i for i in _commas_outside_quotes(remaining)
                  if i + 3 <= limit]
        if commas:
            cut = commas[-1]
            wrapped.append(remaining[:cut + 1] + " &")
            remaining = cont_indent + remaining[cut + 1:].lstrip()
            continue
        spaces = [i for i, ch in enumerate(remaining)
                  if ch == " " and cont_indent != remaining[:i]
                  and i + 2 <= limit
                  and "'" not in remaining[:i]]
        if spaces:
            cut = spaces[-1]
            wrapped.append(remaining[:cut] + " &")
            remaining = cont_indent + remaining[cut + 1:].lstrip()
            continue
        # Only reachable inside an over-long string literal: Fortran
        # string continuation needs '&' at both ends of the break.
        wrapped.append(remaining[:limit - 1] + "&")
        remaining = cont_indent + "&" + remaining[limit - 1:]
    wrapped.append(remaining)
    return wrapped


def _wrap_fortran_lines(lines, limit=_MAX_LINE):
    wrapped = []
    for line in lines:
        wrapped.extend(_wrap_fortran_line(line, limit))
    return wrapped


def emit_fortran_program(ir) -> str:
    """Serialise *ir* to a standalone Fortran program (frame 0 only)."""
    name = _program_name(ir)
    width = int(_get(ir, "width", default=640))
    height = int(_get(ir, "height", default=480))
    bg = _color_ints(_get(ir, "bg", "background", default=(25, 25, 35)))
    if bg is None:
        bg = (25, 25, 35)
    camera = _get(ir, "camera", default=None)
    cam_pos = _vec3(_get(camera, "pos", "position", default=(3, 2.5, 4)))
    cam_target = _vec3(_get(camera, "target", default=(0, 0, 0)))
    cam_up = _vec3(_get(camera, "up", default=(0, 1, 0)))
    aspect = (width / height) if height else 1.0

    light_dir = (-0.5, -1.0, -0.7)
    for light in (_get(ir, "lights", default=[]) or []):
        if str(_get(light, "kind", default="directional")).lower() \
                != "ambient":
            light_dir = _vec3(
                _get(light, "direction", "dir", default=light_dir),
                light_dir)
            break

    out = []
    out.extend(_stamp(ir, "!"))
    out.append("! Static frame 0 only: animation is rendered via the")
    out.append("! .scene path (emit_scene_text / scene.f90 frame loop),")
    out.append("! not by this generated program.")
    out.append("program %s" % name)
    out.append("    use math_3d")
    out.append("    use mesh_3d")
    out.append("    use camera_3d")
    out.append("    use material_3d")
    out.append("    use renderer_3d")
    out.append("    implicit none")
    out.append("")
    out.append("    type(Mesh) :: msh")
    out.append("    type(Camera) :: cam")
    out.append("    type(FrameBuffer) :: fb")
    out.append("    type(mat4) :: model")
    out.append("    type(Material) :: mat")
    out.append("    type(vec3) :: light_dir")
    out.append("")
    out.append("    call framebuffer_init(fb, %d, %d)" % (width, height))
    out.append("    call framebuffer_clear(fb, %d, %d, %d)" % bg)
    out.append("    call camera_init(cam, %s, %s, %s, %s, %s, %s)" % (
        _f_vec(cam_pos), _f_vec(cam_target),
        _f(_get(camera, "fov", default=60.0)), _f(aspect),
        _f(_get(camera, "near", default=0.1)),
        _f(_get(camera, "far", default=100.0))))
    if tuple(cam_up) != (0, 1, 0) and tuple(cam_up) != (0.0, 1.0, 0.0):
        out.append("    cam%%up = %s" % _f_vec(cam_up))
        out.append("    call camera_update_matrices(cam)")
    out.append("    light_dir = %s" % _f_vec(light_dir))
    out.append("")

    for obj in (_get(ir, "objects", default=[]) or []):
        obj_name = str(_get(obj, "name", default="object"))
        prim = str(_get(obj, "prim", "primitive", default="cube")).lower()
        pos = _vec3(_get(obj, "pos", "position", default=(0, 0, 0)))
        rotate = _vec3(_get(obj, "rotate", "rotation", default=(0, 0, 0)))
        scale = _vec3(_get(obj, "scale", default=(1, 1, 1)), (1, 1, 1))
        out.append("    ! object %s (%s)" % (obj_name, prim))
        if prim == "load":
            out.append("    ! loadobj %s is loaded by the .scene path "
                       "(scene.f90 / obj_loader); skipped here"
                       % (_get(obj, "source_file", "path", default="")
                          or "model.obj"))
            out.append("")
            continue
        if prim == "tris":
            tris = _triangles(obj)
            out.append("    if (allocated(msh%triangles)) "
                       "deallocate(msh%triangles)")
            out.append("    msh%%num_triangles = %d" % len(tris))
            out.append("    allocate(msh%%triangles(%d))" % len(tris))
            for index, (tri_color, points) in enumerate(tris, start=1):
                verts = ", ".join(_f_vec(p) for p in points)
                out.append("    msh%%triangles(%d)%%v = [%s]"
                           % (index, verts))
                out.append("    msh%%triangles(%d)%%color = [%d, %d, %d]"
                           % (index, tri_color[0], tri_color[1],
                              tri_color[2]))
                out.append(
                    "    msh%%triangles(%d)%%normal = "
                    "compute_triangle_normal(msh%%triangles(%d)%%v(1), "
                    "msh%%triangles(%d)%%v(2), msh%%triangles(%d)%%v(3))"
                    % (index, index, index, index))
        else:
            build = _build_call(obj)
            if build is None:
                out.append("    ! unknown primitive '%s': cube fallback"
                           % prim)
                build = "call create_cube(msh, %s)" % _f(
                    _scalar(_get(obj, "size")) or 2.0)
            out.append("    " + build)
        if _material_needs_palette_comment(obj):
            out.append("    ! palette colour cannot show through "
                       "basic/phong (use_tri_color=.false.): white used")
        out.append("    mat = %s" % _material_call(obj))
        out.append("    model = mat4_compose_trs(%s, %s, %s)" % (
            _f_vec(pos), _f_vec(rotate), _f_vec(scale)))
        out.append("    call framebuffer_render_mesh_mat(fb, msh, model, "
                   "cam, light_dir, mat)")
        out.append("")

    out.append("    call framebuffer_save_ppm(fb, %s)"
               % _f_str(_output_path(ir)))
    out.append("end program %s" % name)
    return "\n".join(_wrap_fortran_lines(out)) + "\n"


# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------

def emit_scene(ir) -> str:
    """Alias for :func:`emit_scene_text`."""
    return emit_scene_text(ir)


def emit_fortran(ir) -> str:
    """Alias for :func:`emit_fortran_program`."""
    return emit_fortran_program(ir)
