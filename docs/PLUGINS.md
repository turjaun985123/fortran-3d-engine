# Forge3D Plugins — rigs, actions and channel vocabularies

Forge3D's core language, compiler and Timeline IR are rig- and
character-type agnostic. Character rigs, action verb sets,
character prop schemas and feature capabilities register as
**plugins** in the compiler's plugin registry
(`compiler/src/f3dc_plugins.f90`). The core never hardcodes a
plugin's vocabulary: it asks the registry.

## The plugin model

A plugin declares:

| Declaration | Meaning |
|---|---|
| `id` | Stable identifier (`"stickman"`). Recorded on every Timeline IR Character as `plugin`. |
| `rig` | Plugin-owned rig description, carried opaquely into the IR Character's `rig` object. |
| `channels` | The generic channel ids its verbs animate (`body`, `face`) — used for overlap checks (E207) and reported on action tracks. |
| `verbs` | Its action verb set. Every spelling (canonical "-s" form and base-form alias) maps to the generic channel the verb animates and to a **template id**. |
| `template id` (per verb) | Which resolver template turns the verb into resolved keys. `0` / none = the verb stays **unresolved**: the IR track carries `resolved: false` and no `keys`, and hosts must report it as unmapped, never approximate it. |
| `rig_channels` | The published rig-channel vocabulary (below): the per-channel key names a resolved action track may carry, each with its value form (`deg` → emitted as `value_deg`, otherwise `value`). |
| prop schema | Character prop name → kind (`flag` / `enum` / `word` / `free` / `number` / `colour` / `itemcolour`), so character-line parsing and validation are data-driven. |
| `caps` | Named capabilities other stages ask about instead of hardcoding rules (e.g. `speaks`: characters of this plugin may speak dialogue, E211). |

Registration is lazy and idempotent: every registry query
populates the built-ins exactly once, so all entry points
(build / check / fmt) see the same registry. The first
registered plugin is the default for characters that name none.

**Resolution** (Wave 3): the Timeline IR emitter calls the
action resolver (`compiler/src/f3dc_anim_resolve.f90`) once per
action track, in timeline order per scene. The resolver keeps a
per-character **root cursor** (position + current `face.expr`),
reset per scene to the character's declaration position and
declared starting expression; movement templates move the
cursor, so consecutive cues chain (walk → wave happens *there*).
Templates are span-relative: keys sit at fractions of
`[start_frame, end_frame]`; the cue's ease applies to the
primary movement end-keys; oscillation keys ease `smooth`;
cycle counts derive from the span in seconds
(`span_frames × fps_den / fps_num`). Resolved keys are sorted
by (frame, channel); a repeated (frame, channel) keeps the last
key. Core verbs (`spin`, `bob`, `pulse`, `orbit`, `move`,
`turn`, `grow`) are **not** plugin templates — on characters
they stay unresolved, exactly as before.

Custom actions never reach the resolver: desugar has already
expanded them into built-in cues.

## The stickman plugin (`stickman`)

Rig: `{"kind": "stick", "topology": "humanoid11"}`.
Channels: `body`, `face`. Capabilities: `speaks`.
Character props: `proportions` (`tall` / `short` / `kid`),
`height`, `head`, `hair`, `face`, `wears`, `holds`.

### Rig-channel vocabulary

| Channel | Form | Meaning |
|---|---|---|
| `root.x`, `root.y`, `root.z` | value | Root position, world units |
| `root.face` | value_deg | Yaw facing offset |
| `torso` | value_deg | In-plane torso tilt |
| `head.pitch`, `head.yaw` | value_deg | Head pitch / yaw |
| `arm.l.upper`, `arm.l.fore` | value_deg | Left upper arm / forearm |
| `arm.r.upper`, `arm.r.fore` | value_deg | Right upper arm / forearm |
| `leg.l.thigh`, `leg.l.shin` | value_deg | Left thigh / shin |
| `leg.r.thigh`, `leg.r.shin` | value_deg | Right thigh / shin |
| `face.expr` | value | Expression code: 0 neutral, 1 happy, 2 sad, 3 determined, 4 surprised |

**Angle convention:** 0 = the limb hanging straight down;
positive rotates the down-vector toward the character's right
(+u in the figure plane). A right-arm raise (wave) is
`arm.r.upper → +150`; a left-arm raise is `arm.l.upper → −150`.

### Template table (as implemented, Wave 3 S1)

All 20 stickman verbs have templates. Span-relative fractions
are of the cue's `[start_frame, end_frame]`.

| Verb | Template |
|---|---|
| `walk` | root.x/z: cursor → `to` position (cue ease on end keys); gait cycle 1.8 Hz: thigh swing ±28° antiphase, shin bend 0–40° trailing, arm swing ∓18° opposite the same-side leg, root.y bob 0.05. Cursor moves to the target. |
| `run` | As walk, at 2.6 Hz with thigh ±40°, arm ±28°, bob 0.07. |
| `enter` | root.x/z: declaration position offset by the `from` side (left: x−6, right: x+6) → declaration position, plus the walk gait. Cursor ends at the declaration position. |
| `exit` | root.x/z: cursor → cursor + side offset (`direction` param, default right), plus the walk gait. Cursor moves. |
| `wave` | Arm from `arm` / authored `hand` param (default right; `both` = both arms): upper → ±150 at fraction 0.2 (cue ease), held to the end; forearm oscillates ±25 for `cycles` cycles (param, else max(1, round(span s × 1.2))). |
| `sit` | root.y → 0.5 (seat height); thighs → −90, shins → +90, torso → +5; cue ease on end keys. Cursor y becomes 0.5. |
| `stand` | root.y → declaration ground y; legs leave the sit pose (thigh −90 / shin +90 / torso +5) for 0. Cursor y restored. |
| `jump` | root.y parabola peaking at cursor y + 0.55 at fraction 0.5; legs tuck mid-span (thigh −30, shin +55); both arms raise mid-span (upper ±150). |
| `fall` | torso → 88, root.y → 0.1, legs slight bend (thigh −10, shin +15); ease `cubic-in`. Cursor y becomes 0.1. |
| `sleep` | torso → 80 slowly (`cubic-in-out`), head.pitch → 15. |
| `dance` | 2 Hz cycles: arms alternate raised/rest (right +150↔0, left −150↔0), torso ±8, root.y bounce 0.06, thighs alternate ±20, head.yaw ±10. |
| `nod` | head.pitch 0 → 18 → 0, 2 cycles. |
| `shake` | head.yaw 0 → −20 → 20 → 0. |
| `look` | head.yaw → ±25, sign of (target.x − character.x); target from the `target` param (position, or a character name resolved to its declaration position). Unresolvable without a target position. |
| `point` | The arm on the target's side raises (right +90 / left −90); head.yaw → sign × 15. Unresolvable without a target position. |
| `face` | With an `expression` param: an expression change (below). Otherwise root.face → yaw toward the target, `atan2(dx, dz)` in degrees clamped to ±180, computed from positions with the default camera at +Z; target `camera` → 0. |
| `smile` | Expression change to happy (1). |
| `pick` | Mid-span: torso +25, arm.r.upper +60 (settling to +20 at the end), root.y dips to ×0.85. |
| `give` | Mid-span: both arms' upper +70, torso +10; returning by the end. |
| `tap` | leg.r.thigh oscillates between −12 and 0 at 3 Hz. |

**Expression changes** (`smile`, and `face` with an expression
param) emit a single `face.expr` key at `start_frame` with the
new code, plus an end key with the same value easing `hold`;
the expression cursor moves, so later cues inherit it.

### Identity in the IR

A Character record gains an optional `identity` object when
the declaration carries any of `head`, `hair`, `face`,
`wears`, `holds` — copied verbatim from the declaration. It is
omitted when the declaration carries none of them. (Additive
under ADR-5: older readers ignore it.)

## The humanoid plugin (`humanoid`) — skeleton

Registered as a **skeleton** proving the registry is
plugin-shaped, not stickman-shaped:

- Rig: `{"kind": "humanoid", "topology": "humanoid11"}`.
- Channels: `body`, `face`. Capabilities: `speaks`.
- The same 20-verb set as stickman — with **no templates**, so
  humanoid actions stay `resolved: false` in the IR.
- **No rig channels** published (empty vocabulary).
- Character props: `proportions` / `height` only.

A future slice can give humanoid its own channel vocabulary
and templates without touching the core or the stickman
plugin.
