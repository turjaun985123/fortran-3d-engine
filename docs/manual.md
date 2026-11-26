# Forge3D User Manual

Forge3D compiles a tiny declarative language (`.f3d`) into a 3D scene,
renders it natively with a deterministic Fortran software renderer, and
emits a dependency-free JavaScript/WebGL viewer for the same scene.
Compiler: `f3dc` — native (Fortran modules plus a clang C helper,
sources in `compiler/`), built with `make -C compiler` and installed as
`bin/f3dc` by `make f3dc`. Building it requires flang-18 (binary
`flang-new-18`) and clang-18; the compiler itself has no Python
dependency. Version: `f3dc 4.0.0`.

Comments start with `#` or `//`. One statement per line. Names are
identifiers you choose (`cube spinner red …` names the cube `spinner`).


## 1. 60-second quickstart

```bash
make f3dc                                # build + install the native compiler to bin/f3dc
bin/f3dc new hello                       # creates hello.f3d, never overwrites
bin/f3dc run hello.f3d                   # build + compile engine + render
bin/f3dc hello.f3d                       # bare file = same as `run`
```

`f3dc new` writes exactly the 3-line contract:

```f3d
cube red
spin it
render
```

That is a complete program: a lit, framed, spinning red cube, rendered to
a PPM image — no camera, light, loop, resize, or boilerplate lines.

### What those 3 lines desugar to

Missing pieces are injected with these defaults (warnings `W101`/`W201`
name the important substitutions; ordinary per-field defaults are silent
by design):

| Thing | Default injected |
|---|---|
| Scene size | `640 x 480` |
| Background | `#191923` = RGB (25, 25, 35) |
| Camera | `at 3 2.5 4`, `look 0 0 0`, up `0 1 0`, `fov 60`, near `0.1`, far `100` |
| Light | `directional`, direction `(-0.5, -1, -0.7)`, intensity `1.0`, white |
| Object position / rotation / scale | `at 0 0 0` / `rotate 0 0 0` / `scale 1 1 1` |
| Object size | `size 2` (radius/height derive per primitive, §2.2) |
| Object colour | none = per-face palette (red/green/blue/yellow/magenta/cyan) |
| Material | `lambert` |
| `spin` animation | axis `y`, speed `90` °/s, duration `5` s, fps `30`, ease `linear`, loop `forever` |
| Render output | `<stem>.ppm` in `build/` (see §3) |

An empty (or comment-only) file also renders the demo cube on the render
path, with a warning — it is an error under strict checking workflows.


## 2. The `.f3d` language reference

Vectors (`vec3`) are written as three numbers: `4 3 6`, `4, 3, 6`, or
`(4, 3, 6)` — all equivalent wherever a vec3 is expected.

### 2.1 Scene, camera, light

```f3d
scene "materials" size 640 480 background black
scene multi size 800 600 bg black
camera at 6 4 8 look 0 0 0 fov 60
light directional dir -0.5 -1 -0.7 strength 1.2
```

- `scene [name|"name"] [size W H | size WxH] [bg|background colour]`
  — at most one takes effect; a later one replaces an earlier (`W102`).
- `scene … [antialias N]` — supersampling factor for the v3 renderer
  (§2.10): `N` is one of `1`, `2`, `4` or `8`. The scene renders at
  `N`× resolution and is box-downsampled in linear space; `1` (the
  default when the clause is absent) is no supersampling.
- `camera [at vec3] [look vec3] [up vec3] [fov n] [near n] [far n]`
  — every clause optional; omitted fields keep the §1 defaults.
- `light (directional|ambient) [dir vec3 | from vec3] [intensity n | strength n] [colour]`
  — `from` is negated into a direction. A bare vec3 is the direction; a
  bare colour word sets the light colour. (`point`/`spot` are parsed but
  are Wave A work — see §7; do not rely on them yet.)

### 2.2 Objects: primitives and their properties

Form: `primitive [name] [colour] {prop}` — name and colour may appear in
either order after the primitive; every prop is optional.

| Primitive | Default triangles (med detail) | Notes |
|---|---|---|
| `cube` | 12 | governed by `size` |
| `sphere` | 352 | governed by `radius` |
| `cylinder` | 64 | `radius` + `height`, `capped` by default |
| `plane` | 4 | governed by `size` (double-sided since Wave C, D1) |
| `pyramid` | 6 | `size` + `height` |
| `cone` | 32 | `radius` + `height` |
| `torus` | 384 | governed by `radius` |
| `circle` | `2·seg` | `radius`; flat filled disc — `circle radius 1 color <named>` |
| `ring` | `4·seg` | `inner` + `outer` radii; flat annulus — `ring inner 0.5 outer 1 color <named>` |
| `capsule` | `2·seg+2·seg·(2·hr−1)` | `radius` + `height`; capped cylinder, `hr = seg/4` — `capsule radius 0.5 height 2 color <named>` |
| `tube` | `(n−1)·seg·2+2·seg` | `radius` swept along a `path` of n points — `tube radius 0.2 path 0,0,0 1,1,0 2,0,0 color <named>` |
| `lathe` | `(n−1)·seg·2` | `points` profile of n points revolved about Y — `lathe points 0,0 0.6,0.2 0.6,1 0,1.2 color <named>` |
| `extrude` | `4n−4` | `shape` polygon of n points + `depth` — `extrude shape 0,0 1,0 1,1 0,1 depth 0.5 color <named>` |
| `tetrahedron` | 4 | Platonic solid governed by `radius` — `tetrahedron radius 1 color <named>` |
| `octahedron` | 8 | Platonic solid governed by `radius` — `octahedron radius 1 color <named>` |
| `icosahedron` | 20 | Platonic solid governed by `radius` — `icosahedron radius 1 color <named>` |
| `dodecahedron` | 36 | Platonic solid governed by `radius` (pentagonal faces triangulated) — `dodecahedron radius 1 color <named>` |
| `torusknot` | `seg·tseg·2` | governed by `radius` — `torusknot radius 1 color <named>` |

Properties (each may appear at most once — duplicates are `E110`):

| Prop | Meaning |
|---|---|
| `at vec3` (aliases `pos`, `position`) | position, default `0 0 0` |
| `size n` | overall size, default `2` |
| `radius n` | sphere/cylinder/cone/torus radius |
| `height n` | cylinder/cone/pyramid height |
| `color colour` | Wave D spelling of the object colour (see §2.3), e.g. `color red` |
| `inner n` / `outer n` | ring inner / outer radius |
| `path p,p,p …` | tube centreline points, comma triples (e.g. `path 0,0,0 1,1,0 2,0,0`) |
| `points p,p …` | lathe profile points, comma pairs (e.g. `points 0,0 0.6,0.2 0.6,1 0,1.2`) |
| `shape p,p …` | extrude outline points, comma pairs (e.g. `shape 0,0 1,0 1,1 0,1`) |
| `depth n` | extrude depth |
| `rotate vec3` | rotation in degrees (X, Y, Z) |
| `scale n` or `scale vec3` | uniform or per-axis scale |
| `material lambert\|basic\|phong` | `lambert` = lit default; `basic` = unlit flat colour; `phong` = specular highlight |
| `segments int` | tessellation segments (overrides `detail`) |
| `detail low\|med\|high` | tessellation preset, default `med` |
| `capped` / `open` | capped (default) or open ends, cylinder/cone |
| `shading smooth\|flat` | vertex-normal (smooth) or face-normal (flat) shading; default `smooth` for curved primitives (sphere, cylinder, cone, capsule, tube, lathe, torus, torusknot), `flat` otherwise; may also be set once on the `scene` line as the scene default |
| `mirror x\|y\|z` | reflect the object's geometry across that axis through its own local origin (applied before its scale/rotation/position); winding is corrected automatically, so lighting stays outward |
| `texture "path"` | base-colour texture image: a `.ppm` or a `.png` file (see “Textures and material keys” below) |
| `normalmap "path"` | tangent-space normal map (`.ppm`/`.png`), sampled as linear data |
| `mr "path"` | metallic-roughness map (`.ppm`/`.png`), sampled as linear data |
| `emissivemap "path"` | emissive map (`.ppm`/`.png`), sampled as sRGB |
| `occlusionmap "path"` | ambient-occlusion map (`.ppm`/`.png`), sampled as linear data |
| `emissive colour` | emissive colour added on top of the lit result (any §2.3 spelling) |
| `opacity n` | opacity, `0`–`1` (default `1`); multiplies the texture alpha |
| `cutoff n` | alpha-mask threshold, `0`–`1` (default `0.5`) |
| `alpha opaque\|mask\|blend` | alpha treatment (default `opaque`) — see below |

```f3d
cube lambert_cube red at -3 1 0 size 2 material lambert
sphere basic_ball #FF8800 at 3 1 0 radius 1 material basic
cylinder phong_pillar rgb 60 220 120 at 3 -2 0 radius 1 height 3 material phong
```

Textures and material keys (v3.0): the base `texture` and the four
extra slots (`normalmap`, `mr`, `emissivemap`, `occlusionmap`) each
take a quoted path to a `.ppm` or `.png` file — no other texture
format is accepted. Paths resolve like an imported part's (against
the working directory, then the scene file's directory); a missing
file is error `E501`. PNG files are decoded by the engine itself
(non-interlaced PNGs; Adam7-interlaced files are rejected), and every
loaded texture gets a mip chain. The emissive map loads as sRGB; the
normal, metallic-roughness and occlusion maps load as linear data.

The effective fragment alpha is the base texture's alpha (1 when the
texture has none) multiplied by `opacity`. The `alpha` key selects
what the v3 renderer does with it:

- `opaque` (default) — alpha is ignored; the fragment is fully opaque.
- `mask` — cutout: fragments with alpha below `cutoff` are discarded,
  so what is behind them shows through (e.g. the slats-and-gaps fence
  in `examples/alpha-masked.f3d`).
- `blend` — the fragment is alpha-blended over what is behind it
  using the effective alpha.

### Wave D geometries

Wave D adds `circle`, `ring`, `capsule`, `tube`, `lathe`, `extrude`,
the Platonic solids `tetrahedron`, `octahedron`, `icosahedron` and
`dodecahedron`, and `torusknot` (showcased together in
`examples/geometries.f3d`). They take the usual props (`at`, `rotate`,
`scale`, `material`, `segments`/`detail`) plus the geometry props in
the table above, and are coloured with `color <named>` (see §2.3).
Triangle counts at a given tessellation (`seg` = `segments`, `tseg` =
the torusknot's second tessellation count, `n` = point count of the
path/profile/shape):

| Primitive | Triangles |
|---|---|
| `circle` | `2·seg` |
| `ring` | `4·seg` |
| `capsule` | `2·seg+2·seg·(2·hr−1)`, where `hr = seg/4` |
| `tube` | `(n−1)·seg·2+2·seg` |
| `lathe` | `(n−1)·seg·2` |
| `extrude` | `4n−4` |
| `tetrahedron` | 4 |
| `octahedron` | 8 |
| `icosahedron` | 20 |
| `dodecahedron` | 36 |
| `torusknot` | `seg·tseg·2` |

### 2.3 Colours

Three spellings, usable anywhere a colour is expected:

- named: `red` (see table)
- hex: `#FF8800` (6 hex digits)
- rgb: `rgb 60 220 120`, `rgb(60,220,120)`, or `rgb 60, 220, 120`
  (channels are whole numbers 0–255)

Named colours — these exact RGB values everywhere (compiler, native
renderer, JS viewer); the first six are also the per-face palette:

| Name | RGB | Name | RGB |
|---|---|---|---|
| `red` | (220, 60, 60) | `orange` | (240, 140, 40) |
| `green` | (60, 220, 60) | `purple` | (140, 80, 200) |
| `blue` | (60, 100, 240) | `pink` | (240, 150, 190) |
| `yellow` | (240, 220, 50) | `white` | (240, 240, 240) |
| `magenta` | (200, 80, 220) | `black` | (20, 20, 25) |
| `cyan` | (60, 220, 220) | `gray` / `grey` | (140, 140, 145) |

Note: named `white`/`black` are not pure extremes — use `#FFFFFF`/`#000000`
for those exactly. An unknown colour word is error `E202` (did-you-mean included).

### 2.4 Groups

```f3d
group duo
  cone hat orange at -2 0 3 radius 1 height 2
  pyramid peak purple at 2 0 3 size 2 height 2
end
```

`group name {prop} … end` — one level only (no nested groups in
source). Group props (e.g. `at`, `rotate`, `scale`) are defaults for
every child: a child's own prop wins, and the group's value applies
where the child does not set one. Groups are flattened at compile
time, named children are prefixed `group.name`, and a group name is
a valid animation target. A missing or stray `end` is error `E401`.

### 2.4b Importing parts (components)

```f3d
import "parts/rocket-fin.f3d" as fin_r at 1.0 -2.6 -0.09
import "parts/rocket-fin.f3d" as fin_l at -1.0 -2.6 -0.09 mirror x
```

`import "path" as name {prop} …` — compile-time inclusion of another
`.f3d` file as a reusable part. The part file holds objects, groups
and animations only (no `scene`/`camera`/`render` statements — those
are error `E103`). Everything named in the part is prefixed
`name.` (e.g. `fin_l.fin`), animations inside the part are retargeted
to the prefixed names, and the import line's props behave exactly
like a group header's props (defaults for the part's objects).
Imports nest — a part may import other parts, with paths resolved
relative to the importing file — and all paths must stay inside the
scene's directory tree. A missing part file is error `E501`; an
import cycle is error `E504`. See `examples/rocket-parts.f3d` and
`examples/parts/`.

### 2.5 Repeat, grid, ring

Prefix any single object statement; expansion happens at compile time:

```f3d
repeat 3 torus ringlet pink at -3 -2 -2 radius 1
grid 10 x 10 cube          # plan form: rows x cols of the object
ring 8 sphere blue radius 1
```

- `repeat N <object>` — N copies of the object statement.
- `grid R x C <object>` — an R×C arrangement (also written `grid R C`).
- `ring N <object>` — N copies arranged in a ring.

All expansions count toward the §7 placement/triangle limits.

### 2.6 Loading an OBJ model

```f3d
load "../model.obj" imported at 0 0 -5
```

`load "path" [name] {prop}` — same props as an object line. Paths are
scene-relative and containment-checked (§7). OBJ subset: `v`/`vt`/`vn`/`f`
with groups. A missing file is a compile-time error (`E501`), not a
runtime 404. glTF is Wave B (§7), not v1.

### 2.7 Controls (viewer)

```f3d
controls orbit
controls orbit autorotate min 2 max 20
controls none
```

`controls (orbit|none) [autorotate] [min n] [max n]` — orbit is the
viewer default even without this line; `min`/`max` clamp the orbit
distance. This affects the generated viewer only, not the native render.

### 2.8 Animation

Short form — one verb, one target:

```f3d
spin it
bob bouncer amplitude 0.5 duration 2 fps 15
pulse pulser duration 2 fps 15
```

Long form — `animate` first, in either order:

```f3d
animate spinner spin y speed 180 duration 2 fps 15
animate spin it speed 90
```

Verbs: `spin` (rotate about an axis), `bob` (vertical sine offset,
amplitude 0.5), `pulse` (scale sine, ±20%), `orbit` (circle radius 2
about Y), `move`, `turn`, `grow`. Targets: `it` (the most recent object),
an object name, a group name, or `all`. Unknown targets are `E201`.

Animation properties (all optional):

| Prop | Default | Meaning |
|---|---|---|
| axis (`x`/`y`/`z`, bare or after `axis`) | `y` | axis for spin/turn/orbit |
| `speed n` | `90` | degrees/second for rotational verbs |
| `duration n` | `5` | seconds |
| `fps int` | `30` | frames per second when baking frames |
| `amplitude n` | verb default | e.g. `bob` height |
| `distance n` / `amount n` / `angle n` | verb default | verb-specific magnitude |
| `ease name` | `linear` | easing curve name: `linear`, `smooth`, `in`, `out`, `cubic-in`, `cubic-out`, `cubic-in-out`, or `bezier(x1,y1,x2,y2)` (a cubic Bézier easing through control points `(x1,y1)`/`(x2,y2)`; `x1`/`x2` are clamped to 0–1, and a malformed `bezier(...)` falls back to `linear`, as does any unknown name) |
| `loop once\|forever\|pingpong\|repeat(N)` | `forever` | bare `loop` means `forever` |

Animation is closed-form `f(t)`: same `t` ⇒ same pose natively and in JS; frame 0 is the still.

Keyframe tracks — a `keys` header plus one `key` line per keyframe:

```f3d
keys mover duration 2 loop pingpong
key mover at 0 pos 0 -1.2 0 rot 0 0 0 scale 1
key mover at 1 pos 1.5 -0.2 0 rot 0 90 0 scale 1.2 ease smooth
key mover at 2 pos 0 -1.2 0 rot 0 180 0 scale 1
```

- `keys <target> [duration n] [loop once|forever|pingpong] [fps n]` —
  with `fps n` on the header, that track's key times and duration are
  **frame numbers**, not seconds (each clip carries its own fps; the
  engine converts `t` internally). Without `fps`, times are seconds,
  exactly as before.
- `key <target> at <time> [pos vec3] [rot vec3] [scale n] [ease name]`
  — `ease` takes the same names as the table above, including the
  `cubic-in` / `cubic-out` / `cubic-in-out` family.
- Rotation between keys is interpolated in the engine with
  quaternions (`quat_slerp`, shortest path): a 350° → 10° turn goes
  the short way through 0°, and there is no gimbal-lock degeneracy.
  Keys are still authored as Euler `rot` degrees; the quaternion form
  is the engine's interpolation form.

### 2.9 Render and export

```f3d
render
render "multi-object.ppm"
render size 800 600
render duration 2 fps 15
export json "scene.json"
export obj "scene.obj"
export html "viewer.html"
```

- `render [ "file.ppm" ] [size W H | WxH] [duration n] [fps n] [frames n] [still]`
  — without a filename the output is `<stem>.ppm`. With `duration`/`fps`
  (or any animation present) `f3dc run` also writes animation frame
  files named `<stem>_0000.ppm`, `<stem>_0001.ppm`, … (4-digit, zero-padded)
  in the output directory and reports the frame count.
- The image format follows the filename extension: a name ending in
  `.png` (any case) writes a **native PNG** — lossless, pixel-identical
  to the PPM render, written by the engine itself with no external
  tools. Any other name writes PPM as before. Animation frame files
  inherit the extension (`<stem>_0000.png`, …). Example:
  `render to "poster.png"`.
- `export (json|obj|html) [ "path" | to "path" ]` — additional outputs
  alongside the render.

Worked examples shipped in `examples/`: `hello-cube.f3d` (the contract),
`multi-object.f3d` (group/repeat/load/controls), `animated.f3d`
(spin/bob/pulse, 320×240, 2 s at 15 fps = 30 frames), `materials.f3d`
(lambert/basic/phong, all three colour spellings), `geometries.f3d`
(every Wave D geometry, §2.2).

### 2.10 The v3 renderer (default) and the legacy renderer

Since v3.0 the native engine renders with the **v3 rasterizer by
default**. Compared with the v2 renderer it is perspective-correct
(attributes are interpolated in homogeneous space, not screen space),
casts a shadow map per light, and shades into a linear HDR
framebuffer that is tone-mapped at the end, so highlights roll off
instead of clipping. The v3 rasterizer is tile-parallel: the
environment variable `FORGE3D_THREADS` sets how many threads it uses
(unset = the OpenMP default; the rendered image is identical for any
thread count). Supersampling is the scene-level `antialias` clause
(§2.1).

The frozen v2 renderer is still available, unchanged, for exact
reproduction of v2 output:

- engine flag `--renderer legacy`, or
- environment variable `FORGE3D_RENDERER=legacy`

(`--renderer v3` / `FORGE3D_RENDERER=v3` selects the default
explicitly; the flag wins over the environment variable, and an
unknown value is an error, exit 2.) The legacy path reproduces the
frozen v2 renderer **bit-exact** — same input, byte-identical PPM —
which is what the pinned v2 golden is checked against.


### 2.11 Film mode: animation scripts (v4.0)

A `.f3d` file whose **first statement** is `film` is a film: a story
written in sentences — characters, actions, dialogue, camera moves —
that play **in written order**. Everything in this section exists only
in film mode; a file without the `film` header is parsed, desugared
and rendered exactly as in §2.1–§2.10 (the 3-line contract of §1 is
untouched). The design of record is `docs/ANIM-PLAN.md`; the compiled
output contract is the Timeline IR (`docs/TIMELINE-FORMAT.md`).

```f3d
film "Saturday Market" size 1280 720 fps 24
```

- `film ["title"] [size W H] [fps n] [tempo n]` — `size`/`fps` are the
  usual keywords; `fps` is the film's master frame rate. `tempo n`
  sets beats per minute (default 60, so 1 beat = 1 second until
  stated); durations may be written `N seconds` or `N beats`.
- Inside a film, each `scene` line starts a **shot**. Setup lines are
  the statements you already know (primitives, `group`, `import`,
  `repeat`, lights, the opening `camera`), plus `character` and
  `place`. Everything after the setup is **cues**.
- `place name at vec3` names a spot so cues never need raw
  coordinates: `lloyd walks to stall-front`.
- `f3dc build` on a film also writes `build/<stem>.timeline.json`
  (Timeline IR v1, frozen under ADR-5: integer frames at a rational
  fps, half-open `[start_frame, end_frame)` spans) and, when the film
  has dialogue, a `<stem>.srt` sidecar (§2.11, Export). A still —
  no timeline — writes neither file. `bin/engine3d
  build/<stem>.timeline.json` renders the film itself.

#### Characters and the identity rule

A character line has the same shape as a primitive line — keyword,
name, colour, free-order props. The prop vocabulary is **not core**:
it is declared by the character's plugin package (Plugins, below);
for the shipped `stickman` package it is:

```f3d
character lloyd blue at -5 0 2 tall head round wears cap red
character mira pink at 4 0 2 kid head round hair bun
```

| Prop | Meaning |
|---|---|
| `at vec3` | where they stand |
| `tall` / `short` / `kid` / `height n` | proportions — `kid` is child proportions, not a scaled adult |
| `head round\|square\|oval` | head style |
| `hair <word>` / a hair colour | hair as rig-attached geometry |
| `face happy\|sad\|determined\|surprised\|neutral` | starting expression (default `neutral`) |
| `wears <item> [colour]` (repeatable) | clothing/accessory, attached to the rig |
| `holds <name>` | an ordinary named object, held in the dominant hand |

**Identity rule:** proportions, `head` and `wears` are *who the
character is*. Cues may change `face`, position and pose only — there
is no cue syntax for changing identity mid-film. Declare a character
in each shot it appears in, restating the same identity (the shipped
examples do exactly this). At render time the engine generates the
figure procedurally from the pose — you never model body parts. A
character outside a film is also legal: a static figure, targetable
by the §2.8 verbs.

#### Cues: written order is play order

One grammar for characters, camera and objects alike:
**`<who> <verb-phrase> [in|for <duration>] [ease <name>]`**.
`in N seconds` = taking N seconds to get there; `for N seconds` =
keep doing it for N seconds. Instant actions (`jumps`, `nods`)
default to 1 second. Four modifiers, and only four, change the
default "one after another":

| Form | Reading |
|---|---|
| (default) | the cue starts when the previous cue ends |
| `with <cue>` | starts **with** the previous cue; the pair ends when the longer cue ends |
| `together` … `end` | all cues in the block start together; the block lasts as long as its longest cue |
| `at <time> <cue>` | starts at an absolute time (`at 5 seconds …`, `at 0:05 …`), measured from the shot's start |
| `wait N seconds` | hold everything for N seconds |

Two resolved cues on the same character and the same channel (body
motion) may not overlap — that is error `E207`; `with` is the
explicit opt-in, and cross-channel overlap (walk + talk) is free.
Easing is §2.8's vocabulary with two sentence adverbs: `slowly` ≡
`ease out`, `gently` ≡ `ease cubic-in-out` (`f3dc fmt` prints the
canonical form).

#### Actions: built-in and custom

The `stickman` package's verb set (canonical "-s" form; the base
form — `walk`, `wave` — is accepted as an alias everywhere, and
`f3dc fmt` prints the "-s" form):

`walks to <place|character|vec3>`, `runs to …`, `walks in from
left|right` (also `enters`), `exits left|right`, `waves [left
hand|right hand|both hands]`, `sits on <object>`, `stands`, `jumps`,
`falls`, `looks at <target>`, `faces <character|camera>`, `points at
<target>`, `nods`, `shakes head`, `dances`, `sleeps`, `smiles`,
`face <expression>`, `picks up <object>`, `gives <object> to
<character>`, `taps foot`. Objects are cue subjects too, with the
§2.8 core verbs: `bus moves to stop in 4 seconds ease out`.

All 20 stickman verbs resolve at compile time to key lists on the
plugin's 16 rig channels (`root.x/y/z`, `root.face`, `torso`,
`head.pitch/yaw`, `arm.l/fore`, `arm.r.upper/fore`,
`leg.l/thigh/shin`, `leg.r.thigh/shin`, `face.expr`) — the resolved
keys, not the verb name, are the Timeline IR contract. The §2.8 core
verbs (`spin`, `bob`, …) used **on a character** are *not* resolved
to keys: their tracks are emitted with `resolved: false` and are
evaluated by the engine's closed-form animation path instead.

**Custom actions** are defined once, like a `group`; inside the
block, **`it` is the actor**:

```f3d
action celebrate
  it jumps
  it waves both hands
  it spins speed 360
end

rafi does celebrate for 2 seconds
```

Cues inside play in order. `does <action> for N seconds` time-scales
the whole action to N seconds; without `for`, it takes the sum of
its cues' durations. Actions may use other actions; recursion is
error `E212`. Actions defined in an imported part file work through
the existing `import … as …` mechanism, so a shared `actions.f3d`
library is just a part file.

#### Camera cues

The shot's `camera at … look …` line is its opening framing; `look`
may also name a character or place. After that, the camera is
another cue subject:

```f3d
camera follows lloyd
camera zooms in on stall in 2 seconds ease smooth
camera zooms out in 1 second
camera pans to door in 3 seconds
camera orbits mira in 3 seconds
camera looks at bench in 1 second
```

`follows <character>` lasts until the next camera cue or the shot's
end; write it as a `with` cue to run it alongside an action. Camera
moves compile to keys on the reserved pseudo-target `@camera` in
the Timeline IR.

#### Dialogue, captions, titles

```f3d
lloyd says "Good morning, Mira!" for 2 seconds
mira says "The mangoes look fresh today!"
caption "Meanwhile, across town…" for 3 seconds
title "The Lost Key" for 3 seconds
```

- `<character> says "…"` — only characters speak (an object name is
  error `E211`). The text is an ordinary `.f3d` string, byte-verbatim
  in the IR, so Bengali (or any Unicode) dialogue needs no special
  syntax. With no written duration, the compiler estimates reading
  time (≈0.4 s/word, minimum 1.5 s) and says so — warning `W204`,
  never silent. Trailing variants: `bubble only`, `subtitle only`,
  `thinking` (thought bubble) are parsed and carried as the line's
  style.
- `caption "…"` is narrator text nobody speaks; `title "…"` is big
  centred screen text. Both are screen-space, distinct from the
  in-world `text` primitive (§2.2's Wave B features), and — by a
  decision recorded at the IR freeze — **captions and titles have
  no Timeline IR v1 record**: they live in the scene artifacts for
  Forge3D's own preview/export paths, and hosts do not receive
  them through the IR.
- **No voice or TTS is implied by `says`** — dialogue is timing,
  text and style only.
- Honest rendering note: the native engine's film mode does **not**
  draw speech bubbles or burned-in subtitles. Dialogue reaches the
  screen as the preview's subtitle overlay (Preview playback,
  below) and reaches files as the `.srt` sidecar (Export, below).

#### Scenes and transitions

In film mode the `scene` line gains one optional prop; the
transition belongs to the shot it **opens** and overlays that
shot's first cue (it does not add to the film's length):

```f3d
scene "market" background white transition fade 1 second
scene "home" background black transition dissolve 1 second
scene "park" transition cut
```

Values: `cut` (default), `fade`, `fade black`, `dissolve`, `slide
left|right`, `wipe`. In the engine, `fade` and `dissolve` are
rendered as post-render blends between the two shots; **`slide`
and `wipe` render as a cut**, with a note. (The transition *variant*
— `fade black`, `slide left` — is not carried in Timeline IR v1.)
The closing cue `fade out in 1 second` is usable as a `with` cue
over a film's final action.

#### Repeat blocks and `let`

The §2.5 prefix `repeat` (setup expansion) is untouched. Among
cues, one block form repeats *time*:

```f3d
repeat 2 times
  rafi taps foot for 1 second
end
```

Variables are one deliberately minimal form — a named literal,
scene-block scoped, immutable, defined before use (violations are
`E213`):

```f3d
let wait-time be 3 seconds
let hero-colour be blue
rafi sits on bench for wait-time
```

Values are numbers, durations, colours or names. No arithmetic, no
expressions.

#### Plugins: external packages

Character rigs, verb sets, prop schemas and capabilities are
declared by **plugins — external packages on disk**, never compiled
into the core. The core keeps only the loader, the registry and a
generic template interpreter (`docs/PLUGINS.md` is the design of
record, ADR-PLUGIN-1):

```
plugins/<id>/plugin.json
```

- Shipped packages: `plugins/stickman/` (the full verb set above,
  16 rig channels, all 20 parametric templates as data) and
  `plugins/humanoid/` — a **skeleton**: rig record, channels, verbs
  and the `speaks` capability, but no templates and no rig channels,
  so its actions stay unresolved by design.
- Search list: if `F3DC_PLUGIN_PATH` is **set**, its
  colon-separated entries, in order — the **empty string loads
  nothing**. If it is **unset**: `[<repo_root>/plugins, ./plugins]`.
  Nonexistent entries are skipped silently. The first package with
  a given id wins; a duplicate is skipped with warning `W205`.
- A malformed package (missing/unparseable `plugin.json`, directory
  name ≠ manifest `id`, unsupported package `format`, a verb naming
  a missing template, …) is skipped whole with one `W205` warning
  naming the directory and the reason — never a crash, never a
  partial registration.
- A film whose character belongs to a plugin that is not loaded
  fails cleanly with error `E214`, naming the character and, when
  the character carries one, the plugin id. With the stickman
  package present, output is byte-identical to the pre-external
  compiler; with it absent, non-film scenes and characterless
  films still build.

#### Preview playback

`f3dc preview <film.f3d>` (§3) plays a film, not just a still:

- **Transport bar:** play/pause, a frame-stepped scrub slider, and
  a `t / duration · frame N` readout. Playback uses the same JS
  timeline evaluator as the compiled viewer — there is no second
  timing implementation — and seeking is deterministic: the same
  `t` always shows the same frame.
- **`GET /__timeline`** serves the preview compile's Timeline IR
  verbatim (byte-identical to `f3dc build`'s `.timeline.json` for
  the same source), or a well-formed empty document for a still —
  never 404. The page polls `/__status` (600 ms) for recompiles.
- **Subtitle overlay:** the dialogue cue live at the current frame
  (half-open: live iff `start_frame ≤ f < end_frame`), with the
  speaker coloured from the IR character colour.
- **Action lanes:** per-character action spans, a dialogue lane and
  marker ticks under the transport; clicking a lane seeks.
- **Diagnostics drawer:** a collapsible panel rendering the
  `/__status` diagnostics (code, severity, `file:line:col`,
  message, help).
- **`#t=` hash:** the playhead persists across the save-reload loop
  in the URL hash (`#t=<seconds>`), so a reload after an edit
  resumes where you were.
- One limit, stated plainly: **multi-scene films do not preview.**
  The preview compiles a file as a single scene (it has never done
  `build`'s chunk splitting), so a two-scene film gets the error
  page plus the empty `/__timeline` document. Single-scene films
  preview fully.

#### Export: video and subtitles

- `render "name.mp4"` — in **film mode only**, an `.mp4` render
  name means "render the timeline and assemble video" through the
  `--video`/ffmpeg path below. (Outside film mode an `.mp4` name
  still writes PPM, as §2.9 says.)
- `--video <file.mp4>` (§3) with a film assembles the film's frames
  at the film fps, with transitions already rendered into the
  frames. **ffmpeg-absent behaviour:** if `ffmpeg` is not on
  `PATH`, the render still exits 0, the frame files are kept, no
  video is written, and a loud 3-line warning names ffmpeg, the
  kept frames and the exact assembly command. If ffmpeg runs and
  fails, the frames are kept and a note is printed (the Phase-8
  design). A frame *write* failure is a clean `error: failed to
  write …` with exit 1. A single-frame `--video` remains a no-op.
- **`.srt` sidecar:** `f3dc build` writes `<stem>.srt` beside the
  `.timeline.json` whenever the film has dialogue — one whole-film
  file, serialised from the same finalized dialogue list as the IR,
  frame times converted with exact integer rational arithmetic,
  text byte-verbatim with no speaker prefix. A film with no
  dialogue writes no `.srt`, and a stale sidecar from an earlier
  build is removed.

Worked film examples: the three scripts of `docs/ANIM-PLAN.md`
§1.10 ship as IR fixtures (`tests/ir/fixtures/saturday-market.f3d`,
`the-bus-is-late.f3d`, `the-lost-key.f3d`), and
`examples/anim-golden.f3d` is the pinned golden film (48 frames,
two scenes, a dissolve, a camera track — `docs/V4-GOLDENS.md`).


## 3. CLI reference: `f3dc`

```
bin/f3dc [--version] <command> …
f3dc <file.f3d>            # bare file = run; with no file, a single
                           # scene.f3d/main.f3d/*.f3d in cwd is discovered
```

Inputs to `check`/`build`/`run`/`fmt` may be `.f3d`, legacy `.json`, or
`.obj` files. `--json` (on `check`) prints diagnostics as JSON instead
of the default text form. (The native binary honours the `NO_COLOR`
and `F3DC_DEBUG` environment variables: diagnostics are coloured
when stderr is a TTY, unless `NO_COLOR` is set — present with any
value, including empty — and `F3DC_DEBUG=1` adds internal diagnostic
detail — one `debug: ` line per diagnostic with its code, severity,
span and message — after the normal text output; see
`compiler/REPLACEMENT.md`.)

| Command | Usage | Does |
|---|---|---|
| `new` | `f3dc new <name>` | Write `<name>.f3d` with the 3-line contract. Never overwrites (existing file → exit 3). |
| `check` | `f3dc check [--explain] [--json] <file>` | Validate only — no files written. `--explain` prints the desugared program summary; `--json` prints diagnostics as JSON. |
| `build` | `f3dc build [-o DIR] [--explain] [--force] <file>` | Compile to `build/` (default) — no native render. Incremental: a plain build whose inputs are byte-identical to the manifest recorded by the previous build (`.f3dc-manifest-<stem>` in the output directory) and whose outputs are all present is skipped and prints `up to date: <file> (manifest match)`. `--force` ignores the manifest check and always rebuilds (it still refreshes the manifest). |
| `run` | `f3dc run [-o DIR] <file>` | Build, compile the Fortran engine, render, report outputs and animation frames. |
| `fmt` | `f3dc fmt <file>` | Print the canonical `.f3d` form to stdout. |
| `preview` | `f3dc preview [--port N] [--no-browser] <file>` | Real-time preview: serve the viewer locally and watch the file — every save recompiles and open browser tabs reload themselves. A broken scene shows its diagnostics in the tab and recovers on the next good save. Default port 8765 (`0` = any free port). The preview page adds a toolbar with a LIVE/ERROR status pill and an FPS meter; orbit/zoom work as in the normal viewer. Tabs poll `/__version` to notice recompiles; `/__status` reports the current preview state as JSON. |
| `doctor` | `f3dc doctor` | Print version and check python / gfortran / make / convert (optional) / repo + engine sources, with fixes. |
| `profile` | `f3dc profile [-o DIR] <file>` | Build exactly as `build` does (always a full build — the incremental skip never applies) and print the per-stage compile timings, one line per stage in milliseconds: `parse`, `desugar`, `validate`, `emit`, `write`, and `total`. |

`build/` outputs for input stem `<stem>` (build never overwrites the
repo-root `scene.json` or `viewer.html`):

| File | Contents |
|---|---|
| `<stem>.json` | Scene JSON v2 (typed IR) |
| `<stem>.legacy.json` | Legacy v1 JSON for the old `viewer.html` |
| `<stem>.js` | Dependency-free JS module embedding the scene |
| `<stem>.html` | Single-file viewer (template + inlined scene + runtime), `file://`-safe |
| `<stem>_scene.f90` | Generated Fortran scene program |
| `<stem>.ppm` | (from `run`) native render; plus `<stem>_NNNN.ppm` frames for animations (`.png` instead when the render filename ends in `.png`) |

Engine flags and environment (the native renderer `f3dc run` drives;
the renderer-selection pair `--renderer` / `FORGE3D_RENDERER` is
covered in §2.10, and `FORGE3D_THREADS` there too):

| Flag / variable | Meaning |
|---|---|
| `--binary-ppm` / `FORGE3D_BINARY_PPM` | Write PPM output in binary `P6` form instead of the default ASCII `P3`. The flag wins over the variable; the variable accepts `1`/`true` or `0`/`false` (any other value is an error). |
| `--video <file.mp4>` | After a multi-frame render, assemble the numbered frame files into `<file.mp4>` with `ffmpeg` (libx264, yuv420p, at the scene fps). Needs `ffmpeg` on `PATH`: if it is missing or fails, a note is printed, the frame files are kept, no video is written, and the exit code is unchanged. Single-image renders are unaffected. |
| `FORGE3D_MAX_FRAMES` | Maximum frames in one render (default `100000`); a render needing more is refused with an error. Must be ≥ 1. |
| `FORGE3D_MAX_RESOLUTION` | Maximum frame size in pixels, width × height (default `268435456` = 16384×16384); a larger frame is refused with an error. Must be positive. |

Exit codes:

| Code | Meaning |
|---|---|
| 0 | success (warnings may still be printed) |
| 1 | scene errors (any `E…` diagnostic) |
| 2 | usage error |
| 3 | I/O error (missing input, unwritable output) |
| 4 | toolchain failure (gfortran/make/engine failed) |
| 70 | unexpected internal error |

Diagnostics look like `file.f3d:3:6: error E202: …` followed by the
offending line with a caret underline, a `why:` line, and a paste-ready
`help:` line. Typos get did-you-mean suggestions.


## 4. Error code index

Codes are stable and append-only (source of truth:
`compiler/src/f3dc_errors.f90`). Families: E1xx syntax, E2xx names, E3xx ranges,
E4xx structure, E5xx I/O, E8xx security/limits, Wxxx warnings.

| Code | Meaning |
|---|---|
| E101 | unexpected token |
| E102 | expected number |
| E103 | unterminated string |
| E104 | unknown statement |
| E110 | duplicate property |
| E201 | unknown name/target |
| E202 | unknown colour |
| E203 | unknown primitive |
| E204 | texture not in v1 |
| E205 | reserved keyword |
| E206 | unknown action |
| E207 | overlapping actions |
| E208 | timeline overrun |
| E209 | unknown character |
| E210 | camera follow target missing |
| E211 | dialogue for undefined character |
| E212 | custom-action recursion |
| E213 | undefined / redefined variable |
| E214 | plugin not loaded |
| E301 | value out of range |
| E302 | non-positive size |
| E303 | fov range |
| E401 | structure (group/end mismatch) |
| E402 | no objects |
| E501 | file not found |
| E502 | cannot write output |
| E504 | import cycle |
| E820 | security/limit violation |
| W101 | default injected |
| W102 | statement replaced |
| W201 | animation defaulted |
| W203 | unused action |
| W204 | dialogue duration estimated |
| W205 | plugin package skipped |


## 5. The JavaScript viewer

`f3dc build`/`run` generate a single-file HTML viewer per scene, and
`runtime/f3d.js` is the reusable player (zero dependencies). The
viewer boots **WebGL2-first**: the WebGL2 sidecar
(`runtime/f3d-webgl2.js`) tries a WebGL2 context and, when WebGL2 is
unavailable, the viewer falls back to the Canvas2D core player
(`runtime/f3d.js`) with the identical API. There is **no WebGL1
path**. Embed it yourself:

```html
<script src="f3d.js"></script>
<f3d-view src="scene.json"></f3d-view>
<!-- or, with an inline scene: -->
<script>window.F3D_SCENE = { /* scene JSON v2 */ };</script>
<f3d-view></f3d-view>
```

- `<f3d-view>` — custom element. With a `src` attribute it fetches that
  scene JSON (http(s) only — `fetch` does not work from `file://`, which
  is why the generated HTML inlines its scene instead); without `src` it
  uses `window.F3D_SCENE`. The generated `<stem>.html` needs no server.
- `F3D.create(target, scene)` — `target` is a canvas or container
  element; returns a player with `play()`, `pause()`, `setTime(t)`,
  `render(t?)`, and `destroy()`. Also exposed: `F3D.auto(scene)` (finds
  the first `<f3d-view>`/canvas and creates a player) and
  `F3D.version` (`"4.0.0"`). TypeScript declarations: `runtime/f3d.d.ts`.
- Orbit controls are built in: drag to orbit, wheel to dolly, touch-drag
  on mobile — honouring the scene's `controls` line (§2.7). Shading is
  Lambert, matching the native renderer, and animation uses the same
  closed-form `f(t)` as §2.8.


## 6. Honest comparison notes

Only these claims are made — each is measurable:

- **Lines to first 3D:** the rotating cube is 3 lines of `.f3d`
  (`cube red` / `spin it` / `render`); the render loop and resize
  handling are 0 lines, because the compiler and runtime own them.
- **Runtime size:** the JS player budget is ≤ 15,360 bytes minified,
  CI-enforced (current `runtime/f3d.min.js`: 12,460 bytes).
- **Zero-config:** camera, light, background, size, and framing all have
  the §1 defaults; an empty-ish file renders a good scene instead of a
  black canvas, and mistakes are friendly compile errors, not silence.
- **Deterministic native render:** same `.f3d` + same `t` ⇒ byte-identical
  PPM, offline, with no browser, GPU, or JavaScript involved.

Explicitly **not** claimed: any FPS or render-speed win over GPU WebGL
(native CPU rendering vs GPU rendering is not comparable), any bundle
ratio that has not been measured on pinned files, and feature parity
for anything not yet verified in the parity matrix.


## 7. Limits and what's next

Security/robustness limits (P26; violations are `E820` unless noted):

| Limit | Value |
|---|---|
| `.f3d` source size | 1 MiB |
| Line length | 4,096 characters |
| Nesting depth | 16 (groups themselves: 1 level) |
| `repeat` count | ≤ 1,000 per statement |
| Total placements (after expansion) | ≤ 10,000 |
| Triangles per scene | ≤ 1,000,000 |
| OBJ file | ≤ 64 MB, ≤ 500,000 faces |
| Declarative only | `system` / `eval` / `import` are rejected (`E820`); paths must stay inside the scene tree (symlink containment); toolchain calls are argv-only |

What's next — parity waves from the Master Plan (§3–§4), in order.
Nothing in the parity matrix is cut; features land wave by wave and are
only claimed once verified:

- **Wave A** — textures/UV, point & spot lights, real shadow maps, fog,
  tone mapping, PBR (`material standard`).
- **Wave B** — glTF/GLB loading, full keyframe animation, raycasting /
  picking, sprites, text, particles.
- **Wave C** — post-processing/filters, orthographic camera, true
  instancing, multi-scene.
- **Continuous** — remaining geometries and beyond, until the
  Three.js/PixiJS parity matrix is 100% implemented and tested.
