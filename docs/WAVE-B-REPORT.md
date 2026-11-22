# Forge3D — Wave B Report (B63–B74 + investigations + fixes)

Wave B scope per `docs/plan/MASTER-PLAN.md` §3/§6: assets / picking /
2D-in-3D / particles — glTF loading, raycasting, sprites + text,
particles, full keyframe animation, Wave-B parity + e2e tests, a
showcase example, and the two investigations Wave A logged honestly
(directional-light shadows; large-plane rasterisation quirk).

**Verdict: Wave B complete. All gates green (below). Committed locally;
no GitHub push (per standing order).**

## Agent counts (actual runs, parallel ceiling 10)

| Batch | Seats | Runs |
|---|---|---|
| Batch 1 | B63 ext_gltf, B64 gltf_loader, B65 raycast.f90, B66 f3d-raycast.js, B67 sprite.f90, B68 text_render.f90, B69 f3d-sprites-text.js, B70 ext_sprites_text, B71 particles.f90, B72 f3d-particles.js | 10 |
| Batch 2a | B73 ext_particles, B93 keyframe.f90 (minted), B94 ext_keys (minted), B95 f3d-keys.js (minted), B97 directional-shadow investigation, B98 plane investigation | 6 |
| Batch 2b | B74 parity + e2e tests, B96 showcase example | 2 |
| Fix round | JS font alignment, glTF emit shape, text winding, particles winding, glTF winding (compiler), glTF winding (native) | 6 |
| **Total child runs** | | **24** |

Plus coordinator wiring/integration (Makefile, parser/validate/emit,
scene.f90, main.f90, directional-shadow frustum fit, parity-expectation
update for the winding conversion) done by the coordinator directly.

## Parity rows changed (§3 matrix)

| Row | Feature | Status after Wave B | Proving tests |
|---|---|---|---|
| 19 | glTF loading | Done-verified | `test_ext_gltf` 21/21 (incl. new `test_winding_conversion_swaps_v2_and_v3`), `test_gltf_loader` 30/30, parity `TestRow19GlTF` 3/3, e2e `test_row19_gltf_quad_renders_nonflat` |
| 20 | Raycasting / picking | Done-verified | `test_raycast` 40/40 (Möller–Trumbore, eps 1e-9, both windings, nearest-t), `test_f3d_raycast_js` 8/8 cross-checked against the Fortran |
| 23 | Sprites (billboards) | Done-verified | `test_sprite` 30/30 incl. real-renderer visibility from both camera sides (253 px) |
| 24 | Text rendering | Done-verified | `test_text_render` 50/50 incl. real-renderer visibility (269 px); JS↔Fortran font cross-check 43/43 glyphs (`TestRow24FontCrossCheck`) |
| 29 | 2D-in-3D overlay (sprites+text in scene) | Done-verified | e2e `test_rows23_24_29_sprite_and_text_render`; coordinator isolation: text-only scene renders 2,461 px |
| 32 | Particles | Done-verified | `test_particles` 366/366 (deterministic hash contract, JS split-multiply matches Fortran exactly), `test_ext_particles` 29/29, `test_f3d_particles_js` 9/9, e2e determinism (byte-identical re-render); coordinator isolation: particles-only scene renders 660 px |
| 17 | Keyframe animation (full tracks) | Done-verified | `test_keyframe` 40/40, `test_ext_keys` 24/24, `test_f3d_keys_js` 14/14, e2e `test_row17_keys_animation_frames_differ` |
| 16 | Shadow maps — directional | Claim now fully backed (was: spot/point only) | Investigation B97 + coordinator probe + e2e `test_row16_...` proven scene (see below); spot/point backing from Wave A unchanged |

Frozen contracts were preserved: the v1 IR dataclass is unchanged
(Wave B entities ride `IRScene.extensions["waveb"]`, the Wave A `env`
pattern); Python stdlib only throughout.

## Investigation 1 — directional-light shadows (B97): ROOT CAUSE FOUND AND FIXED

Full evidence: `docs/plan/WB-INV-DIRECTIONAL-SHADOW.md`.

- **Root cause: bias-swallowed shadow.** `main.f90` placed the
  directional shadow camera 30 units from the scene with near 0.5 /
  far 80, so the caster→receiver depth delta at the receiver
  (Δz ≈ 0.00135) was smaller than the fixed bias 0.002 in
  `renderer.f90 draw_triangle_env` — the shadow compared as "lit".
  Measured: receiver NDC z 0.981208 vs stored depth 0.979861;
  dz/dd ≈ 0.000978/unit at depth 32 (a spot light at ~9 units has
  Δz ≈ 0.0168, which is why spot shadows verified in Wave A).
  Ruled out with evidence: light-selection fallback (the directional
  position IS used), empty shadow map (1,512 cells filled), env gating.
- **Fix (applied by coordinator in `src/main.f90`):** fit the
  directional shadow frustum to scene bounds — D = R+10,
  near = max(0.5, D−R−5), far = D+R+5, where R is the scene radius
  from object positions + extents. Punctual lights keep 0.5/80.
- **Proof:** coordinator probe with the real modules on the real
  compiled scene — new params give `shadow_factor` 0.0 (shadowed) at
  the receiver where old params give 1.0 (lit); Δz improves to
  0.0145 (7.2× the bias). End-to-end control scene: 322 differing
  pixels shadow-on vs off; shadow-centre pixel (76,68) = (35,35,36)
  on vs (114,114,118) off.
- **Caveat (honest):** on a cube used as ground, the camera-visible
  face is the far-side bottom face (normal −Y, zero diffuse), so a
  shadow cannot be visible there regardless; the proven e2e geometry
  uses a plane receiver. Row 16's directional claim stands
  Done-verified on the B97 evidence + probe + e2e.

## Investigation 2 — large-plane rasterisation quirk (B98): CHARACTERISED, FIX QUEUED

Full evidence: `docs/plan/WB-INV-PLANE.md` (pass/fail table: plane
sizes 4/8/12/15/16/20/40 × 3 cameras; a Python replica of the engine
math reproduces engine pixel counts to 1 px).

- **Two coupled defects.** (D1) The screen-space winding cull keeps
  only back faces, so a horizontal plane's front face viewed from
  above is culled even with sane projection (the same plane from
  below renders 192,400 px). (D2) There is no clip-space clipping
  anywhere: `mat4_transform_vec3` divides by w unconditionally, so a
  vertex behind the camera flips NDC/winding and the plane "renders"
  as a distorted artifact — B62's "size 16 worked" observation was
  this artifact, and non-zero pixel counts *decrease* with plane
  size. Integer overflow was ruled out for the tested cases. The
  same D2 pattern exists in `shadow.f90`.
- **Not fixed in Wave B:** the fix (Sutherland–Hodgman clip-space
  clipping in the renderer mat+env paths and `shadow_add_mesh`, plus
  double-sided `create_plane`) lives in v1-owned renderer/mesh
  files, outside Wave B's file scope. It is specified precisely in
  the investigation doc with acceptance checks and is queued as
  **Wave C housekeeping**. Golden-safety argument (in the doc):
  clip-only-when-crossing is a no-op for fully-inside triangles and
  the golden scenes contain no plane. Note: double-siding changes
  the plane triangle count 2→4 (MASTER-PLAN P11 says 2) — flag
  when scheduling.

## Defects found by Wave B's own tests and fixed in-wave (G5 working as intended)

B74's parity/e2e layer caught four real defects; all fixed by the
owning seats and re-verified:

1. **JS font mismatch** — `f3d-sprites-text.js` glyph masks disagreed
   with the authoritative Fortran font at 9 of 43 glyphs
   (C, G, I, N, W, 3, 6, 7, 9). Corrected mechanically from the
   Fortran masks; cross-check now 43/43.
2. **glTF triangles silently dropped at emit** — `emit_fortran`
   didn't recognise ext_gltf's `(colour, [v1,v2,v3])` shape, so glTF
   loads compiled to `tris NAME 0`. Fixed in `_tri_parts`; compiler
   layer 349 tests green.
3. **Text and particles invisible in the real renderer** — glyph and
   particle quad windings failed the engine's screen-space winding
   cull from the front (both seats had authored winding from
   geometry reasoning; the sprite seat's renderer-visibility test
   was the proven reference). Windings flipped to the sprite-proven
   order; both modules gained real-renderer visibility tests
   (text 269 px, particles 73 colour px; old winding re-verified
   at 0 px). Coordinator isolation scenes: text-only 2,461 px,
   particles-only 660 px (both were 0).
4. **glTF front faces culled** — standard glTF CCW winding renders
   0 px in this engine (coordinator probe: flipped winding → 3,069
   px). Both ingest paths now convert winding (v1,v3,v2) at load:
   `ext_gltf.py` and `gltf_loader.f90`, documented in both, with
   tests updated/added. This is the same engine winding convention
   all native primitives use; the global cull itself is B98's D1,
   queued for Wave C.

Also fixed by the coordinator during wiring: parser node-name table
missing the five new statement names (E103), a validate.py substring
classification trap (`"keys" in "keystmt"`), and E402 false "empty
scene" for Wave-B-only scenes.

## Gates — exactly as run (final run, after all fixes)

- `make clean && make` — **PASS** (21 modules, clean link of
  `bin/engine3d`).
- `python3 tests/run_tests.py` — **RESULT: PASS**: compiler PASS
  (incl. Wave B parity 13/13), e2e PASS (incl. Wave B e2e 7/7 and
  both golden regressions), Fortran PASS (14 test programs, incl.
  the six new Wave B programs), golden layer SKIP by design (no
  golden image committed; the strict check below is the binding one).
- **Strict golden — PASS, no re-baseline:** legacy no-arg engine run
  sha256 = `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`;
  1-line `cube` program via f3dc sha256 = the same value.
- Showcase (`examples/waveb-showcase.f3d`, run post-fix): 30 frames,
  frame 0 has 23 distinct colours — ground, keyframed/spinning
  cube+sphere, glTF pyramid gold (63,48,16) 2,027 px, sprite 751 px,
  text 869 px, particles 432 px.

## JS sizes (raw bytes)

Core `runtime/f3d.js` untouched by Wave B (15,600 B raw; 12,460 B
minified vs the 15,360 B minified budget from Wave A — unchanged).
New sidecars: `f3d-raycast.js` 4,347 B · `f3d-sprites-text.js`
6,198 B · `f3d-particles.js` 5,392 B · `f3d-keys.js` 3,512 B.
(Wave A sidecars unchanged: `f3d-pbr.js` 7,443 B, `f3d-env.js` 5,153 B.)

## Remaining matrix rows

- **Wave C (B75–B84):** row 3 orthographic camera, row 22 true
  instancing, row 26 multi-scene/levels, row 30 post-processing/
  filters — plus the B98 housekeeping item (clip-space clipping +
  double-sided plane; see Investigation 2, with its P11 tri-count
  flag).
- **Continuous (B85+):** row 7 remaining geometries, skinning/morph
  targets, custom shaders, WebGL2 backend, XR. The B85 matrix
  generator and B86 coverage test are still unbuilt — no coverage
  percentage is claimed until they exist.
