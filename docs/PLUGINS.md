# Forge3D Plugins — external packages: rigs, actions and channel vocabularies

Forge3D's core language, compiler and Timeline IR are rig- and
character-type agnostic. Character rigs, action verb sets,
character prop schemas and feature capabilities are declared by
**plugins**. Since the user ruling of 2026-11-26
(`docs/ANIM-WAVES.md`, "Plugin externalization"), a plugin is an
**external package on disk**, loaded by the compiler at run time:

```
plugins/<id>/plugin.json
```

The core keeps only the **loader + registry mechanism** and the
**template interpreter** (`compiler/src/f3dc_plugins.f90`,
`compiler/src/f3dc_anim_resolve.f90`). No plugin's data — no verb,
channel, prop, expression name, rig record or template constant —
remains in core source. This document is the design of record for
that externalization (Wave 5, slice E1): §1 inventories everything
that moves out, §2–§3 define the package format and schema, §4
the loader semantics, §5 the missing-plugin diagnostic, §6 the
per-module migration map, §7 the Timeline IR verdict.

The registry *query* surface the rest of the compiler uses does
not change: parser, desugar, validator and emitter keep calling
`plugin_default_id`, `plugin_verb_channel`, `plugin_prop_*`,
`plugin_capability`, `plugin_rig`, `plugin_rig_channel_*` and
friends. Only where the answers come from changes: a package
file, not a registration block compiled into the binary.

---

## 1. Inventory — everything that must move out

### 1.1 Registry data in `f3dc_plugins.f90` (`ensure_plugins`)

Two plugins are registered as data tables today.

| Declaration | stickman | humanoid |
|---|---|---|
| rig record (dyn dict) | `{"kind":"stick","topology":"humanoid11"}` (2 keys) | `{"kind":"humanoid","topology":"humanoid11"}` (2 keys) |
| channels | 2 (`body`, `face`) | 2 (`body`, `face`) |
| capabilities | 1 (`speaks`) | 1 (`speaks`) |
| verb entries | 20 canonical verbs × 2 spellings ("-s" form + base alias) = **40 entries** | 40 entries, same verb set |
| verb → channel | `face`, `smile` → `face`; other 18 → `body` | identical |
| verb → template | 20 distinct template ids (TPL_WALK…TPL_EXIT = 1…20) | all 40 entries TPL_NONE (unresolved by design) |
| rig channels | **16** (13 `deg`, 3 `value`) | 0 |
| prop records | **9 records / 7 distinct props** | **4 records / 2 distinct props** |

Totals across both plugins: **80 verb entries, 16 rig channels,
13 prop records, 2 rig records, 4 channel entries, 2 capability
entries** — all of it moves to package files.

The stickman rig-channel vocabulary (16):

`root.x` (value), `root.y` (value), `root.z` (value),
`root.face` (deg), `torso` (deg), `head.pitch` (deg),
`head.yaw` (deg), `arm.l.upper` (deg), `arm.l.fore` (deg),
`arm.r.upper` (deg), `arm.r.fore` (deg), `leg.l.thigh` (deg),
`leg.l.shin` (deg), `leg.r.thigh` (deg), `leg.r.shin` (deg),
`face.expr` (value; 0 neutral, 1 happy, 2 sad, 3 determined,
4 surprised).

Angle convention (plugin documentation, carried in the package's
own docs, not core): 0 = limb hanging straight down; positive
rotates the down-vector toward the character's right. A right-arm
raise is `arm.r.upper → +150`, a left-arm raise `arm.l.upper →
−150`.

The prop records. A record is `(name, kind, surface, allowed,
multi, lower)`; `kind` ∈ {`flag`, `enum`, `word`, `free`,
`number`, `colour`, `itemcolour`} (7 kinds — the schema in §3
must support all 7, plus the `surface` word, the `allowed` list
for closed kinds, and the `multi` / `lower` booleans):

| Plugin | Records |
|---|---|
| stickman | `proportions` flag ×3 (surfaces `tall`/`short`/`kid`), `height` number, `head` enum (`round,square,oval`), `hair` word, `face` enum (`happy,sad,determined,surprised,neutral`), `wears` itemcolour (multi), `holds` free (lower=false) |
| humanoid | `proportions` flag ×3 (`tall`/`short`/`kid`), `height` number |

### 1.2 The expression-code map — duplicated in TWO core modules

The map `neutral→0, happy→1, sad→2, determined→3, surprised→4`
(5 entries) exists **twice** outside `f3dc_plugins.f90`:

- `expr_code` in `f3dc_anim_resolve.f90` (used by the `face`
  template's expression branch);
- `expr_code_of` in `f3dc_emit_timeline.f90` (used for a
  character's declared starting `face`, via `char_decl`).

Both copies are stickman vocabulary in core source. The package
schema therefore includes an `expression_codes` object (§3), and
core gains one generic query, `plugin_expression_code(id, name,
code, found)`, backed by package data. Humanoid declares no
`expression_codes` (it has no `face` prop); lookups against it
report not-found and the starting expression stays 0, exactly as
today.

### 1.3 Template constructs in `f3dc_anim_resolve.f90`

The resolver holds 20 named templates (one subroutine or inline
block per verb) built from **93 direct `add_key` calls and 29
`add_key_f` (fraction) calls**, 7 `osc` call sites, and 3 further
inline sampling loops. Every construct they use is catalogued
here; §3's schema covers each one.

**Key shapes.** A key is `(frame, channel, value, ease)` where
the frame is either the span start/end or a fraction of
`[start_frame, end_frame]` (frame = `sf + nint(frac × (ef−sf))`).
Fractions used: 0, 0.2, 0.25, 1/3, 0.5, 2/3, 0.75, 1, plus
sampled grids (below). Whether a key is emitted as `value` or
`value_deg` is decided by the channel's published form — already
registry data, not template data.

**Eases used.** The cue's own ease (`w_ease`, defaulting to
`linear` when empty) on primary end keys, plus five literals:
`linear`, `smooth`, `cubic-in`, `cubic-in-out`, `hold`. All
spellings pass through the core `ease_canonical` authority.

**Value forms** (every form that appears as a key value):

1. Numeric literals (angles, heights: −150…150, 0.5, 0.1, 88, …).
2. Cursor state: `cursor.x/y/z` (e.g. start keys, `pick`'s
   `cursor.y × 0.85`).
3. Declaration position: `decl.x/y/z` (`enter`'s target, `stand`'s
   ground y).
4. Destination params: `to` / `target` resolved to a vec3 — the
   param may be a `<key>_pos` vec, a direct vec, or a **character
   name looked up among the scene's declared characters**
   (`dest_pos`/`lookup_other`).
5. String params, lower-cased: `from`, `direction`, `arm`, `hand`,
   `expression`.
6. Numeric params: `cycles` (int or real).
7. Span-derived values: `span_sec = (ef−sf) × fps_den / fps_num`;
   cycle counts `max(1, nint(span_sec × hz))` for hz ∈ {1.8, 2.6,
   3.0, 2.0} and `max(1, nint(span_sec × 1.2))` (wave default).
8. Arithmetic over the above: `+ − × ÷`, parentheses, unary
   minus, scaling of a sign variable (`sgn × 90`).
9. Functions: `sin`, `cos`, `abs` (sampled generators, below);
   `atan2(dx, dz) × 180/π` clamped to ±180 (`face`); `nint`,
   `max`, `min`.
10. Conditionals / selection:
    - string equality on a param (`from`/`direction` = left/right
      → offset −6/+6; any other value → **unresolved**);
    - arm selection (`arm`, falling back to `hand`, default
      `right`; `both` expands to both arms; unknown → unresolved);
    - sign of a comparison (`target.x` vs `cursor.x` → −25/0/+25
      in `look`; in `point` the same comparison also **selects
      the channel** `arm.l.upper` vs `arm.r.upper`);
    - presence of a param (`face`: `expression` present →
      expression branch);
    - name equality (`face`: target name `camera` → yaw 0);
    - absence fallback (`face`: neither `target` nor `target_pos`
      present at all → yaw 0; present but unresolvable →
      unresolved).
11. The expression-name → code map of §1.2 (`face` branch,
    `smile` = code 1).

**Sampled generators** (keys generated on a grid, not listed):
the grid is always `steps = max(4 × cycles, 1)`, one key per
`i = 0..steps` at fraction `i/steps`, ease `smooth`.

- `osc(channel, base, amp, cycles, phase)`: value =
  `base + amp × sin(2π × cycles × frac + phase)`. 7 call sites:
  6 inside `gait` (phases 0, 0, −π/2, +π/2, 0, 0) and 1 in `tap`
  (base −6, amp 6, 3 Hz).
- `gait(cycles, thigh_amp, arm_amp, bob_amp, base_y)`: a
  composite — the 6 `osc` calls above (thighs antiphase via
  negated amp, shins base 20 amp 20 phase-shifted, arms negated
  opposite the same-side leg) **plus** a `root.y` bob loop with
  value `base_y + bob_amp × (0.5 − 0.5 × cos(2 × 2π × cycles ×
  frac))`. Used by walk (1.8 Hz, ±28, ±18, 0.05), run (2.6 Hz,
  ±40, ±28, 0.07), enter and exit (walk's numbers).
- `wave_arm` forearm loop: `osc`-shaped but windowed to
  fractions 0.2…1.0 and phased by step index (value
  `25 × sin(2π × cycles × i/steps)`).
- `dance` loop: 7 channels sampled from one `s = sin(2π × cycles
  × frac)` per step: `arm.r.upper = 75 + 75s`,
  `arm.l.upper = −75 + 75s` (note: **not** negated as a whole —
  the encoding must reproduce this asymmetry byte-for-byte),
  `torso = 8s`, `leg.l.thigh = 20s`, `leg.r.thigh = −20s`,
  `head.yaw = 10s`, `root.y = cursor.y + 0.06 × |s|`.
- `jump` root.y: 5 listed keys whose value is the parabola
  `cursor.y + 0.55 × 4 × f × (1 − f)` at f = 0, .25, .5, .75, 1 —
  i.e. a key value that depends on **the key's own fraction**.

**Cursor side effects** (applied only on success; on failure the
cursor and expression are untouched and the track stays
`resolved: false`):

| Verb(s) | Effect |
|---|---|
| walk, run | cursor.x/z := destination |
| enter | cursor := decl |
| exit | cursor.x += side offset |
| sit | cursor.y := 0.5 |
| stand | cursor.y := decl.y |
| fall | cursor.y := 0.1 |
| smile, face (expression branch) | expr := new code |
| all others | none |

**Failure (unresolved) conditions:** no template for the verb;
`ef ≤ sf`; missing/unresolvable destination (`walk`/`run` without
`to`, `look`/`point` without `target`); unknown side string
(`enter`/`exit`); unknown arm string (`wave`); unknown expression
name (`face`).

**Generic mechanism already in the resolver (stays in core):**
key emission with `value`/`value_deg` selection, `snap()`
(near-integer snapping, −0.0 normalisation), `frame_at`,
`finish_keys` (sort by (frame, channel), de-duplicate keeping
the last key, strip the internal order field, force the first
key's ease to `linear`), destination lookup, param access, the
per-character cursor plumbing owned by the emitter.

### 1.4 Constructs that cannot be a flat key list — and their resolutions

Nothing in §1.3 may silently stay in core as stickman-specific
code. The five constructs that exceed a literal key list, and
the **generic** mechanism that expresses each as data:

1. **Sampled oscillation** (osc / gait / dance / wave forearm /
   tap) → an `osc` **step kind** in the schema with `waveform` ∈
   {`sin`, `abs_sin`, `bob`} (§3). `gait` needs **no** primitive
   of its own: it is exactly 6 `sin` osc steps + 1 `bob` osc
   step. `dance` is 7 osc steps. This keeps `sin`/`cos`/`abs`
   *inside* the generic sampler — they are not expression
   functions.
2. **Destination / name lookup** (`to`, `target`) → destination
   references in the expression language: `dest(param).x/y/z`
   and the condition `dest_found(param)`. The lookup itself
   (vec param, `<key>_pos`, character-name resolution) is the
   existing generic `dest_pos` mechanism.
3. **Facing angle** (`face`) → two expression functions,
   `atan2_deg(a, b)` (= atan2 in degrees) and `clamp(v, lo, hi)`.
   These are the only functions the inventory proves the
   expression language needs beyond `min`/`max`/`nint`.
4. **Sign / side / channel selection** (`look`, `point`, `enter`,
   `exit`, `wave`, `face` branches) → **guarded step groups**:
   a step group carries a `when` condition (§3); groups whose
   condition is false are skipped. `point`'s dynamic channel
   becomes two guarded groups with concrete channel names.
   Template-level `requires` conditions reproduce the
   unresolved-on-bad-input semantics, and `fail_if_empty`
   reproduces `face`'s final fallback.
5. **Expression-name → code map** → the package's
   `expression_codes` data (§1.2), exposed to expressions as
   `expr_code(param.expression)` and to core as
   `plugin_expression_code`.

**Conclusion: zero constructs require stickman-specific code to
remain in core.** Everything above is a plugin-agnostic
mechanism (sampler, evaluator, guards, lookup) interpreting
package data.

---

## 2. Package format — decision

> **ADR-PLUGIN-1 (Wave 5, slice E1).** A plugin package is a
> directory `plugins/<id>/` whose single manifest+declarations
> file is **`plugin.json`** (JSON). The compiler parses it with
> the existing JSON machinery, `f3dc_ir.ir_json_parse`
> (JSON text → `dyn`), producing exactly the `dyn` structures
> the registry and the Timeline IR already traffic in.
>
> **Rationale.** (i) The compiler already owns a complete,
> tested JSON reader (`f3dc_ir`) and writer; the Timeline IR is
> JSON and the rig record is already a `dyn` dict carried
> opaquely — a JSON package makes the rig record a literal
> sub-tree of the package file, copied, never re-encoded.
> (ii) Zero-Python holds and no new parser is written, reviewed
> or fuzzed. (iii) A bespoke text format would need a new lexer,
> grammar, diagnostics and round-trip rules for zero expressive
> gain: every declaration in §1 is naturally a JSON object,
> array or string. (iv) Dependency check: `f3dc_plugins` is
> currently a leaf over `f3dc_dyn`/`f3dc_str`; `f3dc_ir` depends
> only on `f3dc_dyn`/`f3dc_str`/`f3dc_errors`, none of which
> depend on `f3dc_plugins` — so `f3dc_plugins → f3dc_ir` is
> acyclic and the module stays usable by every existing caller.
> (The private parser inside `f3dc_compat` was rejected: it is
> module-private and shaped for compat-file reading.)
>
> **Consequence.** Template bodies are JSON data (§3); the
> per-verb `TPL_*` integer constants in `f3dc_plugins` and the
> 20 template subroutines in `f3dc_anim_resolve` are deleted and
> replaced by one generic interpreter.

Package layout:

```
plugins/
  stickman/
    plugin.json        <- the package (required, only required file)
  humanoid/
    plugin.json
```

The directory name must equal the manifest `id` (§4). A package
may carry further files (its own docs, examples) — the loader
reads only `plugin.json` and ignores the rest.

---

## 3. Package schema (`plugin.json`)

Top level (all keys required unless marked optional):

| Key | Type | Meaning |
|---|---|---|
| `format` | integer | Package-format version. This design is `1`. The loader accepts exactly `1` (§4). |
| `id` | string (slug) | Plugin id; must equal the directory name. |
| `version` | string | The plugin's own version (opaque; recorded in the registry, never compared by core). |
| `capabilities` | array of string | Named capabilities (`speaks`, …). May be empty. |
| `channels` | array of string | Generic channel ids its verbs animate (`body`, `face`). |
| `rig` | object \| null | Rig description, carried opaquely into the IR Character's `rig`. |
| `rig_channels` | array of `{"name","form"}` | Published rig-channel vocabulary; `form` ∈ {`deg`, `value`}. May be empty. |
| `expression_codes` | object string→number (optional) | Expression name → `face.expr` code (§1.2). Absent = the plugin has no expression vocabulary. |
| `props` | array of prop records | Character prop schema, in declaration order. |
| `verbs` | array of verb records | Action verb set. |
| `templates` | object string→template | Template bodies by template name. May be empty/absent. |

A **prop record**: `{"name", "kind", "surface", "allowed",
"multi", "lower"}` — `kind` one of the 7 kinds of §1.1;
`surface` the word that introduces the prop in a character line
(for `flag` records, the flag word itself; several records may
share one `name`); `allowed` the array of permitted words for
`enum` (empty otherwise); `multi` repeatable; `lower` value
stored lower-cased.

A **verb record**: `{"forms": ["walks","walk"], "channel":
"body", "template": "walk"}` — `forms` lists every spelling
(first = canonical); `template` is a key of `templates`, or
`null` for a verb that stays unresolved (humanoid's whole set).

### 3.1 Templates

A template is data interpreted by the generic resolver:

```json
{
  "param_defaults": { "direction": "right",
                      "cycles": {"expr": "max(1, nint(span_sec * 1.2))"} },
  "requires": [ <condition>, ... ],
  "steps": [ <step>, ... ],
  "cursor": { "x": "dest(to).x", "y": 0.5, "expr": "expr_code(param.expression)" },
  "fail_if_empty": false
}
```

**Amendment (Wave 5 implementation, coordinator ruling):** `cursor`
has a second form — a LIST of guarded entries
`[{"set": "cursor.x", "expr": "cursor.x - 6", "when": <condition>}, ...]`
— for updates whose value depends on a param (the `exit` template's
±6 side offset is the motivating case). Entries apply in order;
`when` uses the §3.3 condition grammar; an entry without `when`
applies unconditionally. The flat map form above remains valid and
is sugar for unconditional entries. Both forms are interpreted by
the same generic resolver; no verb-specific code exists for either.
A related data rule, proven by the Wave 5 differential harness:
guard groups in a template must reproduce the old code's branch
exclusivity exactly (e.g. `face`'s expression branch returns early,
so its yaw groups carry `not(param_present expression)` guards).

- `param_defaults` (optional): a param's default when the cue
  does not supply it — a JSON literal, or `{"expr": "..."}`
  evaluated in declaration order (so `arm` may default from
  `param.hand`). This reproduces `wave`'s arm fallback and cycle
  default, and `exit`'s default direction.
- `requires` (optional): conditions (§3.3) that must **all**
  hold or the template is unresolved (cursor untouched).
- `steps`: an ordered list of step objects, each optionally
  guarded by `"when": <condition>` (false → step skipped).
- `cursor` (optional): updates applied on success only; keys are
  `x`, `y`, `z`, `expr`; values are numbers or expression
  strings. Absent key = component unchanged.
- `fail_if_empty` (optional, default false): if no step emitted
  any key, the template is unresolved. (`face` needs this.)

**Step kinds** (exactly two):

1. `{"keys": [ <key>, ... ]}` — explicit keys. A key:
   `{"channel": "root.x", "at": 0.5, "value": <number|expr-string>,
   "ease": "cue"}`. `at` is a fraction 0…1, or `"start"` /
   `"end"`. `value` is a JSON number or an expression string
   (§3.2). `ease` is `"cue"` (the cue's ease) or an easing name
   (canonicalised by core as today).
2. `{"osc": {...}}` — a sampled generator:
   `{"channel", "waveform", "base", "amp", "cycles", "phase_deg",
   "from", "to", "ease"}`. `waveform` ∈ {`sin`, `abs_sin`,
   `bob`}; value at fraction f is
   `base + amp × sin(2π·cycles·f + phase)` /
   `base + amp × |sin(2π·cycles·f)|` /
   `base + amp × (0.5 − 0.5·cos(4π·cycles·f))` respectively.
   `cycles` is `{"hz": 1.8}` (→ `max(1, nint(span_sec × hz))`)
   or `{"expr": "..."}`. `phase_deg` (default 0), `from`/`to`
   (default 0/1) window the grid; the grid is
   `steps = max(4 × cycles, 1)` keys at `from + (to−from) ×
   i/steps`, ease `smooth` unless overridden. `base`/`amp` are
   numbers or expression strings.

### 3.2 The expression mini-language

Deliberately minimal — the inventory (§1.3) is the ceiling:

```
expr    := term (("+" | "-") term)*
term    := factor (("*" | "/") factor)*
factor  := "-" factor | "(" expr ")" | number | ref | call
ref     := "cursor.x"|"cursor.y"|"cursor.z" | "decl.x"|"decl.y"|"decl.z"
         | "span_sec" | "f" | "pi"
         | "param." NAME | "dest(" NAME ")." ("x"|"y"|"z")
call    := "atan2_deg(" expr "," expr ")" | "clamp(" expr "," expr "," expr ")"
         | "min(" expr "," expr ")" | "max(" expr "," expr ")"
         | "nint(" expr ")" | "expr_code(" expr ")"
```

- `f` is the fraction of the key being built (jump's parabola);
  inside `osc` steps `base`/`amp` are evaluated once per template
  (they may not use `f`).
- `param.NAME` is the cue param as a number; a string param used
  in a numeric expression, a missing param with no default, an
  unknown `expr_code` name, or a missing `dest(...)` makes
  evaluation **fail**, and a failed evaluation makes the whole
  template unresolved — the existing failure semantics.
- String-valued params are compared through conditions (§3.3),
  never through expressions. Division is real division; the
  interpreter never traps — evaluation failure is a value, not
  a crash.
- No other surface exists: no variables, no assignment, no
  string arithmetic, no `sin`/`cos`/`abs` (they live inside
  `osc` waveforms, §1.4).

### 3.3 Conditions

A condition is a single-key object:

| Form | Meaning |
|---|---|
| `{"param_eq": ["from", "left"]}` | string param equals (params are lower-cased by the existing param access, as today) |
| `{"param_in": ["from", ["left","right"]]}` | string param is in the list |
| `{"param_present": "expression"}` | the cue supplied the param (or its `<name>_pos` form where the existing `dest_pos` checks it — `face`'s fallback tests `target`/`target_pos` via `not` + `any` below) |
| `{"dest_found": "target"}` | `dest_pos` resolves the param |
| `{"name_is": ["target", "camera"]}` | the param's authored name (when it was one) equals the string |
| `{"lt": [e1, e2]}` / `{"ge": [e1, e2]}` / `{"eq": [e1, e2]}` | numeric comparison of two expressions |
| `{"all": [c, ...]}` / `{"any": [c, ...]}` / `{"not": c}` | combinators |

### 3.4 Worked encodings (normative for the migration)

`walk` — destination keys + the gait expansion (7 osc steps):

```json
"walk": {
  "requires": [{"dest_found": "to"}],
  "steps": [
    {"keys": [
      {"channel":"root.x","at":"start","value":"cursor.x","ease":"linear"},
      {"channel":"root.x","at":"end","value":"dest(to).x","ease":"cue"},
      {"channel":"root.z","at":"start","value":"cursor.z","ease":"linear"},
      {"channel":"root.z","at":"end","value":"dest(to).z","ease":"cue"}]},
    {"osc": {"channel":"leg.l.thigh","waveform":"sin","base":0,"amp":28,"cycles":{"hz":1.8}}},
    {"osc": {"channel":"leg.r.thigh","waveform":"sin","base":0,"amp":-28,"cycles":{"hz":1.8}}},
    {"osc": {"channel":"leg.l.shin","waveform":"sin","base":20,"amp":20,"cycles":{"hz":1.8},"phase_deg":-90}},
    {"osc": {"channel":"leg.r.shin","waveform":"sin","base":20,"amp":20,"cycles":{"hz":1.8},"phase_deg":90}},
    {"osc": {"channel":"arm.l.upper","waveform":"sin","base":0,"amp":-18,"cycles":{"hz":1.8}}},
    {"osc": {"channel":"arm.r.upper","waveform":"sin","base":0,"amp":18,"cycles":{"hz":1.8}}},
    {"osc": {"channel":"root.y","waveform":"bob","base":"cursor.y","amp":0.05,"cycles":{"hz":1.8}}}
  ],
  "cursor": {"x": "dest(to).x", "z": "dest(to).z"}
}
```

`run` is `walk` with hz 2.6, amps ±40/±28, bob amp 0.07.
`enter`/`exit` reuse the same 7 osc steps; their root keys are
guarded groups (`param_eq from/direction = left` → offset −6,
`right` → +6) over `decl`/`cursor` bases, with
`requires: [{"param_in": ["from", ["left","right"]]}]` (enter)
and `param_defaults {"direction":"right"}` (exit).

`face` — all four branches of §1.3(10) as guarded groups:

```json
"face": {
  "steps": [
    {"when": {"param_present": "expression"},
     "keys": [
       {"channel":"face.expr","at":"start","value":"expr_code(param.expression)","ease":"linear"},
       {"channel":"face.expr","at":"end","value":"expr_code(param.expression)","ease":"hold"}]},
    {"when": {"name_is": ["target","camera"]},
     "keys": [
       {"channel":"root.face","at":"start","value":0,"ease":"linear"},
       {"channel":"root.face","at":"end","value":0,"ease":"cue"}]},
    {"when": {"dest_found": "target"},
     "keys": [
       {"channel":"root.face","at":"start","value":0,"ease":"linear"},
       {"channel":"root.face","at":"end","ease":"cue",
        "value":"clamp(atan2_deg(dest(target).x - cursor.x, dest(target).z - cursor.z), -180, 180)"}]},
    {"when": {"not": {"any": [{"param_present":"target"},{"param_present":"target_pos"}]}},
     "keys": [
       {"channel":"root.face","at":"start","value":0,"ease":"linear"},
       {"channel":"root.face","at":"end","value":0,"ease":"cue"}]}
  ],
  "cursor": {"expr": "expr_code(param.expression)"},
  "fail_if_empty": true
}
```

(The `cursor.expr` update applies only when the expression
group fired: a cursor update whose expression fails to evaluate
is skipped, not fatal — matching today's behaviour, where the
yaw branches never touch the expression cursor. `smile` is the
two `face.expr` keys with value `1` and `cursor.expr = 1`.)

Remaining verbs encode mechanically from §1.3: `nod`/`shake`/
`sit`/`stand`/`fall`/`sleep`/`pick`/`give` are single `keys`
steps (fractions and constants as catalogued; `pick`'s dip is
`"cursor.y * 0.85"`); `jump` is `keys` steps whose root.y values
use `"cursor.y + 0.55 * 4 * f * (1 - f)"`; `tap` is one `osc`
step (base −6, amp 6, hz 3); `dance` is 7 `osc` steps at hz 2
(arms base ±75 amp 75 — left arm base −75, amp **+75**, per
§1.3 — torso amp 8, thighs ±20, head.yaw amp 10, root.y
`abs_sin` base `cursor.y` amp 0.06); `wave` is three guarded
groups (arm right/left/both) each holding the raise keys
(fraction 0.2, ±150) plus a windowed `osc` (`from` 0.2, amp 25,
`cycles` from `param.cycles` via the template's param default);
`look` is three guarded `keys` groups on `dest(target).x` vs
`cursor.x` (`lt` → −25, `eq` → 0, `ge` → +25 — today's code
yields 0 only on exact equality, hence the `eq` form in §3.3);
`point` is two
guarded groups (`lt` → `arm.l.upper` −90 / head.yaw −15;
otherwise → `arm.r.upper` +90 / head.yaw +15 — today's code
takes the right arm whenever `target.x ≥ cursor.x`, so `ge`
is the exact guard).

### 3.5 The stickman package (declarations, abbreviated templates)

```json
{
  "format": 1,
  "id": "stickman",
  "version": "1.0.0",
  "capabilities": ["speaks"],
  "channels": ["body", "face"],
  "rig": {"kind": "stick", "topology": "humanoid11"},
  "rig_channels": [
    {"name":"root.x","form":"value"}, {"name":"root.y","form":"value"},
    {"name":"root.z","form":"value"}, {"name":"root.face","form":"deg"},
    {"name":"torso","form":"deg"}, {"name":"head.pitch","form":"deg"},
    {"name":"head.yaw","form":"deg"}, {"name":"arm.l.upper","form":"deg"},
    {"name":"arm.l.fore","form":"deg"}, {"name":"arm.r.upper","form":"deg"},
    {"name":"arm.r.fore","form":"deg"}, {"name":"leg.l.thigh","form":"deg"},
    {"name":"leg.l.shin","form":"deg"}, {"name":"leg.r.thigh","form":"deg"},
    {"name":"leg.r.shin","form":"deg"}, {"name":"face.expr","form":"value"}
  ],
  "expression_codes": {"neutral":0,"happy":1,"sad":2,"determined":3,"surprised":4},
  "props": [
    {"name":"proportions","kind":"flag","surface":"tall","allowed":[],"multi":false,"lower":true},
    {"name":"proportions","kind":"flag","surface":"short","allowed":[],"multi":false,"lower":true},
    {"name":"proportions","kind":"flag","surface":"kid","allowed":[],"multi":false,"lower":true},
    {"name":"height","kind":"number","surface":"height","allowed":[],"multi":false,"lower":true},
    {"name":"head","kind":"enum","surface":"head","allowed":["round","square","oval"],"multi":false,"lower":true},
    {"name":"hair","kind":"word","surface":"hair","allowed":[],"multi":false,"lower":true},
    {"name":"face","kind":"enum","surface":"face","allowed":["happy","sad","determined","surprised","neutral"],"multi":false,"lower":true},
    {"name":"wears","kind":"itemcolour","surface":"wears","allowed":[],"multi":true,"lower":true},
    {"name":"holds","kind":"free","surface":"holds","allowed":[],"multi":false,"lower":false}
  ],
  "verbs": [
    {"forms":["walks","walk"],"channel":"body","template":"walk"},
    {"forms":["faces","face"],"channel":"face","template":"face"},
    {"forms":["smiles","smile"],"channel":"face","template":"smile"}
    /* …all 20, per §1.1… */
  ],
  "templates": { "walk": { /* §3.4 */ }, "face": { /* §3.4 */ } /* …all 20… */ }
}
```

The humanoid package is the same shape with stickman's verb
list but `"template": null` on every verb, `rig_channels: []`,
no `expression_codes`, `templates` absent, and only the
`proportions`/`height` props. It ships as a skeleton package in
the same wave — its registry data leaves core with everything
else (its *depth* still arrives in Waves 19–24, per the ruling).

---

## 4. Loader semantics

**Search list (fixed interface).**

- If the environment variable `F3DC_PLUGIN_PATH` is **set**
  (present, whatever its value): the search list is its
  colon-separated entries, in order. The **empty string means
  an empty list — load nothing.** (This is how the
  absent-plugin proof of §8 runs.)
- If it is **unset**: the list is
  `[<repo_root>/plugins, ./plugins]` (current directory first
  resolved at process start).
- `<repo_root>` is resolved exactly as the compiler already
  resolves it for `runtime/` files: `driver_repo_root` in
  `f3dc_driver.f90` — take argv[0], make it absolute, resolve
  `.`/`..` textually, and return the parent of the binary's
  directory, so `<root>/compiler/f3dc` and `<root>/bin/f3dc`
  both yield `<root>` (falling back to the current directory
  when argv[0] is unusable). The CLI already calls
  `driver_repo_root` for the runtime family
  (`emit_html_runtime_js(root, …)`, the `RUNTIME_DEPS` hashing
  in `f3dc_cli`); the loader receives the same root.
- Nonexistent or non-directory entries are skipped silently
  (search-path tolerance, like `PATH`).

**Wiring.** `f3dc_cli`'s program entry resolves the root once
and calls `plugin_configure(root)` before dispatching any
command, so build / check / fmt / preview all see the same
registry. Inside `f3dc_plugins`, the existing lazy
`ensure_plugins()` becomes load-once: the first registry query
triggers the load if configuration happened; if no
configuration happened (a caller linked the modules directly),
the loader falls back to the `F3DC_PLUGIN_PATH`-or-`./plugins`
list. Loading is idempotent per process, as registration is
today.

**Enumeration and order.** Within each search directory, in
list order, the loader enumerates subdirectories
(lexicographic order by directory name, for determinism —
directory listing reuses the driver's command-capture helper,
the same shell-out precedent as `driver_is_dir`) and reads
`<dir>/<name>/plugin.json`. Load order = enumeration order.
The **default plugin** (`plugin_default_id`) is the first
successfully loaded plugin, preserving today's
first-registered-wins semantics.

**Duplicate id.** The first package with a given id wins; a
later package with the same id is skipped and reported with
**W205** (warning; §5). Directory name ≠ manifest `id` is a
malformed package (below), not a duplicate.

**Malformed packages — diagnostic, never crash.** A package is
skipped, with one W205 warning naming the package directory and
the reason, when: `plugin.json` is missing or unreadable; the
JSON does not parse; the top level is not an object; `id` is
missing or ≠ the directory name; `format` ≠ 1 (see version
handling); a required key has the wrong type; a verb names a
template that does not exist; a template body fails schema
validation (unknown step kind, unknown waveform, unparseable
expression — expressions are parsed once at load, so a bad
expression is a load-time W205, never a compile-time surprise).
A skipped package simply does not exist as far as the registry
is concerned; if a film then needs it, §5's E214 fires. The
loader never stops the process and never emits partial
registrations: a package registers whole or not at all.

**Version handling.** `format` is the only version core acts
on: exactly `1` loads; anything else is skipped with W205
("package format N is not supported by this compiler"). The
plugin's own `version` string is opaque metadata. There is no
minimum-version or range logic in v1 of the format.

**Registry limits.** The existing fixed caps (`MAX_PLUGINS`
16, `MAX_PROPS` 32 per plugin) stay as loader limits; exceeding
one is a malformed-package W205 for the overflowing package,
not a silent truncation (today's `add_prop` silently drops —
that behaviour does not survive the move).

---

## 5. Diagnostic — plugin not loaded: **E214**

**Code choice.** E2xx is the validator's names/references
family. In `f3dc_errors.f90`'s append-only table the family
currently ends at **E213** ("undefined/redefined variable");
E214 appears nowhere in `compiler/src` or the tests (grep
census-clean), and the next family starts at E301. **E214 is
therefore the next free E2xx code.** It is appended to the
table (title `plugin not loaded`, `N_CODES` 32 → 33) and to
the census (§8). Its companion loader warning **W205** is
likewise the next free W2xx (W201/W203/W204 exist; W202 is
taken by the documented-unreachable list), appended the same
way (`N_CODES` → 34 with both).

**Raise site and form.** The validator
(`f3dc_val_timeline.f90`, beside the existing per-character
checks in `check_character_props` / `character_facts`) raises
E214 once per character whose plugin id is not in the loaded
registry, with the character's span. Severity `error` (so the
exit code is the usual scene-error 1 via
`error_bag_fail_code`). House style (message / why / help,
mirroring E205/E211's `verr_full` shape):

Form A — the character carries a plugin id that is not loaded:

```
error E214: character 'ada' belongs to plugin 'stickman', which is not loaded
  why: characters, their props and their actions are declared by plugins; the core language does not define them
  help: install the 'stickman' plugin package (plugins/stickman/plugin.json) or add its parent directory to F3DC_PLUGIN_PATH
```

Form B — no plugin is loaded at all, so the character's id is
the empty default:

```
error E214: character 'ada' has no plugin: no character plugin is loaded
  why: characters, their props and their actions are declared by plugins; the core language does not define them
  help: install a character plugin package under plugins/ or set F3DC_PLUGIN_PATH to a directory containing one
```

Form B is not a shortcut around "naming the missing plugin":
in the load-nothing world the language gives a character no
plugin name of its own (characters declare no plugin in the
Wave-2 language; the id is the registry default), so the only
honest name available is the character's and the fact of the
empty registry. Naming `stickman` in form B would require a
stickman literal in core source — exactly what the ruling
forbids. A character that *carries* an id (a node-level plugin
prop, as `character_facts` already reads) gets form A, which
names it.

**W205 drafts** (loader, printed through the same bag at CLI
level, no span):

```
warning W205: plugin package 'plugins/badpkg' skipped: plugin.json is not valid JSON
warning W205: plugin 'stickman' in 'extras/stickman' skipped: already loaded from 'plugins/stickman'
warning W205: plugin package 'plugins/future' skipped: package format 2 is not supported by this compiler
  why: a plugin package must be a directory plugins/<id>/ containing a plugin.json this compiler can read
  help: fix the package or remove it from the plugin search path
```

---

## 6. Migration map

| Module | Data deleted | Mechanism kept / added |
|---|---|---|
| `f3dc_plugins.f90` | The entire `ensure_plugins` registration blocks for stickman **and** humanoid (rig dicts, channels, caps, 80 `reg_verbs` entries, 16 `reg_rig_channel` calls, 13 `add_prop` records); the `TPL_*` constants (TPL_NONE…TPL_EXIT) | All public query procedures, unchanged signatures; `ease_canonical` (core easing authority, not plugin data). **Added:** the loader (§4) behind `ensure_plugins`; template storage (per verb, the parsed `dyn` template body) with `plugin_template(id, verb, template, found)` replacing `plugin_template_id`; `expression_codes` storage + `plugin_expression_code`; W205 reporting hook (the loader collects warnings; the CLI drains them into the bag before the pipeline runs). |
| `f3dc_anim_resolve.f90` | All 20 template subroutines and their helpers-as-data: `gait_move`, `enter_t`, `exit_t`, `wave_t`/`wave_arm`, `sit_t`, `stand_t`, `jump_t`, `fall_t`, `sleep_t`, `dance_t`, `look_t`, `point_t`, `face_t`, `expr_t`, `expr_code`, the inline nod/shake/tap blocks, and `gait`'s/osc's per-call constants | **Kept (generic):** `anim_resolve` entry + cursor contract, `add_key`/`add_key_f`, `snap`, `frame_at`, `finish_keys` + sort helpers, `dest_pos`/`lookup_other`/`vec_of`, `pstr`, `cycles_at`. **Added:** the template interpreter — step walker with `when` guards, the `osc` sampler (the existing `osc` body, parameterised by waveform), the expression evaluator (§3.2), the condition evaluator (§3.3), param-default resolution. The interpreter contains no verb name, channel name or numeric template constant. |
| `f3dc_emit_timeline.f90` | `expr_code_of` (the duplicated expression map, §1.2) | `anim_resolve` call site unchanged; `char_decl` now asks `plugin_expression_code(pid, …)`; `plugin_rig` / `plugin_verb_channel` call sites unchanged. |
| `f3dc_desugar.f90` | — (no plugin data lives here) | No change: `plugin_default_id` / `plugin_channel_for_verb` queries are loader-backed now. The placeholder still stamps the default id — which is the first *loaded* plugin. |
| `f3dc_parser.f90` | — | No change: `plugin_default_id` / `plugin_prop_by_surface` call sites unchanged. (With an empty registry, undeclared-prop collection proceeds as today and the validator's E214/E205 path reports the real problem.) |
| `f3dc_val_timeline.f90` | — | **Added:** the E214 check (§5). All other call sites (`plugin_capability`, `plugin_prop_*`) unchanged. |
| `f3dc_val_common.f90` | — | No change: `plugin_is_verb` is loader-backed. |
| `f3dc_cli.f90` | — | **Added:** resolve `driver_repo_root` once at program entry and call `plugin_configure(root)`; drain loader W205 warnings into each command's bag before diagnostics print. No command's behaviour changes otherwise. |
| `f3dc_errors.f90` | — | **Added:** E214 + W205 table entries (§5); `N_CODES` 32 → 34, `error_code_count` likewise. |
| `plugins/stickman/plugin.json`, `plugins/humanoid/plugin.json` | — | **Created:** the packages of §3.5, encoding §1 in full (all 20 stickman templates per §3.4; humanoid template-less). |
| Engine (`src/`) | — | **Untouched.** The engine consumes the frozen IR; `src/char_figure.f90` is a host-side figure for the stickman rig vocabulary, not compiler registry data, and is out of this slice's scope. |

**What remains in core — exhaustively:** the registry storage
and query procedures; the package loader; JSON parsing
(`f3dc_ir`); the template interpreter (step walker, osc
sampler, expression and condition evaluators); destination /
param / cursor plumbing; key sorting and de-duplication;
easing canonicalisation; the E214/W205 diagnostics. Every item
on that list is plugin-agnostic mechanism. **Acceptance grep:**
after the migration, `compiler/src` contains no occurrence of
`stickman`, `humanoid`, any of the 20 verb names as data, any
rig-channel name, any prop name or expression name from §1 —
outside comments that cite this document. (Comments in
`f3dc_val_common` / `f3dc_val_timeline` that currently narrate
stickman behaviour are reworded to plugin-generic language as
part of the move.)

---

## 7. Timeline IR check — **no change**

The frozen Timeline IR (ADR-5, `docs/TIMELINE-FORMAT.md`)
already carries everything this design needs, and resolution
stays at compile time against the loaded registry:

- Character `plugin` is already a **required** string field —
  "the core format never interprets the id beyond recording
  it". Its value now comes from the first *loaded* package
  instead of the first *registered* one; the field, its type
  and its semantics are untouched.
- Character `rig` is already a plugin-owned opaque object; the
  emitter obtains it via `plugin_rig` and copies the `dyn`
  verbatim. A rig parsed from `plugin.json` is the same `dyn`
  shape as the one built by today's registration block, so the
  emitted bytes are identical.
- Action tracks already carry `keys` **or** `resolved: false`;
  template ids (`TPL_*`) are compiler-internal and were never
  emitted. Replacing integer template ids with package
  template bodies changes nothing on the wire.
- `identity`, `proportions`, channel names and expression
  codes are already plugin vocabulary carried as data.

**Verdict: no IR format change, no ADR-5 amendment, no
`ir_version` bump.** With the stickman package present, emitted
IR must be byte-identical to today's (§8, proof b).

---

## 8. Proof tests (the gate, from the ruling)

a. **Absent plugin.** Run the suite (or the designated subset)
   with `F3DC_PLUGIN_PATH=""`: the core still works — non-film
   scenes build, `check`/`fmt` behave — and a film declaring a
   character fails with **E214** (form B; a fixture whose
   character carries the `stickman` id exercises form A and
   asserts the id is named). E214 enters the error-code census
   in `tests/native/property_tests.f90`: a minimal failing
   input in the codes section + `E214` added to the census
   `COVERED` list (likewise `W205`, triggered by a malformed
   package fixture). Without this, the census grep fails the
   suite — by design.
b. **Present plugin.** With `plugins/stickman/` in place and
   `F3DC_PLUGIN_PATH` unset, the full suite passes exactly as
   today, with byte-identical outputs (artifact pins, IR
   fixtures and the legacy golden
   `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`
   unchanged). Template encodings are validated against the
   existing anim corpus pins — any encoding slip in §3.4 shows
   up as a pin diff, which is a migration bug, not a re-bake
   occasion.
c. **Loader hygiene.** Fixtures for: duplicate id (first wins +
   W205), malformed JSON (skip + W205, compile proceeds),
   `format: 2` (skip + W205), directory/`id` mismatch (skip +
   W205), a template naming a missing template (skip + W205).
   No fixture may crash the compiler.
