# P23 — Benchmark Plan vs Three.js (and PixiJS): Honest, Measured, Per-Feature

> **Status:** PLAN ONLY — no benchmark, script, `src/`, `Makefile`, or workflow
> file is created by this document. Every script/path in §8 is a specification
> to be built later, in its own approved change.
> **Repo baseline (verified 2026-11-23, by reading the tree):**
> `src/*.f90` = 629 lines total (`math_3d` 210, `renderer` 161, `mesh` 144,
> `main` 68, `camera` 46); `Makefile` = `gfortran -O3 -Wall -Wextra
> -fcheck=all -Jinclude`, target `bin/engine3d`; `src/main.f90` hard-codes
> one scene (640×480, one 12-triangle cube) and writes `output_render.ppm`
> (P3 ASCII, 3,686,895 B at root), `scene.json`, `model.obj`;
> `viewer.html` = 16,975 B / 541 lines, single-file Canvas 2D viewer —
> **not** the future JS runtime (P06). There is **no** `.f3d` compiler, **no**
> `runtime/f3d.min.js`, **no** `tests/`, **no** `benchmarks/`, **no** CI.
> **Toolchain in this planning environment (verified):** `node v24.22.1`,
> `python3 3.12.3`, GNU Make 4.3, `gcc 13` — and **no `gfortran`, no
> `hyperfine`, no `cloc`/`tokei`, no `brotli`, no `terser` binary**. So no
> Fortran timing in this document could have been measured here, and none is
> quoted. Any number below that is not sourced from the tree above is a
> *target, a method, or an explicitly flagged unverified figure* — never a result.
> **Product goal it serves:** a compiler that is *greater than Three.js /
> PixiJS* — where "greater" is only ever claimed **per feature row, per
> metric, from a committed measurement** (§6). There is no aggregate
> "we beat Three.js" claim in this plan, and the plan is designed so that
> such a claim cannot be smuggled out of its results.

---

## 1. The honesty law (read before any other section)

1. **No fabricated wins.** A metric is reportable only if a committed script,
   run against committed inputs on a recorded machine, produced a raw data
   file in `benchmarks/results/<date>-<machine>/` (§8.4). Memory, blog posts,
   vendor pages, and sibling plans are *hypotheses*, not measurements.
2. **Known unverified figures already in the plan series — do not reuse:**
   P06 states "Three.js is ~600 KB minified (~150 KB gzip) and PixiJS
   ~450 KB minified" with no version, file, or command attached. Those
   numbers are **quarantined**: §3 exists precisely to replace them with
   measured ones, and until it runs, public copy must say "not yet measured",
   not quote P06.
3. **Unlike things are never averaged, ranked, or put in one bar chart.**
   CPU software rasterisation (Fortran), GPU WebGL rendering (Three.js /
   our future JS runtime), and 2D sprite batching (PixiJS core) are three
   execution models. §7 lists exactly which cross-model numbers may sit
   side by side (as labelled facts) and which comparisons are forbidden
   (as wins).
4. **A feature we do not have scores GAP, not 0 lines / 0 bytes.** Shadows,
   textures, glTF, PBR, scene graph etc. are roadmap items in P02/P10–P17.
   Counting a missing feature as "infinitely concise" is the cheapest
   fabricated win in benchmark design and is banned (§6.3).
5. **Losses are published in the same table as wins.** If a row, metric, or
   scaling point goes to Three.js/PixiJS, the summary prints it. Selective
   publication voids the whole run.
6. **Perf numbers are reported, never gated** (consistent with P19 §1/§8.3):
   timing varies by machine; CI may trend it, a PR is never failed for it.
   Size and line counts, which are deterministic, *may* be gated (§9).

---

## 2. What is benchmarked: four metric families, kept separate

| Family | Question it answers | § | Comparable across systems? |
|---|---|---|---|
| **A. Bundle / deliverable size** | How many bytes must a user download / ship? | §3 | Yes — bytes are bytes, *within* a delivery model (web JS vs native binary reported separately) |
| **B. Authored code for the same task** | How much code/concepts does the user write? | §4 | Yes — under one published counting rule, for Three.js, PixiJS, and `.f3d` alike |
| **C. Native render time** | How fast is the Fortran software rasteriser, on its own terms? | §5.1 | Fortran-vs-Fortran (versions, flags, scaling) yes; vs GPU WebGL **no** (§7) |
| **D. Compile / build / time-to-first-pixel** | How long from source to picture, per pipeline stage? | §5.2 | Stage-by-stage yes; a single "faster" headline no |
| **E. Web runtime frame time** | Once our WebGL runtime (P06) exists, is it competitive *in the browser, on the GPU*? | §5.3 | Yes vs Three.js — **only** same browser/GPU/scene/resolution; this is the one fair FPS contest |

Families A+B are available earliest and are where the product's actual pitch
(ease, P01/P04/P06) lives. C is a fact about our engine, not a contest.
E is a real contest but is **blocked until the runtime exists** (§10).

---

## 3. Family A — Bundle size: measure real, in four labelled columns

### 3.1 Pin everything first

No measurement starts until `benchmarks/manifest.lock.json` (§8.2) records:
exact Three.js version, exact PixiJS version, exact `@pixi/3d` version (if
used — always reported *separately* from core PixiJS, per P02 §4.3), npm
registry tarball URLs + SHA-256 of each downloaded file, Node version, and
the minifier name+version. "Latest" is not a version. A re-run with a
different pin is a new result set, never an edit of an old one.

### 3.2 What is counted, per system

| System | Primary file(s) counted | Also reported, never merged into the primary number |
|---|---|---|
| Three.js (full, CDN-style) | The pinned release's minified module build file, as downloaded — `wc -c` on the exact file, filename+version printed | Gzip (`gzip -9`) and, where available, Brotli size of the same file |
| Three.js (bundled, per task) | Tree-shaken bundle for each §6 task app, built with one pinned bundler config (§3.3), minified, no sourcemap | Addon bytes *itemised*: e.g. `OrbitControls`, `OBJLoader`/`MTLLoader` are counted when the task uses them — neither silently included in "core" nor silently excluded from the task total |
| PixiJS core | The pinned release's minified bundle file, as downloaded | Gzip/Brotli as above. Labelled **2D engine** in every table |
| PixiJS + `@pixi/3d` | Core bytes **+** `@pixi/3d` package bytes, shown as a stacked/itemised figure | Never labelled "PixiJS" alone; P02: 3D there is a separate beta package with its own scene graph |
| **Ours — web** | `runtime/f3d.min.js` raw bytes (P06/P19 contract: ≤15,360 B) | Gzip alongside (never substituted, P19 §7.1); **plus** the task's emitted `scene.json` bytes, and the standalone emitted `.html` total — our runtime is small partly because the compiler did work upstream, and the scene payload is part of what the user ships |
| **Ours — native** | `bin/engine3d` bytes, unstripped and `strip`ped, both printed | Reported under the heading *native binary*, **never** in the same column/ranking as JS bundles: it needs no download in a browser because it does not run in one |
| Ours — today (baseline honesty) | `viewer.html` = **16,975 B**, unminified HTML+CSS+JS demo shell | Baseline only. Per P19 §7.1 it must not be scored against the 15 KiB runtime budget, and must not be quoted as "our bundle size" |

Rules applying to every row: raw bytes are the headline; compressed bytes are
a second column, same compressor+level for all systems; no cherry-picking
"min+gzip of ours vs raw full build of theirs"; library bytes and
*application* bytes are separate columns (a Three.js task app is a few KB of
user JS on top of the library — hiding either number distorts in opposite
directions).

### 3.3 Two delivery modes, both measured, never conflated

1. **Full-file mode:** user includes the whole library (CDN `<script>` /
   importmap). Count §3.2 primary files.
2. **Bundled mode:** pinned bundler (one of esbuild/Rollup — choice and exact
   version recorded in the manifest; config committed, identical settings for
   all three systems: minify on, sourcemaps off, target recorded), one entry
   per §6 task. This is how most real Three.js apps ship, and tree-shaking
   is a legitimate Three.js strength — omitting this mode would rig Family A.

`.f3d` has no bundled mode in v1 (P06: plain file, no build step) — that
absence is itself reported as a workflow fact in §5.2, not converted into a
byte figure.

---

## 4. Family B — Lines of code and concepts for the *same* tasks

### 4.1 Reuse P01's counting rules; extend, don't reinvent

P01 §1 is the baseline method and its Three.js figures (hand-counted,
±20%) are the *prior* this family must re-derive mechanically:

- Physical, non-blank, non-comment lines; **Terse** and **Idiomatic** variants
  for JS; **Total = Idiomatic + HTML shell** (P01 fixed the shell at +13).
- P23 changes three things, all disclosed wherever results are printed:
  (a) counts are produced by a committed counter script (§8.3) over committed
  task sources, not by hand — hand and script counts are both printed for the
  first run so the delta vs P01 is visible, not hidden;
  (b) **build/config lines are counted in their own column** (`package.json`,
  importmap, bundler config) — P01 excluded them; excluding them flatters
  Three.js/PixiJS, including them in the main column would break comparability
  with P01, so: separate column, both totals printed;
  (c) PixiJS tasks are counted under *identical* rules, with core-only and
  `+@pixi/3d` variants as separate sources where a task needs the extension.
- `.f3d` side: authored `.f3d` lines only in the headline column; generated
  Fortran/JS/JSON is disclosed in a *generated lines/bytes* column (P01 R6
  honesty law). A task the DSL cannot yet express is **not counted at all** —
  it is a GAP row (§6.3), and any escape-hatch version is counted separately
  and labelled as such.
- Deterministic seeded sources: every task's sources for all systems are
  written to the *same* functional spec (same objects, colours, camera,
  motion, output size), reviewed side by side, and committed *before*
  counting. Nobody counts code written by an advocate of one side alone:
  the Three.js/PixiJS versions must be idiomatic, tutorial-grade code a
  competent user would write — golfed JS and straw-man JS both invalidate
  the run (P01 §1 honesty note 1 applies in reverse too).

### 4.2 Beyond lines: the three sub-metrics that make "easier" falsifiable

Per task, per system, also recorded (P01 §3/§5 already defines most of these):

| Sub-metric | Definition |
|---|---|
| **Concepts to first pixel** | Distinct classes/APIs/language constructs a new user must name to get the task on screen (P01 counted ~20 across its census; count the same way) |
| **Defaults-correct count** | Of a fixed checklist — lit, antialiased, pixel-ratio capped, resize-correct, delta-timed, damped orbit (when orbit is in the task), sRGB-correct (when textured), no-silent-black on error — how many are correct *without the user writing anything for them* |
| **Silent-failure modes** | Number of distinct ways the committed task source can be plausibly broken (omitted line/flag) that produce a black/empty/wrong image with **no** diagnostic. Counted by actually performing each omission and recording the result — not by assertion |

---

## 5. Families C, D, E — Time

### 5.1 C: Native (Fortran) render time — a scaling fact, not a contest

- **Subject:** `bin/engine3d`'s software rasteriser (`renderer.f90`:
  barycentric fill, Z-buffer, per-face Lambert) only.
- **Workloads (generated fixtures, committed generators, not hand-made
  files):** the demo cube (12 tris) plus procedural scenes at
  1k / 10k / 100k triangles, each rendered at 320×240, 640×480, 1280×720.
  Triangle count and resolution vary independently — one "demo cube time"
  generalises to nothing.
- **Split the timings — this is mandatory with the current code:** the
  shipped program spends much of its wall time *writing P3 ASCII PPM*
  (3,686,895 B for one 640×480 frame). Report (i) end-to-end program time,
  (ii) rasterise-only time, (iii) file-write time, as three numbers.
  (ii) requires timing instrumentation around
  `framebuffer_render_mesh` / `framebuffer_save_ppm`; that instrumentation
  is an implementation task this plan specifies but does not perform, and
  until it exists only (i) may be published, labelled end-to-end.
  Quoting (i) as "render time" is a banned claim (§7).
- **Flags honesty:** the Makefile's `-O3 … -fcheck=all` mixes optimisation
  with run-time checks. Report the as-shipped flags *and* an
  `-O3`-without-`-fcheck=all` build as two labelled configurations; never
  silently benchmark a flags variant users don't get, and never ship a
  benchmark-only flags change as if it were the product.
- **Method:** §8.4 statistics (warm-ups, ≥15 timed repetitions, interleaving
  where two configurations are compared, median + p95 + min, CPU model /
  governor / load recorded). Derived units allowed: ms/frame, Mtri·s⁻¹,
  Mpixel·s⁻¹ — each tied to its workload cell.
- **Allowed framing:** "our software rasteriser renders *X* tris at *Y*
  ms/frame at 640×480 on *<recorded CPU>*, single-threaded" — a standalone,
  checkable fact. Forbidden framing: §7.

### 5.2 D: Compile / build time, stage by stage

Pipelines are different shapes, so the unit is the **stage table**, not a race:

| Stage | Ours (when the compiler exists) | Three.js / PixiJS equivalent |
|---|---|---|
| Author → runnable artefact | `f3dc build <task>.f3d`: lex/parse/validate/emit, per-stage wall time | Bundler build (`build` command of the pinned bundler) for the task app, wall time |
| Artefact → executable | `gfortran` clean build: `make clean && make` (all 5 modules), and incremental (touch one module) — two numbers | — (no native compile; print `—`, not 0) |
| One-time project setup | `f3dc new` + first build, commands counted and timed, **excluding network** | `npm create`/install + first build: commands counted; install timed separately and flagged network/cache-dependent, never in a headline |
| Runnable → first pixel | Native: process start → PPM written. Web: §5.3 harness, page load → first presented frame | Same web harness for Three.js/PixiJS task apps |

Rules: clean vs incremental and cold-cache vs warm-cache are always separate
rows; `gfortran --version` is recorded (`.mod`/FP behaviour is
version-sensitive, P19 §4.1); a stage a system doesn't have is `—`
("does not exist"), which is a *workflow* observation, not a time of zero.

**Blocker for this environment:** with no `gfortran` on this machine (§0),
no Fortran compile time can be produced here at all. The plan's scripts must
fail loudly (`gfortran: command not found` → run aborted, no partial table)
rather than fall back to `gcc` or skip the column.

### 5.3 E: Web frame time — the one fair FPS contest (blocked until P06 lands)

- **Contestants:** our P06 WebGL1 runtime vs Three.js WebGL, and — for 3D
  rows only — PixiJS `+@pixi/3d`. PixiJS *core* enters E only on a genuinely
  2D task, where it is labelled a 2D contest and we may simply not compete.
- **Fairness contract (all must hold, or the run is void):** same machine,
  same browser + version, same GPU/driver, same scene (same triangle count,
  same colours/shading model — flat/Lambert only, since that is all our
  renderer does today; a Three.js scene using PBR/shadows is a *different,
  heavier* scene and beating it would prove nothing), same canvas size and
  devicePixelRatio (capped at 2 per P06 §5.4), same camera path (scripted,
  deterministic, no human mouse), WebGL context for both.
- **Measurement:** in-page `requestAnimationFrame` delta series over a fixed
  scripted run (≥10 s after ≥2 s warm-up), captured by a pinned headless-
  browser harness (§8.3); report median frame time, p95, p99, and FPS
  derived from the median — never a single `fps` counter reading, never the
  best second. Headless-browser GPU behaviour differs from a real display
  session: the harness, GPU string (`WEBGL_debug_renderer_info`), and
  headless flags are recorded, and results are labelled *headless* until
  re-run in a headed browser on the target machine (owner's Vega 7-class
  iGPU hardware is a required second cell, P06 §5.3).
- **Render-on-demand trap (P06 §7.1):** our runtime deliberately renders
  ~0 fps for a static scene. FPS comparisons are run only on *animated*
  scenes with the dirty-flag path exercised identically, and static-scene
  power/CPU behaviour is reported as its own metric (CPU % at idle scene),
  never converted into an FPS figure.

---

## 6. Per-feature parity benchmark (the expansion structure)

### 6.1 The row set

Rows are the union of P01's 10 tasks, P02's capability census, and the
feature plans P10–P17. A row exists even if — especially if — we currently
fail it. Rows may be added; a row may be removed only by a plan amendment
stating why, never silently between runs.

| Row | Feature | Source plan |
|---|---|---|
| F01 | Rotating cube (hello-world) | P01 #1 |
| F02 | Lit sphere (lights as a feature) | P01 #2 |
| F03 | Textured plane (texture + UV + colour space) | P01 #3, P14 |
| F04 | Orbit camera (incl. damping, limits) | P01 #4, P13 |
| F05 | Delta-timed animation loop / declarative motion | P01 #5, P09 |
| F06 | Multi-object scene (10 objects, varied) | P01 #6 |
| F07 | Shadows (one caster, ground, one light) | P01 #7, P10 |
| F08 | Loading an OBJ model (+MTL) | P01 #8, P15 |
| F09 | Particles (1,000 points) | P01 #9 |
| F10 | Responsive resize | P01 #10 |
| F11 | Primitives set (sphere/cylinder/cone/torus/plane beyond cube) | P11 |
| F12 | Materials & lighting modes (flat / Lambert / Phong, PBR) | P10 |
| F13 | Scene graph / hierarchy / grouping | P12 (**rejected for v1** — row stays, verdict GAP until that changes) |
| F14 | Camera types & input beyond orbit (pan/zoom/FPS-style, keys/touch) | P13 |
| F15 | glTF/GLB loading | P15, P02 #9 |
| F16 | Multi-object instancing (100+ copies of one mesh) | P16 |
| F17 | Render targets / offscreen / post-processing | P17 |
| F18 | Headless / non-browser render to file | P02 #16 (our native path; Three.js/PixiJS: not native — see §6.3 rule for inverse gaps) |

### 6.2 Columns recorded for every row

For each of **Three.js**, **PixiJS core**, **PixiJS + `@pixi/3d`**,
**`.f3d` (ours)**:

| Column | Family |
|---|---|
| Status: `WORKS` / `WORKS-VIA-ADDON` / `WORKAROUND` / `NOT-POSSIBLE` / `NOT-YET (ours)` | — |
| Authored LOC — terse, idiomatic, total incl. shell, config column (§4.1) | B |
| Concepts to first pixel; defaults-correct *n/N*; silent-failure modes *n* | B |
| Runtime bytes attributable to the row: library mode (full / bundled) + app + scene payload (§3) | A |
| Frame time (web, §5.3 conditions) and/or native render time (§5.1) — in their separate labelled sub-columns | E / C |
| Time-to-first-pixel stage summary (§5.2) | D |

PixiJS core and `+@pixi/3d` are **never merged into one column**: P02 shows
they are different products in effect (2D core vs beta 3D add-on, separate
scene graph), and merging them would fabricate a PixiJS that no user can
install.

### 6.3 Verdict rules per row (applied mechanically, not by the row's author)

| Verdict | Rule |
|---|---|
| **WIN** | Our status is `WORKS`, **and** we are strictly better on ≥1 of {LOC idiomatic, concepts, defaults-correct, attributable bytes} by more than the counting noise (LOC: >20%, per P01's ±20%; bytes: >5%), **and** not materially worse (>20% LOC / >5% bytes / a whole defaults point) on any other recorded column, **and** any frame-time column present was measured under §5.3/§5.1 rules |
| **PARITY** | `WORKS` on both sides, all compared columns within noise, or wins and losses that cancel and are printed together |
| **GAP** | Opponent `WORKS` (incl. via its official addon) and ours is `NOT-YET`, `WORKAROUND`, or requires the escape hatch. **GAP rows have no LOC/byte score for us** — blank, not zero |
| **INVERSE-GAP** | We `WORK` and the opponent is `NOT-POSSIBLE`/`WORKAROUND` (e.g. F18 headless native render; P02 #16). Reported as a *capability* fact with the opponent's workaround costed in LOC where one exists — never as a speed/size win |
| **NOT-COMPARABLE** | Execution models or scene semantics differ so no shared metric is honest for that column (e.g. Fortran CPU ms/frame vs WebGL GPU ms/frame; PixiJS core 2D sprite FPS on a 3D row). The cell prints `n/c` with the reason — an `n/c` cell can never support a WIN |
| **BLOCKED** | A §10 blocker prevents measuring a column that would otherwise be comparable (no runtime yet, no `gfortran` here, feature unimplemented). Distinct from GAP: GAP is a product fact, BLOCKED is a measurement fact; a row can be both, in different columns |

**Roll-up rule:** there is no total score. The published summary is the full
table plus three counts — rows WIN / PARITY / GAP (+INVERSE-GAP,
NOT-COMPARABLE, BLOCKED listed, not netted). "Better per feature row" is the
claim; anything broader ("better engine", "faster", "smaller overall") is
outside what this benchmark can issue (§7).

### 6.4 Worked expectation (illustrative, *not* results)

F01 rotating cube is the row the whole product is aimed at: P01 gives
Three.js 28 idiomatic JS / 41 total and a `.f3d` target of ≤5 lines (P01 §5).
If the compiler lands, F01 should test WIN on LOC/concepts/defaults — while
its frame-time cell vs Three.js WebGL stays `n/c` for the Fortran path and
becomes a real §5.3 contest only for the JS runtime. F07 shadows and F13
scene graph are expected GAP today. A first published table that does not
contain several GAPs is, by construction, a table that was rigged.

---

## 7. Claims ledger — what we can and cannot say

### 7.1 CAN claim (each only with its measurement artefact linked)

| Claim shape | Requires |
|---|---|
| "Task *T* takes *N* authored lines in `.f3d` vs *M* idiomatic in Three.js *<version>*" | §4 counter output + committed sources for both sides |
| "Our web runtime is *N* B raw / *G* B gzip; Three.js *<version>*'s minified build is *M* B raw / *G′* B gzip, same compressor" | §3.2 files + hashes in the manifest |
| "For task *T*, the bundled Three.js app + addons total *X* B vs our runtime + scene *Y* B" | §3.3 bundled run, addon itemisation shown |
| "Our software rasteriser renders *<fixture>* in *t* ms median (rasterise-only) on *<CPU>*" | §5.1 split timings + env record |
| "Clean `gfortran` build takes *t* s; `f3dc build` takes *t′* s for *<task>*" | §5.2 stage table on a recorded machine with `gfortran` present |
| "In the same browser/GPU/scene, our WebGL runtime's median frame time is *t* vs Three.js's *t′*" | §5.3 fairness contract fully satisfied and logged |
| "Feature *F* needs no user code here (default) and *k* lines in Three.js" | §4.2 defaults checklist, verified by the omission tests |

### 7.2 CANNOT claim (banned, with the reason printed wherever it matters)

| Banned claim | Why it is dishonest |
|---|---|
| **"Faster than Three.js" / any FPS win from Fortran CPU timings vs WebGL** | **CPU software rasterisation vs GPU-accelerated WebGL is not a fair win in either direction.** The GPU does per-pixel work massively in parallel on different hardware; the Fortran renderer does it serially on CPU (single-threaded today). A Fortran "win" would mean the scene/resolution differed; a Three.js win proves only that GPUs rasterise fast. Both numbers may be *printed*, labelled by execution model, with `n/c` in the verdict cell (§6.3) — neither may be ranked |
| "Faster than PixiJS" from any 3D scene | PixiJS core is a 2D engine (P02); its batching figures are for 2D sprites. There is no shared workload |
| "Smaller than Three.js" quoting only `f3d.min.js` | Excludes our scene payload and the compiler's upstream work (§3.2); and quoting P06's unmeasured ~600 KB figure for Three.js compounds it (§1.2) |
| "Smaller binary than Three.js" from `bin/engine3d` bytes | Native binary vs JS bundle are different delivery models (§3.2) |
| Any LOC win on a GAP feature (shadows, glTF, PBR, scene graph…) | We didn't write less code; we didn't write the feature (§1.4) |
| "Render time" quoted from the shipped program's end-to-end time | Includes P3 ASCII PPM writing, which dominates (§5.1); the split is mandatory |
| Compile-time wins that include the opponent's `npm install` network time, or exclude our `gfortran` stage | §5.2 stage rules |
| Frame-time wins from a static scene against our render-on-demand runtime, or from unmatched shading models/DPR/resolution | §5.3 fairness contract |
| Ecosystem, maturity, or community comparisons dressed as benchmark results | LOC/bytes do not measure them (P01 §6); they belong in prose, labelled opinion/context |
| Any number from a machine/toolchain that is not in the run's env record — including any Fortran number attributed to *this* planning environment, which has no `gfortran` | §1.1, §5.2 blocker |

---

## 8. Reproducible scripts (specification — to be built, not yet built)

### 8.1 Layout

```
benchmarks/
  manifest.lock.json        # §8.2 — pins: versions, hashes, tool versions
  tasks/
    F01-rotating-cube/  spec.md  three/  pixi/  pixi3d/  f3d/   # §6 rows, one dir each
    F02-lit-sphere/     …
    … F18-headless/
  fixtures/                 # procedural scene generators for §5.1 (12 / 1k / 10k / 100k tris)
  scripts/
    fetch_libs.sh           # download pinned Three.js/PixiJS files, verify SHA-256, print wc -c
    measure_bundle.sh       # §3: raw/gzip(/brotli) for every §3.2 file, full + bundled modes
    count_loc.py            # §4: one counter, all languages, all columns incl. config + generated
    bench_native.sh         # §5.1: build (both flag configs), run fixtures × resolutions, raw timings
    bench_compile.sh        # §5.2: clean/incremental/stage timings, all pipelines
    bench_web.mjs           # §5.3: pinned headless-browser harness, rAF series → raw JSON
    summarise.py            # raw CSV/JSON → the §6.2 table + §6.3 verdicts (mechanical rules)
  results/
    <YYYY-MM-DD>-<machine-id>/  env.txt  raw.csv  raw-web.json  summary.md
```

### 8.2 `manifest.lock.json` (fields)

`three_version, three_file, three_sha256, pixi_version, pixi_file,
pixi_sha256, pixi3d_version (or null), bundler+version, minifier+version,
node, python, gfortran (or "ABSENT — native/compile families not run"),
browser+version, cpu_model, gpu_string, os, date`. `summarise.py` refuses
to emit a table if a field required by a family's rows is missing — a
partial table with silently missing columns is how fabricated wins start.

### 8.3 Tool choices

| Need | Tool | Notes |
|---|---|---|
| Byte counts | `wc -c`, `gzip -9`, `brotli` if present else recorded absent | No bundlephobia/online calculators as primary source (unpinned, unrepeatable); allowed only as a sanity cross-check, labelled as such |
| LOC/concepts | `count_loc.py` (committed, stdlib-only) | One implementation for Fortran/JS/`.f3d`/HTML/config so no language gets a friendlier counter; blank/comment rules per §4.1, unit-tested on fixtures with known counts |
| Native/compile timing | `hyperfine` if available; else a Python harness (`time.perf_counter` around subprocess, same statistics) | Whichever is used is recorded; `/usr/bin/time -v` additionally captures peak RSS for the native runs (memory is a reportable fact, not a verdict) |
| Web timing | Pinned headless Chrome via a pinned driver (`puppeteer-core`-style), version in manifest | This planning agent cannot drive a live browser; the harness build/run is an implementation task for an agent/machine with browser access, and §5.3's headed re-run cell is scheduled there too |
| Statistics | `summarise.py` (stdlib) | §8.4 rules hard-coded, not per-run options |

### 8.4 Statistics and environment rules (all time families)

- Record first, summarise second: scripts write append-only raw files
  (one line/sample: family, workload, config, run index, ms, env id);
  summaries are regenerated from raw, never edited.
- ≥3 warm-up runs (discarded, but counted in raw), ≥15 timed repetitions
  per cell; report **median, p95, min, n** — never mean alone, never best-only.
- Compared configurations are **interleaved** (A B A B…), not run as two
  blocks, so thermal/load drift hits both sides.
- One machine per result set; machine id = CPU model + OS + (for web) GPU
  string. No pooling across machines. Background load, power/governor
  state, and display/headless mode are noted in `env.txt`.
- Outliers are kept in raw and visible in p95; dropping samples requires a
  rule stated in `summarise.py` before the run, not a judgement after it.
- Determinism checks: same-seed fixture generators; render outputs from
  timed runs are hashed — if two systems' images differ beyond the P19
  golden tolerance, the timing for that cell is **void** (they were not
  rendering the same thing) and the row records why.

### 8.5 The one-command run

`benchmarks/scripts/run_all.sh` (spec): verify manifest + tool presence
(abort loudly on missing `gfortran`/browser where a family needs it) →
fetch+hash libs → Family A → Family B → C → D → E → `summarise.py`.
Each family can also run alone. A family whose prerequisites are absent is
reported `BLOCKED` in the summary — never skipped silently, never faked
with a substitute tool.

---

## 9. Reporting format and gates

- **Published artefact:** `results/<date>-<machine>/summary.md` containing:
  env record, Family A table (§3.2 columns), Family B table (§4 columns),
  C/D stage tables, E table (or BLOCKED), and the §6.2 parity table with
  §6.3 verdicts and WIN/PARITY/GAP counts. Raw files sit beside it.
- **Public-copy rule:** any README/marketing sentence derived from a run
  must cite the run's path and date, name versions, and link the summary.
  A claim without a run path is treated as unmeasured (§1.1).
- **Gates (deterministic only, per §1.6):** `f3d.min.js` ≤ 15,360 B (P06/P19)
  and per-row LOC budgets (P01 R5) may fail CI once the artefacts exist.
  Times (C/D/E) are trend-reported in the CI summary (P19 §8.3 style),
  never merge gates.
- **Re-run cadence:** on any pinned-version change, on any renderer/runtime
  change, and before any public comparison is published or renewed.
  `@pixi/3d` is beta and moving (P02 §4.3) — Pixi rows expire fastest;
  a summary older than the newest pin it names is stale and must say so.

---

## 10. Blockers and rollout order

| # | Blocker | Blocks | Minimum viable unblocking |
|---|---|---|---|
| K1 | No `.f3d` compiler (P04 not built) | All `.f3d` columns in B, D; F-rows' our-status | P04 pipeline producing a runnable hello-cube |
| K2 | No JS runtime (P06 not built) | Family A (ours-web), Family E entirely | `runtime/f3d.min.js` from a committed, repeatable minify command (P19 B3) |
| K3 | No `gfortran` in this environment | Families C, D (native parts) — **here** | Run those families on a machine with `gfortran` (CI runner per P19, or owner's PC); record version |
| K4 | `src/main.f90` hard-codes one scene/size; no timing instrumentation | §5.1 workloads + split timings | Parameterised fixture driver + timers around rasterise vs PPM-write (implementation change, separately approved) |
| K5 | No Three.js/PixiJS task sources exist | Families A (bundled), B, E | §6 task sources written to shared specs and committed (§4.1) |
| K6 | No browser harness / headed test machine | Family E | §8.3 harness + a headed cell on Vega 7-class hardware (P06 §5.3) |
| K7 | Features on roadmap only (P10–P17) | F03, F07, F11–F17 our-columns | Nothing to do in benchmarking: rows publish as GAP until the feature plans land |

**Rollout:**

| Phase | Contents | Exit criterion |
|---|---|---|
| v0 | Manifest, `fetch_libs.sh`, `measure_bundle.sh` (theirs + `viewer.html` baseline), `count_loc.py` re-deriving P01's Three.js counts + first PixiJS counts | Script counts match P01 hand counts within ±20% or the delta is explained in the summary |
| v1 | §6 task sources for F01–F10 (Three.js + Pixi variants); first parity table with our side honestly BLOCKED/GAP where K1/K2 apply | Table publishes with GAP/BLOCKED rows visible — a v1 table with no gaps fails review |
| v2 | Families C+D on a `gfortran` machine (K3/K4 closed) | Split rasterise/write timings reported for all §5.1 cells |
| v3 | Family A ours-web + Family E (K2/K6 closed) | §5.3 fairness log complete for F01/F02/F06 at minimum |
| Ongoing | Re-runs per §9 cadence; rows F11–F18 fill in as features land | No public claim older than its run |

---

## 11. Risks

| Risk | Mitigation |
|---|---|
| Benchmarketing: choosing tasks/scenes/sizes that flatter us | Row set fixed in §6.1 *before* results exist; scene specs shared across systems; image-hash equality check (§8.4) voids mismatched cells |
| Straw-man opponent code inflating Family B | Idiomatic, tutorial-grade opponent sources, reviewed against P01's published examples; terse column shows the floor honestly |
| Version drift making old wins silently false | Pins + hashes (§8.2); §9 expiry rule; re-run on pin change |
| Headless-GPU numbers misread as real-world FPS | §5.3 labelling + mandatory headed second cell before any public FPS sentence |
| Pressure to produce a single "winner" score | §6.3 roll-up rule: counts per verdict only; §7.2 bans the aggregate claims |
| `-fcheck=all` / flag games in native timings | §5.1: both flag configurations, labelled; benchmark-only flags banned |

---

*End of P23 — planning only. No `benchmarks/` file, script, workflow, or
`src/` change was made. Companion plans: P01 (LOC census + counting rules),
P02 (PixiJS capability census), P04 (compiler), P06 (JS runtime + size
budget), P19 (CI reporting/gating style).*
