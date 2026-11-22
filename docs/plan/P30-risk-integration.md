# P30 — Risk Register & Integration Plan: 50-Agent Build, Continuous Parity Waves

> **Status:** Planning only — no `src/` changes in this document.
> **Expansion update (user, 2026-11-23 00:06):** Full Three.js + PixiJS parity
> is the destination; delivery is in **continuous waves**; **v1 is milestone 1,
> not the finish**. This plan therefore has **no Won't bucket** (§7): nothing
> in parity scope is discarded — it is sequenced, gated, or queued for a named
> later wave.
> **Repo baseline (verified 2026-11-23):** single commit on `main`;
> `src/math_3d.f90`, `src/mesh.f90`, `src/camera.f90`, `src/renderer.f90`,
> `src/main.f90` (hard-coded 640×480 cube demo); `Makefile`
> (`gfortran -O3 -Wall -Wextra -fcheck=all -Jinclude`, ordered
> math→mesh/camera→renderer→main, target `bin/engine3d`); checked-in
> `scene.json` (legacy v1 flat `{triangles:[{id,v,color}]}`), `model.obj`,
> `output_render.ppm` (P3, 640×480, bg `25 25 35`), `viewer.html` (Canvas 2D,
> painter's algorithm — divergent projection/camera/animation, see P06/P09/P13).
> **No** `tests/`, **no** CI, **no** parser/compiler/CLI yet. This VM has no
> local `gfortran` (P18/P19) — Fortran verdicts come from GitHub Actions CI.
> **Sibling plans served:** P01 (Three.js pain census), P02 (PixiJS 3D limits),
> P03 (DSL grammar), P04 (compiler pipeline/IR), P05 (Fortran gaps), P06 (JS
> runtime), P07 (optimization), P08 (error UX), P09–P17 (features), P18
> (testing), P19 (CI), P20 (CLI).

---

## 1. Integration success — definition

Integration succeeds only when **all** of these hold at one commit on `main`:

1. Clean `gfortran` build + smoke run (§6, Gate G1).
2. Compiler + Fortran unit + error-golden tests green (Gate G2/G5).
3. Golden render verdict green on the pinned canonical CI cell (Gate G3).
4. Fortran ↔ JS parity suite green for every feature claimed in that wave
   (Gate G4) — same scene in, same geometry/camera/motion/pixels within the
   P18 tolerances out, on both backends.
5. No unowned file conflicts, no silent golden re-bless, no feature claimed
   on the basis of a config field / stub / reserved keyword alone.
6. The wave's parity ledger (§7.2) is updated: every item is `Done-verified`,
   `In-wave`, or `Queued-wave-N` — never `Won't`.

A green build alone, a demo screenshot, or 50 agent reports are **not**
integration success.

---

## 2. Risk register (ranked)

Scoring: Likelihood × Impact, H/M/L. Owner = a *role*, assigned to a named
person/agent at wave launch; an unowned risk is an open risk.

| ID | Risk | L×I | Early signal | Mitigation (prevent) | Contingency (if it fires) |
|---|---|---|---|---|---|
| **R1** | **Grammar freeze late / never** — P03 (line-oriented, no braces), P04 (brace blocks, ~25 productions), P08 (different diagnostic codes) already disagree on surface syntax and code scheme. 50 agents build parsers, validators, emitters, fixtures against different grammars. | H×H | Agents cite different plans for the same statement; fixtures cannot be authored (P18 §9) | **Freeze before feature code (Wave 0, §5 Step 0):** one reconciled grammar + defaults table + diagnostic-code table, versioned (`grammar v1.0`), signed off in one document; all other plans marked superseded-on-conflict. Freeze date is a gate, not a target. | Stop-the-line: pause parser-adjacent work, integrator arbitrates the diff in one ruling, bump grammar version, regenerate fixtures once — do not let agents patch around divergence locally. |
| **R2** | **Fortran / JS parity divergence** — today JS rotates the *object* with ad-hoc projection (`distance=4.0`, no FOV/near/far, frame-rate-dependent `rotY += 0.015`); Fortran uses view/projection matrices, Z-buffer; JS viewer uses painter's algorithm. Parity fails structurally, not by a bug. | H×H | Same scene looks/moves differently per backend; diffs explained as "viewer quirks" | Single Typed IR (P04 §5.2, `ir_version` frozen) is the *only* input to both backends; one camera, one transform order (`T·R·S`, P03 §7), one animation clock (P09), depth-sort only as JS emit ordering (O7), never as semantics. Parity suite per feature *before* it is claimed (§6 G4). | Feature is marked `Fortran-only-unverified` in the ledger, cannot close the wave, and cannot be built on by the next wave until parity passes or the JS side is fixed. No "close enough" waiver. |
| **R3** | **Golden breakage / false goldens** — baseline captured *after* changes, from unexplained mismatch, or auto-blessed; or hash-only gate flakes across gfortran/libm versions (P18 D4, P19 §6.2). | H×H | First golden PR also changes renderer code; CI red only on one toolchain cell | **Phase 0 first:** bless `cube-default` from the *unmodified* demo, cross-checked against checked-in `output_render.ppm`, manifest records gfortran/flags/hash (P18 §6.1/§6.4). Two-tier verdict: SHA-256 exact on pinned canonical cell, PSNR ≥60 dB / ≤0.1% pixels / ≤±2 portable elsewhere. Re-bless is a separate human PR with image + `why`. | Quarantine the case, render diff bundle (actual/expected/diff PPM + stats) uploaded as CI artefact; decide *code bug vs intentional pixel change* in review — never re-bless inside the failing PR to make it green. |
| **R4** | **Merge conflicts / concurrent-edit collisions** — 50 agents, tiny tree: `mesh.f90`, `renderer.f90`, `main.f90`, `Makefile`, `scene.json`/`viewer.html` are shared hotspots; Fortran `.mod` ordering makes textual merges semantically fragile. | H×H | Two agents report editing the same file; long-lived branches; `git status` dirt from another seat | File-ownership matrix (§4) — one owner per file per wave, others propose patches to the owner; small batches (≤10 agents, report actual vs ordered at each batch close), short-lived branches, daily integrator rebase, generated files (`obj/`, `include/*.mod`, root renders) never committed by agents. `Makefile` and module-interface changes are integrator-only. | Integrator resolves in a dedicated merge commit (never force-push over an agent branch), re-runs G1–G3 on the *merge result* — both parents green proves nothing about the merge. |
| **R5** | **Scope creep (classic)** — v1 grammar quietly grows variables/loops/textures/PBR/physics that P03 §11 deferred; each addition invalidates fixtures, defaults, and error catalogue. | H×M | A PR adds a keyword not in the frozen grammar; "just one extra property" | Frozen grammar + reserved-keyword rule: reserved words lex and error `not supported yet`, never silently substitute/fake (P03 §8, e.g. no cube for `sphere`). New scope enters only via the wave queue (§7), with its own parity + golden + error fixtures budgeted. | Remove the unplanned surface from the wave branch into a queued-wave branch/proposal; do not expand the current wave's exit criteria mid-wave. |
| **R6** | **Parity scope growth (expansion risk)** — "full Three.js + PixiJS parity" is unbounded if read as *every API either library ever shipped*; the programme never finishes and v1 stalls waiting for total parity. | H×H | Parity list grows faster than it closes; agents argue parity from blog posts / memory of APIs | Parity is a **finite, enumerated ledger**, derived only from P01's counted task census + P02's limits table + the feature plans P09–P17 — each row: capability, Three.js/PixiJS reference task, our DSL surface, Fortran behaviour, JS behaviour, test. New rows enter the ledger by integrator ruling with a wave assignment (§7), not by agent discovery mid-wave. "Full parity" = every *ledger row* verified, not every conceivable API. | Split the row: ship the verified core in its wave, queue the remainder as a new explicit row in a later wave. Never redefine a row's acceptance test to be smaller so it can close. |
| **R7** | **Wave-gating failure** — Wave N+1 feature work starts on an unverified Wave N base (the standing failure mode: building on a config field, not a proven path). Errors compound and no commit is known-good. | M×H | Next wave launches while parity/golden jobs are red or unrun; "we'll fix parity later" | Hard gate (§3): a wave may not start — except fix-only work — until the previous wave's G1–G5 are green *at the integration commit* and recorded. Integrator publishes the gate verdict per wave; the verdict, not agent self-report, opens the next wave. | Freeze new-wave work, revert to last gate-green commit as the integration base (§8), and run a fix-only wave until gates pass. |
| **R8** | **No-Won't-bucket decay** — deferred items silently become dropped items: no owner, no wave, no test — indistinguishable from Won't within two waves. | M×H | Ledger rows with status `later` / `TBD` / no wave number | §7 rules: every deferred row must carry `Queued-wave-N`, an owner role, an entry trigger, and the parity test it will have to pass. A row may close without implementation only as a *duplicate* or *invalid* (with the duplicate/invalid evidence linked) — never as Won't / out-of-scope. Periodic ledger audit each wave close: count rows by status; any unassigned row blocks wave close. | Ledger audit becomes a wave-close blocker; orphan rows are assigned a wave and owner before any new scope is admitted. |
| **R9** | **Plan divergence beyond grammar** — IR schema, JSON dialect (v1 legacy vs v2), error codes, test location (P04 `tools/f3dc/tests/` vs P18 root `tests/`) drift per emitter/agent. | H×M | Two emitters emit different v2 JSON; a code exists with no fixture | Single owners for: IR schema (freeze at `ir_version: 1` in Wave 0/1), diagnostic catalogue, defaults table. Mechanical CI check (P18 §8): every `E`/`W` code in source has a fixture; every public Fortran procedure appears in its test program. | Schema/code bump is a versioned, all-emitters-at-once change in one PR; partial bumps are reverted. |
| **R10** | **Hotspot architecture** — new modules (material, scene, obj_loader…) each need `Makefile` rule + link order + `.mod` dependency; agents invent workarounds or edit `renderer.f90` constants in place. | M×H | PRs touch `Makefile` independently; shading constants edited per-feature | P05 disjoint-ownership interfaces agreed in Wave 0; new-module proposals go to integrator with dependency order stated; renderer changes are single-owner, sequential, never parallel. | Integrator extracts the tangled change into its own sequential PR and re-gates. |
| **R11** | **Optimizer changes pixels** — O4 backface pre-cull, O2 dedup, O6 transform bake (P04 §4.4 / P07) silently alter the render; O4 is sound only for static, closed, single-camera scenes. | M×H | Golden diff only when `--optimize` on; animation scenes cull wrongly | Pass-by-pass tests (P18 §5.4), idempotence test, O4 disabled when any animation flag is set (negative test mandatory), `--no-optimize` render as the reference in parity checks. | Disable the offending pass by default (keep the code, gate the pass), restore golden, re-enable only with its equivalence test green. |
| **R12** | **Error-UX regression** — wording/span/hint changes silently; Fortran tracebacks (`STOP`, `Backtrace`) leak to beginners (P08). | M×M | Snapshot diffs bundled into feature PRs unread | Error messages are verbatim goldens (P18 §7): full stderr + exit code + "no output file created"; a wording change is a deliberate, reviewed diff in its own commit. Banned-string lint (`token`, `AST`, `framebuffer`, Fortran artefacts). | Revert the wording change separately from the feature; re-run error goldens. |
| **R13** | **Verification illusion at scale** — 50 agents report "done"; counts, CI runs, or renders that never happened get summarised as fact; local agents cannot run `gfortran` so "it builds" is asserted, not shown. | M×H | Reports without commit SHAs / CI run links / artefact names | Every claim in an agent report must cite: commit SHA, CI run, gate ID (§6), and artefact. Integrator spot-checks the live artefact (file, Release/PR list, rendered image) before recording a pass. Report actual agents/runs at each batch close against the ordered number. No success verdict from an absent marker. | Claim is downgraded to `unverified` in the ledger; wave gate stays closed until independently reproduced in CI. |
| **R14** | **Environment / FP non-determinism** — `-O3` contraction, libm differences, ImageMagick absence, dict-order in emitters produce irreproducible outputs. | M×M | Same input, different hash across runs/machines | Determinism suite (build twice → sha256 identical, P18 §5.5); canonical sorted/fixed-precision emit (P04); no test depends on ImageMagick, network, wall-clock, or dict order; pinned canonical CI cell owns golden verdicts, other cells are signal-only (P19 §4.1). | Fall back to the P18 portable gate for diagnosis; fix the non-determinism — do not widen tolerances to hide it without a spec amendment. |
| **R15** | **Root-artifact destruction** — tests/agents overwrite checked-in `scene.json`, `model.obj`, `output_render.ppm`, `viewer.html` (fixtures and the legacy-compat path). | M×M | `git status` shows root artefacts modified by a test run | All test/agent runs in per-test temp dirs (P18 D8); default compiler output to `build/`, never repo root (P04 §10); root artefacts are read-only fixtures during the build. | Restore from git, move the offending run to a temp dir, re-run legacy-compat gate G4/G2 before proceeding. |

---

## 3. Wave model & wave gating (expansion)

v1 is **Milestone 1**. After it, waves continue until the parity ledger (§7.2)
is fully `Done-verified`. There is no final "done" declaration at v1.

| Wave | Content (illustrative allocation — integrator fixes at launch) | Exit = next wave may start |
|---|---|---|
| **Wave 0 — Freeze & baseline** | Reconciled grammar/defaults/diagnostic freeze (R1/R9); file-ownership matrix; `cube-default` golden blessed from unmodified engine (R3); CI v0 build+smoke (P19). | Freeze document merged; baseline manifest committed; G1 green in CI. |
| **Wave 1 — v1 = Milestone 1** | P04 pipeline a–f: lexer/parser → validate/IR → JSON+compat → optimize → Fortran emit + driver → JS/HTML emit; P18 test layers land *with* each phase; 3-line contract (`cube red / spin it / render`, P03) end-to-end. | **All G1–G5 green at integration commit**, incl. Fortran↔JS parity for every v1 feature and the legacy `scene.json` path. |
| **Wave 2+ — Parity waves** | Ledger rows grouped by dependency, e.g. primitives (P11) → materials/lighting (P10) → scene graph (P12) → animation (P09) → loaders (P15) → instancing (P16) → render targets (P17) → camera/input parity (P13) → textures/UV (P14). Order is integrator's, dependency-driven. | Per wave: its rows move to `Done-verified` with G4 parity tests green; no row silently dropped (R8 audit). |
| **Wave N — Parity complete** | Every ledger row `Done-verified`; full-census re-run of P01 tasks in `.f3d` vs Three.js/PixiJS reference counts. | Ledger audit: zero `Queued`, zero unassigned, zero `unverified`. Only then is "full parity" claimed. |

**Gate rules (non-negotiable):**

1. A wave starts only on the previous wave's gate-green integration commit.
2. While a gate is red, work is **fix-only** against that gate — no new-wave
   features, no scope additions, no golden re-bless to force green.
3. Parity tests for a feature are written in the *same* wave as the feature;
   a feature without a G4 parity test cannot close, and blocks the next wave.
4. Gate verdicts are published per wave (commit SHA, CI run, G1–G5 results,
   ledger delta) — the moment they are checked, pass or fail.
5. Continuous waves means *no dead time, not no gate*: the next wave's board
   (rows, owners, tests) is prepared while the current wave runs, but its
   code does not merge until the gate opens.

---

## 4. Ownership & merge protocol (50 agents)

- **Batches:** ≤10 agents per batch, integrator-coordinated; report actual
  agents run vs ordered at each batch close.
- **One owner per file per wave.** Indicative hotspots: `Makefile` +
  module interfaces — integrator only; `renderer.f90` — single runtime owner;
  `mesh.f90` — single mesh owner; compiler stages (`lexer/parser/validate/
  optimize/emit_*`) — one owner per stage, emitters never import parser/AST
  (P04 §9 layering); `viewer.html`/JS runtime — JS owner, who also owns G4
  parity fixtures with the Fortran owner.
- **Shared contracts, not shared files:** grammar, IR schema, defaults,
  diagnostic catalogue are edited only by their single owner, by versioned
  change, announced to all batches before code moves.
- **Branches:** short-lived, one topic, rebased daily onto integration;
  integration merges are small and sequential — no 50-agent big-bang merge.
- **Every merge** re-runs G1–G3 (and G4 if it touches a parity surface) on
  the merge result before the next merge lands.

---

## 5. Integration steps (per wave, in order)

0. **Freeze check** — confirm grammar/IR/code-catalogue versions the wave
   builds against; if a freeze is missing or stale, that is the wave's
   first task, not background work.
1. **Board** — ledger rows for the wave, file owners, tests named per row,
   rollback point tagged (`pre-wave-N`, §8).
2. **Baseline** — confirm goldens valid at the starting commit (G3 green
   before any change; a red start is reported, not inherited silently).
3. **Build in dependency order** — Fortran modules in `Makefile` order
   (math→mesh/camera→renderer→driver), compiler stages in pipeline order
   (lex→parse→validate→optimize→emit), JS runtime last against frozen IR.
4. **Integrate continuously** — merge per §4 as batches close; integrator
   resolves conflicts, never the second agent by force-push.
5. **Gate** — run §6 G1–G6 at the integration commit in CI; publish verdict.
6. **Ledger & close** — update parity ledger, risk register (new risks,
   fired risks, mitigations that failed), and manifest; audit for
   unassigned/`Won't` rows (R8).
7. **Open next wave** — only on a green gate (§3); carry queued rows forward
   explicitly by number.

---

## 6. Verification gates

| Gate | Check | Command / source | Pass criterion |
|---|---|---|---|
| **G0 Baseline integrity** | Unmodified-demo golden exists and cross-checks | P18 §6.1: fresh run vs checked-in `output_render.ppm` | Hash match explained & blessed, or discrepancy investigated before any code lands |
| **G1 gfortran build** | Clean build + smoke | CI: `make clean && make`; run `bin/engine3d` in temp dir (P19 §4.2) | Exit 0; `bin/engine3d`, `obj/*.o`, `include/*.mod` exist; PPM starts `P3`, non-empty; warning count recorded (fatal only after the P19 `-Werror` ratchet is adopted) |
| **G2 Compiler + unit tests** | Compiler unit (lexer/parser/desugar/validate/optimize/emitters, IR round-trip, determinism) + Fortran unit (math/mesh/camera/renderer/PPM, `-fcheck=all`) | `make test` / `make test-compiler test-fortran` (P18 §8; targets land with Wave 1) | All green in CI within P18 budgets; locally, gfortran-dependent layers report `SKIP — gfortran not found`, never a silent pass |
| **G3 Golden render** | `cube-default` (640×480) + per-feature cases at 160×120 (P18 §6.3) | `make test-golden`; `tests/golden/check_image.py` per manifest row | Canonical cell: SHA-256 of canonical pixel stream exact; portable: PSNR ≥60 dB, ≤0.1% pixels differ, max Δ ≤2; diff bundle uploaded on failure |
| **G4 Fortran ↔ JS parity** | Same IR/scene rendered both backends: geometry counts, camera, transform order, animation frame-at-t, colours/lighting | Parity suite per ledger row (extends P18 §5.5/P06/P09/P13 tests); JS depth-sorted emit vs Fortran Z-buffer compared on pixels, not implementation | Per row: triangle multiset equal, frame pixels within G3 portable tolerances, motion at sampled times equal within P18 math tolerances (`1e-6` composed). A row without this test is not `Done-verified` |
| **G5 Error goldens** | Every diagnostic code: verbatim stderr, exit code, no partial output, no Fortran artefacts | `make test-errors` (P18 §7) | Byte-for-byte after only the specified path normalisation; every code in source has a fixture (mechanical check) |
| **G6 Docs / JS size / CI hygiene** | Docs links/lint; JS runtime size; no generated artefacts committed | P19 §7: docs-lint on `README.md`+`docs/**`; minified JS <15,360 B raw (once the P06 artefact exists — absent, not faked, until then) | Lint green; size reported with headroom; `git status` clean of `obj/`, `.mod`, stray renders |

Gate failure handling: first failure stops promotion (not investigation);
the failing gate's artefact bundle is the discussion object; fixes land,
**all** gates re-run at the new integration commit — a gate is not
"previously passed" across commits.

---

## 7. No-Won't-bucket & parity-ledger rules (expansion)

### 7.1 Rules

1. **There is no Won't / Out-of-scope status.** Statuses are only:
   `Done-verified`, `In-wave-N`, `Queued-wave-N`, `Blocked-by-<risk/row>`.
2. Every `Queued` row carries: owner role, wave number, entry trigger, and
   the G4 parity test + golden/error fixtures it will need.
3. A row leaves the ledger without implementation only as **duplicate**
   (link to surviving row) or **invalid** (evidence the capability does not
   exist in either reference library) — both integrator-ruled, in writing.
4. Deferral is a *sequencing* decision, restated at every wave close; a row
   deferred twice in a row gets an explicit user-visible note in the wave
   report, so deferral cannot become silent dropping.
5. v1's deferred list (P03 §11: variables, loops, grouping, textures,
   multi-light, keyframes, OBJ-as-statement, MP4/GIF…) is the initial
   Wave 2+ queue — each item already has a home plan (P09–P17) and enters
   the ledger from there, not from memory.

### 7.2 Ledger shape

```markdown
| Row | Capability | Reference (P01 task / P02 limit) | DSL | Fortran | JS | Parity test | Status |
|-----|-----------|-----------------------------------|-----|---------|----|-------------|--------|
| PAR-001 | Rotating cube, one camera, one light | P01 hello-cube | `cube/spin/render` | render_mesh + Z-buffer | runtime + painter/depth-sort | G4 cube frame-at-t | Done-verified (Wave 1) |
| … | … | … | … | … | … | … | Queued-wave-N |
```

The ledger lives with the plan set and is updated in the same PR that
claims the row — a merged feature with an un-updated ledger is incomplete.

---

## 8. Rollback

| Level | Trigger | Action |
|---|---|---|
| **Single merge** | G1–G5 red at merge result and not fixed same session | `git revert` the merge (not reset/force-push); re-run gates to confirm green; the work returns as a corrected branch. |
| **Feature / pass** | One feature or optimizer pass breaks golden/parity | Gate it off by default (pass disabled, keyword returns to `not supported yet`, JS feature hidden) rather than reverting the whole wave; fix forward in a fix-only branch. |
| **Golden** | Intentional pixel change | Never roll the *code* back via the golden: re-bless only by the P18 §6.4 separate-PR protocol; if the change was unintentional, revert code, baseline untouched. |
| **Wave** | Gate cannot go green without destabilising prior waves | Roll integration back to the `pre-wave-N` tag / last gate-green commit (tagged at every wave close); the wave restarts from that base with a reduced row set — removed rows become `Queued-wave-N+1`, **not** Won't (§7). |
| **Schema / grammar** | Frozen IR/grammar version proves unworkable | Version bump (`ir_version` / grammar version) with all emitters + fixtures migrated in one PR; if migration fails, revert to the prior version wholesale — no mixed-version tree on `main`. |
| **Artefacts** | Root fixtures overwritten / generated files committed | Restore checked-in artefacts from git, purge generated files from the commit, re-run G0/G4 legacy-compat before resuming. |

Rollback is rehearsed once in Wave 1 (deliberate-break experiment, as in
P19 §9 v2 for the golden job): revert a test merge, prove gates return to
green, record the time it took. An unrehearsed rollback is a hope, not a plan.

---

## 9. Top-5 watchlist for the integrator (daily)

1. **R1 freeze** — is there exactly one grammar/IR/code version in force today?
2. **R4 collisions** — which hotspot files have more than one active editor?
3. **R3/G3 golden** — green at the *current* integration commit, or inherited?
4. **R6/R8 ledger** — rows added, rows closed-verified, rows orphaned — counts, not vibes.
5. **R7 gate discipline** — is any next-wave code being written against an un-gated base?

*End of plan — only this file written; no `src/`, `Makefile`, CI, or test file created or changed.*
