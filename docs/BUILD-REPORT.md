# Forge3D — Build Report (Milestone 1 / v1)

Built 2026-11-23 by a 50-agent build swarm (5 batches × 10) coordinated against
`docs/plan/MASTER-PLAN.md`, plus 10 coordinator-dispatched fix tasks to the
original seat owners. **60 agents total. Nothing pushed to GitHub.**

## Batch closes (actual counts)

| Batch | Seats | Result |
|---|---|---|
| 1 | B01–B10 compiler front end + IR + optimize | 10/10 |
| 2 | B11–B20 emitters, driver, CLI, template, Fortran math/mesh | 10/10 (cumulative 20) |
| 3 | B21–B30 Fortran back end + JS runtime (+B30 in batch 4 slot) | 10/10 (cumulative 30) |
| 4 | B31–B40 tests | 10/10 (cumulative 40) |
| 5 | B41–B50 golden/e2e, examples, Makefile, CI, manual, README | 10/10 (cumulative 50) |
| Fixes | B05 ×3 (anim kind, quote stripping, diagnostic-bag + grid `2x3`), B09 ×2 (IR defaults, palette-None), B17 ×1 (absolute scene path), B31 ×1 (golden SKIP), B03 ×1 + B05 ×1 (COLON token), B12 ×1 (generated-program compile) | 10/10 |

Phase-0 contracts (errors B02, IR B08) were frozen in the coordinator's briefs
before Batch 1; every seat ran its own file-level check before returning.

## Gates — run by the coordinator at integration, verbatim verdicts

- **G1 gfortran build — PASS.** `make clean && make` (gfortran 13.3, `-O3 -Wall
  -Wextra`): 0 errors, `bin/engine3d` from all 9 modules.
- **G2 tests — PASS.** `python3 tests/run_tests.py` exit 0: compiler PASS
  (lexer 11, parser 14, validate 12, optimize 9, emit 11, errors 12 = 69),
  e2e PASS (10), Fortran PASS (`test_math_mesh` 54/54, `test_camera_renderer`
  35/35), golden layer SKIP (no golden image committed — by design, see G3).
- **G3 golden render — PASS (strict).**
  - Legacy regression: new engine, no args, produces `output_render.ppm`
    **byte-identical** to the committed original (sha256
    `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`);
    `scene.json`/`model.obj` also byte-identical.
  - Scene path: the 1-line program `cube` + `render still`, compiled by f3dc
    and rendered via `scene.f90`, is **also byte-identical** to that golden
    (PSNR = ∞, canonical image hash `da78bf9bcc8a1f0d…`). Pixel coverage of an
    earlier grey-render run matched exactly while colours were wrong — the
    B09 palette fix (bare object colour = None, not white) closed it.
  - 3-line contract (below): renders 151 PPMs (frame 0 + 150 numbered),
    frame 0 non-flat, bg (25,25,35), red-dominant (55,15,15)/(56,15,15) —
    exactly Lambert 0.25 × (220,60,60). Distinct colours = 3, which is
    correct for a single-colour cube (an earlier `--min-distinct 4`
    expectation was the coordinator's error, not the product's).
  - Determinism: `examples/animated.f3d` run twice → all 31 PPM hashes
    identical (`DETERMINISM_OK`).
- **G4 error goldens — PASS.** `cube gold` → exit 1, E202 with help;
  `cubee red` → exit 1, E104 "did you mean 'cube'?"; missing file → exit 3,
  E501; `texture: "x.png"` and `texture "x.png"` → exit 1, E204 (reserved in
  v1); unknown anim kind → E201 (never silently dropped).
- **G-size — PASS.** `runtime/f3d.js` 15,600 B readable; terser minified
  10,184 B (`-c -m`) / 12,460 B (Makefile recipe) — both ≤ 15,360 B budget.
- **Generated Fortran program — PASS after B12 fix.** `*_scene.f90` from
  `f3dc build` compiles, links and runs against the real modules, producing a
  non-flat 640×480 PPM. (Its pixels differ slightly from the scene path —
  float vs integer Lambert scaling; byte parity is guaranteed on the legacy
  and scene paths, not the generated-program path.)
- **Examples — all verified by the coordinator:** `f3dc check` exit 0 for all
  four; native renders: materials 41 distinct colours, multi-object 800×600 /
  46 distinct colours, animated 23 distinct colours over 30 frames.

## The 3-line contract

```f3d
cube red
spin it
render
```
(`examples/hello-cube.f3d`) → `f3dc run` builds the engine if needed, writes
`build/` artefacts (`.scene`, v2 JSON, legacy JSON, JS, standalone HTML,
`*_scene.f90`) and renders `output_render.ppm` + `output_render_0001..0150.ppm`
(5 s × 30 fps, spin 90°/s about Y, on top of the demo pose 20°X/35°Y).
One full 640×480 run took ~21 s on this VM (≈0.14 s/frame; ASCII P3 writing
dominates) and ~480 MB of PPMs — see Known gaps.

## File inventory (50 seat files, one owner each)

- Compiler (18): `tools/f3dc/{f3dc,errors,lexer,ast_nodes,parser,compat,
  desugar,ir_nodes,validate,optimize,emit_common,emit_fortran,emit_json,
  emit_js,emit_html,driver,cli}.py`, `viewer_template.html` — Python stdlib
  only (CI greps the whitelist).
- Fortran (9): `src/{math_3d,mesh,camera,renderer,main}.f90` extended +
  `src/{material,scene,obj_loader,animation}.f90` new. All 7 primitives in
  `mesh.f90` (sphere = exactly 352 tris @ segments 16, cylinder 64, cone 32,
  plane 2, pyramid 6, torus, cube/box 12).
- Runtime (3): `runtime/f3d.js` (Canvas2D, Fortran-identical math, orbit
  controls, `<f3d-view>`), `runtime/f3d.d.ts`, legacy `viewer.html` (bg fixed
  to #191923, still reads v1 JSON).
- Tests (12): `tests/run_tests.py`, 6 compiler suites, `tests/e2e/test_cli.py`,
  `tests/golden/check_image.py`, 3 Fortran test files (89 Fortran assertions).
- Examples/build/docs/CI (8): 4 × `examples/*.f3d`, `Makefile` (+ `debug`,
  `test`, `minjs` targets), `.github/workflows/ci.yml`, `docs/manual.md`
  (411 lines), `README.md`.
- Integrator edits outside seats: `.gitignore` gained `__pycache__/`,
  `runtime/f3d.min.js`, `build/` (generated artefacts are not committed).

## Known gaps vs the parity matrix (MASTER-PLAN §3) — by wave

- **Wave A (B51–B62):** textures/UV (v1: E204 reserved), point/spot lights,
  real shadow maps (v1 has no shadow; `shadow: soft` is not silently faked —
  it is not in the v1 grammar at all), fog, tone mapping, PBR/Standard
  material, Phong is present but basic.
- **Wave B (B63–B74):** glTF/GLB (OBJ subset works: v/f, fan triangulation,
  negative indices), raycasting/picking, sprites, text, particles, full
  keyframe tracks (v1 has closed-form spin/bob/pulse/orbit/move/turn/grow).
- **Wave C (B75–B84):** post/filters, orthographic camera, true instancing
  (v1 `repeat/grid/ring` is compile-time expansion), multi-scene.
- **Continuous (B85+):** remaining geometries, skinning/morph, custom shaders,
  WebGL2/WebGL runtime path (v1 JS runtime is Canvas2D by deliberate choice —
  identical math over GPU speed), XR, ecosystem loaders. Matrix coverage
  generator (B85) and stop-rule test (B86) not yet built, so no coverage %
  is claimed.
- **v1 rough edges (found at integration, recorded honestly):**
  - `loadobj` paths inside `.scene` resolve relative to the engine's cwd
    (the build dir), not the source `.f3d` — the multi-object example's OBJ
    object is skipped with a warning when rendered into a different output
    dir. Compiler-side path rewriting is the fix (Wave A housekeeping).
  - Animation renders are ASCII P3 PPMs: ~3.7 MB/frame at 640×480; the
    Fortran writer does not detect disk-full errors (a truncated frame can
    exit 0). Binary P6 output + write checks are Wave A housekeeping.
  - `emit_fortran`'s generated program is frame-0 only (by design; animation
    goes through the `.scene` path) and its Lambert rounding differs by ±1
    from the scene path on some pixels.
  - CI (`ci.yml`) is committed but has never run on GitHub (nothing pushed);
    its G3 step uses the portable tier (non-flat + bg + distinct + reported
    hash), not a pinned sha — pinning remains a human blessing step (P18).

## Claims discipline

Only MASTER-PLAN §5 claims are made anywhere in README/manual: fewer lines
(3 vs ~23 for a rotating cube), smaller JS runtime (≤15,360 B, measured),
zero-config defaults, no silent black screens (friendly diagnostics),
deterministic offline native rendering. No FPS-vs-GPU claims; no feature is
claimed Done-verified beyond what the tests above actually ran.
