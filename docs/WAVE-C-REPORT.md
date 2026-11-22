# Forge3D — Wave C Report (B75–B84 + B85/B86 + housekeeping)

Wave C scope per `docs/plan/MASTER-PLAN.md` §3/§6: post-processing /
filters (row 30), orthographic camera (row 3), true instancing
(row 22), multi-scene (row 26) — plus the Wave B housekeeping item
from `docs/plan/WB-INV-PLANE.md` (clip-space clipping D2 + plane
double-siding D1), and the B85 parity-matrix generator + B86
coverage test that §3 governance always called for.

**Verdict: Wave C complete. All gates green (below). Committed
locally; no GitHub push (per standing order). Strict golden
byte-identical — NO re-baseline.**

## Agent counts (actual runs, parallel ceiling 10)

| Batch | Seats | Runs |
|---|---|---|
| Batch 1 | B75 postprocess.f90, B76 f3d-post.js, B77 ext_post, B78 camera_ortho.f90, B79 f3d-ortho.js, B80 ext_cameras, B81 instancing.f90, B82 f3d-instanced.js, B84 examples, HK-M plane double-siding | 10 |
| Batch 2 | HK-R renderer clipping, HK-S shadow clipping, B85 parity generator, B86 coverage test | 4 |
| Batch 3 | B83 parity + e2e tests, B84-FIX showcase composition | 2 |
| **Total child runs** | | **16** |

Plus coordinator wiring/integration (parser `filter`/`instance`
statements + camera `size`, validate Wave C block + plane tri
estimate fix, emit_fortran Wave C lines, scene.f90 `ortho`/`post`/
`instance` lines, main.f90 ortho projection + post chain, Makefile,
runtime/f3d.js plane double-siding, cli.py multi-scene split/build/
run + per-scene output renaming, parity-status data fixes) done by
the coordinator directly.

## Parity rows changed (§3 matrix)

| Row | Feature | Status after Wave C | Proving tests |
|---|---|---|---|
| 30 | Post-processing / filters | Done-verified | `test_postprocess` 46/46, `test_ext_post` 33/33, `test_f3d_post_js` 16/16, parity `TestRow30Post` (chain order, defaults, unknown filter = E301, gamma changes pixels) |
| 3 | Orthographic camera | Done-verified | `test_camera_ortho` 35/35, `test_ext_cameras` 27/27, `test_f3d_ortho_js` 9/9, parity `TestRow03Ortho` (ortho spheres 2,764 vs 2,764 px — exactly equal at different depths; perspective 721 vs 4,041) |
| 22 | True instancing | Done-verified | `test_instancing` 17/17 (shared base + transform list, count preserved), `test_f3d_instanced_js` 12/12, parity `TestRow22Instancing` (base cube 489 px → 1,858 px with 3 instances; unknown source = E201) |
| 26 | Multi-scene / multi-view | Done-verified | Parity `TestRow26MultiScene` + e2e: `examples/multi-scene.f3d` builds/runs two independent outputs (320×240 dark bg (20,20,25); 640×480 light bg (240,240,240)) |

Frozen contracts preserved: v1 IR dataclass unchanged (Wave C rides
`IRScene.extensions["wavec"]`, the Wave A/B pattern); Python stdlib
only throughout.

## Housekeeping — plane / clipping (WB-INV-PLANE D1 + D2): FIXED

Note on sources: `docs/plan/WB-INV-PLANE.md` on disk is truncated
mid-§2.2 (the file itself ends with a truncation marker, 6,247 B);
the operative fix spec was the Wave B report's summary of it.
Implemented exactly that:

- **D1 — plane double-sided (HK-M).** `create_plane` now emits
  4 triangles (front pair unchanged + reversed-winding back pair,
  normals +Y,+Y,−Y,−Y). **Tri-count change 2 → 4 applied
  explicitly, never silently:** `src/mesh.f90` code + comment,
  MASTER-PLAN §1.2 P11 reference ("plane 2" → "plane 4"),
  `tests/fortran/test_math_mesh.f90` assertion, coordinator fixes
  to the two compiler predictors HK-M flagged
  (`validate.py _estimate_triangles` 2·ws·ds → 4·ws·ds,
  `cli.py` fallback 2 → 4), `runtime/f3d.js` plane builder (JS
  parity), and `docs/manual.md` primitive table. Historical
  investigation docs (WB-INV-*, P05/P11/P21 plans, BUILD/WAVE-B
  reports) describe the pre-fix state and were left as-is.
  Proof: lone plane size 8 from above went from **0 px (B98) to
  193,680 px**; B83 regression asserts size 8 → 36,023 and
  size 15 → 58,655 non-bg px (monotonic).
- **D2 — clip-space clipping (HK-R + HK-S).** Sutherland–Hodgman
  clipping in homogeneous clip space (6 planes, attributes
  interpolated) now runs before the perspective divide in both
  renderer paths (`framebuffer_render_mesh_mat`,
  `framebuffer_render_mesh_env`; public `clip_triangle_frustum`,
  `test_clipping` 9/9) and in `shadow.f90`'s depth rasteriser
  (`test_shadow_clipping` 16/16; fully-inside caster depth map
  identical pre/post: 784 cells, centre 0.754385965; crossing
  caster went 0 → 1,284 filled cells). Fully-inside triangles
  take the verbatim original code path in all three places —
  which is why the golden survived (below). Plane pixel counts
  now **increase monotonically** with size at both B98 cameras
  (A: 49,701 → 254,290 for sizes 4 → 40; B: 15,346 → 221,950),
  where the investigation measured decreases and zeros.

## Defects found by Wave C's own process and fixed in-wave

1. **Multi-scene output collision (coordinator).** Both scenes
   rendered to the default `output_render.ppm`, scene 2 silently
   overwriting scene 1. Fixed in cli.py: each scene's outputs are
   renamed to its chunk stem (`multi-scene-multi-scene-one.ppm`,
   `…-two.ppm`); verified distinct sizes/backgrounds.
2. **Showcase composition (B84-FIX).** The post-ortho demo spheres
   sat at the ortho frustum edge (189/216/103 dominant px).
   Recomposed (explicit on-axis camera, spheres spread across the
   frame at depths 8/12/16): **2,237/2,222/2,023 px** (within
   ~10%), 302 distinct colours.
3. **Parity data gaps (B86 cross-check).** `parity-status.json`
   lacked the `_baseline_pct` key and six Done-verified rows
   (8, 9, 18, 27, 28, 36) cited no test. Coordinator added the
   baseline (86.1, the pre-Wave-C §3 coverage) and honest test
   citations from the actual suites; B85's generator was taught
   to skip `_`-prefixed metadata keys. B86 now passes.

## Gates — exactly as run (final run, on the committed tree)

- `make clean && make` — **PASS** (24 modules incl. new
  `postprocess_3d`, `camera_ortho_3d`, `instancing_3d`; clean link
  of `bin/engine3d`).
- `python3 tests/run_tests.py` — **RESULT: PASS**: compiler PASS
  (incl. Wave C parity 13/13 and parity-coverage), e2e PASS
  (incl. Wave C e2e 6/6 and both golden regressions), Fortran PASS
  (19 test programs, incl. new `test_postprocess`,
  `test_camera_ortho`, `test_instancing`, `test_clipping`,
  `test_shadow_clipping`), golden layer SKIP by design (no golden
  image committed; the strict check below is the binding one).
- **Strict golden — PASS, no re-baseline:** legacy no-arg engine
  run sha256 = `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`;
  1-line `cube` via f3dc = same value. The clipping fix did NOT
  change the golden (as predicted: the golden scene is a cube,
  fully inside the frustum, taking the verbatim fast path).
- Showcase (`examples/post-ortho.f3d`): 11 objects (8 + 3
  instances), 302 distinct colours, spheres 2,237/2,222/2,023
  dominant px; deterministic (e2e hash-equality test).

## JS sizes (raw bytes)

Core `runtime/f3d.js` 15,701 B raw; **minified 12,486 B vs the
15,360 B budget — within budget** (grew +101 B raw for the
double-sided plane line). New Wave C sidecars: `f3d-post.js`
5,815 B · `f3d-ortho.js` 3,856 B · `f3d-instanced.js` 11,492 B.
(Wave A/B sidecars unchanged.)

## Coverage and the definitive remaining-rows list (continuous phase, B85+)

Measured by the new B85 generator + B86 coverage test (both built
this wave): **§3 rows 35/36 Done-verified = 97.2 %**; including
the continuous extras, **35/40 = 87.5 %**. `_baseline_pct` floor
recorded at 86.1 (§3 basis) — coverage may not regress.

**Remaining — the complete list (nothing else is outstanding):**

| ID | Feature | Status | Next seat |
|---|---|---|---|
| Row 7 | Remaining geometries (Circle, Ring, Tube, Lathe, Extrude, Text-geometry, …) via `ext_*.py` + `mesh.f90` builders, one geometry per seat with count/normal/golden tests | Queued-continuous | B93+ (mint per geometry) |
| C1 | Skinning / morph targets | Queued-continuous | B93+ |
| C2 | Custom shaders | Queued-continuous | B93+ |
| C3 | WebGL2 backend | Queued-continuous | B93+ |
| C4 | XR | Queued-continuous | B93+ |

**Next launch spec (ready to go):** Wave D = row 7 geometry
series — one seat per geometry family (Circle+Ring, Tube,
Lathe, Extrude, Capsule, Polyhedron set), each following the
established pattern (Fortran builder in mesh.f90 via a minted
seat, compiler `ext_geometry.py`, JS builder mirror, count/
normal/golden tests, matrix row split per geometry in
parity-status.json). After row 7: C2 custom shaders, C1
skinning/morph, C3 WebGL2, C4 XR, in that order (shaders unlock
the most parity value; XR last — it needs a live browser/device
check this VM cannot do). B86's stop rule stands: waves continue
until it reports 100 %.
