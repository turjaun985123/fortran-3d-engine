# Forge3D Animation Compiler — Design Plan

**Status: DESIGN — decision-ready, awaiting the user's approval to build.**
Produced 2026-11-26 by a 5-area design pass (language, compiler, Timeline IR /
host contract, engine + preview, test + wave plan), integrated into this one
document. No production code was written for this plan.

**User decision (2026-11-26):** the goal is an animation studio where
animation is written as easy, human-readable code. The ruling: upgrade the
CURRENT compiler (`f3dc` / `.f3d`, v3.0.0 just released — tag `v3.0.0` at
`d1c34cd`, main `bc8ec6a`) further into an animation scripting compiler.
LATER, this compiler will be used inside StykAnimate (the user's stickman
studio). No new language from scratch, no new studio now.

**The one-sentence design:** a `.f3d` file whose first statement is `film`
becomes a story written in sentences — characters, actions, dialogue, camera
moves, in written order — which the compiler resolves into the keyframe
tracks, scene extensions, and Timeline IR it already knows how to handle,
and which the engine renders as flat 2D stickman characters living inside
real 3D environments (the Tall Tale charter: 2D characters in 3D worlds,
never modelled 3D characters).

---

## 0. Ground facts and baseline corrections

Verified against the tree (and the host repo) during design; these correct
or sharpen assumptions the design started from:

1. **StykAnimate is no longer GPUI.** The local checkout lives at
   `~/workspace/StykAnimate-RS` (repo `turjaun985123/stykanimaters`, HEAD
   `a0b4da9`). `Cargo.toml` depends on `rune`/`rune-kit`; the README records
   the GPUI shell was removed in full on 2026-11-08 (`docs/RUNE_MIGRATION.md`).
   The GitHub repo description still says GPUI — it is stale. **Nothing in
   the host contract may assume GPUI.** The host's model layer is
   deliberately UI-free (`src/model.rs`: "No UI types leak in"), which is
   what makes a clean importer possible.
2. **The host already has the precedent for this integration:**
   `src/harness_import.rs` imports an external JSON episode format (beats in
   seconds, dialogue, a named cast) into a `Project`, with an honesty
   contract — anything unmappable is listed in `ImportReport::unmapped`,
   never faked or silently dropped. Timeline IR import is designed as a
   sibling of that module, not a new pattern. The host also already shells
   out via `std::process::Command` (ffplay, file dialogs), so a CLI
   integration is idiomatic there.
3. **The easing vocabularies already agree.** Forge3D `ease_value`
   (`linear/smooth/in/out` = `t`, `t²(3−2t)`, `t²`, `1−(1−p)²`) and
   StykAnimate's `Easing` have identical formulas for the shared four names.
4. **One real convention clash exists:** Forge3D keyframe easing belongs to
   the key a segment *ends at* (frozen `keyframe.f90` semantics);
   StykAnimate's belongs to the key a segment *starts at*. The importer must
   shift easing one key earlier (§3.4). This is the single most likely
   silent-corruption bug in the future integration, and the conformance
   tests are designed around it.
5. **The engine has no camera animation, no dialogue, and no character
   concept today** (grep-verified across `src/`, the compiler, and the
   examples). Bones exist (`SceneBone`, `skin_apply`) but are static,
   applied at load. The compiler AST's `AnimStmt` already carries
   `verb/motion/action` fields — an anticipation this design uses.
6. **The JS runtime mirror lags the engine:** `runtime/f3d-keys.js` mirrors
   only the frozen Euler `key_eval`, not Phase 5's `key_eval_q` (slerp,
   per-axis scale, per-track fps). Preview parity work must budget mirror
   upgrades as first-class work (§4.4).
7. **No v3 frame-time baseline exists.** `docs/bench/BASELINES.md` holds
   legacy-renderer numbers only (640×480, 166–227 ms/frame on the throttled
   build VM). Export cost estimates in §4.5 are extrapolations until Wave 5
   measures real v3 rows.
8. **Multi-scene today is a CLI-level split** (`multi_chunks` in
   `f3dc_cli.f90`): each `scene` block builds as an independent program;
   nothing cross-scene exists below the CLI. This constrains transitions
   (§2.5, open question Q6).

---

## 1. Language design

### 1.1 Film mode — the one structural idea

A file is a **film** only if its first statement is `film`:

```f3d
film "Saturday Market" size 1280 720 fps 24
```

Reading: *"Make a film called Saturday Market, this big, at 24 frames per
second."* `size`/`fps` are the existing keywords with their existing
meanings; `fps` is the film's master rate (per-track `fps` overrides still
win locally). Everything new lives inside film mode; outside it, nothing
changes (§1.9).

Inside a film, each `scene` line starts a **shot** — same `scene` syntax as
today, plus one optional prop (§1.7). Inside a shot, lines are of two kinds:

1. **Setup lines** — everything that already exists (primitives, `group`,
   `import`, `repeat`, lights, initial `camera`), plus `character` and
   `place`. They describe what is *there*.
2. **Cue lines** — sentences (§1.3–§1.6). **Cues play one after another, in
   written order.** That single rule is the whole timeline; timecodes are an
   escape hatch, never a requirement.

A `place` line names a spot so scripts never need raw coordinates in cues:
`place stall-front at 1 0 2` → `lloyd walks to stall-front`.

### 1.2 Characters (stickman-first)

Same shape as a primitive line — keyword, name, colour, free-order props:

```f3d
character lloyd blue at -5 0 2 tall head round wears cap red
character mira pink at 4 0 2 kid head round hair bun wears dress yellow
character rafi green at 0 0 0 short face determined holds stick
```

Reading: *"Lloyd is a tall blue stickman with a round head, wearing a red
cap, standing over there."*

| Prop | Values | Meaning |
|---|---|---|
| `at vec3` | as today | where they stand |
| `tall` / `short` / `kid` / `height n` | words canonical, `height` the numeric escape hatch | proportions — `kid` = child proportions, not a scaled adult |
| `head round\|square\|oval` | `round` default | head style (identity) |
| `hair bun\|…` / `hair colour` | e.g. `hair bun` | hair as rig-attached geometry |
| `face happy\|sad\|determined\|surprised\|neutral` | `neutral` default | starting expression; cues may change it |
| `wears cap\|hat\|dress\|shirt\|glasses … [colour]` | rig-attached | clothing/accessory — moves with its body part |
| `holds name` | an ordinary named object | prop in the dominant hand |

**Identity rule, stated in the language:** proportions, `head`, and `wears`
are *who the character is*; cues may change `face`, position, and pose only.
A cue that tries to change identity mid-film is a compile error.

How a character exists in the system: the declaration registers the
character (identity + proportions + placement) with the compiler; at
compile time it becomes a named scene object plus a Timeline IR cast entry;
at render time the engine generates the figure procedurally from the pose
(§4.3) — the author never models body parts.

### 1.3 Actions — built-in and custom

One cue grammar for characters, camera, and objects alike:
**`<who> <verb-phrase> [in|for <duration>] [ease <name>]`**.

```f3d
lloyd walks to stall-front in 4 seconds ease smooth
mira waves for 2 seconds
rafi sits on bench for 3 seconds
lloyd jumps
mira looks at lloyd
rafi does celebrate for 2 seconds
bus moves to stop in 4 seconds ease out
```

Built-in verb-phrases (canonical form is the natural "-s" sentence form;
the base form — `walk`, `wave` — is accepted as an alias everywhere, in the
language's existing alias tradition; `f3dc fmt` prints the "-s" form):

`walks to <place|character|vec3>`, `runs to …`, `walks in from left|right`,
`exits left|right`, `waves [left hand|right hand|both hands]`,
`sits on <object>`, `stands`, `jumps`, `falls`, `looks at <target>`,
`faces <character|camera>`, `points at <target>`, `nods`, `shakes head`,
`dances`, `sleeps`, `smiles`, `face <expression>`, `picks up <object>`,
`gives <object> to <character>`, `taps foot`, `spins`, `moves to …`.

Durations: `in N seconds` = taking N seconds to get there (movement,
camera); `for N seconds` = keep doing it for N seconds (wave, sit,
dialogue). Instant actions (`jumps`, `nods`) default to 1 second.

**Custom actions** — defined once, like a `shader` is defined once, as a
block like `group`. Inside the block, **`it` is the actor** — the existing
pronoun's second natural job:

```f3d
action celebrate
  it jumps
  it waves both hands
  it spins speed 360
end
```

Reading: *"Celebrating means: jump, wave both hands, spin around."* Cues
inside play in order. `rafi does celebrate for 2 seconds` plays the whole
action time-scaled to 2 s; without `for`, it takes the sum of its cues'
durations. Actions may use other actions; recursion is an error (E212).
Actions are definable in imported part files, so a shared `actions.f3d`
library works through the existing `import … as …` mechanism.

### 1.4 Timeline sequencing in plain words

Written order = play order. Four modifiers, and only four:

| Form | Sketch | Reading |
|---|---|---|
| (default) | `lloyd waves for 2 seconds` | "Then Lloyd waves for two seconds." |
| Parallel with previous | `with mira waves for 2 seconds` | "At the same time, Mira waves too." The pair ends when the longer cue ends. |
| Parallel block | `together` … `end` | "All of these happen at once" — 3+ simultaneous cues; lasts as long as its longest cue. |
| Absolute time | `at 5 seconds lloyd jumps` / `at 0:05 lloyd jumps` | "At the five-second mark…" — the escape hatch. Measured from the shot's start, so shots stay movable. |
| Pause | `wait 1 second` | "Hold everything for one second." |

Durations are `N seconds` or `N beats` — `film … tempo 120` sets beats per
minute (default 60, so 1 beat = 1 s until stated otherwise):
`mira dances for 8 beats`.

### 1.5 Camera moves over time

The existing `camera at … look …` line is the shot's opening framing, with
one additive extension: `look` may name a character or place
(`camera at 0 3 10 look lloyd`). After that, the camera is another cue
subject:

```f3d
camera follows lloyd
camera zooms in on stall in 2 seconds ease smooth
camera pans to door in 3 seconds
camera orbits mira in 3 seconds
camera looks at bench in 1 second
```

`follows <character>` lasts until the next camera cue or shot end; write it
as a `with` cue to run it alongside an action. `zooms in/out` reuses the
existing `fov` machinery; all camera cues take the standard
`[in N seconds] [ease name]` tail.

### 1.6 Dialogue, subtitles, on-screen text

```f3d
lloyd says "Good morning, Mira!" for 2 seconds
mira says "The mangoes look fresh today!"
caption "Meanwhile, across town…" for 3 seconds
title "The Lost Key" for 3 seconds
```

`says` produces a speech bubble over the character **and** a subtitle at
the bottom, both on by default. The line lasts `for N seconds`, or, if
unwritten, long enough to read (≈0.4 s/word, minimum 1.5 s — a stated
default; the estimate is surfaced as warning W204). Variants as trailing
props: `bubble only`, `subtitle only`, `thinking` (thought bubble). Quoted
text is an ordinary `.f3d` string, so Bengali (or any Unicode) dialogue
needs no special syntax. `caption "…"` is narrator text nobody speaks;
`title "…"` is big centred screen text. Both are screen-space and
deliberately distinct from the existing in-world `text` primitive, which is
unchanged. No voice/TTS is implied by `says` in v1 (open question Q4).

### 1.7 Multiple scenes and transitions

In film mode the `scene` line gains one optional prop; the transition
belongs to the shot it **opens** and overlays that shot's first cue (it
does not add to the film's length):

```f3d
scene "market" background white transition fade 1 second
scene "home" background black transition dissolve 1 second
scene "park" transition cut
```

Values: `cut` (default — today's behaviour), `fade`, `fade black`,
`dissolve`, `slide left|right`, `wipe`. A closing cue exists for the film's
end: `fade out in 1 second`, usable as a `with` cue over the final action.
How transitions are realised given the CLI chunk-split architecture is a
design decision with a user-facing fork — see §7/Q6.

### 1.8 Easing, loops, variables

- **Easing:** no new names. Any cue takes the existing tail —
  `ease linear|smooth|in|out|cubic-in|cubic-out|cubic-in-out|bezier(…)`.
  Two adverb aliases for sentence flow only: `slowly` ≡ `ease out`,
  `gently` ≡ `ease cubic-in-out`; `f3dc fmt` prints the canonical form.
- **Loops:** the existing object-level `loop once|forever|pingpong|repeat(N)`
  is untouched. At timeline level, one new block form (the block cousin of
  the existing prefix `repeat`):

  ```f3d
  repeat 2 times
    rafi taps foot for 1 second
  end
  ```

  A cue may also carry `loop forever` — in a film it means "until this shot
  ends," and the compiler warns that the shot's length then comes from its
  other cues.
- **Variables:** one deliberately minimal form — a named literal reusable
  anywhere that kind of value fits:

  ```f3d
  let wait-time be 3 seconds
  let hero-colour be blue
  rafi sits on bench for wait-time
  ```

  Values are numbers, durations, colours, or names. No arithmetic, no
  expressions in v1 (design decision D5, §7).

### 1.9 Compatibility rules

Purely additive — no existing program changes meaning:

1. **The 3-line contract is frozen.** `cube red` / `spin it` / `render`
   compiles byte-identically; `f3dc new` still writes exactly it. Film mode
   is opt-in by the `film` first statement; a file without it is parsed,
   desugared, and rendered exactly as v3.0.0 does.
2. All existing statements, props, defaults, easing names, loop forms,
   error codes, and limits are unchanged. New diagnostics are append-only
   (§2.4).
3. `scene … transition …` occupies a prop slot that previously rejected
   unknown props — no valid program used it.
4. `camera look <character|place>` widens a form that previously required a
   vec3 — a widening of an invalid form, not a change to a valid one.
5. New statement words (`character`, `place`, `action`, `caption`, `title`,
   `let`, `wait`, `together`, `with`, `at <time>`) are reserved **only as
   the first token of a line and only in film mode**; in legacy mode a name
   position still accepts them (`cube character red` keeps working).
6. A `character` line is also legal outside a film (static pose,
   targetable by existing verbs — `spin lloyd`, `keys lloyd …`). Cues exist
   only in film mode, where sequential semantics are unambiguous.

Needs care (named, with the chosen guard):

7. **`render "x.mp4"`** — today any non-`.png` name writes PPM, so `.mp4`
   interpretation is gated to film mode only; in film mode it means
   "render the timeline and assemble video" via the existing
   `--video`/ffmpeg path.
8. **`repeat`** — the existing prefix form (setup expansion) is untouched;
   the timeline form is syntactically distinct (`repeat N times` + block,
   only among cues); a block form among setup lines is an error, never a
   guess.
9. **`it`** — in legacy animation, `it` = most recent object (unchanged);
   inside an `action` block, `it` = the actor. The two never coexist in one
   scope, and `f3dc check --explain` prints which binding it resolved.
10. **Sequential vs parallel default** is the one real semantic fork —
    scoped to film mode precisely so it can never leak into legacy files.
11. **Determinism is preserved:** a film timeline compiles down to the
    same keyframe/verb IR, so same file + same `t` ⇒ same pose, natively
    and in the JS viewer.


### 1.10 Example scripts — three complete ~15-second shorts

Timings in comments are the compiled cue windows; transitions overlay and
add nothing.

**Script A — "Saturday Market"** (meet, greet, camera follow + zoom)

```f3d
film "Saturday Market" size 1280 720 fps 24

scene "market" background white transition fade 1 second
camera at 0 3 10 look 0 1 0
plane ground gray at 0 -2 0 size 16
cube stall red at 3 0 0 size 2
sphere mango orange at 3 1 0 radius 0.3
place stall-front at 1 0 2
character lloyd blue at -5 0 2 tall head round wears cap red
character mira pink at 4 0 2 kid head round hair bun

lloyd walks to stall-front in 4 seconds ease smooth   # 0–4
with camera follows lloyd
lloyd waves for 2 seconds                             # 4–6
with mira waves for 2 seconds
lloyd says "Good morning, Mira!" for 2 seconds        # 6–8
mira says "The mangoes look fresh today!" for 3 seconds  # 8–11
camera zooms in on stall in 2 seconds ease smooth     # 11–13
mira picks up mango for 1 second                      # 13–14
mira smiles for 1 second                              # 14–15
with fade out in 1 second

render "saturday-market.mp4"
```

Readability proof: *Make a film called "Saturday Market," this size, 24
fps. / Scene: the market, white background, fade in. / The camera starts
here, looking at the middle. / A grey ground, a red stall, a small orange
mango on it, and a named spot in front of the stall. / Lloyd: tall, blue,
round head, red cap, standing left. Mira: a pink kid with a hair bun,
standing right. / Lloyd walks to the stall-front, taking four seconds,
smoothly — while the camera follows him. / Lloyd waves for two seconds —
and at the same time Mira waves back. / Lloyd says "Good morning, Mira!"
/ Mira answers. / The camera zooms in on the stall, smoothly. / Mira
picks up the mango. / Mira smiles as the picture fades out. / Render it
as this video file.* No line needs a programming word.

**Script B — "The Bus Is Late"** (custom action, variable, repeat block,
object as cue subject)

```f3d
film "The Bus Is Late" size 1280 720 fps 24
let wait-time be 3 seconds

action celebrate
  it jumps
  it waves both hands
  it spins speed 360
end

scene "bus stop" background white
camera at 0 3 10 look 0 1 0
plane ground gray at 0 -2 0 size 16
cube bench gray at -2 0 0 size 2
cube bus yellow at -14 0 0 size 4
place stop at 3 0 2
character rafi green at -2 0 2 short face determined

rafi sits on bench for wait-time          # 0–3
repeat 2 times                            # 3–5
  rafi taps foot for 1 second
end
bus moves to stop in 4 seconds ease out   # 5–9
with rafi stands for 1 second
rafi says "Finally!" for 2 seconds        # 9–11
rafi does celebrate for 2 seconds         # 11–13
rafi walks to bus in 2 seconds            # 13–15

render "the-bus-is-late.mp4"
```

Readability proof: *A film, "The Bus Is Late." / Let wait-time be three
seconds (change the joke's timing in one place). / "Celebrate" means:
jump, wave both hands, spin right around — whoever does it. / Scene: the
bus stop — camera, ground, a bench, a yellow bus waiting off-screen, a
named spot called stop. / Rafi: short, green, determined face, at the
bench. / Rafi sits for wait-time. / Twice: Rafi taps his foot for a
second. / The bus moves to the stop, easing out — while Rafi stands up.
/ Rafi says "Finally!" / Rafi does the celebrate action, squeezed into
two seconds. / Rafi walks to the bus. / Render the video.* The three
"hardest" ideas — a variable, a repeat, a custom action — are each one
ordinary English sentence.

**Script C — "The Lost Key"** (two scenes, dissolve, caption, `together`)

```f3d
film "The Lost Key" size 1280 720 fps 24

scene "park" background white transition fade 1 second
camera at 0 3 10 look 0 1 0
plane ground gray at 0 -2 0 size 16
cube bench gray at 2 0 0 size 2
cube key yellow at 2 -1 1 size 0.3
character lloyd blue at -5 0 2 tall head round wears cap red

caption "One sunny morning, Lloyd lost his key." for 2 seconds  # 0–2
lloyd walks to bench in 3 seconds ease smooth                  # 2–5
lloyd picks up key for 1 second                                # 5–6
lloyd says "Found it!" for 2 seconds                           # 6–8

scene "home" background black transition dissolve 1 second
camera at 0 3 10 look 0 1 0
plane ground gray at 0 -2 0 size 16
character lloyd blue at -3 0 2 tall head round wears cap red
character mira pink at 3 0 2 kid head round hair bun

mira says "You found it!" for 2 seconds                        # 8–10
together                                                       # 10–13
  lloyd dances for 3 seconds
  mira dances for 3 seconds
  camera orbits lloyd in 3 seconds ease smooth
end
camera zooms out in 1 second                                   # 13–14
lloyd smiles for 1 second                                      # 14–15
with mira smiles for 1 second
with fade out in 1 second

render "the-lost-key.mp4"
```

Readability proof: *Film: "The Lost Key." / Scene one, the park, fading
in: camera, ground, a bench, a tiny yellow key; Lloyd — same cap, same
proportions as always. / A caption tells the audience what happened
(nobody says it aloud). / Lloyd walks to the bench, smoothly. / He picks
up the key. / He says "Found it!" / Scene two, home, dissolving in: the
same Lloyd (re-declared — as today, nothing carries between scenes; see
open question Q3), Mira waiting. / Mira says "You found it!" / All at
once for three seconds: Lloyd dances, Mira dances, the camera circles
Lloyd. / The camera zooms out. / Both smile as it fades to black. /
Render.*

---

## 2. Compiler architecture

Grounded in `compiler/src/` as of v3.0.0: the typed AST is *shallow by
design* (`f3dc_ast.f90`) — `ast_stmt` carries a `kind` tag, `name`,
`target`, `line`, a props bag, a fields bag, and recursive `children`;
`ast_program_from_dyn`/`ast_program_to_dyn` are structural inverses.
Statement classification is key-presence signature matching, duplicated in
three ladders (`classify_stmt` in `f3dc_ast.f90`, `is_node` in
`f3dc_desugar.f90`, `classify_node` in `f3dc_val_common.f90`). Desugar is
dyn inside (typed → dyn → desugar → typed), and **validate re-runs
desugar**, so every desugar rewrite must be idempotent under a second pass.

### 2.1 New typed-AST node kinds

No new Fortran derived types — new `kind` tags + parser-emitted key
signatures. Each new parser node emits **one unique marker key**, checked
*first* in all three classification ladders, so a new node can never be
swallowed by an older signature. Payload goes to the props bag; everything
else rides the fields bag verbatim — that is what keeps the converters
lossless.

| kind tag | Marker | Contents | Reuses |
|---|---|---|---|
| `"film"` | `"film_def"` | title, `size`, `fps`, `tempo` | scene header vocabulary |
| `"character"` | `"char_def"` | `name`; props: colour, proportions, `head`, `hair`, `face`, `wears`, `voice`; optional children via `"body"` (member objects — held props, accessories as ordinary statements) | group body mechanism; `char.member` naming from group expansion |
| `"actiondef"` | `"action_def"` | `name`; `duration` (declared or null = sum of steps); children via `"body"`: cues with relative timing | AnimStmt/KeyframeStmt shapes for steps |
| `"timeline"` | `"timeline_def"` | children via `"body"`: the shot's cues in source order. *Implicit:* the parser wraps each shot's cue run in this node — authors never write it | group-style child list, consumed by desugar before group expansion |
| `"cue"` | `"cue"` | `target` (string only); `action` (built-in verb or custom action name); `timing` (`at\|then\|after\|with`), `anchor`, `offset`, `duration`; props = the ordinary anim props (`ANIM_PROP_WORDS`) | AnimStmt almost wholesale — a cue *is* an AnimStmt plus timing fields; `parse_anim`'s prop loop reused verbatim |
| `"cammove"` | `"cam_move"` | `from_pos/to_pos`, `from_look/to_look`, **`follow`** (string name — deliberately not the key `target`, §2.6), `fov_from/fov_to`, `duration`, `ease`, timing fields as a cue | CameraStmt field vocabulary; keys-track payload shape at emit |
| `"dialogue"` | `"say"` | `speaker`; **`content`** (the line text — the TextStmt key, safe only because `"say"` is checked before the `content` signature in all three ladders); `duration` (explicit or null = estimated); timing fields; props: `voice`, `style` | `parse_text` quoted-string parsing |
| `"transition"` | `"transition"` | `kind` (`cut/fade/dissolve/wipe/slide`), `duration`, `from_scene`, `to_scene` | — (metadata between scene blocks) |
| `"loopblock"` | `"loop_block"` | `count` or null; children via `"body"`: cues. Must **not** carry `obj`+`mode` or it classifies as a repeat | RepeatStmt's concept, for time instead of space |
| `"let"` | `"let_name"` | `let_name`, `value` (any dyn scalar/list, verbatim) | — (note: `let` is currently in `RESERVED_ALL` and raises E205 today; see D5) |

Parser work implied: new starters and `parse_*` routines modelled on
`parse_anim`/`parse_text`/`parse_keys_header`; `f3dc fmt` needs a
`format_stmt` branch per new kind. **The lexer needs no change** — all new
vocabulary is plain words/numbers/strings the existing tokeniser already
produces.

### 2.2 Pipeline changes — desugar owns timeline resolution

Desugar is the only stage that still sees definitions and source order,
already performs every other expansion, and runs before the single
typed→dyn conversion boundary — so everything downstream (validator, all
four emitters, `f3dc_optimize`) keeps consuming exactly the node shapes it
consumes today. **The validator must never see a `then`.**

New sub-steps in dyn desugar, in order:

- **Step 0.5a — `let` substitution.** Collect bindings (scene-block scope,
  must precede use, immutable), substitute into subsequent statements,
  drop the `let` nodes. Runs before everything else, so variables can
  appear in durations, positions, counts — and import paths (see §2.5).
- **Step 0.5b — definition collection.** Hoist all `character` and
  `actiondef` nodes (file scope, like imports) into definition tables;
  remove them from the statement stream. Character member statements (if
  any) expand through the *existing* group machinery via a synthetic
  group named after the character, so member naming, transform
  composition, and `prefix_anim_target` come for free.
- **Step 0.5c — timeline resolution (the core new pass).** For each scene
  block, walk its timeline children in source order, maintaining one
  cursor per scene:
  - `at T` → start = T. `then` (the default) → start = end of previous
    cue. `after X` → start = end of cue/instance X, + `offset`. `with` →
    start = start of previous cue.
  - Duration: explicit → else the action definition's declared/computed
    duration → else `ANIM_DEFAULTS` (5 s).
  - **Custom-action expansion:** a cue naming an `actiondef` is replaced
    by the definition's steps, their relative timing resolved against the
    cue's start; nesting recurses with an explicit expansion stack (the
    `expand_imports` cycle-stack analogue). Expansion is counted and
    capped like repeat placements (E820-family budget).
  - `loopblock`: resolved cues re-emitted `count` times, each iteration
    shifted by the iteration duration; also capped.
  - **Output — only pre-existing shapes survive:**
    - a cue on a built-in verb → a plain **AnimStmt** with two extra
      fields-bag keys, `start` and the resolved `duration`. (The one IR
      change built-in animation needs: `ir_anim` gains `start` in
      `f3dc_ir.f90` / `f3dc_val_anim.f90`; the legacy JSON emitter omits
      `start` when 0 so non-timeline scenes stay byte-stable.)
    - a pose-based cue (from an `actiondef` with key steps) or a
      `cammove` → **`keys` header + `key` statements** in the exact shape
      `f3dc_ext_keys.build_tracks` already consumes, with absolute times;
      camera moves emit keys for the reserved pseudo-target `"@camera"`.
    - a `dialogue` cue → a resolved `dialogue` statement (marker
      retained) carrying absolute `start`/`duration`; it is *not* lowered
      to TextStmt — a subtitle is timed screen text, not a scene object.
  - `character`, `actiondef`, `timeline`, `cue`, `loopblock`, `let`
  nodes **never survive desugar** (the ImportStmt precedent). This makes
  the pass trivially idempotent under validate's second desugar run:
  on re-entry there is nothing left to resolve.

`transition` nodes survive desugar untouched (fields-bag round-trip) and
are handled at the CLI/multi-scene level (§2.5 emit note, Q6).

### 2.3 Validate

- `classify_node` must recognise the two resolved survivors: `dialogue`
  (marker `"say"`, checked **before** the `"content"` → `C_TEXT`
  signature) and camera keys (the `"@camera"` keys header is exempted
  from `val_waveb_keys`' "no object is called that" check and routed to
  the new section).
- New section module **`f3dc_val_timeline.f90`**, registered in
  `validate_program` **after `"outputs"`** (it needs the render
  duration/fps only the outputs section parses) and before `"env"`. It
  performs the §2.4 semantic checks on the *resolved* stream and builds:
  `ir_anim.start` per animation; a scene extension **`"dialogue"`**
  (`[{speaker, text, start, duration}]`) and a scene extension
  **`"camera_track"`** (build_tracks-shaped, for `"@camera"`), via the
  existing `set_scene_extension` stash. Using scene extensions means
  **zero emitter dispatch changes** — extensions already flow into the
  JSON/JS/HTML/Fortran emitters.
- Definition-level errors visible only before expansion (unknown action,
  recursion) are raised in **desugar**, following the E504/E820 precedent.

### 2.4 New diagnostics (existing E-code style, append-only)

The code table (`f3dc_errors.f90`, 22 entries today) is organised by
stage family; E2xx is "validate: names/references" and E206–E213 are
free. (A fresh E6xx/E7xx block was considered and rejected: the table's
families are stage-based, not feature-based, and scattering breaks the
census discipline.) Text form stays `error E2xx: <message>` with optional
`why:`/`help:` lines; the new section populates why/help properly rather
than inheriting the validator's current span-less style debt.

| Code | Raised | Rule |
|---|---|---|
| **E206** unknown action | desugar 0.5c | Cue names an action that is neither a built-in verb (`ANIM_KINDS`: spin, bob, pulse, orbit, move, turn, grow — plus the new sentence verbs) nor a defined `actiondef`. Did-you-mean (Damerau–Levenshtein ≤ 2) over built-ins + defined actions |
| **E207** overlapping actions | validate, timeline section | Two resolved cues on the **same character and same channel** (body motion) overlap in `[start, start+duration)`. Cross-channel overlap (walk + talk) is free; `with` is the explicit same-channel opt-in and suppresses this for the cues it joins |
| **E208** timeline overrun | validate, timeline section | A cue's end exceeds the scene's *explicit* render duration. Not raised when no explicit duration exists — the timeline then *defines* the duration (D2) |
| **E209** unknown character | validate / desugar | A cue, dialogue, or camera-follow names a character no `character` definition and no object/group provides. Distinct from E201, which stays "no *object* is called that" for plain anim/key targets |
| **E210** camera follow target missing | validate, timeline section | A `cammove`'s `follow` name is not a defined character or object |
| **E211** dialogue for undefined character | validate, timeline section | A `dialogue` node's `speaker` is not a defined character — an object name is not sufficient; only characters speak |
| **E212** custom-action recursion | desugar 0.5c | An `actiondef` directly or transitively invokes itself; reported with the expansion chain, as import cycles report theirs under E504. (Deliberately not E5xx: recursion is a scene error, exit 1, not an IO error, exit 3) |
| **E213** undefined / redefined variable | desugar 0.5a | Reference to a `let` name with no preceding binding, or a second binding in one scene block |
| **W203** unused action | validate, timeline section | An `actiondef` never used by any cue (warning — action libraries are legitimate) |
| **W204** dialogue duration estimated | validate, timeline section | A dialogue line had no explicit duration; the estimate is surfaced, never silent |

Example diagnostics, in the existing formats:

```
error E206: timeline uses action 'danse', but no action is called that; did you mean 'dance'?

error E207: 'mira' is already doing 'walk' from 2s to 5s, so 'wave' cannot start at 4s
  why: two body actions on the same character cannot overlap
  help: start 'wave' with 'after walk', or join it with 'with' if they should play together

error E212: action 'celebrate' uses itself: celebrate -> spin_fast -> celebrate

error E208: the timeline runs to 12.5s, but the scene renders only 10s
```

Inherited for free: cue durations/speeds/fps/eases are validated by the
existing E303/E201 checks once cues become AnimStmts; keyframe times by
`f3dc_ext_keys.validate_tracks`. Timeline expansion blow-up (loop ×
custom action × repeat) reuses the **E820** budget mechanism with a step
budget rather than a new code.

### 2.5 Incremental compile impact

The manifest hashes **files**, not definitions — so the question is
whether every new input is already a dep:

- Actions/characters/variables defined in the main `.f3d`: covered — the
  source file is dep #1.
- Imported parts (including a shared `actions.f3d`): covered **if** they
  arrive through the existing `import` statement — desugar records them
  in `_import_deps`, which `collect_build_deps` already adds. **Rule for
  all new work:** any new file-reference syntax (action library, voice or
  subtitle asset) must append its resolved canonical path to that same
  `_import_deps` list. No manifest format change, no `f3dc-manifest`
  version bump.
- Dialogue/voice assets, if they ever become files: add a dep loop over
  the `"dialogue"` extension in `collect_build_deps`, the way texture
  slots are handled today. Inline text needs nothing.

Risks, in severity order:

1. **Runtime-module gap (pre-existing, becomes live):**
   `collect_build_deps` hashes only `runtime/f3d.js` and
   `runtime/f3d-webgl2.js`, but the HTML output inlines the whole runtime
   family. A new animation runtime module not added to the dep list
   produces stale "up to date" skips after a runtime-only fix. **Fix in
   Wave 1: hash every runtime file the HTML emitter inlines.**
2. **Variable-fed paths:** a dep path produced by `let` substitution is
   recorded post-substitution and re-hashed correctly — but only because
   step 0.5a runs before import expansion. That ordering is load-bearing;
   it gets a test.
3. **512-dep ceiling:** `dep_paths(512)` in `do_build` is fixed-size; a
   project importing many small part files could silently exceed it.
   Raise the cap or make `dep_add` diagnose overflow, in this upgrade.
4. **Multi-scene chunk builds are unmanifested** — scenes with
   transitions get no incremental benefit in v1. Acceptable while
   transitions are metadata (Q6); revisit if that ruling changes.
5. Compiler changes are self-invalidating (the f3dc binary is itself a
   dep), so timeline-semantics changes need no manifest bump.

### 2.6 Riskiest seams (named, with mitigations)

1. **Signature collision** across the three classification ladders. Known
   traps found in the code: `dialogue` carries `"content"` (TextStmt);
   a `loopblock` carrying `"obj"`+`"mode"` becomes a RepeatStmt; a
   `cammove` carrying `fov`+`pos`+`target` classifies as a CameraStmt.
   Mitigation: unique marker keys (§2.1), checked first in all three
   ladders — one shared ordering rule, unit-tested.
2. **The `target` extraction trap** (`ast_stmt_from_dyn`): only
   string/null targets lift into the typed field; a vec3 target stays in
   the fields bag by design. That is why `cammove` uses `follow` for its
   string target and `from_look`/`to_look` for vec3s — reusing `target`
   for both would silently null one of them on round-trip.
3. **Child-key capture:** children are extracted from `"children"`, else
   `"obj"`, else a non-empty `"body"`. Container nodes must use `"body"`
   exclusively and be consumed by desugar step 0.5 *before* group
   expansion, because the validator treats any `"body"` node as a group.
4. **Double desugar** (validate re-runs it): the defence is structural
   (nothing resolvable survives pass 1) but must be *proven* by a test
   that desugars a timeline scene twice and diffs the programs —
   mirroring the B07 default-output regression test.

**Lossless invariant, kept:** every new key is assigned exactly one home
(typed field / props bag / fields bag) in a table in the `f3dc_ast.f90`
header; the property tests gain generators for each new node shape
asserting `dyn → ast → dyn` structural equality; the new shapes enter the
black-box corpus so a converter regression fails CI, not a user.

**Effort shape:** `f3dc_parser.f90` changes most by volume (~9 new
`parse_*` routines — high volume, low subtlety); `f3dc_desugar.f90`'s
timeline-resolution pass is the intellectual core and the biggest
risk-adjusted chunk; `f3dc_val_common.f90` + new `f3dc_val_timeline.f90`
+ small edits to `f3dc_validate/val_anim/val_keys/f3dc_ir/f3dc_cli/
f3dc_errors` follow. Untouched: lexer, `f3dc_dyn`, `f3dc_str`,
`f3dc_optimize`, `f3dc_compat`, all other validator families, and the
engine's evaluators.


---

## 3. Timeline IR — the StykAnimate contract

This is the stable interface StykAnimate will consume later. It is
designed against both codebases as they actually are (§0), and it is
frozen early (Wave 2) precisely so engine work can never bend it.

### 3.1 Placement and identity

Timeline IR is a **new artifact of `f3dc build`, not a modification of
the scene JSON**:

- New file `build/<name>.timeline.json`, emitted alongside `<name>.json` /
  `<name>.scene` whenever the source contains animation authoring beyond
  a still. No timeline → no timeline file (absence = still, matching the
  existing frame-count rule).
- New discriminator, following the ADR-3 pattern exactly:
  `"format": "forge3d-timeline"`, `"ir_version": 1`. It must **not** reuse
  `"forge3d-scene"` — a timeline is not loadable by `engine3d` as a scene,
  and distinct discriminators let each format evolve on its own cadence.
- The timeline **references** scene artifacts (relative path + the
  scene's own `ir_version`); it never embeds scene geometry.

### 3.2 Canonical time: integer frames at a rational fps

**The canonical, normative time in Timeline IR is an integer frame
index, under a timeline-level `fps` expressed as a rational
`{num, den}`. All spans are `[start_frame, end_frame)` half-open integer
pairs.** Rationale, grounded in both codebases:

1. **The host is frame-native.** StykAnimate's `Frame`,
   `CameraKey.frame`, `SubtitleCue.start_frame/end_frame`, chapters,
   beat markers, and audio clips are all integer frames; seconds are
   derived (beats ÷ fps). Float-seconds IR would make every import a
   host-side rounding decision — the host re-interpreting the contract.
2. **Forge3D already accepts this model:** `KeyTrack%fps > 0` means "key
   times are frame numbers at this rate", and `round(duration × fps)` is
   already the frame-count derivation rule.
3. **Float seconds are not byte-stable across implementations**
   (Fortran `real(dp)` vs the host's `f32` model). Integer frames need no
   rounding spec at all.
4. **Beats are rejected as canonical** — "beat" already means two
   different things on the two sides. Story beats survive as named
   `markers[]`, which is also how the host models them.

Spans may carry `"t_seconds"` as informational floats; the spec states:
*if `t_seconds` disagrees with `frame / fps`, the frame values win;
readers must not compute timing from `t_seconds`.*

### 3.3 Structure

```
{
  "format": "forge3d-timeline",
  "ir_version": 1,
  "name": string,                     // film/episode name
  "fps": {"num": 24, "den": 1},       // canonical rate for ALL frame values
  "duration_frames": int,             // authoritative total
  "generator": {tool, version, source, source_sha256},   // provenance only
  "characters": [ Character ],        // cast table, declared once, referenced by id
  "scenes":     [ SceneSpan ],        // ordered partition of the timeline
  "tracks":     [ Track ],            // timed performance + camera data
  "dialogue":   [ Cue ],              // subtitle/dialogue cues
  "markers":    [ Marker ]            // named story beats / chapter points
}
```

- **Character** — declared once at top level because characters persist
  across scenes (unlike scene objects, which are per-scene by the
  existing multi-scene rule): `{id, name, color:[r,g,b], rig:{kind:
  "stick", topology:"humanoid11"}, proportions?, voice?{speaker}}`. The
  IR carries identity and proportion *hints*, never a host-specific node
  list — topology is the host's business.
- **SceneSpan** — the sequencing layer that does not exist in Forge3D
  today: `{id, name, scene_file, scene_ir_version, start_frame,
  duration_frames, bindings:{character_id → object name in THIS scene}}`.
  Bindings are per-scene because scene artifacts are self-contained; a
  character absent from `bindings` is off-stage for that scene.
- **Track kinds (v1):** `action` (character; resolved spans, §3.4),
  `pose_keys` (character or scene object; generalises
  `extensions.waveb.keys`), `verb` (scene object; today's `animations[]`
  closed-form spans), `camera` (§3.5), `visibility` (on/off spans).
- **Dialogue cue** — shaped to map 1:1 onto the host's `SubtitleCue` plus
  a character link: `{id, scene, start_frame, end_frame, speaker:
  <character id>, text}`. Text is byte-verbatim from source; the compiler
  never emits an empty-text cue (diagnostic instead). `end > start`,
  half-open, matching `SubtitleCue::is_live_at`.
- **Marker:** `{frame, name, kind: "beat"|"chapter"}` → host `BeatMarker`
  / `Chapter`.

### 3.4 Actions: resolved keys are normative, symbols are provenance

An authored action compiles to a **resolved span**: the symbolic layer
(`action: "wave"`, `params`) is retained for editability, but the
**resolved per-channel `keys` are the contract** — a host that implements
only the keys produces the correct frames. This follows the emitter
philosophy already in evidence: groups and `repeat` blocks are expanded
by the emitter so the reader sees a flat list; resolution happens at
compile time, never at read time. A host must not re-expand the symbol
with its own action library and expect the same frames. An action that
genuinely cannot be resolved to keys (future procedural/IK cases) is
emitted with `"resolved": false` and no `keys`, and hosts must list it
in their unmapped report rather than approximate it silently.

**Easing:** string names from the closed registry Forge3D already
evaluates (`linear, smooth, in, out, cubic-in, cubic-out, cubic-in-out`,
the parameterised `bezier(x1,y1,x2,y2)` form, plus `hold` for hard cuts).
**Attachment rule: easing belongs to the key the segment ENDS at** —
Forge3D's frozen semantics win over host convenience. The host uses the
opposite convention; its importer shifts easing one key earlier at
import (§3.7), and the conformance kit includes an easing-boundary case
for exactly this. The first key's `ease` is emitted as `"linear"` and
ignored. Unknown ease names: readers treat as `linear` **and** record a
diagnostic — the fallback, without the silence.

**Camera track:** the IR carries the 3D truth (`pos/target/fov` keys)
and lets the host project (§3.7) — the host's camera is 2D
(centre + zoom + rotation), so any 2D form in the IR would lose the
native path's information.

### 3.5 Concrete excerpt — 2 characters, 1 action, 1 line, 1 camera move

```json
{
  "format": "forge3d-timeline",
  "ir_version": 1,
  "name": "gate-scene",
  "fps": {"num": 24, "den": 1},
  "duration_frames": 48,
  "generator": {"tool": "f3dc", "version": "4.0", "source": "gate.f3d"},
  "characters": [
    {"id": "mira", "name": "Mira", "color": [90, 140, 220],
     "rig": {"kind": "stick", "topology": "humanoid11"}, "voice": {"speaker": "Mira"}},
    {"id": "finn", "name": "Finn", "color": [230, 170, 60],
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
       {"frame": 24, "channel": "arm.r.upper", "value_deg": -10.0, "ease": "linear"},
       {"frame": 36, "channel": "arm.r.upper", "value_deg": -150.0, "ease": "smooth"},
       {"frame": 48, "channel": "arm.r.upper", "value_deg": -10.0, "ease": "smooth"}
     ]},
    {"kind": "pose_keys", "scene": "s1", "character": "finn",
     "keys": [
       {"frame": 0,  "pos": [1.5, 0, 0], "rot_deg": [0, -20, 0], "scale": 1.0, "ease": "linear"},
       {"frame": 48, "pos": [1.5, 0, 0], "rot_deg": [0, -35, 0], "scale": 1.0, "ease": "smooth"}
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

(Finn has no action — he stands and turns via `pose_keys`. Mira's `wave`
shows one channel for brevity; a real emission carries every animated
channel of the action, in the versioned rig-channel vocabulary — Q7/§3.7.)

### 3.6 Versioning and stability (recorded as ADR-5)

Timeline IR is a **sibling format under the ADR-3 regime**, recorded as
**ADR-5** before Wave 2. It copies ADR-3's rules with its own `format`
string and its own `ir_version` counter starting at 1; neither format's
version bumps for the other's changes, and a timeline pins its scenes'
versions per SceneSpan. The stability promises, to be written into
`docs/TIMELINE-FORMAT.md` (the sibling of `docs/SCENE-FORMAT.md`):

1. **Field stability:** within an `ir_version`, no key is removed,
   renamed, re-typed, re-meaninged, or given a different default. Ever.
2. **Additive-only evolution:** new optional keys, new track kinds, new
   ease names, and safely-skippable enum values do not bump `ir_version`.
   Readers ignore unknown keys at every level and skip unknown track
   kinds **with a diagnostic** — never a crash, never a silent drop.
3. **Bump discipline:** a breaking change bumps `ir_version` by exactly
   1, with migration notes in the changelog. A downgrade target is added
   only if a real consumer needs it.
4. **Exact-version readers:** a reader accepts exactly the `ir_version`s
   it implements and rejects others with an error naming the version
   found. Missing `format` or `ir_version` is an error, not a default.
5. **Emitter guarantees:** canonical (alphabetical) key order; stable
   array ordering (scenes in timeline order; tracks sorted by
   `(scene, kind, character/target, start_frame)`; keys sorted by
   frame — the evaluator never sorts, so the emitter must); no
   timestamps or random ids in the normative payload.
6. **The host's half of "stable":** the host treats IR as read-only
   import input, never its working format. Round-tripping
   IR → Project → IR is **not** promised in v1 (Q7).

### 3.7 Determinism — and the host's obligations

| Pinned by the emitter / file | Rule |
|---|---|
| fps | In-file rational `{num, den}`. Never assumed, never defaulted. All frame arithmetic is integer. |
| Frame spans | Integers, half-open `[start, end)`. No float time is normative anywhere. |
| Easing evaluation | The named-ease formulas and the `bezier(…)` solver are **part of the format spec**, including edge rules (progress clamped to [0,1]; bezier x clamped; malformed/unknown → linear + diagnostic). |
| Loop mapping | `once` = clamp; `forever` = `modulo(max(t,0), D)`, exact multiples → 0; `pingpong` = triangle over `2D` — copied verbatim from frozen `keyframe.f90`. |
| Key ordering | Emitter sorts by frame; equal-frame keys are a compile-time validation error (no reader tie-break to invent). |
| Float formatting | One spec'd format (shortest round-trip decimal, or fixed `%.17g`-equivalent — Wave 2 picks and documents); no locale separators; no `NaN`/`Inf` (validation error); `-0.0` normalised to `0.0`; whole values emitted as JSON integers, never `48.0`. |
| Text | UTF-8, no BOM, dialogue byte-verbatim; no Unicode normalisation by either side. |
| IDs | Source-derived slugs, stable across recompiles; no generated UUIDs in normative positions. |

**What the host must NOT re-interpret:** (1) re-expand symbolic actions
with its own library in place of resolved keys; (2) re-derive timing
from seconds, its own project fps, or `t_seconds` — a rate change is one
documented resample at import, nothing else; (3) re-sort, dedupe, or
merge keys/cues, or move easing between keys except the single specified
ends-at → starts-at conversion; (4) substitute its own easing formulas
(`cubic-in` is `p³`, not the host's `EaseIn` `p²` — close is wrong);
(5) apply its log-space zoom rule (RM18, a host-authoring rule) to IR
camera keys — projection happens once at import, after which the keys
are host data.

**Precision boundary, stated honestly:** Forge3D evaluates in `f64`, the
host model is `f32`. Bit-identical *bytes* are promised for the IR file
itself (same compiler + same source → same file, hash-testable).
Bit-identical *rendered frames* across the boundary are promised only
to the extent that the importer converts `f64 → f32` once, at import,
round-to-nearest — after which the host's existing deterministic `f32`
pipeline (which already has determinism tests) owns playback. The
contract says this plainly rather than claiming cross-language bit
equality it cannot keep.

**Conformance kit (part of the deliverable):** golden `.f3d` +
expected `.timeline.json` pairs in `tests/`, plus one adversarial case
per rule — an easing-boundary case, a `forever` loop landing exactly on
a duration multiple, a 24000/1001 fps case, a `-0.0`/whole-float
formatting case. The host mirrors these as importer tests on its side.

### 3.8 Embedding: CLI subprocess now, library later

**Recommended for the first integration: (a) `f3dc` as a CLI subprocess
producing Timeline IR files.** It is the only surface f3dc has today
(no library, no C ABI, no FFI); it keeps the Fortran toolchain and its
build fragility entirely outside the Rust binary; version skew is
handled by the `ir_version` gate at file level, where both projects
already have discipline; and it matches how the host already consumes
the outside world. Shape: the host gains an **importer first** (import
pre-built artifacts), and optionally a "Compile .f3d…" command second,
behind a path setting for the `f3dc` binary.

**(b) A library form** (`bind(C)` shim over parse→validate→emit, stable
C ABI, per-platform packaging, gfortran runtime linkage inside the
host's distribution, ABI versioning *in addition to* format versioning)
is a multi-week compiler project. It buys in-process speed and a live
recompile loop inside the editor. **Do not build it until the file
contract has survived one real production episode** — the file format
*is* the API, so a library producing the same bytes is later a drop-in
accelerator, not a redesign.

### 3.9 What StykAnimate-RS would need to build (future work, scoped here)

Grounded in its actual tree (`~/workspace/StykAnimate-RS`); all host-side
work follows its house rule — no local cargo builds, CI-only
verification:

1. **`src/timeline_import.rs`** — a sibling of `src/harness_import.rs`
   with the same contract shape: a pure function (parsed JSON in →
   `Result<(Project, ImportReport), String>`), no file IO inside,
   everything unmappable listed field-by-field in
   `ImportReport::unmapped`, refusal only on nothing-to-import (bad
   `format`, unsupported `ir_version` named in the error, zero scenes,
   zero frames).
2. **Bake-on-import:** IR tracks are evaluated at every host frame in
   their span and written as dense `Frame { poses, duration: 1.0,
   easing: None }` entries — because the host's main timeline is dense
   (`frames: Vec<Frame>`); sparse channels exist only in its graph/clip
   subsystems. Baking is also what makes the determinism boundary clean:
   after import, playback is purely the host's existing tested
   evaluation. (Live, unbaked IR tracks would be a new sparse-track
   model in `Project` — its own future design, not v1.)
3. **Time conversion in exactly one place:** if IR fps ≠ project fps,
   one documented resample (evaluate IR tracks at host frame times);
   if equal (the expected case), frame-for-frame transcription.
4. **Easing shift:** where anything is transcribed sparsely (camera),
   each segment's ease shifts one key earlier to match `CameraKey`'s
   starts-at convention; baked tracks use IR easing directly at bake
   time. Unit-tested with the §3.7 adversarial case.
5. **Dialogue:** cues → `Vec<SubtitleCue>` (frames transcribed/resampled
   with round-half-to-even, `end > start` clamped), text verbatim,
   speaker = display name resolved from the IR character table through
   the existing `normalise_speaker` path; scene boundaries → `Chapter`s;
   markers → `BeatMarker`s. Near-copy of what `harness_import` already
   does with story beats.
6. **Character mapping:** each IR character → one `FigureInstance` built
   as the classic 11-node humanoid (`FigureDef::humanoid()`), coloured
   from the IR `color` — the same construction `harness_import` uses for
   its cast, for the same channel reason (cast stays recognisably
   stickman). `proportions`, when present, scale node lengths from the
   humanoid defaults; absent → plain humanoid + a line in the import
   report, never a silent invention. The rig-channel vocabulary
   (`root`, `head`, `arm.l.upper/fore`, `arm.r.*`, `leg.l.*`, `leg.r.*`,
   `torso`) maps to `Pose.angles` indices + `Pose.root` as a data table
   in the importer, pinned first by the conformance tests.
7. **The dimensionality gap, plainly:** Forge3D poses are 3D; host poses
   are 2D. The importer projects `pos[0], pos[1]` → stage x/y (one
   documented world→stage scale factor, reported); `pos[2]` depth and
   out-of-plane rotations are **unmapped and reported** in v1; in-plane
   rotation maps to node-angle deltas. Camera keys project to
   `CameraKey {x, y, zoom, angle: 0}` (target → x/y, zoom derived from
   fov + distance) — lossy whenever the view direction is not
   front-parallel, and listed as such in the report. Scene geometry is
   **not** imported in v1: the host imports timeline, characters,
   dialogue, and camera; 3D scenes remain Forge3D/`engine3d`'s render
   domain.
8. **Thin wiring:** one MCP tool (`import_timeline`) beside the harness
   import tool; one import-dialog filter entry. Optional phase 2: the
   "Compile .f3d…" action chaining `f3dc build` into the importer,
   surfacing f3dc's diagnostics verbatim on failure.

---

## 4. Engine, preview, and export

### 4.1 What exists to build on

The engine's animation substrate is stronger than "nothing": `keyframe.f90`
provides `KeyTrack`/`KeyFrame` with two evaluators — `key_eval` (frozen
Euler semantics the JS mirror follows) and `key_eval_q` (Phase 5: quaternion
slerp, per-axis scale, per-track fps). `animation.f90` provides the
closed-form verbs (`spin/bob/pulse/orbit/move/turn/grow`), all pure `f(t)`.
The frame loop in `main.f90` computes `t_sec = (frame_i-1)/fps_r` (fps
chain: scene fps → first anim's fps → 30) and applies the first
name-matching `KeyTrack` per object. **Missing:** any per-frame camera
motion (the camera is built once at load), any character/joint evaluation
(tracks target whole objects only), and any dialogue concept.

### 4.2 Animation evaluation design

House principle, unchanged: **every pose is a pure function of absolute
`t`** — no accumulated state, no frame-stepping. The timeline layer is
orchestration *above* `key_eval_q`; neither frozen evaluator is modified.

| Track kind | Reuse | Evaluation at `t` |
|---|---|---|
| Object TRS (existing) | `KeyTrack` + `key_eval_q` verbatim | as today |
| Character root | same `KeyTrack`, `target = <char name>` | identical path; the character is a scene object whose *mesh* is regenerated from the pose (§4.3) |
| Character joint (new data, same evaluator) | same `KeyTrack`, `target = "<char>:<joint>"` | `key_eval_q` per joint; rotation (slerp) and `scale3` carry the joint. Name-matching extends from "object" to "object or object:joint", first-match rule unchanged |
| Action instance (new) | `ActionClip` (named bundle of joint+root tracks in character-local space) + existing loop map | local time `tl = (t − start) × speed`, loop-mapped exactly as `key_eval_q` maps it; per-joint quats out |
| Camera (new) | position + look via `key_eval_q`; one scalar FOV channel via a small `CamTrack` | evaluated in `main` *before* the object loop; rebuilds `sc%cam` per frame. Everything downstream already reads `sc%cam`/`models` — no renderer change |
| Dialogue (new, non-render) | `DialogueSpan{start, end, speaker, text}` array on `Scene` | pure interval lookup at `t`. The renderer **never sees it** — consumers are preview (§4.4) and export (§4.5). Deliberate: dialogue must not become a scene text entity, or it trips the legacy fallback (§4.6) |

**Blending:** overlapping action instances and the base/idle pose combine
per joint — positional/scale lerp, rotational **pairwise slerp by
accumulated weight** (keeps shortest-path behaviour and determinism;
order = timeline order, fixed). Weights come from instance blend windows
eased with the existing `ease_value` set.

**The pose model:** a fixed joint enum — root, head, shoulder.L/R,
elbow.L/R, hand.L/R, hip.L/R, knee.L/R, foot.L/R (15 nodes) — each with a
rest offset and a segment length from the character's proportions.
Forward kinematics is the only genuinely new math: a pure subroutine
`figure_fk(pose, proportions) → joint world positions` in a new module
`src/char_figure.f90` (~100 lines of existing `vec3` ops).

**Build vs reuse:** reuse `key_eval_q`, `quat_slerp`, `ease_value`, loop
maps, per-clip fps, the frame loop, the validator/diagnostic machinery.
Build: `ActionClip`/`DialogueSpan` scene types + serialisation, instance
resolution + blending, the `CamTrack` hook, `char_figure.f90` FK + mesh
emission, and the JS mirror upgrades (§4.4).

### 4.3 The stickman representation — Approach A (recommended)

The heart of the engine design. Constraint recap: expressive **2D**
characters, camera-facing, inside fully 3D environments; recognisably
stickman; never a modelled 3D character. Three approaches were compared:

- **A — Procedural jointed figure as real geometry in a facing plane.**
  FK produces joint positions in a character-local 2D plane, placed in
  the world by the root track and **yaw-billboarded (cylindrical)**: the
  plane rotates about world Y to face the camera (the `sprite.f90` basis
  idea, minus pitch — feet stay planted, ground contact and shadows stay
  truthful from high/low cameras). An authored facing offset lets a
  character turn profile/away within the convention. Each limb segment
  becomes a **capsule mesh** (`geo_capsule.f90` already exists), the head
  a flat **disc** (`circle` primitive), face features and accessories
  small discs/capsules parented to joints — all emitted per frame as one
  ordinary scene-object mesh (the `render_waveb` per-frame mesh-build
  precedent), shaded with `fragment_v3`'s existing **unlit "basic"
  material mode** so limbs read as flat colour, not shaded tubes.
- **B — Billboarded sprite per character.** Poses are continuous, so
  textures would need per-frame generation (a whole 2D rasteriser to
  write and mirror) or an exploding atlas. One quad = one depth plane
  (no per-limb occlusion), and the shadow map would cast a **rectangle**
  silhouette. Rejected on depth and shadows.
- **C — Screen-space thick-line pass in the rasterizer.** The most
  precise 2D look (constant screen-space line weight), but: no native
  shadows (characters would need a fake blob shadow beside the
  environment's real per-light shadows), limb-vs-limb ordering needs its
  own sort, the highest renderer cost, and a whole new determinism
  surface plus a JS mirror of the pass. Rejected for v1; kept as the
  documented fallback if A's look fails user review.

**Why A wins:** it is the only option that gets depth, shadows,
determinism, and preview parity *by inheritance* rather than by new
engineering. It is real visibility-buffer geometry (per-pixel correct
occlusion against sets, props, and other characters — no sorting);
`shadow_v3_build` gives it stickman-shaped cast/receive shadows for
free because it is an ordinary scene object; triangle order is fixed by
joint enum order, so the tile rasterizer's thread-invariance covers
characters unchanged; and it needs **zero renderer changes**. Cost is
one mesh build per character per frame (~900 tris/character — noise
next to any environment). Line weight is in world units, so it thins
with distance — arguably correct for the charter: the character is
flat, but it *lives* in the 3D world and is photographed by its camera.
Character identity lives in the proportions record (`head_r, torso,
upper_arm, fore_arm, thigh, shin, line_r, color, head_style`) plus
joint-parented accessories. One known interaction: v3 *drops*
near-plane-crossing triangles instead of clipping (existing Phase-2
debt) — a character walking into the camera will pop limbs; staging
keeps characters ≥ near-plane distance, and this stays logged as the
existing clipping debt, not a new one.

### 4.4 Preview: playing a script live

All additive to `f3dc_preview.f90`'s toolbar/client JS and the runtime;
the watch/recompile/reload machinery is **not modified**.

- **Transport:** the runtime already owns `playing`/`time` and
  `api.play()/pause()`. Add toolbar ⏵/⏸ buttons, a **scrub slider** and
  a `t / duration · frame N` readout, backed by one new runtime entry
  `api.seek(t)` (the paused-render path already exists). The compiler
  emits a `timeline` object (`duration, fps, frames`) into the compiled
  viewer — no new route needed for transport. Playhead survives the
  save-reload loop via `location.hash`, which makes edit-save-watch
  actually usable for timing work.
- **Dialogue/subtitles:** one new route `/__timeline` (served from
  preview state like `/__status`): dialogue spans, action spans, markers.
  The existing rAF tick does the interval lookup at current `time` and
  updates a subtitle div (speaker name in the character's colour + line);
  the same span data renders as **action-track lanes** under the scrub
  bar, so timing errors are visible.
- **Error surfacing:** today the LIVE/ERROR pill goes red but diagnostics
  require the reload error page, even though `/__status` already serves
  them as structured JSON. Switch the 600 ms poll to `/__status` (a
  superset), keep version-bump reload identical, and render diagnostics
  into a collapsible drawer (`code severity file:line:col message —
  help`). The new animation validators then surface live, with zero new
  plumbing.
- **Parity caveat (stated plainly):** preview plays the **JS runtime**;
  export renders the **Fortran engine**. Preview truth therefore depends
  on the JS mirror learning slerp/`key_eval_q`, action blending, camera
  tracks, and Approach-A figure meshing. Each new evaluator ships with a
  cross-check test comparing Fortran vs JS poses at sampled `t` (the
  repo's existing mirror discipline, e.g. the `text_render` cross-check).

### 4.5 Export path: frames → video

No new machinery — correct scene settings on existing paths:

- `fps 24` in the film header (scene fps wins the `main` fps chain) +
  `render duration 15 fps 24` → 360 frames, PNG output (ASCII PPM at
  ~3.5 MB/frame would be ≈1.26 GB of scratch for one short).
- `engine3d … --video out.mp4` → the existing Phase-8 ffmpeg image2
  assembly (libx264/yuv420p). ffmpeg failure is non-fatal by design
  (frames kept, stderr note) — the export runbook checks the `.mp4`
  exists, not the exit code. Frame 1 is the un-numbered base file; the
  `%04d` pattern construction gets a 2-frame smoke check before the
  first full export.
- **Subtitles:** an `.srt` sidecar serialised from the same
  `DialogueSpan` array at compile time (frame-accurate at the film's
  fps). Burn-in, if ever wanted, is an ffmpeg-step option
  (`subtitles=` filter) — never engine text geometry (§4.6).
- **Cost of a 15 s / 24 fps short (360 frames), honestly bounded:** the
  only recorded engine numbers are legacy-renderer, 640×480, throttled
  VM: 166–227 ms/frame → **60–82 s at 640×480**. At 1080×1920 (6.75×
  the pixels) with no v3 baseline in existence, the defensible range is
  **roughly 5–15 minutes on this VM**, materially less on the user's
  PC; compile (~0.1 s) and ffmpeg assembly (seconds) are negligible.
  Wave 5's first task is adding the missing v3 baseline rows at
  640×480 and 1080×1920 so the next estimate is measured, not
  extrapolated. Characters (~900 tris each) are not the cost driver;
  resolution is.

### 4.6 Renderer split — the transition contract

The fallback rule today is scene-global (`main` flips the whole scene to
legacy if sprites/text/particles are present), and it **stays
scene-global**: legacy and v3 differ in framebuffer semantics (linear
real32 + end-of-pipeline sRGB vs 8-bit throughout), so a mixed frame
would seam visibly and void both paths' goldens.

| Script content | Path |
|---|---|
| Geometry, materials, lights, keyframe tracks (existing) | v3 (default) |
| **Characters (Approach A), action clips, camera tracks** | **v3** — characters are ordinary scene-object meshes and must *not* increment the sprite/text/particle counts or otherwise enter the fallback condition |
| **Dialogue** | **Neither** — metadata only (preview overlay, `.srt` sidecar); never a scene entity |
| `sprite` / `text` / `particle` statements (existing) | whole scene → legacy, stderr note, exactly as today |
| `--renderer legacy` | legacy, always; frozen and golden-exact regardless |

So the rule's *form* is unchanged — a script falls back iff it uses
legacy-only entity statements — and the design work is precisely keeping
the new signature features out of that trigger set. The migration debt
is also unchanged and named: an existing script combining, say,
particles with characters renders all-legacy (losing v3 shadows/tonemap
for the whole frame) until v3 grows its own sprite/text/particle pass —
the known Phase-2 limitation, neither fixed nor worsened here. Golden
safety: the fallback condition, both evaluators' frozen semantics, and
the legacy renderer are untouched; existing scenes render
byte-identically. New v3 features get new goldens (§5.2).


---

## 5. Test and quality plan

House discipline carries over unchanged: the legacy golden
(`28b6a81d…`) is pinned in CI and never re-baselined; baked hashes change
only with cause, each listed in the wave's hash-change manifest; every
error code has a minimal failing input; per-wave commits + pushes with
CI watched to completion.

### 5.1 Script corpus

New cases enter `tests/native/corpus.json` as a named `anim_cases`
section, plus a curated set in `tests/native/curated.json`. Target
≈ **200–240 new corpus cases + ~24 curated**:

| Category | ~Count | Pins |
|---|---|---|
| Character declaration | 20 | proportions, colours, defaults, duplicate-name / unknown-part errors |
| Built-in actions | 30 | each stock verb × parameter variants — `.scene` + IR artifact hashes |
| Custom actions | 25 | definition, parameter binding, shadowing a built-in, recursive reference (must fail) |
| Plain-word timelines | 35 | `at/then/after/with/together`, and plain-word ↔ numeric **equivalence pairs** — the same script written both ways must produce identical IR bytes |
| Camera moves | 20 | follow/pan/zoom/orbit, ease variants, camera track vs scene cuts |
| Dialogue/subtitles | 25 | speaker attribution, timing, multi-line, Unicode/Bangla text, overlap behaviour |
| Multi-scene + transitions | 25 | ordering, cut/fade/dissolve boundaries, per-scene overrides, transition at t=0 / past end (errors) |
| Loops & variables | 30 | `repeat N times`, `let` substitution in times/params, loop-carried state, zero/negative diagnostics |
| fps/timebase edges | 15 | mixed per-clip fps, non-integer frame times, duration rounding, `t` beyond last key |
| Negative/diagnostic | per §5.4 | one minimal failing script per new code |

Engine-side (Fortran layer): ≈ 8–10 new test programs —
`test_stickman_rig` (FK pose at known angles), `test_anim_eval`,
`test_timeline_eval`, `test_camera_track`, `test_dialogue_timing`,
`test_scene_sequence`, `test_ir_read`/`test_ir_write`. JS layer: ≈ 40
new tests over shared fixtures — the `math_vectors.json` pattern extended
to `tests/fixtures/timeline_vectors.json` (script fragment → sampled
poses at fixed `t`, asserted by **both** engines).

The property layer (parse→print→parse stability, `fmt` idempotence)
extends to every new statement kind automatically — a new syntax form is
not "done" until the sweep covers it (this is what caught the v3 `fmt`
non-idempotence, and the §2.6 converter invariant lives here).

### 5.2 Golden frames at pinned timestamps

New registry `docs/V4-GOLDENS.md`, mirroring `docs/V3-GOLDENS.md` plus a
**time column**. Pinned timestamps per golden scene (frame-exact at the
scene's canonical fps): `t=0` (initial pose), first keyframe hit,
**mid-ease** (50% of an eased segment — the most float-sensitive point),
a slerp midpoint, **loop wrap** (last frame of iteration 1 + first of
iteration 2, asserted as a pose-identical pair), **transition midpoint**
(50% blend), dialogue start frame (subtitle present) and the frame after
dialogue end (absent), and the final frame.

Judgement split, exactly per ADR-1: same-renderer repeatability is a
**sha256 hard gate**; cross-renderer quality (native v3 vs legacy vs JS
preview) is **PSNR/SSIM** — a drop > 3 dB against the recorded value, or
one the reviewer can't attribute to an intended change, blocks a re-pin.
Subtitle-bearing frames are hash-gated only within the native renderer
(text rasterisation is the least portable surface); cross-renderer they
get PSNR + a subtitle-region pixel-diff bound.

New CI gates in the `build-test` job, alongside G3a/G3b/G3c (which remain
untouched, legacy pins included): **G3d** — one canonical animation
scene (`examples/anim-golden.f3d`: character + custom action + camera
move + one transition) rendered at the pinned timestamps, sha256-pinned,
threads 1 vs 8 identical. **G3e** — multi-frame sequence digest: sha256
over the concatenation of all frame hashes of a ≤ 30-frame render,
catching inter-frame state bugs (loop carry, variable drift) that single
frames miss. Golden scenes stay small (≤ 320×240, ≤ 2 s) so the gates
cost seconds.

### 5.3 Determinism gates

1. **IR byte determinism:** same `.f3d` compiled twice (and on a clean
   rebuild) → byte-identical Timeline IR, `.scene`, and JS artifacts.
   Requires the §3.6 canonical serialisation.
2. **Frame determinism across threads:** pinned-timestamp frames at
   `FORGE3D_THREADS=1` vs `=8` byte-identical. This is why §4.2 mandates
   per-frame-independent evaluation: pose is a pure function of absolute
   `t`, never accumulated.
3. **fps-independence gate (new, animation-specific):** the same
   timeline rendered at 15, 24, and 30 fps must produce identical poses
   at shared absolute times (t = 0.5 s, 1.0 s) — joint angles within
   1e-6 rad, and byte-identical frames where frame times coincide
   exactly. This gate is what forbids frame-stepped integration anywhere
   in action evaluation.
4. **Cache determinism:** cache-hit and `--force` builds of every
   animation corpus case produce identical artifact hashes (extends the
   v3 C5 manifest discipline to the new inputs).

### 5.4 Diagnostic tests

Every new code (E206–E213, W203–W204) gets one minimal failing `.f3d`
asserting **exit code + exact code + JSON-diagnostics shape**, plus one
"near-miss valid" twin that must compile (guards against over-eager
errors). The error-code census is updated so a code that exists in
`compiler/src` with no failing-input test **fails the suite** — the
upgrade's target is 100% reachable-or-documented from day one.

### 5.5 Timeline IR contract tests

The IR is a public contract, so it gets its own layer, `tests/ir/`,
independent of compiler internals:

- **Schema tests:** the versioned schema (`docs/TIMELINE-FORMAT.md` +
  machine-readable schema in-tree) validated against IR emitted for
  every curated animation case; unknown-field tolerance and
  required-field presence both asserted.
- **Golden IR fixtures:** for ~15 representative scripts, the full
  expected IR is committed as a *reviewed fixture file* (not a hash), so
  a diff shows semantically what changed; fixture changes carry the
  same cause-named discipline as golden re-pins.
- **Version tests:** current-version emit; previous-version fixtures
  still readable (or explicitly rejected with a named diagnostic, per
  ADR-5); future-version input rejected cleanly, never silently mis-read.
- **Round-trip tests:** IR → engine scene state → re-emit =
  byte-identical IR (the v3 typed-IR inverse-proof pattern).
- **Host-simulation test:** a small standalone consumer (zero compiler
  internals) that reads only the schema + a golden fixture and extracts
  track/key/pose data — proving a third party can implement against the
  contract alone. **This test is the artefact StykAnimate reuses.**
- **CI stability gate:** IR fixtures + schema are pinned like goldens;
  a wave that changes emitted IR for an *unchanged* feature lists it in
  its manifest with cause.

### 5.6 Fuzz additions

Extending `tests/fuzz/` (ASan/UBSan harness discipline unchanged):

- **`fuzz_timeline`** — mutational fuzzing of timeline blocks (statement
  reordering, time-expression mutation, loop-bound corruption):
  invariants are no crash, no hang, every failure a named E-code.
- **`fuzz_desugar`** — plain-word forms fuzzed against their numeric
  equivalents: desugared output is either identical IR or a named
  diagnostic — never different-but-silent IR.
- **`fuzz_ir`** — mutated Timeline IR into the engine reader:
  version-gate and bounds behaviour, no silent drops.
- Loop/variable fuzz specifically targets **non-termination**:
  adversarial loop bounds must hit the resource-limit diagnostic, not
  spin; the harness enforces a per-case wall-clock bound.
- Release bar inherited from v3 Phase 9: a **24-hour fuzz run with zero
  crashes** before the release wave closes (per-wave bar: the existing
  short fuzz pass stays clean).

### 5.7 Risks to quality discipline (upgrade-specific)

| Risk | Mitigation |
|---|---|
| Golden churn from evaluation changes (one easing tweak moves every animation golden → pressure to blanket re-pin) | Numeric fixtures *below* the pixel layer (`timeline_vectors.json` joint angles/poses, tight tolerances) so a change first appears as an explainable *numbers* diff; re-pins only per the V3-GOLDENS procedure, one cause per commit; static-scene goldens must never move — a wave that moves one is automatically suspect |
| Float nondeterminism in slerp across fps | Absolute-time pure evaluation (§4.2); the fps-independence gate (§5.3.3); adversarial near-parallel-quaternion fixtures (slerp's nlerp fallback branch is threshold-sensitive) |
| Transition blending breaks thread determinism | Transition frames = a defined sequential blend over two independently deterministic scene renders; G3d pins the transition *midpoint* at threads 1 vs 8 |
| Subtitle/text rendering variance | Hash-gated only within the native renderer; timing/content tested at IR level (data, not pixels) so most dialogue regressions never reach the pixel layer |
| Loops/variables make compiles stateful | Desugar fully unwinds/bounds loops at compile time where possible; runtime loops get hard limits with diagnostics (fuzz-enforced); cache-hit vs `--force` byte-equality gate |
| IR contract drift under deadline pressure | Contract freeze at Wave 2 close + ADR-5 additive-only rule + pinned IR fixtures + the host-simulation test *in CI* (the consumer is in CI, as a test) |
| Plain-word ambiguity (`after` relative to what?) | Every plain-word form has a numeric twin case asserting identical IR; ambiguous forms are diagnostics, never guesses; `fuzz_desugar` checks equivalence mechanically |
| Scope creep eating the hardening wave | Wave 6 is feature-frozen by definition; exit criteria are gates, not aspirations — a wave with red gates is not complete |

---

## 6. Wave plan

Mirrors the V3-PLAN structure: scope, explicit exit criteria, and what
is NOT in the wave. Per-wave quality gates (every wave close, from
V3-PLAN): full `run_tests.sh` green; legacy golden unchanged; v3+v4
goldens within their rules; commit(s) + push with CI watched to
completion; hash-change manifest for any baked expectation that moved,
with cause; zero Python.

### Wave 1 — Language + compiler front-end
- **Scope:** the §1 grammar (film mode, characters, actions, cues,
  camera moves, dialogue, transitions as nodes, loops, `let`) through
  parser → typed AST (§2.1) → desugar with timeline resolution (§2.2) →
  validator incl. the new timeline section and E206–E213/W203–W204
  (§2.3–2.4). Emits existing `.scene`/JS formats only — animated output
  rides the current keyframe path and the `dialogue`/`camera_track`
  scene extensions. Includes the §2.5 cache fixes (runtime dep list,
  dep-cap) and the §2.6 invariant tests (round-trip generators,
  double-desugar diff).
- **Exit criteria:** corpus categories for syntax/desugar green with
  artifact hashes; property sweep covers every new statement kind;
  error-code census includes every new code with a minimal failing
  input; full suite green; legacy pins + G3a/G3b/G3c unchanged; zero
  corpus drift outside the new `anim_cases` section.
- **NOT in this wave:** Timeline IR emission; stickman rig in the
  engine; any new renderer behaviour; preview/export changes.

### Wave 2 — Timeline IR contract (freeze early — StykAnimate depends on it)
- **Scope:** Timeline IR v1 per §3: schema + `docs/TIMELINE-FORMAT.md` +
  **ADR-5**; `f3dc` emits `.timeline.json`; the engine gains a typed,
  version-gated IR *reader* (ADR-3 pattern). The full §5.5 contract
  layer lands, including the host-simulation consumer and the §3.7
  conformance kit.
- **Exit criteria:** all §5.5 tests green; golden IR fixtures pinned; IR
  byte-determinism gate in CI; every Wave-1 corpus case compiles to
  schema-valid IR; full suite green; all prior pins unchanged.
  **Contract freeze is declared at this wave's close** — later waves add
  IR fields only per ADR-5's additive rule.
- **NOT in this wave:** engine-side character evaluation (IR is produced
  and readable, not yet the engine's animation source); preview playback
  of IR; any IR v2 features.

### Wave 3 — Engine: stickman characters + animation evaluation
- **Scope:** `char_figure.f90` (FK + proportions), the Approach-A figure
  mesh (capsules + disc head, unlit material, yaw billboard) as an
  ordinary scene object; the §4.2 evaluation layer (joint tracks,
  `ActionClip` instances + blending, `CamTrack`, `DialogueSpan`);
  multi-scene sequencing + transition blending in the render loop; the
  JS runtime gains the matching evaluator over shared
  `timeline_vectors.json`, including the `key_eval_q` mirror upgrade.
- **Exit criteria:** new Fortran test programs green; **G3d + G3e live
  in CI** with pinned timestamps; threads 1 vs 8 identical on all
  animation goldens; fps-independence gate green; full suite green;
  legacy + v3 static goldens all reproduce exactly (animation moves zero
  static pixels); any perf regression > 10% vs v3 baselines on static
  bench scenes carries a written reason in the wave report.
- **NOT in this wave:** preview playback UI; video export; imported
  character models or custom rig topologies (fixed topology,
  user-definable proportions only — D6).

### Wave 4 — Preview playback
- **Scope:** §4.4 in full: transport (play/pause/seek/scrub + hash
  playhead), `/__timeline` route, subtitle overlay + action lanes,
  diagnostics drawer via `/__status`. Playback uses the Wave-3 JS
  evaluator — no second timing implementation.
- **Exit criteria:** ≈ 15 new e2e playback checks, including
  scrub-to-t frame hash parity with the G3d golden frame at the same t
  (preview/native parity by hash at pinned timestamps, PSNR between);
  same t requested twice → identical frame; existing preview tests +
  the sanitize job's preview harness green; full suite green.
- **NOT in this wave:** video export; audio; editing (preview stays a
  viewer — editing is StykAnimate's job, via the IR).

### Wave 5 — Video export
- **Scope:** §4.5: v3 rows added to `docs/bench/BASELINES.md` first
  (measured, not extrapolated); the `--video` path hardened for
  animation — full-timeline render at film fps, `.srt` sidecar from the
  dialogue tracks, transitions rendered through, deterministic frame
  sequence, write-failure detection with non-zero exit, documented
  ffmpeg-absent behaviour (frames-only + loud warning, never silent).
- **Exit criteria:** e2e export test — a ≤ 2 s golden script exports and
  every exported frame's hash matches the corresponding G3d/G3e pinned
  frame (export is a render, not a re-implementation); export run twice
  → identical sequence digest; missing-ffmpeg path tested; full suite
  green.
- **NOT in this wave:** audio tracks/mixing; codecs beyond the existing
  ffmpeg pipe; upscaling.

### Wave 6 — Verification + release
- **Scope:** no new features. Full verification pass in the v3 style:
  entire suite counted per layer (native corpus incl. anim cases, JS,
  e2e, Fortran programs, IR contract layer, fuzz layer); 24-hour fuzz
  run over all harnesses incl. the three new ones; debug and sanitize
  CI jobs green; docs (`manual.md`, `docs/TIMELINE-FORMAT.md`, this
  plan's status log + finding-closure table), CHANGELOG, version bump,
  tag + GitHub Release with Linux assets built from the tagged tree
  (the v3.0 release pattern — created only on the user's nod).
- **Exit criteria:** all four CI jobs green at job/step level on the
  release commit, verified twice; every golden in `V3-GOLDENS.md` +
  `V4-GOLDENS.md` reproduces; legacy hash `28b6a81d…` still exact; zero
  Python; release assets verified by downloading them back and running
  the G3d scene.
- **NOT in this wave:** any feature work; any re-pin not already
  reviewed in Waves 1–5.

Dependency order: W1 → W2 → W3 → W4 and W5 (W5 needs only W3 and may
parallel W4) → W6. Wave 2 is deliberately small and early: its whole
purpose is freezing the contract before engine work creates pressure to
bend it.

---

## 7. Decisions taken in this plan (reversible, with rationale)

- **D1 — Desugar owns timeline resolution; the validator never sees a
  `then`.** Only desugar still has definitions + source order; resolving
  there keeps every downstream consumer on today's node shapes (§2.2).
- **D2 — Master clock:** the timeline defines a scene's duration unless
  the render states one explicitly; an explicit duration the timeline
  exceeds is E208. Keeps old scenes byte-identical.
- **D3 — One cursor per timeline block** (not per character): `then`
  follows whatever came before, matching how scripts are written;
  per-character chaining remains expressible via `after <cue>`.
- **D4 — Overlap strictness:** same-character same-channel overlap is an
  **error** (E207), cross-channel is free, `with` is the explicit
  opt-in. A warning would invite timelines that render differently from
  what the author pictured, with no signal.
- **D5 — Variables are literals + references only** (`let x be …`,
  scene-scoped, immutable, desugar-substituted). `let` is un-reserved
  from E205 for this form. Arithmetic would need an expression AST
  neither the typed AST nor the props-bag design has — a separate
  design if ever wanted.
- **D6 — Stickman rig: fixed joint topology, user-definable
  proportions** (limb lengths, colours, head style). Fully custom
  topologies multiply the rig-test matrix and threaten Wave 3 without
  changing the IR contract.
- **D7 — Subtitles: preview overlay + `.srt` sidecar; burn-in only as
  an ffmpeg-step option**, never via engine text geometry (which would
  flip scenes to the legacy renderer, §4.6).
- **D8 — Easing registry is shared and spec'd:** the IR carries
  Forge3D's closed ease set with ends-at attachment; the host's
  starts-at convention is converted once, at import (§3.4, §3.7).

---

## 8. Open questions for the user (rulings needed before/during build)

1. **Q1 — Version number: ship as v4.0.0 (recommended) or v3.1.0?**
   A new public contract (Timeline IR) + a new language surface is a
   major by this project's own precedent (v2 = native break, v3 =
   pipeline break). v3.1 is defensible only if the IR is labelled
   experimental — but then StykAnimate shouldn't build on it yet.
2. **Q2 — Film mode + sequential cues: approve the core bet?**
   `film` as the opt-in first statement, cues playing in written order,
   parallelism only via `with`/`together` (recommended). This is the
   entire readability win; legacy files are unaffected either way. (The
   name `film` vs `story`/`video` rides with this ruling —
   recommendation: `film`.)
3. **Q3 — Characters declared once per film (recommended) or
   re-declared per shot?** Today's rule is that nothing carries between
   `scene` blocks, which forces Script C's re-declaration and risks
   identity drift. Recommendation: allow film-level declaration;
   a shot-level `character lloyd at 3 0 2` then overrides *placement
   only* — identity stays film-level and enforceable.
4. **Q4 — Dialogue scope in v1: bubble + subtitle, no voice (TTS)?**
   Recommendation: yes — bubble + subtitle + timing only. Voice
   (especially Bengali + English voices for the channel) is a
   quality/cost decision to make on samples, not bundled into the
   language ruling.
5. **Q5 — Stickman look: approve Approach A with its three defaults?**
   Procedural capsule figure + disc head, yaw-only billboarding with an
   authored facing offset, world-space line weight (thins with
   distance). Recommendation: approve, and judge from a rendered test
   shot in Wave 3 before considering the screen-space line pass
   (Approach C).
6. **Q6 — Transitions: metadata + assembly (recommended for this
   upgrade) or whole-file compilation?** Today scenes build as
   independent chunks; transitions can be (a) per-chunk metadata
   honoured by the player/export assembly, or (b) a reason to compile
   the whole file as one program with one master timeline — which
   rewrites `do_build`, the manifest story, and the "scenes are
   self-contained" contract. Recommendation: (a) now; revisit only if
   true cross-fades between scene *renders* are wanted.
7. **Q7 — StykAnimate's first integration: import-and-bake via CLI
   artifacts (recommended)?** Including its corollaries: 3D-only data
   (depth, out-of-plane rotation, scene geometry) is report-and-drop in
   v1; no IR round-trip (`.f3d` is the author's truth, `Project` JSON is
   the host's); Forge3D owns the versioned action/rig-channel registry;
   and the pipeline's default fps is **24** on both sides (host default
   is 12, engine default 30 — the contract supports any rational rate,
   but one default keeps the resample path the exception). This ruling
   is only needed before the *host* work starts, not before Waves 1–5.

---

## Status log

- 2026-11-26 — Design pass completed (5 areas, integrated here).
  Awaiting the user's rulings on §8 and approval to start Wave 1.
  On approval, this plan's wave table becomes the build programme;
  ADR-5 is written at Wave 2 start; `docs/V4-GOLDENS.md` and
  `docs/TIMELINE-FORMAT.md` are created in their waves.
