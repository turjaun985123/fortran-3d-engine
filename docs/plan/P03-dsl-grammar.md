# P03 — Easy-DSL Grammar Design for `.f3d`

> Status: planning only (no engine code changed). Repo ground truth at design time:
> `src/math_3d.f90` (`vec3`, `mat4`, translate/scale/rotate-x/y/z, perspective, look-at),
> `src/mesh.f90` (`create_cube(m, size)` **only** — 12 triangles, per-face colours),
> `src/camera.f90` (`camera_init`: position, target, fov, aspect, near, far; up = +Y),
> `src/renderer.f90` (framebuffer, z-buffer, Lambertian light, PPM export only),
> `src/main.f90` (the hardcoded demo this DSL replaces: 640×480, cube size 2,
> camera (3, 2.5, 4)→(0,0,0), fov 60, near 0.1, far 100, light dir (−0.5, −1, −0.7),
> static rotation 35° Y / 20° X, outputs `output_render.ppm` + `scene.json` + `model.obj`).

## 1. Design promise

**A beginner who knows no 3D vocabulary gets a picture from one word, and an
animated rotating cube in at most 3 lines. Everything omitted has a default
copied from the working `main.f90` demo, so omission never means failure.**

```f3d
cube red
spin it
render
```

That is the contract test: 3 lines, no `scene`, no `camera`, no `light`, no
coordinates, no units, no punctuation, no boilerplate. It must produce an
animated render (see §7 for exactly what each line expands to).

Non-goals for v1: variables, expressions, loops, functions, materials/shaders,
physics, textures, nesting/group hierarchies, scripting. If a feature needs a
brace, a semicolon, or a manual, it is out of v1.

### Principles

1. **Line-oriented.** One statement per line. No semicolons, no commas required,
   no closing braces in the common path. Newline = end of statement.
2. **English order, forgiving surface.** `cube red at 0 0 0 size 2` and
   `red cube size 2` are not both supported — one canonical order (§4) so error
   messages can say what was expected; forgiveness comes from *defaults and
   optional words*, not from free word order.
3. **Defaults over declarations.** `scene`, `camera`, `light`, and `render`
   are all optional statements that *override* an implicit default scene.
4. **Names are optional; pronouns work.** An unnamed object is addressable as
   `it` / `last` in the next statements — that is what makes 3 lines possible.
5. **Units are plain.** Angles in degrees (engine converts, as `main.f90`
   does: `deg * PI / 180`), lengths in world units, times in seconds,
   speeds for `spin` in degrees/second. No suffixes required in v1.
6. **Case-insensitive, comment-friendly.** Keywords and colour names are
   case-insensitive (trivial in a Fortran lexer); `#` starts a comment.
7. **Fail in plain English, with the line number.** e.g.
   `line 2: 'spin' needs an axis or a speed I understand — try: spin y 90`.
   Never a Fortran runtime traceback for a DSL mistake.
8. **Grammar ≠ capability.** Keywords for not-yet-built primitives are
   *reserved* (§5) so programs don't silently change meaning later, but the
   v1 compiler must reject them with `not supported yet: sphere (only cube
   exists today)` — never silently substitute a cube.

## 2. Lexical rules

| Token | Rule | Examples |
|---|---|---|
| `number` | Integer or decimal, optional leading `-`. No exponent in v1. | `2`, `-1.5`, `0.25` |
| `name` | Letter followed by letters/digits/`_`/`-`; cannot be a keyword/colour. | `hero`, `my-cube_2` |
| `colour` | Named colour (§6.3), `#RRGGBB`, or `rgb r g b` (0–255 ints). | `red`, `#3cdc3c`, `rgb 60 220 60` |
| `string` | Double-quoted, no escapes in v1; used only for file paths/titles. | `"out.png"` |
| `vec3` (syntax, not a token) | Three consecutive `number`s. No commas/brackets required; commas *allowed* and ignored. | `3 2.5 4`, `3, 2.5, 4` |
| Comment | `#` to end of line. Blank lines ignored. | `# my first scene` |
| Whitespace | Spaces/tabs separate tokens; indentation insignificant (v1 has no blocks except optional `scene … end`, §4.3). | |

Reserved-but-rejected in v1 (lexed, then a targeted error): `let`, `if`,
`for`, `loop`, `function`, `import`, `texture`, `material`.

## 3. The 3-line contract, expanded

```f3d
cube red          # (1) create the default object, coloured red
spin it           # (2) animate: rotate it, continuously
render            # (3) write the default output
```

Deterministic desugaring (the compiler prints this with `--explain`):

```f3d
scene "untitled" size 640 480 background #191923        # (25,25,35) in renderer.f90
camera at 3 2.5 4 look 0 0 0 fov 60 near 0.1 far 100
light dir -0.5 -1 -0.7                                  # directional, Lambertian
cube named last at 0 0 0 size 2 colour red rotate 20 35 0
animate last spin y speed 90 duration 5                 # §7 defaults
render to "output_render.ppm" frames 150 fps 30         # + scene.json/model.obj if `export` given
```

Notes: the static `rotate 20 35 0` matches the demo's 20° X / 35° Y pose so a
still looks good in frame 0; `spin` *adds* rotation over time on top of it.

## 4. EBNF (ISO/IEC 14977)

```ebnf
(* .f3d program — v1 grammar *)

program        = { line } ;
line           = [ statement ] , [ comment ] , newline ;
comment        = "#" , { any-character } ;

statement      = scene-stmt | camera-stmt | light-stmt
               | object-stmt | transform-stmt | animate-stmt
               | render-stmt | export-stmt ;

(* --- scene / output frame --- *)
scene-stmt     = "scene" , [ string ] , { scene-prop } ;
scene-prop     = "size" , number , number            (* width height, px *)
               | "background" , colour
               | "bg" , colour ;                     (* alias *)

(* --- camera: overrides default camera --- *)
camera-stmt    = "camera" , { camera-prop } ;
camera-prop    = "at" , vec3                         (* position *)
               | "look" , vec3                       (* target *)
               | "fov" , number                      (* degrees *)
               | "near" , number | "far" , number
               | "up" , vec3 ;

(* --- light: overrides default directional light --- *)
light-stmt     = "light" , { light-prop } ;
light-prop     = "dir" , vec3                        (* direction, normalised by engine *)
               | "from" , vec3                       (* point it shines from: dir = -from *)
               | "colour" , colour | "color" , colour
               | "strength" , number ;               (* 0..n, 1 = current renderer mix *)

(* --- objects: the only way to create geometry --- *)
object-stmt    = primitive , [ name ] , { object-prop } ;
primitive      = "cube"                              (* v1: IMPLEMENTED *)
               | "sphere" | "cylinder" | "cone"      (* reserved: backend TODO *)
               | "plane" | "pyramid" | "torus" ;     (* reserved: backend TODO *)
object-prop    = "at" , vec3                         (* position, default 0 0 0 *)
               | "pos" , vec3                        (* alias of at *)
               | "colour" , colour | "color" , colour
               | "size" , number                     (* cube edge / sphere diameter *)
               | "size" , vec3                       (* non-uniform: box sx sy sz *)
               | "radius" , number                   (* sphere/cylinder/cone *)
               | "height" , number                   (* cylinder/cone/pyramid *)
               | "rotate" , vec3                     (* static Euler degrees x y z *)
               | "rot" , vec3 ;                      (* alias *)

(* --- transforms on an existing object --- *)
transform-stmt = action , target , { object-prop | motion-prop } ;
action         = "move" | "rotate" | "spin" | "scale" ;
target         = name | "it" | "last" | "all" ;

(* --- animation --- *)
animate-stmt   = "animate" , target , motion , { motion-prop }
               | "spin" , target , { motion-prop }   (* sugar: animate + spin *)
               | "spin" , { motion-prop } ;          (* sugar, target defaults to last *)
motion         = "spin" | "move" | "bob" | "pulse" ;
motion-prop    = axis , [ number ]                   (* axis + total degrees / distance *)
               | "speed" , number                    (* deg/s for spin, units/s for move *)
               | "duration" , number                 (* seconds *)
               | "loop" | "once" | "pingpong"
               | "ease" , ( "linear" | "smooth" | "in" | "out" ) ;
axis           = "x" | "y" | "z" ;

(* --- output --- *)
render-stmt    = "render" , { render-prop } ;
render-prop    = "to" , string                       (* .ppm in v1; .png via converter if present *)
               | "size" , number , number
               | "frames" , number | "fps" , number | "duration" , number
               | "still" ;                           (* force 1 frame even if animated *)
export-stmt    = "export" , ( "obj" | "json" ) , [ string ] ;

vec3           = number , [ "," ] , number , [ "," ] , number ;
colour         = colour-name | "#" , 6 * hex-digit | "rgb" , number , number , number ;
```

### 4.1 Grammar constraints not expressible in EBNF (validate in parser)

- Each property may appear at most once per statement; duplicate →
  `line N: 'size' given twice`.
- `object-prop`s may appear in any order *after* the primitive/name.
- A statement may not mix creation and animation: `cube spin …` is an error
  with a hint (`write 'spin it' on the next line`).
- `target` must resolve: a declared `name`, or `it`/`last` = most recently
  created or transformed object; error if none exists yet.
- Numbers: `size`/`radius`/`height` > 0; `fov` in (0, 180); `near` > 0;
  `far` > `near`; colour channels 0–255. All checked at parse time.
- At most one `scene`, one `camera`, and one `light` statement take effect;
  a second one *replaces* (with a warning), it does not merge — predictable
  for beginners.

### 4.2 Optional block form (sugar, not required)

For multi-object scenes, an optional wrapper is allowed and ignored semantically:

```f3d
scene "demo"
  cube red at -2 0 0
  cube blue at 2 0 0
end
```

`scene … end` is the only block in v1. Indentation inside it is cosmetic.
Programs without it are exactly equivalent.

## 5. Keywords

| Category | Keywords | Notes |
|---|---|---|
| Structure | `scene end background bg` | All optional. |
| Camera | `camera at look fov near far up` | `at`/`look` take a `vec3`. |
| Light | `light dir from strength` | One directional light in v1 (matches `renderer.f90`). |
| Primitives (v1) | `cube` | Maps to `create_cube`. |
| Primitives (reserved) | `sphere cylinder cone plane pyramid torus` | Grammar-ready; compiler errors `not supported yet` until `mesh.f90` grows a constructor per primitive. Do **not** fake with cubes. |
| Object props | `at pos size radius height colour color rotate rot` | `color` = US alias of `colour`, everywhere. |
| Actions | `move rotate scale spin` | On an existing `target`. |
| Animation | `animate duration speed loop once pingpong ease linear smooth in out bob pulse` | See §7. |
| Targets | `it last all` | Pronouns; `all` applies to every object. |
| Output | `render to frames fps still export obj json` | `render` with no props = still PPM unless an `animate`/`spin` exists (§7). |
| Axes / misc | `x y z named` | `named` is internal to the desugared form; users write `cube hero …` (bare name). |

Total beginner surface: **~15 words to learn** (`cube, colour-name, at, size,
rotate, spin, move, camera, light, animate, duration, render, to, export, scene`)
— everything else is optional refinement.

## 6. Defaults (single source of truth)

Every default below is taken from the current working engine, so a default
program renders *the demo the engine already renders*, only easier to write.

### 6.1 Scene / camera / light

| Setting | Default | Engine source |
|---|---|---|
| Image size | `640 × 480` | `main.f90`: `width=640, height=480` |
| Background | `#191923` = rgb(25, 25, 35) | `renderer.f90`: `framebuffer_clear(fb, 25, 25, 35)` |
| Camera position | `3 2.5 4` | `main.f90`: `eye` |
| Camera target | `0 0 0` | `main.f90`: `target` |
| Camera up | `0 1 0` | `camera.f90`: `camera_init` |
| FOV / near / far | `60` / `0.1` / `100` | `main.f90`: `camera_init(...)` |
| Aspect ratio | derived: width ÷ height | `main.f90` (never asked of the user) |
| Light direction | `-0.5 -1 -0.7` (normalised internally) | `main.f90`: `light_dir` |
| Shading | ambient 0.25 + 0.75 × Lambert diffuse | `renderer.f90`: `intensity = 0.25 + 0.75*diffuse` |
| Output file | `output_render.ppm` | `main.f90`: `output_file` |

### 6.2 Object

| Property | Default | Notes |
|---|---|---|
| Position (`at`) | `0 0 0` | Origin; camera default frames it. |
| Size | `2` | `main.f90`: `create_cube(cube, 2.0_dp)`. |
| Static rotation | `20 35 0` degrees (x y z) | Demo pose in `main.f90` (35° Y, 20° X) so a lone cube never looks flat/axis-aligned. Single-object scenes only; multi-object scenes default to `0 0 0` unless specified — avoids every object sharing a "demo pose" by accident. |
| Colour | Per-face palette (below) if unspecified; a single colour if given | Preserves today's look by default. |
| Name | auto: `last` (and `cube1`, `cube2`, … internally) | Enables `it`. |

### 6.3 Colours

Named colours (case-insensitive) — a deliberately small, memorable set:
`red green blue yellow magenta cyan orange purple pink white black gray/grey`.
Unspecified cube faces keep the engine palette from `mesh.f90`:
south red (220,60,60), east green (60,220,60), north blue (60,100,240),
west yellow (240,220,50), top magenta (200,80,220), bottom cyan (60,220,220).
A single named colour tints **all** faces that colour (shading still varies
by face via Lambert term) — simplest mental model for a beginner.
`#RRGGBB` and `rgb r g b` are the escape hatches.

## 7. Animation model

Animation is declarative, not frame-scripted: the user states *what moves,
how fast / how far, for how long*; the compiler generates frames.

| Aspect | Rule / default |
|---|---|
| Trigger | Any `animate` statement, or bare `spin`, makes `render` produce a sequence instead of one still. |
| `spin <target>` defaults | axis `y`, speed `90` °/s (one full turn in 4 s), `loop`, easing `linear`. |
| Duration default | `5` s. At default `30 fps` → 150 frames. `duration`, `frames`, `fps`: any two determine the third; specifying all three inconsistently is an error. |
| `bob` | Sinusoidal Y motion, amplitude 0.5 units, period = duration, unless `speed`/distance given. (Sugar over `move`; v1 may desugar or defer — if deferred, same `not supported yet` error rule.) |
| `pulse` | Scale oscillates 1.0 → 1.2 → 1.0 over duration. Same deferral rule as `bob`. |
| Static + animated | Final transform per frame = translation(`at`) · rotation(static `rotate` + animated angle(t)) · scale — i.e. `mat4_mult` composition of the existing `math_3d` matrices, in that documented order. |
| Output of an animation (v1) | Numbered PPM frames `output_render_0001.ppm`, … plus the first frame as `output_render.ppm`. GIF/MP4 assembly is **out of v1** (engine only writes PPM today); the plan may note it as a post-v1 converter step, not a grammar feature. |
| `render still` | Overrides animation: exactly 1 frame at t=0. |

## 8. Render / export semantics

- `render` alone → one still (or the animation sequence, per §7) to the
  default file. `render to "x.ppm"` changes only the path/basename.
  A `.png` target is accepted only if the existing ImageMagick conversion
  step (see `Makefile: run`) is available; otherwise a clear error naming
  the `.ppm` that *was* written — never a silent success.
- `export obj` / `export json` map to the existing `export_mesh_obj` /
  `export_mesh_json` in `mesh.f90`, default files `model.obj` / `scene.json`.
  Export is of the t=0 posed scene; animation export is out of v1.
- Exit behaviour (for the future compiler driver): success = exit 0 and the
  output path printed; any DSL error = exit non-zero, one plain-English
  message per error, no partial output file left behind.

## 9. Examples (graded)

### 9.1 One line — a picture

```f3d
cube
```

A per-face-coloured cube, demo pose, default camera/light, `output_render.ppm`.

### 9.2 Three lines — the contract (rotating cube)

```f3d
cube red
spin it
render
```

### 9.3 Still, placed and posed (~10 s to read)

```f3d
# A blue cube, off-centre, turned toward us
scene size 800 600 background black
camera at 4 3 6 look 0 0 0
cube hero blue at 1 0 0 size 3 rotate 0 45 0
render to "hero.ppm"
```

### 9.4 Two objects, one named, one pronoun

```f3d
cube red at -2 0 0 size 2
cube green at 2 0 0 size 1
spin it speed 180        # only the green (last) cube spins
render duration 3
```

### 9.5 Explicit animation block-style (same grammar, no new syntax)

```f3d
cube gold at 0 0 0
animate it spin x speed 45 duration 4 loop
animate it bob duration 4
camera at 0 2 8 look 0 0 0 fov 50
light from 2 4 3 strength 1
render to "spin.ppm" fps 30
```

(`gold` is intentionally **not** in §6.3 — this example must fail with
`unknown colour 'gold' — try yellow, or #RRGGBB`. It is kept here as the
canonical error-message test case; change `gold`→`yellow` to run it.)

### 9.6 Future primitive (grammar accepted, backend pending)

```f3d
sphere red at 0 1 0 radius 1
render
```

v1 compiler output: `line 1: 'sphere' is in the .f3d language but not built
yet — only 'cube' works today.` This is the specified behaviour until a
`create_sphere` exists in `mesh.f90`; the grammar does not change when it lands.

## 10. Implementation notes for the future Fortran compiler (informative)

- **Parser shape:** a line lexer + recursive-descent per statement fits
  Fortran easily: read a line, split tokens, dispatch on token 1. No AST
  depth beyond a flat statement list; objects in an allocatable array.
- **Two passes:** (1) parse + validate (§4.1) collecting scene/camera/light/
  objects/animations; (2) lower to today's calls — `framebuffer_init`,
  `create_cube`, `camera_init`, per-frame `mat4_translation × mat4_rotate_*
  × mat4_scale` via `mat4_mult`, `framebuffer_render_mesh`,
  `framebuffer_save_ppm`, optional exporters. `main.f90` becomes the driver
  that reads a `.f3d` file instead of hardcoding the demo (separate plan item).
- **Angles:** store degrees in the AST; convert once at lowering
  (`* PI / 180`), exactly as `main.f90` does today.
- **Reserved primitives:** dispatch table keyed by primitive name; missing
  constructor → the §9.6 error. Adding `sphere` later touches `mesh.f90`
  + one dispatch entry, zero grammar changes.
- **Testing the grammar:** golden files = §9.1–9.5 (9.5 with `yellow`),
  the §9.5-`gold` and §9.6 error cases, duplicate-property and bad-vec3
  cases, and a byte-check that §9.1's default render matches the current
  hardcoded demo's `output_render.ppm` (regression anchor).

## 11. Explicitly deferred (not in v1 grammar)

Variables/expressions, conditionals/loops, grouping & parenting, textures/
materials/lights beyond one directional light, point/spot lights, keyframes
beyond the §7 motions, curves/paths, text, importing `.obj` as an object
statement, sound, interactivity, GIF/MP4 output. Each, if added later, must
preserve the §1 contract: the 3-line rotating cube stays 3 lines, unchanged.
