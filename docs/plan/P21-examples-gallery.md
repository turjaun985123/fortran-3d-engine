# P21 — Examples Gallery: 10 `.f3d` Programs, Ranked by Length

> Status: planning only (no engine code changed, no example files created yet).
> This plan specifies the gallery that P18 (testing) will turn into golden
> files and P20 (CLI) will ship as templates. Every program below is written
> **only** in syntax already specified by an earlier plan — the source plan is
> named per example, and any syntax that plan itself defers is flagged, never
> silently assumed.
>
> Repo ground truth at design time: `src/mesh.f90` has `create_cube` **only**
> (12 triangles, per-face colours); `src/main.f90` is a hardcoded 640×480
> demo (cube size 2, camera `(3, 2.5, 4)→(0,0,0)`, fov 60, near 0.1, far 100,
> light dir `(−0.5, −1, −0.7)`, pose 35° Y / 20° X, PPM out);
> `src/renderer.f90` is a flat Lambertian rasterizer (`0.25 + 0.75·diffuse`),
> no shadows, no alpha, no textures. The `.f3d` compiler itself is planned
> (P03/P04), not built. **Therefore no example below is runnable as `.f3d`
> today** — see the status column in §2. Examples 01 and 04 describe scenes
> the current binary already renders in hardcoded form; the rest are
> acceptance targets for the plans they depend on.

## 1. Rules of the gallery

1. **Ranking is by `.f3d` code lines**, counted exactly as printed: one
   statement per line (P03 §1 rule 1), blank lines and `#` comments excluded,
   `render` counted when written. Tiers: **1 line** (§3), **3 lines** (§4),
   **~10 lines** (§5). No semicolon-joining, no multi-statement lines — in
   `.f3d` or in the Three.js comparisons (§6).
2. **Exact code, exact expected output.** Each example states image size,
   background, camera, triangle count, and output file(s) — every value
   derived from the P03 §6 defaults table or stated in the program. If an
   output number cannot be derived, it is not claimed.
3. **Honest status.** Each example is labelled:
   `ENGINE-TODAY` (the scene exists, hardcoded in `main.f90`),
   `PLANNED` (syntax + backend both specified in a named plan, not built), or
   `PART-DEFERRED` (one feature in it is deferred by its own source plan).
4. **No new syntax.** If a tempting line is not in P03/P09/P11/P12/P13/
   P15/P16, it does not appear. Gaps found while writing the gallery are
   listed in §8, not papered over with invented keywords.
5. **Proposed on-disk layout** (to be created by the implementing work, not
   by this plan):

   ```text
   examples/
     01-hello-cube/      hello-cube.f3d   expected.md   golden.ppm
     02-one-sphere/      …
     …                   (one folder per example, numbered as in §2)
     10-animation-scene/
   ```

   `expected.md` in each folder is the "Expected output" paragraph of this
   plan, copied verbatim; `golden.ppm` is generated only when the example's
   status reaches runnable, and thereafter guarded by P18's golden tests.
   Run command for every example (P20): `f3dc run <file>.f3d`.

## 2. The gallery at a glance

| # | Example | Tier | `.f3d` lines | Depends on | Status |
|---|---|---|---|---|---|
| 01 | Hello Cube | 1 line | 1 | P03 | ENGINE-TODAY (hardcoded equivalent) |
| 02 | One Sphere | 1 line | 1 | P03 + P11 | PLANNED |
| 03 | One Pyramid | 1 line | 1 | P03 + P11 | PLANNED |
| 04 | Rotating Cube | 3 lines | 3 | P03 §7 / P09 | PLANNED (scene = ENGINE-TODAY still) |
| 05 | Sphere + Lights | 3 lines | 3 | P03 + P11 | PLANNED |
| 06 | Pyramid Desert | 3 lines | 3 | P03 + P11 | PLANNED |
| 07 | Loaded OBJ | 3 lines | 3 | P03 + P15 | PLANNED |
| 08 | Solar System Lite | 10 lines | 10 | P03 + P09 + P11 | PART-DEFERRED (see §5.1) |
| 09 | Grid City | 10 lines | 10 | P03 + P11 + P16 | PLANNED |
| 10 | Animation Scene | 10 lines | 10 | P03 + P09 + P11 | PART-DEFERRED (see §5.3) |

Defaults invoked everywhere below (P03 §6, from `main.f90`/`renderer.f90`):
640×480, background `#191923` rgb(25,25,35), camera `(3, 2.5, 4)→(0,0,0)`,
fov 60, near 0.1, far 100, light dir `(−0.5, −1, −0.7)`, output
`output_render.ppm`, animation defaults 30 fps / 5 s / spin 90°/s about Y
unless the program overrides them.

---

## 3. Tier 1 — one line (learn: *one word makes a picture*)

### 01 · Hello Cube

```f3d
cube
```

**Expected output.** One still, `output_render.ppm`, 640×480, background
`#191923`. A size-2 cube at the origin in the demo pose (rotate 20° X /
35° Y — the P03 §6.2 single-object default), per-face engine palette
(red/green/blue/yellow/magenta/cyan, `mesh.f90`), default camera and light,
Lambert shading. **12 triangles.** This must be byte-identical to today's
hardcoded `make run` output — it is the regression anchor named in P03 §10.

**Teaches:** nothing to learn. That is the point.

### 02 · One Sphere

```f3d
sphere red
```

**Expected output.** One still, `output_render.ppm`, 640×480, background
`#191923`, default camera/light. A red sphere, radius 1 (P11 §3: `size 2`
equivalent), centred at the origin, default detail `segments 16, rings 12`
→ **352 triangles**, flat-shaded per face by the current renderer (P11 §3
sphere normals are analytic, but `renderer.f90` shades per-face today — the
still will look faceted, and `expected.md` must say so until P10 lands).

**Teaches:** primitives are one word; colour is one word (P03 §6.3 palette).

### 03 · One Pyramid

```f3d
pyramid yellow
```

**Expected output.** One still, `output_render.ppm`, 640×480, background
`#191923`, default camera/light. A yellow square pyramid, base size 2,
height 2 (P11 §6 defaults), centred at the origin — base at y = −1, apex at
y = +1 — **6 triangles** (4 sides + 2 base), flat-shaded, apex never smoothed
(P11 §6.3).

**Teaches:** every primitive renders sensibly with zero properties written.

---

## 4. Tier 2 — three lines (learn: *name it, move it, render it*)

### 04 · Rotating Cube — the P03 contract test

```f3d
cube red
spin it
render
```

**Expected output.** An animation, not a still (P03 §7: any `spin` makes
`render` produce a sequence). `output_render.ppm` (frame at t = 0, red cube
size 2, demo pose, defaults as in 01) plus numbered frames
`output_render_0001.ppm` … at 30 fps for the default 5 s = **150 frames**,
the cube turning about Y at 90°/s (one full turn per 4 s, `loop`, linear).
**12 triangles per frame.** No GIF/MP4 — assembly is a post-v1 converter
step (P03 §7, P17 §6.3), and the gallery must not claim one.

**Teaches:** the pronoun `it` (= last object), animation is a statement,
not a loop the user writes.

### 05 · Sphere + Lights

```f3d
sphere blue at 0 0 0 radius 1 detail high
light from 2 4 3 strength 1.2
render to "sphere.ppm"
```

**Expected output.** One still, `sphere.ppm`, 640×480, background
`#191923`, default camera. A blue sphere at the origin,
`detail high` = `segments 32, rings 24` (P11 §2.5) → **1,472 triangles**,
lit by the scene's single directional light shining from `(2, 4, 3)`
(P03: `from` sets direction = `−from`, normalised) at strength 1.2 — the
upper-right of the sphere is the brightest region, the lower-left falls to
the 0.25 ambient floor of the renderer's shading equation.

**Honest limits, stated in `expected.md`:** one directional light only
(P03 §5); no point/spot lights, no shadows, no specular/Phong — those are
P10, whose block-style material syntax is *not* used here precisely because
P10 has not been reconciled into the P03 line grammar yet (§8). This
example demonstrates the lighting v1 actually specifies, not P10's model.

**Teaches:** `light` overrides a default, it does not have to be declared
before use; `render to` names the output.

### 06 · Pyramid Desert

```f3d
plane orange size 20
pyramid yellow at 0 1.5 0 size 4 height 3
render
```

**Expected output.** One still, `output_render.ppm`, 640×480, background
`#191923`, default camera/light. An orange floor: plane in XZ at y = 0,
20×20, **2 triangles** (P11 §5 — a plane is a floor, single-sided, invisible
from below). On it, a yellow pyramid, base size 4, height 3, placed
`at 0 1.5 0` so its base sits exactly on y = 0 and its apex is at y = 3
(P11 §6.4's centred-height arithmetic, shown once here on purpose),
**6 triangles**. Total scene: **8 triangles**. From the default camera the
floor fills the lower frame; its far edge ends at z = −10 — beyond that the
background shows. No sky, no fog, no dunes: none are specified anywhere yet.

**Teaches:** composition = one line per thing; `at` is centre, not base.

### 07 · Loaded OBJ

```f3d
load "model.obj" hero colour red size 2
spin it
render
```

Uses the repo's own checked-in `model.obj` (the exported cube: 12 `f`
faces), copied into the example folder.

**Expected output.** An animation as in 04 (150 frames at defaults, plus
the t = 0 still `output_render.ppm`). The loaded mesh is centred and scaled
so its largest side is 2 (P15 §6.3 `load` defaults, here explicit), tinted
uniformly red (OBJ materials are ignored in v1, P15 §4.6), **12 triangles
per frame**, spinning about Y at 90°/s — `it` after a `load` is the whole
load (P15 §6.2). Load summary line on stdout per P15 §9.3.

**Honest limits:** `.obj` only — `load "x.gltf"` is the specified P15 §7.4
error in v1, and this example's `expected.md` says so. A downloaded model
with thousands of faces works by the same three lines; its triangle count
goes in that folder's `expected.md` when such a fixture is added, not here.

**Teaches:** importing a real model is not a subsystem, it is a statement
with the same props as a primitive.

---

## 5. Tier 3 — ten lines (learn: *scenes, patterns, timelines*)

### 08 · Solar System Lite

```f3d
scene "solar-lite" background black
camera at 0 6 12 look 0 0 0
sphere sun yellow at 0 0 0 radius 2
sphere earth blue at 5 0 0 radius 0.7
sphere mars red at -7 0 0 radius 0.5
sphere moon white at 6.5 0 0 radius 0.3
spin sun speed 20
spin earth speed 90
spin mars speed 60
render duration 4
```

**Expected output.** An animation: t = 0 still `output_render.ppm` plus
**120 frames** (4 s × 30 fps), 800×600 **not** set — image stays 640×480 on
a black background, camera above the plane of the system at `(0, 6, 12)`
looking at the origin. Four spheres, each 352 triangles at default detail
→ **1,408 triangles per frame**. Sun radius 2 at the origin; earth, mars,
and moon (beside earth, at x = 6.5) at the stated radii, all centred on
y = 0. Default directional light — the sun does **not** light the planets;
there is no point light in v1 (P03/P10 §5.3 is post-v1 design), and
`expected.md` must say the illumination comes from the default direction,
not from the sun sphere.

**PART-DEFERRED, honestly:** the planets *spin in place*; they do not
orbit. `orbit` exists only in P09 §4's illustrative block syntax
("final keywords belong to the DSL-grammar plan") and is **not** in P03's
`animate` motion list (`spin | move | bob | pulse`). A "lite" that claimed
orbits would be claiming unspecified syntax. When P09's orbit is reconciled
into P03, this example gains orbiting planets *as a new revision* — the
10-line version above stays as the v1 golden.

**Teaches:** named objects, per-object animation speeds, `scene`/`camera`
as overrides, `duration` on `render`.

### 09 · Grid City

```f3d
scene background black
camera at 12 10 16 look 0 2 0
plane gray size 30
grid 5 5 cube blue size 1 spacing 3 0 3 at -6 0.5 -6
grid 3 3 cube cyan size 2 spacing 6 0 6 at -4.5 1 -4.5
cube road black at 0 0.05 0 size 14 0.1 2
cube road2 black at 0 0.05 0 size 2 0.1 14
line 5 cube yellow size 0.3 from -6 0.15 3 to 6 0.15 3
light from 5 10 3 strength 1.1
render to "city.ppm"
```

**Expected output.** One still, `city.ppm`, 640×480, black background,
camera at `(12, 10, 16)` looking at `(0, 2, 0)`. Contents:

- grey ground plane 30×30 at y = 0 — 2 triangles;
- 25 blue towers, size 1, on a 5×5 grid (P16 §3.3: row-major, x fastest,
  first placement at the `at` corner), centres y = 0.5 so they sit on the
  ground — 25 × 12 = 300 triangles;
- 9 cyan towers, size 2, on a 3×3 grid offset to `(−4.5, …, −4.5)` with
  spacing 6 so no placement coincides with a blue tower, centres y = 1 —
  9 × 12 = 108 triangles;
- two flat black road slabs crossing at the centre (`size` as a vec3,
  P03 object-prop), each 12 triangles, top at y = 0.1;
- 5 yellow size-0.3 cubes evenly spaced along z = 3 by `line … from … to`
  (P16 §3.3, endpoints inclusive), centres y = 0.15 — streetlights in
  shape only; they emit no light (v1 has no point lights).

Total: **42 placements, 494 triangles.** All towers are the same height
within each grid — `grid` has no per-placement height variation in P16 v1
(`grow`/`fade` vary scale/colour along a `repeat`, not a `grid`), and
`expected.md` says so rather than letting the screenshot imply a skyline
algorithm that does not exist.

**Teaches:** pattern statements (`grid`) replace arithmetic the language
deliberately cannot express (no variables, no loops — P03 §1 non-goals);
multi-object scenes default to rotation `0 0 0` (P03 §6.2), so towers stand
upright without a `rotate` line.

### 10 · Animation Scene

```f3d
scene "finale" size 800 600 background black
camera at 0 3 9 look 0 1 0
plane gray size 16
cube hero red at -2 0.5 0 size 1
sphere ball blue at 2 1 0 radius 1
animate hero spin y speed 90 duration 4 loop
animate ball bob duration 4
animate hero pulse duration 4
light from 3 5 4 strength 1.2
render to "finale.ppm" fps 30 duration 4
```

**Expected output.** An animation at **800×600**: t = 0 still
`finale.ppm` plus **120 frames** (`finale_0001.ppm` …, per P17 frame
naming applied to the `render to` stem). Grey floor 16×16 (2 triangles);
a red size-1 cube at `(−2, 0.5, 0)` — sitting on the floor — spinning
about Y at 90°/s and pulsing (scale 1.0 → 1.2 → 1.0, P03 §7) over the 4 s;
a blue sphere, radius 1, centre `(2, 1, 0)` — resting on the floor —
bobbing sinusoidally on Y, amplitude 0.5, period 4 s (P03 §7 defaults).
Per frame: 2 + 12 + 352 = **366 triangles**.

**PART-DEFERRED, honestly:** P03 §7 allows the compiler to defer `bob`
and `pulse` ("v1 may desugar or defer — if deferred, same `not supported
yet` error rule"). Until the implementing work rules on that, this
example's golden is conditional: if `bob`/`pulse` are deferred, 10 ships
with lines 7–8 removed and a documented 8-line variant, and the 10-line
form becomes the acceptance test for the follow-up. It is never shipped
silently substituting a different motion.

**Teaches:** several motions on several objects compose by naming the
target; size, camera, light, and output are all one-line overrides.

---

## 6. Three.js comparison — method first, numbers second

### 6.1 Counting method (the only way this comparison means anything)

- **Unit:** non-blank, non-comment lines, one statement per line, idiomatic
  formatting (no joining statements with `;` to game the count — in either
  language).
- **Three.js side:** a self-contained module page using the current
  Three.js idiom (`import * as THREE from 'three'`, `WebGLRenderer`,
  `PerspectiveCamera`, one mesh per object unless a loop/instancing is the
  natural idiom, `requestAnimationFrame` loop for animated examples).
  Imports, renderer/scene/camera setup, and the render/animation loop are
  **counted** — a beginner must write them all before anything appears.
- **`.f3d` side:** the lines printed in §3–§5. Setup is *not* missing from
  the count out of charity: it does not exist, because the defaults are
  the compiler's (P03 §6). The user's one shell command (`f3dc run …`,
  P20) is the counterpart of opening the HTML page and is not counted on
  either side.
- **Exact vs estimated:** examples 01 and 04 are counted exactly from the
  reference snippet in §6.2. The other rows are *estimates by delta* from
  that snippet (+2 lines per additional simple object — mesh line(s) +
  `scene.add` — +2–3 per light, etc.), shown as ranges. They are labelled
  estimates wherever they appear; nobody should quote them as measured.
- **Different artifacts:** Three.js draws a live WebGL canvas in a browser;
  `.f3d` (per P17) emits PPM/PNG stills, frame sequences, and an HTML
  viewer. The comparison is **authoring lines for a comparable scene and
  motion**, not identical output files. Three.js has no built-in PPM
  export; `.f3d` v1 has no interactivity at all. Both facts belong in the
  table's shadow, and §6.3 states what the table does *not* show.

### 6.2 Reference snippet (counted exactly — animated rotating cube)

```js
import * as THREE from 'three';                                   //  1
const renderer = new THREE.WebGLRenderer({ antialias: true });    //  2
renderer.setSize(640, 480);                                       //  3
document.body.appendChild(renderer.domElement);                   //  4
const scene = new THREE.Scene();                                  //  5
scene.background = new THREE.Color(0x191923);                     //  6
const camera = new THREE.PerspectiveCamera(60, 640 / 480, 0.1, 100); // 7
camera.position.set(3, 2.5, 4);                                   //  8
camera.lookAt(0, 0, 0);                                           //  9
const light = new THREE.DirectionalLight(0xffffff, 1);            // 10
light.position.set(0.5, 1, 0.7);                                  // 11
scene.add(light);                                                 // 12
const cube = new THREE.Mesh(                                      // 13
  new THREE.BoxGeometry(2, 2, 2),                                 // 14
  new THREE.MeshLambertMaterial({ color: 0xdc3c3c })              // 15
);                                                                // 16
scene.add(cube);                                                  // 17
function tick() {                                                 // 18
  cube.rotation.y += Math.PI / 2 / 60;                            // 19
  renderer.render(scene, camera);                                 // 20
  requestAnimationFrame(tick);                                    // 21
}                                                                 // 22
tick();                                                           // 23
```

**23 lines** for example 04's scene (with two honest asterisks: line 19's
spin speed is frame-rate dependent — doing it properly with
`THREE.Clock` costs ~2 more lines; and the `.f3d` version's red is a
single flat colour, matched here, while 01's per-face palette would need
a material array, ~+4 lines). Deleting the loop (lines 18–23) and adding
one `renderer.render(scene, camera);` gives the still version:
**18 lines** for example 01.

### 6.3 The table

| # | Example | `.f3d` | Three.js | Basis | Ratio |
|---|---|---|---|---|---|
| 01 | Hello Cube | 1 | **18** | counted (§6.2, still variant) | ~18× |
| 02 | One Sphere | 1 | ~18 | est. (geometry swap, same shape) | ~18× |
| 03 | One Pyramid | 1 | ~19 | est. (`ConeGeometry` 4-sided + alignment rotation) | ~19× |
| 04 | Rotating Cube | 3 | **23** | counted (§6.2) | ~7.7× |
| 05 | Sphere + Lights | 3 | ~20–22 | est. (still + repositioned/ambient light lines) | ~7× |
| 06 | Pyramid Desert | 3 | ~21–23 | est. (still + plane + pyramid) | ~7× |
| 07 | Loaded OBJ | 3 | ~27–31 | est. (still + `OBJLoader` addon import, async load, centre/scale via `Box3`) | ~10× |
| 08 | Solar System Lite | 10 | ~38–44 | est. (4 spheres, 3 spin updates in loop) | ~4× |
| 09 | Grid City | 10 | ~34–40 | est. (nested loop or `InstancedMesh`, ground, 2 roads, light) | ~3.7× |
| 10 | Animation Scene | 10 | ~40–48 | est. (clock, spin + sine bob + pulse updates, 2 objects, floor) | ~4.3× |

### 6.4 What the table does **not** show (read before quoting it)

- **Three.js wins, outright, on capability:** real-time interaction,
  textures, shadows, transparency, glTF, post-processing, and a vast
  ecosystem are available in those extra lines' neighbourhood; `.f3d` v1
  has none of them (P03 §11, P10 §7.1, P15 §7). Brevity here is bought
  with scope, and this plan does not pretend otherwise.
- **The ratio shrinks as scenes grow** (18× → ~4×): `.f3d`'s advantage is
  the fixed setup cost it deletes, not per-object magic. Past a few dozen
  hand-placed objects both sides need patterns; P16's helpers are what
  keep 09 at 10 lines.
- **Three.js can be shortened** with helper libraries, builders, or a
  hand-rolled `makeBox()` function — amortised over many scenes, at the
  cost of the beginner first writing/learning that layer. `.f3d` is,
  in effect, that layer, standardised and shipped with the compiler.
- **`.f3d` can be lengthened** by spelling out every default
  (`scene`/`camera`/`light`/`render` lines) — example 10 does some of
  this. The gallery counts what a beginner would actually write.
- Line count is not learning time, debugging time, or power. It is the
  one metric this project's promise ("unbelievably easy") is stated in,
  so it is the one measured — with its limits stated alongside.

## 7. How the gallery is used

| Consumer | Use |
|---|---|
| P18 (testing) | Each folder = one golden test: compile, render, compare against `golden.ppm` + the `expected.md` numbers (size, triangle count, frame count). 01 is the byte-identical regression anchor (P03 §10). |
| P20 (CLI) | `f3dc new --template` offers 01 and 04; the gallery is the source of the P20 §8 worked sessions, which must not show an example this plan labels PART-DEFERRED without its caveat. |
| P08 (errors) | The gallery's negative companions already exist in P03 §9.5 (`gold` colour) and §9.6 (reserved primitive) — the gallery adds none, and must not be "fixed" by making those programs valid. |
| Docs / README (future) | The gallery *is* the tutorial: tiers map to "first minute / first ten minutes / first hour". README may quote §6.3 only together with §6.4. |

**Acceptance for the implementing work:** all 10 folders exist; every
`.f3d` file parses under the P03 grammar plus its named deltas (P11 §2.5,
P15 §6.1, P16 §3.6) with no additional keywords; every runnable example's
render matches its "Expected output" paragraph on size, background,
triangle count, and frame count; status labels in §2 are updated in this
file in the same commit that makes an example runnable.

## 8. Gaps this gallery exposed (for owner ruling, not invented here)

1. **P10 syntax is unreconciled with P03.** P10 §6 writes materials/lights
   in a block style (`material brass { … }`, `light directional sun { … }`)
   that P03's line grammar cannot parse. Example 05 deliberately uses only
   P03's `light` line. One dialect must win before any material example
   can join the gallery.
2. **`orbit` has semantics (P09 §4) but no line grammar.** Example 08 is
   "lite" because of this. Reconciling `orbit` into P03's `animate`
   motions is the single highest-value gallery follow-up.
3. **`bob`/`pulse` deferral (P03 §7)** leaves example 10 conditional;
   the implementing work should rule desugar-vs-defer before goldens are
   pinned.
4. **No variation inside `grid` (P16 v1)** caps example 09's skyline;
   a `grid … grow`/`fade` delta is a P16 question, not a gallery fix.
5. **Colour palette** (P03 §6.3) has no sand/earth tones — 06 uses
   `orange`/`yellow`. Extending the palette is a P03 amendment; the
   gallery does not smuggle in new colour names (cf. the `gold` error
   case, P03 §9.5).

## 9. Explicitly not in this gallery

Scenes requiring textures/UVs (P14), groups/cars (P12 §6.1 has its own
worked example — a candidate 11th entry once groups ship), camera
`controls`/autorotate (P13 — viewer behaviour, not a still/frame output),
instancing beyond `grid` patterns, glTF loads (P15 v2), shadows,
transparency, and any example whose expected output cannot be stated
exactly from defaults + program. A gallery entry that cannot say what
picture it makes is marketing, not a test.
