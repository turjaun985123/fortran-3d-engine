"""Forge3D standalone HTML emitter (B15).

Stdlib only.  ``emit_html(ir, runtime_js, template) -> str`` builds a
single self-contained ``.html`` file from an ``IRScene`` (B08,
``ir_nodes``): the B18 template (``viewer_template.html``) with the
B14 ``emit_js`` scene payload and the JS runtime (B28, ``f3d.js``)
inlined, so the result opens over ``file://`` with no ``fetch`` and
no external ``<script src=...>``.

Placeholders (plain string substitution, no template engine):

* ``{{TITLE}}``    -- scene name, HTML-escaped.
* ``{{SCENE_JS}}`` -- ``emit_js(ir)`` output (scene JSON payload).
* ``{{F3D_JS}}``   -- ``runtime_js`` when supplied; otherwise an
  explanatory HTML comment plus a minimal inline message script.
* ``{{FALLBACK}}`` -- fallback message shown when the runtime is
  missing; empty when the runtime was inlined.

``emit_js`` / ``emit_common`` are parallel seats: they are imported
best-effort (plain and package-relative, like ``ir_nodes`` does for
``errors``) and, while they have not landed, a local fallback emits
``const SCENE = <ir_nodes.to_json(ir)>;`` so this module works and
is smoke-testable on its own.  Once B14 lands its ``emit_js`` is
used verbatim.
"""

from __future__ import annotations

import html
import json
import os
from typing import Any, Optional

__all__ = ["emit_html", "FALLBACK_COMMENT", "BUILTIN_TEMPLATE"]


# Exact marker required when no runtime is supplied.  A
# ``<script src="runtime/f3d.js">`` fallback is deliberately NOT
# used: it would break the standalone ``file://`` guarantee.
FALLBACK_COMMENT = "<!-- f3d.js runtime not supplied: link runtime/f3d.js -->"

_FALLBACK_MESSAGE = (
    "F3D runtime not supplied: this file was built without the "
    "f3d.js runtime, so the scene cannot be rendered. Rebuild with "
    "the runtime (runtime/f3d.js) inlined."
)

# Minimal inline script (JS body, no tags) used for the missing-
# runtime case when the placeholder sits inside a <script> element;
# wrapped in tags by _substitute_js when it does not.
_FALLBACK_JS = (
    "console.error('F3D: runtime not supplied - link runtime/f3d.js');\n"
    "(function () {\n"
    "  var el = document.getElementById('f3d-fallback');\n"
    "  if (el) { el.textContent = " + json.dumps(_FALLBACK_MESSAGE) + "; }\n"
    "})();"
)

BUILTIN_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<style>
  body { margin: 0; background: #191923; color: #f0f0f0;
         font-family: system-ui, sans-serif; }
  main { max-width: 960px; margin: 0 auto; padding: 1rem; }
  canvas { display: block; background: #000; max-width: 100%; }
  #f3d-fallback:empty { display: none; }
</style>
</head>
<body>
<main>
<h1>{{TITLE}}</h1>
<canvas id="f3d-canvas" width="640" height="480"></canvas>
<div id="f3d-fallback" role="alert">{{FALLBACK}}</div>
</main>
{{F3D_JS}}
{{SCENE_JS}}
<script>
(function () {
  var scene = (typeof SCENE !== "undefined") ? SCENE : window.SCENE;
  var canvas = document.getElementById("f3d-canvas");
  if (!canvas || !scene) { return; }
  if (window.F3D && typeof window.F3D.create === "function") {
    window.F3D.create(canvas, scene);
  } else if (window.F3D && typeof window.F3D.mount === "function") {
    window.F3D.mount(canvas, scene);
  }
})();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Sibling emitters (parallel seats, imported best-effort)
# ---------------------------------------------------------------------------
def _load_emit_js():
    """Return B14's ``emit_js`` callable, or ``None`` if not landed."""
    candidates = []
    try:
        import emit_js as _mod  # type: ignore

        candidates.append(_mod)
    except Exception:
        pass
    try:
        from . import emit_js as _rel_mod  # type: ignore

        candidates.append(_rel_mod)
    except Exception:
        pass
    for mod in candidates:
        for attr in ("emit_js", "emit", "render_js", "to_js"):
            fn = getattr(mod, attr, None)
            if callable(fn):
                return fn
    return None


def _fallback_scene_js(ir: Any) -> str:
    """Scene JS from the frozen IR JSON while B14 has not landed."""
    text = None
    to_json = None
    try:
        import ir_nodes as _irn  # type: ignore

        to_json = getattr(_irn, "to_json", None)
    except Exception:
        try:
            from . import ir_nodes as _irn_rel  # type: ignore

            to_json = getattr(_irn_rel, "to_json", None)
        except Exception:
            to_json = None
    if callable(to_json):
        try:
            text = to_json(ir)
        except Exception:
            text = None
    if text is None:
        if isinstance(ir, dict):
            data = ir
        elif hasattr(ir, "__dict__"):
            data = dict(vars(ir))
        else:
            data = {"scene": repr(ir)}
        text = json.dumps(data)
    return "const SCENE = " + text + ";\nwindow.SCENE = SCENE;\n"


def _scene_js(ir: Any) -> str:
    fn = _load_emit_js()
    if fn is not None:
        try:
            out = fn(ir)
        except TypeError:
            out = fn(ir, None)  # tolerate emit_js(ir, runtime) shapes
        if isinstance(out, str) and out:
            return out
    return _fallback_scene_js(ir)


def _scene_name(ir: Any) -> str:
    if isinstance(ir, dict):
        return str(ir.get("name") or "untitled")
    return str(getattr(ir, "name", None) or "untitled")


# ---------------------------------------------------------------------------
# Template handling / placeholder substitution
# ---------------------------------------------------------------------------
def _load_template(template: Optional[str]) -> str:
    if template is not None:
        # A template argument that names an existing file (and is
        # not itself markup) is read; anything else is the text.
        if "<" not in template and "{{" not in template:
            try:
                if os.path.isfile(template):
                    with open(template, "r", encoding="utf-8") as fh:
                        return fh.read()
            except OSError:
                pass
        return template
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (
        os.path.join(here, "viewer_template.html"),
        os.path.join(here, "templates", "viewer_template.html"),
        os.path.join(here, "templates", "viewer.html.tmpl"),
    ):
        try:
            with open(candidate, "r", encoding="utf-8") as fh:
                return fh.read()
        except OSError:
            continue
    return BUILTIN_TEMPLATE


def _inside_script(text: str, pos: int) -> bool:
    """True if offset ``pos`` lies inside a <script>...</script>."""
    before = text[:pos].lower()
    return before.rfind("<script") > before.rfind("</script")


def _substitute_js(text: str, placeholder: str, js_code: str,
                   missing: bool = False) -> str:
    """Replace a JS placeholder, respecting <script> context.

    Bare placeholders get wrapped in ``<script>`` tags; placeholders
    already inside a script element receive the raw JS.  For the
    missing-runtime case the exact ``FALLBACK_COMMENT`` plus a
    minimal inline message script is produced (never ``src=``).
    """
    while placeholder in text:
        pos = text.index(placeholder)
        if _inside_script(text, pos):
            if missing:
                repl = FALLBACK_COMMENT + "\n" + _FALLBACK_JS
            else:
                repl = js_code
        else:
            if missing:
                repl = (FALLBACK_COMMENT + "\n<script>\n"
                        + _FALLBACK_JS + "\n</script>")
            else:
                repl = "<script>\n" + js_code + "\n</script>"
        text = text[:pos] + repl + text[pos + len(placeholder):]
    return text


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def emit_html(ir: Any, runtime_js: Optional[str] = None,
              template: Optional[str] = None) -> str:
    """Return a single self-contained HTML document for ``ir``.

    ``runtime_js`` is the f3d.js runtime source to inline; when it
    is provided the result needs no external files.  When it is
    ``None`` a comment + inline message script is emitted instead
    (no ``<script src=...>`` fallback, which ``file://`` would
    break).  ``template`` overrides the B18 template on disk, which
    in turn overrides the built-in minimal template.
    """
    out = _load_template(template)

    if runtime_js:
        out = _substitute_js(out, "{{F3D_JS}}", str(runtime_js))
        fallback_html = ""
    else:
        out = _substitute_js(out, "{{F3D_JS}}", "", missing=True)
        fallback_html = html.escape(_FALLBACK_MESSAGE)

    out = _substitute_js(out, "{{SCENE_JS}}", _scene_js(ir))
    out = out.replace("{{FALLBACK}}", fallback_html)
    out = out.replace("{{TITLE}}", html.escape(_scene_name(ir), quote=True))
    return out
