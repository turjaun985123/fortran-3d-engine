# P04 — Compiler Pipeline Design: `parse → validate → optimize → emit`

> **Status:** Planning only — no `src/` changes in this document.
> **Repo baseline (verified 2026-11-23):** `src/math_3d.f90` (`math_3d`: `vec3`, `mat4`),
> `src/mesh.f90` (`mesh_3d`: `Triangle`, `Mesh`, `create_cube`, `export_mesh_json/obj`),
> `src/camera.f90` (`camera_3d`: `Camera`), `src/renderer.f90` (`renderer_3d`: `FrameBuffer`,
> Z-buffer, Lambertian rasterizer, PPM P3 export), `src/main.f90` (hard-coded 640×480 cube demo).
> Build: `Makefile`, `gfortran -O3 -Wall -Wextra -fcheck=all -Jinclude`, target `bin/engine3d`.
> Interchange today: `scene.json` = `{triangles:[{id, v:[[x,y,z]×3], color:[r,g,b]}]}`,
> `model.obj`, `output_render.ppm`; consumer: `viewer.html` (Canvas 2D, painter's algorithm,
> loads `scene.json`, decodes P3 PPM). No parser, no scene language, no CLI flags exist yet.
>
> **Product goal:** an *easy* 3D compiler that beats Three.js / PixiJS **on ease**, not on
> feature count: one small declarative file in, a runnable Fortran render + a self-contained
> web viewer out, with defaults for everything Three.js makes you wire by hand
> (scene / camera / renderer / light / loop / resize).

---

## 1. Principle and Non-Goals

| Principle | Consequence for the pipeline |
|---|---|
| One file, zero boilerplate | A 6-line source must compile to a complete scene (§2). Camera, light, background, output size all have defaults injected in *validate/desugar*, never required in source. |
| Errors a beginner can act on | Every diagnostic carries `file:line:col`, the offending token, a plain-language cause, and a *did-you-mean / fix* hint. No Fortran compiler errors leak to the user for source-language mistakes. |
| Fortran is the runtime, not the authoring surface | Users never write Fortran. The compiler *emits* Fortran that links the existing 4 modules unchanged in spirit; `gfortran` is an implementation detail invoked (or not) by `f3dc`. |
| Deterministic, diffable output | Emitted JSON/JS/Fortran is sorted, fixed-precision, header-stamped with source hash. Same input → byte-identical output (except HTML timestamp, opt-in). |
| Pipeline is inspectable | Every stage can be dumped: `--emit tokens|ast|ir|opt-ir`. This is the debugging story and the test story. |

**Non-goals (v1):** no general-purpose scripting / Turing-complete language, no shader language,
no skeletal animation system, no physics, no network/asset fetching at compile time.
Expressions are arithmetic only (§3.3).

---

## 2. Source Language at a Glance (input to the pipeline)

Working name: **F3D**, extension `.f3d`. The grammar itself is owned by the language plan;
this plan only fixes what the pipeline must accept.

```f3d
# hello-cube.f3d — the entire program
scene "Hello" {
  size 640x480
  camera at (3, 2.5, 4) look (0, 0, 0) fov 60
  light dir (-0.5, -1, -0.7)
  cube "hero" size 2 at (0, 0, 0) rotate (20, 35, 0) color #DC3C3C
}
```

Equivalent Three.js is ~40 lines of imperative JS across 5 object types. Here: 1 block,
5 statements, every other value defaulted. Primitives in v1 map 1-to-1 onto what the Fortran
runtime can already rasterize or can trivially gain: `cube` (exists: `create_cube`),
plus planned `plane`, `tri` (raw triangle, escape hatch), `mesh "file.obj"` (import),
`group { … }` (transform nesting), `repeat n { … }` (compile-time unroll, §6).

Two alternate front doors feed the *same* pipeline after lexing (§4.1):
(a) `scene.json` in the current legacy shape — auto-detected, upgraded by a compatibility
reader so existing files and `viewer.html` keep working; (b) Wavefront `.obj` import as a
mesh-only scene. Neither gets its own pipeline.

---

## 3. Pipeline Overview

```
 .f3d ──▶ [1 LEX] ──▶ [2 PARSE] ──▶ [3 VALIDATE] ──▶ [4 OPTIMIZE] ──▶ [5 EMIT] ──▶ targets
           tokens      AST           Typed IR          Optimized IR     ├─ Fortran scene (.f90) ─▶ gfortran ─▶ PPM
                                                                          ├─ JSON (scene.json v2 + legacy v1)
 .json ──▶ compat reader ────────────────┘                                ├─ JS   (scene.js / ES module)
 .obj  ──▶ obj reader ───────────────────┘                                └─ HTML (single-file viewer)
                    ▲ diagnostics (all stages, unified)        ▲
                    └──────────── source map (node → span) ────┘
```

### 3.1 Stage contracts

| # | Stage | Input → Output | Pure? | Failure mode |
|---|---|---|---|---|
| 1 | Lex | `str` (UTF-8) → `list[Token]` + comments stripped | Yes | `E1xx` lexical error, abort |
| 2 | Parse | tokens → `AST` (`SceneNode` tree, spans preserved) | Yes | `E2xx` syntax error, recover at next statement (§7) |
| 3a | Desugar | AST → AST′ (defaults, `repeat` unroll, color/unit normalization) | Yes | — |
| 3b | Validate | AST′ → **Typed IR** or diagnostic list | Yes | `E3xx` semantic, `E4xx` range/type; collect *all*, then abort if any error |
| 4 | Optimize | Typed IR → Optimized IR + stats | Yes | Never fails; warnings `W5xx` only |
| 5 | Emit | Optimized IR → one file per `--target` | Yes (per target) | `E6xx` I/O / unsupported-for-target |
| 6 | Drive (optional) | Fortran target → `make`/`gfortran` → `bin/engine3d` → run | No (subprocess) | Surface stderr verbatim, exit ≠ 0 |

Stages 1–5 are a library (`f3dc_core`), stage 6 and all I/O live in the CLI driver.
No stage mutates its input; each returns a new value — this is what makes `--emit ast|ir`
dumps, golden tests, and future LSP reuse trivial.

### 3.2 Global invariants

1. **Span everywhere:** every token, AST node, and IR node carries `Span{file, line, col, end_line, end_col}`. Optimizers must preserve the span of the surviving node.
2. **One diagnostic type** (§7) from every stage; warnings never block emit, errors always do.
3. **Units are resolved once**, in desugar: angles → degrees in AST (source may write `35deg` / `0.61rad`), colors → `(r,g,b) int[0,255]`, lengths → `float` world units. Downstream never re-interprets units. (Fortran side converts deg→rad itself, cf. `camera_init` / `mat4_rotate_*` taking radians after `* PI/180` in `main.f90`.)
4. **IR is the only thing emitters see.** No emitter re-reads the AST or source text.

---

## 4. Stage Designs

### 4.1 Lexer

- Token kinds: `IDENT, NUMBER (int|float), STRING, COLOR (#RRGGBB), KEYWORD, LPAREN/RPAREN, LBRACE/RBRACE, COMMA, EQ, SIZE (640x480 as one lexeme only in `size` position — simpler: lex as `NUMBER 'x' NUMBER` and let parser join; **decision: parser joins**, lexer stays context-free), NEWLINE (significant as statement terminator, semicolon optional), EOF`.
- Keywords (reserved, case-insensitive, stored lower-cased): `scene size camera at look fov near far light dir ambient cube plane tri mesh group repeat color rotate scale background wireframe output`.
- Comments: `#` and `//` to end-of-line (both, because `scene.json`/shell users expect `#`, JS refugees expect `//`). No block comments in v1.
- Numbers: decimal int/float, optional leading `-` handled by parser (unary), no hex except in `COLOR`.
- Max file size guard (default 1 MiB source) and max token count — fail with `E101` rather than hang; "never hang the user" applies to the compiler too.

### 4.2 Parser

- Hand-written **recursive descent**, one function per production, no parser generator (rationale §8). Grammar is deliberately tiny (~25 productions).
- Produces the AST in §5.1; statements are order-insensitive inside a block *except* `group`/`repeat` nesting, which is structural.
- Error recovery: on `E2xx`, skip to next `NEWLINE`/`}` and continue, capping reported syntax errors at 10 — a beginner fixes the first, not the fiftieth.
- Duplicate singleton statements (`camera` twice in one scene) parse fine and are rejected in *validate* (`E301`) where a better message ("second camera at line 9; first at line 4") is possible.

### 4.3 Validate (desugar + semantic + typing)

Desugar first, in fixed order: (1) inject defaults — `size 640x480`, `camera at (3,2.5,4) look (0,0,0) fov 60 near 0.1 far 100`, `light dir (-0.5,-1,-0.7)`, `background (25,25,35)` (matches `framebuffer_clear(fb,25,25,35)` in `renderer.f90`), primitive defaults `at (0,0,0) rotate (0,0,0) scale 1 color white`; (2) expand `repeat` (cap 1 000 expansions, `E401` above); (3) flatten `group` transforms into each child's accumulated `mat4` *intent* (kept symbolic as TRS components in IR, composed numerically in optimize); (4) expand primitives to triangle soups *lazily* — keep `PrimKind` in IR, expansion happens in optimize/emit so counts and dedup stay visible.

Semantic checks (each = one error code, all collected):

| Code | Check |
|---|---|
| `E301/E302` | Duplicate / unknown top-level block; unknown statement or property (with did-you-mean over keyword table, edit distance ≤ 2) |
| `E310` | Unknown / duplicate object name; reference to undefined name |
| `E320–E329` | Type errors: expected vec3 / number / color / string, got X (span on the value) |
| `E330` | `fov ∉ (0,180)`, `near ≤ 0`, `far ≤ near`, `size` dimension ∉ [16, 4096], color channel ∉ [0,255] |
| `E340` | Degenerate triangle (area < 1e-12, mirrors `vec3_normalize` epsilon in `math_3d.f90`), zero-length light dir, camera `at == look` |
| `E350` | `mesh` file missing / not `.obj` / unparseable (delegates to obj reader, wraps its error) |
| `W501/W502` | Object fully outside far plane (static estimate); scene with 0 renderable triangles |

Output is the **Typed IR** (§5.2): fully defaulted, fully typed, no optional fields left ambiguous.

### 4.4 Optimize

All passes operate on triangle lists per object, are order-fixed, and report counts in `--stats`:

| Pass | What | Why / grounded limit |
|---|---|---|
| O1 Dead-object drop | Remove objects with 0 tris or `W501`-culled by static frustum test | Cheap; uses IR camera |
| O2 Vertex dedup + index build | Hash exact `vec3` → shared vertex table per object | Cube: 36 tri-verts → 8 verts; shrinks JSON/JS/OBJ emit; Fortran target re-expands (its `Mesh` is a triangle soup — `mesh.f90` has no index buffer) |
| O3 Degenerate / duplicate-tri removal | Drop zero-area and exact-duplicate triangles | Prevents wasted rasterizer work in `draw_triangle` |
| O4 Backface pre-cull (static only) | *Only* for closed, statically-transformed objects: drop tris whose world normal faces away from the fixed camera | Sound only because v1 scenes are static with one camera; disabled if any future animation flag is set. Runtime already culls in `renderer.f90`, so this is a size/speed win, never a correctness dependency |
| O5 Color palette extraction | Repeated `color` values → palette table | Smaller JSON/JS; Fortran emit inlines again (its `Triangle%color(3)` is per-tri) |
| O6 Transform bake | Compose group TRS chain into one `mat4` per object; if object is axis-aligned unit primitive, keep parametric form for Fortran emit (see §6.1) | One matrix per object matches `framebuffer_render_mesh(fb, mesh, model_matrix, cam, light_dir)`'s single-model-matrix signature |
| O7 Triangle sort hint | No reordering for Fortran (Z-buffer makes order irrelevant); for JS/HTML emit, pre-sort key = centroid depth desc | `viewer.html` uses painter's algorithm (no Z-buffer) — emit order is its correctness input |

Explicitly **not** in v1: mesh simplification/decimation, BVH, texture work — they change pixels and break the determinism invariant.

### 4.5 Emit — see §6 per target.

---

## 5. Data Structures

### 5.1 AST (parse tree, close to source)

```python
# Python dataclasses (see §8 for language choice); every node: span: Span
Scene(span, name: str|None, body: list[Stmt])
Stmt = SizeStmt(w,h) | CameraStmt(pos, target, fov, near, far)   # fields Optional — user omitted = None
     | LightStmt(dir, ambient) | BackgroundStmt(color)
     | ObjectStmt(kind: PrimKind|MeshRef, name, props: Props, span)
     | GroupStmt(props, body: list[Stmt]) | RepeatStmt(count, body)
Props(at, rotate, scale, color)   # each Optional[Vec3|float|Color]
Value = VecLit(x,y,z) | NumLit(float) | ColorLit(r,g,b) | StrLit(str) | IdentRef(name)
```

AST keeps *source fidelity* (omitted = `None`, units as written) so diagnostics and
`--emit ast` show what the user wrote. It is never optimized or emitted from directly.

### 5.2 IR (the contract between front end and back ends)

```python
@dataclass(frozen=True)
class IRScene:
    meta: Meta(name, source_hash, compiler_version, tri_count, vert_count)
    render: RenderCfg(width=640, height=480, background=(25,25,35), output="output_render.ppm")
    camera: IRCamera(pos: Vec3, target: Vec3, up=(0,1,0), fov_deg=60.0, aspect: float, near=0.1, far=100.0)
    lights: list[IRLight]            # v1: exactly 1 directional; list leaves room for ambient/point
    objects: list[IRObject]

@dataclass(frozen=True)
class IRObject:
    name: str; span: Span
    model: Mat4                      # baked TRS (row-major 4×4 floats, matches mat4%m(4,4) semantics)
    verts: list[Vec3]                # deduped (O2)
    tris: list[Tri]                  # Tri(a,b,c: int indices into verts, color: int palette index)
    palette: list[Color]             # per-scene in practice; per-object field keeps emitters stateless

Vec3 = tuple[float, float, float];  Color = tuple[int, int, int]  # 0..255
Mat4 = tuple[float, ...]  # 16 floats
```

Design notes: (a) IR mirrors the Fortran runtime's concepts 1-to-1 — `IRCamera` ≅ `Camera`
(`position/target/up/fov_deg/aspect_ratio/near_plane/far_plane`), `IRObject.tris` ≅ `Mesh.triangles`,
`RenderCfg.background` ≅ `framebuffer_clear` args — so the Fortran emitter is a transcription,
not a translation. (b) `frozen=True` + tuples: IR is hashable, safely shareable across the
four emitters, and snapshot-testable. (c) A versioned JSON serialization of IR
(`--emit ir` → `*.ir.json`, `ir_version: 1`) is the golden-test format and the future
language-server / other-frontend boundary.

### 5.3 Fortran-side structures (emitted code uses, does not modify, existing types)

No new Fortran types are required for v1. Emitted code constructs `Mesh` by allocating
`triangles(n)` and filling `v/color/normal` (via existing `compute_triangle_normal`), or calls
`create_cube` for the parametric fast path (§6.1). If a later version needs indexed meshes,
that is a `mesh.f90` change owned by the runtime plan, not this pipeline.

---

## 6. Emitters (one module per target, shared helpers)

Common: `emit_common.py` — number formatting (`%.3f` for JSON/OBJ parity with current
`export_mesh_json` `F8.3`; `%.6f` inside Fortran/JS where precision matters), color formatting,
header stamp (`! generated by f3dc <ver> from <file> sha256:<…> — do not edit`).

### 6.1 `--target fortran` → `scene_main.f90` (default name `<stem>_scene.f90`)

A drop-in replacement for the *demo content* of `main.f90`, using only existing public APIs:
`framebuffer_init/clear/render_mesh/save_ppm`, `camera_init`, `mat4_translation/scale/rotate_x/y/z/mult`,
`export_mesh_json/obj`. Shape:

```fortran
program scene_main          ! generated — structure mirrors src/main.f90 steps 1–8
  use math_3d; use mesh_3d; use camera_3d; use renderer_3d
  ! per object: if parametric cube → call create_cube(m, size)
  !             else → allocate triangles, fill v/color, compute_triangle_normal
  ! per object: model_matrix = T * Rz * Ry * Rx * S composed with mat4_mult
  ! camera_init(cam, eye, target, fov, aspect, near, far); light_dir = vec3_create(...)
  ! framebuffer_render_mesh(...) per object; framebuffer_save_ppm; export_mesh_json/obj
end program
```

Multi-object note: current `main.f90` renders one mesh; emitting one `render_mesh` call per
`IRObject` into the same `FrameBuffer` is valid (Z-buffer persists in `fb`) and needs **zero**
runtime changes — this is the key compatibility fact the design rests on.
`f3dc build` then compiles it *alongside* the 4 modules (never overwriting `src/main.f90`;
output goes to `build/`), reusing the Makefile's flags.

### 6.2 `--target json` → `scene.json`

Two dialects, one flag: `--json-dialect v2|v1|both` (default `both` while `viewer.html` is v1).
**v2** (native IR dump): `{ir_version, meta, render, camera, lights, palette, objects:[{name, model:[16], verts, tris:[{v:[a,b,c], c:paletteIdx}]}]}`.
**v1** (legacy compat): exactly today's shape — flat `{triangles:[{id, v:[[..]×3], color:[r,g,b]}]}`,
world transforms *baked into vertices* (v1 has no transform/camera fields), `id` from 1,
`F8.3`-style 3-decimal numbers. Guarantees current `viewer.html` loads v1 output unmodified.

### 6.3 `--target js` → `scene.js`

ES module: `export const SCENE = {…v2 JSON…}; export const TRIANGLES = [/* v1-flat, depth-sorted (O7) */];`
plus a tiny optional runtime (`--js-runtime`) exporting `mount(canvas, SCENE)` that replicates
`viewer.html`'s orbit/painter renderer (~120 lines) so `<canvas>` + 2 lines replaces a Three.js
setup. No dependencies, no bundler assumed.

### 6.4 `--target html` → `<stem>.html`

Single self-contained file: the `viewer.html` template (same dark theme, tabs, PPM tab retained)
with (a) the JS scene inlined instead of the hard-coded cube array, (b) `fetch('scene.json')`
made optional/fallback (inlined data is primary, so `file://` works — fixing today's CORS
fallback path), (c) title from `scene "name"`. Template lives as a *data file* in the compiler
package (`templates/viewer.html.tmpl` with `{{SCENE_JS}}` / `{{TITLE}}` / `{{TRI_COUNT}}`
placeholders) — string substitution only, no template engine dependency.

Emitter matrix: all four targets derive from the same Optimized IR in one run;
`--target all` is the default for `f3dc build`.

---

## 7. Diagnostics

```python
@dataclass
class Diagnostic:
    code: str            # E101..E6xx / W5xx — stable, documented, grep-able
    severity: Literal["error","warning"]
    span: Span; message: str; hint: str|None; related: list[Span]  # e.g. first definition
```

Rendered as `hello.f3d:4:14: error[E320]: expected color, got number '12' — hint: use #RRGGBB or (r,g,b)`.
`--format json` emits machine-readable diagnostics for editors/CI. Exit codes mirror this:
`0` ok, `1` source errors (E1–E4), `2` usage/CLI error, `3` emit/IO error (E6), `4` gfortran stage failed.

---

## 8. Implementation Language: Python compiler, Fortran runtime — Recommendation

**Recommend: write lexer/parser/AST/validate/optimize/emitters in Python 3 (stdlib only);
keep all rendering in Fortran.** The compiler is a new `tools/f3dc/` Python package; no new
Fortran module is added for compilation itself.

| Criterion | Python (recommended) | Fortran compiler |
|---|---|---|
| String/text work (lexing, JSON, HTML templating) | Native strengths; `json`, `re`, `dataclasses`, `argparse` in stdlib | Manual formatting throughout (cf. `export_mesh_json`'s format-string gymnastics); no JSON parser, no regex, no hash map in stdlib |
| Error messages with spans/hints | Trivial string building | Painful; risks exposing gfortran-style errors — the opposite of the ease goal |
| Iteration speed / tests | No compile step; `pytest` golden tests on IR JSON | Every compiler fix = full `make` cycle with `-fcheck=all` |
| Distribution | `f3dc` = a `#!/usr/bin/env python3` script; user box already needs only `python3` + `gfortran` | Single binary is nicer, but couples compiler bugs to the `-O3` build |
| Performance | Irrelevant at v1 scale (≤ ~100 k tris; lex/parse is milliseconds) | Faster, needlessly |
| Precedent in repo | `viewer.html` already makes JS the second language; Python adds tooling, not runtime | — |

**Costs accepted:** (1) two toolchains to document (`python3 ≥3.10`, `gfortran`); (2) no
type-checked guarantee that emitted Fortran compiles — mitigated by golden tests that run
`gfortran -fsyntax-only` on emitted code in CI; (3) if a future self-hosting / single-binary
requirement appears, the IR JSON (§5.2) is the port boundary: reimplement stages 1–5 against
that contract, emitters last. A Fortran implementation of the *lexer/parser only* was also
rejected: it buys nothing the runtime needs and puts the worst text-processing workload in
the weakest text-processing language available here.

Zero third-party Python dependencies is a hard rule (no `pip install` step — ease goal);
hand-rolled lexer/parser and stdlib `json`/`hashlib`/`argparse` only.

---

## 9. File / Module Layout (new files only; `src/` untouched)

```
tools/f3dc/
  f3dc                  # executable shim: #!/usr/bin/env python3 → f3dc_pkg.cli:main
  f3dc_pkg/
    __init__.py         # __version__
    errors.py           # Diagnostic, Span, ErrorBag (collect-cap-report), codes table
    lexer.py            # tokenize(source, filename) -> list[Token]
    ast_nodes.py        # §5.1 dataclasses
    parser.py           # Parser(tokens).parse_scene() -> Scene (AST)
    compat.py           # legacy scene.json reader + .obj reader -> AST (synthetic spans)
    desugar.py          # defaults, repeat expansion, group flattening
    validate.py         # AST' -> IRScene | raises ErrorBag   (uses ir_nodes)
    ir_nodes.py         # §5.2 frozen dataclasses + to_json/from_json (ir_version)
    optimize.py         # passes O1–O7, each fn(IRScene)->IRScene, + stats dict
    emit_common.py      # formatting, header stamp, palette helpers
    emit_fortran.py     # -> .f90   (§6.1)
    emit_json.py        # -> scene.json v2 and/or v1 (§6.2)
    emit_js.py          # -> scene.js (+ optional runtime string) (§6.3)
    emit_html.py        # -> .html  (§6.4, loads template)
    templates/viewer.html.tmpl
    driver.py           # gfortran/make invocation for `build`/`run`, subprocess handling
    cli.py              # argparse: subcommands + flags (§10), stage orchestration
  tests/
    test_lexer.py  test_parser.py  test_validate.py  test_optimize.py
    golden/             # <case>.f3d + expected .ir.json / .json / .js / .f90 (+ .html skeleton)
    cases/              # hello-cube, groups-repeat, legacy-cube (from repo scene.json), errors/*
Makefile                # (later, separate plan) add `f3dc`/`scene` convenience targets only
docs/plan/P04-compiler-pipeline.md   # this file
```

Dependency rule (enforced by import layering in tests): `lexer ← parser ← desugar/validate →
ir_nodes → optimize → emit_* → cli/driver`. Emitters never import parser/AST; front end never
imports emitters. `compat.py` may only produce AST.

---

## 10. CLI: `f3dc`

```console
f3dc <command> [options] <input.f3d|input.json|input.obj>

f3dc check  hello.f3d                     # lex+parse+validate only; print diagnostics; no files written
f3dc build  hello.f3d                     # full pipeline, --target all, into build/ (default)
f3dc build  hello.f3d --target fortran,json --out dist/
f3dc run    hello.f3d                     # build fortran target, compile with gfortran, execute, report PPM path
f3dc fmt    hello.f3d                     # canonical re-print of AST (2-space indent, sorted props) — v1.1, optional
f3dc new    my-scene                      # scaffold my-scene.f3d from hello-cube template

Global / pipeline flags:
  --emit tokens|ast|ir|opt-ir            # dump that stage (stdout or --out file) and stop
  --stats                                 # per-pass object/tri/vert counts (O1–O7) to stderr
  --json-dialect v1|v2|both               # default both
  --format text|json                      # diagnostics format
  --strict                                # warnings (W5xx) become errors
  --no-optimize                           # skip §4.4 (debugging; O7 sort still applied for js/html correctness)
  --keep-build                            # retain generated .f90 + objects after `run`
  -q | -v                                 # quiet / verbose (stage timings)
```

Behavior rules: input type by extension (`.f3d`/`.json`/`.obj`); output names derive from the
input stem; existing outputs are overwritten only if they carry the `f3dc` header stamp or
`--force` is given (never silently clobber a hand-written `scene.json` / `viewer.html` in the
repo root — default out dir is `build/`, precisely to avoid colliding with the checked-in
`scene.json`, `viewer.html`, `model.obj`); `run` invokes the repo build as
`gfortran -O3 -Wall -Wextra -fcheck=all -Jinclude src/math_3d.f90 src/mesh.f90 src/camera.f90
src/renderer.f90 build/<stem>_scene.f90 -o build/<stem>` (same flags/order as `Makefile`
module dependencies: math → mesh/camera → renderer) or delegates to `make` when a target exists.

The ease comparison the CLI must keep winning: Three.js hello-cube ≈ create project, install,
import, ~40 lines, dev server. `f3dc`: write 6 lines, `f3dc run hello.f3d`, open the emitted
`.html`. Two commands, no install, no server.

---

## 11. Testing Strategy (pipeline-specific)

1. **Golden per stage:** each `golden/*.f3d` pins tokens/AST/IR/opt-IR/emitted files; a diff in any stage fails with that stage's dump — localizes regressions to one stage.
2. **Round-trips:** IR → v2 JSON → IR is identity; IR → v1 JSON → `compat` reader → IR preserves triangle multiset (transforms already baked); emitted Fortran → `gfortran -fsyntax-only` clean; emitted Fortran compiled + run on hello-cube reproduces a PPM whose `scene.json` export matches v1 emit (cross-checks §6.1 against `export_mesh_json`).
3. **Legacy fixture:** the repo's current 12-triangle `scene.json` is a permanent golden case (compat reader → all four targets; HTML must load in the *unmodified* current viewer logic).
4. **Error fixtures:** one file per `E`-code asserting code, span, and hint text.
5. **Determinism:** build twice, `sha256` all outputs, require equality.

---

## 12. Phased Delivery (suggested order, each phase independently usable)

| Phase | Deliverable | Usable result |
|---|---|---|
| P04-a | `errors/lexer/parser/ast_nodes` + `f3dc check` + `--emit tokens|ast` | Language can be written and syntax-checked |
| P04-b | `desugar/validate/ir_nodes` + `--emit ir` + error fixtures | Full diagnostics; IR contract frozen (`ir_version: 1`) |
| P04-c | `emit_json (v1+v2)` + `compat` + legacy golden case | Drop-in replacement for hand-made `scene.json`; current `viewer.html` works end-to-end |
| P04-d | `optimize (O1–O3, O5–O7)` + `--stats` | Size/speed wins; HTML/JS ordering correctness |
| P04-e | `emit_fortran` + `driver` + `f3dc run` | Headline flow: `.f3d` → PPM with zero Fortran authoring |
| P04-f | `emit_js`, `emit_html`, `f3dc new` | Self-contained web output; the Three.js/PixiJS ease comparison is demonstrable |

Risks / open questions for the parent plan: (1) v2 JSON schema ownership — freeze in P04-b or
it will drift per emitter; (2) `viewer.html` template divergence — once `emit_html` ships, the
checked-in `viewer.html` should be *generated* from the template to avoid two viewers;
(3) multi-object Fortran emit relies on shared-`FrameBuffer` sequential `render_mesh` calls —
verify no per-call clear is introduced in `renderer.f90` later; (4) animation/time is out of
scope now, but IR `Meta` reserves a `timeline` field so adding it is not a breaking IR change.
