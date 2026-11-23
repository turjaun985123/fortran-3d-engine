# Forge3D browser runtime

How the JavaScript runtime in `runtime/` is laid out, how big it
honestly is, how it is built for the generated viewer, and how it is
kept in agreement with the Fortran engine.

## Honest size: the total, not the core

The historical mistake (finding J3) was quoting the size of the core
file as if it were the whole runtime. The core is only one of
fifteen files a full viewer loads.

**Total runtime: 139,928 bytes (unminified)** — the sum of
`runtime/f3d.js` plus every `runtime/f3d-*.js` sidecar:

| File | Bytes | Role |
|---|---:|---|
| `runtime/f3d.js` | 22,100 | Core (`f3d-core`): Canvas2D player, scene normalisation, base geometry builders, animation evaluation, `create()` / `auto()` / `worldTris()`, the `<f3d-view>` element |
| `runtime/f3d-webgl2.js` | 17,962 | WebGL2 GPU rasterisation sidecar for the triangles the core produces |
| `runtime/f3d-geo.js` | 19,790 | Extra geometry builders: circle, ring, capsule, tube, lathe, extrude, Platonic solids, torus-knot, `triCount` |
| `runtime/f3d-instanced.js` | 12,375 | Instancing: one shared base geometry plus per-instance transforms (mirror of `src/instancing.f90`) |
| `runtime/f3d-pbr.js` | 8,507 | PBR shading: Cook–Torrance GGX / Smith–Schlick / Fresnel–Schlick, light attenuation and spot falloff |
| `runtime/f3d-shader.js` | 7,571 | Custom shaders: CPU evaluation of the same RPN token stream the Fortran shader module uses (no GLSL) |
| `runtime/f3d-sprites-text.js` | 7,088 | Sprites / billboards and 5×7 bitmap text (mirrors of `src/sprite.f90`, `src/text_render.f90`) |
| `runtime/f3d-xr.js` | 6,665 | WebXR: immersive-vr session, reference space and stereo views, behind feature detection |
| `runtime/f3d-post.js` | 6,433 | Post-processing: ordered screen-space filter chain applied to a finished frame |
| `runtime/f3d-env.js` | 6,010 | Environment: fog factors / blending and tonemapping (mirrors of `src/fog.f90`, `src/tonemapping.f90`) |
| `runtime/f3d-skin.js` | 5,824 | Skinning and morph targets over flat vertex arrays |
| `runtime/f3d-particles.js` | 6,081 | Deterministic seeded particle emitter; state is a pure function of `(system, index, t)` |
| `runtime/f3d-raycast.js` | 4,894 | Raycasting / picking: Möller–Trumbore ray–triangle intersection (mirror of `src/raycast.f90`) |
| `runtime/f3d-keys.js` | 4,244 | Keyframes: position / rotation / scale tracks, named easing, once / forever / pingpong looping |
| `runtime/f3d-ortho.js` | 4,384 | Orthographic camera projection (mirror of `src/camera_ortho.f90`) |
| **Total** | **139,928** | **Core + all 14 sidecars** |

Not counted in the total, and why:

- `runtime/f3d.min.js` (15,335 bytes) is the minified form of the
  **core only** — an alternative copy of `f3d.js`, not an additional
  module. Counting it alongside `f3d.js` would double-count the core.
  The old "≤ 15 KB runtime" claim referred to this file alone.
- `runtime/f3d.d.ts` (1,965 bytes) is hand-written TypeScript types;
  it is not loaded by a viewer.

Sizes move as modules change. The figure above is a snapshot; the
authoritative, current number is the size report printed by
`tools/build_runtime.mjs` (below), which recomputes the same sum.

## ES module layout

Each runtime file is authored as an ES module (Phase 7) with named
exports for its public API:

- `runtime/f3d.mjs` is the **aggregator**: it re-exports the public
  names of the core and the sidecars from one entry point, so an ES
  consumer imports the whole runtime with a single
  `import { … } from './runtime/f3d.mjs'`.
- The per-module files (`runtime/f3d.js` and `runtime/f3d-*.js`,
  table above) stay individually importable. A consumer that only
  needs, say, raycasting or keyframes can import that one module
  instead of the aggregator.
- Modules are zero-dependency and, unless their header says
  otherwise, import nothing from their siblings: shared behaviour is
  reached through the core's published surface, not by reaching into
  another sidecar. Several sidecars are also usable standalone, as
  noted in their file headers.

## Per-module budgets: `runtime/module-budgets.json`

`runtime/module-budgets.json` records a byte budget for every runtime
module (core and each sidecar). The build checks every module
against its budget and fails if any module is over.

**Ratchet rule:** a budget may only ever move **down**. When a module
shrinks, its budget is lowered to match (plus any explicitly recorded
headroom), so the saving is locked in; a budget is never raised to
accommodate growth. Growth inside an existing budget is allowed;
growth that needs a bigger budget is not — shrink the module, split
it, or get the increase reviewed as a deliberate exception rather
than editing the number up silently. The total runtime size is the
sum of the modules, so the ratchet is what keeps the total honest
over time instead of drifting up file by file.

## Building the viewer bundle: `tools/build_runtime.mjs`

`tools/build_runtime.mjs` (Node, no dependencies) does two things:

1. **Size report** — measures every runtime module, checks each one
   against `runtime/module-budgets.json`, and prints the per-module
   sizes and the **total** runtime size (the same sum as the table
   above). This is the number to quote.
2. **Classic bundle** — concatenates the ES modules into a classic
   (non-module) script bundle for the generated viewer. The
   generated HTML viewer cannot rely on ES-module loading in every
   context it is opened from (including `file://`), so the compiler
   inlines the classic bundle into the page produced from
   `compiler/viewer_template.html`.

## Compatibility footer: `globalThis.F3D`

ES modules alone would break existing consumers: generated viewers,
checked-in pages, and tests were written against classic globals
such as `window.F3D` and `window.Forge3DWebGL2`. Every module
therefore ends with a **compatibility footer** following one pattern:

1. The module's real implementation is defined once, and its public
   names are declared as named ES exports — no logic is duplicated
   for the global form.
2. The footer attaches **those same function objects** onto a
   namespace on `globalThis`, creating the namespace if absent —
   for the core, `globalThis.F3D` (e.g. `globalThis.F3D.create`,
   `.auto`, `.worldTris`, `.version`); sidecars attach their API to
   their own namespace (e.g. `F3DEnv`, `F3DKeys`, `F3DPost`,
   `Forge3DWebGL2`) and, where they extend the core, register into
   `globalThis.F3D` as well.
3. Where a `window` exists the same namespace is mirrored onto it,
   and where a CommonJS `module` exists it is assigned to
   `module.exports`, so classic scripts, browsers, and Node test
   harnesses all see the identical API.

Net effect: `import` it as a module, or load the classic bundle and
use the global — both paths run the same code.

## Viewer boot order (finding J2)

Generated viewers boot **WebGL2-first**:

1. The viewer tries the WebGL2 sidecar (`f3d-webgl2.js`, via
   `F3D.worldTris` from the core) when WebGL2 is available and the
   scene is eligible.
2. If WebGL2 is unavailable or fails to start, it **falls back to
   the Canvas2D core player** (`F3D.create` / `F3D.mount` in
   `f3d.js`).
3. If neither path can start, the page shows its fallback message
   instead of a silent black canvas.

There is **no WebGL1 path** and no WebGL1 fallback: the core player
is Canvas2D by design (it renders with the same math as the Fortran
engine, so stills are deterministic and match native output), and
WebGL2 is the only GPU path. Older wording that described the player
as "WebGL1" was stale and has been removed.

## Shared Fortran ↔ JS math vectors

Engine and runtime must not drift apart mathematically, so they are
tested against **one shared fixture file**:
`tests/fixtures/math_vectors.json`. Each entry names a case, its
kind (`euler_quat_euler`, `axis_angle_mat4_vec3`, `slerp`,
`mat4_inverse`, `mat3_inverse`, …), its inputs, and the expected
outputs (quaternions in `[x, y, z, w]` order, rotated vectors,
inverse matrices, determinants).

The same file is consumed by both sides:

- **Fortran:** `tests/fortran/test_math_quat.f90` reads the fixture
  and checks the engine's quaternion / matrix code
  (`src/math_3d.f90`) against every expected value.
- **JavaScript:** `test_math_vectors_js.js` reads the same fixture
  and checks the runtime's math against the same expected values.

A formula changed on only one side therefore fails on that side
against the shared expectation, instead of the two implementations
silently diverging. New math behaviour gets a new fixture entry
first, then implementations on both sides to match it.
