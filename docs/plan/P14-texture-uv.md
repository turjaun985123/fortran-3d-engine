# P14 — Texture & UV Specification (Deferrable to v2)

> **Status:** Planning only — no code changed by this document.
> **Repo ground truth at design time (2026-11-23):**
> `src/mesh.f90` (`Triangle { v(3): vec3, normal: vec3, color(3): integer 0–255 }`,
> `Mesh` flat triangle soup, `create_cube(m, size)` only — 12 triangles,
> per-face colours, `export_mesh_json` / `export_mesh_obj` with no `vt`),
> `src/renderer.f90` (`FrameBuffer { pixels(3,w,h): integer, z_buffer }`,
> barycentric `draw_triangle` with flat colour — weights `w0,w1,w2` computed
> per pixel but used only for depth, Lambertian `intensity = 0.25 + 0.75*diffuse`
> per face, P3 PPM export only),
> `src/camera.f90` / `src/math_3d.f90` (no `vec2` type),
> `src/main.f90` (hard-coded demo: 640×480, cube size 2, outputs
> `output_render.ppm` + `scene.json` + `model.obj`),
> `viewer.html` (Canvas 2D painter's-algorithm viewer + P3 PPM decoder,
> consumes `{triangles:[{v,color}]}` only),
> `Makefile` (pure `gfortran`, no external libraries; PNG appears only as an
> optional ImageMagick `convert output_render.ppm output_render.png` step).
> **Companion plans:** P03 reserves the word `texture` and defers textures
> from the v1 grammar; P10 §0/§6.4 rules `texture:` a reserved/not-in-v1
> compile error and defers textures/UVs/PBR with no faking. This plan is the
> detailed design both point at — it changes neither ruling.

---

## 0. Verdict in one page

| Decision | Ruling |
|---|---|
| **v1 ships** | **Colours only. No UVs generated, no image loaded, no texture sampled — at runtime, ever.** The word and the syntax are reserved (§7), parsed, and rejected with one clear diagnostic (§8). This is the whole of v1's texture work: *reserve + reject honestly*, plus the data-model reservations in §3.1 that cost nothing now and prevent a breaking change later. |
| **v2 feature** | Textured materials behind a single compiler feature flag `--textures` (§9). Without the flag, v2 behaves exactly like v1. With it, one diffuse map per material, sampled in the Fortran rasterizer and in the browser viewer with the same UVs, same origin, same flip rule (§2). |
| **DSL syntax** | Inside a material/object definition: `texture: "file.png"` — a double-quoted relative path, nothing else required. Optional v2 companions, all with defaults: `uv: <mode>`, `wrap:`, `filter:`, `repeat:`, `offset:` (§7.2). No second syntax. |
| **UV space** | `u,v ∈ ℝ` (normally `[0,1]` per face/primitive patch), origin **bottom-left**, `v` up — the OpenGL/OBJ convention. Image row 0 (top) maps to `v = 1`; the flip happens **once, at image load**, never per-primitive or per-sampler (§2.2). |
| **UV generation** | Compiler-generated per primitive at mesh-build time (§4): cube = per-face planar `[0,1]²`; sphere = spherical; cylinder/cone = cylindrical + separate cap discs; plane = planar; pyramid = per-face planar; torus = parametric grid. OBJ import keeps file `vt`; raw triangle soup with no source gets a documented planar fallback + warning. Users never hand-write UVs in v1/v2 DSL. |
| **Formats — v2 tier 1** | **PPM/PGM (P3/P6)** and **BMP (24/32-bit uncompressed)** natively in Fortran (no new dependency); **PNG** and **JPEG** in the browser for free (platform decoder) and natively only via one optional C-interop decoder (§6). Everything else is an error naming the supported list, not a silent skip. |
| **Sampling (v2)** | Perspective-correct barycentric interpolation (not affine — §5.2), `filter: nearest` (default for beginners' pixel look? No — default `linear`, §5.3), `wrap: repeat` default, no mipmaps in first textured milestone; mipmaps + anisotropy are separately-flagged deferrables (§9.2). Colour is multiplied: `final = texel × material colour × lighting` — so every v1 coloured scene keeps working and a white material shows the texture unmodified. |
| **Deferrable means deferrable** | Each v2 sub-feature (formats, filtering, mipmaps, browser GPU upload, normal maps, atlases) has its own flag/gate and its own *not-yet* diagnostic (§9.2, §10). Cutting any of them changes an error message, never a scene's meaning and never the v1 golden image. |
| **Golden guarantee** | A scene with no `texture:` renders **pixel-identically** in v1, in v2 without `--textures`, and in v2 with `--textures` but no textured material. Tested, not hoped (§11). |

Non-goals, stated now so nobody designs them in by accident: normal/bump/
specular/roughness/emissive maps, cube maps / environment maps, procedural
textures, texture painting, UV editing in the DSL, video textures, SVGs as
textures, per-object texture blending / decals, compressed GPU texture
formats (KTX/DDS/ASTC). Each is a future plan, not a v2 flag (§12).

---

## 1. Where we start — the audited baseline

### 1.1 There is no texture-shaped hole anywhere yet

| Layer | Today | Consequence for this design |
|---|---|---|
| Geometry | `Triangle` has positions, one face normal, one integer colour. No `uv`, no material id (P10 proposes adding `material_id`; this plan builds on that, §3). Vertices are duplicated per triangle (cube = 36 exported verts for 8 corners). | UVs, when they come, are **per-corner** (`uv(3)` per triangle), matching the existing soup. No indexed-vertex refactor is required — and none is smuggled in by this plan. |
| Rasterizer | `draw_triangle(fb, x, y, z, base_color, intensity)` computes one RGB triple per triangle and fills. Barycentric weights already exist per pixel. | v2 sampling reuses those weights — but must add perspective correction (§5.2); the current weights alone would swim on slanted faces. |
| Shading | One scalar Lambert `intensity` per face; no per-pixel anything. | Texture sampling is inherently per-pixel, so the first textured path is also the first per-pixel path. It must not be conflated with P10's `phong` milestone: a textured `flat`-shaded triangle = per-pixel *texel*, per-face *light* (§5.1). |
| Images | Engine **writes** P3 PPM; it **reads no image format at all**. No stb, no libpng, no zlib anywhere; `Makefile` has zero external deps. | Native loading is net-new code. Format choice is therefore a dependency decision first and a convenience decision second (§6.1). |
| Browser | `viewer.html` draws flat-coloured triangles on Canvas 2D; its only image code decodes the Fortran P3 PPM output for display. No WebGL in the shipped viewer (P06 designs a WebGL runtime as a separate plan). | Browser texture support has two honest tiers: Canvas 2D pattern/clip fill (works, slow, affine) vs. WebGL `texImage2D` (correct, depends on P06). §6.3 specifies both and says which milestone owns which. |
| DSL | P03: `texture` is in the reserved-but-rejected word list. P10 §6.4: `texture:` → reserved/not-in-v1 error. No `.f3d` parser exists yet. | This plan specifies parser *behaviour* for the reserved syntax so the future compiler implements one behaviour, not two. |

### 1.2 Why deferral is the right call (and what it must not become)

Textures are the single largest beginner-visible feature still missing, and
also the one with the worst cost/benefit in v1: a decoder dependency, a
per-pixel rasterizer path, a UV convention, asset-path rules, and a browser
story — five new failure surfaces — to replace a colour the user can already
write in one word (`cube red`, P03). v1's promise is *easy*; a half-working
texture path is the opposite of easy.

Deferral done badly, however, is how projects get stuck: scenes written in
v1 break in v2, or the v2 implementer discovers the v1 data model cannot
hold a UV. This plan exists to make deferral *safe*:

1. **Syntax is frozen now** (§7) — a v1 user who writes `texture:` gets a
   precise "not in v1" error today and the *same line* compiles in v2.
2. **Data-model space is reserved now** (§3.1) — field names, JSON keys, and
   OBJ behaviour are decided while they are still free to decide.
3. **Semantics are frozen now** (§2, §4, §5) — origin, flip, per-primitive
   generation, and the multiply rule are the parts that are expensive to
   change after users have assets that depend on them.

---

## 2. UV space — the frozen conventions

These five rules are the contract. Every primitive generator (§4), both
loaders (§6), both samplers (§5), and both exporters (§3.3) obey all five;
a disagreement between the Fortran render and the browser view of the same
scene is by definition a bug in one of them.

### 2.1 Coordinates

- A UV is a pair of `real(dp)` values `(u, v)`, stored per triangle corner.
- Nominal range is `[0, 1]` across one repetition of the texture on one
  patch (one cube face, one sphere wrap, one plane). Values outside
  `[0, 1]` are legal data — `wrap` (§5.4) decides what they mean; the
  generator for `repeat: 2 3` (§7.2) deliberately emits them.
- There is no third texture coordinate in v2. No `w` texture axis, no
  texture matrices beyond `repeat`/`offset` (§7.2).

### 2.2 Origin and the flip rule (the #1 texture bug, decided once)

- **UV origin is bottom-left: `(0,0)` = bottom-left of the image as the
  author sees it, `(1,1)` = top-right.** This matches OBJ `vt` and OpenGL,
  which are the two formats this engine already neighbours (`model.obj`
  export; P06's WebGL runtime).
- Image files store row 0 at the **top**. Therefore exactly one flip exists
  in the whole system: **at load time, the native loader stores rows
  bottom-up (or equivalently sets a `flipped` flag the sampler honours),
  and the browser path sets `UNPACK_FLIP_Y_WEBGL = true` (WebGL) or draws
  with a negative Y scale (Canvas 2D).**
- Primitive generators, DSL code, and scene authors **never** write
  `1 - v` to compensate. A generator that "looks right" only because it
  pre-flips is non-conformant; §11 has a test image that catches it (an
  asymmetric test card — letter "R" + arrow — which reads correctly in
  exactly one orientation).

### 2.3 Texel mapping

- Texel centres sit at `(i + 0.5) / W`, `(j + 0.5) / H` for a `W×H` image.
  `nearest` picks the texel whose cell contains `(u, v)` after wrapping;
  `linear` blends the 2×2 neighbourhood around the texel-centre grid
  (§5.3). Stating this matters: the half-texel offset is the second most
  common texture bug (blurry/shifted textures), and Fortran and JS must
  implement the *same* rule.
- Non-power-of-two (NPOT) images are **accepted** in the native sampler
  (it is just array indexing — no restriction exists to inherit) and in
  WebGL1 only with `wrap: clamp` + `filter: linear/nearest` and no
  mipmaps, per the WebGL1 spec; the browser loader must enforce/diagnose
  that combination rather than let WebGL silently produce black (§6.3).

### 2.4 Colour space (honest, like P10)

- v2 does **no** colour-space conversion: texel bytes are treated as the
  same linear-ish 0–1 values P10 already uses for material colour, and the
  final pixel is `clamp(result, 0, 1) × 255`. No sRGB decode on load, no
  gamma on store.
- Consequence, stated in the future manual: a texture will render with the
  same values it has in an image editor (which is what a beginner expects
  from a teaching engine), and it will not match a colour-managed engine.
  An `srgb: true` flag is a recorded future option (§12), not a v2 knob —
  adding it later is additive; silently converting in v2 would not be.

### 2.5 Precision

UVs are `real(dp)` in Fortran and `Float32` in the browser. At teaching
scene scales (≤ a few thousand repetitions) the difference is invisible;
`repeat` values above 1024 are a validation warning (§7.3) because float
precision in the browser path starts to band there.

---

## 3. Data model (reserved in v1, built in v2)

### 3.1 Fortran types — what v1 reserves, what v2 adds

**v1 reservation (zero behaviour, do now with the compiler skeleton):**
the names `uv`, `texture`, `Texture`, and `texture_id` are not used for
anything else in any module, the JSON key `"uv"` / `"texture"` and the OBJ
token `vt` are documented as reserved in the exporter docstrings. Nothing
is emitted, nothing is read. That is the entire v1 code footprint of this
plan.

**v2 additions (new module `src/texture.f90`, module `texture_3d`):**

```fortran
type :: Texture
    character(len=:), allocatable :: path      ! as written in the DSL
    integer  :: width = 0, height = 0
    integer, allocatable :: pixels(:, :, :)    ! (3, width, height), 0..255,
                                               ! stored BOTTOM row first (§2.2)
    integer  :: wrap   = WRAP_REPEAT           ! WRAP_REPEAT | WRAP_CLAMP | WRAP_MIRROR
    integer  :: filter = FILTER_LINEAR         ! FILTER_NEAREST | FILTER_LINEAR
    logical  :: has_alpha = .false.            ! v2: alpha parsed, NOT blended
end type Texture                     !   (blending is P10 opacity's job, §5.5)

type :: TextureTable                     ! fixed cap, compiler-counted
    integer, parameter :: MAX_TEXTURES = 32
    type(Texture), allocatable :: items(:)
    integer :: count = 0
end type TextureTable
```

- Pixels as integer 0–255 RGB mirrors `FrameBuffer%pixels` exactly — the
  sampler converts to `real` 0–1 at sample time, one conversion site, same
  rounding story as P10 §3.1. Alpha, when present in the source, is dropped
  at load with a one-time note (or kept in a 4th plane behind the atlas/
  decal future — implementer's choice, but it is never *silently* used).
- One texture per material in v2. The material gains exactly one field
  (extends P10 §3.1; if P10 has not landed, the field lives on the mesh's
  material record instead — same name, same semantics):

```fortran
integer :: texture_id = 0   ! 0 = no texture (the v1 case); >0 = index into TextureTable
```

- `Triangle` (in `mesh_3d`) gains exactly one field in v2:

```fortran
real(dp) :: uv(2, 3) = 0.0_dp   ! uv(:,corner); default (0,0) is harmless
                                ! because texture_id = 0 means "never sampled"
```

  Default-zero UVs on untextured geometry are safe *by construction*: the
  sampler is only called when the triangle's material has `texture_id > 0`.

### 3.2 Compiler-side mirror

The compiler's scene/material record carries `texture: path | none`,
`uv_mode`, `wrap`, `filter`, `repeat(2)`, `offset(2)` with the §7.2
defaults. It resolves paths (§6.4), deduplicates identical paths to one
`TextureTable` entry (two materials naming `"wood.png"` load it once and
share the id — stated because beginners *will* do this), and counts
against `MAX_TEXTURES` with a named-cap error (§7.3).

### 3.3 Export / interchange (additive only)

| Format | v1 (today) | v2 with `--textures` | v2 without the flag |
|---|---|---|---|
| `scene.json` | `{id, v, color}` per triangle | Adds `"uv": [[u,v]×3]` per textured triangle and a top-level `"textures": [{id, path, wrap, filter}]` table; untextured triangles unchanged | Byte-identical to v1 output (golden-safe) |
| `model.obj` | `v` + `f a b c` | Emits `vt u v` lines and `f a/a b/b c/c` for textured triangles; `mtllib`/`.mtl` is **not** emitted (OBJ material files are a dialect swamp; the JSON table above is our contract) | Identical to v1 output |
| Browser scene (P06 v2 format) | `positions`, `colors` | Adds `uvs` flat array + `textures` table mirroring the JSON above | Unchanged |

Path in exports is the DSL-relative path as written (§6.4), never an
absolute machine path — an exported scene must stay portable.

---

## 4. UV generation per primitive

**Rule 0: the user never writes a UV in the DSL.** The compiler (or the
`mesh.f90` constructor, when geometry is built in Fortran) generates UVs
at build time from the primitive's own parameters, using the modes below.
`uv: <mode>` (§7.2) may *override* the mode, never the coordinates by hand.

All generators emit per-corner UVs for the triangle soup. Where a primitive
has a seam (sphere, cylinder, torus), the seam vertices are **duplicated
with different UVs** (`u = 0` on one side, `u = 1` on the other) — the soup
representation makes this natural, and interpolating across the seam
instead would smear the whole texture backwards across one triangle, the
classic seam bug.

### 4.1 Cube / box — per-face planar (the only v1 primitive; v2's reference case)

Each of the 6 faces independently maps to the full `[0,1]²`. The whole
texture appears once per face. Orientation is fixed so the image is
**upright when that face is viewed head-on from outside, with world +Y as
"up" where the face has a Y extent**:

| Face (normal) | `u` increases along | `v` increases along | Corner `(u,v)` anchor |
|---|---|---|---|
| North `+Z` | `+X` | `+Y` | bottom-left of face (min X, min Y) = `(0,0)` |
| South `−Z` | `−X` | `+Y` | viewed from −Z: bottom-left = `(0,0)` |
| East `+X` | `−Z` | `+Y` | viewed from +X: bottom-left = `(0,0)` |
| West `−X` | `+Z` | `+Y` | viewed from −X: bottom-left = `(0,0)` |
| Top `+Y` | `+X` | `−Z` | viewed from above with −Z as image-up: `(0,0)` at (min X, max Z) |
| Bottom `−Y` | `+X` | `+Z` | viewed from below: documented, rarely textured |

The two triangles of a face share the face's four corner UVs
`(0,0), (1,0), (1,1), (0,1)` in the face's winding order — i.e. this is
exactly the quad split `create_cube` already performs, plus a lookup.
Non-uniform box (`size sx sy sz`, P03) changes nothing: UVs are
per-face-normalised, so the texture stretches with the face (documented;
`uv: world` in §4.7 is the unstretched alternative).

*Teaching note for the manual:* "a textured cube is a dice/crate — the
picture repeats on every side." Users wanting one picture across a whole
object want an atlas (§12), not a different cube mapping.

### 4.2 Sphere — spherical (equirectangular)

For a vertex at direction `d = normalize(p − centre)`:

```
u = 0.5 + atan2(d.x, d.z) / (2π)        ! seam at −Z, u: 0→1 around Y
v = 0.5 − asin(clamp(d.y, −1, 1)) / π   ! v = 1 at +Y pole, 0 at −Y pole
```

- Poles pinch the texture (inherent to equirectangular — show it in the
  manual with the test-card image, don't hide it).
- Seam column duplicated per Rule 0/§4 preamble; pole triangles get the
  `u` of their own longitude (degenerate but well-defined).
- This is the mapping every equirectangular world-map image assumes, so
  `sphere texture: "earth.png"` just works — the beginner demo this
  section is designed around.

### 4.3 Cylinder — cylindrical side + planar caps

- **Side:** `u = 0.5 + atan2(d.x, d.z) / (2π)` (same longitude as sphere,
  seam at −Z), `v = (y − y_bottom) / height` (0 at bottom rim, 1 at top).
- **Caps:** each cap is its own patch: planar map of the disc,
  `u = 0.5 + x / (2·radius)`, `v = 0.5 + z / (2·radius)` for the top cap
  (viewed from above, −Z up as in §4.1 top face); bottom cap mirrored so
  it reads upright from below. Caps and side do **not** share UV space —
  the full texture appears on the side *and* (cropped to a circle) on
  each cap. Documented; a single `texture:` paints all three.

### 4.4 Cone — cylindrical side (apex-aware) + planar base

- **Side:** same longitude `u` as cylinder; `v = s` where `s` is the
  fractional distance along the slant from base rim (`v = 0`) to apex
  (`v = 1`). Apex vertices all carry `v = 1` with their own segment's `u`
  (degenerate triangles at the tip pinch, as with sphere poles).
- **Base:** planar disc exactly as the cylinder bottom cap (§4.3).

### 4.5 Plane — planar (the trivial, most-used case)

`u = (x − x_min) / width`, `v = (y − y_min) / height` in the plane's local
2D coordinates (for a ground plane in XZ: `u` along +X, `v` along −Z so
the image reads upright viewed from above with the default camera —
consistent with §4.1's top-face rule). One repetition across the plane;
`repeat:` (§7.2) is the intended way to tile a floor, and §5.4's
`wrap: repeat` exists largely for this primitive.

### 4.6 Pyramid — per-face planar

Each triangular face maps to `(0,0), (1,0), (0.5, 1)` (base-left,
base-right, apex) in face-local view; the square base, if present, maps
as §4.1's bottom face. The texture appears once per face, upright on each
face. (A `0.5` apex `u` centres the image peak — the only generator here
whose patch is a triangle, not a quad; stated so the test in §11 can pin
it.)

### 4.7 Torus — parametric grid

`u = θ / (2π)` around the main ring, `v = φ / (2π)` around the tube, both
seams duplicated per the preamble rule. The texture tiles seamlessly
around both axes with `wrap: repeat` — the one primitive where repeat
wrapping is exercised even at `repeat: 1 1`.

### 4.8 Non-primitive geometry (OBJ import / raw soup) and override modes

| Source | Default UV behaviour |
|---|---|
| OBJ with `vt` | File UVs used verbatim (origin/flip already OBJ-convention, §2.2 — no conversion). Missing `vt` on *some* faces → those triangles get §4.8-fallback + one warning naming the file. |
| OBJ / soup with no UVs at all | **Fallback planar projection** along the dominant axis of each face normal (box-projection-lite: project onto the plane perpendicular to the largest `|normal|` component, normalised per connected mesh bounding box) + warning `W-TEX-UVFALLBACK`. Never a silent `(0,0)` smear. |
| `uv:` override in DSL | One of `auto` (default — the per-primitive rules above), `planar-x` / `planar-y` / `planar-z` (world-axis planar projection over the object's bounding box — the "brick wall that must not stretch" escape hatch), `sphere`, `cylinder` (force §4.2/§4.3 longitude mapping onto any primitive). Any other value is a validation error listing these (§7.3). |

Generation is deterministic and unit-testable without any image: §11's
tests assert UV *numbers* per primitive, so a generator regression is
caught before a pixel is ever sampled.

---

## 5. Sampling — the v2 rasterizer change

### 5.1 Where sampling lives

In `renderer.f90`, the textured path extends `draw_triangle` (or adds
`draw_triangle_textured` alongside it, mirroring P10 §8.3's
two-routines-not-flag-soup rule):

```
per pixel (existing barycentric w0,w1,w2, existing depth test):
    uv        = perspective_correct_interp(uv0, uv1, uv2, w0, w1, w2)   ! §5.2
    texel     = sample(texture, uv)                                       ! §5.3/§5.4
    rgb01     = texel/255  ×  material.color  ×  lighting                 ! multiply rule, §0
    store     = clamp(rgb01) × 255                                        ! P10 §3.2 store rule
```

- **Lighting stays at P10's frequency for the material's shading mode:**
  `flat` = one intensity per face (today's code) multiplied per pixel —
  a textured cube face is uniformly lit but textured. Texture does **not**
  secretly upgrade anyone to per-pixel lighting.
- Untextured triangles take today's code path untouched (the golden
  guarantee, §0). Dispatch is per-triangle on `texture_id > 0`.

### 5.2 Perspective-correct interpolation (non-negotiable)

Screen-space barycentric weights interpolate UVs *affinely*, which bends
textures on any face not parallel to the screen — immediately visible on
the default demo cube's pose. The fix is standard and cheap: carry
clip-space `w` (currently discarded — `mat4_transform_vec3(..., .true.)`
in `framebuffer_render_mesh` does the divide internally, so the transform
call must additionally expose pre-divide `w` per vertex; that is the one
touch to the vertex path this plan requires), then per pixel:

```
u = (w0·u0/w0c + w1·u1/w1c + w2·u2/w2c) / (w0/w0c + w1/w1c + w2/w2c)
    (same for v; wc = clip w of corner c)
```

Depth interpolation gets the same treatment or stays as-is — implementer's
choice, but UV must not stay affine. §11 includes a slanted-plane test
that affine interpolation visibly fails and this formula passes.

### 5.3 Filtering

| `filter:` | Behaviour | Notes |
|---|---|---|
| `nearest` | One texel (§2.3 cell rule) | The pixel-art / Minecraft look; cheapest; also the debugging filter (mapping errors are obvious). |
| `linear` (**default**) | Bilinear blend of the 2×2 texel-centre neighbourhood, in integer→real 0–1 space, per channel | Default because a beginner's photo texture under `nearest` shimmers and looks broken; `nearest` is one word away when wanted. |
| *(deferred)* `mipmap` | Bilinear + mip chain, level from UV derivatives | Separate flag/gate (§9.2). Needs generated mip levels at load (memory +33%, build cost) and per-pixel derivative estimates; specified here only as: box-filter halving to 1×1, sampled trilinearly. Cutting it must not change `linear` results. |

Sampling at a triangle's pixels outside the generated mip range, at
extreme grazing angles under `linear`, will alias/shimmer — stated in the
manual as the known cost of the default, with `mipmap` named as the
future remedy. No anisotropic filtering in v2.

### 5.4 Wrapping

Applied to `(u, v)` independently, after `repeat`/`offset` (§7.2), before
§2.3 mapping:

| `wrap:` | Formula (per axis, `t` = coordinate) | Use |
|---|---|---|
| `repeat` (**default**) | `t − floor(t)` | Tiling floors, torus, brick |
| `clamp` | `min(max(t, 0), 1)` — edge texel stretches beyond the border | Photos/decals that must not tile; also the WebGL1-NPOT requirement (§2.3) |
| `mirror` | triangle-wave fold into `[0,1]` | Seamless tiling of non-tileable images |

One mode per texture in v2 (both axes) — separate `wrap-u`/`wrap-v` is
deferred (§12); the common asymmetric case (cylinder side wraps, caps
don't) is already handled by per-patch generation (§4.3), not by wrap.

### 5.5 What texture does *not* do to the rest of the pipeline

- **Alpha in an image is not opacity.** P10 owns `opacity` and the
  transparent pass; a PNG with transparency loads its RGB and ignores
  alpha in v2 (§3.1) until/unless a future plan explicitly wires
  `alpha: texture` — accepting the file must never silently punch holes.
- **Texture does not change culling, depth, or sorting.** Textured
  triangles use the identical z-buffer path.
- **Texture × emissive:** emissive (P10) is *added after* the multiply
  in §5.1 and is not textured in v2 (no emissive maps, §0 non-goals).

---

## 6. Image loading — formats, and browser vs. native

### 6.1 Format tiers (the dependency decision)

Fortran has no standard image decoding. Every native format below is
therefore either (a) decodable in pure Fortran in a few hundred lines, or
(b) a new foreign dependency — and the `Makefile`'s zero-dependency purity
is a feature of this project, not an accident.

| Format | Native (Fortran engine) | Browser | Tier / ruling |
|---|---|---|---|
| **PPM / PGM** (P3 ASCII, P6 binary; PGM → grey replicated to RGB) | ✅ Pure Fortran, ~150 lines, reuses the P3 knowledge already in `framebuffer_save_ppm` / `viewer.html` | via `Image` only if converted; Canvas decoder hand-written like the existing PPM viewer code | **Tier 1 — first textured milestone.** The test/debug format: the engine already *writes* it, so round-trip tests need no fixtures from elsewhere. |
| **BMP** (24-bit & 32-bit, uncompressed `BI_RGB`, bottom-up & top-down) | ✅ Pure Fortran, ~120 lines (header + row padding + BGR swap) | ✅ native `<img>` | **Tier 1.** The no-dependency way to load a "real" image a user exported from any editor. RLE-compressed BMP → explicit unsupported-variant error. |
| **PNG** | ⚠️ Only via optional C interop: bind `stb_image.h` (single-header, public domain — the least-bad dependency: one file, no build system) through `iso_c_binding`, compiled **only when** the builder opts in (`make TEXTURES_PNG=1`, §9.3). Without it, PNG input is the §8 "decoder not built" error, not a crash. | ✅ native, free, hardware-mature (`Image` / `createImageBitmap`) | **Tier 2.** The format users will actually write in the DSL (`texture: "file.png"` is the canonical example) — so the browser path supports it from its first textured milestone, and the native path documents exactly how to enable it. Never pretend pure-Fortran PNG (DEFLATE + filters) is a weekend job; it is explicitly not attempted. |
| **JPEG** | ⚠️ Same optional `stb_image` route as PNG (same binding, no extra dep) | ✅ native | **Tier 2**, same gate as PNG. Photos only — JPEG artefacts on flat colour/diagrams are a teaching point for the manual, not a code concern. |
| **GIF / WebP / AVIF / SVG / TGA / DDS / KTX** | ❌ | GIF/WebP/AVIF ✅ native in modern browsers; others ❌ | **Not promised anywhere.** Browser may *happen* to decode GIF/WebP through the generic `Image` path — that is platform behaviour, documented as "works in browser preview, not in native render", never a spec guarantee. SVG is rejected by name in both paths (it is a document, not a pixel grid; rasterizing it is a project, §12). |

**Interchange rule that follows:** a scene that must render identically
natively and in the browser uses Tier-1 formats, or Tier-2 with the
native PNG/JPEG build enabled. The compiler **warns** (`W-TEX-PORTABLE`)
when a scene's textures are browser-only under the current native build
configuration — portability surprises are exactly what beginners cannot
debug.

### 6.2 Native loading pipeline (Fortran + compiler)

```
DSL texture: "path"  →  compiler resolves path (§6.4), checks extension
  →  compiler emits texture table (path, wrap, filter) into generated code/scene data
  →  engine start: texture_load(path) per unique path:
        sniff magic bytes (NOT extension alone — a .png that is really a BMP
        loads as BMP or errors honestly; mismatched extension = warning)
        decode → Texture%pixels bottom-up (§2.2), RGB 0..255
        enforce limits (§6.5) → register in TextureTable
  →  any load failure = engine start-up error naming path + reason + format
     tried; no render with a half-loaded table, no magenta fallback by default
     (a --texture-fallback checker flag for layout work is §9.2-deferred sugar)
```

Decoding happens **once at start-up**, never per frame, never per triangle.
`stb_image` binding, when enabled, sits behind the same `texture_load`
interface as the pure-Fortran decoders — callers cannot tell which decoded
a file, and the build without it simply has two fewer registered formats.

### 6.3 Browser loading — two paths, one UV contract

**Path A — WebGL (target, owned by P06's runtime plan):**

- Load each texture with `Image`/`createImageBitmap` from the same
  relative path; on `load`, `texImage2D` with
  `UNPACK_FLIP_Y_WEBGL = true` (§2.2), `wrap`/`filter` mapped 1:1 from
  §5.3/§5.4 (`repeat→REPEAT`, `clamp→CLAMP_TO_EDGE`, `mirror→MIRRORED_REPEAT`;
  `linear→LINEAR`, `nearest→NEAREST`; no mipmaps in the first milestone,
  so no `GENERATE_MIPMAP` and NPOT + `repeat` is the forbidden combo §2.3
  — the loader rewrites it to `clamp` **with a console warning naming the
  texture**, or errors; pick error in strict mode, warning otherwise, but
  never WebGL's silent black texture).
- Loading is async; the viewer shows the material's flat colour until the
  texture arrives, then swaps — progressive, never a blocked first frame.
  A failed load shows the flat colour permanently + one console/`onError`
  report (browser parity with §6.2's "no silent magenta" is *not* required
  here: the browser is a preview surface, the native render is the
  deliverable — stated so nobody "fixes" the wrong one).

**Path B — Canvas 2D (fallback / current `viewer.html` lineage):**

- True per-pixel texturing on Canvas 2D requires either per-pixel
  `ImageData` rasterization (a port of the Fortran sampler — correct,
  including perspective, but a second sampler to keep in lockstep) or the
  classic clip-path + affine `setTransform` + `drawImage` per triangle
  trick (fast, but affine — §5.2's bending returns, and seams show).
- **Ruling:** Path B textured rendering is **deferred entirely** (§9.2).
  The 2D fallback renders textured materials as their flat material colour
  and badges the viewport `textures need WebGL preview` — honest
  degradation in the spirit of P06 §9, not an affine approximation
  presented as the texture feature. If a software-Canvas sampler is ever
  wanted, it is a port of §5 wholesale, specified then.

### 6.4 Path resolution & asset rules

- Paths in the DSL are **relative to the `.f3d` scene file's directory**,
  always. Not the CWD, not the engine binary, not an asset root — one
  rule, teachable in one sentence, identical in compiler, native engine,
  and browser (browser: relative to the scene JSON's URL).
- Forward slashes only in the DSL (`"textures/wood.png"`); the native
  loader translates if a platform ever needs it. Subdirectories allowed.
- `..` components that escape the scene directory are **rejected**
  (`E-TEX-PATH`, §7.3) in the compiler — scenes are shareable artifacts
  and must not read arbitrary files by construction. Absolute paths and
  URLs (`http://…`) are likewise rejected in v2 native; browser URL
  textures are a future, CORS-laden plan (§12), not a flag.
- Case: paths are matched case-sensitively as written; a not-found error
  includes a "did you mean" only if a case-insensitive sibling exists
  (the Windows-authored-scene-on-Linux trap — cheap to check, miserable
  to debug without).

### 6.5 Limits (enforced at load, named in errors)

| Limit | Value | Rationale |
|---|---|---|
| Max textures per scene | 32 (`MAX_TEXTURES`) | Matches P10's fixed-cap philosophy; counted by the compiler. |
| Max image dimension | 4096 per axis | Bounds a decompression/typo accident; teaching textures are ≤ 1024. |
| Max total texture memory | 64 MiB (sum of `W×H×3`) | This engine targets modest hardware (cf. P06 §5.3); mipmaps, when they land, count their +33% against the same budget. |
| Min dimension | 1×1 is legal | A 1×1 texture is a legitimate colour-swatch idiom. |

Exceeding any limit is a load/compile error naming the limit and the
actual value — never a truncation, clamp, or downscale performed quietly
(downscaling on request is what `repeat`/authoring tools are for).

---

## 7. DSL syntax — reserved in v1, live in v2

### 7.1 The one canonical form

Following P03's line-oriented surface and P10 §6's `key: value` material
props, the texture declaration is a property of a **material** (preferred —
reusable, P10 §6.2's binding rule) with an object-level shorthand that
desugars to an anonymous material:

```scene
# --- preferred: named material (P10 syntax family) ---
material crate {
  color:   #ffffff              # white = texture shows unmodified (§0 multiply rule)
  texture: "textures/crate.png"
}

object box : cube(2) {
  material: crate
  at: [0, 1, 0]
}

# --- shorthand: one-off texture on one object ---
object photo : plane(4, 3) {
  color:   #ffffff
  texture: "photo.bmp"          # desugars to an anonymous material holding
}                               # exactly { color, texture } for this object
```

And in P03's terse line dialect, the same statement on an object line —
the compiler accepts the prop in the same position a colour would go;
both dialects share the tokens below, only punctuation differs by dialect
as it already does for `color`:

```f3d
cube crate texture "textures/crate.png" colour white
plane floor texture "tiles.ppm" repeat 8 8
```

**`texture:` takes exactly one double-quoted string.** No bare words, no
variables (v1/v2 DSL has none), no string concatenation, no environment
expansion. If it isn't a quoted relative path, it isn't a texture
declaration — it is a parse error pointing at this rule.

### 7.2 Companion properties (all optional, all v2, all defaulted)

Inside the same material/object block as `texture:`:

| Prop | Values | Default | Meaning |
|---|---|---|---|
| `uv:` | `auto \| planar-x \| planar-y \| planar-z \| sphere \| cylinder` | `auto` | Generator override (§4.8). Ignored-with-warning if the geometry already carries file UVs (OBJ `vt` wins). |
| `wrap:` | `repeat \| clamp \| mirror` | `repeat` | §5.4, both axes. |
| `filter:` | `nearest \| linear \| mipmap` | `linear` | §5.3. `mipmap` is itself gated (§9.2) — writing it without that gate is its own not-yet error. |
| `repeat:` | two numbers `ru rv`, each > 0 | `1 1` | UV scale applied at generation/sampling: `uv' = uv × repeat + offset`. Named `repeat` (what it does) — the alias `scale:` is **not** accepted (P10 §6.4's one-name rule). |
| `offset:` | two numbers `ou ov` | `0 0` | UV translation, applied after `repeat`. |

Grammar sketch (this slice only, P10 §6.2 style):

```
texture_prop := "texture:" STRING
              | "uv:"     ("auto"|"planar-x"|"planar-y"|"planar-z"|"sphere"|"cylinder")
              | "wrap:"   ("repeat"|"clamp"|"mirror")
              | "filter:" ("nearest"|"linear"|"mipmap")
              | "repeat:" NUMBER NUMBER
              | "offset:" NUMBER NUMBER
STRING       := '"' <relative path, §6.4> '"'
```

A material may declare **at most one** `texture:`. A second one is a
duplicate-definition error, not last-one-wins — two diffuse maps is a
different feature (blending, §0 non-goals), and v2 will not fake it by
picking one.

### 7.3 Validation — compile-time, with line numbers (extends P10 §6.4)

| Input | Diagnostic |
|---|---|
| `texture:` present, textures not enabled (v1, or v2 without `--textures`) | **§8's reserved diagnostic** — the most important row in this table |
| Unquoted / empty path, absolute path, `..` escape, URL | `E-TEX-PATH` — reason + the §6.4 rule in one line |
| Extension/magic not in the build's format table (§6.1) | `E-TEX-FORMAT` — names the file, what it appears to be, and the supported list *for this build* (so the PNG-without-stb case reads as a build option, not a mystery) |
| File not found at compile time (compiler checks existence; engine re-checks at load) | `E-TEX-NOTFOUND` — resolved absolute location that was tried + case-sibling hint (§6.4) if any |
| Unknown `uv:`/`wrap:`/`filter:` value | Error listing the legal values (P10 precedent) |
| `repeat:` ≤ 0, or > 1024 | ≤ 0 = error; > 1024 = `W-TEX-REPEAT` precision warning (§2.5), compiles |
| Companion prop (`wrap:` etc.) with **no** `texture:` in the same block | `W-TEX-ORPHAN` warning — almost certainly a mistake; compiles (the props are inert data if a texture is added later) |
| 33rd distinct texture path | Cap error naming `MAX_TEXTURES = 32` (§6.5) |
| Dimensions/memory over §6.5 limits | Error at whichever stage (compile probe or load) measures it first, naming limit + actual |
| OBJ geometry with partial `vt` | `W-TEX-UVFALLBACK` for the affected faces (§4.8) |

---

## 8. v1 behaviour — colours only, syntax reserved, one clear diagnostic

This section is the **only** part of P14 that v1 implements, and it is
specified to the letter so every future compiler version says the same thing.

### 8.1 The default: hard error

Any `texture:` property (or `texture` prop in the line dialect), in any
position, in a v1 compile produces exactly one error per occurrence and
**no output files** (P03 §8's no-partial-output rule):

```
error[E-TEX-V1]: line 7: textures are not supported in v1
  |
7 |   texture: "textures/crate.png"
  |            ^^^^^^^^^^^^^^^^^^^^
  = this scene would need the v2 texture feature (--textures, see P14)
  = for v1, remove the texture: line and keep color: — the object
    renders in its flat colour, exactly as all v1 scenes do
```

- It is an **error, not a warning, by default** — following P03's
  reserved-primitive precedent (§9.6 there) and P10 §6.4. A warning that
  still produces a render teaches users that textures "sort of work" and
  the flat-colour result reads as a bug report waiting to happen.
- The error fires at **parse/validation time**, before any file access:
  v1 does not check whether `textures/crate.png` exists, does not sniff
  its format, does not load it. A missing file under a v1 scene gets
  E-TEX-V1, not E-TEX-NOTFOUND — the version problem is the first problem.
- Companion props (`wrap:`, `filter:`, `repeat:`, `offset:`, `uv:`) in a
  block **without** `texture:` get only the §7.3 orphan warning in v1 as
  in v2 (they are inert without a texture in every version). With a
  `texture:` present, E-TEX-V1 subsumes them — one error, not five.

### 8.2 The escape hatch: `--warn-textures` (migration aid, v1 only)

```
f3dc --warn-textures scene.f3d
  → warning[W-TEX-V1]: line 7: texture: ignored in v1 (colours only);
    object 'box' renders in its color: #ffffff
  → compile proceeds; texture: and its companion props are dropped;
    if the material/object has no color:, the P10 default (white) applies
    and the warning says so explicitly.
```

- Purpose: previewing/migrating a v2-authored scene on a v1 toolchain and
  seeing its layout in flat colour — a deliberate user choice, made on the
  command line, announced per texture. It is never the default, never
  implied by any other flag, and it **disappears in v2** (where
  `--no-textures`, §9.1, plays the symmetric role).
- The generated scene data under `--warn-textures` contains **no** texture
  record at all (not a disabled one) — v1 outputs stay byte-identical to
  a scene that never mentioned textures (§3.3's golden rule).

### 8.3 What v1 does *not* do with the syntax

No placeholder/checkerboard rendering, no loading the image to "validate
it for later", no emitting UVs "so v2 will be faster", no reserving the
file. Reservation lives in the grammar, the diagnostic, and §3.1's names —
that is sufficient, and each of those temptations is a v1 feature in
disguise with its own bugs.

---

## 9. The feature flag — `--textures` and its family

### 9.1 The main flag (compiler driver, v2+)

| Invocation | Behaviour |
|---|---|
| `f3dc scene.f3d` (v1) | Colours only. `texture:` → E-TEX-V1 (§8.1). `--warn-textures` is the only texture-related flag that exists. |
| `f3dc scene.f3d` (v2, no flag) | **Identical to v1**, including E-TEX-V1 (message now reads "pass --textures to enable"). Default-off is deliberate: enabling a per-pixel path + decoder for every legacy build is how goldens and build times regress without anyone deciding they should. |
| `f3dc --textures scene.f3d` (v2) | Textures compiled per §§3–7. The flag is recorded in the scene metadata (`"textures": true` capability note) so the runtime/engine can refuse a textured scene on an untextured build with E-TEX-V1's mirror image, instead of rendering it wrong. |
| `f3dc --no-textures scene.f3d` (v2) | Explicit off; overrides any config-file default-on. Same diagnostics as no-flag. Exists so build scripts can pin behaviour. |
| `--textures` passed to a **v1** binary | `error: --textures requires the v2 texture feature; this build is v1 (colours only)` — a flag must never be silently accepted-and-ignored (P10 §2). |
| Engine/viewer receives a textured scene but was built without texture support | Start-up error naming the scene's requirement and the build's capability; no partial render. (Browser Path A is always texture-capable for Tier-2 formats; Path B degrades per §6.3.) |

Configuration-file / environment defaults for the flag are a compiler-
driver question owned by the pipeline plan; if they exist, command line
wins, and the effective state is printed in the build log
(`textures: on (formats: ppm, pgm, bmp, png*, jpeg*)` — `*` = via optional
decoder, §9.3) so a build is never mysterious about which §6.1 tiers it
actually contains.

### 9.2 Sub-feature gates (each independently deferrable)

| Gate | Unlocks | If written/used without the gate |
|---|---|---|
| `--textures` | Everything in §§3–7 at Tier-1 formats, `nearest`/`linear`, all §5.4 wraps, all §4 generators | E-TEX-V1 (§8) |
| *(build option, §9.3)* | PNG/JPEG native decoding | E-TEX-FORMAT with the build-options wording (§7.3) |
| `--texture-mipmaps` (proposed; or `filter: mipmap` auto-requiring it) | `filter: mipmap`, mip generation at load | `filter: mipmap` → error naming the gate; other filters unaffected |
| *(no flag — P06 milestone)* | Browser WebGL textured preview | Browser shows flat colour + badge (§6.3 Path B ruling) until P06 lands it; native render unaffected |
| *(future plan, no flag reserved)* | Normal maps, atlases, URL textures, sRGB, alpha-from-texture | Their keywords (`normal:`, `bump:`…) are **not** reserved by this plan beyond P10's existing reserved-error treatment — a future plan reserves them properly rather than this one guessing their syntax |

Design rule for adding any future gate: **one flag, one diagnostic, one
§11 test.** A sub-feature that cannot state all three is not ready to be
a flag.

### 9.3 Build-time options (native decoder)

```make
make                  # Tier 1 only: PPM/PGM/BMP, pure Fortran, zero deps (default, always)
make TEXTURES_PNG=1   # + PNG/JPEG via vendored stb_image C binding (§6.1);
                      # build log and --version must report it; CI builds BOTH
                      # configurations so the no-decoder error path stays tested
```

The vendored header, if adopted, lives under `lib/` per the README layout,
is pinned to a named upstream version, and is the project's **only**
third-party code — adopting it needs its own explicit decision at v2
kickoff (this plan recommends it, and Tier 1 exists precisely so the
project is never *forced* into it to have textures at all).

---

## 10. Implementation sequence (v2 milestones; v1 = §8 only)

| # | Milestone | Contents | Exit test (§11) |
|---|---|---|---|
| V1 | **Reserve & reject** | Grammar reservation, E-TEX-V1 + `--warn-textures` (§8), §3.1 name reservations | §11.1 |
| T1 | **UVs without images** | `vec2`-equivalent storage (`Triangle%uv`), §4 generators for cube + plane + sphere, JSON/OBJ export (§3.3), a debug mode rendering UVs *as colour* (`u→red, v→green`) so generation is visually verifiable before any decoder exists | §11.2 UV-number tests + debug-render eyeball vs. §4 tables |
| T2 | **Tier-1 sampling** | `texture.f90` (PPM/PGM/BMP loaders), `TextureTable`, perspective-correct textured raster path (§5), `nearest` + `linear`, all wraps, `--textures` flag + capability plumbing (§9.1) | §11.3 sampling tests incl. test-card orientation |
| T3 | **Remaining generators + browser** | §4.3/§4.4/§4.6/§4.7 generators, OBJ `vt` import + fallback, P06 WebGL textured preview (§6.3 Path A), `W-TEX-PORTABLE` | §11.2 (all primitives), §11.4 parity stills |
| T4 | **Tier-2 formats (optional)** | `TEXTURES_PNG=1` stb binding, PNG/JPEG native (§9.3) | §11.3 with PNG fixtures; both build configs in CI |
| T5 | **Mipmaps (optional, separately gated)** | §9.2 gate, mip generation + trilinear sampling | §11.3 grazing-angle comparison; `linear` results unchanged |

T1 is the highest-value milestone after V1 and needs no image code at
all — it proves the convention (§2) end-to-end. T4/T5 are cut-able
forever without invalidating T1–T3 scenes (their content degrades to
§7.3/§9.2 diagnostics, never to wrong pixels).

---

## 11. Tests & acceptance

### 11.1 v1 (ship gate for this plan's v1 slice)

1. Scene with `texture:` → exactly E-TEX-V1 (line, path excerpt, remedy),
   exit non-zero, **no output files written**.
2. Same scene with `--warn-textures` → W-TEX-V1 per texture, render
   produced, output byte-identical to the same scene with texture lines
   deleted.
3. Scene without any texture mention → unchanged v1 golden
   (`output_render.ppm` for the demo scene), byte-identical.
4. `--textures` on the v1 binary → the §9.1 unknown-capability error.

### 11.2 UV generation (T1/T3 — pure numbers, no images)

5. Cube: all 12 triangles' UVs match §4.1's face table exactly.
6. Sphere: pole/equator/seam sample vertices match §4.2's formulas
   (tolerance 1e-9); seam column exists in duplicate with `u ∈ {0, 1}`.
7. Cylinder/cone/plane/pyramid/torus: equivalent pinned samples per §4,
   including cap patches and the pyramid apex `(0.5, 1)`.
8. OBJ with `vt` round-trips: import → export `vt` values unchanged.

### 11.3 Sampling & loading (T2/T4)

9. **Orientation test card:** an asymmetric image (letter + arrow +
   distinct corners) on a head-on plane and on the cube's north face
   reads **correctly** (not mirrored, not flipped) in the native render
   and in the WebGL preview — the §2.2 flip rule, proven.
10. Perspective: a long plane at a grazing angle, checker texture —
    straight checker lines stay straight (affine interpolation fails
    this visibly, §5.2).
11. `nearest` vs. `linear` on a 2×2 test texture produce the §5.3/
    §2.3 hand-computed pixel values at named sample points (±1 LSB).
12. Each `wrap:` mode on `repeat: 2 2` plane matches its §5.4 formula
    at the borders; `mirror` shows no seam at integer boundaries.
13. Multiply rule: textured material with `color: #808080` renders the
    §11.3.9 card at half brightness (±1 LSB) vs. white.
14. Loaders: PPM P3 + P6, PGM, BMP 24/32 (both row orders) decode a
    known fixture to identical `Texture%pixels`; PNG/JPEG fixtures
    likewise under `TEXTURES_PNG=1`, and produce E-TEX-FORMAT (not a
    crash) without it; magic/extension mismatch warns (§6.2).
15. Limits: 33rd texture, 4097-px image, and over-budget total each
    produce their §6.5 named error.

### 11.4 Compatibility & parity

16. Golden: every §11.1.3 scene re-rendered under v2 with and without
    `--textures` (no textured materials) is pixel-identical.
17. Native vs. browser still of the §11.3.9 scene, same camera: texel
    colours agree within rounding at sampled pixels (the §2 contract).
18. Error catalogue: every row of §7.3 produces its diagnostic in a
    golden-message test (wording is part of the spec, per §8.1).

---

## 12. Explicitly deferred beyond v2 (future plans, not flags)

Normal/bump/specular/emissive maps · texture atlases & sprite sheets
(`uv:` sub-rectangles) · cube/environment maps · procedural textures ·
URL/remote textures · SVG textures · texture alpha as opacity ·
anisotropic filtering · separate `wrap-u`/`wrap-v` · sRGB/gamma-correct
sampling · compressed formats (KTX/DDS) · texture animation (offset
scrolling is *expressible* via P09-style animation of `offset:` — noted
as a free consequence, not a v2 commitment) · UV editing/visualisation
tooling beyond T1's debug render.

## 13. Risks & open questions

- **`stb_image` adoption (T4)** is the project's first third-party code.
  If the v2 kickoff rejects it, Tier 1 still ships and PNG stays
  browser-only behind `W-TEX-PORTABLE` — the plan survives either ruling,
  but the ruling must be made *before* T2's loader interface freezes,
  because the interface (§6.2) is designed to hide the decoder choice.
- **Interaction with P10 milestones:** `texture_id` (§3.1) assumes P10's
  material record exists. If textures are scheduled before P10's M1, the
  field lives temporarily on `Mesh` — acceptable, but the two plans must
  not *both* invent a material home. Owner: whoever schedules first.
- **Per-pixel cost:** §5 makes textured triangles per-pixel work in a CPU
  rasterizer on modest hardware (cf. P10 §8.6). At 640×480 with a
  full-screen textured plane this is noticeable but bounded (one sample +
  a few multiplies per pixel); the manual should steer big textured
  surfaces to `nearest` if a scene is slow. No threading in v2.
- **JSON size:** per-corner UVs grow `scene.json` by ~50% for textured
  scenes. Acceptable at teaching scale; P06 §13's binary-format
  discussion owns anything larger.
- **The `color` spelling:** §7.1 examples use P10's `color:` inside
  blocks and P03's `colour` on lines — both dialects keep their existing
  alias rule; `texture:` itself has **no** alias and no localised
  spelling, deliberately (file paths are the least portable part of a
  scene; one keyword spelling keeps docs and errors unambiguous).
- **Open — checker fallback flag** (`--texture-fallback` rendering a
  magenta/black checker for missing files during layout work): genuinely
  useful in production pipelines, genuinely dangerous as a default.
  Deferred as §9.2 sugar; if adopted it must watermark the build log per
  use, like `--warn-textures` does.

---

*End of P14. Summary for the roadmap: v1 reserves `texture: "file.png"`,
rejects it with E-TEX-V1 (or drops it loudly under `--warn-textures`), and
renders colours only; v2 turns the same line on with `--textures`, UVs
generated per primitive (§4), Tier-1 formats natively and PNG/JPEG in the
browser (native via one optional binding), perspective-correct sampling,
and every sub-feature independently gated so deferral never becomes
breakage.*
