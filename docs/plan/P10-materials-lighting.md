# P10 — Materials & Lighting Design

> **Status:** Planning only — no code changed by this document.
> **Repo state audited:** `src/renderer.f90`, `src/mesh.f90`, `src/math_3d.f90`,
> `src/camera.f90`, `src/main.f90`, `scene.json`, `Makefile` (2026-11-23).
> **Goal served:** an *easy* 3D compiler — a beginner writes a short scene file,
> names a material and a couple of lights, and gets a predictable picture.
> Materials/lighting must therefore be **few-knob, forgiving, and honest**:
> every keyword either does what it says or the compiler says it does not.

---

## 0. Verdict in one page

| Decision | v1 ruling |
|---|---|
| Material model | One `Material` type: `color`, `emissive`, `opacity`, `specular`, `shininess`, `shading`. No textures, no PBR (metalness/roughness), no bump — deferred, not faked. |
| Shading modes | `flat` (= today's behaviour), `lambert` (per-vertex/Gouraud diffuse), `phong` (per-pixel Blinn–Phong-lite). Three names, three visibly different costs/results. |
| Lights | One `ambient`, any number (cap **8 total**) of `directional` + `point`. No spotlights in v1. |
| Colour space | **Not** physically correct: colours are treated as linear values in `[0,1]` and clamped to 0–255. No gamma, no tone mapping, no energy conservation in v1 — stated in user docs, not hidden. |
| Opacity | Real but simple: alpha-blended transparent pass, sorted back-to-front, depth-test on, depth-write off. No refraction, no per-pixel sorting, no order-independent transparency. Interpenetrating transparent objects **will** artefact — documented. |
| Shadows | **None in v1. No real shadows are claimed.** Only an explicitly-named fake: `shadow: blob` (a soft dark ellipse/disc on the ground plane under an object). A `shadow: on/soft/real` keyword is **rejected at compile time**, never silently ignored. Shadow maps are the designed v1.1/v2 path (§7). |
| Backwards compatibility | A scene with no `material` and no `light` blocks renders **pixel-identically** to today: legacy defaults reproduce `intensity = 0.25 + 0.75 * diffuse` exactly (§9). This is a golden-image test, not a hope. |
| Fortran work | 2 new modules (`material.f90`, `lighting.f90`), changes to `mesh.f90`, `renderer.f90`, `main.f90` (or its compiler-generated replacement), `Makefile`. No change needed to `math_3d.f90` / `camera.f90` beyond using existing `vec3_*` helpers (§8). |

Non-goals for v1 (say so in the DSL manual, in one list): textures/UVs, PBR,
spotlights, shadow maps, refraction, reflections/environment maps, gamma/tone
mapping, emissive bloom, light cookies, per-object light layers.

---

## 1. Where we start — the audited baseline

Everything below is what the code actually does today; the design extends it,
it does not describe a renderer we wish we had.

### 1.1 Geometry & colour today

- `mesh_3d:Triangle` (`src/mesh.f90`) carries exactly:
  `v(3)` (`vec3`), one face `normal` (`vec3`), and `color(3)` — **integer**
  RGB 0–255, default white `[255,255,255]`.
- There is **no material indirection**: colour lives per-triangle.
  `create_cube` hard-codes six face colours by triangle index.
- There are **no vertex normals**: `Triangle%normal` is a single face normal,
  and the renderer doesn't even use it — `framebuffer_render_mesh` recomputes
  the world-space face normal per triangle via `compute_triangle_normal`.
- There are no UVs, no vertex colours, no alpha anywhere.
- `Mesh` is a flat triangle soup: vertices are duplicated per triangle
  (the cube exports 36 vertices for 8 corners in `model.obj`). This matters
  for smooth shading — see §3.3.

### 1.2 Lighting today

In `framebuffer_render_mesh(fb, target_mesh, model_matrix, cam, light_dir)`
(`src/renderer.f90`):

```fortran
norm_light = vec3_normalize(light_dir)
diffuse    = max(0.0_dp, vec3_dot(normal_world, vec3_scale(norm_light, -1.0_dp)))
intensity  = 0.25_dp + 0.75_dp * diffuse        ! scalar, per face
```

- Exactly **one directional light**, passed as a bare `vec3` direction.
  No colour, no intensity parameter, no position.
- Ambient is not a light; it is the hard-coded `0.25` floor in the formula.
- `main.f90` hard-codes the direction: `light_dir = (-0.5, -1.0, -0.7)`.
- The scalar `intensity` is passed to `draw_triangle`, which multiplies the
  integer `base_color` by it **once per triangle** and fills the whole
  triangle with that one RGB triple. Shading is therefore per-face flat —
  there is no interpolation of colour, normal, or position across a triangle.
  (Barycentric weights `w0,w1,w2` *are* already computed per pixel in
  `draw_triangle`, but only used for depth — §8.3 reuses them.)
- No specular term, no emissive term, no distance attenuation, no shadows.

### 1.3 Framebuffer today

- `FrameBuffer%pixels(3,width,height)` — integer RGB, **no alpha channel**.
- `z_buffer` is a single depth per pixel; `draw_triangle` writes a pixel iff
  its interpolated depth is strictly less than the stored depth, and always
  writes depth. There is no blending, no transparent pass, no sorting.
- Clear colour is hard-coded `(25,25,35)` in `framebuffer_init`.
- Output is P3 PPM via `framebuffer_save_ppm`; `scene.json` is an **export**
  (geometry + integer colour per triangle), not an input format. Nothing in
  the engine reads a scene file — `main.f90` builds one cube in code.
  The compiler/DSL front end is therefore green-field: P10 only fixes the
  *semantics and syntax surface* it must target.

---

## 2. Design principles

1. **Easy beats complete.** A material has 6 knobs, not 26. Every knob has a
   default, so `material red { color: #d83c3c }` is a complete material.
2. **Name things truthfully.** If it's a fake, its keyword says so (`blob`).
   If a feature isn't implemented, the compiler errors — it never accepts
   and ignores a keyword. Silent no-ops are how beginners lose hours.
3. **Legacy is a special case, not a different renderer.** Default material +
   default lights must algebraically reduce to today's formula (§9), so old
   scenes and the existing `output_render.ppm` golden keep passing.
4. **One lighting equation, three evaluation frequencies.** `flat`,
   `lambert`, and `phong` differ only in *where* the same equation is
   evaluated (per face / per vertex / per pixel) — not in different maths.
   That keeps teaching, debugging, and testing simple.
5. **Fixed small caps, reported.** Max 8 dynamic lights, max 64 materials
   per scene (proposed constants, §5.4/§8). Exceeding a cap is a compile
   error naming the cap, not a truncation.
6. **Cheap first.** The renderer is a CPU software rasterizer on modest
   hardware; per-pixel lighting is opt-in via `shading: phong`, never the
   default for every object.

---

## 3. The material model

### 3.1 Fields

Proposed Fortran type (new module `material_3d`, §8.1) — compiler-side mirror
must carry the identical fields and defaults:

```fortran
type :: Material
    character(len=32) :: name        = ''        ! DSL identifier, '' = legacy default
    real(dp) :: color(3)    = [1.0_dp, 1.0_dp, 1.0_dp]  ! albedo, 0..1 per channel
    real(dp) :: emissive(3) = [0.0_dp, 0.0_dp, 0.0_dp]  ! added light, 0..1 per channel
    real(dp) :: opacity     = 1.0_dp             ! 1 = opaque, 0 = invisible
    real(dp) :: specular    = 0.0_dp             ! specular strength 0..1 (phong only)
    real(dp) :: shininess   = 32.0_dp            ! Blinn-Phong exponent, 1..256
    integer  :: shading     = SHADING_FLAT       ! FLAT | LAMBERT | PHONG
    logical  :: double_sided = .false.           ! v1: affects culling only, §3.5
end type Material
```

Notes:

- **Internal colour is `real(dp)` 0–1, not integer 0–255.** Today's integer
  `Triangle%color` cannot express emissive-over-1 clamping, blending, or
  multi-light accumulation without repeated rounding. Conversion happens
  once: DSL/compiler → `real` material; final pixel → `int(clamp(c,0,1)*255)`.
- `emissive` is a colour, not `emissive_color × intensity` pair — one knob
  fewer. A user who wants a dim glow writes a dim colour (`#331100`).
  Emissive is **added after lighting and is not multiplied by albedo**;
  an emissive-only object (`color: #000000, emissive: #ff8800`) glows orange
  in a scene with no lights at all. No bloom/glow blur in v1 — say so.
- `specular` defaults to `0`, so `phong` with no `specular` written is just
  smooth diffuse — predictable for beginners. Specular colour is fixed white
  in v1 (tinted specular is a deferred knob, not a hidden behaviour).
- No `roughness`/`metalness`: those names promise a PBR model this renderer
  does not implement. They are **reserved-and-rejected** (§6.4): writing one
  is a compile error pointing at `specular`/`shininess`.

### 3.2 The one lighting equation

For a point with world position `P`, unit normal `N`, view direction
`V = normalize(camera_pos - P)`:

```
result = emissive
       + color * ( ambient_color * ambient_intensity
                 + Σ_directional  light_color * intensity * max(0, N·L)            )
       + color * ( Σ_point        light_color * intensity * max(0, N·L) * atten  )
       + Σ_all_dir+point  specular * light_color * intensity
                          * max(0, N·H)^shininess * atten_if_point
where  L = direction to light,  H = normalize(L + V)
final pixel = clamp(result, 0, 1) * 255        (per channel)
```

- Ambient is **global** (one per scene, §5.1), not per-material. A
  per-material ambient knob was considered and rejected: beginners read
  "ambient" as scene mood, and two ambient knobs invite double-counting.
- Specular exists only in the `phong` evaluation (§3.4). In `flat`/`lambert`
  modes a non-zero `specular` is **ignored with a compiler warning**
  ("specular has no effect unless shading: phong") — warned, not silent.
- Attenuation for point lights only (§5.3). Directional lights never attenuate.
- No distance-based ambient, no hemisphere light, no fog coupling in v1.

### 3.3 Shading modes — what each name means here

| Mode | Normal used | Equation evaluated | Cost | Looks like |
|---|---|---|---|---|
| `flat` | Face normal (recomputed from world verts, as today) | Once per triangle | Today's cost | Faceted; correct for cubes, crates, low-poly |
| `lambert` | Per-vertex normals, interpolated, **not** renormalized per pixel (Gouraud) | Once per vertex; resulting *colour* interpolated across the triangle | ~3× lighting evals per triangle vs flat | Smooth diffuse gradient; specular absent; highlight can be missed on big triangles — documented |
| `phong` | Per-vertex normals, interpolated **and renormalized per pixel** | Once per pixel (diffuse + Blinn–Phong specular) | Per-pixel loop cost; the expensive mode | Smooth diffuse + moving highlight; the "shiny ball" mode |

Terminology honesty: classic "Phong shading" = per-pixel normal interpolation;
classic "Phong reflection model" also includes specular. Our `phong` is both,
lite version (Blinn half-vector instead of reflect-vector — cheaper and no
worse visually at this scale). The manual must call it **"phong (lite)"** and
state: no reflections, no Fresnel, white specular only.

**Vertex normals are the hidden prerequisite.** Today there are none (§1.1).
Rules:

- Primitives generated by the compiler (sphere, cylinder, …) supply analytic
  vertex normals.
- Imported/generated triangle soup gets vertex normals by averaging face
  normals of triangles sharing a **welded** vertex position (exact position
  match within the soup). Welding is a compiler/mesh-load step, not a
  renderer step.
- **Crease rule:** if the angle between two sharing faces exceeds a compiler
  constant (proposed 60°), normals are *not* averaged across that edge.
  Consequence a beginner can rely on: a cube stays faceted even with
  `shading: lambert/phong` (its 90° edges exceed the crease), a sphere goes
  smooth. Without this rule, "lambert cube" would look melted — the single
  most likely beginner confusion.
- `flat` never uses vertex normals, so legacy geometry is untouched by this.

### 3.4 Which mode is the default?

- **Default material (no `material` block, or no `shading:` inside one):
  `flat`.** It is today's behaviour, cheapest, and matches the cube demo.
- The manual should *recommend* `phong` for spheres/curved primitives and
  `flat` for boxes/architecture, with one side-by-side example image.
- Do **not** auto-upgrade shading by primitive type in v1 — magic defaults
  make compiler output hard to predict. (Possible v2 sugar, not v1.)

### 3.5 Smaller material behaviours — decided, not left vague

- **`opacity < 1` ⇒ transparent pass** (§4). `opacity: 0` is legal
  (invisible but still in the scene graph; useful for toggling).
- **`double_sided: true`** disables back-face culling for that material's
  triangles. Today culling is a screen-space winding test in
  `framebuffer_render_mesh`; the flag must be threaded through (§8.3).
  Lighting of a back face uses the negated normal. Default `false`.
- **Per-face colour override stays.** The compiler may still emit a raw
  per-triangle colour (the legacy path): it is lowered to "default material
  with `color` = that triangle's colour". One code path, no special case
  in the renderer beyond a `material_id` per triangle (§8.2).
- **No per-material light exclusion, no cast/receive flags in v1** — there
  are no shadows for them to control (§7). Adding the flags now would be
  exactly the fake-knob anti-pattern §2 forbids.

---

## 4. Opacity & transparency — the honest version

Current framebuffer has no alpha and a write-always depth policy (§1.3).
v1 design, in full:

1. Split each mesh render into two passes inside `framebuffer_render_mesh`
   (or a scene-level render routine, §8.3): **opaque** (`opacity == 1`)
   first with today's depth rule; **transparent** (`opacity < 1`) second.
2. Transparent triangles are collected, sorted **back-to-front by centroid
   view depth**, then rasterized with depth-test on, **depth-write off**,
   blending per pixel:
   `out = src * opacity + dst * (1 - opacity)` per channel, computed in
   `real` 0–1 before the final integer store.
3. `pixels` stays integer RGB — blending reads the stored destination pixel,
   converts, blends, stores. No framebuffer format change in v1. (A float
   framebuffer is cleaner and is a legitimate v2 refactor; it is *not*
   required for correct-enough v1 blending at 8-bit output.)

Known, documented limitations (print them in the manual, not just here):

- Sorting is per-triangle, not per-pixel: intersecting or cyclically
  overlapping transparent triangles render in the wrong order somewhere.
- A transparent object does not refract or tint by thickness; `opacity` is
  a screen-door-simple mix, nothing more.
- Transparent objects receive the same lighting as opaque ones; they do not
  shadow (nothing does, §7) and do not blend with each other's emissive
  specially.

Rejected alternative: accepting `opacity` in the DSL but treating everything
as opaque in v1. That is a silent fake — §2 forbids it. If the transparent
pass slips from a milestone, `opacity < 1` must become a **compile error**
("opacity ships in milestone X"), not a warning-free ignore.

---

## 5. Lights

### 5.1 Ambient (exactly one, global)

```fortran
type :: AmbientLight
    real(dp) :: color(3)   = [1.0_dp, 1.0_dp, 1.0_dp]
    real(dp) :: intensity  = 0.25_dp        ! legacy default, §9
end type
```

- DSL may declare it at most once; a second `light ambient` block is a
  compile error ("ambient is global — merge the two blocks"), because
  silently adding or overriding both surprise beginners.
- If no ambient is declared, the legacy default `(white, 0.25)` applies.
  `light ambient { intensity: 0 }` is the explicit way to get pure black
  unlit faces — today impossible without editing Fortran.

### 5.2 Directional

```fortran
type :: DirectionalLight
    type(vec3) :: direction          ! direction light travels, as today
    real(dp)   :: color(3) = [1,1,1]
    real(dp)   :: intensity = 1.0_dp
end type
```

- Semantics match today's convention exactly: shading uses
  `max(0, N · normalize(-direction))`. The DSL manual must show one diagram
  sentence: "`direction` is where the light is *going*, like sunlight
  arrows" — this is the #1 sign-error source for beginners.
- Today's hard-coded `(-0.5,-1.0,-0.7)` at intensity effectively `0.75`
  (the `0.75` factor in the legacy formula) becomes the *default scene
  light* when a scene declares no lights at all (§9).

### 5.3 Point

```fortran
type :: PointLight
    type(vec3) :: position
    real(dp)   :: color(3)  = [1,1,1]
    real(dp)   :: intensity = 1.0_dp
    real(dp)   :: range     = 0.0_dp   ! 0 = no cutoff
end type
```

- Per fragment/vertex: `L = normalize(position - P)`,
  `d = |position - P|`, attenuation **`atten = 1 / (1 + d*d / k)`** with a
  single fixed `k` — *or*, simpler to teach and to compute, the
  range-window form below. **Recommendation: range-window only in v1:**
  `atten = clamp(1 - d/range, 0, 1)` when `range > 0`, else `atten = 1`.
  Rationale: beginners can *see* a range ("the lamp lights 5 units");
  quadratic falloff constants cannot be intuited and invite cargo-cult
  numbers. Physical falloff is a v2 decision, recorded here as deferred.
  (If reviewers prefer inverse-square, it must replace — not join — this:
  two attenuation models in v1 is one too many.)
- Point lights are why `phong` needs world position per pixel and `lambert`
  needs it per vertex; `flat` evaluates at the triangle centroid. All three
  are approximations of the same equation (§2.4) — the manual says so.
- A point light *inside* a closed mesh lights its interior faces only if
  they pass culling/normal tests; no special-casing in v1.

### 5.4 Caps and scene container

```fortran
integer, parameter :: MAX_LIGHTS = 8        ! directional + point combined
type :: LightScene
    type(AmbientLight)                    :: ambient
    type(DirectionalLight), allocatable   :: dir(:)
    type(PointLight),       allocatable   :: point(:)
end type
```

- Cap rationale: per-pixel cost is linear in light count; 8 is generous for
  teaching scenes and bounds worst-case `phong` cost. The compiler counts
  and errors: `"scene has 11 lights; v1 supports at most 8"`.
- Light *colour × intensity* may exceed 1 before clamping — that is legal
  and is how a user makes one light dominate. Final clamp is per-pixel (§3.2).

---

## 6. DSL syntax (materials & lights slice)

Syntax below follows the presumed compiler style (named blocks, `key: value`,
`#`/`//` comments per the wider plan's convention — if the core DSL plan
picks different punctuation, only the punctuation changes; the *names,
defaults, ranges, and error rules in this section are the contract*).

### 6.1 Complete worked example

```scene
material brass {
  color:     #c9a227
  specular:  0.6
  shininess: 48
  shading:   phong
}

material glass {
  color:   #aaccee
  opacity: 0.35
  shading: phong
}

material glow_lamp {
  color:    #000000
  emissive: #ff9911
}

light ambient {
  color:     #334455
  intensity: 0.3
}

light directional sun {
  direction: [-0.5, -1.0, -0.7]
  color:     #fff2dd
  intensity: 1.0
}

light point lamp {
  position:  [2.0, 3.0, 1.0]
  color:     #ffaa33
  intensity: 1.2
  range:     8.0
}

object ball : sphere(1.0) {
  material: brass
  at: [0, 1, 0]
  shadow: blob            # fake ground shadow, §7 — opt-in, honestly named
}
```

### 6.2 Grammar sketch (this slice only)

```
material_block := "material" IDENT "{" material_prop* "}"
material_prop  := "color:" COLOR | "emissive:" COLOR
                | "opacity:" NUMBER | "specular:" NUMBER
                | "shininess:" NUMBER
                | "shading:" ("flat"|"lambert"|"phong")
                | "double_sided:" ("true"|"false")

light_block    := "light" "ambient" "{" ambient_prop* "}"
                | "light" "directional" IDENT? "{" dir_prop* "}"
                | "light" "point" IDENT? "{" point_prop* "}"
ambient_prop   := "color:" COLOR | "intensity:" NUMBER
dir_prop       := "direction:" VEC3 | "color:" COLOR | "intensity:" NUMBER
point_prop     := "position:" VEC3 | "color:" COLOR
                | "intensity:" NUMBER | "range:" NUMBER

object material binding := "material:" IDENT        (inside object block)
object shadow flag      := "shadow:" ("none"|"blob")
COLOR := "#" HEX6 | "rgb(" N "," N "," N ")"        (N = 0..255 int or 0..1 float — pick ONE in core plan; recommend hex + rgb255)
```

- Named lights (`sun`, `lamp`) are optional but recommended; names exist for
  error messages and future animation hooks, not for v1 behaviour.
- Colour literals: hex is the teaching format (`#rrggbb`). Whatever second
  form the core plan adopts, the compiler normalizes to `real` 0–1 once.
  Named colours (`red`, `teal`, …) are nice sugar — defer to core plan;
  if adopted, define the exact palette table there, not ad hoc.
- Binding is by material *name* on the object, never by copying material
  fields into the object block. Inline anonymous materials were considered
  and rejected for v1: named-and-reused is easier to teach and to diff.

### 6.3 Defaults table (the contract a beginner relies on)

| Omitted thing | Result |
|---|---|
| Whole `material` block / `material:` binding | Legacy default material: white unless the geometry carries a per-face colour (§3.5), `flat`, opaque, no emissive/specular |
| `color` | white `(1,1,1)` |
| `emissive` | black (none) |
| `opacity` | `1.0` |
| `specular` / `shininess` | `0.0` / `32` (shininess irrelevant until specular > 0) |
| `shading` | `flat` |
| All `light` blocks | Ambient `(white, 0.25)` + one directional, direction `(-0.5,-1,-0.7)`, white, effective intensity reproducing legacy `0.75` (§9) |
| `light ambient` only | Ambient as written + **no** default directional added — declaring *any* light block means the user owns the whole rig. (State this loudly in the manual; it is the one non-obvious default rule.) |
| Point `range` | `0` = unlimited |
| `shadow:` on object | `none` |

### 6.4 Validation — compile errors, not renderer surprises

Compiler (not Fortran) rejects, with line numbers:

| Input | Error |
|---|---|
| `opacity: 1.5`, `specular: -0.1`, channel > range | "value out of range 0..1" |
| `shininess: 0` or `> 256` | out of range 1..256 |
| `shading: gouraud` / any unknown enum | error listing the 3 legal values (we deliberately call it `lambert`, §3.3 — do not accept `gouraud` as an alias in v1; two names for one mode is beginner-hostile) |
| `material: nosuch` | unknown material, list defined names |
| Duplicate material name; second `light ambient` | duplicate-definition error |
| 9th directional/point light | cap error (§5.4) |
| `roughness:`, `metalness:`, `texture:`, `shadow: soft` on a light, `cast_shadow: true` | **reserved/not-in-v1 error**: "X is not supported in v1" + pointer to the supported alternative (`specular`/`shininess`; `shadow: blob`) |
| Zero-length light `direction: [0,0,0]` | error (normalizing it is undefined — renderer guards too, §8.4) |
| Non-zero `specular` with `shading: flat/lambert` | **warning**, not error (§3.2) |

Renderer-side Fortran must still defensively clamp (§8.4): the compiler is
not the only future caller of these modules.

---

## 7. Shadows — the honest section

### 7.1 v1: no real shadows. Full stop.

The current rasterizer renders each mesh in one immediate pass with a single
camera depth buffer. Real shadows need a second depth render from each
light's point of view (shadow mapping) or ray casting — neither exists, and
bolting on a bad version produces the worst outcome: artefacts beginners
cannot explain. Therefore:

- v1 renders **no** cast shadows from any light. Scenes will look "floaty"
  for objects above a ground plane; the manual says this in the first
  lighting chapter, with a picture, not in a footnote.
- The DSL has **no** `shadow: on` that could be misread as real.

### 7.2 The one fake we do ship: `shadow: blob`

- Opt-in per object: `shadow: blob`. A dark, soft-edged ellipse is drawn on
  the scene's ground plane (`y = ground_y`, a compiler/scene setting,
  default `y = 0`) centred under the object's bounding-box centre, sized
  from the bounding box's XZ extent, opacity scaled by object height above
  the plane (clamped) — classic contact blob, ~20 lines of rasterizer work
  (a pre-shaded transparent disc mesh through the existing transparent pass
  of §4 is an acceptable implementation).
- It ignores light direction and other objects entirely. The manual's exact
  wording should be: *"blob is a sticker under the object, not a shadow —
  it does not move with the sun and objects do not shadow each other."*
- `shadow: none` (default) and `shadow: blob` are the only legal values.
  `shadow: soft|hard|real|on|true` → reserved-word compile error (§6.4).

### 7.3 Designed future path (v1.1/v2 — design noted, not promised as v1)

Directional-light shadow map is the tractable next step for this rasterizer:
render the scene's depth from the sun's orthographic viewpoint into a second
`FrameBuffer`-like depth array (the existing barycentric rasterizer already
interpolates depth; a depth-only mode is a flag, not a rewrite), then test
per pixel in the `phong`/per-vertex in `lambert` paths with a small bias.
Point-light shadows (6-face cube depth) and soft/PCF filtering come after,
if ever. When that lands, the DSL grows `shadow: map` on the *light* (the
light owns shadow quality), and `blob` stays as the cheap option. Recording
this path here so v1 data structures (per-pixel world position in `phong`)
are chosen compatibly — world `P` per pixel is exactly what a shadow test
needs.

---

## 8. Fortran renderer changes needed

### 8.1 New module `src/material.f90` (`material_3d`)

- Types: `Material` (§3.1), shading-mode `parameter` constants
  (`SHADING_FLAT=0, SHADING_LAMBERT=1, SHADING_PHONG=2`), `MAX_MATERIALS=64`.
- `type :: MaterialTable` — fixed-size array + count + name lookup
  (`material_find(table, name) -> index`), `material_default()` returning
  the legacy default, `material_validate(m) -> error string` (range clamps
  per §6.4 as a backstop).
- No dependency beyond `math_3d` (for `dp`).

### 8.2 Changes to `src/mesh.f90` (`mesh_3d`)

- `Triangle` gains: `integer :: material_id = 1` and
  `type(vec3) :: vnormal(3)` (vertex normals, default = face normal so
  un-welded legacy geometry degrades to flat-looking, never garbage).
- `Triangle%color` is **kept** for one release as the legacy colour source;
  the compiler loader lowers it into a generated material (§3.5). Mark it
  deprecated in a comment; removing it is a v2 cleanup, not v1 churn.
  (`export_mesh_json/obj` keep working unchanged; optionally emit
  `material_id` in JSON — additive, safe.)
- New helper: `compute_vertex_normals(mesh, crease_angle_rad)` implementing
  weld-by-position + angle-weighted average + crease split (§3.3). Pure
  mesh-side; renderer never welds.
- `create_cube` sets `material_id` per face-group *or* keeps colours —
  either is fine provided §9's golden still passes; simplest v1: leave
  `create_cube` byte-identical and let the default-material lowering handle it.

### 8.3 Changes to `src/renderer.f90` (`renderer_3d`) — the bulk

1. **New module `src/lighting.f90` (`lighting_3d`)**: `AmbientLight`,
   `DirectionalLight`, `PointLight`, `LightScene` (§5),
   `lighting_default_scene()` (§9), and one pure function used by all modes:

   ```fortran
   pure function shade_point(mat, P, N, cam_pos, lights) result(rgb01)
       ! implements §3.2 for a single point; specular included,
       ! caller passes specular=0 materials for flat/lambert passes
   end function
   ```

   Keeping the equation in **one** function is what makes §2.4 true.
2. **Signature change**:
   `framebuffer_render_mesh(fb, mesh, model_matrix, cam, light_dir)` →
   `framebuffer_render_mesh(fb, mesh, model_matrix, cam, materials, lights)`.
   This is a breaking API change; `main.f90` is the only in-repo caller.
   Keep no compatibility shim — a shim with the old `light_dir` argument
   would invite two lighting paths to drift.
3. **Per-mode rasterization paths** inside the render loop:
   - `flat`: as today — face normal, `shade_point` at centroid (or with the
     face normal at any vertex; diffuse is constant per face for directional,
     centroid matters only for point lights), one colour per triangle.
   - `lambert`: transform the 3 vertex normals by the model's rotation
     (upper 3×3 of `model_matrix`, renormalized — non-uniform scale normal
     correction/inverse-transpose is a **known v1 limitation**, documented;
     compiler-generated primitives use uniform scale in all examples),
     `shade_point` per vertex (specular zeroed), pass 3 colours into the
     rasterizer and interpolate with the existing barycentric weights.
   - `phong`: pass world positions + world vertex normals per vertex;
     in the pixel loop interpolate both, renormalize `N`, call
     `shade_point` per pixel with `cam%position` as view origin.
   - `draw_triangle` therefore splits into a flat-colour variant (today's,
     kept) and an interpolated variant carrying per-vertex colour *or*
     per-vertex `(P,N)` + material + lights. Do not overload one routine
     with flag soup; two routines, shared bounding-box/barycentric core
     factored into an internal helper if clean.
4. **Transparent pass** (§4): partition triangles by material opacity,
   render opaque, collect+sort transparent by centroid depth
   (simple insertion/qsort on ≤ a few thousand triangles is fine),
   rasterize with blend + no depth write. `draw_triangle*` needs a
   `write_depth` flag and a blend branch at the pixel store.
5. **Blob shadows** (§7.2): `render_blob_shadow(fb, mesh, model_matrix, cam,
   ground_y)` drawing a dark transparent disc mesh before/with the
   transparent pass; or compiler lowers `shadow: blob` to an extra disc
   object with a generated transparent black material — **preferred**: zero
   new renderer concepts, reuses §4. Renderer change then = none. Decide
   for the compiler-side lowering in implementation; this plan accepts either.
6. **Back-face culling** must consult `double_sided` (§3.5): the current
   screen-space winding `cycle` needs a per-material branch (skip cull +
   flip normal when the winding says back face).
7. **Clear colour** becomes a parameter: `framebuffer_clear(fb, r,g,b)`
   already takes RGB — `framebuffer_init`'s hard-coded `(25,25,35)` should
   be overridable by the scene background (compiler concern; renderer just
   stops hard-coding it in the one call site in `main`).

### 8.4 Defensive rules in Fortran (compiler is not the only caller)

- `shade_point`: normalize `N` and each `L` internally; a zero normal or a
  point light exactly at `P` contributes diffuse/specular 0 for that light
  (guard with the same `1e-12` epsilon style `vec3_normalize` already uses).
- Clamp every material/light input into its §6.4 range on entry to the
  render call (clamp + no crash); validation *errors* remain the compiler's
  job, the renderer just never produces NaN pixels.
- All accumulation in `real(dp)`; single clamp+`int()` conversion at store.

### 8.5 `main.f90` / `Makefile`

- `main.f90`: replace the hard-coded `light_dir` with
  `lights = lighting_default_scene()` and a default material table, so the
  standalone demo still builds and matches the golden. When the compiler
  lands, generated code replaces this file's scene section — keep the demo
  scene semantically identical (same cube, camera, light direction).
- `Makefile`: add `material.f90` and `lighting.f90` to `MODULE_SRCS`/objects
  with correct dependency order (`material` after `math_3d`; `lighting`
  after `math_3d`+`material`; `renderer` after both). No new external
  dependencies; still pure gfortran, still `-O3 -Wall -Wextra -fcheck=all`.

### 8.6 Performance expectations (state them, don't discover them)

- `flat`: ≈ today's cost (+ light-loop over ≤8 lights per triangle — negligible).
- `lambert`: ≈ 3 `shade_point` calls/triangle; negligible at teaching scale.
- `phong`: `shade_point` per covered pixel × lights — at 640×480 this is
  the difference between instant and noticeable on CPU. Mitigations in v1:
  it's opt-in per material; the manual advises `phong` on hero objects,
  `flat`/`lambert` on scenery. No threading in v1 (matches current code).

---

## 9. Backwards compatibility — the legacy golden

Claim to be *tested*, not assumed: with default material + default lights,
output equals today's `output_render.ppm` for the `main.f90` cube scene.

Algebra check: legacy `intensity = 0.25 + 0.75·diffuse`, colour multiplied
as a scalar (greyscale light). New equation with ambient `(white, 0.25)`,
one directional `(white, intensity I)`, material `specular=0`:

```
result = color * (0.25 + I · diffuse)
```

Setting **`I = 0.75`** reproduces the legacy formula exactly, per channel
(white light ⇒ scalar). So `lighting_default_scene()` = ambient 0.25 white +
directional `(-0.5,-1.0,-0.7)`, white, **0.75** — and the DSL default-light
rule (§6.3) must use the same numbers. Any "prettier" default (e.g. 1.0)
breaks the golden and is a deliberate, separately-approved change, not a
side effect of this work.

Tests that must exist before this plan is called done:

1. **Golden PPM**: pre-change `output_render.ppm` for the cube scene,
   byte/pixel-compared after the change with default scene.
2. **Mode separation**: one sphere, three renders (`flat`/`lambert`/`phong`),
   asserted pairwise-different; cube in `lambert` still faceted (crease rule).
3. **Light unit checks** (Fortran-level or compiler-level): directional
   facing away ⇒ ambient-only colour; point light beyond `range` ⇒ ambient
   only; emissive-only material renders its emissive colour with **zero**
   lights declared beyond defaults-off rig.
4. **Opacity**: two overlapping transparent quads, known blend result at the
   overlap pixel (±1 LSB); transparent object behind opaque object is
   correctly depth-rejected.
5. **Error cases**: every row of §6.4's table produces its compile error.
6. **Blob**: `shadow: blob` darkens ground pixels under the object and
   changes nothing elsewhere; `shadow: soft` is a compile error.

---

## 10. Implementation sequence (suggested milestones)

| # | Milestone | Contents | Exit test |
|---|---|---|---|
| M1 | Materials + lights, flat only | `material.f90`, `lighting.f90`, new render signature, `shade_point`, multi-light diffuse + ambient + emissive, DSL blocks for material/ambient/directional | Golden (§9.1) + §9.3 directional cases |
| M2 | Point lights + lambert | `PointLight` + range attenuation, vertex normals + weld/crease, Gouraud path | §9.2 (lambert leg), §9.3 point cases |
| M3 | Phong-lite + opacity | Per-pixel path + specular, transparent pass + blending, `double_sided` | §9.2 (phong leg), §9.4 |
| M4 | Blob + polish | `shadow: blob` (compiler lowering preferred), all §6.4 errors/warnings, manual chapter with the honesty notes (§4, §7.1) verbatim in substance | §9.5, §9.6 |

M1 alone is a shippable, honest improvement; M2–M4 are independently
cut-able **only** by turning their DSL keywords into §6.4-style
not-in-v1 errors — never by accepting-and-ignoring them.

## 11. Risks & open questions

- **Normal transform under non-uniform scale** is wrong in v1 (§8.3.3).
  If the core DSL makes non-uniform scale a headline feature, promote the
  inverse-transpose normal matrix into M2 — it's ~15 lines in `math_3d`
  usage, but must be a conscious decision.
- **Colour literal second form** (§6.2) and named-colour palette belong to
  the core DSL plan; P10 needs the decision before M1's parser work.
- **Float vs integer framebuffer**: v1 blends through the integer buffer
  (§4.3). Banding in subtle blends is possible; acceptable for v1, revisit
  if the viewer work raises output-quality ambitions.
- **`scene.json` export** gains materials/lights? Out of scope here — the
  viewer (`viewer.html`) currently consumes triangles+colours only. If the
  viewer plan wants lit preview, it needs its own material story; P10 does
  not silently extend the export format beyond the additive `material_id`.
- **Light cap of 8 / material cap of 64** are proposals sized for teaching
  scenes; if the core plan expects imported production scenes, raise them
  there explicitly — the constants live in one place each for that reason.
