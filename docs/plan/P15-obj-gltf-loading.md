# P15 — OBJ / glTF Loading: Import Spec (v1 OBJ, glTF Deferred to v2)

> **Status:** Planning only — no code changed by this document.
> **Repo state audited:** `src/mesh.f90`, `src/main.f90`, `src/renderer.f90`,
> `src/math_3d.f90`, `model.obj`, `scene.json`, `docs/plan/P03-dsl-grammar.md`,
> `docs/plan/P08-error-ux.md`, `docs/plan/P10-materials-lighting.md` (2026-11-23).
> **Goal served:** an *easy* 3D compiler — a beginner downloads a model, writes
> one line naming the file, and renders it. Import must therefore be
> **one line, forgiving about real-world OBJ files, and honest about
> everything it drops.**

---

## 0. Verdict in one page

| Decision | Ruling |
|---|---|
| v1 import format | **Wavefront OBJ (`.obj`) only**, text, subset in §3. It is line-oriented, trivially tokenised in Fortran, and is already this engine's export format. |
| v1 entry point (DSL) | `load "model.obj"` — one new object statement (§6). This **amends P03 §11**, which deferred "importing `.obj` as an object statement"; P15 is that deferral being picked up. P03's 3-line contract is unchanged for primitives. |
| v1 entry point (Fortran) | One new module `src/obj_loader.f90` exposing `load_mesh_obj(...)` (§8). No other module changes except `Makefile` order and the compiler driver calling it. |
| Internal target | Today's `mesh_3d:Mesh` unchanged in v1: flat triangle soup, `Triangle%v(3)`, one face `normal`, integer `color(3)`. Conversion rules in §5 — including what is lost, said out loud. |
| `vt` (UVs) | **Parsed and validated, then discarded in v1** with one summary warning. The renderer has no textures and `Triangle` has no UV field (P10 defers textures too); storing UVs nobody can use is fake support. The parse must not *fail* on their presence — most real OBJ files carry them. |
| `vn` (vertex normals) | **Parsed and validated, then not used for shading in v1.** `renderer.f90` recomputes the face normal per triangle anyway, and `Mesh` stores only a face normal. Loaded triangles get `normal = compute_triangle_normal(...)` exactly like `create_cube`. Smooth shading from `vn` is a P10-`lambert`/`phong` era feature, not smuggled in here. |
| Groups (`o` / `g`) | Preserved as **separate scene objects**, one `Mesh` per group (§4.5), each addressable by name in the DSL. Flattening them into one anonymous soup would destroy the only structure a beginner can act on (`spin wheel`, `move door`). |
| Materials (`mtllib` / `usemtl`) | **Not loaded in v1.** `mtllib` is not opened; `usemtl` is recorded as a group label only. One warning per file (§4.6). Colour comes from the DSL statement (§6.3), defaulting to white. Claiming `.mtl` support we don't render (no textures, P10 material model not yet built) would be a silent fake. |
| Polygons | Faces with > 3 vertices are **fan-triangulated** (§5.2). Quads are ubiquitous in real OBJ; rejecting them would reject most downloadable models. |
| Indices | Both OBJ index styles supported: positive (1-based, absolute) and **negative (relative to the most recent vertex)** (§4.4). Negative indices appear in exporter output in the wild; supporting them is ~5 lines. |
| glTF / GLB | **Deferred to v2**, rationale in §7 — not "later, maybe": §7.3 fixes the seam (a format-neutral intermediate mesh) so v2 is an addition, not a rewrite. Interim path: convert with an external tool to OBJ (§7.4), and the compiler says exactly that on seeing `.gltf`/`.glb`. |
| Errors | Never a Fortran traceback, never a partial mesh silently rendered. All failures go through P08's diagnostic sink; file-level failure = **no object created** (§6.4 / §9). New codes proposed in the `E51xx`/`W51xx` block (§9.2), appended per P08's append-only rule. |
| Round-trip guarantee | The engine's own `model.obj` (produced by `export_mesh_obj`) **must load back to the same 12 triangles** (§10.1). This is the first acceptance test: if we cannot read what we write, nothing else matters. |

Non-goals for v1 (stated in the user manual in one list): glTF/GLB, `.mtl`
materials, textures, vertex-normal shading, animations/skins (OBJ has none),
curves/free-form surfaces (`vp`, `cstype`, …), lines/points as renderable
geometry, per-vertex colours, writing an *indexed* or grouped OBJ on export
(export stays exactly as it is today).

---

## 1. Where we start — the audited baseline

### 1.1 There is export, and only export

`src/mesh.f90` (`module mesh_3d`) publicly exports:

```fortran
public :: Triangle, Mesh, create_cube, compute_triangle_normal, &
          export_mesh_json, export_mesh_obj
```

- `export_mesh_obj(m, filename)` writes a deliberately minimal OBJ:
  a `# Fortran 3D Engine OBJ Export` header, then **3 non-indexed `v` lines
  per triangle** (36 `v` lines for the 12-triangle cube — vertices are
  duplicated, never shared), then `f i i+1 i+2` lines using bare positive
  vertex indices only. No `vt`, no `vn`, no `o`/`g`, no `mtllib`/`usemtl`.
- `export_mesh_json(m, filename)` writes triangles with `v` and integer
  `color` to `scene.json`. JSON is an **output** for `viewer.html`; nothing
  reads it back, and P15 does not propose making it an import format.
- There is **no loader of any kind**: `src/main.f90` builds exactly one
  object, `create_cube(cube, 2.0_dp)`, in code. Grep finds no `read` of a
  model file anywhere in `src/`.

### 1.2 The internal mesh the loader must produce

```fortran
type :: Triangle
    type(vec3) :: v(3)     ! positions only
    type(vec3) :: normal   ! ONE face normal
    integer    :: color(3) = [255, 255, 255]
end type Triangle

type :: Mesh
    integer :: num_triangles
    type(Triangle), allocatable :: triangles(:)
end type Mesh
```

Consequences that shape the whole spec:

1. **Triangle soup, no index buffer.** Any indexed source must be
   *de-indexed* on load: each face corner copies its position out of the
   vertex pool (§5.1). Memory cost is accepted — it is the existing
   representation everywhere (`create_cube` does the same).
2. **No place to put UVs or per-vertex normals.** Hence §0's parse-and-drop
   rulings for `vt`/`vn`. Extending `Triangle` is P10's decision (it already
   proposes `vnormal(3)`); P15 must not pre-empt it. If P10 lands first,
   §5.4 notes the one-line change to *keep* `vn`.
3. **One integer colour per triangle.** No material indirection yet
   (P10 §1.1). A loaded mesh gets one DSL-supplied colour on every triangle,
   or white — never the cube's per-face palette, which is a `create_cube`
   hard-coding, not a mesh property.
4. **Normals are recomputed, not trusted.** `framebuffer_render_mesh`
   (`src/renderer.f90`) ignores `Triangle%normal` and recomputes the
   world-space face normal via `compute_triangle_normal`. The loader still
   fills `Triangle%normal` (as `create_cube` does) so the in-memory value
   is never garbage for other consumers (e.g. JSON export).

### 1.3 Coordinates and units — OBJ happens to match

OBJ is conventionally right-handed, Y-up, unitless. The engine is the same:
`camera.f90` uses up = +Y, `math_3d.f90` is right-handed, world units are
unitless (`create_cube` size 2 ⇒ edge length 2). **Therefore v1 performs no
axis conversion, no handedness flip, and no unit scaling by default.**
Winding order is preserved as written; the renderer's screen-space winding
cull then behaves for OBJ files exactly as it does for `create_cube`
geometry — which also means a model authored with reversed winding renders
inside-out, and §9 makes that a diagnosable warning case, not a loader
"fix" (auto-flipping winding would break correctly-authored files).
Optional user-requested scaling exists only through the DSL (§6.3).

### 1.4 The file we must read on day one

The repo-root `model.obj` is the exporter's own cube: 36 `v` lines,
12 `f  a b c` lines, values at `F9.4` precision. §10.1 turns it into the
golden round-trip fixture. Any OBJ reader that cannot read this file is
wrong by definition.

---

## 2. Design principles

1. **One line loads a model.** `load "model.obj"` with no other words must
   work, be centred sensibly (§6.3), and render. Options refine; they are
   never required to avoid failure.
2. **Accept what exporters actually emit.** Blender, MeshLab, and assorted
   web exporters differ in whitespace, comment placement, face forms, group
   usage, and line ordering. The subset in §3 is drawn from what those
   tools produce, not from the OBJ spec's greatest hits.
3. **Parse strictly, fail in plain English, drop nothing silently.**
   Anything ignored (`vt`, `vn`, `usemtl`, smoothing groups, …) is counted
   and reported once per file as a warning in P08 format. Anything
   *malformed* is an error with the OBJ file's own line number (§9).
4. **All-or-nothing per file.** A file that errors creates no object and
   renders nothing new — never "the first 200 triangles plus a crash".
   (Warnings do not block; a warned-about file still loads.)
5. **No new Fortran superpowers required.** Line reading, token splitting,
   and list-directed-free parsing with explicit `iostat` checks — all
   within the Fortran 2008 subset the codebase already uses. No JSON
   parser, no binary reader, no external library. This principle is also
   the entire glTF story (§7).
6. **The loader is a compiler component, not a renderer feature.** It runs
   at scene-compile time, reports through the P08 diagnostic collector, and
   hands the compiler finished `Mesh` values. The renderer never sees a
   filename.

---

## 3. OBJ subset for v1 — the grammar of what we read

### 3.1 Line model

- File is read line by line (max line length **4096** characters; longer ⇒
  `E5101`, §9.2 — protects fixed buffers and catches binary files fed in
  by mistake). Leading/trailing whitespace is insignificant; tokens are
  separated by one or more spaces/tabs. CRLF line endings are accepted
  (strip a trailing `CR` before tokenising — Windows-exported files are
  common and this is a one-line fix for a classic beginner trap).
- `#` starts a comment anywhere on a line; the rest of the line is ignored.
  Blank and comment-only lines are skipped.
- The first token (the *keyword*) is case-sensitive lowercase as written by
  every known exporter (`v`, `f`, …). An unrecognised keyword is **not**
  automatically an error — see the disposition table (§3.2): unknown
  keywords are ignored with a once-per-keyword warning, because the OBJ
  ecosystem carries vendor extensions. A keyword that is *known but
  malformed* is an error.
- Numbers: reals in decimal or scientific notation (`1`, `-1.5`, `0.25`,
  `1.0e-3`, `+2.0`) — parse with an internal `read(...,*,iostat=...)` per
  token and check `iostat`; a non-numeric token where a number is required
  is `E5102` naming the token and the line. Indices are integers with an
  optional leading `-`; `1.0` as an index is an error, not a truncation.

### 3.2 Keyword disposition table (complete for v1)

| Keyword | Meaning | v1 disposition |
|---|---|---|
| `v x y z [w]` | Vertex position | **Supported.** 3 required reals; optional 4th (`w`) parsed and ignored. Stored in the vertex pool (§5.1). |
| `vt u [v [w]]` | Texture coordinate | **Parsed, validated, discarded** (§0). 1–3 reals; only the count is kept for the warning summary. |
| `vn x y z` | Vertex normal | **Parsed, validated, discarded** (§0). 3 reals. Not required to be unit length (we don't use it). |
| `f a b c [d …]` | Face (polygon) | **Supported.** ≥ 3 corners, corner forms in §3.3, fan-triangulated (§5.2). |
| `o name` | Object name | **Supported:** starts a new group (§4.5). Name = rest of line, trimmed (may contain spaces in the wild; DSL name is derived per §4.5). |
| `g name …` | Group name(s) | **Supported:** starts a new group, like `o`. If multiple names follow, the first is used and the rest are ignored-with-warning (multi-group membership is inexpressible in a flat object list). |
| `usemtl name` | Material selection | **Recorded, not applied** (§4.6). Sets the current group's material *label* (used only in messages); no colour change in v1. |
| `mtllib file …` | Material library | **Not opened.** Counted; one warning per file (§4.6). |
| `s n` / `s off` | Smoothing group | **Ignored silently-by-design** — but counted in the load summary line (§9.3), because flat shading (§1.2) makes it a no-op the user should know about once, not per line. |
| `p` / `l` / `vp` | Point / polyline / parameter vertex | **Ignored with one warning per file** ("this file contains lines/points, which are not surfaces — skipped"). They cannot become triangles honestly. |
| `cstype`, `deg`, `bmat`, `step`, `curv`, `surf`, `parm`, `trim`, `hole`, `scrv`, `sp`, `end`, `con`, `mg`, `bevel`, `c_interp`, `d_interp`, `lod`, `shadow_obj`, `trace_obj`, `ctech`, `stech` | Free-form / display attributes | **Ignored with one warning per keyword per file** ("free-form surfaces are not supported — export as triangles"). |
| Anything else | Vendor/unknown extension | **Ignored with one warning per keyword per file**, naming the keyword. Never an error in v1. |

Rationale for ignore-with-warning over hard errors on unknown keywords:
a beginner cannot edit a downloaded file's extensions away, and the
geometry they care about (`v`/`f`) is unaffected. The warning keeps it
honest; the load keeps it easy.

### 3.3 Face corner forms (all four must parse)

Each corner is one token in one of these forms, where `i` = vertex index,
`j` = UV index, `k` = normal index; each present index follows §4.4:

| Form | Example | v1 handling |
|---|---|---|
| `i` | `f 1 2 3` | Position only. (The only form our own exporter emits.) |
| `i/j` | `f 1/1 2/2 3/3` | Position + UV (UV validated, discarded). |
| `i//k` | `f 1//1 2//2 3//3` | Position + normal (normal validated, discarded). Note the empty middle field — the splitter must treat `//` as an empty token, not collapse it. |
| `i/j/k` | `f 1/1/1 2/2/2 3/3/3` | Position + UV + normal. |

Rules:

- All corners **of one face** must use the same form; mixed forms in one
  face (`f 1/1 2 3//3`) ⇒ `E5103` (real exporters don't do this; accepting
  it would mean guessing which fields were meant).
- Forms may differ *between* faces in the same file (also seen in the
  wild); the loader tracks the pools independently, so this costs nothing.
- A corner with a trailing slash and nothing after it (`1/`, `1/2/`),
  an empty corner, or more than 2 slashes ⇒ `E5103`.
- Index `0` is always invalid in OBJ ⇒ `E5104` (with the P08-style help:
  "OBJ counts from 1 — 0 usually means the file was written by a program
  counting from 0").

---

## 4. Semantics

### 4.1 Two passes over an in-memory tokenisation

The loader reads the whole file once into memory (files are capped, §4.7),
tokenising as it goes, because negative indices (§4.4), group boundaries,
and all-or-nothing semantics (§2.4) are all easier — and error reporting
is better — when validation completes before any `Mesh` is built:

1. **Pass 1 — parse & validate:** fill the vertex/UV/normal pools (positions
   kept; UV/normal values validated then freed), record faces as integer
   corner triples `(v, vt, vn)` per group, record group boundaries and
   names. Collect *all* errors (P08 caps display at 10), don't stop at the
   first.
2. **Pass 2 — build:** only if pass 1 had zero errors, convert each group
   to a `Mesh` (§5) and return the list. On any error, deallocate
   everything and return no meshes.

### 4.2 Pools are file-global, indices are 1-based

`v`/`vt`/`vn` lines append to three independent pools in file order,
regardless of group boundaries (this is how OBJ works — groups do not
restart numbering). A face may only reference indices **already defined
above it** for positive indices (forward references ⇒ `E5104`; every real
exporter writes vertices first, and permitting forward refs would force
deferred resolution for no real file's benefit).

### 4.3 What counts as geometry

- A file with zero `f` lines ⇒ `E5105` ("the file has vertices but no
  faces — there is nothing solid to draw"), even if it has thousands of
  `v` lines. A file with zero `v` lines ⇒ same code, "no vertices".
- Faces appearing **before any `o`/`g`** belong to an implicit group named
  after the file (§4.5). Our own `model.obj` has no groups at all and must
  load as exactly one object.
- Duplicate vertices are **not welded** in v1. Welding changes triangle
  counts, interacts with P10's future vertex-normal work, and the soup
  representation doesn't need it. (A file that lists 36 vertices for a
  cube loads as a 36-vertex-equivalent soup — same as our exporter made.)

### 4.4 Index resolution

For an index token `n` in a pool that currently holds `N` entries:

| Case | Resolved (1-based) | Validity |
|---|---|---|
| `n > 0` | `n` | Valid iff `n ≤ N` **at the face's line** (no forward refs, §4.2) |
| `n < 0` | `N + n + 1` (so `-1` = most recent entry) | Valid iff result `≥ 1` |
| `n = 0` | — | Always `E5104` |

Out-of-range ⇒ `E5104` with the actual numbers in the message, P08-style:
"line 812: face uses vertex 1042, but only 900 vertices are defined above
this line". The three pools are checked independently (a bad `vt` index is
an error even though UVs are discarded — a corrupt index means a corrupt
file, and §2.3 forbids silently guessing).

### 4.5 Groups → objects

- Each `o` or `g` line closes the current group and opens a new one.
  Consecutive group lines with no faces between them produce **no** empty
  object (skipped, counted in the summary — exporters emit stray `g`
  lines liberally).
- Each non-empty group becomes **one scene object / one `Mesh`**, in file
  order. The compiler holds a *list* of meshes for a `load` statement
  (§6.2) — the single-`Mesh` shape of `main.f90`'s demo is a driver
  concern, not a loader limitation.
- **Naming:** the DSL-visible name is derived from the group name by
  P03's `name` rule (letter, then letters/digits/`_`/`-`): lowercase it,
  replace any run of other characters with `-`, trim leading/trailing
  `-`; if the result is empty or starts with a digit, prefix `mesh-`.
  Collisions (two groups sanitising to the same name, or a name already
  used in the scene) get `-2`, `-3`, … suffixes, with a warning naming
  both. The *original* group name is kept alongside for messages
  ("group 'Left Wheel!' loaded as `left-wheel`").
- A file with exactly one group (or none) behaves exactly like a single
  object: `load "car.obj"` followed by `spin it` spins the whole car,
  groups or not (§6.2 defines `it` for the multi-group case).

### 4.6 Materials in OBJ files — the honest v1 story

- `mtllib` filenames are **never opened** in v1 (they may be absolute
  paths, missing, or hostile; opening them buys nothing we can render).
- `usemtl name` changes only the current material *label*, stored per
  group for messages. It does **not** split groups (some exporters emit
  `usemtl` per face; splitting on it would explode object counts) and
  does **not** change colour.
- Exactly one warning per file if either keyword appeared, e.g.:
  "this file names materials (usemtl ×14, mtllib 'car.mtl'), but v1 does
  not load .mtl files — everything is coloured by your scene line instead
  (see §6.3 of the manual)". When P10's material system and a `.mtl`
  reader land, `Kd` → material `color` is the designed first step; it is
  **not** in v1 and must not be half-faked by parsing `Kd` alone.

### 4.7 Limits (fail loudly, never truncate silently)

| Limit | Value | On exceed |
|---|---|---|
| File size | 64 MB | `E5106` ("too large for v1") |
| Line length | 4096 chars | `E5101` |
| Vertices (`v`) | 1,000,000 | `E5106` |
| Faces (pre-triangulation) | 500,000 | `E5106` |
| Corners per face | 1024 | `E5103` |
| Groups | 1024 | `E5106` |

These are teaching-engine caps, sized far above any sane beginner model
and far below memory danger on modest hardware (the soup expansion in
§5.1 multiplies position storage by ~3× per face corner: 500k faces ≈
1.5M corners ≈ 36 MB of `vec3` — acceptable; 10× that is not). Raising a
cap is a one-constant change in `obj_loader.f90`, documented as such.

---

## 5. Conversion to the internal `Mesh`

### 5.1 De-indexing

For each group, in face order, for each triangulated face (§5.2), emit one
`Triangle` whose `v(1..3)` are **copies** of the pool positions at the
resolved corner vertex indices. `num_triangles` = total emitted triangles
for the group. Allocation is exact: pass 1 already counted the
post-triangulation total, so pass 2 allocates once — no growth-by-copy
loop in the hot path.

### 5.2 Triangulation: fan, and only fan

A face with corners `c1 c2 … cn` (n ≥ 3) becomes triangles
`(c1,c2,c3), (c1,c3,c4), …, (c1,c(n-1),cn)` — n−2 triangles, order and
winding preserved. Fan is correct for convex polygons and for the
overwhelmingly common quad case (any quad, convex or with one reflex
vertex, fans correctly from a suitable vertex — from `c1` a *concave*
quad can produce one flipped triangle; this is a known, documented v1
limitation, not hidden: ear-clipping is v2 polish if a real file ever
demonstrates the need). n-gons that are non-planar fan into a tent —
again documented, again what most simple loaders do.

### 5.3 Degenerate faces

After de-indexing, a triangle whose three positions are identical or
collinear (`compute_triangle_normal` would normalise a zero vector;
`vec3_normalize` already guards length < 1e-12 by returning zero) is
**dropped**, counted, and summarised in one warning per file:
"12 faces were dropped because their points are in a line / on top of
each other — they have no surface to draw". Dropping (not erroring) is
right: real files contain degenerate slivers, and one bad triangle must
not veto a 50k-triangle model. If **all** faces are degenerate ⇒ `E5105`
(nothing to draw), because an empty object would fail later and weirder.

### 5.4 Normals and colour on load

- `Triangle%normal = compute_triangle_normal(v(1), v(2), v(3))` — the
  existing `mesh_3d` function, exactly as `create_cube` fills it. Loaded
  `vn` data plays no part (§0). *If P10 has landed* and `Triangle` has
  gained `vnormal(3)`, the loader additionally copies the resolved `vn`
  values into `vnormal` when the face form supplied them (face normal
  otherwise) — a strictly additive change, flagged here so P10's author
  knows the loader is the intended producer.
- `Triangle%color` = the single colour resolved by the DSL statement
  (§6.3) for **every** triangle of every group from that `load`, unless
  per-group colours are given (§6.3). Default: white `[255,255,255]`
  (the `Triangle` default). OBJ itself carries no colour in v1 (§4.6).

### 5.5 Transform on load

The loader itself applies **no** transform — pool coordinates become
world-of-the-object coordinates verbatim. Placement (`at`, `rotate`,
`size`/`scale`) is the compiler's job, using the same `mat4_*`
composition P03 §7 defines for primitives, applied to the whole loaded
object (all groups move together; §6.2). One loader-specific helper the
compiler needs: the loader returns the mesh's **bounding box**
(min/max `vec3`) per group and for the whole file, because §6.3's
centering/scaling defaults are defined in terms of it. Computing it in
pass 2 is free (positions are already being copied).

---

## 6. DSL surface: the `load` statement

Syntax follows P03 (line-oriented, canonical order, `#` comments,
case-insensitive keywords, `string` = double-quoted, no escapes in v1).

### 6.1 Grammar (P03 EBNF, additions only)

```ebnf
(* P03: statement gains one alternative *)
statement      =/ load-stmt ;

load-stmt      = "load" , string , [ name ] , { load-prop } ;
load-prop      = "at" , vec3 | "pos" , vec3              (* alias, as P03 *)
               | "colour" , colour | "color" , colour    (* alias, as P03 *)
               | "size" , number          (* scale so largest bbox side = this *)
               | "scale" , number         (* uniform multiplier, raw *)
               | "rotate" , vec3 | "rot" , vec3          (* alias, as P03 *)
               | "centre" | "center"      (* translate bbox centre to origin *)
               | "ground" ;               (* translate so bbox min-y sits on y=0 *)
```

- `load` joins P03 §5's keyword table under Objects; the file extension
  is part of validation, not grammar: `.obj` loads; `.gltf`/`.glb` ⇒ the
  §7.4 error; anything else ⇒ "I don't know how to load '.xyz' — v1 loads
  .obj files".
- The optional bare `name` works exactly like P03 object statements
  (`cube hero …`): `load "car.obj" hero …` names the (first / whole)
  object `hero`. With multiple groups, §6.2 applies.
- Reserved-but-rejected props get P03 §1.8-style targeted errors, e.g.
  `texture` ⇒ "'texture' is not supported yet — loaded models are coloured
  with 'colour' for now".

### 6.2 Multi-group semantics in the DSL

A `load` of a multi-group file creates **several scene objects at once**.
Rules that keep pronouns predictable (P03 §4.1's target resolution is
extended, not changed):

- The `load` statement's own name (given or auto-derived from the file
  stem, e.g. `car` from `"car.obj"`) names the **whole load** — a handle
  to all its groups. `move car …`, `spin car`, `colour car red` apply to
  every group in it. (Implementation: the compiler keeps a group-of-objects
  list per load; transforms compose per object.)
- Each group is *also* individually addressable by its §4.5 derived name
  (`spin wheel-fl`, `colour door blue`). Individual props on the `load`
  line itself (`at`, `rotate`, …) apply to the whole load, applied before
  any later per-group statements.
- `it` / `last` after a `load` = the whole load (not the last group) —
  the least surprising reading of "spin it" after loading a car.
- Per-group colour override on the load line is **not** v1 syntax;
  colour groups with follow-up statements (`colour door blue`). One
  mechanism, no comma-lists of group/colour pairs to misparse.

### 6.3 Defaults — a downloaded model must just appear

Downloaded models arrive at arbitrary scale (millimetres, inches,
kilometres) and arbitrary origin. Raw P03 primitive defaults (position
`0 0 0`, no scaling) would make most real loads invisible or gigantic.
`load` therefore has its own defaults, chosen so the model appears,
framed, in front of the default camera:

| Property | `load` default | Why |
|---|---|---|
| Position | bbox centre placed at origin, base on ground: equivalent to `centre` + `ground` | Models are rarely origin-centred; centring is what every viewer does and what a beginner expects. (Primitives keep P03's `at 0 0 0` — they are authored at origin already.) |
| Scale | **`size 2`** — largest bbox side scaled to 2 world units | Matches `create_cube`'s default size 2: a loaded model and a `cube` in the same scene are comparable, and the default camera (at `3 2.5 4`, fov 60) frames it. Without this, "easy" is a lie for 90% of real files. |
| Colour | white, all groups | §5.4. Shading (Lambert, renderer) still gives form. |
| Rotation | `0 0 0` — **not** P03's `20 35 0` demo pose | That pose exists to make a lone cube look good; tipping a loaded car 20° looks broken. |

Explicit props replace defaults piecemeal: `at` replaces the centring
translation (but `size` normalisation still applies unless `scale` is
also given — `scale` and `size` are mutually exclusive on one line,
duplicate/conflict ⇒ P03-style error "'size' and 'scale' do the same job
differently — pick one"). `size 0`/negative and `scale ≤ 0` are parse-time
range errors per P03 §4.1. A zero-size bbox (all points identical — already
`E5105` at load) can never reach the scaler.

Worked examples:

```f3d
load "model.obj"                       # the repo's own cube: centred, size 2, white
render
```

```f3d
load "car.obj" hero red at 0 0 0 size 3
spin hero
colour door blue                       # one group recoloured afterwards
render
```

### 6.4 Failure behaviour at the DSL level

- Missing file, unreadable file, wrong extension, and every `E51xx`
  (§9.2) are **compile errors** in P08 format, located at the `load`
  line in the `.f3d` file (primary span) with the OBJ file's own
  line in the message body where applicable (secondary information) —
  the user must fix either *their line* (wrong path) or *their model*
  (bad face), and the message says which.
- Path resolution: relative paths resolve **relative to the `.f3d`
  file's directory**, not the process working directory — a scene folder
  must be portable. Absolute paths are accepted as written. (P08 §8.8's
  cwd-honesty rule applies to the error message: it prints the resolved
  absolute path it tried.)
- No partial scene: if any `load` in the file errors, nothing renders
  (P08 exit-code rules; §9.4). Other independent statements' errors are
  still collected in the same run (P08 recovery rules).

---

## 7. glTF: deferred to v2 — rationale and the seam

### 7.1 Why not v1 (concrete, not "it's hard")

glTF 2.0 (`.gltf` JSON + external/embedded buffers, or binary `.glb`) is
the right *second* format and the wrong *first* one, for reasons specific
to this codebase:

1. **It needs a JSON parser; the codebase has none.** `scene.json` is
   write-only (§1.1). A correct-enough JSON parser in Fortran (strings,
   escapes, nested arrays, numbers) is a project comparable to the OBJ
   loader itself — before any glTF semantics begin.
2. **It needs binary buffer decoding.** Accessors/bufferViews over
   `.bin` files or GLB chunks, with component types, strides, and
   **base64 data-URIs** — none of which has any precedent in `src/`.
   OBJ v1 needs none of this: it is the same line-reading the exporter
   already mirrors.
3. **Its scene model is a graph, ours is a list.** Nodes with TRS/matrix
   hierarchies, meshes with multiple primitives, skins, morphs, cameras,
   and animations must all be *flattened or rejected* to reach
   `Mesh` — a design exercise (§7.3), not a parser exercise.
4. **Its material model (metallic-roughness PBR + textures) has no
   renderer to land on.** P10 explicitly defers PBR and textures. Loading
   glTF in v1 would mean discarding *more* of the file than OBJ discards,
   while looking more "supported" — the exact silent-fake failure P10 §2
   and P08 §1.5 ban.
5. **Beginner supply is not blocked.** Every common tool that exports
   glTF (Blender, MeshLab, online converters) also exports OBJ, and the
   asset sites beginners use offer OBJ downloads. v1's user loses no
   model they could otherwise have used; they lose one *format*.

### 7.2 What v2 glTF support will mean (scoped now, built later)

In scope for v2: `.gltf` (JSON + external `.bin`) and `.glb`; static
triangle primitives only; node hierarchy flattened by composing node
transforms into positions at load (the soup has no hierarchy to keep);
`POSITION`/`NORMAL`/`TEXCOORD_0` accessors (normals/UVs landing only if
P10's fields exist by then); base colour factor → per-primitive colour.
Out of scope even in v2 unless separately planned: skins, morph targets,
animations, KHR extensions, Draco/meshopt compression (⇒ targeted error,
not garbage). Coordinate note for v2: glTF is also right-handed Y-up, so
§1.3's no-conversion stance carries over; only the default forward axis
convention differs, which matters for cameras, not for loaded geometry.

### 7.3 The seam v1 must build so v2 is additive

- The compiler talks to a **format-neutral intermediate form**, not to
  OBJ records: pass 1 of any loader produces
  `LoadedFile { groups: [ { name, positions pool, faces (resolved corner
  positions), bbox } ] }` (names indicative), and §5's conversion is
  shared. The OBJ loader is the first producer; a glTF loader is the
  second. No `Mesh`-building code may live inside the OBJ parser.
- DSL dispatch is by extension through one table (`load` → loader), so
  v2 adds a row, not a statement.
- Error codes: glTF gets its own `E52xx` block when it lands; v1 reserves
  the numbering pattern (§9.2) without inventing messages for it now.

### 7.4 Interim behaviour (v1, specified)

```f3d
load "robot.gltf"
```
```
error[E5200-reserved → emitted as E5003 in v1, see §9.2 note]:
  'robot.gltf' is a glTF file, which v1 cannot load yet
  = help: convert it to Wavefront OBJ first — in Blender: File > Export >
    Wavefront (.obj); online converters also work — then load the .obj:
    load "robot.obj"
```
The message must name a *working alternative*, not just refuse. (In v1
this is emitted under the existing P08 code `E5003` — "referenced model
file not found or unparseable" — with this body text; the dedicated
`E52xx` codes arrive with the v2 loader, per P08's append-only rule.
This plan does not mint codes for unbuilt features.)

---

## 8. Fortran implementation sketch (for the implementing agent)

### 8.1 New module `src/obj_loader.f90` (`obj_loader`)

```fortran
module obj_loader
    use math_3d,  only: dp, vec3
    use mesh_3d,  only: Mesh
    implicit none
    private
    public :: LoadedGroup, LoadedFile, load_obj_file

    type :: LoadedGroup
        character(:), allocatable :: name        ! original group name
        type(Mesh) :: mesh                       ! built by §5 conversion
        type(vec3) :: bbox_min, bbox_max
    end type LoadedGroup

    type :: LoadedFile
        type(LoadedGroup), allocatable :: groups(:)   ! file order, ≥1 on success
        type(vec3) :: bbox_min, bbox_max              ! whole file
        integer :: n_vertices, n_faces_in, n_triangles_out, n_degenerate_dropped
        integer :: n_vt_ignored, n_vn_ignored, n_usemtl, n_mtllib
    end type LoadedFile

    ! Reports through the P08 diag collector; never STOPs, never prints.
    subroutine load_obj_file(filename, diag, result_file, ok)
        character(len=*), intent(in)    :: filename
        type(diag_list_t), intent(inout) :: diag   ! from P08's diag module
        type(LoadedFile), intent(out)   :: result_file
        logical, intent(out)            :: ok      ! .false. ⇒ result_file empty
    end subroutine load_obj_file
end module obj_loader
```

(`diag_list_t` is P08 §3.1's proposed type; if the loader is built before
the diag module exists, the interim is an `integer :: status` +
`character(:), allocatable :: errmsg` pair with the same never-stop
contract, migrated when P08 lands — do not invent a third reporting
style, and do not `print` from the loader either way.)

### 8.2 Parsing mechanics (decisions, not options)

- Read with `open(newunit=..., status='old', action='read', iostat=...)`;
  map open failure to P08 `E5003` (missing) / unreadable variants — the
  loader owns OBJ-file IO errors, the compiler owns `.f3d`-file ones.
- One pass over lines (§4.1 pass 1): classify by first token using
  `select case` on the keyword; split face corners on `/` by explicit
  index scanning (Fortran has no split intrinsic; write one small helper
  and unit-test the `i//k` empty-field case specifically).
- Pools as allocatable arrays grown by doubling (`real(dp)` positions
  `(:,3)`-style or `type(vec3)` array — match `mesh_3d` style and use
  `vec3_create`). Faces stored as resolved integer corner arrays plus a
  per-face group id. All growth bounded by §4.7's caps, checked *before*
  each append.
- Every numeric conversion via internal `read(token, *, iostat=ios)` with
  `ios` checked; on failure, `E5102` with line + token. No list-directed
  read touches the file unit directly (a malformed line must not consume
  the next line or abort the run — the classic Fortran OBJ-loader bug).
- `ieee_arithmetic` guard: reject non-finite parsed values (`NaN`,
  `Infinity` tokens parse on some compilers) with `E5102` — a NaN vertex
  otherwise poisons the bbox and vanishes the whole model silently.

### 8.3 Build integration

- `Makefile`: `obj_loader.f90` compiles after `mesh.f90` (depends on
  `math_3d`, `mesh_3d`, and P08's diag module when present); add to the
  module/object lists in that order. No new external dependencies; still
  pure gfortran.
- `main.f90` is **not** changed by the loader itself; the compiler driver
  (P03/P04 work) calls `load_obj_file` when lowering a `load` statement
  and receives `LoadedFile%groups(:)%mesh` values ready for the existing
  `framebuffer_render_mesh`.

---

## 9. Error handling — catalogue for this feature

All diagnostics follow P08 §2 anatomy (header with actual values, span,
`why:`, `help:`, `see:`), go to the single collector, and are golden-tested
in plain mode. OBJ-internal errors carry the `.f3d` `load` line as the
primary span and quote the OBJ `file:line` in the header/body — two files
are involved and the message must never confuse them.

### 9.1 Reused P08 codes (no new codes needed)

| Code | Use in this feature |
|---|---|
| `E5003` | Model file not found / is a directory / unreadable; also the v1 vehicle for the §7.4 glTF refusal and for unknown extensions. Did-you-mean on the filename per P08 §8.8 (same-directory listing + distance). |
| `E5004` | (Unchanged — output paths; not a loader code.) |

### 9.2 New codes proposed (append-only, `51xx` = OBJ loader block)

| Code | Meaning | Sev |
|---|---|---|
| `E5101` | Line too long (> 4096) or file appears binary (NUL byte found) — "this does not look like a text .obj file" | error |
| `E5102` | Bad number: non-numeric / non-finite token where a number is required (names token, line, and which of `v`/`vt`/`vn` it was) | error |
| `E5103` | Malformed face: < 3 corners, mixed corner forms in one face, bad slash form, > 1024 corners | error |
| `E5104` | Index problem: index 0, out of range, or forward reference (message carries the actual index and pool size, §4.4) | error |
| `E5105` | No drawable geometry: no vertices, no faces, or all faces degenerate | error |
| `E5106` | Limit exceeded (§4.7 table; message names the limit and the count) | error |
| `W5101` | File features parsed but not used in v1 — the once-per-file summary covering `vt`, `vn`, `usemtl`/`mtllib`, `s`, `p`/`l`, free-form and unknown keywords, each with its count (§3.2, §4.6) | warning |
| `W5102` | Degenerate faces dropped (§5.3; count in message) | warning |
| `W5103` | Group name sanitised or de-duplicated (§4.5; shows original → derived) | warning |
| `W5104` | Suspicious winding/empty render risk: loaded mesh renders but every triangle was back-face culled under the default camera — help text suggests the model may have reversed winding and names the follow-up (`rotate … 180` is *not* suggested as a fix; the help points at re-exporting with flipped normals / a future `flip` prop) | warning |

Each new code needs a P08 §6.3 `--explain` page before this feature ships;
wording follows P08 §9 (no "invalid", no "malformed" in user text — the
table above is internal shorthand; user headers say what happened, e.g.
`E5103`: "line 40 of 'car.obj': this face has only 2 corners — a face
needs at least 3 points to have a surface").

### 9.3 The load summary (success path, stdout, one line per file)

Consistent with P08 §5.2 (progress/summary on stdout, diagnostics on
stderr), a successful load prints exactly one summary line, e.g.:

```
loaded 'car.obj': 4 objects (body, door, wheel-fl, wheel-fr), 12,408 triangles
  from 8,214 faces · 24,630 vertices · materials and UVs in the file were not used (W5101)
```

The counts come from `LoadedFile` (§8.1) — they are also what the tests
assert (§10), so the summary can never drift from reality.

### 9.4 Exit behaviour

Any `E51xx`/`E5003` from a `load` ⇒ scene errors ⇒ P08 exit `1` (or `3`
for pure IO), nothing rendered, no partial object in the scene, footer
per P08 §7 ("nothing was rendered"). Warnings ⇒ render proceeds, exit
`0`, warnings counted in the footer.

---

## 10. Acceptance tests (all must exist before "done")

1. **Round-trip golden:** load the repo's `model.obj` ⇒ exactly 1 group,
   12 triangles, positions matching the file's 36 `v` lines in order
   (tolerance 1e-4, the exporter's `F9.4` precision); re-export via
   `export_mesh_obj` and diff against the original — byte-identical
   except possibly the header line. Render equals the current cube
   render up to colour (white vs per-face palette, §5.4).
2. **Face forms:** one fixture per §3.3 form (`i`, `i/j`, `i//k`,
   `i/j/k`), each a single triangle with known pools; assert triangle
   positions and that `vt`/`vn` indices out of range still error
   (`E5104`) even though the data is discarded.
3. **Negative indices:** a quad written entirely with negative indices
   loads to the same 2 triangles as its positive-index twin.
4. **Polygons:** quad ⇒ 2 triangles (fan order asserted); convex pentagon
   ⇒ 3; face with 2 corners ⇒ `E5103`; mixed-form face ⇒ `E5103`.
5. **Groups:** fixture with `o`/`g`, an unnamed leading group, an empty
   group, and a name needing sanitising ⇒ expected object list, names,
   and `W5103`; whole-load vs per-group DSL addressing per §6.2.
6. **Real-world-shaped file:** a Blender-style export fixture (comments,
   `mtllib`, `usemtl`, `vn`, `vt`, `s`, CRLF line endings, blank lines)
   loads with exactly one `W5101` and correct geometry.
7. **Error fixtures (golden stderr, P08 §10 style):** missing file
   (`E5003` + did-you-mean), index 0, index past end, forward reference,
   bad number, NaN vertex, no faces, all-degenerate, over-cap vertices,
   `.gltf` refusal (§7.4 text), unknown extension. Each asserts: correct
   code, correct exit status, **no output file written**.
8. **Degenerates:** file with 3 degenerate + 7 good faces ⇒ 7 triangles
   + `W5102` with count 3.
9. **DSL defaults:** `load "model.obj"` alone renders the cube centred
   at size 2 (§6.3) — pixel-diff against a reference render; `size` +
   `scale` together ⇒ conflict error; `load` of a multi-group file +
   `spin it` moves all groups (§6.2).
10. **No-crash sweep (extends P08 §10.3):** the §10.6 fixture truncated
    at every byte offset, plus random single-token mutations, must exit
    1/3 with a diagnostic — never a Fortran backtrace, never exit 0 with
    a partial render.

---

## 11. Implementation sequence

| # | Milestone | Contents | Exit test |
|---|---|---|---|
| M1 | Core loader | `obj_loader.f90`: line/token machinery, `v`/`f` (form `i` only), pools, negative indices, de-indexing, bbox, diag wiring | §10.1, §10.3, §10.7 (index/number cases) |
| M2 | Full face & file surface | `vt`/`vn` parse-validate-discard, all corner forms, fan triangulation, degenerates, limits, unknown-keyword handling, `W5101`/`W5102` | §10.2, §10.4, §10.6, §10.8 |
| M3 | Groups + DSL | `o`/`g` → objects, name sanitising, `load` statement + defaults (§6.3), whole-load/per-group addressing, path resolution, glTF/unknown-extension refusals | §10.5, §10.9, §10.7 (extension cases) |
| M4 | Hardening + docs | No-crash sweep, `--explain` pages for `E51xx`/`W51xx`, manual chapter (subset table §3.2 and the §4.6 materials honesty note, in substance) | §10.10; P08 banned-word lint on new templates |

M1 alone already satisfies the headline promise (`load "model.obj"`
renders the repo's own model). M2–M4 may be cut only by turning the
affected inputs into targeted errors — never by accepting-and-ignoring
(§2.3), and the §3.2 disposition table must be updated in the same change
so the manual never claims what the code doesn't do.

## 12. Risks & open questions

- **Concave-quad fan artefact (§5.2)** is the known geometric wart. If a
  test fixture demonstrates it visibly, ear-clipping for quads only is a
  small, contained upgrade — decide on evidence, not preemptively.
- **`centre`+`ground`+`size 2` defaults (§6.3)** diverge deliberately from
  P03's primitive defaults. If the P03 owner prefers one global default
  story, the fallback is an explicit `load "x.obj" auto` sugar word —
  but *some* framing default is non-negotiable for real-world files.
- **Colourless models look flat-white** under a single directional light
  for axis-aligned faces (all faces of an untextured box at one
  intensity). Acceptable for v1; per-group default *tints* were considered
  and rejected (surprising, un-teachable). The manual example should load
  with an explicit `colour`.
- **P10 interaction:** if P10's `Triangle%vnormal` and material table
  land before M2, §5.4's additive `vn` retention and a `usemtl` →
  material-*name* binding (still no `.mtl` file reading) should be folded
  into M2 rather than retrofitted. Coordinate between the two plans at
  implementation time; neither plan's v1 scope depends on the other.
- **Binary garbage renamed `.obj`** is caught by the NUL-byte check
  (`E5101`) only heuristically; the line-length and number errors catch
  most of the rest. Good enough for v1 — a magic-number sniffer is
  over-engineering for a text format with no magic number.
