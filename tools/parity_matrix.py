#!/usr/bin/env python3
"""Forge3D parity-matrix generator (Wave C seat B85, MASTER-PLAN section 3).

Parses the two tables in docs/plan/MASTER-PLAN.md section 3 (rows 1-28
Three.js, 29-36 PixiJS), merges statuses from docs/parity-status.json,
and writes docs/parity-matrix.json plus a coverage report on stdout.

Statuses allowed ONLY: Done-verified, In-wave-C, Queued-wave-3,
Queued-continuous, Blocked.

Extra entries in parity-status.json whose key is not a section-3 row
number (e.g. "C1".."C4" for the continuous items named in MASTER-PLAN
section 4 continuous text / section 7, not as section-3 rows) are
included as extra rows when they carry their own feature /
forge3d_equivalent / wave / proof_test / better_metric fields.

Exits nonzero if a matrix row lacks a status or a status is invalid.
Python standard library only. Output is deterministic: re-running
regenerates an identical docs/parity-matrix.json.
"""

import json
import re
import sys
from pathlib import Path

ALLOWED_STATUSES = (
    "Done-verified",
    "In-wave-C",
    "Queued-wave-3",
    "Queued-continuous",
    "Blocked",
)

ROOT = Path(__file__).resolve().parent.parent
PLAN_PATH = ROOT / "docs" / "plan" / "MASTER-PLAN.md"
STATUS_PATH = ROOT / "docs" / "parity-status.json"
OUTPUT_PATH = ROOT / "docs" / "parity-matrix.json"


def fail(message):
    print(f"parity_matrix: ERROR: {message}", file=sys.stderr)
    return 1


def split_row(line):
    """Split a Markdown table row into stripped cells."""
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|"):
        text = text[:-1]
    return [cell.strip() for cell in text.split("|")]


def is_separator(cells):
    return all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells if cell)


def parse_plan_tables(plan_text):
    """Extract rows 1-36 from the section-3 tables of MASTER-PLAN.md."""
    # Isolate section 3 (from '## 3.' up to '## 4.').
    start = plan_text.find("## 3.")
    if start < 0:
        raise ValueError("MASTER-PLAN.md: section 3 heading not found")
    end = plan_text.find("## 4.", start)
    if end < 0:
        end = len(plan_text)
    section = plan_text[start:end]

    rows = []
    for line in section.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = split_row(line)
        if len(cells) != 6 or not cells[0].isdigit():
            continue
        if is_separator(cells):
            continue
        rows.append(
            {
                "row": int(cells[0]),
                "feature": cells[1],
                "forge3d_equivalent": cells[2],
                "wave": cells[3],
                "proof_test": cells[4],
                "better_metric": cells[5],
            }
        )
    rows.sort(key=lambda r: r["row"])
    numbers = [r["row"] for r in rows]
    if numbers != list(range(1, 37)):
        raise ValueError(
            f"MASTER-PLAN.md section 3: expected rows 1-36, got {numbers}"
        )
    return rows


def main():
    try:
        plan_text = PLAN_PATH.read_text(encoding="utf-8")
        rows = parse_plan_tables(plan_text)
    except (OSError, ValueError) as exc:
        return fail(str(exc))

    try:
        statuses = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return fail(f"cannot read {STATUS_PATH}: {exc}")
    if not isinstance(statuses, dict):
        return fail("parity-status.json must be a JSON object (map row -> status)")

    errors = []

    def check_entry(key, entry):
        """Validate one status entry; return (status, evidence) or None."""
        if not isinstance(entry, dict) or "status" not in entry:
            errors.append(f"row {key}: missing status")
            return None
        status = entry["status"]
        if status not in ALLOWED_STATUSES:
            errors.append(
                f"row {key}: invalid status {status!r} "
                f"(allowed: {', '.join(ALLOWED_STATUSES)})"
            )
            return None
        return status, entry.get("evidence", "")

    merged = []
    known_keys = set()
    for row in rows:
        key = str(row["row"])
        known_keys.add(key)
        entry = statuses.get(key)
        if entry is None:
            errors.append(f"row {key}: lacks a status in parity-status.json")
            continue
        checked = check_entry(key, entry)
        if checked is None:
            continue
        status, evidence = checked
        merged.append({**row, "status": status, "evidence": evidence})

    # Extra entries (e.g. C1..C4 continuous items): not section-3 rows,
    # so they must carry their own descriptive fields. Keys starting
    # with "_" are file metadata (e.g. _baseline_pct for the B86
    # coverage test), not rows — skip them (Wave C coordinator wiring).
    extra_keys = [k for k in statuses
                  if k not in known_keys and not k.startswith("_")]
    for key in sorted(extra_keys):
        entry = statuses[key]
        checked = check_entry(key, entry)
        if checked is None:
            continue
        status, evidence = checked
        missing = [
            field
            for field in (
                "feature",
                "forge3d_equivalent",
                "wave",
                "proof_test",
                "better_metric",
            )
            if field not in entry
        ]
        if missing:
            errors.append(
                f"extra row {key}: missing field(s) {', '.join(missing)} "
                "(extra rows are not in the MASTER-PLAN section 3 tables, "
                "so parity-status.json must supply them)"
            )
            continue
        merged.append(
            {
                "row": key,
                "feature": entry["feature"],
                "forge3d_equivalent": entry["forge3d_equivalent"],
                "wave": entry["wave"],
                "proof_test": entry["proof_test"],
                "better_metric": entry["better_metric"],
                "status": status,
                "evidence": evidence,
            }
        )

    if errors:
        for message in errors:
            print(f"parity_matrix: ERROR: {message}", file=sys.stderr)
        return 1

    counts = {status: 0 for status in ALLOWED_STATUSES}
    for row in merged:
        counts[row["status"]] += 1
    total = len(merged)
    done = counts["Done-verified"]
    percent = (100.0 * done / total) if total else 0.0

    document = {
        "source_plan": "docs/plan/MASTER-PLAN.md",
        "source_status": "docs/parity-status.json",
        "rows": merged,
        "coverage": {
            "total_rows": total,
            "counts": counts,
            "done_verified": done,
            "done_verified_percent": round(percent, 1),
        },
    }
    OUTPUT_PATH.write_text(
        json.dumps(document, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print("Forge3D parity coverage (MASTER-PLAN section 3 + continuous extras)")
    print(f"Total rows: {total}")
    for status in ALLOWED_STATUSES:
        print(f"  {status}: {counts[status]}")
    print(f"Done-verified: {done}/{total} = {percent:.1f}%")
    print(f"Wrote {OUTPUT_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
