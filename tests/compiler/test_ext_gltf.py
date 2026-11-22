#!/usr/bin/env python3
"""Tests for the Forge3D Wave B glTF extension (ext_gltf.py).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_ext_gltf.py
    python3 -m unittest tests.compiler.test_ext_gltf

All fixtures are built in code (``struct`` / ``base64`` / ``json``)
and written to a fresh temporary directory per test.
"""

import base64
import json
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__)))),
        "tools", "f3dc",
    ),
)

import ext_gltf  # noqa: E402
from ext_gltf import GltfError, load_gltf, triangles_to_tris_lines  # noqa: E402

TRI_POSITIONS = [0.0, 0.0, 0.0,
                 1.0, 0.0, 0.0,
                 0.0, 1.0, 0.0]
# Expected load_gltf output for TRI_POSITIONS: the winding conversion
# swaps the 2nd and 3rd vertices, so (v1, v2, v3) comes out (v1, v3, v2).
TRI_VERTS = [(0.0, 0.0, 0.0), (0.0, 1.0, 0.0), (1.0, 0.0, 0.0)]


def _pad4(data):
    return data + b"\x00" * (-len(data) % 4)


def build_gltf(positions, indices=None, colors=None,
               color_component=5126, color_type="VEC3",
               mode=4, material=None, materials=None, nodes=None,
               position_count=None):
    """Assemble (gltf_dict, buffer_bytes) from flat Python lists.

    Segments are laid out positions | indices | colors, each padded
    to a 4-byte boundary. ``position_count`` overrides the POSITION
    accessor count (for the oversized-accessor error test).
    """
    buffer = b""
    views = []
    accessors = []

    def add_segment(data, target):
        nonlocal buffer
        offset = len(buffer)
        views.append({"buffer": 0, "byteOffset": offset,
                      "byteLength": len(data), "target": target})
        buffer = _pad4(buffer + data)
        return len(views) - 1

    pos_view = add_segment(struct.pack("<%df" % len(positions), *positions),
                           34962)
    accessors.append({
        "bufferView": pos_view, "componentType": 5126, "type": "VEC3",
        "count": (len(positions) // 3 if position_count is None
                  else position_count),
    })
    attributes = {"POSITION": 0}
    primitive = {"attributes": attributes, "mode": mode}

    if indices is not None:
        if max(indices) > 65535:
            fmt, comp = "<%dI", 5125
        elif max(indices) > 255:
            fmt, comp = "<%dH", 5123
        else:
            fmt, comp = "<%dH", 5123
        idx_view = add_segment(
            struct.pack(fmt % len(indices), *indices), 34963)
        accessors.append({"bufferView": idx_view, "componentType": comp,
                          "type": "SCALAR", "count": len(indices)})
        primitive["indices"] = len(accessors) - 1

    if colors is not None:
        if color_component == 5126:
            data = struct.pack("<%df" % len(colors), *colors)
        elif color_component == 5121:
            data = struct.pack("<%dB" % len(colors), *colors)
        elif color_component == 5123:
            data = struct.pack("<%dH" % len(colors), *colors)
        else:  # pragma: no cover - fixture builder misuse
            raise AssertionError(color_component)
        col_view = add_segment(data, 34962)
        comps = {"VEC3": 3, "VEC4": 4}[color_type]
        accessor = {"bufferView": col_view,
                    "componentType": color_component,
                    "type": color_type, "count": len(colors) // comps}
        if color_component in (5121, 5123):
            accessor["normalized"] = True
        accessors.append(accessor)
        attributes["COLOR_0"] = len(accessors) - 1

    if material is not None:
        primitive["material"] = material

    if nodes is None:
        nodes = [{"mesh": 0}]
    doc = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": [{"primitives": [primitive]}],
        "bufferViews": views,
        "accessors": accessors,
        "buffers": [{"byteLength": len(buffer)}],
    }
    if materials is not None:
        doc["materials"] = materials
    return doc, buffer


def data_uri(buffer):
    return ("data:application/octet-stream;base64,"
            + base64.b64encode(buffer).decode("ascii"))


def make_glb(doc, buffer):
    """Wrap a glTF dict + buffer bytes as a .glb byte string."""
    doc = dict(doc)
    doc["buffers"] = [{"byteLength": len(buffer)}]
    raw_json = json.dumps(doc).encode("utf-8")
    # Per the GLB spec the JSON chunk is space-padded, BIN is NUL-padded.
    json_chunk = raw_json + b" " * (-len(raw_json) % 4)
    bin_chunk = _pad4(buffer)
    total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    out = struct.pack("<4sII", b"glTF", 2, total)
    out += struct.pack("<II", len(json_chunk), 0x4E4F534A) + json_chunk
    out += struct.pack("<II", len(bin_chunk), 0x004E4942) + bin_chunk
    return out


class GltfTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name

    def write(self, name, payload):
        path = os.path.join(self.dir, name)
        mode = "wb" if isinstance(payload, bytes) else "w"
        with open(path, mode) as handle:
            handle.write(payload)
        return path

    def write_gltf(self, doc, buffer, name="model.gltf", external=False):
        doc = dict(doc)
        if external:
            self.write("buffer.bin", buffer)
            doc["buffers"] = [{"byteLength": len(buffer),
                               "uri": "buffer.bin"}]
        else:
            doc["buffers"] = [{"byteLength": len(buffer),
                               "uri": data_uri(buffer)}]
        return self.write(name, json.dumps(doc))


class TestLoadGltf(GltfTestCase):
    def test_minimal_data_uri_triangle_exact(self):
        doc, buffer = build_gltf(TRI_POSITIONS)
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["count"], 1)
        self.assertEqual(len(data["triangles"]), 1)
        colour, verts = data["triangles"][0]
        self.assertEqual(colour, (255, 255, 255))
        self.assertEqual(verts, TRI_VERTS)

    def test_winding_conversion_swaps_v2_and_v3(self):
        # Explicit winding conversion: a known single triangle with
        # distinct vertices (v1, v2, v3) must come out as (v1, v3, v2),
        # because glTF CCW front faces are opposite to the engine's
        # winding-cull convention.
        positions = [1.0, 2.0, 3.0,
                     4.0, 5.0, 6.0,
                     7.0, 8.0, 9.0]
        doc, buffer = build_gltf(positions)
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["count"], 1)
        colour, verts = data["triangles"][0]
        self.assertEqual(verts, [(1.0, 2.0, 3.0),
                                 (7.0, 8.0, 9.0),
                                 (4.0, 5.0, 6.0)])

    def test_indexed_quad_two_triangles(self):
        positions = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
                     1.0, 1.0, 0.0, 0.0, 1.0, 0.0]
        doc, buffer = build_gltf(positions, indices=[0, 1, 2, 0, 2, 3])
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["count"], 2)
        # Winding conversion: each (v1, v2, v3) comes out (v1, v3, v2).
        self.assertEqual(data["triangles"][0][1],
                         [(0.0, 0.0, 0.0), (1.0, 1.0, 0.0),
                          (1.0, 0.0, 0.0)])
        self.assertEqual(data["triangles"][1][1],
                         [(0.0, 0.0, 0.0), (0.0, 1.0, 0.0),
                          (1.0, 1.0, 0.0)])

    def test_node_trs_translation_applied(self):
        nodes = [{"mesh": 0, "translation": [10.0, 20.0, 30.0],
                  "scale": [2.0, 2.0, 2.0]}]
        doc, buffer = build_gltf(TRI_POSITIONS, nodes=nodes)
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["triangles"][0][1],
                         [(10.0, 20.0, 30.0), (10.0, 22.0, 30.0),
                          (12.0, 20.0, 30.0)])

    def test_node_matrix_applied(self):
        # Column-major translation by (5, 6, 7).
        matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 6, 7, 1]
        doc, buffer = build_gltf(
            TRI_POSITIONS, nodes=[{"mesh": 0, "matrix": matrix}])
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["triangles"][0][1],
                         [(5.0, 6.0, 7.0), (5.0, 7.0, 7.0),
                          (6.0, 6.0, 7.0)])

    def test_parent_node_transform_chain(self):
        nodes = [{"translation": [1.0, 0.0, 0.0], "children": [1]},
                 {"mesh": 0, "translation": [0.0, 2.0, 0.0]}]
        doc, buffer = build_gltf(TRI_POSITIONS, nodes=nodes)
        # build_gltf lists every node as a scene root; fix to root [0].
        doc["scenes"] = [{"nodes": [0]}]
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["count"], 1)
        self.assertEqual(data["triangles"][0][1][0], (1.0, 2.0, 0.0))

    def test_glb_round_trip_same_triangle(self):
        doc, buffer = build_gltf(TRI_POSITIONS)
        path = self.write("model.glb", make_glb(doc, buffer))
        data = load_gltf(path)
        self.assertEqual(data["count"], 1)
        self.assertEqual(data["triangles"][0], ((255, 255, 255), TRI_VERTS))

    def test_color0_float_mapping_averaged(self):
        # Pure red / green / blue vertices average to (85, 85, 85).
        colors = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
        doc, buffer = build_gltf(TRI_POSITIONS, colors=colors)
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["triangles"][0][0], (85, 85, 85))

    def test_color0_uint8_mapping(self):
        colors = [255, 0, 0, 255, 0, 0, 255, 0, 0]
        doc, buffer = build_gltf(TRI_POSITIONS, colors=colors,
                                 color_component=5121)
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["triangles"][0][0], (255, 0, 0))

    def test_material_base_color_factor(self):
        materials = [{"pbrMetallicRoughness":
                      {"baseColorFactor": [1.0, 0.5, 0.0, 1.0]}}]
        doc, buffer = build_gltf(TRI_POSITIONS, material=0,
                                 materials=materials)
        data = load_gltf(self.write_gltf(doc, buffer))
        self.assertEqual(data["triangles"][0][0], (255, 128, 0))

    def test_external_bin_buffer(self):
        doc, buffer = build_gltf(TRI_POSITIONS)
        path = self.write_gltf(doc, buffer, external=True)
        data = load_gltf(path)
        self.assertEqual(data["count"], 1)
        self.assertEqual(data["triangles"][0][1], TRI_VERTS)


class TestErrors(GltfTestCase):
    def test_gltf_error_is_value_error(self):
        self.assertTrue(issubclass(GltfError, ValueError))

    def test_missing_file(self):
        with self.assertRaises(GltfError):
            load_gltf(os.path.join(self.dir, "nope.gltf"))

    def test_bad_magic_glb(self):
        doc, buffer = build_gltf(TRI_POSITIONS)
        payload = b"XXXX" + make_glb(doc, buffer)[4:]
        with self.assertRaises(GltfError):
            load_gltf(self.write("bad.glb", payload))

    def test_mode_not_triangles(self):
        doc, buffer = build_gltf(TRI_POSITIONS, mode=1)
        with self.assertRaises(GltfError):
            load_gltf(self.write_gltf(doc, buffer))

    def test_oversized_accessor_count(self):
        # POSITION claims far more vertices than the buffer holds.
        doc, buffer = build_gltf(TRI_POSITIONS, position_count=10 ** 9)
        with self.assertRaises(GltfError):
            load_gltf(self.write_gltf(doc, buffer))

    def test_unsupported_extension(self):
        doc, buffer = build_gltf(TRI_POSITIONS)
        path = self.write_gltf(doc, buffer, name="model.obj")
        with self.assertRaises(GltfError):
            load_gltf(path)

    def test_malformed_json(self):
        path = self.write("broken.gltf", "{not json")
        with self.assertRaises(GltfError):
            load_gltf(path)

    def test_missing_external_buffer(self):
        doc, buffer = build_gltf(TRI_POSITIONS)
        doc = dict(doc)
        doc["buffers"] = [{"byteLength": len(buffer), "uri": "gone.bin"}]
        path = self.write("model.gltf", json.dumps(doc))
        with self.assertRaises(GltfError):
            load_gltf(path)


class TestTrisLines(GltfTestCase):
    def test_tris_lines_format_parses_back(self):
        doc, buffer = build_gltf(TRI_POSITIONS)
        data = load_gltf(self.write_gltf(doc, buffer))
        lines = triangles_to_tris_lines("hero", data)
        self.assertEqual(lines[0], "tris hero 1")
        self.assertEqual(len(lines), 2)
        parts = lines[1].split()
        self.assertEqual(parts[0], "tri")
        self.assertEqual([int(p) for p in parts[1:4]], [255, 255, 255])
        coords = [float(p) for p in parts[4:13]]
        # Winding-converted order (v1, v3, v2), as load_gltf emits it.
        self.assertEqual(coords, [0.0, 0.0, 0.0,
                                  0.0, 1.0, 0.0,
                                  1.0, 0.0, 0.0])

    def test_tris_lines_float_format(self):
        data = {"triangles": [((1, 2, 3), [(0.5, 0.25, -1.5),
                                           (2.0, 0.0, 0.0),
                                           (0.0, 3.0, 0.0)])],
                "count": 1}
        lines = triangles_to_tris_lines("m", data)
        self.assertEqual(lines[0], "tris m 1")
        self.assertEqual(lines[1], "tri 1 2 3 0.5 0.25 -1.5 2 0 0 0 3 0")


if __name__ == "__main__":
    unittest.main()
