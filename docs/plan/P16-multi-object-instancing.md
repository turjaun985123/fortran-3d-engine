# P16 — Multi-Object Scenes & Instancing

> **Status:** Planning only — no `src/` changes in this document.
> **Repo state audited:** `src/main.f90`, `src/mesh.f90`, `src/renderer.f90`,
> `src/math_3d.f90`, `src/camera.f90`, `scene.json`, `viewer.html`,
> `Makefile` (2026-11-23), plus companion plans P03 (DSL grammar),
> P04 (compiler pipeline), P06 (JS runtime), P07 (optimization passes).
> **Goal served:** an *easy* 3D compiler — a beginner who can place one
> cube should be able to place a street, a forest, or a wall of 100 cubes
> in one or two lines, without learning loops, arrays, or draw calls,
> and without the compiler silently producing a scene that takes a
> minute to render or a 20 MB `scene.json` to load.

---

## 0. Verdict in one page

| Decision | Ruling |
|---|---|
| Mental model | **Prototype + placements.** The user defines/creates a shape once and *places* it many times. DSL words are `repeat`, `grid`, `line`, `ring` — never `instance`, `clone`, or `draw call` in user-facing text. "Instancing" is a compiler/backend word only. |
| DSL surface | Multiple plain object lines (already in P03 §4.2/§9.4) **plus** three helpers (§3): `repeat N { … }` / one-line `repeat N cube …`, `grid nx ny nz spacing …`, and sugar `line`/`ring`. All are **compile-time expansions** with deterministic order. No variables, no general loops, no conditionals in v1 (preserves P03 §11). |
| Expansion cap | Per-helper cap **1,000** placements (inherits P04 §4.3's `repeat` cap of 1,000); **scene cap 10,000 objects / 1,000,000 triangles** after all expansion, checked on the *product* of nested helpers (§6, §8). Exceeding a cap is a compile **error** naming the arithmetic — never a silent truncation. |
| IR | Keep objects distinct: `IRObject { prototype_ref, model: Mat4, … }` (§5). **Do not** flatten to one triangle soup in IR. Flattening/merging is a per-backend, per-target lowering choice (§6–§7), so the same IR can be instanced on one backend and expanded on another. |
| Fortran backend | **Shared mesh + per-instance matrix loop (default).** One `Mesh` per prototype, one `framebuffer_render_mesh(fb, mesh, model_i, cam, light)` call per placement. This needs **zero renderer changes** — the signature already takes `(mesh, model_matrix)` and the Z-buffer lives in `fb`, not in the call (P04 §6.1). Expanded/merged soup is the fallback only when a prototype occurs once, or when P07 static-merge is explicitly selected for a small static scene (§6.3). |
| JS/WebGL backend | **Pseudo-instancing by default, real instancing opportunistically.** WebGL1 has no guaranteed instanced draw. Default: one VBO set per prototype, one draw per placement with a different `mvp`/`nm` uniform — same buffers, no duplicated geometry (§7.2). Use `ANGLE_instanced_arrays` + per-instance matrix attributes only behind a capability check, as an optimization of the identical scene. **Never** expand to per-instance geometry in v2 JSON. |
| Legacy `scene.json` v1 | **Expanded, always.** v1 (`{triangles:[…]}`) has no object, prototype, or transform concept, so v1 emit bakes every placement into world-space triangles. That is a *format* cost, disclosed with a size warning above 20,000 emitted triangles (§7.4). The current `viewer.html` keeps working unmodified. |
| Naming / pronouns | Every placement gets a deterministic auto-name (`wall`, `wall#2`, … / `cube7`). `it`/`last` inside a helper means the **whole helper result** for `spin`/`move` targeting, not the last single placement — otherwise `repeat 100 …` + `spin it` would spin one cube out of 100 (§3.4). Addressing one placement: `wall#37`, 1-based, in expansion order. |
| Animation | Animating a group animates every placement around its **own** centre (spin/pulse) or by the same delta (move/bob), unless `around scene` is written. Per-placement phase/step variation is via the helper's `step` clause (§3.3), not per-object statements. |
| Performance promise | Publish budgets, don't promise speed (§9): **green ≤ 25k tris (Fortran) / ≤ 100k tris (JS-WebGL)**, amber to 100k / 500k, red above. `f3dc` prints the scene's triangle + placement counts and its zone on every build — the beginner learns the cost from the tool, not from a hang. |

Non-goals for v1: user-defined reusable `define`/`prefab` blocks spanning
files, nested scene graphs / parenting (P03 §11, P04 flattens groups),
per-instance random scatter without a seed, physics/collision avoidance,
spatial partitioning authored by the user, GPU instancing in the Fortran
software rasterizer (there is no GPU there — §6.1), and editing one
placement's *geometry* differently from its prototype (colour/transform
may vary per placement; vertices may not — §5.2).

---

## 1. Where we start — the audited baseline

### 1.1 The engine today renders exactly one object, once

`src/main.f90` in full: one `type(Mesh) :: cube`, one
`call create_cube(cube, 2.0_dp)` (12 triangles), one composed
`model_matrix = rotY(35°) × rotX(20°)`, one
`call framebuffer_render_mesh(fb, cube, model_matrix, cam, light_dir)`,
one PPM, one `scene.json`, one `model.obj`. There is no scene type, no
object list, no name, and no second render call anywhere in the repo.

Three facts in that baseline are load-bearing for this plan:

1. **The renderer is already multi-object-ready.**
   `framebuffer_render_mesh(fb, target_mesh, model_matrix, cam, light_dir)`
   (`src/renderer.f90`) takes the mesh *and* its matrix per call, keeps all
   persistent state in `fb` (`pixels`, `z_buffer`), and never clears inside
   the call — clearing is `framebuffer_clear`, called only from
   `framebuffer_init`. So N sequential calls into one `fb` compose a
   correct multi-object image with correct inter-object occlusion, today,
   with no renderer edit. P04 §6.1 rests on the same fact.
2. **A mesh is a self-contained triangle soup.**
   `mesh_3d:Mesh { num_triangles, triangles(:) }`,
   `Triangle { v(3): vec3, normal: vec3, color(3): int }`
   (`src/mesh.f90`). No shared vertices (a cube is 36 vertex slots for
   8 corners), no transform stored in the mesh, no identity/name.
   Reusing one `Mesh` under many matrices therefore duplicates *nothing*.
3. **Exports are single-mesh.** `export_mesh_json(m, …)` /
   `export_mesh_obj(m, …)` each take one `Mesh`. Multi-object export is
   a compiler-side decision (merge-then-export, or a v2 format with an
   object list), not something the current exporters express (§6.4, §7.4).

### 1.2 What the companion plans already decided (this plan must not contradict)

| Plan | Already fixed | Consequence here |
|---|---|---|
| P03 §4–§6 | Line-oriented DSL; objects are `primitive [name] {props}`; `at/size/colour/rotate` props; `it`/`last`/`all` targets; unnamed objects auto-named `cube1, cube2, …`; multi-object scenes default `rotate 0 0 0` (demo pose is single-object only) | Helpers must be sugar that desugars to ordinary object statements (§4), and must respect the pronoun and default-rotation rules (§3.4) |
| P03 §11 | Variables, loops, grouping/parenting explicitly deferred from v1 grammar | `repeat`/`grid` here are *not* a general loop: fixed count, no variable, no body expressions. If the parent plan wants zero loop-like syntax in v1, §3 helpers move to v1.1 intact — the IR (§5) and backends (§6–§7) do not depend on the surface syntax |
| P04 §2, §4.3 | `group { … }` and `repeat n { … }` named as pipeline inputs; desugar expands `repeat` with **cap 1,000, error `E401` above**; group transforms flattened in desugar | This plan adopts the 1,000 cap, extends the check to nested products and to `grid` (§8), and specifies *what* expansion produces (§4) |
| P04 §5.2 | IR is `objects: list[IRObject]`, each with a baked `model: Mat4`, deduped `verts`, indexed `tris`, palette index | §5 adds `prototype_ref` + `placement` provenance to that shape; it does not replace it |
| P04 §4.4 (O2/O6) | Vertex dedup is per object; Fortran target re-expands indexed IR to soup because `Mesh` has no index buffer | Prototype dedup happens **once per prototype**, not once per placement — the main file-size win of §5 |
| P06 §4.2, §5.1 | JS scene v2 is `meshes: […]` with flat `positions`, optional `indices`/`transform`; runtime does **1 draw per mesh**, `STATIC_DRAW` buffers uploaded once; target ≤ 100k triangles/scene | §7 adds an optional `instances` array per mesh to v2 (additive, ignored-keys rule in P06 §4.2 rule 5 keeps old runtimes safe-ish — see §7.3 caveat) and redefines "1 draw per mesh" as "1 draw per placement" in the default path |
| P06 §9 | Canvas 2D fallback: painter's sort per triangle, budget > 20k tris → wireframe + warning | Painter's correctness now depends on sorting **across** placements, not within one mesh (§7.5) |
| P07 §4.2/§4.6 | Static transform baking; static mesh merge grouped by material, triangle count invariant, merge cap 1,000,000 tris | Merge (§6.3) is P07's pass applied at lowering time; instancing and merging are alternative lowerings of the same IR, chosen per prototype group (§6.3 rule table) |

### 1.3 The gap, stated plainly

Nothing today stops a *compiler* from emitting 100 render calls — but
nothing helps it either: no syntax to ask for 100 objects without writing
100 lines, no IR field saying "these 100 are the same cube", no rule for
what `spin it` means after a helper, no cap that fires before the user
generates a 1.2-million-triangle scene from `grid 100 100 100`, and no
guidance separating "100 cubes is nothing" from "100,000 cubes is a
different sport on a CPU rasterizer". This plan fills exactly those five.

---

## 2. Concepts — four words, kept separate

Confusing these is how instancing designs go wrong, so the compiler's
vocabulary (and the manual's) keeps them distinct:

| Word | Meaning | Example |
|---|---|---|
| **Prototype** | A geometry + default colour definition, built once. In v1, implicitly: one primitive kind + `size`/`radius`/`height` + base colour. | "a red cube of size 1" |
| **Object (statement)** | One authored DSL statement creating one placement (or, via a helper, many). | `cube hero red at 0 0 0` |
| **Placement** (a.k.a. instance, internal term) | One occurrence in the scene: a prototype + one `Mat4` + optional colour override. This is the IR unit (§5). | `wall#37` |
| **Draw** | One backend rendering operation. **Not** a user concept and not 1:1 with any word above: Fortran draws = placements (default) or merged groups (§6.3); JS draws = placements (default) or 1 per prototype (true instancing, §7.2). | — |

Rules that follow from the definitions:

- Placements of one prototype **share geometry exactly**. A placement may
  override `colour` (cheap: a per-placement colour or palette index) and
  its transform (position/rotation/scale). It may **not** override
  `size` in a way that changes geometry — `size` *is* a uniform/non-uniform
  scale in the placement matrix (consistent with P03: cube `size vec3` is
  a box scale), so this costs nothing and keeps sharing total.
- Two authored statements with identical primitive+geometry props are the
  **same prototype automatically** (compiler dedups by a prototype key,
  §5.1). The user never writes a prototype declaration in v1; `cube …`
  written 100 times by hand and `repeat 100 cube …` compile to the same IR.
- A prototype with exactly **one** placement is just an object. There is no
  separate code path, in IR or in either backend, for "single" vs "many".

---

## 3. DSL surface

Syntax below is shown in P03's canonical line form; where P04's block
form differs it is noted once (§3.5) and the semantics are identical.
New keywords: `repeat grid line ring step spacing around`. All are
reserved from v1 even if a given milestone defers one (§3.6), under
P03 §1 rule 8: reject with `not supported yet`, never substitute.

### 3.1 The baseline that already works: many plain lines

```f3d
cube red   at -2 0 0 size 1
cube green at  0 0 0 size 1
cube blue  at  2 0 0 size 1
render
```

Three objects, three placements, one prototype if `size`/colour matched —
here colour differs, so three prototypes under the §5.1 key (colour is
part of the v1 prototype key; see the trade-off note in §5.1). This is
the fallback every helper desugars to, and the form the manual teaches
first. Practical hand-writing limit: ~20 lines before a helper is kinder.

### 3.2 `repeat` — the headline helper

```f3d
# 100 cubes in a row, 2.5 units apart, marching +x from the first one's `at`
repeat 100 cube red size 1 at 0 0 0 step 2.5 0 0

# block form (P04 spelling) — same meaning, body may hold >1 statement
repeat 10 {
  cube blue size 1 at 0 0 0
  sphere red radius 0.4 at 0 1.2 0
} step 3 0 0        # 10 pairs = 20 placements; step applies per iteration
```

Semantics (normative, §4 gives the algorithm):

- `repeat N` runs its body N times. Iteration *k* (0-based) adds
  `k × step` to every `at` in the body. `step` defaults to `0 0 0`
  (a stack of coincident objects — legal, but see the `W` warning in §8.2).
- Optional per-iteration variation, all linear and beginner-readable:
  `turn <vec3>` adds `k × turn` degrees to `rotate`;
  `grow <number>` multiplies scale by `(1 + k×grow)`;
  `fade to <colour>` lerps colour from the body's colour to the target
  across the N placements. At most one of `grow`/`fade` per helper in v1
  (keeps the mental model to "one thing changes along the row").
- N must be a literal integer ≥ 1 in v1 (no expressions — P03 non-goal).
  `repeat 0` is an error with a hint, not an empty scene: a beginner who
  wrote 0 almost certainly miscounted.

### 3.3 `grid`, `line`, `ring` — named patterns, not arithmetic homework

The teaching failure this avoids: making a beginner compute
`x = (i mod 10) * spacing, z = (i div 10) * spacing` — a language with
no variables cannot even express that. The pattern *is* the statement:

```f3d
grid 10 10 cube green size 1 spacing 2.2 0 2.2 at -10 0 -10
#  = 100 placements; cell (i,j): at + (i*sx, 0, j*sz); order: row-major,
#    x fastest — so grid#1 is the `at` corner, grid#100 the far corner.

line 7 cube yellow size 0.8 from -6 0 0 to 6 0 0
#  = endpoints inclusive, evenly spaced; no `step` maths for the user.

ring 12 cube magenta size 0.7 centre 0 0 0 radius 5 facing centre
#  = placements on a circle in the XZ plane; `facing centre|out|none`
#    sets each placement's Y-rotation; default `none` (all same rotation).
```

- `grid nx [ny] nz`: 2 numbers = XZ ground grid (the common case);
  3 numbers = a 3D block (`ny` is vertical layers). `spacing` is a vec3
  with the same arity rule. A 1×1×1 grid is legal and equals one object.
- `grid` is *defined as* sugar over `repeat` (§4.2) so caps, naming, and
  error messages are shared — there is one expansion engine, not four.
- `scatter` (random placement in a box) is **deferred, keyword reserved**:
  it needs a seed for determinism (P04's byte-identical-output invariant)
  and collision expectations v1 cannot meet. `scatter …` →
  `not supported yet` error, per P03 rule 8.

### 3.4 Names, pronouns, and targeting after a helper

Deterministic naming is what makes a generated scene debuggable:

| Case | Auto-name rule |
|---|---|
| Plain statement, unnamed | As P03: `cube1`, `cube2`, … (global per-primitive counter) |
| Helper, unnamed body object | `<primitive><n>` continuing the same counter, in expansion order |
| Helper with a named body object | `name`, `name#2`, `name#3`, … (first placement keeps the bare name, so existing single-object references never break) |
| `grid`/`line`/`ring` | Same `#k` rule; k follows the pattern order defined in §3.3 |

Targeting rules (extending P03 §4.1's `it`/`last`/`all`):

- `it` / `last` after a helper = **the helper's whole placement set**
  (a *group reference* in the IR, §5.3). `spin it` after
  `repeat 100 …` spins all 100. This is a deliberate deviation from a
  naive "last object" reading, and the compiler must say so in
  `--explain` output: `spin it  →  spin wall (100 placements)`.
- A bare name that heads a `#`-family (`wall`) as a transform/animate
  target = the whole family. `wall#37` = exactly one placement.
- `all` = every placement in the scene (unchanged from P03).
- Naming collision: a user name equal to an auto-name, or two helpers
  given the same body name, → `E310`-class duplicate-name error
  (P04 §4.3) listing both source lines. `#` is therefore reserved in
  user names (lexer rule addition: `name` may not contain `#`).

### 3.5 Block vs line form — one desugaring

P04 §2 writes `repeat n { … }` and `group { … }`; P03 writes flat lines
with an optional `scene … end` wrapper only. **This plan does not pick
the winner** — it requires that whichever surface the core grammar
adopts, helpers desugar (§4) to the same flat placement list before
validation, and that the one-line form in §3.2 is always available
(it is the form a beginner types first). `group` (P04) with no `repeat`
is a helper with N=1 whose only effect is a shared transform prefix and
a group reference — it follows every rule in this section unchanged.

### 3.6 Grammar sketch (delta over P03 §4 EBNF)

```ebnf
statement      =/ helper-stmt ;
helper-stmt    = repeat-stmt | grid-stmt | line-stmt | ring-stmt ;
repeat-stmt    = "repeat" , integer , ( object-stmt | block ) , [ step-clause ] , { vary-clause } ;
grid-stmt      = "grid" , integer , integer , [ integer ] , object-tail , "spacing" , vec3 ;
line-stmt      = "line" , integer , object-tail , "from" , vec3 , "to" , vec3 ;
ring-stmt      = "ring" , integer , object-tail , "centre" , vec3 , "radius" , number , [ "facing" , ("centre"|"out"|"none") ] ;
object-tail    = primitive , [ name ] , { object-prop } ;   (* as P03, minus nothing *)
step-clause    = "step" , vec3 ;
vary-clause    = "turn" , vec3 | "grow" , number | "fade" , "to" , colour ;
block          = "{" , { object-stmt } , "}" ;              (* only if core grammar adopts P04 blocks *)
```

Constraints beyond EBNF: count integers ≥ 1; `grid` dimension integers
≥ 1; `ring radius > 0`; `line from ≠ to` when count > 1; at most one
`grow` and one `fade` per helper; helpers may nest at most **2 deep**
(`repeat { grid { … } }` is legal, a third level is an error pointing
at the cap arithmetic in §8 — nesting is where counts explode invisibly).

---

## 4. Expansion semantics (desugar — the one algorithm)

Expansion runs in P04's desugar stage (stage 3a), after defaults are
injected, in source order. It is pure, deterministic, and total:
either it produces a flat placement list or the compile fails (§8).

### 4.1 `repeat` expansion

```
expand(repeat N, body, step, vary):
  for k in 0 .. N-1:
    for stmt in body:
      placement.at     = stmt.at + k * step
      placement.rotate = stmt.rotate + k * turn        (if turn given)
      placement.scale  = stmt.scale * (1 + k*grow)     (if grow given)
      placement.colour = lerp(stmt.colour, fade_to, k/(N-1))  (if fade; N=1 → stmt.colour)
      placement.name   = auto-name(stmt.name, running index)   (§3.4)
      placement.span   = stmt.span, with expansion index k recorded
```

All arithmetic in `real64`, same operation order as written above, so
two runs are byte-identical (P04 determinism invariant). Each placement
keeps its body's source span *plus* its expansion index — an error or a
`--explain` line can always say `wall#37 (from line 5, repeat step 37)`.

### 4.2 `grid` / `line` / `ring` are rewrites, then §4.1

- `grid nx ny nz … spacing s at a` →
  `repeat (nx*ny*nz)` over the body where iteration (i,j,l) — enumerated
  x-fastest, then z, then y — has `step` replaced by the explicit offset
  `(i*sx, l*sy, j*sz)`. (Implemented as a direct offset table, not nested
  repeats, so the §3.6 nesting-depth rule is not consumed by sugar.)
- `line N … from A to B` → `repeat N` with `step = (B-A)/(N-1)`, base
  `at = A` (N=1 → placement at A, `step` unused).
- `ring N … centre C radius r facing f` → `repeat N` with per-iteration
  offset `(r·sin θk, 0, r·cos θk)`, `θk = 2πk/N`, and per-iteration
  Y-rotation `θk` in degrees if `facing out`, `θk+180` if `centre`,
  none if `none`. θ computed in `real64` from `PI` in `math_3d.f90`'s
  convention; placement 1 sits at `C + (0,0,r)` (angle 0 = +Z) — stated
  here so goldens never drift on an implementer's guess.

### 4.3 What expansion does *not* do

- It does not merge, cull, sort, or dedup geometry — those are P07
  passes / backend lowerings over the expanded IR (§5–§7). Desugar's
  only judgements are the §8 caps.
- It does not evaluate visibility. 100 cubes behind the camera expand to
  100 placements; removing them is a *hint/lowering* decision (P07 §4.3),
  never a desugar deletion, because exports must still contain them.
- Group references (§3.4) survive expansion as IR metadata even though
  the placement list is flat — flattening geometry must not flatten away
  the user's ability to say `spin wall`.

---

## 5. IR representation

### 5.1 Prototype table (addition to P04 §5.2)

```python
@dataclass(frozen=True)
class IRPrototype:
    key: str                    # hash of (kind, geometry props, base colour)
    kind: PrimKind              # cube | sphere | … | mesh ref
    tris: list[Tri]             # indexed, deduped (P04 O2) — stored ONCE
    verts: list[Vec3]
    tri_count: int
    bounds: Bounds              # local-space sphere + AABB (P07 §2 schema)

@dataclass(frozen=True)
class IRObject:                 # = one placement (P04's IRObject, extended)
    name: str; span: Span
    prototype: str              # → IRPrototype.key
    model: Mat4                 # baked TRS, as P04 §5.2
    color_override: Color | None   # None = prototype's per-face palette
    group: str | None           # helper/family name for §3.4 targeting
    expansion_index: int | None # k from §4.1; None for plain statements
```

`IRScene` gains `prototypes: list[IRPrototype]` alongside `objects`.
Prototype key includes base colour in v1 because colour currently lives
per-triangle (`Triangle%color`, `mesh.f90`) — splitting colour out of
the prototype (one geometry, many palettes) is the cleaner v2 shape and
is recorded as an open question (§11), not silently assumed. Even with
colour in the key, the canonical cases win fully: `repeat 100` of one
statement = 1 prototype; a `fade` helper = N prototypes of 12 tris each
in the worst case — which is exactly why §3.2 limits `fade` and why
§9 steers colour-varied crowds to the JS backend's per-instance colour
(§7.2) once the v2 key split lands.

### 5.2 Invariants the verifier checks (extending P07 §2)

1. Every `IRObject.prototype` resolves; Σ placements' `tri_count`
   (via prototype) equals the reported scene triangle count.
2. Every placement matrix is finite; a zero/negative-determinant matrix
   follows P07 §4.2's mirroring rule (winding flip or refuse to bake).
3. Group references resolve to ≥ 1 placement; `#k` references resolve
   to exactly 1 and `k` is within the family's expansion count.
4. Colour overrides are the *only* per-placement material variation in
   v1. A helper body that would vary geometry per iteration (there is
   no syntax for it — §3.6) is unrepresentable by construction.
5. Counts satisfy §8 caps. The verifier, not desugar alone, owns this —
   hand-written (non-helper) scenes with 10,001 plain lines must fail
   identically.

### 5.3 Animation binding

An `animate`/`spin` statement targeting a group compiles to **one**
animation record with a group target, not N records — file size and
error reporting stay O(1) in the helper. Evaluation (both backends):
per frame, per placement, `final = placement.model × motion(t + phase_k)`
where `phase_k` is 0 unless the helper's vary clauses set it (v1: no
phase clause; all placements move in sync — stated, not implied).
Spin/pulse centre = the placement's own origin (§0). This matches the
Fortran lowering trivially: the per-frame matrix replaces `model_i` in
the same render call (§6.2).

---

## 6. Fortran backend — expanded triangles vs shared mesh

### 6.1 The two candidate lowerings

**A. Expanded soup.** Bake every placement's matrix into vertices, merge
all placements into one giant `Mesh`, one `framebuffer_render_mesh` call.

**B. Shared mesh, per-placement call (instancing, Fortran-style).**
Build each prototype's `Mesh` once (`create_cube`, …), then per
placement compose `model_i` and call `framebuffer_render_mesh` once.
There is no GPU and no instanced-draw API in a CPU rasterizer — but
there doesn't need to be: the *savings* of instancing here are memory
and setup, and B captures both. The per-triangle work is identical in
A and B (the rasterizer touches every triangle of every placement
either way); anyone claiming B "renders faster" beyond setup is wrong,
and the manual must not claim it.

### 6.2 Comparison (100 red cubes, size 1 — the running example)

| | A. Expanded soup | B. Shared mesh (default) |
|---|---|---|
| Geometry memory | 100 × 12 tris × ~112 B/`Triangle`¹ ≈ **134 KB**, growing linearly forever | 12 tris ≈ **1.3 KB** + 100 × `mat4` (128 B) ≈ **14 KB total** |
| `create_cube` calls | 1 (then 1,200 vertex transforms at build time) | 1 |
| Render calls | 1 | 100 (each recomputes `model_view`/`mvp`: 2 `mat4_mult` ≈ 128 mults — noise vs rasterization) |
| Per-tri render cost | Identical: transform 3 verts, recompute face normal, Lambert, screen-space cull, bbox raster scan (`renderer.f90`) | Identical |
| Static culling / merge interplay | Already merged; P07 merge pass has nothing to do; frustum culling can only drop whole-soup or nothing without re-splitting | Per-placement bounds test can skip a call (§6.3); P07 merge remains available as an alternative lowering |
| `scene.json` v1 / OBJ export | Natural: the soup *is* the export | Compiler must expand **at export time only** (§6.4) — exports get A, rendering gets B |
| Code shape | One `Mesh`, mirrors today's `main.f90` most closely | A loop — the generated Fortran is ~10 lines longer (§6.5) |

¹ `Triangle` = 3×`vec3`(24 B) + `normal`(24 B) + `color(3)` int (12 B)
≈ 108 B, padded ≈ 112 B. `mat4` = 16 × `real64` = 128 B. Estimates from
the type definitions in `mesh.f90`/`math_3d.f90`; treat as ±10%.

**Ruling: B is the default lowering; A is produced only** (a) at export
boundaries that require soup (§6.4), and (b) when §6.3's merge rule
fires. Generated code must never hold both the soup and the prototypes
for the same scene (the memory row above is the reason).

### 6.3 When merging beats looping — the hybrid rule

Per-placement calls have one real weakness: fixed per-call setup and,
more importantly, no per-triangle early-out across placements. P07
§4.6 static merge has the opposite profile. Lowering choice, per
prototype group, decided in optimize and reported by `--stats`:

| Condition | Lowering |
|---|---|
| Prototype placed once | Direct single call (B with N=1; no loop emitted) |
| Any placement animated/dynamic, or group targeted by animation | **B** (merge would freeze the motion — P07 §4.6 forbids merging animated objects) |
| All placements static, total group tris ≤ 4,800 (≈ 400 cubes), single camera, no per-placement export | **A via P07 merge** is *permitted* (one call, simplest code) — but B is equally correct; default stays B for uniformity unless `--opt-level=O2` |
| All static, group tris > 4,800 | **B + per-placement frustum skip**: generated code tests the placement's world bounding sphere against the camera frustum before the call and `cycle`s on fully-outside. This is a *lowering* of P07 §4.3's hint, re-checked at run time in the generated code — sound even if the camera statement changes, because the test is in the emitted program, not baked into geometry. Expected win is scene-dependent (a 10×10 ground grid viewed from inside it culls ~⅓–½ of placements; a wall facing the camera culls ~none) — report culled counts in the run output, promise nothing |

Backface culling needs no per-backend work: `renderer.f90` already
culls per triangle after projection (signed-area `<= 0` → `cycle`),
for every placement, in both lowerings. Note its cost honestly: culling
happens *after* full vertex transformation, so a back-facing placement
still costs its transforms — one more reason the §9 budgets count
*submitted* triangles, not visible ones.

### 6.4 Exports from a multi-object scene

- `export obj` / `export json` (v1 dialect) operate on the **expanded,
  world-space** scene (A), generated at export time from IR — matching
  P04 §6.2's v1 rule ("transforms baked into vertices") and P07 C2
  (exports byte-stable across opt levels: expansion order = IR placement
  order = §4 expansion order, so bytes are deterministic).
- Export triangle order groups by prototype, then expansion index —
  *not* by authored statement order interleaved — and the header/`--explain`
  says so, because a user diffing `model.obj` against their source will
  otherwise think objects moved. (Scene *rendering* is order-independent
  thanks to the Z-buffer; only the file cares.)
- A scene that is legal to render may be expensive to export: v1 JSON
  for 120,000 tris is ~18 MB of text (§7.4 math). Export above the
  §8 soft cap warns and requires `--force` — rendering it does not.

### 6.5 Generated Fortran shape (informative, mirrors P04 §6.1)

```fortran
! generated by f3dc — structure mirrors src/main.f90 steps 1–8
call create_cube(proto_cube, 1.0_dp)          ! once per prototype
! … camera_init, light, framebuffer_init as today …
do i = 1, n_placements
  model_matrix = placement_model(i)           ! baked Mat4 table, or T*R*S composed
  if (frustum_skip(i)) cycle                  ! only when §6.3 row 4 applies
  call framebuffer_render_mesh(fb, proto_of(i), model_matrix, cam, light_dir)
end do
call framebuffer_save_ppm(fb, output_file)
! exports, if requested, expand from the same tables (§6.4)
```

`placement_model` / `proto_of` are generated tables (literal `mat4`
components or TRS triples composed with the existing
`mat4_translation/rotate_*/scale/mult`), never a new runtime type —
§5.3 of P04 ("no new Fortran types for v1") still holds. Animation
replaces the table lookup with a per-frame composition (§5.3); the
loop shape is unchanged.

---

## 7. JS backend — instancing vs expanded triangles

### 7.1 The constraint P06 already set

The JS runtime (P06) is WebGL1, one VBO set per mesh, `STATIC_DRAW`,
one draw per mesh, flat arrays in v2 JSON, ≤ 15 KB runtime budget, and a
Canvas 2D painter's fallback. WebGL1 core has **no instanced drawing**;
`ANGLE_instanced_arrays` (`vertexAttribDivisor` /
`drawArraysInstancedANGLE`) is an extension — widely available on
desktop, historically spotty on older mobile Safari/Android. Any design
that *requires* it breaks P06's "widest reach, one code path" ruling.

### 7.2 The three lowerings

| | J1. Expanded geometry | J2. Pseudo-instancing (default) | J3. True instancing (opportunistic) |
|---|---|---|---|
| Scene data | Every placement's vertices baked in; one big mesh | Prototype buffers once + per-placement `model` (16 floats) list | J2's data + matrices repacked as an instanced attribute buffer |
| Draws | 1 per prototype-group | **1 per placement** (same VBOs, reset `mvp`/`nm` uniforms between draws) | 1 per prototype-group |
| GPU memory (100 cubes) | 100 × 36 verts × (pos+norm+col) ≈ 100 × 36 × 36 B ≈ **130 KB** | 36 verts ≈ **1.3 KB** + 100 matrices (6.4 KB, CPU-side) | J2 + 6.4 KB GPU attribute buffer |
| Cost driver | Vertex processing of duplicated geometry; JSON size (§7.4) | Draw-call count: ~100 draws is nothing; ~10,000 draws at 60 fps is the classic WebGL1 death (CPU-bound, ~1–3 µs/draw call overhead in JS + driver) | Attribute fetch per instance; cheapest at scale |
| Runtime code cost | Zero new code (it *is* P06 v2 today) | ~15 lines: loop placements, compose/upload uniforms, draw | +~40 lines: extension detection, divisor setup, matrix attribute plumbing, fallback branch — charged against P06's §10 budget headroom (3.1 KB), needs its own ruling (§11) |
| Canvas 2D fallback | Painter over all tris | Identical triangle set after CPU transform (§7.5) | Must degrade to J2/J1 — extension absence and 2D fallback are the same code path |

**Ruling: emit J2 by default.** Promote a prototype group to J3 at
*load time* (not compile time — capability is a property of the
visitor's browser, not the author's scene) when the extension exists
**and** the group has ≥ 64 placements (below that, draw calls are not
the bottleneck and the simpler path wins). J1 is emitted only for the
v1 JSON dialect (§7.4) and for groups of 1 placement (where J1 ≡ J2).

This mirrors the Fortran ruling (§6.2) on purpose: **both backends keep
the prototype factored and pay per placement at draw time; expansion
exists only at legacy-format boundaries.** One mental model for the
whole compiler, stated once in the manual.

### 7.3 v2 scene format delta (additive, per P06 §4.2)

```json
{ "f3d": 2,
  "meshes": [
    { "name": "cube", "positions": […], "indices": […], "colors": […],
      "instances": [ { "t": [16 column-major floats],
                       "c": [r,g,b] } ] } ] }
```

- `instances` absent or length 1 with no `t` ≡ today's v2 mesh
  (backwards compatible by construction). `c` is the optional
  per-placement colour override (§5.1), 0..1 floats per P06 rule 3.
- **Caveat to P06 rule 5** ("unknown keys are ignored"): an old runtime
  ignoring `instances` would render *one* cube instead of 100 —
  silently wrong, the exact failure P03 rule 8 forbids on the DSL side.
  Therefore: a mesh using `instances` with length > 1 must also carry
  `"requires": "instances"` in `meta`, and the runtime's loader (next
  revision) must throw `F3D: scene requires instances` rather than
  render a partial scene. Until that runtime revision ships, the
  compiler emits J1-expanded v2 for any scene with a multi-placement
  group — correctness over size, with the §7.4 warning shown.
- Matrices are emitted at ≤ 6 significant digits (P06 §4.3). 100
  placements ≈ 100 × 16 × ~8 chars ≈ 13 KB of JSON — vs ~180 KB for
  the same scene as v1 triangle soup (§7.4). Still text; a binary
  sidecar remains a v3 discussion (P06 §13), now with a concrete
  trigger: scenes whose v2 JSON exceeds ~1 MB should be the first
  candidates.

### 7.4 Legacy v1 JSON — the expansion tax, in numbers

v1 (`scene.json` today) is per-triangle objects with `F8.3`-style
coordinates: measured on the repo's current file, ≈ **150 B per
triangle** (12 tris ≈ 1.8 KB). Hence:

| Scene | Tris | v1 JSON | v2 instanced (J2/J3) |
|---|---|---|---|
| 1 cube | 12 | ~1.8 KB | ~1.8 KB |
| `repeat 100` cubes | 1,200 | ~180 KB | ~15 KB |
| `grid 32 32` cubes | 12,288 | ~1.8 MB | ~135 KB |
| 10,000 cubes (scene cap) | 120,000 | **~18 MB** | ~1.3 MB |

Consequences, all enforced in §8: v1 emit warns at 20,000 tris
(~3 MB) and errors at the 1,000,000-tri scene cap unless the user
explicitly splits output; the HTML target (P04 §6.4) must not *inline*
a v1-expanded scene above the warning threshold (a 3 MB inline script
is a hung page, not a viewer); `model.obj` expansion is cheaper per tri
(~30 B/tri in `v`/`f` lines) but follows the same warning rule.

### 7.5 Canvas 2D fallback with placements

Painter's algorithm (P06 §9) sorts **triangles by mean depth** — with
placements, the sort key set is the union over all placements after
their model transforms, i.e. the fallback internally expands to a
triangle list (J1 on the CPU) regardless of the WebGL lowering. Rules:
sort globally, never per-prototype (per-prototype sorting is visibly
wrong for interleaved placements — two overlapping rows of cubes are
the minimal counterexample, and a required test fixture, §10);
the existing > 20k-tri wireframe guard now counts *expanded* tris;
per-placement colour overrides apply before shading, identically to
the WebGL path, so fallback and WebGL stills match within rounding
(P06 acceptance criterion 2, extended to a multi-placement fixture).

---

## 8. Limits — hard caps, soft warnings, and the arithmetic

### 8.1 The cap table (single source; error codes extend P04 §4.3/§7)

| Limit | Value | Kind | Diagnostic |
|---|---|---|---|
| `repeat` count, per statement | 1,000 | hard | `E401` (existing, P04) |
| `grid` dimensions product, per statement | 1,000 | hard | `E401` with the product spelled out: `grid 100 100 = 10,000 placements > 1,000 per helper` |
| Helper nesting depth | 2 | hard | `E402` |
| **Total placements, per scene** | **10,000** | hard | `E403`: lists each helper's contribution, e.g. `repeat 100 (line 5) × grid 10×10 (line 6) = 10,000 … scene total 12,400 > 10,000` |
| **Total triangles, per scene** (Σ placements × prototype tris) | **1,000,000** | hard | `E404` (aligns with P07 §4.6 merge cap) |
| Total triangles | > 25,000 (Fortran target) / > 100,000 (JS target) | soft | `W510` performance warning with §9 zone + the two cheapest fixes (reduce count, raise prototype size/spacing, split scene) |
| v1 JSON / OBJ expanded emit | > 20,000 tris | soft→hard at cap | `W511` warning; `--force` required above 200,000 tris |
| Coincident placements (`step 0 0 0`, or duplicate `at`) | any exact duplicate (same prototype, same matrix) | soft | `W512`: `37 placements occupy the exact position of wall#1 — did you mean step …?` (Z-fighting + wasted rasterization; never an error — stacking is sometimes intentional) |
| Placements fully outside far plane / frustum (static camera estimate) | > 50% of placements | soft | `W513` (P04 `W501`, generalized per group): suggests checking `at`/`spacing` signs — the classic grid-grows-away-from-camera mistake |
| Per-prototype triangle count | > 50,000 (e.g. an imported mesh repeated) | soft | `W514`: repetition multiplies it; shows the product before the user discovers it in the render time |

Why a *scene* cap in addition to P04's per-`repeat` cap: caps compose
multiplicatively in the user's blind spot. `repeat 100 { grid 10 10 {
cube } }` is two legal statements and 10,000 cubes / 120,000 tris;
`grid 100 100 100` is one legal-looking statement and 1,000,000 cubes.
A compiler whose promise is "easy" must do this multiplication for the
user, at compile time, in the error message — §8.1's `E403`/`E401`
messages are specified to show the product for exactly this reason.

### 8.2 Validation order (so the *first* error is the useful one)

1. Per-helper caps (`E401`, `E402`) during desugar, in source order.
2. Scene totals (`E403`, `E404`) in the verifier, after full expansion.
3. Soft warnings (`W510`–`W514`) after optimization stats exist
   (P04 `--stats` gains: `prototypes, placements, placements_per_prototype
   (max), tris_submitted, tris_after_static_cull_estimate, lowering
   per group (B/A/J1/J2/J3)`).
4. `--strict` (P04 §10) promotes `W510`–`W514` to errors, unchanged.

### 8.3 What is *not* capped, deliberately

Distinct prototypes (a scene of 500 *different* objects is a authoring
problem, not a blow-up risk — its cost is linear and visible in the
source); scene file *lines*; group/target references. Each uncapped
dimension is still *counted* in `--stats`.

---

## 9. Performance guidance (the numbers the manual publishes)

All figures are guidance zones derived from the algorithms in
`renderer.f90` / P06, **not benchmarks** — the first implementation
must replace the Fortran column with measured medians on the reference
hardware (owner-class Ryzen iGPU machine, CPU rasterizer) using P07
C11's method (≥ 15 runs, `-O3` per `Makefile`), and this section's
thresholds are the values to confirm or adjust at that point.

### 9.1 Why the Fortran rasterizer's cost is what it is

Per submitted triangle, `framebuffer_render_mesh` pays: 6
`mat4_transform_vec3` (3 world + 3 MVP), one cross/dot normal, then —
if it survives the screen-space cull (~½ of a closed mesh's tris,
view-dependent) — `draw_triangle` scans the triangle's **screen
bounding box** pixel by pixel with barycentric tests. Consequences a
beginner can use:

- **Cost ∝ submitted triangles × average on-screen size.** 100 large
  cubes can cost more than 1,000 distant ones. Triangle count alone
  is the budget unit only because it's the one the compiler can count
  statically; the manual must say so.
- **Overdraw is invisible waste:** coincident/stacked placements
  (§8 `W512`) rasterize fully and lose the Z-test at the last pixel.
- **Resolution multiplies fill cost:** the same scene at 1280×960
  costs ~4× the fill of 640×480. Halving image size is the fastest
  legitimate "make it quicker" knob and the manual should offer it
  before suggesting fewer objects.

### 9.2 Budget zones

| Zone | Fortran (software, 640×480) | JS WebGL (J2/J3) | JS Canvas 2D fallback |
|---|---|---|---|
| **Green** — interactive-feeling / seconds | ≤ 25k submitted tris (≈ 2,000 cubes) **and** ≤ 2,500 placements | ≤ 100k tris (P06 target) and ≤ 2,500 draws (J2) — J3 lifts the draw limit ~10× | ≤ 5k tris (P06 §9 target: 30 fps at 5k) |
| **Amber** — works, wait is noticeable; `W510` fires | 25k–100k tris (≈ 8,000 cubes) | 100k–500k tris, or 2,500–10,000 draws (J2) | 5k–20k tris |
| **Red** — minutes (Fortran) / jank or hang risk; `W510` + explicit advice | > 100k tris | > 500k tris or > 10,000 draws without J3 | > 20k tris → runtime already degrades to wireframe (P06 §9) |

Worked examples for the manual (cubes = 12 tris):

| User's line | Placements / tris | Verdict |
|---|---|---|
| `repeat 100 cube … step …` | 100 / 1,200 | Green everywhere. The headline example: trivial on every backend, ~15 KB v2 JSON. Teach this one. |
| `grid 10 10 cube …` | 100 / 1,200 | Same as above — grids feel bigger than they are. |
| `grid 50 50 cube …` (a "city") | 2,500 / 30,000 | Fortran amber (expect a noticeable render, not a hang); JS green/amber by draws; 2D fallback red → wireframe notice. The manual's "big scene" example, with the frustum-skip note (§6.3). |
| `repeat 1000` of a 500-tri imported mesh | 1,000 / 500,000 | Fortran red, JS amber, v1 export ~75 MB → refused without `--force`/split (§8). `W514` fires at compile time with this exact product — the user learns *before* rendering. |
| `grid 100 100 100 cube` | 1,000,000 / 12,000,000 | **Compile error** (`E401`/`E403`/`E404` all trip; first reported wins). The error suggests `grid 20 20 20` (8,000 / 96k, amber) as the nearest legal scene — errors teach the scale. |

### 9.3 Guidance rules (manual chapter, in this order)

1. **Reuse beats reduce:** if you're writing the same shape twice, it's
   already one prototype (§2) — repetition of a prototype is ~free in
   memory and file size; only *rasterization* scales with placements.
2. **Count triangles, not objects:** a scene of 10 spheres can out-cost
   1,000 cubes once sphere tessellation lands (a 500-tri sphere × 10
   = 5k vs 12 × 1,000 = 12k — comparable!). `--stats` prints both counts;
   trust the triangle number.
3. **Spread out or step back:** frustum skip (§6.3) and JS frustum
   behaviour only help placements the camera can't see; a grid the
   camera *inside* of gets culled least. Wide spacing + a camera that
   sees a fraction of the scene is the cheap large-world pattern.
4. **Animate groups, not counts:** animating 2,500 placements costs the
   same per frame as rendering them once, *every frame* — on the Fortran
   side that means an animation multiplies §9.2's wait by the frame
   count (P03 §7: 150 frames default). `render still` + a big scene is
   a fine combination; animation + a red-zone scene is 150 red zones.
5. **Export is a separate budget** (§6.4/§7.4): a scene can be green to
   render and red to export as v1. Prefer v2/HTML targets at scale.

---

## 10. Acceptance criteria (for the build that follows this plan)

1. **Golden identity:** a scene written as 100 plain `cube` lines and
   the same scene as `repeat 100 … step …` produce byte-identical IR
   (modulo spans), byte-identical v1 exports, and pixel-identical PPMs.
2. **Headline case:** `repeat 100 cube red size 1 at 0 0 0 step 2.5 0 0`
   + default camera framing guidance — compiles with no warning,
   renders on both backends, v2 JSON ≤ 20 KB, Fortran geometry memory
   is the §6.2 B-row (one prototype mesh in the generated code —
   asserted by inspecting the emitted `.f90`, not by trust).
3. **Cap arithmetic:** fixtures for every §8.1 row, including the
   nested `repeat { grid }` product case and `grid 100 100 100`,
   asserting code, message text (with the product shown), and span.
4. **Pronoun semantics:** `repeat …` + `spin it` rotates **all**
   placements (PPM differs from the un-animated render across the whole
   row, not one cube); `wall#37` targeting moves exactly one placement
   (pixel-diff mask touches only its screen region).
5. **Occlusion correctness:** two overlapping rows of cubes (the §7.5
   counterexample) render identically (within rounding) in Fortran PPM,
   JS WebGL, and JS 2D fallback stills — catches per-prototype sorting
   and any Z-buffer regression across render calls.
6. **Frustum skip soundness:** with §6.3 row 4 active, PPM is
   pixel-identical to the no-skip render on ≥ 3 multi-object fixtures
   including a camera-inside-the-grid case (P07 C7-style property:
   no skipped placement would have produced a pixel).
7. **Determinism:** two builds of a `grid` + `ring` + `fade` scene →
   identical hashes on all targets (P04 §11.5), including placement
   naming and export ordering (§6.4).
8. **Legacy safety:** the repo's current 12-tri `scene.json` still
   loads in the unmodified current viewer (P04 §11.3); a multi-placement
   scene emitted as v1 loads and shows **all** placements.
9. **Stats truth:** `--stats` counts on the §9.2 fixtures match
   hand-computed placements/tris exactly; `W510` fires on the amber
   fixtures and not on the green ones.
10. **Old-runtime guard:** a v2 scene with `requires: "instances"`
    (§7.3) opened in a runtime without instance support produces the
    specified error, not a one-cube render.

---

## 11. Risks & open questions (need owner ruling before build)

1. **Is `repeat` in v1 at all?** P03 §11 defers loops; P04 §2 assumes
   `repeat`. This plan's position: `repeat`/`grid` are *pattern
   statements*, not loops (no variable, no condition, fixed literal
   count) and belong in v1 because "many objects" is the first thing a
   beginner wants after one cube. If the owner rules otherwise, §3
   ships in v1.1 and §§5–9 are unchanged — but the ruling should be
   explicit, since P03 and P04 currently disagree by implication.
2. **Colour in the prototype key (§5.1).** Splitting colour from
   geometry (one prototype, per-placement palette) makes `fade` and
   colour-varied crowds cheap on both backends and is the natural v2
   IR move — but it touches P04's IR freeze (`ir_version: 1`) and
   P10's per-triangle colour lowering. Decide before the IR freezes,
   or accept N-prototypes-for-N-colours in v1 (documented in §5.1).
3. **J3 true instancing vs the 15 KB JS budget (P06 §10).** J3's ~40
   lines + extension plumbing must be charged against P06's headroom
   and re-measured in its CI size gate; if it doesn't fit, J3 becomes
   an add-on file (`f3d-instanced.js`, per P06 §1.2's add-on rule) and
   §7.2's promotion rule loads it opportunistically. Either way J2
   remains the default and the fallback.
4. **Sphere/other primitives change every number in §9.** All budgets
   are stated in triangles precisely so they survive new primitives,
   but the *worked examples* assume the cube (the only constructor in
   `mesh.f90` today). When `create_sphere` lands, its default
   tessellation must be published next to these tables — a "sphere"
   that silently costs 2,000 tris breaks `W514`'s usefulness.
5. **Frustum skip in generated Fortran (§6.3)** writes a culling test
   into *generated* code using `math_3d` primitives; if the runtime
   later grows a real `framebuffer_render_scene` / culling API, the
   generated code should switch to it and §6.3's rule table becomes a
   renderer concern. Flagged so nobody builds both permanently.
6. **Inter-placement transparency sorting** (if P10's transparent pass
   lands) interacts with placements exactly as §7.5's painter issue:
   sorting must be global across placements. P10 §4 already sorts
   per-triangle at scene level — this plan requires that property to
   be preserved when its implementation meets multi-object scenes.

---

*End of P16. Companion ownership: DSL surface conflicts (§11.1) belong
to the core grammar plan (P03/P04 reconciliation); IR freeze and the
prototype-key question (§11.2) to P04; JS runtime budget and the
`requires` loader guard (§§7.3, 11.3) to P06; merge/cull hint
soundness (§6.3) to P07; per-triangle colour lowering (§5.1) to P10.*
