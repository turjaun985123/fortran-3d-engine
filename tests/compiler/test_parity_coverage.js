#!/usr/bin/env node
"use strict";
/**
 * Parity coverage / stop-rule tests (seat B86, MASTER-PLAN section 3).
 *
 * Node.js builtins only; standalone-runnable::
 *
 *     node tests/compiler/test_parity_coverage.js
 *
 * Port of tests/compiler/test_parity_coverage.py. This is the
 * governance gate for the Feature-Parity Matrix (MASTER-PLAN
 * section 3, rows 1-36). Waves continue until B86 reports
 * 100 % ``Done-verified`` -- that is the stop rule.
 *
 * Cross-check design (deliberate): seat B85 owns the parity generator
 * (``tools/parity_matrix.py``), ``docs/parity-status.json`` and the
 * generated ``docs/parity-matrix.json``. This test does **not** reuse
 * B85's parser. It parses the section 3 tables in
 * ``docs/plan/MASTER-PLAN.md`` itself, from scratch, and checks B85's
 * artefacts against that independent reading -- a re-run of the same
 * code could not catch a parser bug shared by both sides.
 *
 * Contracts checked:
 *
 * * MASTER-PLAN section 3 contains exactly rows 1..36.
 * * ``docs/parity-status.json`` maps every row 1..36 to
 *   ``{"status": ..., "evidence": ...}`` where ``status`` is one of the
 *   allowed values only and ``evidence`` is a non-empty string.
 * * Every ``Done-verified`` row cites proof: its evidence names at
 *   least one test (contains "test", case-insensitively).
 * * Coverage (% of rows that are ``Done-verified``) is printed, and is
 *   >= the baseline recorded in ``parity-status.json`` under the
 *   top-level key ``_baseline_pct``. A missing ``_baseline_pct`` key is
 *   a failure naming the key (the baseline is what stops coverage from
 *   silently regressing between waves).
 * * ``docs/parity-matrix.json`` exists and its row count matches the
 *   number of row entries in ``parity-status.json``.
 */

const fs = require("fs");
const path = require("path");
const assert = require("assert");

const REPO_ROOT = path.join(__dirname, "..", "..");

const MASTER_PLAN = path.join(REPO_ROOT, "docs", "plan", "MASTER-PLAN.md");
const STATUS_JSON = path.join(REPO_ROOT, "docs", "parity-status.json");
const MATRIX_JSON = path.join(REPO_ROOT, "docs", "parity-matrix.json");

const EXPECTED_ROWS = Array.from({ length: 36 }, (_, i) => i + 1);

const ALLOWED_STATUSES = new Set([
  "Done-verified",
  "In-wave-C",
  "Queued-wave-3",
  "Queued-continuous",
  "Blocked",
]);

const BASELINE_KEY = "_baseline_pct";

// ---------------------------------------------------------------------------
// Independent section-3 parser (B86's own; shares no code with B85)
// ---------------------------------------------------------------------------

function parseMasterPlanSection3Rows(filePath = MASTER_PLAN) {
  // Return the row numbers in the MASTER-PLAN section 3 tables.
  //
  // Section 3 runs from its ``## 3.`` heading to the next ``## ``
  // heading (``## 4.``). Inside it, a matrix row is a Markdown table
  // line whose first cell is a bare integer (the ``#`` column of
  // tables 3A and 3B). Header and separator rows have no integer
  // first cell and are ignored.
  const lines = fs.readFileSync(filePath, "utf-8").split(/\r?\n/);

  let inSection3 = false;
  const rows = [];
  for (const line of lines) {
    const stripped = line.trim();
    if (stripped.startsWith("## ")) {
      if (stripped.startsWith("## 3.")) {
        inSection3 = true;
        continue;
      }
      if (inSection3) {
        break;
      }
    }
    if (!inSection3) {
      continue;
    }
    if (!stripped.startsWith("|")) {
      continue;
    }
    const cells = stripped
      .replace(/^\|+/, "")
      .replace(/\|+$/, "")
      .split("|")
      .map((cell) => cell.trim());
    if (cells.length && /^\d+$/.test(cells[0])) {
      rows.push(parseInt(cells[0], 10));
    }
  }
  return rows;
}

// ---------------------------------------------------------------------------
// parity-status.json / parity-matrix.json helpers
// ---------------------------------------------------------------------------

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function statusRowEntries(statusData) {
  // Extract ``{row_number: entry}`` from parsed parity-status.json.
  //
  // The contract shape is a top-level object mapping a row number to
  // ``{"status": ..., "evidence": ...}``, alongside top-level
  // metadata keys such as ``_baseline_pct``. A ``rows`` sub-object of
  // the same shape is also accepted, so the check follows the data
  // rather than one serialisation detail.
  if (!isPlainObject(statusData)) {
    return {};
  }
  let container = statusData;
  const rowsValue = statusData["rows"];
  if (isPlainObject(rowsValue)) {
    container = rowsValue;
  } else if (Array.isArray(rowsValue)) {
    const entries = {};
    for (const item of rowsValue) {
      if (isPlainObject(item) && "row" in item) {
        entries[parseInt(item["row"], 10)] = item;
      }
    }
    return entries;
  }
  const entries = {};
  for (const [key, value] of Object.entries(container)) {
    if (typeof key === "string" && /^\d+$/.test(key)) {
      entries[parseInt(key, 10)] = value;
    }
  }
  return entries;
}

function statusAllEntryCount(statusData) {
  // Count every row entry in parity-status.json.
  //
  // Beyond rows 1..36 the status file may carry extra continuous-wave
  // entries (B85 uses ids such as ``C1``..``C4`` for skinning/morph,
  // custom shaders, WebGL2, XR). A row entry is a top-level value
  // that is an object carrying a ``status`` field; top-level metadata
  // such as ``_baseline_pct`` is not a row entry.
  if (!isPlainObject(statusData)) {
    return 0;
  }
  return Object.values(statusData).filter(
    (value) => isPlainObject(value) && "status" in value
  ).length;
}

function matrixRows(matrixData) {
  // Return the row items of parsed parity-matrix.json as a list.
  //
  // Accepts the plausible generated shapes: a top-level list of rows,
  // a top-level object mapping row ids to entries, or an object with
  // a ``rows`` list/object of either shape.
  if (Array.isArray(matrixData)) {
    return [...matrixData];
  }
  if (isPlainObject(matrixData)) {
    const rowsValue = matrixData["rows"];
    if (Array.isArray(rowsValue)) {
      return [...rowsValue];
    }
    if (isPlainObject(rowsValue)) {
      return Object.values(rowsValue);
    }
    return Object.entries(matrixData)
      .filter(([key]) => typeof key === "string" && /^\d+$/.test(key))
      .map(([, value]) => value);
  }
  return [];
}

function coveragePct(entries) {
  // Percentage (0-100) of rows 1..36 whose status is Done-verified.
  const done = EXPECTED_ROWS.filter(
    (row) =>
      isPlainObject(entries[row]) && entries[row]["status"] === "Done-verified"
  ).length;
  return [(100.0 * done) / EXPECTED_ROWS.length, done];
}

function loadJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf-8"));
}

// ---------------------------------------------------------------------------
// Shared parity-status loading (mirrors ParityStatusTestBase)
// ---------------------------------------------------------------------------

let statusData = null;
let statusError = null;
let statusEntries = {};
try {
  statusData = loadJson(STATUS_JSON);
  statusEntries = statusRowEntries(statusData);
} catch (exc) {
  // file missing / bad JSON: report, don't hide
  statusError = exc;
  statusData = null;
  statusEntries = {};
}

function requireStatus() {
  if (statusError !== null) {
    assert.fail(
      `docs/parity-status.json could not be loaded: ${statusError}`
    );
  }
  assert.notStrictEqual(
    statusData,
    null,
    "docs/parity-status.json could not be loaded"
  );
  // Mirror Python assertIsNotNone's None check for the undefined case too.
  assert.ok(
    statusData !== undefined,
    "docs/parity-status.json could not be loaded"
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

function repr(value) {
  return JSON.stringify(value);
}

const tests = [];

function test(name, fn) {
  tests.push([name, fn]);
}

test("test_section3_rows_1_to_36_all_present", () => {
  const rows = parseMasterPlanSection3Rows();
  const uniqueSorted = [...new Set(rows)].sort((a, b) => a - b);
  assert.deepStrictEqual(
    uniqueSorted,
    EXPECTED_ROWS,
    "MASTER-PLAN section 3 must contain rows 1..36 exactly; " +
      `parsed rows were ${repr(uniqueSorted)}`
  );
});

test("test_section3_rows_have_no_duplicates", () => {
  const rows = parseMasterPlanSection3Rows();
  assert.strictEqual(
    rows.length,
    new Set(rows).size,
    `duplicate row numbers in MASTER-PLAN section 3: ${repr(rows)}`
  );
});

test("test_status_file_covers_rows_1_to_36", () => {
  requireStatus();
  const missing = EXPECTED_ROWS.filter(
    (row) => !Object.prototype.hasOwnProperty.call(statusEntries, row)
  );
  assert.deepStrictEqual(
    missing,
    [],
    `parity-status.json has no entry for rows ${repr(missing)}`
  );
  const extra = [...new Set(Object.keys(statusEntries).map(Number))]
    .filter((row) => !EXPECTED_ROWS.includes(row))
    .sort((a, b) => a - b);
  assert.deepStrictEqual(
    extra,
    [],
    `parity-status.json has entries for rows outside 1..36: ${repr(extra)}`
  );
});

test("test_every_row_status_allowed_and_evidence_non_empty", () => {
  requireStatus();
  const problems = [];
  for (const row of EXPECTED_ROWS) {
    const entry = statusEntries[row];
    if (!isPlainObject(entry)) {
      problems.push(`row ${row}: entry is not an object`);
      continue;
    }
    const status = entry["status"];
    if (!ALLOWED_STATUSES.has(status)) {
      problems.push(
        `row ${row}: status ${repr(status)} is not one of ` +
          `${repr([...ALLOWED_STATUSES].sort())}`
      );
    }
    const evidence = entry["evidence"];
    if (typeof evidence !== "string" || !evidence.trim()) {
      problems.push(`row ${row}: evidence is missing or empty`);
    }
  }
  assert.deepStrictEqual(problems, [], problems.join("\n"));
});

test("test_done_verified_rows_cite_a_test_as_evidence", () => {
  requireStatus();
  const problems = [];
  for (const row of EXPECTED_ROWS) {
    const entry = statusEntries[row];
    if (!isPlainObject(entry)) {
      continue;
    }
    if (entry["status"] !== "Done-verified") {
      continue;
    }
    const evidence = entry["evidence"] || "";
    if (!String(evidence).toLowerCase().includes("test")) {
      problems.push(
        `row ${row}: Done-verified but evidence names no test: ${repr(evidence)}`
      );
    }
  }
  assert.deepStrictEqual(problems, [], problems.join("\n"));
});

test("test_coverage_meets_recorded_baseline_and_is_printed", () => {
  requireStatus();
  const [coverage, done] = coveragePct(statusEntries);
  // The stop rule made visible: waves continue until this is 100%.
  console.log(
    `\nParity coverage (Done-verified): ${coverage.toFixed(1)}% ` +
      `(${done}/${EXPECTED_ROWS.length} rows) -- stop rule: waves continue until 100%`
  );
  assert.ok(
    isPlainObject(statusData),
    "parity-status.json top level must be an object holding " +
      `'${BASELINE_KEY}'`
  );
  assert.ok(
    Object.prototype.hasOwnProperty.call(statusData, BASELINE_KEY),
    "parity-status.json is missing the required top-level " +
      `baseline key '${BASELINE_KEY}': coverage has no recorded floor to be ` +
      "checked against (seat B85 / wiring must add it)"
  );
  const baseline = statusData[BASELINE_KEY];
  assert.ok(
    typeof baseline === "number" && !Number.isNaN(baseline),
    `'${BASELINE_KEY}' must be a number, got ${repr(baseline)}`
  );
  assert.ok(
    coverage >= parseFloat(baseline),
    `parity coverage ${coverage.toFixed(1)}% regressed below the recorded ` +
      `baseline ${repr(baseline)} (${BASELINE_KEY})`
  );
});

test("test_matrix_exists_and_row_count_matches_status_file", () => {
  requireStatus();
  assert.ok(
    fs.existsSync(MATRIX_JSON) && fs.statSync(MATRIX_JSON).isFile(),
    "docs/parity-matrix.json does not exist (B85 generates it)"
  );
  const matrixData = loadJson(MATRIX_JSON);
  const rows = matrixRows(matrixData);
  const statusCount = statusAllEntryCount(statusData);
  assert.strictEqual(
    rows.length,
    statusCount,
    `parity-matrix.json has ${rows.length} rows but parity-status.json ` +
      `has ${statusCount} row entries`
  );
  const numericIds = rows
    .filter(
      (item) =>
        isPlainObject(item) &&
        typeof item["row"] === "number" &&
        Number.isInteger(item["row"])
    )
    .map((item) => item["row"])
    .sort((a, b) => a - b);
  assert.deepStrictEqual(
    numericIds,
    EXPECTED_ROWS,
    "parity-matrix.json numeric row ids should be exactly " +
      `1..36, found ${repr(numericIds)}`
  );
});

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

let failures = 0;
for (const [name, fn] of tests) {
  try {
    fn();
  } catch (err) {
    failures += 1;
    console.error(`FAIL: ${name}`);
    console.error(err && err.message ? err.message : String(err));
  }
}

if (failures > 0) {
  console.error(
    `test_parity_coverage.js: FAIL (${failures} of ${tests.length} tests failed)`
  );
  process.exit(1);
}

console.log(`test_parity_coverage.js: PASS (${tests.length} tests)`);
