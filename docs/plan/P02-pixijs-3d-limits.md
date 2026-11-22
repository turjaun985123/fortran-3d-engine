# P02 — PixiJS 3D Limits Census

**Repo:** `~/workspace/fortran-3d-engine` — Fortran 3D engine (5 modules in `src/`, 629 LOC at census time)
**Question:** What can PixiJS *not* do natively for 3D, what do the workarounds cost, and which gaps does this engine fill?
**Date / scope:** 2026-11-23. "Natively" = the core package `pixi.js` (v8 line), as documented on pixijs.com.
The separate, very new `@pixi/3d` extension is treated as a *workaround/extension*, not as core — see §4.3, it changes the positioning, not the core census.
**Method:** Official PixiJS 2D page, official Mesh / `PerspectiveMesh` API docs, PixiJS GitHub discussions/wiki, and the plugin repos themselves. No claim below rests on a blog alone where an official source exists.

---

## 1. Verdict in one paragraph

PixiJS is, by its own branding, a **2D** engine: its homepage is literally "PixiJS 2D | The HTML5 Creation Engine — Build 2D games and apps that run in every browser" [E1]. Its scene graph, transforms, camera model, draw-order model, geometry set, asset types, and maths are all 2D. It contains the *raw ingredients* a determined developer can abuse into 3D — custom `Mesh` geometry and hand-written GLSL/WGSL shaders — but an escape hatch is not a 3D engine: every 3D concept (perspective camera, depth, lighting, a loaded model) must be built, bought as a plugin, or, since Nov 2026, added via the beta `@pixi/3d` package. Our engine's opening is the inverse default: **3D concepts are the primitives, in one compiled codebase, with nothing to add.**

---

## 2. Limits table — core `pixi.js`

Legend — **Ours (now):** present in `src/` today · **Ours (roadmap):** gap our design fills by intent, not yet in code. Do not quote roadmap rows as shipped.

| # | 3D capability | Core PixiJS natively | Evidence | Workaround & its cost | Our engine fills |
|---|---|---|---|---|---|
| 1 | **3D scene graph** | ❌ Graph is `Container`/`Sprite` trees with 2D transforms only: `position`/`scale` are `PointData` (x,y), `rotation` is one scalar angle, plus `pivot`/`skew` | Container options in official API docs list exactly those fields, no z anywhere [E2] | `pixi-projection` adds parallel `*3d` classes/fields; `@pixi/3d` adds a separate `Container3D` tree inside a `View3D` | **Now:** all transforms are `mat4` in 3D (`math_3d.f90`: translation, scale, rotate X/Y/Z). **Roadmap:** hierarchical 3D scene graph |
| 2 | **Perspective camera** | ❌ No camera object at all in core — no FOV, near/far planes, `lookAt`, view matrix. "Camera" in the ecosystem means a 2D viewport plugin | Maintainer answer (2022): perspective is *"still not a feature available by default"*, use a plugin [E3]; v5 wiki lists cameras under third-party resources [E4] | `pixi-projection` `Camera3d.setPlanes(...)`; `@pixi/3d` `Camera3D` + `OrbitCamera`/`FPSCamera` extras | **Now:** `camera.f90` — `camera_init(pos, target, fov_deg, aspect, near, far)`, `mat4_look_at`, `mat4_perspective` are first-class |
| 3 | **Z-buffer / depth testing & occlusion** | ❌ Visibility is **draw order** (insertion order, `zIndex` sorting) — painter's algorithm. Two crossing/intersecting triangles cannot resolve per-pixel; sorting whole objects is the only tool | Scene-graph rule from docs/guides: *"Draw order follows insertion order"* [E5] | Hand-rolled shader + `State` depth config on a custom `Mesh` (you own the whole pipeline); or a 3D extension (§4) | **Now:** `renderer.f90` — per-pixel `z_buffer(:,:)`, barycentric depth interpolation, `depth < z_buffer(px,py)` test in `draw_triangle` |
| 4 | **3D geometry / primitives** | ❌ Built-ins are flat: `PlaneGeometry`, `MeshPlane`, `MeshRope`, `NineSlicePlane`. No cube/sphere/cone, no volumetric geometry type; `MeshGeometry` positions are a flat `Float32Array` consumed as 2D | Official Mesh guide's built-in list is planes/rope only [E6] | Procedural geometry by hand in a custom `Mesh`; extensions add primitives | **Now:** triangle meshes with 3D vertices + face normals (`mesh.f90`), `create_cube`; OBJ/JSON export. **Roadmap:** sphere/cone/etc. primitive library |
| 5 | **"Perspective" that is actually 3D** | ⚠️ `PerspectiveMesh` *looks* 3D but is explicitly not: official source — *"IMPORTANT: This is not a full 3D mesh, it is a 2D mesh with a perspective projection applied to it"*; correction is done **at UV level** on one quad | `PerspectiveMesh.ts` docs [E7]; Mesh guide: *"Ideal for emulating 3D projection in 2D"* [E6] | None needed if a textured quad is all you want — that is the ceiling, not a starting point | **Now:** true perspective divide through a 4×4 projection matrix for *every* vertex, not UV trickery on a quad |
| 6 | **3D transforms: rotation on 3 axes / quaternions** | ❌ One Z-axis `rotation` scalar. No X/Y rotation, no Euler triple, no quaternion, no gimbal-lock story | See #1 [E2]; `pixi-projection` README states the gap itself: *"PixiJS gives only `position`, `scale`, `rotation`, `pivot`"* and adds `position3d`, `euler`, `scale3d`, `pivot3d` [E8] | `pixi-projection` (see §4.1 for version rot) | **Now:** `mat4_rotate_x/y/z`, full `mat4_mult` composition. **Roadmap:** quaternions |
| 7 | **Lights** | ❌ No light types, no lighting environment. Illumination = tint, blend modes, filters — all 2D/screen-space | Official 2D feature list: sprites, graphics, filters & blend modes, text, masks — no lights/materials [E1] | `pixi3d` `LightingEnvironment`; `@pixi/3d` directional/point/spot/ambient (≤32/view) | **Now (partial):** directional Lambertian shading in `renderer.f90` (`light_dir`, per-face intensity). **Roadmap:** point/spot/ambient, shadows |
| 8 | **Materials (PBR / Phong / specular)** | ❌ No material concept. A `Mesh` has a texture + a shader you write yourself; no metallic-roughness, normals-based shading, IBL, env maps | Mesh guide defines a mesh as geometry + **your** shader + GPU state [E6] | `pixi3d` / `@pixi/3d` PBR materials | **Roadmap:** material system. Honest note: today we have flat colour + Lambert only — this row is a gap for *both* core Pixi and our current code, closed by design intent only |
| 9 | **3D model loading (glTF / OBJ)** | ❌ Core `Assets` loads *"textures, spritesheets, fonts, SVG, video and compressed textures"* — no 3D model format | Official 2D page, Assets feature [E1] | `pixi3d` and `@pixi/3d` both add glTF/GLB (+Draco/meshopt in the latter) | **Roadmap:** native loader. **Now:** meshes are procedural + OBJ/JSON *export*; no glTF import yet — do not claim parity here |
| 10 | **Shadows** | ❌ No shadow maps, no casters/receivers. Fake blob/drop shadows via filters only | Absent from the entire core feature surface [E1][E6] | `@pixi/3d` (PCF + cascades); `pixi3d` dynamic shadows | **Roadmap** only |
| 11 | **Skeletal / morph / 3D animation** | ❌ Core animation = `AnimatedSprite` frame flipping and 2D tweens. No skinning, bones, morph targets, clip blending for models | 2D page lists `AnimatedSprite` *"for frame animation"* [E1] | Both 3D extensions add skinned + morph animation | **Roadmap** only |
| 12 | **3D maths library** | ❌ Core maths is 2D points/matrices for affine transforms. No `Vector3`, `Matrix4`, quaternion, `Ray`/`Plane`/`Box` in core | `@pixi/3d` intro advertises `Vector3`, `Matrix4`, `Quaternion`, `Ray`, `Plane`, `Box` as things *it* adds [E9] | Extension, or bring your own maths (e.g. gl-matrix) and bridge it | **Now:** `math_3d.f90` — `vec3` (add/sub/scale/dot/cross/norm/normalize), `mat4` (identity/mult/translate/scale/rotate/perspective/look-at/transform) |
| 13 | **Near/far clipping & frustum culling (3D)** | ❌ No frustum exists to cull against. Core culling is 2D bounds-based | Consequence of #2; `pixi-projection` lists culling as *not yet available* even in the plugin (*"Will be available after we add it to `pixi-layers`"*) [E8] | Extension / hand-rolled | **Now (partial):** NDC depth-range check in `draw_triangle`. **Roadmap:** full frustum culling |
| 14 | **3D picking / raycasting** | ❌ Pointer events hit-test in 2D (hit areas, point-in-shape). No ray, no unprojection, no `screenToWorld`/`worldToScreen` for a 3D scene | `pixi3d` README has to supply `camera.screenToWorld` / `worldToScreen` itself because core cannot convert [E10] | Extensions add ray-picking | **Roadmap** only |
| 15 | **Depth-aware effects / post-processing** | ⚠️ ~40 filters exist, but they are 2D screen-space effects on display objects — no depth buffer to do SSAO, depth-of-field, fog-by-distance, or correct transparency-in-depth | Filters listed as a 2D feature [E1]; depth-based effects appear only in `@pixi/3d/extras` (Bloom, SSAO, FXAA) [E11] | `@pixi/3d/extras` | **Roadmap:** fog/DoF become cheap *because* we own a real z-buffer from day one |
| 16 | **Runs outside a browser / GPU stack** | ❌ Browser-only, WebGL/WebGPU (experimental Canvas fallback). No native binary, no headless file render, no Fortran/C interop path, JS runtime required | Renderers guide: WebGPU feature-complete but WebGL *"recommended for production"*; Canvas renderer experimental [E12] | Bolt Pixi and Three.js onto one shared WebGL context (officially possible in v8, with `resetState()` juggling and no shared textures — a known-painful hybrid [E13]) | **Now:** compiled Fortran, deterministic software rasteriser, renders to PPM/PNG with **no browser, no GPU, no JS** — and is callable/compilable like any native library |

### What core PixiJS *does* give a would-be 3D author (fairness box)

- **Batching at scale** — its actual superpower: 200k sprites / 1M particles at 60 fps claims on the official page [E1]. Irrelevant to correctness of 3D, decisive for flat scenes.
- **A real escape hatch** — `Mesh` + custom GLSL/WGSL shaders + configurable GPU `State` (blending, depth, stencil) [E6]. A skilled graphics programmer *can* hand-build a 3D renderer inside Pixi. That is "Pixi doesn't stop you", not "Pixi does 3D" — the camera, depth discipline, lighting and loaders are then *your* code to maintain.
- **2.5D tricks that are often enough** — `PerspectiveMesh`, parallax, projected sprite demos (the official tour's "star warp" projects 3D points to 2D sprites in user code [E1]). If the product never needs intersecting geometry, occlusion, or a movable camera, faking it is the cheaper correct choice — say so to users.

---

## 3. The pattern behind the limits

All 16 rows are one decision, not sixteen accidents:

1. **Coordinates are 2D at the type level** — `PointData` positions, scalar rotation. Z cannot be smuggled in; it must be added by replacing the classes (which is exactly what every plugin does).
2. **Order replaces depth** — a retained scene graph drawn in tree order has no place to put a depth buffer without changing the renderer's contract.
3. **The product boundary is deliberate** — PixiJS calls itself a *creation/rendering engine, not a game engine*, and its own ecosystem strategy is to fill gaps with separate packages rather than grow the core [E12]. 3D was always going to arrive, if at all, as an add-on — and it did (§4.3).

**Implication for us:** competing with core Pixi on 3D is competing with an absence. The real competitor for a user who wants Pixi-flavoured 3D is `@pixi/3d` (§4.3) and Three.js — positioning must be won against them, not against the straw man.

---

## 4. Workarounds census

### 4.1 `pixi-projection` — 2.5D/3D transforms for sprites

- **What it adds:** `Camera3d`, `Sprite3d`/`Container3d`/`Mesh3d2d`, `position3d`/`euler`/`scale3d`, projective & bilinear quads [E8].
- **Ceiling:** it projects *flat Pixi objects* in 3D space — it is not a mesh renderer: no model loading, no PBR, no real depth-resolved geometry. Its own README: no `Graphics` support, culling "will be available", bilinear classes "WORK IN PROGRESS" [E8].
- **Version rot (the recurring plugin tax):** documented for Pixi v5 (later builds claim v7); deprecation breakage reported from Pixi ≥6.5 (`registerPlugin` → `extensions.add`) [E14]. No v8 path in the sources found. A user on current Pixi cannot rely on it.

### 4.2 `jnsmalm/pixi3d` — the community full 3D renderer

- **What it adds:** genuinely a lot — glTF loading, PBR + IBL, custom materials/shaders, 3D sprites, morph + skeletal animation, shadows, punctual lights [E10].
- **Ceiling / status:** *"Compatible with PixiJS v5, v6 and v7"* — **not v8** [E10]; last npm publish found: `2.5.0`, Dec 2023 [E13]. Choosing it means pinning your whole app to an old Pixi major.
- **Integration seam:** even inside one app, *"the transforms used by 2D and 3D works differently … and are not compatible. The transforms won't be affected by each other, even if they have a parent-child relation"* — conversion only via camera `screenToWorld`/`worldToScreen` [E10]. Two scene graphs, manually bridged.

### 4.3 `@pixi/3d` — official extension (NEW — changes the landscape)

- **What it is:** official PixiJS-team package, `npm install @pixi/3d`, requires `pixi.js` ≥ 8.23.0; WebGL2 & WebGPU renderers; a `View3D` you *"add to the stage like a sprite"* containing its own 3D scene [E11][E9].
- **What it adds:** glTF/GLB (+Draco, meshopt), PBR/Phong/Toon materials, lights & PCF shadows, skinned + morph animation, particles, post-processing (Bloom, SSAO, FXAA…), `OrbitCamera`/`FPSCamera`, 3D ray-picking, instancing/`BatchedMesh3D` [E11][E9].
- **Status caveat (verify before quoting in marketing):** secondary coverage describes it as **open beta (v0.1.0, from 12 Nov 2026), API can still change before 1.0** [E15]. It is days-to-weeks old at census time, not battle-tested production infrastructure.
- **Structural caveats that survive its launch:**
  - It is still **a separate package and a separate scene tree** (`View3D.root` of `Container3D` nodes) bolted onto a 2D stage [E9] — the "one API you already know" framing papers over a second set of classes, maths, and conventions (even Y-axis direction flips: 3D is Y-up, Pixi 2D is Y-down [E15]).
  - **Browser + WebGL2/WebGPU only** — no native/offline/deterministic path (row 16 stands).
  - **No physics** — its own intro: *"There's no physics engine; bring your own"* [E9].
- **Honest conclusion:** as of Nov 2026 the claim "Pixi can't do 3D" is **dead**; the defensible claim is "Pixi *core* is 2D; 3D is a new, beta, browser-only add-on with its own scene graph." Our positioning in §5 is written to survive @pixi/3d maturing.

### 4.4 Non-plugin workarounds

| Workaround | How it goes | Why it caps out |
|---|---|---|
| Hand-rolled shaders in core `Mesh` | Custom geometry + GLSL/WGSL + depth `State` | You have just written a 3D engine, inside a 2D one, alone |
| Pixi + Three.js, shared WebGL context | v8 supports initialising Pixi on Three's context with `clearBeforeRender:false` + `resetState()` between renders | Textures not shared; inter-layer depth ordering "painful" [E13]; two engines to learn/pin/debug |
| Pre-render 3D → sprite frames | Render models elsewhere (e.g. Three.js offscreen) to 8-direction sheets, play as Pixi sprites | Fixed angles, no dynamic camera/lighting; a pipeline, not interactivity [E13] |
| Second canvas overlaid | Three.js canvas stacked on Pixi canvas | 3D objects can never go *behind* 2D scene elements correctly [E13] |
| Fake it in 2.5D | `PerspectiveMesh`, parallax, painter-sorted sprites | Fine until geometry must intersect, occlude per-pixel, or the camera must move freely |

---

## 5. Positioning — where this engine wins

**One-liner:** *PixiJS makes 2D unbelievably easy and 3D somebody else's package; this engine makes 3D itself the easy, native, compiled default.*

| Axis | PixiJS core | PixiJS + `@pixi/3d` (beta) | **This engine** |
|---|---|---|---|
| First 3D scene | Impossible without leaving core | Install 2nd package, learn `View3D`/`Container3D`/Y-up world | Camera + perspective + z-buffer are the starter API (`camera.f90`, `renderer.f90`) |
| Number of scene graphs / APIs | 1 (2D) | 2, manually composited | **1 — 3D only, no seam** |
| Depth correctness | Painter's order | Real (in the extension) | Real, per-pixel, in the core rasteriser from the first commit |
| Runtime | Browser + WebGL/WebGPU + JS | Browser + WebGL2/WebGPU + JS | **Native compiled binary; CPU software render; no browser/GPU/JS; deterministic, scriptable, embeddable** |
| Version-matrix risk | — | Plugin/extension vs core-major compatibility (the pixi-projection & pixi3d history, §4.1–4.2) | None — one repo, one compiler (`make`) |
| Ease target | Easy 2D | Familiar-to-Pixi-users 3D | **The stated goal: 3D *greater than* Three.js/PixiJS and *unbelievably easy* — a small, readable, hackable ~900-line-class codebase a single developer can hold in their head** |
| Maturity today | Very mature (2D) | Beta, v0.1.0 | Early: Lambert shading, cube/procedural meshes, OBJ/JSON export, PPM/PNG out. **No glTF, PBR, shadows, skinning yet — those are roadmap, and any comparison that hides this is dishonest** |

**Claims we may make (evidence-backed):** "3D-native, not 3D-added-on" · "one compiled codebase, no plugin version matrix" · "renders 3D with no browser, no GPU, no JavaScript" · "perspective camera and z-buffer are primitives, not packages."
**Claims we must not make:** "PixiJS cannot do 3D" (false since `@pixi/3d`, Nov 2026) · "more features than PixiJS 3D" (false today — see maturity row) · any performance superiority (no benchmark exists yet; Pixi's batching numbers are for 2D sprites and are not comparable to a software rasteriser).

**The durable moat is not a feature checklist** — a funded team can out-feature a small Fortran engine. It is: (1) *simplicity as the product* — the whole pipeline (maths → mesh → camera → z-buffered rasteriser) is five readable modules; (2) *the compiler angle* — a native, deterministic renderer that can be embedded, scripted, and run anywhere Fortran compiles, including headless/CI; (3) *no seams* — one scene model where 2D-in-3D and 3D-in-2D compositing hacks (§4.4) never arise.

---

## 6. Evidence index

All URLs copied verbatim from sources retrieved 2026-11-23.

- [E1] Official PixiJS 2D page — branding, feature list, Assets types, batching claims: https://pixijs.com/2d
- [E2] Official API docs — `ContainerOptions` (position/scale `PointData`, scalar rotation, pivot/skew; no z): https://pixijs.download/v8.3.2/docs/scene.html
- [E3] PixiJS Discussion #8845 — maintainer: perspective *"not a feature available by default"*, plugin required: https://github.com/pixijs/pixijs/discussions/8845
- [E4] PixiJS v5 wiki resources — cameras & 3D objects listed as third-party (pixi-viewport, pixi-projection, pixi-3d): https://github.com/pixijs/pixijs/wiki/v5-Resources
- [E5] PixiJS guide coverage — scene-graph rules incl. *"Draw order follows insertion order"*: https://www.urhoba.net/en/post/what-is-pixijs
- [E6] Official Mesh guide — built-in meshes are planes/rope; mesh = geometry + your shader + GPU state; PerspectiveMesh *"emulating 3D projection in 2D"*: https://pixijs.com/8.x/guides/components/scene-objects/mesh
- [E7] Official API source docs — `PerspectiveMesh.ts`: *"This is not a full 3D mesh, it is a 2D mesh with a perspective projection applied to it"*, UV-level correction: https://pixijs.download/v8.7.1/docs/scene_mesh-perspective_PerspectiveMesh.ts.html
- [E8] `pixi-projection` README — adds `position3d`/`euler`/`scale3d`; no Graphics support; culling not yet available; v5-era compatibility: https://socket.dev/npm/package/pixi-projection/overview/0.3.2
- [E9] Official PixiJS 3D intro — separate `Container3D` tree under `View3D`, features it adds (maths, cameras, materials, glTF), *"no physics engine"*, WebGPU/WebGL2: https://pixijs.com/3d/guides/getting-started/intro
- [E10] `jnsmalm/pixi3d` README — glTF/PBR/IBL/skinning; v5–v7 only; 2D/3D transforms incompatible, bridged by `screenToWorld`/`worldToScreen`: https://github.com/jnsmalm/pixi3d
- [E11] Official PixiJS 3D page / repo — `@pixi/3d`, needs pixi.js ≥8.23.0, View3D, PBR/Phong/Toon, lights/shadows, extras post-processing: https://pixijs.com/3d and https://github.com/pixijs/3d
- [E12] PixiJS production/guides coverage — "creation engine, not a game engine", ecosystem-package strategy, WebGL recommended over WebGPU for production, Canvas experimental: https://appscale.blog/en/blog/pixijs-high-performance-2d-web-graphics-2026
- [E13] Workaround field report — shared-context Pixi+Three pain, pixi3d last publish 2.5.0 (Dec 2023), pre-render & overlay verdicts: https://github.com/cayden-h/larpcity/blob/HEAD/research/01-avatar-and-persona.md
- [E14] `pixijs-userland/projection` Issue #113 — deprecation breakage on Pixi ≥6.5.0: https://github.com/pixijs-userland/projection/issues/113
- [E15] PixiJS 3D beginner coverage — open beta 12 Nov 2026, v0.1.0, Y-up vs Pixi 2D Y-down: https://venogame.com/en/pixijs-3d-beginners-guide-browser-games

**Local evidence (this repo):** `src/math_3d.f90` (vec3/mat4, perspective, look-at), `src/camera.f90` (FOV/near/far camera), `src/renderer.f90` (z-buffer, barycentric rasteriser, Lambert), `src/mesh.f90` (3D triangle meshes, cube, OBJ/JSON export), `README.md` (feature list as shipped).

*Planning document only — no source code was changed for this census. Re-verify [E11]/[E15] (`@pixi/3d` version & stability) before any public comparison, as the beta is moving fast.*
