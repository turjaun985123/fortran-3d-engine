# Changelog

All notable changes to Forge3D. Dates are commit dates.

## 3.0.0 — Real Pipeline (2026-11-23)

Status: code complete; the v3.0 wave was written in a no-test wave by user order and is UNTESTED pending the verification pass; the tag/Release await the maintainer's nod.

The "Real Pipeline" release: the renderer becomes a linear,
HDR pipeline with a new default rasterizer, the scene and model
formats become fully typed, textures gain a native PNG decoder
and the full material map set, animation gains quaternions, and
the compiler gains a typed IR, incremental compilation and fuzz
hardening. The legacy renderer is frozen, not removed, and
remains available as `--renderer legacy`.

### Added

- **Benchmarking and profiling (Phases 0 and 8).** `f3dc bench`
  for repeatable render/compiler timings, and `f3dc profile` for
  per-stage profiling of a compile and render.
- **Typed scene and model data (Phase 1).** Indexed mesh data as
  the internal representation, a typed JSON reader, full OBJ and
  glTF readers, and the typed `forge3d-scene` scene format.
- **Per-light shadows and PBR lighting (Phase 3).** Per-light PCF
  shadow maps — directional (orthographic), spot, and point
  (cube) — GGX specular, and a linear-HDR pipeline with ACES and
  Reinhard tonemapping plus bloom.
- **Full texture pipeline (Phase 4).** PNG textures decoded by
  Forge3D's own decoder, mipmaps with trilinear filtering, and
  normal, metallic-roughness, emissive and occlusion maps, with
  alpha mask and alpha blend transparency modes.
- **Quaternion animation (Phase 5).** Quaternions with slerp
  keyframe interpolation, per-axis scale, per-track fps, and
  cubic and bezier easing.
- **Modular JS runtime (Phase 7).** The browser runtime is now
  split into ES modules with per-module size budgets (total
  139,928 B), and the Fortran and JS sides share the same math
  vectors.
- **Compressed and binary output (Phase 8).** Compressed PNG
  output using real DEFLATE, binary PPM (P6) output, a `--video`
  render mode, SSIM reported alongside PSNR, and block-wise
  SHA-256 hashing, with parallel-build polish.
- **Fuzzing (Phase 9).** Fuzz harnesses for the parsers and
  readers, feeding the hardening work below.

### Changed

- **Toolchain standardised on gfortran (Phase 0).** The build
  standardises on gfortran, and `f3dc preview` is hardened to
  bind loopback-only.
- **v3 rasterizer is now the default renderer (Phase 2).** The
  new rasterizer — fixed-point edges, perspective-correct
  interpolation, a visibility buffer, tiled rendering with
  OpenMP, and SSAA — replaces the legacy renderer as the
  default. The legacy renderer is frozen and remains available
  as `--renderer legacy`.
- **Colour pipeline is linear-HDR (Phase 3).** Lighting and
  shading now run in linear HDR through to tonemapping (see
  Added above), rather than shading directly in display space.
- **Typed compiler internals (Phase 6).** The compiler gains a
  typed IR and a typed AST, with the validator and emitter split
  into separate units, an incremental compile manifest for
  incremental compilation, and property tests plus a curated
  test set replacing baked-corpus-only gating.

### Fixed

- **String builder self-concatenation (Phase 6).** The string
  builder no longer self-concatenates (self-concat 390→0),
  removing the quadratic behaviour on large generated output.
- **`fmt` round-trip (Phase 6).** Formatting a scene and parsing
  it back now round-trips correctly.
- **Hardening (Phase 9).** Scene storage is now growable instead
  of fixed-size, write failures are detected and reported rather
  than silently dropped, and resource limits and dimension caps
  bound the input a scene, model or texture can demand.

## 2.0.0 — Native Edition (2026-11-23)

The compiler is now fully native and the renderer gained the
features that were still missing after 1.x. There are **no breaking
changes**: every 1.x scene compiles and renders as before, and the
strict golden render is byte-identical to 1.x.

- **Smooth shading (P1).** Curved surfaces (sphere, cylinder, cone,
  capsule, tube, lathe, torus knot, …) now shade smoothly with true
  per-vertex normals instead of flat facets, in the Fortran engine,
  the Canvas2D player and the WebGL2 viewer. A default sphere went
  from ~20 faceted colour bands to 159 distinct colours. Use
  `shading flat` on an object or scene to get the old faceted look
  back.
- **Native PNG output (P2).** `render to "shot.png"` (and numbered
  animation frames) are written by a PNG encoder built into the
  engine itself. PNG output no longer needs ImageMagick's `convert`
  on your PATH. PPM output is unchanged.
- **Model components: `import` + `mirror` (P3).** Build a part once
  and reuse it: `import "parts/fin.f3d" as fin at 1 0 0`. Imports
  behave exactly like hand-written groups (prop defaults, nested
  imports, animation retargeting), with new diagnostics for missing
  files (E501) and import cycles (E504). The new `mirror x|y|z`
  object property reflects a part in place — see
  `examples/rocket-parts.f3d`, which imports one fin twice and
  mirrors the second copy.
- **`NO_COLOR` / `F3DC_DEBUG` honoured (P4).** The native compiler
  now respects the environment conventions the deleted Python
  compiler had: colour diagnostics only on a TTY and never when
  `NO_COLOR` is set (any value), and `F3DC_DEBUG` adds one debug
  line per diagnostic. This closed the last documented divergence
  from the Python oracle.
- **Preview v2 (P5).** `f3dc preview` now watches everything your
  scene depends on — imported part files (including nested ones),
  `load`ed OBJ/glTF models and material textures — and recompiles
  when any of them change, not just when the scene file is saved.
  Generated HTML viewers now boot the **WebGL2** renderer by
  default for GPU-accelerated playback, with the Canvas2D player
  kept as an automatic fallback (same picture, drawn the
  universally supported way) whenever WebGL2 is unavailable.

## 1.x history (2026-11-22 – 2026-11-23)

- **2026-11-22 — v1 built.** The `.f3d` language and `f3dc`
  compiler, the deterministic Fortran software renderer, and the
  tiny dependency-free JS runtime: a scene renders from three
  lines of `.f3d`.
- **2026-11-22 — Parity waves A–E.** Textures/UV, point + spot
  lights, real shadow maps, fog, tonemapping and PBR materials
  (A); glTF loading, raycasting, sprites/text, particles and
  keyframes (B); post-processing filters, orthographic camera,
  true instancing and multi-scene support (C); the extended
  geometry set — circle, ring, capsule, tube, lathe, extrude,
  polyhedra, torus knot (D); custom shaders, skinning/morph
  targets, the WebGL2 viewer and the WebXR sidecar (E). The
  feature matrix reached 39/40; the one remaining item, C4, is a
  real-device WebXR session check (see `docs/XR-CHECK.md`).
- **2026-11-23 — Native compiler port.** The Python compiler was
  rebuilt from scratch as Fortran modules plus a small clang C
  helper (Flang/clang 18), matching the Python oracle's output
  byte-for-byte on the test corpus, then **replaced it**: the
  Python tree was deleted and the native binary took over as
  `bin/f3dc`.
- **2026-11-23 — Zero Python.** The remaining Python test harness
  was rewritten in shell, Fortran and Node. The repository now
  contains no Python files at all, and the full test suite passes
  with `python3` off the PATH.
