# Forge3D — 3D in 3 lines

Write a scene in plain words, compile it, and render it — natively, offline,
with no boilerplate.

```f3d
cube red
spin it
render
```

That is the whole program (`examples/hello-cube.f3d`): a red cube, spinning,
rendered with a sensible default camera, light, scene size, and background —
none of which you had to write.

## Run it

```bash
make
make f3dc   # build the native compiler and install it as bin/f3dc
bin/f3dc run examples/hello-cube.f3d
```

Prerequisites: `gfortran` and `make` for the engine, plus `flang-18`
(binary `flang-new-18`) and `clang-18` for the compiler. The compiler is
native (Fortran + a clang C helper, sources in `compiler/`) and has no
Python dependency.

## What you get

- **A native PPM render** — produced by the Fortran renderer in `src/`,
  no browser, GPU, or JavaScript needed.
- **A standalone HTML viewer** — a single self-contained page you can open
  in a browser to orbit and inspect the same scene.
- **`scene.json`** — the compiled scene in JSON form, alongside the other
  build outputs (by default under `build/`).

## A slightly bigger scene

Abbreviated from `examples/multi-object.f3d`:

```f3d
scene multi size 800 600 bg black
camera at 0 5 12 look 0 0 0 fov 60
cube hero red at -4 0 0 size 2
sphere orb blue at 0 1 0 radius 1
cylinder tower green at 4 0 0 radius 1 height 3
group duo
  cone hat orange at -2 0 3 radius 1 height 2
  pyramid peak purple at 2 0 3 size 2 height 2
end
repeat 3 torus ringlet pink at -3 -2 -2 radius 1
load "../model.obj" imported at 0 0 -5
controls orbit
render "multi-object.ppm"
```

More scenes live in `examples/`: `animated.f3d` and `materials.f3d`, as well
as the two shown above.

## Features

- **7 primitives, one word each:** `cube`, `sphere`, `cylinder`, `plane`,
  `pyramid`, `cone`, and `torus` — every parameter has a default.
- **Materials:** `lambert` (the default, lit), `basic` (flat, unlit), and
  `phong` (specular highlights) — e.g. `material phong` on an object line.
- **Animation:** declarative verbs such as `spin`, `bob`, and `orbit` —
  no render loop, clock, or resize code in your program.
- **Groups and repetition:** `group … end` blocks, plus `repeat` (and
  grid/ring forms) to place many objects without copying lines.
- **OBJ loading:** `load "model.obj"` puts an existing model in the scene
  in one line.
- **A tiny JS runtime:** `runtime/f3d.min.js` is at most 15 KB minified
  (≤ 15,360 bytes, enforced by the build) for playing scenes on the web.
- **Friendly compiler errors:** mistakes come back as located diagnostics
  with an explanation and a suggested fix — not a blank or black canvas.

## Honestly better — only what we can measure

These are the claims made in `docs/plan/MASTER-PLAN.md` §5, and only these:

- **Fewer lines:** the rotating cube takes 3 lines here (the same task was
  hand-counted at 23 lines in a standalone Three.js program); loading an
  OBJ takes one `load` line; the render loop and resize handling take
  0 lines, because the compiler and runtime own them.
- **Smaller runtime:** the JS player is ≤ 15,360 bytes minified,
  CI-enforced — far smaller than a full Three.js build.
- **Zero-config:** camera, light, scene size, background, and framing all
  have defaults, so `cube` alone renders a lit, framed scene instead of
  nothing.
- **No silent black screens:** a missing camera, a bad colour, or a missing
  asset is a friendly compile error, not a black canvas at runtime.
- **Deterministic offline render:** the same `.f3d` file at the same time
  `t` produces a byte-identical PPM, with no browser, GPU, or network
  required.

No frame-rate claims are made: the native renderer is a CPU renderer, and
speed against GPU WebGL is not a comparison we claim to win.

## CLI at a glance

Invoke it as `bin/f3dc <command> …` (build and install it first with
`make f3dc`):

| Command | What it does |
|---|---|
| `new` | Create a new `.f3d` scene from the starter template |
| `check` | Validate a scene only — no files written |
| `build` | Compile a scene to `build/` (Fortran + JSON + JS + HTML) |
| `run` | Build, compile the engine, and render |
| `fmt` | Print the canonical `.f3d` form of a scene |
| `preview` | Serve the compiled viewer locally, watch the scene file, and recompile + reload the browser on every save |
| `doctor` | Check the python / gfortran / make / convert toolchain and print fixes |

## Repository structure

```
.
├── src/            # Fortran engine: math, meshes, camera, materials,
│                   # scene loading, animation, OBJ loading, renderer
├── compiler/       # The f3dc compiler, native: Fortran modules + a
│                   # clang C helper; `make -C compiler` builds it,
│                   # `make f3dc` installs it as bin/f3dc
├── runtime/        # Tiny JS runtime: f3d.js, f3d.min.js, f3d.d.ts
├── examples/       # .f3d scenes: hello-cube, multi-object, animated,
│                   # materials
├── tests/          # Compiler, Fortran, golden-image, and end-to-end tests
├── docs/           # Documentation, including docs/plan/
├── Makefile        # Build, test, and runtime-minification targets
├── model.obj       # Sample OBJ model used by the examples
├── scene.json      # Checked-in sample compiled scene
└── viewer.html     # Checked-in legacy HTML viewer
```

## Testing

```bash
make test
```

This runs `tests/run_tests.sh` (POSIX shell; the harness is shell +
Fortran + Node — there is no Python anywhere in this repo), covering
the native-compiler black-box tests, the JS runtime tests, the Fortran
tests, the golden-image checks, and the end-to-end CLI tests.

## Roadmap

Forge3D is being built toward full Three.js / PixiJS feature parity in
waves — lighting and materials, assets, sprites and text, post-processing,
and more. The parity matrix, the wave plan, and the current status of every
feature live in `docs/plan/MASTER-PLAN.md`.

---

## Legacy engine

Forge3D stands on the original Fortran 3D engine in this repository: a
modular software renderer written in modern Fortran (2008/2018) with a
vector/matrix library, triangle meshes, a perspective camera, a barycentric
rasterizer with a Z-buffer, Lambertian shading, and PPM export. That
renderer is still the native engine under `src/` — Forge3D is the language,
compiler, and runtime built around it.
