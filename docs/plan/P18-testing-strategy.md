# P18 — Testing Strategy: Compiler, Fortran Runtime, Golden Images, Error Messages

> **Status:** Planning only — no `src/` changes, no tests created by this document.
> **Repo baseline (verified 2026-11-23):** **no tests at all** — no `tests/`
> directory exists despite `README.md` promising one, no test target in
> `Makefile`, no CI config in the tree. Runtime: `src/math_3d.f90` (210 lines,
> `vec3_*`/`mat4_*`, all `pure`), `src/mesh.f90` (144, `create_cube`,
> `compute_triangle_normal`, `export_mesh_json/obj`), `src/camera.f90` (46,
> `camera_init`, `camera_update_matrices`), `src/renderer.f90` (161,
> `framebuffer_init/clear/render_mesh`, `draw_triangle`, `framebuffer_save_ppm`),
> `src/main.f90` (68, hard-coded 640×480 cube demo). Build:
> `gfortran -O3 -Wall -Wextra -fcheck=all -Jinclude`, target `bin/engine3d`.
> Checked-in artifacts usable as fixtures: `scene.json` (12 triangles, legacy v1
> shape), `model.obj`, `output_render.ppm` (**P3 ASCII, 640×480, max 255,
> background `25 25 35`**), `viewer.html`.
> **Sibling plans this strategy serves:** P03 (DSL grammar + defaults table),
> P04 (pipeline `lex → parse → validate/desugar → optimize → emit`, Python
> stdlib-only compiler in `tools/f3dc/`, IR JSON as golden format, §11 sketch
> this plan supersedes and expands), P08 (diagnostics: codes, plain-mode
> format, §10 testing requirements this plan operationalises).
> **Environment fact:** this VM has Python 3.12.3 but **no `gfortran` and no
> `pytest`** — the strategy must run with zero installs locally and get its
> Fortran verdicts from CI (the user's standing GitHub-Actions pattern).
>
> **Product goal:** an *easy* 3D compiler. Testing serves ease directly: the
> 3-line program must always work, a beginner's mistake must always produce
> the promised helpful error, and the default cube must never silently
> change its picture.

---

## 1. Decisions in one page

| # | Decision | Rationale |
|---|---|---|
| D1 | **Python tests: stdlib `unittest`, not pytest.** Files are written in `unittest.TestCase` style so `pytest` *can* run them where it exists, but nothing requires it. | P04's hard rule is zero third-party Python dependencies (no `pip install` step — ease goal). `pytest` is not installed here; `unittest` + `unittest discover` is in every Python ≥ 3.10. |
| D2 | **Fortran tests: no framework** (no pFUnit/FRUIT). One small in-repo assertion module + one test *program* per runtime module, verdict = exit code. | No Fortran package manager in the build; adding a framework contradicts the zero-install rule and the `Makefile`'s simplicity. The runtime surface is 4 modules / ~25 procedures — a framework buys nothing. |
| D3 | **One test tree at repo root `tests/`** (the location `README.md` already promises), superseding P04 §9's `tools/f3dc/tests/`. Compiler tests import `f3dc_pkg` via `PYTHONPATH=tools/f3dc` set by the test runner. | One `make test` entry point; a contributor never has to know which subtree a failing test lives in conceptually — only its directory (§3). |
| D4 | **Golden images: two-tier verdict — SHA-256 exact hash is the pinned-environment gate; PSNR/pixel-diff is the portable gate.** Never hash alone, never PSNR alone. | Fortran `-O3` + libm `sin/cos/tan` results vary across gfortran versions/architectures. Hash-only = false failures everywhere except one machine; PSNR-only = slow drift nobody notices. §6 sets both thresholds. |
| D5 | **The baseline cube is captured before any compiler code lands (Phase 0, §9), from the current unmodified `main.f90` demo.** | After the compiler exists there is no trustworthy "before" picture. Today's `output_render.ppm` *is* the regression anchor P03 §10 and P10 both assume. |
| D6 | **Error messages are golden-tested verbatim** — plain mode (`NO_COLOR`), full stderr + exit code + "no output file was created". | P08: errors are the user interface. Untested wording regresses silently; a wording change must be a deliberate diff a reviewer reads. |
| D7 | **Every stage is tested at its own boundary** using P04's `--emit tokens\|ast\|ir\|opt-ir` dumps; end-to-end tests are the minority. | A golden failure must name the stage that broke. E2E-only testing gives a red light with no location. |
| D8 | **No test ever writes into the repo root or `src/`.** All runs happen in a per-test temp dir; fixtures are read-only inputs. | The root already carries hand-checked-in `scene.json` / `model.obj` / `output_render.ppm`; a test that overwrites them destroys fixtures and pollutes `git status`. |
| D9 | **Deterministic or it doesn't ship:** fixed seeds, no wall-clock, no dict-order dependence, no network, no ImageMagick dependency in any required test. | Flaky tests teach contributors to ignore red — fatal for a project whose CI *is* the verification path (no local gfortran). |

---

## 2. The test pyramid (and what each layer may not do)

```
        ╱  E2E / CLI        ╲   ~10 cases   subprocess: f3dc run → PPM exists + golden verdict
       ╱  Golden (image,     ╲  ~8 scenes   full pipeline + Fortran render vs baseline
      ╱   error, emit)        ╲
     ╱  Fortran unit          ╲  5 programs math/mesh/camera/renderer + PPM round-trip
    ╱  Compiler unit           ╲ ~150 cases lexer/parser/validator/optimizer/emitters, pure Python
```

| Layer | Runs | Needs gfortran? | Budget (CI) | Owns | Must never |
|---|---|---|---|---|---|
| Compiler unit | every push | No | < 10 s | Token/AST/IR correctness, diagnostics data, emitter *text* | Spawn `gfortran`; compare rendered pixels |
| Fortran unit | every push | Yes | < 30 s | Runtime maths & rasterizer behaviour in isolation | Parse `.f3d`; know the compiler exists |
| Golden emit | every push | No | < 10 s | Byte-stability of IR JSON / v1+v2 JSON / JS / Fortran source text per stage | Execute emitted code |
| Golden image | every push | Yes | < 60 s | Pixels: default cube + one scene per renderer feature | Run at full 640×480 for *every* case — §6.3 sizes |
| Error golden | every push | No (except renderer-guard cases) | < 10 s | Exact stderr, exit code, no partial output | Accept "contains substring" as a pass |
| E2E / CLI | every push | Yes | < 60 s | The headline flow: write 3 lines → `f3dc run` → picture; flags, exit codes, `--emit` dumps | Assert pixels beyond the golden verdict helper |
| Sweeps (fuzz/truncation) | nightly / pre-release | Mixed | < 5 min | No-crash guarantee (P08 §10.3) | Block a normal push on a *new* crash class without a minimised fixture being filed |

Total push-gate target: **< 3 minutes** end-to-end in CI. Anything slower gets
demoted to the nightly tier, not deleted.

---

## 3. Test file layout (all new files; `src/` untouched)

```
tests/
  README.md                  # how to run each layer, how to bless a golden (§6.4)
  run_tests.py               # stdlib-only orchestrator: discovers + runs every layer
                             #   available locally, SKIPS (loudly) layers needing
                             #   gfortran when it is absent; exit = worst verdict
  compiler/                  # Python, unittest, PYTHONPATH=tools/f3dc
    test_lexer.py
    test_parser.py
    test_desugar_defaults.py # P03 §6 / P04 §4.3 defaults table, case by case
    test_validate.py         # semantic/range checks, one method per E-code
    test_didyoumean.py       # P08 §4 typo corpus (table-driven)
    test_optimize.py         # one class per pass O1–O7 (P04 §4.4)
    test_emit_json.py        # v1 shape exactness, v2 round-trip (§5.2)
    test_emit_fortran.py     # text goldens + API-use lint (§5.3)
    test_emit_js_html.py
    test_ir_roundtrip.py     # IR → JSON → IR identity; IR hash stability
    test_determinism.py      # build twice → sha256 equality of all emits
    fixtures/
      valid/                 # *.f3d (+ *.tokens / *.ast.json / *.ir.json goldens)
      invalid/               # *.f3d, each named for the code it must raise
  fortran/
    assert_utils.f90         # module test_assert: assert_true/near/int_eq/str_eq,
                             #   failure counter, summary + `stop 1` on any failure
    test_math_3d.f90         # program; links math_3d only
    test_mesh.f90            # links math_3d + mesh_3d
    test_camera.f90          # links math_3d + camera_3d
    test_renderer.f90        # links all 4 modules; small framebuffers only
    test_ppm_io.f90          # save → re-read via a tiny Fortran P3 reader in the test
  golden/
    manifest.tsv             # case, scene, size, baseline sha256, blessed-by/date/why
    scenes/                  # *.f3d (and legacy-cube.json — copy of repo scene.json)
    baselines/               # *.ppm blessed baselines (see §6.4; NOT under docs/)
    expected_emit/           # per-scene pinned .ir.json / .json / .js / .f90 text
    check_image.py           # stdlib P3 parser + hash / PSNR / diff-stats verdict (§6.2)
  errors/
    cases/                   # <code>__<slug>.f3d + .stderr.txt + .exit (expected code)
    run_error_goldens.py     # drives f3dc check/build in temp dirs, diffs verbatim
  e2e/
    test_cli.py              # subprocess: new/check/build/run, flags, exit codes 0–4
    test_legacy_compat.py    # repo scene.json → all targets; viewer-shape assertions
  sweeps/
    truncate_scene.py        # every byte-offset truncation of a valid scene (P08 §10.3)
    fuzz_tokens.py           # seeded random token soup; assert: diagnostic or success,
                             #   never traceback / hang (timeout per case)
Makefile                     # (separate change) test, test-compiler, test-fortran,
                             #   test-golden, test-errors, test-e2e, test-nightly targets
.github/workflows/test.yml   # (separate change) §8
```

Naming rules: a test file is named for the *stage/module it guards*; a fixture
is named for the *behaviour it pins* (`fov_180_is_error.f3d`, never
`case37.f3d`); every golden/error fixture carries a one-line header comment
naming the plan section that specifies it.

---

## 4. Fortran unit tests (runtime, D2)

### 4.1 Harness

`assert_utils.f90` provides `assert_near(real(dp), real(dp), tol, name)`,
`assert_eq_int`, `assert_eq_str`, `assert_true`, and a `check_count/fail_count`
pair; each test program prints `PASS <name> (n checks)` or per-failure
`FAIL <name>: <check> got … want …` and ends `stop 1` iff `fail_count > 0`.
The `Makefile` compiles each test program against the module objects
**without** `main.o`, with the same flags as production
(`-O3 -Wall -Wextra -fcheck=all`) — `-fcheck=all` is part of the test value:
bounds/pointer errors in the rasterizer must fail loudly here, not in a render.
Tolerance policy: `dp` results compared at `1e-9` absolute for unit-scale
quantities, `1e-6` for composed matrices / perspective entries; **never**
exact equality on anything that passed through `sin/cos/tan`, exact equality
required for integer/structural results (counts, colours, indices).

### 4.2 Coverage checklist (every public procedure ≥ 1 test — this table is the audit)

| Module | Procedures / behaviour pinned |
|---|---|
| `math_3d` | `vec3_create/add/sub/scale/dot/cross/norm/normalize` (incl. zero-vector normalize → the epsilon behaviour in the current code, asserted as-is); `mat4_identity/mult/translation/scale/rotate_x/y/z` (90° rotations map basis vectors exactly-ish; `T·R·S` composition order used by P03 §7); `mat4_perspective` (known fov/aspect/near/far → known entries); `mat4_look_at` (eye at demo position → orthonormal basis, forward = −Z of view space); `mat4_transform_vec3` point (`is_point=.true.`, w-divide) vs direction (`.false.`) |
| `mesh_3d` | `create_cube`: exactly **12 triangles**, 8 distinct corners at `±size/2`, per-face colours equal to the palette P03 §6.3 records (south 220,60,60 … bottom 60,220,220); `compute_triangle_normal` on an axis triangle + a degenerate (collinear) triangle; `export_mesh_json` output re-parsed in Python (in the compiler-layer suite) equals the repo's legacy `scene.json` shape; `export_mesh_obj` vertex/tri counts |
| `camera_3d` | `camera_init` stores fields verbatim and derives aspect-dependent matrices via `camera_update_matrices`; view matrix maps target → origin; projection matrix matches `mat4_perspective` for the same inputs (guards the two code paths drifting apart) |
| `renderer_3d` | `framebuffer_init` dimensions/allocation; `framebuffer_clear` fills every pixel (sample corners + centre); `draw_triangle`: a known screen-space triangle colours its centroid pixel, respects the Z-buffer (nearer second draw wins, farther second draw loses), clamps intensity as the current code does (behaviour pinned, cf. P08's no-*silent*-clamp rule at the DSL layer — the runtime clamp itself is specified, tested behaviour); `framebuffer_render_mesh`: identity-model cube at the demo camera produces non-background pixels and the centre pixel is a cube face colour, not background |
| PPM (`test_ppm_io`) | `framebuffer_save_ppm` on a 4×3 framebuffer with hand-set pixels → file re-read token-by-token equals header `P3 / 4 3 / 255` + the exact pixel sequence; this is the contract `check_image.py` (§6) and `viewer.html` both depend on |

Property-style checks (seeded, in Fortran or driven from Python): random
`vec3`s satisfy `a×b = −(b×a)`, `dot(a, a×b) = 0`, `normalize(v)·norm(v) = v`
within tolerance; random TRS matrices satisfy `(T·R)·v = T·(R·v)`. Fixed seed,
100 iterations — no external property library needed at this scale.

---

## 5. Compiler unit tests (Python, D1)

All pure: input string / IR object in, value or `Diagnostic` list out. No
subprocess, no filesystem except `tmp` fixtures. Runner:
`python3 -m unittest discover -s tests/compiler -t .` (and identically under
`pytest` where available).

### 5.1 Lexer (`test_lexer.py`)

- One case per token kind in the final grammar (P03 lexical table / P04 §4.1 —
  fixtures follow whichever grammar the language plan freezes; the *test
  structure* does not change): numbers (`2`, `-1.5`, `0.25`), names, colour
  literals (`#RRGGBB`, named colours), strings, punctuation/keywords.
- Spans: every token's `line/col/end_col` asserted on a multi-line fixture —
  spans are the load-bearing hook for all diagnostics (P08 §0); a span
  regression must fail here, not in an error golden.
- Comments (`#`, and `//` if the frozen grammar keeps both) and blank lines
  produce no tokens but advance line numbers correctly.
- Lexical errors: unterminated string, stray character, bad number — each
  asserts code, span, and that lexing *aborts or recovers* exactly as P04/P08
  specify; size/token-count guard (`E101`-class in P04) tripped by a generated
  oversized input.
- Case-insensitivity: keywords/colours in mixed case lex identically.

### 5.2 Parser (`test_parser.py`)

- One golden AST (`.ast.json` via `--emit ast`) per graded example in the
  grammar plan (P03 §9.1–9.5, with §9.5's colour fixed to a valid one) plus
  one per production not covered by them.
- Statement-order insensitivity where the grammar promises it; structural
  nesting (`scene…end` / `group`/`repeat`, per frozen grammar) preserved.
- Recovery: a file with three independent syntax errors reports all three
  (capped at 10 — the cap itself is a test with 11 errors), in file order.
- Duplicate property in one statement, creation/animation mixing, unresolved
  pronoun (`spin it` with no prior object) — parser/validator boundary cases,
  each asserting the specified code and span.
- Reserved-but-unbuilt primitives (`sphere` today) produce the
  "not supported yet — only `cube` works" diagnostic, **never** a cube AST
  (P03 §8: no silent substitution — this test is the enforcement).

### 5.3 Validator / desugar (`test_desugar_defaults.py`, `test_validate.py`)

- **Defaults table is data-driven:** every row of the defaults table
  (image 640×480, background 25,25,35, camera (3,2.5,4)→(0,0,0), fov 60,
  near 0.1, far 100, light (−0.5,−1,−0.7), cube size 2, demo pose 20/35/0 for
  a lone cube, per-face palette) becomes one test: minimal input → IR field
  equals the table value. If a default ever changes, exactly these tests fail
  and the diff *is* the change review.
- One test per semantic/range code in the catalogue (P04 §4.3 E3xx/E4xx and
  P08 §6.2, reconciled when the code table freezes): fov bounds (0, 180 are
  errors; 179 ok; 175 warns), `near ≤ 0`, `far ≤ near`, size bounds, colour
  channel bounds, `at == look`, zero light direction, degenerate triangle,
  duplicate name/block, unknown name/property (with did-you-mean attached).
- Collect-all semantics: a file with one error per category returns all of
  them, sorted by (line, col), warnings not blocking, `--strict` promoting.
- Desugar mechanics: `repeat` expansion count + cap error, group transform
  accumulation, colour/unit normalisation (hex, named, `rgb` → one IR form).

### 5.4 Optimizer (`test_optimize.py`)

One class per pass O1–O7 (P04 §4.4), each: small hand-built IR in → expected
IR out + expected `--stats` counts. Cube arithmetic is the anchor case:
O2 dedup takes the cube's 36 triangle-vertices to **8**; O3 removes a planted
duplicate and a zero-area triangle; O4 culls only for a static closed object
and is *disabled* when an animation flag is set (negative test matters more
than the positive one); O7's depth-sort is asserted as an ordering property
(centroid depths non-increasing), not a full golden. Pass-order test: running
the full chain twice is idempotent.

### 5.5 Codegen / emitters

| Suite | Assertions |
|---|---|
| `test_ir_roundtrip.py` | IR → v2 JSON → IR is identity for every valid fixture; IR JSON carries `ir_version`; canonical serialisation (sorted keys, fixed float precision) so the same IR always hashes the same |
| `test_emit_json.py` | v1 output matches the legacy shape *exactly* (keys, 1-based `id`, 3-decimal numbers, transforms baked) — verified against the structure of the repo's real `scene.json`; v2 output golden-diffed per scene |
| `test_emit_fortran.py` | (a) Text golden per scene; (b) **API lint:** emitted source references only existing public runtime APIs (`create_cube`, `camera_init`, `framebuffer_*`, `mat4_*`, `export_mesh_*`) — a regex inventory test, so an emitter inventing a procedure fails without needing gfortran; (c) header stamp + source hash present; (d) one `framebuffer_render_mesh` per object into the shared framebuffer (P04 §6.1 compatibility fact) |
| `test_emit_js_html.py` | JS module parses as JSON-payload + export shape; HTML golden is a *skeleton* diff (placeholders substituted, scene payload extracted and compared as JSON — full-file HTML goldens are too brittle); inlined-data path present so `file://` works without `fetch` |
| Fortran-emit compile (Fortran layer, §4 infra) | Every golden scene's emitted `.f90` compiles with `gfortran -fsyntax-only` in CI, and the hello-cube emit compiles, links against the 4 modules, runs, and its PPM passes the §6 verdict — the cross-check that closes P04 §11.2 |
| `test_determinism.py` | Compile every valid fixture twice in separate temp dirs → `sha256` of every emitted file identical; also with dict/hostile ordering inputs (statements shuffled where legal) |

---

## 6. Golden image tests

### 6.1 The baseline cube (Phase 0 deliverable)

Canonical case `cube-default`: the scene the current `main.f90` renders —
640×480, cube size 2, camera (3, 2.5, 4)→(0,0,0), fov 60, near 0.1, far 100,
light (−0.5, −1, −0.7), pose 35°Y/20°X, background (25,25,35). Baseline is
produced by building and running the **unmodified** engine, then blessing
(§6.4) into `tests/golden/baselines/cube-default.ppm` with a `manifest.tsv`
row recording: source (commit or "pre-compiler tree"), gfortran version,
flags, image size, SHA-256. The already-checked-in root `output_render.ppm`
is the cross-check: a fresh run of the unmodified engine must hash-match it
or the discrepancy is investigated *before* blessing — a baseline captured
from an unexplained mismatch blesses a mystery.

### 6.2 Comparison: `check_image.py` (stdlib only)

Parses P3 PPM (whitespace-tolerant — the writer's spacing is not part of the
contract; pixel values are), then reports and decides:

| Check | Strict gate (pinned CI env) | Portable gate (any other env) |
|---|---|---|
| Dimensions / maxval | Must equal baseline exactly | Must equal exactly |
| SHA-256 of canonical pixel stream (parsed ints, not raw bytes) | **Must equal** manifest hash | Reported, not required |
| Differing pixels | 0 | ≤ 0.1 % of pixels |
| Max per-channel abs diff | 0 | ≤ 2 |
| PSNR (on differing stream; ∞ when identical) | ∞ | **≥ 60 dB** |
| Mean colour per face region / background pixel at (0,0) | Equal | Background exactly (25,25,35); face means within ±1 |

Verdicts: `IDENTICAL`, `TOLERANT-PASS` (portable criteria met, hash differed —
printed loudly, counts as pass only outside the pinned env), `FAIL` with a
diff report: counts, max diff, PSNR, bounding box of differing pixels, and a
diff PPM written to the temp output dir for eyeballing. Threshold rationale:
60 dB / ±2 / 0.1 % is far above libm/optimisation noise (which, if present at
all, shifts edge pixels by ±1) and far below any real shading, geometry, or
colour regression (a wrong face colour or a 1° pose change fails all three
by orders of magnitude). A scene that renders *all background* or *all one
colour* fails a separate sanity assert regardless of PSNR — PSNR against a
degenerate baseline is meaningless.

### 6.3 Case list and sizes

Full-size (640×480) only where size is the point; everything else renders at
160×120 against its own blessed baseline to keep the gate under a minute
(aspect and camera maths are size-invariant; the one full-size case proves
the real path):

| Case | Size | Pins |
|---|---|---|
| `cube-default` | 640×480 | The demo, forever (D5) |
| `cube-one-line` | 160×120 | The minimal DSL program (`cube`) renders the default scene |
| `cube-red-spin-still` | 160×120 | Single-colour tint + frame 0 of an animation (`render still`) |
| `two-cubes` | 160×120 | Multi-object, shared framebuffer, Z-buffer between objects |
| `camera-move` | 160×120 | Non-default camera/fov actually moves the picture |
| `light-move` | 160×120 | Non-default light direction changes face intensities |
| `legacy-cube` | 160×120 | Repo `scene.json` through the compat reader renders like the direct scene |
| `behind-camera` | 160×120 | Object behind camera → pure background + the specified warning (couples image + error goldens) |

### 6.4 Blessing protocol (how baselines change — deliberately annoying)

1. Baselines are **never** updated by CI and never by a `--bless` flag run
   as part of a failing-test retry loop.
2. A human runs `tests/golden/check_image.py --bless <case>` locally/CI-
   artifact, views the new image and the diff report against the old one,
   and writes the `manifest.tsv` row: date, who, and *why* (linking the
   change that intentionally alters pixels — e.g. a P10 shading change).
3. A PR that changes a baseline without a manifest `why`, or changes pixels
   without changing a baseline in the pinned env, fails review — not just CI.
4. Baselines live in `tests/golden/baselines/` as PPM (the native format —
   no PNG conversion dependency), one per case, named exactly as the case.

---

## 7. Error-message golden tests (P08 §10, operationalised)

### 7.1 Fixture format

One directory entry per case in `tests/errors/cases/`:
`<CODE>__<slug>.f3d` (the smallest input that triggers exactly that
diagnostic), `<CODE>__<slug>.stderr.txt` (the **complete** expected stderr in
plain mode), `<CODE>__<slug>.exit` (expected exit code: 1 scene errors,
2 CLI misuse, 3 IO, per P04 §7 / P08 §7 — one reconciled table when both
plans freeze). The runner executes the compiler in a fresh temp dir with
`NO_COLOR=1`, relative input path, and asserts, in order:

1. Exit code equals `.exit`.
2. stderr equals `.stderr.txt` **byte-for-byte** after exactly two
   normalisations: the temp-dir absolute path (IO cases only) → `<DIR>`,
   and nothing else. No substring matching, no regex, no "close enough".
3. stdout contains no diagnostic text (diagnostics go to stderr, P08 §5.2).
4. **No output file exists** in the temp dir (no partial render on error —
   P03 §8 exit behaviour).
5. stderr contains no Fortran artefacts: the strings `STOP`, `Backtrace`,
   `Fortran runtime error`, and no internal terms from P08 §9's banned list
   (`token`, `AST`, `framebuffer`, …) — one shared lint over all fixtures.

### 7.2 Coverage

- **Every code in the frozen catalogue gets ≥ 1 fixture before the release
  that introduces the code** — a code without a fixture does not ship.
  Priority order is P08's 10 common mistakes (§8 there: typo'd keyword,
  bad colour, colour range, missing camera, fov range, missing brace,
  wrong type, file-not-found, near/far + eye==target, duplicate definition),
  whose "good" blocks become fixtures *verbatim*.
- **Did-you-mean corpus** (`test_didyoumean.py`, unit layer, feeding two
  error goldens end-to-end): ≥ 3 typos per keyword/colour (deletion,
  transposition, substitution, case-only) asserting the intended suggestion;
  negative cases (`xyz`) asserting **no** suggestion is offered.
- **Colour/ANSI:** one fixture run three ways — forced `--color=always`
  (snapshot compared with ANSI sequences normalised to placeholders),
  `NO_COLOR=1`, and piped — asserting identical *information*: same codes,
  same spans, zero escape bytes in the plain runs.
- **JSON diagnostics:** `--format json` output for three representative
  codes parsed and asserted field-by-field (`code, severity, message, file,
  line, col, label, why, help, suggestion`) — schema test, not a text golden.
- **Truncation / no-crash sweep** (nightly, §3 `sweeps/`): the valid
  hello-cube scene truncated at **every byte offset**, plus the seeded token
  fuzz corpus: every run must exit 1/2/3 with a diagnostic, never 0, never a
  traceback, never a timeout, and never leave an output file. A failure is
  minimised into a permanent `errors/cases/` fixture.
- **Gutter/alignment fixture:** an error at line ≥ 100 (generated scene with
  99 comment lines) — multi-digit gutter alignment is exactly the formatting
  bug unit tests won't catch and P08 §11 flags.
- **Human gate (not automatable, recorded):** before v1 ships, P08's
  10-second test with ≥ 3 first-time users on the typo, colour-range,
  missing-camera, and fov cases; pass/fail recorded in the successor doc.
  Goldens prove stability, not comprehension — the plan says so out loud.

---

## 8. Running it: Makefile, CI, and this machine

```make
# Proposed Makefile targets (implementation is a separate change)
test:            test-compiler test-errors test-fortran test-golden test-e2e
test-compiler:   PYTHONPATH=tools/f3dc python3 -m unittest discover -s tests/compiler
test-errors:     python3 tests/errors/run_error_goldens.py
test-fortran:    # build test programs (no main.o), run each, fail on first non-zero
test-golden:     # build engine + emitted scenes, run check_image.py per manifest row
test-e2e:        python3 -m unittest discover -s tests/e2e
test-nightly:    test + sweeps (truncation + fuzz)
```

- **Locally (this VM):** `make test-compiler test-errors` run today-class
  (pure Python, no installs). Fortran-dependent targets detect the missing
  `gfortran` and report `SKIP — gfortran not found` with a distinct exit
  message from the orchestrator — a skip is printed, never silently a pass
  (D9; and per standing practice, no success verdict from an absent marker).
- **CI (GitHub Actions, the repo's verification path):** one workflow,
  `ubuntu-latest`, steps in pyramid order (compiler → errors → Fortran →
  golden → e2e) with fail-fast *between layers* but full reporting *within*
  a layer. The pinned environment for the strict hash gate (§6.2) is this
  workflow's image + its `gfortran --version` / `python3 --version` printed
  into the job log and the golden manifest; a toolchain bump in CI is a
  deliberate act that may require re-blessing under §6.4. On golden failure,
  upload the actual PPM, the diff PPM, and the diff report as artifacts —
  the reviewer must be able to *see* the regression without reproducing it.
- **Coverage accountability without a coverage tool** (third-party
  `coverage.py` is out under D1): two checklist audits are the coverage
  metric — §4.2's procedure table (Fortran) and §7.2's code table
  (diagnostics) — plus a mechanical check in `run_tests.py` that every
  `E`/`W` code string found in the compiler source has a matching fixture
  file, and every public Fortran procedure name appears in its test program.
  A new code or procedure without a test fails that check by construction.

---

## 9. Phased delivery (tests land *with* each P04 phase, never after)

| Phase | Test deliverable | Gate it creates |
|---|---|---|
| **P18-0 (before P04-a)** | Capture + bless `cube-default` baseline from the unmodified engine; `check_image.py`; `test_ppm_io` + `assert_utils.f90` skeleton | The "before" picture exists and the PPM contract is pinned while the runtime is untouched |
| P18-a (with lexer/parser) | `test_lexer`, `test_parser`, valid/invalid fixtures, span assertions | `f3dc check` cannot regress silently |
| P18-b (with validate/IR) | Defaults table suite, per-code validator tests, IR round-trip, first error goldens (E3xx/E4xx) | IR contract `ir_version: 1` frozen under test |
| P18-c (with JSON emit + compat) | v1-shape exactness, `legacy-cube` golden image + emit, `test_legacy_compat` | Checked-in `scene.json`/`viewer.html` path proven end-to-end |
| P18-d (with optimize) | Per-pass O1–O7 suites, idempotence, determinism suite | Optimizer can be extended pass-by-pass safely |
| P18-e (with Fortran emit + driver) | Emit text goldens + API lint, `-fsyntax-only` sweep, hello-cube compile-run-golden, full Fortran unit suite (§4) in CI | Headline flow `.f3d → PPM` proven; runtime maths pinned independently of the compiler |
| P18-f (with JS/HTML + `new`) | JS/HTML skeleton goldens, full E2E suite, error-golden catalogue complete (every code), colour/JSON-diagnostic tests | v1 release gate = `make test` green + §7.2 human 10-second test recorded |
| Nightly (from P18-f) | Truncation + fuzz sweeps, full-size golden variants | No-crash guarantee maintained as the grammar grows |

**Explicit non-goals:** no browser automation for `viewer.html` (its contract
is the v1 JSON shape + the inlined-data HTML skeleton, both tested without a
browser); no performance benchmarking suite (timing budgets in §2 are
tripwires, not benchmarks — a perf plan owns real numbers); no testing of
gfortran's own diagnostics (contributor-facing, out of scope per P08);
no snapshot library, no test framework, no fixture-generation from the
implementation under test (goldens are blessed by humans under §6.4 or
hand-written — a golden generated by the code it tests proves nothing).

**Risks / open questions for the parent plan:** (1) The grammar/code
catalogues are not yet frozen across P03 (line-oriented), P04 (brace blocks,
E1xx–E6xx), and P08 (E1001-style codes, different surface syntax) — fixtures
must be written against the *reconciled* freeze; this strategy is deliberately
syntax- and code-scheme-agnostic, but §5/§7 fixture *content* cannot be
authored until that freeze lands. (2) P04 §9 places compiler tests under
`tools/f3dc/tests/`; D3 moves them to root `tests/compiler/` — parent plan
should record the override so the two documents stop disagreeing.
(3) The strict hash gate is only as stable as the CI image; if the project
later supports user machines as a test target, the portable PSNR gate
becomes the only gate there and the 0.1 %/±2 thresholds should be re-derived
from observed cross-machine noise, not assumed. (4) Who blesses: §6.4 needs
a named maintainer role once more than one contributor exists.
