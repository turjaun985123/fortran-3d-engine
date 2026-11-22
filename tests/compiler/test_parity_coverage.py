#!/usr/bin/env python3
"""Parity coverage / stop-rule tests (seat B86, MASTER-PLAN section 3).

Stdlib ``unittest`` only; standalone-runnable::

    python3 tests/compiler/test_parity_coverage.py

This is the governance gate for the Feature-Parity Matrix
(MASTER-PLAN section 3, rows 1-36).  Waves continue until B86 reports
100 % ``Done-verified`` -- that is the stop rule.

Cross-check design (deliberate): seat B85 owns the parity generator
(``tools/parity_matrix.py``), ``docs/parity-status.json`` and the
generated ``docs/parity-matrix.json``.  This test does **not** import
or reuse B85's parser.  It parses the section 3 tables in
``docs/plan/MASTER-PLAN.md`` itself, from scratch, and checks B85's
artefacts against that independent reading -- a re-run of the same
code could not catch a parser bug shared by both sides.

Contracts checked:

* MASTER-PLAN section 3 contains exactly rows 1..36.
* ``docs/parity-status.json`` maps every row 1..36 to
  ``{"status": ..., "evidence": ...}`` where ``status`` is one of the
  allowed values only and ``evidence`` is a non-empty string.
* Every ``Done-verified`` row cites proof: its evidence names at
  least one test (contains "test", case-insensitively).
* Coverage (% of rows that are ``Done-verified``) is printed, and is
  >= the baseline recorded in ``parity-status.json`` under the
  top-level key ``_baseline_pct``.  A missing ``_baseline_pct`` key is
  a failure naming the key (the baseline is what stops coverage from
  silently regressing between waves).
* ``docs/parity-matrix.json`` exists and its row count matches the
  number of row entries in ``parity-status.json``.
"""

import json
import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))

MASTER_PLAN = os.path.join(REPO_ROOT, "docs", "plan", "MASTER-PLAN.md")
STATUS_JSON = os.path.join(REPO_ROOT, "docs", "parity-status.json")
MATRIX_JSON = os.path.join(REPO_ROOT, "docs", "parity-matrix.json")

EXPECTED_ROWS = list(range(1, 37))

ALLOWED_STATUSES = {
    "Done-verified",
    "In-wave-C",
    "Queued-wave-3",
    "Queued-continuous",
    "Blocked",
}

BASELINE_KEY = "_baseline_pct"


# ---------------------------------------------------------------------------
# Independent section-3 parser (B86's own; shares no code with B85)
# ---------------------------------------------------------------------------

def parse_master_plan_section3_rows(path=MASTER_PLAN):
    """Return the row numbers in the MASTER-PLAN section 3 tables.

    Section 3 runs from its ``## 3.`` heading to the next ``## ``
    heading (``## 4.``).  Inside it, a matrix row is a Markdown table
    line whose first cell is a bare integer (the ``#`` column of
    tables 3A and 3B).  Header and separator rows have no integer
    first cell and are ignored.
    """
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    in_section3 = False
    rows = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("## "):
            if stripped.startswith("## 3."):
                in_section3 = True
                continue
            if in_section3:
                break
        if not in_section3:
            continue
        if not stripped.startswith("|"):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if cells and re.fullmatch(r"\d+", cells[0]):
            rows.append(int(cells[0]))
    return rows


# ---------------------------------------------------------------------------
# parity-status.json / parity-matrix.json helpers
# ---------------------------------------------------------------------------

def status_row_entries(status_data):
    """Extract ``{row_number: entry}`` from parsed parity-status.json.

    The contract shape is a top-level object mapping a row number to
    ``{"status": ..., "evidence": ...}``, alongside top-level
    metadata keys such as ``_baseline_pct``.  A ``rows`` sub-object of
    the same shape is also accepted, so the check follows the data
    rather than one serialisation detail.
    """
    if not isinstance(status_data, dict):
        return {}
    container = status_data
    rows_value = status_data.get("rows")
    if isinstance(rows_value, dict):
        container = rows_value
    elif isinstance(rows_value, list):
        entries = {}
        for item in rows_value:
            if isinstance(item, dict) and "row" in item:
                entries[int(item["row"])] = item
        return entries
    entries = {}
    for key, value in container.items():
        if isinstance(key, str) and re.fullmatch(r"\d+", key):
            entries[int(key)] = value
    return entries


def status_all_entry_count(status_data):
    """Count every row entry in parity-status.json.

    Beyond rows 1..36 the status file may carry extra continuous-wave
    entries (B85 uses ids such as ``C1``..``C4`` for skinning/morph,
    custom shaders, WebGL2, XR).  A row entry is a top-level value
    that is an object carrying a ``status`` field; top-level metadata
    such as ``_baseline_pct`` is not a row entry.
    """
    if not isinstance(status_data, dict):
        return 0
    return len([value for value in status_data.values()
                if isinstance(value, dict) and "status" in value])


def matrix_rows(matrix_data):
    """Return the row items of parsed parity-matrix.json as a list.

    Accepts the plausible generated shapes: a top-level list of rows,
    a top-level object mapping row ids to entries, or an object with
    a ``rows`` list/object of either shape.
    """
    if isinstance(matrix_data, list):
        return list(matrix_data)
    if isinstance(matrix_data, dict):
        rows_value = matrix_data.get("rows")
        if isinstance(rows_value, list):
            return list(rows_value)
        if isinstance(rows_value, dict):
            return list(rows_value.values())
        return [value for key, value in matrix_data.items()
                if isinstance(key, str)
                and re.fullmatch(r"\d+", key)]
    return []


def coverage_pct(entries):
    """Percentage (0-100) of rows 1..36 whose status is Done-verified."""
    done = sum(1 for row in EXPECTED_ROWS
               if isinstance(entries.get(row), dict)
               and entries[row].get("status") == "Done-verified")
    return 100.0 * done / len(EXPECTED_ROWS), done


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestMasterPlanSection3(unittest.TestCase):
    def test_section3_rows_1_to_36_all_present(self):
        rows = parse_master_plan_section3_rows()
        self.assertEqual(
            sorted(set(rows)), EXPECTED_ROWS,
            "MASTER-PLAN section 3 must contain rows 1..36 exactly; "
            "parsed rows were %r" % (sorted(set(rows)),))

    def test_section3_rows_have_no_duplicates(self):
        rows = parse_master_plan_section3_rows()
        self.assertEqual(
            len(rows), len(set(rows)),
            "duplicate row numbers in MASTER-PLAN section 3: %r"
            % (rows,))


class ParityStatusTestBase(unittest.TestCase):
    """Loads parity-status.json once; failures name the real problem."""

    status_data = None
    status_error = None
    entries = {}

    @classmethod
    def setUpClass(cls):
        try:
            cls.status_data = load_json(STATUS_JSON)
            cls.entries = status_row_entries(cls.status_data)
        except Exception as exc:  # file missing / bad JSON: report, don't hide
            cls.status_error = exc
            cls.status_data = None
            cls.entries = {}

    def require_status(self):
        if self.status_error is not None:
            self.fail("docs/parity-status.json could not be loaded: %s"
                      % (self.status_error,))
        self.assertIsNotNone(
            self.status_data,
            "docs/parity-status.json could not be loaded")


class TestParityStatus(ParityStatusTestBase):
    def test_status_file_covers_rows_1_to_36(self):
        self.require_status()
        missing = [row for row in EXPECTED_ROWS if row not in self.entries]
        self.assertEqual(
            missing, [],
            "parity-status.json has no entry for rows %r" % (missing,))
        extra = sorted(set(self.entries) - set(EXPECTED_ROWS))
        self.assertEqual(
            extra, [],
            "parity-status.json has entries for rows outside 1..36: %r"
            % (extra,))

    def test_every_row_status_allowed_and_evidence_non_empty(self):
        self.require_status()
        problems = []
        for row in EXPECTED_ROWS:
            entry = self.entries.get(row)
            if not isinstance(entry, dict):
                problems.append("row %d: entry is not an object" % row)
                continue
            status = entry.get("status")
            if status not in ALLOWED_STATUSES:
                problems.append(
                    "row %d: status %r is not one of %r"
                    % (row, status, sorted(ALLOWED_STATUSES)))
            evidence = entry.get("evidence")
            if not isinstance(evidence, str) or not evidence.strip():
                problems.append(
                    "row %d: evidence is missing or empty" % row)
        self.assertEqual(problems, [], "\n".join(problems))

    def test_done_verified_rows_cite_a_test_as_evidence(self):
        self.require_status()
        problems = []
        for row in EXPECTED_ROWS:
            entry = self.entries.get(row)
            if not isinstance(entry, dict):
                continue
            if entry.get("status") != "Done-verified":
                continue
            evidence = entry.get("evidence") or ""
            if "test" not in evidence.lower():
                problems.append(
                    "row %d: Done-verified but evidence names no test: %r"
                    % (row, evidence))
        self.assertEqual(
            problems, [], "\n".join(problems))

    def test_coverage_meets_recorded_baseline_and_is_printed(self):
        self.require_status()
        coverage, done = coverage_pct(self.entries)
        # The stop rule made visible: waves continue until this is 100%.
        print("\nParity coverage (Done-verified): %.1f%% "
              "(%d/%d rows) -- stop rule: waves continue until 100%%"
              % (coverage, done, len(EXPECTED_ROWS)))
        self.assertIsInstance(
            self.status_data, dict,
            "parity-status.json top level must be an object holding %r"
            % (BASELINE_KEY,))
        self.assertIn(
            BASELINE_KEY, self.status_data,
            "parity-status.json is missing the required top-level "
            "baseline key %r: coverage has no recorded floor to be "
            "checked against (seat B85 / wiring must add it)"
            % (BASELINE_KEY,))
        baseline = self.status_data[BASELINE_KEY]
        self.assertIsInstance(
            baseline, (int, float),
            "%r must be a number, got %r" % (BASELINE_KEY, baseline))
        self.assertGreaterEqual(
            coverage, float(baseline),
            "parity coverage %.1f%% regressed below the recorded "
            "baseline %r (%s)" % (coverage, baseline, BASELINE_KEY))


class TestParityMatrix(ParityStatusTestBase):
    def test_matrix_exists_and_row_count_matches_status_file(self):
        self.require_status()
        self.assertTrue(
            os.path.isfile(MATRIX_JSON),
            "docs/parity-matrix.json does not exist (B85 generates it)")
        matrix_data = load_json(MATRIX_JSON)
        rows = matrix_rows(matrix_data)
        status_count = status_all_entry_count(self.status_data)
        self.assertEqual(
            len(rows), status_count,
            "parity-matrix.json has %d rows but parity-status.json "
            "has %d row entries" % (len(rows), status_count))
        numeric_ids = sorted(
            item["row"] for item in rows
            if isinstance(item, dict)
            and isinstance(item.get("row"), int))
        self.assertEqual(
            numeric_ids, EXPECTED_ROWS,
            "parity-matrix.json numeric row ids should be exactly "
            "1..36, found %r" % (numeric_ids,))


if __name__ == "__main__":
    unittest.main()
