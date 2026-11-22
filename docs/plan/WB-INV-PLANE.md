# WB-INV-PLANE — Investigation: lone large plane renders zero pixels (Wave B seat B98)

**Verdict (root cause, one line):** There are *two* coupled defects — (D1) the
engine's screen-space winding cull keeps only back faces (NDC-clockwise), so a
horizontal plane's front face viewed from above is culled even when its
projection is perfectly sane; and (D2) there is no clip-space clipping anywhere,
so once a plane vertex crosses behind the camera the unconditional `w` divide
flips its NDC, flips the winding sign, and the culled plane suddenly "renders"
as a distorted artifact — B62's "size 16 worked" was that artifact, not the
plane.

All renders were produced in `/tmp/wb98` with the stock engine (`make`,
`bin/engine3d`) from `.f3d` scenes compiled with `tools/f3dc/f3dc.py build`.
No source or test file was modified.

---

## 1. Reproduction — size × camera pass/fail table (legacy path)

Scenes: a lone `plane ground gray at <pos> size <S> rotate 0 0 0`, 640×480,
fov 60, near 0.1, far 100. (`rotate 0 0 0` is pinned explicitly: f3dc's
desugar injects the demo pose (20°, 35°, 0°) into a lone object that omits
rotation — see `tools/f3dc/desugar.py`, `DEMO_POSE` — which would tilt the
plane and confound the test. In the multi-object lighting showcase the plane
gets rotation (0,0,0), so the pinned scenes match showcase geometry.)

Cameras:

| ID | Camera | Plane at |
|---|---|---|
| A_default | at (3, 2.5, 4) look (0, 0, 0) — engine/compiler default | (0, 0, 0) |
| B_showcase | at (5, 3, 7) look (0, −1, 0) — `examples/lighting-showcase.f3d` | (0, −2, 0) |
| C_low | at (0, 0.6, 4) look (0, 0, 0) — low, near-ground | (0, 0, 0) |

Non-background pixels (background = (20, 20, 25); frame = 307,200 px),
counted with a Python-stdlib PPM reader:

| size | A_default | B_showcase | C_low |
|---:|---:|---:|---:|
| 4  | 0 | 0 | 0 |
| 8  | 0 | 0 | 0 |
| 12 | 67,889 | 0 | 10,173 |
| 15 | 58,391 | **0** | 9,306 |
| 16 | 55,804 | **83,062** | 8,949 |
| 20 | 47,169 | 71,928 | 7,854 |
| 40 | 24,927 | 40,330 | 4,812 |

Findings from the table alone:

- **B62 reproduced exactly:** at the showcase camera, sizes ≤ 15 render
  **zero** pixels and size 16 "works".
- The failure is **not** showcase-specific and **not** large-plane-specific:
  sizes 4 and 8 render zero at *all three* cameras.
- Every non-zero count **decreases as the plane grows** (A: 67,889 → 24,927
  from size 12 → 40). A correctly rendered ground plane must do the opposite.
  The "passing" renders are therefore not correct renders of the plane —
  §2 shows they are flipped-winding artifacts, and the true visible area is
  zero in *every* row of this table.

**Env path (`framebuffer_render_mesh_env`) fails identically.** Re-running
with `material standard` (which sets `Scene%has_env` and routes through the
env rasteriser) gives byte-identical pixel counts: B 15 → 0, B 16 → 83,062,
A 8 → 0, A 12 → 67,889. Both rasterisers share the same projection, cull and
depth code shape (`src/renderer.f90`), so this is expected — but it is now
measured, not assumed.

---

## 2. Mechanism proof (Python replication of the engine math)

The replication implements, line for line: `create_plane` vertices
(`src/mesh.f90`: a=(−h,0,−h), b=(h,0,−h), c=(h,0,h), d=(−h,0,h); triangles
[a,c,b] and [a,d,c]), `mat4_look_at` / `mat4_perspective` /
`mat4_transform_vec3` (`src/math_3d.f90`, including the unconditional divide
by `w` for points), and the renderer's screen mapping
`sx = int((ndc_x+1)·0.5·W)`, `sy = int((1−(ndc_y+1)·0.5)·H)` plus the winding
test `(sx2−sx1)(sy3−sy1) − (sy2−sy1)(sx3−sx1) ≤ 0 → skip`
(`src/renderer.f90`, `framebuffer_render_mesh_mat`).

**Replication fidelity:** for every "passing" case the replica's
barycentric + depth-gate pixel count reproduces the engine's count to
within 1 px (the shared-edge pixel, decided by the z-buffer):
B16: replica 46,492 + 36,571 = 83,063 vs engine 83,062;
A12: 38,307 + 29,583 = 67,890 vs 67,889; A40: 14,749 + 10,179 = 24,928 vs
24,927. The mechanism below is therefore the engine's actual behaviour, not
a model of it.

### 2.1 Failing case — B_showcase, size 15 (engine: 0 px)

| vertex | view-space z | clip w | NDC (x, y, z) | screen (sx, sy) |
|---|---|---:|---|---|
| a (−7.5,−2,−7.5) | −19.395 | **+19.395** | (−0.117, 0.313, 0.992) | (282, 164) |
| b (7.5,−2,−7.5) | −11.490 | **+11.490** | (1.183, −0.026, 0.985) | (698, 246) |
| c (7.5,−2,7.5) | −0.422 | **+0.422** | (5.372, −21.846, 0.527) | (2039, 5483) |
| d (−7.5,−2,7.5) | −8.327 | **+8.327** | (−1.632, −0.342, 0.978) | (−202, 321) |

All four vertices are **in front of the camera (every w > 0)**; nothing is
behind the camera and nothing crosses the near plane (closest view depth
0.422 > near 0.1). Yet:

- tri [a,c,b]: winding cross = **−2,068,630 → culled**
- tri [a,d,c]: winding cross = **−2,850,245 → culled**

**The step that kills the triangles is the winding cull, full stop.** The
plane's triangles are counter-clockwise in NDC (y-up) when seen from above —
i.e. they are the *front* face (normal +Y, camera above) — and the renderer's
convention (keep screen cross > 0, with `sy` y-flipped) keeps only
NDC-clockwise, i.e. *back*, faces. This is the same v1 convention the Wave A
report logged as "far-side visible faces": a closed cube still shows its
far-side faces, but a plane has no far side — its only 2 triangles are the
front face, so from above it can never render. The same all-in-front cull
kills A size 8 (cross −712,189 / −918,521, all w > 0) and C size 8
(−1,162,830 / −104,688,324, all w > 0).

**Control experiment (proves D1, not a projection bug):** the identical
plane viewed from *below* — camera (3, −2.5, 4) look (0,0,0), size 8, all
vertices in front — renders **192,400 px**. From below the same triangles
are NDC-clockwise, pass the cull, and rasterise normally. From below at
size 16 it renders 0 again, because a vertex then crosses behind the
camera and the flip of §2.2 culls it — the mirror image of the from-above
behaviour.

### 2.2 "Passing" case — B_showcase, size 16 (engine: 83,062 px of artifact)

Only vertex c changes material
...[truncated 6858 chars]