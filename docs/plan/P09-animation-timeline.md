# P09 — Animation & Timeline Design

> Status: planning only (read-only survey). No code in this document is implemented.
> Goal context: an "easy 3D compiler" — a beginner writes a short DSL scene,
> the compiler emits (a) a native Fortran program using this renderer and
> (b) a JS/`viewer.html` runtime, and both produce the *same* motion.

## 1. Current state (grounded in the repo)

| Fact | Where |
|---|---|
| No animation system, no clock, no frame loop. One still frame is rendered and the program exits. | `src/main.f90` (whole program) |
| Rotation is hardcoded constants, not data: `mat4_rotate_y(35°)` ∘ `mat4_rotate_x(20°)`, composed once into `model_matrix`. | `src/main.f90` §4 |
| The renderer is already animation-ready in shape: `framebuffer_render_mesh(fb, mesh, model_matrix, cam, light_dir)` takes the model matrix per call — a loop only has to recompute that matrix and re-clear/re-render. | `src/renderer.f90` |
| All transform primitives an evaluator needs already exist and are `pure`: `mat4_rotate_x/y/z`, `mat4_translation`, `mat4_scale`, `mat4_mult`, `vec3_add/sub/scale`. No new math is required for v1. | `src/math_3d.f90` |
| There is exactly one object, no named-object/scene graph, and no per-object transform storage. `scene.json` is a flat baked triangle list (`{triangles:[{v,color}]}`) with no object identity, origin, or transform. | `src/main.f90`, `src/mesh.f90:export_mesh_json`, `scene.json` |
| The JS side has animation, but it is a *different, hardcoded* one: global `rotX=0.35, rotY=0.6`, `if (autoRotate) rotY += 0.015` per `requestAnimationFrame` — frame-rate dependent, whole-scene only, not driven by `scene.json`. Native and JS motion therefore cannot match today. | `viewer.html:render3D()` |
| Camera is static after `camera_init`; it has position/target/fov fields that a track could write, but nothing does. | `src/camera.f90` |

**Consequence:** animation is not a renderer change. It is (1) a *timeline
model* in the compiler IR, (2) a tiny *evaluator* `eval(object, t) → mat4`
implemented twice (Fortran + JS) from one spec, and (3) a *frame loop* around
the existing render call. Per-object identity in the scene/IR is a prerequisite
(dependency on the scene/DSL plan, §10).

## 2. Design principles

1. **Time is data, never code.** The DSL declares *what moves, how, how long*;
   no user callbacks, expressions, or scripting in v1/v2. This keeps the
   Fortran and JS evaluators trivially equivalent.
2. **One IR, two evaluators, no baking by default.** The compiler emits the
   timeline symbolically (§7). Baking to per-frame matrices is an export
   option, not the model — symbolic is smaller, editable, and lets the JS
   viewer stay interactive (pause/scrub) instead of playing a flipbook.
3. **Deterministic, sample-based.** Motion is a pure function `f(t)` of
   timeline seconds. No accumulated state (`rotY += …` is explicitly banned —
   it drifts and depends on frame rate, cf. `viewer.html` today). Same `t` →
   same matrix, bit-for-bit modulo float rounding, on both targets.
4. **Beginner vocabulary, maths underneath.** Users say `spin`, `bob`, `orbit`;
   each is a closed-form formula (§4) built from existing `mat4_*` calls.
   Nobody writes a matrix or a keyframe to make a cube turn.
5. **Defaults that animate.** Every primitive has a sensible duration/easing/
   loop default so `spin cube` alone does something visible; every parameter
   is overridable.
6. **Static pose = timeline at t=0.** A scene with no `animate` block must
   compile to exactly today's behaviour (static transform, one frame native).

## 3. Timeline model

```
Scene ── duration D (s), fps F (native export), loop mode
  └─ Track   : target = object name | camera | light   (v1: objects only)
       └─ Clip : one primitive or keyframe list,
                 start (s, default 0), duration (s), easing, loop, delay
```

- **Global clock:** `t ∈ [0, D)`. Scene `duration` defaults to the longest
  clip end; explicit `duration` may truncate or pad (pad = hold last pose).
- **Sampling:** native renders frames `n = 0 … ⌈D·F⌉−1` at `t = n/F`
  (default `F = 30`; DSL `fps` only affects native export, §8). JS samples the
  same function at the display's rAF timestamps — same poses, denser times.
- **Composition order (fixed, documented):** for one object, clips on
  *different channels* (translate / rotate / scale) compose; the final matrix
  is `M = T · R · S` — the same order as today's `rot_y · rot_x` composition
  generalised. Multiple clips on the *same channel* in v1: last-declared wins
  for its interval, with a compiler warning; additive/override blending is v2.
  Rotation from several clips composes as `R = R_spin · R_orbit · R_keyframe`
  in declaration order (matrix multiply, matching `mat4_mult` semantics).
- **Base transform:** the object's static `position/rotation/scale` from its
  scene declaration is the value every channel starts from and returns to for
  `loop: pingpong`/`once` hold semantics.

## 4. Primitives (v1 DSL)

Illustrative syntax (final keywords belong to the DSL-grammar plan; semantics
here are normative):

```dsl
object cube { shape: cube; size: 2; color: red }

animate cube {
  spin  axis: y  speed: 90deg/s            # or: turns: 1  duration: 4s
  bob   axis: y  height: 0.5  period: 2s   # sinusoidal up/down
  orbit center: (0,0,0) radius: 3 period: 6s phase: 0
}
animate cube { move from: (-3,0,0) to: (3,0,0) duration: 2s ease: easeInOut loop: pingpong }
animate cube { grow from: 0.5 to: 1.5 duration: 1s }        # uniform-scale lerp
animate camera { orbit center: (0,0,0) radius: 6 period: 12s }  # v1 stretch / v2
```

| Primitive | Channels | Closed form (t = local clip time, T = period/duration) | Built from |
|---|---|---|---|
| `spin` | rotate | `angle(t) = angle₀ + 360°·turns·(t/T)` (or `speed·t`); unbounded under `loop: forever` | `mat4_rotate_{x,y,z}` |
| `bob` | translate (1 axis) | `offset = height · sin(2π·t/period + phase)`; starts/ends at base | `mat4_translation` + `sin` |
| `pulse` | scale | `s = base · (1 + amount·sin(2π·t/period))` — `bob` for scale; cheap to add, same code path | `mat4_scale` |
| `orbit` | translate (+ optional `face: center\|direction\|none`) | `pos = center + radius·(cos θ, plane_y, sin θ)`, `θ = 2π·t/period + phase`; plane = XZ default, XY/XZ/… via `plane:` | `mat4_translation`, optionally `mat4_rotate_y(−θ)` for facing |
| `move` / `lerp` | translate | `pos = lerp(from, to, ease(u))`, `u = clamp(t/duration)` — the generic primitive; `spin`/`grow` are sugar over the same lerp core for angles/scalars | `vec3_add/sub/scale`, `mat4_translation` |
| `turn` | rotate | `angle = lerp(from_deg, to_deg, ease(u))` about one axis | `mat4_rotate_*` |
| `grow` / `shrink` | scale | `s = lerp(from, to, ease(u))`, scalar or per-axis vec3 | `mat4_scale` |
| `fade` | — | **Deferred:** renderer has only per-triangle RGB with no alpha/opacity (`renderer.f90` writes opaque RGB), so `fade` is rejected in v1 with a clear error, not silently ignored. Revisit if colour/alpha lands. | — |

Notes:
- `spin` accepts exactly one of `speed` / `turns+duration`; both given = error.
- All angles in degrees in the DSL (renderer converts, as `main.f90` does
  today with `* PI / 180`); all times in seconds (`2s`, `500ms` accepted).
- `lerp` is also exposed generically — `lerp cube.position from … to …` — as
  the escape hatch the keyframe system (§6) is built on.

## 5. Easing, duration, loop

**Easing** applies to the normalised progress `u ∈ [0,1]` of finite clips
(`move/turn/grow`, keyframe segments). Periodic primitives (`spin/bob/orbit/
pulse`) are intrinsically sinusoidal/linear and ignore `ease` (warning if set).

| Name | Formula `e(u)` | Notes |
|---|---|---|
| `linear` (default) | `u` | |
| `easeIn` | `u²` | quadratic; cheap, no `pow` portability issues |
| `easeOut` | `1−(1−u)²` | |
| `easeInOut` (default for `move`) | `2u²` if u<½ else `1−(−2u+2)²/2` | |
| `easeInCubic`, `easeOutCubic` | `u³`, `1−(1−u)³` | v1 optional |
| `smooth` | `3u²−2u³` (smoothstep) | zero slope both ends; good default for keyframes |
| `bounce`, `elastic`, `back`, steps/`steps(n)` | — | **v2 only**; piecewise/overshoot complicates Fortran↔JS parity tests |

Easings are a closed named set (an enum in IR), never user formulas — this is
what makes dual-target parity testable (§9).

**Duration / delay / loop** — every clip carries:
`start` (default 0), `delay` (= start offset sugar), `duration`/`period`,
`loop: once | forever | pingpong | repeat(n)`, `hold: first|last` for after a
finite clip ends (default `last` inside scene duration).

| Loop mode | Local time mapping for global t |
|---|---|
| `once` | `u = clamp((t−start)/duration)`; hold end pose after |
| `forever` | `τ = mod(t−start, period)` — the natural mode for spin/bob/orbit |
| `pingpong` | triangle wave over `2·duration`: forward then reverse (easing applied per leg) |
| `repeat(n)` | `forever` for n cycles, then hold |

## 6. Keyframes: v1 simple vs v2 full

### v1 — "simple keys" (ship this)
Per-object, per-channel key lists with scalar/vec3 values at times; the
compiler sorts, validates, and lowers them to piecewise `lerp` segments —
no new runtime concept beyond §4's lerp core.

```dsl
animate cube {
  keys position { at 0s: (-3,0,0);  at 2s: (3,0,0) ease: easeInOut;  at 3s: (3,1,0) }
  keys rotation.y { at 0s: 0;  at 2s: 180;  at 4s: 360 }   # degrees, unwrapped (see below)
}
```

Rules: first key need not be at 0 (hold-first before it); last key holds to
scene end; one easing per segment (named on the *destination* key, default
`smooth`); duplicate times = error; rotation keys interpolate the *number*
(so 350→10 goes backwards unless written 350→370 — documented, with a
`shortest` modifier reserved for v2); no tangents, no per-key easing curves.

### v2 — full keyframes (design now, build later)
- Any animatable channel incl. camera position/target/fov, light direction,
  and colour (if the material plan adds it).
- Cubic Bézier / Catmull-Rom interpolation with in/out tangents
  (`interp: linear|smooth|bezier|step`), `step` = hold-then-jump.
- `shortest`-path angle interpolation; quaternion slerp if/when a quaternion
  type joins `math_3d` (v1 deliberately stays Euler-per-axis, matching the
  existing `mat4_rotate_x/y/z` API).
- Clip blending: additive + weighted override between overlapping clips,
  cross-fades, named reusable clips (`clip spin_fast { … }`, `use spin_fast on cube`),
  timeline markers/events (`at 2s { … }` one-shot triggers), and grouped/
  staggered tracks (`stagger: 0.2s` across a group).
- Import of keyframes from external tools (glTF animation) — explicitly out
  of scope until an asset-import plan exists.

**Cut line:** if a beginner can express it with spin/bob/orbit/move + v1 keys,
it is v1. Everything requiring tangents, blending, or triggers is v2.

## 7. Compiler IR (the contract both runtimes implement)

Emitted into `scene.json` as a new top-level block alongside today's
`triangles`, plus named objects (prerequisite, §10). Versioned so the viewer
can refuse unknown versions instead of mis-playing them.

```json
{ "version": 2,
  "objects": [{ "name": "cube", "base": {"position":[0,0,0],
                "rotation_deg":[20,35,0], "scale":[1,1,1]}, "mesh": "…" }],
  "timeline": { "duration": 4.0, "loop": "forever",
    "tracks": [{ "target": "cube", "clips": [
      {"kind":"spin","channel":"rotate","axis":"y","turns":1,
       "start":0,"duration":4,"loop":"forever","ease":"linear"},
      {"kind":"keys","channel":"translate","keys":[
        {"t":0,"v":[-3,0,0]},{"t":2,"v":[3,0,0],"ease":"easeInOut"}]}
    ]}]}
}
```

Compiler passes: parse → resolve targets/defaults → validate (§9) → lower
sugar (`bob`→sinusoidal translate track, `spin`→angle track, `grow`→scale
lerp) → emit IR. Lowering in the *compiler* means both runtimes implement only
the small lowered set: `spin/angle`, `periodic-translate (orbit/bob)`,
`lerp (vec3|scalar)`, `keys`. Runtimes never see DSL sugar.

## 8. Emission: native Fortran vs JS runtime

Same IR, two consumers — the essential asymmetry is *who owns the clock*:

| | Native (Fortran) | JS (`viewer.html`) |
|---|---|---|
| Clock | Compiler-chosen fixed step: frame `n`, `t=n/fps` | Wall clock: `t = (now − start)/1000`, wrapped by timeline loop mode |
| Output | Sequence `frames/frame_0000.ppm … frame_NNNN.ppm` (existing P3 writer, unchanged) + optional `ffmpeg` hint/`Makefile` target to mux to MP4/GIF (tooling note only; renderer gains no encoder) | Live canvas playback via existing `requestAnimationFrame(render3D)` loop |
| Evaluator | New module `src/animation.f90` (planned): `timeline_eval(tracks, name, t) → mat4`, pure functions mirroring §4–§6 formulas using existing `mat4_*`/`vec3_*`; `main.f90` gains a frame loop: for each frame, per object — clear FB, `framebuffer_render_mesh(..., model_matrix=timeline_eval(...))`, `framebuffer_save_ppm` | `evaluateTrack(track, t) → {position, rotation, scale}` in JS, replacing the hardcoded `rotY += 0.015` and global `rotX/rotY`; per-object transforms applied in `rotatePoint/project` path (requires per-object grouping of triangles — today they are one flat list) |
| Interactivity | None (offline render); `--frame N` / `--time T` single-frame mode preserves today's one-PPM behaviour and is the parity-test hook | Play/pause, scrub slider, speed — free once time is a function argument; auto-rotate button becomes "play timeline" |
| Static scenes | No `timeline` ⇒ compile exactly today's `main.f90` shape, one frame | No `timeline` ⇒ viewer keeps manual orbit controls as now |

**Baked alternative (export option, not default):** `compile --bake` samples
the IR at `fps` and emits per-frame matrices (native: a Fortran include/table;
JS: a JSON array). Useful for archival/exact-reproduction and as a debugging
oracle, at ~`frames × objects × 16 floats` size. Never the interchange format.

**Parity rule:** both evaluators implement §4–§6 formulas in double (Fortran
`real(dp)`) / IEEE-754 double (JS `number`) with identical operation order for
lerp/easing; trig (`sin/cos`) may differ in the last ulp — acceptable, as poses
are compared with tolerance (§9), never bitwise.

## 9. Validation & diagnostics (compiler, all with line numbers)

Unknown target object; unknown easing/loop/kind; `duration ≤ 0`, `period ≤ 0`,
negative `radius/height`; `spin` with both `speed` and `turns`; keys unsorted
after parse / duplicate `t` / key outside `[0, duration]` (warn + clamp option);
clip extending past scene `duration` (warn, not error); same-channel overlap
in v1 (warn: last wins); `fade` or any v2-only feature used in v1 mode (error
naming the feature and version). Empty `animate {}` = warning, static object.

## 10. Dependencies, phases, acceptance

**Dependencies:** named objects + per-object base transform in the scene/IR
and in `scene.json` (scene/DSL plan) — without object identity there is
nothing for a track to target; grouped triangles per object in `viewer.html`;
compiler CLI flags for `--fps/--bake/--frame` (CLI plan).

**Phases:**
1. **P09-a IR + native evaluator:** timeline IR, `animation.f90` evaluator
   (spin, move/lerp, grow, bob, orbit), frame loop + `frame_%04d.ppm`,
   single-frame mode. Reproduce today's pose as t=0 regression.
2. **P09-b JS evaluator:** viewer consumes the same IR; delete hardcoded
   auto-rotate as a *motion source* (keep as a fallback demo only when no
   timeline exists); play/pause/scrub UI.
3. **P09-c v1 keys + easing set + pingpong/repeat**, diagnostics (§9).
4. **P09-d (v2):** camera/light tracks, Bézier/step interp, clip blending,
   reusable clips, markers.

**Acceptance tests:**
- *Golden poses:* for a fixture scene using every v1 primitive, sample
  `t = 0, ¼, ½, ¾` of duration; Fortran evaluator (via `--time` mode printing
  the matrix) and a headless JS evaluation must agree per element within 1e-6.
- *Loop closure:* pose at `t=0` equals pose at `t=duration` for
  `loop: forever` scenes built from periodic primitives (within 1e-9).
- *Static regression:* no-`animate` scene produces a PPM identical to the
  current `output_render.ppm` pipeline.
- *Frame count/duration:* native export of a 4 s @ 30 fps scene yields
  exactly 120 PPMs named sequentially; JS reports the same duration.
- *Diagnostics:* each §9 error triggered by a minimal bad input, asserting
  message + line number.

## 11. Risks & open questions

- **Per-object rendering cost native-side:** frame loop re-rasterises per
  object into one framebuffer — fine for v1 scene sizes; multi-object
  z-buffer interaction is already handled because `renderer.f90` keeps the
  z-buffer in the shared `FrameBuffer` across `render_mesh` calls (verify in
  P09-a; clear must happen once per frame, not per object).
- **PPM volume:** P3 ASCII at 640×480 × 120 frames is hundreds of MB —
  recommend P6/binary or direct pipe to an encoder as a fast follow-up
  (renderer plan), and default native previews to lower fps/resolution.
- Euler-order surprises for combined keyframed rotation (documented
  `R = Rx·Ry·Rz` order needed — today only `Ry·Rx` is exercised in `main.f90`);
  quaternion path is the v2 answer.
- Should scene-level `loop: forever` be the default for *native* export
  (infinite frames)? No — native always requires a finite `duration`;
  `forever` clips wrap inside it. JS may loop the timeline indefinitely.
- Open: audio/sync, timeline events triggering non-motion actions, and
  animating colour/light — all v2+, gated on renderer/material plans.
