# P05 — Fortran Engine Gaps & Extensions: Scene Reader, Primitives, Materials

> Read-only audit, 2026-11-23. Repo: `~/workspace/fortran-3d-engine`
> Scope: what `src/` changes are needed for (1) a scene file reader,
> (2) more primitives, (3) materials — listed **per existing file**, with
> disjoint ownership so parallel agents never edit the same concern in two places.
> Out of scope for P05 (other plans own them): scene graph/hierarchy, animation,
> input, tests/CI design — interfaces below leave room for them, do not build them.

## 1. Verified current state (grounded in source, not README)

| File | Module / program | What it actually has | Gap driving this plan |
|---|---|---|---|
| `src/math_3d.f90` | `math_3d` | `vec3`, `mat4(4,4)`; `vec3_create/add/sub/scale/dot/cross/norm/normalize`; `mat4_identity/mult/translation/scale/rotate_x/y/z/perspective/look_at/transform_vec3`; `PI`, `dp=real64` | No TRS compose, no axis-angle rotation, no inverse/transpose, no `lerp/reflect/neg`, no degree helper, no validation helpers. Scene/rotation/material code would each reinvent these. |
| `src/mesh.f90` | `mesh_3d` | `Triangle{v(3), normal, color(3) int}`, `Mesh{num_triangles, triangles(:) allocatable}`; **only** `create_cube(m,size)` (12 tris, hard-coded 6-face palette); `compute_triangle_normal`; `export_mesh_json`, `export_mesh_obj` (write-only) | No other primitive; no OBJ/JSON **import**; colour is baked per-triangle, not a material; no `uv`, vertex normals, `material_id`, mesh name, or `free_mesh`; every new primitive would copy cube's allocate+normal+colour loop. |
| `src/camera.f90` | `camera_3d` | `Camera{position,target,up,fov_deg,aspect_ratio,near_plane,far_plane,view_matrix,proj_matrix}`; `camera_init`, `camera_update_matrices` | No validation (fov/near/far/aspect), no setters. Scene reader must not poke fields + duplicate validation — it calls `camera_init` only. |
| `src/renderer.f90` | `renderer_3d` | `FrameBuffer{pixels(3,w,h), z_buffer}`; barycentric `draw_triangle` (private), Z-test `-1<=z<=1`, backface cull by screen winding, Lambert `intensity=0.25+0.75*diffuse` with one `light_dir`; `framebuffer_render_mesh(fb,mesh,model,cam,light_dir)`; PPM `P3` only | Shading constants, single light, and `tri%color` are hard-wired. No material, specular, per-object tint, scene background, or multi-mesh entry point. No near-plane clipping (out-of-NDC tris are culled only by winding/bounds). |
| `src/main.f90` | `program main` | Hard-coded `640x480`, `output_render.ppm`, one cube `size=2.0`, eye `(3,2.5,4)`, rot `35°Y/20°X`, light `(-0.5,-1,-0.7)`; exports `scene.json`+`model.obj` | No CLI args (`get_command_argument` unused), no loop over objects, no cleanup. Note: exported root `scene.json` is the **export format** `{"triangles":[{v,color}]}` — it is *not* a scene description and must not be reused as the input format. |
| `Makefile` | — | Explicit per-object rules, ordered `math→mesh→camera→renderer→main` | Any new module (`material.f90`, `scene.f90`) needs a rule + link order; see §7. No other file may work around this. |

Dependency direction today (preserve it): `math_3d ← mesh_3d, camera_3d ← renderer_3d ← main`. New modules must slot in without cycles (§3).

## 2. Design decisions (fix these before any code)

1. **Scene format = line-based, not full JSON, for v1.** Writing a general JSON
   parser in Fortran is the largest, buggiest possible first step and duplicates
   the JSON *export* problem. v1: a documented `.scene` text format —
   one directive per line, `#` comments, whitespace-separated `key=value`,
   parsed with `read(line,*)`/`iostat` + line-numbered errors. JSON scene
   *import* is a later, separate swap behind the same `scene_load` interface.
2. **Materials are a new module, not a `mesh.f90` growth.** `Triangle%color`
   stays as legacy fallback; new code carries `Triangle%material_id` (index
   into a scene-owned `Material(:)` table, `0` = default). Only `material.f90`
   defines `Material`; only `renderer.f90` interprets it for shading;
   `mesh.f90` only stores the integer id — that split is the disjointness.
3. **Primitives keep the existing signature shape** `create_cube(m, size)`:
   `subroutine create_X(mesh, <dims...>, material_id)` with
   `intent(inout) Mesh`, deallocating first, exact pre-computed triangle count,
   outward winding matching cube's (renderer culls `cross <= 0` in screen space),
   normals via existing `compute_triangle_normal`. No primitive sets colours
   directly any more except the legacy cube palette when `material_id==0`.
4. **No silent failures.** Every new loader/creator returns `ierr` (or
   `logical ok` + `character(*) errmsg` allocatable): bad file, unknown
   directive/primitive/material, non-positive size/segments, duplicate name.
   `main` is the only place that prints the error and `stop 1`s.
5. **Backward compatibility:** no-arg run must reproduce today's cube render
   and `scene.json`/`model.obj` exports byte-for-byte in geometry (palette
   preserved via a built-in default material table replicating cube colours
   is *not* required — keep cube's existing path untouched when no scene file).

### Proposed v1 `.scene` format (owned by `scene.f90` only)

```ini
# example.scene — all units: degrees for angles, world units for lengths
renderer  width=640 height=480 output=output_render.ppm background=25,25,35
camera    pos=3,2.5,4 target=0,0,0 fov=60 near=0.1 far=100
light     dir=-0.5,-1,-0.7 color=255,255,255 intensity=1.0   # repeatable later; v1: exactly 1
material  name=red   ambient=0.25 diffuse=0.75 specular=0.0 shininess=1  color=220,60,60
material  name=shiny ambient=0.20 diffuse=0.60 specular=0.60 shininess=32 color=60,100,240
object    name=ground type=plane    size=10,10        pos=0,-1,0 rot=0,0,0 scale=1,1,1 material=red
object    name=ball   type=sphere   radius=1 segments=24,16 pos=1.5,0.5,0 material=shiny
object    name=box    type=cube     size=2            pos=-1.5,0,0 rot=35,20,0 material=red
object    name=can    type=cylinder radius=0.5 height=2 segments=20 pos=0,0,-2 material=shiny
object    name=import type=obj      file=model.obj    pos=0,0,0 material=red   # if OBJ import lands
```

Rules: unknown `type=`/directive/material name = error with line number;
omitted fields default to identity transform / default material / today's
camera+renderer defaults; names unique; `segments` clamped-or-rejected
(reject: `<3` stacks/slices, non-positive radius/height/size).

## 3. New files (exactly two; everything else is edits to existing files)

| New file | Module | Owns (sole owner) | Depends on | Must NOT contain |
|---|---|---|---|---|
| `src/material.f90` | `material_3d` | `Material` type, `material_default/create/preset`, validation, named preset table (flat colours replicating cube palette + matte/gloss) | `math_3d` only (for `dp`, `vec3` if colour becomes `vec3`) | Geometry, file I/O, shading maths (renderer applies it) |
| `src/scene.f90` | `scene_3d` | `Scene`, `SceneObject`, `Light` types; `scene_load(filename,scene,ierr,errmsg)`, `scene_free`, directive parsing, name→material-index resolution, building each object's `Mesh` by calling mesh primitives, composing its model matrix by calling math helpers | `math_3d`, `mesh_3d`, `camera_3d`, `material_3d` | Rasterisation, shading, CLI handling, primitive geometry maths, JSON parsing |

Suggested `Material` shape (fields renderer needs, nothing more):

```fortran
type :: Material
  character(len=32) :: name = 'default'
  integer  :: color(3)   = [255,255,255]  ! base albedo, same convention as Triangle%color
  real(dp) :: ambient    = 0.25_dp        ! replaces renderer's hard-coded 0.25
  real(dp) :: diffuse    = 0.75_dp        ! replaces hard-coded 0.75
  real(dp) :: specular   = 0.0_dp         ! 0 = today's pure-Lambert look
  real(dp) :: shininess  = 1.0_dp         ! Phong/Blinn exponent, validated >0
end type Material
type :: SceneObject
  character(len=64) :: name;  type(Mesh) :: mesh;  type(mat4) :: model_matrix
  integer :: material_id = 0  ! index into Scene%materials, applied if triangles don't carry one
end type SceneObject
type :: Scene
  type(Camera) :: camera;  type(Light), allocatable :: lights(:)
  type(Material), allocatable :: materials(:);  type(SceneObject), allocatable :: objects(:)
  integer :: width=640, height=480, background(3)=[25,25,35]
  character(len=256) :: output_file='output_render.ppm'
end type Scene
```

## 4. Per-existing-file changes

### 4.1 `src/math_3d.f90` — owner: math only (no I/O, no types from other modules)

Add (all `pure`, exported in the existing `public ::` list style):
- `mat4_compose_trs(pos, rot_deg_xyz, scale_vec) result(m)` — `T * Rz*Ry*Rx * S`,
  the one place scene/main get a model matrix from pos/rot/scale; fixes main's
  current ad-hoc `mat4_mult(rot_y, rot_x)` (note: define/document Euler order).
- `mat4_rotate_axis(axis, angle_rad)`, `deg2rad(deg)`, `mat4_transpose(m)`,
  `mat4_inverse_rigid(m)` (rotation+translation only; document non-rigid = unsupported, needed for normal matrix/view inverse later).
- `vec3_neg(v)`, `vec3_lerp(a,b,t)`, `vec3_reflect(v,n)` (specular in renderer),
  `vec3_component_mul` if material colour becomes float; keep zero-guard style of `vec3_normalize`.
- Acceptance: existing callers compile unchanged; `compose_trs(0,0,1)==identity`.

### 4.2 `src/mesh.f90` — owner: geometry + mesh I/O only

- **Internal builder (private):** `mesh_allocate(m, ntris)`, `mesh_set_tri(m,i,v1,v2,v3,material_id)`
  (computes normal via `compute_triangle_normal`, sets colour from material fallback),
  `free_mesh(m)`. All primitives below are rewritten on it; `create_cube` refactored
  onto it *without changing its 12 triangles, winding, or palette*.
- **`Triangle` extension:** add `integer :: material_id = 0`; optionally
  `real(dp) :: uv(2,3) = 0` — reserve only, no texturing in this plan. Do not remove `color`.
- **New primitives** (validate args, exact counts, outward normals, centred at origin like cube):
  | Subroutine | Params | Triangles | Notes |
  |---|---|---|---|
  | `create_plane(m, w, d, mat)` | width, depth, XZ plane, +Y normal | 2 | Ground for scenes; single-sided (document) |
  | `create_pyramid(m, base, height, mat)` | square base | 6 | Cheap breadth proof |
  | `create_tetrahedron(m, size, mat)` / `create_octahedron` (optional) | size | 4 / 8 | Table-driven vertices/faces |
  | `create_sphere(m, radius, lon, lat, mat)` | `lon>=3, lat>=2` | `lon*lat*2 - 2*lon` approx; poles as fans | Smooth look still flat-shaded (face normals) — state it; vertex normals = future |
  | `create_cylinder(m, radius, height, seg, capped, mat)` | `seg>=3` | side `2*seg` + caps `2*seg` if capped | Open variant for cans/pipes |
  | `create_cone(m, radius, height, seg, capped, mat)` | `seg>=3` | side `seg` + cap `seg` | Shares cylinder's ring helper (private) |
  | `create_torus(m, r_major, r_minor, seg_a, seg_b, mat)` — *stretch, last* | both radii `>0` | `2*seg_a*seg_b` | Only if earlier primitives pass; cut first under time pressure |
  | `create_grid` — skip; `plane` + material colour suffices for v1. |
- **OBJ import:** `load_mesh_obj(m, filename, material_id, ierr, errmsg)` — parse
  `v`/`f` lines only, triangulate polygonal `f` as a fan, support `f a b c` and
  `f a//n`/`a/t/n` index forms, reject negative indices in v1 with a clear error.
  This closes the asymmetry that `export_mesh_obj` exists but nothing can read it back.
  JSON import: **do not add here** (see §2.1).
- Acceptance: each primitive reports expected `num_triangles`, all normals unit-length,
  closed primitives (sphere/cylinder/cone/cube) pass a signed-volume `>0` sanity check.

### 4.3 `src/camera.f90` — owner: camera construction/validation only

- Add `camera_validate(cam, ierr, errmsg)` called from `camera_init`: reject
  `fov_deg ∉ (0,180)`, `near<=0`, `far<=near`, `aspect<=0`, `position==target`.
  `camera_init` gains an optional/error-returning variant rather than changing
  its signature for existing callers (e.g. `camera_init_checked(...,ierr,errmsg)`).
- Add `camera_set_aspect(cam, aspect)` (main/scene use it when scene `width/height`
  differ from camera line) — the only sanctioned way to mutate after init besides
  assigning `position/target` + `camera_update_matrices` (document that pattern).
- No parsing, no orbit/animation/input maths here.

### 4.4 `src/renderer.f90` — owner: rasterisation + shading only

- Replace hard-coded Lambert in `framebuffer_render_mesh`: `intensity` computed
  from a `Material` — `ambient + diffuse*max(0,dot(n,-light))`, plus optional
  Blinn-Phong `specular * max(0,dot(n,half))^shininess` using view dir from
  `cam%position` and `vec3_reflect` from math. `specular=0` must reproduce today's image.
- Signature evolution (keep old one as a thin wrapper for main's legacy path):
  `framebuffer_render_mesh_mat(fb, mesh, model, cam, light_dir, materials)` resolving
  `tri%material_id → materials(id)`, falling back to `tri%color` + default material for `id==0`;
  and `framebuffer_render_scene(fb, scene)` — **but** `renderer` must not `use scene_3d`
  if `scene_3d` uses it (cycle). Resolve by: scene lives *above* renderer —
  `scene.f90`/`main` loop objects and call `render_mesh_mat` per object; there is
  **no** `render_scene` in renderer. Renderer receives `background` via existing
  `framebuffer_clear(fb, r,g,b)` — caller passes `scene%background`.
- `Light`: renderer accepts `light_dir` today; extend to a small local
  `type :: DirLight { vec3 dir; integer color(3); real(dp) intensity }` defined in
  **renderer** (scene converts its parsed light into it) *or* defined in `material.f90` —
  pick one at implementation start; do not define it in both. v1 stays single-light.
- Explicitly deferred here: near-plane clipping, perspective-correct interpolation,
  smooth/vertex normals, textures, P6 PPM — each changes pixels and needs its own plan.
- Acceptance: default-material sphere/cube render with no black faces on lit side;
  gloss preset shows a highlight; Z-buffer/backface behaviour unchanged on the cube.

### 4.5 `src/main.f90` — owner: CLI + orchestration only (no parsing/geometry/shading)

- `get_command_argument(1)` = optional scene path; `command_argument_count()==0`
  → today's hard-coded demo exactly as now (regression anchor).
- With a scene: `scene_load` → `framebuffer_init(fb, scene%width, scene%height)` →
  `framebuffer_clear(fb, scene%background)` → loop `scene%objects` calling
  `framebuffer_render_mesh_mat(fb, obj%mesh, obj%model_matrix, scene%camera, light, scene%materials)`
  → `framebuffer_save_ppm(fb, scene%output_file)` → `scene_free`/`free_mesh` cleanup.
  Exports (`scene.json`/`model.obj`) become per-object or skipped in scene mode — decide
  and print which; do not silently overwrite the input-adjacent files.
- On `ierr /= 0`: print `errmsg` + usage line, `stop 1`. No other logic moves into main.

## 5. Disjoint ownership matrix (who may edit what)

| Concern | Sole owner | Everyone else |
|---|---|---|
| `vec3/mat4` helpers, TRS compose, Euler order | `math_3d.f90` | call only |
| `Material` type, presets, validation | `material.f90` *(new)* | store/pass `material_id` or `Material` values |
| Primitives, `Triangle/Mesh`, OBJ import/export, JSON export | `mesh.f90` | call `create_*`/`load_mesh_obj` |
| Camera validation/setters | `camera.f90` | call `camera_init*` |
| `.scene` format, parsing, `Scene/SceneObject`, dispatch to primitives | `scene.f90` *(new)* | never parse files elsewhere |
| Shading formula, lights-in-renderer, rasteriser, PPM | `renderer.f90` | pass materials/lights in |
| CLI args, object loop, exit codes | `main.f90` | — |
| Build rules/link order for new modules | `Makefile` (integration step, last) | list needed rule, don't hand-compile around it |

Conflict rule: a needed cross-boundary change (e.g. renderer needs a new math
helper) is filed as a request to that file's owner, not edited opportunistically.

## 6. Implementation order & acceptance gate

1. **`material.f90` + `math_3d` helpers** — compiles alone; no pixel change.
2. **`mesh.f90` builder + primitives + OBJ import** — cube output unchanged
   (diff exported `model.obj`/`scene.json` vs. current copies); new primitives pass §4.2 counts/volume.
3. **`camera.f90` validation** — invalid demo values error, valid ones unchanged.
4. **`renderer.f90` material shading** — legacy wrapper reproduces current cube PPM;
   specular preset visibly differs on sphere.
5. **`scene.f90` + `main.f90` CLI + `Makefile`** (`material` after `math`;
   `scene` after `mesh/camera/material`; `renderer` before `main`; link order updated) —
   gate: example scene in §2 renders ≥4 objects of ≥3 primitive types with
   ≥2 materials in one PPM; missing file / unknown type / unknown material /
   bad segments each fail with a line-numbered message and non-zero exit;
   no-arg run still produces the original cube.

## 7. Risks / open questions for the user

- **Format bet:** line-based `.scene` v1 vs. investing immediately in a Fortran
  JSON parser (or an external `jq`/Python pre-converter emitting `.scene`) — recommendation: line-based.
- **Flat shading ceiling:** sphere/cylinder will look faceted because `Triangle`
  carries one face normal and `draw_triangle` interpolates only depth, not normals/colour.
  Materials make this *look intentional*; smooth shading is a renderer+mesh change beyond P05.
- **`scene.json` name collision:** today's export overwrites `scene.json` in CWD;
  scene mode must not clobber a user's input file of a similar name — rename export or gate it.
- Colour space/clamping stays integer `0–255` with renderer's existing `min/max` clamp; no gamma work in P05.
