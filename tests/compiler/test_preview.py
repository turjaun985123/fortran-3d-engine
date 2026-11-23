"""Tests for the Forge3D real-time previewer (tools/f3dc/preview.py).

Stdlib unittest only.  Starts the real HTTP server on an ephemeral port
and drives it with urllib: initial page, /__version, live recompile on
save, error state, and self-recovery.
"""

import json
import sys
import threading
import time
import unittest
import urllib.request
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "f3dc"))

import preview  # noqa: E402


def _get(url):
    with urllib.request.urlopen(url, timeout=5) as resp:
        return resp.status, resp.read().decode("utf-8")


def _wait_version(base, want_greater, timeout=8.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        _, body = _get(base + "/__version")
        last = json.loads(body)
        if last["version"] > want_greater:
            return last
        time.sleep(0.1)
    raise AssertionError(f"version did not pass {want_greater}: {last}")


class TestPreview(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.scene = Path(self.tmp.name) / "demo.f3d"
        self.scene.write_text("cube red\nspin it\nrender\n", encoding="utf-8")
        self.state = preview.PreviewState(self.scene)
        self.assertTrue(self.state.compile_now())
        self.server = preview.make_server(self.state, port=0)
        self.port = self.server.server_address[1]
        self.base = f"http://127.0.0.1:{self.port}"
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.stop = threading.Event()
        self.watcher = threading.Thread(
            target=preview._watch, args=(self.state, self.stop), daemon=True)
        self.watcher.start()

    def tearDown(self):
        self.stop.set()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def test_initial_page_has_viewer_and_toolbar(self):
        status, body = _get(self.base + "/")
        self.assertEqual(status, 200)
        self.assertIn("f3d-preview-bar", body)
        self.assertIn("Forge3D Preview", body)
        self.assertNotIn("__VERSION__", body)  # placeholder substituted

    def test_version_endpoint_ok(self):
        _, body = _get(self.base + "/__version")
        data = json.loads(body)
        self.assertTrue(data["ok"])
        self.assertEqual(data["errors"], 0)
        self.assertGreaterEqual(data["version"], 1)

    def test_save_recompiles_and_page_changes(self):
        _, before = _get(self.base + "/__version")
        v0 = json.loads(before)["version"]
        self.scene.write_text("sphere blue\nrender\n", encoding="utf-8")
        data = _wait_version(self.base, v0)
        self.assertTrue(data["ok"])
        _, page = _get(self.base + "/")
        self.assertIn("f3d-preview-bar", page)

    def test_broken_scene_shows_error_then_recovers(self):
        _, before = _get(self.base + "/__version")
        v0 = json.loads(before)["version"]
        self.scene.write_text("cubee red\nrender\n", encoding="utf-8")
        data = _wait_version(self.base, v0)
        self.assertFalse(data["ok"])
        self.assertGreaterEqual(data["errors"], 1)
        _, page = _get(self.base + "/")
        self.assertIn("Scene error", page)
        _, status_body = _get(self.base + "/__status")
        status = json.loads(status_body)
        self.assertFalse(status["ok"])
        self.assertTrue(status["diagnostics"])
        # Fix the file: the preview must recover on its own.
        v1 = data["version"]
        self.scene.write_text("cube green\nrender\n", encoding="utf-8")
        data2 = _wait_version(self.base, v1)
        self.assertTrue(data2["ok"])

    def test_unknown_path_404(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            _get(self.base + "/nope")
        self.assertEqual(ctx.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
