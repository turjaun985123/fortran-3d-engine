# P19 — CI / GitHub Actions Spec: Build, Compiler Tests, Golden Render, JS Size, Docs Lint

> **Status:** PLAN ONLY — no workflow file created by this document. Do not
> create `.github/workflows/*` until this spec is approved and §2 blockers close.
> **Repo baseline (verified 2026-11-23):** no `.github/`, no CI, no `tests/`
> directory. Build is `Makefile` only: `gfortran -O3 -Wall -Wextra -fcheck=all
> -Jinclude`, modules `src/math_3d.f90`, `src/mesh.f90`, `src/camera.f90`,
> `src/renderer.f90` → `obj/*.o` + `include/*.mod`, `src/main.f90` → target
> `bin/engine3d`, run writes `output_render.ppm` (640×480 demo cube in
> `src/main.f90`). Present at root: `scene.json`, `model.obj`, `viewer.html`
> (16,975 B, single-file Canvas 2D viewer — *not* the future JS runtime, §6).
> **Product goal:** an *easy* 3D compiler. CI is its trust signal: every PR
> proves (a) it builds clean, (b) the compiler behaves, (c) a picture did not
> silently change, (d) the shipped JS stays tiny (<15 KB, P06), (e) docs do
> not rot — in minutes, with a failure a beginner can act on.

---

## 1. Principles and Non-Goals

| Principle | Consequence |
|---|---|
| One canonical job, mirrors as checks | Golden verdicts come from one pinned cell (§4) only; other matrix cells are build/smoke signals, never competing goldens |
| Fast PR gate, deep nightly | PR target ≤5 min wall-clock; exhaustive matrix + larger renders run nightly / on demand, not per push |
| Failures are artefacts, not log archaeology | Every failing job uploads its outputs + writes a Job Summary (§8); no "scroll 4,000 lines" |
| No secrets, no publishing | CI builds and tests only. No release, deploy, npm/Pages publish, or credentials in v1 |
| Deterministic before clever | Pinned action versions (full SHA or major tag per §3.3), pinned compiler for goldens, no floating `latest` tools in verdict paths |
| Warnings visible, not yet fatal | Makefile already passes `-Wall -Wextra`; v1 records warnings, a follow-up ratchets to `-Werror` once the baseline is proven warning-free in CI (do not assume it — local `gfortran` was unavailable at planning time) |

**Non-goals (v1):** Windows/macOS parity claims, coverage dashboards, code
signing, release packaging, performance benchmarking gates (timing is
reported, never failed, §8.3), and testing unmerged future stages as if they
existed — compiler/JS/docs checks are *staged* (§2, §9).

---

## 2. Blockers — Nothing Here Is Greenfield-Until-These-Exist

CI cannot be written against vapour. Each check lists its prerequisite:

| # | Blocker | Needed for | Minimum viable form |
|---|---|---|---|
| B1 | `tests/` suite (README promises one; none exists) | Compiler/unit tests (§5) | `tests/run_tests.sh` (or `make test` target — preferred, §5.1) exiting non-zero on failure, printing one `PASS`/`FAIL <name>` line per case |
| B2 | Committed golden render + generator (§6.1) | Golden check | Small deterministic scene + reference PPM/PNG + checksum, in `tests/golden/` — **not** the 3,686,895 B root `output_render.ppm`, and not a file regenerated from the same code under test |
| B3 | JS runtime artefact (P06) | Size check (§6→§7) | `runtime/f3d.min.js` produced by a repeatable, committed minify command; until then the size job is `if: false`-style *absent*, not a check on `viewer.html` |
| B4 | Docs lint config | Docs lint (§7.2) | Committed `.markdownlint.*` config + link-check config with the repo's rules (line length off for tables/code is typical); unconfigured default lint on `docs/plan/*.md` would fail on style noise, not errors |
| B5 | `make test` / variables | All jobs | Makefile targets or documented env overrides for: test, golden-scene render at reduced size, and `FFLAGS` override — today only `all`/`run`/`clean` exist, and `run` hard-codes 640×480 via `src/main.f90` |

Until B1–B5 land, the only honest v0 workflow is **build + smoke run** (§4,
job `build`). Adding placeholder jobs that always pass is explicitly rejected.

---

## 3. Workflow Outline (specification, not a file)

### 3.1 Files (when approved)

```
.github/workflows/ci.yml        # the one PR/push workflow in this spec
.github/workflows/nightly.yml   # OPTIONAL phase 2: full matrix + big render
# No reusable workflows, no composite actions in v1 — one repo, one file to read.
```

### 3.2 Triggers, permissions, concurrency (outline)

```yaml
# OUTLINE ONLY — values to transcribe on approval, not a created workflow
name: CI
on:
  push:        { branches: [main] }
  pull_request: { branches: [main] }
  workflow_dispatch: {}            # manual re-run / debugging
  # nightly.yml only: schedule: [{ cron: "17 3 * * *" }]  # off-peak, non-round hour
permissions: { contents: read }    # least privilege; no writes, no PR comments in v1
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true         # superseded PR pushes cancel; never cancel main
env:
  MAKEFLAGS: -j2                   # modest: free runners + .mod ordering is serial-sensitive
```

No `pull_request_target`, no secret use, no checkout of untrusted code with
write tokens — fork PRs must run identically and safely under `contents: read`.

### 3.3 Action pinning

Use only: `actions/checkout@v4`, `actions/cache@v4`,
`actions/upload-artifact@v4`, `actions/setup-node@v4` (docs/JS jobs only).
Record the resolved SHAs at implementation time and let Dependabot (separate,
later decision) propose bumps — a bump that changes a golden or size verdict
is a PR to review, not an auto-merge.

---

## 4. Job Graph and Matrix

```
        ┌─ build (matrix, §4.1) ── smoke run ──────────────┐
push/PR ┼─ compiler-tests (needs: build-canonical)          ├─► ci-summary (§8)
        ├─ golden-render  (needs: build-canonical, pinned)  │
        ├─ js-size        (independent, node only)          │
        └─ docs-lint      (independent, node only) ─────────┘
```

Independent jobs run in parallel; `compiler-tests`/`golden-render` reuse the
canonical build rather than rebuilding differently. A red job never blocks
the *others* from reporting — the summary aggregates all five.

### 4.1 Matrix

| Axis | PR gate | Nightly (phase 2) | Rationale |
|---|---|---|---|
| OS | `ubuntu-24.04` only | `ubuntu-22.04`, `ubuntu-24.04`, `macos-latest` | Linux/gfortran is the only supported platform today; macOS is signal-only (`continue-on-error: true`), never a merge gate until supported. **Windows excluded:** no MSYS2/gfortran story exists in the repo; adding one is a platform project, not a CI cell |
| gfortran | Runner default, version *printed and recorded* | 12, 13, 14 via `apt`/toolchain setup where available | `.mod` files and FP results are compiler-version-sensitive (§6.2); breadth belongs in nightly, not the PR gate |
| Build type | As-shipped: `-O3` (Makefile default) | `-O2` variant + a `-O0 -fcheck=all` debug cell | Catches optimisation-sensitive UB / uninitialised use that one `-O3` build hides |
| Canonical cell | `ubuntu-24.04` + runner-default gfortran + `-O3` | — | Sole source of golden + test verdicts; named explicitly (`build-canonical`), not "first matrix leg" |

Rules: `fail-fast: false` on every matrix (one cell's failure must not cancel
the evidence from the others); matrix is defined per-job, not globally —
`js-size` and `docs-lint` have **no** Fortran matrix at all.

### 4.2 Build job steps (outline)

1. Checkout → install/verify toolchain: `gfortran --version`, `make --version`
   echoed into the summary (apt install only if absent; no PPA in PR gate).
2. `make clean && make` — capture full log to `build.log`; count `warning:`
   lines into the summary (visible, non-fatal in v1, §1).
3. Assert artefacts exist: `bin/engine3d`, `include/*.mod`, `obj/*.o`.
4. Smoke: run `bin/engine3d` in a temp dir; assert exit 0 and
   `output_render.ppm` exists, is non-empty, and starts with the expected PPM
   magic (`P3`, per `renderer.f90` export). No pixel verdict here — that is §6.
5. Upload `build.log` on failure only (§8.1).

---

## 5. Compiler Tests Job

### 5.1 Contract (what CI assumes, B1/B5)

Single entry point — CI calls exactly one of, in preference order:
`make test` ▸ `tests/run_tests.sh`. It must: need no network, no display, no
writes outside a temp/build dir; finish in <2 min; print
`PASS <name>` / `FAIL <name>: <one-line reason>` per case; exit non-zero iff
any case fails. Adding a test must require no workflow edit.

### 5.2 Coverage the suite is expected to contain (owned by test plans, gated here)

| Suite | Examples | CI treatment |
|---|---|---|
| Fortran unit | `math_3d` (dot/cross/normalise, mat4 multiply/perspective/look-at), `mesh` (cube primitive counts), `camera`, `renderer` (single-triangle framebuffer/Z-buffer) | Gate |
| Compiler golden-emit (P04 pipeline, when it exists) | Fixed `.f3d` inputs → byte-compare emitted JSON/JS/Fortran against committed expected files (sorted, fixed-precision, source-hash stamped per P04) | Gate; diff uploaded on failure |
| Error UX snapshots (P08) | Invalid inputs → compare `file:line:col` + message + hint text exactly; a wording change is a deliberate snapshot update, never a silent pass | Gate |
| End-to-end | One tiny source → compile → build → render → §6 mini-golden | Gate (shares §6 comparator) |

Sharding/parallel test runners are out of scope until the suite exceeds ~2 min.

---

## 6. Golden Render Check

The highest-risk check in this spec: done naively it is either flaky
(byte-compare across compilers) or vacuous (compare against itself).

### 6.1 Golden design (B2)

- **Scene:** a dedicated, committed test scene exercising cube + rotation +
  Lambert shading (the current demo's ingredients), rendered at reduced size
  (propose 160×120; final size is B2's decision) — fast, small to store, and
  reviewable as an image. Requires the size to be parameterisable (B5); until
  then the interim golden is the full 640×480 demo, accepted as slow/large.
- **Reference:** committed under `tests/golden/` as PPM (lossless; PNG only as
  a human-viewable companion) + a `README` in that folder stating which
  compiler/OS produced it and the regeneration command. Regeneration is a
  *human, reviewed* act in its own PR with the rendered image shown — CI never
  regenerates or auto-blesses a golden.
- **Storage note:** root `output_render.ppm`/`.png` are build outputs, not
  goldens; CI must not diff against them (they are produced by the very run
  under test).

### 6.2 Comparison rule

| Cell | Rule |
|---|---|
| Canonical cell only (§4.1) | Primary: SHA-256 of the PPM **pixel payload** (header-normalised — strip comments/whitespace variance) must match the committed checksum |
| If byte equality proves brittle across patch releases of the pinned compiler | Fallback, adopted only by an explicit spec amendment: per-pixel absolute tolerance (propose ≤2/255 per channel) **and** ≥99.9% pixels within tolerance **and** zero pixels off by >16 — reported numerically in the summary either way |
| All non-canonical cells | No golden verdict. Render, record hash + differing-pixel count vs golden as *information* in nightly report |

Rationale: `-O3` floating-point contraction/reordering legitimately varies
by gfortran version and architecture; pretending otherwise manufactures
flaky red CI that trains everyone to ignore CI — the worst outcome for an
"easy" product.

### 6.3 On mismatch

Fail the job; upload an artefact bundle (§8.1): actual PPM/PNG, expected PNG,
and a visual diff image (amplified absolute difference, generated with
ImageMagick `compare` if available, else a small committed script) plus the
numeric stats (hashes, differing-pixel %, max delta). The summary links the
bundle and states the two legitimate resolutions verbatim: *fix the code*, or
*in a separate PR, regenerate the golden and show the new image*.

---

## 7. JS Size Check and Docs Lint (independent, fast, no Fortran)

### 7.1 JS size (<15 KB) — P06 contract

- **Measured file:** the shipped minified runtime only (P06: proposed
  `runtime/f3d.min.js`). Explicitly **not** `viewer.html` (16,975 B today —
  it is a demo shell containing CSS/markup; measuring it against 15 KB would
  fail for the wrong reason and teach the wrong lesson).
- **Metric:** raw bytes of the minified file, `wc -c`, limit **15,360 B
  (15 KiB)** — state the unit in the job name/summary to end KB/KiB ambiguity.
  Gzip size is *reported* alongside (target audience feels gzip on the wire)
  but is not the gate.
- **Reproducibility:** CI rebuilds the minified file from the committed source
  with the committed, pinned minifier (Node + pinned dev-dependency, lockfile
  required) and checks *both* that the committed `.min.js` matches a fresh
  build (no stale/hand-edited artefacts) and that the fresh build is < limit.
- **Reporting:** summary shows `size / limit / headroom` and the delta vs the
  base branch when computable. Crossing 90% of budget = annotation warning,
  not failure — size creep gets noticed before it gets blocked.
- **Until B3 lands:** job does not exist. A size check with nothing to measure
  must not be faked against `viewer.html` or an empty file.

### 7.2 Docs lint

- **Scope:** `README.md` + `docs/**/*.md` (this plan series included).
- **Checks, in order of value:** (1) internal link/anchor integrity —
  relative links and `P##` cross-references resolve to real files/headings;
  (2) `markdownlint` with the committed config (B4) — errors gate, style-only
  rules are configured, not argued per-PR; (3) fenced-code sanity: `yaml`/
  `bash` fences that claim to be runnable parse/lex (outline snippets like
  §3.2, explicitly marked OUTLINE, are exempt by config/comment convention);
  (4) no trailing whitespace / missing final newline (cheap, auto-fixable).
- **Not gated:** prose style, spelling dictionaries, line length in tables —
  high noise, zero defect signal for this repo's docs.
- Runs on `ubuntu-24.04` + `setup-node` with cached `node_modules`/tool
  install (§8.2); target <60 s. Failures annotate the exact file/line in the
  PR via the lint tool's GitHub formatter where supported.

---

## 8. Caching and Failure Reporting

### 8.1 Artefacts (failure-first)

| Job | On failure upload | On success | Retention |
|---|---|---|---|
| build | `build.log`, compiler version dump | nothing | 7 days |
| compiler-tests | full test log, emit-diff files | summary only | 7 days |
| golden-render | actual + expected + diff image + stats (§6.3) | summary only | 14 days (visual evidence is the valuable kind) |
| js-size / docs-lint | tool log | nothing | 7 days |

Names include job + run id (`golden-<run_id>`); `if: failure()` guards every
upload so green runs stay free and fast. Artefacts are the *only* failure
channel beyond status — no PR comments, no issues auto-filed, no external
notifications in v1.

### 8.2 Caching — deliberately minimal

| Cache | Key | Verdict |
|---|---|---|
| `obj/`, `include/` (Fortran) | **Do not cache in v1** | Build is 5 files / seconds; `.mod` files are gfortran-version-locked and a stale-cache hit produces inscrutable module-version errors — the exact failure a beginner cannot debug. Revisit only if build >60 s |
| Node tools (lint/minifier) | `actions/setup-node` cache / `actions/cache` keyed on lockfile hash | Yes — safe, content-addressed, no compiler coupling |
| `apt` packages | No cache | Runner images already carry gfortran in the expected case; caching apt state saves little and adds restore-key staleness |

General rule: no `restore-keys` prefix fallbacks on anything that can affect
a verdict (golden, emit, size). A cache miss must always be the safe path.

### 8.3 Job Summary and status reporting

Every job appends to `$GITHUB_STEP_SUMMARY`; a final `ci-summary` job
(`if: always()`, `needs:` all jobs) publishes one table:

```markdown
| Check | Result | Detail |
|---|---|---|
| Build (canonical) | ✅/❌ | gfortran <ver>, warnings: <n>, time: <s> |
| Compiler tests | ✅/❌ | <passed>/<total>, first failure: <name> |
| Golden render | ✅/❌/— | sha match / diff <x>% pixels, max Δ <n> |
| JS size | ✅/⚠️/— | <bytes> / 15360 (headroom <bytes>, gzip <bytes>) |
| Docs lint | ✅/❌ | <n> errors in <n> files |
```

Plus: step-level `::error file=…,line=…::` annotations wherever a tool gives
a location (lint, test failures with source refs); job *names* state the
contract (`js-size (<15360 B)`, `golden-render (canonical)`) so the PR checks
list is self-explanatory without opening logs. Timing per job is printed for
trend-watching but never gated. Branch protection (separate repo-settings
decision, §9) should require: canonical build, compiler-tests,
golden-render, docs-lint — with js-size required once B3 lands.

---

## 9. Rollout Order and Open Decisions

| Phase | Contents | Exit criterion |
|---|---|---|
| v0 | `ci.yml` with build + smoke only (§4.2) | Green on `main`; warning count baselined |
| v1 | + compiler-tests (B1/B5), docs-lint (B4) | `make test` exists and is meaningful, not a stub |
| v2 | + golden-render (B2/B5, §6) | Golden committed via its own reviewed PR; one deliberate-break experiment proves the job goes red with a readable diff bundle |
| v3 | + js-size (B3, §7.1); branch protection enabled | P06 runtime exists; required-checks list updated in the same PR |
| Phase 2 | `nightly.yml` full matrix (§4.1) | Only if PR-gate data shows version/OS drift is a real risk |

**Open decisions for the user/maintainer (defaults proposed):**
1. Reduced golden size and scene (propose 160×120 test scene) vs interim
   640×480 demo golden — §6.1.
2. Byte-exact-first vs tolerance-first golden comparator — propose
   byte-exact on the canonical cell, tolerance only by amendment (§6.2).
3. 15 KB = 15,360 B on `f3d.min.js` raw bytes — confirm against P06 (§7.1).
4. macOS as nightly signal-only vs dropped entirely — propose signal-only.
5. `-Werror` ratchet timing — propose after 2 weeks of green v0 warning data.
6. Branch protection + Dependabot — repo-settings changes, outside any
   workflow file; need explicit approval when v1 lands.

*End of plan — no `.github/` file, `Makefile`, or `src/` change made.*
