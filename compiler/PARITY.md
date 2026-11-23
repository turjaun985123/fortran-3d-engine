# Forge3D Native Compiler — Final Differential Parity Report

## What was compared

- **Native:** `compiler/f3dc` (rebuilt with `make -C compiler` before the sweep), built with flang-new-18 18.1.3 and clang-18 (18.1.3).
- **Oracle:** `python3 tools/f3dc/f3dc.py` (the Python compiler, untouched).
- **Date:** 2026-11-23.
- Scratch for every run in this sweep: `compiler/build/parity-final/`. Nothing outside `compiler/` was modified by this sweep (the only deliverable file is this `compiler/PARITY.md`).

## Artifact parity — 11 scenes (10 examples + `rocket.f3d`)

Each scene was built with both compilers (`build -o` into separate directories) and every artifact compared byte-for-byte (`cmp`).

| Artifact type | Match | Total |
|---|---|---|
| .scene | 12 | 12 |
| .json | 12 | 12 |
| .legacy.json | 12 | 12 |
| .js | 12 | 12 |
| .html | 12 | 12 |
| _scene.f90 | 12 | 12 |
| **Total** | **72** | **72** |

Result: **72/72 artifacts byte-identical.** (`multi-scene.f3d` produces two artifact sets, hence 12 per type over 11 scenes.) Every scene exited 0 under both compilers.

## Sweep 1 — test-corpus differential

Extractor: Python `ast` walk of `tests/compiler/*.py` and `tests/e2e/*.py` (44 files), collecting every string constant, deduped.

Exact filter: keep iff (lexer.tokenize(value, 'scene.f3d', ErrorBag()) yields >=2 tokens excluding EOF) OR ('\n' in value); tokenize via tools/f3dc/lexer.py tokenize()

- Extracted (unique string constants): **1515**
- Kept (scene-input heuristic): **896**
- `check` identical (stdout + stderr + exit code): **862 / 896** in the original sweep; **892 / 896** after the SIGSEGV fix described below (re-run of this sweep's extractor/comparator against the fixed binary; the only remaining mismatches are the 4 Python-crash cases).
- Inputs where Python `check` exited 0 and `build` was also compared: **91**
- Build artifact files byte-identical: **546 / 546** (all 91 build-compared inputs artifact-identical; build stdout itself names the differing `-o` directory, so it is not compared literally).
- Check mismatches: **34** — class (a) Unicode (non-ASCII bytes in input): **0** (no kept string contained non-ASCII bytes); class (b) other: **34**.

### Mismatch classification

The 34 class-(b) check mismatches fall into exactly two groups:

1. **Native SIGSEGV on high-diagnostic-count invalid inputs — 30 cases. FIXED (2026-11-23, after this sweep).** Long JavaScript snippets and docstrings extracted from the test files (they are not valid `.f3d` at all) make Python exit 1 with a very large diagnostic dump (tens to over a hundred KB of stderr), while the native binary died with signal 11 (exit −11 in subprocess terms) and produced no stdout or stderr at all. Short inputs of the same kind (e.g. a single line `const gl = new MockGL();`) matched exactly; truncating one failing input showed the native binary matching at 400 chars and crashing at 526 chars, i.e. the crash was driven by the volume of diagnostics, not by any single character. **Root cause (diagnosed with gdb + valgrind, scratch in `compiler/build/segfix/`): stack overflow in `error_bag_format_text` (`compiler/src/f3dc_errors.f90`, the `out = out // achar(10)` / `out = out // block_text` assembly lines). flang-new-18 alloca's each deferred-length concatenation temporary on the stack and does not reclaim it until the enclosing procedure returns, so the loop's stack cost was the sum of every intermediate length of the growing output (quadratic in the total diagnostic text); at ~105 diagnostics over a ~460-char line (minimal synthetic repro: ~170 `=` characters on one line, 170 E101s) the cumulative alloca passed the 8 MiB main-thread stack. With an unlimited stack the unfixed binary produced byte-identical output, confirming no heap corruption and no logic error. Fix (in `f3dc_errors.f90` only, no limits raised, no diagnostics suppressed): each diagnostic's block/record is now built in its own subroutine (`diag_block_text` / `json_record_text`, so its temporaries are bounded by one block and released on return) and the full text/JSON output is assembled into a single preallocated buffer filled by position; `expand_tabs` and `json_escape` were rewritten the same buffered way (their char-by-char self-concatenation had the same quadratic stack cost). Post-fix verification: all 30 Group A inputs byte-identical to Python `check` (exit + stdout + stderr); full Sweep 1 re-run: `check` identical **892 / 896** (only the 4 Python-crash cases of group 2 still differ), build artifacts still 546 / 546; 11-scene artifact sweep still 72 / 72; `make test-smoke` passes.** This was a genuine native bug found by this sweep and is NOT in the divergence register below.
2. **Python crash (exit 70, `E9000`) not replicated — 4 cases.** Python dies with its generic internal-error message while the native binary emits proper diagnostics: `cube hero red at 0 0 0 size 2 shader checker` (Python 70 vs native 1, native reports E201) and the three missing-file glTF loads `load "quad.gltf" quad at 0,0,0`, `load "quad.gltf" quad at 5,0,0`, and the 160×120 scene containing the first of those (Python 70 vs native 3, native reports E501 file-not-found). See register item (2)/(6).

### Mismatch list (all 34, class (b))

| # (kept-index) | Python exit | Native exit | Input (first line / excerpt) | First differing line |
|---|---|---|---|---|
| 1 | 1 | -11 | `\n'use strict';\nconst assert = require('assert');\nconst E = require(process.argv[1]);\nassert(E && typeof E …` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:2:1: error E101: unexpected character '''" native='<missing>'; |
| 116 | 1 | -11 | `G.builders.circle(2, 8).forEach(function (t) {  t.slice(0, 3).forEach(function (v) {    assert.strictEqual(v[1…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:2: error E101: unexpected character '.'" native='<missing>'; |
| 207 | 1 | -11 | `Wave E compiler parity tests (seat E11).\n\nStdlib ``unittest`` only; standalone-runnable::\n\n    python3 tes…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:30: error E101: unexpected character '('" native='<missing>'; |
| 210 | 1 | -11 | `['tetrahedron','octahedron','icosahedron', 'dodecahedron'].forEach(function (name) {  [1, 2].forEach(function …` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:1: error E101: unexpected character '['" native='<missing>'; |
| 222 | 1 | -11 | `assert.deepStrictEqual(S.shadeRGB(['0.5'], [10, 20, 30], {}),  [128, 128, 128]);assert.deepStrictEqual(S.shade…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:7: error E101: unexpected character '.'" native='<missing>'; |
| 225 | 1 | -11 | `assert.ok(near(P.ggxD(1, 1), 1 / Math.PI, 1e-12));assert.ok(Number.isFinite(P.ggxD(1, 0)));assert.strictEqual(…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:7: error E101: unexpected character '.'" native='<missing>'; |
| 330 | 1 | -11 | `const attempts = [];const sess = makeSession(async t => {  attempts.push(t);  if (t === 'local') return {type:…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:16: error E101: unexpected character '='" native='<missing>'; |
| 331 | 1 | -11 | `const bad = [  [['foo'], /unknown/],  [['c', 'bogus', '+'], /unknown/],  [['nosuchfn'], /unknown/],  [['+'], /…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:11: error E101: unexpected character '='" native='<missing>'; |
| 333 | 1 | -11 | `const base = [220, 60, 60];const out = P.shadePoint({base, normal: [0, 0, 1],  worldPos: [0, 0, 0], camPos: [5…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:12: error E101: unexpected character '='" native='<missing>'; |
| 335 | 1 | -11 | `const c = [1, 2, 3], size = 4;const q = S.spriteQuad(c, size, [3, 2.5, 4]);assert.strictEqual(q.length, 4);for…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:9: error E101: unexpected character '='" native='<missing>'; |
| 342 | 1 | -11 | `const gl = new MockGL();const r = W.create(makeCanvas(gl));assert.ok(r, 'create must return a renderer');asser…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:10: error E101: unexpected character '='" native='<missing>'; |
| 344 | 1 | -11 | `const gl = new MockGL();const r = W.create(makeCanvas(gl));gl.calls.length = 0;assert.strictEqual(W.renderScen…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:10: error E101: unexpected character '='" native='<missing>'; |
| 345 | 1 | -11 | `const gl = new MockGL();const r = W.create(makeCanvas(gl));gl.calls.length = 0;assert.strictEqual(W.renderScen…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:10: error E101: unexpected character '='" native='<missing>'; |
| 346 | 1 | -11 | `const gl = new MockGL();const r = W.create(makeCanvas(gl));gl.calls.length = 0;const n = W.renderScene(r, TRIS…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:10: error E101: unexpected character '='" native='<missing>'; |
| 360 | 1 | -11 | `const o = [1/3, 1/3, 1], d = [0, 0, -1];const a = R.rayTriangle(o, d, [0,0,0], [1,0,0], [0,1,0]);const b = R.r…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:9: error E101: unexpected character '='" native='<missing>'; |
| 361 | 1 | -11 | `const o = [1/3, 1/3, 1], d = [0, 0, -1];const tri = [[0, 0, 0], [1, 0, 0], [0, 1, 0]];const h = R.rayTriangle(…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:9: error E101: unexpected character '='" native='<missing>'; |
| 362 | 1 | -11 | `const proj = new Float32Array(IDENT);const v0 = { projectionMatrix: proj,  transform: { matrix: new Float32Arr…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:12: error E101: unexpected character '='" native='<missing>'; |
| 364 | 1 | -11 | `const rows = S.glyphRows('A');let pop = 0;for (const row of rows)  for (let c = 0; c < 5; c++)    pop += (row …` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:12: error E101: unexpected character '='" native='<missing>'; |
| 375 | 1 | -11 | `const sess = makeSession();let gotMode = null, gotOpts = null;setNav({xr: {  isSessionSupported: async m => m …` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:12: error E101: unexpected character '='" native='<missing>'; |
| 376 | 1 | -11 | `const sess = makeSession();setNav({xr: {  isSessionSupported: async () => true,  requestSession: async () => s…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:12: error E101: unexpected character '='" native='<missing>'; |
| 379 | 1 | -11 | `const sys = %s;const st = P.state(sys, 2, 0.9);const q = P.quad(sys, 2, 0.9, [10, 3, -4]);assert.strictEqual(q…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:11: error E101: unexpected character '='" native='<missing>'; |
| 401 | 70 | 1 | `cube hero red at 0 0 0 size 2 shader checker\n` | exit python=70 native=1; stderr: line 1: python="error E9000: internal f3dc error -- please report it with 'f3dc --version' and the scene file (set F3DC_DEBUG=1 for a traceback)" native='warning W101: no scene statement: injecting default scene 640x480 bg #191923'; |
| 495 | 1 | -11 | `for (const cam of [[3, 2.5, 4], [0, 10, 0]]) {  const b = S.spriteBasis([0, 0, 0], cam);  assert.ok(near(len(b…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:5: error E101: unexpected character '('" native='<missing>'; |
| 516 | 1 | -11 | `function checkTris(tris) {  assert.ok(Array.isArray(tris), 'builder must return array');  tris.forEach(functio…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:19: error E101: unexpected character '('" native='<missing>'; |
| 517 | 1 | -11 | `function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}function cross(a,b){return[a[1]*b[2]-a[2]*b[1],a[2]*b…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:13: error E101: unexpected character '('" native='<missing>'; |
| 518 | 1 | -11 | `function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}function cross(a,b){return[a[1]*b[2]-a[2]*b[1],a[2]*b…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:13: error E101: unexpected character '('" native='<missing>'; |
| 519 | 1 | -11 | `function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}function cross(a,b){return[a[1]*b[2]-a[2]*b[1],a[2]*b…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:13: error E101: unexpected character '('" native='<missing>'; |
| 526 | 1 | -11 | `global.window = globalThis;eval(require('fs').readFileSync(process.env.F3D_KEYS, 'utf8'));const K = globalThis…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:7: error E101: unexpected character '.'" native='<missing>'; |
| 532 | 1 | -11 | `global.window = globalThis;eval(require('fs').readFileSync(process.env.F3D_RAYCAST, 'utf8'));const R = globalT…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:7: error E101: unexpected character '.'" native='<missing>'; |
| 538 | 1 | -11 | `global.window = globalThis;eval(require('fs').readFileSync(process.env.F3D_WEBGL2, 'utf8'));const W = globalTh…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:7: error E101: unexpected character '.'" native='<missing>'; |
| 539 | 1 | -11 | `global.window = globalThis;eval(require('fs').readFileSync(process.env.F3D_XR, 'utf8'));const X = globalThis.F…` | exit python=1 native=-11; stderr: line 1: python="/home/hatch/workspace/fortran-3d-engine/compiler/build/parity-final/sweep1-work/scene.f3d:1:7: error E101: unexpected character '.'" native='<missing>'; |
| 595 | 70 | 3 | `load "quad.gltf" quad at 0,0,0\n` | exit python=70 native=3; stderr: line 1: python="error E9000: internal f3dc error -- please report it with 'f3dc --version' and the scene file (set F3DC_DEBUG=1 for a traceback)" native='warning W101: no scene statement: injecting default scene 640x480 bg #191923'; |
| 596 | 70 | 3 | `load "quad.gltf" quad at 5,0,0\n` | exit python=70 native=3; stderr: line 1: python="error E9000: internal f3dc error -- please report it with 'f3dc --version' and the scene file (set F3DC_DEBUG=1 for a traceback)" native='warning W101: no scene statement: injecting default scene 640x480 bg #191923'; |
| 753 | 70 | 3 | `scene size 160 120\ncamera at 0 0 10 look 0 0 0\nload "quad.gltf" quad at 0,0,0\nrender still\n` | exit python=70 native=3; stderr: line 1: python="error E9000: internal f3dc error -- please report it with 'f3dc --version' and the scene file (set F3DC_DEBUG=1 for a traceback)" native='warning W101: no light statement: injecting default directional light dir (-0.5, -1, -0.7) intensity 1.0'; |

Full inputs, full stdout/stderr captures for both compilers are preserved in `compiler/build/parity-final/sweep1.json`.

## Sweep 2 — CLI surface battery

Cases run on the final binary vs Python, comparing exit code, stdout and stderr exactly (build cases: file list + every artifact byte, with only the `-o` directory path normalised in stdout; `new`: created file bytes compared): **29 / 29 PASS** (the +1 is the bare-file run below, run separately).

| Case | Result |
|---|---|
| --version | PASS |
| --help | PASS |
| -h | PASS |
| help run | PASS |
| help build | PASS |
| help check | PASS |
| help new | PASS |
| help preview | PASS |
| help fmt | PASS |
| help doctor | PASS |
| unknown command | PASS |
| no args | PASS |
| check valid | PASS |
| check valid --json | PASS |
| check valid --explain | PASS |
| check broken | PASS |
| check broken --json | PASS |
| check broken --explain | PASS |
| check missing | PASS |
| check missing --json | PASS |
| check missing --explain | PASS |
| fmt hello-like | PASS |
| fmt rocket | PASS |
| fmt broken | PASS |
| build hello-cube (file list + artifacts + normalized stdout/stderr) | PASS |
| build rocket (file list + artifacts + normalized stdout/stderr) | PASS |
| new myscene (created file bytes + stdout/stderr/rc) | PASS |
| doctor | PASS |
| bare-file run of hello-cube (`f3dc hello-cube.f3d`, separate scratch dirs) | PASS — stdout identical, stderr identical, file list identical, `build/output_render.ppm` sha256 identical (see below) |

Battery detail: `--version`, `--help`/`-h`, all 7 subcommand helps (run/build/check/new/preview/fmt/doctor), unknown command, no-args, `check` on valid/broken/missing scenes in text + `--json` + `--explain` forms (9 cases), `build` file lists + artifacts for hello-cube and rocket, `fmt` on 3 scenes including a broken one, `new` created-file bytes, and `doctor` — all matched exactly.

## Run / PPM hash equality (hello-cube)

Bare-file run of `examples/hello-cube.f3d` in separate scratch directories:

- Python `build/output_render.ppm` sha256: `090fa22a7faa670ef98dc16858006d6f0babb243a26e0f77dce471564942d19d`
- Native `build/output_render.ppm` sha256: `090fa22a7faa670ef98dc16858006d6f0babb243a26e0f77dce471564942d19d`
- **Verified equal** (and equal to the expected hash), with stdout, stderr and the full output file list (150 animation frame PPMs plus the 6 build artifacts) also identical.

## Strict golden

Engine no-arg render (`bin/engine3d` with no arguments, run in a scratch directory) produced `output_render.ppm` with sha256:

`28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`

**Verified** — byte-identical to the strict golden, unchanged.

## Preview acceptance

Stage-4 preview acceptance: **25/25, previously verified** (stated as previously verified; not re-run in full here).

Re-run in this sweep: the 5 core checks from `tests/compiler/test_preview.py`, adapted to the native binary on a scratch copy of `rocket.f3d` (ephemeral port, `--no-browser`): page **PASS**, version **PASS**, edit-bump **PASS** (valid edit `fov 60` → `fov 61`; version 1→2, ok), error **PASS** (broken scene → `ok:false`, ≥1 error, “Scene error” page, `/__status` diagnostics), recovery **PASS** (fixing the scene → `ok:true`). Total: **5/5 PASS**.

## Sweep 3 — repo test suites (oracle-side sanity)

`python3 tests/run_tests.py` (tests the PYTHON compiler and the Fortran engine; the oracle tree is untouched by the port): **PASS — RESULT: PASS (no layer failed); layers: compiler PASS, e2e PASS, fortran PASS (29 test programs), golden SKIP (no golden image committed, by design); 3 passed, 0 failed, 1 skipped** (exit 0). Full log: `compiler/build/parity-final/run_tests.log`. This proves the sweep/port did not break the oracle tree.

## Divergence register

Copied verbatim; each item marked **confirmed by sweep** or **not exercised** (by this sweep's corpus/battery).

- (1) Unicode byte-vs-codepoint semantics in lexer/parser/diagnostics (non-ASCII identifiers, columns, exotic line breaks) — **not exercised**. No kept corpus string contained non-ASCII bytes (0 of 896), and no CLI-battery case used non-ASCII input.
- (2) Python crash paths not replicated (format_text crash on pos-carrying diagnostics — oracle exit 70; _wrap_fortran_line hang on pathological lines) — **confirmed by sweep**. Four corpus `check` cases show Python exiting 70 (`E9000`) where native emits proper diagnostics and exits 1/3 (see Sweep 1 group 2). The specific format_text/_wrap_fortran_line sub-cases were not individually isolated.
- (3) arbitrary-precision ints beyond int64 (parser literals, JSON parsers, ext _as_int) — **not exercised**. No corpus string contained an integer literal of 19+ digits.
- (4) optimizer bare-string bag entries -> typed warning diagnostic (IR-visible text identical), non-numeric triangle coords kept vs Python TypeError — **not exercised**. No corpus mismatch was attributable to this item; all 91 build-compared inputs produced byte-identical artifacts.
- (5) particles colour-as-dict resolves via name (Python: default) — unreachable from .f3d — **not exercised**. As stated, unreachable from `.f3d`; the corpus is `.f3d`-only.
- (6) glTF: NaN/Infinity JSON literals rejected, two OS-error suffixes, null byteOffset path, tris-lines malformed suffix — **confirmed by sweep**. In part: the missing-file glTF `load` path diverged (Python exit 70 vs native exit 3, E501) in 3 corpus cases. The NaN/Infinity, null byteOffset and tris-lines sub-cases were not exercised.
- (7) preview transport differences (Connection: close, 501 body, E502 strerror format, watcher poll 100ms vs 0.4s, xdg-open timing) — **not exercised**. Preview core checks (page/version/edit-bump/error/recovery) passed 5/5, but transport-level headers/bodies/timing were not compared.
- (8) driver subprocess via shell+timeout vs argv exec, iostat-based OSError texts in E501/E502 paths — **not exercised**. The bare-file run matched stdout/stderr/PPM exactly; no iostat-text E501/E502 case was isolated (the glTF E501 case is counted under (2)/(6), where Python crashed instead).
- (9) sprite/particles classification by props vs class name — **not exercised**. Sprite/particles scenes in the corpus built byte-identically; no case distinguishing the classification route was isolated.
- (10) JSON error micro-positions in compat/gltf parsers approximated — **not exercised**. Corpus inputs were fed as `.f3d` files; malformed `.json`/`.gltf` inputs were not part of the sweep.
- (11) materials texture rewrite join_path vs Python abspath for relative textures under relative base_dir — **not exercised**. Texture scenes in the corpus built byte-identically; the specific relative-texture under relative-base_dir condition was not isolated.

### Additional divergence found by this sweep (not in the register above)

- **Native SIGSEGV (signal 11, no output) on invalid inputs that generate a very large number of diagnostics** — 30 of 896 corpus `check` cases (long JavaScript/docstring strings fed as `.f3d`). Python exits 1 with the full diagnostic dump in these cases. Short inputs of the same kind match exactly. This was the only native-side crash found by the sweep and the largest parity gap in this report. **FIXED 2026-11-23** — stack overflow from flang-18 concatenation alloca's accumulating inside `error_bag_format_text`'s assembly loop in `compiler/src/f3dc_errors.f90`; restructured to per-diagnostic block builders + a preallocated output buffer (see Sweep 1 group 1 for the full diagnosis). All 30 cases now byte-identical; corpus `check` parity is 892 / 896 with only the 4 Python-crash cases differing.

## Verdict

Byte-identical: all build artifacts for the 11 named scenes (72/72) and for every valid corpus input (546/546 files over 91 inputs); the full CLI surface battery (29/29 cases including the bare-file run); the hello-cube rendered PPM (sha256 `090fa22a…d19d` under both compilers); the strict engine golden (sha256 `28b6a81d…cec1`); and `check` output (stdout/stderr/exit) for 862 of 896 corpus inputs at sweep time — **892 of 896 after the 2026-11-23 SIGSEGV fix** (see Sweep 1 group 1). Not byte-identical: at sweep time, 34 corpus `check` cases — 30 where the native binary segfaulted on high-diagnostic-count invalid inputs where Python exits 1 (**all 30 fixed and re-verified byte-identical**), and 4 where Python itself crashes with exit 70 and the native binary (non-identically, but more usefully) emits proper diagnostics (the only remaining `check` mismatches) — plus the register items above, of which (2) and (6) were confirmed in part and the rest were not exercised by this sweep. The Python compiler remains in place pending the user's replacement decision.
