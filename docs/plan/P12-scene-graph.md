# P12 — Scene Graph & Transforms: Flat + Groups (v1)

> Status: planning only (no engine code changed). This plan is the
> normative spec for scene structure; where earlier plans conflict it
> supersedes them on this topic only (see §2.3).
> Repo ground truth at design time:
> `src/math_3d.f90` (`vec3`, `mat4`, `mat4_translation/scale/rotate_x/y/z`,
> `mat4_mult`, `mat4_transform_vec3` — all `pure`),
> `src/mesh.f90` (`Mesh{num_triangles, triangles(:)}` — one flat triangle
> soup per mesh, no object identity, no transform stored),
> `src/renderer.f90` (`framebuffer_render_mesh(fb, mesh, model_matrix, cam,
> light_dir)` — exactly one model matrix per mesh per call),
> `src/main.f90` (one hard-coded cube, one composed matrix
> `mat4_mult(rot_y(35°), rot_x(20°))`),
> `scene.json` (flat baked `{triangles:[{id,v,color}]}` — no nodes),
> `viewer.html` (one flat `triangles` array, one global `rotX/rotY` for the
> whole scene — no per-object anything).

## 1. Decision in one paragraph

**v1 is a flat list of objects, plus one level of named groups.**
A group is an *authoring and targeting convenience*, not a runtime tree:
it owns a TRS transform (§4) and a set of member objects, and the compiler
flattens it away — every backend receives a flat list of objects, each with
one pre-composed world matrix. There is no group inside a group, no
object parented to another object, no recursion, no cycles, and therefore
nothing in the Fortran or JS backends ever walks a tree. Beginners get the
one hierarchy idea they actually reach for ("move the whole car"), and
both backends keep the flat shape they already have today.

```
scene (implicit root, identity transform)
├── object  cube1                      ← depth 1, parent = root
├── object  cube2
└── group   car          (TRS only, no geometry)
    ├── object  body                   ← depth 2, parent = car  ← MAX
    └── object  wheel                  ← depth 2, parent = car  ← MAX
```

## 2. Flat list vs hierarchy — why this split

### 2.1 The options, honestly

| Model | Beginner cost | Backend cost | Verdict |
|---|---|---|---|
| Pure flat list (today) | Zero new concepts; but moving a 4-part car = editing 4 `at`s, and `spin` can only target one object at a time | Zero: `Mesh` + one matrix per render call already is this | Kept as the **execution model** |
| Full hierarchy / scene graph (Three.js `Object3D`, Pixi `Container`) | Parent/child, local-vs-world, traversal order, reparenting — the single biggest beginner cliff in P01/P02 | Fortran: recursive/pointer types, cycle checks, per-frame tree walk. JS (P06): the graph P06 explicitly refused to ship | **Rejected for v1** |
| **Flat + one group level (this plan)** | One new word (`group`), one new idea (members move together). No paths, no traversal vocabulary | Compile-time only: one extra matrix multiply per grouped object. Backends unchanged in shape | **v1** |

### 2.2 What groups buy, concretely

1. **Move/pose together:** `move car …`, `rotate car …`, `spin car` (§7)
   transform every member at once.
2. **Relative placement:** a member's `at` is written relative to the
   group origin (§5.2) — build a car around its own centre once, place
   the car anywhere.
3. **Reusable sub-assemblies:** combined with `repeat` (P04) a group is
   the unit a beginner duplicates to make a row of houses/cars.

What groups do **not** buy in v1, by design: geometry (a group draws
nothing), colour/material/size inheritance, visibility/layer systems,
constraints, or a second coordinate vocabulary.

### 2.3 Reconciliation with earlier plans

- **P03 §11** deferred "grouping & parenting" entirely and P03's grammar
  has no blocks except optional `scene … end`. This plan lifts that one
  deferral, in the smallest form: `group … end` (§6) reuses P03's exact
  block style — no braces added to the language.
- **P04 §2/§4.3/§5.1** sketched `group { … }` with transform nesting and
  AST `GroupStmt(props, body)`. The *AST/IR idea is kept* (a group node
  with props + member list); the brace syntax is not (P03 line style wins),
  and "nesting" is capped at depth 1 instead of being general (§8).
  P04's O6 "compose group TRS chain into one `mat4` per object" becomes
  trivial: the chain is at most two matrices long (§5.3).
- **P06 §1.2/§4.3** excluded a runtime scene graph and required the
  compiler to flatten. This plan honours that exactly: the JS runtime
  never sees a live group object (§10) — at most a `group` name string
  for animation targeting.
- **P09 §1/§10** listed "per-object identity" as animation's missing
  prerequisite. This plan supplies it: node ids/names (§9.1) and
  per-object world matrices are what P09 tracks target.

## 3. Vocabulary (the whole of it)

| Word | Meaning |
|---|---|
| **node** | Anything addressable: an object or a group. Internal term; users say "object" and "group". |
| **object** | A leaf node with geometry (v1: a primitive/mesh from P03). Has a local TRS + pivot. |
| **group** | A named node with a local TRS + pivot and ≥ 0 member objects. No geometry. |
| **root** | The implicit scene node. Identity transform, unnamed, cannot be targeted, moved, or written in the DSL. Ungrouped objects are its members. |
| **local transform** | A node's own TRS, as written. For a grouped object: relative to its group. |
| **world transform** | Local transform composed with the parent's world transform. What backends consume. Never written by the user in v1. |
| **pivot** | The local point that rotation and scale act *about* (§4.3). Default: the node's own origin. |

Names: **one global namespace** for objects and groups (a group and an
object may not share a name; two objects in different groups may not
either). This is the price of having no path syntax — `spin wheel`
and `spin car` are both unambiguous with no `car/wheel` spelling.
Duplicate → error (§8).

## 4. TRS — the one transform model

### 4.1 Components and defaults

Every node (object or group) carries exactly these fields:

| Field | DSL | Type / unit | Default |
|---|---|---|---|
| position | `at x y z` (`pos` alias) | `vec3`, world units | `0 0 0` |
| rotation | `rotate x y z` (`rot` alias) | Euler angles, **degrees**, one angle per axis | `0 0 0` |
| scale | `scale s` or `scale sx sy sz` | unitless factors; `scale s` = uniform `(s,s,s)` | `1` |
| pivot | `pivot x y z` | `vec3`, in the node's **local** (pre-transform) coordinates | `0 0 0` |

Notes grounded in the engine: position/scale map 1-to-1 onto the existing
`mat4_translation` / `mat4_scale`; rotation is stored as degrees in the
AST/IR and converted once at lowering (`deg * PI / 180`), exactly as
`main.f90` does today and P03 §7 / P04 §3.2 already require. There are no
quaternions, no axis-angle form, no shear, and no matrix input in v1 DSL.

### 4.2 Composition order (fixed, documented, never configurable)

For one node, with `T` = translation, `R` = rotation, `S` = scale,
`P` = pivot point:

```
M_local  =  T(position) · T(pivot) · R · T(−pivot) · S
R        =  Ry · Rx · Rz          (all angles converted to radians first)
world(v) =  M_world · v           (column-vector convention, as in math_3d)
```

Reading right-to-left as application order: a vertex is scaled first
(about the origin), un-pivoted/translated so the pivot sits at the origin,
rotated, moved back, then positioned. Consequences the docs must state
plainly for beginners:

- **Scale first, then rotate, then move** — the classic TRS promise:
  `rotate` never changes where `at` put the object, and `scale` never
  changes its direction of travel. (This is P03 §7 / P09 §3's `T·R·S`,
  now with the pivot factor made explicit.)
- **Euler order is Z, then X, then Y** (because `Ry·Rx·Rz` applies `Rz`
  first). This is chosen for continuity, not novelty: with `z = 0` it
  reduces to `mat4_mult(rot_y, rot_x)` — *byte-for-byte the composition
  `main.f90` already ships*. Gimbal lock at `x = ±90°` is a real Euler
  property; v1 accepts it (quaternions are a deferred decision, §11),
  and the manual must say so in one sentence, not hide it.
- Animation (P09) composes on top, unchanged: per frame
  `M_local(t) = T · T(pivot) · R_static+animated(t) · T(−pivot) · S`.

### 4.3 Pivot semantics

- Pivot is the centre of **rotation and scale only**. Translation is
  unaffected by pivot (moving `at` moves the whole node, pivot included).
- Pivot coordinates are in the node's local geometry space, i.e. the
  space the primitive was built in *before* its own TRS. For a centred
  cube (`create_cube` builds `[-h,+h]³`), `pivot 0 0 0` = its centre —
  hence the default "spins in place" behaviour beginners expect.
- Canonical uses the spec must show as examples:
  - *Hinge:* a door slab built/placed so its edge is at local `x = -1`:
    `pivot -1 0 0` makes `rotate … y …` swing it from the edge, not the middle.
  - *Axle / group origin:* a wheel grouped with its car (§6 example)
    spins about its own centre because its centre *is* its local origin;
    a group pivot lets a whole group orbit a point outside itself
    (e.g. cars on a roundabout: group `pivot` at the roundabout centre).
- Pivot is **not** inherited: a member uses its own pivot inside the
  group's already-transformed space. Group pivot and member pivot compose
  through §5.3 — no special case.
- Non-uniform scale + rotation is legal; normals are safe on both
  backends without extra user action: Fortran recomputes the face normal
  from world vertices in `framebuffer_render_mesh`, and the JS side must
  use the normal matrix (inverse-transpose of the world 3×3, already in
  P06 §5.2 as `nm`) — never the raw world matrix for normals.

### 4.4 Validation of TRS values (parse/validate time, P08 style)

| Rule | Error (plain English, with line) |
|---|---|
| Every `scale` component `> 0` | `line N: scale cannot be 0 or negative — got -1. Use rotate to flip an object.` Negative scale = mirroring (flips winding/back-face culling in `renderer.f90`); deferred, §11 — rejected, never silently honoured. |
| `at` / `rotate` / `pivot` = exactly 3 numbers | `line N: 'at' needs 3 numbers (x y z) — got 2.` |
| `scale` = 1 or 3 numbers | `line N: 'scale' needs 1 number (same all sides) or 3 (x y z).` |
| All TRS numbers finite | NaN/overflow literals rejected by the lexer/parser path (P04 guards). |

## 5. Parent–child semantics (depth ≤ 1 of grouping)

### 5.1 The rules

1. A group's members are **objects only**. A `group` statement inside a
   `group … end` block is an error, not nesting (§8).
2. An object belongs to **at most one** group: the block it is written
   in, or root if written outside any block. There is no `parent`
   keyword, no reparenting statement, and no membership by reference in
   v1 — where you write it is where it lives.
3. A group has **no members by reference**: you cannot write
   `group car contains body wheel`. Membership is purely textual
   containment inside `group … end`.
4. Only **TRS is inherited**. Colour, size, material, and pivot are never
   inherited from a group; a group statement carrying `colour`/`size`
   is an error with a hint (`groups have no colour — colour the objects
   inside`), not a silent no-op.
5. Order inside a group is source order, and groups sit in the flat
   object list at the position of their first member (§9.2). Draw order
   is semantically irrelevant for the Fortran Z-buffer backend; for the
   JS painter's-sort fallback (P06 §9) the compiler's depth-sort hint
   (P04 O7) is computed *after* flattening, on world geometry.

### 5.2 Local means local — the one surprise, stated up front

Inside a group, `at` is **relative to the group origin**, and
`rotate`/`scale` are relative to the group's orientation/scale:

```f3d
group car at 10 0 0
  cube body red at 0 1 0 size 2     # world position (10, 1, 0)
  cube cab  blue at 0 2 0 size 1    # world position (10, 2, 0)
end
move car at 0 0 0                   # whole car now centred on origin;
                                    # body is at (0,1,0), cab at (0,2,0)
```

The compiler's `--explain` desugaring (P03 §3) must print both the local
line and the resolved world position for every grouped object, so this
is never a silent surprise. Group scale multiplies member sizes and
member offsets alike (`group … scale 2` doubles the car *and* the gap
between its parts) — that is what scale inheritance means, and the
manual shows it with this exact example rather than apologising for it.

### 5.3 World composition (the entire "scene graph evaluation")

```
M_world(object) = M_local(object)                                  if parent = root
M_world(object) = M_local(group) · M_local(object)                 if grouped
M_world(group)  = M_local(group)                                   (groups have only root as parent)
```

That is all. Maximum chain length = 2, evaluation is a single forward
pass in source order (a group statement is fully parsed before its
members are lowered, so the parent matrix always exists first), and no
dirty-flagging, caching, or traversal machinery exists in v1 — static
scenes compose once at compile time; animated nodes recompose per frame
from P09 tracks targeting the node, still with chain length ≤ 2.

## 6. DSL syntax

Extends P03's grammar; everything else in P03 is unchanged. Line-oriented,
`#` comments, case-insensitive keywords, no braces, no commas required.

```ebnf
group-stmt   = "group" , name , { node-prop } , newline ,
               { object-stmt , newline } ,      (* objects only — §5.1 *)
               "end" ;
node-prop    = "at" , vec3 | "pos" , vec3
             | "rotate" , vec3 | "rot" , vec3
             | "scale" , number , [ number , number ]
             | "pivot" , vec3 ;
object-prop  = (* all P03 object-props, plus *) "pivot" , vec3
             | "scale" , number , [ number , number ] ;
```

- `scale` and `pivot` are **new object props** added by this plan to
  P03 §4's `object-prop` list (P03 had `scale` only as a transform
  *action*); they follow the same "at most once per statement" rule
  (P03 §4.1).
- A group **must be named** (unlike objects, which may be anonymous /
  `last`). An unnamed group could never be targeted, which is its only
  purpose — `group` with no name is a parse error suggesting a name.
- `end` closes the innermost (and only) open block; `scene … end`
  (P03 §4.2) and `group … end` may not interleave: a group inside the
  optional scene block is fine, a scene block inside a group is not.
- Empty group (`group x` immediately followed by `end`): legal syntax,
  **warning** `group 'x' has nothing in it`, and the group is dropped
  from the IR (it can still not be targeted — targeting it is then the
  §8 unknown-name error). Dropping beats keeping a no-op node.

### 6.1 Worked example — the car

```f3d
# Two cars from one idea: local build, global placement
group car1 at -3 0 0 rotate 0 30 0
  cube body red   at 0 0.5 0 size 3 1 1        # size sx sy sz per P03
  cube cab  blue  at 0 1.25 0 size 1.5
  cube wheel1 black at -1 0 0.6 size 0.5
  cube wheel2 black at  1 0 0.6 size 0.5
end

group car2 at 3 0 0 rotate 0 -30 0 scale 0.5
  cube body2 red   at 0 0.5 0 size 3 1 1
  cube cab2  blue  at 0 1.25 0 size 1.5
end

spin car1 speed 45          # §7: every member of car1, about car1's pivot
render
```

(Duplicated member names with suffixes are v1 reality — there are no
templates/instancing in v1; `repeat` from P04 may generate the second
car, and if it does it must auto-uniquify names under the §3 global
namespace rule or fail with the duplicate-name error.)

## 7. Targeting groups (transform & animation statements)

P03's `target = name | it | last | all` is extended by interpretation,
not by new syntax:

| Statement | On an object | On a group |
|---|---|---|
| `move <t> at …` / `rotate <t> …` / `scale <t> …` | Sets the object's **local** TRS field(s) | Sets the group's local TRS field(s); members follow via §5.3 |
| `spin <t> …`, `animate <t> …` (P09 tracks) | Animates the object | Compiler expands to one track per member **composed with** an animated group matrix — i.e. the group node itself is the track target in the IR, and both evaluators apply `M_group(t) · M_member`. Members keep any of their own tracks too (composition order: group outside, member inside) |
| `all` | Every object | Every object, grouped or not (groups themselves are not separately transformed — `all` already reaches their members, so applying group transforms too would double-apply) |

- `it` / `last` after a `group … end` block refers to the **group**
  (it is the most recently created node), so the P03 idiom
  `group … end` / `spin it` works. Inside a block, `last` still means
  the last object created, as in P03.
- Setting a grouped object's TRS from outside its block
  (`move wheel1 at …`) is legal and edits its **local** values; the
  `--explain` output and the manual must say "local" out loud, because
  the resulting world position is `group · local` (§5.2).

## 8. Limits & errors (v1, exhaustive)

| Case | Behaviour |
|---|---|
| `group` inside `group` | Error: `line N: groups cannot go inside groups in v1 — end group 'car' first, or merge the two groups.` Never auto-flatten silently: the user wrote a structure the language does not have. |
| Object inside object / any block other than `scene`/`group` containing statements | Existing P03/P04 syntax error path. |
| Duplicate name (object↔object, group↔group, object↔group, incl. across groups) | Error (extends P04 `E310`): `line N: 'wheel' is already used at line M — names must be unique everywhere, even in different groups.` |
| Targeting an unknown name | Existing P03 unknown-target error, with did-you-mean over the global namespace (P04 `E302` machinery). |
| Group with `colour`/`size`/`radius`/geometry words | Error: `line N: a group has no colour/size of its own — put it on the objects inside the group.` |
| Group depth / count caps | Depth is structural (≤ 1, above) — no runtime cap needed. No cap on number of groups or members in the spec; compiler resource guards from P04 (source/token limits) apply unchanged. |
| Self-reference / cycles | **Impossible by construction**: membership is textual containment and names cannot be referenced as parents, so no cycle check exists or is needed. This is a headline benefit of the flat design — state it, don't add the check anyway. |
| Forward reference (`spin car` before `group car`) | Follows P03's existing resolve-after-parse behaviour for targets: allowed only if the name is declared somewhere in the program; otherwise the unknown-name error. Groups get no special case. |

Proposed diagnostic codes (final allocation is P08's): reuse `E310`
(duplicate name), `E302`-family (unknown name/property) and add one
code for group-in-group and one for property-on-group.

## 9. Compiler / IR representation

### 9.1 IR node list (extends P04 §5.2 `IRScene`)

The IR keeps the graph *information* (it is cheap and diagnostics,
`--explain`, and animation targeting need it) while keeping the
*shape* flat — a list, not a tree type:

```text
Transform  { pos: vec3, rot_deg: vec3, scale: vec3, pivot: vec3 }
Node       { id: int,                 # 1-based, source order; 0 = root (never stored)
             name: str | None,
             kind: OBJECT | GROUP,
             parent: int,             # 0 = root, else a GROUP node's id; OBJECT id here = invalid IR
             local: Transform,
             world: mat4,             # filled by the flatten pass, §9.2
             mesh: PrimKind | MeshRef | None }   # None iff GROUP
IRScene    { …, nodes: list[Node] }   # groups and objects in ONE list, source order
```

Invariants the IR verifier (P04 §4.3 / P07) must check: every
`parent` is `0` or the id of an *earlier* `GROUP` node; every `GROUP`
has `mesh = None`; ids are dense and source-ordered. "Earlier" is what
makes single-pass flattening sound.

### 9.2 Flatten pass (where groups die)

Runs in P04's desugar/optimize position (after defaults, before emit;
merges with P04 O6 transform bake):

1. Inject defaults into every node's `Transform` (P03 §6 + §4.1 here).
2. For each node in list order: compose `M_local` per §4.2 from the
   existing `mat4_*` constructors; set
   `world = (parent == 0) ? M_local : nodes[parent].world · M_local`.
   A group node's `world` is computed only to serve its members.
3. Emit list = the `OBJECT` nodes only, each carrying its one `world`
   matrix. Group nodes are retained in the IR dump / source map (for
   errors and `--explain`) and **dropped from every backend payload**.

No recursion, no stack, no topological sort: list order + the
"parent is earlier" invariant is the whole algorithm — O(n) with
n = node count, ≤ 2 matrix multiplies per object.

### 9.3 Legacy path

`scene.json` v1 input (P04 compat reader) has no nodes at all: it
lowers to a single anonymous OBJECT node at root with identity TRS and
the baked triangles as its mesh — today's files keep working, and the
round-trip in §12.5 holds.

## 10. Backend representations

### 10.1 Fortran (native target)

Fortran gets **no scene-graph type**. The flat shape is a deliberate
match to what the language and the current code do well — allocatable
arrays and integer indices, no recursive derived types, no pointer
parent links (which would be the first and worst Fortran version of
this feature):

```fortran
! PLANNED shape only (new module src/scene.f90, owned by the build plan)
type :: Transform                  ! mirrors IR Transform, angles in degrees
    type(vec3) :: pos, rot_deg, scale, pivot
end type
type :: SceneNode
    integer :: parent = 0          ! index into nodes(:); 0 = root
    integer :: mesh_index = 0      ! index into meshes(:); 0 = group (draws nothing)
    type(Transform) :: local
    type(mat4) :: world            ! composed once at load/build time
end type
type :: Scene
    type(SceneNode), allocatable :: nodes(:)
    type(Mesh),      allocatable :: meshes(:)   ! existing mesh_3d type, now an array
end type
```

- Composition uses only existing pure functions:
  `world = mat4_mult(parent_world, mat4_mult(T, mat4_mult(Tp, mat4_mult(Ry, mat4_mult(Rx, mat4_mult(Rz, mat4_mult(Tnp, S)))))))`
  — written as a helper `compose_trs(Transform) result(mat4)` in the
  planned scene module, not inlined at call sites.
- Rendering is a flat loop replacing `main.f90`'s single call; the
  renderer's signature does not change at all:

```fortran
do i = 1, size(scene%nodes)
    if (scene%nodes(i)%mesh_index == 0) cycle          ! group: nothing to draw
    call framebuffer_render_mesh(fb, scene%meshes(scene%nodes(i)%mesh_index), &
                                 scene%nodes(i)%world, cam, light_dir)
end do
```

- Animation (P09): per frame, recompose `world` only for nodes with a
  track (and their members, chain ≤ 2) — same loop, no tree walk.
- **Exports:** `export_mesh_json` today bakes one mesh. v2 export
  (§10.2) writes per-object meshes + world matrices; legacy v1 export
  keeps working by baking `world` into each object's triangles and
  concatenating into the single flat `triangles` list — groups are
  unrecoverable from a v1 file, which is acceptable and documented
  (v1 JSON was always a baked render artifact, §9.3).

### 10.2 JS runtime (per P06 contract — player, not engine)

The runtime's internal and wire representations stay flat; groups exist
only as compile-time data the *compiler* already consumed:

```jsonc
// scene.json v2 (extends P06 §4.2 — additive, unknown keys ignored there)
{ "f3d": 2,
  "meshes": [
    { "name": "body",  "group": "car1",            // optional label only:
                                                   // picking, HUD, anim targeting
      "positions": [/* … */], "colors": [/* … */],
      "transform": [/* 16 floats, column-major WORLD matrix (§5.3 result) */] },
    { "name": "wheel1", "group": "car1", "positions": [/* … */], "transform": [/* … */] }
  ],
  "anim": [ { "mesh": "body", "prop": "ry", "keys": [[0,0],[2,6.283]] } ] }
```

Rules:

1. **No `Group`/`Object3D` class, no children arrays, no traversal** in
   `f3d.js` — P06's size budget (§10 there) is not spent here. The
   loader reads a flat `meshes[]`, one buffer set + one matrix each,
   exactly as P06 §5.1 already specifies; per-frame cost for a grouped
   object is identical to an ungrouped one (zero).
2. `transform` on the wire is the **world** matrix. A compiler that
   wants live group animation (P09 group tracks, §7) does *not* ship
   the group node; it ships the group's track expanded per member
   (compiler-side composition into each member's animated matrix), or
   equivalently per-member tracks — the runtime evaluator stays the
   P06 §7.2 per-mesh TRS evaluator. Group structure is therefore
   unrecoverable in the browser too, by design.
3. `group` (string) is metadata only: the runtime may surface it in
   `viewer.state` / a future picking add-on (P06 §1.2 add-on rule) and
   must ignore it for rendering. A v2 file without any `group` keys is
   the common case and must be indistinguishable in output.
4. The current `viewer.html` flat-`triangles` path is the degenerate
   case of the same model (one implicit object, identity world,
   global orbit camera) — P06's v1-compat loader already covers it;
   this plan adds nothing to it.

### 10.3 Parity rule

Fortran and JS must produce the same world matrices from the same IR:
same composition order (§4.2/§5.3), same degree→radian conversion point
(at matrix composition, never stored in radians in IR), same
column-major layout (P06 §3 — Fortran `mat4` is already column-major
compatible). The §12 parity fixture is the enforcement, not prose.

## 11. Explicitly deferred (not v1, each needs its own ruling)

- Groups inside groups / arbitrary depth; object-as-parent
  (`wheel` parented to `car` as an object); reparenting statements;
  path names (`car/wheel`).
- Instancing/templates (`group` defined once, placed many times with
  shared geometry) — distinct from P04 `repeat` unrolling.
- Quaternions / axis-angle / look-at orientation; shear; negative
  (mirroring) scale; per-axis pivot animation.
- Inheritance of colour/material/visibility; group-level clipping,
  layers, or render-order control.
- World-space editing (`move wheel1 to world …`) and any statement
  that reads a computed world transform back into the DSL.
- Runtime (JS or Fortran) scene-graph APIs for user scripting.

Each, if approved later, must preserve: the 3-line P03 contract, the
flat backend payloads (§10), and old `.f3d` programs' meanings. Depth,
if ever raised, should go to a *stated* new cap (e.g. 3) — not to
"unlimited" by default.

## 12. Acceptance criteria (for the build that follows this plan)

1. **Regression anchor:** an ungrouped program renders byte-identical
   output to today's hard-coded demo path (same rule as P03 §10), and
   a program whose objects are wrapped in an identity-transform group
   renders byte-identical output to the same program ungrouped.
2. **Translation inheritance:** §5.2's example — grouped `body` lands
   at world `(10,1,0)`; verified in `--explain` output and in the
   rendered frame / exported v2 `transform`.
3. **Rotation inheritance:** a group rotated `rotate 0 90 0` moves a
   member at local `(2,0,0)` to world offset `(0,0,-2)` from the group
   origin (sign per §4.2's `Ry`), in both backends.
4. **Scale inheritance:** group `scale 2` doubles member size *and*
   member offset; group `scale 0` and member `scale -1` each produce
   the §4.4 error and no output file.
5. **Pivot:** a cube with `pivot -1 0 0` rotated `0 90 0` about Y
   occupies the hinge position predicted by §4.2's formula (golden
   matrix in the test, not eyeballed); pivot on a group orbits its
   members around the group pivot.
6. **Errors:** group-in-group, duplicate name across groups,
   `colour` on a group, and unnamed group each produce exactly the
   §8 message shape (line number + plain-English fix) and exit non-zero.
7. **Targeting:** `spin <group>` animates all and only its members;
   `spin all` does not double-apply group motion (§7); `spin it`
   after `group … end` targets the group.
8. **Parity:** one grouped fixture scene (≥ 2 groups, ≥ 5 objects,
   non-uniform scale, one pivot, one group rotation) produces world
   matrices from the Fortran and JS paths agreeing to ≤ 1e-6 per
   element, and stills differing only within P06 §12.2's colour
   rounding tolerance.
9. **Legacy:** today's `scene.json` (12 triangles) loads through
   §9.3 and renders unchanged in both backends; legacy v1 export of a
   grouped scene produces a flat file that renders the same still.

## 13. Risks

| Risk | Mitigation |
|---|---|
| Local-vs-world confusion is *the* beginner bug of every grouped system | §5.2 example in the manual's first group page; `--explain` prints resolved world positions; group-relative wording in every group error message |
| Two syntax traditions (P03 `end`, P04 `{}`) drift apart in implementations | §2.3 rules P03 style canonical for v1; P04 AST node kept so a later brace sugar is an alias, not a redesign |
| Users immediately ask for nested groups (cars in a convoy in a city) | §8 error message teaches the v1 workaround (one merged group / `repeat`); §11 records the capped-depth path instead of a silent "never" |
| Global namespace feels restrictive in big scenes | Accepted v1 cost of no path syntax; auto-uniquified names under `repeat` (§6.1) cover the common mechanical case |
| Euler gimbal lock surprises at `rotate 90 0 0`-style poses | Documented in §4.2; static-pose scenes (v1's bulk) are unaffected in practice; quaternions stay a §11 decision, not a patch |

---

*End of P12. Companions: P03 (grammar/defaults this extends), P04
(pipeline/IR/flatten position), P06 (JS wire format & size budget),
P08 (diagnostic codes/wording), P09 (animation targeting of nodes).*
