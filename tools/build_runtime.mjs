// build_runtime.mjs -- Forge3D runtime size budgets + classic bundle.
//
// Dependency-free Node script (node:fs / node:path only). Run it
// from anywhere; all paths are resolved from this file's location:
//
//   node tools/build_runtime.mjs            budget check only
//   node tools/build_runtime.mjs --bundle   budget check, then write
//                                           build/f3d.bundle.js
//
// BUDGET CHECK (always runs)
//   Reads runtime/module-budgets.json and reports, for every module
//   in MODULES below, the file's actual byte size next to its
//   budget, then a TOTAL line for the sum of all modules. The exit
//   code is non-zero when any module exceeds its budget, when the
//   total exceeds the total budget, or when a module / budget entry
//   is missing -- so CI can gate on this script directly. Budgets
//   are a ratchet: they were pinned at each module's size rounded
//   up to the next 512 bytes and are meant to be lowered (never
//   silently raised) as modules shrink; see the "note" field in
//   module-budgets.json. f3d.mjs (the aggregator) and f3d.min.js
//   (a build artifact) are not budgeted modules and are not counted
//   in the total.
//
// CLASSIC BUNDLE (--bundle)
//   Writes build/f3d.bundle.js: the fifteen modules concatenated
//   in the aggregator's dependency order (MODULES below -- keep it
//   in sync with runtime/f3d.mjs), each preceded by a banner
//   comment naming its source file, so a plain <script> tag gets
//   the whole runtime with no module loader. The bundle is written
//   even when the budget check fails; the exit code still reports
//   the failure.
//
//   The transform is deliberately small and LINE-BASED, and its
//   limits are part of the contract -- it handles the export /
//   import shapes THIS repo's runtime modules use, nothing more:
//     * `export { a, b, ... };` statements (single- or multi-line)
//       are dropped: the names stay as ordinary top-level
//       declarations in the bundled scope.
//     * `export const|let|var|function|class NAME ...`,
//       `export async function ...` and `export default function
//       ...` keep their declaration with the `export` (and
//       `default`) keyword stripped.
//     * `export * from "...";` lines are dropped.
//     * `import ... from "...";` and `import "...";` statements
//       (single- or multi-line) are dropped: in the bundle every
//       module's code is already present, in dependency order.
//     * A bare `export default <expression>;` line is dropped.
//   NOT handled (do not use these shapes in runtime modules):
//   export/import statements split in other ways than the above,
//   re-export renames (`export { a as b } from "..."`), dynamic
//   import(), and any export syntax appearing inside a string or
//   comment (the transform is line-based and cannot tell). The
//   repo's Phase 7 modules use none of these.
//   Each transformed module is wrapped in an IIFE so its top-level
//   helper names (several modules define their own v3/sub/dot/...)
//   cannot collide with a sibling's in the shared classic scope;
//   a module reaches the outside world exactly as it does
//   standalone -- through its globalThis compatibility footer,
//   which is preserved verbatim. Top-level `await` or a top-level
//   `return` in a module would break under the wrapper; the repo's
//   modules use neither.

import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";

// The fifteen budgeted modules, in the aggregator's dependency
// order (runtime/f3d.mjs): the core first, then every sidecar.
const MODULES = [
  "f3d.js",
  "f3d-geo.js",
  "f3d-env.js",
  "f3d-pbr.js",
  "f3d-keys.js",
  "f3d-instanced.js",
  "f3d-post.js",
  "f3d-shader.js",
  "f3d-skin.js",
  "f3d-sprites-text.js",
  "f3d-particles.js",
  "f3d-webgl2.js",
  "f3d-xr.js",
  "f3d-raycast.js",
  "f3d-ortho.js",
];

const ROOT = path.resolve(path.dirname(process.argv[1]), "..");
const RUNTIME_DIR = path.join(ROOT, "runtime");
const BUDGETS_PATH = path.join(RUNTIME_DIR, "module-budgets.json");
const BUNDLE_PATH = path.join(ROOT, "build", "f3d.bundle.js");

const wantBundle = process.argv.slice(2).includes("--bundle");

// ------------------------------------------------------------------
// Budget check
// ------------------------------------------------------------------

// Budget entries in module-budgets.json are objects
// ({ budgetBytes: n, ... }); a bare number is also accepted so a
// hand-trimmed budgets file keeps working.
function budgetOf(entry) {
  if (entry == null) return null;
  if (typeof entry === "number") return entry;
  return typeof entry.budgetBytes === "number" ? entry.budgetBytes : null;
}

function checkBudgets() {
  if (!existsSync(BUDGETS_PATH)) {
    console.error("build_runtime: missing " + BUDGETS_PATH);
    return { ok: false, sizes: new Map() };
  }
  const budgets = JSON.parse(readFileSync(BUDGETS_PATH, "utf8"));
  const entries = budgets.modules || {};
  const sizes = new Map();
  let ok = true;
  let totalActual = 0;

  console.log("Forge3D runtime budgets (bytes):");
  for (const name of MODULES) {
    const file = path.join(RUNTIME_DIR, name);
    const budget = budgetOf(entries[name]);
    if (budget == null) {
      console.error("  " + name.padEnd(22) + " NO BUDGET ENTRY");
      ok = false;
      continue;
    }
    if (!existsSync(file)) {
      console.error("  " + name.padEnd(22) + " MISSING FILE");
      ok = false;
      continue;
    }
    const actual = statSync(file).size;
    sizes.set(name, actual);
    totalActual += actual;
    const over = actual > budget;
    if (over) ok = false;
    console.log(
      "  " + name.padEnd(22) +
      String(actual).padStart(7) + " / " +
      String(budget).padStart(7) +
      "  headroom " + String(budget - actual).padStart(6) +
      (over ? "  OVER BUDGET" : "  ok")
    );
  }

  const totalBudget = budgetOf(budgets.total);
  if (totalBudget == null) {
    console.error("  TOTAL: no total budget in module-budgets.json");
    ok = false;
  } else {
    const over = totalActual > totalBudget;
    if (over) ok = false;
    console.log(
      "  " + "TOTAL".padEnd(22) +
      String(totalActual).padStart(7) + " / " +
      String(totalBudget).padStart(7) +
      "  headroom " + String(totalBudget - totalActual).padStart(6) +
      (over ? "  OVER BUDGET" : "  ok")
    );
  }
  console.log(ok ? "build_runtime: all budgets satisfied."
                 : "build_runtime: BUDGET FAILURE (see above).");
  return { ok, sizes };
}

// ------------------------------------------------------------------
// Classic bundle
// ------------------------------------------------------------------

// Line-based ES-module -> classic transform; see the header for
// exactly which shapes are handled and which are not. `pending`
// tracks a multi-line import/export-{...} statement whose lines
// are still being skipped.
function toClassic(source) {
  const out = [];
  let pending = null; // "import" | "export-list"
  for (const line of source.split("\n")) {
    const trimmed = line.trim();

    if (pending) {
      // A skipped statement ends at its closing ";" -- for an
      // export list, at the line carrying "};".
      if (pending === "export-list" ? trimmed.includes("};") : trimmed.endsWith(";")) {
        pending = null;
      }
      continue;
    }

    if (/^import[\s{*(]/.test(trimmed)) {
      // Drop the import; if it does not end on this line, keep
      // dropping until its terminating ";".
      if (!trimmed.endsWith(";")) pending = "import";
      continue;
    }
    if (/^export\s*\{/.test(trimmed)) {
      // Drop an export list; multi-line lists end at "};".
      if (!trimmed.includes("};")) pending = "export-list";
      continue;
    }
    if (/^export\s+\*\s+from\b/.test(trimmed)) continue; // export *
    if (/^export\s+default\s+\S/.test(trimmed) &&
        !/^export\s+default\s+(async\s+)?(function|class)\b/.test(trimmed)) {
      continue; // bare `export default <expression>;`
    }
    // Declaration exports: strip the keyword(s), keep the code.
    out.push(line.replace(/^(\s*)export\s+(default\s+)?/, "$1"));
  }
  return out.join("\n");
}

function writeBundle() {
  const parts = [
    "// f3d.bundle.js -- Forge3D classic bundle (generated file).",
    "//",
    "// Generated by tools/build_runtime.mjs --bundle from the ES",
    "// modules in runtime/, concatenated in dependency order with",
    "// import/export syntax stripped (see that script's header for",
    "// the transform's limits). Do not edit by hand; edit the",
    "// modules and regenerate. Load with a plain <script> tag: each",
    "// module publishes through its globalThis compatibility",
    "// footer, so globalThis.F3D and the historical per-module",
    "// globals are available once this file has run.",
    "",
    '"use strict";',
    "",
  ];
  for (const name of MODULES) {
    const source = readFileSync(path.join(RUNTIME_DIR, name), "utf8");
    parts.push("// =============================================================");
    parts.push("// runtime/" + name);
    parts.push("// =============================================================");
    parts.push("(function () {");
    parts.push(toClassic(source).replace(/\s+$/, ""));
    parts.push("})();");
    parts.push("");
  }
  mkdirSync(path.dirname(BUNDLE_PATH), { recursive: true });
  const bundle = parts.join("\n");
  writeFileSync(BUNDLE_PATH, bundle);
  console.log("build_runtime: wrote " + BUNDLE_PATH +
              " (" + Buffer.byteLength(bundle) + " bytes, " +
              MODULES.length + " modules).");
}

// ------------------------------------------------------------------

const { ok } = checkBudgets();
if (wantBundle) writeBundle();
process.exitCode = ok ? 0 : 1;
