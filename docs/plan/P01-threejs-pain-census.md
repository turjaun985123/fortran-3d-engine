# P01 — Three.js API Pain Census

**Agent:** P01 (read-only planning) · **Date:** 2026-11-23 · **Repo state at census:** 5 Fortran modules, 629 LOC (`wc -l src/*.f90`: math_3d 210, renderer 161, mesh 144, main 68, camera 46)
**Question:** How much code does Three.js — the incumbent "easy" 3D API — actually force on a user for the 10 most common beginner tasks, and what must our `.f3d` DSL beat, concretely?
**Goal it serves:** A compiler/DSL making 3D *greater than Three.js/PixiJS and unbelievably easy*. "Greater" is not measurable; line counts, concepts-to-learn, and failure modes are. This census is the baseline every later design decision is scored against.

---

## 1. Counting method (read this before trusting any number)

Counts are **not** copied from blog claims. Each task was reconstructed in canonical modern style and counted by hand under fixed rules, then cross-checked against published examples (sources in §7).

| Rule | Definition |
|---|---|
| Three.js version | r160–r180 era, ES modules (`import * as THREE from 'three'`, addons via `three/addons/…`). No React Three Fiber, no TypeScript types, no build-config lines counted. |
| **Terse JS** | Shortest *correct* JS a knowledgeable author would ship: chained/one-line constructors where idiomatic, no optional polish. Non-blank, non-comment physical lines. |
| **Idiomatic JS** | What tutorials/docs teach as best practice: `antialias:true`, pixel-ratio cap, named geometry/material variables, damping/`Clock` where relevant, error/progress callbacks where the API offers them. Non-blank, non-comment physical lines. |
| **Total** | Idiomatic JS **+ HTML shell** (`<!DOCTYPE>`, `<head>`, importmap or script tag, `<canvas>`/container, minimal CSS to make the canvas fill the window): a fixed **+13 lines** on every standalone task. Nobody runs JS alone — this overhead is real and is part of the pain. |
| **Incremental** | Lines the task itself adds *on top of* the empty scaffold in §2. This is the fairest cross-task comparison, and the number `.f3d` must crush. |
| Excluded | Blank lines, comments, Prettier line-wrapping variance (±15–20% — treat all counts as ±20%, not gospel), asset files, `npm`/Vite setup commands. |

**Honesty notes**

1. A determined expert can golf several tasks 30–40% shorter (inline everything, omit pixel-ratio, reuse one material). That does not refute the census: golfed code is exactly what beginners cannot write or read, and tutorials do not teach it.
2. Conversely, production code is *longer* than the idiomatic column: disposal, context-loss handling, loading UI, and TypeScript types are all extra and uncounted here.
3. Cross-checks agree with the method: one current tutorial introduces its finished spinning cube as *"only 60 lines"* (with comments/blanks/HTML — consistent with 28 idiomatic JS + 13 HTML + comments/blanks here); the Motion.dev Three.js example needs ~25 lines of setup *before* any animation is added.

---

## 2. The scaffold tax: the empty program

Before drawing **anything**, every standalone Three.js program needs:

```js
import * as THREE from 'three'                                  // 1
const scene = new THREE.Scene()                                  // 1
const camera = new THREE.PerspectiveCamera(75, innerWidth/innerHeight, 0.1, 1000) // 1
camera.position.set(0, 0, 5)                                     // 1
const renderer = new THREE.WebGLRenderer({ antialias: true })    // 1
renderer.setSize(innerWidth, innerHeight)                        // 1
renderer.setPixelRatio(Math.min(devicePixelRatio, 2))            // 1
document.body.appendChild(renderer.domElement)                   // 1
renderer.setAnimationLoop(() => renderer.render(scene, camera))  // 1–3
```

**≈ 9 terse / 11 idiomatic JS lines, 22–24 total with HTML — to render a black rectangle.**
The user must already understand 5 classes (`Scene`, `PerspectiveCamera`, `WebGLRenderer`, plus the DOM), 4 unexplained magic numbers (FOV `75`, near `0.1`, far `1000`, pixel-ratio cap `2`), and the fact that the camera starts at the origin *inside* anything placed at the origin. Nothing in the API states any of this; it is learned by failure. **This fixed tax, paid by every program forever, is pain point #1 and the single biggest thing `.f3d` can delete.**

---

## 3. The census: 10 common tasks

| # | Task (standalone, working, on screen) | Terse JS | Idiomatic JS | **Total (JS+HTML)** | Incremental over scaffold | Distinct concepts / classes touched | Silent-failure modes |
|---|---|---:|---:|---:|---:|---|---|
| 1 | Rotating cube | 17 | 28 | **41** | +9 (mesh triple 4, `scene.add` 1, rotation in loop 2–4) | 7: Scene, Camera, Renderer, BoxGeometry, Material, Mesh, loop | Wrong material + no light = black cube; camera at origin = black screen |
| 2 | Lit sphere | 21 | 32 | **45** | +13 (sphere triple 4, ambient 2, directional + position 3, add ×3) | 9: + SphereGeometry, AmbientLight, DirectionalLight | Forgetting either light, or light position, yields black/flat sphere with **no error** |
| 3 | Textured plane | 22 | 34 | **47** | +15 (TextureLoader 2, texture colour-space 1–2, plane triple 4, rotation `-Math.PI/2` 1) | 9: + TextureLoader, Texture, PlaneGeometry | Washed-out colours if `texture.colorSpace = SRGBColorSpace` omitted; plane invisible edge-on / from below (single-sided) if rotation/side not understood |
| 4 | Orbit camera | 24 | 36 | **49** | +6 terse / +10 idiomatic (separate addon import 1, construct 1, target 1, damping flag 1, `controls.update()` **every frame** 1, limits 0–4) | 8: + `OrbitControls` from a *different import path* | Damping silently does nothing if `update()` is not in the loop; addon import path breaks across versions/bundlers |
| 5 | Animation loop (delta-timed, multi-object) | 12* | 20* | **33*** | *Standalone figure is the loop itself: `Clock` 1, `getDelta/getElapsedTime` 2, loop fn 6–10, per-object updates, render 1 | 5: `Clock`/`setAnimationLoop` or RAF, delta vs elapsed, render call | Frame-rate-dependent motion if raw `+= 0.01` used (the pattern most tutorials teach); tab-switch delta spike |
| 6 | Multi-object scene (10 objects, varied) | 38 | 58 | **71** | +40 naive (geometry+material+mesh+position+`add` ≈ 4–5 lines × 10); ≈ +25 if the user hand-writes a helper/loop the API does not provide | 8 + user-invented abstraction | Re-created geometries/materials waste GPU memory; one missed `scene.add()` = object silently absent |
| 7 | Shadows (1 caster, ground, 1 light) | 38 | 56 | **69** | +16–20 scattered in **5 places**: renderer flag+type 2, light `castShadow` 1, shadow-camera bounds 4–6, map size 2, bias 1, `cast/receiveShadow` per mesh 2×N, ground 4 | 10: + shadow camera, shadow map types | Any **one** omitted flag = no shadow, no warning; wrong shadow-camera bounds = clipped/vanishing shadows; acne/peter-panning without bias tuning |
| 8 | Loading an OBJ model | 40 | 62 | **75** | +19–27 (addon import 1, loader 1, `load(url, onLoad, onProgress, onError)` 6–12, `traverse()` to fix materials/shadows 5–8; **+MTLLoader pre-load ≈ +8** for materials) | 11: + OBJLoader, (MTLLoader), LoadingManager, Group, traverse/callback model | Async: code after `load()` runs before the model exists; OBJ without MTL arrives untextured grey; per-child flags require traversal knowledge |
| 9 | Particles (1,000 points) | 32 | 50 | **63** | +18–22 (`Float32Array(count*3)` 1, fill loop 5–8, BufferGeometry + `setAttribute(new BufferAttribute(…,3))` 3, PointsMaterial 4–7, Points + add 2, per-frame update/`needsUpdate` 2–4) | 10: + BufferGeometry, BufferAttribute, typed arrays, PointsMaterial, Points | Wrong item-size (the magic `3`), forgotten `needsUpdate`, or opaque square points (no `transparent`/`depthWrite:false`/blending) — all silent |
| 10 | Responsive resize | 6* | 8* | **8* incremental** | *Not standalone — pure addition to any of the above: listener 1, `camera.aspect` 1, `updateProjectionMatrix()` 1, `renderer.setSize` 1, pixel-ratio 1, braces 2 | 3 objects must be kept in sync manually | Forget `updateProjectionMatrix()` = stretched image; forget it entirely (many tutorials' first versions do) = broken on first window resize |

**Totals that matter**

- **Median standalone task: ≈ 49 total lines** (range 41–75) for effects a user describes in 2–5 words ("spinning cube", "load this model").
- **A "real first scene" combining tasks 2+4+6+7+10** (lit objects, orbit, shadows, resize): **≈ 95–120 idiomatic JS lines, ≈ 110–135 total** — before any logic the user actually cares about.
- **Concepts before competence: ~20 classes** across the 10 tasks (`Scene, PerspectiveCamera, WebGLRenderer, Mesh, *Geometry ×4, *Material ×4, *Light ×2, OrbitControls, TextureLoader, OBJLoader/MTLLoader, BufferGeometry, BufferAttribute, Points, Clock`), plus the DOM, ES-module importmaps, and async callbacks.

Representative idiomatic rotating cube (task 1, the 28-line JS core — every other task starts from this and grows):

```js
import * as THREE from 'three'
const scene = new THREE.Scene()
const camera = new THREE.PerspectiveCamera(75, innerWidth / innerHeight, 0.1, 1000)
camera.position.z = 5
const renderer = new THREE.WebGLRenderer({ antialias: true })
renderer.setSize(innerWidth, innerHeight)
renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
document.body.appendChild(renderer.domElement)
const geometry = new THREE.BoxGeometry(1, 1, 1)
const material = new THREE.MeshStandardMaterial({ color: 0x44aa88 })
const cube = new THREE.Mesh(geometry, material)
scene.add(cube)
const clock = new THREE.Clock()
renderer.setAnimationLoop(() => {
  const dt = clock.getDelta()
  cube.rotation.x += dt * 0.8
  cube.rotation.y += dt * 0.6
  renderer.render(scene, camera)
})
window.addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight
  camera.updateProjectionMatrix()
  renderer.setSize(innerWidth, innerHeight)
})
```

Note what this *still* does not have: a light (the `MeshStandardMaterial` cube above renders **black** without one — the most common beginner bug in Three.js history), orbit controls, shadows, or cleanup. Add the light and it is task 2's count, not task 1's.

---

## 4. Top 10 pain points (ranked by damage × frequency)

1. **The scaffold tax.** ~11 JS + 13 HTML lines and 5 concepts before the first pixel (§2). It never amortises for small programs — and most programs people *want* to write are small.
2. **The Geometry + Material + Mesh triple, plus `scene.add()`.** One visible thing = 3 constructions + 1 registration, repeated per object (task 6: ~45 lines for 10 objects). Four chances per object to err; the registration step fails *silently* (object exists, is never drawn, no error).
3. **Black-screen-by-default failure design.** Unlit material, camera inside the object, missing light, single-sided plane facing away, forgotten `castShadow` — the dominant beginner outcomes are all *silence*, not errors. The API almost never tells the user which of ~8 causes they hit.
4. **Lighting is a separate, mandatory, invisible subsystem.** Choosing a "nice" material (`MeshStandardMaterial`/`Phong`) secretly creates a dependency on lights the user hasn't written; the "simple" material (`MeshBasicMaterial`) ignores lights entirely. Material choice and light choice must be learned as a pair, upfront.
5. **Shadows are a 5-place scattered opt-in.** Renderer flag, light flag, per-mesh cast flag, per-mesh receive flag, shadow-camera bounds, map size, bias (task 7). No single `shadows: on`. Miss one → nothing, with no diagnostic. Tuning values are magic numbers learned from forums.
6. **Addon fragmentation.** `OrbitControls`, `OBJLoader`, loaders and controls live outside the core namespace, at import paths that have changed repeatedly (`examples/js` → `examples/jsm` → `three/addons/`), and are the first thing to break under a new bundler/version. The core import succeeding proves nothing about the addons.
7. **Async loaders with a 4-callback signature and manual repair.** `load(url, onLoad, onProgress, onError)`; the loaded thing is a `Group` needing `traverse()` surgery to set materials/shadows/scale; OBJ needs a *second* loader (MTL) loaded *first* for textures (task 8: the most lines and most concepts of any task).
8. **Manual per-frame plumbing.** The user owns the loop, the clock, delta-vs-elapsed, `controls.update()` for damping, and render ordering — forever, in every program. The tutorial-taught shortcut (`rotation += 0.01`) is frame-rate-dependent and therefore wrong.
9. **Resize is the user's job, in 3 synced places.** Camera aspect + projection matrix + renderer size (+ pixel ratio), via a DOM event listener (task 10). Nothing about "the window changed" is automatic in a library whose entire job is drawing to that window.
10. **Low-level data plumbing leaks into a beginner task.** Particles — a canonical "wow, easy!" demo — require typed arrays, stride arithmetic (`count * 3`, magic item-size `3`), `BufferAttribute`, and `needsUpdate` bookkeeping (task 9). Version churn compounds all of the above: e.g. r152+ colour-management defaults, r155 physical light units, `outputEncoding` → `outputColorSpace` renames — old answers online silently become wrong code.

*PixiJS note (honesty):* PixiJS has the same shape of tax in 2D — `Application` init (now async), stage, sprite/texture loading — so beating Three.js on these counts does not automatically beat PixiJS; `.f3d` defaults (§5) must be designed against both. A separate PixiJS census is out of P01's scope.

---

## 5. What `.f3d` must beat — the contract

Design targets, each traceable to a census row. A target counts as met only if the `.f3d` program **runs and shows the correct image** — not if it merely parses.

| # | Census baseline (Three.js idiomatic total) | `.f3d` target | Target `.f3d` sketch (illustrative syntax, not a spec) |
|---|---|---|---|
| 1 | Rotating cube — **41** | **≤ 5 lines, 0 scaffold** | `cube color=#44aa88`<br>`spin cube 0.8, 0.6` |
| 2 | Lit sphere — **45** | **≤ 4 lines; lighting is a default, not a subsystem** (sane key+ambient rig built in; `light` line only to customise) | `sphere r=1 color=teal` |
| 3 | Textured plane — **47** | **≤ 3 lines; sRGB correct by default** | `plane 10x10 texture="wood.png"` |
| 4 | Orbit camera — **49** | **≤ 1 line; damping on by default**, limits as named options | `camera orbit` |
| 5 | Animation loop — **33, user-owned forever** | **0 lines.** No loop, clock, or render call exists in the language; declarative `spin`/`move`/`every` statements are delta-timed by the runtime | `spin cube` (see #1) |
| 6 | 10-object scene — **71** | **≤ 12 lines** (one line per object, no triple, no `add` — declaration *is* registration) | `cube at -3,0,0 color=red` ×10, varied |
| 7 | Shadows — **69** | **≤ 1 line total** (`shadows on` — or on by default); renderer/light/mesh flags and shadow-camera fitting are the compiler's problem; bias has a sane default | `shadows on` |
| 8 | Load OBJ — **75** | **≤ 2 lines, synchronous-looking**; MTL auto-discovered, materials/shadows fixed up by the loader, load failure is a **compile/run-time error naming the file**, never a silent grey mesh | `model "chair.obj" at 0,0,0 scale=0.5` |
| 9 | Particles — **63** | **≤ 3 lines; no typed arrays, strides, or buffer vocabulary in the language** | `particles 1000 in sphere r=5 color=white size=0.05` |
| 10 | Responsive resize — **+8 on every program** | **0 lines, unconditional.** The runtime owns resize, aspect, projection and pixel ratio (capped) — it cannot be forgotten because it cannot be written | — (nothing) |

**Cross-cutting acceptance rules (the "greater than", made falsifiable)**

- **R1 — Zero-scaffold law:** No imports, renderer, scene, camera, DOM, or HTML in user code. A `.f3d` file *is* the whole program; the compiler emits whatever host scaffolding is needed.
- **R2 — Defaults law:** Lit, antialiased, pixel-ratio-capped, resize-correct, delta-timed, damped-orbit-ready by default. Every §4 pain that is a *default* in Three.js must be a *default-correct* behaviour here; opting out is allowed, opting in to correctness is not.
- **R3 — No silent black:** Any scene that would render black/empty in Three.js (no light, camera inside object, missing file, un-added object — the last is impossible by R1/declaration) must produce a **named diagnostic** ("scene has a lit material but no light — added default light" / error), never a silent black frame.
- **R4 — One-place features:** Shadows, orbit, textures each have exactly **one** declaration site. If a feature needs flags in ≥2 places, the DSL design has failed that feature, regardless of line count.
- **R5 — Budget law:** Every task in §3 must land at **≤ ⅓ of Three.js's idiomatic JS count and ≤ 5 new concepts**, with tasks 5 and 10 at exactly **0**. The combined "real first scene" (§3, ~110–135 total lines) must fit in **≤ 20 `.f3d` lines**.
- **R6 — Honesty law:** `.f3d` wins on *authored* lines; generated JS/Fortran host code does not count against the user, but must be disclosed in docs (the compiler's output is not magic, and escape hatches to it must exist for what the DSL cannot yet express — with the census re-run on the escape hatch so it does not quietly become Three.js again).

---

## 6. Limits of this census

Counts are hand-counted reconstructions under §1's rules (±20%), not a corpus study of GitHub code; a corpus study would likely show *higher* real-world counts (error handling, types, comments-as-apology). Three.js also buys real things for its lines — a huge ecosystem, WebGL performance, any-shader-you-want flexibility — which line counts do not capture; `.f3d` beating the census while losing the ecosystem is a trade the wider plan must state openly, not discover later. PixiJS, Babylon.js and R3F were not censused here.

## 7. Sources consulted (2026-11-23)

- Three.js manual / fundamentals pattern (scene–camera–renderer–mesh, resize handler) — threejs.org/manual
- Motion.dev, *Three.js example & tutorial* — ~25 lines of scene/camera/renderer/light setup before animation (motion.dev/examples/js-three)
- Stardust Fighter tutorial, *Your First Cube: The Big Four* — finished spinning cube described as "only 60 lines" incl. HTML/comments (laniakeaoverflow.github.io/stardust-fighter)
- Community Three.js skill references (r160–r180 patterns): canonical resize block, `Points`/`BufferGeometry` particle block (~20 lines incremental), OrbitControls/shadow/OBJLoader usage — github.com skill collections surveyed via search
- CodePen OBJLoader + OrbitControls + shadows demos — OBJ load + `traverse()` + MTL pre-load and 5-place shadow setup as counted in task 7/8
- mysimulator.uk, *Three.js Particle System Tutorial* — Float32Array/BufferAttribute/PointsMaterial particle construction
