# P13 — Camera Controls & Input

> Status: planning only (no engine or viewer code changed).
> Goal context: an "easy 3D compiler" — a beginner writes a short `.f3d`
> scene, views it interactively in the JS `viewer.html`, and renders the
> same framing natively in Fortran. The camera they *author*, the camera
> they *orbit with*, and the camera that *renders* must be one camera.
> Dependencies: P03 (DSL grammar — `camera` statement), P04 (compiler
> pipeline / `f3dc` CLI), P06 (JS runtime), P09 (animation/timeline —
> camera tracks are P09-d/v2 there, not this plan).

## 1. Current state (grounded in the repo)

### 1.1 The JS viewer (`viewer.html`)

| Fact | Where / value |
|---|---|
| Model is two Euler angles + screen-space offsets, not a camera | Globals `rotX=0.35, rotY=0.6`, `panX=0, panY=0`, `zoom=140` |
| Rotation is applied to the *object*, not the camera | `rotatePoint(p, rotX, rotY)` rotates every vertex (Ry then Rx); there is no view matrix, no `lookAt` in JS |
| Projection is ad-hoc and diverges from Fortran | `project()`: fixed `distance=4.0`, `f = zoom / (z+4.0)`, centre + `panX/panY` pixels. No FOV, near, or far |
| Orbit | Left-drag (`button 0`): `rotY += dx*0.01`, `rotX += dy*0.01`. No pitch clamp — dragging far enough flips the model over the poles |
| Pan | Right-drag (`button 2`): `panX += dx`, `panY += dy` (pixels, added at projection). `contextmenu` is suppressed on the viewport. Pan does **not** move a target — it slides the picture, so it composes differently at every zoom and is lost on any reframe |
| Zoom | `wheel`: `zoom += -deltaY*0.2`, clamped `[20, 600]`. This changes focal scale, not camera distance — there is no dolly, so no parallax change and no near/far interaction |
| Auto-rotate | Boolean `autoRotate=true` at load; in `render3D()`, `if (autoRotate && !isDragging) rotY += 0.015` **per rAF frame** — frame-rate dependent (≈0.9 rad/s at 60 Hz, half that at 30 Hz), no speed control, no resume delay |
| Buttons | `toggleAutoRotate()` (label flips Pause/Resume), `toggleWireframe()`, `resetCamera()` (restores the five globals above). No view presets, no FOV control |
| Input devices | Mouse only: `mousedown`/`mousemove` (on `window`)/`mouseup`/`wheel`. **No keyboard, no touch, no pointer events, no pinch, no double-click** |
| Pointer capture / robustness | None: drag state is a boolean; leaving the window mid-drag, a second button, or an interrupted gesture can strand `isDragging`. `wheel` listener is `{passive:false}` + `preventDefault()` so the page does not scroll — correct, keep |
| HUD | One static hint: "Drag left mouse to Rotate \| Scroll to Zoom \| Drag right mouse to Pan" — wrong for touch/keyboard users, never updates |

### 1.2 The native side (`src/camera.f90`, `src/main.f90`)

| Fact | Where / value |
|---|---|
| A real perspective camera exists | `Camera{position, target, up, fov_deg, aspect_ratio, near_plane, far_plane, view_matrix, proj_matrix}`; `camera_init(cam,pos,target,fov,aspect,near,far)`, `up` hardcoded `+Y`; `camera_update_matrices` = `mat4_look_at` + `mat4_perspective` |
| It is entirely hardcoded, with **no input of any kind** | `main.f90`: `eye=(3,2.5,4)`, `target=(0,0,0)`, `fov=60`, `near=0.1`, `far=100`, aspect `640/480`. No `get_command_argument` anywhere in `src/` |
| It never moves | One still frame is rendered and the program exits (see P09 §1) |

### 1.3 The DSL side (P03, already designed)

`camera at <vec3> look <vec3> fov <n> near <n> far <n> up <vec3>` — all
optional, defaults exactly the `main.f90` values above, at most one
`camera` statement (a second replaces, with a warning). P03 defines the
*authored still camera only*: no controls, no initial orbit state, no
auto-rotate, no presets.

**Consequence:** today there are effectively two unrelated cameras — a
correct-but-frozen Fortran `position/target/fov` camera, and a JS
`rotX/rotY/zoom/pan-pixels` model-rotation hack that cannot reproduce it
(the default JS view is not even the `(3,2.5,4)→(0,0,0)`, fov 60 view).
Framing a shot in the viewer therefore does not predict the native render.
Fixing that — one state model, §3 — is the whole point of this plan.

## 2. Scope and non-goals

**In scope (v1):** orbit / pan / zoom in the JS viewer on a true
`position/target/fov` camera; auto-rotate; keyboard, mouse, and touch
input; camera presets and reset; the camera DSL extensions and the
`scene.json` camera block that carry the authored camera to the viewer;
native camera selection by **CLI arguments only**.

**Explicit non-goals:**

- **No input in the native Fortran render.** No keyboard, mouse, stdin,
  or interactive loop in `main.f90` or any renderer module — ever, in
  this plan. Native is a batch renderer: camera in via `.f3d` (§7) or
  CLI args (§8), one deterministic render out. Interactivity lives
  exclusively in the JS viewer. This keeps native output reproducible
  in CI and is a hard boundary, not a v1 deferral.
- **First-person / fly camera: deferred** (§9) — not built, not faked
  with orbit.
- **Camera animation** (dolly/orbit tracks, keyframed `target`/`fov`):
  P09-d/v2. This plan only guarantees the state model (§3) is the one
  P09 animates.
- Picking/selection by click, camera collision, terrain following,
  cinematic easing paths — out.

## 3. One camera state model (normative)

The viewer's orbit state is a *parameterisation of the Fortran camera*,
never a separate model. Canonical state, held by the viewer and
serialisable (§7.2):

```
OrbitState {
  target : vec3        # look-at point — the pan-able centre of orbit
  azimuth: degrees     # θ around +Y from +Z axis
  polar  : degrees     # φ from +Y axis, clamped (§4.1)
  radius : float > 0   # distance eye↔target — the zoom
  fov_deg: (0,180)     # vertical FOV — projection only, not zoom
}
eye = target + radius * ( sinφ·sinθ,  cosφ,  sinφ·cosθ )
```

- Lowering to Fortran is literal: `camera_init(cam, eye, target, fov_deg,
  aspect, near, far)` + `camera_update_matrices`. Lowering to JS replaces
  `rotatePoint/project` with the same `lookAt` + perspective maths
  (P06 owns the JS renderer shape; this plan owns the formulas).
- The authored DSL camera (`at`/`look`) converts to orbit state once, at
  load: `target = look`, `radius = |at − look|`,
  `θ/φ` from `at − look`. If `at == look` the compiler already rejects it
  (P04 `E340`); the viewer falls back to the default state and warns.
- **Default orbit state must equal the current Fortran demo view:**
  `target (0,0,0)`, `eye (3,2.5,4)` ⇒ `radius ≈ 5.385`,
  `azimuth ≈ 36.87°`, `polar ≈ 62.18°`, `fov 60`. `resetCamera()`
  restores the *authored* camera (DSL/`scene.json`), falling back to
  this default when the scene declares none — not to today's unrelated
  `rotX=0.35, rotY=0.6, zoom=140`.
- `aspect` is never user state: it is `canvas.width / canvas.height`,
  recomputed on resize (viewer) / from `size` (DSL/native), as today.
- `near/far` are authored properties (DSL/CLI), not controls; no gesture
  modifies them. Zoom limits (§4.3) keep `radius` well inside them.

## 4. Orbit / pan / zoom specification (JS viewer)

All gestures manipulate `OrbitState` only; rendering is a pure function
of it (the P09 determinism rule applied to input). Speeds are in
time/angle/distance units — **never per-frame increments** (today's
`rotY += 0.015` and `dx*0.01` are the anti-pattern being removed).

### 4.1 Orbit

| Input | Effect |
|---|---|
| Left-drag / one-finger drag / `←→↑↓` (§6) | `azimuth −= dx · orbitSpeed`, `polar −= dy · orbitSpeed`; `orbitSpeed = 0.25°/px` default (i.e. a 720 px drag ≈ half-turn), scaled by nothing else — angle-per-pixel is zoom-independent by design |
| Clamp | `polar ∈ [1°, 179°]` — prevents pole flip and the `lookAt` singularity when the eye crosses `up`. Hitting the clamp stops polar motion only; azimuth continues |
| Wrap | `azimuth` wraps to `(−180°, 180°]`; no clamp |

### 4.2 Pan

| Input | Effect |
|---|---|
| Right-drag, middle-drag, `Shift`+left-drag, two-finger drag (§6) | Move `target` in the camera's right/up plane: `target −= right·(dx·s)`, `target += up·(dy·s)`, where `s = 2·radius·tan(fov/2) / viewportHeightPx` (world units per pixel — pan tracks the scene 1:1 under the cursor at the target depth, at any zoom) |
| Notes | Pan changes `target`, **not** a screen offset: orbiting after a pan orbits the new target, and "Copy camera" (§7.3) captures it. No clamp in v1 (a lost user recovers with Reset / a preset, §5); the HUD shows the live `target` so a lost scene is diagnosable |

### 4.3 Zoom (dolly, not focal scale)

| Input | Effect |
|---|---|
| Wheel / trackpad scroll, pinch (§6), `+`/`−` keys | Exponential dolly: `radius *= exp(deltaY · 0.001)` for wheel (sign: scroll-up = closer); pinch: `radius *= prevPinchDist / pinchDist`. Exponential, not linear, so one gesture model feels uniform at `radius 0.5` and `radius 50` |
| Clamp | `radius ∈ [0.5, 100]` default; scene may narrow it via DSL `controls` (§7.1). Hitting a clamp is silent saturation, never an error |
| FOV | **Not** zoom. `fov` changes only via DSL, CLI, or the FOV slider (§5) — conflating dolly and FOV (today's `zoom` focal hack) is explicitly rejected: dolly changes parallax, FOV changes framing, beginners must be able to learn them separately |

### 4.4 Smoothing / damping

- Gestures set a *goal* state; the rendered state eases toward it with a
  frame-rate-independent exponential damp (`state += (goal−state) ·
  (1 − exp(−dt/τ))`, `τ = 60 ms`, `dt` from rAF timestamps). Direct 1:1
  tracking while a pointer is down (no lag on drag); damping applies to
  wheel, keys, preset jumps, and release inertia only.
- **Inertia:** on release with pointer velocity > threshold, azimuth/
  polar continue with exponentially decaying velocity (half-life
  ≈150 ms, capped at 2 s). Any new pointer-down, key, or button cancels
  inertia immediately.
- Auto-rotate, inertia, and damping all suspend while the PPM tab is
  active (today's `currentTab !== '3d'` guard, generalised).

## 5. Auto-rotate, presets, and viewer UI

### 5.1 Auto-rotate

- State: `autoRotate: bool`, `autoRotateSpeed: degrees/sec`, default
  `30°/s` (one turn in 12 s — calmer than today's ≈52°/s at 60 Hz).
  Implementation: `azimuth += speed · dt` with `dt` in seconds; the
  current `+= 0.015`/frame behaviour is removed, not retuned.
- Default **on** for a scene with no authored camera work (preserves
  today's welcoming first impression), **off** when the DSL declares
  `controls …` (§7.1) or a P09 timeline is playing — the timeline owns
  motion then (P09 §8: the button becomes "play timeline").
- Any manual gesture (drag, wheel, key, pinch) pauses it; it resumes
  after **3 s idle** only if it was on before the gesture. The button
  toggles it permanently and its label/state must reflect *effective*
  state (spinning / paused-by-gesture / off), not just the flag —
  today's two-label toggle is insufficient once resume exists.

### 5.2 Presets and helpers (buttons, all one click)

| Control | Sets |
|---|---|
| Reset View | Authored camera (§3), `fov` included; clears pan |
| Front / Back / Left / Right / Top / Iso | `azimuth/polar` = `0/180/−90/90/≈0°*` and Iso = default demo angles, keeping current `target` and `radius` (*Top uses `polar=1°` clamp, never 0°) |
| Fit Scene | `target` = scene bounding-box centre (from loaded triangles), `radius` = bbox radius / `tan(fov/2)` · 1.2 margin. This is the recovery action for a lost/panned-away scene and the correct first-load framing for non-cube `scene.json` |
| FOV slider | `fov_deg ∈ [20°, 120°]`, live; labelled "Field of view", kept visually separate from zoom |
| Copy Camera (§7.3) | Clipboard: the current state as a DSL `camera` line |
| Wireframe toggle | Unchanged (existing button), orthogonal to camera |

### 5.3 HUD and discoverability

- Hint text is input-aware: mouse text (today's line, updated to name
  Shift-pan and middle-drag), touch text ("Drag to orbit · Pinch to zoom
  · Two-finger drag to pan") when a touch pointer is first seen,
  keyboard summary when the canvas gains keyboard focus.
- A small live readout (toggleable, on by default in a "Camera" panel):
  `at (x, y, z) · look (x, y, z) · fov n°` derived from `OrbitState` —
  this is the teaching bridge to the DSL: what you see is the line you
  would write.
- Canvas is focusable (`tabindex="0"`, visible focus ring, `aria-label`
  describing the controls); buttons keep today's native `<button>`
  semantics. Colour-only state signalling is not used.

## 6. Input mapping — keyboard, mouse, touch

Unify on **Pointer Events** (`pointerdown/move/up/cancel` +
`setPointerCapture` on the viewport), replacing the three mouse
listeners: one code path then serves mouse, touch, and pen, and
`pointercancel` fixes the stranded-drag failure in §1.1. Track active
pointers in a map (needed for pinch); `touch-action: none` on the
viewport so the browser does not hijack gestures for scrolling.

| Gesture / key | Action | Notes |
|---|---|---|
| Left-drag · 1-finger drag | Orbit (§4.1) | |
| Right-drag · middle-drag · Shift+left-drag | Pan (§4.2) | `contextmenu` suppression stays; also suppress on long-press (touch) |
| Wheel · trackpad scroll | Dolly (§4.3) | `preventDefault`, viewport only; `Ctrl`+wheel (trackpad pinch gesture) dollies 3× faster — browsers report it as wheel with `ctrlKey` |
| 2-finger pinch | Dolly: `radius *= prev/curr` finger distance | Simultaneous 2-finger *translation* (centroid moves, distance ~constant) = pan (§4.2). Decide per-move by distance change vs centroid move; hysteresis so a pinch does not jitter into pan |
| Double-click / double-tap | Fit Scene (§5.2) | Cheap, discoverable recovery |
| `←` `→` `↑` `↓` | Orbit by `5°` per press (held key repeats naturally); `Shift`+arrows = `1°` fine | Only when canvas focused or focus is not in a form control |
| `W A S D` / `Q E` | Pan target left/right/forward-ish (camera right/plane axes) / down/up, step = `radius · 0.1` | **Reserved conflict, decided here:** WASD moves the *target* (pan), not a first-person body — §9. Do not let it accrete fly semantics |
| `+` / `−` (and `=`) | Dolly ×/÷ `1.15` per press | |
| `R` | Reset View | |
| `F` | Fit Scene | |
| `Space` | Toggle auto-rotate | `preventDefault` when canvas focused (page scroll) |
| `1`–`6` | Presets Front/Back/Left/Right/Top/Iso | |
| `Home` | Reset View (alias) | |

Keyboard state changes go through the same goal/damping path as wheel
(§4.4) — no separate un-damped code path. No global hotkeys: outside
canvas focus, keys belong to the page.

## 7. Camera DSL and interchange

### 7.1 DSL — extend P03's `camera`, add optional `controls`

P03's statement is unchanged and remains the only way to author a
camera. This plan adds *viewer-behaviour* properties, all optional,
on a separate statement so a still-only program never meets them:

```f3d
camera at 3 2.5 4 look 0 0 0 fov 60 near 0.1 far 100   # P03, unchanged
controls orbit autorotate 30 min 1 max 50              # P13, optional
```

```ebnf
controls-stmt = "controls" , { controls-prop } ;
controls-prop = "orbit"                                (* default & only mode in v1 *)
              | "none"                                 (* locked camera: viewer disables gestures *)
              | "autorotate" , [ number ]              (* on, deg/s; bare = 30 *)
              | "noautorotate"
              | "min" , number | "max" , number ;      (* radius clamps, §4.3 *)
```

Rules: at most one `controls` statement (P03's replace-with-warning
singleton rule); `min < max`, both > 0, validated at parse time with
P03-style plain-English errors; `controls none` + `autorotate` together
is an error ("a locked camera cannot auto-rotate"); unknown mode word
(e.g. `controls fly`) → `line N: 'fly' camera is not built yet — only
'orbit' and 'none' work today`, following P03 §8's reserved-feature
rule, never a silent fallback to orbit. The native renderer **parses
and ignores** `controls` (validating it like everything else) — it
describes the viewer, not the render.

### 7.2 `scene.json` — carry the camera (v2 block)

Today's `scene.json` is a flat `{triangles:[…]}` with no camera (P09
§1), so the viewer *cannot* open on the authored view. The compiler's
v2 export (P04/P09 IR) adds, alongside `triangles`:

```json
"camera":   { "position": [3, 2.5, 4], "target": [0, 0, 0],
              "fov_deg": 60, "near": 0.1, "far": 100 },
"controls": { "mode": "orbit", "auto_rotate_deg_s": 30,
              "min_radius": 0.5, "max_radius": 100 }
```

Viewer load order: v2 `camera` → initialise `OrbitState` from it
(§3 conversion); absent (v1 files, hand-loaded triangle JSON) →
default state + Fit Scene. Unknown `controls.mode` → orbit + a visible
warning, not a silent lock. `export_mesh_json` in Fortran gains these
fields only when the compiler/scene work (P04/P05) lands — this plan
specifies the fields, not that change.

### 7.3 Round-trip: "Copy camera"

The viewer's Copy Camera button (§5.2) emits exactly one P03/P13 line
from the live state, eye recomputed via §3:

```f3d
camera at 4.12 1.85 2.03 look 0.50 0.00 -0.25 fov 50
```

(3-decimal rounding; `near/far` omitted unless non-default.) Pasting
it into the `.f3d` source and rendering natively must reproduce the
viewer's framing — this is the plan's headline workflow and its main
acceptance test (§10). It turns orbiting from a toy into the compiler's
camera-placement tool: *frame it by hand, paste the line, render it
for real.*

## 8. Native Fortran: CLI args only

`main.f90` gains argument parsing (Fortran `get_command_argument` —
no new dependency) solely to override the compiled/DSL camera for
one-off renders and parity tests. Nothing interactive, nothing read
after start-up.

| CLI form (on the compiler driver / generated program, per P04 CLI) | Overrides |
|---|---|
| `--camera-at x y z` | `camera position` |
| `--camera-look x y z` | `camera target` |
| `--camera-fov deg` | `fov_deg` |
| `--camera-near n` / `--camera-far n` | clipping planes |

- **Precedence (single rule, documented in `--help`):**
  CLI arg > `.f3d` `camera` statement > P03 defaults
  (`(3,2.5,4)`, `(0,0,0)`, `60`, `0.1`, `100`). Aspect is never a CLI
  arg — it follows output `size`, as in `main.f90` today.
- Validation is the compiler/camera validation of P05
  (`fov ∈ (0,180)`, `near > 0`, `far > near`, `at ≠ look`): a bad CLI
  value is a usage error — plain message, exit 2 (P04 exit-code table),
  no render, no partial PPM.
- `--controls`, gestures, and auto-rotate have **no CLI counterpart**
  and must be rejected as unknown flags if typed — there is no viewer
  in native mode for them to describe. (A *sequence* of native frames
  from moving cameras is animation: P09's timeline + frame loop, driven
  by data, still not input.)
- Parity hook: `--camera-*` is how §10's tests drive the native side
  to an arbitrary viewer state without editing source.

## 9. First-person / fly camera — deferred, explicitly

Deferred to a future plan (post-v1), for stated reasons:

- It is a different state model (eye + yaw/pitch + velocity, no
  target), a different input model (pointer-lock, sustained WASD
  velocity, up/down), and different failure modes (getting lost,
  clipping through geometry the software rasteriser has no collision
  for). Bolting it onto `OrbitState` would corrupt the §3 unification.
- Nothing in the current engine needs it: scenes are single-object or
  small dioramas authored from outside; orbit + pan + fit covers
  inspection and shot-framing, which is the compiler's actual job.
- Groundwork this plan *does* lay, so deferral is cheap later: the
  true `position/target/fov` camera everywhere (a fly camera is the
  same `Camera`, driven differently), Pointer Events + pointer capture
  (pointer-lock is an adjacent API), and the WASD-reservation warning
  in §6 (in v1 WASD pans — a future fly mode must be an explicit
  `controls fly` mode switch, with WASD rebound per-mode, never a
  silent reinterpretation).
- Until then: `controls fly` / `first-person` / `walk` are reserved
  words producing the §7.1 "not built yet" error.

## 10. Phases and acceptance

**Phases**

1. **P13-a — One state model:** viewer adopts `OrbitState` (§3) +
   lookAt/perspective projection; mouse orbit/pan/wheel re-implemented
   on it (§4, still mouse-only); default view pixel-matches the
   Fortran demo framing. Delete `rotX/rotY/panX/panY/zoom` globals.
2. **P13-b — Feel:** damping/inertia (§4.4), time-based auto-rotate
   with pause/resume (§5.1), presets + Fit + FOV slider + live readout
   (§5).
3. **P13-c — Input breadth:** Pointer Events unification, touch +
   pinch (§6), keyboard map, input-aware HUD, focus/a11y (§5.3).
4. **P13-d — Round-trip:** `scene.json` v2 camera/controls block
   (§7.2, with P04/P06), `controls` DSL (§7.1, with P03 compiler work),
   Copy Camera (§7.3), native `--camera-*` CLI (§8, with P04/P05).

**Acceptance tests**

- *Default parity:* untouched viewer on the default cube frames it as
  the native `output_render.ppm` does (same eye/target/fov) — checked
  by comparing projected corner coordinates JS vs the §3 formulas,
  tolerance 1 px at 640×480.
- *Round-trip:* orbit/pan/dolly to a non-default view → Copy Camera →
  paste into `.f3d` → native render (or `--camera-*` equivalent) →
  framing matches the viewer within the same 1 px projection tolerance.
- *Frame-rate independence:* auto-rotate at simulated 30 Hz and
  120 Hz advances the same degrees per wall-clock second (±1%);
  damping reaches the same goal state regardless of rAF rate.
- *Clamps:* polar never leaves `[1°,179°]` under scripted drag/pinch/
  key fuzzing; radius never leaves `[min,max]` under wheel/pinch fuzz;
  no `NaN` in state after any input sequence (including `pointercancel`
  mid-pinch).
- *Pan correctness:* after panning, orbiting keeps the new target
  centred; pan speed in world units doubles when radius doubles.
- *DSL/CLI:* each §7.1 validation error and each §8 precedence case
  (CLI beats DSL beats default) covered by a minimal fixture;
  `controls fly` and a native `--controls` flag both fail with the
  specified messages; a scene with `controls none` opens in the viewer
  with gestures disabled and Reset/presets still working.
- *Regression:* PPM tab behaviour, wireframe toggle, and `scene.json`
  loading from before this plan are unchanged; v1 `scene.json` (no
  camera block) still loads (default state + Fit).

## 11. Risks & open questions

- **JS projection rewrite risk:** replacing `rotatePoint/project`
  touches the only working viewer rendering path; P13-a must land
  behind the corner-projection test above before the old path is
  deleted, and P06 (JS runtime) may subsume it — coordinate ownership
  there to avoid two competing viewer rewrites.
- **Pan disorientation** is the top beginner risk of a target-based
  model (pan away, scene lost). Mitigations are specified (Fit on
  double-click/`F`, live `look` readout, Reset) but the *default*
  remains full pan — if user testing shows repeated loss, gate pan
  behind right-drag only (remove Shift+left) rather than removing pan.
- Pinch-vs-pan disambiguation on real trackpads/touchscreens is
  heuristic; the hysteresis rule in §6 needs device testing, and the
  fallback (pinch = dolly only, two-finger pan dropped) is acceptable
  for v1 if it proves unreliable.
- `scene.json` v2 depends on compiler/IR work owned by P04/P09; until
  it lands, P13-a–c ship against hand-authored/default cameras and
  Copy Camera (§7.3) still works — the round-trip must not be blocked
  waiting for the file format.
- Open: should `controls` also carry `damping off` / speed settings
  for accessibility (reduced-motion: honour
  `prefers-reduced-motion` by defaulting auto-rotate **off** and
  damping to instant — recommended, decide in P13-b); multi-camera
  scenes / named cameras (`camera "closeup" …` + a viewer switcher)
  are a natural v2 extension of §7 and are deliberately not designed
  here beyond not forbidding them.
