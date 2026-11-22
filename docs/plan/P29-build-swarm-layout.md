# P29 — Build Swarm Layout: Exact File List, One Owner per File, Build Order

> Planning only, 2026-11-23. Repo: `~/workspace/fortran-3d-engine`
> Inputs: P01–P20 (esp. P03 grammar, P04 pipeline, P05 Fortran gaps, P06 JS runtime,
> P11 primitives, P14 textures, P15 loaders, P16 instancing, P17 targets, P18 tests,
> P19 CI, P20 CLI) + **expansion order 2026-11-23 00:06: full Three.js + PixiJS
> parity, continuous waves until the parity matrix is 100% implemented + tested.**
> Ground truth today: `src/{math_3d,mesh,camera,renderer,main}.f90`, `Makefile`,
> `README.md`, `viewer.html`, root `scene.json`/`model.obj`/`output_render.*`
> (generated artefacts, **not** seat files — nobody hand-edits them).

## 0. Hard rules for the whole swarm (v1 and every parity wave)

1. **One file = one seat = one owner, forever.** A seat edits exactly its one
   file. Nobody else edits it — not the integrator, not a later wave. A needed
   change in another seat's file is an API request to that owner, who makes it
   as a follow-on task in their own seat.
2. **Disjoint by construction:** no two rows in §2/§6 name the same path.
   Generated files (`runtime/f3d.min.js`, root `scene.json`/`model.obj`/PPMs,
   `build/*`) have **no** seat; they are outputs of the owning source seat's
   build rule (min.js ← B28 via B47's Makefile rule).
3. **Compiler is Python 3 stdlib only** (`tools/f3dc/*.py`): no pip, no
   third-party imports; CI (B48/B91) greps imports against a stdlib whitelist.
   Rendering stays Fortran; viewing stays dependency-free JS.
4. **Extension hooks are a v1 deliverable**, because parity waves may not edit
   v1 files: B08 `ir_nodes.py` exposes an extension-field dict on `IRScene`/
   `IRObject`; B10 `optimize.py`, B09 `validate.py`, B14/B15 emitters expose a
   registry (`register_pass/register_keyword/register_emitter_hook`) that
   parity `ext_*.py` files plug into. Without these hooks, §6 is impossible
   under rule 1 — they are Phase-0 acceptance criteria, not polish.
5. **Deviations from earlier plans, decided here:** (a) P04's `f3dc_pkg/`
   package is **flattened** to `tools/f3dc/*.py` (shim imports siblings);
   (b) P05's OBJ-import-inside-`mesh.f90` is **superseded** by a separate
   `src/obj_loader.f90` (B26) so geometry and parsing stay disjoint;
   (c) P18's many small test files are **consolidated** to the 12 test seats
   in §2 for v1 (parity waves re-split per wave, §6); fixture *data* files
   under a test seat's directory belong to that seat, not to new seats.

## 1. v1 layout at a glance

```
tools/f3dc/*.py (18, B01–B18)   src/*.f90 (9, B19–B27)      runtime/ + viewer (3, B28–B30)
tests/ (12, B31–B42)            examples/*.f3d (4, B43–B46)  Makefile/CI/docs (4, B47–B50)
                                                          = 50 seats, 50 files, 0 overlaps
```

## 2. The 50 v1 seats (B01–B50) — exact file list

Dep = seats that must be merged/green before this seat can finish (it may
start against the frozen Phase-0 contracts, §3).

### Compiler — `tools/f3dc/*.py`, stdlib only (B01–B18)

| Seat | File (only file owned) | Contents / sole responsibility | Dep |
|---|---|---|---|
| B01 | `tools/f3dc/f3dc.py` | Executable shim: `#!/usr/bin/env python3`, path fix, delegates to `cli.main` | B17 |
| B02 | `tools/f3dc/errors.py` | `Span`, `Diagnostic`, `ErrorBag`, E/W code table (P04 §7, P08) | — |
| B03 | `tools/f3dc/lexer.py` | Tokeniser for P03 grammar; `#`/`//` comments | B02 |
| B04 | `tools/f3dc/ast_nodes.py` | AST dataclasses (P04 §5.1), span on every node | B02 |
| B05 | `tools/f3dc/parser.py` | Tokens→AST, error recovery (cap 10 syntax errors) | B03,B04 |
| B06 | `tools/f3dc/compat.py` | Legacy `scene.json` v1 + `.obj` → synthetic AST (only AST producer besides B05) | B04 |
| B07 | `tools/f3dc/desugar.py` | Defaults injection, `repeat`/`group` expansion (P03 §6, P12, P16) | B04 |
| B08 | `tools/f3dc/ir_nodes.py` | Frozen Typed IR, `ir_version: 1`, IR↔JSON, **extension hooks (rule 4)** | B02 |
| B09 | `tools/f3dc/validate.py` | AST′→IR, semantic/range checks E3xx/E4xx; texture syntax reserved→diagnostic (P14 §8) | B07,B08 |
| B10 | `tools/f3dc/optimize.py` | Passes O1–O7 (P04 §4.4/P07) + pass registry (rule 4) | B08 |
| B11 | `tools/f3dc/emit_common.py` | Number formatting, header stamp w/ source hash, palette helpers | B08 |
| B12 | `tools/f3dc/emit_fortran.py` | IR→generated `*_scene.f90` (mirrors `main.f90` steps, multi-object) | B08,B11 |
| B13 | `tools/f3dc/emit_json.py` | `scene.json` v2 + legacy v1 emit | B08,B11 |
| B14 | `tools/f3dc/emit_js.py` | `scene.js` emit for the runtime contract (P06 §4) | B08,B11 |
| B15 | `tools/f3dc/emit_html.py` | Standalone `.html` emit (inlines B18 template + B14 output) | B11,B14,B18 |
| B16 | `tools/f3dc/driver.py` | `gfortran`/`make` invocation for `build`/`run`, exit code 4 on failure | B12 |
| B17 | `tools/f3dc/cli.py` | `argparse`: `check/build/run/new`, `--emit tokens\|ast\|ir\|opt-ir`, exit codes 0–4 (P20) | B02–B16 |
| B18 | `tools/f3dc/viewer_template.html` | The HTML template B15 inlines (no JS runtime logic — that is B28) | B28 |

### Fortran — `src/*.f90` (B19–B27; 5 existing extended, 4 new)

| Seat | File | Contents / sole responsibility | Dep |
|---|---|---|---|
| B19 | `src/math_3d.f90` *(exists)* | `math_3d` + P05 §4.1: TRS compose, axis-angle, `deg2rad`, transpose/inverse-rigid, `lerp/reflect/neg` | — |
| B20 | `src/mesh.f90` *(exists)* | `mesh_3d`: builder/`free_mesh`, `material_id` on `Triangle`, all P11 primitives (plane, pyramid, sphere, cylinder, cone, torus-stretch); **no** OBJ parsing (B26) | B19 |
| B21 | `src/camera.f90` *(exists)* | `camera_3d` + validation/`camera_init_checked`, `camera_set_aspect` (P05 §4.3) | B19 |
| B22 | `src/material.f90` *(new)* | `material_3d`: `Material`, presets/validation (P05 §3, P10 flat/Lambert slice) | B19 |
| B23 | `src/scene.f90` *(new)* | `scene_3d`: `.scene` reader, `Scene/SceneObject`, name→material resolution, primitive dispatch (P05 §3) | B19,B20,B21,B22 |
| B24 | `src/renderer.f90` *(exists)* | `renderer_3d`: material-aware shading (`render_mesh_mat`, old signature kept as wrapper), rasteriser, PPM | B19,B20,B21,B22 |
| B25 | `src/main.f90` *(exists)* | `program main`: CLI arg = scene path, object loop, exit codes; no-arg run = today's cube byte-for-byte | B23,B24 |
| B26 | `src/obj_loader.f90` *(new)* | OBJ import only (P15 v1 subset: `v`/`f`, fan triangulation, no negative indices) → `Mesh` | B19,B20 |
| B27 | `src/animation.f90` *(new)* | `animation_3d`: timeline/easing evaluation (P09 v1: spin/TRS tracks) used by B25's frame loop | B19 |

### Runtime JS (B28–B30)

| Seat | File | Contents / sole responsibility | Dep |
|---|---|---|---|
| B28 | `runtime/f3d.js` | Readable WebGL runtime + Canvas2D fallback, orbit, `<f3d-view>` (P06; <15 KB minified budget) | B13 (v2 format) |
| B29 | `runtime/f3d.d.ts` | Hand-written types for B28's public API only | B28 |
| B30 | `viewer.html` *(exists)* | Legacy viewer: kept working on legacy v1 `scene.json`; migration source for B18 — no new features | B13 |

### Tests (B31–B42, per P18 consolidated)

| Seat | File | Guards | Dep |
|---|---|---|---|
| B31 | `tests/run_tests.py` | Stdlib orchestrator for all layers; loud SKIP without `gfortran` | B32–B42 |
| B32 | `tests/compiler/test_lexer.py` | Lexer vs P03 lexical rules | B03 |
| B33 | `tests/compiler/test_parser.py` | Parser + desugar defaults (P03 §6 table) | B05,B07 |
| B34 | `tests/compiler/test_validate.py` | One method per E3xx/E4xx code | B09 |
| B35 | `tests/compiler/test_optimize.py` | One class per pass O1–O7 | B10 |
| B36 | `tests/compiler/test_emit.py` | All 4 emitters: goldens, IR round-trip, determinism (build twice→sha256) | B12–B15 |
| B37 | `tests/compiler/test_errors.py` | Error goldens + did-you-mean corpus (P08) | B02,B17 |
| B38 | `tests/fortran/assert_utils.f90` | `test_assert` module: all Fortran test programs link it | — |
| B39 | `tests/fortran/test_math_mesh.f90` | `math_3d`+`mesh_3d` coverage table (P18 §4.2), primitive tri counts/normals/volume | B19,B20,B38 |
| B40 | `tests/fortran/test_camera_renderer.f90` | `camera_3d`+`renderer_3d`+PPM I/O (P18 §4.2) | B21,B24,B38 |
| B41 | `tests/golden/check_image.py` | Stdlib P3 parser, hash/PSNR verdicts, golden manifest handling | B24 |
| B42 | `tests/e2e/test_cli.py` | Subprocess `new/check/build/run`, exit codes 0–4, legacy-compat case | B17,B28 |

### Examples, build, docs, CI (B43–B50)

| Seat | File | Contents | Dep |
|---|---|---|---|
| B43 | `examples/hello-cube.f3d` | The 3-line contract scene (P03 §9.2); first Phase-0 contract fixture | B08 |
| B44 | `examples/multi-object.f3d` | Groups/`repeat`/instancing, ≥3 primitives, named materials | B09,B20 |
| B45 | `examples/animated.f3d` | P09 v1 timeline: spin + duration/fps/frames | B09,B27 |
| B46 | `examples/materials.f3d` | Every B22 preset, two lights-worth of Lambert contrast (v1: one dir light) | B09,B22 |
| B47 | `Makefile` *(exists)* | New module/test/f3dc/minify rules, link order `math→material→mesh→camera→obj_loader→animation→scene→renderer→main`; **integration seat: build only, no source** | All B19–B27,B31 |
| B48 | `.github/workflows/ci.yml` | P19 v1: build-canonical + compiler tests + golden + JS size + docs lint | B31,B41,B47 |
| B49 | `docs/manual.md` | User manual: DSL reference, CLI, error-code index (single doc seat in v1) | B17,B43–B46 |
| B50 | `README.md` *(exists)* | Quick-start rewrite to `f3dc run examples/hello-cube.f3d`; structure tree | B47,B49 |

## 3. Build order — phases and gates

| Phase | Seats (parallel inside phase) | Gate to exit phase |
|---|---|---|
| **0 Contracts freeze** | B02, B08, B19, B38, B43 | IR JSON of B43 hand-checked; error-code table, Fortran module APIs, assert API signed off in-file. No other seat codes against unfrozen contracts. |
| **1 Compiler front end** | B03+B04 → B05, B06, B07 → B09 | `f3dc check` logic exists in library form; B32–B34 green. |
| **1′ Fortran core** (parallel with 1) | B20, B21, B22 → B26, B27 | Existing demo still builds/renders unchanged; B39/B40 green for B19–B22 parts. |
| **2 Optimise + emit** | B10, B11 → B12, B13, B14 → B18, B15 | B35/B36 green; emitted Fortran passes `gfortran -fsyntax-only`. |
| **3 Fortran back end** | B23 → B24 → B25 | Scene-mode render of B44/B46 matches Fortran-direct render; no-arg regression byte-identical. |
| **4 CLI + runtime** | B16 → B17; B28 → B29, B30 | B42 green; B28 loads v1 **and** v2 scenes; minified size <15 KB. |
| **5 Examples + tests fill-out** | B44, B45, B46, B31, B37, B41 (+ B32–B40 completion) | `tests/run_tests.py` all-green (or loud SKIP only for absent gfortran). |
| **6 Integration** | B47 → B49, B50 → B48 **last** | Clean-checkout `make && make test && f3dc run examples/hello-cube.f3d`; CI green on canonical cell (P19). B48 merges only after everything it checks exists — no placeholder jobs (P19 §2). |

Critical path: `B08 → B09 → B13 → B28 → B42 → B47 → B48` and
`B19 → B20 → B23 → B24 → B25 → B47` — these two chains set the swarm's length;
all other seats are slack and must not block them.

## 4. Dependency rules between seats

- **Imports encode deps:** Fortran `use` order = §2 Dep column (no cycles;
  `renderer` never `use`s `scene_3d` — B23/B25 loop objects per P05 §4.4).
  Python: emitters import only B08/B11 (+registries); front end never imports
  emitters; B06 produces AST only.
- **Contract change protocol:** changing a frozen Phase-0 contract (IR field,
  error code, module API, scene-JSON shape) requires the owning seat to notify
  every seat in its reverse-Dep list (derivable from §2/§6) and re-freeze
  before dependents continue. Silent contract drift = failed seat.
- **Tests land with the seat, not after:** a seat is "done" only when its
  §2 test seat's corresponding cases pass; test seats write cases against the
  contract during the same phase, not in Phase 5 (Phase 5 is fill-out only).

## 5. Explicitly NOT v1 (reserved, diagnosed, or deferred)

Textures beyond reserved syntax (P14), glTF (P15), PNG/multi-target (P17),
keyframes beyond TRS tracks (P09), point/spot lights, shadows, PBR — all are
parity-wave scope (§6). In v1, B09 must reject them with a named diagnostic
("in the language, not built yet", P03 §9.6 style), never silently ignore.

---

## 6. EXPANSION — Parity waves beyond B50 (continuous until 100%)

**Backlog source of truth:** B85's machine-readable parity matrix, built from
P01 (Three.js) + P02 (PixiJS) feature censuses. A matrix row counts as done
**only** with: implementation file + test in that wave's test seat + example
or doc mention. Waves repeat the A→D pattern below, minting fresh seat IDs
(B93, B94, …) per uncovered row cluster, **until B86 reports 100%
implemented + tested** — no wave may declare parity by assertion.

**Parity mechanics under rule 1:** compiler features arrive as new
`tools/f3dc/ext_*.py` plug-ins via B08/B09/B10 registries (rule 4); JS
features as new `runtime/f3d-*.js` add-ons registering on `window.F3D`
(B28's API is frozen); Fortran features as new `src/*.f90` modules. Where a
parity feature unavoidably needs a call-site inside a v1 file (e.g. B24
renderer invoking shadows), that edit is a **follow-on task for the original
v1 owner seat**, queued by the parity seat as an API request — the parity
seat never touches the v1 file.

### Wave A — Lighting, materials, environment (B51–B62)

| Seat | File | Scope | Dep |
|---|---|---|---|
| B51 | `src/texture.f90` | `texture_3d`: UVs, image store, nearest/bilinear sampling (P14 v2) | B19,B20 |
| B52 | `src/lighting.f90` | `lighting_3d`: point + **spot lights**, attenuation; dir light migrates here as data | B19,B22 |
| B53 | `src/shadow.f90` | Shadow-map target, depth render, PCF sampling (Three `ShadowMap` parity) | B24,B52 |
| B54 | `src/fog.f90` | Linear/exp² **fog** (Fortran shading + emitted scene params) | B24 |
| B55 | `src/tonemapping.f90` | **Tone mapping** (ACES/Reinhard/none) + output colour-space conversion | B24 |
| B56 | `src/material_pbr.f90` | **PBR/Standard material**: metalness/roughness shading (Three `MeshStandardMaterial`, Pixi-mesh parity) | B22,B51,B52 |
| B57 | `tools/f3dc/ext_materials.py` | PBR + texture DSL/IR/emit plug-in | B08–B11 hooks |
| B58 | `tools/f3dc/ext_lights_env.py` | Spot/point/fog/tone-mapping DSL/IR/emit plug-in | B08–B11 hooks |
| B59 | `runtime/f3d-pbr.js` | PBR + textures in WebGL runtime | B28,B57 |
| B60 | `runtime/f3d-env.js` | Spot/point, shadows, fog, tone mapping in WebGL runtime | B28,B53,B58 |
| B61 | `tests/parity/test_wave_a.py` | Shadows/textures/PBR/fog/spot/tone-map goldens + unit cases | B51–B60 |
| B62 | `examples/lighting-showcase.f3d` | One scene exercising every Wave-A row | B57,B58 |

### Wave B — Assets, picking, 2D-in-3D, particles (B63–B74)

| Seat | File | Scope | Dep |
|---|---|---|---|
| B63 | `tools/f3dc/ext_gltf.py` | **glTF/GLB import** → AST/IR (P15 v2; stdlib `json`/`struct` only) | B06,B08 |
| B64 | `src/gltf_loader.f90` | Fortran-side glTF-converted mesh/animation ingest (via B63's intermediate) | B20,B27,B63 |
| B65 | `src/raycast.f90` | **Raycasting**: ray type, tri/mesh intersection, picking for native side | B19,B20 |
| B66 | `runtime/f3d-raycast.js` | Raycaster + pointer picking (Three `Raycaster` parity) | B28,B65 |
| B67 | `src/sprite.f90` | **Sprites**/billboards: always-face-camera quads in the Fortran renderer data path | B20,B51 |
| B68 | `src/text_render.f90` | **Text**: built-in bitmap font, text quads/sprites (Pixi `Text` analogue, 3D-side) | B51,B67 |
| B69 | `runtime/f3d-sprites-text.js` | Sprites + text in JS runtime (canvas-font atlas) | B28,B67,B68 |
| B70 | `tools/f3dc/ext_sprites_text.py` | `sprite`/`text` DSL/IR/emit plug-in | B08 hooks,B67,B68 |
| B71 | `src/particles.f90` | **Particles**: point-sprite emitter simulation, fixed-step (Three `Points`/Pixi particles parity) | B19,B67 |
| B72 | `runtime/f3d-particles.js` | Particle system in JS runtime | B28,B71 |
| B73 | `tools/f3dc/ext_particles.py` | Particle-emitter DSL/IR/emit plug-in | B08 hooks,B71 |
| B74 | `tests/parity/test_wave_b.py` | glTF/raycast/sprite/text/particle cases | B63–B73 |

### Wave C — Post, cameras, instancing (B75–B84)

| Seat | File | Scope | Dep |
|---|---|---|---|
| B75 | `src/postprocess.f90` | **Filters/post** native: blur, bloom-approx, vignette, gamma (framebuffer passes) | B24,B55 |
| B76 | `runtime/f3d-post.js` | WebGL post chain + Pixi-style **filters** (blur/glow/colour-matrix) | B28 |
| B77 | `tools/f3dc/ext_post.py` | Filter-chain DSL/IR/emit plug-in | B08 hooks,B75,B76 |
| B78 | `src/camera_ortho.f90` | **Ortho camera** projection + validation (parallel module, B21 untouched) | B19,B21 |
| B79 | `runtime/f3d-ortho.js` | Ortho + preset cameras in JS runtime (P13) | B28,B78 |
| B80 | `tools/f3dc/ext_cameras.py` | Ortho/preset camera DSL/IR/emit plug-in | B08 hooks,B78 |
| B81 | `src/instancing.f90` | True instanced draw data (P16 back-end form; v1 `repeat` expansion stays B07) | B20,B23 |
| B82 | `runtime/f3d-instanced.js` | WebGL instanced rendering path | B28,B81 |
| B83 | `tests/parity/test_wave_c.py` | Post/ortho/instancing cases | B75–B82 |
| B84 | `examples/post-ortho.f3d` | Ortho scene with a filter chain | B77,B80 |

### Wave D — Parity closure & hardening (B85–B92, then repeat)

| Seat | File | Scope | Dep |
|---|---|---|---|
| B85 | `tools/f3dc/parity_matrix.py` | **Parity matrix generator**: Three+Pixi rows × {impl, test, example} → coverage %; the swarm's backlog | P01,P02,§2,§6 |
| B86 | `tests/parity/test_matrix_coverage.py` | Fails CI until matrix = 100% implemented + tested; thereafter guards regressions | B85 |
| B87 | `runtime/f3d-pixi-compat.js` | Pixi-style 2D surface (sprites/filters/filters-on-2D) sharing the F3D canvas | B69,B76 |
| B88 | `src/output.f90` | PNG writer + multi render targets (P17 deferred slice) | B24 |
| B89 | `tools/f3dc/ext_animation2.py` | Full keyframes/easing/morph targets (P09 v2, glTF-driven) | B08 hooks,B27,B63 |
| B90 | `src/animation_skin.f90` | Skinning/morph evaluation for glTF assets | B19,B64,B89 |
| B91 | `.github/workflows/nightly.yml` | P19 phase 2: full OS/gfortran matrix, big renders, parity job running B86 | B48,B86 |
| B92 | `docs/parity/PARITY-MATRIX.md` | Human-readable matrix (draft generated by B85; this seat curates/explains gaps) | B85 |

**Continuation rule:** after Wave D, B85's uncovered rows are clustered and
minted as Waves E, F, … with seat IDs continuing from B93, always: new files
only, one owner per file, one wave test seat + one example seat per wave,
integration via original owners + B47/B48 follow-ons. The swarm stops only
when B86 passes at 100% — implemented **and** tested — on the canonical CI
cell and nightly (B91) agrees.

## 7. Seat-count summary

| Block | Seats | Files |
|---|---|---|
| v1 compiler / Fortran / runtime / tests / examples / build-docs-CI | B01–B50 | 50 |
| Parity Wave A (lights/PBR/texture/shadow/fog/spot/tone-map) | B51–B62 | 12 |
| Parity Wave B (glTF/raycast/sprites/text/particles) | B63–B74 | 12 |
| Parity Wave C (post/filters/ortho/instancing) | B75–B84 | 10 |
| Parity Wave D (matrix/closure/Pixi-compat/PNG/skinning/nightly) | B85–B92 | 8 |
| Parity Waves E+ | B93… | minted from B85's uncovered rows until B86 = 100% |
