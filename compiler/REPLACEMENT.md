# Forge3D — Python → Native Compiler Replacement

**Date:** 2026-11-23
**Order:** the user, explicitly: "Replace it: native becomes f3dc,
delete the Python compiler."
**Scope of this change:** the native Fortran+clang compiler in
`compiler/` (parity-proven in `compiler/PARITY.md`) becomes the repo's
`f3dc`; the Python compiler is deleted; tests, CI and docs are rewired
to the binary. Nothing was pushed.

## What was deleted

- `tools/f3dc/` — the entire Python compiler: 29 `.py` modules
  (`lexer`, `parser`, `desugar`, `ir_nodes`, `validate`, `optimize`,
  `emit_*`, `ext_*`, `cli`, `driver`, `preview`, `f3dc` shim, …) plus
  its `__pycache__`. No copy is kept anywhere in the tree (it remains
  in git history at `ea40376` and earlier, like any deleted file).
- 23 files under `tests/compiler/` that imported those modules
  in-process (550 test methods): `test_lexer`, `test_parser`,
  `test_emit`, `test_errors`, `test_validate`, `test_optimize`,
  `test_preview`, `test_ext_*` (10), `test_wave*_parity` (5).
- `tools/f3dc/viewer_template.html` was **not** lost: it is an HTML
  asset, not Python, and the native emitter's template search already
  listed `compiler/viewer_template.html` as a candidate (mirroring how
  Python found it next to `emit_html.py`). The file was relocated
  there byte-for-byte. This matters: without a template on disk the
  native emitter silently falls back to a plainer built-in template
  and `.html` artifacts change — the relocation was caught by
  byte-comparing a fresh `rocket.f3d` build against the git-history
  oracle during this replacement's verification.

## What was installed / rewired

- **Binary:** `make f3dc` (new root-Makefile target) builds
  `compiler/` with flang-new-18 + clang-18 and copies
  `compiler/f3dc` → `bin/f3dc` (bin/ is gitignored, like
  `bin/engine3d`). `compiler/Makefile`'s install note was updated to
  match.
- **CI** (`.github/workflows/ci.yml`): installs flang-18 + clang-18,
  builds `make f3dc` before the test step, G3/determinism/G4 now call
  `bin/f3dc`, and the stdlib-only guard was replaced with a
  **no-Python guard**: fail if `tools/f3dc` exists or any `*.py`
  exists under `compiler/`. (Python remains in CI only as the test
  harness: `tests/run_tests.py` + `tests/golden/check_image.py`.)
- **Docs:** `README.md` and `docs/manual.md` now invoke `bin/f3dc`,
  document the native toolchain prerequisites (flang-18/clang-18 to
  build the compiler; gfortran/make for the engine), describe
  `compiler/` in the tree listing, and keep the preview section
  accurate for the native preview. `docs/plan/*` (historical) was not
  touched.

## How the tests were converted

The old suites tested Python internals in-process; that interface no
longer exists. The replacement is black-box, in a new layer
`tests/native/` driven by `tests/run_tests.py` (which also gained a
step that builds `bin/f3dc` via `make f3dc` when missing):

- **`tests/native/corpus.json`** — before deletion, the PARITY.md
  sweep-1 extractor was re-run against the old test files: 1,515
  string constants → 896 scene inputs. Each case's expectations were
  baked from the Python oracle (relative-path invocation in a bare
  temp dir): exact exit code, stdout/stderr SHA-256, the ordered
  diagnostic codes, and — for the 91 inputs that compile — the
  SHA-256 of every build artifact (546 files). The native test
  replays all 896 through `bin/f3dc check`/`build` and compares.
- **The 4 oracle-crash cases** (PARITY.md register items 2/6: Python
  exits 70/E9000) are flagged `oracle_crash` in the corpus; their
  expectations were baked from the *native* compiler's proper
  diagnostics (exit 1/3, E201/E501) — the documented, deliberate
  divergence, preserved as the expected behavior going forward.
- **`tests/native/examples.json`** — all 10 `examples/*.f3d` (72
  artifacts incl. multi-scene's double set), baked from the oracle
  with absolute scene paths (the parity-sweep discipline) and a
  machine-independence canonicalization applied identically at bake
  and test time (repo-root path → `<REPO>`; embedded `sha256:` header
  lines → placeholder, since they hash content containing the
  machine's path). The canonicalization exists because of register
  item 11: with a *relative* scene path, Python abspaths relative
  texture paths in artifacts while the native compiler joins them to
  the scene dir as written (`examples/assets/checker.ppm` in
  `lighting-showcase`); under absolute paths the two are
  byte-identical, as the sweep proved.
- **`tests/native/cli_battery.json`** — the sweep-2 CLI surface (28
  cases: --version/--help/all subcommand helps, unknown command,
  no-args, check in text/--json/--explain forms on valid/broken/
  missing scenes, fmt ×3, build ×2 with artifact hashes, `new` with
  created-file hash). `doctor` is asserted loosely (exit 0 + output)
  because its text names locally found tool versions and paths.
- **Preview** — the 5 core checks of the old `test_preview.py`,
  re-implemented against the `bin/f3dc preview` subprocess (page,
  `/__version`, edit → version bump, broken scene → error state +
  `/__status` diagnostics, fix → recovery).
- **Determinism** — hello-cube builds byte-identically twice.
- **`tests/e2e/` (6 files, 55 test methods)** — converted 1:1 from
  `cli.main(...)` in-process calls to `bin/f3dc` subprocess calls;
  every scene string and every assertion (including the PPM pixel
  checks via `tests/golden/check_image.py`) preserved.
- **`tests/compiler/` kept files (151 test methods)** — the 15
  `test_f3d_*_js.py` node suites (they test the `runtime/*.js`
  sidecars and never imported the compiler) and
  `test_parity_coverage.py` (docs governance) are unchanged.
- Fortran (29 programs) and golden layers: unchanged.

## Coverage that could not be preserved (named, not hidden)

- **Internal-structure assertions are gone.** The 550 deleted methods
  included assertions about Python implementation details — lexer
  token-kind sequences, AST node field values, IR dict shapes,
  optimizer internals, `ext_*` function-level return values,
  `ErrorBag` formatting units. There is no black-box equivalent for
  "the parser's AST node has field X"; what *is* preserved is the
  behavior those tests exercised: every scene string in them is a
  corpus case with exact exit/output/diagnostic-code expectations,
  and every valid scene's emitted artifacts are hash-compared
  byte-for-byte. A behavioral regression in lexing/parsing/
  validation/emission that changes any output will fail the corpus;
  a purely internal refactor with identical behavior is now
  (correctly) untestable — and untestable-by-design rather than
  silently dropped.
- **`doctor`'s exact text** is no longer byte-asserted (see above);
  its exit code and the CLI battery's help/version texts still are.
- The old suites also ran a handful of **timing/perf-shaped checks**
  embedded in unit tests (e.g. optimizer size heuristics asserted via
  internal counters); these had no output-observable counterpart and
  are not carried over. No user-visible behavior was covered *only*
  by them, to the best of the corpus extraction's reach (every string
  constant in every deleted file was extracted and filtered by the
  project's own lexer heuristic).

## Verification (first-hand, post-deletion tree)

- `make -C compiler clean && make f3dc` from scratch: builds in ~1
  min; `bin/f3dc --version` → `f3dc 0.1.0`.
- `bin/f3dc run` (bare-file form) on `examples/hello-cube.f3d` in a
  scratch dir: exit 0, `build/output_render.ppm` sha256
  `090fa22a7faa670ef98dc16858006d6f0babb243a26e0f77dce471564942d19d`
  — identical to the Python path's, per PARITY.md.
- `bin/f3dc build` on `rocket.f3d` vs the Python oracle restored from
  git history into a temp dir: all 6 artifacts byte-identical (this
  is the check that caught the template relocation above).
- Native preview smoke on a copy of `rocket.f3d`: page serves,
  `/__version` ok; edit → version 2 ok; break → version 3,
  `ok:false`, "Scene error" page; SIGINT stops it cleanly.
- `python3 tests/run_tests.py`: **PASS** — native (black-box),
  compiler-js + governance, e2e, fortran (29 programs) all PASS;
  golden SKIP (no golden image committed — same as the
  pre-replacement baseline).
- Strict golden untouched: repo-root `output_render.ppm` sha256
  `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`,
  and `output_render.png` unmodified.
