# Changelog

All notable changes to Forge3D. Dates are commit dates.

## 4.0.0 — Animation Platform (2026-11-26)

Status: Waves 1–5 complete and CI-green; Wave 6 verification +
release prep in progress; the tag/Release await the maintainer's
nod (see `docs/releases/v4.0.md`).

The "Animation Platform" release: a `.f3d` file whose first
statement is `film` becomes a story written in sentences —
characters, actions, dialogue, camera moves, in written order —
compiled to a frozen Timeline IR contract, rendered by the engine
as flat 2D characters inside real 3D environments, previewed with
transport/subtitle/lane playback, and exported to video with an
`.srt` sidecar. Character rigs and action sets are **plugins**:
external packages on disk, not core features — the stickman engine
is the first plugin, not a built-in. Purely additive: every
pre-4.0 program compiles and renders exactly as before, and the
legacy golden is unchanged.

### Added

- **Film mode (Wave 1).** The `film` header (title, `size`,
  `fps`, `tempo`), `character` and `place` setup lines, cues in
  written order with `with` / `together` / `at <time>` / `wait`
  sequencing, built-in and custom actions (an `action` block where
  `it` is the actor, invoked with `does`), camera cues (`follows`,
  `zooms in/out`, `pans`, `orbits`, `looks at`), dialogue
  (`says`, with `bubble only` / `subtitle only` / `thinking`
  styles), `caption` / `title` screen text, scene `transition`
  props and the `fade out` closing cue, timeline `repeat N times`
  blocks, and minimal `let` variables. New diagnostics
  **E206–E213** and warnings **W203–W204** (append-only, in the
  existing families).
- **Timeline IR v1 + ADR-5 contract freeze (Wave 2).**
  `f3dc build` emits `build/<name>.timeline.json`
  (`"format": "forge3d-timeline"`, `ir_version: 1`) whenever a
  source has animation authoring: canonical integer frames at a
  rational fps, half-open spans, a cast table with plugin ids and
  rig records, per-scene spans with bindings, action / pose_keys /
  verb / camera / visibility tracks, dialogue cues and markers.
  The spec is `docs/TIMELINE-FORMAT.md`; evolution from the
  Wave 2 freeze is additive-only under ADR-5. The engine gained
  a typed, exact-version IR reader. Also in Wave 2: the plugin
  registry foundation and `docs/ALLROUNDER-MATRIX.md` (feature
  coverage vs Blender, measured axes only).
- **Engine film rendering + the stickman plugin (Wave 3).**
  `engine3d <file>.timeline.json` renders a whole film: spans in
  order, characters as procedurally generated figures
  (`src/char_figure.f90` — proportions incl. `kid`, 16-joint FK,
  capsule figure with head/face/hair/`wears` accessories),
  channel evaluation with blending, camera tracks, and
  fade/dissolve transition blending. The stickman plugin
  resolves all 20 of its verbs to key lists on its 16 rig
  channels at compile time. The JS runtime gained the matching
  timeline evaluator, asserted against the engine over shared
  test vectors. CI gates **G3d** (six pinned film frames) and
  **G3e** (48-frame sequence digest) guard the golden film
  `examples/anim-golden.f3d` (`docs/V4-GOLDENS.md`).
- **Preview playback (Wave 4).** `f3dc preview` plays films:
  a transport bar (play/pause, frame-stepped scrub, frame
  readout) with deterministic seek, a `GET /__timeline` route
  serving the preview's Timeline IR, a subtitle overlay (live
  cue, speaker colour), per-character action lanes with
  click-to-seek, a diagnostics drawer fed by `/__status`, and
  the playhead persisted in the `#t=` URL hash.
- **Plugin externalization (Wave 5, first scope).** Plugins are
  now external packages: `plugins/<id>/plugin.json` (ADR-PLUGIN-1
  in `docs/PLUGINS.md`), loaded at run time via `F3DC_PLUGIN_PATH`
  (set-but-empty loads nothing) or the default
  `[<repo_root>/plugins, ./plugins]` search list. The stickman
  package carries its rig, channels, prop schemas, expression
  codes and all 20 parametric templates as data; the core keeps
  only the loader, the registry and one generic template
  interpreter. New diagnostics **E214** (plugin not loaded) and
  **W205** (plugin package skipped). Proof gate: with the
  package absent, a stickman film fails cleanly with E214 while
  non-film scenes still build; with it present, output is
  byte-identical.
- **Video export + `.srt` sidecar (Wave 5, second scope).**
  Film-mode `--video` (and `render "name.mp4"` in film mode)
  assembles the film's frames at the film fps with transitions
  already rendered in; ffmpeg-absent is a loud warning with the
  frames kept and exit 0, never a silent success. `f3dc build`
  writes a `<stem>.srt` SubRip sidecar from the film's dialogue
  (exact integer rational timing, byte-verbatim text). First
  measured v3 rows added to `docs/bench/BASELINES.md`.

### Changed

- **Nothing pre-existing.** Film mode is opt-in by the `film`
  first statement; all existing statements, defaults, error
  codes and limits are unchanged, new diagnostics are
  append-only, and the strict legacy golden sha256
  `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`
  has never been re-baselined.

### Known limits (honest)

- **The `humanoid` plugin is a skeleton only** — rig record,
  channels, verbs and the `speaks` capability, but no templates
  and no rig channels: its actions stay unresolved by design.
  Its depth is scheduled for Waves 19–24 of the programme in
  `docs/ANIM-WAVES.md`.
- **`slide` and `wipe` transitions render as a cut** in the
  engine (with a note); `fade` and `dissolve` are real blends.
  The transition variant (`fade black`, `slide left`) is not
  carried in Timeline IR v1.
- **Core verbs on characters are `resolved: false`** in the IR:
  `spin` / `bob` / … are closed-form object verbs evaluated by
  the engine's animation path, not resolved to rig-channel keys
  by a plugin.
- **No TTS or voice of any kind.** `says` is text, timing and
  style only; the engine draws no speech bubbles or burned-in
  subtitles — dialogue reaches the screen via the preview
  subtitle overlay and files via the `.srt` sidecar. Captions
  and titles have no Timeline IR v1 record (a recorded freeze
  decision, not an omission).
- **Multi-scene films do not preview** (the preview compiles a
  single scene; two-scene films get the error page and the empty
  `/__timeline` document). Single-scene films preview fully.
- **`sit` uses a generic 0.5 seat height** — the resolver does
  not look up the named object's geometry.

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
