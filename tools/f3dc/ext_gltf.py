"""Forge3D Wave B glTF/GLB import (MASTER-PLAN row 19, P15 v2, P26).

Stdlib only (``base64``, ``json``, ``os``, ``struct``, ``urllib``).

This module is the compiler-side loader behind the *existing* DSL line::

    load "model.gltf"

The ``load`` line is the same one used for OBJ files -- the format is
selected by the file extension (``.gltf`` / ``.glb``), it is not a new
API.  :func:`load_gltf` converts a glTF 2.0 asset into a flat,
format-neutral list of coloured triangles, and
:func:`triangles_to_tris_lines` renders that list in the frozen
``.scene`` ``tris`` / ``tri`` format that ``src/scene.f90`` already
parses.  No other part of the compiler needs to know glTF exists.

Coordinate system: glTF is right-handed and Y-up, and so is Forge3D,
so **no axis conversion is performed** -- vertex coordinates are
carried through unchanged (after node transforms).

Winding conversion: glTF front faces are counter-clockwise (CCW),
but the Forge3D rasteriser's screen-space winding cull keeps only
triangles whose screen-projected winding matches the engine's own
(far-side) winding convention -- the convention all engine
primitives and the OBJ import path effectively use, which is the
opposite of glTF's CCW front faces.  A glTF triangle emitted
unchanged would therefore be culled and render zero pixels.  To
make glTF content visible in the engine, :func:`load_gltf` swaps
the 2nd and 3rd vertices of every converted triangle -- each
triangle ``(v1, v2, v3)`` is output as ``(v1, v3, v2)``.  Only the
vertex order changes; positions, colours and counts are unaffected.

Public API (frozen for Wave B seat B63)::

    GltfError
    load_gltf(path) -> {"triangles": [...], "count": int}
    triangles_to_tris_lines(name, data) -> list[str]

Each triangle is ``(color_rgb_tuple_0_255, [(x, y, z), (x, y, z),
(x, y, z)])`` with vertices in world space (node transforms applied).

Supported subset -- anything outside it raises :class:`GltfError`
(a ``ValueError`` subclass) with a clear message; nothing is silently
dropped and no bare exception type escapes:

* ``.gltf`` JSON with buffers from ``data:`` base64 URIs or external
  relative files, and binary ``.glb`` (``glTF`` magic, JSON + BIN
  chunks);
* accessors / bufferViews for ``POSITION`` (float32 ``VEC3``, honouring
  ``byteStride``), indices (uint8 / uint16 / uint32, or non-indexed
  sequential order) and ``COLOR_0`` (float ``VEC3``/``VEC4`` or
  normalised uint8 / uint16 ``VEC3``/``VEC4``).  ``NORMAL`` is ignored;
* per-vertex ``COLOR_0`` averaged to a per-triangle RGB colour, else
  the primitive material's ``baseColorFactor``, else white
  (255, 255, 255);
* primitives with mode 4 (TRIANGLES) only;
* nodes with translation / rotation (quaternion) / scale or a
  column-major ``matrix``, composed through the scene parent chain;
* multiple meshes and primitives, concatenated in scene order.

Limits (MASTER-PLAN P26): the input file must be at most 64 MB and
the asset must contain at most 500,000 triangles.
"""

import base64
import binascii
import json
import os
import struct
from urllib.parse import unquote

__all__ = [
    "GltfError",
    "MAX_FILE_BYTES",
    "MAX_TRIANGLES",
    "load_gltf",
    "triangles_to_tris_lines",
]

MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_TRIANGLES = 500_000

# glTF accessor component types: id -> (struct format char, byte size).
_COMPONENTS = {
    5120: ("b", 1),  # BYTE
    5121: ("B", 1),  # UNSIGNED_BYTE
    5122: ("h", 2),  # SHORT
    5123: ("H", 2),  # UNSIGNED_SHORT
    5125: ("I", 4),  # UNSIGNED_INT
    5126: ("f", 4),  # FLOAT
}

# glTF accessor types: name -> number of components.
_TYPE_COMPONENTS = {
    "SCALAR": 1,
    "VEC2": 2,
    "VEC3": 3,
    "VEC4": 4,
    "MAT2": 4,
    "MAT3": 9,
    "MAT4": 16,
}

_GLTF_MAGIC = b"glTF"
_GLB_VERSION = 2
_CHUNK_JSON = 0x4E4F534A  # 'JSON'
_CHUNK_BIN = 0x004E4942   # 'BIN\0'


class GltfError(ValueError):
    """Raised for any unsupported or malformed glTF/GLB input."""


# ------------------------------------------------------------------ helpers

def _fail(message):
    raise GltfError(message)


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _require_list(doc, key, required=False):
    value = doc.get(key)
    if value is None:
        if required:
            _fail("glTF document is missing required %r array" % key)
        return []
    if not isinstance(value, list):
        _fail("glTF %r must be an array" % key)
    return value


def _require_index(value, length, what):
    if not _is_int(value) or not (0 <= value < length):
        _fail("%s index %r is out of range (valid: 0..%d)"
              % (what, value, length - 1))
    return value


def _fmt_float(value):
    return "%.6g" % float(value)


# ------------------------------------------------------------------ matrices
# Matrices are held internally as 4x4 row-major tuples of tuples and
# multiply column vectors: world_point = M * (x, y, z, 1).

_IDENTITY = (
    (1.0, 0.0, 0.0, 0.0),
    (0.0, 1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0, 0.0),
    (0.0, 0.0, 0.0, 1.0),
)


def _mat_mul(a, b):
    """Return ``a * b`` (apply ``b`` first, then ``a``)."""
    return tuple(
        tuple(
            a[row][0] * b[0][col]
            + a[row][1] * b[1][col]
            + a[row][2] * b[2][col]
            + a[row][3] * b[3][col]
            for col in range(4)
        )
        for row in range(4)
    )


def _mat_apply(m, point):
    x, y, z = point
    out = [
        m[row][0] * x + m[row][1] * y + m[row][2] * z + m[row][3]
        for row in range(4)
    ]
    w = out[3]
    if w not in (0.0, 1.0):
        return (out[0] / w, out[1] / w, out[2] / w)
    return (out[0], out[1], out[2])


def _node_local_matrix(node, index):
    """Local transform for one node (column-major matrix, or TRS)."""
    if "matrix" in node and node["matrix"] is not None:
        raw = node["matrix"]
        if (not isinstance(raw, list) or len(raw) != 16
                or not all(_is_number(v) for v in raw)):
            _fail("node %d 'matrix' must be 16 numbers (column-major)"
                  % index)
        vals = [float(v) for v in raw]
        # Column-major input -> row-major internal storage:
        # internal[row][col] == vals[col * 4 + row].
        return tuple(
            tuple(vals[col * 4 + row] for col in range(4))
            for row in range(4)
        )

    translation = node.get("translation", [0.0, 0.0, 0.0])
    rotation = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
    scale = node.get("scale", [1.0, 1.0, 1.0])
    for key, value, want in (("translation", translation, 3),
                             ("rotation", rotation, 4),
                             ("scale", scale, 3)):
        if (not isinstance(value, list) or len(value) != want
                or not all(_is_number(v) for v in value)):
            _fail("node %d %r must be %d numbers" % (index, key, want))
    tx, ty, tz = (float(v) for v in translation)
    qx, qy, qz, qw = (float(v) for v in rotation)
    sx, sy, sz = (float(v) for v in scale)

    # Rotation matrix from a (possibly unnormalised) quaternion.
    norm = qx * qx + qy * qy + qz * qz + qw * qw
    if norm == 0.0:
        _fail("node %d rotation quaternion has zero length" % index)
    s = 2.0 / norm
    xx, yy, zz = qx * qx * s, qy * qy * s, qz * qz * s
    xy, xz, yz = qx * qy * s, qx * qz * s, qy * qz * s
    wx, wy, wz = qw * qx * s, qw * qy * s, qw * qz * s
    rot = (
        (1.0 - (yy + zz), xy - wz, xz + wy),
        (xy + wz, 1.0 - (xx + zz), yz - wx),
        (xz - wy, yz + wx, 1.0 - (xx + yy)),
    )
    # Local = T * R * S.
    return tuple(
        tuple(rot[row][col] * (sx, sy, sz)[col] for col in range(3))
        + ((tx, ty, tz)[row],)
        for row in range(3)
    ) + ((0.0, 0.0, 0.0, 1.0),)


# ------------------------------------------------------------------ buffers

def _read_file_bytes(path):
    """Read the top-level .gltf/.glb file, enforcing the size limit."""
    try:
        size = os.path.getsize(path)
    except FileNotFoundError:
        _fail("glTF file not found: %s" % path)
    except OSError as exc:
        _fail("cannot read glTF file %s: %s" % (path, exc))
    if size > MAX_FILE_BYTES:
        _fail("glTF file %s is %d bytes, exceeding the 64 MB limit"
              % (path, size))
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except FileNotFoundError:
        _fail("glTF file not found: %s" % path)
    except OSError as exc:
        _fail("cannot read glTF file %s: %s" % (path, exc))


def _load_external_buffer(uri, base_dir, declared_length):
    """Load an external relative buffer file resolved from ``base_dir``."""
    rel = unquote(uri)
    if os.path.isabs(rel):
        _fail("buffer URI %r is absolute; only relative buffer files "
              "are supported" % uri)
    full = os.path.normpath(os.path.join(base_dir, rel))
    try:
        size = os.path.getsize(full)
    except FileNotFoundError:
        _fail("buffer file not found: %s (referenced as %r)"
              % (full, uri))
    except OSError as exc:
        _fail("cannot read buffer file %s: %s" % (full, exc))
    if size > MAX_FILE_BYTES:
        _fail("buffer file %s is %d bytes, exceeding the 64 MB limit"
              % (full, size))
    try:
        with open(full, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        _fail("cannot read buffer file %s: %s" % (full, exc))
    if declared_length is not None and len(data) < declared_length:
        _fail("buffer file %s is %d bytes but the buffer declares %d"
              % (full, len(data), declared_length))
    return data


def _decode_data_uri(uri):
    """Decode a ``data:...;base64,...`` buffer URI."""
    header, sep, payload = uri.partition(",")
    if not sep or ";base64" not in header.lower():
        _fail("unsupported buffer data URI %r: only base64 data URIs "
              "are supported" % uri[:64])
    try:
        return base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError) as exc:
        _fail("invalid base64 in buffer data URI: %s" % exc)


def _resolve_buffers(doc, base_dir, glb_bin):
    """Return the raw bytes for every entry in ``doc['buffers']``."""
    buffer_defs = _require_list(doc, "buffers")
    buffers = []
    for i, entry in enumerate(buffer_defs):
        if not isinstance(entry, dict):
            _fail("buffer %d must be an object" % i)
        byte_length = entry.get("byteLength")
        if byte_length is not None and (not _is_int(byte_length)
                                        or byte_length < 0):
            _fail("buffer %d 'byteLength' must be a non-negative integer"
                  % i)
        uri = entry.get("uri")
        if uri is None:
            if glb_bin is None:
                _fail("buffer %d has no 'uri' and the file has no GLB "
                      "BIN chunk" % i)
            if i != 0:
                _fail("buffer %d has no 'uri'; only the first GLB "
                      "buffer may omit it" % i)
            data = glb_bin
        elif isinstance(uri, str) and uri.startswith("data:"):
            data = _decode_data_uri(uri)
        elif isinstance(uri, str) and uri:
            data = _load_external_buffer(uri, base_dir, byte_length)
        else:
            _fail("buffer %d has an invalid 'uri'" % i)
        if byte_length is not None and len(data) < byte_length:
            _fail("buffer %d declares %d bytes but only %d are available"
                  % (i, byte_length, len(data)))
        buffers.append(data[:byte_length] if byte_length is not None
                       else data)
    return buffers


# ------------------------------------------------------------------ accessors

def _read_accessor(doc, buffers, index, what):
    """Read one accessor as a list of component tuples (raw values).

    Honours the bufferView ``byteStride`` for interleaved data and the
    accessor's own ``byteOffset``.  Bounds are checked against both the
    bufferView and the underlying buffer; any overrun is a GltfError
    (this is what turns an oversized accessor count into an error
    rather than a crash or a silent truncation).
    """
    accessors = _require_list(doc, "accessors", required=True)
    _require_index(index, len(accessors), "%s accessor" % what)
    accessor = accessors[index]
    if not isinstance(accessor, dict):
        _fail("%s accessor %d must be an object" % (what, index))
    if "sparse" in accessor:
        _fail("%s accessor %d uses sparse storage, which is not "
              "supported" % (what, index))
    if "bufferView" not in accessor:
        _fail("%s accessor %d has no 'bufferView'" % (what, index))

    views = _require_list(doc, "bufferViews", required=True)
    view_index = accessor["bufferView"]
    _require_index(view_index, len(views), "bufferView")
    view = views[view_index]
    if not isinstance(view, dict):
        _fail("bufferView %d must be an object" % view_index)

    buffer_index = view.get("buffer", 0)
    _require_index(buffer_index, len(buffers), "buffer")
    data = buffers[buffer_index]

    component_type = accessor.get("componentType")
    if component_type not in _COMPONENTS:
        _fail("%s accessor %d has unsupported componentType %r"
              % (what, index, component_type))
    fmt_char, component_size = _COMPONENTS[component_type]

    type_name = accessor.get("type")
    if type_name not in _TYPE_COMPONENTS:
        _fail("%s accessor %d has unsupported type %r"
              % (what, index, type_name))
    num_components = _TYPE_COMPONENTS[type_name]

    count = accessor.get("count")
    if not _is_int(count) or count < 0:
        _fail("%s accessor %d 'count' must be a non-negative integer"
              % (what, index))

    view_offset = view.get("byteOffset", 0)
    view_length = view.get("byteLength")
    accessor_offset = accessor.get("byteOffset", 0)
    for key, value in (("bufferView byteOffset", view_offset),
                       ("bufferView byteLength", view_length),
                       ("accessor byteOffset", accessor_offset)):
        if value is not None and (not _is_int(value) or value < 0):
            _fail("%s must be a non-negative integer" % key)
    if view_length is None:
        view_length = len(data) - view_offset
    if view_offset + view_length > len(data):
        _fail("bufferView %d extends past its buffer (%d + %d > %d)"
              % (view_index, view_offset, view_length, len(data)))

    element_size = component_size * num_components
    stride = view.get("byteStride")
    if stride is None:
        stride = element_size
    elif not _is_int(stride) or stride < element_size:
        _fail("bufferView %d byteStride %r is smaller than one element "
              "(%d bytes)" % (view_index, stride, element_size))

    if count > 0:
        needed = accessor_offset + (count - 1) * stride + element_size
        if needed > view_length:
            _fail("%s accessor %d declares %d elements but its "
                  "bufferView holds only %d bytes (needs %d)"
                  % (what, index, count, view_length, needed))

    unpack = struct.Struct("<" + fmt_char * num_components).unpack_from
    base = view_offset + accessor_offset
    return [unpack(data, base + i * stride) for i in range(count)]


# ------------------------------------------------------------------ colours

def _clamp01(value):
    return 0.0 if value < 0.0 else (1.0 if value > 1.0 else value)


def _to_byte(value):
    return int(round(_clamp01(float(value)) * 255.0))


def _material_colour(doc, primitive):
    """Base colour for a primitive from its material (default white)."""
    material_index = primitive.get("material")
    if material_index is None:
        return (255, 255, 255)
    materials = _require_list(doc, "materials")
    _require_index(material_index, len(materials), "material")
    material = materials[material_index]
    if not isinstance(material, dict):
        _fail("material %d must be an object" % material_index)
    pbr = material.get("pbrMetallicRoughness")
    if pbr is None:
        return (255, 255, 255)
    if not isinstance(pbr, dict):
        _fail("material %d 'pbrMetallicRoughness' must be an object"
              % material_index)
    factor = pbr.get("baseColorFactor")
    if factor is None:
        return (255, 255, 255)
    if (not isinstance(factor, list) or len(factor) not in (3, 4)
            or not all(_is_number(v) for v in factor)):
        _fail("material %d 'baseColorFactor' must be 3 or 4 numbers"
              % material_index)
    return tuple(_to_byte(v) for v in factor[:3])


def _read_vertex_colours(doc, buffers, accessor_index):
    """Read COLOR_0 as a list of (r, g, b) float tuples in 0..1."""
    accessors = _require_list(doc, "accessors", required=True)
    _require_index(accessor_index, len(accessors), "COLOR_0 accessor")
    accessor = accessors[accessor_index]
    if not isinstance(accessor, dict):
        _fail("COLOR_0 accessor %d must be an object" % accessor_index)
    component_type = accessor.get("componentType")
    type_name = accessor.get("type")
    if type_name not in ("VEC3", "VEC4"):
        _fail("COLOR_0 accessor %d must be VEC3 or VEC4, got %r"
              % (accessor_index, type_name))
    raw = _read_accessor(doc, buffers, accessor_index, "COLOR_0")
    colours = []
    if component_type == 5126:  # float
        for entry in raw:
            colours.append(tuple(_clamp01(float(v)) for v in entry[:3]))
    elif component_type == 5121:  # uint8, normalised
        for entry in raw:
            colours.append(tuple(v / 255.0 for v in entry[:3]))
    elif component_type == 5123:  # uint16, normalised
        for entry in raw:
            colours.append(tuple(v / 65535.0 for v in entry[:3]))
    else:
        _fail("COLOR_0 accessor %d has unsupported componentType %r "
              "(expected float, uint8 or uint16)"
              % (accessor_index, component_type))
    return colours


def _average_colour(vertex_colours):
    """Average three per-vertex 0..1 colours to one RGB 0..255 tuple."""
    return tuple(
        int(round(sum(c[channel] for c in vertex_colours) / 3.0 * 255.0))
        for channel in range(3)
    )


# ------------------------------------------------------------------ primitives

def _primitive_triangles(doc, buffers, primitive, mesh_index,
                         prim_index, world):
    """Triangles (world space) for one mesh primitive."""
    if not isinstance(primitive, dict):
        _fail("mesh %d primitive %d must be an object"
              % (mesh_index, prim_index))
    mode = primitive.get("mode", 4)
    if mode != 4:
        _fail("mesh %d primitive %d has mode %r; only mode 4 "
              "(TRIANGLES) is supported" % (mesh_index, prim_index, mode))
    attributes = primitive.get("attributes")
    if not isinstance(attributes, dict):
        _fail("mesh %d primitive %d has no 'attributes' object"
              % (mesh_index, prim_index))
    if "POSITION" not in attributes:
        _fail("mesh %d primitive %d has no POSITION attribute"
              % (mesh_index, prim_index))

    raw_positions = _read_accessor(
        doc, buffers, attributes["POSITION"], "POSITION")
    positions = []
    for entry in raw_positions:
        if len(entry) != 3:
            _fail("POSITION accessor must be VEC3")
        positions.append((float(entry[0]), float(entry[1]),
                          float(entry[2])))
    # The accessor reader already enforces VEC3 via its type table for
    # well-formed files, but a POSITION declared with another type
    # would surface here as the wrong tuple width; reject it plainly.
    pos_accessor = _require_list(doc, "accessors", required=True)[
        attributes["POSITION"]]
    if isinstance(pos_accessor, dict) and pos_accessor.get("type") != "VEC3":
        _fail("POSITION accessor must be VEC3, got %r"
              % (pos_accessor.get("type"),))
    if isinstance(pos_accessor, dict) \
            and pos_accessor.get("componentType") != 5126:
        _fail("POSITION accessor must be float32 (componentType 5126), "
              "got %r" % (pos_accessor.get("componentType"),))

    if "indices" in primitive and primitive["indices"] is not None:
        index_accessor = _require_list(doc, "accessors", required=True)
        idx_pos = primitive["indices"]
        _require_index(idx_pos, len(index_accessor), "indices accessor")
        idx_def = index_accessor[idx_pos]
        if not isinstance(idx_def, dict) \
                or idx_def.get("componentType") not in (5121, 5123, 5125) \
                or idx_def.get("type") != "SCALAR":
            _fail("indices accessor %d must be SCALAR with componentType "
                  "5121, 5123 or 5125" % (idx_pos,))
        raw_indices = _read_accessor(doc, buffers, idx_pos, "indices")
        indices = [int(entry[0]) for entry in raw_indices]
        if len(indices) % 3 != 0:
            _fail("mesh %d primitive %d index count %d is not a "
                  "multiple of 3" % (mesh_index, prim_index, len(indices)))
    else:
        if len(positions) % 3 != 0:
            _fail("mesh %d primitive %d has %d non-indexed vertices, "
                  "not a multiple of 3"
                  % (mesh_index, prim_index, len(positions)))
        indices = list(range(len(positions)))

    if "COLOR_0" in attributes and attributes["COLOR_0"] is not None:
        vertex_colours = _read_vertex_colours(
            doc, buffers, attributes["COLOR_0"])
        if len(vertex_colours) != len(positions):
            _fail("mesh %d primitive %d COLOR_0 count %d does not match "
                  "POSITION count %d"
                  % (mesh_index, prim_index, len(vertex_colours),
                     len(positions)))
        flat_colour = None
    else:
        vertex_colours = None
        flat_colour = _material_colour(doc, primitive)

    triangles = []
    for start in range(0, len(indices), 3):
        tri_indices = indices[start:start + 3]
        for vertex_index in tri_indices:
            if not (0 <= vertex_index < len(positions)):
                _fail("mesh %d primitive %d references vertex %d but "
                      "POSITION has only %d vertices"
                      % (mesh_index, prim_index, vertex_index,
                         len(positions)))
        verts = [_mat_apply(world, positions[i]) for i in tri_indices]
        # Winding conversion (see module docstring): glTF front faces
        # are CCW, but the Forge3D rasteriser's winding cull keeps the
        # opposite (engine) convention, so swap v2 <-> v3 to emit
        # (v1, v3, v2) and make the triangle visible in the engine.
        verts = [verts[0], verts[2], verts[1]]
        if vertex_colours is not None:
            colour = _average_colour(
                [vertex_colours[i] for i in tri_indices])
        else:
            colour = flat_colour
        triangles.append((colour, verts))
    return triangles


# ------------------------------------------------------------------ parsing

def _parse_glb(raw, path):
    """Split GLB bytes into (json_doc, bin_chunk_or_None)."""
    if len(raw) < 12:
        _fail("GLB file %s is too short (%d bytes) to hold a header"
              % (path, len(raw)))
    magic, version, total_length = struct.unpack_from("<4sII", raw, 0)
    if magic != _GLTF_MAGIC:
        _fail("GLB file %s has bad magic %r (expected b'glTF')"
              % (path, magic))
    if version != _GLB_VERSION:
        _fail("GLB file %s has version %d; only glTF version 2 is "
              "supported" % (path, version))
    if total_length > len(raw):
        _fail("GLB file %s declares %d bytes but the file is %d bytes"
              % (path, total_length, len(raw)))

    offset = 12
    json_doc = None
    bin_chunk = None
    first_chunk = True
    while offset < total_length:
        if offset + 8 > total_length:
            _fail("GLB file %s has a truncated chunk header at byte %d"
                  % (path, offset))
        chunk_length, chunk_type = struct.unpack_from("<II", raw, offset)
        offset += 8
        if offset + chunk_length > total_length:
            _fail("GLB file %s has a truncated chunk at byte %d"
                  % (path, offset - 8))
        chunk = raw[offset:offset + chunk_length]
        offset += chunk_length
        if first_chunk and chunk_type != _CHUNK_JSON:
            _fail("GLB file %s first chunk is not the JSON chunk"
                  % path)
        first_chunk = False
        if chunk_type == _CHUNK_JSON:
            if json_doc is not None:
                _fail("GLB file %s has more than one JSON chunk" % path)
            try:
                # JSON chunks are space-padded to 4 bytes; tolerate
                # NUL padding from sloppy exporters too.
                json_doc = json.loads(
                    chunk.decode("utf-8").rstrip(" \t\r\n\x00"))
            except (UnicodeDecodeError, ValueError) as exc:
                _fail("GLB file %s has invalid JSON chunk: %s"
                      % (path, exc))
        elif chunk_type == _CHUNK_BIN:
            if bin_chunk is not None:
                _fail("GLB file %s has more than one BIN chunk" % path)
            bin_chunk = chunk
        # Unknown chunk types are extension chunks; glTF requires
        # readers to skip them, and they carry no geometry.
    if json_doc is None:
        _fail("GLB file %s has no JSON chunk" % path)
    if not isinstance(json_doc, dict):
        _fail("GLB file %s JSON chunk is not an object" % path)
    return json_doc, bin_chunk


def _parse_gltf_json(raw, path):
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail("glTF file %s is not valid UTF-8: %s" % (path, exc))
    try:
        doc = json.loads(text)
    except ValueError as exc:
        _fail("glTF file %s is not valid JSON: %s" % (path, exc))
    if not isinstance(doc, dict):
        _fail("glTF file %s JSON root is not an object" % path)
    return doc


def _check_asset(doc):
    asset = doc.get("asset")
    if asset is not None:
        if not isinstance(asset, dict):
            _fail("glTF 'asset' must be an object")
        version = asset.get("version")
        if version is not None and str(version) not in ("2.0", "2"):
            _fail("unsupported glTF asset version %r (only 2.0 is "
                  "supported)" % (version,))


# ------------------------------------------------------------------ public API

def load_gltf(path):
    """Load a ``.gltf`` / ``.glb`` file as flat coloured triangles.

    ``path`` is a filesystem path (``str`` or path-like).  Returns::

        {"triangles": [( (r, g, b), [(x, y, z), (x, y, z), (x, y, z)] ),
                        ...],
         "count": <number of triangles>}

    Vertices are in world space (scene node transforms applied) and in
    glTF's own right-handed Y-up coordinates -- identical to Forge3D's,
    so no axis conversion is done.  Raises :class:`GltfError` on any
    unsupported or malformed input, on a missing file, on a file over
    64 MB, and on an asset with more than 500,000 triangles.
    """
    path = os.fspath(path) if not isinstance(path, str) else path
    suffix = os.path.splitext(path)[1].lower()
    if suffix not in (".gltf", ".glb"):
        _fail("unsupported file extension %r for %s: only .gltf and "
              ".glb are supported" % (suffix or "(none)", path))

    raw = _read_file_bytes(path)
    base_dir = os.path.dirname(os.path.abspath(path))

    if suffix == ".glb":
        doc, glb_bin = _parse_glb(raw, path)
    else:
        doc, glb_bin = _parse_gltf_json(raw, path), None
    _check_asset(doc)

    buffers = _resolve_buffers(doc, base_dir, glb_bin)
    meshes = _require_list(doc, "meshes", required=True)
    if not meshes:
        _fail("glTF file %s contains no meshes" % path)
    nodes = _require_list(doc, "nodes")

    triangles = []

    def add_mesh(mesh_index, world):
        _require_index(mesh_index, len(meshes), "mesh")
        mesh = meshes[mesh_index]
        if not isinstance(mesh, dict):
            _fail("mesh %d must be an object" % mesh_index)
        primitives = mesh.get("primitives")
        if not isinstance(primitives, list) or not primitives:
            _fail("mesh %d has no 'primitives' array" % mesh_index)
        for prim_index, primitive in enumerate(primitives):
            new = _primitive_triangles(
                doc, buffers, primitive, mesh_index, prim_index, world)
            if len(triangles) + len(new) > MAX_TRIANGLES:
                _fail("glTF file %s exceeds the %d triangle limit"
                      % (path, MAX_TRIANGLES))
            triangles.extend(new)

    if nodes:
        scenes = _require_list(doc, "scenes")
        if scenes:
            scene_index = doc.get("scene", 0)
            _require_index(scene_index, len(scenes), "scene")
            scene = scenes[scene_index]
            if not isinstance(scene, dict):
                _fail("scene %d must be an object" % scene_index)
            roots = scene.get("nodes", [])
            if not isinstance(roots, list):
                _fail("scene %d 'nodes' must be an array" % scene_index)
        else:
            # No scene table: every node that is nobody's child is a root.
            child_set = set()
            for node in nodes:
                if isinstance(node, dict):
                    for child in node.get("children", []) or []:
                        if _is_int(child):
                            child_set.add(child)
            roots = [i for i in range(len(nodes)) if i not in child_set]

        def visit(node_index, parent_world, stack):
            _require_index(node_index, len(nodes), "node")
            if node_index in stack:
                _fail("node graph contains a cycle at node %d"
                      % node_index)
            node = nodes[node_index]
            if not isinstance(node, dict):
                _fail("node %d must be an object" % node_index)
            world = _mat_mul(parent_world,
                             _node_local_matrix(node, node_index))
            if "mesh" in node and node["mesh"] is not None:
                add_mesh(node["mesh"], world)
            children = node.get("children", [])
            if children is None:
                children = []
            if not isinstance(children, list):
                _fail("node %d 'children' must be an array" % node_index)
            stack = stack | {node_index}
            for child in children:
                visit(child, world, stack)

        for root in roots:
            if not _is_int(root):
                _fail("scene node reference %r is not an integer" % (root,))
            visit(root, _IDENTITY, frozenset())
    else:
        # No node graph at all: meshes stand alone at the origin.
        for mesh_index in range(len(meshes)):
            add_mesh(mesh_index, _IDENTITY)

    if not triangles:
        _fail("glTF file %s contains no triangles" % path)
    return {"triangles": triangles, "count": len(triangles)}


def triangles_to_tris_lines(name, data):
    """Render loaded triangles in the frozen ``.scene`` tris format.

    ``data`` is a dict as returned by :func:`load_gltf`.  Returns::

        ["tris NAME COUNT",
         "tri R G B x1 y1 z1 x2 y2 z2 x3 y3 z3", ...]

    with coordinates formatted ``%.6g`` -- exactly the format
    ``src/scene.f90`` parses.  Raises :class:`GltfError` if ``data``
    does not carry a usable triangle list.
    """
    if not isinstance(data, dict) or "triangles" not in data:
        _fail("triangles_to_tris_lines: data must be a dict with a "
              "'triangles' list (as returned by load_gltf)")
    triangles = data["triangles"]
    if not isinstance(triangles, list):
        _fail("triangles_to_tris_lines: 'triangles' must be a list")
    lines = ["tris %s %d" % (name, len(triangles))]
    for i, triangle in enumerate(triangles):
        try:
            colour, verts = triangle
            red, green, blue = (int(c) for c in colour)
            coords = [float(v) for vert in verts for v in vert]
        except (TypeError, ValueError) as exc:
            _fail("triangles_to_tris_lines: triangle %d is malformed: "
                  "%s" % (i, exc))
        if len(coords) != 9:
            _fail("triangles_to_tris_lines: triangle %d does not have "
                  "3 vertices" % i)
        lines.append(
            "tri %d %d %d %s"
            % (red, green, blue,
               " ".join(_fmt_float(c) for c in coords)))
    return lines
