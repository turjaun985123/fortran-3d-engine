"""Lexer for the Forge3D ``.f3d`` language (seat B03).

Stdlib-only, line-oriented tokeniser per MASTER-PLAN section 1 and
P03 sections 2-4.

Token kinds are plain strings: ``WORD``, ``NUMBER``, ``STRING``,
``COLOR``, ``COMMA``, ``COLON``, ``NEWLINE`` and ``EOF``.  ``Token.text`` is the
raw lexeme exactly as written (a ``STRING`` keeps its quotes and a
``COLOR`` keeps its leading ``#``), and ``Token.span`` is an
``errors.Span`` with 1-based line/col.

Diagnostics are collected through the caller's ``ErrorBag`` (never
raised for ordinary lexical errors, so lexing can recover and
continue to the next character / line):

* ``E101`` -- unexpected / stray character.
* ``E102`` -- malformed number.
* ``E103`` -- unterminated string.
* ``E820`` -- security limit exceeded (input > 1 MiB, or a line
  longer than 4096 characters).
"""

from __future__ import annotations

from dataclasses import dataclass

try:  # Normal package import (B02's errors.py).
    from .errors import Diagnostic, Span
except Exception:  # pragma: no cover - direct / standalone use
    try:
        from errors import Diagnostic, Span  # type: ignore
    except Exception:
        # Fallback matching the frozen B02 contract, used only when
        # errors.py has not landed yet / the file is run standalone.
        # When errors.py is present its classes are always used.
        @dataclass(frozen=True)
        class Span:  # type: ignore[no-redef]
            source: str
            line: int
            col: int
            length: int

        @dataclass
        class Diagnostic:  # type: ignore[no-redef]
            code: str
            severity: str
            span: Span
            message: str
            hint: str | None = None


__all__ = [
    "Token",
    "tokenize",
    "WORD",
    "NUMBER",
    "STRING",
    "COLOR",
    "COMMA",
    "COLON",
    "NEWLINE",
    "EOF",
    "MAX_INPUT_BYTES",
    "MAX_LINE_CHARS",
]

WORD = "WORD"
NUMBER = "NUMBER"
STRING = "STRING"
COLOR = "COLOR"
COMMA = "COMMA"
COLON = "COLON"
NEWLINE = "NEWLINE"
EOF = "EOF"

MAX_INPUT_BYTES = 1024 * 1024  # 1 MiB
MAX_LINE_CHARS = 4096

_HEX = frozenset("0123456789abcdefABCDEF")


@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    span: Span


def _make_diagnostic(code, span, message, hint=None):
    """Build a B02 Diagnostic, tolerating minor constructor shapes."""
    attempts = (
        lambda: Diagnostic(
            code=code, severity="error", span=span, message=message,
            help=hint or "",
        ),
        lambda: Diagnostic(
            code=code, severity="error", span=span, message=message, hint=hint
        ),
        lambda: Diagnostic(code=code, severity="error", span=span, message=message),
        lambda: Diagnostic(code, span, message),
        lambda: Diagnostic(code, "error", span, message, hint),
    )
    last_exc = None
    for attempt in attempts:
        try:
            return attempt()
        except TypeError as exc:  # try the next plausible shape
            last_exc = exc
    raise last_exc  # type: ignore[misc]


def _report(bag, code, span, message, hint=None):
    """Add a diagnostic to *bag* via whichever API B02 provides."""
    if bag is None:
        return
    if isinstance(bag, list):
        bag.append(_make_diagnostic(code, span, message, hint))
        return

    diag = None

    def _diagnostic():
        nonlocal diag
        if diag is None:
            diag = _make_diagnostic(code, span, message, hint)
        return diag

    # Preferred: add(Diagnostic) / add(code, span, message, ...) etc.
    for method_name in ("add", "error", "add_error", "report", "append"):
        method = getattr(bag, method_name, None)
        if not callable(method):
            continue
        call_forms = (
            lambda m=method: m(_diagnostic()),
            lambda m=method: m(code, span, message),
            lambda m=method: m(
                code=code, span=span, message=message, hint=hint
            ),
            lambda m=method: m(code=code, span=span, message=message),
        )
        for form in call_forms:
            try:
                form()
                return
            except (TypeError, AttributeError):
                continue
    # Last resort: a public diagnostics/errors list on the bag.
    for attr in ("diagnostics", "errors", "items"):
        seq = getattr(bag, attr, None)
        if isinstance(seq, list):
            seq.append(_diagnostic())
            return
    # If no known sink exists, surface the error rather than hide it.
    raise TypeError("ErrorBag object does not accept diagnostics")


def _is_word_start(ch):
    return ch.isalpha() or ch == "_"


def _is_word_char(ch):
    return ch.isalnum() or ch in "_-"


def _is_color_at(line, i):
    """True iff line[i:] is '#' + exactly 6 hex digits + word boundary."""
    if i + 7 > len(line):
        return False
    if any(c not in _HEX for c in line[i + 1 : i + 7]):
        return False
    # Exactly six: a seventh word character (hex digit, letter,
    # digit, '_' or '-') means this is not a #RRGGBB literal.
    if i + 7 < len(line) and _is_word_char(line[i + 7]):
        return False
    return True


def tokenize(text, source_name, bag):
    """Tokenise *text* from *source_name*, reporting errors to *bag*.

    Returns a list of :class:`Token` always ending in one ``EOF``
    token.  Lexical errors are reported to *bag* and lexing recovers
    (skips the offending character / rest of a malformed token).
    """
    if isinstance(text, (bytes, bytearray)):
        raw = bytes(text)
        if len(raw) > MAX_INPUT_BYTES:
            _report(
                bag, "E820", Span(source_name, 1, 1, 1),
                "input is larger than the 1 MiB limit",
                "split the scene into smaller files",
            )
            return [Token(EOF, "", Span(source_name, 1, 1, 0))]
        text = raw.decode("utf-8", errors="replace")
    elif len(text.encode("utf-8", errors="ignore")) > MAX_INPUT_BYTES:
        _report(
            bag, "E820", Span(source_name, 1, 1, 1),
            "input is larger than the 1 MiB limit",
            "split the scene into smaller files",
        )
        return [Token(EOF, "", Span(source_name, 1, 1, 0))]

    tokens: list[Token] = []
    lines = text.splitlines(keepends=True)
    line_no = 0

    for raw_line in lines:
        line_no += 1
        # Separate the line terminator so spans/text stay accurate.
        if raw_line.endswith("\r\n"):
            content, terminator = raw_line[:-2], "\r\n"
        elif raw_line.endswith(("\n", "\r")):
            content, terminator = raw_line[:-1], raw_line[-1]
        else:
            content, terminator = raw_line, ""

        if len(content) > MAX_LINE_CHARS:
            _report(
                bag, "E820",
                Span(source_name, line_no, MAX_LINE_CHARS + 1, 1),
                "line is longer than the 4096 character limit",
                "split the statement across shorter lines",
            )
            content = content[:MAX_LINE_CHARS]

        i = 0
        n = len(content)
        while i < n:
            ch = content[i]
            col = i + 1  # 1-based

            # Whitespace (spaces/tabs) separates tokens only.
            if ch in " \t\f\v":
                i += 1
                continue

            # Comments: '//' to end of line.
            if ch == "/" and i + 1 < n and content[i + 1] == "/":
                i = n
                break

            # '#' : COLOR literal, otherwise a comment to end of line.
            if ch == "#":
                if _is_color_at(content, i):
                    tokens.append(
                        Token(COLOR, content[i : i + 7],
                              Span(source_name, line_no, col, 7))
                    )
                    i += 7
                    continue
                i = n
                break

            # Commas are tokens in their own right (parser may skip).
            if ch == ",":
                tokens.append(
                    Token(COMMA, ",", Span(source_name, line_no, col, 1))
                )
                i += 1
                continue

            # Colons are tokens in their own right (parser may skip),
            # e.g. 'texture: "path"' in property syntax.
            if ch == ":":
                tokens.append(
                    Token(COLON, ":", Span(source_name, line_no, col, 1))
                )
                i += 1
                continue

            # Double-quoted string, no escapes, cannot span lines.
            if ch == '"':
                end = content.find('"', i + 1)
                if end == -1:
                    lexeme = content[i:]
                    span = Span(source_name, line_no, col, len(lexeme))
                    _report(
                        bag, "E103", span,
                        "unterminated string: missing closing '\"'",
                        'add a closing " at the end of the string',
                    )
                    tokens.append(Token(STRING, lexeme, span))
                    i = n
                    break
                lexeme = content[i : end + 1]
                tokens.append(
                    Token(STRING, lexeme,
                          Span(source_name, line_no, col, len(lexeme)))
                )
                i = end + 1
                continue

            # Number: optional '-', digits, optional decimal part.
            # No exponent in v1 (P03 section 2).
            if ch.isdigit() or (
                ch == "-" and i + 1 < n and content[i + 1].isdigit()
            ):
                start = i
                if content[i] == "-":
                    i += 1
                while i < n and content[i].isdigit():
                    i += 1
                malformed = False
                if i < n and content[i] == ".":
                    malformed = True  # cleared if digits follow
                    i += 1
                    frac_start = i
                    while i < n and content[i].isdigit():
                        i += 1
                    if i > frac_start:
                        malformed = False
                    # A second '.' (e.g. 1.2.3) is malformed.
                    if i < n and content[i] == ".":
                        malformed = True
                        i += 1
                        while i < n and (
                            content[i].isdigit() or content[i] == "."
                        ):
                            i += 1
                if i < n and (content[i].isalpha() or content[i] == "_"):
                    # '640x480': 'x' joins two numbers in the parser,
                    # so it starts a separate WORD token, not an error.
                    if content[i] not in "xX":
                        malformed = True
                        while i < n and _is_word_char(content[i]):
                            i += 1
                lexeme = content[start:i]
                if malformed:
                    _report(
                        bag, "E102",
                        Span(source_name, line_no, start + 1, len(lexeme)),
                        f"malformed number '{lexeme}'",
                        "write a number like 2, -1.5 or 0.25 "
                        "(no exponent)",
                    )
                tokens.append(
                    Token(NUMBER, lexeme,
                          Span(source_name, line_no, start + 1, len(lexeme)))
                )
                continue

            # Word: letter/'_' then letters/digits/'_'/'-'.
            if _is_word_start(ch):
                start = i
                i += 1
                while i < n and _is_word_char(content[i]):
                    i += 1
                lexeme = content[start:i]
                tokens.append(
                    Token(WORD, lexeme,
                          Span(source_name, line_no, start + 1, len(lexeme)))
                )
                continue

            # Anything else is a stray character: report and skip it.
            _report(
                bag, "E101", Span(source_name, line_no, col, 1),
                f"unexpected character '{ch}'",
                "remove this character",
            )
            i += 1

        if terminator:
            tokens.append(
                Token(NEWLINE, "\n",
                      Span(source_name, line_no, len(content) + 1,
                           len(terminator)))
            )

    # EOF: positioned just past the last character of the last line.
    if lines:
        last = lines[-1]
        last_content = last.rstrip("\r\n")
        if last.endswith(("\n", "\r")):
            eof_line, eof_col = line_no + 1, 1
        else:
            eof_line, eof_col = line_no, len(last_content) + 1
    else:
        eof_line, eof_col = 1, 1
    tokens.append(Token(EOF, "", Span(source_name, eof_line, eof_col, 0)))
    return tokens
