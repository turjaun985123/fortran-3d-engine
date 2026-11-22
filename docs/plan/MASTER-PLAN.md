# Forge3D — MASTER PLAN
### A compiler that makes 3D greater than Three.js and PixiJS — and unbelievably easy to use

> Synthesised 2026-11-23 from a **30-agent planning swarm** (3 batches × 10, all 30 verified on disk, 14,149 lines in `docs/plan/P01`–`P30`).
> **Product name (working): Forge3D.** Language: `.f3d`. Compiler CLI: `f3dc`. Native engine: the existing Fortran renderer in `src/`.
> **User expansion 2026-11-23 00:06 (superseding):** *“Don’t stop until it’s compatible as Three.js and PixiJS 3D — all features — and better than those and easy to use.”*
> Therefore: **v1 is Milestone 1, not the finish.** There is **no “Won’t do” bucket for parity features** — deferral is by wave order only. Waves continue until the Feature-Parity Matrix (§3) is **100 % implemented AND tested**.

---

## 0. Baseline (verified audit, do not re-litigate)

| Fact | Value |
|---|---|
| Repo | `turjaun985123/fortran-3d-engine`, 1 commit, clean |
| Fortran | 5 modules, ~900 LOC: `math_3d.f90` (vec3/mat4, perspective, look_at), `mesh.f90` (Triangle/Mesh, **only** `create_cube`, JSON/OBJ export), `camera.f90`, `renderer.f90` (CPU barycentric rasterizer, Z-buffer, Lambert `0.25+0.75·diffuse`, PPM P3), `main.f90` (hardcoded 640×480, one rotating cube) |
| Other | `Makefile` (gfortran `-O3 -Wall -Wextra -fcheck=all`), `scene.json` (12 tris), `model.obj`, `viewer.html` (16,975 B, mouse orbit, painter’s algorithm) |
| Missing | Scene graph, other primitives, materials/textures, animation system, input system, tests, CI, any compiler/language |

**Planning gaps note (expansion handling):** P01–P27 were briefed before the 00:06 expansion and some use old “v1/v2, deferred” language (e.g. P03 reserves primitives, P10 defers shadows, P14 defers textures, P15 defers glTF). Those deferrals are **re-interpreted by this master plan as wave assignments**, not cuts. P28/P29/P30/P23 received the expansion in-flight and already use Must / Wave 2 / Wave 3 with no Won’t bucket (P28 §8, P29 §6, P30 ledger). Where a P-file says “won’t / not supported”, the matrix row in §3 governs.

---

## 1. The .f3d language — grammar (synthesis of P03, amended by P09–P16, P21)

### 1.1 The contract
```f3d
cube red
spin it
render
```
3 lines = the current `main.f90` demo, deterministically: 640×480, bg `#191923` (25,25,35), camera (3, 2.5, 4)→(0,0,0) fov 60 / near 0.1 / far 100, directional light (−0.5,−1,−0.7), cube size 2 at pose 20°X / 35°Y, spin = Y axis, 90°/s, 5 s, 30 fps (P03/P09). One-liners also work: `cube` · `sphere red` · `pyramid yellow` (P21).

### 1.2 Core grammar (EBNF, v1 core; wave extensions add productions, never change these)
```
program     := { line }
line        := scene_stmt | camera_stmt | light_stmt | object_stmt
             | group_block | anim_stmt | controls_stmt | load_stmt
             | repeat_stmt | output_stmt | comment | blank
comment     := ("#" | "//") { any }
scene_stmt  := "scene" [name] [ "size" int "x" int ] [ "bg" colour ]
camera_stmt := "camera" [ "at" vec3 ] [ "look" vec3 ] [ "fov" num ]
               (* wave C adds: "ortho" | preset names *)
object_stmt := prim [ name ] [ colour ] { prop }
prim        := "cube" | "sphere" | "cylinder" | "plane" | "pyramid" | "cone" | "torus"
prop        := "at" vec3 | "size" num | "radius" num | "height" num
             | "rotate" vec3 | "scale" (num | vec3) | "material" ident
             | "segments" int | "detail" ("low"|"med"|"high") | "capped" | "open"
             | texture_prop   (* wave A; v1: reserved, diagnostic E-TEX-V1 — P14 *)
group_block := "group" name { prop } NEWLINE { object_stmt } "end"   (* one level only — P12 *)
light_stmt  := "light" ("directional"|"ambient") [ vec3 ] [ "intensity" num ] [ colour ]
               (* wave A adds "point" | "spot" *)
anim_stmt   := ("spin"|"bob"|"pulse"|"orbit"|"move"|"turn"|"grow") target { anim_prop }
anim_prop   := "axis" axis | "speed" num | "duration" num | "fps" int
             | "ease" ident | "loop" ("once"|"forever"|"pingpong"|"repeat(" int ")")
load_stmt   := "load" string [ name ] { prop }   (* OBJ v1 — P15; glTF wave B *)
repeat_stmt := ("repeat" int | "grid" int "x" int | "ring" int) object_stmt  (* P16, caps §7 *)
controls_stmt := "controls" ("orbit"|"none") { "autorotate" | "min" num | "max" num }  (* P13 *)
output_stmt := "render" [ string ] [ "size" int "x" int ] | "export" ("json"|"obj"|"html") [ string ]
colour      := named | "#" hex6 | "rgb(" int "," int "," int ")"   (* named palette = mesh.f90 + Okabe–Ito defaults, P24 *)
vec3        := num "," num "," num | "(" num "," num "," num ")"
target      := "it" | name | "all" | group_name
```
Lexical/validation rules, full EBNF and defaults table: **P03**. Animation formulas are closed-form `f(t)` (deterministic, native ≡ JS): **P09**. Primitives (defaults / tri counts): sphere 352, cylinder 64, plane 4, pyramid 6, cone 32, torus 384, cube 12: **P11**.

### 1.3 Defaults = the product (P24)
Zero-config is a feature, not an accident: missing camera/light/scene all inject the demo defaults above; empty file renders the demo cube with warnings (render path only). Single shared defaults source for Fortran, compiler and viewer — the current bg divergence (`#191923` vs viewer `#020617`) must be fixed in Phase 0.

---

## 2. Compiler architecture (P04, P20, P08, P07, P26)

```
.f3d ─▶ lexer ─▶ parser (recursive descent, span-preserving AST)
     ─▶ desugar (defaults, group/repeat expansion)
     ─▶ validate ─▶ Typed IR (frozen, versioned, mirrors Fortran Camera/Mesh/FrameBuffer)
     ─▶ optimize O1–O7: drop · dedup/index · degenerate-cull · static backface ·
                        palette · transform-bake · JS depth-sort   (P07 correctness rules apply)
     ─▶ emit ─┬─ Fortran scene program (uses existing src/ APIs)
               ├─ scene.json v2 (+ legacy v1 compat for today’s viewer.html)
               ├─ dependency-free JS module
               └─ single-file HTML (template + inlined scene, file://-safe)
```
- **Implementation language:** stdlib-only **Python 3** in `tools/f3dc/` — no pip, no third-party imports (CI greps a whitelist). Rendering stays Fortran. IR JSON is the port boundary if self-hosting is ever wanted (P04).
- **CLI `f3dc`** (P20): `new / check / build / run / fmt / doctor`; bare `f3dc file.f3d` = run. Outputs default to `build/`; **never clobbers** checked-in `scene.json`/`viewer.html`. Exit codes 0 / 1 scene / 2 usage / 3 IO / 4 toolchain / 70 internal.
- **Diagnostics** (P08): `file:line:col`, underlined snippet, `why:` + paste-ready `help:`, did-you-mean (Damerau–Levenshtein ≤ 2 + alias table), stable append-only codes (E1xx syntax, E2xx names, E3xx ranges, E4xx structure, E5xx IO, E8xx security/limits, W-codes), `--explain`, `NO_COLOR`/JSON modes. **No silent black screens** — the #1 Three.js pain (P01) is a compile error here.
- **Security limits** (P26): 1 MiB `.f3d`, 4,096-char lines, nesting depth 16, repeat ≤ 1,000, ≤ 10,000 placements, ≤ 1 M triangles/scene, OBJ ≤ 64 MB / 500 k faces; scene-relative paths with symlink containment; declarative only — `system/eval/import` are rejected (E820); argv-only toolchain calls.
- **JS runtime** (P06): player-not-engine, WebGL1, zero deps, `<f3d-view>` / `F3D.create()`, orbit + TRS animation, Lambert matching `renderer.f90`, Canvas-2D fallback with identical API. **Hard budget: `f3d.min.js` ≤ 15,360 B, CI-enforced.**

---

## 3. ⭐ FEATURE-PARITY MATRIX — the spine (expansion §1)

Legend — **Wave:** 1 = v1 build swarm (B01–B50) · 2 = Wave A/B · 3 = Wave C+ · Cont = continuous seats B85/B86/B93+.
**Better metric** is per-row and measurable (P23 §6 verdicts: WIN / PARITY / GAP / NOT-COMPARABLE; GAP scores blank, never 0; **no aggregate score, no FPS-vs-GPU claims**).

### 3A. Three.js core parity
| # | Three.js feature | Forge3D equivalent (.f3d / API) | Wave | Proof test | Better (measurable) |
|---|---|---|---|---|---|
| 1 | Scene + Scene graph | Flat list + 1-level `group … end`, flattened at compile (P12) | 1 (deep nesting 2) | Identity-group regression; world=group·local parity ≤1e-6 | 1 concept (group) vs Object3D tree + add/remove boilerplate |
| 2 | PerspectiveCamera | `camera at … look … fov …` or nothing (default) | 1 | Golden cube with default camera = baseline hash | 0 lines vs ~4 + aspect/resize plumbing |
| 3 | OrthographicCamera | `camera ortho` (ext_cameras) | 3 (B78–B80) | Ortho golden, `examples/post-ortho.f3d` | Same 1 line as perspective |
| 4 | BoxGeometry | `cube` | 1 | Tri count 12, normals, golden | 1 word vs Geometry+Material+Mesh triple |
| 5 | SphereGeometry | `sphere` | 1 | 352 tris @ med, analytic normals | 1 word, sensible segment defaults |
| 6 | Cylinder / Cone / Plane / Pyramid* / Torus | `cylinder` `cone` `plane` `pyramid` `torus` (*pyramid = extra, Three has no direct equiv.) | 1 | P11 count formulas + volume/normal tests | Defaults for every parameter; 0 required args |
| 7 | All other geometries (Circle, Ring, Tube, Lathe, Extrude, Text…) | New primitives via `ext_*.py` + `mesh.f90` builders, minted seats B93+ | Cont | Per-geometry count/normal/golden test, matrix row flips to Done-verified | Same 1-word form for every geometry |
| 8 | MeshBasicMaterial | `material basic` / flat colour | 1 | Unlit golden (light-independent) | Colour is a word on the object line, not a material object |
| 9 | MeshLambertMaterial | Default material (Lambert, legacy 0.25/0.75 reproduced exactly) | 1 | Legacy-default golden = today’s render | Default — 0 lines to get lit 3D |
| 10 | MeshPhongMaterial | `material phong`, specular/shininess | 1 (Should) / 2 | Blinn specular golden (P10) | One keyword vs material class + light setup |
| 11 | MeshStandardMaterial (PBR) | `material standard`, metalness/roughness (B56–B59) | 2 | PBR golden suite (Wave A parity tests B61) | PBR with defaults; no env-map boilerplate to start |
| 12 | Ambient / Directional lights | `light ambient` / default directional | 1 | Legacy lighting golden | A working light exists with 0 lines |
| 13 | Point / Spot lights | `light point …` / `light spot …` (B52, B58, B60) | 2 | Attenuation/spot-cone goldens | Position + intensity only; no helper objects |
| 14 | Fog | `scene fog …` linear/exp² (B54) | 2 | Fog golden at 3 depths | 1 clause on the scene line |
| 15 | Textures / UV | `texture: "…"` + frozen UV contract per primitive (P14) | 2 (v1: reserved + loud diagnostic) | Orientation test-card, v1 golden pixel-identity without textures | UVs generated per primitive — 0 UV code |
| 16 | Shadows | `shadow: blob` fake in 1 (honest label); real shadow maps (B53, B60) | 1 fake / 2 real | Shadow-map golden; `shadow: soft` in v1 = compile error, never a silent fake | 1 word vs 5-place scattered opt-in in Three (P01 pain #4) |
| 17 | AnimationMixer / clips / timeline | `spin/bob/orbit/move…` + keyframe tracks in IR (P09) | 1 simple / 2 full keys | Loop-closure + golden-pose tests; frame-0 = still | Declarative 1 line vs mixer/clip/action plumbing; no user loop |
| 18 | OBJ loading | `load "model.obj"` (P15: v/vt/vn/f, groups) | 1 (Should) | Round-trip repo `model.obj`: 36 v / 12 f → 12 tris | 1 line vs async loader + callbacks |
| 19 | glTF / GLB loading | `load "model.gltf"` via `ext_gltf.py` + Fortran ingest (B63–B64) | 2 | glTF sample-scene parity tests (B74) | Same `load` line as OBJ — format is not a new API |
| 20 | Raycaster / picking | Raycast module native (B65) + JS picking (B66) | 2 | Pick-cube-at-pixel test, native ≡ JS | Picking on by default in viewer; no ray math in user code |
| 21 | OrbitControls | `controls orbit` (default in viewer), Pointer Events, touch, keys (P13) | 1 | Clamp/frame-rate-independence + parity tests | Built-in, 0 imports, 0 lines |
| 22 | InstancedMesh | `repeat/grid/ring` compile-time expansion (1); true instancing (B81–B82) | 1 / 3 | 100-cube scene = 1,200 tris budget test (P16) | `grid 10x10 cube` vs InstancedMesh matrix plumbing |
| 23 | Sprite | `sprite …` billboards (B67, B69–B70) | 2 | Billboard-always-faces-camera test | Sprite is a scene object, not a separate system |
| 24 | Text overlay (via CSS2D / troika in Three) | `text "…"` bitmap-font quads (B68–B70) | 2 | Text golden, atlas test | 1 line; works in native render too (Three text needs DOM) |
| 25 | Tone mapping / colour space | ACES/Reinhard/none pass (B55) | 2 | Tone-map golden, colour-space test | 1 scene keyword, default = none (deterministic) |
| 26 | Multi-scene / multi-view | Multiple `scene` blocks + multiple `<f3d-view>` / outputs | 3 | Two-scene compile + render test | Scenes are files/blocks, not renderer juggling |
| 27 | Renderer (WebGL) | Fortran CPU renderer (deterministic) + tiny WebGL player | 1 | Cross-renderer parity goldens | **Different claim:** offline, deterministic, no GPU/browser needed — FPS vs GPU is NOT-COMPARABLE (P23) |
| 28 | Clock / render loop | No user loop anywhere: compiler + runtime own it | 1 | Animation goldens at fixed t | **0 lines** — loop and resize are exactly 0 (P01 contract) |

### 3B. PixiJS strengths applied to 3D (P02 — note: `@pixi/3d` beta v0.1.0 exists, Nov 2026; “Pixi can’t do 3D” is **not** a claim we make)
| # | PixiJS strength | Forge3D equivalent | Wave | Proof test | Better (measurable) |
|---|---|---|---|---|---|
| 29 | Stage / 2D overlay on top of render | HTML viewer overlay + `text`/`sprite` layer in scene IR | 2 | Overlay renders above 3D in both backends | One scene file for 2D+3D — no second stage/renderer seam |
| 30 | Filters / post effects | Post chain: blur, bloom-approx, vignette, gamma, colour-matrix (B75–B77) | 3 | Per-filter goldens, chain-order test | `filter blur` clause vs filter objects + areas |
| 31 | Text (Pixi Text) | See row 24 | 2 | See row 24 | Native + web, same line |
| 32 | Particle systems | Fixed-step point-sprite emitters (B71–B73) | 2/3 | Deterministic emitter test at t (seeded) | Deterministic + offline-renderable; Pixi particles are wall-clock only |
| 33 | Ticker / animation loop | See row 28 — timeline is data (`f(t)`), ticker is internal | 1 | Determinism: same t ⇒ same frame, both backends | No ticker code; time is scrubbable/bakeable |
| 34 | Assets / loader | `load` line + compiler asset checks (exists, limits, format) at build time | 1 OBJ / 2 glTF+textures | Missing-asset = compile error with path, not runtime 404 | Errors move from runtime to compile time |
| 35 | Sprites (Pixi Sprite) | See row 23 | 2 | See row 23 | Sprites participate in 3D depth, not a 2D layer |
| 36 | Ease of getting *anything* on screen (Pixi’s real strength) | `cube` alone renders a lit, framed scene | 1 | Zero-config golden (P24) | 1 line total incl. HTML — measured, P21/P23 method |

**Matrix governance (P29/P30):** B85 generates this matrix machine-readably; B86 is the coverage test / stop rule. Status values only: `Done-verified / In-wave-N / Queued-wave-N / Blocked`. Waves mint seats **B93, B94, …** until B86 reports **100 %**.

---

## 4. Exact v1 file list — ONE owner seat per file, 50-agent build swarm (P29 §2, verbatim ownership)

### Compiler — `tools/f3dc/*.py`, stdlib only (B01–B18)
| Seat | File | Seat | File |
|---|---|---|---|
| B01 | `tools/f3dc/f3dc.py` (shim) | B10 | `tools/f3dc/optimize.py` (O1–O7 + pass registry) |
| B02 | `tools/f3dc/errors.py` (Span/Diagnostic/codes) | B11 | `tools/f3dc/emit_common.py` |
| B03 | `tools/f3dc/lexer.py` | B12 | `tools/f3dc/emit_fortran.py` |
| B04 | `tools/f3dc/ast_nodes.py` | B13 | `tools/f3dc/emit_json.py` (v2 + legacy v1) |
| B05 | `tools/f3dc/parser.py` | B14 | `tools/f3dc/emit_js.py` |
| B06 | `tools/f3dc/compat.py` (legacy JSON/OBJ→AST) | B15 | `tools/f3dc/emit_html.py` |
| B07 | `tools/f3dc/desugar.py` (defaults, group/repeat) | B16 | `tools/f3dc/driver.py` (gfortran/make) |
| B08 | `tools/f3dc/ir_nodes.py` (frozen IR + **extension hooks**) | B17 | `tools/f3dc/cli.py` |
| B09 | `tools/f3dc/validate.py` (AST→IR, E3xx/E4xx) | B18 | `tools/f3dc/viewer_template.html` |

### Fortran — `src/*.f90` (B19–B27; 5 existing extended, 4 new)
B19 `math_3d.f90` · B20 `mesh.f90` (all P11 primitives; **no** OBJ parsing) · B21 `camera.f90` · B22 `material.f90` *(new)* · B23 `scene.f90` *(new, .scene reader + dispatch)* · B24 `renderer.f90` (material-aware, old signature kept as wrapper) · B25 `main.f90` (CLI scene arg; no-arg = today’s cube byte-for-byte) · B26 `obj_loader.f90` *(new)* · B27 `animation.f90` *(new)*

### Runtime JS (B28–B30)
B28 `runtime/f3d.js` (WebGL + Canvas2D fallback, orbit, `<f3d-view>`; ≤15 KB min) · B29 `runtime/f3d.d.ts` · B30 `viewer.html` (legacy, kept working on v1 JSON, no new features)

### Tests (B31–B42)
B31 `tests/run_tests.py` · B32 `test_lexer.py` · B33 `test_parser.py` · B34 `test_validate.py` · B35 `test_optimize.py` · B36 `test_emit.py` · B37 `test_errors.py` · B38 `tests/fortran/assert_utils.f90` · B39 `test_math_mesh.f90` · B40 `test_camera_renderer.f90` · B41 `tests/golden/check_image.py` · B42 `tests/e2e/test_cli.py` *(all under `tests/compiler/` unless shown)*

### Examples / build / docs / CI (B43–B50)
B43 `examples/hello-cube.f3d` · B44 `examples/multi-object.f3d` · B45 `examples/animated.f3d` · B46 `examples/materials.f3d` · B47 `Makefile` *(integration seat, build only)* · B48 `.github/workflows/ci.yml` *(merges last)* · B49 `docs/manual.md` · B50 `README.md`

### Parity waves (P29 §6 — new files only, via v1 extension hooks; v1 files are not re-owned)
- **Wave A (B51–B62)** Lighting/materials/env: `texture.f90`, `lighting.f90`, `shadow.f90`, `fog.f90`, `tonemapping.f90`, `material_pbr.f90`, `ext_materials.py`, `ext_lights_env.py`, `f3d-pbr.js`, `f3d-env.js`, Wave-A parity tests, lighting showcase example.
- **Wave B (B63–B74)** Assets/picking/2D-in-3D/particles: `ext_gltf.py`, `gltf_loader.f90`, `raycast.f90`, `f3d-raycast.js`, `sprite.f90`, `text_render.f90`, `f3d-sprites-text.js`, `ext_sprites_text.py`, `particles.f90`, `f3d-particles.js`, `ext_particles.py`, Wave-B parity tests.
- **Wave C (B75–B84)** Post/cameras/instancing: `postprocess.f90`, `f3d-post.js`, `ext_post.py`, `camera_ortho.f90`, `f3d-ortho.js`, `ext_cameras.py`, `instancing.f90`, `f3d-instanced.js`, Wave-C parity tests, post-ortho example.
- **Continuous (B85–B92 + B93+):** parity-matrix generator (B85), coverage/stop-rule test (B86), remaining geometries, skinning/morph, WebGL2, custom shaders, XR, ecosystem loaders — minted per uncovered matrix row until 100 %.

---

## 5. Honest “greater than Three/Pixi” claims (P01, P02, P23 — the only claims allowed)

**Allowed (measurable, will be measured by P23 scripts before publishing):**
1. **Fewer lines:** median Three.js standalone task ≈ 49 lines (41–75, P01 hand-counted, ±20 %); `.f3d` contract = each task ≤ ⅓, rotating cube ≤ 3 (vs 23 counted), OBJ ≤ 2, shadows ≤ 1, **loop + resize = 0 lines**.
2. **Fewer concepts:** one object line replaces Geometry+Material+Mesh+`scene.add()`; one scene file replaces stage+renderer seams (Pixi).
3. **Smaller runtime:** JS player ≤ 15,360 B minified, CI-enforced — ~40× smaller than Three.js full build *(exact ratio only after P23 measures pinned files)*.
4. **Zero-config:** defaults for camera, light, size, background, framing — an empty-ish file renders a good scene; Three/Pixi render black/nothing by default.
5. **No silent failures:** missing camera, bad colour, missing asset = friendly compile errors (P08), not a black canvas.
6. **Native deterministic render:** same `.f3d` + same `t` ⇒ byte-identical PPM, offline, no browser/GPU/JS — a capability neither Three (GPU/WebGL) nor Pixi core offers. Determinism is the claim; **speed vs GPU is NOT-COMPARABLE and will never be marketed as an FPS win.**
7. **Compile-time checks:** assets, ranges, limits validated before anything runs (P26).

**Banned claims:** any FPS/render-speed win over GPU WebGL; “Pixi can’t do 3D” (false since `@pixi/3d` beta); any bundle/ratio number not produced by the committed P23 counter on pinned versions; feature parity for any matrix row not `Done-verified`.

---

## 6. Build order & verification gates (P29 § phases, P18, P19, P30)

**Build order:** Phase 0 Contracts freeze (B02, B08, B19, B38, B43 — IR + error table + Fortran APIs signed off; *no seat codes against unfrozen contracts*) → Phase 1 Compiler front end ∥ Fortran core → Phase 2 Optimise + emit → Phase 3 Fortran back end (`scene.f90`→`renderer`→`main`; renderer never `use`s scene — no cycle) → Phase 4 CLI + runtime → Phase 5 Tests/examples fill-out → Phase 6 Integration (B47, then B49/B50, **B48 CI last**).
Critical paths: `B08→B09→B13→B28→B42→B47→B48` and `B19→B20→B23→B24→B25→B47`.

**Gates — every wave, no exceptions (a wave starts only on the previous wave’s all-green integration commit; red gates = fix-only work):**
- **G1** `gfortran` build clean (`make`, `-O3 -Wall -Wextra`; `-fcheck=all` is dev-only per P27, removed for release timing).
- **G2** Compiler tests + Fortran tests green (`tests/run_tests.py`; loud SKIP only if gfortran absent).
- **G3** Golden render: baseline cube PPM SHA-256 strict in pinned CI (PSNR ≥ 60 dB portable tier); goldens blessed by a human only (P18).
- **G4** Error goldens: verbatim stderr + exit code for every E/W code exercised.
- **G5** Parity: every feature shipped in that wave has its §3 matrix test in the *same* wave; B86 coverage % is reported at each wave close.
- Plus: JS size ≤ 15,360 B (G-size, in CI), determinism (build twice → identical sha256), no-clobber + fuzz no-crash sweep (P26).

**Performance (P27, measure-first):** baseline harness before any claim; then flags → culling → edge-function rasterizer → SoA → OpenMP screen-tiling (bit-identical at any thread count). Targets are per-slice ranges only, never multiplied into a headline.

---

## 7. The cut line — revised under the expansion

| Bucket | Contents |
|---|---|
| **v1 MUST (Milestone 1)** | DSL core + diagnostics, all 7 primitives, flat+groups, Basic/Lambert materials, simple animation, compiler → Fortran/JSON/JS/HTML, native PPM render, WebGL viewer + orbit, `f3dc` CLI, tests, CI. Ship gate: G1–G5 green + 3-line cube contract. |
| **v1 SHOULD (may slip to Wave 2, named consequence each)** | OBJ subset, Phong, point lights, blob shadow, repeat/grid, PNG-via-converter, `doctor`, advanced optimisations (P28). |
| **Wave 2** | Textures/UV, glTF, full keyframes, real shadow maps, spot lights, fog, tone mapping, PBR/Standard, raycasting, sprites, text, particles (core), MTL/smooth normals, native PNG, fly camera. |
| **Wave 3+ / Continuous** | Post/filters, ortho, true instancing, remaining geometries, skinning/morph, custom shaders, WebGL2, multi-scene, XR, ecosystem loaders — **until §3 = 100 % Done-verified.** |
| **Won’t** | **Nothing in the parity matrix.** Only *claims* are refused: unmeasured FPS/parity claims and silent fakes (P28 §8). |

## 8. Index of the 30 plans
P01 Three.js pain census · P02 PixiJS 3D limits · P03 DSL grammar · P04 Compiler pipeline · P05 Fortran gaps · P06 JS runtime · P07 Optimisation passes · P08 Error UX · P09 Animation/timeline · P10 Materials/lighting · P11 Primitives · P12 Scene graph · P13 Camera/input · P14 Texture/UV · P15 OBJ/glTF · P16 Multi-object/instancing · P17 Render targets · P18 Testing · P19 CI · P20 CLI UX · P21 Examples gallery · P22 Docs/tutorial · P23 Benchmarks (honest) · P24 Accessibility/defaults · P25 Migration/interop · P26 Security/robustness · P27 Performance · P28 Scope/waves · P29 Build-swarm layout (B01–B92+) · P30 Risk/integration

*Next step (not in this planning phase): the 50-agent build swarm, B01–B50, in the Phase 0–6 order above. No `src/` was edited in planning. Nothing was pushed to GitHub.*
