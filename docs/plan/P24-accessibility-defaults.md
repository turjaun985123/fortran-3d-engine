# P24 — Accessibility & Sensible Defaults: Zero-Config Renders Something Good

> **Status:** Planning only — no code changed by this document. The only
> file written for this plan is this one; no `src/`, `viewer.html`,
> `scene.json`, or other plan edits.
> **Repo state audited:** `src/main.f90`, `src/camera.f90`,
> `src/renderer.f90`, `src/mesh.f90`, `viewer.html`, `scene.json`,
> `README.md` (2026-11-23), plus prior plans P03 (§6 defaults), P04
> (§desugar/defaults injection), P08 (diagnostics), P10 (lighting),
> P13 (camera/input, esp. §11 reduced-motion open question), P20 (§4
> zero-config).
> **Goal served:** *zero-config works.* A beginner creates an empty or
> one-line file, runs the one obvious command, opens the viewer — and
> gets a well-framed, well-lit, distinguishable picture and a viewer
> they can operate with a keyboard, with motion sickness, or with
> colour-vision deficiency. No flag, config file, or tribal knowledge
> may be required to repair a default (P20 §4.1's rule, adopted here).

---

## 0. Verdict in one page

| Decision | Ruling |
|---|---|
| Canonical defaults | **Do not invent a second defaults table.** P03 §6 / P04 desugaring / P20 §4.1 already agree on one set (§2). P24 extends that table with the rows it lacks (palette, motion, contrast, viewer behaviour) and fixes the places where code *diverges* from it (§1). |
| Empty / minimal file | Renders the built-in demo scene with a **warning, not an error** (§3). This deliberately amends P08's `E4005`/`E5002`-as-error for the *render* path; `check`/`--strict` keep the error. A missing file stays an error — empty ≠ absent. |
| Default camera / light / bg / size | Keep the proven demo values exactly: `640×480`, camera `(3,2.5,4)→(0,0,0)` fov 60 near 0.1 far 100, light `(-0.5,-1,-0.7)`, ambient floor `0.25`, background `(25,25,35)` `#191923` (§2). They are good; the bugs are divergence and missing fields, not these numbers. |
| Auto-framing | If geometry exists but no camera is authored, **fit-to-bounds** (§2.3) instead of blindly using the origin camera — a model at `(20,0,0)` or of size 100 must not render as an empty/overflow frame. |
| Palette | Adopt the **Okabe–Ito** colourblind-safe palette as the recommended/default-assignment palette for unspecified colours (§4), with `legacy` retained as a named opt-in. Never encode meaning by hue alone: luminance separation + optional labels/patterns are part of the spec. One deliberate golden-image change, taken once, with sign-off — not a silent drift. |
| Reduced motion | `prefers-reduced-motion` is **decided here** (resolving P13 §11's open question): auto-rotate defaults **off**, damping/inertia off, CSS transitions off in the viewer. Auto-rotate also defaults off for everyone after first manual interaction until explicitly re-enabled — see §5 for the exact state rule. |
| Keyboard | The viewer is fully operable keyboard-only (§6): focusable canvas with the P13 key map, native buttons, visible focus, no keyboard trap, no global hotkeys, `?` shortcut help. Today it is mouse-only — that is the single largest accessibility gap in the repo. |
| Contrast | WCAG 2.2 AA as a *tested* bar, not an aspiration (§7): text ≥ 4.5:1, large text / UI components / focus ≥ 3:1. One current failure is already measurable: white on the button blue `#0284c7` is **4.10:1** — fix to `#0369a1` (5.93:1). Rendered-scene contrast is specified separately (silhouette/edge rule, §7.3) because WCAG text ratios do not directly govern 3D shading. |
| Announcements | No `alert()` for load/status. A polite `aria-live` status region, a text description of the scene for the canvas, and errors in text (P08) — colour is never the only signal (§8). |

Non-goals: a theme editor / user palette builder, high-contrast *render*
modes that re-light the scene, screen-reader *3D navigation* beyond the
camera keys + textual scene summary, audio cues, and any change to the
native renderer's determinism. Native Fortran stays a batch renderer
(P13 §2): all interactivity rules below bind `viewer.html` only.

---

## 1. Current state (grounded in the repo)

### 1.1 The defaults that exist — and where they actually live

There is no scene input and no defaults module today. Every default is a
hard-coded literal in the one demo program, duplicated (differently) in
the viewer:

| Setting | Fortran (`src/`) | Viewer (`viewer.html`) | Agree? |
|---|---|---|---|
| Size | `main.f90`: `width=640, height=480` | `<canvas width=640 height=480>`, `.viewport` fixed `640×480 px` | Yes, but viewer overflows small screens (§8.3) |
| Background | `renderer.f90` `framebuffer_init`: `framebuffer_clear(fb, 25, 25, 35)` = `#191923` | Canvas fill `#020617`; page `#090d16` | **No** — same scene, two backgrounds; the PPM and the interactive view do not match |
| Camera | `main.f90`: eye `(3, 2.5, 4)`, target `(0,0,0)`, fov 60, near 0.1, far 100, up `+Y` (`camera.f90`) | `rotX=0.35, rotY=0.6, zoom=140`, ad-hoc `distance=4.0` projection (P13 §1.1) | **No** — unrelated models; default framing differs |
| Light | `main.f90`: `light_dir=(-0.5,-1.0,-0.7)`; `renderer.f90`: `intensity = 0.25 + 0.75*diffuse` | Same direction `[-0.5,-1.0,-0.7]`, same `0.25 + 0.75*diffuse` | Yes — the one aligned pair; keep |
| Demo pose | `main.f90`: rotY 35°, rotX 20° | Initial `rotX/rotY` above (different angles, object-space) | No (consequence of the camera row) |
| Object | `mesh.f90` `create_cube(cube, 2.0)`: size-2 cube at origin, 12 triangles | Identical hard-coded 12 triangles as fallback if `fetch('scene.json')` fails | Yes |
| Colour, unspecified triangle | `mesh.f90` `Triangle%color = [255,255,255]` (white) | `tri.color` dereferenced unconditionally — a `scene.json` triangle **without** `color` throws / renders nothing | **No** — viewer has no per-field fallback at all |
| Face palette | `mesh.f90` by index: red `(220,60,60)`, green `(60,220,60)`, blue `(60,100,240)`, yellow `(240,220,50)`, magenta `(200,80,220)`, cyan `(60,220,220)`; duplicated verbatim in `scene.json` and in the viewer's fallback array | Same six values | Yes — and red-vs-green as the first two faces is the classic deuteranopia collision (§4.1) |
| Output | `main.f90`: `output_render.ppm` (+ exported `scene.json`, `model.obj`) | — | — |

### 1.2 Accessibility state of the viewer today

- **Motion:** `let autoRotate = true` at load; `render3D()` does
  `rotY += 0.015` per `requestAnimationFrame` — always spinning, at a
  frame-rate-dependent speed, with no check of
  `prefers-reduced-motion`, no pause on hover/focus, and no pause when
  the tab/section is hidden beyond the PPM-tab guard. For a user with a
  vestibular disorder the *first thing the product does* is move.
- **Keyboard:** none. Listeners are `mousedown`/`mousemove`/`mouseup`/
  `wheel` only. The canvas has no `tabindex`, no `role`, no
  `aria-label`; there is no focus style anywhere in the CSS. Buttons are
  real `<button>`s (good — keep) but the toggle buttons expose no state
  (`aria-pressed` absent; state is text + emoji only).
- **Tabs:** two `<button>`s with an `.active` class — no
  `role="tablist"/tab`, no `aria-selected`, arrow-key tab navigation
  absent.
- **Status/errors:** `alert('Invalid JSON file')` and
  `alert('Currently supporting ASCII PPM (P3)…')`; a silent
  `.catch(() => {})` on the `scene.json` fetch. Success/failure is
  otherwise conveyed by the picture alone.
- **Colour/contrast (measured, §7.1):** body text and muted text pass AA;
  primary-button white-on-`#0284c7` **fails** at 4.10:1; the HUD hint is
  `rgba(255,255,255,0.6)` over `rgba(0,0,0,0.5)` — unmeasurable-by-design
  translucency over a moving 3D scene, i.e. not guaranteed readable.
- **Touch targets / layout:** buttons are ~33 px tall (below the 44 px
  comfortable target, §8.2); `.viewport` is a fixed 640 px box, so on a
  360 px phone the page scrolls horizontally and the canvas is clipped.
- **Semantics:** `<html lang="en">` present (keep); no heading structure
  beyond one `<h1>`; the file inputs are `display:none` inside `<label>`s
  (keyboard-reachable via the label's button styling in some browsers,
  inconsistently — §6.4); emoji are used as the *only* iconography on
  several controls, with text labels present (acceptable) but toggle
  state sometimes carried by the emoji swap alone (not acceptable, §8.1).

### 1.3 What "empty" does today

Nothing — because there is no input path. `main.f90` ignores files
entirely and always renders its hard-coded cube. That accident is, in
effect, the perfect zero-config demo; the compiler/DSL plans (P03/P04)
are what introduce the failure modes this plan must pre-empt: a parsed
empty file, a `{}` scene, a triangle list with missing fields, a scene
whose only object sits nowhere near the default camera. P08 currently
classifies those as errors (`E4005` empty scene, `E5002` empty file,
`E4001` missing camera block). §3 reconciles that with the goal.

---

## 2. The canonical defaults table (P24 additions in **bold**)

This extends P03 §6 — it does not replace it. One table, one home
(P03 §6 in docs; the compiler's defaults-injection step in P04 in code;
a generated `defaults.json`/Fortran `defaults` module from that single
source when implementation lands — hand-maintained copies in Fortran,
the compiler, and the viewer are exactly how §1.1's divergences happened).

### 2.1 Scene, camera, light, output

| Setting | Default | Why this value |
|---|---|---|
| Image size | `640 × 480` (4:3) | Today's value everywhere; cheap on CPU (P10 §8.6), large enough to judge framing, matches all goldens. Not 1080p: a first render must be fast, and size is one word to change. |
| Background | `(25,25,35)` `#191923`, **in both renderers** | Dark slate, not pure black: shaded faces keep a visible silhouette step against it, and it is the existing Fortran value, so the golden survives. Viewer canvas fill changes from `#020617` to `#191923` (parity fix, §7.3). |
| Camera position / target / up | `(3, 2.5, 4)` / `(0,0,0)` / `(0,1,0)` | The proven demo three-quarter view; subject at origin is seen, lit, and unmistakably 3D in one still. |
| FOV / near / far | `60°` / `0.1` / `100` | As today (`camera_init` call). Aspect always derived from size, never asked. |
| Model pose (single-object/demo) | rotX 20°, rotY 35° | P03 §6.2: a lone cube never presents a flat, ambiguous face-on square. Multi-object scenes: no pose (P03 rule stands). |
| Light | Directional `(-0.5,-1.0,-0.7)`, white; ambient floor `0.25`, diffuse weight `0.75` | P10 §9 legacy equation. The 0.25 floor is itself an accessibility property: **no face ever renders pure black**, so shape is never lost entirely in shadow. Do not lower it in the name of "realism" without re-opening this plan. |
| Default geometry | Size-2 cube at origin, 12 triangles (`create_cube`) | Already the engine's demo and the viewer's fallback; zero new assets. |
| **Unspecified triangle/object colour** | **White `(255,255,255)` in Fortran (existing `Triangle` default); viewer must apply the same fallback instead of dereferencing `undefined`** | One rule in both runtimes: *a missing colour is white, never a crash and never invisible-by-accident* (white on `#191923` under the default light is plainly visible). |
| Output file | `output_render.ppm` (+ `scene.json`, `model.obj` exports) | As today / P20 §4.1. |
| **Fallback notice** | **Every substituted default that changes what the user asked for is named in the run summary / viewer status line (§3.3)** | Defaults are forgiving, never silent (P08 principle 10 / P10 §2.2 applied to defaults themselves). |

### 2.2 Viewer-behaviour defaults (new rows — no prior plan owned these)

| Setting | Default | § |
|---|---|---|
| Auto-rotate | **Off** if `prefers-reduced-motion: reduce`; otherwise on at P13's `30°/s`, pausing on any interaction, resuming only per §5.2 | §5 |
| Damping / inertia | On (P13 §4.4 τ≈60 ms); **instant (off)** under reduced motion | §5 |
| Palette for unspecified colours | `okabe-ito` assignment sequence; `legacy` available by name | §4 |
| Wireframe | Off (shaded) | existing behaviour |
| Camera on load | Authored camera → auto-fit → canonical default, in that order | §2.3 |
| UI contrast mode | Follow OS (`prefers-contrast`, forced-colors) where the platform exposes it; no in-app theme switch in v1 | §7.2 |

### 2.3 Auto-fit: the default camera is a fallback, not a trap

Order of framing decisions on load / on render, first match wins:

1. **Authored camera** (scene/DSL/`scene.json` camera block, P13 §7) —
   used verbatim; the user's framing is never overridden.
2. **Auto-fit** — geometry exists, no camera: compute the triangle
   bounding box; `target = bbox centre`,
   `radius = bbox_radius / tan(fov/2) × 1.2`, eye placed on the default
   view direction (normalised `(3, 2.5, 4)`) at that radius, near/far
   widened only if the fit requires it (and then reported, §3.3).
   This is P13 §5.2's Fit Scene promoted to a load-time default.
3. **Canonical default** (§2.1) — no geometry either (the §3 demo case).

Degenerate inputs must not produce NaN or a blank frame: empty bbox,
single point, or zero radius ⇒ fall through to the next rule; a model
entirely behind the authored camera stays a P08 `W4001` warning (the
author asked for that camera), while the *viewer* additionally offers
Fit — it never silently reframes an authored view.

---

## 3. Empty and minimal files: render the demo, say so

### 3.1 The matrix (normative)

| Input | Behaviour on `run`/`build` (default mode) | In `check` / `--strict` |
|---|---|---|
| No file argument, no scene in cwd | Built-in demo (§2) → `output_render.ppm`; summary line `no scene found — rendered the built-in demo cube` | n/a |
| File exists, 0 bytes, or only whitespace/comments | Demo scene substituted; **warning** `W5002: file is empty — rendered the built-in demo; add 'cube' to start your own scene` (wording per P08 §"empty file" starter-scene guidance) | Error (P08 `E5002` stands) |
| Valid file, zero objects (`{}`, `{"triangles":[]}`, a scene with only `camera`/`light` statements) | Demo **geometry** substituted, but the file's own camera/light/background/size are honoured — the user styled an empty stage, so light their stage and put the demo actor on it; warning `W4005` (new warning twin of `E4005`) | Error (P08 `E4005` stands) |
| One object, nothing else (e.g. just `cube`) | Full §2 defaults; this is the headline zero-config case and produces **no warning at all** — it is not a mistake | Passes |
| Object(s) present, fields missing (no colour, no `at`, no size…) | Per-field defaults (§2.1, P03 §6.2); no warning for ordinary omissions — defaults are the language working as designed | Passes |
| File **not found** / unreadable / is a directory | **Error**, unchanged (P08 `E5001`/`E5002`): absence is a typo until proven otherwise; substituting a demo for a mistyped path would hide real mistakes | Error |
| Malformed / unparseable file | **Error**, unchanged (P08 fuzz rule: never exit 0, never a rendered file on garbage input) | Error |

Rationale for splitting empty from missing/malformed: an empty file is
the natural first artifact of `touch scene.f3d`, a template, or a
teacher handing out starters — punishing it teaches nothing. A missing
or corrupt file signals a real mistake the demo would paper over.

### 3.2 Viewer equivalent

Opening `viewer.html` with no `scene.json` reachable, an empty JSON
file, or a JSON file whose `triangles` is `[]`/absent ⇒ the built-in
12-triangle demo (already the fallback array) **plus** a status-line
message (`Demo cube shown — no scene.json loaded`), never a blank
canvas and never only a console error. A *malformed* JSON shows the
demo too, but the status line says the file could not be read and why —
the picture is a courtesy, the message is the truth (§8.1).

### 3.3 Reporting substituted defaults

- CLI/native: one summary block (P20 normal verbosity) listing only the
  *consequential* substitutions: demo-geometry substitution, auto-fit
  framing, near/far widening. Routine per-field defaults are not listed
  (that would train users to ignore the block); `-v` lists all of them.
- Viewer: the same facts in the status region (§8.1), in words:
  `12 triangles · demo palette · camera auto-fitted`.
- Exit code stays **0** for the warning cases above in default mode —
  a successful render with a warning is P08's existing model.

---

## 4. Colourblind-safe palette

### 4.1 The problem with the current palette

`red (220,60,60)` vs `green (60,220,60)` as adjacent cube faces is the
worst common pairing for deuteranopia/protanopia (the most common CVD
forms, ~8% of men): under simulation the two faces collapse toward a
similar yellowish-brown and are told apart mainly by their (different)
luminance — luck, not design. Magenta/cyan/yellow are less confusable,
but the set as a whole was chosen for saturated variety, not for
pairwise distinguishability under CVD simulation or under the renderer's
own shading (every colour is multiplied by `intensity ∈ [0.25, 1.0]`,
so a palette must survive being darkened to 25%, §4.3).

### 4.2 The recommended palette: Okabe–Ito

Adopt the Okabe–Ito palette (designed for CVD distinguishability) as
the named palette `okabe-ito`, assigned in this order to unspecified
faces/objects (colour *i* of the sequence to the *i*-th unspecified
item, cycling after 7 — black is reserved for outlines/text, not fills):

| # | Name | RGB | Hex | vs bg `#191923` (full intensity) |
|---|---|---|---|---|
| 1 | Orange | 230, 159, 0 | `#E69F00` | 7.74:1 |
| 2 | Sky blue | 86, 180, 233 | `#56B4E9` | 7.55:1 |
| 3 | Bluish green | 0, 158, 115 | `#009E73` | 5.10:1 |
| 4 | Yellow | 240, 228, 66 | `#F0E442` | 13.18:1 |
| 5 | Blue | 0, 114, 178 | `#0072B2` | 3.36:1 |
| 6 | Vermillion | 213, 94, 0 | `#D55E00` | 4.51:1 |
| 7 | Reddish purple | 204, 121, 167 | `#CC79A7` | 5.69:1 |
| — | (Outline/text black) | 0, 0, 0 | `#000000` | — |

Rules:

- **Suggestions, not a cage.** Explicit user colours are never rewritten.
  The palette governs only (a) colours the engine must invent (demo cube,
  unspecified objects) and (b) documentation examples. A scene that
  specifies the old red/green pair renders exactly as written.
- **`legacy` stays available** as a named palette (the §1.1 six colours)
  for reproducing old renders; the built-in demo's migration to
  `okabe-ito` is a *single deliberate golden change* (§9, Phase A) —
  proposed here, executed only with that phase's explicit sign-off,
  because it intentionally breaks pixel-identity with today's
  `output_render.ppm` (P10 §9's golden rule is about *unintended* drift).
- P03 §6.3's named-colour vocabulary (`red green blue …`) is unchanged
  as *user-facing names*; only the colours assigned when the user names
  **nothing** change. If P03's named set is ever re-valued, re-value
  `green`/`red` last and only with CVD simulation evidence (§9 tests).
- The JS viewer, the Fortran demo, and `scene.json` export must draw
  from the same generated palette table (§2 preamble) — three
  hand-copied arrays is how the current set ossified.

### 4.3 Palette rules that are not about hue

1. **Shaded-range check, not swatch check.** A palette colour is only
   accepted if it stays distinguishable from the background and from
   its neighbours across the whole Lambert range. Measured honestly:
   at the 0.25 ambient floor, *every* colour above drops to ≈1.0–1.5:1
   against `#191923` — hue cannot rescue an unlit face. Hence rule 2:
2. **Silhouette guarantee.** Shape legibility must not depend on fill
   contrast alone: the viewer already strokes each triangle
   (`rgba(0,0,0,0.3)` edges); strengthen the *default* view with a
   defined edge stroke (≥1 px, contrasting against both fill and
   background — dark edge on lit faces, and the background step itself
   on dark faces), and specify the same edge pass as a *default-on,
   opt-out* option for the native renderer in the implementation plan
   (it is a renderer feature request recorded here, not a claim it
   exists). Faces are read by their outlines when their fills go dark.
3. **Never colour-alone.** Anywhere colour carries *meaning* (selected
   object, error state, face identity in docs/examples), pair it with a
   second channel: a label, a position in a legend, a pattern/hatch in
   wireframe/legend swatches, or a text name (`Orange face`, not just
   an orange chip). This is P08 principle 10 applied to rendering.
4. **Docs/examples** use `okabe-ito` order and name colours in captions,
   so a reader with CVD and a reader without are reading the same text.

---

## 5. Reduced motion (viewer)

This section **decides** the question P13 §11 left open.

### 5.1 Honour the OS setting, automatically

On load, and live if it changes (`matchMedia('(prefers-reduced-motion:
reduce)')` + `change` listener):

| Behaviour | `reduce` | `no-preference` |
|---|---|---|
| Auto-rotate initial state | **Off** (button shows "Resume Auto-Rotate") | On, 30°/s (P13 §5.1) |
| Damping / inertia (P13 §4.4) | Instant: state = goal, no easing, no release inertia | On |
| CSS transitions (`transition: all 0.2s` on tabs/buttons today) | `transition: none` via the media query in CSS | As designed |
| Animated anything else (future GIF-like previews, spinners) | Static first frame / non-animated indicator | — |

No in-app toggle is required in v1 *for the media query itself* — the
OS setting is the toggle — but the existing auto-rotate button remains
the manual override in both directions, and a manual choice made in the
viewer wins over the media query for that session (a user who pressed
"Resume" under `reduce` gets rotation; agency beats inference).

### 5.2 Interaction rules for everyone (motion hygiene)

- Auto-rotate **pauses on any interaction** — pointer drag, wheel,
  keyboard camera key, or the canvas/buttons receiving focus — and does
  not resume while the user is interacting or reading controls. Resume
  (P13's 3 s idle rule) applies only if auto-rotate was on and the user
  has not toggled it off; the button label/`aria-pressed` always shows
  the *effective* state (spinning / paused / off), per P13 §5.1.
- **No flashing:** nothing in the viewer or the default render sequence
  may flash more than 3 times per second (WCAG 2.3.1); error/status
  changes are fades or instant text changes, never blinks.
- Native renders are stills/frame sequences authored by the user
  (P09); reduced-motion binds the *viewer's playback/auto-motion*, not
  the user's own authored animation — but the viewer's default playback
  of an authored sequence under `reduce` starts **paused on frame 1**
  with a Play button, rather than auto-playing.

---

## 6. Keyboard access (viewer)

Target: every action reachable by mouse is reachable and usable by
keyboard alone, in a sensible order, with the focus always visible.
This adopts P06's v1 keyboard line and P13 §6's map — P24 makes them
*requirements with acceptance tests* (§9) rather than features.

### 6.1 Focus fundamentals

- Canvas wrapper gets `tabindex="0"`, `role="application"` is **not**
  used (it hijacks screen-reader keys); use `role="img"` on the canvas
  with a dynamic `aria-label`/description (§8.1) plus a separate
  focusable *controls* pattern: the viewport container is focusable and
  key handlers live there, so screen-reader users get the description
  and keyboard users get the keys, without lying about the element type.
  (Implementation may choose container-vs-canvas; the *contract* is:
  focusable, labelled, key map below, no trap.)
- **Visible focus:** `:focus-visible` outline ≥ 2 px, offset ≥ 2 px,
  colour with ≥ 3:1 against adjacent colours in both themes — e.g.
  `#F0E442` (14.7:1 on the page background) outline on dark surfaces.
  Never `outline: none` without a replacement; the current stylesheet
  has no focus style at all, which is the first fix.
- Tab order = visual order: tabs → 3D controls → viewport → PPM
  controls (when active) → instructions. No positive `tabindex`, no
  focus trap anywhere, `Esc` never strands focus (§6.3).

### 6.2 Key map (when the viewport is focused)

Adopt P13 §6 verbatim as the contract; summarised so this plan is
testable on its own:

| Key | Action |
|---|---|
| `← → ↑ ↓` | Orbit 5° per press (`Shift` = 1° fine) |
| `+` / `-` (and `=`) | Dolly in / out |
| `W A S D` / `Q E` | Pan target (P13's reservation: pan, not fly) |
| `R` / `Home` | Reset to authored/default camera |
| `F` | Fit scene (§2.3) |
| `Space` | Toggle auto-rotate (`preventDefault` — no page scroll) |
| `1`–`6` | View presets Front/Back/Left/Right/Top/Iso |
| `?` | Open shortcut-help (a `<dialog>` or details panel listing this table); `Esc` closes it and returns focus to the viewport |
| `Tab` / `Shift+Tab` | Leave the viewport to the next/previous control — always works |

Keys do nothing when focus is in a text field, file picker, or the help
dialog (except `Esc` there). No global hotkeys. Held-key repeat is the
OS's; per-press steps go through the same goal-state path as pointer
input (P13 §4.4), and under reduced motion they apply instantly (§5.1).

### 6.3 Buttons, tabs, and controls

- All controls remain native `<button>`/`<input>`/`<label>` — keyboard
  and screen-reader support is then the platform's, not hand-rolled.
- Toggle buttons (Auto-Rotate, Wireframe) get `aria-pressed` synced
  with state; tab buttons get `role="tab"`, `aria-selected`, and
  `←/→` navigation within the tablist per the ARIA tabs pattern, with
  the inactive panel's controls removed from tab order.
- Sliders/inputs added later (FOV etc., P13 §5.2) must be real
  `<input type="range">` with a `<label>` and arrow-key operation —
  never a drag-only custom widget.

### 6.4 File loading without a mouse

The hidden `display:none` file inputs inside styled `<label>`s are
replaced by the standard pattern: a visually-hidden-but-focusable
input + label styled as a button, operable with `Enter`/`Space`,
announcing the chosen file and result in the status region. Drag-and-
drop (if ever added) is an enhancement, never the only path. The
`fetch('scene.json')` auto-load failure path must surface in the status
region, not the current silent `.catch(() => {})`.

---

## 7. Contrast

### 7.1 UI text and controls — WCAG 2.2 AA, measured on today's CSS

Ratios computed with the WCAG relative-luminance formula from the
viewer's actual hex values:

| Pair (today) | Ratio | AA verdict | Fix |
|---|---|---|---|
| Body text `#f8fafc` on card `#1e293b` | 13.98:1 | Pass | — |
| Muted `#94a3b8` on panel `#131d2e` | 6.59:1 | Pass (≥4.5) | — (keep; it is the floor, do not mute further) |
| Accent `#38bdf8` on page `#090d16` | 9.07:1 | Pass | — |
| Active tab `#0f172a` on `#38bdf8` | 8.33:1 | Pass | — |
| **White on button `#0284c7`** | **4.10:1** | **Fail** (< 4.5 for 0.85 rem text) | **Background → `#0369a1` (5.93:1)**; hover `#0ea5e9` has the same defect for white text — hover must also stay ≥ 4.5:1 while hovered (use `#0369a1` bg with a non-colour cue — underline/outline — instead of a lighter blue) |
| HUD hint `rgba(255,255,255,.6)` on `rgba(0,0,0,.5)` over the live canvas | Indeterminate | Not guaranteed | HUD sits on a **solid** chip (`#0f172a` at full opacity, text `#f8fafc` = >13:1) or moves below the viewport as ordinary page text. Translucent-over-3D text is banned for essential hints. |
| Focus indicator | Absent | Fail | §6.1 (`#F0E442`, 14.7:1 on page bg) |

Standing rule for implementation: every new foreground/background pair
ships with its computed ratio in the PR/test (§9); "looks fine" is not
a contrast check. Large text (≥ 24 px, or 18.66 px bold) may use 3:1;
icons/UI-component boundaries and the focus indicator use 3:1 against
*adjacent* colours (WCAG 1.4.11), not against the page at large.

### 7.2 Platform modes

- `@media (prefers-contrast: more)` / forced-colors (`forced-color-adjust`):
  do not fight the platform — let borders, buttons, and focus use system
  colours (`ButtonText`, `Highlight` etc. via `forced-color-adjust: auto`
  defaults), and ensure the canvas container keeps a visible border when
  backgrounds are stripped. No custom "high-contrast theme" in v1.
- Colour scheme stays dark-only in v1 (the render background is dark by
  design, §2.1); page chrome must not claim a light theme it does not have.

### 7.3 Rendered-scene contrast (the part WCAG does not directly cover)

For the 3D picture itself the requirements are perceptual, stated as
testable rules rather than WCAG citations:

1. **Background step:** every palette colour at *full* intensity ≥ 3:1
   against the background (Okabe–Ito's weakest, blue `#0072B2`, is
   3.36:1 — passes; the legacy blue `(60,100,240)` is 3.55:1, legacy red
   3.95:1 — the current set passes *this* test too, which is why §4 is
   about CVD, not brightness).
2. **Dark-face rule:** at the ambient floor, fills converge toward the
   background (§4.3 measurement), so legibility is carried by the edge
   stroke + the inter-face luminance step: adjacent faces of the default
   object must differ in *rendered* luminance by a step a test can
   measure on the golden image (assert in §9; if a future palette fails
   it, the palette changes, not the test).
3. **No information in the darkest band alone:** a scene that is only
   readable on a bright monitor is a defect — the §9 checks include a
   simulated low-brightness/low-contrast-display pass (gamma/luminance
   compression) on the default golden.

---

## 8. Beyond colour and keys: the rest of the viewer surface

### 8.1 Names, status, and errors (screen-reader contract)

- Canvas/viewport accessible description, updated on load and on
  Reset/Fit (not on every orbit frame — that would flood a screen
  reader): e.g. `3D view: cube, 12 triangles, camera at (3.0, 2.5, 4)
  looking at origin. Press ? for keyboard controls.` This reuses P13
  §5.3's live camera readout as text, not just pixels.
- One `aria-live="polite"` status region carries: file loaded (name +
  triangle count), demo-substitution notices (§3.2), auto-fit notices,
  and **all errors** — replacing both `alert()` calls. Errors are text
  with the P08 wording; they are never conveyed by colour, icon, or
  the absence of a picture alone.
- Toggle state is in the accessible name/state (`aria-pressed`, §6.3),
  not only in an emoji/text swap on the button face.

### 8.2 Targets, text, and layout

- Interactive targets ≥ **44 × 44 px** (WCAG 2.5.8's AA floor is 24 px;
  44 px is the comfortable platform norm and this UI has room for it) —
  today's ~33 px buttons grow via padding, not font size.
- Page text ≥ 0.85 rem is today's floor; nothing essential below it.
  Layout must survive **200% text zoom** without horizontal scrolling
  or clipped controls (the fixed-640 px `.viewport` becomes
  `max-width: 640px; width: 100%` with the canvas scaling — internal
  render resolution stays 640×480, CSS scales it; aspect preserved).
- Instructions stop being mouse-only prose: the instructions card and
  the HUD list keyboard and touch equivalents alongside the mouse text
  (P13 §5.3's input-aware hint, with the static fallback listing all
  three).

### 8.3 Language and plain wording

Defaults and notices use the P08 plain-English register: name the thing
that happened and the next action (`No scene.json found — showing the
demo cube. Load a file with 'Load scene.json'.`), never a bare code or
a technical shrug. Diagnostic *codes* (P08) may follow in parentheses
for support, never lead.

---

## 9. Phases and acceptance

**Phases** (each independently shippable; viewer phases need no Fortran
changes, defaults phases need no viewer changes beyond parity):

1. **P24-a — One defaults source + parity fixes.** Generate/share the
   §2 table (incl. palette table) across compiler, Fortran demo, and
   viewer; viewer canvas background → `#191923`; viewer missing-`color`
   fallback → white; default view = Fortran demo framing (with P13-a).
   *Deliberate sub-decision, taken in this phase with explicit
   sign-off:* demo palette migrates `legacy` → `okabe-ito` and the
   golden PPM is regenerated once.
2. **P24-b — Empty/minimal semantics.** §3.1 matrix in the compiler/CLI
   (demo substitution + `W4005`/`W5002`, strict mode keeps P08 errors);
   viewer §3.2 demo + status behaviour.
3. **P24-c — Motion + keyboard.** §5 media-query behaviour and
   pause rules; §6 focus, key map, tabs pattern, file-input pattern,
   `?` help. (Lands with/after P13-c; P24 supplies the a11y acceptance
   tests, P13 the camera mechanics.)
4. **P24-d — Contrast + semantics polish.** §7.1 button/HUD fixes,
   §8 status region replacing `alert()`, target sizes, responsive
   viewport, forced-colors sanity.

**Acceptance tests**

- *Zero-config golden:* empty file, comments-only file, `{}`, and
  `cube`-only file each produce a non-blank 640×480 render; the first
  three are pixel-identical to the demo golden (post-P24-a palette)
  apart from the honoured-camera case in §3.1, which is asserted
  separately. Missing-file and garbage-file fixtures still exit
  non-zero with P08 diagnostics (no regression of P08's fuzz rule).
- *Defaults parity:* for the default scene, projected corner
  coordinates and background RGB agree across Fortran PPM, `scene.json`
  round-trip, and viewer canvas (background exactly `(25,25,35)`;
  corners within P13's 1 px tolerance); a `scene.json` triangle with
  no `color` renders white in both runtimes.
- *Auto-fit:* fixtures with geometry centred at `(20,0,0)`, at scale
  100, and at scale 0.01 each render with the object occupying
  30–90% of frame height and fully inside the frame; an authored-camera
  fixture is *not* reframed.
- *CVD simulation:* the default demo rendered through deuteranopia,
  protanopia, and tritanopia simulation matrices — every pair of
  adjacent demo faces remains distinguishable by the test's
  luminance+simulated-hue distance threshold, and the §7.3 dark-face
  edge assertion holds in all three simulations.
- *Contrast automation:* a CI script recomputes every foreground/
  background pair declared in the viewer stylesheet (and the §4 palette
  vs background) with the WCAG formula and fails below the §7 bars —
  including hover/focus states, not just the resting state.
- *Keyboard-only walkthrough (automated + manual):* with no mouse —
  load page, tab to viewport, orbit with arrows, dolly, reset, toggle
  wireframe and auto-rotate, switch tabs, open and close `?` help,
  load a file — every step completable, focus visible in screenshots,
  focus never lost to `body` except by tabbing out of the page.
- *Reduced motion:* with the media query emulated `reduce` — the
  canvas is pixel-stable over 2 s on load (no auto-rotation), key
  orbits land instantly, authored-sequence playback starts paused;
  with `no-preference`, auto-rotate runs at 30°/s ±10% regardless of
  refresh rate (with P13's frame-rate test).
- *Screen-reader smoke:* status region announces load success, demo
  substitution, and a malformed-file error; toggle buttons expose
  correct `aria-pressed`; canvas description matches §8.1's format.
- *Layout:* at 360 px width and at 200% text zoom, no horizontal
  scrollbar, no clipped control, canvas fully visible.

---

## 10. Risks & open questions

- **P08 conflict is real and must be closed, not worked around.**
  §3 amends `E4005`/`E5002` for the default render path only. If the
  P08 owner prefers, the alternative is a `--demo-on-empty` flag —
  rejected here because a flag a beginner must discover to make an
  empty file work is the opposite of zero-config. Strict/check keeping
  the error preserves the safety net for pipelines that *want* empty
  to be a mistake.
- **Golden break (palette).** P24-a's demo-palette migration is the
  only intentional pixel change in this plan; everything else is
  parity-preserving. If sign-off is withheld, ship `okabe-ito` as the
  documented recommendation + the palette for *multi-object*
  unspecified colours, keep the demo `legacy`, and record the demo as
  a known CVD-weak default — do not silently recolour it later.
- **Edge pass for native renders** (§4.3 rule 2) is a renderer feature
  this plan requests but does not design; if it is rejected there, the
  native default's dark-face legibility rests on the background step
  alone and §9's dark-face test must be re-scoped to the viewer only,
  explicitly.
- **Auto-rotate default-on (no-preference)** preserves today's
  welcoming first impression but any motion-by-default is contested;
  if user testing shows annoyance, flipping the *general* default to
  off (with a prominent Play/Resume) is a one-line change this plan's
  structure already isolates — the reduced-motion rule does not change
  either way.
- **WCAG scope honesty:** WCAG governs the *chrome*, not the artwork.
  §7.3's scene rules are this project's own perceptual bar; do not
  market the engine as "WCAG-compliant 3D" — the claim is: AA viewer
  chrome, CVD-checked default palette, motion-respecting viewer.
- Open: should the textual scene description (§8.1) grow into a full
  object list for non-trivial scenes (useful, but verbose — needs a
  summary + on-demand detail pattern); and should `palette` become a
  scene-level statement (`palette okabe-ito|legacy|<custom>`)? Both are
  v2 candidates — v1 needs only the default, the named fallback, and
  no syntax that would forbid them later.
