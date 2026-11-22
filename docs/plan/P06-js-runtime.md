# P06 — JS Runtime Design: Tiny WebGL Viewer

> Status: PLAN ONLY — no code written by this document.
> Repo baseline (verified 2026-11-23): `viewer.html` = 16,975 B, single file,
> Canvas 2D painter's-algorithm renderer + P3 PPM viewer, hard-coded cube,
> `fetch('scene.json')`, mouse orbit / wheel zoom / right-drag pan.
> Fortran baseline: `src/math_3d.f90` (`vec3`, `mat4`, perspective, look-at),
> `src/mesh.f90` (`Triangle{v(3), normal, color}`, `Mesh`, `export_mesh_json`),
> `src/camera.f90` (`Camera{position,target,up,fov,aspect,near,far}`),
> `src/renderer.f90` (Z-buffer, barycentric, Lambertian shading, PPM export).
> Goal: an *easy 3D compiler > Three.js / PixiJS* — the Fortran compiler emits
> a scene; this runtime displays it. Ease comes from a tiny, opinionated API,
> not from feature count.

---

## 1. Thesis and Non-Goals

### 1.1 Thesis

Three.js is ~600 KB minified (~150 KB gzip) and PixiJS ~450 KB minified,
because they are general engines: scene graphs, materials, loaders, lights,
cameras, post-processing, WebGL2 state management. A compiled-scene viewer
needs none of that generality — the Fortran side has *already* done the
scene-graph, math, and shading-model decisions. The JS runtime is therefore
a **player, not an engine**: upload flat buffers once, multiply three
matrices per object per frame, draw.

Pitch in one line: **`<script src="f3d.min.js">` + one tag + one line =
orbitable 3D, in under 15 KB, with no build step and no dependencies.**

### 1.2 Explicit non-goals (each is a size saving, defended)

| Excluded | Why |
|---|---|
| Scene graph / hierarchy / groups | Compiler flattens transforms at compile time (§4.3) |
| Materials system, textures, PBR, shadows | v1 shading = flat colour + Lambert, matching `renderer.f90` exactly |
| Loaders (OBJ/glTF/…) in runtime | Compiler ingests formats; runtime reads only its own JSON (§4) |
| Lights as objects | One directional light, baked into scene header |
| Skeletal / morph animation | Only object TRS keyframe tracks (§7) — covers compiler-emitted motion |
| Raycasting / picking, physics, audio, UI widgets | Application concerns; expose hooks, don't ship them |
| WebGL2-only features | WebGL1 everywhere = widest reach + one code path (§3) |
| IE11 / pre-ES2017 browsers | Arrow functions, `Float32Array`, template literals assumed |

Any of the above, if later approved, is an **add-on file** (`f3d-pick.js`,
etc.), never growth of the core. Core size is a contract (§8.3).

---

## 2. Deliverables and File Layout

| File | Role | Ships? |
|---|---|---|
| `runtime/f3d.js` | Readable source, commented, ES2020, no modules/build | Dev |
| `runtime/f3d.min.js` | Terser-minified single file — **the product** | Yes |
| `runtime/f3d.d.ts` | Hand-written types (~1 KB, not counted in runtime budget) | Yes (npm only) |
| `viewer.html` (rewritten) | Thin demo shell: loads `f3d.min.js`, one `<f3d-view>` tag | Yes |
| `runtime/f3d.js` embedded variant | Same source inlined into a standalone `.html` for `file://` use | Optional |

Rules: zero dependencies at runtime *and* at build time for the user;
Terser is a maintainer-only dev tool. No bundler config for consumers.
Distribution: plain file copy, CDN (`unpkg`/`jsdelivr` via npm package
`f3d-runtime`), and copy-paste into a page. Works from `file://` when the
scene is inlined (§4.5); `fetch()` of a sibling JSON needs `http(s)` — the
current viewer's silent `fetch('scene.json')` failure on `file://` is a
known wart this design fixes by falling back to the embedded default cube.

---

## 3. Technology Choices

| Decision | Choice | Rationale |
|---|---|---|
| Graphics API | **WebGL1** (`webgl` → `experimental-webgl`) | ~100 % browser reach incl. old Safari/Android; our shaders need nothing from WebGL2; one context path keeps size down |
| Language | Vanilla ES2020, single IIFE, `'use strict'` | No transpiler, no framework; minifies well |
| Math | Hand-rolled `Float32Array(16)` mat4 (~30 lines) | Mirrors `math_3d.f90` ops only: `multiply, perspective, lookAt, translate/rotate/scale compose`. No vec/mat classes (allocation + size) |
| Matrix convention | **Column-major, right-handed, NDC z ∈ [-1,1]** | Identical to WebGL *and* to Fortran's column-major `mat4` — compiler can emit matrices that upload verbatim, zero transpose bugs |
| Shading | GLSL ES 1.0, one program: per-vertex Lambert + flat colour attribute | Byte-for-byte visual parity with `renderer.f90` (ambient 0.25 + diffuse 0.75 in current viewer; make both scene-configurable, defaults matching Fortran) |
| DOM integration | Custom Element `<f3d-view>` **plus** plain function API | Tag = zero-JS ease (the "easier than Three.js" claim); function API = control for real apps |
| State | One plain object per viewer instance; no globals except `window.F3D` | Multiple viewers per page must work (docs, galleries) |

---

## 4. Compiled Scene Format (the compiler ↔ runtime contract)

### 4.1 v1 compatibility (must not break)

Current `scene.json` (emitted by `mesh.f90:export_mesh_json`) and the
hard-coded cube in `viewer.html` share this shape, and the runtime **must**
load it unchanged:

```json
{ "triangles": [ { "id": 1, "v": [[-1,-1,-1],[1,1,-1],[1,-1,-1]],
                   "color": [220, 60, 60] } ] }
```

v1 semantics: non-indexed triangle soup, colour 0–255 RGB per triangle,
no normals (runtime computes flat normals), no camera/light (runtime
defaults: camera §6.1, light §5.3), world = model space.

### 4.2 v2 format (what the compiler should emit next)

```json
{
  "f3d": 2,
  "meta":  { "name": "cube", "compiler": "fortran-3d-engine x.y", "units": "m" },
  "camera": { "pos": [3,2,4], "target": [0,0,0], "fov": 60,
              "near": 0.1, "far": 100 },
  "light":  { "dir": [-0.5,-1,-0.7], "ambient": 0.25, "diffuse": 0.75,
              "bg": [0.008, 0.023, 0.09] },
  "meshes": [
    { "name": "cube",
      "positions": [/* flat xyz… */],
      "indices":   [/* optional; omit = triangle soup */],
      "colors":    [/* flat rgb, 0..1 floats, per-vertex OR per-face */],
      "normals":   [/* optional flat xyz; omit = compute flat */],
      "transform": [/* optional mat4, 16 column-major floats */] }
  ],
  "anim": [ /* optional, §7 */ ]
}
```

Design rules for v2:

1. **Flat typed-array-friendly arrays**, never arrays-of-arrays (v1's
   `[[x,y,z],…]` costs parse time and runtime flattening code). JSON numbers
   parse straight into `new Float32Array(json.meshes[0].positions)`.
2. Everything optional except `f3d` + `meshes[].positions`. Defaults fill
   the rest — a minimal v2 scene is smaller than v1.
3. Colours as 0..1 floats in v2 (shader-native); v1's 0–255 is detected by
   version and divided by 255 in the loader only.
4. `indices` uses `Uint16` ≤ 65 535 verts/mesh, `Uint32` via
   `OES_element_index_uint` when present, else compiler splits the mesh.
   Runtime never splits (size).
5. Unknown keys are ignored (forward compatibility); a `f3d` major version
   greater than the runtime's throws `F3D: unsupported scene version N`.

### 4.3 Compiler's half of the bargain (recommendations, other plans own these)

Flatten hierarchy, bake per-face colours, emit flat normals only if the
Fortran side already has them (`Triangle.normal` — it does), emit `anim`
tracks (§7) instead of per-frame geometry, and round floats to ≤ 6
significant digits (JSON size is the user's bandwidth, not ours).

### 4.4 Validation

Loader validates minimally and fails loudly once: missing `positions`,
length not divisible by 3, or NaN → `throw` with mesh name + field.
No schema library. Dev build (`f3d.js`, unminified) adds `console.warn`
for suspicious data (empty mesh, far ≤ near); min build stays silent-but-correct.

### 4.5 Loading sources

`src` may be: URL string (→ `fetch`, JSON), a parsed object, a JSON string,
or `null` (built-in cube, so a viewer never renders black on error).
`<f3d-view src="scene.json">`, `<script type="application/f3d+json">`
inline block (the `file://`-safe path), and drag-and-drop of a `.json`
file onto the canvas are all supported — drag-and-drop and the PPM tab
are existing viewer behaviours users already know.

---

## 5. WebGL Renderer (primary path)

### 5.1 Pipeline

```
load → flatten to Float32Array → create 1 VBO per attribute per mesh
     → per frame: compute VP (perspective × orbit lookAt)
       → per mesh: model = mesh.transform × animTRS(t)
       → 1 drawElements / drawArrays per mesh → done
```

Static geometry: `STATIC_DRAW`, buffers created once at load, never
re-uploaded. Interleaving attributes into one buffer was considered and
rejected: separate buffers = simpler loader code, negligible perf cost at
our mesh sizes (target ≤ 100 k triangles/scene; see §10).

### 5.2 Shaders (complete v1 program — this is all of it)

```glsl
// vertex
attribute vec3 p; attribute vec3 n; attribute vec3 c;
uniform mat4 mvp; uniform mat4 nm; // normal matrix (upper 3x3 of model)
varying vec3 vc; varying float li;
uniform vec3 ld;                   // normalised light dir
void main(){ vc=c;
  li = AMBIENT + DIFFUSE * max(0.0, dot(normalize(mat3(nm)*n), -ld));
  gl_Position = mvp * vec4(p,1.0); }
// fragment
precision mediump float; varying vec3 vc; varying float li;
void main(){ gl_FragColor = vec4(vc*li, 1.0); }
```

`AMBIENT`/`DIFFUSE` are `#define`-injected from the scene at compile time
(no extra uniforms, no per-frame cost). Wireframe mode = same program,
`gl.LINES` on an index-derived edge list is too costly to build; instead
wireframe re-draws with `polygonOffset`-free trick: draw filled, then the
fallback renderer (§9) owns true wireframe — **or** simpler ruling:
WebGL wireframe = `gl.LINES` using positions as line pairs is wrong, so
v1 WebGL wireframe is *omitted* and the toggle routes to the 2D renderer.
Decision flagged in §11.

### 5.3 Context setup

`antialias:true, depthFunc:LEQUAL, enable(DEPTH_TEST), enable(CULL_FACE)`
(back-face, matching current viewer's `nz <= 0` cull and Fortran's
Z-buffer result), clear colour from `scene.light.bg` (default `#020617`
as today). `powerPreference:'low-power'` — this is a viewer, not a game;
keeps laptop/iGPU users (incl. the owner's Vega 7 class hardware) cool.
Handle `webglcontextlost` → show overlay text + attempt restore on
`webglcontextrestored` (re-upload buffers from retained typed arrays —
retain them; ~10 lines, prevents a whole class of "black canvas" reports).

### 5.4 Resize & DPI

`ResizeObserver` on the element (fallback: window `resize`), canvas backing
store = `clientSize × min(devicePixelRatio, 2)`, aspect fed to
`perspective()`. Cap DPR at 2: beyond that is invisible for flat shading
and quadruples fragment cost.

---

## 6. Orbit Controls

Replaces today's ad-hoc `rotX/rotY/panX/zoom` globals with a spherical
orbit state per instance — same feel, correct maths:

```
state = { theta, phi, radius, target:[x,y,z] }   // phi clamped [0.05, π-0.05]
camera.pos = target + radius·(sinφ·sinθ, cosφ, sinφ·cosθ)
view = lookAt(pos, target, [0,1,0])
```

| Input | Action | Notes |
|---|---|---|
| Left-drag / 1-finger touch | Orbit (`theta -= dx·0.01`, `phi -= dy·0.01`) | Same 0.01 sensitivity as current viewer — muscle memory preserved |
| Wheel / pinch | Zoom `radius *= exp(deltaY·0.001)`, clamp `[near·2, far/2]` then scene override | Exponential = uniform feel at all scales; replaces linear `zoom ±` |
| Right-drag / middle-drag / 2-finger | Pan target in camera right/up plane, scaled by `radius` | `contextmenu` suppressed on canvas only |
| Double-click | Reset to scene camera (or default §6.1) | Also `viewer.reset()` |
| Keys (canvas focused, `tabindex=0`) | Arrows orbit, `+/-` zoom, `R` reset | Accessibility, ~15 lines, include in v1 |

Defaults §6.1: if scene has no camera, frame the mesh: compute bounding
sphere from positions at load, `radius = 2.2 × sphere.radius`,
`theta=0.6, phi=1.22` (≈ today's `rotY 0.6, rotX 0.35` view), target =
sphere centre. Auto-framing is the single biggest "it just works" win
over both the current viewer (fixed `zoom=140`, distance 4) and a raw
Three.js setup. Auto-rotate: `theta += dt·0.9 rad/s` when enabled and not
interacting (today: fixed 0.015/frame — frame-rate dependent; fix to
time-based), pauses on pointer-down, resumes after 2 s idle if it was on.
Touch: Pointer Events unify mouse/touch/pen — one handler set, no
separate touch code.

---

## 7. Animation Loop and Animation Data

### 7.1 Loop

- Single `requestAnimationFrame` per instance; `dt` clamped to 50 ms
  (tab-switch spikes must not teleport animations).
- **Render-on-demand optimisation:** if no animation track is active,
  auto-rotate is off, and no control is interacting, skip rendering after
  one final frame (dirty-flag set by controls/resize/load). A static
  product page with 10 viewers then costs ~0 % CPU — a headline advantage
  over a naive Three.js loop, and kind to battery/iGPU heat.
- Pause automatically on `document.hidden` (rAF does this anyway) and on
  `IntersectionObserver` off-screen (docs pages with many viewers).
- `viewer.fps` (rolling average) exposed for HUD/debug; no HUD ships.

### 7.2 Animation format (compiler-emitted, optional)

```json
"anim": [ { "mesh": "cube", "prop": "rotY",
            "keys": [[0, 0], [2, 6.283]], "ease": "lin", "loop": true } ]
```

`prop ∈ {tx,ty,tz, rx,ry,rz, sx,sy,sz}` (uniform `s` allowed), times in
seconds, linear interpolation in v1; `ease ∈ {lin, io}` (smoothstep) only.
Per frame, animated meshes compose `T·Rx·Ry·Rz·S` into their model matrix;
unanimated meshes use their static `transform` untouched (zero cost).
This covers turntables, mechanisms, and compiler demos — everything the
Fortran engine can currently express — in ~0.6 KB. Anything richer
(skeletons, paths, events) is an add-on (§1.2), decided in §11.

---

## 8. Public API

### 8.1 Zero-JS form (the marketing surface)

```html
<script src="f3d.min.js"></script>
<f3d-view src="scene.json" autorotate wireframe style="width:640px;height:480px"></f3d-view>
```

Attributes: `src`, `autorotate`, `wireframe`, `bg` (CSS colour override),
`spin-speed`. Element properties mirror the JS API below. This is the
entire learning curve for the common case — compare Three.js: import map,
module script, renderer/camera/scene boilerplate (~40 lines before a cube).

### 8.2 Function form

```js
const v = F3D.create(canvasOrSelector, opts?)   // → Viewer
v.load(sceneOrUrl)        // Promise<Viewer>; replaces scene
v.setScene(object)        // synchronous, already-parsed scene
v.start() / v.stop()      // animation loop control (starts on load)
v.render()                // one frame, now (render-on-demand mode)
v.reset()                 // camera to scene/default framing
v.snapshot()              // → dataURL PNG (preserveDrawingBuffer:false;
                          //   renders once synchronously then captures)
v.dispose()               // frees GL buffers/context listeners; element reusable
v.on('load'|'error'|'frame', fn)   // only three events in v1
v.state                   // { backend:'webgl'|'2d', tris, fps, camera:{…} }
Viewer opts: { autorotate, wireframe, dpr, light:{…}, onError }
F3D.version               // '1.0.0'  •  F3D.supported() → 'webgl'|'2d'
```

Conventions: methods chain where sensible (`v.load(x).then(()=>v.reset())`),
errors are `Error` with `F3D:` prefix, no method throws after successful
`create()` except `load` on a malformed scene. Global footprint: exactly
one name, `F3D`, plus the `f3d-view` element registration.

### 8.3 Stability contract

API above is frozen at 1.0; scene format v2 is frozen likewise (§4.2 rule 5
is the evolution path). Semver: additive opts/attributes = minor, never
breaking a v1 or v2 scene = major-only, and the runtime must *always* load
v1 (§4.1) — old Fortran exports keep working forever.

---

## 9. Fallback: Canvas 2D / Software Path

Trigger: `canvas.getContext('webgl')` returns null or context creation
throws (blocked GPU, very old browser, headless, some VMs). Fallback is
**automatic, silent except `v.state.backend === '2d'`, and API-identical**
— same scene, same controls, same animation. This reuses, deliberately,
the *existing* viewer's proven approach rather than inventing a new one:

| Aspect | Spec (largely = today's `viewer.html` maths) |
|---|---|
| Projection | CPU mat4 MVP per vertex (reuse §3 math), perspective divide, viewport map |
| Depth | Painter's sort by mean z per triangle (today's approach) — *not* a per-pixel Z-buffer: a 640×480 `Float32Array` Z-buffer + barycentric rasteriser (Fortran parity) costs ~1.2 KB more and is the §11 decision; painter's is correct for convex/non-intersecting meshes, which is what the compiler emits today |
| Culling/shading | Back-face cull on signed area; per-face Lambert with the same light/ambient/diffuse constants as GLSL path → visually near-identical stills |
| Wireframe | Native here: stroke projected triangles (today's behaviour) — and the WebGL path's wireframe toggle routes here (§5.2) |
| Performance guardrails | Triangle budget: > 20 k tris → auto-reduce to wireframe + one `console.warn`; target 30 fps at 5 k tris on a mid phone; DPR forced to 1; render-on-demand still applies |
| Animation | Same `anim` tracks (§7.2), evaluated on CPU — no format difference |

Also on this path: the **PPM viewer tab stays**. `output_render.ppm`
(P3 today; P6 support is a compiler/viewer-plan question, not runtime)
remains a feature of the demo `viewer.html` shell, implemented *outside*
`f3d.min.js` — it is Fortran-rasteriser showcase, not runtime scope, and
excluding it is ~2 KB of the size win (§10.2). The shell keeps the tab UI;
the runtime keeps only 3D.

Degraded-but-honest: if Canvas 2D is also unavailable (effectively never),
`create()` draws a static message into the element and fires `onError`.

---

## 10. Size Budget — < 15 KB

### 10.1 Definition of the number

**`f3d.min.js` ≤ 15,360 B minified (Terser, `ecma:2020`), target ≈ 11–12 KB,
stretch ≤ 8 KB gzipped.** Measured in CI on every commit (§10.3); the
budget is a failing test, not an aspiration. HTML shell, `.d.ts`, and the
PPM tab code are not counted (they are not the runtime) — and must be
reported separately so the claim stays honest.

### 10.2 Budget breakdown (minified estimates, from module design)

| Module | Contents | Budget |
|---|---|---|
| Boot + Custom Element | IIFE, `F3D` export, `<f3d-view>` define, attribute glue | 1.2 KB |
| Mat4 math | identity/multiply/perspective/lookAt/compose-TRS, bounding sphere | 1.4 KB |
| Scene loader | v1 detect+convert, v2 flatten, defaults, validation, fetch/inline/drop | 1.8 KB |
| WebGL renderer | context, shader compile (strings incl.), buffers, draw, context-lost | 2.6 KB |
| Orbit controls | Pointer Events, wheel, pinch, keys, auto-rotate, framing | 1.7 KB |
| Animation | rAF loop, dirty-flag, dt, keyframe eval (lin/io) | 0.9 KB |
| Canvas 2D fallback | project, sort, cull, shade, fill, wireframe | 1.9 KB |
| Misc | events (3), snapshot, dispose, resize/DPR | 0.7 KB |
| **Total planned** | | **12.2 KB** |
| Headroom to hard cap | reserved for fixes, not features | 3.1 KB |

### 10.3 How the current 17 KB becomes 12 KB (the honest delta)

Today's 16,975 B is *unminified* HTML+CSS+JS for a 2D-only viewer.
Savings: page CSS/chrome (~5.5 KB) moves to the demo shell and is not
runtime; PPM parser (~2 KB) leaves the runtime (§9); hard-coded cube
shrinks to a compact default-scene literal (~0.3 KB). Costs added back:
real WebGL path (+2.6 KB), v2 loader, animation, accessibility. Net:
more capability than today's viewer in ~72 % of its byte count — and the
comparison to quote publicly is vs. Three.js (~40× smaller), not vs.
our own demo page. Enforcement: CI step `wc -c f3d.min.js` + budget file
`runtime/.size-budget` (15360); PR that exceeds it fails. Gzip figure
reported alongside, never substituted for the raw number.

### 10.4 Techniques that buy the budget

Short-but-readable identifiers pre-minify (minifier does the rest), no
helper libraries, no class hierarchies (plain functions + one state
object), shader strings kept terse, single code path per feature
(Pointer Events only; WebGL1 only), and every feature in §1.2 refused.

---

## 11. Open Decisions (need owner ruling before build)

1. **Wireframe on WebGL:** route toggle to 2D renderer (recommended,
   §5.2/§9) vs. build edge-index buffer at load (+~0.5 KB, true GL
   wireframe). Default if unruled: route to 2D.
2. **2D fallback depth:** painter's sort (recommended, §9) vs. per-pixel
   Z-buffer for Fortran-identical output on intersecting geometry
   (+~1.2 KB, slower). Default: painter's; revisit when compiler emits
   intersecting meshes.
3. **PPM P6 support** in the demo shell (today: P3 only, P6 alerts) —
   belongs to the viewer/compiler plan, noted here because users hit it.
4. **Animation scope:** TRS keyframes only (recommended) vs. also
   camera-path tracks in v1. Default: TRS only.
5. **npm publication** under `f3d-runtime` + CDN links vs. repo-file-only
   distribution for v1.0. Default: repo file first, npm at 1.1.

## 12. Acceptance Criteria (for the build that follows this plan)

1. `f3d.min.js` ≤ 15,360 B in CI; zero dependencies; loads with one
   `<script>` tag, no build step, no console errors.
2. Loads today's `scene.json` (v1, 12 triangles) and a v2 fixture;
   renders both with correct Lambert shading vs. Fortran PPM reference
   (side-by-side still, same camera/light, colour diff within rounding).
3. `<f3d-view src>` zero-JS embedding works; two viewers on one page
   operate independently.
4. Orbit/wheel/pan/touch/keys match §6 table; auto-frame fits an
   off-centre, non-unit mesh without user input; auto-rotate is
   time-based (same speed at 30 Hz and 144 Hz displays).
5. With WebGL disabled (browser flag), same page renders via `2d`
   backend with identical controls and `state.backend === '2d'`.
6. Static scene with no interaction settles to ~0 frames/sec
   (render-on-demand); animated scene sustains display refresh.
7. Works over `file://` with an inlined scene; context-lost/restored
   cycle recovers the image without reload.
8. Demo `viewer.html` rebuilt on the runtime retains: scene.json load
   (button + drag-drop), PPM tab, tri-count badge, reset, wireframe,
   auto-rotate toggle.

## 13. Risks

| Risk | Mitigation |
|---|---|
| WebGL1 deprecation pressure (long-term) | Isolate GL calls in one module; a future WebGL2 swap touches ~2.6 KB only |
| JSON scene size for large meshes (text floats) | Compiler rounding (§4.3); binary sidecar format is a v3 discussion, not v1 scope creep |
| Painter's-sort artefacts misread as runtime bugs | §11.2 ruling + fallback docs state the convex-mesh assumption plainly |
| Size creep via "just one feature" PRs | Hard CI budget (§10.3); add-ons as separate files (§1.2) |
| Safari quirks (Pointer Events, DPR) | Pointer Events supported Safari 13+; test matrix = Chrome/Firefox/Safari/Android Chrome at build time |

---

*End of P06. Companion topics owned by sibling plans: compiler JSON
emission (v2 writer in `mesh.f90`), demo-shell/viewer UX, PPM roadmap,
and any binary scene format.*
