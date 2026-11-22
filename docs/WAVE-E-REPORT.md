# Forge3D — Wave E Report (continuous extras C2 → C1 → C3 → C4, seats E01–E14 + F1/F2)

Wave E scope per `docs/WAVE-D-REPORT.md` launch spec and
`docs/plan/MASTER-PLAN.md` §3 continuous rows: the last four
parity items — C2 custom shaders, C1 skinning + morph targets,
C3 WebGL2 runtime, C4 XR — each implemented AND tested in-wave
(G5), in the order C2 → C1 → C3 → C4.

**Verdict: C2, C1 and C3 Done-verified. C4 implemented and
headless-verified, but its row stays Blocked on the one thing
this VM cannot do — a real immersive session on XR hardware
(exact unblock condition below). Coverage: core §3 matrix
36/36 = 100.0 % (unchanged); with continuous extras 39/40 =
97.5 %. All gates green (below). Committed locally; no GitHub
push. Strict golden byte-identical — NO re-baseline.**

## Agent counts (actual runs, parallel ceiling 10)

| Batch | Seats | Runs |
|---|---|---|
| Batch 1 | E01 compiler shaders, E02 Fortran shader eval, E03 renderer shader path, E04 JS shaders, E05 Fortran skinning, E06 compiler skin, E07 JS skin, E08 WebGL2, E09 XR, E10 showcase + manual | 10 |
| Batch 2 | E11 parity, E12 e2e, E13 WebGL2 Lambert fix | 3 |
| Fix wave | F1 Fortran bulge correction, F2 JS bulge correction | 2 |
| Batch 3 | E14 coverage (B85/B86) | 1 |
| **Total child runs** | | **16** |

Plus coordinator wiring (the Wave D pattern — seats own new
files, the coordinator owns shared files): `Makefile`
(shader/skinning objects + deps), `tools/f3dc/parser.py`
(`shader`/`morph`/`bone`/`skin` statements + object `shader`
prop), `tools/f3dc/validate.py` (wavee IR block in
`scene.extensions["wavee"]`, E201/E301 diagnostics),
`tools/f3dc/emit_fortran.py` (wavee `.scene` lines),
`src/scene.f90` (`shaderdef`/`shaderbind`/`morph`/`bone`/`skin`
line parsing + post-parse resolution by name),
`src/main.f90` (shader render dispatch on the plain, keyframe
and env paths).

## C2 — Custom shaders: Done-verified

The easy surface (one line to define, one word to bind):

```f3d
shader checker expr "c * step(0.5, fract((x + y) * 2))"
cube checkered red shader checker
```

- **Language:** a small safe expression language over
  `c r g b x y z u v ndl t pi` with `+ - * / % ^`, unary minus,
  parentheses, and functions sin cos tan abs sqrt floor ceil
  fract (1-arg), min max step pow (2-arg), clamp mix (3-arg).
  `f3dc` compiles it to RPN string tokens
  (`tools/f3dc/ext_shader.py`); the `.scene` carries
  `shaderdef NAME N tok…` + `shaderbind OBJ SHADER`.
- **Execution, identical in both backends:** Fortran
  `src/shader.f90` (stack evaluator) + the new per-pixel
  `framebuffer_render_mesh_shader` in `src/renderer.f90`
  (pure additions — 199 insertions, 0 deletions; world position
  barycentric-interpolated, `u`/`v` = barycentric weights,
  `ndl` = per-triangle Lambert diffuse). JS mirror
  `runtime/f3d-shader.js` evaluates the same RPN. Semantics
  guards are frozen and identical: division/modulo by zero → 0,
  invalid `pow` domain → 0 (0^0 = 1), `sqrt` of negative → 0,
  `fract(x) = x − floor(x)`, `step(edge,x) = x>=edge ? 1 : 0`.
  The shader result **replaces** the channel value (clamped
  0..1); lighting is the user's choice via `ndl` — there is no
  silent Lambert fallback.
- **Honesty proof (user code changes pixels, asserted):**
  `test_shader_render.f90` 16/16 — identity shader `c`
  reproduces the unlit flat render pixel-for-pixel (0 differing
  pixels); constant `0.5` → every covered pixel exactly 128;
  shader `0` → every covered pixel black; checker → ≥ 2
  distinct values. E2E: three renders (`c` / `0` / no shader)
  pairwise-different hashes; shader `c` == `material basic`
  render **byte-identical**.
- **Tests:** `test_shader.f90` 69/69 (every function, guards,
  parse errors), `test_ext_shader.py` 65 (RPN precedence,
  arity, every error class, exact emission),
  `test_f3d_shader_js.py` 7 (59-case value grid vs an
  independent Python implementation, 1e-9), parity in
  `test_wavee_parity.py` (exact `shaderdef`/`shaderbind`
  lines; unknown shader → E201, unknown function → E301).

## C1 — Skinning + morph targets: Done-verified

The easy surface (named bones/morphs, one weight concept):

```f3d
sphere bulgy green radius 1
morph bulgy bulge 0.5
cylinder pillar yellow radius 0.7 height 3
bone spine at 2.5,0,0 rotate 0,0,30 radius 3
skin pillar spine
```

- **Morphs** (`src/skinning.f90` `morph_apply`, JS mirror
  `runtime/f3d-skin.js`): `bulge` (barrel profile: x/z scale
  `s = 1 + factor·0.5·(1 − q²)`, `q = (y − cy)/halfh` —
  strongest at the middle height, poles unchanged), `taper`
  (x/z scale `1 − factor·0.5·h` by normalized height),
  `squash` (y `1 − 0.5·factor`, x/z `1 + 0.25·factor`).
  Factor 0 is a bit-exact identity for every kind.
- **Skinning** (linear blend): per-vertex weight
  `w = smoothstep(clamp(1 − dist_to_pivot/radius, 0, 1))`;
  skinned position `(1−w)·p + w·(M·p)` with
  `M = T(pivot)·Rz·Ry·Rx·T(−pivot)`. Vertices at/beyond
  `radius` are bit-identical to the input; a vertex at the
  pivot follows `M` exactly. `.scene` lines: `morph OBJ KIND
  FACTOR`, `bone NAME px py pz rx ry rz radius`,
  `skin OBJ BONE` (`tools/f3dc/ext_skin.py`).
- **Tests proving vertices actually move per weights/factors:**
  `test_skinning.f90` 33/33 (analytic bulge/taper/squash
  values; on a real sphere the equator scales by exactly
  `1 + 0.5·factor`; `skin_weight` 1 / 0.5 / 0 at
  0 / radius÷2 / radius; partial-weight vertex equals the
  `(1−w)/w` blend), `test_ext_skin.py` 47,
  `test_f3d_skin_js.py` 16 (JS vs Python reference, 1e-9),
  e2e: morph factor 0 byte-identical to no-morph; skin with a
  zero-rotation bone byte-identical to unskinned; skin at 30°
  differs; sphere bulge render 17,548 → 32,625 non-bg px.
- **In-wave correction (F1/F2):** the first bulge formula was
  radial (`1 − (d/maxr)²`); E12 caught that every sphere
  vertex sits at `d == maxr`, making bulge a silent no-op on
  spheres — including in the showcase. The formula was
  replaced with the barrel profile above in Fortran, JS, the
  compiler docstring and both test references, and re-proven.
  The manual's plain-language description ("most strongly
  around its middle (equator)") matched the new profile
  unchanged.

## C3 — WebGL2 runtime: Done-verified (headless-provable scope)

- `runtime/f3d-webgl2.js` (12,522 B raw): GLSL ES 3.00
  shaders (`#version 300 es`, `aPos`/`aColor`/`uMVP`),
  feature-detected `getContext('webgl2')` with `attach()`
  reporting `'webgl2'` or `'canvas2d'` so the core runtime
  remains the fallback; `DEPTH_TEST` on; matrix convention
  identical to the Fortran `mat4` (column-major flat 16,
  translation at 12/13/14, same perspective-divide guard).
- **Same-image basis:** after fix seat E13, `renderScene`
  shades each triangle with the core runtime's exact Lambert
  (`0.25 + 0.75·max(0, −dot(n, ld))`, default light
  (−0.5,−1,−0.7); `flat: true` opts out), so the WebGL2 path
  produces the core's colours, not raw face colours.
- **Tests:** `test_f3d_webgl2_js.py` 15/15 — mock-GL call
  verification (shader sources passed verbatim, buffer
  Float32Array lengths = tris×9 positions + tris×9 colours,
  `uniformMatrix4fv` 16 elements, `drawArrays` = tris×3,
  depth test enabled), `projectPoint` vs Fortran-convention
  expectations within 1e-9 (identity / translation /
  perspective), Lambert colour parity vs a Python mirror
  within float32 tolerance, back-face = exactly
  ambient × colour, fallback returns `'canvas2d'` on null GL.
- **Stated limit (in the file header and the matrix
  evidence):** real GPU rasterization in a browser is not
  exercised on this VM (no browser/GPU). The verified claim
  is API/plumbing + transform + shading-colour parity.

## C4 — XR: implemented + headless-verified; row **Blocked**

- `runtime/f3d-xr.js` (6,003 B raw): `window.Forge3DXR` —
  `isSupported()` (dynamic `navigator.xr` detection),
  `requestVRSession()` (`immersive-vr`,
  `optionalFeatures: ['local-floor','bounded-floor']` merged
  with caller options, `'end'` listener clears state),
  `requestReferenceSpace()` (tries `local-floor` → `local` →
  `viewer` in order), `stereoViews(frame, refSpace)` (per-view
  projection/view matrices + viewports; view matrix from
  `view.transform.inverse.matrix` when supplied, else the
  file's own Gauss-Jordan 4×4 inverse), `endSession()`,
  `shouldFallback()`. Nothing throws; every failure resolves
  to `false`/`null`/`[]` and the normal render path proceeds.
- **Tests:** `test_f3d_xr_js.py` 9/9 with mock
  `navigator.xr`/session/frame objects — no-XR grace,
  unsupported grace (requestSession never called), supported
  plumbing (mode + features asserted), reference-space
  attempt order recorded and asserted, two-view stereo output
  with exact inverse checks, end-event state clearing.
- **What is NOT proven, plainly:** a real immersive session
  on XR hardware — session creation, tracking, reference
  spaces and presentation on a headset — cannot be run on
  this VM (no XR device, no browser). **Unblock condition:
  the user loads a page using `runtime/f3d-xr.js` on a real
  XR device and confirms an `immersive-vr` session starts
  and presents; on that confirmation the C4 evidence is
  updated and the row flips to Done-verified (40/40).**
  Until then the row is recorded `Blocked`, not
  Done-verified — no fake parity.

## Showcase + docs

- `examples/wavee-showcase.f3d` — two differently-shaded
  objects (checker + sine stripes), a bulged sphere, a
  skinned cylinder; e2e-verified: deterministic (two runs →
  identical sha256), 20,031 non-bg px, 397 distinct colours.
- `docs/wavee-manual.md` — manual chapter §8 covering all
  four features with the easy forms, semantics in plain
  language, and the honesty limits (shader guards, morph/skin
  formulas, WebGL2 fallback, XR device boundary).

## JS sizes (raw bytes)

Core `runtime/f3d.js` **unchanged**: 15,701 B raw, minified
12,486 B vs the 15,360 B budget — within budget. New Wave E
sidecars: `runtime/f3d-shader.js` 7,002 B,
`runtime/f3d-skin.js` 5,229 B, `runtime/f3d-webgl2.js`
12,522 B, `runtime/f3d-xr.js` 6,003 B.

## Gates — exactly as run (final run, on the committed tree)

- `make clean && make` — **PASS** (33 modules incl. new
  `shader_3d` + `skinning_3d`; clean link of `bin/engine3d`,
  0 errors).
- `python3 tests/run_tests.py` — **RESULT: PASS**: compiler
  PASS (incl. Wave E: ext_shader 65, ext_skin 47, shader JS 7,
  skin JS 16, WebGL2 JS 15, XR JS 9, Wave E parity 16/16),
  e2e PASS (incl. Wave E e2e 10/10), Fortran PASS (29 test
  programs incl. test_shader 69/69, test_shader_render 16/16,
  test_skinning 33/33), golden layer SKIP by design (strict
  check below is binding).
- **Strict golden — PASS, no re-baseline:** legacy no-arg
  engine run sha256 =
  `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`
  (re-verified on the final binary; shader/skinning/WebGL2
  work changes no default render — the shader path is only
  taken for shader-bound objects, morph/skin only on their
  `.scene` lines).

## Coverage (B85 generator + B86 test, recomputed this wave)

**§3 core matrix: 36/36 Done-verified = 100.0 %** (unchanged).
**Including the continuous extras: 39/40 = 97.5 %** (was
90.0 %). Generator output: `Done-verified: 39, Blocked: 1`.
B86: 7 tests OK, printing core coverage 100.0 % (36/36).
`_baseline_pct` floor 86.1 unchanged — no regression.

## FINAL-PARITY summary — every row's status

§3 core rows 1–36: **all Done-verified** (36/36, per
`docs/parity-status.json`; rows 1–36 unchanged by this wave
except that no default render moved — golden byte-identical).

Continuous extras:

| ID | Feature | Status |
|---|---|---|
| C1 | Skinning / morph targets | **Done-verified** (this wave) |
| C2 | Custom shaders | **Done-verified** (this wave) |
| C3 | WebGL2 backend | **Done-verified** (headless-provable scope; browser GPU raster check noted in evidence) |
| C4 | XR | **Blocked** — API surface + fallback implemented and mock-verified 9/9; real-device immersive session unproven. Unblock: user confirms session creation + presentation on a real XR device |

**The parity programme is therefore complete except for the
single device-bound sub-item of C4, which no agent on this
VM can close. Everything closable headlessly is implemented,
tested, and green: 39/40 = 97.5 %, with the remaining 2.5 %
named, evidenced, and waiting on exactly one user action.**
