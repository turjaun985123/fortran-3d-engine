# Forge3D User Manual

Forge3D compiles a tiny declarative language (`.f3d`) into a 3D scene,
renders it natively with a deterministic Fortran software renderer, and
emits a dependency-free JavaScript/WebGL viewer for the same scene.
Compiler: `f3dc` — native (Fortran modules plus a clang C helper,
sources in `compiler/`), built with `make -C compiler` and installed as
`bin/f3dc` by `make f3dc`. Building it requires flang-18 (binary
`flang-new-18`) and clang-18; the compiler itself has no Python
dependency. Version: `f3dc 0.1.0`.

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

```f3d
cube lambert_cube red at -3 1 0 size 2 material lambert
sphere basic_ball #FF8800 at 3 1 0 radius 1 material basic
cylinder phong_pillar rgb 60 220 120 at 3 -2 0 radius 1 height 3 material phong
```

Textures are **not** in v1: a `texture` property is a loud diagnostic (`E204`).

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

`group name {prop} … end` — one level only (no nested groups). Group
props (e.g. `at`, `rotate`, `scale`) apply to every child; groups are
flattened at compile time, and a group name is a valid animation target.
A missing or stray `end` is error `E401`.

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
| `ease name` | `linear` | easing curve name (e.g. `linear`) |
| `loop once\|forever\|pingpong\|repeat(N)` | `forever` | bare `loop` means `forever` |

Animation is closed-form `f(t)`: same `t` ⇒ same pose natively and in JS; frame 0 is the still.

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
- `export (json|obj|html) [ "path" | to "path" ]` — additional outputs
  alongside the render.

Worked examples shipped in `examples/`: `hello-cube.f3d` (the contract),
`multi-object.f3d` (group/repeat/load/controls), `animated.f3d`
(spin/bob/pulse, 320×240, 2 s at 15 fps = 30 frames), `materials.f3d`
(lambert/basic/phong, all three colour spellings), `geometries.f3d`
(every Wave D geometry, §2.2).


## 3. CLI reference: `f3dc`

```
bin/f3dc [--version] <command> …
f3dc <file.f3d>            # bare file = run; with no file, a single
                           # scene.f3d/main.f3d/*.f3d in cwd is discovered
```

Inputs to `check`/`build`/`run`/`fmt` may be `.f3d`, legacy `.json`, or
`.obj` files. `--json` (on `check`) prints diagnostics as JSON instead
of the default text form. (The Python compiler's `NO_COLOR` and
`F3DC_DEBUG` environment variables are not read by the native binary;
see `compiler/REPLACEMENT.md`.)

| Command | Usage | Does |
|---|---|---|
| `new` | `f3dc new <name>` | Write `<name>.f3d` with the 3-line contract. Never overwrites (existing file → exit 3). |
| `check` | `f3dc check [--explain] [--json] <file>` | Validate only — no files written. `--explain` prints the desugared program summary; `--json` prints diagnostics as JSON. |
| `build` | `f3dc build [-o DIR] [--explain] <file>` | Compile to `build/` (default) — no native render. |
| `run` | `f3dc run [-o DIR] <file>` | Build, compile the Fortran engine, render, report outputs and animation frames. |
| `fmt` | `f3dc fmt <file>` | Print the canonical `.f3d` form to stdout. |
| `preview` | `f3dc preview [--port N] [--no-browser] <file>` | Real-time preview: serve the viewer locally and watch the file — every save recompiles and open browser tabs reload themselves. A broken scene shows its diagnostics in the tab and recovers on the next good save. Default port 8765 (`0` = any free port). The preview page adds a toolbar with a LIVE/ERROR status pill and an FPS meter; orbit/zoom work as in the normal viewer. Tabs poll `/__version` to notice recompiles; `/__status` reports the current preview state as JSON. |
| `doctor` | `f3dc doctor` | Print version and check python / gfortran / make / convert (optional) / repo + engine sources, with fixes. |

`build/` outputs for input stem `<stem>` (build never overwrites the
repo-root `scene.json` or `viewer.html`):

| File | Contents |
|---|---|
| `<stem>.json` | Scene JSON v2 (typed IR) |
| `<stem>.legacy.json` | Legacy v1 JSON for the old `viewer.html` |
| `<stem>.js` | Dependency-free JS module embedding the scene |
| `<stem>.html` | Single-file viewer (template + inlined scene + runtime), `file://`-safe |
| `<stem>_scene.f90` | Generated Fortran scene program |
| `<stem>.ppm` | (from `run`) native render; plus `<stem>_NNNN.ppm` frames for animations |

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
| E301 | value out of range |
| E302 | non-positive size |
| E303 | fov range |
| E401 | structure (group/end mismatch) |
| E402 | no objects |
| E501 | file not found |
| E502 | cannot write output |
| E820 | security/limit violation |
| W101 | default injected |
| W102 | statement replaced |
| W201 | animation defaulted |


## 5. The JavaScript viewer

`f3dc build`/`run` generate a single-file HTML viewer per scene, and
`runtime/f3d.js` is the reusable player (WebGL1, zero dependencies,
Canvas-2D fallback with the identical API). Embed it yourself:

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
  `F3D.version` (`"1.0.0"`). TypeScript declarations: `runtime/f3d.d.ts`.
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
