# P25 — Migration & Interop: Export, Embed, Three.js Import, Coexistence

> **Status:** Planning only — no code changed by this document.
> **Repo state audited:** `src/main.f90`, `src/mesh.f90`
> (`export_mesh_json`, `export_mesh_obj`), repo-root `scene.json`,
> `model.obj`, `viewer.html`, `docs/plan/P03-dsl-grammar.md`,
> `P04-compiler-pipeline.md`, `P06-js-runtime.md`,
> `P12-scene-graph.md`, `P15-obj-gltf-loading.md`, `P20-cli-ux.md`
> (2026-11-23).
> **Goal served:** an *easy* compiler. A user must be able to (a) get
> their `.f3d` scene **out** into tools they already use, (b) put it
> **on a web page** in one paste, (c) bring a simple Three.js scene
> **in** without starting over, and (d) do all of that **gradually** —
> `.f3d` and Three.js side by side, never a flag-day rewrite.

---

## 0. Verdict in one page

| Question | Ruling |
|---|---|
| Source of truth | **`.f3d` is always the source; every other artefact is generated.** `scene.json`, `model.obj`, single-file HTML, and the embed snippet are outputs (P04 §6), never hand-edited second sources. Three.js JSON is an *input* only via the one-way importer in §5. |
| Export JSON from `.f3d` | Two dialects, already fixed by P04 §6.2: **v1** = today's flat `{triangles:[{id,v,color}]}` (loads in the unmodified `viewer.html`); **v2** = native IR dump (`{ir_version,meta,render,camera,lights,palette,objects:[{name,model,verts,tris}]}`). Default `both`. P25 adds no third dialect. |
| Export OBJ from `.f3d` | Keep today's `export_mesh_obj` semantics as the baseline (non-indexed `v` soup, bare `f a b c`, no `vt`/`vn`), plus a **grouped variant** (§3.3): one `o <name>` per IR object. OBJ carries **no colour, camera, light, or animation** — said in the output header and the manual, never implied otherwise. Colour, if the receiving tool needs it, travels in the companion v2 JSON or a sidecar `.mtl` (§3.4, deferred). |
| Embed HTML | **One self-contained `.html` file is the product** (P04 §6.4): scene JS inlined, no `fetch('scene.json')`, works from `file://`. The iframe snippet (§4) is a *generated text file* (`<stem>.embed.html.txt`) containing one `<iframe src="…">`; `srcdoc` embedding is an explicit opt-in with a size warning, not the default. |
| Import Three.js scene JSON | **Limited, one-way, loss-reporting** (§5): `Object3D.toJSON()` output only — *not* Three.js JavaScript code. Supports a named subset: `Scene`/`Group`/`Mesh` nodes, `BoxGeometry` (+ raw `BufferGeometry` positions/indices), `PerspectiveCamera`, `Ambient`/`DirectionalLight`, `MeshBasicMaterial`/`MeshLambertMaterial` colour, node TRS/matrix. Everything else is dropped **with a per-item report**, never silently, never faked. |
| Import direction naming | Importer emits a **`.f3d` file + a migration report**, not a live scene. The user reads/edits the `.f3d`, then builds normally. No direct Three-JSON → renderer path. |
| Coexistence | First-class, indefinite (§6): same page, `.f3d` viewer in an `<iframe>` next to an untouched Three.js canvas; same project, some scenes `.f3d`, some Three.js, sharing exported OBJ/JSON assets. Coexistence is a supported end-state, not just a migration phase. |
| Round-trip promise | Narrow and honest (§7): `.f3d → v1 JSON → viewer` and `.f3d → OBJ → f3dc load` (P15) preserve the **triangle multiset**. `.f3d → v2 JSON → IR` is identity (P04 §11). Three.js → `.f3d` → Three.js is **not** promised lossless and must never be marketed as such. |
| Non-goals (v1) | Importing `.js`/`.ts` Three.js programs, shaders/material graphs, textures, skinning/morphs, Three.js animation clips, physics, `Editor` project files as such, glTF (P15 §7 owns that), bidirectional live sync, hosting/CDN upload. |

---

## 1. Baseline — what exists today, exactly

### 1.1 Exports are real but minimal, and hard-coded

`src/main.f90` steps 7–8 unconditionally write three files for one
hard-coded cube; there are no flags, no choice of target, no stem naming:

```fortran
call framebuffer_save_ppm(fb, output_file)   ! 'output_render.ppm'
call export_mesh_json(cube, 'scene.json')
call export_mesh_obj (cube, 'model.obj')
```

- **`scene.json` (v1):** `{"triangles":[{"id":1,"v":[[x,y,z]×3],
  "color":[r,g,b]}, …]}` — 12 triangles for the cube. No camera, light,
  scene name, object name, or transform: transforms are already baked
  into the vertices, colour is per-triangle integers 0–255.
  Precision `F8.3` (`export_mesh_json` in `src/mesh.f90`).
- **`model.obj`:** header `# Fortran 3D Engine OBJ Export`, then
  **3 duplicated `v` lines per triangle** (36 for the cube, never
  shared/indexed), then `f i i+1 i+2`. No `o`/`g`, `vt`, `vn`,
  `mtllib`/`usemtl` — therefore **no colour at all** in the OBJ.
- **`viewer.html`:** standalone Canvas-2D painter's-algorithm viewer.
  It contains a **second, hand-duplicated copy of the cube** as a JS
  literal, tries `fetch('scene.json')` (silently no-ops on failure —
  notably under `file://`), and offers a file-picker for `scene.json`
  and PPM. It is the embed experience today, with its two known warts:
  duplication and the `file://` fetch failure. P04 §6.4 / P06 already
  plan the fix (inlined scene, generated viewer); P25 specifies the
  *migration/embed contract* on top of them, not a new viewer.

### 1.2 What the neighbouring plans already decided (P25 does not re-decide)

| Decision | Owner |
|---|---|
| Pipeline `parse → validate → optimize → emit`; emitters see only IR; `--target fortran,json,js,html`, default `all`; outputs under `build/`, never clobbering repo-root `scene.json`/`viewer.html`/`model.obj` without `--force` | P04 §4–§6, §9 |
| v1 vs v2 JSON dialects; v2 shape and `ir_version: 1` | P04 §6.2; P06 §4.2 (runtime form: `"f3d": 2`, flat arrays) — the two v2 spellings must be reconciled at implementation time; P25 treats them as *one* dialect and flags the discrepancy in §9 |
| Single-file HTML from a template, inlined scene, `file://`-safe | P04 §6.4 |
| JS runtime, `<f3d-view>`, multiple viewers per page, no globals except `window.F3D` | P06 §3, §6 |
| `.f3d` grammar: `export obj` / `export json [string]` statements; animation export out of v1; t=0 posed scene only | P03 §4, §8 |
| OBJ **import** (`load "x.obj"`), groups→objects, limits, errors `E51xx` | P15 (whole document) |
| Scene graph is flat objects + one level of named groups; one global namespace; no parenting/reparenting | P12 §1–§3 |
| CLI has five commands (`new/build/run/check/fmt`); `build` writes `build/<stem>.{f90,json,js,html}` | P20 §2–§3 |

Anything in P25 that appears to conflict with a row above loses to that
row unless §9 explicitly calls it an amendment for its owner to accept.

---

## 2. Principles

1. **Generated, stamped, regenerable.** Every export/embed file carries
   the P04 header stamp (compiler version, source file, source hash).
   If a user edits an export, the next build overwrites it under
   `build/` — the stamp says so in the file itself. Support answer to
   "my edits disappeared" is always "edit the `.f3d`".
2. **Loss is a report, not a surprise.** Every format boundary in this
   document has a *loss table* (§3.5, §5.4). Where loss occurs at
   compile/import time, the tool prints it, itemised and counted.
   Silent loss is a bug by definition here (same rule as P15 §2.3).
3. **The easy path is the compatible path.** Default export is the
   format the *existing* consumer already reads (v1 JSON for
   `viewer.html`, plain OBJ for Blender/Three.js `OBJLoader`).
   Richer formats are additive options, never the only output.
4. **Import is a starting point, not a conversion promise.** The
   Three.js importer succeeds if a beginner gets an editable,
   rendering `.f3d` that *looks like* their simple scene and a list of
   what to rebuild by hand. It fails if it produces a `.f3d` that
   renders wrong without saying why.
5. **No lock-in in either direction.** A user can leave `.f3d` taking
   OBJ + v2 JSON with them, and can arrive from Three.js taking the
   subset in §5.2. The exit door is a feature of the entrance pitch.
6. **Embed must work offline and alone.** Double-click the HTML →
   scene appears. No server, no CDN, no build step, no sibling files.
   This is the beginner's "send it to a friend / put it on my page"
   moment and it is not negotiable for the default path.

---

## 3. Export: `.f3d` → JSON / OBJ

### 3.1 Surface (no new grammar beyond P03)

```f3d
cube hero red at 0 0 0 size 2
export json              # → scene.json   (v1+v2 per §3.2)
export obj               # → model.obj
export json "dist/hero.json"
export obj  "dist/hero.obj"
render
```

CLI equivalent (P20/P04, preferred for scripts):

```console
$ f3dc build hero.f3d --target json,obj --out dist/
✓ built hero → dist/ (2 files) · hero.json: 12 triangles · hero.obj: 12 faces, colour not included (see §3.5)
```

- `export` in the `.f3d` file and `--target` on the CLI are two spellings
  of the same IR→emitter call (P04 §6); they must produce byte-identical
  files for the same IR. A file may contain both; duplicates dedupe.
- Default filenames follow P03 §8 (`scene.json` / `model.obj`) in the
  legacy in-place mode, and `<stem>.json` / `<stem>.obj` under `build/`
  in CLI mode (P20 §3.4). The plan does not introduce a third scheme.
- Export is of the **t=0 posed scene** (P03 §8): static `rotate`/`at`
  applied, animation not baked. Baking animation to per-frame OBJ/JSON
  sequences is explicitly out of v1 (§8).

### 3.2 JSON export — the two dialects

| | v1 (compat) | v2 (native) |
|---|---|---|
| Shape | `{triangles:[{id, v:[[..]×3], color:[r,g,b]}]}` | P04 §6.2 IR dump: `{ir_version, meta, render, camera, lights, palette, objects:[{name, model:[16], verts, tris:[{v:[a,b,c], c}]}]}` |
| Transforms | **Baked into vertices** | Kept as per-object `model` matrix; verts deduped/indexed |
| Camera/light/names/groups | Absent | Present (`group` as label only, per P12 §10) |
| Colour | Per-triangle, 0–255 ints | Palette indices, 0–255 ints in IR form (P06's 0–1 float runtime form is a runtime-loader conversion, §9) |
| Numbers | 3 decimals (`F8.3` parity) | 3 decimals for positions in file output; `%.6f` only in `--emit ir` dumps (P04 §6) |
| Consumers | Today's `viewer.html` unmodified; any existing user script reading `scene.json`; Three.js via the trivial loader in §6.3 | Future tooling, the importer in §5's counterpart, language servers, golden tests |
| Default | Emitted | Emitted (`--json-dialect both`); `--json-dialect v1` for users with old consumers |

Determinism (P04 §1): objects in source order, palette in first-use
order, keys in the documented order, no timestamps inside the JSON.
Same `.f3d` → byte-identical JSON. This is what makes export diffable
in version control, which §6.4 recommends for the v2 file only.

### 3.3 OBJ export — plain and grouped

Baseline (default, `--obj-dialect plain`): exactly today's format —
header, non-indexed `v` soup, bare faces. Any tool that reads today's
`model.obj` reads tomorrow's. Do not "improve" it by default.

Grouped (`--obj-dialect grouped`, or `export obj grouped` if the P03
owner accepts one optional word): one `o <name>` line before each IR
object's vertices, faces offset accordingly; still no `vt`/`vn`/`usemtl`.
This is the form P15's loader reads back into **separate named objects**
(P15 §4.5), so it is the round-trip form (§7) and the form to recommend
for Blender/Three.js, where named objects survive import. Group names
are the P12 global-namespace names, sanitised exactly as P15 §4.5
sanitises on the way in (lowercase, non-`[a-z0-9_-]` runs → `-`), so
export→import is name-stable.

Header honesty (both dialects), as OBJ comments:

```obj
# Fortran 3D Engine OBJ Export — generated by f3dc <ver> from hero.f3d sha256:<…>
# Geometry only: colour, camera, light and animation are NOT in this file.
# Colour/scene data: see hero.json (v2) alongside this file.
```

### 3.4 Colour into OBJ-land: the deferred `.mtl` sidecar

OBJ's only colour channel is `mtllib`/`usemtl` + a `.mtl` file with
`Kd r g b` (0–1 floats). Supporting it is *tempting and deferred*:

- **v1: do not emit `.mtl`.** Per-triangle colours (the v1 model) would
  need one material per distinct colour and a `usemtl` switch per face
  run — legal OBJ, but it doubles exporter complexity, interacts with
  P10's not-yet-built material model, and most simple OBJ consumers
  (including Three.js `OBJLoader` without `MTLLoader`) ignore it anyway.
- **Designed seam:** when P10 materials land, emit `<stem>.mtl` with one
  `newmtl color_<hex>` per palette entry and `usemtl` per face in the
  *grouped* dialect only, behind `--obj-mtl`. P15's loader ruling
  ("`usemtl` recorded, not applied") means our own re-import stays
  honest until P10 lands on both sides.
- Until then, the documented answer for "my OBJ is grey in Blender" is
  one sentence in the manual and in the build summary (§3.1): colour
  lives in the JSON; OBJ is geometry-only. Grey-by-surprise is the
  failure mode; grey-by-announcement is a format fact.

### 3.5 Export loss table (printed in the manual verbatim)

| Data in `.f3d` / IR | v1 JSON | v2 JSON | OBJ plain | OBJ grouped |
|---|---|---|---|---|
| Triangles / positions | ✅ baked | ✅ | ✅ | ✅ |
| Per-face colour | ✅ | ✅ (palette) | ❌ | ❌ (§3.4) |
| Object names | ❌ | ✅ | ❌ | ✅ (`o`) |
| Groups (P12, 1 level) | ❌ | ✅ label | ❌ | ⚠️ flattened to objects |
| Object transforms | baked | ✅ matrix | baked | baked |
| Camera, light, background, size | ❌ | ✅ | ❌ | ❌ |
| Animation (P09 tracks) | ❌ | ❌ v1 of v2* | ❌ | ❌ |
| Source `.f3d` text | ❌ (hash only) | ❌ (hash only) | ❌ (hash only) | ❌ |

\* P06 §4.2 reserves an optional `anim` array in the runtime form;
emitting it is P09's decision, not P25's. P25 only requires that the
loss table be updated in the same change that adds it.

---

## 4. Embed: single-file HTML and the iframe snippet

### 4.1 Single-file HTML — the artefact

`f3dc build page.f3d --target html` → `build/page.html`, per P04 §6.4:

- Template = the `viewer.html` shell (dark theme, 3D/PPM tabs retained),
  with three substitutions only: `{{TITLE}}` (scene name or file stem),
  `{{SCENE_JS}}` (inlined v1 triangles today; v2 + P06 runtime when it
  lands), `{{TRI_COUNT}}`.
- **No external references at all:** no `fetch`, no CDN script/style,
  no webfont, no favicon request (use an inline `data:` favicon or
  none). Acceptance test §7.3 greps the output for `http://`,
  `https://`, `fetch(`, and `src=` pointing outside the file.
- Works from `file://`, from any static host, and as an email/chat
  attachment. Degrades exactly as `viewer.html` does today (Canvas 2D
  painter's algorithm; convex-mesh assumption documented in P06 §11).
- Title, `<meta charset>`, and a `<noscript>` line ("this 3D scene
  needs JavaScript") are required — a beginner pasting the file into a
  CMS that strips `<script>` gets that sentence, not a blank box.

### 4.2 The iframe snippet — the paste

Alongside the HTML, `build` with `--target html` also writes
`<stem>.embed.html.txt` — a plain-text file whose entire content is
ready to paste into a blog, README-rendered page, LMS, or docs site
that hosts the `.html` file somewhere reachable:

```html
<!-- Fortran 3D scene "hero" — generated by f3dc from hero.f3d -->
<iframe src="hero.html" title="Interactive 3D scene: hero"
        width="680" height="520" loading="lazy"
        style="border:1px solid #334155;border-radius:8px;max-width:100%"
        sandbox="allow-scripts"></iframe>
```

Rules:

- **Relative `src` by default** (snippet sits next to the hosted file).
  `--embed-url https://…/hero.html` rewrites only the `src` value.
- **Size:** `width`/`height` = scene size (default 640×480) + 40 px of
  viewer chrome (header/controls), matching `viewer.html`'s layout;
  `max-width:100%` keeps it from breaking mobile layouts. No
  `allowfullscreen` (nothing fullscreenable in v1), no `allow` features.
- **`sandbox="allow-scripts"` and nothing else:** the viewer needs its
  own inline script and nothing else — no same-origin, no forms, no
  popups, no top navigation. This is the security story a user can
  paste into a school/company page and defend. If a future viewer
  needs storage or same-origin access, that is a documented flag
  change, never a silent snippet change.
- **`title` attribute is mandatory** (accessibility; screen readers
  announce iframes by title). Generated from the scene name.
- The snippet is a *separate file*, not a mode of the HTML: the HTML
  stays a clean artefact, the snippet stays copy-pasteable without
  opening it.

### 4.3 `srcdoc` variant — supported, warned, off by default

`f3dc build page.f3d --target html --embed srcdoc` additionally writes
a snippet whose `srcdoc="…"` carries the **entire escaped HTML**
(`"` → `&quot;`, `&` → `&amp;`, in that order). For pages where the
user cannot host a file at all (some wiki/LMS editors). The build
summary must warn, with the real number:

```console
✓ built page → build/ · embed (srcdoc): 21,408 bytes inlined — some editors truncate pasted HTML near 32 KB; prefer the hosted iframe (§4.2) for scenes over ~2,000 triangles
```

No other difference. The hosted-iframe snippet is always also written.

### 4.4 What embed is not

No hosted service, no upload, no shortlink, no analytics, no
`postMessage` API in v1. A host page cannot drive the embedded scene
(rotate-to-angle, swap colour) in v1; P06's in-page `<f3d-view>` /
`F3D.create(canvas)` is the API for *same-page* integration, and §6.2
keeps the two stories distinct: **iframe = isolation & paste-ability;
`<f3d-view>` = integration & control.** A `postMessage` bridge
(`{type:"f3d", …}`) is a named v2 candidate (§8), designed then against
real requests, not speculatively now.

---

## 5. Import: Three.js scene JSON → `.f3d` (limited)

### 5.1 Exactly which file this means

The input is the JSON produced by Three.js **`Object3D.toJSON()`**
(and saved by the Three.js Editor as a scene), identified by:

```json
{ "metadata": { "version": 4.5, "type": "Object",
                "generator": "Object3D.toJSON" },
  "geometries": [ … ], "materials": [ … ], "textures": [ … ],
  "object": { "type": "Scene", "children": [ … ] } }
```

Identification is by structure, not extension (`.json` proves nothing):
`metadata.type == "Object"` + top-level `object` + `geometries`/
`materials` arrays. Anything else gets one of three precise refusals:

| Input actually is | Message (P08 style, plain English) |
|---|---|
| Our own v1/v2 `scene.json` | "this is already a Fortran 3D scene file — build it directly: `f3dc build scene.f3d`" (v1 scene.json has no `.f3d`; help points at P15/P06 compat loading instead — wording fixed at implementation against the P08 catalogue) |
| Arbitrary JSON | "I can't tell what kind of JSON this is — the Three.js importer needs a file saved by Three.js `scene.toJSON()` / the Three.js Editor" |
| Not JSON / binary (e.g. `.glb`) | "this doesn't look like a text JSON file" (+ P15 §7.4's glTF guidance for `.glb`/`.gltf`) |

Three.js **source code is never an input.** There is no JS parser, no
transpiler, in this plan or any other: a user with a `main.js` is told,
in the manual's migration chapter, to add the two lines
`console.log(JSON.stringify(scene.toJSON()))` (or use the Editor's
*Save*) and import the result. That two-line bridge *is* the code
migration path — honest, tiny, and it runs their real scene graph
through Three.js's own serializer instead of our guess at their code.

### 5.2 Supported subset (v1 importer)

Traversal: depth-first over `object` and its `children`, composing
transforms down the tree (Three.js JSON gives either `matrix` (16,
column-major) or decomposed `position`/`quaternion`/`scale` per node —
importer accepts both; if `matrixAutoUpdate`-style decomposed fields
and `matrix` disagree, `matrix` wins and a report line says so).

| Three.js thing | Maps to | Conditions / notes |
|---|---|---|
| `Scene` node | `.f3d` scene (name from `name`, else file stem) | `background` colour → `scene background` if it is a plain colour; texture/cube background → dropped, reported |
| `Group`, plain `Object3D` | P12 `group` **if** it has ≥1 supported descendant mesh and depth ≤ 1 below scene; deeper nesting → **flattened** (world transforms baked into children), reported per group | P12 forbids deeper hierarchy; flattening preserves the picture, loses the structure — reported, §5.4 |
| `Mesh` + `BoxGeometry` | `cube` statement | `width/height/depth` → `size sx sy sz` (P03 non-uniform size); the one case that round-trips to a real primitive |
| `Mesh` + other primitive geometry (`SphereGeometry`, `CylinderGeometry`, `ConeGeometry`, `PlaneGeometry`, `TorusGeometry`, …) | **Not** a `.f3d` primitive in v1 | P03 reserves those keywords with `not supported yet` errors — the importer must not emit `.f3d` that the compiler then rejects. Instead: geometry is baked to an OBJ (§5.3) and referenced by `load`. Report says which and why. |
| `Mesh` + `BufferGeometry` with `attributes.position` (+ optional `index`, `attributes.color`) | Baked OBJ + `load` (§5.3) | Non-indexed or indexed both accepted; index expanded. Missing `position` → mesh dropped, reported. |
| Node `position`/`quaternion`/`scale` or `matrix` | `at` / `rotate` (Euler XYZ, degrees) / `size`-scale on the emitted statement | Quaternion → Euler conversion may be gimbal-ambiguous; matrix is decomposed once, at import. Non-uniform scale on a baked mesh folds into the OBJ vertices instead (exact), reported. |
| `PerspectiveCamera` (first one found) | `camera at … look … fov … near … far …` | `look` derived from camera world quaternion applied to (0,0,-1) + position. Extra cameras → dropped, reported. No camera → P03 defaults, one report line. |
| `DirectionalLight` (first) | `light dir … colour … strength …` | Direction = position→target (target node resolved if present, else origin). `intensity` → `strength`. |
| `AmbientLight` / `HemisphereLight` | Folded into the single light's `strength`/report only | The engine has one directional light + fixed ambient 0.25 (P03 §6.1); ambient lights cannot be represented — reported, not approximated silently. Further directional lights → dropped, reported. |
| `MeshBasicMaterial` / `MeshLambertMaterial` with plain `color` | `colour` on the statement | `color` is a hex int in Three JSON → `#RRGGBB`. Per-mesh material only; shared materials are just repeated. |
| Vertex colours (`vertexColors: true` + `attributes.color`) | Per-face colour in the baked OBJ path is **not** representable (P15: OBJ colour not loaded) → mesh imports uncoloured, reported | Kept visible in the report precisely because the render will look different. |
| Node/mesh `name` | `.f3d` name | Sanitised under P03/P12 rules (one global namespace; collisions → `-2`, `-3`, reported, cf. P15 §4.5). Empty name → auto `mesh1`, `cube1`, … |
| `visible: false` nodes | Dropped, reported (counted) | `.f3d` v1 has no visibility flag; emitting them would change the picture. |

Hard caps, mirroring P15 §4.7 in spirit: file ≤ 64 MB, ≤ 500 k
triangles after expansion, ≤ 1,024 emitted objects; exceeding any is a
refusal with the number, not a truncation.

### 5.3 The baked-geometry escape hatch (why import works at all)

Only boxes map to primitives, so a naïve importer would reject almost
every real Three.js scene. The hatch that makes the subset useful:

- For every non-box mesh, the importer writes
  `<stem>_assets/<name>.obj` (positions + faces only — exactly the
  P15-supported OBJ subset, world transform of the *geometry's own*
  node baked in, ancestors applied to the emitted `load` statement's
  `at`/`rotate` where decomposable, else also baked).
- The `.f3d` then contains `load "<stem>_assets/<name>.obj" <name>
  colour … at …` — which P15 already specifies end-to-end.
- Result: **any** static triangle mesh Three.js can serialise imports
  and renders, at the cost of becoming an opaque loaded mesh rather
  than an editable primitive. The report (§5.4) separates "imported as
  editable `.f3d`" from "imported as baked mesh" so the user knows
  exactly what they can still edit as code.

### 5.4 The migration report (mandatory, not a flag)

Every import writes `<stem>.migration.md` next to the `.f3d` and prints
a 3-line summary. Format is fixed (tests assert its sections):

```markdown
# Migration report — myscene.json → myscene.f3d
Imported as editable .f3d:  3 objects (2 cubes, 1 group of 1)
Imported as baked meshes:   5 objects → myscene_assets/*.obj (listed)
Dropped, with reason:       7 items
  - textures: 3 (engine has no textures yet — meshes keep their colour)
  - materials: 2 MeshStandardMaterial → colour kept, metalness/roughness lost
  - lights: 1 PointLight 'lamp' (only one directional light exists)
  - animation: 1 clip 'spin' (not imported; see P09 for .f3d animation)
Changed silently: NOTHING.  (This line is literal and always present.)
Numbers: 12,408 triangles in, 12,408 triangles out.
```

Rules: every dropped/changed item is named (type + Three.js `name` or
uuid prefix); triangle counts in/out must reconcile or the import
**fails** rather than reporting a mismatch as success; unsupported
*material classes* (`MeshStandardMaterial`, `MeshPhongMaterial`,
`ShaderMaterial`, …) keep their `color` if present and lose everything
else, itemised — except `ShaderMaterial`, whose colour is not
extractable and which is reported as uncoloured. Unknown node/geometry
types are dropped-and-reported, never fatal: one weird node must not
veto a scene (contrast P15's all-or-nothing *file validity* rule —
here the file is valid; its *contents* are partially out of scope).

### 5.5 CLI / grammar surface

One new subcommand is required, which **amends P20** (its five-command
list gains a sixth, or — P20 owner's choice — this ships as
`f3dc build --from three <file.json>`; P25's requirement is only the
behaviour below, not the spelling):

```console
$ f3dc import myscene.json
✓ imported myscene.json → myscene.f3d (3 editable + 5 baked objects) — 7 things were not imported; see myscene.migration.md
  next: f3dc run myscene.f3d
```

- Never overwrites an existing `.f3d`/assets dir without `--force`
  (P20 never-clobber rule). Exit codes per P20 §6.2: bad invocation 2,
  unreadable/invalid input file 3, scene-level refusal (caps, §5.1
  misidentification) 1 with the P08-style message.
- No `.f3d` grammar change: the importer is a *producer* of ordinary
  P03 `.f3d` (`cube`, `load`, `camera`, `light`, `scene`, `group`,
  `render`, `export`) plus `#` comments noting the source uuid per
  object, so a migrated file is a normal file from line one.

### 5.6 Worked miniature

Input (abridged): a `Scene` with one red `BoxGeometry(2,2,2)` mesh
named `hero` at (1,0,0), one `SphereGeometry` mesh, a
`PerspectiveCamera(60, …, 0.1, 100)` at (3,2.5,4), one
`DirectionalLight`. Output:

```f3d
# imported from myscene.json by f3dc <ver> — see myscene.migration.md
scene "myscene"
camera at 3 2.5 4 look 0 0 0 fov 60 near 0.1 far 100
light dir -0.5 -1 -0.7        # from the Three.js directional light
cube hero colour #ff0000 at 1 0 0 size 2 2 2
load "myscene_assets/orb.obj" orb colour #3366ff at -2 0 0
render
```

(The sphere arrives as `orb.obj`, per §5.3 — editable as a file,
honest in the report, and upgradeable to a real `sphere` statement by
hand the day P11/P03 primitives land, with no importer change.)

---

## 6. Coexistence — `.f3d` and Three.js in the same world

### 6.1 Stance

Migration is **per-scene, reversible, and optional**. Nothing in this
plan deprecates Three.js for a user who needs what §5.2 drops
(textures, PBR, skeletal animation). The pitch is: use `.f3d` where
easy wins (teaching, prototypes, embeds, simple product/object
viewers), keep Three.js where it is already working.

### 6.2 Same page

Two supported patterns, deliberately different (§4.4):

1. **Isolated:** the §4.2 iframe next to / above / replacing one
   Three.js canvas. No shared JS state, no version coupling, works
   even when the page's Three.js is bundled/minified/ancient. This is
   the recommended incremental step: swap *one* viewer, keep the rest.
2. **Integrated:** P06's `<f3d-view src="scene.json">` or
   `F3D.create(canvas, …)` in the same page as a Three.js renderer.
   Two canvases, two render loops; P06 §6's no-globals rule and
   pause-when-hidden behaviour are what make this safe. Sharing one
   canvas/WebGL context between the two engines is **not** supported
   and the manual says so in one line.

### 6.3 Same data

- **`.f3d` → Three.js:** load the exported OBJ with Three.js
  `OBJLoader` (grouped dialect preserves object names), or load v1
  JSON with the ~20-line `BufferGeometry` builder documented in the
  manual (triangles array → `position`/`color` attributes,
  `MeshLambertMaterial({vertexColors:true})`). This snippet is a
  *documentation artefact*, tested against the current v1 golden file
  (§7), not a shipped library.
- **Three.js → `.f3d`:** §5's importer.
- **Shared assets:** an OBJ in the project is consumable by both
  (Three.js `OBJLoader`; `.f3d` `load`, P15). Teams mid-migration keep
  one asset folder; neither side owns it.

### 6.4 Incremental migration playbook (the manual's chapter, in brief)

1. **Embed first (zero code change):** build the HTML for one `.f3d`
   scene, iframe it beside the existing Three.js page. (§4.2)
2. **Export across:** point one existing Three.js viewer at an exported
   OBJ/v2 JSON instead of its hand-built geometry. (§6.3)
3. **Import one simple scene:** run §5 on the simplest Three.js scene
   in the project; read the migration report; fix by hand only what it
   lists. Keep the original JSON under version control beside the
   generated `.f3d` + report, so re-import after upstream changes is a
   diff, not a leap.
4. **Stop wherever it stops paying.** Scenes that hit §5.2's drop list
   hard stay in Three.js; that is the design working, not failing.

Version-control guidance (one paragraph in the manual): commit `.f3d`
sources and v2 JSON exports; treat v1 JSON, OBJ, and HTML as build
artefacts (regenerable, P04 stamps prove it) unless a consumer outside
the build needs them pinned.

### 6.5 Version coexistence

- v1 JSON readers (today's `viewer.html`) must keep working against
  every future exporter's v1 dialect — the dialect is frozen at
  today's shape; additions go to v2 only (P06 §4.1 rule).
- The Three.js importer names the Three.js JSON versions it was tested
  against (`metadata.version` 4.5-era `toJSON`, r160–r180 per P01's
  census range) and **warns, but proceeds**, on a higher version:
  Three's `toJSON` layout has been stable across that range, and a
  hard refusal on an unknown-but-probably-fine version is the opposite
  of easy. New/renamed fields land in the drop report via §5.4's
  unknown-type rule, which is what makes proceeding safe.

---

## 7. Acceptance tests

1. **Export golden:** the P03 §9 examples built with `--target json,obj`
   produce byte-identical files across two runs; v1 JSON loads in the
   **unmodified** current `viewer.html` logic and shows the same
   triangle count badge as the source scene.
2. **OBJ round-trip:** grouped OBJ exported from a 2-object `.f3d`,
   re-imported via P15's `load`, yields the same object names and the
   same triangle multiset (positions to 1e-3, the `F8.3`/`F9.4`
   precision floor); plain OBJ round-trips geometry as one object.
3. **Embed self-containment:** generated HTML contains no external
   reference (grep test, §4.1), renders the correct triangle count with
   networking disabled and from `file://`, and its triangle data equals
   the same build's v1 JSON exactly (no third copy of geometry — the
   §1.1 duplication wart cannot regress).
4. **Snippet correctness:** the generated iframe snippet, pasted into a
   bare HTML page beside the hosted file, displays the scene; snippet
   contains `title=`, `sandbox="allow-scripts"`, and no other `allow*`
   attributes; `srcdoc` variant round-trips escaping on a scene whose
   name contains `"` and `&`.
5. **Three.js import fixtures:** (a) box-only scene → all-editable
   `.f3d`, zero baked, zero dropped; (b) mixed scene (sphere mesh,
   standard material, point light, one texture, one animation clip) →
   `.f3d` compiles and renders, report itemises exactly the expected
   5+ drops/changes and triangle counts reconcile; (c) nested groups
   3 deep → flattened, reported; (d) each §5.1 misidentification →
   its exact refusal message, no `.f3d` written; (e) sphere fixture's
   baked OBJ loads under P15 rules unmodified.
6. **Report integrity:** for every fixture in (5), deleting any dropped
   item from the input removes exactly its report line; the literal
   line `Changed silently: NOTHING.` is present in every report.
7. **Coexistence smoke:** one page containing a Three.js canvas and
   the §4.2 iframe (and, separately, a `<f3d-view>`) renders both
   scenes; neither engine's failure (bad JSON for one) blanks the other.
8. **No-clobber:** `import` and export-to-repo-root without `--force`
   refuse over existing files (P20 rule), exit code as specified.

---

## 8. Explicitly deferred / out of scope

- `.mtl` emission (§3.4, waits on P10); texture import/export in any
  direction (waits on P14/P10); animation export or Three.js animation
  import (P09 owns `.f3d` animation semantics first).
- `postMessage` embed API, hosted embeds, embed analytics (§4.4).
- Importing Three.js **code**, React Three Fiber JSX, or Editor
  `.json` *project* files containing scripts/history (§5.1 covers
  scene JSON only; a project file wrapping a scene is unwrapped by
  hand — one manual paragraph, no code).
- glTF in either direction (P15 §7); USD/FBX/STL in either direction
  (no plan owns them; OBJ+JSON cover the beginner interchange need).
- Live/two-way sync, shared scene editing, and any guarantee about
  Three.js → `.f3d` → Three.js fidelity (§0).
- Wiring `export` statements to *upload* anywhere. Export writes files.
  Period.

---

## 9. Risks & open questions

- **Two v2 JSON spellings exist on paper** — P04 §6.2's IR dump
  (`ir_version`, `objects[].tris[].c`) vs P06 §4.2's runtime form
  (`"f3d": 2`, `meshes[].positions`, 0–1 colours). P25 assumes one
  dialect with a loader-side conversion (as P06 §4.2 rule 3 already
  describes for v1 colours); the P04/P06 owners must pick the file
  spelling before the exporter is built, or §3.2's "no third dialect"
  ruling is violated by our own plans.
- **CLI spelling of import** (§5.5) needs P20's owner to accept a sixth
  command or a `--from` mode. Behaviour is specified either way;
  shipping it as a separate script outside `f3dc` is the one option
  ruled out (breaks P20's one-tool story).
- **Quaternion→Euler on import** can produce ugly-but-correct
  `rotate` triples (e.g. `0 90 180`-style equivalents). Acceptable for
  v1 — the `.f3d` renders identically — but the report should note
  objects whose rotation was decomposed from a matrix, so users are
  not surprised by unfamiliar numbers in "their" file.
- **Three.js `toJSON` embeds `metadata.version` per library version,
  not per format stability**; §6.5's warn-and-proceed stance depends on
  the drop-report safety net. If a future Three release restructures
  `geometries` (e.g. moves to a registry format), the importer must
  fall back to the §5.1 "can't tell what this is" refusal rather than
  importing garbage — fixture (5d) should gain a synthetic
  future-format case when that happens.
- **OBJ grouped dialect vs strict parsers:** some minimal OBJ readers
  mishandle `o` lines mid-file. Mitigation is the default staying
  *plain* (§3.3); grouped is opt-in and documented as the
  Blender/Three.js/P15 round-trip form.
- **Iframe + `sandbox` on some CMS/LMS hosts** strips `sandbox` or
  iframes entirely; the fallback story is the `srcdoc` snippet (§4.3)
  or same-page `<f3d-view>` (P06) — the manual's embed chapter should
  present all three in that order of preference.

---

## 10. Implementation sequence

| # | Milestone | Contents | Exit test |
|---|---|---|---|
| M1 | Export contract | `--json-dialect`, `--obj-dialect` on P04 emitters; OBJ header honesty lines; §3.5 loss table in manual; build-summary loss lines | §7.1, §7.2, §7.8 |
| M2 | Embed | `<stem>.embed.html.txt` (hosted iframe) from `emit_html`; self-containment grep in CI; `srcdoc` variant + size warning | §7.3, §7.4 |
| M3 | Three.js import, core | Identifier + refusals (§5.1); scene/camera/light/box/name/transform mapping; migration report skeleton with the literal line | §7.5a, §7.5d, §7.6 |
| M4 | Three.js import, baked path | `BufferGeometry`/non-box primitives → `<stem>_assets/*.obj` + `load` statements; group flattening; material-colour extraction; caps | §7.5b, §7.5c, §7.5e |
| M5 | Coexistence docs + smoke | Manual migration chapter (§6.4 playbook, Three.js v1-JSON snippet, exit-door story); two-engines-one-page smoke fixture | §7.7 |

M1 alone already improves today's reality (honest, dialect-controlled
exports from the existing pipeline). M3 is the smallest import that is
worth the name; M4 is what makes it useful on real scenes — cutting M4
means the importer handles only box worlds, and the manual must then
say exactly that rather than letting §5's subset imply more.
