# ADR-5: Timeline IR as a sibling, versioned file contract

- Status: **APPROVED** (user bundle approval of ANIM-PLAN §8 + scope
  ruling, 2026-11-26)
- Context: Forge3D Animation Compiler (docs/ANIM-PLAN.md §3, §8)

## Context

Film mode compiles a `.f3d` script down to keyframe tracks and scene
extensions (`dialogue`, `camera_track`) inside the existing scene
artifacts. That is enough for Forge3D's own engine and preview, but it
is not a contract anyone else can build on: the scene JSON is the
engine's load format, it evolves for the engine's reasons, and it has
no place for a film-level cast, scene sequencing, or dialogue as
first-class records.

StykAnimate will consume Forge3D animation later. If the interface
between the two projects is "whatever the scene JSON happens to look
like when the host work starts", the engine's needs will have bent it
long before then. The contract therefore has to be frozen **before**
the engine work (ANIM-PLAN Wave 3) starts, on its own terms — this is
why the Timeline IR lands in Wave 2, deliberately small and early.

A second pressure shapes the contract's content. The 2026-11-26 scope
ruling superseded the plan's stickman-first framing: the platform is
an all-rounder, the core is rig-agnostic and character-type-agnostic,
and the stickman engine is **one plugin** (id `stickman`). A Timeline
IR that baked in stickman topology — a fixed joint list, stickman
channel names as core vocabulary — would freeze exactly the wrong
contract. The IR must record *which plugin* owns a character's rig
and carry that plugin's channel keys as generic strings, without the
core format knowing what they mean.

## Decision

1. **Timeline IR is a sibling artifact, not a scene-format change.**
   `f3dc build` emits `build/<name>.timeline.json` alongside
   `<name>.json` / `<name>.scene` whenever the source contains
   animation authoring beyond a still. Its discriminator is
   `"format": "forge3d-timeline"` — never `"forge3d-scene"`, because
   a timeline is not loadable by `engine3d` as a scene — and it
   carries its own `"ir_version"`, starting at **1**, evolving on its
   own cadence; neither format's version bumps for the other's
   changes. The timeline **references** scene artifacts (relative
   path + the scene's own `ir_version`, pinned per scene span); it
   never embeds scene geometry. **Absence of the file means the
   source is a still** — no timeline file is emitted for a source
   with no animation authoring, matching the existing frame-count
   rule.

2. **Canonical time is integer frames.** All normative time in the IR
   is an integer frame index under a timeline-level `fps` expressed
   in-file as a rational `{"num": …, "den": …}`. All spans are
   half-open `[start_frame, end_frame)` integer pairs. A span may
   carry `t_seconds` as an informational float only: if `t_seconds`
   disagrees with `frame / fps`, **the frame values win**, and
   readers must not compute timing from `t_seconds`. No float time
   is normative anywhere in the format.

3. **Actions ship resolved keys as the normative contract.** An
   authored action compiles to a resolved span: the symbolic layer
   (`action` name, `params`) is retained as provenance for
   editability, but the resolved per-channel `keys` are what a host
   must implement — a host that implements only the keys produces
   the correct frames, and a host must not re-expand the symbol with
   its own action library and expect the same frames. An action that
   genuinely cannot be resolved to keys is emitted with
   `"resolved": false` and no `keys`; hosts must list such spans in
   their unmapped/import report — **never approximate them**
   silently.

4. **Easing is a closed registry with one canonical spelling.**
   The registry is: `linear`, `smooth`, `in`, `out`, `cubic-in`,
   `cubic-out`, `cubic-in-out`, the parameterised
   `bezier(x1,y1,x2,y2)` form, and `hold`. Each curve has exactly
   one canonical spelling in the IR; source-language aliases (e.g.
   `slowly`, `gently`, `ease-in`) are normalised by the compiler
   before emission and never appear in the file. **Easing attaches
   to the key the segment ENDS at** — Forge3D's frozen keyframe
   semantics win over host convenience; a host whose convention is
   starts-at converts once, at import. The named-ease formulas and
   the bezier solver are part of the format spec. An unknown ease
   name is read as `linear` **and** recorded as a diagnostic — the
   fallback, without the silence.

5. **Characters are plugin-owned; channel keys are generic.** A
   character record carries a `plugin` id (e.g. `"plugin":
   "stickman"`) and a plugin-owned `rig` description whose contents
   the core format does not define. Resolved keys address channels
   by generic string keys (e.g. `"arm.r.upper"`) owned by the
   registering plugin's vocabulary. The core format defines the
   record shapes, the time model, and the stability regime — never
   a rig topology, a joint list, or a channel vocabulary. New rigs
   and channel vocabularies arrive by registering a plugin, not by
   amending this contract.

6. **The stability regime is ADR-3's, copied.** Timeline IR is a
   sibling format under the same regime as the scene format:
   - **Field stability within an `ir_version`:** no key is removed,
     renamed, re-typed, re-meaninged, or given a different default.
     Ever.
   - **Additive-only evolution:** new optional keys, new track
     kinds, new ease names, and safely-skippable enum values do not
     bump `ir_version`. Readers ignore unknown keys at every level
     and skip unknown track kinds **with a diagnostic** — never a
     crash, never a silent drop.
   - **Bump discipline:** a breaking change bumps `ir_version` by
     exactly 1, with migration notes in the changelog. A downgrade
     target is added only if a real consumer needs it.
   - **Exact-version readers:** a reader accepts exactly the
     `ir_version`s it implements and rejects others with an error
     naming the version found. Missing `format` or `ir_version` is
     an error, not a default.
   - **Canonical serialisation:** alphabetical key order; spec'd
     array ordering (scenes in timeline order; tracks sorted by
     `(scene, kind, character/target, start_frame)`; keys sorted by
     frame); no timestamps or random/UUID ids in the normative
     payload.

7. **The determinism boundary is stated honestly.** Same compiler +
   same source ⇒ **bit-identical IR bytes** (hash-testable; this is
   what the canonical serialisation in point 6 buys). Forge3D
   evaluates in `f64`; a host model may be `f32` (StykAnimate's is).
   Bit-identical *rendered frames* across that boundary are **not**
   promised: cross-language frame equality holds only via the one
   documented conversion — `f64 → f32` once, at host import,
   round-to-nearest — after which the host's own deterministic
   pipeline owns playback. The contract says this plainly rather
   than claiming cross-language bit equality it cannot keep.

8. **Embedding is CLI subprocess now; a library is deferred.** The
   first integration runs `f3dc` as a CLI subprocess producing
   Timeline IR files — the only surface `f3dc` has today, and the
   one that keeps the Fortran toolchain outside any host binary,
   with version skew handled by the `ir_version` gate at file
   level. A `bind(C)` library form is **not** built until the file
   contract has survived one real production episode: the file
   format *is* the API, so a library producing the same bytes is
   later a drop-in accelerator, not a redesign.

The implementable specification of this contract is
`docs/TIMELINE-FORMAT.md`, the sibling of `docs/SCENE-FORMAT.md`.

## Consequences

- Wave 2 freezes the contract: the schema, `docs/TIMELINE-FORMAT.md`,
  the emitter, a typed version-gated engine reader (the ADR-3
  pattern), and the contract-test layer (golden IR fixtures, the
  §3.7 conformance kit, and a host-simulation consumer that reads
  only the spec + a fixture) all land before any engine character
  work. **Contract freeze is declared at Wave 2's close** — later
  waves add IR fields only per this ADR's additive rule.
- The compiler gains a third build artifact and a second versioned
  format to keep stable. That cost is deliberate: it is the price of
  StykAnimate (and any third-party reader) never depending on the
  scene JSON's internals.
- Hosts take on real obligations, not just permissions: resolved
  keys are implemented as-is, unresolved spans are reported rather
  than approximated, timing is never re-derived from seconds or a
  host fps, and easing is converted (ends-at → the host's
  convention) exactly once, at import. A host treats the IR as
  read-only import input, never its working format; round-tripping
  IR → host project → IR is **not** promised in v1.
- The plugin boundary is load-bearing from day one: the stickman
  plugin's topology (`humanoid11`) and channel vocabulary appear in
  the IR only as a plugin id, an opaque plugin-owned `rig` value,
  and generic channel strings. If a future rig cannot be expressed
  that way, that is a defect in this contract to fix by the bump
  discipline in point 6 — not a reason to special-case the core.
- Deferring the `bind(C)` library means the first host integration
  pays subprocess + file-IO latency and needs a configured `f3dc`
  path. Accepted: correctness and contract stability first, speed
  once the contract has survived real use.
