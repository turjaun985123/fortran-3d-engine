# Forge3D Animation Platform — 50-Wave Programme (living doc)

Standing order (user, 2026-11-26): **"Don't stop until 50 waves."**
Waves 1–6 follow `docs/ANIM-PLAN.md`; Waves 7–50 are the extension
roadmap below. This doc is updated with every wave: scope delivered,
commits, CI run + verdict, gate status. Plan changes are recorded
here with their reason — the invariants never change.

## Scope correction (user ruling, 2026-11-26) — read first

**This platform is NOT stickman-only.** The target is an
**all-rounder animation platform, better than Blender**, at an
extreme level. The stickman engine is **one plugin**.

- **Plugin architecture is a core design pillar.** A plugin
  registry/API lets character rigs, action sets, and feature packs
  register with the core. The stickman engine (Approach A procedural
  figure, its actions, its rig channels) is the **first plugin**
  (id `stickman`) — the proof case, not a core assumption.
- **Core stays rig-agnostic and character-type-agnostic:** the
  language, compiler, and Timeline IR must not bake in stickman
  topology, stickman-only channels, or stickman-named built-ins.
- **"Better than Blender" is measured, never asserted:** Wave 2
  writes `docs/ALLROUNDER-MATRIX.md` (feature coverage vs Blender +
  superiority axes). An axis counts as "better" only with a
  measurement or a shipped feature behind it.

## Plugin externalization (user ruling, 2026-11-26) — read second

**"Stickman will be a plugin for our main engine — NOT built-in."**
The user explicitly rejects the Wave 2/3 state where stickman is
registered as data tables inside the core module
`f3dc_plugins.f90`: registration-as-data inside the core binary
still counts as built-in. This ruling **supersedes the Wave 2/3
"registered as pure data" framing** wherever it appears below
(the Wave 2/3 log entries stand as history; their framing does
not). Required end state:

- **Plugins are external packages on disk:** a directory with a
  manifest (id, version, capabilities) plus its declarations —
  channels, verb→channel maps and parametric templates, character
  prop schemas, rig record — in a data format the compiler LOADS
  at run time. The core keeps only the loader + registry
  mechanism. Package format is a design call for the
  externalization wave, recorded in `docs/PLUGINS.md` (and an ADR
  note if it touches the contract surface); zero-Python holds.
- **Stickman ships as a normal external package** (e.g.
  `plugins/stickman/`), loaded like any other plugin. No stickman
  data remains in core source. Humanoid likewise becomes an
  external package when its depth waves (W19–24) arrive.
- **Proof tests are the gate:** (a) a suite run with the stickman
  package ABSENT — the core still works, and a film using a
  stickman character fails with a clean diagnostic naming the
  missing plugin (new E-code via the census if needed); (b) with
  the package present, the full suite passes exactly as today.
  Byte-identical outputs in both worlds.
- **IR compatibility:** the frozen Timeline IR already carries
  plugin ids, so no format change is expected; resolution happens
  at compile time against loaded plugins. Any genuine format
  consequence goes through the ADR-5 additive path and is flagged
  before landing.
- **Slotting:** externalization is the FIRST scope of Wave 5
  (ahead of video export), and it MUST land before the Wave 6
  v4.0.0 release prep — **v4.0.0 does not ship with stickman
  built in.**

## Invariants (every wave, no exceptions)

- Full `./tests/run_tests.sh` green with every layer genuinely
  running (no silent SKIPs — the gfortran-vanishes trap is checked).
- Legacy golden sha256
  `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`
  **unchanged**.
- Commit + push per wave (active gh account `turjaun985123`, secret
  scan), CI watched to a job-level verdict, fix-forward until green.
- Zero Python in this repo.
- Character identity rules hold per plugin (a character's identity
  props are locked against mid-film cue changes).
- A wave that fails its gates is not "done" — it is fixed or
  reported. Tags/GitHub Releases only with the user's nod.

## Wave map

### Waves 1–6 — per ANIM-PLAN (core + contract)

| Wave | Scope |
|---|---|
| W1 | Language + compiler front-end: film mode, characters, actions, cues, camera moves, dialogue, transitions as nodes, loops, `let`; desugar timeline resolution; validator + E206–E213/W203–W204; cache fixes; corpus + census + property sweep |
| W2 | **Timeline IR v1 + ADR-5 + contract FREEZE**; plugin registry foundation (plugin ids in IR, generic channel keys); `docs/ALLROUNDER-MATRIX.md`; Wave-1 stickman-hardcoding flags (below) all resolved BEFORE the freeze |
| W3 | Engine animation evaluation; **stickman plugin** (Approach A figure, rig, action set) as the first registered plugin; general humanoid rig plugin skeleton |
| W4 | Preview playback (seek/scrub, `/__timeline`, subtitle overlay, diagnostics drawer) |
| W5 | **FIRST: plugin externalization (user ruling 2026-11-26 — stickman becomes an external package under `plugins/`, core keeps loader+registry only, absent-plugin proof tests)**; then video export (film-mode `.mp4` assembly, transitions honoured in export, `.srt` sidecar) |
| W6 | Verification + **v4.0.0 release prep** (tag/Release on user nod) |

### Waves 7–12 — language & library growth

Full built-in action library shipped as plugin packs: locomotion,
gestures, emotions, two-character interactions, prop actions; easing
library; camera grammar depth; dialogue/subtitle polish; transitions
honoured across export paths.

### Waves 13–18 — audio groundwork

Sound/music cue lines in the language, the audio timing model,
mixing metadata in the IR, **TTS hook only** — no shipped voice
without a later user decision on samples.

### Waves 19–24 — effects, environments & general coverage

Weather, particles, day/night in film mode; reusable set/prop
libraries; example films; general-rig coverage growth per
ALLROUNDER-MATRIX (humanoid rig plugin depth, mesh/modeling growth,
materials/lighting depth).

### Waves 25–32 — StykAnimate integration

In `~/workspace/StykAnimate-RS` (its own rules: CI-only verification,
no local cargo builds): `timeline_import.rs` per ANIM-PLAN §3.9,
bake-on-import, easing ends-at conversion + adversarial conformance
tests, dialogue → SubtitleCue, characters → rig instances, MCP/dialog
wiring. StykAnimate consumes the **stickman plugin + core**.

### Waves 33–40 — robustness

Fuzz the film pipeline (incl. the 24-hour zero-crash bar), big
multi-scene stress films, performance work, diagnostics quality,
manual + tutorials; compositing/post coverage per the matrix.

### Waves 41–50 — polish & milestone releases

Complete example film library as fixtures, language ergonomics
passes from real usage, final hardening; version bumps per
milestone, tags/Releases only with the user's nod.

## Wave 2 must-fix flags (from Wave 1 — resolve BEFORE the IR freeze)

Recorded at Wave 1 close (audit of the landed front-end):

1. **Channels are literals in core desugar** (`channel` = body/face
   stamped in `f3dc_desugar.f90`). Must resolve through the plugin
   registry to generic channel keys before the IR can freeze.
2. **Humanoid-flavoured character props live in the core parser**
   (proportions/head/hair/face/wears in `f3dc_parser.f90`). Core
   should keep name/colour/placement; prop schemas belong to the
   registering plugin (stickman plugin declares these).
3. **The extended verb list is a core table** (`ANIM_KINDS_EXT` in
   `f3dc_val_common.f90`). Action sets must register via the plugin
   registry; core keeps only the resolution mechanism.
4. **Character placeholder objects** emitted by desugar carry
   `character=true`; before the IR they must carry a plugin
   reference (default plugin id `stickman`) instead of a core
   humanoid assumption.
5. **Speech/identity semantics in the validator** (E209/E211:
   "only characters speak") must be expressed via registry
   capabilities, not a core humanoid rule.
6. **Easing names carry two spellings** (Wave 1 unification made
   both registries accept `ease-in|out|in-out` and
   `cubic-in|out|in-out` as aliases of the same curves). The
   Timeline IR must emit ONE canonical spelling per curve, chosen
   in Wave 2, or hosts will inherit the ambiguity.

## Per-wave log

### Wave 5, first scope — Plugin externalization (user ruling) (2026-11-26) ✅

- Scope delivered (6 agents: design E1, proof tests E2, package
  data I1, loader I2, interpreter I3 + coordinator integration):
  **stickman is no longer built in.** `plugins/stickman/plugin.json`
  (44 KB) and `plugins/humanoid/plugin.json` (skeleton) are
  external packages in the repo — manifest (`format: 1`, id,
  version, capabilities) + channels, verb→channel maps, character
  prop schemas, rig record, expression codes, and all 20 parametric
  templates as DATA (schema in `docs/PLUGINS.md`, ADR-PLUGIN-1:
  JSON, parsed by the existing `ir_json_parse`; no new parser,
  zero-Python holds). **Core keeps only mechanism:**
  `f3dc_plugins.f90` lost both registration blocks and every
  `TPL_*` constant and gained the loader (search list =
  `F3DC_PLUGIN_PATH` when set — empty string loads nothing — else
  `[<repo_root>/plugins, ./plugins]`, canonical-key deduped;
  malformed/duplicate packages skipped with the new **W205**
  warning, never a crash); `f3dc_anim_resolve.f90` lost all 20
  per-verb subroutines and gained ONE generic interpreter (keys/osc
  steps, expression mini-language, guard conditions — no verb-name
  conditionals); the duplicated expression-code maps in the
  resolver and the timeline emitter are gone (package data via
  `plugin_expression_code`). The one `stickman` literal remaining
  in `compiler/src` is the language-level `DEFAULT_PLUGIN_ID`
  constant (spec, not data — it is what lets the absent-plugin
  diagnostic name the plugin, as the ruling's proof requires);
  acceptance grep over `compiler/src` for
  stickman/humanoid/`TPL_*` returns exactly that one line.
  **New diagnostic E214** ("plugin not loaded", form A names the
  character + plugin id) at the validator's per-character check.
  Two schema completions were proven necessary by a differential
  harness (old resolver vs new interpreter, 53 cases, keys +
  cursor + expression compared exactly): guarded cursor-update
  entries (`exit`'s ±6 side offset; amendment recorded in
  PLUGINS.md) and branch-exclusivity guards in the `face` template
  — with both data fixes the harness is **53/53** and
  `anim-golden`'s `.timeline.json` is byte-identical.
- **Absent-plugin proof (the ruling's gate):**
  `tests/e2e/test_plugin_external_e2e.sh` — **8/8 PASS**: present
  world resolves + emits `"plugin":"stickman"` IR; absent world
  (`F3DC_PLUGIN_PATH=""`) fails the film with E214 naming
  `stickman`, emits no timeline, while non-film scenes and a
  characterless film still build; malformed package fails
  cleanly (diagnostic, no crash/hang). E214 + W205 are also
  registered in the diagnostics census (`property_tests` codes
  section, bespoke env-controlled blocks; census now 33 of 38
  triggered, 5 documented-unreachable).
- **IR compatibility: NO format change** (plugin ids were already
  carried; resolution is compile-time against loaded packages).
  No ADR-5 amendment needed.
- Fix-forward inside the scope: the loader's first dedupe used a
  `realpath` subprocess per search dir per invocation and the
  property driver timed out in-suite; replaced with one `pwd`
  capture + string-canonical keys (per-invocation loader cost
  ~0.03 s). The same dedupe also fixed a real bug: running from
  the repo root enumerated `./plugins` twice and W205-warned
  every package as a spurious duplicate.
- Gates: full suite PASS (native incl. anim 169/169 + curated +
  properties/census, compiler-js 254, e2e 85, fortran 47, ir 64;
  golden SKIP by design) with **zero pin rebakes** — byte-identity
  in the present world is total; legacy golden `28b6a81d…`
  verified unchanged (G3a method); zero Python; concat lint 0.
  CI verdict recorded in the wave close report.
- Carried forward: template bodies are not expression-validated
  at load time (a bad expression inside a template surfaces at
  resolution, not as a load-time W205) — robustness-wave polish.
  Wave 5 continues with its second scope: video export.

### Wave 4 — Preview playback (2026-11-26) ✅

- Scope delivered (4 agents + coordinator integration): **Transport
  runtime** (`runtime/f3d.js`): `api.seek(t)` (pure absolute
  assignment — seek twice = identical frame; clamps to the timeline
  duration when known), `api.time()`, `api.frame()` (round(t·fps),
  the repo's nint rule), `api.timeline` (descriptor from
  `scene.timeline` / `F3D_SCENE` sibling / `F3D_TIMELINE` global;
  both the §4.4 shape and the IR shape accepted); `create()` now
  publishes the player as `window.F3DViewer` so page chrome can
  drive it; `f3d.d.ts` gained the new members. **Compiled viewer**
  (`f3dc_emit_js.f90`/`f3dc_emit_html.f90`): when a scene carries a
  timeline (the `.timeline.json` emission condition), the
  `F3D_SCENE` blob gains a `"timeline"` descriptor
  (`duration`/`duration_seconds`, `duration_frames`, `frames`,
  `fps {num,den}` — frames normative, seconds derived) and
  `runtime/f3d-timeline.js` is inlined after the WebGL2 sidecar so
  the Wave-3 evaluator is the only timing implementation in the
  page. No dep-list change was needed (`f3d-timeline.js` was
  already in `RUNTIME_DEPS`). Non-timeline output is byte-identical
  (proven by old-vs-new builds). **Preview server + page**
  (`f3dc_preview.f90`): the preview compile now also captures the
  Timeline IR via the same emit machinery `do_build` uses
  (`tl_reset`/`tl_add_scene`/`tl_finalize` over
  `timeline_fragment()`; byte-identical to `f3dc build`'s
  `.timeline.json` for the same source, verified live); new route
  `GET /__timeline` serves it verbatim, or the well-formed empty
  document for stills — never 404; the 600 ms poll switched from
  `/__version` to `/__status` (same version field drives the
  reload; LIVE/ERROR pill unchanged); a collapsible **diagnostics
  drawer** renders `/__status` diagnostics (code, severity,
  file:line:col, message, help; `diag_json` gained one additive
  `"file"` field); the page chrome gained a **transport bar**
  (play/pause, frame-stepped scrub slider, `t / duration · frame N`
  readout), a **subtitle overlay** (live cue at the current frame,
  speaker coloured from the IR character colour), and **action
  lanes** (per-character spans + dialogue lane + marker ticks,
  click-to-seek); the playhead persists across the save-reload loop
  via `location.hash` (`#t=`). Playback uses the Wave-3 JS
  evaluator throughout — no second timing implementation.
- Tests: **22 new playback checks** — `tests/compiler/
  test_playback_js.js` (10: real-player seek determinism by pixel
  hash, seek clamping, G3d-timestamp frame mapping, evaluator state
  hashes pinned at all six G3d frames, timeline-vectors hash parity,
  dialogue half-open liveness, per-scene descriptor 28+20=48) and
  `tests/e2e/test_playback_e2e.sh` (12: live `f3dc preview` server —
  `/__timeline` content/501/empty-doc, page transport/subtitle/
  lanes/drawer ids, hash playhead, `/__status` poll, byte-identical
  repeat GETs). Scrub parity is asserted at the evaluated-state
  level (hashes at the G3d pinned timestamps + fixture vectors)
  because no headless harness renders the film through the JS
  stack; the native pixel pins remain CI gates G3d/G3e.
- Pin discipline: the runtime/emitter changes drifted artifact
  hashes in corpus (91), anim (35), examples (12), cli (2) cases.
  Confinement was PROVEN before rebaking (old HEAD binary vs new
  binary over every corpus/anim build case: artifact sets
  identical; changed files only `*.html`/`*.js`; sample content
  diffs show only the inlined transport runtime, the inlined
  evaluator, and the `"timeline"` descriptor key). Rebake was
  surgical (175 distinct hash values remapped consistently, no
  capture-hash collisions, formatting preserved): 258 pin lines
  across corpus/curated/examples/cli_battery.
- Gates: full suite PASS (native incl. anim 169/169 + curated +
  properties/fmt, compiler-js 254, e2e 77, fortran 47, ir 64;
  golden SKIP by design); legacy golden `28b6a81d…` verified
  unchanged by hand (G3a method); zero Python. CI: first run
  `45803947996` failed ONLY the concat lint (one self-concat site
  in the new emit_html inlining code); fixed forward onto
  `str_builder` (byte-identical output, native pins unmoved) in
  `6ddbebb`; run `45805606686` **SUCCESS** — all 4 jobs green,
  verified twice at job/step level (G3a–G3e + G4 all green).
- Carried forward: (i) **multi-scene films do not preview** — the
  preview compiles a file as a single scene (pre-existing: it has
  never done `do_build`'s chunk splitting), so a two-scene film
  like `examples/anim-golden.f3d` gets the error page + the empty
  `/__timeline` document; single-scene films preview fully.
  Fixing this means chunk support in the preview pipeline — a
  later wave's decision, not a silent change to the watch
  machinery. (ii) The Play/Pause label infers state from time
  advance (the runtime exposes no `playing` flag) — cosmetic.
  (iii) Wave-3 carried items stand (core verbs `resolved: false`
  by design; slide/wipe = cut in engine; sit seat height 0.5).

### Wave 3 — Engine evaluation + stickman plugin resolution + film mode (2026-11-26) ✅

- Scope delivered: **Action resolution (compiler):** the stickman
  plugin now publishes a rig-channel vocabulary (16 channels:
  root.x/y/z, root.face, torso, head.pitch/yaw, arm.l/fore,
  arm.r.upper/fore, leg.l.thigh/shin, leg.r.thigh/shin, face.expr)
  and per-verb parametric templates; new `f3dc_anim_resolve.f90`
  resolves all 20 stickman verbs (+ custom-action expansions,
  which desugar already inline) to key lists in the Timeline IR —
  resolved tracks emit `keys` and omit `resolved` (ADR-5: both
  fields already existed in v1; not a format change). Core verbs
  (spin/bob/…) on characters stay `resolved: false` honestly —
  they are closed-form object verbs, evaluated by the engine's
  anim path, not the plugin's key templates (carried, below).
  IR characters gain an additive optional `identity` object
  (head/hair/face/wears/holds — previously dropped by the
  emitter). **`humanoid` plugin registered as a skeleton**
  (rig record + channels + verbs + speaks; no templates, no
  rig channels — its actions stay unresolved by design).
  `docs/PLUGINS.md` documents the plugin model + vocabulary.
  **Engine:** `src/char_figure.f90` — proportions (adult base
  H0 = 1.83; tall/short/kid/height rules), 16-joint FK, and the
  Approach-A figure mesh (capsules + disc head + face + hair +
  wears accessories, BASIC unlit, yaw billboard; 828 tris
  default, 1014 fully dressed, budget ≤ 1100).
  `src/timeline_eval.f90` — film state (Timeline IR + per-span
  scene loading + bindings), channel evaluation with trapezoid
  blending (face.expr largest-weight-wins), camera-track
  evaluation, dialogue span lookup, transition state; the IR
  reader grew additive fields (plain `value` on keys — it was
  being dropped — plus span transitions and character
  proportions/identity). `src/main.f90`: the per-frame scene
  body was extracted verbatim into `render_scene_frame`
  (G3a/G3b/G3c pins reproduce exactly after the move), and
  `engine3d <file>.timeline.json` now RENDERS the film
  (spans in order, film-owned character objects get figure
  meshes + evaluated root/camera; fade/dissolve transitions
  blend two span renders post-render; slide/wipe fall back to
  cut with a note; `--report` keeps the Wave 2 load-and-report
  behaviour). Scene/Anim machinery is reused, not duplicated:
  closed-form anims still apply to characters (anim_eval's
  default case makes sentence verbs no-ops there, so nothing
  double-animates). **JS mirror:** `f3d-keys.js` gained the
  full ease registry (cubic-*, bezier, hold) + `evalTrackQ`
  (key_eval_q mirror: slerp, scale3, fps); new
  `runtime/f3d-timeline.js` evaluates IR channels/blending/
  pose_keys/camera/FK/dialogue identically; shared
  `tests/fixtures/timeline_vectors.json` (26 vectors, 6 kinds)
  is asserted by BOTH engines. **Gates:** `examples/anim-golden.f3d`
  (48 frames, 2 spans, dissolve, camera track, all 7 action
  tracks resolved) + CI **G3d** (6 pinned frames, threads 1 = 8)
  and **G3e** (48-frame sequence digest) + `docs/V4-GOLDENS.md`.
  New Fortran tests: test_stickman_rig (35), test_timeline_eval
  (24), test_camera_track (9), test_dialogue_timing (9),
  test_timeline_vectors (145 assertions).
- **Figure fix (same wave, before first CI):** the first Q5
  render pass showed cap/eyes/bun/glasses missing. Root cause
  (proven by bisection): the figure's single-sided flat parts
  were wound (c, p0, p1) in the (right, up, fwd) billboard
  triad, which is back-facing under both renderers' y-down
  screen-space culling — only double-sided parts (head disc)
  and capsules showed. `char_figure` now emits the
  screen-facing winding for fans/bands/glasses, adds
  shoulder/hip bars (arms/legs read as detached), raises the
  cap dome above the eye line, and enlarges the eyes. G3d/G3e
  re-pinned once, cause recorded in V4-GOLDENS.md. Two S8
  suspicions were NOT bugs: `faces <character>` compiles and
  resolves fine on a disk-backed scratch (the 0-byte outputs
  were this VM's 512 MB /tmp tmpfs filling during parallel
  work), and the "missing ground plane" is the known v3
  near-plane debt — a size-16 plane reaches the camera and its
  two triangles are dropped whole (no frustum clipping);
  staging guidance: keep ground planes clear of the camera.
- Gates: full suite PASS (native incl. anim 169/169 +
  curated 72/323, compiler-js 244, e2e 65, fortran 47
  programs, ir 64; golden SKIP by design); legacy golden
  `28b6a81d…` verified unchanged (G3a reproduced exactly, plus
  G3b/G3c pins); zero Python; CI verdict recorded in the wave
  close report. Perf: `f3dc bench` on this throttled VM (median of 3): hello-cube 676 ms/frame, objects-100 475, textured-plane 481, shadowed 599 -- recorded for reference only: docs/bench/BASELINES.md still holds legacy-pipeline rows from a different method/machine load, and no v3 baseline rows exist yet to regress against (adding them is Wave 5 scope per ANIM-PLAN). The static render path is byte-identical to its pre-wave pins (G3a/G3b/G3c), so static per-frame work is unchanged in kind; Wave 3 code activates only for .timeline.json inputs.
- Pin discipline: 9 IR fixtures + 31 anim corpus cases + 8
  curated copies rebaked, every one proven confined to
  `*.timeline.json` changes of the two allowed classes
  (action tracks gaining keys / losing `resolved: false`;
  characters gaining `identity`) — strip-proof: removing those
  additions reproduces the old hashes byte-for-byte.
  Host-sim assertions updated to the resolved reality; new
  adversarial IR case `unresolved-action` keeps the unmapped
  path covered. Property sweep ratchet: examples 16 → 17,
  EX_XFAIL_MAX 4 → 5 (anim-golden is a two-scene film — the
  documented class-3 structural class; hand-verified).
- Carried forward: (i) core verbs on characters emit
  `resolved: false` (closed-form domain; sampling them into
  root keys is a library-wave concern, W7+); (ii) slide/wipe
  transitions render as cut in the engine (fade/dissolve
  implemented; Q6 metadata rule unchanged); (iii) speech
  bubbles/subtitles do not render in engine film mode —
  dialogue is IR data for the Wave 4 preview overlay + Wave 5
  .srt; (iv) sit targets use a generic 0.5 seat height (the
  resolver does not look up the named object's geometry);
  (v) the humanoid plugin is a registry skeleton — no
  templates, no engine figure (W19–24 depth); (vi) Q5 look
  judgement is the user's, from
  `~/workspace/your_files/forge3d-wave3-stickman-renders.zip`.

### Wave 2 — Timeline IR v1 + ADR-5 + plugin registry + contract FREEZE (2026-11-26) ✅

- Scope delivered: **Timeline IR emission** (`f3dc_emit_timeline.f90`):
  `f3dc build` writes `build/<name>.timeline.json` for any source
  with animation authoring (absence = still; `check` writes
  nothing); canonical integer frames, gcd-reduced rational fps,
  alphabetical keys, spec float hygiene (whole → integer, −0.0 →
  0); characters (with `plugin` id + registry-owned `rig`),
  SceneSpans with bindings + authored `transition` objects,
  dialogue cues (byte-verbatim), camera/pose_keys tracks with real
  keys, verb tracks, action tracks symbolic with
  `"resolved": false` (key resolution is Wave 3 plugin work, per
  ANIM-PLAN §3.4); conditional 7th manifest output so cache hits
  keep the file correct. **ADR-5 written** + `docs/TIMELINE-FORMAT.md`
  (the frozen spec; freeze amendments recorded in-doc: zero-length
  SceneSpan exception, action-track `channel` documented, captions
  have no v1 IR record by design, generator.version note).
  **Plugin registry foundation** (`f3dc_plugins.f90`, leaf module):
  plugins declare channels, verb→channel maps, character prop
  schemas, action verb sets, capabilities, rig records; `stickman`
  registered as pure data. **All six must-fix flags resolved**
  (registry channel resolution in desugar; schema-driven character
  props — core keeps name/colour/`at`; `ANIM_KINDS_EXT` core table
  deleted for registry queries; placeholders carry plugin id;
  E209/E211 via capabilities; one canonical easing spelling —
  cubic-in family — in resolved output). **Both carried items
  closed:** enumerated-prop validation gap (`head triangle` →
  E205, schema-driven, no new code) and the E213 double-print
  (root cause: duration stored in two slots, both recursed by
  `subst_walk`; now reported once). **Engine reader**
  (`src/timeline_ir.f90`): typed, exact-version (ADR-5) reader +
  `engine3d` load-and-report dispatch; 100-assertion test.
  **Contract layer** (`tests/ir/`): purpose schema + validator,
  host-simulation consumer written from the spec alone, 14
  reviewed golden fixtures, 5 adversarial cases, corpus sweep
  (35/35 emitted IR valid); wired into `run_tests.sh` as the `ir`
  layer. **`docs/ALLROUNDER-MATRIX.md`**: 14 coverage areas vs
  Blender (Shipped 1 · Partial 10 · Absent 3), 8 superiority axes
  (PROVEN 4 · PARTIAL 2 · NOT YET MEASURED 2 — no fabricated
  numbers).
- **CONTRACT FREEZE DECLARED at this wave's close.** From here,
  Timeline IR changes are additive-only under ADR-5; any breaking
  change bumps `ir_version` with migration notes.
- Commits: `c7462c2` (compiler: registry + flags + emission +
  pins), `9545eff` (engine reader), `476bc20` (tests/ir), plus
  the docs commit carrying this entry. CI fix-forward: the first
  CI run's concat lint (cap 0) caught 5 self-concat sites in the
  new Wave-2 code; all rewritten onto `str_builder` (slug
  functions ×2, plugin CSV builders ×3) with the native/property/
  IR layers re-verified byte-identical before re-push.
- Gates: full suite PASS (native incl. anim 169/169 + curated
  72/323, compiler-js 190, e2e 65, fortran 42, ir 63; golden
  layer SKIP by design); legacy golden `28b6a81d…` verified
  unchanged by hand (G3a method, `--renderer legacy` render);
  zero Python; CI verdict recorded in the wave close report.
- Pin discipline: 37 artifact-set rebakes proven to be ONLY the
  added `*.timeline.json` (extractor aborted on any other diff);
  curated 11 rebakes same cause; 3 corpus pins + 2 IR fixtures
  changed by the SceneSpan transition addition only (strip-proof:
  removing `transition` reproduces the old hash byte-for-byte);
  sweep ratchet `AN_XFAIL_MAX` 6→7 with hand-verified cause
  (case 164, a Wave-2 two-scene film — the documented structural
  class; its artifact trees are byte-identical except the
  timeline's `generator.source_sha256`, which correctly hashes
  the fmt-rewritten source).
- Carried forward: (i) action tracks ship `resolved: false` —
  Wave 3 makes the stickman plugin resolve its actions to keys;
  (ii) transition *variant* (`fade black`, `slide left`) is not
  carried in v1 — the spec's transition object has no field for
  it (additive candidate); (iii) `hold`/`bezier(...)` are in the
  IR ease registry but not yet authorable in the keys grammar
  (pre-existing E201/E101 limits) — language-growth waves;
  (iv) captions/titles have no v1 IR record (spec decision, see
  TIMELINE-FORMAT).

### Wave 1 — Language + compiler front-end (2026-11-26) ✅

- Scope delivered: film mode end-to-end through the front-end —
  parser (film/character/place/action/cue/cammove/dialogue/
  transition/loopblock/let, `at`/`with`/`after` timing, custom
  actions with `it`), 10 typed-AST node kinds via marker keys,
  desugar timeline resolution (0.5a/0.5b/0.5c), validator timeline
  section + E206–E213/W203–W204, `ir_anim.start`, film-mode `.mp4`
  gating, fmt round-trip for all new kinds, multi-scene film
  chunk prelude, cache fixes (runtime dep family, dep cap),
  unified easing registries. Tests: 162 anim corpus cases (198
  artifact hashes), diagnostics census (36 codes), property
  sweep incl. anim_strict/animprop; ratchet tightened 16/130 →
  144/6 after the fmt fix.
- Commits: `fe8147b` (compiler), `112cc3d` (tests), plus the docs
  commit carrying this entry.
- Gates: full suite PASS locally (native incl. anim 162/162,
  compiler-js 190, e2e 65, fortran 41; golden layer SKIP by
  design); legacy golden `28b6a81d…` verified unchanged by hand
  (G3a method); zero Python; CI verdict for the final head is
  recorded in the wave close report.
- Scope-correction application: core stayed syntax-generic; the
  five stickman-hardcoding flags above are the Wave 2 must-fix
  list (plus easing-spelling canonicalisation, flag 6). Nothing
  was generalised unsafely inside Wave 1.
- Deviations found & fixed inside the wave: fmt round-trip
  rewrite for anim forms; `enter` verb missing from the extended
  registry; `gently` ease spelling; `let` in repeat counts;
  `after` prefix implementation; easing registry split (anim vs
  keyframe tracks); legacy AnimStmt `loop repeat(N)` fmt.
