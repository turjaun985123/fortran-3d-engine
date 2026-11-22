"""Forge3D parser (seat B05) -- recursive descent, one statement per line.

parse(text, source_name, bag) -> Program

Surface forms (MASTER-PLAN section 1 + P03 section 4, both must work):
  * Forgiving: commas ignored, vec3 = 3 consecutive numbers, colours as a
    WORD name / COLOR token / ``rgb r g b`` / ``rgb(r,g,b)``.
  * P03 forms: ``light dir|from vec3``, ``strength n``, ``animate t spin``,
    ``render to "x"``, ``scene "name"``, bare axis in animation props.

Stdlib only.  Errors are reported into ``bag`` and parsing recovers at the
next line; after 10 syntax errors an E820 stop diagnostic is emitted.
"""

import inspect
import re

__all__ = ["parse", "Parser"]

# --------------------------------------------------------------------------
# Optional sibling modules (B02 errors / B03 lexer / B04 ast_nodes).
# They are imported when present; small local fallbacks keep this module
# usable (and smoke-testable) on its own.
# --------------------------------------------------------------------------
try:  # B04
    from . import ast_nodes as _ast
except Exception:  # pragma: no cover
    try:
        import ast_nodes as _ast  # type: ignore
    except Exception:
        _ast = None

try:  # B03
    from .lexer import tokenize as _lexer_tokenize
except Exception:  # pragma: no cover
    try:
        from lexer import tokenize as _lexer_tokenize  # type: ignore
    except Exception:
        _lexer_tokenize = None

try:  # B02
    from . import errors as _errors
except Exception:  # pragma: no cover
    try:
        import errors as _errors  # type: ignore
    except Exception:
        _errors = None


class _FallbackNode:
    _fields = ()

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    def __repr__(self):
        inner = ", ".join("%s=%r" % kv for kv in sorted(self.__dict__.items()))
        return "%s(%s)" % (type(self).__name__, inner)

    def __eq__(self, other):
        return type(self) is type(other) and self.__dict__ == other.__dict__


def _fallback_class(name):
    return type(name, (_FallbackNode,), {})


_NODE_NAMES = ("Program", "SceneStmt", "CameraStmt", "LightStmt", "ObjectStmt",
               "GroupStmt", "AnimStmt", "LoadStmt", "RepeatStmt",
               "ControlsStmt", "OutputStmt",
               # Wave B (fallback node classes; semantics in validate)
               "SpriteStmt", "TextStmt", "ParticlesStmt", "KeysStmt",
               "KeyStmt",
               # Wave C (fallback node classes; semantics in validate)
               "FilterStmt", "InstanceStmt")
_NODES = {}
for _n in _NODE_NAMES:
    _cls = getattr(_ast, _n, None) if _ast is not None else None
    _NODES[_n] = _cls if _cls is not None else _fallback_class(_n)


def _make(node_name, **fields):
    """Construct an AST node tolerantly: honour the real class signature
    when there is one, then set every parsed field as an attribute so any
    reasonable field name a consumer uses is present."""
    cls = _NODES[node_name]
    obj = None
    try:
        params = inspect.signature(cls).parameters
        accepted = {k: v for k, v in fields.items()
                    if k in params or any(p.kind == inspect.Parameter.VAR_KEYWORD
                                          for p in params.values())}
        obj = cls(**accepted)
    except Exception:
        obj = None
    if obj is None:
        try:
            obj = cls()
        except Exception:
            obj = object.__new__(cls)
    for k, v in fields.items():
        try:
            setattr(obj, k, v)
        except Exception:
            pass
    return obj


# --------------------------------------------------------------------------
# did-you-mean (errors.did_you_mean preferred, local Damerau fallback)
# --------------------------------------------------------------------------
def _dl(a, b, limit=2):
    la, lb = len(a), len(b)
    if abs(la - lb) > limit:
        return limit + 1
    d = [[0] * (lb + 1) for _ in range(la + 1)]
    for i in range(la + 1):
        d[i][0] = i
    for j in range(lb + 1):
        d[0][j] = j
    for i in range(1, la + 1):
        for j in range(1, lb + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[la][lb]


def _did_you_mean(word, candidates):
    fn = getattr(_errors, "did_you_mean", None) if _errors else None
    if fn is not None:
        try:
            r = fn(word, list(candidates))
            if r:
                return r[0] if isinstance(r, (list, tuple)) else r
        except Exception:
            pass
    best, bestd = None, 3
    for c in candidates:
        dist = _dl(word.lower(), c.lower())
        if dist < bestd:
            best, bestd = c, dist
    return best


# --------------------------------------------------------------------------
# Fallback lexer (used only when B03 lexer is unavailable)
# --------------------------------------------------------------------------
class _Tok:
    __slots__ = ("kind", "value", "text", "line", "col")

    def __init__(self, kind, value, line, col):
        self.kind = kind
        self.value = value
        self.text = value
        self.line = line
        self.col = col

    def __repr__(self):
        return "Tok(%s,%r)" % (self.kind, self.value)


_NUM_RE = re.compile(r"-?\d+(?:\.\d+)?$")
_HEX6 = re.compile(r"[0-9a-fA-F]{6}$")


def _fallback_tokenize(text, source, bag):  # noqa: ARG001 - contract shape
    toks, line, col, i, n = [], 1, 1, 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "\n":
            toks.append(_Tok("NEWLINE", "\n", line, col)); line += 1; col = 1; i += 1
        elif ch in " \t\r":
            col += 1; i += 1
        elif ch == "#" and _HEX6.match(text[i + 1:i + 7]) and not (
                i + 7 < n and (text[i + 7].isalnum() or text[i + 7] == "_")):
            toks.append(_Tok("COLOR", text[i:i + 7], line, col)); col += 7; i += 7
        elif ch == "#" or text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif ch == '"':
            j = text.find('"', i + 1)
            if j < 0:
                j = n
            toks.append(_Tok("STRING", text[i + 1:j], line, col))
            col += j - i + 1; i = min(j + 1, n)
        elif ch == ",":
            toks.append(_Tok("COMMA", ",", line, col)); col += 1; i += 1
        elif ch == ":":
            toks.append(_Tok("COLON", ":", line, col)); col += 1; i += 1
        elif ch.isdigit() or (ch == "-" and i + 1 < n and text[i + 1].isdigit()):
            m = re.match(r"-?\d+(?:\.\d+)?(?:x\d+(?:\.\d+)?)?", text[i:])
            s = m.group(0)
            toks.append(_Tok("NUMBER" if "x" not in s else "WORD", s, line, col))
            col += len(s); i += len(s)
        elif ch.isalpha() or ch == "_":
            m = re.match(r"[A-Za-z_][A-Za-z0-9_-]*:?", text[i:])
            s = m.group(0)
            toks.append(_Tok("WORD", s, line, col)); col += len(s); i += len(s)
        else:
            toks.append(_Tok("PUNCT", ch, line, col)); col += 1; i += 1
    toks.append(_Tok("EOF", "", line, col))
    return toks


# --------------------------------------------------------------------------
# Token access helpers (tolerant of object / dict / tuple token shapes)
# --------------------------------------------------------------------------
def _tkind(t):
    if isinstance(t, dict):
        return str(t.get("kind") or t.get("type") or "").upper()
    k = getattr(t, "kind", None) or getattr(t, "type", None)
    if k is None and isinstance(t, (list, tuple)) and t:
        k = t[0]
    return str(k or "").upper()


def _unquote(s):
    """Strip surrounding double quotes from a STRING lexeme, if present.

    The real lexer (B03) keeps quotes on STRING tokens (``'"x.ppm"'``)
    while the fallback lexer strips them; normalising here makes every
    STRING value (render/export/load paths, scene names, texture paths,
    and any other ``ident()``/``next_text()`` STRING use) quote-free.
    """
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s


def _ttext(t):
    if isinstance(t, dict):
        v = t.get("value", t.get("text", t.get("lexeme", "")))
    else:
        v = getattr(t, "value", None)
        if v is None:
            v = getattr(t, "text", None)
        if v is None:
            v = getattr(t, "lexeme", None)
        if v is None and isinstance(t, (list, tuple)) and len(t) > 1:
            v = t[1]
    s = "" if v is None else str(v)
    if _tkind(t) == "STRING":
        s = _unquote(s)
    return s


def _tline(t, default=0):
    v = None
    if isinstance(t, dict):
        v = t.get("line", t.get("lineno"))
    else:
        v = getattr(t, "line", None) or getattr(t, "lineno", None)
        if v is None:
            span = getattr(t, "span", None)
            if span is not None:
                v = getattr(span, "line", None) or getattr(span, "start_line", None)
    try:
        return int(v) if v else default
    except Exception:
        return default


def _tcol(t, default=0):
    v = None
    if isinstance(t, dict):
        v = t.get("col", t.get("column"))
    else:
        v = getattr(t, "col", None) or getattr(t, "column", None)
        if v is None:
            span = getattr(t, "span", None)
            if span is not None:
                v = getattr(span, "col", None) or getattr(span, "start_col", None)
    try:
        return int(v) if v else default
    except Exception:
        return default


def _colour_raw_str(colour):
    """Canonical raw colour string for ObjectStmt.color_raw (B04 contract):
    named/hex lower-cased, rgb channels as ``rgb(r,g,b)``; None stays None.
    The original value is left untouched in props."""
    if colour is None:
        return None
    if isinstance(colour, (list, tuple)):
        if len(colour) == 3:
            fn = getattr(_ast, "colour_raw", None) if _ast is not None else None
            if fn is not None:
                try:
                    return fn(int(colour[0]), int(colour[1]), int(colour[2]))
                except Exception:
                    pass
            return "rgb(%d,%d,%d)" % tuple(int(c) for c in colour)
        return str(colour)
    return str(colour).lower().replace(" ", "")


def _num(s):
    try:
        return int(s)
    except Exception:
        pass
    try:
        f = float(s)
        return int(f) if f == int(f) and re.match(r"-?\d+\.0+$", s) else f
    except Exception:
        return None


# --------------------------------------------------------------------------
# Vocabulary
# --------------------------------------------------------------------------
PRIMS = ("cube", "sphere", "cylinder", "plane", "pyramid", "cone", "torus")
ANIM_VERBS = ("spin", "bob", "pulse", "orbit", "move", "turn", "grow")
RESERVED_SECURITY = {"system", "eval", "import"}
RESERVED = {"let", "if", "for", "function"} | RESERVED_SECURITY
STARTERS = (("scene", "camera", "light", "group", "end", "animate", "load",
             "repeat", "grid", "ring", "controls", "render", "export",
             "filter", "instance")
            + PRIMS + ANIM_VERBS)
# Extended (CSS-like) colour vocabulary used ONLY to tell a bare colour word
# apart from an object name; membership here does not make a colour valid --
# validate.py owns the real palette and rejects e.g. 'gold'.
COLOUR_WORDS = set("""red green blue yellow magenta cyan orange purple pink
white black gray grey gold silver brown beige coral crimson indigo ivory
khaki lavender lime maroon navy olive teal turquoise violet salmon tan
skyblue steelblue seagreen forestgreen darkred darkblue darkgreen lightblue
lightgreen hotpink deeppink aqua azure fuchsia limegreen royalblue""".split())
AXES = ("x", "y", "z")
OBJECT_PROP_WORDS = {"at", "pos", "position", "size", "radius", "height",
                     "width", "depth", "rotate", "rot", "scale", "material",
                     "segments", "detail", "capped", "open", "texture",
                     "colour", "color", "named", "name"}
ANIM_PROP_WORDS = {"axis", "speed", "duration", "fps", "ease", "loop",
                   "amplitude", "distance", "amount", "angle"}


class _StopParsing(Exception):
    pass


class _LineError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------
# Parser
# --------------------------------------------------------------------------
class Parser:
    def __init__(self, text, source_name="input.f3d", bag=None):
        self.text = text or ""
        self.source = source_name
        self.bag = bag
        self.errors = []          # (code, message, line, col) collected here
        self.syntax_errors = 0
        self._stopped = False

    # -- diagnostics ------------------------------------------------------
    def error(self, code, message, line=0, col=0):
        self.errors.append((code, message, line, col))
        if code.startswith(("E1", "E2", "E4")):
            self.syntax_errors += 1
        self._report_to_bag(code, message, line, col)
        if self.syntax_errors >= 10 and not self._stopped:
            self._stopped = True
            msg = "too many syntax errors (10) -- stopping parse"
            self.errors.append(("E820", msg, line, col))
            self._report_to_bag("E820", msg, line, col)
            raise _StopParsing()

    def _report_to_bag(self, code, message, line, col):
        bag = self.bag
        if bag is None:
            return
        # Build a proper Diagnostic (errors.py: Diagnostic(code, severity,
        # message, span, why, help) -- severity is required). Never fall
        # back to bag.add(message_string): ErrorBag.add expects a
        # Diagnostic, and a bare str corrupts bag.diagnostics and crashes
        # has_errors()/format_text() (CLI exit 70 instead of 1).
        severity = "warning" if str(code).startswith("W") else "error"
        why, help_text = "", ""
        m = re.search(r"did you mean '([^']+)'", str(message))
        if m:
            help_text = "did you mean '%s'?" % m.group(1)
            why = "the compiler does not know this word"
        span = None
        span_cls = getattr(_errors, "Span", None) if _errors else None
        if span_cls is not None:
            try:
                span = span_cls(self.source, int(line) or 1, int(col) or 1)
            except Exception:
                span = None
        diag = None
        diag_cls = getattr(_errors, "Diagnostic", None) if _errors else None
        if diag_cls is not None:
            try:
                diag = diag_cls(code=code, severity=severity, message=message,
                                span=span, why=why, help=help_text)
            except Exception:
                diag = None
        if diag is None:
            # errors.py unavailable: keep a tuple, never a bare string.
            diag = (code, severity, message, line, col)
        if isinstance(bag, list):
            bag.append(diag)
            return
        add = getattr(bag, "add", None)
        if callable(add):
            add(diag)
            return
        diags = getattr(bag, "diagnostics", None)
        if isinstance(diags, list):
            diags.append(diag)

    # -- token stream -----------------------------------------------------
    def _lines(self):
        tokenize = _lexer_tokenize or _fallback_tokenize
        try:
            toks = tokenize(self.text, self.source, self.bag)
        except TypeError:
            try:
                toks = tokenize(self.text, self.source)
            except Exception:
                toks = _fallback_tokenize(self.text, self.source, self.bag)
        except Exception:
            toks = _fallback_tokenize(self.text, self.source, self.bag)
        toks = [t for t in (toks or []) if _tkind(t) != "EOF"]
        lines, cur, cur_no = [], [], 0
        if any(_tkind(t) == "NEWLINE" for t in toks):
            for t in toks:
                if _tkind(t) == "NEWLINE":
                    lines.append((cur_no, cur)); cur, cur_no = [], 0
                else:
                    if not cur:
                        cur_no = _tline(t, cur_no)
                    cur.append(t)
            if cur:
                lines.append((cur_no, cur))
        else:  # lexer without NEWLINE tokens: split on token line numbers
            for t in toks:
                ln = _tline(t, cur_no or 1)
                if cur and ln != cur_no:
                    lines.append((cur_no, cur)); cur = []
                cur_no = ln
                cur.append(t)
            if cur:
                lines.append((cur_no, cur))
        return [(no, [t for t in ts if _tkind(t) not in ("COMMA", "COLON")])
                for no, ts in lines]

    # -- main entry -------------------------------------------------------
    def parse_program(self):
        statements = []
        lines = self._lines()
        i = 0
        try:
            while i < len(lines):
                no, toks = lines[i]
                i += 1
                if not toks:
                    continue
                first = _ttext(toks[0]).lower().rstrip(":")
                try:
                    if first == "group":
                        stmt, i = self._parse_group(toks, no, lines, i)
                        if stmt is not None:
                            statements.append(stmt)
                    elif first == "end":
                        continue  # P03 scene...end sugar: block close, ignored
                    else:
                        stmt = self._parse_statement(toks, no)
                        if stmt is not None:
                            statements.append(stmt)
                except _LineError as e:
                    self.error(e.code, e.message, no, _tcol(toks[0]))
                except _StopParsing:
                    raise
                except Exception as e:  # never crash on one bad line
                    self.error("E103", "could not parse line: %s" % e, no,
                               _tcol(toks[0]))
        except _StopParsing:
            pass
        prog = _make("Program", statements=statements, stmts=statements,
                     source=self.source, source_name=self.source,
                     errors=self.errors)
        return prog

    # -- dispatch ---------------------------------------------------------
    def _parse_statement(self, toks, no):
        lp = _Line(self, toks, no)
        first = lp.peek_word()
        if first is None:
            raise _LineError("E103", "expected a statement")
        if first in RESERVED:
            code = "E820" if first in RESERVED_SECURITY else "E205"
            raise _LineError(code, "'%s' is reserved and not allowed in .f3d "
                                   "(the language is declarative only)" % first)
        if first == "scene":
            return self._parse_scene(lp)
        if first == "camera":
            return self._parse_camera(lp)
        if first == "light":
            return self._parse_light(lp)
        if first in PRIMS:
            return self._parse_object(lp)
        if first in ("repeat", "grid", "ring"):
            return self._parse_repeat(lp)
        if first in ANIM_VERBS or first == "animate":
            return self._parse_anim(lp)
        if first == "load":
            return self._parse_load(lp)
        if first == "sprite":
            return self._parse_sprite(lp)
        if first == "text":
            return self._parse_text(lp)
        if first == "particles":
            return self._parse_particles(lp)
        if first == "filter":
            return self._parse_filter(lp)
        if first == "instance":
            return self._parse_instance(lp)
        if first == "keys":
            return self._parse_keys_header(lp)
        if first == "key":
            return self._parse_key(lp)
        if first == "controls":
            return self._parse_controls(lp)
        if first in ("render", "export"):
            return self._parse_output(lp)
        if first == "group":
            raise _LineError("E401", "'group' must start a block")
        suggestion = _did_you_mean(first, STARTERS)
        msg = "unknown word '%s'" % first
        if suggestion:
            msg += " -- did you mean '%s'?" % suggestion
        raise _LineError("E104", msg)

    # -- shared helpers via _Line -----------------------------------------
    def _parse_scene(self, lp):
        lp.next()  # scene
        name, size, bg = None, None, None
        env_clauses = {}
        seen = set()
        clause_words = ("size", "bg", "background", "colour", "color",
                        "fog", "tonemap", "tone", "shadow")
        while not lp.at_end():
            w = lp.peek_word()
            if w in ("size",):
                lp.next(); lp.dup(seen, "size")
                size = lp.size()
            elif w in ("fog", "tonemap", "tone", "shadow"):
                # Wave A environment clause: consume tokens up to the
                # next clause keyword; ext_lights_env owns semantics.
                key = "tonemap" if w in ("tonemap", "tone") else w
                lp.next(); lp.dup(seen, key)
                parts = [w]
                while not lp.at_end() and lp.peek_word() not in clause_words:
                    parts.append(lp.next_text())
                env_clauses[key] = " ".join(parts)
            elif w in ("bg", "background", "colour", "color"):
                lp.next(); lp.dup(seen, "background")
                bg = lp.colour()
            elif lp.peek_kind() == "STRING" and name is None:
                name = lp.next_text()
            elif lp.peek_size_token():
                lp.dup(seen, "size"); size = lp.size()
            elif w is not None and name is None and w not in RESERVED:
                name = lp.next_text()
            else:
                raise _LineError("E103", "unexpected '%s' in scene statement"
                                         % lp.peek_text())
        scene_props = {"size": size, "background": bg}
        scene_props.update(env_clauses)
        return _make("SceneStmt", name=name, size=size,
                     width=size[0] if size else None,
                     height=size[1] if size else None,
                     bg=bg, background=bg, colour=bg, color=bg,
                     fog=env_clauses.get("fog"),
                     tonemap=env_clauses.get("tonemap"),
                     shadow=env_clauses.get("shadow"),
                     props=scene_props,
                     line=lp.no, span=None)

    def _parse_camera(self, lp):
        lp.next()
        props, seen = {}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w in ("at", "look", "up"):
                lp.next(); lp.dup(seen, w); props[w] = lp.vec3()
            elif w in ("fov", "near", "far"):
                lp.next(); lp.dup(seen, w); props[w] = lp.number(w)
            elif w == "size":
                # Wave C: ortho frustum height (`camera ortho size N`).
                lp.next(); lp.dup(seen, w); props[w] = lp.number(w)
            elif w == "ortho":
                lp.next(); props["ortho"] = True
            else:
                raise _LineError("E103", "unexpected '%s' in camera statement"
                                         % lp.peek_text())
        return _make("CameraStmt", at=props.get("at"), position=props.get("at"),
                     look=props.get("look"), target=props.get("look"),
                     up=props.get("up"), fov=props.get("fov"),
                     near=props.get("near"), far=props.get("far"),
                     props=props, line=lp.no, span=None)

    def _parse_light(self, lp):
        lp.next()
        kind, direction, frm, intensity, colour = None, None, None, None, None
        position, target = None, None
        extra = {}
        props, seen = {}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w in ("directional", "ambient", "point", "spot"):
                lp.next(); kind = w
            elif w in ("dir", "direction"):
                lp.next(); lp.dup(seen, "dir"); direction = lp.vec3()
            elif w in ("at", "pos", "position"):
                lp.next(); lp.dup(seen, "at"); position = lp.vec3()
            elif w in ("look", "target", "look_at"):
                lp.next(); lp.dup(seen, "look"); target = lp.vec3()
            elif w in ("distance", "decay", "angle", "penumbra"):
                lp.next(); lp.dup(seen, w); extra[w] = lp.number(w)
            elif w == "from":
                lp.next(); lp.dup(seen, "from"); frm = lp.vec3()
                direction = tuple(-v for v in frm)
            elif w in ("intensity", "strength"):
                lp.next(); lp.dup(seen, "intensity")
                intensity = lp.number("intensity")
            elif w in ("colour", "color"):
                lp.next(); lp.dup(seen, "colour"); colour = lp.colour()
            elif lp.peek_kind() == "NUMBER":
                lp.dup(seen, "dir"); direction = lp.vec3()
            elif lp.peek_kind() == "COLOR" or w == "rgb" or w in COLOUR_WORDS:
                lp.dup(seen, "colour"); colour = lp.colour()
            else:
                raise _LineError("E103", "unexpected '%s' in light statement"
                                         % lp.peek_text())
        if position is None:
            # For point/spot, `from <vec3>` names the light's position
            # (ext_lights_env semantics), not a direction. For
            # directional lights this preserves the v1 position=frm.
            position = frm
        props.update({"direction": direction, "dir": direction, "from": frm,
                      "intensity": intensity, "strength": intensity,
                      "colour": colour, "at": position,
                      "position": position, "look": target,
                      "target": target})
        props.update(extra)
        return _make("LightStmt", kind=kind or "directional",
                     type=kind or "directional", mode=kind or "directional",
                     direction=direction, dir=direction, from_=frm,
                     position=position, target=target,
                     intensity=intensity, strength=intensity,
                     colour=colour, color=colour, props=props,
                     line=lp.no, span=None)

    def _object_props(self, lp, props, seen):
        """Parse one object-style prop at lp's position into props."""
        w = lp.peek_word()
        if w in ("at", "pos", "position"):
            lp.next(); lp.dup(seen, "at"); props["at"] = lp.vec3()
            props["pos"] = props["at"]
        elif w == "size":
            lp.next(); lp.dup(seen, "size"); props["size"] = lp.num_or_vec3()
        elif w in ("radius", "height", "width", "depth"):
            lp.next(); lp.dup(seen, w); props[w] = lp.number(w)
        elif w in ("rotate", "rot"):
            lp.next(); lp.dup(seen, "rotate"); props["rotate"] = lp.vec3()
            props["rot"] = props["rotate"]
        elif w == "scale":
            lp.next(); lp.dup(seen, "scale"); props["scale"] = lp.num_or_vec3()
        elif w == "material":
            lp.next(); lp.dup(seen, "material"); props["material"] = lp.ident()
        elif w in ("metalness", "roughness", "specular", "shininess"):
            lp.next(); lp.dup(seen, w); props[w] = lp.number(w)
        elif w == "segments":
            lp.next(); lp.dup(seen, "segments")
            v = lp.number("segments"); props["segments"] = int(v)
        elif w == "detail":
            lp.next(); lp.dup(seen, "detail")
            d = lp.ident()
            if d is not None and d.lower() not in ("low", "med", "high"):
                raise _LineError("E103", "detail must be low, med or high, "
                                         "got '%s'" % d)
            props["detail"] = d.lower() if d else d
        elif w == "capped":
            lp.next(); lp.dup(seen, "capped"); props["capped"] = True
        elif w == "open":
            lp.next(); lp.dup(seen, "open"); props["open"] = True
        elif w == "texture":
            lp.next(); lp.dup(seen, "texture")
            if lp.peek_kind() == "STRING":
                props["texture"] = lp.next_text()
            else:
                props["texture"] = lp.ident()
        elif w in ("colour", "color"):
            lp.next(); lp.dup(seen, "colour"); props["colour"] = lp.colour()
            props["color"] = props["colour"]
        else:
            return False
        return True

    def _parse_object(self, lp):
        prim = lp.next_text().lower()
        name, colour = None, None
        props, seen = {}, set()
        # Optional [name] / [colour] / 'named NAME' right after the primitive.
        while not lp.at_end():
            w = lp.peek_word()
            if w == "named":
                lp.next(); name = lp.ident(); continue
            if lp.peek_kind() == "COLOR" or w == "rgb":
                lp.dup(seen, "colour"); colour = lp.colour(); continue
            if w is not None and w not in OBJECT_PROP_WORDS and w not in RESERVED:
                if w in COLOUR_WORDS:
                    lp.dup(seen, "colour"); colour = lp.colour(); continue
                if name is None:
                    name = lp.next_text(); continue
                raise _LineError("E103", "unexpected word '%s' after %s name"
                                         % (w, prim))
            break
        while not lp.at_end():
            if self._object_props(lp, props, seen):
                continue
            w = lp.peek_word()
            if lp.peek_kind() == "COLOR" or w == "rgb" or w in COLOUR_WORDS:
                lp.dup(seen, "colour"); colour = lp.colour(); continue
            raise _LineError("E103", "unexpected '%s' in %s statement"
                                     % (lp.peek_text(), prim))
        if colour is None:
            # Colour may have arrived via _object_props ('colour'/'color').
            colour = props.get("colour", props.get("color"))
        if colour is not None:
            props.setdefault("colour", colour); props.setdefault("color", colour)
        return _make("ObjectStmt", prim=prim, primitive=prim, type=prim,
                     kind=prim, name=name, colour=colour, color=colour,
                     color_raw=_colour_raw_str(colour),
                     colour_raw=_colour_raw_str(colour),
                     props=props, line=lp.no, span=None,
                     **{k: v for k, v in props.items()
                        if k not in ("prim", "primitive", "type", "kind",
                                     "name", "line", "span", "props",
                                     "colour", "color")})

    def _parse_group(self, header_toks, no, lines, i):
        lp = _Line(self, header_toks, no)
        lp.next()  # group
        name = lp.ident()
        if name is None:
            raise _LineError("E401", "'group' needs a name")
        props, seen = {}, set()
        while not lp.at_end():
            if self._object_props(lp, props, seen):
                continue
            raise _LineError("E103", "unexpected '%s' in group header"
                                     % lp.peek_text())
        children, nested = [], 0
        while i < len(lines):
            cno, ctoks = lines[i]
            i += 1
            if not ctoks:
                continue
            fw = _ttext(ctoks[0]).lower().rstrip(":")
            if fw == "end":
                if nested:
                    nested -= 1
                    continue
                return (_make("GroupStmt", name=name, props=props,
                              children=children, objects=children,
                              statements=children, line=no, span=None), i)
            if fw == "group":
                self.error("E401", "groups cannot be nested (one level only)",
                           cno, _tcol(ctoks[0]))
                nested += 1
                continue
            if nested:
                continue
            try:
                stmt = self._parse_statement(ctoks, cno)
                if stmt is not None:
                    children.append(stmt)
            except _LineError as e:
                self.error(e.code, e.message, cno, _tcol(ctoks[0]))
        self.error("E401", "group '%s' has no closing 'end'" % name, no, 0)
        return (_make("GroupStmt", name=name, props=props, children=children,
                      objects=children, statements=children, line=no,
                      span=None), i)

    def _parse_anim(self, lp):
        first = lp.next_text().lower()
        verb, target = None, None
        if first == "animate":
            w = lp.peek_word()
            if w in ANIM_VERBS:
                verb = lp.next_text().lower()
                # 'animate spin it ...': target may follow the motion.
                w_after = lp.peek_word()
                if (w_after is not None and w_after not in ANIM_PROP_WORDS
                        and w_after not in AXES
                        and w_after not in ("loop", "once", "forever",
                                            "pingpong", "repeat")):
                    target = lp.next_text()
            elif w is not None:
                target = lp.next_text()
                w2 = lp.peek_word()
                if w2 in ANIM_VERBS:
                    verb = lp.next_text().lower()
                else:
                    raise _LineError("E103", "'animate' needs a motion such "
                                             "as spin, bob, pulse or move")
            else:
                raise _LineError("E101", "'animate' needs a target and a motion")
        else:
            verb = first
            w = lp.peek_word()
            if w is not None and w not in ANIM_PROP_WORDS and w not in AXES:
                target = lp.next_text()
        props, seen = {}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w == "axis":
                lp.next(); lp.dup(seen, "axis")
                a = lp.ident()
                if a is None or a.lower() not in AXES:
                    raise _LineError("E103", "axis must be x, y or z")
                props["axis"] = a.lower()
            elif w in AXES and "axis" not in seen:
                lp.dup(seen, "axis"); props["axis"] = lp.next_text().lower()
                if lp.peek_kind() == "NUMBER":  # P03: axis + total amount
                    props["amount"] = lp.number("amount")
            elif w in ("speed", "duration", "amplitude", "distance", "amount"):
                lp.next(); lp.dup(seen, w); props[w] = lp.number(w)
            elif w == "fps":
                lp.next(); lp.dup(seen, "fps"); props["fps"] = int(lp.number("fps"))
            elif w == "ease":
                lp.next(); lp.dup(seen, "ease"); props["ease"] = lp.ident()
            elif w == "loop":
                lp.next(); lp.dup(seen, "loop")
                v = lp.peek_word()
                if v in ("once", "forever", "pingpong"):
                    props["loop"] = lp.next_text().lower()
                elif v == "repeat":
                    props["loop"] = lp.loop_repeat()
                else:
                    props["loop"] = "forever"  # bare 'loop' (P03 section 9.5)
            elif w in ("once", "forever", "pingpong"):
                lp.dup(seen, "loop"); props["loop"] = lp.next_text().lower()
            elif w == "repeat":
                lp.dup(seen, "loop"); props["loop"] = lp.loop_repeat()
            else:
                raise _LineError("E103", "unexpected '%s' in animation" % lp.peek_text())
        fields = dict(kind=verb, verb=verb, motion=verb, action=verb,
                      target=target, props=props, line=lp.no, span=None)
        for k in ("axis", "speed", "duration", "fps", "ease", "loop"):
            fields[k] = props.get(k)
        return _make("AnimStmt", **fields)

    def _parse_load(self, lp):
        lp.next()
        if lp.peek_kind() == "STRING":
            path = lp.next_text()
        elif not lp.at_end():
            path = lp.next_text()
        else:
            raise _LineError("E101", "'load' needs a quoted file path")
        name, props, seen = None, {}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w == "named":
                lp.next(); name = lp.ident(); continue
            if self._object_props(lp, props, seen):
                continue
            if w is not None and name is None and w not in OBJECT_PROP_WORDS:
                name = lp.next_text(); continue
            raise _LineError("E103", "unexpected '%s' in load statement"
                                     % lp.peek_text())
        return _make("LoadStmt", path=path, file=path, name=name, props=props,
                     line=lp.no, span=None,
                     **{k: v for k, v in props.items() if k != "name"})

    # -- Wave B statements (B67-B95; semantics live in the ext_*
    #    modules + ext_keys, this layer only shapes the nodes) ---------

    def _waveb_named_props(self, lp, extra_words=()):
        """Shared [name] + object-prop tail for sprite/particles."""
        name, colour = None, None
        props, seen = {}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w == "named":
                lp.next(); name = lp.ident(); continue
            if lp.peek_kind() == "COLOR" or w == "rgb":
                lp.dup(seen, "colour"); colour = lp.colour(); continue
            if (w is not None and w not in OBJECT_PROP_WORDS
                    and w not in extra_words and w not in RESERVED):
                if w in COLOUR_WORDS:
                    lp.dup(seen, "colour"); colour = lp.colour(); continue
                if name is None:
                    name = lp.next_text(); continue
                raise _LineError("E103", "unexpected word '%s'" % w)
            break
        while not lp.at_end():
            if self._object_props(lp, props, seen):
                continue
            w = lp.peek_word()
            if w in extra_words:
                lp.next(); lp.dup(seen, w)
                props[w] = lp.number(w); continue
            if lp.peek_kind() == "COLOR" or w == "rgb" or w in COLOUR_WORDS:
                lp.dup(seen, "colour"); colour = lp.colour(); continue
            raise _LineError("E103", "unexpected '%s'" % lp.peek_text())
        if colour is None:
            colour = props.get("colour", props.get("color"))
        if colour is not None:
            props.setdefault("colour", colour)
            props.setdefault("color", colour)
        return name, colour, props

    def _parse_sprite(self, lp):
        lp.next()  # sprite
        name, colour, props = self._waveb_named_props(lp)
        return _make("SpriteStmt", name=name, colour=colour,
                     color=colour, props=props, line=lp.no, span=None)

    def _parse_particles(self, lp):
        lp.next()  # particles
        name, colour, props = self._waveb_named_props(
            lp, extra_words=("count", "life", "speed", "spread",
                             "gravity", "seed"))
        if "count" in props:
            props["count"] = int(props["count"])
        if "seed" in props:
            props["seed"] = int(props["seed"])
        return _make("ParticlesStmt", name=name, colour=colour,
                     color=colour, props=props, line=lp.no, span=None)

    # -- Wave C statements (B75-B82; semantics live in ext_post /
    #    ext_cameras + validate, this layer only shapes the nodes) --

    def _parse_filter(self, lp):
        lp.next()  # filter
        name = lp.ident()
        if name is None:
            raise _LineError("E101", "'filter' needs a filter name, "
                                     "like: filter blur 1")
        amount = None
        if not lp.at_end():
            amount = lp.number("filter amount")
        if not lp.at_end():
            raise _LineError("E103", "unexpected '%s' in filter "
                                     "statement" % lp.peek_text())
        props = {"name": name.lower()}
        if amount is not None:
            props["amount"] = amount
        return _make("FilterStmt", name=name.lower(), amount=amount,
                     props=props, line=lp.no, span=None)

    def _parse_instance(self, lp):
        lp.next()  # instance
        new_name = lp.ident()
        if new_name is None:
            raise _LineError("E101", "'instance' needs a name for the "
                                     "new object, like: instance c2 of "
                                     "cube1 at 2,0,0")
        if lp.peek_word() != "of":
            raise _LineError("E103", "'instance' expects 'of' after "
                                     "the new name")
        lp.next()  # of
        source = lp.ident()
        if source is None:
            raise _LineError("E101", "'instance' needs the name of "
                                     "the object it copies after 'of'")
        props, seen = {}, set()
        while not lp.at_end():
            if self._object_props(lp, props, seen):
                continue
            raise _LineError("E103", "unexpected '%s' in instance "
                                     "statement" % lp.peek_text())
        props["source"] = source
        return _make("InstanceStmt", name=new_name, source=source,
                     props=props, line=lp.no, span=None)

    def _parse_text(self, lp):
        lp.next()  # text
        name = None
        # Optional name: a word directly followed by the quoted string.
        if lp.peek_kind() == "WORD" and lp.i + 1 < len(lp.toks) \
                and _tkind(lp.toks[lp.i + 1]) == "STRING":
            name = lp.next_text()
        if lp.peek_kind() != "STRING":
            raise _LineError("E101", "'text' needs a quoted string, "
                                     "like: text \"HELLO\"")
        content = lp.next_text()
        colour = None
        props, seen = {}, set()
        while not lp.at_end():
            if self._object_props(lp, props, seen):
                continue
            w = lp.peek_word()
            if lp.peek_kind() == "COLOR" or w == "rgb" or w in COLOUR_WORDS:
                lp.dup(seen, "colour"); colour = lp.colour(); continue
            raise _LineError("E103", "unexpected '%s' in text statement"
                                     % lp.peek_text())
        if colour is None:
            colour = props.get("colour", props.get("color"))
        if colour is not None:
            props.setdefault("colour", colour)
            props.setdefault("color", colour)
        props["content"] = content
        return _make("TextStmt", name=name, content=content,
                     colour=colour, color=colour, props=props,
                     line=lp.no, span=None)

    def _parse_keys_header(self, lp):
        lp.next()  # keys
        target = lp.ident()
        if target is None:
            raise _LineError("E101", "'keys' needs the name of the "
                                     "object it animates")
        duration, loop = None, None
        props, seen = {}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w == "duration":
                lp.next(); lp.dup(seen, "duration")
                duration = lp.number("duration")
            elif w == "loop":
                lp.next(); lp.dup(seen, "loop")
                v = lp.peek_word()
                if v in ("once", "forever", "pingpong"):
                    loop = lp.next_text().lower()
                else:
                    raise _LineError("E103", "loop must be once, "
                                             "forever or pingpong")
            elif w in ("once", "forever", "pingpong"):
                lp.dup(seen, "loop"); loop = lp.next_text().lower()
            else:
                raise _LineError("E103", "unexpected '%s' in keys "
                                         "statement" % lp.peek_text())
        if duration is not None:
            props["duration"] = duration
        if loop is not None:
            props["loop"] = loop
        props["target"] = target
        return _make("KeysStmt", target=target, duration=duration,
                     loop=loop, props=props, line=lp.no, span=None)

    def _parse_key(self, lp):
        lp.next()  # key
        target = lp.ident()
        if target is None:
            raise _LineError("E101", "'key' needs the name of the "
                                     "object it animates")
        time_, pos, rot, scale, ease = None, None, None, None, None
        props, seen = {}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w == "at":
                lp.next(); lp.dup(seen, "at")
                time_ = lp.number("key time")
            elif w in ("pos", "position"):
                lp.next(); lp.dup(seen, "pos"); pos = lp.vec3()
            elif w in ("rot", "rotate"):
                lp.next(); lp.dup(seen, "rot"); rot = lp.vec3()
            elif w == "scale":
                lp.next(); lp.dup(seen, "scale")
                scale = lp.number("scale")
            elif w == "ease":
                lp.next(); lp.dup(seen, "ease"); ease = lp.ident()
            else:
                raise _LineError("E103", "unexpected '%s' in key "
                                         "statement" % lp.peek_text())
        if time_ is None:
            raise _LineError("E101", "'key' needs a time: key %s at 0 "
                                     "..." % target)
        props.update({"target": target, "time": time_, "pos": pos,
                      "rot": rot, "scale": scale, "ease": ease})
        return _make("KeyStmt", target=target, time=time_, pos=pos,
                     rot=rot, scale=scale, ease=ease, props=props,
                     line=lp.no, span=None)

    def _parse_repeat(self, lp):
        kind = lp.next_text().lower()
        count, rows, cols = None, None, None
        if kind == "repeat":
            count = int(lp.number("repeat count"))
        elif kind == "ring":
            count = int(lp.number("ring count"))
        else:  # grid
            size = lp.grid_size()
            rows, cols = size
            count = rows * cols
        if lp.at_end():
            raise _LineError("E101", "'%s' needs an object to repeat" % kind)
        w = lp.peek_word()
        if w not in PRIMS:
            raise _LineError("E103", "'%s' must be followed by an object, "
                                     "got '%s'" % (kind, lp.peek_text()))
        obj = self._parse_object(lp)
        return _make("RepeatStmt", kind=kind, mode=kind, count=count,
                     rows=rows, cols=cols, grid=(rows, cols) if kind == "grid" else None,
                     object=obj, obj=obj, props={}, line=lp.no, span=None)

    def _parse_controls(self, lp):
        lp.next()
        mode = lp.ident()
        if mode is not None:
            mode = mode.lower()
        if mode not in ("orbit", "none"):
            raise _LineError("E103", "controls must be 'orbit' or 'none'")
        props, seen = {"autorotate": False}, set()
        while not lp.at_end():
            w = lp.peek_word()
            if w == "autorotate":
                lp.next(); props["autorotate"] = True
            elif w in ("min", "max"):
                lp.next(); lp.dup(seen, w); props[w] = lp.number(w)
            else:
                raise _LineError("E103", "unexpected '%s' in controls" % lp.peek_text())
        return _make("ControlsStmt", mode=mode, type=mode,
                     autorotate=props["autorotate"],
                     min=props.get("min"), max=props.get("max"),
                     props=props, line=lp.no, span=None)

    def _parse_output(self, lp):
        kind = lp.next_text().lower()
        fmt, path, size, still = None, None, None, False
        props, seen = {}, set()
        if kind == "export":
            fmt = lp.ident()
            if fmt is None or fmt.lower() not in ("json", "obj", "html"):
                raise _LineError("E103", "export needs a format: json, obj or html")
            fmt = fmt.lower(); props["format"] = fmt
            if lp.peek_kind() == "STRING":
                path = lp.next_text()
            elif lp.peek_word() == "to":
                lp.next(); path = lp.next_text()
        while not lp.at_end():
            w = lp.peek_word()
            if lp.peek_kind() == "STRING" and path is None:
                path = lp.next_text()
            elif w == "to":
                lp.next(); path = lp.next_text()
            elif w == "size":
                lp.next(); lp.dup(seen, "size"); size = lp.size()
            elif lp.peek_size_token():
                lp.dup(seen, "size"); size = lp.size()
            elif w == "still":
                lp.next(); still = True
            elif w in ("frames", "fps", "duration"):
                lp.next(); lp.dup(seen, w); props[w] = lp.number(w)
            else:
                raise _LineError("E103", "unexpected '%s' in %s statement"
                                         % (lp.peek_text(), kind))
        if size is not None:
            props["size"] = size
        if path is not None:
            props["path"] = path
        return _make("OutputStmt", kind=kind, mode=kind, format=fmt, fmt=fmt,
                     path=path, file=path, size=size,
                     width=size[0] if size else None,
                     height=size[1] if size else None, still=still,
                     frames=props.get("frames"), fps=props.get("fps"),
                     duration=props.get("duration"), props=props,
                     line=lp.no, span=None)


# --------------------------------------------------------------------------
# Per-line cursor
# --------------------------------------------------------------------------
class _Line:
    def __init__(self, parser, toks, no):
        self.p = parser
        self.toks = [t for t in toks if _tkind(t) not in ("COMMA", "COLON")
                     and (_tkind(t) not in ("PUNCT",)
                          or _ttext(t) in ("(", ")"))]
        self.i = 0
        self.no = no or (_tline(toks[0]) if toks else 0)

    def at_end(self):
        return self.i >= len(self.toks)

    def peek(self):
        return self.toks[self.i] if not self.at_end() else None

    def peek_kind(self):
        t = self.peek()
        return _tkind(t) if t is not None else "EOF"

    def peek_text(self):
        t = self.peek()
        return _ttext(t) if t is not None else ""

    def peek_word(self):
        if self.peek_kind() == "WORD":
            return self.peek_text().lower().rstrip(":")
        return None

    def next(self):
        t = self.peek()
        self.i += 1
        return t

    def next_text(self):
        return _ttext(self.next())

    def dup(self, seen, key):
        if key in seen:
            raise _LineError("E110", "'%s' given twice in one statement" % key)
        seen.add(key)

    def ident(self):
        if self.peek_kind() in ("WORD", "STRING"):
            return self.next_text()
        return None

    # -- values -----------------------------------------------------------
    def number(self, what="number"):
        if self.peek_kind() == "NUMBER":
            v = _num(self.next_text())
            if v is not None:
                return v
        raise _LineError("E102", "expected a number for %s, got '%s'"
                                 % (what, self.peek_text()))

    def _numbers_ahead(self):
        out = []
        j = self.i
        while j < len(self.toks) and _tkind(self.toks[j]) == "NUMBER":
            out.append(_num(_ttext(self.toks[j]))); j += 1
        return out

    def vec3(self):
        # rgb-style parenthesised form: '(' n n n ')'
        if self.peek_text() == "(":
            self.next()
            vals = [self.number("vec3"), self.number("vec3"), self.number("vec3")]
            if self.peek_text() == ")":
                self.next()
            return tuple(vals)
        nums = self._numbers_ahead()
        if len(nums) < 3:
            raise _LineError("E102", "expected 3 numbers (a vec3), got %d"
                                     % len(nums))
        self.i += 3
        return tuple(nums[:3])

    def num_or_vec3(self):
        nums = self._numbers_ahead()
        if not nums:
            raise _LineError("E102", "expected a number, got '%s'" % self.peek_text())
        # vec3 only when exactly 3 numbers are followed by a word / end, so
        # 'size 2 at ...' stays scalar and 'size 2 3 4 rotate ...' is a vec3.
        nxt = self.toks[self.i + 3] if self.i + 3 < len(self.toks) else None
        if len(nums) >= 3 and (nxt is None or _tkind(nxt) == "WORD"):
            self.i += 3
            return tuple(nums[:3])
        self.i += 1
        return nums[0]

    def colour(self):
        t = self.peek()
        if t is None:
            raise _LineError("E101", "expected a colour")
        if _tkind(t) == "COLOR":
            return self.next_text()
        w = self.peek_word()
        if w == "rgb":
            self.next()
            if self.peek_text() == "(":
                self.next()
                vals = [self.number("rgb"), self.number("rgb"), self.number("rgb")]
                if self.peek_text() == ")":
                    self.next()
                return tuple(int(v) for v in vals)
            m = re.match(r"rgb\((\d+),(\d+),(\d+)\)$", self.peek_text(), re.I)
            if m:  # single-token rgb(...) form
                self.next()
                return tuple(int(g) for g in m.groups())
            nums = self._numbers_ahead()
            if len(nums) < 3:
                raise _LineError("E102", "'rgb' needs 3 numbers")
            self.i += 3
            return tuple(int(v) for v in nums[:3])
        m = re.match(r"rgb\((\d+),(\d+),(\d+)\)$", self.peek_text(), re.I)
        if m:
            self.next()
            return tuple(int(g) for g in m.groups())
        if _tkind(t) == "WORD":
            # Raw word stored as-is: validate.py decides if it is a colour.
            return self.next_text().lower()
        raise _LineError("E102", "expected a colour, got '%s'" % self.peek_text())

    def peek_size_token(self):
        # Single token '800x600', or lexer-split forms: the real lexer
        # emits '800x600' as NUMBER '800' + WORD 'x600', and '800 x 600'
        # as NUMBER + WORD 'x' + NUMBER.
        if re.match(r"\d+x\d+$", self.peek_text()):
            return True
        if self.peek_kind() != "NUMBER":
            return False
        nxt = self.toks[self.i + 1] if self.i + 1 < len(self.toks) else None
        if nxt is None:
            return False
        nt = _ttext(nxt)
        if re.match(r"x\d+$", nt, re.I):
            return True
        if nt.lower() == "x":
            nxt2 = self.toks[self.i + 2] if self.i + 2 < len(self.toks) else None
            return nxt2 is not None and _tkind(nxt2) == "NUMBER"
        return False

    def _second_of_pair(self, what):
        """Second number of a '<n>x<m>' pair after the first is consumed:
        WORD 'x600', WORD 'x' + NUMBER, or a bare NUMBER; else None."""
        m = re.match(r"x(\d+)$", self.peek_text(), re.I)
        if m and self.peek_kind() == "WORD":
            self.next()
            return int(m.group(1))
        if self.peek_word() == "x":
            self.next()
            return int(self.number(what))
        if self.peek_kind() == "NUMBER":
            return int(self.number(what))
        return None

    def size(self):
        m = re.match(r"(\d+)x(\d+)$", self.peek_text())
        if m:
            self.next()
            return (int(m.group(1)), int(m.group(2)))
        w = self.number("size width")
        h = self._second_of_pair("size height")
        if h is None:
            raise _LineError("E102", "expected a size height, got '%s'"
                                     % self.peek_text())
        return (int(w), h)

    def grid_size(self):
        m = re.match(r"(\d+)x(\d+)$", self.peek_text())
        if m:
            self.next()
            return (int(m.group(1)), int(m.group(2)))
        a = int(self.number("grid rows"))
        b = self._second_of_pair("grid cols")
        return (a, b) if b is not None else (a, a)

    def loop_repeat(self):
        self.next()  # 'repeat'
        if self.peek_text() == "(":
            self.next()
            n = int(self.number("repeat count"))
            if self.peek_text() == ")":
                self.next()
            return "repeat(%d)" % n
        m = re.match(r"repeat\((\d+)\)$", self.peek_text(), re.I)
        if m:
            self.next()
            return "repeat(%d)" % int(m.group(1))
        if self.peek_kind() == "NUMBER":
            return "repeat(%d)" % int(self.number("repeat count"))
        return "repeat"


def parse(text, source_name="input.f3d", bag=None):
    """Parse .f3d source text into a Program AST (see module docstring)."""
    return Parser(text, source_name, bag).parse_program()
