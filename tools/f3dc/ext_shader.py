"""Forge3D Wave E extension: custom ``shader`` statements (C2).

Stdlib only. This module is an *extension* (see ``ir_nodes`` plan
rule 4: new features register, they do not edit the frozen IR). It
owns the compiler side of the Wave E custom-shader surface; the
compiler coordinator wires ``parser.py`` / ``validate.py`` / ``emit``
to call it.

Scope is tokenising / compiling / validation / emit only, exactly
like the other ``ext_*`` modules: the per-pixel evaluation lives in
the Fortran renderer and its JS mirror, never here. Both mirrors
implement the frozen semantics guards exactly:

* division by zero -> 0
* modulo by zero -> 0
* ``pow`` with an invalid domain (negative base with a fractional
  exponent, or ``0`` raised to a negative power) -> 0
* ``sqrt`` of a negative number -> 0

User syntax (frozen)::

    shader <name> expr "<expression>"

defines a shader, and the object property::

    shader <name>

binds a previously defined shader to an object (the coordinator
handles both statement shapes; this module owns the expression
language and the ``.scene`` lines below).

Expression language (frozen)::

    variables   c r g b x y z u v ndl t pi
    binary ops  + - * / % ^      (``^`` is power, right-associative)
    unary       -                (emitted as ``neg`` in RPN)
    grouping    parentheses, decimal numbers
    1-arg       sin cos tan abs sqrt floor ceil fract
    2-arg       min max step pow
    3-arg       clamp mix

with ``step(edge, x) = 1 if x >= edge else 0``,
``mix(a, b, f) = a + (b - a) * f`` and ``fract(x) = x - floor(x)``.

``.scene`` lines emitted::

    shaderdef NAME NTOK tok1 ... tokN
    shaderbind OBJ SHADER

Public API (the exact names the coordinator wires to)::

    tokenize_expr(src) -> list[str]
    to_rpn(tokens) -> list[str]
    EXPR_VARS
    EXPR_FUNCS
    validate_shader(name, rpn) -> list[str]
    scene_lines(defs) -> list[str]
    binding_line(obj, shader_name) -> str

RPN token format (frozen): numbers and variable names as-is
(numbers verbatim, exactly as written in the source), binary
operators as the single character, unary minus as ``neg``, and
functions by name.

All functions are defensive, pure and side-effect free. Error
strings are plain human-readable messages (no diagnostic codes):
``validate`` wraps them in E301-family diagnostics, exactly as for
``ext_post`` / ``ext_materials`` / ``ext_particles``.
``to_rpn`` instead raises ``ValueError`` with a clear message, so a
malformed expression never reaches validation.
"""

from __future__ import annotations

import re

__all__ = [
    "EXPR_VARS",
    "EXPR_FUNCS",
    "tokenize_expr",
    "to_rpn",
    "validate_shader",
    "scene_lines",
    "binding_line",
]

# ---------------------------------------------------------------------------
# Frozen vocabulary
# ---------------------------------------------------------------------------

#: Expression variables, as a set for membership checks.
EXPR_VARS = frozenset({
    "c", "r", "g", "b", "x", "y", "z", "u", "v", "ndl", "t", "pi",
})

#: Function name -> arity (frozen).
EXPR_FUNCS = {
    "sin": 1,
    "cos": 1,
    "tan": 1,
    "abs": 1,
    "sqrt": 1,
    "floor": 1,
    "ceil": 1,
    "fract": 1,
    "min": 2,
    "max": 2,
    "step": 2,
    "pow": 2,
    "clamp": 3,
    "mix": 3,
}

_BINARY_OPS = frozenset("+-*/%^")

# Binary-operator precedence; ``^`` is right-associative, the rest
# are left-associative. Unary minus (``neg``) sits between ``^`` and
# ``*`` so ``-2^2`` reads as ``-(2^2)``, matching ordinary maths.
_PRECEDENCE = {"+": 1, "-": 1, "*": 2, "/": 2, "%": 2, "neg": 3, "^": 4}
_RIGHT_ASSOC = frozenset({"^", "neg"})

_NUMBER_RE = re.compile(r"(?:\d+(?:\.\d*)?|\.\d+)")
_IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def _is_number(token):
    return isinstance(token, str) and _NUMBER_RE.fullmatch(token) is not None


def _is_ident(token):
    return isinstance(token, str) and _IDENT_RE.fullmatch(token) is not None


# ---------------------------------------------------------------------------
# Tokeniser
# ---------------------------------------------------------------------------
def tokenize_expr(src) -> list[str]:
    """Split an expression source string into tokens. Pure.

    Numbers are kept verbatim (``"0.50"`` stays ``"0.50"``),
    identifiers (variables and function names) are kept as written,
    and every operator / parenthesis / comma is its own
    single-character token. Whitespace separates tokens but is
    otherwise insignificant.

    Raises ``ValueError`` on a non-string input, on an invalid
    character, and on a malformed number such as ``1.2.3``. An
    empty / whitespace-only source gives ``[]`` (``to_rpn`` is
    responsible for rejecting an empty expression).
    """
    if not isinstance(src, str):
        raise ValueError(
            "shader expression must be a string, got %r" % (src,))
    tokens = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        if ch.isspace():
            i += 1
            continue
        if ch.isdigit() or (ch == "." and i + 1 < n
                            and src[i + 1].isdigit()):
            j = i
            while j < n and (src[j].isdigit() or src[j] == "."):
                j += 1
            text = src[i:j]
            if not _is_number(text):
                raise ValueError(
                    "malformed number %r in shader expression" % text)
            tokens.append(text)
            i = j
            continue
        if ch.isalpha() or ch == "_":
            j = i
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            tokens.append(src[i:j])
            i = j
            continue
        if ch in "+-*/%^(),":
            tokens.append(ch)
            i += 1
            continue
        raise ValueError(
            "invalid character %r in shader expression" % ch)
    return tokens


# ---------------------------------------------------------------------------
# Shunting-yard: infix tokens -> RPN
# ---------------------------------------------------------------------------
class _Paren:
    """One open parenthesis: grouping, or a function call frame."""

    __slots__ = ("func", "commas", "has_arg")

    def __init__(self, func=None):
        self.func = func        # function name, or None for grouping
        self.commas = 0         # commas seen at this level
        self.has_arg = False    # any operand completed at this level

    @property
    def argc(self):
        return self.commas + (1 if self.has_arg else 0)


def to_rpn(tokens) -> list[str]:
    """Compile infix *tokens* (from ``tokenize_expr``) to RPN.

    Shunting-yard. Numbers and variables pass through as-is, binary
    operators are emitted as their single character, unary minus is
    emitted as ``neg``, and a function name is emitted after its
    arguments.

    Raises ``ValueError`` with a clear message on: empty input, an
    unknown variable, an unknown function, a function called with
    the wrong number of arguments, unbalanced parentheses, a
    trailing operator, a missing operator between two operands, a
    comma outside a function call, and a malformed number token.
    """
    if tokens is None or isinstance(tokens, (str, bytes)):
        raise ValueError(
            "empty shader expression: no tokens to compile")
    tokens = list(tokens)
    if not tokens:
        raise ValueError("empty shader expression: nothing to compile")
    for token in tokens:
        if not isinstance(token, str):
            raise ValueError(
                "invalid token %r in shader expression" % (token,))

    output = []
    ops = []        # '(', a function name, a binary op, or 'neg'
    parens = []     # _Paren frames, parallel to the '(' entries in ops
    expect_operand = True

    def mark_arg():
        if parens:
            parens[-1].has_arg = True

    def pop_operator():
        op = ops.pop()
        output.append(op)
        return op

    def push_binary(op):
        prec = _PRECEDENCE[op]
        while ops and ops[-1] != "(" and ops[-1] not in EXPR_FUNCS:
            top = ops[-1]
            top_prec = _PRECEDENCE[top]
            if top_prec > prec or (top_prec == prec
                                   and op not in _RIGHT_ASSOC):
                pop_operator()
            else:
                break
        ops.append(op)

    i = 0
    while i < len(tokens):
        token = tokens[i]
        if expect_operand:
            if _is_number(token):
                output.append(token)
                mark_arg()
                expect_operand = False
            elif token in EXPR_FUNCS:
                if i + 1 >= len(tokens) or tokens[i + 1] != "(":
                    raise ValueError(
                        "function %r must be followed by '(' in "
                        "shader expression" % token)
                ops.append(token)
                # The '(' on the next iteration opens its frame.
            elif _is_ident(token):
                if i + 1 < len(tokens) and tokens[i + 1] == "(":
                    if token in EXPR_VARS:
                        raise ValueError(
                            "missing operator before '(' in shader "
                            "expression")
                    raise ValueError(
                        "unknown function %r in shader expression"
                        % token)
                if token not in EXPR_VARS:
                    raise ValueError(
                        "unknown variable %r in shader expression: "
                        "variables are %s"
                        % (token, " ".join(sorted(EXPR_VARS))))
                output.append(token)
                mark_arg()
                expect_operand = False
            elif token == "-":
                # Unary minus: pushed without popping, so it binds
                # to the operand that follows (``2 ^ -3``, ``-x``).
                ops.append("neg")
                # The operand that follows still marks the arg.
            elif token == "(":
                func = None
                if ops and ops[-1] in EXPR_FUNCS:
                    func = ops[-1]
                ops.append("(")
                parens.append(_Paren(func))
            elif token == ")":
                if not parens:
                    raise ValueError(
                        "unbalanced parentheses in shader expression: "
                        "unexpected ')'")
                frame = parens[-1]
                if frame.func is not None and not frame.has_arg \
                        and frame.commas == 0:
                    raise ValueError(
                        "function %r called with 0 arguments in "
                        "shader expression: %r expects %d argument(s)"
                        % (frame.func, frame.func,
                           EXPR_FUNCS[frame.func]))
                raise ValueError(
                    "missing operand before ')' in shader expression")
            elif token == ",":
                raise ValueError(
                    "missing operand before ',' in shader expression")
            elif token in _BINARY_OPS:
                raise ValueError(
                    "missing operand before operator %r in shader "
                    "expression" % token)
            elif token[0:1].isdigit() or token.startswith("."):
                raise ValueError(
                    "malformed number %r in shader expression" % token)
            else:
                raise ValueError(
                    "unknown token %r in shader expression" % token)
        else:
            if token in _BINARY_OPS:
                push_binary(token)
                expect_operand = True
            elif token == ",":
                if not parens:
                    raise ValueError(
                        "unbalanced parentheses in shader expression: "
                        "',' outside any parentheses")
                while ops and ops[-1] != "(":
                    pop_operator()
                if not ops:
                    raise ValueError(
                        "unbalanced parentheses in shader expression: "
                        "',' without a matching '('")
                frame = parens[-1]
                if frame.func is None:
                    raise ValueError(
                        "',' is only allowed inside a function call "
                        "in shader expression")
                if not frame.has_arg:
                    raise ValueError(
                        "missing argument before ',' in call to "
                        "function %r in shader expression" % frame.func)
                frame.commas += 1
                frame.has_arg = False
                expect_operand = True
            elif token == ")":
                if not parens:
                    raise ValueError(
                        "unbalanced parentheses in shader expression: "
                        "unexpected ')'")
                while ops and ops[-1] != "(":
                    pop_operator()
                if not ops:  # pragma: no cover - parens guards this
                    raise ValueError(
                        "unbalanced parentheses in shader expression: "
                        "unexpected ')'")
                ops.pop()  # discard the '('
                frame = parens.pop()
                if frame.func is not None:
                    if ops and ops[-1] == frame.func:
                        ops.pop()
                    argc = frame.argc
                    want = EXPR_FUNCS[frame.func]
                    if argc != want:
                        raise ValueError(
                            "function %r called with %d argument(s) "
                            "in shader expression: %r expects %d "
                            "argument(s)"
                            % (frame.func, argc, frame.func, want))
                    output.append(frame.func)
                elif not frame.has_arg and frame.commas == 0:
                    raise ValueError(
                        "empty parentheses in shader expression")
                mark_arg()
                # A closed group / call is itself an operand.
                expect_operand = False
            elif token == "(":
                raise ValueError(
                    "missing operator before '(' in shader expression")
            elif _is_number(token) or _is_ident(token) \
                    or token in EXPR_FUNCS:
                raise ValueError(
                    "missing operator before %r in shader expression"
                    % token)
            else:
                raise ValueError(
                    "unknown token %r in shader expression" % token)
        i += 1

    if parens or "(" in ops:
        raise ValueError(
            "unbalanced parentheses in shader expression: "
            "missing ')'")
    if expect_operand:
        last = tokens[-1]
        if last in _BINARY_OPS:
            raise ValueError(
                "trailing operator %r in shader expression: the "
                "expression ends before its right-hand operand" % last)
        if last in EXPR_FUNCS:
            raise ValueError(
                "function %r in shader expression has no argument "
                "list" % last)
        raise ValueError(
            "incomplete shader expression: an operand is missing "
            "at the end")
    while ops:
        op = ops.pop()
        if op == "(":  # pragma: no cover - checked above
            raise ValueError(
                "unbalanced parentheses in shader expression: "
                "missing ')'")
        output.append(op)
    if not output:  # pragma: no cover - empty input checked above
        raise ValueError("empty shader expression: nothing to compile")
    return output


# ---------------------------------------------------------------------------
# Validate an already-compiled shader definition
# ---------------------------------------------------------------------------
def validate_shader(name, rpn) -> list[str]:
    """Return human-readable errors for one shader definition.

    ``name`` is the shader's declared name and ``rpn`` its compiled
    token list as returned by ``to_rpn``. Checks: the name is a
    non-empty identifier; the RPN is a non-empty list; every token
    is a known number / variable / operator / function; and a stack
    simulation leaves exactly one value (no underflow from an
    operator or function, no leftover operands). Each message names
    the shader. An empty list means valid. The coordinator wraps
    these messages in E301-family diagnostics.
    """
    errors = []
    label = name if isinstance(name, str) and name.strip() else ""
    if not label:
        errors.append(
            "shader has no name: 'shader' must name the shader "
            "before its expression")
        label = "<unnamed>"
    elif not _NAME_RE.match(label.strip()):
        errors.append(
            "shader name %r is not a valid identifier: a shader "
            "name must start with a letter or '_' and contain only "
            "letters, digits and '_'" % (name,))

    if rpn is None or isinstance(rpn, (str, bytes)) \
            or not isinstance(rpn, (list, tuple)):
        errors.append(
            "shader %r has no compiled expression: its 'expr' must "
            "compile to a non-empty token list" % label)
        return errors
    if not rpn:
        errors.append(
            "shader %r has an empty expression: 'expr' must contain "
            "at least one token" % label)
        return errors

    depth = 0
    for token in rpn:
        if not isinstance(token, str):
            errors.append(
                "shader %r expression contains a non-token value "
                "%r" % (label, token))
            continue
        if _is_number(token):
            depth += 1
        elif token in EXPR_VARS:
            depth += 1
        elif token == "neg":
            if depth < 1:
                errors.append(
                    "shader %r expression applies unary minus with "
                    "no operand" % label)
            # neg consumes one value and produces one: depth fixed.
        elif token in _BINARY_OPS:
            if depth < 2:
                errors.append(
                    "shader %r expression applies operator %r with "
                    "fewer than two operands" % (label, token))
                depth = 1
            else:
                depth -= 1
        elif token in EXPR_FUNCS:
            arity = EXPR_FUNCS[token]
            if depth < arity:
                errors.append(
                    "shader %r expression calls function %r with "
                    "fewer than its %d argument(s)"
                    % (label, token, arity))
                depth = 1
            else:
                depth -= arity - 1
        elif _is_ident(token):
            errors.append(
                "shader %r expression contains unknown variable "
                "%r: variables are %s"
                % (label, token, " ".join(sorted(EXPR_VARS))))
            # Count it as a value so one bad name yields one error,
            # not a cascade of stack-shape errors after it.
            depth += 1
        else:
            errors.append(
                "shader %r expression contains unknown token %r"
                % (label, token))
    if depth != 1:
        errors.append(
            "shader %r expression leaves %d values instead of one: "
            "operands or operators are missing" % (label, depth))
    return errors


# ---------------------------------------------------------------------------
# Emit lines
# ---------------------------------------------------------------------------
def scene_lines(defs) -> list[str]:
    """Serialise shader definitions to their ``.scene`` lines::

        shaderdef NAME NTOK tok1 ... tokN

    ``defs`` is a list of ``(name, rpn)`` pairs, with ``rpn`` as
    returned by ``to_rpn``; one line is emitted per definition, in
    order. RPN tokens are joined verbatim, so a number keeps the
    exact spelling it had in the source expression. A definition
    with an empty RPN emits ``shaderdef NAME 0``. ``None`` / empty
    input gives ``[]``.
    """
    if not defs or not isinstance(defs, (list, tuple)):
        return []
    lines = []
    for item in defs:
        if isinstance(item, dict):
            name = item.get("name", "")
            rpn = item.get("rpn", item.get("tokens", []))
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            name, rpn = item
        else:  # pragma: no cover - defensive, off-contract input
            continue
        name = str(name).strip()
        tokens = [str(tok) for tok in rpn] if rpn else []
        if tokens:
            lines.append("shaderdef %s %d %s"
                         % (name, len(tokens), " ".join(tokens)))
        else:
            lines.append("shaderdef %s 0" % name)
    return lines


def binding_line(obj, shader_name) -> str:
    """Serialise one shader binding to its ``.scene`` line::

        shaderbind OBJ SHADER
    """
    return "shaderbind %s %s" % (str(obj).strip(),
                                 str(shader_name).strip())
