# Forge3D Timeline IR — the format contract (ADR-5)

The Timeline IR is the stable, versioned interface between `f3dc`
and animation hosts (first consumer: StykAnimate). It is a **sibling
format** to the scene formats in `docs/SCENE-FORMAT.md`, governed by
ADR-5 (`docs/adr/ADR-5-timeline-ir-contract.md`). This document is
the implementable specification: a third party must be able to write
a conforming reader from this document alone.

| Artifact | Format | Reader | Status |
|---|---|---|---|
| `build/<name>.timeline.json` | Keyed JSON (`"format": "forge3d-timeline"`) | Any host importer; a typed, version-gated reader in the engine (ADR-3 pattern) | **v1 — frozen at Wave 2 close; evolves only per ADR-5's additive rule** |

Emission rule: `f3dc build` emits the timeline file alongside
`<name>.json` / `<name>.scene` **whenever the source contains
animation authoring beyond a still**. No timeline → no timeline
file: **absence of the file means the source is a still**, matching
the scene formats' frame-count rule.

The timeline **references** scene artifacts; it never embeds scene
geometry. Characters, sequencing, timed tracks, dialogue and markers
live here; meshes, materials and lights live in the scene files.

---

## The file at a glance

- UTF-8 JSON, **no BOM** (see *Text rules*).
- A single JSON object. Key order in emitted files is canonical
  (alphabetical — see *Emitter guarantees*), but readers must not
  depend on key order.
- `"format": "forge3d-timeline"` — required; readers reject any
  other value.
- `"ir_version": 1` — required; see *Versioning and migration*.

### Top-level structure

```json
{
  "format": "forge3d-timeline",
  "ir_version": 1,
  "name": "gate-scene",
  "fps": {"num": 24, "den": 1},
  "duration_frames": 48,
  "generator": {"tool": "f3dc", "version": "4.0", "source": "gate.f3d",
                "source_sha256": "…"},
  "characters": [ ],
  "scenes":     [ ],
  "tracks":     [ ],
  "dialogue":   [ ],
  "markers":    [ ]
}
```

| Key | Type | Meaning / reader behaviour |
|---|---|---|
| `format` | string | Must equal `"forge3d-timeline"`, else reject. Missing is an error (see *Reader obligations*). |
| `ir_version` | int | Must be a version the reader implements (this spec: `1`), else reject naming the version found. Missing is an error, not a default. |
| `name` | string | Film/episode name, from the source. Informational; no timing or identity semantics hang off it (ids do that work). |
| `fps` | `{num, den}` ints | The canonical rate for **all** frame values in the file. See *Frames and fps*. Never assumed, never defaulted. |
| `duration_frames` | int | Authoritative total length of the timeline, in frames. |
| `generator` | object | **Provenance only** — `{tool, version, source, source_sha256}`. `version` is the emitting `f3dc` version (`"3.0.0"` until the v4.0.0 release; the worked example below shows `"4.0"`). Readers must ignore it for semantics. `source_sha256` is the hash of the `.f3d` source and is content-derived, so it does not break byte determinism; no timestamps or random values ever appear here or anywhere else in the file. |
| `characters` | array of Character | The cast table, declared once, referenced by `id` everywhere else. May be empty. |
| `scenes` | array of SceneSpan | Ordered partition of the timeline (see *Array ordering*). At least one entry in any file a host can import. |
| `tracks` | array of Track | Timed performance + camera data. May be empty. |
| `dialogue` | array of Dialogue cue | Subtitle/dialogue cues. May be empty. |
| `markers` | array of Marker | Named story beats / chapter points. May be empty. |

---

## Frames and fps

1. **Canonical time is an integer frame index.** Every `*_frame`
   value, every key `frame`, and `duration_frames` are JSON
   integers. No float time is normative anywhere in the format.
2. **`fps` is a rational** `{"num": int, "den": int}`, both
   positive, written in reduced form (`num`/`den` divided by their
   gcd — e.g. 24000/1001 is written as-is, 48/2 is written as
   `{"num": 24, "den": 1}`). It is always present in-file; readers
   never assume or default a rate. All frame arithmetic is integer
   arithmetic.
3. **All spans are half-open** `[start_frame, end_frame)`: a span
   is live at frame `f` iff `start_frame ≤ f < end_frame`.
   `end_frame > start_frame` for every **track and dialogue cue**.
   SceneSpans are the exception: a scene with no cues contributes a
   zero-length span (`duration_frames: 0`), and a film with no cues
   at all has top-level `duration_frames: 0` — the partition rule
   (SceneSpan durations sum to the total) still holds. (Clarified
   at the Wave 2 freeze; emitted files already behaved this way.)
4. A span or cue may carry **`t_seconds`** (float, informational
   only). If `t_seconds` disagrees with `frame × den / num`, **the
   frame values win**; readers must not compute timing from
   `t_seconds`.
5. A reader whose own timeline runs at a different rate performs
   **one documented resample at import** and nothing else — timing
   is never re-derived per-frame from seconds or from the reader's
   fps (see *Determinism*).

---

## Records

### Character

Declared once at top level, because characters persist across
scenes (unlike scene objects, which are per-scene). Referenced by
`id` from scene bindings, tracks and dialogue.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `id` | string (slug) | yes | Source-derived identifier (see *ID rules*). Unique within `characters`. |
| `name` | string | yes | Display name, byte-verbatim from source. |
| `plugin` | string (slug) | yes | Id of the plugin that owns this character's rig, action set and channel vocabulary — e.g. `"stickman"` for the stickman plugin. The core format never interprets the id beyond recording it; a reader that does not know the plugin can still import timing, dialogue and camera, and must report the character's plugin-owned tracks as unmapped rather than guessing at them. |
| `color` | `[r, g, b]` ints 0–255 | yes | The character's identity colour. |
| `rig` | object | yes | **Plugin-owned rig description.** Its contents are defined by the registering plugin's vocabulary, not by this spec — for the `stickman` plugin it is `{"kind": "stick", "topology": "humanoid11"}`. The IR carries identity and proportion *hints*, never a host-specific node list; topology is the host's/plugin's business. Core readers treat `rig` as opaque: preserve/report it, never interpret keys the plugin has not published. |
| `proportions` | object | no | Plugin-owned proportion hints (e.g. limb lengths, height class), in the plugin's vocabulary. Absent means "plugin defaults"; a reader must not invent proportions silently — if it substitutes defaults, that belongs in its import report. |
| `voice` | object | no | `{speaker: string}` — the display/speaker name dialogue cues resolve against. |

### SceneSpan

The sequencing layer: one entry per scene, in timeline order,
partitioning `[0, duration_frames)`.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `id` | string (slug) | yes | Source-derived scene identifier. Unique within `scenes`; referenced by tracks and dialogue as `scene`. |
| `name` | string | yes | Scene name from the source. |
| `scene_file` | string | yes | Relative path to the scene artifact for this span (e.g. `"gate-gate-one.json"`), resolved relative to the timeline file's directory. |
| `scene_ir_version` | int | yes | The **scene format's** `ir_version` of `scene_file` — pinned per span, so the two formats evolve independently (ADR-5 point 1). |
| `start_frame` | int | yes | First frame of the span. The first span starts at 0; spans are contiguous and non-overlapping. |
| `duration_frames` | int | yes | Length of the span; the span covers `[start_frame, start_frame + duration_frames)`. Span durations sum to the top-level `duration_frames`. |
| `bindings` | object | yes | Map `character_id → object name in THIS scene`. Bindings are per-scene because scene artifacts are self-contained. A character absent from `bindings` is **off-stage** for that scene. May be empty. |
| `transition` | object | no | How this span opens, as recorded by the compiler (kind + duration in frames). Presentation metadata for players/export assembly; it does not change the span's frames. |

### Track

All tracks carry `kind` and `scene` (a SceneSpan `id`). v1 kinds:
`action`, `pose_keys`, `verb`, `camera`, `visibility`. Readers
**skip unknown kinds with a diagnostic** (see *Reader
obligations*); new kinds are additive and do not bump `ir_version`.

#### Common key fields (all keyed track kinds)

A *key* is one sample on a track. Keys within a track are sorted by
`frame` (emitter guarantee); equal-frame keys in one track never
occur in a valid file (they are a compile-time error — see
*Emitter guarantees*).

| Key field | Type | Meaning |
|---|---|---|
| `frame` | int | Absolute frame (timeline frames, not scene-local). |
| `ease` | string | Easing of the segment **ending at this key** (see *Easing*). The first key's `ease` is emitted as `"linear"` and ignored. |

#### `action` — a resolved character action

| Key | Type | Required | Meaning |
|---|---|---|---|
| `kind` | `"action"` | yes | |
| `scene` | string (SceneSpan id) | yes | |
| `character` | string (Character id) | yes | The actor. |
| `action` | string | yes | The authored action's name — **provenance**. |
| `channel` | string | no | The generic channel key (plugin vocabulary, e.g. `"body"`/`"face"` for the stickman plugin) the authored action animates, per the owning plugin's verb→channel mapping. Present so hosts can group and report spans — including `resolved: false` spans that carry no keys yet. |
| `start_frame`, `end_frame` | int | yes | The action's span, half-open. |
| `params` | object | no | The authored parameters — **provenance** (e.g. `{"arm": "right", "cycles": 2}`). |
| `resolved` | bool | no (default `true`) | `false` means the action could not be resolved to keys: `keys` is then absent, and hosts must report the span as unmapped, never approximate it (ADR-5 point 3). |
| `keys` | array | yes, when resolved | The **normative contract**: resolved per-channel keys. A host that implements only the keys produces the correct frames; a host must not re-expand `action`/`params` with its own action library and expect the same frames. |

Each action key is `{frame, channel, value…, ease}`:

| Key field | Type | Meaning |
|---|---|---|
| `channel` | string | A **generic channel key owned by the character's plugin's vocabulary** (e.g. `"arm.r.upper"` for the stickman plugin). The core format defines no channel names. |
| `value` / `value_deg` | number | The channel's value at this frame — `value_deg` when the channel is an angle in degrees, `value` otherwise. Which form a channel uses is part of the plugin's published vocabulary. |

#### `pose_keys` — keyed placement/pose for a character or scene object

Carries exactly one of `character` (Character id) or `target`
(scene object name, as bound in the span's scene).

Each key is `{frame, pos, rot_deg, scale, ease}` — every field
optional except `frame` and `ease`; an absent field means "not
keyed on this track at this frame":

| Key field | Type | Meaning |
|---|---|---|
| `pos` | `[x, y, z]` numbers | World position. |
| `rot_deg` | `[x, y, z]` numbers | Euler rotation in degrees. |
| `scale` | number, or `[x, y, z]` numbers | Uniform or per-axis scale. |

#### `verb` — a closed-form animation span on a scene object

The IR form of the scene formats' `animations[]`: a named
closed-form verb evaluated by formula, not by keys.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `kind` | `"verb"` | yes | |
| `scene` | string | yes | |
| `target` | string | yes | Scene object name. |
| `verb` | string | yes | The verb name (the scene vocabulary: `spin`, `bob`, `pulse`, `orbit`, `move`, `turn`, `grow`, …). |
| `start_frame`, `end_frame` | int | yes | The span, half-open. |
| `params` | object | no | Verb parameters in the scene vocabulary (e.g. `axis`, `speed`), verbatim. |

#### `camera` — the 3D camera track

One per scene at most. The IR carries the 3D truth and lets the
host project; no 2D camera form exists in the IR, because it would
lose the native path's information.

Each key is `{frame, pos, target, fov, ease}`:

| Key field | Type | Meaning |
|---|---|---|
| `pos` | `[x, y, z]` numbers | Camera position. |
| `target` | `[x, y, z]` numbers | Look-at point. |
| `fov` | number | Vertical field of view in degrees. |

#### `visibility` — on/off spans

One record per span: `{kind: "visibility", scene, start_frame,
end_frame, visible}` plus exactly one of `character` (Character
id) or `target` (scene object name). `visible` is a bool: the
subject is visible throughout `[start_frame, end_frame)` iff
`visible` is `true`. Outside all its visibility spans, a subject
keeps the visibility its scene artifact gives it.

### Dialogue cue

Shaped to map 1:1 onto a host subtitle cue plus a character link.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `id` | string (slug) | yes | Source-derived; unique within `dialogue`. |
| `scene` | string (SceneSpan id) | yes | |
| `start_frame`, `end_frame` | int | yes | Half-open; `end_frame > start_frame`. The cue is live at `f` iff `start_frame ≤ f < end_frame`. |
| `speaker` | string (Character id) | yes | Who speaks. (Narrator text — captions/titles — is not a dialogue cue in v1.) |
| `text` | string | yes | The line, **byte-verbatim from source** (see *Text rules*). Never empty: the compiler emits a diagnostic instead of an empty-text cue. |

**Captions and titles have no v1 IR record — by design.** Narrator
`caption`/`title` lines are screen text for Forge3D's own preview
and export paths and live in the scene artifacts; hosts do not
receive them through the Timeline IR in v1. If a future version
gives them a record kind, that is an additive change under ADR-5.
(Noted explicitly at the Wave 2 freeze so the absence is a
decision, not an omission.)

### Marker

| Key | Type | Required | Meaning |
|---|---|---|---|
| `frame` | int | yes | Absolute frame the marker sits on. |
| `name` | string | yes | Marker name, byte-verbatim from source. |
| `kind` | string | yes | `"beat"` (story beat) or `"chapter"`. Other values are safely-skippable enum values: readers that do not know one keep the marker as an untyped point or report it — never crash. |

---

## Worked excerpt

Two characters, one action, one line of dialogue, one camera move
(the ANIM-PLAN §3.5 excerpt, with the character records carrying
their `plugin` id per the 2026-11-26 scope ruling):

```json
{
  "format": "forge3d-timeline",
  "ir_version": 1,
  "name": "gate-scene",
  "fps": {"num": 24, "den": 1},
  "duration_frames": 48,
  "generator": {"tool": "f3dc", "version": "4.0", "source": "gate.f3d"},
  "characters": [
    {"id": "mira", "name": "Mira", "plugin": "stickman", "color": [90, 140, 220],
     "rig": {"kind": "stick", "topology": "humanoid11"}, "voice": {"speaker": "Mira"}},
    {"id": "finn", "name": "Finn", "plugin": "stickman", "color": [230, 170, 60],
     "rig": {"kind": "stick", "topology": "humanoid11"}, "voice": {"speaker": "Finn"}}
  ],
  "scenes": [
    {"id": "s1", "name": "gate-one",
     "scene_file": "gate-gate-one.json", "scene_ir_version": 1,
     "start_frame": 0, "duration_frames": 48,
     "bindings": {"mira": "mira_body", "finn": "finn_body"}}
  ],
  "tracks": [
    {"kind": "action", "scene": "s1", "character": "mira",
     "action": "wave", "start_frame": 24, "end_frame": 48,
     "params": {"arm": "right", "cycles": 2},
     "keys": [
       {"frame": 24, "channel": "arm.r.upper", "value_deg": -10, "ease": "linear"},
       {"frame": 36, "channel": "arm.r.upper", "value_deg": -150, "ease": "smooth"},
       {"frame": 48, "channel": "arm.r.upper", "value_deg": -10, "ease": "smooth"}
     ]},
    {"kind": "pose_keys", "scene": "s1", "character": "finn",
     "keys": [
       {"frame": 0,  "pos": [1.5, 0, 0], "rot_deg": [0, -20, 0], "scale": 1, "ease": "linear"},
       {"frame": 48, "pos": [1.5, 0, 0], "rot_deg": [0, -35, 0], "scale": 1, "ease": "smooth"}
     ]},
    {"kind": "camera", "scene": "s1",
     "keys": [
       {"frame": 0,  "pos": [5, 3, 7], "target": [0, 0, 0],   "fov": 60, "ease": "linear"},
       {"frame": 48, "pos": [3, 2, 4], "target": [0, 0.5, 0], "fov": 50, "ease": "smooth"}
     ]}
  ],
  "dialogue": [
    {"id": "d1", "scene": "s1", "start_frame": 12, "end_frame": 48,
     "speaker": "mira", "text": "Finn — over here!"}
  ],
  "markers": [
    {"frame": 24, "name": "the wave", "kind": "beat"}
  ]
}
```

Finn has no action — he stands and turns via `pose_keys`. Mira's
`wave` shows one channel for brevity; a real emission carries every
animated channel of the action, in the plugin's published
rig-channel vocabulary. (Whole-valued reals appear as JSON integers
per *Float formatting* — `-10`, `60`, `1` above, never `-10.0`.)

---

## Easing

### The closed registry

These spellings, and only these, appear in emitted files. The
formulas are **part of the format spec** — a reader implements
these, not its own easing library's versions of the same names.
`p` is segment progress, **clamped to [0, 1]** before evaluation.

| Spelling | Formula (`e` = eased progress) |
|---|---|
| `linear` | `p` |
| `smooth` | `p²(3 − 2p)` |
| `in` | `p²` |
| `out` | `1 − (1 − p)²` |
| `cubic-in` | `p³` |
| `cubic-out` | `1 − (1 − p)³` |
| `cubic-in-out` | `4p³` for `p < 0.5`; else `1 − (−2p + 2)³ / 2` |
| `bezier(x1,y1,x2,y2)` | Cubic Bézier with control points `(0,0)`, `(x1,y1)`, `(x2,y2)`, `(1,1)`: solve `x(t) = p` for `t` (Newton iteration with a bisection fallback), return `y(t)`. `x1`/`x2` are **clamped to [0, 1]**; `y1`/`y2` are unrestricted. The four arguments are numbers in the *Float formatting* form, comma-separated, no spaces. |
| `hold` | `0` for `p < 1`, `1` at `p = 1` — the segment holds the starting key's value, then steps to the ending key's value at the segment's end. |

Notes:

- **`cubic-in` is `p³`, not `p²`.** In particular it is *not* the
  same curve as `in`, and not any host's `EaseIn` unless that is
  also `p³`. Close is wrong (§3.7 of the plan).
- **One canonical spelling per curve.** Source-language aliases
  (`slowly` ≡ `out`, `gently` ≡ `cubic-in-out`, `ease-in`,
  `ease-in-out`, …) are normalised by the compiler before
  emission and never appear in the IR.
- New ease names are additive (no `ir_version` bump); see the
  unknown-ease rule below for how old readers treat them.

### Attachment: easing belongs to the key the segment ENDS at

The `ease` on a key governs the segment **from the previous key to
this key**. This is Forge3D's frozen keyframe semantics and it wins
over host convenience. The first key of a track has no incoming
segment: its `ease` is emitted as `"linear"` and readers ignore it.

A host whose own convention attaches easing to the key a segment
*starts at* converts **once, at import**, by shifting each
segment's ease one key earlier. That shift is the only easing move
a reader may perform; readers never move easing between keys for
any other reason.

### Unknown or malformed ease

A reader that meets an ease name it does not know — or a malformed
`bezier(…)` string — evaluates that segment as `linear` **and
records a diagnostic**. The fallback is mandatory; the silence is
forbidden.

---

## Float formatting

Timeline IR reals are formatted **exactly as the existing JSON
emitter formats them** (`fmt_real` in `compiler/src/f3dc_str.f90`,
used by `json_real`/`json_dumps` in
`compiler/src/f3dc_emit_common.f90` — the Python `repr(float)`
mirror), with the two Timeline normalisations below. The rule:

1. **Shortest round-trip decimal.** The digit string is the
   shortest correctly-rounded decimal that round-trips to the
   exact same IEEE-754 binary64 value (the emitter searches
   precisions 1–17 digits and takes the first that round-trips).
2. **Notation.** Let the value be `d.ddd × 10^dec_exp` (`dec_exp`
   = exponent of the first significant digit). If
   `−4 ≤ dec_exp < 16`, fixed notation is used; otherwise
   scientific notation `d.ddde±XX` — exponent sign always present,
   exponent padded to at least two digits. No locale separators:
   the decimal point is always `.`, and no thousands separators
   ever appear.
3. **Whole-valued reals are emitted as JSON integers** — `48`,
   never `48.0`. (The emitter's integral branch: a real whose
   value is a whole number is written with the integer formatter.)
4. **`-0.0` is normalised to `0`** — negative zero never appears
   in the file.
5. **Non-finite values never appear.** `NaN` and `±Inf` are not
   valid JSON numbers in this format and are never emitted; a
   value that would be non-finite is a compile-time validation
   error, not an output.

Integers (frames, `fps` parts, colour components, counts) are
plain JSON integers with no decimal point, as everywhere in
Forge3D's JSON output.

---

## Text rules

- The file is **UTF-8, no BOM**. Readers reject or strip nothing —
  a BOM is a malformed file, not a variant.
- **Dialogue text is byte-verbatim from the `.f3d` source.** No
  Unicode normalisation, no whitespace trimming or collapsing, no
  case folding — by either the emitter or any reader. Bengali (or
  any Unicode) dialogue needs no escaping beyond JSON's own string
  rules.
- Names (`name`, marker `name`, speaker display names) follow the
  same byte-verbatim rule.
- JSON string escaping in emitted files follows the existing
  emitter (the quote, backslash and control characters `< 0x20`
  are escaped; non-ASCII bytes pass through as raw UTF-8).

## ID rules

- Every `id` (`characters[].id`, `scenes[].id`, `dialogue[].id`)
  is a **source-derived slug**: derived deterministically from the
  source name by lower-casing it, replacing every maximal run of
  characters outside `[a-z0-9]` with a single `-`, and stripping
  leading/trailing `-`. Example: scene `"Gate One"` → `"gate-one"`.
- Ids are **stable across recompiles** of the same source — the
  same source name always yields the same id.
- **No generated UUIDs, timestamps or random ids** appear in any
  normative position (the `generator` provenance block included).
- Ids are unique within their collection. Two distinct source
  names that would slug to the same id are a compile-time error —
  the emitter never silently renames.

---

## Determinism

### What the emitter pins

| Pinned by the emitter / file | Rule |
|---|---|
| fps | In-file rational `{num, den}`. Never assumed, never defaulted. All frame arithmetic is integer. |
| Frame spans | Integers, half-open `[start, end)`. No float time is normative anywhere. |
| Easing evaluation | The named-ease formulas and the `bezier(…)` solver are part of this spec, including edge rules (progress clamped to [0, 1]; bezier x clamped; malformed/unknown → `linear` + diagnostic). |
| Loop mapping | `once` = clamp; `forever` = `modulo(max(t, 0), D)`, exact multiples → 0; `pingpong` = triangle over `2D` — copied verbatim from the frozen `keyframe.f90` semantics. (Loop modes appear on `verb` spans and plugin action parameters.) |
| Key ordering | Emitter sorts by frame; equal-frame keys are a compile-time validation error (no reader tie-break to invent). |
| Float formatting | The spec'd format in *Float formatting* above; no locale separators; no `NaN`/`Inf` (validation error); `-0.0` normalised to `0`; whole values emitted as JSON integers, never `48.0`. |
| Text | UTF-8, no BOM, dialogue byte-verbatim; no Unicode normalisation by either side. |
| IDs | Source-derived slugs, stable across recompiles; no generated UUIDs in normative positions. |

**Byte determinism:** same compiler + same source ⇒ bit-identical
`.timeline.json` bytes, hash-testable. This is a release gate, not
an aspiration (ANIM-PLAN §5.3).

### What the host must NOT re-interpret

1. Re-expand symbolic actions with its own library in place of the
   resolved keys.
2. Re-derive timing from seconds, its own project fps, or
   `t_seconds` — a rate change is one documented resample at
   import, nothing else.
3. Re-sort, dedupe, or merge keys/cues, or move easing between keys
   except the single specified ends-at → starts-at conversion.
4. Substitute its own easing formulas (`cubic-in` is `p³`, not a
   host `EaseIn` `p²` — close is wrong).
5. Apply host-authoring rules (e.g. a host's log-space zoom rule)
   to IR camera keys — projection happens once at import, after
   which the keys are host data.

### The precision boundary, stated honestly

Forge3D evaluates in `f64` (IEEE-754 binary64); a host model may be
`f32` (StykAnimate's is). Bit-identical *bytes* are promised for
the IR file itself (above). Bit-identical *rendered frames* across
the language boundary are promised **only** to the extent that the
importer converts `f64 → f32` **once, at import,
round-to-nearest** — after which the host's existing deterministic
`f32` pipeline owns playback. No stronger cross-language claim is
made.

---

## Reader obligations

A conforming reader:

1. **Checks the discriminator first.** `format` must equal
   `"forge3d-timeline"`. Any other value — including
   `"forge3d-scene"` — is a rejection. **Missing `format` is an
   error, not a default.**
2. **Gates on `ir_version` exactly.** It accepts exactly the
   `ir_version`s it implements and rejects any other with an error
   **naming the version found**. **Missing `ir_version` is an
   error, not a default.**
3. **Ignores unknown keys at every level** — top level, records,
   keys, `params`, `generator`. Unknown keys are forward
   compatibility within a version, never an error. (The one
   exception is `rig`, which is not "unknown keys" but a
   plugin-owned value: see Character.)
4. **Skips unknown track kinds WITH a diagnostic.** An unknown
   `kind` in `tracks` is skipped and reported (in the host's
   import/unmapped report or equivalent) — never a crash, never a
   silent drop.
5. **Applies the unknown-ease rule**: unknown or malformed ease →
   `linear` + a diagnostic (see *Easing*).
6. **Reports the unresolvable**: any track with `"resolved":
   false`, any character whose `plugin` it does not know, and any
   data it cannot map (e.g. depth or out-of-plane rotation for a
   2D host) is listed in its import/unmapped report — never
   approximated, faked or silently dropped.
7. **Trusts frames, not seconds** (see *Frames and fps*), and
   performs the documented one-time conversions (fps resample,
   easing shift, `f64 → f32`) at import only.
8. **Treats the IR as read-only import input**, never as its
   working format. Round-tripping IR → host project → IR is not
   promised in v1.

## Emitter guarantees

A conforming emitter (in practice: `f3dc`):

1. **Canonical key order**: object keys are written in
   alphabetical order, at every level.
2. **Array ordering**:
   - `scenes` in timeline order (ascending `start_frame`);
   - `tracks` sorted by `(scene, kind, character/target,
     start_frame)` — by scene id, then kind, then the track's
     `character` (or `target` for object tracks; camera tracks,
     which have neither, sort with an empty character/target
     component), then `start_frame`;
   - `keys` within a track sorted by `frame`;
   - `characters`, `dialogue` and `markers` in source/timeline
     order (dialogue and markers ascending by `start_frame` /
     `frame`).
3. **Equal-frame keys are a compile-time error.** Two keys at the
   same frame in one track (for `action` tracks: same frame *and*
   same `channel`) never reach the file — the evaluator never
   sorts and no reader tie-break exists, so the emitter must
   guarantee the order.
4. **No timestamps, UUIDs or random values** anywhere in the file,
   including `generator`; ids are source-derived slugs (see *ID
   rules*).
5. **Floats and text** exactly per *Float formatting* and *Text
   rules*; the compiler never emits an empty-text dialogue cue
   (a diagnostic instead).
6. **Always writes `format` and `ir_version`.**

---

## Versioning and migration

Timeline IR is a sibling format under the ADR-3 regime, recorded
as ADR-5, with its own `format` string and its own `ir_version`
counter starting at 1. Neither this format's version nor the scene
format's bumps for the other's changes; a timeline pins its
scenes' versions per SceneSpan (`scene_ir_version`).

1. **Field stability within an `ir_version`:** no key is removed,
   renamed, re-typed, re-meaninged, or given a different default.
   Ever.
2. **Additive-only evolution:** adding a new optional key, a new
   track kind, a new ease name, or a safely-skippable enum value
   is **not** breaking and does not bump `ir_version`. Old readers
   already handle all four safely (ignore / skip-with-diagnostic /
   linear-with-diagnostic), by the obligations above.
3. **Bump discipline:** a breaking change bumps `ir_version` by
   **exactly 1**, with **migration notes in the changelog**
   describing what changed, what readers must do, and what happens
   to files written under the previous version. A downgrade target
   (an emitter option to write an older `ir_version`) is added
   only if a real consumer needs it.
4. **Exact-version readers:** as in *Reader obligations* point 2 —
   accept exactly the implemented versions, reject others naming
   the version found; missing `format` or `ir_version` is an
   error, not a default.
5. **The host's half of "stable":** hosts treat the IR as
   read-only import input (see *Reader obligations* point 8), so
   a version bump is an importer change on the host side, never a
   data migration of host projects.

**Migration procedure for a future bump** (e.g. 1 → 2): the
changelog entry names the breaking change and the mechanical
transform, if any, from v1 files; readers that implement v2 state
explicitly whether they also accept v1 (a reader *may* implement
several versions — it must accept exactly the set it implements,
no more); the conformance kit gains v1 fixtures that must still
read (or be rejected with the named-version error, per the bump's
notes) alongside the v2 fixtures.
