# Forge3D v3.0 — "Real Pipeline" — Upgrade Plan

- Status: **ADOPTED** (user decision, 2026-11-23); execution in progress.
- Source: external full-repo analysis + v3.0 plan (pasted 2026-11-23),
  verified first-hand against the tree by the parent agent; this
  document adapts that plan to the corrected baseline below.
- Decisions: `docs/adr/ADR-1..4` (all APPROVED 2026-11-23).

## Baseline corrections (already done — NOT v3.0 work)

The analysis was prepared from a zip that predated the v2.0 finish.
The following are already shipped in v2.0.0 (tag `v2.0.0`, head
`3f0311c`) and are excluded from the phases below:

- Smooth shading (v2 P1) — Phase 2 builds on it; finding R3's area
  already changed.
- Native PNG output (v2 P2) — stored-deflate only; real compression
  is Phase 8.
- Model components: `import` + `mirror` (v2 P3).
- `NO_COLOR` / `F3DC_DEBUG` wired in the native compiler (v2 P4).
- Preview dependency watching (v2 P5a).
- Generated viewers boot WebGL2-first (v2 P5b) — finding J2's headline
  is stale; Phase 7 keeps only the residue (see there).
- Benchmarks + version 2.0.0 + release (v2 P6).

## Goals

1. Correct images: perspective-correct, sub-pixel, anti-aliased,
   linear-light, per-light shadows.
2. One data model: indexed meshes with positions, normals, UVs,
   tangents, and a real glTF 2.0 import path.
3. One render path in the engine (v3; legacy frozen per ADR-1), one
   default renderer in the browser (WebGL2).
4. A compiler that is typed, modular, and testable without an
   external oracle.
5. A CI gate that catches pixel regressions on the real scene
   pipeline.

Non-goals: a GPU backend for the Fortran engine; real-time frame-rate
claims; PBR feature parity with Three.js beyond the existing parity
matrix; new DSL primitives (v3.1 scope).

## Decisions (ADRs, all approved 2026-11-23)

| # | Decision | Summary |
|---|----------|---------|
| ADR-1 | Legacy golden | Legacy renderer frozen as `--renderer legacy`, pinned sha256 `28b6a81d…` in CI. v3 becomes default at Phase 2. v3 goldens by PSNR/SSIM; determinism a hard gate in both modes. |
| ADR-2 | Toolchain | gfortran ≥ 13 standard for engine + compiler; flang an optional non-blocking CI job; `preview_http.c` via system `cc`; clang-18 no longer required. |
| ADR-3 | Scene format | Versioned, keyed format (v2 JSON lineage) + typed reader; `.scene` v1 readable behind the legacy path. |
| ADR-4 | Color | `real32` linear-RGB framebuffer for v3; sRGB output transform at the end. Legacy keeps its 8-bit pipeline. |

## Phases

### Phase 0 — Foundations and hygiene

- ADR-2 portability sweep (gating): compiler builds under
  gfortran-13; fix the `f3dc_validate` module/procedure name
  collision, the `read_file` double-allocation, and all
  non-short-circuit bounds-guard sites in `compiler/src`.
- Fix CI gate B1: G3 renders the **compiled** `.scene` and compares
  against a pinned golden; the legacy no-arg anchor stays as a
  separate step with its pinned hash.
- CI jobs: `make debug` (`-fcheck=all`) running the Fortran tests; a
  sanitizer job (ASan/UBSan) for the C helper; warnings hygiene
  (`-std=f2018 -Wall -Wextra` on new code).
- Makefile: generated dependency rules with `.mod` tracking and `-j`
  (replacing hand-written serial rules in both Makefiles).
- Hygiene (B4): README `doctor` row, stale Python-era comments,
  `.gitignore`/README mismatches, `DESIGN.md` "oracle" language.
- Security quick wins first: X1 (preview binds loopback by default;
  no silent `INADDR_ANY` fallback) and X2 (per-request buffer in
  `preview_http.c`; bounded header scan over `used` bytes only).
- All §6.7 week-1 quick wins: M1 `look_at` up-parallel guard + test;
  G4 `Mesh%num_triangles = 0`; S2 capacity-doubling `append_*`;
  S3 legacy side effects documented (kept, per ADR-1); quick win 8
  (`nint`) deferred to the v3 pipeline by the freeze — recorded, not
  applied to the legacy path; CI lint counting `s = s //` sites in
  `compiler/src` (can only go down).
- Add `f3dc bench`; record baselines (frame time: hello-cube,
  100-object scene, textured plane, shadowed scene) under
  `docs/bench/`. No performance target is binding until these exist.
- Exit: green CI with the new gates; baselines committed.

### Phase 1 — Data model

- New `MeshData` type: indexed, structure-of-arrays (`pos(3,:)`,
  `nrm(3,:)`, `uv(2,:)`, `tan(4,:)`, `idx(3,:)`), plus bounds.
  `Triangle` kept only as a conversion shim.
- Rewrite builders (`create_*`, `geo_*`) to emit indexed meshes with
  shared vertices and real UVs (eliminates `prim_uv`; closes G1).
- Real OBJ (v/vt/vn, groups, `mtl` basics) and glTF 2.0: `.glb`, all
  meshes/primitives, node hierarchy transforms,
  NORMAL/TEXCOORD_0/TANGENT, base-color texture,
  metallic-roughness; one shared proper JSON parser (replacing the
  text scanner here, `tools/json_read.f90`,
  `tests/native/json_parse.f90`). Closes G2.
- Typed scene reader per ADR-3 for the v3 path (replaces the
  `scene_load` monolith there; S1 closed for v3).
- Exit: a textured glTF sample renders with correct UVs; 100k-triangle
  mesh load < 1 s [measure]; vertex-transform count = vertex count.

### Phase 2 — Rasterizer rewrite (v3 renderer)

- Fixed-point sub-pixel setup (28.4), top-left fill rule, incremental
  edge functions, 2×2 quads. Closes R2.
- Perspective-correct interpolation (attribute/w, 1/w) for UV, world
  position, normals, depth; float depth. Closes R1.
- Per-material `double_sided`; delete the 4-triangle plane
  workaround. Closes R4.
- One pipeline: `_mat`/`_env`/`_shader` collapse into a single path
  whose fragment stage is a function; the RPN custom shader becomes
  one fragment stage. Closes R3, R5.
- Visibility buffer (IDs + barycentrics first, shade once per pixel).
  Tile binning with OpenMP/`do concurrent`, per-tile deterministic
  order. Closes R6 (with Phase 0 baselines as the yardstick).
- SSAA/MSAA (`antialias 2|4|8` in the DSL).
- v3 becomes the default renderer (ADR-1); legacy stays behind
  `--renderer legacy` with its pinned gate.
- Exit: R1–R6 closed; thread-count determinism test (1/2/8 threads →
  identical hash); speedup vs Phase 0 baseline reported.

### Phase 3 — Color, lighting, shadows

- Linear float framebuffer (ADR-4); sRGB output; HDR tone mapping
  (ACES/Reinhard) before quantization; true bloom (threshold +
  separable blur). Closes L3, L4.
- Energy-conserving Lambert + GGX; the `(1 - ambient)` legacy
  weighting retired in v3.
- Per-light shadow maps: orthographic fitted directional (cascades
  optional), cube maps for point lights, perspective for spot;
  slope-scaled + normal-offset bias; PCF kernel as a scene setting;
  persistent allocation. Closes L1, L2.
- Hemisphere ambient; optional small prefiltered environment
  lighting (aligned with the JS `env` sidecar).
- Exit: two-light shadow test (each light's shadow independent);
  HDR highlight test (value > 1 survives to tone mapping).

### Phase 4 — Textures and materials

- Decoders: PNG (own inflate) and binary PPM; JPEG optional.
- Samplers: bilinear, trilinear with mipmaps; clamp/repeat/mirror
  wrap; anisotropic optional; sRGB-aware decode. Closes G3.
- Material slots: base color, normal map (tangent space),
  metallic-roughness, emissive, occlusion; alpha modes (opaque,
  mask, blend with sorted transparent pass).
- Exit: normal-mapped and alpha-masked samples in `examples/`.

### Phase 5 — Math and animation

- Add `quat`, `mat3`, `vec4`, general `mat4_inverse`, operator
  overloading; the Phase 0 `look_at` guard is completed with a
  proper diagnostic path (M1 closed here in full).
- Keyframes: quaternion slerp (shortest path), per-axis scale,
  cubic/bezier easing; rotation authored as Euler, stored as
  quaternions. Closes M2.
- Per-clip fps / scene-level timeline. Closes M3.
- Exit: gimbal-lock and 350°→10° tests; golden numeric fixtures
  shared with the JS runtime tests.
- (May run parallel with Phases 1–3; file ownership disjoint.)

### Phase 6 — Compiler redesign

- Replace `dyn` dictionaries with derived types for AST and IR (one
  type per node kind); `dyn` kept only at the JSON boundary.
  Closes C1.
- Split `f3dc_validate` into per-statement validators in a registry;
  split `emit_scene_text` / `emit_fortran_program` per feature.
  Target: no procedure above ~150 lines. Closes C2.
- String-builder type; eliminate the ~390 `s = s //` self-concat
  sites; the Phase 0 CI lint ratchets to zero. Closes C4.
- Replace the baked 914 KB corpus with property tests (round-trip:
  `fmt` idempotent; parse→print→parse stable; every error code has
  a minimal failing input) + a small curated golden set. Closes C3.
- Incremental compile + asset caching; error recovery (one typo
  doesn't hide later errors); machine-readable (JSON) diagnostics.
- Shortest-round-trip float formatting tested directly (retires the
  Python-`repr` mimicry).
- Exit: C1–C5 closed; `f3dc` build time and `check` throughput vs
  Phase 0 baseline recorded.

### Phase 7 — Browser runtime (residue after v2 P5)

- Convert the runtime to ES modules with per-module size budgets in
  CI (core, webgl2, pbr, post, shader, skin, xr…).
- Publish the measured **total** runtime size (fixes J3's core-only
  figure) in README and docs.
- Fix remaining stale fallback wording (J2 residue).
- Share test vectors with Fortran (math, easing, particle hash,
  shading) so engine and runtime cannot drift.
- Exit: J1 addressed by the WebGL2-default path (Canvas2D retained
  as documented fallback), J2/J3 closed; native-vs-browser visual
  parity test under a PSNR threshold.

### Phase 8 — Output and tooling

- Binary PPM (P6); real compressed PNG (fixed-Huffman deflate,
  table-driven CRC-32, filter selection). Closes B5.
- Optional `--video` piping frames to `ffmpeg` if present.
- `f3dc profile` counters (triangles in/out, pixels shaded, overdraw
  ratio, shadow time).
- Exit: a 150-frame render ≥ 20× smaller on disk [measure].

### Phase 9 — Hardening

- Fuzz lexer, parser, OBJ, glTF, `.scene` readers with an in-tree
  mutation fuzzer under ASan/UBSan. Closes X3.
- Growable storage everywhere on the v3 path; remaining fixed caps
  (S1 residue) replaced by diagnostics, never silent drops.
- Resource limits (max triangles, texture size, scene file size)
  with friendly errors.
- Exit: 24-hour fuzz run with zero crashes; S1–S3 closed in full.

## Quality gates (every phase close)

- Full `./tests/run_tests.sh` green, plus the Phase 0 CI gates.
- Legacy-mode golden hash unchanged
  (`28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`).
- v3 goldens within PSNR/SSIM thresholds; thread-count determinism
  hash equal (Phase 2 on).
- Performance vs Phase 0 baselines: any regression > 10% needs a
  written reason in the phase report.
- Each finding ID closed with a test that fails on the old code.
- Zero Python: `git ls-files '*.py'` stays empty.
- Commit per phase (or coherent sub-step); push after every commit
  (standing order); CI watched to completion per push.

## Timeline (from the adopted analysis; engineer-weeks, one dev)

| Phase | Effort | Depends on |
|-------|--------|-----------|
| 0 Foundations | 1–2 | — |
| 1 Data model | 3–4 | 0 |
| 2 Rasterizer | 4–6 | 1 |
| 3 Color/lighting/shadows | 4–5 | 2 |
| 4 Textures/materials | 3–4 | 1, 2 |
| 5 Math/animation | 2 | 0 |
| 6 Compiler redesign | 6–8 | 0, ADR-3 |
| 7 Browser runtime | 4–5 | 0 (parity needs 3) |
| 8 Output/tooling | 2 | 2 |
| 9 Hardening | 2 + ongoing | all |
| **Total** | **~30–40** | critical path ~16–20 with parallelism |

## Risks

- Breaking the legacy anchor erodes determinism trust → legacy mode
  frozen and gated in CI; determinism is also a v3 gate.
- Compiler rewrite stalls (largest component) → migrate one pipeline
  stage at a time behind the existing CLI; old stage selectable until
  its tests move.
- flang-new instability → ADR-2 (gfortran primary; flang optional).
- Visibility-buffer/tiling complexity → land the single-path
  rasterizer first, then threading, then the visibility buffer, each
  with its own golden.
- Scope creep from the parity matrix → v3.0 is correctness and
  structure; new Three.js/PixiJS features wait for v3.1.

## Out of scope for v3.0

GPU backend for the native engine; skeletal-animation retargeting;
physics; scripting beyond the existing shader expressions; new DSL
primitives.

## Status log

- 2026-11-23: Plan adopted (incl. ADR-1). ADRs written. Phase 0
  launched: ADR-2 sweep, preview security fixes, engine quick wins
  in flight.
