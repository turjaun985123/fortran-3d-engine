#!/usr/bin/env python3
"""Forge3D built-in real-time previewer.

`f3dc preview scene.f3d` serves the compiled viewer on a local port and
watches the scene file: every save recompiles the scene and any open
browser tab reloads itself with the new render -- no manual rebuild, no
manual refresh.  A scene that fails to compile does not kill the
preview: the tab shows the compiler's diagnostics and recovers by itself
as soon as the file compiles again.

Stdlib only, like the rest of f3dc.  The preview recompiles through the
same pipeline as `f3dc build` (cli.compile_pipeline + cli._html_text),
so what you see is exactly what `build`/`run` would produce in the
browser viewer.
"""

import json
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import cli
from errors import ErrorBag

POLL_SECONDS = 0.4
DEBOUNCE_SECONDS = 0.15

_CLIENT_JS = """
(function () {
  var seen = __VERSION__;
  var pill = document.getElementById('f3d-pill');
  var fpsEl = document.getElementById('f3d-fps');
  var frames = 0, last = performance.now();
  function tick(now) {
    frames++;
    if (now - last >= 500) {
      if (fpsEl) fpsEl.textContent = Math.round(frames * 1000 / (now - last)) + ' fps';
      frames = 0; last = now;
    }
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
  setInterval(function () {
    fetch('/__version', {cache: 'no-store'}).then(function (r) { return r.json(); })
      .then(function (v) {
        if (v.version !== seen) { location.reload(); return; }
        if (pill) {
          pill.textContent = v.ok ? '● LIVE' : '● ERROR';
          pill.style.color = v.ok ? '#4ade80' : '#f87171';
        }
      }).catch(function () {
        if (pill) { pill.textContent = '● OFFLINE'; pill.style.color = '#f87171'; }
      });
  }, 600);
})();
"""

_TOOLBAR = """
<div id="f3d-preview-bar" style="position:fixed;top:0;left:0;right:0;z-index:9999;
  display:flex;gap:14px;align-items:center;padding:6px 12px;
  background:rgba(13,13,20,.88);color:#e5e7eb;font:13px/1.4 system-ui,sans-serif;">
  <strong>Forge3D Preview</strong>
  <span>__STEM__.f3d</span>
  <span id="f3d-pill" style="color:#4ade80">● LIVE</span>
  <span id="f3d-fps" style="color:#9ca3af"></span>
  <span style="margin-left:auto;color:#9ca3af">edit &amp; save — the preview reloads itself · drag to orbit · scroll to zoom</span>
</div>
<div style="height:30px"></div>
<script>__CLIENT__</script>
"""


def _diag_dict(d):
    span = getattr(d, "span", None)
    return {
        "code": d.code,
        "severity": d.severity,
        "message": d.message,
        "why": getattr(d, "why", ""),
        "help": getattr(d, "help", ""),
        "line": getattr(span, "line", None),
        "col": getattr(span, "col", None),
    }


class PreviewState:
    """The compiled state of one watched scene file (lock-guarded)."""

    def __init__(self, scene_path):
        self.path = Path(scene_path)
        self.stem = self.path.stem
        self.lock = threading.Lock()
        self.version = 0
        self.ok = False
        self.html = None
        self.diagnostics = []
        self.compile_count = 0
        self._mtime_ns = None

    def compile_now(self):
        """Recompile through the real pipeline; bump version on change."""
        bag = ErrorBag()
        try:
            ir = cli.compile_pipeline(str(self.path), bag)
        except Exception as exc:  # a compiler crash must not kill preview
            ir = None
            bag_error = {"code": "E9000", "severity": "error",
                         "message": f"internal compiler error: {exc}",
                         "why": "", "help": "", "line": None, "col": None}
            with self.lock:
                self.ok = False
                self.html = None
                self.diagnostics = [bag_error]
                self.compile_count += 1
                self.version += 1
            return False
        diags = [_diag_dict(d) for d in bag.diagnostics]
        html = cli._html_text(ir, self.stem) if ir is not None else None
        with self.lock:
            self.ok = ir is not None
            self.html = html
            self.diagnostics = diags
            self.compile_count += 1
            self.version += 1
        return self.ok

    def snapshot(self):
        with self.lock:
            return {
                "version": self.version,
                "ok": self.ok,
                "html": self.html,
                "diagnostics": list(self.diagnostics),
                "compile_count": self.compile_count,
                "stem": self.stem,
            }

    def page(self):
        """The full HTML to serve: viewer + toolbar, or an error page."""
        snap = self.snapshot()
        if snap["ok"] and snap["html"]:
            client = _CLIENT_JS.replace("__VERSION__", str(snap["version"]))
            bar = _TOOLBAR.replace("__STEM__", snap["stem"]).replace(
                "__CLIENT__", client)
            html = snap["html"]
            if "</body>" in html:
                return html.replace("</body>", bar + "</body>", 1)
            return html + bar
        lines = []
        for d in snap["diagnostics"]:
            where = ""
            if d.get("line"):
                where = f":{d['line']}:{d.get('col') or 1}"
            lines.append(f"{d['code']} {d['severity']}{where}: {d['message']}")
            if d.get("why"):
                lines.append(f"  why: {d['why']}")
            if d.get("help"):
                lines.append(f"  help: {d['help']}")
        if not lines:
            lines = ["scene failed to compile (no diagnostics)"]
        body = "\n".join(lines)
        client = _CLIENT_JS.replace("__VERSION__", str(snap["version"]))
        bar = _TOOLBAR.replace("__STEM__", snap["stem"]).replace(
            "__CLIENT__", client)
        return ("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
                f"<title>Forge3D Preview — {snap['stem']} (error)</title>"
                "</head><body style=\"background:#0d0d14;color:#e5e7eb;"
                "font:14px/1.5 ui-monospace,monospace;padding:16px\">"
                + bar +
                "<h2 style=\"color:#f87171\">Scene error — fix the file and "
                "save; this page recovers by itself.</h2>"
                f"<pre>{body}</pre>"
                "</body></html>\n")


def _watch(state, stop_event):
    try:
        state._mtime_ns = state.path.stat().st_mtime_ns
    except OSError:
        state._mtime_ns = None
    while not stop_event.wait(POLL_SECONDS):
        try:
            mtime = state.path.stat().st_mtime_ns
        except OSError:
            mtime = None
        if mtime != state._mtime_ns:
            state._mtime_ns = mtime
            time.sleep(DEBOUNCE_SECONDS)
            try:
                state._mtime_ns = state.path.stat().st_mtime_ns
            except OSError:
                state._mtime_ns = None
            state.compile_now()


def make_server(state, host="127.0.0.1", port=8765):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # keep the console clean
            pass

        def _send(self, body, content_type, status=200):
            data = body.encode("utf-8") if isinstance(body, str) else body
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self._send(state.page(), "text/html; charset=utf-8")
            elif self.path == "/__version":
                snap = state.snapshot()
                self._send(json.dumps({
                    "version": snap["version"], "ok": snap["ok"],
                    "errors": sum(1 for d in snap["diagnostics"]
                                  if d["severity"] == "error"),
                }), "application/json")
            elif self.path == "/__status":
                snap = state.snapshot()
                self._send(json.dumps({
                    "version": snap["version"], "ok": snap["ok"],
                    "compile_count": snap["compile_count"],
                    "diagnostics": snap["diagnostics"],
                }), "application/json")
            else:
                self._send("not found\n", "text/plain", status=404)

    return ThreadingHTTPServer((host, port), Handler)


def serve(scene_path, port=8765, open_browser=True, host="127.0.0.1"):
    """Run the preview server until Ctrl+C. Returns a process exit code."""
    state = PreviewState(scene_path)
    ok = state.compile_now()
    try:
        server = make_server(state, host=host, port=port)
    except OSError as exc:
        print(f"error E502: cannot start preview server on "
              f"{host}:{port}: {exc}", flush=True)
        return 3
    actual_port = server.server_address[1]
    url = f"http://{host}:{actual_port}/"
    stop_event = threading.Event()
    watcher = threading.Thread(target=_watch, args=(state, stop_event),
                               daemon=True)
    watcher.start()
    print(f"Forge3D preview: {state.path} "
          f"({'ok' if ok else 'COMPILE ERROR — see browser'})")
    print(f"  open  {url}")
    print("  watching for saves — the browser reloads itself. "
          "Ctrl+C to stop.")
    if open_browser:
        threading.Timer(0.3, webbrowser.open, args=(url,)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\npreview stopped")
    finally:
        stop_event.set()
        server.shutdown()
        server.server_close()
    return 0
