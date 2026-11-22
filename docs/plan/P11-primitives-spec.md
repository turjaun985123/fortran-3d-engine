# P11 — Primitives Spec: Sphere / Cylinder / Plane / Pyramid / Cone / Torus

> **Status:** Planning only — no engine code changed by this document.
> **Repo ground truth audited:** `src/mesh.f90`, `src/math_3d.f90`,
> `src/renderer.f90`, `src/main.f90`, and `docs/plan/P03-dsl-grammar.md`
> (grammar, defaults, reserved primitives), `docs/plan/P10-materials-lighting.md`
> (§3.3 vertex normals / shading modes).
> **Goal served:** the easy 3D compiler — each primitive is **one DSL word**,
> renders sensibly with **zero properties written**, and is **one Fortran
> subroutine** following the exact pattern of the one constructor that exists.

---

## 0. Baseline: the cube is the template, not an exception

Everything in this spec is derived from `create_cube(m, size)` in
`src/mesh.f90`. New primitives must match it on every point below, or this
document must say why they differ.

| Fact (from `src/mesh.f90` today) | Consequence for all primitives |
|---|---|
| `Mesh` is a flat triangle soup: `num_triangles` + allocatable `triangles(:)`; no vertex/index arrays | Constructors **precompute the exact triangle count, `allocate` once, fill by cursor index** — no appends, no reallocation, no shared vertices |
| `Triangle` = `v(3)` (`vec3`), one face `normal` (`vec3`), `color(3)` integer RGB 0–255, default white `[255,255,255]` | There are **no vertex normals in the type today**. §2.3 specifies both the face normal (now) and the analytic per-vertex normal (for the `vnormal(3)` field P10 §8.2 proposes) |
| `create_cube` is a `subroutine`, `type(Mesh), intent(inout)`, geometry args `real(dp), intent(in)`, `deallocate`s any existing triangles first | Every `create_*` below has the same shape: `(m, <dims…>, <optional detail…>)`, same deallocate-first behaviour |
| Normals are **not** hand-written: a final loop sets `triangles(i)%normal = compute_triangle_normal(v1, v2, v3)` for every `i` | Same final loop for every new primitive, verbatim. Hand-written normals are forbidden for the face normal — winding and normal can then never disagree |
| Colours are set inside the constructor (cube: six-face palette by index) | New constructors take **no colour argument** (§2.4). DSL colour is applied after creation, uniformly, by the compiler lowering |
| Cube is centred on the origin, `size` = full edge length (half = `size/2`) | Every primitive is centred on the origin (§2.1) and `size` means **overall extent**, never radius/half-size (§2.2) |
| Renderer (`src/renderer.f90`) recomputes the world face normal itself, shades flat per face (`0.25 + 0.75·diffuse`), and culls by screen-space winding (`… <= 0 → cycle`) | Winding is a correctness requirement, not style: **counter-clockwise as seen from outside** (§2.3). A reversed primitive is invisible, not just dark |
| Up axis is +Y (`camera.f90` via P03 §6.1; `mat4_rotate_y` is the spin axis) | All rotational primitives are built **around the Y axis**; the plane lies in XZ (§5) |

Cube reference numbers, for calibration: `size` default `2` (P03 §6.2),
**12 triangles**, no segments, flat axis normals.

---

## 1. Summary table (defaults are the contract)

Defaults assume the P03 default object size of `2`. "Segments" naming is
defined in §2.5. Triangle counts are exact, not estimates — each is an
acceptance test (§10).

| Primitive | DSL word | Primary size (default) | Other dims (default) | Segments (default) | Triangles (default) | Formula |
|---|---|---|---|---|---|---|
| Cube *(exists)* | `cube` | `size 2` (edge) | — | — | **12** | `12` |
| Sphere | `sphere` | `radius 1` (= `size 2`) | — | `segments 16`, `rings 12` | **352** | `2·S·(R−1)` |
| Cylinder | `cylinder` | `radius 1` (= `size 2`) | `height 2`, capped | `segments 16`, `rings 1` | **64** | `2·S·H + (capped ? 2·S : 0)` |
| Plane | `plane` | `width 2` (= `size 2`) | `depth 2` | `segments 1 1` | **2** | `2·WS·DS` |
| Pyramid | `pyramid` | `size 2` (base width) | `height 2`, `sides 4` | n/a (`sides` plays that role) | **6** | `N + (N−2)` = `2N−2` |
| Cone | `cone` | `radius 1` (= `size 2`) | `height 2`, capped (base only) | `segments 16`, `rings 1` | **32** | `S·H + (capped ? S : 0)` |
| Torus | `torus` | `radius 0.75` (ring), `tube 0.25` (= `size 2` outer) | — | `segments 16`, `rings 12` | **384** | `2·S·T` |

Cost note (honest): sphere (352) and torus (384) are ~30× the cube's
triangle count. That is fine for this software rasterizer — its cost is
dominated by covered pixels, not triangles, at teaching-scene scale — but
it is why the defaults are 16-wide and not 32-wide. `detail` (§2.5) is the
user's one-word escape hatch in both directions.

---

## 2. Rules common to all six primitives

### 2.1 Placement and axes

- Geometry is generated **centred at the local origin**, exactly like the
  cube. The DSL `at` / `rotate` / `size` lowering then applies the model
  matrix (`mat4_translation × mat4_rotate_* × mat4_scale` composition, P03
  §7). Constructors know nothing about position, rotation, or scene scale.
- Vertical extent is centred too: cylinder, cone, and pyramid span
  `y ∈ [−height/2, +height/2]` (base at `−height/2`, apex/top at
  `+height/2`) — **not** base-at-0. Rationale: `at 0 0 0` must behave the
  same for every primitive; a base-at-0 cone would sit half-sunk next to a
  centred cube in the same scene. A user who wants it on the floor writes
  `at 0 1 0` for the default height, same idiom as the cube.
- Sphere and torus are centred in all three axes. Plane lies in the XZ
  plane at `y = 0` (§5.1 gives the reasoning).

### 2.2 `size` vs `radius` — one dimension, two spellings, never both

P03 §4 already gives objects both `size` and `radius` props, and P03 §6.2
defines `size` for a sphere as its diameter. This spec generalises that
into a single rule:

> **`size` always names the overall extent a beginner would measure with a
> ruler; `radius` names the half-extent. They are two spellings of the same
> dimension. Giving both in one statement is an error.**

| Primitive | `size` means | Relation |
|---|---|---|
| Sphere | diameter | `radius = size/2` |
| Cylinder / cone | base diameter | `radius = size/2` |
| Torus | **outer** diameter | `size = 2·(ring_radius + tube)`; with only `size`, the default 3:1 ring:tube ratio is kept (`ring = 3·size/8`, `tube = size/8`) |
| Pyramid | base width (square base: width = depth) | no `radius` spelling |
| Plane | width (square if `depth` omitted) | no `radius` spelling |
| Cube | edge (existing) | — |

- Error (P03 §1 principle 7, plain English, with line number):
  `line N: 'size' and 'radius' both set the width of a sphere — give only one`.
- `height`, where a primitive has one, **defaults to the resolved `size`**
  (which itself defaults to `2`). So `cylinder size 4` is a 4-wide, 4-tall
  cylinder — uniform, predictable — and `cylinder size 4 height 1` is the
  explicit squat form. Height never defaults to a hidden constant unrelated
  to what the user wrote.
- Validation (parse time, per P03 §4.1): every dimension `> 0`;
  torus additionally `tube < ring_radius` is **not** required — `tube ≥ ring`
  is legal (a spindle/lemon torus, hole closed) and must not error; only
  `tube > 0` and `ring_radius > 0` are checked. Fortran-side defensive rule
  in §9.3 covers unvalidated direct callers.

### 2.3 Normals and winding

Two different normals must not be conflated:

1. **Face normal (exists today, mandatory).** After filling all vertices,
   run the cube's loop: `normal = compute_triangle_normal(v(1), v(2), v(3))`
   (`vec3_cross(v2−v1, v3−v1)`, normalised). This is the only normal the
   current renderer effectively uses (it recomputes the same quantity in
   world space), and it gives every primitive correct flat shading for free.
2. **Analytic vertex normals (specified now, stored when P10 lands).**
   P10 §3.3/§8.2 proposes `Triangle%vnormal(3)`, defaulting to the face
   normal. When that field exists, each constructor below must also fill it
   from the closed-form column in its section — **never** by averaging face
   normals (averaging is the fallback for imported soup, P10 §3.3, not for
   geometry whose true normal is known exactly). Until that field exists,
   this column is normative for the *tests* (§10: sample the formula, not a
   stored field) and ignored by the constructor body. Because `Mesh` is a
   soup, the same position appearing in adjacent triangles carries that
   triangle's copy of the analytic normal — at smooth seams the copies
   agree (that is what makes the surface shade smooth under `lambert`/
   `phong`); at intended creases (cap rims, pyramid edges, §2.3.1) they
   deliberately do not, because the vertices are generated per-part.

**Winding invariant (all primitives):** vertices are ordered so that
`compute_triangle_normal` points **away from the interior** (outward).
Equivalently, each triangle is counter-clockwise when viewed from outside
the solid. This is testable without rendering (§10, test 3) and is the
single most likely implementation bug — the renderer's screen-space
culling will silently delete a wrongly-wound part.

#### 2.3.1 Creases are made by construction, not by a crease pass

Caps, bases, and pyramid faces are generated as **separate vertex sets**
from the curved/sloped part that meets them, even where positions coincide.
Consequences a beginner can rely on (mirrors P10's 60° crease rule, achieved
structurally): a capped cylinder shades as *smooth side, flat caps, hard
rim* — never a melted rim — in every shading mode, with no special-casing
in the renderer.

### 2.4 Colour

- Constructors set every triangle's `color` to white `[255,255,255]` (the
  `Triangle` default), except where a section below says otherwise.
  The cube's six-face palette is a cube legacy, **not** a pattern to copy:
  inventing per-part palettes for spheres would make `sphere` with no
  colour written render a patchwork the user never asked for.
- A DSL colour (`sphere red`, P03 §6.3) is applied by the compiler lowering
  after construction, overwriting `color` on all triangles uniformly —
  exactly the mental model P03 §6.3 already promises ("a single named
  colour tints all faces"). No `create_*` signature grows a colour
  parameter; if a future Fortran caller wants a tint, it loops over
  `m%triangles` itself.
- Pyramid is the one arguable exception (cube-like flat faces) — ruling:
  **white like the others.** A user who wants the cube's party trick
  already has the cube.

### 2.5 Segments, `detail`, and the new DSL props

P03's `object-prop` list (`at pos size radius height colour color rotate
rot`) has no way to express resolution or the torus/pyramid/plane shapes.
This spec adds the following props to that EBNF list — **grammar additions
P03 must absorb; no existing prop changes meaning**:

```ebnf
object-prop  =/ "segments" , number              (* around-count S, §2.5.1 *)
              | "rings" , number                 (* second count: sphere bands / cyl-cone height bands / torus tube *)
              | "width" , number                 (* plane only *)
              | "depth" , number                 (* plane only *)
              | "tube" , number                  (* torus only: tube radius *)
              | "sides" , number                 (* pyramid only: base sides N *)
              | "detail" , ("low" | "med" | "high")  (* preset for segments+rings *)
              | "capped" | "open" ;              (* cylinder/cone only; default capped *)
```

1. **`segments` = the count around the Y axis** (sphere, cylinder, cone,
   torus). For the plane, `segments n` sets both subdivision counts, and
   `segments n m` — the one two-number form — sets width/depth counts
   separately; `rings` is not used by the plane. For the pyramid,
   `segments` is **not** accepted; the count-like prop is `sides`, because
   a beginner counts a pyramid's sides, not its segments.
2. **`rings` = the second count**: sphere latitude bands, cylinder/cone
   height bands, torus tube cross-section count. (Names deliberately avoid
   the Three.js `widthSegments`/`heightSegments`/`tubularSegments` tangle:
   in this DSL, `segments` always goes *around*, `rings` always goes
   *across/over*.)
3. **`detail` presets** (the beginner path; explicit `segments`/`rings`
   override it, and giving both a preset and an explicit count for the
   *same* axis is the §2.2-style conflict error):

   | Primitive | `detail low` | default (`med`) | `detail high` |
   |---|---|---|---|
   | Sphere | `segments 8 rings 6` → 80 tris | `16 / 12` → 352 | `32 / 24` → 1 472 |
   | Cylinder | `segments 8` → 32 tris (capped) | `16` → 64 | `32` → 128 |
   | Cone | `segments 8` → 16 tris (capped) | `16` → 32 | `32` → 64 |
   | Torus | `segments 10 rings 8` → 160 tris | `16 / 12` → 384 | `32 / 24` → 1 536 |
   | Plane / pyramid | no effect (counts are structural, not smoothness) | — | — |

4. **Minimums** (parse errors, plain English): `segments ≥ 3` for revolved
   primitives (`segments 2` cannot enclose volume), `rings ≥ 2` for sphere,
   `rings ≥ 1` for cylinder/cone, `rings ≥ 3` for torus, plane segment
   counts `≥ 1`, pyramid `sides ≥ 3`. Error form:
   `line N: a sphere needs at least 3 segments — try: segments 16`.
   There is **no maximum** in the grammar; the compiler should warn (not
   error) above 10 000 triangles for one primitive, naming the count it
   computed from the §1 formulas — beginners typing `segments 1000` deserve
   to be told they asked for ~2 000 000 torus triangles *before* the render.

### 2.6 What is *not* a parameter in v1

Elliptical/non-uniform radii (`radius` is one number; non-uniform shape is
the model matrix's `scale`, P03 §4 `scale` action), sphere partial arcs
(`phiStart`-style), open-ended sphere, cylinder with different top/bottom
radii as a *user* prop (it exists only as the cone's internal construction,
§8.2), torus arc, plane orientation prop (fixed by §5.1), pyramid apex
offset. Each was omitted because it needs a word a beginner does not yet
have; none blocks a v2 addition under a new keyword.

---

## 3. Sphere

### 3.1 Parameters

| Parameter | DSL | Fortran arg | Default | Meaning |
|---|---|---|---|---|
| Radius | `radius r` or `size 2r` | `radius` | `1.0_dp` | Centre to surface |
| Around segments | `segments S` | `radial_segs` | `16` | Longitude divisions |
| Latitude rings | `rings R` | `height_segs` | `12` | Bands from top pole to bottom pole |

### 3.2 Construction

UV sphere around Y. For `j = 0..R` (latitude, `φ = π·j/R` from the +Y pole)
and `i = 0..S−1` (longitude, `θ = 2π·i/S`):

```
point(θ, φ) = ( radius·sinφ·cosθ , radius·cosφ , radius·sinφ·sinθ )
```

- **Poles are fans, not collapsed quads:** the top row is `S` triangles
  (pole vertex + first ring), the bottom row likewise; the `R−2`
  intermediate bands are `S` quads = `2S` triangles each. Collapsing a
  quad row onto the pole would create zero-area triangles whose
  `compute_triangle_normal` is the zero vector — forbidden everywhere in
  this spec (§9.2, rule G3).
- Pole vertices are duplicated per fan triangle (soup, §0) — positions
  identical, analytic normals identical too, so no seam artefact.
- The longitude seam (`θ = 0` vs `2π`) is likewise duplicated positions
  with identical normals: invisible in this renderer (no textures/UVs).

**Triangle count:** `S (top) + 2S·(R−2) (bands) + S (bottom) = 2·S·(R−1)`.
Default: `2·16·11 = ` **352**.

### 3.3 Normals

- Face: common loop (§2.3).
- Analytic vertex: `normalize(position) = position / radius` — radially
  outward at every vertex, pole vertices `(0, ±1, 0)`.

### 3.4 DSL

```f3d
sphere red                                # r=1, 16×12, 352 tris, at origin
sphere ball blue at 0 1 0 radius 1.5
sphere small size 1 detail low            # diameter 1 → r=0.5, 8×6, 80 tris
sphere big segments 48 rings 32           # 2·48·31 = 2 976 tris
```

### 3.5 Fortran signature

```fortran
subroutine create_sphere(m, radius, radial_segs, height_segs)
    type(Mesh), intent(inout) :: m
    real(dp),   intent(in)    :: radius
    integer,    intent(in), optional :: radial_segs   ! default 16
    integer,    intent(in), optional :: height_segs   ! default 12
```

Segment args are `optional` with `present()` fallbacks so a Fortran caller
can write `call create_sphere(m, 1.0_dp)` and get the DSL default mesh;
the compiler lowering always passes all arguments explicitly. This
optional-detail pattern is used by every signature in this spec:
**primary dimensions are required and positional (like cube's `size`);
resolution/cap args are optional and carry the table defaults.**

---

## 4. Cylinder

### 4.1 Parameters

| Parameter | DSL | Fortran arg | Default | Meaning |
|---|---|---|---|---|
| Radius | `radius r` or `size 2r` | `radius` | `1.0_dp` | Both caps (equal — see §2.6) |
| Height | `height h` | `height` | resolved `size` (= `2`) | `y ∈ [−h/2, +h/2]` |
| Around segments | `segments S` | `radial_segs` | `16` | Side divisions |
| Height bands | `rings H` | `height_segs` | `1` | Side subdivisions along Y |
| Caps | `capped` / `open` | `capped` | `.true.` | Top **and** bottom caps |

### 4.2 Construction

Side: for band `j = 0..H−1` between `y_j = −h/2 + h·j/H` and `y_{j+1}`,
`S` quads (`point(θ, y) = (radius·cosθ, y, radius·sinθ)`), 2 triangles
each. Caps (if capped): each cap is a **fan** of `S` triangles around a
centre vertex at `(0, ±h/2, 0)` — a fan, not an `(S−2)` polygon
triangulation, because the fan keeps every cap triangle's winding and
normal trivially uniform and matches the cone/sphere pole pattern (§9.1).
Cap vertices are distinct from side vertices (§2.3.1).

**Triangle count:** side `2·S·H`; caps `2·S` if capped.
Default (capped, `H=1`): `32 + 32 = ` **64**. `open`: **32**.

### 4.3 Normals

- Face: common loop.
- Analytic vertex: side `(cosθ, 0, sinθ)` (pure radial, independent of
  `y`); top cap `(0, +1, 0)`; bottom cap `(0, −1, 0)`. Rim vertices exist
  in both side and cap copies with their respective normals (§2.3.1).

### 4.4 DSL

```f3d
cylinder green                            # r=1, h=2, capped, 64 tris
cylinder pole at 2 0 0 radius 0.25 height 5
cylinder pipe open radius 1 height 3      # a tube: 32 tris, see-through ends
cylinder flat size 4 height 0.5           # r=2, h=0.5 — a disc/coin
```

### 4.5 Fortran signature

```fortran
subroutine create_cylinder(m, radius, height, radial_segs, height_segs, capped)
    type(Mesh), intent(inout) :: m
    real(dp),   intent(in)    :: radius, height
    integer,    intent(in), optional :: radial_segs   ! default 16
    integer,    intent(in), optional :: height_segs   ! default 1
    logical,    intent(in), optional :: capped        ! default .true.
```

---

## 5. Plane

### 5.1 Orientation ruling (the one real decision here)

The plane lies in the **XZ plane, normal +Y — it is a floor**, not a wall.
Reasons, in order of weight: (1) +Y is up in this engine, and the first
thing a beginner wants a plane for is ground under an object (P10 §7.2's
blob shadow already assumes a ground plane at `y = 0`); (2) a wall plane
is one `rotate 90 0 0` away, while a floor that had to be rotated into
place would be a day-one stumbling block; (3) P03's default camera at
`(3, 2.5, 4)` looks *down* at the origin — an XZ plane is visible in the
default render, an XY plane at the origin is seen nearly edge-on from
some angles and backface-culled from behind.

Consequences, stated honestly: the plane is **single-sided** in v1 (the
renderer culls back faces; there is no `double_sided` until P10 §3.5
lands). From below, it is invisible. The DSL manual must say
*"a plane is a floor you look down on"* in one sentence. A vertical
backdrop is `plane … rotate 90 0 0`.

### 5.2 Parameters

| Parameter | DSL | Fortran arg | Default | Meaning |
|---|---|---|---|---|
| Width (X) | `width w` or `size w` | `width` | `2.0_dp` | `x ∈ [−w/2, +w/2]` |
| Depth (Z) | `depth d` | `depth` | = `width` | `z ∈ [−d/2, +d/2]` |
| Subdivisions | `segments WS [DS]` | `width_segs`, `depth_segs` | `1`, `1` | Grid cells per axis |

`size` sets width **and** depth (a square) unless `depth` is also given:
`plane size 10` is the 10×10 ground; `plane width 10 depth 4` is the
rectangle. `width` without `depth` leaves depth = width (square) — one
rule, stated once: *an omitted second horizontal dimension copies the
first*, the same rule as `height` in §2.2.

### 5.3 Construction

Grid over `x ∈ [−w/2, +w/2]`, `z ∈ [−d/2, +d/2]`, `y = 0`; each cell is a
quad split into 2 triangles, wound so `compute_triangle_normal` = +Y
(§2.3 invariant — with `v1=(−w/2, 0, −d/2)`, `v2=(−w/2, 0, +d/2)`,
`v3=(+w/2, 0, +d/2)` as the cell's first triangle, the cross product
`(v2−v1)×(v3−v1)` is `+Y`; implementers verify against §10 test 3
rather than trusting any single listing here).

**Triangle count:** `2·WS·DS`. Default: **2**. Subdivisions exist for
future displacement/vertex-colour work and for P10 `lambert`/`phong`
evaluation density; in flat shading today they are visually identical —
the manual should not pretend otherwise.

### 5.4 Normals

Face and analytic vertex normals are both `(0, +1, 0)` everywhere.

### 5.5 DSL

```f3d
plane gray                                # 2×2 floor, 2 tris
plane ground size 20 colour green         # the classic ground
plane backdrop width 8 depth 3 at 0 2 -4 rotate 90 0 0
```

(`gray`/`green` are in the P03 §6.3 palette; note `colour`/`color` both
work per P03, and a plane named `ground` is just a name.)

### 5.6 Fortran signature

```fortran
subroutine create_plane(m, width, depth, width_segs, depth_segs)
    type(Mesh), intent(inout) :: m
    real(dp),   intent(in)    :: width, depth
    integer,    intent(in), optional :: width_segs    ! default 1
    integer,    intent(in), optional :: depth_segs    ! default 1
```

---

## 6. Pyramid

### 6.1 Parameters

| Parameter | DSL | Fortran arg | Default | Meaning |
|---|---|---|---|---|
| Base size | `size s` | `base_size` | `2.0_dp` | Base width (= depth for the default square base) |
| Height | `height h` | `height` | resolved `size` (= `2`) | Base `y = −h/2`, apex `y = +h/2` |
| Base sides | `sides N` | `base_sides` | `4` | `N ≥ 3`; 4 = classic square pyramid |

### 6.2 Construction

Regular `N`-gon base in the XZ plane at `y = −h/2`, vertices
`( (s/2)·cosθ_k , −h/2 , (s/2)·sinθ_k )` with `θ_k = 2πk/N` — note
`base_size` is the base's **circumscribed width** (centre-to-corner × 2)
for `N ≠ 4`; for `N = 4` the corners sit at `(±s/2, ±s/2)` exactly, i.e.
the first base vertex is placed at `θ = 45°` for `N = 4` so the default
pyramid's base edges are axis-aligned like the cube's. (For `N ≠ 4`,
starting angle is implementer's choice, fixed at `θ_0 = π/N` — flat side
facing +Z — and recorded here so renders are reproducible.)

- **Sides:** `N` triangles, each `(base_k, base_{k+1}, apex)` with
  `apex = (0, +h/2, 0)`. Each side gets its own apex copy (soup) so side
  face normals stay flat and distinct (§2.3.1).
- **Base:** fan/triangulation of the `N`-gon as `N−2` triangles around
  base vertex 0, normal −Y, using base-only vertex copies.

**Triangle count:** `N (sides) + (N−2) (base) = 2N−2`.
Default (`N=4`): `4 + 2 = ` **6**. (`sides 3` → 4, a tetrahedron-like
triangular pyramid; `sides 6` → 10.)

No base-omitted (`open`) form in v1: a pyramid seen from any default
camera angle shows its sides; an open base is an invisible saving of 2
triangles and one more keyword. If it is ever wanted, it follows the
cylinder/cone `open` spelling.

### 6.3 Normals

- Face: common loop — this is the *only* normal that matters here.
- Analytic vertex: **equal to the face normal for every vertex**
  (pyramids are flat-shaded by definition in this spec; the apex must
  never be smoothed — a smoothed apex is the classic "melted pyramid"
  bug). If P10's welding/averaging helper (`compute_vertex_normals`) is
  ever run over a pyramid mesh, its 60° crease rule must leave these
  edges split; the constructor-side guarantee is that it never needs to,
  because it writes the face normal into `vnormal` itself.

### 6.4 DSL

```f3d
pyramid yellow                            # square, 2 wide, 2 tall, 6 tris
pyramid egypt at 0 1 0 size 4 height 3
pyramid gem sides 6 size 1 height 1.5     # hexagonal pyramid, 10 tris
pyramid spike sides 3 height 4 size 1
```

Note on the `egypt` line: with centred height (§2.1), sitting a height-3
pyramid exactly on a `y = 0` floor takes `at 0 1.5 0`. The manual should
show that arithmetic once; it is the price of one placement rule for all
primitives, and this spec judges it lower than per-primitive exceptions.

### 6.5 Fortran signature

```fortran
subroutine create_pyramid(m, base_size, height, base_sides)
    type(Mesh), intent(inout) :: m
    real(dp),   intent(in)    :: base_size, height
    integer,    intent(in), optional :: base_sides    ! default 4
```

---

## 7. Cone

### 7.1 Parameters

| Parameter | DSL | Fortran arg | Default | Meaning |
|---|---|---|---|---|
| Base radius | `radius r` or `size 2r` | `radius` | `1.0_dp` | At `y = −h/2` |
| Height | `height h` | `height` | resolved `size` (= `2`) | Apex at `y = +h/2` |
| Around segments | `segments S` | `radial_segs` | `16` | Side divisions |
| Height bands | `rings H` | `height_segs` | `1` | Side subdivisions along the slope |
| Base cap | `capped` / `open` | `capped` | `.true.` | Base disc only — the apex end has no cap |

### 7.2 Construction

A cone is a cylinder whose top radius is 0 (§8.2 shares the code). Ring
at height fraction `t ∈ [0, 1]`: `y = −h/2 + h·t`,
`radius(t) = radius·(1−t)`. Side bands between successive rings are quads
(2 triangles) **except the top band**, which ends on the apex: it is `S`
triangles (fan onto per-triangle apex copies), never `S` quads with a
collapsed edge (§3.2's zero-area prohibition). Base cap (if capped): `S`
fan triangles around `(0, −h/2, 0)`, separate vertices (§2.3.1).

**Triangle count:** side `2·S·(H−1) + S` (bands below the apex + apex fan)
`= S·(2H−1)`; plus `S` if capped.
Default (`H=1`, capped): side is *only* the apex fan = `16`, cap `16` →
**32**. `open`: **16**. (`H=2`, capped: `48 + 16 = 64`.)

### 7.3 Normals

- Face: common loop.
- Analytic vertex (side): the slope tilts the normal upward. With ring
  angle `θ`, the true surface normal is

  ```
  n(θ) = normalize( ( cosθ·height , radius , sinθ·height ) )
  ```

  i.e. `normalize( radial·height + ŷ·radius )` — **not** the cylinder's
  pure radial normal. Using the radial normal on a cone is a real,
  visible lighting error (a 45° cone's side would shade like a tube);
  this formula is a §10 test case. Apex copies carry the same `n(θ)` of
  their triangle's base midpoint angle, so the tip shades continuously.
  Base cap: `(0, −1, 0)`.

### 7.4 DSL

```f3d
cone orange                               # r=1, h=2, capped, 32 tris
cone hat at 0 2 0 radius 0.8 height 1.2   # a party hat on the origin stack
cone spike open segments 8 height 3       # 8 tris of side, no base
cone scoop size 1 height 1.5 detail high  # segments 32 → 64 tris capped
```

### 7.5 Fortran signature

```fortran
subroutine create_cone(m, radius, height, radial_segs, height_segs, capped)
    type(Mesh), intent(inout) :: m
    real(dp),   intent(in)    :: radius, height
    integer,    intent(in), optional :: radial_segs   ! default 16
    integer,    intent(in), optional :: height_segs   ! default 1
    logical,    intent(in), optional :: capped        ! default .true.
```

Identical in shape to `create_cylinder` (§4.5) — deliberately: a user
reading one signature has read both.

---

## 8. Torus

### 8.1 Parameters

| Parameter | DSL | Fortran arg | Default | Meaning |
|---|---|---|---|---|
| Ring radius | `radius R` | `ring_radius` | `0.75_dp` | Centre of the tube circle, from origin |
| Tube radius | `tube r` | `tube_radius` | `0.25_dp` | Cross-section radius |
| Around segments | `segments S` | `radial_segs` | `16` | Divisions around the main ring (Y axis) |
| Tube rings | `rings T` | `tube_segs` | `12` | Divisions around the tube cross-section |

The torus lies **flat in the XZ plane** (axis = Y), like a doughnut
sitting on a table — consistent with §5.1's floor logic and the default
camera. Defaults give outer diameter `2·(0.75+0.25) = 2` (the §2.2 `size`
convention), hole diameter `2·(0.75−0.25) = 1`. Via `size` alone, the
3:1 ratio is preserved (§2.2); via `radius` + `tube`, both are explicit.
Giving `size` together with `radius` or `tube` is the §2.2 conflict
error (three spellings of two numbers is exactly where beginners get
lost — the compiler asks them to pick a spelling family).

### 8.2 Construction

For `i = 0..S−1` (`θ = 2πi/S`, around Y) and `j = 0..T−1`
(`ψ = 2πj/T`, around the tube):

```
centre(θ)  = ( ring_radius·cosθ , 0 , ring_radius·sinθ )
point(θ,ψ) = ( (ring_radius + tube·cosψ)·cosθ ,
               tube·sinψ ,
               (ring_radius + tube·cosψ)·sinθ )
```

Every `(i, j)` cell is a quad = 2 triangles; the grid wraps in both
directions (no poles, no caps, no seams in the geometry — seam vertices
are duplicated positions with identical normals, as §3.2).

**Triangle count:** `2·S·T`. Default: `2·16·12 = ` **384**.

### 8.3 Normals

- Face: common loop.
- Analytic vertex: `normalize( point(θ,ψ) − centre(θ) )` — radially
  outward from the tube's centre circle. (At `ψ = π`, the inner equator,
  this correctly points *toward* the Y axis.)

### 8.4 DSL

```f3d
torus purple                              # ring 0.75, tube 0.25, 384 tris
torus ring at 0 1 0 rotate 90 0 0         # stood upright, like a wheel/arch
torus fat tube 0.4 radius 0.6             # outer 2.0, hole 0.4 — a plump ring
torus thin size 3 detail low              # outer 3, 10×8 → 160 tris
```

### 8.5 Fortran signature

```fortran
subroutine create_torus(m, ring_radius, tube_radius, radial_segs, tube_segs)
    type(Mesh), intent(inout) :: m
    real(dp),   intent(in)    :: ring_radius, tube_radius
    integer,    intent(in), optional :: radial_segs   ! default 16
    integer,    intent(in), optional :: tube_segs      ! default 12
```

---

## 9. Implementation shape (for whoever builds this — not built here)

### 9.1 Shared internal helpers (private to `mesh_3d`)

Four of the six primitives are surfaces of revolution around Y. Build
**one** private profile-revolution helper and three thin wrappers, rather
than four near-copies:

```fortran
! private — not added to the module's public list beyond the six create_* and existing exports
subroutine revolve_profile(m, profile_r(:), profile_y(:), radial_segs, cap_bottom, cap_top)
    ! profile points ordered bottom → top; a profile radius of 0 = a pole/apex
    ! (fan, §3.2 rule); equal end radii + cap flag = fan cap (§4.2 rule)
```

- `create_sphere` = profile of `R+1` points `(radius·sinφ_j, radius·cosφ_j)`.
- `create_cylinder` = profile of `H+1` points at constant `radius`, caps on.
- `create_cone` = profile of `H+1` points lerping `radius → 0`, bottom cap.
- `create_torus`, `create_plane`, `create_pyramid` are each a single
  direct grid/polygon builder (no helper needed, none forced).

Whether or not the helper is used internally, the **public** surface is
exactly six new names added to `mesh_3d`'s `public ::` list:
`create_sphere, create_cylinder, create_plane, create_pyramid,
create_cone, create_torus`. Compiler dispatch (P03 §10) gains one entry
per name; the P03 §9.6 `not supported yet: sphere…` error is retired
per-primitive as each lands, never all at once on faith.

### 9.2 Generation rules (all constructors)

- **G1 — Count first.** Compute `num_triangles` from the §1 formula,
  `allocate` exactly that, fill with a cursor, assert cursor = count at
  the end (a `stop`-worthy internal bug, not a user error).
- **G2 — Deallocate first**, exactly as `create_cube` does.
- **G3 — No zero-area triangles.** No collapsed quads at poles/apexes
  (fans instead), no duplicate consecutive profile points (sphere with
  `rings ≥ 2` and cylinder with `height_segs ≥ 1` cannot produce them if
  §2.5 minimums are enforced).
- **G4 — Normals last, in one loop**, identical in form to the cube's,
  including the `vnormal` fill (§2.3) once that field exists.
- **G5 — Colour in the same loop**: white, per §2.4 (the loop that sets
  normals is where cube sets colour; follow it).

### 9.3 Defensive behaviour for direct Fortran callers

The DSL compiler validates (§2.2, §2.5), but these subroutines are also
callable from Fortran. On any invalid input (non-positive dimension,
segment count below its §2.5 minimum), a constructor must **return an
empty mesh** (`num_triangles = 0`, `triangles` allocated to size 0) and
not crash, allocate a negative size, or emit NaNs. It does not print —
error *reporting* is the caller's/compiler's job; not crashing is the
constructor's.

### 9.4 Suggested landing order

1. **Plane + pyramid** (no revolution, no caps logic; validates the
   dispatch/colour/count plumbing end-to-end for ~8 triangles).
2. **Cylinder** (builds `revolve_profile` + caps).
3. **Cone + sphere** (profile variants of the cylinder's helper; apex
   fan and pole fans are the only new ideas).
4. **Torus** (independent grid; heaviest default; last because nothing
   depends on it).

Each step retires exactly its own `not supported yet` error and adds its
§10 tests before the next begins.

---

## 10. Acceptance tests (per primitive, all must pass before "done")

Geometry-level (Fortran or compiler test harness, no rendering needed):

1. **Count:** default call produces exactly the §1 table's triangle
   count; one non-default segment call matches the §1 formula.
2. **Bounds:** all vertices lie within the declared bounding box
   (e.g. sphere: `|v| = radius ± 1e-9` for *every* vertex; cylinder:
   `sqrt(x²+z²) ≤ radius + 1e-9`, `|y| ≤ height/2 + 1e-9`; torus:
   outer extent `ring + tube`).
3. **Outward winding:** for every non-plane triangle,
   `dot(face_normal, triangle_centroid − solid_centre) > 0`, where
   `solid_centre` is the origin for sphere/cylinder/cone/pyramid and
   the nearest tube-centre point for torus; for the plane, every
   `face_normal = (0,1,0) ± 1e-9`. Cap triangles are checked against
   their cap's outward axis instead of the centroid rule.
4. **No degenerates:** every triangle's area `> 1e-12`; every face normal
   has length `1 ± 1e-9` (catches the zero-normal collapsed-quad bug).
5. **Analytic normals:** sampled vertices match the section formula
   within `1e-9` — including the cone slope formula (§7.3) at `θ = 0`
   and the torus inner equator (§8.3).
6. **Crease check:** at a capped cylinder's rim, the side copy's and cap
   copy's analytic normals differ (they must *not* be averaged copies).

DSL-level (golden `.f3d` files, in the P03 §10 style):

7. Each §3–§8 example block parses and lowers to the stated constructor
   call with the stated triangle count.
8. Error cases produce their plain-English errors: `size` + `radius`
   together (§2.2); `segments 2` on a sphere (§2.5); `height` on a sphere
   / `tube` on a cube / `sides` on a cone (prop not legal for that
   primitive — error lists that primitive's legal props); `radius 0`;
   `torus size 2 tube 0.5` (mixed spelling families, §8.1).
9. **Regression anchor:** `cube` output is byte-identical before and
   after this work (P03 §10's default-render check still passes) — six
   new constructors must not move the one working render.

---

## 11. Explicitly deferred

UVs/texture coordinates (no field exists; adding geometry now that must
be regenerated when UVs arrive is acceptable — constructors are cheap to
re-run, saved meshes are exports, not sources); partial arcs/sweeps;
elliptical variants; sphere as subdivided icosahedron (nicer poles, but
a second sphere algorithm is one too many for v1 — the UV sphere's pole
pinching is invisible under flat/Lambert shading at these segment
counts); `open` pyramid; double-sided plane flag (waits for P10's
`double_sided` material field, §5.1). Each deferred item, if requested
in the DSL before it exists, gets the P03 §1.8 treatment: a targeted
`not supported yet` error, never a silent approximation.
