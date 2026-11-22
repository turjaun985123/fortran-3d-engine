"""Forge3D diagnostics: spans, error codes, and the error bag.

Phase-0 contract file (seat B02). Stdlib only.

Diagnostic style follows docs/plan/P08-error-ux.md and MASTER-PLAN.md S2:
every diagnostic says what happened, where (file:line:col), why it matters
(``why:``) and how to fix it (``help:``), in plain words. Error codes are
stable and append-only: once a code ships it is never reused or renumbered.

Families: E1xx syntax, E2xx names, E3xx ranges, E4xx structure,
E5xx IO, E8xx security/limits, Wxxx warnings.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

__all__ = [
    "Span",
    "Diagnostic",
    "ERROR_CODES",
    "ErrorBag",
    "ForgeError",
    "did_you_mean",
]


@dataclass
class Span:
    """A location in a source file. ``line``/``col`` are 1-based."""

    source: str
    line: int
    col: int
    length: int = 1


@dataclass
class Diagnostic:
    """One user-facing diagnostic: a header, a place, a why, and a fix."""

    code: str
    severity: str  # 'error' | 'warning'
    message: str
    span: Span | None = None
    why: str = ""
    help: str = ""

    def __post_init__(self) -> None:
        if self.severity not in ("error", "warning"):
            raise ValueError(
                f"severity must be 'error' or 'warning', got {self.severity!r}"
            )


# Stable, append-only code -> short title. Never reuse or renumber a code;
# new codes are appended with the next free number in their family.
ERROR_CODES: dict[str, str] = {
    "E101": "unexpected token",
    "E102": "expected number",
    "E103": "unterminated string",
    "E104": "unknown statement",
    "E110": "duplicate property",
    "E201": "unknown name/target",
    "E202": "unknown colour",
    "E203": "unknown primitive",
    "E204": "texture not in v1",
    "E205": "reserved keyword",
    "E301": "value out of range",
    "E302": "non-positive size",
    "E303": "fov range",
    "E401": "structure (group/end mismatch)",
    "E402": "no objects",
    "E501": "file not found",
    "E502": "cannot write output",
    "E820": "security/limit violation",
    "W101": "default injected",
    "W102": "statement replaced",
    "W201": "animation defaulted",
}


class ForgeError(Exception):
    """Raised by :meth:`ErrorBag.raise_if_errors`; carries the bag."""

    def __init__(self, bag: "ErrorBag | None" = None) -> None:
        self.bag: ErrorBag = bag if bag is not None else ErrorBag()
        text = self.bag.format_text()
        super().__init__(text if text else "Forge3D error")


class ErrorBag:
    """Collects diagnostics from every compiler stage; renders them once."""

    def __init__(self, diagnostics: list[Diagnostic] | None = None) -> None:
        self.diagnostics: list[Diagnostic] = list(diagnostics) if diagnostics else []
        self._source_text: str | None = None

    # -- collection ------------------------------------------------------

    def add(self, diag: Diagnostic) -> Diagnostic:
        self.diagnostics.append(diag)
        return diag

    def set_source(self, text: str) -> "ErrorBag":
        """Provide the source text so format_text() can show snippets."""
        self._source_text = text
        return self

    # -- queries ----------------------------------------------------------

    def errors(self) -> list[Diagnostic]:
        return [d for d in self.diagnostics if d.severity == "error"]

    def warnings(self) -> list[Diagnostic]:
        return [d for d in self.diagnostics if d.severity == "warning"]

    def has_errors(self) -> bool:
        return any(d.severity == "error" for d in self.diagnostics)

    def raise_if_errors(self) -> None:
        if self.has_errors():
            raise ForgeError(self)

    # -- rendering --------------------------------------------------------

    def _snippet_lines(self, diag: Diagnostic) -> list[str]:
        if self._source_text is None or diag.span is None:
            return []
        lines = self._source_text.splitlines()
        idx = diag.span.line - 1
        if idx < 0 or idx >= len(lines):
            return []
        text_line = lines[idx].expandtabs(8)
        # Column is measured on the raw line; expand tabs the same way so
        # the caret still lands under the offending characters.
        raw_prefix = lines[idx][: max(0, diag.span.col - 1)].expandtabs(8)
        caret = " " * len(raw_prefix) + "^" * max(1, diag.span.length)
        return [text_line, caret]

    def format_text(self, use_color: bool = False) -> str:
        blocks: list[str] = []
        for diag in self.diagnostics:
            if diag.span is not None:
                header = (
                    f"{diag.span.source}:{diag.span.line}:{diag.span.col}: "
                    f"{diag.severity} {diag.code}: {diag.message}"
                )
            else:
                header = f"{diag.severity} {diag.code}: {diag.message}"
            if use_color:
                colour = "1;31" if diag.severity == "error" else "1;33"
                header = f"\033[{colour}m{header}\033[0m"
            lines = [header]
            lines.extend(self._snippet_lines(diag))
            if diag.why:
                lines.append(f"  why: {diag.why}")
            if diag.help:
                lines.append(f"  help: {diag.help}")
            blocks.append("\n".join(lines))
        return "\n".join(blocks)

    def format_json(self) -> str:
        records = []
        for diag in self.diagnostics:
            span = diag.span
            records.append(
                {
                    "code": diag.code,
                    "severity": diag.severity,
                    "message": diag.message,
                    "file": span.source if span is not None else None,
                    "line": span.line if span is not None else None,
                    "col": span.col if span is not None else None,
                    "span": (
                        {
                            "source": span.source,
                            "line": span.line,
                            "col": span.col,
                            "length": span.length,
                        }
                        if span is not None
                        else None
                    ),
                    "why": diag.why,
                    "help": diag.help,
                }
            )
        return json.dumps(records, indent=2)


# -- did-you-mean ---------------------------------------------------------


def _damerau_levenshtein(a: str, b: str) -> int:
    """True Damerau-Levenshtein distance (transposition counts as 1)."""
    len_a, len_b = len(a), len(b)
    if len_a == 0:
        return len_b
    if len_b == 0:
        return len_a
    maxdist = len_a + len_b
    # d has an extra sentinel row/column, per the classic algorithm.
    d = [[0] * (len_b + 2) for _ in range(len_a + 2)]
    d[0][0] = maxdist
    for i in range(len_a + 1):
        d[i + 1][0] = maxdist
        d[i + 1][1] = i
    for j in range(len_b + 1):
        d[0][j + 1] = maxdist
        d[1][j + 1] = j
    last_row_for_char: dict[str, int] = {}
    for i in range(1, len_a + 1):
        last_match_col = 0
        for j in range(1, len_b + 1):
            i1 = last_row_for_char.get(b[j - 1], 0)
            j1 = last_match_col
            cost = 1
            if a[i - 1] == b[j - 1]:
                cost = 0
                last_match_col = j
            d[i + 1][j + 1] = min(
                d[i][j] + cost,  # substitution / match
                d[i + 1][j] + 1,  # insertion
                d[i][j + 1] + 1,  # deletion
                d[i1][j1] + (i - i1 - 1) + 1 + (j - j1 - 1),  # transposition
            )
        last_row_for_char[a[i - 1]] = i
    return d[len_a + 1][len_b + 1]


def did_you_mean(word: str, candidates) -> str | None:
    """Return the closest candidate within Damerau-Levenshtein distance 2.

    Matching is case-insensitive; the candidate is returned as written in
    ``candidates``. Returns ``None`` when nothing is close enough.
    """
    if not word or not candidates:
        return None
    lowered = word.lower()
    best: str | None = None
    best_dist = 3  # one past the <= 2 threshold
    for cand in candidates:
        if not cand:
            continue
        dist = _damerau_levenshtein(lowered, str(cand).lower())
        if dist < best_dist:
            best_dist = dist
            best = cand
            if dist == 0:
                break
    return best
