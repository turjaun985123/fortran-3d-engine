# P07 — Optimization Passes

> Status: planning only. No `src/` changes in this document.
> Goal: an *easy* 3D compiler — a scene description in, an optimized scene /
> lowered mesh out — built on top of the current engine, not a rewrite of it.
> Current baseline (grounding): `src/mesh.f90` is an unindexed triangle soup
> (`Mesh{num_triangles, Triangle{v(3), normal, color(3)}}`, no objects, no
> scene graph, no shared vertices); `src/main.f90` hard-codes one cube, one
> camera, one light, and a fixed model matrix; `src/renderer.f90`
> recomputes `model_view`/`mvp` and per-triangle world normals on every call,
> does backface culling only *after* projection (screen-space signed area
> `<= 0` → `cycle`), has no frustum culling and no clipping (depth is tested
> per-pixel in `draw_triangle`), and `main` also exports `scene.json` /
> `model.obj` — those exports are observable side effects, not waste.

## 1. Principles

1. **Semantics first, speed second.** The reference semantics are the
   unoptimized (`-O0`) pipeline rendered by the existing rasterizer. A pass
   that cannot prove equivalence must emit a *hint* (advisory, re-checked at
   render time), never a deletion.
2. **Hints vs. eliminations are different types in the IR** (§2). Eliminations
   are irreversible in the output; hints are ignorable by the renderer with
   zero visual change.
3. **Every pass is pure, named, ordered, and independently disable-able**
   (`--no-<pass>`, `--opt-level=O0|O1|O2`, `--dump-ir=<stage>`). No pass does
   another pass's job as a side effect.
4. **Floating-point conservatism by default.** Fortran `real64` math in
   `math_3d.f90` is evaluated as written. Folding may replace an expression
   with its value only when all operands are compile-time constants; no
   reassociation, no reciprocal substitution, no fast-math — unless a future
   explicit `--ffast-fold` flag opts in (out of scope here).
5. **Provenance is never lost.** Every IR node keeps `source_id` so a merged,
   baked, or surviving object can be traced back to the authored scene and to
   `scene.json` / `model.obj` export order.

## 2. IR Requirements (precondition for all passes)

Passes operate on a Scene IR, not directly on `Mesh`. Minimum schema:

| Node / field | Requirement | Why passes need it |
|---|---|---|
| `Scene { objects[], cameras[], lights[], exports[] }` | `exports[]` (PPM, JSON, OBJ) are explicit root nodes | Dead-object elimination (§4.5) must not delete what an export emits |
| `Object { id, source_id, mesh_ref, material_ref, transform, flags, bounds }` | One node per authored object (today: the single cube from `main.f90`) | Merge, baking, DOE, and LOD all reason per-object before lowering to soup |
| `Transform { kind: static\|dynamic\|animated, matrix: mat4 \| expr }` | `kind` is mandatory; unknown ⇒ `dynamic` | Baking and folding are legal only for `static` |
| `Expr` tree for scalars/vectors/matrices | Constants tagged `const`, non-constants `runtime`; every node carries its type (`real64`, `vec3`, `mat4`, `int`, `color`) | Constant folding (§4.1) is a lattice walk over this tree |
| `MeshData { vertices[], indices[] \| soup, normals, color_per_face, winding }` | Indexed form preferred; soup (current form) must be convertible losslessly. `winding` and `side: front\|back\|double` explicit | Merge and backface hints depend on winding/side; the current code leaves both implicit |
| `Material { color, side, flat_shading: .true. }` | Colour lifted out of `Triangle%color` into a shared, comparable material record | Merge grouping key; two triangles may merge only under an equal material |
| `Bounds { aabb, sphere(center, radius), valid: logical }` | Every object and merged mesh has conservative bounds (enclose all vertices, padded by `1.0e-9_dp` + one ulp growth on transform) | Frustum hints, LOD screen-size estimates, merge batching |
| `CullHint { frustum: inside\|outside\|intersect\|unknown, backface_culled_possible: logical }` | Optional, default `unknown` / `.false.`; stamped with the camera id + camera version it was computed against | A hint computed for one camera is invalid for any other (§4.3) |
| `LODSet { levels[(mesh_ref, min_proj_px, max_proj_px)], hysteresis }` | Optional; level 0 is always the original mesh | LOD is selection metadata, never a replacement of level 0 |
| `Effect flags { exported, referenced_by_animation, user_visible }` | Set by the front end, only cleared by a proof | DOE safety |

IR verifier (runs before the pipeline, between pass groups, and at exit):
well-formed ids/references, finite coordinates (no NaN/Inf introduced),
`bounds` actually enclose the geometry, material/winding present, hint
camera-version matches. Verifier failure = compile error, not a warning.

## 3. Pass Order

Order is dependency-driven; a later pass may assume all earlier invariants.

| # | Pass | Level | Type | Depends on |
|---|---|---|---|---|
| 0 | IR verify + normalize (lift colours → materials, compute bounds, index soup where lossless) | O1 | enabling | — |
| 1 | Constant folding & propagation (§4.1) | O1 | elimination | 0 |
| 2 | Transform baking for `static` objects (§4.2) | O1 | elimination | 1 (folded matrices), then re-run 1 once (fixpoint, max 2 iterations) |
| 3 | Dead object elimination (§4.5) | O1 | elimination | 0–2 (reachability uses folded visibility/flags) |
| 4 | Static mesh merge (§4.6) | O2 | elimination (draw calls, not geometry) | 2, 3 (bake first so merge is concatenation; dead objects never merged in) |
| 5 | Frustum & backface culling hints (§4.3, §4.4) | O1 | hint only | 4 (bounds of the *merged* meshes are what get tested) |
| 6 | LOD hint generation (§4.7) | O2 | hint only | 4, 5 (projected size reuses bounds + frustum data) |
| 7 | Final verify + stats emit (`--opt-report`) | all | checking | all |

Rationale in one line each: fold before you bake (bake a single folded
matrix, not an expression tree); bake before you merge (merged vertices must
already be in world space); eliminate before you merge (don't spend merge
work on dead objects, and never let merging *resurrect* reachability);
hints last (they describe the final geometry and final bounds, and are
invalidated by any later geometry change — hence no geometry pass after 5).

At `O0` only pass 0 (normalize, no optimization) and 7 run: this is the
golden-reference configuration for all correctness checks in §6.

## 4. The Passes

### 4.1 Constant folding & propagation

- **Scope:** scalar/vector/matrix expressions with all-`const` operands:
  `mat4_mult` chains, `mat4_rotate_*` / `mat4_translation` / `mat4_scale`
  of literals, degree→radian conversion (`angle * PI / 180.0_dp`, as in
  `main.f90` and `camera_update_matrices`), `vec3` arithmetic, colour/intensity
  arithmetic with literal lights, identity-matrix multiplication.
- **Rules:** fold using the *same* `pure` routines from `math_3d.f90`
  semantics (evaluate at compile time in `real64`, same operation order —
  e.g. `mat4_mult`'s `i,j,k` accumulation order is part of the result);
  propagate a folded value only within its defining scope; never fold across
  a `runtime`/`dynamic` operand; never fold `camera` view/projection unless
  the camera is declared `static` *and* the fold is stamped with its version.
- **Forbidden:** reassociation (`(a*b)*c → a*(b*c)`), folding a division by a
  value that is zero/non-finite at run time but not provably so at compile
  time, folding away a call whose result feeds an export's formatting
  (exported numbers must print identically, cf. `F8.3`/`F9.4` formats in
  `export_mesh_json` / `export_mesh_obj`).
- **Check:** folded node count reported; §6 golden render must be bit-identical.

### 4.2 Transform baking

- **Scope:** `Object` with `transform%kind == static`: replace
  `vertices` with `mat4_transform_vec3(matrix, v, .true.)` results and set
  the object transform to identity; normals are *recomputed* from baked
  triangles via `compute_triangle_normal` (as the renderer already does per
  frame), not transformed — this avoids the missing inverse-transpose normal
  matrix problem entirely for flat shading.
- **Rules:** bake at most once per object (idempotence flag); singular or
  non-finite folded matrix ⇒ do not bake, keep the transform, warn;
  negative-determinant (mirroring) matrix ⇒ bake is allowed only if winding
  is flipped in the same step and `side`/culling metadata updated, otherwise
  refuse — mirroring silently inverts the renderer's screen-space cull test;
  baked bounds recomputed from baked vertices, never transformed loosely.
- **Payoff measured:** removes per-call `mat4_mult` for `model_view`/`mvp`
  composition and per-vertex model transforms for that object in
  `framebuffer_render_mesh`.

### 4.3 Frustum culling hints

- **Scope:** per (merged) mesh × static camera: test `Bounds%aabb`/`sphere`
  against the six frustum planes derived from that camera's view/projection
  (near/far from `Camera%near_plane`/`far_plane`).
- **Rules — hint only:** emit `outside` only on a *conservative* test
  (sphere/AABB fully outside at least one plane, with padding from §2);
  `intersect` and `unknown` both mean "render normally". The renderer may
  skip a mesh on `outside` but must treat the hint as valid only when the
  hint's camera version equals the active camera's version; any camera move,
  FOV, aspect, near, or far change invalidates all hints. **Never** delete
  geometry on a frustum result — an object outside one camera's frustum is
  still exported and may be visible to another camera.
- **Note vs. current code:** the renderer has no clipping, so a partially
  visible triangle is rasterized with per-pixel depth rejection; hints must
  therefore be at mesh granularity only, never per-triangle deletion.

### 4.4 Backface culling hints

- **Scope:** annotate meshes whose material is `side == front` and whose
  winding is uniform with `backface_culled_possible = .true.`, letting the
  renderer keep (or, later, hoist) its existing cull test.
- **Rules — hint only, no triangle removal at compile time:** a triangle's
  facing depends on the camera, so compile-time removal is legal *only* for
  a proven-static camera + static object + closed mesh, and even then the
  default is hint-only. The hint must record the winding convention it
  assumes; it is void for `side == double`, for open meshes, for mirrored
  (negative-determinant) baked transforms that did not flip winding (§4.2),
  and for any mesh whose triangles disagree in winding. The authoritative
  test remains the renderer's existing screen-space signed-area check —
  sign convention (`<= 0` culls) is the reference; a hint that disagrees
  with it on any golden-scene triangle is a pass bug, by definition.
- **Degenerate triangles** (zero area, `abs(denom) < 1.0e-6_dp` in
  `draw_triangle`) are neither culled nor kept by this pass; they are
  reported in the opt-report as degenerate and left to the rasterizer.

### 4.5 Dead object elimination

- **Definition of live:** reachable from a root — a camera-visible object
  set, an `exports[]` node, an animation/reference edge, or an object with
  `user_visible` set. Roots are the front end's declaration, not inferred.
- **Scope for removal:** objects unreachable from all roots; objects with
  provably-`const` `visible == .false.`; empty meshes (0 triangles);
  duplicate objects only if identical in mesh, material, *and* transform
  and neither is separately exported or named in an export.
- **Rules:** never remove on the basis of a frustum/backface hint (§4.3–4.4
  run later and are camera-relative anyway); never remove an object whose
  `source_id` appears in `scene.json`/`model.obj` export lists — in the
  current demo that is the cube itself, so DOE on today's scene must remove
  exactly 0 objects (a required regression check, §6); removal is logged
  with reason (`unreachable` | `invisible-const` | `empty`) in the opt-report.

### 4.6 Static mesh merge

- **Scope:** objects that are `static`, already baked (§4.2), not dead
  (§4.5), and sharing an equal grouping key:
  `(material_ref, side, winding, flat_shading, lod_level=0, export_group)`.
  Output: one `MeshData` per key = concatenation of triangles, summed bounds,
  retained per-triangle `source_id` ranges.
- **Rules:** no merging across materials/colours (today: the cube's six face
  colours are six materials, so a naive merge of the demo cube yields
  up to 6 groups / 12 triangles — triangle count must not change); no merging
  of `dynamic`/`animated` objects, of separately-exported objects, or of
  objects in different LOD sets; vertex welding/deduplication is *not* part
  of this pass (soup in, soup out) — indexing/welding is a separate future
  pass because it changes `scene.json` vertex order and export bytes;
  cap merged size (default 1,000,000 triangles, `--merge-max-tris`) and split
  deterministically in `source_id` order; merge order is stable/sorted so
  output is reproducible byte-for-byte across runs.
- **Payoff measured:** draw-call count (`framebuffer_render_mesh` calls) and
  per-mesh setup (`mvp` composition) — not triangle count, which is invariant.

### 4.7 LOD hints

- **Scope:** for each object with authored (or front-end-supplied) alternate
  meshes, build an `LODSet`; if no alternate exists, emit at most a
  *suggestion* record (`lod_candidate` with projected size) — the compiler
  never generates a decimated mesh in this plan (no geometry invention).
- **Rules — hint only:** selection is a run-time decision by projected
  screen size of `Bounds%sphere` (pixels) against the level thresholds, with
  hysteresis (default ±10%) to prevent oscillation; level 0 (original) is
  mandatory and is what exports emit; LOD choice must never affect
  `scene.json`/`model.obj`; a level whose material/side differs from level 0
  is rejected at verify time; distance-only LOD (ignoring FOV/resolution) is
  forbidden — thresholds are in projected pixels so a resolution or FOV
  change cannot silently change the picture beyond the chosen level's own
  authored difference.
- **Check:** switching levels at a fixed camera must produce a render whose
  difference from level 0 is attributable solely to the authored alternate
  mesh (tested by rendering each level standalone as a golden, §6).

## 5. Pipeline Interface (for implementers)

```
compile:  scene source ─▶ IR ─▶ [verify] ─▶ fold ─▶ bake ─▶ fold* ─▶ doe
          ─▶ merge ─▶ cull-hints ─▶ lod-hints ─▶ [verify] ─▶ lowered scene
          + opt-report.json
flags:    --opt-level=O0|O1|O2   --no-<pass>   --dump-ir=<stage>
          --merge-max-tris=N     --opt-report=<file>
lowering: lowered scene maps 1:1 onto today's types — merged MeshData →
          mesh_3d::Mesh, baked identity transform → mat4_identity(),
          hints → ignored by the current renderer (forward-compatible).
```

`opt-report.json` (one record per pass): `pass, objects_in, objects_out,
triangles_in, triangles_out, nodes_folded, objects_baked, objects_removed[],
meshes_merged_into, hints_emitted, hints_invalidated, warnings[]`.

## 6. Measurable Checks

All checks run on three fixtures: (a) today's demo cube (12 tris, camera at
`(3, 2.5, 4)` → origin, 640×480), (b) a synthetic multi-object static scene
(≥ 50 objects, ≥ 3 materials, 1 dynamic object, 1 invisible object, 1
off-frustum object, 1 mirrored object), (c) an animated/dynamic scene where
*baking and merging must refuse everything*.

| # | Check | Pass/fail criterion |
|---|---|---|
| C1 | Golden render equivalence, `O0` vs `O1` | PPM bytes identical for fixtures (a) and (b); for (c) identical at every sampled frame |
| C2 | Golden export equivalence | `scene.json` and `model.obj` byte-identical under `O0`/`O1`/`O2` on all fixtures |
| C3 | Triangle invariance | `triangles_out == triangles_in` after fold+bake+merge (only DOE may reduce, and only by logged amounts) |
| C4 | DOE precision | Fixture (a): 0 removed. Fixture (b): exactly the planted invisible + unreachable objects removed, each with a logged reason; dynamic/exported objects: 0 removed |
| C5 | Bake correctness | Baked vertex positions match run-time `mat4_transform_vec3` results to `0.0_dp` when the matrix was folded, else ≤ `1.0e-12_dp`; mirrored fixture object is either winding-flipped or unbaked |
| C6 | Merge accounting | Fixture (b): draw calls drop to exactly the number of distinct grouping keys among live static objects; grouping-key audit shows no cross-material merge |
| C7 | Hint soundness (property test) | Over ≥ 1,000 random static cameras on fixture (b): no mesh hinted `outside` renders any pixel in the reference renderer; no triangle's hint disagrees with the renderer's signed-area cull outcome |
| C8 | Hint invalidation | Mutating camera FOV/position invalidates 100% of stamped hints (version mismatch count in opt-report) |
| C9 | LOD discipline | Exports and level-0 renders unchanged with LOD on; each LOD level standalone matches its own golden; hysteresis prevents level flip-flop over a scripted slow camera dolly (≤ 1 switch per threshold crossing) |
| C10 | Idempotence & determinism | Running the pipeline on its own output changes nothing (second opt-report shows 0 folds/bakes/merges/removals); two runs on same input → byte-identical output |
| C11 | Performance (report, not gate, until baseline exists) | Median of ≥ 15 runs, same machine/build flags (`-O3` per `Makefile`): wall time of compile step and of render step, peak objects/triangles, draw calls — recorded in opt-report; first implementation only needs *no regression > 5%* on fixture (a) render time vs. today's binary |
| C12 | Verifier catches corruption | Hand-broken IR (bad bounds, dangling `mesh_ref`, NaN vertex, hint with stale camera version) each fails compilation with the verifier's named error, never a silent pass |

## 7. Non-Goals, Risks, Open Questions

- **Non-goals:** GPU anything; texture/shader optimization; vertex welding,
  decimation, or any geometry invention; animation optimization; changing
  the rasterizer, its cull sign convention, or its shading model.
- **Risk — hint/renderer drift:** if `renderer.f90` later gains real frustum
  culling or clipping, §4.3–4.4 hints must be re-derived against the new
  test, and C7 re-run; hints carry a `renderer_convention_version` for this.
- **Risk — over-eager DOE:** the single most damaging bug class here is
  deleting something an export or a second camera needed; mitigated by
  roots-in-IR (§2), C2, and C4.
- **Risk — FP drift from folding:** mitigated by §1.4 and C1/C5; any future
  fast-fold flag needs its own tolerance-based (not byte-based) goldens.
- **Open questions for the parent plan:** (1) Scene source format — extend
  today's `scene.json` shape or a new DSL? Passes assume only the IR in §2.
  (2) Is there ever more than one camera? Hints/LOD are designed for many;
  DOE roots depend on the answer. (3) Who authors LOD alternates — user or
  a future decimation pass? This plan assumes user/front-end.
- **Suggested implementation slices:** S1 = IR + verifier + fold + bake +
  C1/C5; S2 = DOE + merge + C3/C4/C6; S3 = cull hints + C7/C8; S4 = LOD
  hints + opt-report + C9–C12. Each slice lands with its checks, in order.
