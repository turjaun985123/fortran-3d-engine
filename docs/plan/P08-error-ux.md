# P08 — Error-Message UX: Errors Are the User Interface

> **Goal linkage:** "Unbelievably easy compiler." For a first-time user, the compiler
> is not the grammar, the flags, or the renderer — it is the first error they hit.
> A user who understands an error in 10 seconds and fixes it in one edit stays.
> A user who gets `STOP 1`, a gfortran backtrace, or a silently wrong picture leaves.
> **This plan treats every diagnostic as a designed product surface, with tests.**

Status: planning only. No code in this document is implemented.

---

## 0. Ground truth today (verified in this repo, 2026-11-23)

There is currently **no scene-language parser and no diagnostic system at all**:

| Fact | Where |
|---|---|
| Scene is hard-coded: cube, camera `(3.0, 2.5, 4.0)→(0,0,0)`, `fov=60`, `640×480`, `near=0.1`, `far=100`, output `output_render.ppm` | `src/main.f90` |
| `camera_init(cam, pos, target, fov_deg, aspect, near, far)` performs **zero validation** — `fov=0`, `fov=300`, `near >= far`, `eye == target` are accepted and produce division-by-zero / garbage in `mat4_perspective` (`src/math_3d.f90`: `tan(fov/2)`, `1/(aspect*tan_half_fov)`) | `src/camera.f90`, `src/math_3d.f90` |
| Colours are `integer :: color(3) = [255,255,255]`, face colours hard-coded in `0..255` | `src/mesh.f90` |
| Out-of-range colour is **silently clamped**, not reported: `min(255, max(0, int(...)))` in `draw_triangle` | `src/renderer.f90` |
| Failures today surface as: gfortran compile errors (for engine contributors), runtime `allocate`/IO aborts, or a wrong/black image with no message | — |

**Implication for sibling plans:** whichever plan defines the scene DSL
(keywords, colour syntax, block structure) must reserve the hooks in §3–§4
(source spans on every token/node, a single diagnostic sink). Retrofitting
spans after the parser exists is the expensive path; emitting them from day
one is nearly free. Keyword/value spellings in the examples below follow the
vocabulary implied by the current engine (`camera`, `cube`, `color`, `fov`,
`position`, `look_at`, `size`, `near`, `far`); if a sibling plan renames a
keyword, the *mechanism and wording patterns* here are unchanged.

**Non-goals:** not a logging framework, not gfortran-error restyling (engine
contributors still see raw gfortran), not localisation in v1 (but see §9:
no sentence is built by string concatenation, so localisation stays possible).

---

## 1. Principles (the contract every diagnostic must pass)

1. **Say what happened, where, why it matters, and how to fix it** — in that
   order, in plain words. Never only one of the four.
2. **Point at the user's text, not at our code.** File, line, column, and the
   offending characters underlined. Never a Fortran line number, module name,
   or backtrace for a *scene* error.
3. **One idea per error, user's vocabulary.** `fov` is explained as
   "field of view — how wide the camera sees" the first time it appears.
   No jargon without a one-line gloss; no internal terms (`token`, `AST`,
   `framebuffer`, `mat4`) in user-facing text.
4. **Suggest, don't just reject.** Where a plausible intended value exists,
   name it and show the corrected line. A suggestion the user can copy-paste
   beats a paragraph.
5. **Never guess silently, never clamp silently.** Today's silent colour
   clamp in `renderer.f90` is the anti-pattern: if we fix a value for the
   user, we say so as a warning; if we can't, we error. No silent changes.
6. **Errors block, warnings don't — and the line is semantic.** Anything that
   would produce a wrong, black, or misleading image is an *error*. Anything
   that renders correctly but is probably unintended is a *warning*.
7. **Show, don't describe, the fix.** Every error carries at least one
   concrete `help:` line with a literal replacement, value, or block to paste.
8. **Be brief first, deep on demand.** Default output ≤ ~12 lines per error.
   `--explain E0301` / the docs page carries the long version (§6).
9. **Stable forever.** Error codes, once shipped, are never reused or
   renumbered; wording may improve, codes and meanings may not (§6).
10. **Accessible by construction.** Meaning never carried by colour alone;
    output is complete and unambiguous in plain `NO_COLOR`/piped mode (§5.3).

### The 10-second test (acceptance shorthand)

> A new user, seeing the error for the first time, can (a) say what they did
> wrong, (b) find the exact characters to change, and (c) make the fix —
> without a search engine — in under 10 seconds for the 10 cases in §8.

---

## 2. Anatomy of a diagnostic

Every user-facing diagnostic, without exception, has these parts:

```
error[E0301]: fov is 300, but a camera can only see between 1 and 179 degrees
  --> scene.t3d:4:14
   |
 4 |   camera { fov: 300 }
   |                ^^^ the value you wrote
   |
   = why: at 180 degrees or more the picture folds inside-out; at 0 the
     camera sees nothing at all.
   = help: change it to a value in range — 60 is a natural-looking default:
 4 |   camera { fov: 60 }
   |
   = see:  engine3d --explain E0301
```

| Part | Rule |
|---|---|
| Header | `error`/`warning` + `[CODE]` + one sentence: **the actual value + the constraint**, not a category ("invalid value" is banned). Present tense, no exclamation marks, no "Error: Failed to…" nesting. |
| Location | `--> file:line:col`, 1-based, column = first character of the offending span. Relative path as the user typed it. |
| Source snippet | The line itself, line-number gutter, span underlined with `^^^` (primary) / `---` (secondary/related span). At most 3 lines of context; long lines truncated around the span with `…`. Tabs expanded before measuring columns. |
| Label | Short phrase on the underline naming the span's role ("the value you wrote", "opened here"). |
| `why:` | Optional but required for non-obvious constraints (ranges, `near < far`, `eye != look_at`): one sentence on the *consequence*, not the implementation. |
| `help:` | Mandatory. A literal fix: corrected line, value to insert, or block to paste. If two fixes are equally likely, list at most two, labelled. |
| `see:` | The error code's explain command / docs anchor. |
| Footer (once per run) | Summary + next action: `✗ 2 errors, 1 warning — nothing was rendered.` / `✓ rendered output_render.ppm (1 warning above)`. Never claim success on error. Exit status per §7. |

**Multi-span errors** (mismatched brace, `near >= far`, duplicate definition):
show the primary span first, then one secondary span with its own label
("…and the camera block opened here"). Cap: 2 spans per diagnostic.

---

## 3. Where diagnostics come from: pipeline hooks

One sink, every stage. No stage prints to stdout/stderr directly.

```
read file ──▶ lex ──▶ parse ──▶ validate (semantic/range) ──▶ render
   │           │        │              │
   └───────────┴────────┴──────────────┴──▶  diag collector  ──▶ render once, sorted by (file, line, col)
```

| Stage | Owns | Examples |
|---|---|---|
| IO | E5xx | file not found, unreadable, empty file |
| Lexer | E1xx | unterminated string, stray character, bad number literal |
| Parser | E1xx/E2xx | missing `}`, missing `:`, unknown keyword (with did-you-mean) |
| Validator | E2xx–E4xx | unknown colour, out-of-range value, missing `camera`, duplicates, `near >= far`, `eye == look_at` |
| Renderer guards | E3xx (defence in depth) | `camera_init` / `framebuffer_init` re-check their preconditions and report through the same sink instead of dividing by zero — this is the fix for today's unvalidated `camera_init` |

### 3.1 The diagnostic record (implementation sketch, Fortran)

Spans are carried from the lexer onward; a diagnostic is data, not a print.

```fortran
type :: span_t
  integer :: line, col_first, col_last   ! 1-based; col_last inclusive
end type

type :: diag_t
  integer       :: severity        ! SEV_ERROR=1, SEV_WARNING=2
  character(5)  :: code            ! "E0301" / "W0202" — stable, see §6
  character(:), allocatable :: message      ! header sentence, values interpolated
  character(:), allocatable :: filename
  type(span_t)  :: primary
  type(span_t), optional :: secondary
  character(:), allocatable :: label, why, help_text, help_replacement
  character(:), allocatable :: suggestion   ! did-you-mean candidate, if any
end type

type :: diag_list_t          ! collector: add(), has_errors(), sorted render()
  type(diag_t), allocatable :: items(:)
end type
```

Rules: (a) validation **never** `stop`s on first failure — it collects;
(b) rendering of diagnostics happens in exactly one module
(`src/diag.f90`, proposed) so wording, alignment, and colour policy cannot
drift between call sites; (c) engine-internal bugs use a separate path —
`internal error [E9000]` + "this is a bug, please report it" + the Fortran
backtrace — and are visually distinct so users never blame themselves for one.

### 3.2 Error recovery & counts

- **Parser recovery:** on a syntax error, skip to the next plausible block
  boundary (`}` / next top-level keyword) and continue, so one missing brace
  does not hide three later typos.
- **Caps:** report at most **10 errors**; then
  `…and 14 more errors (stopped after 10) — fix the first ones and re-run; later errors often disappear.`
  Warnings uncapped but summarised by code if > 5 of one kind.
- **Cascade suppression:** if a value failed to parse, do not also emit its
  range error; if `camera` is missing entirely, do not emit per-field camera
  errors. One root cause = one error (plus at most one "consequence" note).
- **Ordering:** file order (line, then column), not discovery order — the
  user fixes top-down.
- **Warnings never become errors** under a default flag; `--strict` promotes
  warnings for CI users only, and says so in the footer when active.

---

## 4. Did-you-mean suggestions

### 4.1 Algorithm

- Candidate sets are **closed and known**: DSL keywords, block names,
  colour names, property names inside the current block, and identifiers the
  user themselves defined earlier in the file (object names).
- Distance: **Damerau–Levenshtein** (transposition counts as 1 — `camrea`,
  `colro` are the most common real typos) on lower-cased strings; also try
  (a) prefix match, (b) `-`/`_`/space equivalence (`look_at` vs `lookat` vs
  `look at`), (c) a small hand-maintained alias/confusion table
  (`colour → color`, `centre → center`, `fov` expansions, `rgb(...)` forms).
- Threshold: distance ≤ 2 for words ≥ 4 chars, ≤ 1 for shorter; prefix match
  of ≥ 3 chars also qualifies. **At most one** suggestion shown as
  "did you mean"; if two candidates tie, show both as a short list and do
  not auto-pick. If none qualifies, no suggestion — a wrong confident
  suggestion is worse than none (show the valid-options list instead, §4.3).
- Case-only difference (`Color:` vs `color:`) is a special, certain case:
  suggest with "keywords are lower-case" and count it as a fixable warning
  only if the rest of the line parses unambiguously — otherwise error.
- Suggestions are **never auto-applied** in v1. (A future `--fix` may apply
  only the certain classes: case-only, unique distance-1 keyword, missing
  closing brace at EOF — out of scope here, must be opt-in and diff-printed.)

### 4.2 Where suggestions apply

Keywords (`camra`), properties (`postion`), colour names (`gren`, `teal`
is valid — see list), enum values, defined-name references, and CLI flags
(`--ouput` → `--output`, `--explain` for mistyped codes: `E301` → `E0301`).

### 4.3 When there is no near match: list the world

For an unknown keyword/colour/property, after the header show the valid set
if it is small (≤ 12 entries, e.g. named colours, properties of `camera`),
otherwise the category + explain pointer:
`help: this block can contain: position, look_at, fov, near, far`.
The user should never need the manual to discover the legal vocabulary.

---

## 5. Formatting, colour, and machine-readable output

### 5.1 Terminal rendering
- Gutter width adapts to the largest line number shown; snippets aligned
  across all diagnostics in a run.
- Underline length = span length (min 1). For a missing thing (missing
  `camera`, missing `}`), the span is the *insertion point*: a single `^`
  with label "add it here" plus the paste-ready block in `help:`.
- Numbers always shown as the user wrote them (`300`, not `3.0E+02`);
  ranges shown inclusive/exclusive honestly (`1 to 179`, `0 to 255`).

### 5.2 Colour & TTY policy
- Colour only when stderr is a TTY and `NO_COLOR` unset and `--color=never`
  not passed: `error` bold red, `warning` bold yellow, underline matching,
  `help:` green. `--color=auto|always|never`, default `auto`.
- Diagnostics go to **stderr**; the render progress/success summary stays on
  stdout, so `engine3d scene.t3d 2>errors.txt` works and piping never mixes
  a broken PPM path with error text.

### 5.3 Plain mode is the spec, colour is decoration
Piped/`NO_COLOR` output must contain **identical information** (the ASCII
format in §2 is the canonical one). No meaning by colour alone; `error` and
`warning` are words, not just hues. This plain format is what golden tests
assert (§10).

### 5.4 Machine-readable output: `--diagnostics=json`
One JSON object per diagnostic (JSON Lines) with
`{code, severity, message, file, line, col_first, col_last, label, why, help, suggestion}` —
for editors, the `viewer.html` successor, and CI. Same collector, second
renderer; wording identical to the text `message`. Exit codes unchanged.

---

## 6. Error codes: scheme, catalogue, and `--explain`

### 6.1 Scheme

`E` = error, `W` = warning; digits: `1xx` syntax/lexing, `2xx` unknown or
misused names, `3xx` values & ranges, `4xx` structure (missing/duplicate/
conflicting), `5xx` files & IO, `9xx` internal. Codes are **append-only**:
deprecated codes keep their page and say what replaced them.

### 6.2 Initial catalogue (v1 — every code below must have an explain page)

| Code | Meaning | Sev |
|---|---|---|
| E1001 | Unterminated string | error |
| E1002 | Unexpected character | error |
| E1003 | Missing `}` / block not closed | error |
| E1004 | Missing `:` or `=` after a property name | error |
| E1005 | Expected a number, found text/other | error |
| E1006 | Missing comma / separator in a list `[…]` | error |
| E2001 | Unknown keyword (did-you-mean attached when §4 qualifies) | error |
| E2002 | Unknown property for this block | error |
| E2003 | Unknown colour name | error |
| E2004 | Reference to an object name that was never defined | error |
| E3001 | `fov` out of range (1–179) | error |
| E3002 | Colour component out of range (0–255) / bad hex colour | error |
| E3003 | Image `size` invalid (each dimension 16–8192, positive) | error |
| E3004 | `near`/`far` invalid (`0 < near < far`) | error |
| E3005 | Scale/size value ≤ 0 where a positive size is required | error |
| E3006 | Opacity/percent value out of range (0–1 / 0–100, per DSL) | error |
| E4001 | Missing required `camera` block | error |
| E4002 | Missing required property inside a block (e.g. camera `position`) | error |
| E4003 | Duplicate block/property/name (second definition shown as secondary span) | error |
| E4004 | Camera `position` equals `look_at` (camera looks at itself) | error |
| E4005 | Empty scene (no objects to render) | error |
| E5001 | Scene file not found | error |
| E5002 | Scene file unreadable / is a directory / empty | error |
| E5003 | Referenced model file (`.obj`) not found or unparseable | error |
| E5004 | Output path not writable | error |
| W2001 | Keyword/property with wrong case, accepted reading is unambiguous | warning |
| W3001 | Value accepted but suspicious (e.g. `fov` 170–179, image > 4096 wide: slow) | warning |
| W3002 | Colour/number value clamped by an explicit user-facing rule (never silent — replaces today's silent clamp behaviour at the DSL layer) | warning |
| W4001 | Object defined but never visible / placed entirely behind camera | warning |
| W4002 | Property repeated with same value / block has no effect | warning |
| E9000 | Internal error (bug report wording, distinct format, §3.1) | error |

### 6.3 `--explain E0301` and docs
Each code gets: one-paragraph cause, a minimal failing example, the fixed
example, and "common causes" bullets. `engine3d --explain E0301` prints it
offline; the same text lives in `docs/errors/E0301.md` (proposed) and is
generated from one source so CLI and web never diverge. Mistyped codes get
did-you-mean (§4.2). `--explain` with no argument lists codes by category.

---

## 7. Exit codes & run summary

| Exit | Meaning |
|---|---|
| `0` | Rendered (warnings allowed, counted in footer) |
| `1` | Scene errors (any `Exxxx`); nothing rendered; footer says so |
| `2` | Command-line misuse (unknown flag etc., with did-you-mean + usage line) — deliberately distinct so scripts can tell "my flags" from "my scene" |
| `3` | IO failure (E5xx) |
| `70`-style internal | E9000 only (document the chosen value in `--help`; do not reuse 1–3) |

Footer examples: `✗ not rendered: 2 errors in scene.t3d — fix E2001 first (line 3).`
(first = lowest line, since fixing top-down usually cascades least).

---

## 8. The 10 common mistakes: bad vs good

"Bad" = what a naive implementation (and today's engine behaviour) produces.
"Good" = the required output under this plan. Scene language is illustrative
per §0. All "good" blocks must become golden tests verbatim (§10).

### 1. Typo'd keyword — `camra` (E2001, did-you-mean)

```scene
camra { position: [3, 2.5, 4] }
```
❌ Bad: `Parse error at line 1.` / `STOP 1`
✅ Good:
```
error[E2001]: unknown word 'camra'
  --> scene.t3d:1:1
   |
 1 | camra { position: [3, 2.5, 4] }
   | ^^^^^
   |
   = help: did you mean 'camera'? A scene starts its camera like this:
 1 | camera { position: [3, 2.5, 4] }
   = see:  engine3d --explain E2001
```

### 2. Bad colour name — `color: gren` (E2003, did-you-mean + valid list)

```scene
cube { color: gren }
```
❌ Bad: `Invalid color.` (or silently rendering white, the `mesh.f90` default)
✅ Good:
```
error[E2003]: there is no colour called 'gren'
  --> scene.t3d:2:15
   |
 2 | cube { color: gren }
   |               ^^^^
   |
   = help: did you mean 'green'? Or use any of: red, green, blue, yellow,
     magenta, cyan, white, black, orange, purple — or a custom colour
     like color: [220, 60, 60] or color: #dc3c3c
   = see:  engine3d --explain E2003
```
(The named list mirrors the face colours already used in `mesh.f90`.)

### 3. Colour component out of range — `color: [300, 60, 60]` (E3002)

❌ Bad: silently clamped to 255 by `draw_triangle`'s `min(255, max(0, …))` —
user never learns why their colour looks wrong.
✅ Good:
```
error[E3002]: colour value 300 is too big — each part of [red, green, blue] must be 0 to 255
  --> scene.t3d:3:16
   |
 3 | cube { color: [300, 60, 60] }
   |                ^^^ the red part
   |
   = why: 255 is full brightness. Larger numbers cannot be stored in the
     picture, so guessing one would change your colour without telling you.
   = help: use 255 for the brightest red:  color: [255, 60, 60]
     (percentages work too if you meant 30%: color: [76, 60, 60] is 30% of 255)
   = see:  engine3d --explain E3002
```

### 4. Missing camera (E4001, missing-thing span + paste-ready fix)

```scene
cube { color: red }
```
❌ Bad: black image rendered successfully; or crash in projection.
✅ Good:
```
error[E4001]: this scene has no camera, so there is nothing to take a picture from
  --> scene.t3d:1:1
   |
   = help: add a camera block — this one works for most first scenes:
     camera {
       position: [3, 2.5, 4]
       look_at:  [0, 0, 0]
       fov: 60
     }
   = see:  engine3d --explain E4001
```
(No snippet line: for whole-file absences, omit the fake span rather than
underlining line 1 misleadingly; location is the file itself.)

### 5. Out-of-range value — `fov: 300` (E3001)

❌ Bad: accepted by today's `camera_init`; `tan(150°)` produces an
inside-out/garbage image with exit 0.
✅ Good: the §2 example verbatim — value, range `1 to 179`, why (folds
inside-out / sees nothing), and `fov: 60` as the suggested fix.
Boundary wording matters: `fov: 180` and `fov: 0` get the same code with the
specific edge named ("180 is a flat line, not a view"); `fov: 175` renders
with **W3001** ("very wide — edges will look stretched") instead of an error.

### 6. Missing closing brace (E1003, two spans)

```scene
camera {
  position: [3, 2.5, 4]
```
❌ Bad: `Unexpected end of file.` (where? which of 4 blocks?)
✅ Good:
```
error[E1003]: this block is never closed — the '}' is missing
  --> scene.t3d:1:8
   |
 1 | camera {
   |        ^ opened here
   |
   = help: add '}' on its own line after the last camera property:
 3 |   fov: 60
 4 | }
   = see:  engine3d --explain E1003
```

### 7. Wrong type — `size: "big"` (E1005, expected vs found + examples)

❌ Bad: `Type error.` / Fortran `Bad real number in item 1 of list input`.
✅ Good:
```
error[E1005]: size needs two numbers, but you wrote the word "big"
  --> scene.t3d:5:14
   |
 5 | render { size: "big" }
   |                ^^^^^ expected something like [640, 480]
   |
   = help: pick a size in pixels, width then height — common choices:
     size: [640, 480]   (the default)   size: [1280, 720]   (HD)
   = see:  engine3d --explain E1005
```
(Range failures on numeric sizes — `0`, `-100`, `99999` — are E3003, with
"each side must be 16 to 8192" and a memory note for very large sizes.)

### 8. File not found (E5001, did-you-mean on the filename + cwd honesty)

```console
$ engine3d scnee.t3d
```
❌ Bad: `open: No such file or directory` / Fortran runtime backtrace.
✅ Good:
```
error[E5001]: I can't find the file 'scnee.t3d'
   |
   = why: I looked in the current folder: /home/you/project
   = help: did you mean 'scene.t3d'? Run:  engine3d scene.t3d
     Or create a starter scene:  engine3d --new scene.t3d
   = see:  engine3d --explain E5001
```
(Filename suggestions: same directory listing + §4 distance; never suggest a
file that does not exist. Same pattern covers E5003 for a missing `.obj`.)

### 9. Contradictory camera — `near: 10, far: 1` / position == look_at (E3004 / E4004)

❌ Bad: accepted today; near/far feed `mat4_perspective` unchecked → empty or
inverted depth, black output, success exit.
✅ Good:
```
error[E3004]: 'far' (1) must be bigger than 'near' (10)
  --> scene.t3d:4:3
   |
 3 |   near: 10
   |         ^^ this one…
 4 |   far: 1
   |        ^ …is smaller than this one
   |
   = why: the camera only draws things between near and far. With these
     values that space is empty, so the picture would be blank.
   = help: swap them, or use the defaults:  near: 0.1   far: 100
   = see:  engine3d --explain E3004
```
`position` equal to `look_at` is E4004 with the same shape: both spans shown,
"a camera cannot look at the place it is standing", help = move one of them
(suggest `position: [3, 2.5, 4]`).

### 10. Duplicate definition — two `camera` blocks (E4003, both spans)

❌ Bad: last-one-wins silently (user edits the first camera forever, nothing
changes — the most demoralising class of bug for a beginner).
✅ Good:
```
error[E4003]: there are two 'camera' blocks — a scene can only have one
  --> scene.t3d:8:1
   |
 8 | camera {
   | ^^^^^^ the second camera
   |
 1 | camera {
   | ------ the first camera is here (line 1)
   |
   = help: delete one of them, or merge their properties into one block.
   = see:  engine3d --explain E4003
```
Same code/pattern for a repeated property (`fov` twice) and a re-used object
name; the secondary span always points at the first definition.

**Honourable mentions (same machinery, not counted in the 10):**
unterminated string `color: "red` (E1001, span to end of line, "add the
closing `\"`"); British spelling `colour:` (alias table → E2002 with
"did you mean 'color'?" — and docs acknowledge the spelling); empty file
(E5002: "the file is empty — here's a starter scene", not "parse error at
line 1"); object behind camera (W4001 warning, renders anyway).

---

## 9. Wording style guide (enforceable in review)

- **Vocabulary:** sentences a 12-year-old reads once. Banned in user text:
  `invalid` (say what's wrong instead), `token`, `lexeme`, `operand`,
  `segfault`, `allocate`, `unit`, `EOF` (say "end of the file"),
  `illegal`, `malformed`, `syntax error` as a standalone message.
- **Voice:** the program speaks as a helper ("I can't find…"), never blames
  ("you failed to…"), never apologises profusely, never uses `!`.
- **Numbers:** always show the user's actual value and the allowed range/set
  in the same sentence. Units spelled out ("degrees", "pixels").
- **Length:** header ≤ 100 chars; `why:` ≤ 2 lines; `help:` ≤ 3 lines before
  the corrected example. Long explanations live behind `--explain`.
- **Templates, not concatenation:** each code owns one message template with
  named slots (`{value}`, `{range}`, `{suggestion}`). This keeps wording
  reviewable in one file, golden-testable, and translatable later.
- **Consistency lint (proposed check):** a test greps all templates for the
  banned-word list and asserts every template has a `help` slot.

---

## 10. Testing the UX itself

Errors that aren't tested regress silently. Required, all cheap:

1. **Golden files:** one `.t3d` fixture + expected plain-mode stderr per code
   in §6.2 (the 10 in §8 first). Test = run, diff stderr + exit code exactly.
   Colour mode tested once via forced `--color=always` snapshot with ANSI
   codes normalised, plus a `NO_COLOR` run asserting zero escape bytes.
2. **Suggestion tests:** table-driven typo corpus (≥ 3 typos per keyword/
   colour: deletion, transposition, substitution, case) asserting the
   intended suggestion — and negative cases (`xyz`) asserting *no* suggestion.
3. **No-crash sweep:** every golden fixture, plus truncations of a valid
   scene at every byte offset, must exit 1/2/3 with a diagnostic — never a
   Fortran backtrace, never exit 0, never a rendered file. (This directly
   retires today's unvalidated-`camera_init` failure mode.)
4. **No-silent-change test:** any input the validator "fixes" (case, clamp)
   must appear as a warning in output; assert on fixtures from §8.3/§8.10.
5. **Human check before v1 ships:** the §1 10-second test run with ≥ 3
   first-time users on cases 1, 3, 4, 5 only; record pass/fail in the plan's
   successor doc. Automated goldens cannot prove comprehension.

---

## 11. Implementation phases (for the implementing agent)

| Phase | Scope | Acceptance |
|---|---|---|
| 1 | `diag_t` collector + plain renderer + exit codes; IO (E5xx) and validator ranges (E3xx) wired into `camera_init`/`framebuffer_init` guards | §8 cases 3, 5, 8, 9 golden-pass; no scene input can reach `mat4_perspective` unvalidated |
| 2 | Lexer/parser spans + E1xx/E2xx + recovery/caps/cascade rules | §8 cases 1, 6, 7 golden-pass; truncation sweep (§10.3) passes |
| 3 | Did-you-mean engine (§4) + structure checks E4xx + all W-codes | §8 cases 2, 4, 10 golden-pass; suggestion corpus (§10.2) passes |
| 4 | `--explain` + `docs/errors/*.md` generation, `--diagnostics=json`, `--color`/`NO_COLOR` | every §6.2 code has a page; JSON schema matches §5.4; colour snapshots pass |
| 5 | Human 10-second test (§10.5); wording pass against §9 | recorded results; banned-word lint green |

**Dependencies/risks:** Phase 2+ depends on the DSL/parser plan landing with
span-carrying tokens (§0 — flag this to that plan's owner early; it is the
single biggest cost risk in this plan). Colour-name list (§8.2) must be
owned by the DSL plan and imported, not duplicated. Fortran string handling
makes the renderer fiddly — keep all formatting in the one `diag` module and
unit-test alignment with multi-digit line numbers (line ≥ 100 gutter case
must be a fixture).

---

## 12. Open questions (for the user / sibling plans)

1. DSL spelling: American `color` only, or is `colour` accepted as a silent
   alias rather than a suggestion? (This plan assumes suggestion-only.)
2. Named-colour set: exactly the 6 face colours in `mesh.f90` + neutrals as
   in §8.2, or a larger standard palette? Larger set = weaker did-you-mean.
3. Should `--fix` (auto-apply certain suggestions, §4.1) exist at all in v1.x?
   Recommendation: no — trust first, automation later.
4. Localisation: English only for v1 confirmed? Templates (§9) keep the door
   open either way.
