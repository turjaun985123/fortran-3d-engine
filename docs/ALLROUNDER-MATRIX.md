# Forge3D All-Rounder Matrix — Coverage vs Blender, Measured

**Purpose.** Record, area by area, where Forge3D stands against
Blender as an all-rounder animation platform — and where it does
not. This document exists because of the user ruling of
2026-11-26 (`docs/ANIM-WAVES.md`, "Scope correction"): the
platform is an all-rounder meant to be better than Blender, and
the stickman engine is one plugin (id `stickman`), not the
product. This matrix is the scoreboard for that ambition.

**The measurement rule.** "Better" is measured, never asserted.
An axis counts as better only with a measurement or a shipped
feature behind it. Every number in this document comes from this
repository's own docs or code, or is marked **NOT YET MEASURED**
with the wave that will measure it. No number about Blender's
performance, size, or speed is quoted anywhere in this document,
because this repository has never measured Blender.

**Baseline.** Forge3D **v3.0.0** ("Real Pipeline", tag `v3.0.0`,
release notes `docs/releases/v3.0.md`) **plus Animation Wave 1**
(film-mode language + compiler front-end; see the per-wave log in
`docs/ANIM-WAVES.md`). Tree state: `main` at `038050a` when this
document was written. The Three.js/PixiJS comparison is a
separate, older scoreboard (`docs/parity-matrix.json` +
`docs/parity-status.json`: 39 of 40 rows Done-verified, 1 Blocked
— row C4, XR real-device) and is not repeated here; this matrix
is Forge3D vs **Blender** only.

**How to read the statuses.**

| Status | Meaning |
|---|---|
| Shipped | The capability exists in v3.0.0 + Wave 1 and is backed by the cited evidence. |
| Partial | A real, shipped subset exists; named parts of the Blender area are missing. |
| Absent | Nothing in this area is shipped today. |
| Plugin-provided | The capability arrives through a registered plugin, not the core. No area below carries this as its primary status yet: the plugin registry itself is Wave 2 work and the stickman plugin lands in Wave 3. Where a plugin is the planned route, the row says so in its evidence column. |

Coverage verdicts are deliberately brutal. Most rows are Partial
or Absent. That is the point of the matrix: a gap written down
with a wave number is work that can be scheduled; a gap hidden
behind an adjective is not.

---

## 1. Feature coverage vs Blender

Blender's column is qualitative ("Mature") where Blender ships a
full, production-used toolset for the area; it carries no
invented numbers. The Forge3D evidence column names the file,
doc, or feature that backs the status — a status with no evidence
may not be entered (see §4).

| # | Area | Blender | Forge3D status | Forge3D evidence (repo source) | Grows in wave(s) |
|---|---|---|---|---|---|
| 1 | Modelling (primitives / booleans / modifiers / import) | Mature: edit mode, booleans, a large modifier stack, many importers | **Partial** | Shipped: 7 one-word primitives (`cube`, `sphere`, `cylinder`, `plane`, `pyramid`, `cone`, `torus`, README "Features"); extended geometry builders — circle, ring, capsule, tube, lathe, extrude, Platonic solids, torus-knot (`runtime/f3d-geo.js`, parity row 7 Done-verified); `group … end`, `repeat`/grid/ring, true instancing (parity rows 1, 22); OBJ and glTF loading via one `load` line (parity rows 18, 19). Absent: boolean operations, a modifier stack, vertex/edge/face edit mode, sculpt-style mesh editing of any kind. | 19–24 (mesh/modelling growth, per `docs/ANIM-WAVES.md`) |
| 2 | Sculpting | Mature: sculpt mode, brushes, multires, dyntopo | **Absent** | No sculpting feature exists anywhere in `src/`, `compiler/`, `runtime/`, or the docs. The task brief's own ground fact stands: "no sculpting today." No wave in the current map claims it. | — (no wave assigned; see §3) |
| 3 | Rigging (armatures / skinning / constraints) | Mature: armatures, weight painting, IK and a constraint system | **Partial** | Shipped: static bones — `SceneBone` / `skin_apply` applied at load (noted in `docs/ANIM-PLAN.md` §0.5); skinning and morph targets in parity row C1 Done-verified (`.f3d`: `morph`, `bone … rotate … radius …`, `skin`; `src/skinning.f90` + `runtime/f3d-skin.js`). Absent: an armature authoring workflow, weight painting, IK, constraints, and pose-time (animated) bone evaluation in the engine. | 3 (stickman plugin rig + general humanoid rig plugin skeleton); 19–24 (general-rig coverage growth) |
| 4 | Animation (keyframes / NLA / actions / graph editor) | Mature: keyframes, NLA editor, action library, graph editor with curves | **Partial** | Shipped: declarative verbs (`spin`, `bob`, `orbit`, …) plus quaternion keyframe animation with slerp and per-track fps (v3.0.0 highlights; parity row 17 Done-verified); easing registry, `loop once\|forever\|pingpong` (parity rows 17, 28). Wave 1 adds film-mode cue sequencing compiled down to those same tracks (`docs/ANIM-PLAN.md` §2.2). Absent: NLA, an actions editor, a graph/curve editor, and any GUI timeline. | 1 (done — front-end), 2 (Timeline IR), 3 (engine evaluation), 4 (preview playback UI), 7–12 (action library depth) |
| 5 | Character animation (film-mode language + plugins) | Mature, via armatures + pose library + NLA (manual, GUI-driven) | **Partial** | Wave 1 shipped the front-end only: `film` mode, `character` declarations, sentence cues, custom `action` blocks, camera cues, dialogue, transitions as nodes, `let`, desugar timeline resolution, validator E206–E213 / W203–W204 (`docs/ANIM-WAVES.md` Wave 1 log: 162 anim corpus cases). Not yet shipped: engine-side character rendering (the procedural figure), the plugin registry, and the stickman plugin itself. The language is the shipped part; the performer is not. Plugin-provided route: core stays rig-agnostic, characters arrive via plugins (`docs/ANIM-WAVES.md` scope correction). | 2 (plugin registry foundation), 3 (stickman plugin — first registered plugin; general humanoid rig skeleton), 7–12 (plugin action packs) |
| 6 | Simulation (particles / physics / cloth / fluid) | Mature: particle systems, rigid/soft body, cloth, fluid/smoke solvers | **Partial** | Shipped, one slice only: a deterministic seeded particle emitter whose state is a pure function of `(system, index, t)` (`runtime/f3d-particles.js`; parity row 32 Done-verified, 366/366 deterministic-hash tests). Absent: rigid-body physics, soft body, cloth, fluid, smoke, gravity/collision simulation of any kind. The ground fact stands: "no physics sim today." | 19–24 (particles/weather in film mode); physics/cloth/fluid: no wave assigned (see §3) |
| 7 | Rendering (rasterizers / raytracing / shadows / materials / lighting) | Mature: Eevee (GPU raster), Cycles (path tracer), shadow systems, full material/lighting model | **Partial** | Shipped: v3 rasterizer by default — perspective-correct interpolation, per-light shadow mapping, linear-HDR colour with ACES/Reinhard tonemapping (README; `docs/releases/v3.0.md`); the v2/legacy renderer retained bit-exact as `--renderer legacy`; materials `basic`/`lambert`/`phong` plus PBR metalness-roughness and normal maps; ambient/directional/point/spot lights and fog (parity rows 8–16, 25); custom shaders as an RPN expression evaluator shared by Fortran and JS (parity row C2); browser side: WebGL2 sidecar with Canvas2D fallback (`docs/RUNTIME.md`). Absent: raytracing/path tracing of any kind, a GPU compute renderer, volumetrics, caustics. Forge3D's native renderer is a CPU rasterizer — see the rendering-speed axis in §2 before comparing. | 19–24 (materials/lighting depth); raytracing: no wave assigned and out of scope for the CPU rasterizer (see §2) |
| 8 | Textures / UV | Mature: UV editor, texture painting, procedural node textures | **Partial** | Shipped: PNG textures with mipmaps, normal and metalness-roughness maps (v3.0.0); per-primitive generated UVs under a frozen orientation contract (parity row 15 Done-verified, `test_texture.f90` 62 assertions). Known limit: Adam7-interlaced PNGs are rejected with a diagnostic (`docs/releases/v3.0.md`, Known limitations). Absent: a UV editor/unwrapping, texture painting, procedural texture nodes. | 19–24 (materials/lighting depth) |
| 9 | Compositing / Post | Mature: node compositor, render passes, sequencer-integrated post | **Partial** | Shipped: an ordered screen-space post chain (blur, bloom-approx, vignette, gamma, colour-matrix; parity row 30 Done-verified; `runtime/f3d-post.js`); film-mode transition nodes (`fade`, `dissolve`, `wipe`, `slide`, `cut`) parsed in Wave 1 (`docs/ANIM-PLAN.md` §1.7). Absent: a node compositor, render passes/layers, and transitions honoured in exported video (that is export work, not parse work). | 5 (transitions honoured in export), 33–40 (compositing/post coverage per this matrix) |
| 10 | Video sequencing / editing | Mature: Video Sequencer (timeline editing, strips, effects) | **Absent** | No editor or sequencer exists. Wave 1 gates the *interpretation* of `render "x.mp4"` to film mode (`docs/ANIM-PLAN.md` §1.9.7); assembling a film timeline into a video file is Wave 5 work and has not shipped. Writing a timeline in text is authoring, not editing: there is no trimming, rearranging, or strip model after the fact. | 4 (preview playback: seek/scrub), 5 (video export + `.srt` sidecar) |
| 11 | Audio | Mature: audio strips, mixing in the sequencer, speaker objects | **Absent** | No audio of any kind: no sound/music cues, no mixing, no TTS. `docs/ANIM-PLAN.md` §1.6 states explicitly that `says` implies no voice/TTS in v1. The ground fact stands: "no audio today." | 13–18 (sound/music cue lines, audio timing model, IR mixing metadata, TTS hook only — no shipped voice without a later user decision) |
| 12 | Scripting / automation (Blender Python API vs `.f3d` + CLI) | Mature: full Python API (`bpy`), add-ons, scripting workspace | **Shipped** (for its own model; breadth is not parity) | Shipped and load-bearing today: the whole product is scripted — `.f3d` text files compiled by the `f3dc` CLI (`new` / `check` / `build` / `run` / `profile` / `fmt` / `preview` / `doctor`, README "CLI at a glance"), with friendly located diagnostics instead of silent failures. Zero Python anywhere in the repo (v3.0.0 release notes). Honest limit: this is a scene/film *language plus CLI*, not a general-purpose host API — there is no equivalent of `bpy`'s reach into every subsystem, no add-on system yet (the plugin registry is Wave 2), and no interactive console. The status is Shipped because scripted automation is the shipped, primary workflow — not because its breadth matches `bpy`. | 2 (plugin registry/API foundation), 7–12 (library growth) |
| 13 | Interchange (glTF / OBJ import & export) | Mature: importers/exporters for glTF, OBJ, FBX, Alembic, USD and more | **Partial** | Import shipped: OBJ subset (`v/f`, fan triangulation, negative indices; parity row 18) and glTF/GLB loading (parity row 19 Done-verified, `test_ext_gltf` 21/21, `test_gltf_loader` 30/30), both through the same one-line `load`. Export: the compiler emits its own artefacts only — `scene.json`, `.scene`, Timeline IR (Wave 2) — there is **no glTF or OBJ exporter**. Absent entirely: FBX, Alembic, USD, STL, and every other format. | 19–24 (general coverage growth); no wave currently names an exporter (see §3) |
| 14 | XR | Mature-ish: VR scene inspection via add-ons / OpenXR session support | **Partial** | Shipped: WebXR sidecar — immersive-vr session request, reference-space fallback (local-floor → local → viewer), stereo views, graceful fallback (`runtime/f3d-xr.js`, 6,665 bytes per `docs/RUNTIME.md`). Blocked, honestly: parity row C4 is the one non-verified row in the 40-row matrix — headless tests pass 9/9, but a real immersive session on XR hardware has never been run (no device on the build VM); v3.0.0 release notes carry the same open item. Absent: VR authoring/editing in-session, OpenXR desktop support. | No wave assigned; unblocking is a real-device check by a human with a headset, not a build wave |

**Coverage count (the 14 rows above): Shipped 1 · Partial 10 ·
Absent 3 · Plugin-provided (as primary status) 0.**

That count is the honest headline of this document: against
Blender's breadth, Forge3D today is one shipped scripting model,
ten partial areas, and three empty ones. The superiority claims
that *are* made live in §2, and every one of them is narrow.

---

## 2. Superiority axes — claimed only where measured

Status meanings here: **PROVEN** = a measurement or shipped
feature in this repo backs the claim as stated; **PARTIAL** =
part of the claim is backed and part is not, and the row says
which; **NOT YET MEASURED** = no honest evidence exists yet —
the claim may not be made until the named wave produces it.

| # | Axis | Claim (as narrowly as the evidence allows) | Measurement / feature evidence | Status |
|---|---|---|---|---|
| 1 | Lines of code to a first 3D scene | A spinning, lit, framed 3D scene takes **3 lines** of `.f3d`, and a single `cube` line already renders a lit, framed scene. | `examples/hello-cube.f3d` is exactly `cube red` / `spin it` / `render` (README). The same rotating-cube task was hand-counted at 23 lines in a standalone Three.js program (README, "Honestly better"). Caveat, stated plainly: that 23-line count is a Three.js comparison from the repo's own plan, **not** a Blender measurement — Blender is GUI-first, so a line count against it is a workflow contrast, not a measured ratio, and no Blender line count is claimed. | **PROVEN** (Forge3D side measured; no Blender ratio claimed) |
| 2 | Lines to a complete 15 s character short | A complete ~15-second, multi-cue character short — characters, dialogue, camera moves, transitions — takes **20–27 lines** of film-mode `.f3d`. | Counted from the three complete example scripts in `docs/ANIM-PLAN.md` §1.10 (non-blank lines, including the `film` header and the `render` line): Script A "Saturday Market" = **20 lines**, Script B "The Bus Is Late" = **24 lines**, Script C "The Lost Key" = **27 lines**; each script's cue windows are annotated to 15 s in the source. Caveat: Wave 1 shipped the language and compiler front-end that parses, resolves, and validates these scripts (162 anim corpus cases, `docs/ANIM-WAVES.md`); the engine performing them on screen is Wave 3 and video export is Wave 5, so the *authoring* count is proven and the *rendered short* is not yet. | **PARTIAL** |
| 3 | Total runtime size for web playback | The complete browser runtime — core plus all 14 sidecars — totals **139,928 bytes unminified**, with per-module budgets enforced by the build. | `docs/RUNTIME.md` per-module table (15 files, itemised, summing to 139,928 B); `docs/BENCHMARKS.md` Phase 7 update records the same total against a 143,872-byte budget in `runtime/module-budgets.json`. The minified core alone is 15,335 B and is explicitly **not** the total. No Blender comparison number is quoted: Blender is not a web-playback runtime, so this axis is a Forge3D property, stated as such. | **PROVEN** |
| 4 | Determinism | The same `.f3d` file at the same time `t` produces a **byte-identical** render, natively and in the JS viewer; the legacy renderer is pinned to a golden hash that has never been re-baselined. | Legacy golden sha256 `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`, checked in CI (parity rows 28/33 Done-verified: `animated.f3d` run twice, all 31 PPM hashes identical); `docs/ANIM-WAVES.md` invariants require the golden unchanged every wave; Timeline IR determinism rules (integer frames, canonical key order, no timestamps/UUIDs in the normative payload) are specified in `docs/ANIM-PLAN.md` §3.7. | **PROVEN** |
| 5 | Startup / compile latency | The native compiler validates small scenes in tens of milliseconds on the build VM, and `check` is faster than the deleted Python compiler overall. Nothing is claimed against Blender. | `docs/BENCHMARKS.md` (build VM, 1.5 shared vCPUs — indicative only, per that doc's own machine note): native `check` total 0.6714 s vs Python 1.1131 s over the 10-example corpus (1.66×); `hello-cube` check 0.0099 s native. Honest counterweight from the same table: native `build` is **not** faster overall — 0.92× (1.3642 s vs 1.2528 s), winning 4 of 10 examples. No Blender startup or import timing has ever been measured in this repo. | **PARTIAL** |
| 6 | Learning curve | A film script can be read aloud as plain English sentences with no programming vocabulary, which is the design's learnability bet. | The readability proofs in `docs/ANIM-PLAN.md` §1.10: each of the three scripts is followed by a sentence-by-sentence plain-English paraphrase, and "no line needs a programming word." That is a *demonstration*, not a measurement: no learner study, time-to-first-scene test, or error-rate comparison exists in this repo, against Blender or anything else. | **NOT YET MEASURED** (readability demonstrated in §1.10; learnability itself unmeasured — no wave currently owns a learner study) |
| 7 | Install footprint | Forge3D ships as native binaries with **no Python and no runtime dependency** to install. | `docs/BENCHMARKS.md` Sizes: native compiler `bin/f3dc` = 4,275,512 bytes as a single self-contained binary (v2.0-era measurement); engine `bin/engine3d` = 931,792 bytes. v3.0.0 ships the same two binaries as release assets and states "zero Python in the repository" (`docs/releases/v3.0.md`). Prerequisites are build-time only (gfortran/make, flang-18/clang-18 for the compiler). No Blender install-size comparison is quoted — none has been measured here. | **PROVEN** |
| 8 | Rendering speed | **No claim is made.** Forge3D's native renderer is a CPU rasterizer; Blender's Eevee/Cycles are GPU renderers. This repo holds no Forge3D-vs-Blender frame-time measurement, and a GPU raytracing comparison is out of scope for a CPU rasterizer. | The only frame-time numbers in the repo are Forge3D-only regression baselines, and they are **legacy-renderer only**: `docs/bench/BASELINES.md` — 640×480 on the throttled build VM, 165.603 ms/frame (`hello-cube`) to 226.894 ms/frame (`shadowed`); `docs/ANIM-PLAN.md` §0.7 confirms **no v3 frame-time baseline exists**. README states the standing position: "No frame-rate claims are made." The first honest step is Wave 5's v3 export-cost baselines (per `docs/ANIM-PLAN.md` §0.7, export estimates are extrapolations until Wave 5 measures real v3 rows) — and even those will be Forge3D-only regression numbers, not a Blender comparison. | **NOT YET MEASURED** (first step: Wave 5 v3 baselines) |

**Axis count: PROVEN 4** (axes 1, 3, 4, 7) · **PARTIAL 2**
(axes 2, 5) · **NOT YET MEASURED 2** (axes 6, 8). Total 8 axes.

What this table may and may not be used for: the four PROVEN axes
are properties of Forge3D (brevity, size, determinism, footprint)
that are true regardless of Blender. None of them says Forge3D
renders faster, models deeper, or simulates anything Blender
simulates. Breadth belongs to Blender today (§1); the bet of
this programme is that the measured axes plus wave-by-wave gap
closure (§3) are worth more than breadth claimed early.

---

## 3. Gap-closure map — top gaps, ranked

Ranked by how much of the all-rounder promise each gap blocks,
not by ease. Wave bands are those of `docs/ANIM-WAVES.md`.

| Rank | Gap | Where it shows in §1 | Closure route |
|---|---|---|---|
| 1 | Characters exist in the language but not yet on screen: no plugin registry, no stickman plugin, no engine character evaluation | Rows 5, 3 | **Wave 2** (plugin registry foundation; the six Wave-1 stickman-hardcoding flags resolved before the Timeline IR freeze) → **Wave 3** (stickman plugin as first registered plugin; general humanoid rig skeleton; engine animation evaluation) |
| 2 | No audio at all — a film platform that cannot make a sound | Row 11 | **Waves 13–18**: sound/music cue lines, audio timing model, IR mixing metadata, TTS hook only (no shipped voice without a later user decision) |
| 3 | No video out: timelines cannot yet be exported as films, transitions are parse-only | Rows 10, 9 | **Wave 4** (preview playback) → **Wave 5** (film-mode `.mp4` assembly, transitions honoured in export, `.srt` sidecar; also the first v3 frame-time baselines, §2 axis 8) |
| 4 | Modelling depth: no booleans, no modifiers, no mesh editing; rigging depth: no IK, constraints, or weight workflows | Rows 1, 3 | **Waves 19–24**: mesh/modelling growth, materials/lighting depth, general-rig coverage growth, reusable set/prop libraries |
| 5 | Action/character content is thin: the built-in verb set is a starter list, not a library | Rows 4, 5 | **Waves 7–12**: full built-in action library as plugin packs (locomotion, gestures, emotions, two-character interactions, prop actions), easing library, camera grammar depth, dialogue/subtitle polish |
| 6 | Simulation is one deterministic particle emitter and nothing else — no physics, cloth, or fluid, and no wave yet owns them | Row 6 | Particles/weather grow in **waves 19–24**; physics/cloth/fluid have **no assigned wave** — this matrix records them as an open planning gap for a future user ruling, not as scheduled work |
| 7 | Sculpting is entirely absent, with no wave assigned | Row 2 | **No assigned wave.** Recorded here so the absence is a decision on record, not an oversight; scheduling it requires a user ruling |
| 8 | Compositing is a filter chain, not a compositor; no passes, no nodes | Row 9 | **Waves 33–40**: compositing/post coverage growth alongside fuzzing, stress films, performance work, and diagnostics quality |
| 9 | Interchange is import-only and two formats wide; no glTF/OBJ export, no FBX/Alembic/USD | Row 13 | Import breadth can grow in **waves 19–24** (general coverage); no wave currently names an exporter — recorded as an open gap |
| 10 | XR is headless-verified but has never run on a real device | Row 14 | Not a build wave: a human with an XR headset runs `examples/xr-check.html` per `docs/XR-CHECK.md` and confirms session creation + presentation (parity row C4) |
| 11 | Robustness at film scale is unproven: no fuzzing of the film pipeline, no big multi-scene stress films | Rows 4, 5 (risk, not coverage) | **Waves 33–40**: fuzz the film pipeline (including the 24-hour zero-crash bar), stress films, performance work; polish and milestone releases in **waves 41–50** |

---

## 4. Maintenance rule

This document is updated **per wave**, in the same commit series
that closes the wave, alongside the per-wave log in
`docs/ANIM-WAVES.md`.

- A status in §1 may only move (Absent → Partial → Shipped, or
  any axis in §2 moving to PROVEN) when the wave ships the
  feature or records the measurement — and the row's evidence
  cell must name it (file, doc, test, or benchmark) in the same
  edit. A status that moves without new evidence is a defect in
  this document.
- A status may also move **down** when evidence is withdrawn or
  found wrong; the correction is recorded, not silently edited.
- Numbers are never refreshed from memory: re-measure (e.g.
  `tools/build_runtime.mjs` for the runtime total, per
  `docs/RUNTIME.md`) or leave the old number with its date.
- New Blender-comparison claims enter §2 only, only with a
  measurement or shipped feature behind them, and start at
  NOT YET MEASURED until that evidence exists.
