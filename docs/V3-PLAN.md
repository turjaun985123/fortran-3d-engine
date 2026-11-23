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
- 2026-11-23: Phase 0 workstreams complete and integrated. ADR-2
  sweep: compiler builds under gfortran-13 (name collision, double-
  allocate, ~203 non-short-circuit guards audited, ~90 dyn_assign
  conversions — gfortran aliases the recursive dyn type's components
  on intrinsic assignment, a live heap-corruption class flang's deep
  copy had masked); artifacts byte-identical to the flang binary on
  13/13 scenes, corpus 896/896 under -fcheck=all and ASan. X1/X2
  fixed in preview_http.c with a 12/12 ASan socket harness. Engine
  quick wins: M1 look-at guard (+35-assertion test), G4 init, S2
  capacity-doubling appends (~200x on a 3000-object load, output
  byte-identical), S3 documented. Quick win 8 (int->nint) DEFERRED
  to the v3 pipeline: it would change legacy pixels (ADR-1).
  Makefiles now generate module dependencies (tools/fortran_deps.sh)
  and build in parallel; CI gained pinned legacy + compiled-scene
  render gates (B1), debug and sanitizer jobs, an optional flang
  job, and the C4 concat ratchet (baseline 390). `f3dc bench` added;
  baselines in docs/bench/BASELINES.md. B4 hygiene done (README
  doctor row, DESIGN.md status, stale .py references in live code
  comments); doctor itself no longer probes python3/convert (now
  gfortran/make/cc).
- 2026-11-23: NEW Phase 9 observation (found via f3dc bench): the
  engine does not detect output write failures. Rendering an
  animated scene onto a full filesystem exits 0 with frames
  silently truncated/missing and the buffered stdout summary lost.
  Phase 9 should add write-status checks + a non-zero exit.
- 2026-11-23: Phase 1 complete. G1 closed: mesh_data_3d indexed
  SoA type; every builder (mesh.f90 create_* + all geo_* modules)
  emits indexed meshes with shared vertices and real UVs; legacy
  create_* reimplemented via the conversion shim (Triangle gained
  uv(2,3)); golden + hello-cube hashes byte-identical, A/B renders
  of geometries/multi-object identical; test_mesh_data 323/323.
  Recorded deviations: (a) mesh_data carries optional dp shadow
  arrays next to the real32 SoA — the legacy path's pinned 1e-9 dp
  precision contract cannot survive a real32 round-trip; real32
  arrays are authoritative for v3 consumers, the shadow serves
  only the legacy shim; (b) the plane stays 8 verts/4 tris (legacy
  double-sided normals) until Phase 2's per-material double-sided;
  (c) prim_uv survives only in the legacy renderer's env path
  (2 sites) — Phase 2 removes it. G2 closed: shared json_reader_3d
  parser (node pool, full JSON, 55/55 tests); OBJ reader now does
  v/vt/vn, all face forms, groups, mtl basics; glTF 2.0 reader
  rebuilt on the parser — .glb, node hierarchy transforms, all
  meshes/primitives, NORMAL/TEXCOORD_0/TANGENT, base-color factor/
  texture, metallic-roughness; existing assets unchanged (pyramid
  6 tris, model.obj 12 tris); 100,352-tri OBJ load 0.943 s (< 1 s
  target); test_loaders 75/75. ADR-3 landed for the v3 path:
  scene_json_3d typed reader for the forge3d-scene JSON
  (ir_version 1) filling the existing Scene type, format/version
  gates rejecting bad files (2 gate branches fixed at integration
  to reset ok=.false.); docs/SCENE-FORMAT.md documents both scene
  formats + versioning rules. S1 closed for the v3 path (the v1
  text reader remains the frozen legacy path).
- 2026-11-23: Phase 2 complete. R1/R2 closed: renderer_v3_3d —
  28.4 fixed-point setup (int64 edges), top-left fill rule,
  perspective-correct interpolation, 1/w float depth, visibility
  buffer + shade-once-per-pixel. R3/R5 closed: fragment_v3_3d —
  the _mat/_env/_shader paths collapse into one frag_shade entry
  (shader/env/material stages over a shared lighting routine).
  R4 closed on the v3 path: per-object double-sided rendering
  (single two-sided quad renders from both sides; test-proven).
  R6: tile binning (32x32) + OpenMP over tiles; determinism is
  structural — CI G3c pins the v3 hello-cube hash AND requires
  threads 1 == 8 byte-identical. v3 is now the DEFAULT renderer
  (--renderer legacy / FORGE3D_RENDERER keep the frozen path;
  both legacy pins reproduce exactly). Hybrid fallback added at
  integration: scenes using sprites/text/particles route to
  legacy with a stderr note until v3 covers them (no silent
  feature loss). v3 goldens in docs/V3-GOLDENS.md: hello-cube
  2907f60a… (PSNR vs legacy 47.78 dB), objects-100 26ecc60b…
  (31.55 dB), shadowed 3d3ce217… (26.97 dB — v3 has no shadow
  maps until Phase 3), textured 5a920c72… (19.22 dB — perspective-
  correct UVs vs legacy's affine sampling). SSAA via the new
  `antialias` scene clause (1/2/4/8, E302/E110 diagnostics, both
  readers round-trip). PERF (written reason, per the >10% rule):
  at 640x480 on the 1.5-vCPU build VM, v3 is SLOWER than legacy
  on geometry scenes (bench medians, same session: hello-cube
  201 vs 142 ms/frame; objects-100 250 vs 165; textured ~parity;
  shadowed nominally faster only because v3 lacks shadow maps).
  Causes: two-pass vis-buffer architecture, per-pixel perspective
  division, int64 edge evaluation, and no spare cores for the
  tile threading to exploit at this size. Phase 2 bought
  correctness and determinism, not speed; a perf pass is future
  work, and Phase 3 adds shadow/HDR cost on top — recorded so
  nobody has to rediscover it. Known v3 gaps entering Phase 3:
  no shadow maps (fragment sfac = 1.0), opaque-only vis buffer,
  near-plane-crossing triangles dropped (no frustum clipping),
  custom shaders get t = 0 (no time in the fragment API),
  sprites/text/particles via the legacy fallback.
- 2026-11-23: Phase 3 complete. L1/L2 closed: shadow_v3_3d —
  per-light shadow maps (orthographic fitted directional,
  perspective spot with near-plane clipping, 6-face cube for
  point lights), texel-derived slope + normal-offset bias, PCF
  radius from the new `shadow_pcf` scene setting (mode 1 hard =
  single tap, mode 2 soft = (2r+1)^2 taps), persistent maps
  reused while the shape is unchanged; the fragment stage now
  queries shadow_v3_factor PER LIGHT and multiplies only that
  light's contribution (two-light independence proven at unit
  level — test_shadow_v3 48/48, test_fragment_v3 case (l) — and
  at engine level: the shadowed bench scene renders differently
  with `shadow off`, 69.70 dB between the two v3 renders).
  L3/L4 closed: post_v3_3d — true float bloom (bright-pass,
  separable Gaussian, threshold 1.0 linear), exposure + tone
  mapping (Reinhard; ACES via the Stephen Hill fit) on the
  linear buffer, sRGB encode ONLY at quantization (ADR-4);
  fragment_v3 lit stages rewritten: energy-conserving Lambert
  (exposure-matched to legacy per light), GGX (Trowbridge-Reitz
  + Smith + Schlick, F0 = mix(0.04, albedo, metalness)) for
  MAT_STANDARD, hemisphere ambient (sky = scene ambient colour,
  ground = 0.3x sky), the `(1 - ambient)` weighting retired and
  the shade_rgb 8-bit round-trip removed — fragment output is
  HDR and unclamped (intensity-3 light -> 3.25 out).  Documented
  exposure delta: a fully-lit up-facing surface renders at
  legacy x (1 + ambient).  Integration: renderer_v3 builds the
  shadow maps per frame in render_core; main's legacy post chain
  no longer double-applies bloom on the v3 path (other chain
  entries still run).  The optional prefiltered-env item was not
  taken up (plan marks it optional).  Goldens re-pinned (see
  docs/V3-GOLDENS.md): hello-cube v3 45a5af9d… (PSNR vs legacy
  25.43 dB — the drop from Phase 2's 47.78 is the intended
  sRGB/lighting change, explained in the registry), objects-100
  07457fa8… (19.72 dB), shadowed ec447b1c… (22.87 dB), textured
  f8632c1d… (20.27 dB); both legacy pins reproduce exactly
  (28b6a81d…, 090fa22a…); v3 thread determinism holds (threads
  1 == 8 == default).  PERF (written reason, per the >10% rule):
  bench medians, same session, 640x480, build VM — v3 vs legacy:
  hello-cube 192.7 vs 144.7 ms/frame, objects-100 226.8 vs
  162.4, textured 204.1 vs 180.5, shadowed 259.4 vs 204.2.
  Against the Phase 0 legacy baselines v3 is +16% (hello-cube),
  +32% (objects-100), ~parity (textured), +14% (shadowed).
  Causes: the Phase 2 vis-buffer architecture (recorded there)
  plus Phase 3's per-frame shadow-map builds, per-light PCF taps
  and per-fragment GGX; the 1.5-vCPU VM gives tile threading
  nothing to exploit.  Correctness and features were bought, not
  speed; a perf pass remains future work.  Suite: full
  run_tests.sh PASS (Fortran layer now 39 programs;
  test_fragment_v3 83/83, test_shadow_v3 48/48,
  test_renderer_v3 79/79).  Known v3 gaps entering Phase 4:
  opaque-only vis buffer (transparent pass is Phase 4),
  nearest-only texture sampling with legacy texture path (G3 —
  Phase 4), near-plane-crossing triangles dropped, custom
  shaders get t = 0, sprites/text/particles via legacy fallback.
- 2026-11-23: Phase 4 complete. G3 closed. Texture core
  (texture_3d, +983 lines, tests 62 -> 185 assertions): own
  inflate (stored/fixed/dynamic Huffman) PNG decoder — colour
  types 0/2/3/4/6, all five unfilter passes, 16-bit high-byte
  rule; Adam7 interlace is cleanly REJECTED (documented, with a
  fixture asserting rejection); chunk CRCs ignored (documented).
  TextureImage gains alpha + has_alpha + srgb/filter/wrap
  fields; mip chains (2x2 box, linear-space) built at scene
  load; texture_sample_f gives filtered (nearest/bilinear/
  trilinear, derivative LOD at the call site) LINEAR rgba with
  repeat/clamp/mirror wrap; texture_load dispatches PNG/PPM by
  magic. Legacy texture API byte-identical. Material plumbing:
  MaterialPBR gains emissive/opacity/alpha_mode/alpha_cutoff;
  SceneObject gains normal/MR/emissive/occlusion texture slots;
  new .scene lines objtex/objalpha/objemissive; DSL props
  normalmap/mr/emissivemap/occlusionmap + material keys
  emissive/opacity/alpha/cutoff (emitted only when used); JSON
  extensions.material carries the same keys (no gap). Fragment/
  renderer: frag_in gains screen-space derivatives (from the
  vis buffers, same-triangle neighbours); base colour now
  samples filtered+linear; tangent-space normal mapping via the
  cotangent frame from derivatives (no per-vertex tangents);
  emissive added unlit; MR map scales metalness (B) / roughness
  (G); occlusion scales the ambient term only; alpha mask
  discards re-shade the next covering triangle (<= 8 layers);
  alpha blend is a sorted back-to-front pass after the opaque
  pass (single-threaded by design — compositing is
  order-dependent; opaque passes keep tile parallelism).
  Examples: normal-mapped / alpha-masked / alpha-blend .f3d +
  deterministic assets from tools/make_example_textures.f90 —
  all three build and render end-to-end (masked fence shows the
  backdrop through its gaps, pixel-verified). Integration fixes
  by the coordinator: the compiler's Wave A '.ppm only' texture
  validator now accepts .png (the ONE corpus case asserting the
  old E501 premise — a wood.png texture — was re-based to
  wood.jpg, preserving the E501 coverage; every other corpus
  case byte-identical), and both scene readers load the base
  texture through texture_load (PPM behaviour unchanged, PNG
  now reaches %tex). Goldens: legacy pins exact (28b6a81d…,
  090fa22a…); hello-cube v3 UNCHANGED (45a5af9d…, threads
  1 == 8); textured v3 re-pinned 171e9713… (20.32 dB — filtered
  linear sampling; see docs/V3-GOLDENS.md); objects-100 and
  shadowed v3 hashes unchanged. PERF (written reason): bench
  medians, same session — v3 vs legacy: hello-cube 205.3 vs
  144.4, objects-100 293.2 vs 169.4, textured 206.3 vs 178.2,
  shadowed 272.6 vs 212.4 ms/frame. Against Phase 0 baselines
  v3 is +24% / +71% / parity / +20%. The objects-100 step vs
  Phase 3 (226.8 -> 293.2) is the restructured shade walk +
  per-fragment derivative computation, paid even by untextured
  scenes; a perf pass remains future work (correctness first,
  per the plan). Suite: full run_tests.sh PASS (Fortran 39
  programs; test_texture 185, test_fragment_v3 103,
  test_renderer_v3 88, test_material_pbr 49). Known v3 gaps
  entering Phase 5: near-plane-crossing triangles dropped,
  custom shaders get t = 0, sprites/text/particles via legacy
  fallback, Adam7 PNGs rejected, mask fall-through search is
  O(tris) per discarded pixel.
- 2026-11-23: Phase 5 complete. M1 closed in full, M2, M3
  closed. Math core (math_3d +603 lines, purely additive):
  quat (x,y,z,w; Hamilton; Euler order matched to
  mat4_compose_trs), mat3, vec4, general mat4_inverse
  (adjugate; singular -> ok=.false. + identity; agrees with
  mat4_inverse_rigid <= 1e-9), minimal operator overloads for
  the new types, quat_slerp (shortest path, nlerp fallback near
  parallel). Shared golden fixtures tests/fixtures/
  math_vectors.json (17 cases) are read by the Fortran test via
  json_reader_3d — the Phase 7 JS tests will consume the same
  file. test_math_quat 246/246. Keyframes: KeyFrame gains
  rot_quat/has_quat + scale3/has_scale3; scene_load converts
  authored Euler to quaternions at parse (Euler stays the file
  form); key_eval_q SLERPs rotation and lerps scale per-axis —
  main now evaluates tracks through key_eval_q and composes
  T * R(quat) * S (coordinator wiring), while key_eval itself
  keeps the frozen legacy semantics byte-identical (its
  350->10 midpoint is asserted to be exactly 180, where
  key_eval_q gives 0). Easing: cubic-in/out/in-out + CSS-style
  cubic-bezier in ease_value (pure; malformed -> linear).
  M3: KeyTrack%fps (key times as frame numbers when > 0),
  carried end-to-end: .f3d `keys ... fps N` -> .scene
  `keys ... fps N` -> engine; Scene%fps + `fps N` scene line,
  and main's frame-timing chain is now scene fps -> first
  anim fps -> 30 (coordinator wiring; parser/validate fps
  forwarding also landed at integration — present-only, zero
  corpus drift). M1 diagnostic path: camera_view_status
  classifier + optional status on camera_init_checked
  (reporting only, matrices bit-identical); both scene loaders
  warn once, located, on a degenerate camera; the compiler
  warns W302 on the ext-camera path (the main camera line
  already errors E401 for at == look); corpus swept — no case
  affected. test_keyframe 79/79 (40 frozen assertions
  untouched), test_camera_diag 21/21. Goldens: every pin
  reproduces exactly (legacy 28b6a81d…/090fa22a…; v3
  hello-cube 45a5af9d…, objects-100 07457fa8…, textured
  171e9713…, shadowed ec447b1c…) — Phase 5 moved no pixels.
  PERF: bench medians this session (v3 vs legacy: hello-cube
  211.0 vs 169.1, objects-100 278.0 vs 166.3, textured 205.4
  vs 213.9, shadowed 277.2 vs 264.0) are within session noise
  of Phase 4 (legacy itself swung 144 -> 169 on hello-cube);
  no Phase 5-attributable change — the raster path is
  untouched. Suite: full run_tests.sh PASS (Fortran layer now
  41 programs). Known limits entering Phase 6: KeyFrame%ease
  is 16 chars, so a bezier(...) ease cannot be stored on a key
  (ease_value accepts it where a full string reaches it);
  near-plane-crossing triangles still dropped in v3; custom
  shaders still get t = 0.
