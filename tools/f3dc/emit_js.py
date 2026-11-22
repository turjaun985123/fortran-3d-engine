"""Forge3D JS emitter (B14) -- ``scene.js`` for the P06 runtime contract.

Stdlib only.  Emits a tiny, dependency-free JS file:

1. a ``//`` header stamp (see ``emit_common`` when that sibling, B11,
   is present; a local equivalent is used until it lands),
2. ``window.F3D_SCENE = <compact JSON>;`` -- exactly the v2 scene dict
   produced by ``emit_json.emit_json_v2`` (B13), serialised compactly,
   and
3. a tiny bootstrap: on ``DOMContentLoaded`` (or immediately if the
   document is already parsed), if ``window.F3D`` (``runtime/f3d.js``,
   B28) exists and the document contains an ``<f3d-view>`` element or a
   ``canvas#f3d-canvas``, ``F3D.auto(window.F3D_SCENE)`` is called.

All rendering logic lives in B28's ``f3d.js`` -- none is emitted here.
Every bootstrap step is guarded by ``typeof`` checks and ``try/catch``
so the file is harmless when loaded standalone (tests, node, a page
without the runtime or without a target element).
"""

from __future__ import annotations

import json

try:  # Sibling modules, plain (script-style) imports first.
    import emit_common as _emit_common  # type: ignore
except Exception:  # pragma: no cover - package-style fallback
    try:
        from . import emit_common as _emit_common  # type: ignore
    except Exception:
        _emit_common = None  # type: ignore

try:
    import emit_json as _emit_json  # type: ignore
except Exception:  # pragma: no cover - package-style fallback
    try:
        from . import emit_json as _emit_json  # type: ignore
    except Exception:
        _emit_json = None  # type: ignore

try:
    import ir_nodes as _ir_nodes  # type: ignore
except Exception:  # pragma: no cover - package-style fallback
    try:
        from . import ir_nodes as _ir_nodes  # type: ignore
    except Exception:
        _ir_nodes = None  # type: ignore

__all__ = ["emit_js"]

_BOOTSTRAP = """\
;(function () {
  try {
    if (typeof window === "undefined" || typeof document === "undefined") return;
    var run = function () {
      try {
        if (typeof window.F3D === "undefined" || !window.F3D) return;
        if (typeof window.F3D.auto !== "function") return;
        if (typeof document.querySelector !== "function") return;
        if (!document.querySelector("f3d-view, canvas#f3d-canvas")) return;
        window.F3D.auto(window.F3D_SCENE);
      } catch (e) {}
    };
    if (typeof document !== "undefined" && document.readyState === "loading" &&
        typeof document.addEventListener === "function") {
      document.addEventListener("DOMContentLoaded", run);
    } else if (typeof document !== "undefined" &&
               (document.readyState === "interactive" ||
                document.readyState === "complete")) {
      run();
    } else if (typeof document !== "undefined" &&
               typeof document.addEventListener === "function") {
      document.addEventListener("DOMContentLoaded", run);
    }
  } catch (e) {}
})();
"""


def _header_stamp(source_name, obj):
    """Return the ``//`` header stamp lines (no trailing newline).

    Uses ``emit_common.header_stamp(source_name, obj, comment="//")``
    (B11) when available; falls back to the same three-line shape.
    """
    fn = getattr(_emit_common, "header_stamp", None) if _emit_common else None
    if callable(fn):
        try:
            text = fn(source_name, obj, "//")
        except Exception:
            text = None
        if isinstance(text, str) and text.strip():
            return text.strip()
    return (
        "// Forge3D generated file - do not edit\n"
        "// source: %s\n"
        "// Forge3D scene (format v2) for runtime/f3d.js: window.F3D_SCENE"
        % (source_name,)
    )


def _v2_dict(ir):
    """Return the v2 scene dict for ``ir`` (via B13 when available)."""
    if isinstance(ir, dict):
        return ir
    if _emit_json is not None:
        for name in ("emit_json_v2", "scene_to_json_v2", "to_json_v2", "emit_v2"):
            fn = getattr(_emit_json, name, None)
            if not callable(fn):
                continue
            result = fn(ir)
            if isinstance(result, dict):
                return result
            if isinstance(result, (bytes, bytearray)):
                result = result.decode("utf-8")
            if isinstance(result, str):
                return json.loads(result)
            return result
    if _ir_nodes is not None:
        return _ir_nodes.to_dict(ir)
    raise TypeError("emit_js: no emit_json/ir_nodes available for %r" % type(ir))


def _compact_json(data):
    js_json = getattr(_emit_common, "js_json", None) if _emit_common else None
    if callable(js_json):
        try:
            text = js_json(data)
        except Exception:
            text = None
    else:
        text = None
    if not isinstance(text, str):
        text = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    # Safe to inline into HTML/JS: `</script>` must not appear literally,
    # and U+2028/U+2029 are not valid in older JS string literals.
    # Both escapes still parse back to the identical value via json.loads.
    return (
        text.replace("</", "<\\/")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def emit_js(ir, source_name=None, **_kwargs):
    """Serialise IR scene ``ir`` to the ``scene.js`` string described above."""
    if source_name is None:
        source_name = _kwargs.get("source") or _kwargs.get("filename")
    data = _v2_dict(ir)
    if not source_name:
        if isinstance(ir, dict):
            source_name = ir.get("name") or "scene"
        else:
            source_name = getattr(ir, "name", None) or "scene"
    payload = _compact_json(data)
    return (
        _header_stamp(str(source_name), data)
        + '\nif (typeof window === "undefined" && typeof globalThis !== "undefined")'
        + " { var window = globalThis; }\n"
        + "window.F3D_SCENE = "
        + payload
        + ";\n"
        + _BOOTSTRAP
    )
