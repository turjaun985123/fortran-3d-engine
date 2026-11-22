# Forge3D — Wave A Report (Lighting / Materials / Environment)

Built 2026-11-23 on top of Milestone 1 (`38410ec`) by seats **B51–B62**
plus 2 fix dispatches, with coordinator integration wiring. **14 agent
runs total. Nothing pushed to GitHub.**

## Batch closes (actual counts)

| Batch | Seats | Result |
|---|---|---|
| 1 | B51–B60 (Fortran modules, compiler extensions, JS sidecars) | 10/10 |
| 2 | B61 (parity tests), B62 (lighting showcase) | 2/2 (cumulative 12) |
| Fixes | B59 owner fix (JS `spotFactor` cos→angle space, Fortran authoritative); B58-file fix (shadow clause size, fresh agent — original seat session had closed) | 2/2 |

Phase-0-style API contracts for the wave (Light3/LightSet, MaterialPBR,
TextureImage/prim_uv, ShadowMap, fog/tonemap pass signatures, the
`objmat` / punctual-light / env `.scene` line formats, ext_* Python
APIs) were frozen in the coordinator's briefs before Batch 1.

## What each seat delivered

- **B51** `src/texture.f90` — PPM P3/P6 loader, nearest sampling with
  REPEAT wrap (unloaded = magenta debug colour), frozen per-primitive
  UV contract (`prim_uv`; +Z cube face: u→+x, v→+y, v=1 top). 62/62.
- **B52** `src/lighting.f90` — Light3/LightSet (directional/point/
  spot/ambient), Three-style attenuation (physical decay + smooth
  distance cutoff), spot cone with penumbra, `shade_rgb` multi-light
  kernel. Single-directional case reproduces the legacy
  `0.25 + 0.75·diffuse` formula **exactly** (diffuse weighted by
  (1−ambient); documented in the module). 43/43 against the real B56.
- **B53** `src/shadow.f90` — real shadow maps: depth rendered from the
  light POV with the renderer's own winding/barycentric conventions,
  hard factor + 3×3 PCF (`shadow_factor_pcf`) for `shadow: soft`. 27/27.
- **B54** `src/fog.f90` — linear + exp2 fog (Three formulas), view
  distance reconstructed from the NDC z-buffer, FrameBuffer pass that
  never touches background pixels. 106/106.
- **B55** `src/tonemapping.f90` — ACES (Narkowicz) / Reinhard / none;
  `none` early-returns bit-identical (no float round-trip). 64/64.
- **B56** `src/material_pbr.f90` — MeshStandard-style PBR: GGX
  distribution, Smith-Schlick geometry, Schlick Fresnel, metal F0 =
  base colour; defaults metalness 0 / roughness 1 (Three defaults);
  also serves Phong specular for the lighting kernel. 33/33.
- **B57** `tools/f3dc/ext_materials.py` — `material standard`,
  metalness/roughness/specular/shininess validation, texture rules
  (.ppm only in Wave A), `objmat` line emission. 40 tests OK.
- **B58** `tools/f3dc/ext_lights_env.py` — point/spot extraction +
  validation, fog/tonemap/shadow env semantics, `.scene` line
  emission. 52 tests OK (+6 in the fix below = 58).
- **B59** `runtime/f3d-pbr.js` (7,443 B) — JS mirror of the Fortran
  PBR/lighting formulas. 7 tests OK; fix aligned `spotFactor` to the
  Fortran angle-space smoothstep.
- **B60** `runtime/f3d-env.js` (5,153 B) — JS mirror of fog/tonemap
  formulas (incl. NDC→distance). 4 tests OK.
- **B61** Wave-A parity + e2e tests (below) and the two superseded v1
  tests rewritten (standard/texture are no longer E205/E204).
- **B62** `examples/lighting-showcase.f3d` + `examples/assets/
  checker.ppm` — verified render: **2,061 distinct colours**, spot +
  warm point fill, soft shadows (A/B: 3,567 pixels change vs
  `shadow off`), glossy + metal PBR spheres, checker texture, ACES,
  subtle fog.

## Coordinator integration (files no seat owns)

Seats delivered modules/extensions only; the coordinator wired them
end-to-end (the plan's "new files via extension hooks" rule, plus the
minimal v1-file wiring without which the features would be dead code):

- `Makefile` — 6 new modules in dependency order.
- `src/renderer.f90` — new `framebuffer_render_mesh_env`: per-pixel
  multi-light/PBR shading, barycentric UV texture sampling, per-pixel
  shadow lookup. Legacy entry points untouched.
- `src/scene.f90` — parses `light point/spot`, `fog`, `tonemap`,
  `shadow`, `objmat` lines; builds the unified LightSet; loads
  textures; **resolves `loadobj`/texture paths against the .scene
  file's directory** (see rough-edge fix below).
- `src/main.f90` — scene mode renders through the env path **only**
  when the scene uses Wave A features (`Scene%has_env`); shadow map
  built per frame from the first punctual light (else the
  directional); fog/tonemap post passes after objects.
- `tools/f3dc/parser.py` — light `at/look/distance/decay/angle/
  penumbra`, object `metalness/roughness/specular/shininess`,
  scene-line `fog/tonemap/shadow` clauses.
- `tools/f3dc/validate.py` — `standard` material allowed; E204
  texture reservation replaced by ext_materials validation (bad
  texture type = E501, range errors = E301); point/spot validated
  via ext_lights_env (payload rides as dynamic IRLight attributes —
  the frozen IR dataclass is unchanged); env clauses normalised
  into `IRScene.extensions["env"]`; texture paths resolved against
  the .f3d directory.
- `tools/f3dc/emit_fortran.py` — emits punctual-light lines via
  ext_lights_env, `objmat` lines, env lines; **relative `loadobj`
  paths rewritten to absolute** (resolved from the .f3d dir).

## Gates — run by the coordinator at integration, verbatim verdicts

- **G1 build — PASS.** `make clean && make` (gfortran 13.3,
  `-O3 -Wall -Wextra`): `bin/engine3d` from all 15 modules; 1 warning
  (pre-existing-style `-Wcompare-reals` NaN guard in B56's file).
- **G2 tests — PASS.** `python3 tests/run_tests.py` → `RESULT: PASS`:
  compiler PASS (188 tests, incl. ext_materials 40, ext_lights_env
  58, wavea_parity 16, JS sidecars 11, rewritten validate 12),
  e2e PASS (incl. 9 Wave-A e2e), Fortran PASS (8 test programs:
  v1's 3 + texture 62, lighting 43, shadow 27, fog 106, tonemapping
  64, material_pbr 33 assertions), golden layer SKIP by design
  (no committed golden image; strict hash checked separately, G3).
- **G3 golden render — PASS (strict, NO re-baseline).** Legacy no-arg
  render **and** the 1-line `cube` compiler path both produce
  sha256 `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`,
  byte-identical to v1. Wave A passes activate only for scenes that
  opt in (`has_env`), so no intentional lighting change touches the
  default path. Root `output_render.ppm/.png` (deleted by
  `make clean`'s recipe mid-wave) were restored from HEAD and
  re-verified at the same hash.
- **G4 errors — PASS via suites:** spot without `look` → E302;
  metalness 1.5 → E301; `.png` texture → E501; fog near ≥ far → E302;
  shadow size 100 → validate_env error naming `size`.
- **G5 parity — every Wave A row below has its proof test in THIS
  wave** (see table).
- **G-size — PASS.** Core `runtime/f3d.min.js` 12,460 B ≤ 15,360 B
  (unchanged from v1; core runtime untouched). Wave A sidecars are
  optional add-ons: f3d-pbr.js 7,443 B, f3d-env.js 5,153 B readable.
- **Showcase — PASS.** `f3dc run examples/lighting-showcase.f3d` →
  640×480, non-flat, **2,061 distinct colours** (coordinator re-run
  reproduced B62's count exactly — deterministic).
- **Environment incident (recorded honestly):** mid-wave the
  gfortran binary vanished from the VM (B61 noticed first);
  the coordinator restored it from the apt cache
  (`dpkg -i gfortran-13…deb + libgfortran-13-dev…deb`, 13.3.0) and
  re-verified the full build + golden before proceeding.

## Parity matrix changes (§3 rows → status)

| Row | Feature | Status after Wave A | Proof (same wave) |
|---|---|---|---|
| 11 | MeshStandardMaterial (PBR) | **Done-verified** | `test_material_pbr.f90` 33; parity `TestRow11`; e2e metalness 0 vs 1 renders differ |
| 13 | Point / Spot lights | **Done-verified** | `test_lighting.f90` 43 (attenuation/cone); parity `TestRow13` exact `.scene` lines; e2e near-vs-far attenuation + in/out-of-cone means |
| 14 | Fog (linear/exp2) | **Done-verified** | `test_fog.f90` 106; parity `TestRow14`; e2e fogged object pixels move toward fog colour (679.9 → 405.8) |
| 15 | Textures / UV | **Done-verified** | `test_texture.f90` 62 (test-card orientation contract); parity `TestRow15`; e2e checker card shows both texel colours, ≥4 greys |
| 16 | Shadows (real maps) | **Done-verified** (spot/point + module level; see anomaly note) | `test_shadow.f90` 27 (occluded/lit/PCF-edge); parity `TestRow16` incl. size honoured after fix; e2e soft-vs-off pixel darkening; showcase A/B 3,567 px |
| 25 | Tone mapping / colour space | **Done-verified** | `test_tonemapping.f90` 64; parity `TestRow25`; e2e ACES max pixel 204 vs 255 untonemapped |
| 8/9/10/12 | Basic / Lambert / Phong / ambient+directional | unchanged (v1 Done-verified) | legacy golden G3 |

**Anomaly logged, not hidden:** in B61's probes, a *directional-only*
shadow scene showed zero on/off difference end-to-end, while
spot/point shadows verify at every level. The shadow module itself
passes its directional-style geometry tests (light at (0,5,0) →
origin). Suspect the main.f90 directional shadow placement/frustum
or the plane rasterisation quirk below; queued as a Wave B
investigation item. Row 16's claim rests on the spot/point +
module evidence named above.

## v1 rough edge — loadobj paths: FIXED

Compiler side: `emit_fortran` rewrites relative OBJ paths to
absolute (resolved from the .f3d file's dir); engine side:
`scene.f90` resolves `loadobj`/texture paths against the .scene
file's directory when they don't resolve from the cwd. Evidence:
`examples/multi-object.f3d` (`load "../model.obj"`) now emits
`loadobj imported … /home/hatch/workspace/fortran-3d-engine/model.obj`
and renders 800×600 / 48 distinct colours (v1: 46 with the OBJ
object silently skipped).

## Known quirks carried forward

- **Far-side visible faces (v1 convention, unchanged):** the
  screen-space culling shows far-side faces; camera-side point/spot
  lights therefore give ~no diffuse on a lone cube. B61's e2e
  attenuation/spot tests place lights accordingly. `shade_rgb`
  itself is verified correct by direct calls.
- **Large-plane rasterisation:** a lone large plane at some camera
  positions renders zero pixels (B62: plane size ≤15 at the first
  showcase camera; size 16 worked). Pre-existing engine behaviour,
  affects v1 path too; Wave B investigation.
- JS emit (`emit_js`/JSON) carries Wave A lights/materials only in
  the v1 field shape; the complete Wave A shading model on the web
  side is the f3d-pbr.js/f3d-env.js sidecar libraries. The native
  `.scene` path is the complete one.
- `emit_fortran`'s generated program remains frame-0/directional
  only (as in v1, by design).

## Remaining matrix rows by wave (unchanged from MASTER-PLAN §3/§7)

- **Wave B (B63–B74):** rows 19 glTF, 20 raycasting/picking,
  23 sprites, 24 text, 29 2D overlay, 32 particles (core),
  17 full keyframe tracks; + directional-shadow and plane
  investigations above.
- **Wave C (B75–B84):** rows 3 ortho camera, 22 true instancing,
  26 multi-scene, 30 post/filters.
- **Continuous (B85+):** row 7 remaining geometries, skinning/morph,
  custom shaders, WebGL2, XR, loaders; B85 matrix generator +
  B86 coverage/stop-rule still to be built — no coverage % claimed.
