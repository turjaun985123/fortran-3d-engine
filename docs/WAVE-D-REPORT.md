# Forge3D — Wave D Report (row 7 geometry series, seats D01–D12)

Wave D scope per `docs/WAVE-C-REPORT.md` launch spec and
`docs/plan/MASTER-PLAN.md` §3 row 7: every remaining Three.js
geometry as a native Fortran primitive + `.f3d` keyword + JS
runtime support + proving tests in-wave, then the B85/B86
coverage recomputation.

**Verdict: Wave D complete. Row 7 Done-verified — the §3 core
matrix is now 36/36 = 100.0 %. All gates green (below).
Committed locally; no GitHub push. Strict golden byte-identical
— NO re-baseline.**

## Agent counts (actual runs, parallel ceiling 10)

| Batch | Seats | Runs |
|---|---|---|
| Batch 1 | D01 geo_flat, D02 geo_capsule, D03 geo_tube, D04 geo_lathe, D05 geo_extrude, D06 geo_poly, D07 geo_torusknot, D08 compiler ext_geometry, D09 JS sidecar, D10 showcase + manual | 10 |
| Batch 2 | D11 parity + e2e, D12 matrix/coverage | 2 |
| **Total child runs** | | **12** |

Plus coordinator wiring: Makefile (7 new module objects +
scene deps), `src/scene.f90` (geo `use` lines, `SceneObject.pts`
point list from object-line tokens 21+, 11 new dispatch cases in
`scene_build_object_mesh`, `pts` cleanup in `scene_free` and the
object case, `MAX_TOKENS` 40 → 256 so long tube paths / lathe
profiles are not silently truncated).

Architecture note: builders live in **new per-family modules**
(`geo_flat_3d`, `geo_capsule_3d`, `geo_tube_3d`, `geo_lathe_3d`,
`geo_extrude_3d`, `geo_poly_3d`, `geo_torusknot_3d`) instead of
extending `mesh.f90` — one owner per file, zero edit collisions;
`mesh.f90` itself is untouched this wave.

## The 11 new primitives (.f3d surface: one word + obvious props)

| Keyword | Easy form | Fortran builder | Exact tri formula |
|---|---|---|---|
| circle | `circle radius 1` | create_circle | 2·seg (XZ disc, double-sided) |
| ring | `ring inner 0.5 outer 1` | create_ring | 4·seg (XZ annulus, double-sided) |
| capsule | `capsule radius 0.5 height 2` | create_capsule | 2·seg + 2·seg·(2·hr−1), hr=seg/4, seg rounded up to a multiple of 4 |
| tube | `tube radius 0.2 path 0,0,0 1,1,0 2,0,0` | create_tube | (n−1)·seg·2 + 2·seg (parallel-transport sweep, fan caps) |
| lathe | `lathe points 0,0 0.6,0.2 0.6,1 0,1.2` | create_lathe | (n−1)·seg·2 |
| extrude | `extrude shape 0,0 1,0 1,1 0,1 extrude_depth 0.5` | create_extrude | 4n−4 (fan caps, winding-normalised) |
| tetrahedron | `tetrahedron radius 1` | create_tetrahedron | 4 |
| octahedron | `octahedron radius 1` | create_octahedron | 8 |
| icosahedron | `icosahedron radius 1` | create_icosahedron | 20 |
| dodecahedron | `dodecahedron radius 1` | create_dodecahedron | 36 (12 pentagons × 3) |
| torusknot | `torusknot radius 1` | create_torusknot | seg·tseg·2, (p,q)=(2,3) |

Compiler contracts (D08): the `.scene` object line stays the
frozen 20 tokens (ring SIZE=inner/RADIUS=outer, torusknot
SIZE=tube, extrude HEIGHT=depth); tube/lathe/extrude point lists
ride as tokens 21+. `validate._estimate_triangles` matches the
Fortran counts exactly for every family (asserted in parity).
Direct-Fortran emit gained all 11 create-calls with per-scene
`use` lines only for the geo modules a scene actually uses.

Two naming findings, resolved in-wave:
- **`extrude_depth` is the canonical depth prop** — `depth` was
  already a generic object prop, so it could not be taken;
  `depth` is still honoured as an alias on extrude lines
  (parity-tested: `depth 0.9` lands in HEIGHT).
- **`ring` collided with the repeat word** — disambiguated by
  lookahead: `ring 4 sphere …` stays the repeat statement,
  anything else is the ring primitive (regression-tested both
  ways; the collision had also silently dropped ring objects in
  `validate._classify`, fixed).

Errors: no new codes — E301 for geometry validation (too few
points, negative lathe radius, unknown geometry prop, ring
inner ≥ outer, non-positive dims), E102 malformed point
groupings, E103 unknown words.

## Per-geometry test evidence

Fortran test programs (all compiled + run in the suite's
Fortran layer, 26 programs total, was 19):

| Family | Test program | Result |
|---|---|---|
| circle + ring | test_geo_flat | PASS 27/27 |
| capsule | test_geo_capsule | PASS 7/7 (+ scratch outward-normal check 256/256) |
| tube | test_geo_tube | PASS 234/234 |
| lathe | test_geo_lathe | PASS 17/17 |
| extrude | test_geo_extrude | PASS 82/82 |
| polyhedra (×4) | test_geo_poly | PASS 350/350 (counts, circumradius, outward winding, edge uniformity) |
| torusknot | test_geo_torusknot | PASS 14/14 (parallel transport + holonomy distributed so the seam closes) |

Compiler: `test_ext_geometry.py` 28 tests; full compiler suite
506 tests OK at D08 hand-in (grew further with D11/D12 files —
see gates). JS: `test_f3d_geo_js.py` 11 tests — all 11 builders
exist with counts identical to Fortran, no NaN/degenerate
output, polyhedra at circumradius with outward winding.

Rendered pixel proof per family (D11 e2e, single-object scenes
through the real f3dc → engine path; colour-family pixels):

| Prim | Family px | Distinct colours |
|---|---|---|
| circle | 4,826 | 37 |
| ring | 3,664 | 38 |
| capsule | 2,613 | 22 |
| tube | 1,781 | 6 |
| lathe | 1,614 | 5 |
| extrude | 1,563 | 3 |
| tetrahedron | 2,086 | 3 |
| octahedron | 2,781 | 3 |
| icosahedron | 4,036 | 3 |
| dodecahedron | 4,192 | 4 |
| torusknot | 6,152 | 75 |

All > 300 family px, ≥ 3 distinct colours, no thresholds
weakened. (Circle/ring lie in XZ facing +Y: their scenes rotate
90° to face the camera and use a vignette filter for a shading
gradient — a flat disc has a single face normal; the asserted
metric is the colour-family count, as specified.) Showcase
`examples/geometries.f3d` (all 11 prims, spread two rows):
165 distinct colours, 14 dominant colours ≥ 200 px, 17,970
non-bg px, deterministic (two runs → identical sha256).

Parity (D11, `TestRow07Geometries` 15 tests): per-prim `.scene`
dims mapping asserted token-for-token (incl. trailing point
tokens), tri estimates cross-checked compiler vs formula,
ring-repeat regression both directions.

## Row 7 dispositions (everything the matrix row names)

- **Text…** — Three.js TextGeometry is extruded font geometry;
  Forge3D covers text via the Wave B `text` system (flat
  camera-facing text meshes, row for sprites/text). Extruded
  font outlines are **dispositioned, not built**: no font-outline
  source exists in the stdlib-only toolchain; recorded in
  row 7's evidence string in `docs/parity-status.json`.
- **ShapeGeometry** — covered by `extrude` (a shape footprint
  with depth → 0-ish extrusion is the same surface; the flat
  footprint itself is `extrude`'s cap).
- **EdgesGeometry / WireframeGeometry** — helper geometries
  that re-derive edges from another geometry; in Forge3D
  wireframe is a render-mode concern, not a geometry, and no
  `.f3d` wireframe mode exists yet — **dispositioned** in the
  row 7 evidence; building them as mesh duplicates would fake
  parity.
- **Capsule** — named in the launch order though not in the
  original row text; built and proven (above).

## Gates — exactly as run (final run, on the committed tree)

- `make clean && make` — **PASS** (31 modules incl. 7 new geo
  modules; clean link of `bin/engine3d`).
- `python3 tests/run_tests.py` — **RESULT: PASS**: compiler
  PASS (incl. Wave D parity 15/15, ext_geometry 28, JS geo
  11/11, parity-coverage B86), e2e PASS (incl. Wave D e2e
  13/13), Fortran PASS (26 test programs incl. 7 new geo
  programs), golden layer SKIP by design (strict check below
  is binding).
- **Strict golden — PASS, no re-baseline:** legacy no-arg
  engine run sha256 =
  `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`;
  1-line `cube` via f3dc = same value. (The golden scene is a
  cube; no existing builder was modified this wave.)

## JS sizes (raw bytes)

Core `runtime/f3d.js` **unchanged**: 15,701 B raw, minified
12,486 B vs the 15,360 B budget — within budget. New Wave D
sidecar: `runtime/f3d-geo.js` 15,319 B raw (exposes
`window.Forge3DGeo` and registers into `F3D.builders`,
guarded so it never throws without the core).

## Coverage (B85 generator + B86 test, recomputed this wave)

**§3 core matrix: 36/36 Done-verified = 100.0 %** (was 35/36 =
97.2 %). Including the continuous extras: **36/40 = 90.0 %**
(was 87.5 %). `_baseline_pct` floor 86.1 unchanged — no
regression. B86: 7 tests OK.

**Remaining — the complete list (nothing else is outstanding):**

| ID | Feature | Status |
|---|---|---|
| C2 | Custom shaders | Queued-continuous |
| C1 | Skinning / morph targets | Queued-continuous |
| C3 | WebGL2 backend | Queued-continuous |
| C4 | XR | Queued-continuous |

## Next launch spec — Wave E (ready to go)

Order per the standing plan: **C2 → C1 → C3 → C4**.

- **Wave E = C2 custom shaders.** Pattern to follow (mint seats
  B9x): a `.f3d` `shader` statement giving an object a custom
  fragment rule in the same declarative style (e.g.
  `shader name checker scale 4 color1 red color2 white` from a
  small built-in-but-extensible function set, plus a raw
  expression form if the seat can keep it safe), Fortran
  evaluation in the lighting/material kernel (deterministic,
  per-pixel), JS mirror in a `f3d-shader.js` sidecar, parity
  tests asserting shaded pixel values, error codes for unknown
  shader names/params in the E3xx family. Honesty rule: it is
  "custom shaders" only if user-supplied rules change pixels —
  a renamed built-in does not count.
- Then **C1 skinning/morph** (needs a `morph`/`bones` scene
  concept on top of Wave B keyframes), **C3 WebGL2 backend**
  (sidecar runtime upgrade; core budget re-negotiated openly if
  needed, never silently), **C4 XR last** (needs a live
  browser/device check this VM cannot do — its seat must say
  exactly what remains unverifiable headlessly).
- B86's stop rule stands: waves continue until it reports
  100 % on the with-extras basis too (40/40).
