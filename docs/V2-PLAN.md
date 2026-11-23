# Forge3D v2.0 — Native Edition

**Status:** approved plan, written 2026-11-23; execution in progress (see
§8 Results, filled in per phase).
**Release target:** v2.0.0 (from 0.1.0).

## 1. Current state (start of v2.0 work)

- **Compiler is native.** `bin/f3dc` is built from `compiler/src/*.f90`
  (29 Fortran modules, flang-new-18) + `compiler/preview_http.c`
  (clang-18) via `make f3dc`. The Python compiler was deleted
  (replacement commits `522527d`, `ee91db6`; see
  `compiler/REPLACEMENT.md`, `compiler/PARITY.md`).
- **Parity:** core matrix 36/36 Done-verified; with continuous extras
  **39/40**. The one open row is **C4 (XR)** — implemented and
  headless-verified 9/9; it flips to 40/40 only on a real-device
  session check by the user (P6d prepares that check; it is not
  claimed here).
- **Preview is native** (`f3dc preview`, Fortran + C HTTP helper):
  serves the compiled viewer, watches the scene file, recompiles on
  save, live-reloads, error page + self-recovery.
- **Zero Python:** the test harness and tooling have been rewritten
  (shell / node-JS / Fortran drivers); `git ls-files '*.py'` is
  empty and stays empty — v2.0 adds no Python anywhere.
- **Rendering today:** the Fortran engine (`src/`) and the JS runtime
  (`runtime/f3d.js` Canvas2D core + sidecars) shade **flat**: one
  face normal per triangle (`compute_triangle_normal` in the engine;
  per-face cross product in the runtime). Curved primitives look
  faceted. Engine output is ASCII PPM only (~3.7 MB/frame).
- **Known native divergences** (from `compiler/REPLACEMENT.md`):
  the native binary reads neither `NO_COLOR` nor `F3DC_DEBUG`
  (P4 closes this). Corpus artifact hashes are baked in
  `tests/native/` (`corpus.json`, `examples.json`, `cli_battery.json`).

## 2. Regression rules (apply to every phase)

1. **Strict golden is untouchable.** Repo-root `output_render.ppm`
   sha256 must remain
   `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`
   after every phase. Verified after every engine/compiler change,
   not just at phase close.
2. **Full suite green at each phase close:** `./tests/run_tests.sh`
   (the zero-Python harness) exits PASS — native corpus layer, JS
   sidecar suites, e2e, Fortran programs, golden layer.
3. **Baked hashes change only with cause.** Corpus/example artifact
   hashes may be regenerated ONLY where P1/P3 genuinely change
   geometry or language output. Every regenerated expectation is
   listed in the phase's hash-change manifest (§8) with file + cause.
   Everything else stays byte-identical.
4. **No feature cuts. No Python added** (`git ls-files '*.py'`
   stays empty; CI's no-Python guard must pass).
5. **Push every update** (standing user order): commit per phase,
   push after each phase commit as `turjaun985123` (workflow scope;
   verify `gh auth status` + secret-scan the diff before pushing).
   Watch CI after the final push; fix-forward until green.

## 3. P1 — Smooth shading / vertex normals

**Goal:** curved surfaces shade smoothly in both renderers; flat
surfaces are pixel-for-pixel unchanged.

**Design.**
- `src/mesh.f90`: `Triangle` gains per-vertex normals `vn(3)`
  (default: the face normal, so every existing mesh is unchanged)
  and a `smooth` flag (default `.false.`). Builders for curved
  primitives set analytic vertex normals and `smooth = .true.`:
  - `create_sphere` (mesh.f90): normal = normalised position.
  - `create_cylinder`: side vertices get radial normals; cap
    vertices keep the cap face normal (caps stay flat — builders
    emit cap triangles with duplicated rim vertices as today).
  - `create_cone`: side vertices get the cone slant normal
    (radial direction tilted by the slope angle); base cap flat.
  - `create_torus`: normal = normalised (vertex − tube centre).
  - `geo_capsule.f90`: hemisphere parts sphere-like, barrel part
    cylinder-like.
  - `geo_tube.f90`: normals from the existing parallel-transport
    frames (radial around the path).
  - `geo_lathe.f90`: normals from the profile tangent (rotate the
    2D profile normal around Y).
  - `geo_torusknot.f90`: numeric normals (gradient of the implicit
    tube distance / finite differences on the centre curve frame).
  - Flat primitives (cube, box, plane, pyramid, circle, ring,
    extrude, polyhedra) are NOT touched: face normals, `smooth`
    false.
  - `mesh_add_transformed` / skinning / morph paths: vertex normals
    are transformed with the same rotation as positions (and
    renormalised); where a path cannot carry them it resets to face
    normals (never garbage).
- `src/renderer.f90`: 
  - Legacy material path (`framebuffer_render_mesh_mat` +
    `draw_triangle_rgb`): new `draw_triangle_gouraud` interpolates
    per-vertex RGB (computed with the *same* per-material lighting
    formula at each vertex, world-space vertex normal = model
    rotation applied to `vn`, renormalised) with the same
    barycentric raster loop and z interpolation as the flat path.
    Used only when `tri%smooth` is true; flat triangles keep the
    existing fast path byte-for-byte (this is what keeps the golden
    — a cube — identical).
  - Env/PBR path (`framebuffer_render_mesh_env` +
    `draw_triangle_env`): vertex normals are interpolated per pixel
    (Phong-style): `CLIP_ATTR_COUNT` grows 5 → 8, attrs 6–8 carry
    the world-space vertex normal; `shade_rgb` receives the
    interpolated, renormalised normal instead of the face normal
    for smooth triangles. Flat triangles pass the face normal as
    all three vertex normals → identical results.
  - Shader path (`draw_triangle_shader`): custom shaders keep
    their current inputs (the shader language's normal input stays
    the face normal) — documented, not silently changed.
  - Shadow depth path: unchanged (normals do not affect depth;
    existing bias behaviour preserved).
- **Compiler / language:** new object prop `shading smooth|flat`
  (parser `OBJECT_PROP_WORDS` + `object_props`, mirroring the
  `detail` prop's shape and E103 wording), carried through IR
  (`props.shading`), validate (default resolution: `smooth` for
  curved prims — sphere, cylinder, cone, capsule, tube, lathe,
  torus, torusknot — `flat` otherwise), and emitted ONLY when the
  user wrote it explicitly (so artifacts for existing scenes are
  byte-identical). The `.scene` object line gains a trailing
  `shading` token only in that explicit case; `src/scene.f90`
  parses it (unknown trailing tokens already warn-and-skip, so old
  engines degrade gracefully) and `scene_build_object_mesh` applies
  the override after building (flat → force face normals;
  smooth → force smooth normals where the builder provides them).
  Scene-level default: `scene … shading smooth|flat` clause
  (SCENE_CLAUSES) sets the default for all objects without an
  explicit prop.
- **JS runtime:** `runtime/f3d.js` builders attach per-vertex
  normals for the same curved prims (tri entries gain an optional
  normals element, mirroring the existing optional colour element);
  the Canvas2D player computes per-vertex intensities and fills
  smooth triangles via fixed 3-level subdivision with interpolated
  intensity (deterministic, pure Canvas2D — the painter has no
  gradient primitive that matches barycentric interpolation).
  `runtime/f3d-geo.js` builders (capsule, tube, lathe, extrude,
  circle, ring, polyhedra) do the same for their curved prims.
  `runtime/f3d-webgl2.js`: normals become a vertex attribute;
  intensity is computed per-vertex in the vertex shader and
  interpolated (Gouraud) — same formula/constants as today.
  Object `shading` from the scene JSON is honoured identically.
  Core size discipline: `runtime/f3d.js` minified stays within the
  existing budget process (Makefile minify + size check in tests);
  normals code goes in core only for core prims, Wave-D prims stay
  in `f3d-geo.js`.

**Files touched:** `src/mesh.f90`, `src/geo_capsule.f90`,
`src/geo_tube.f90`, `src/geo_lathe.f90`, `src/geo_torusknot.f90`,
`src/renderer.f90`, `src/scene.f90` (+ skinning/morph call sites if
they rebuild normals), `compiler/src/f3dc_parser.f90`,
`compiler/src/f3dc_ir.f90` (if props need registration),
`compiler/src/f3dc_validate.f90`,
`compiler/src/f3dc_emit_fortran.f90`,
`compiler/src/f3dc_emit_json.f90` (only if the JSON object shape
gains the field — explicit-only, mirroring .scene),
`runtime/f3d.js`, `runtime/f3d-geo.js`, `runtime/f3d-webgl2.js`,
`runtime/f3d.min.js` (regenerated), tests under `tests/` (new P1
checks; expectation regeneration per §2.3 if e2e pixel checks on
curved prims move).

**Acceptance tests:**
- Golden sha256 unchanged after every engine commit.
- New Fortran test program: sphere mesh vertex normals are unit
  length and equal normalised positions; cube mesh reports
  `smooth = .false.` and vn == face normal.
- Render proof: a sphere scene rendered flat vs smooth — smooth
  render has strictly more distinct colours and no facet banding
  (distinct-colour count threshold baked from measured values);
  cube render byte-identical to pre-P1.
- JS: node suite asserting sphere builder emits normals and the
  player's smooth path is exercised (mock ctx records subdivided
  fills); WebGL2 suite asserts the normal attribute upload.
- `.f3d` proof: `sphere … shading flat` renders byte-identical to
  the pre-P1 sphere render; `shading smooth` on a cube is accepted
  and renders as before (cube has no smooth normals to apply).
- Full suite PASS.

## 4. P2 — PNG output

**Goal:** renders can be written as PNG, byte-decoded pixels exactly
equal to the PPM; PPM stays available.

**Design.**
- New engine module `src/png_write.f90`: dependency-free PNG
  encoder — zlib stream of DEFLATE **stored** (uncompressed) blocks
  (≤65535 bytes each), Adler-32 + CRC-32 implemented in Fortran,
  filter byte 0 per scanline, 8-bit RGB (colour type 2), single
  IDAT (or chunked IDAT at 64 KiB boundaries). Stored blocks keep
  the encoder small and obviously correct; file size is larger
  than PPM only by per-row filter bytes + framing (still far
  smaller in practice than ASCII PPM's ~11 bytes/pixel: PNG-stored
  is ~3 bytes/pixel + overhead).
- `src/renderer.f90`: `framebuffer_save_png` next to
  `framebuffer_save_ppm`, sharing the framebuffer pixel layout.
- `src/main.f90`: output dispatch by file extension — `.png`
  writes PNG, anything else writes PPM (current behaviour). The
  numbered animation frames (`<base>_0001.…`) inherit the same
  dispatch. `output` line in `.scene` already carries the path, so
  `output out.png` in a scene is all a user needs; no format token
  is added to the language (least invasive, consistent with the
  existing `output PATH` convention).
- Compiler: nothing to change in emission (the `.scene` output
  path already flows through); `f3dc run`'s summary prints the
  actual file written. Manual documents: extension selects the
  format; default remains `output_render.ppm`.

**Files touched:** `src/png_write.f90` (new), `src/renderer.f90`,
`src/main.f90`, root `Makefile` (new module in build list),
`docs/manual.md` (output section), tests (new).

**Acceptance tests:**
- Fortran test: render the golden scene to PNG in a temp dir;
  decode the PNG with an independent decoder (node zlib `inflateSync`
  in a JS test, or a Fortran inflate in the test driver — node is
  already a test dependency) and assert pixel equality with the
  PPM render, byte for byte per pixel.
- PNG signature/IHDR/CRC validity asserted by the decoder test.
- `f3dc run` on a scene with `output x.png` produces a valid PNG;
  without it, PPM behaviour byte-identical (golden).
- Full suite PASS; golden sha256 unchanged.

## 5. P3 — Model components (import + mirror)

**Goal:** reusable `.f3d` parts and a mirror modifier, in the
language's existing idioms.

**Design.**
- **Import:** `import "part.f3d" as name` — compile-time inclusion,
  resolved in `f3dc_desugar.f90` alongside group/repeat expansion
  (the same stage that flattens groups). Syntax mirrors `load`:
  quoted path first; `as name` binds the part. Semantics:
  - The imported file is lexed/parsed with the same pipeline entry
    the CLI uses (`compile_pipeline`'s front half), in the
    importer's directory context; its top-level `group <g> … end`
    (a part file defines exactly one named group — the part) or,
    if it has bare object statements, they are wrapped in an
    implicit group named by the file stem.
  - The part's objects are spliced in with names prefixed
    `name.` (exactly like group expansion prefixes `group.name`),
    so animations can target `name` or `name.child`.
  - Props after the import (`import "p.f3d" as wing at 1 0 0
    rotate 0 45 0`) apply to the part as if it were a group with
    those props (same prop words as a group header).
  - Safety, consistent with existing rules: paths must stay inside
    the scene tree (same containment check as `load`); missing
    file → `E501`; import cycles → new diagnostic `E504`
    (import depth also capped by the existing nesting limit);
    a part file containing `scene`/`camera`/`render` statements
    → `E103`-style error naming the offending statement (parts are
    pure geometry/material/animation-free content; animations
    inside a part targeting its own children ARE allowed and are
    retargeted by the prefix).
  - The word `import` is currently not a statement keyword; the
    manual's "declarative only" note (§ security) is updated to
    describe compile-time part import (it is not code execution:
    no `system`/`eval`, same file-access rules as `load`).
- **Mirror:** object/group prop `mirror x|y|z` (one axis; repeatable
  for two axes = two flips). Applied in desugar as a transform on
  the object's baked geometry path: for primitive objects it is
  emitted as a negative scale component in the existing transform
  (engine and JS already compose TRS; negative scale flips
  winding — both renderers cull by screen-space winding, so the
  plan requires verifying and, if needed, teaching the engine's
  `mesh_add_transformed` and the JS `xform` path to flip triangle
  order when the determinant is negative). For `tris`/loaded
  geometry the mirror is applied to baked vertices + winding at
  compile time in validate (same place `load` geometry is baked).
  Chosen implementation is whichever the code survey shows keeps
  engine/JS/native byte-parity; the decision and its reason are
  recorded in §8.
- **Example:** `examples/rocket-parts.f3d` + `examples/parts/`
  (`fin.f3d`, `tank.f3d`, …): the rocket from the manual rebuilt
  from imported parts, one fin imported once and mirrored for the
  other side. Renders and is covered by e2e.

**Files touched:** `compiler/src/f3dc_lexer.f90` (only if keyword
tables live there), `compiler/src/f3dc_parser.f90` (statement +
prop), `compiler/src/f3dc_desugar.f90` (expansion + mirror),
`compiler/src/f3dc_validate.f90` (baked-geometry mirror, cycle
detection state), `compiler/src/f3dc_errors.f90` (E504 text),
`compiler/src/f3dc_cli.f90` (pipeline hook if desugar needs the
file-reading callback), `src/scene.f90` / `runtime/f3d.js` (only
if the negative-determinant route is chosen),
`examples/rocket-parts.f3d`, `examples/parts/*.f3d`,
`docs/manual.md` (import + mirror sections), tests.

**Acceptance tests:**
- Corpus-style cases: import of a one-cube part == hand-written
  group expansion, byte-identical artifacts; nested import
  (part importing a part) works; cycle → E504; missing file →
  E501; escaping path (`../`) → containment error; part with a
  `scene` statement → error.
- Mirror: mirrored cube renders as the horizontal flip of the
  original render (pixel-exact flip check in the test driver);
  mirrored sphere == original sphere render (symmetry proof).
- Example renders; e2e covers rocket-parts.
- Full suite PASS; golden unchanged.

## 6. P4 — Native divergence cleanup (NO_COLOR / F3DC_DEBUG)

**Goal:** close the named divergence in
`compiler/REPLACEMENT.md`'s post-commit addendum.

**Design** (all in `compiler/src/`):
- `f3dc_errors.f90`: the existing colour machinery gets an
  enable/disable switch consulted at diagnostic format time.
  Colours are disabled when: `NO_COLOR` is present in the
  environment (any value, per no-color.org), OR stderr is not a
  TTY. TTY detection via the C helper: add `preview_http.c`-side
  or a tiny new C unit? — the compiler already links one C file
  (`compiler/preview_http.c`); add `f3dc_isatty(fd)` there
  (isatty(3)) with a Fortran interface in the errors module's
  companion. (If the build layout makes a second C file cleaner,
  `compiler/f3dc_tty.c` — decided during implementation, recorded
  in §8.)
- `F3DC_DEBUG`: when set (any value), internal errors (E9000
  path in `f3dc_cli.f90`) print the full internal detail the
  native compiler has (the failing stage, the internal message,
  and the Fortran backtrace via `traceback`/`backtrace` call if
  flang's runtime supports it non-interactively — otherwise the
  stage + state dump) instead of only the one-line message;
  behaviour without the variable is byte-identical to today
  (corpus stderr hashes must not move).
- `docs/manual.md` §3 wording restored to describe both variables
  as honoured; `compiler/REPLACEMENT.md` addendum updated to mark
  the divergence CLOSED (with the phase/commit reference).

**Files touched:** `compiler/src/f3dc_errors.f90`,
`compiler/src/f3dc_cli.f90`, `compiler/preview_http.c` (or new
`compiler/f3dc_tty.c`) + `compiler/Makefile`,
`compiler/REPLACEMENT.md`, `docs/manual.md`, tests (CLI battery
gains NO_COLOR / piped-stderr cases).

**Acceptance tests:**
- `NO_COLOR=1 bin/f3dc check <broken scene>` → stderr contains no
  ESC bytes; without NO_COLOR but piped → also no ESC bytes
  (matches old Python behaviour); with a pty (script(1) in the
  test) → colours present as before.
- `F3DC_DEBUG=1` on an E9000-shaped input prints strictly more
  diagnostic detail than without; exit codes unchanged.
- Corpus + CLI battery hashes unchanged for the default
  (piped, no env vars) environment.
- Full suite PASS.

## 7. P5 — Preview v2

**P5a — Watch dependencies.** `compiler/src/f3dc_preview.f90`:
the watcher currently polls the scene file's mtime only. Extend
the compile step to record the scene's dependency set after each
successful (or attempted) compile: imported part files (P3),
`load`ed OBJ/glTF files, texture files referenced by materials —
the set the compiler itself touched. Implementation: the preview's
mirrored pipeline (`pv_compile_pipeline`) collects paths from the
IR (object `source_file`s, texture paths, and the import set
recorded by desugar in the IR root) into the preview state; the
watcher tick stats every path in the set (same mtime helper) and
recompiles when any changes; the set is rebuilt after every
compile (so adding a new import starts watching it). Missing
dependency → same error-page path as a broken scene.

**P5b — WebGL2 by default in the viewer.** `f3dc_emit_html.f90`:
the generated single-file viewer currently inlines only
`runtime/f3d.js` and boots `F3D.create/auto` (Canvas2D). Change
the boot sequence to: inline `runtime/f3d-webgl2.js` after the
core (sidecar stays a separate file in `runtime/`; only the
*generated page* inlines it — the core runtime file and its size
budget are untouched), then boot code attempts
`F3DWebGL2.attach(canvas, scene)` inside try/catch; on any
failure (no WebGL2 context, attach throws) it falls back to the
existing `F3D.auto` Canvas2D path, and the template's
`#f3d-fallback` message is shown only if both fail. The preview
serves the same generated page, so preview gets WebGL2 by the
same change (no preview-specific renderer code). Orbit/zoom
controls must work in the WebGL2 path (the sidecar's `attach`
provides them; verified by its test suite extensions).
`.html` artifacts change for every scene → hash-change manifest
entry (cause: P5b viewer boot + sidecar inline), regenerated
deliberately.

**Files touched:** `compiler/src/f3dc_preview.f90`,
`compiler/src/f3dc_desugar.f90` / `f3dc_ir.f90` (dependency set in
IR, if not already derivable), `compiler/src/f3dc_emit_html.f90`,
`compiler/viewer_template.html` (fallback wording),
`runtime/f3d-webgl2.js` (attach robustness if gaps found), tests
(preview cycle gains a dependency-edit case; webgl2 JS suite
gains boot/fallback cases with mock GL + no-GL environments).

**Acceptance tests:**
- Preview cycle: edit a *texture/part/OBJ* dependency (not the
  scene) → `/__version` bumps and the page reflects the change;
  existing scene-edit cycle still passes.
- Generated HTML contains the WebGL2 boot attempt + Canvas2D
  fallback; node suite with a mock WebGL2 context asserts attach
  is used; with `getContext('webgl2')` returning null asserts the
  Canvas2D path boots.
- Full suite PASS; golden unchanged (native render path
  untouched).

## 8. P6 — Benchmarks, version, release prep

- **P6a Benchmarks:** build the deleted Python compiler from git
  history (`ea40376` tree) into a temp dir OUTSIDE the repo;
  time `check`+`build` for every `examples/*.f3d` with both
  compilers (median of 5 runs, same machine, commands recorded);
  record native binary size vs the Python tree size. Table →
  `docs/BENCHMARKS.md` (linked from V2-PLAN §9). Temp oracle
  removed afterwards; nothing of it enters the repo.
- **P6b Version 2.0.0:** `f3dc_cli.f90` VERSION `0.1.0` →
  `2.0.0` (and its stale header comment naming the deleted
  Python file is corrected); `runtime/f3d.js` `version:'1.0.0'`
  → `'2.0.0'` (+ `f3d.min.js` regen, `f3d.d.ts` if it carries a
  version); CLI battery `--version` expectation regenerated
  (manifest-listed); README/manual version mentions updated.
- **P6c CHANGELOG:** `CHANGELOG.md` at repo root with a v2.0.0
  entry summarising P1–P5 (features, the PNG addition, import/
  mirror, env-var cleanup, preview v2, benchmarks headline) and
  the v1.x history summarised from git log in one short section.
- **P6d XR device-check kit:** `examples/xr-check.html`
  (generated from a tiny `examples/xr-check.f3d` using the XR
  sidecar, committed as a ready page) + `docs/XR-CHECK.md`:
  5-minute instructions (open the page on an XR-capable device/
  browser, enter XR, confirm the scene presents and tracks;
  report back the result). The kit is *prepared only* — parity
  row C4 stays **Blocked** in `docs/parity-status.json` until
  the user performs it. Nothing in P6d claims the check passed.
- **P6e Release prep:** `docs/releases/v2.0.md` — draft GitHub
  Release notes (highlights, benchmark table summary, upgrade
  notes, the XR help-wanted note) + a note that CI should attach
  the Linux `f3dc` binary (`bin/f3dc` built by `make f3dc`) and
  the engine binary as release assets. **No tag, no GitHub
  Release is created** — that step waits for the user's nod.

**Files touched:** `docs/BENCHMARKS.md`, `docs/XR-CHECK.md`,
`docs/releases/v2.0.md`, `CHANGELOG.md`,
`compiler/src/f3dc_cli.f90`, `runtime/f3d.js`, `runtime/f3d.d.ts`,
`runtime/f3d.min.js`, `examples/xr-check.f3d` (+ generated
`examples/xr-check.html`), `README.md`, `docs/manual.md`, tests
(battery regeneration).

**Acceptance:** benchmarks table present with methodology;
`bin/f3dc --version` prints `f3dc 2.0.0`; full suite PASS;
golden unchanged; release notes drafted; no tag/release exists
on the remote (`gh release list` empty for v2.0).

## 9. Release checklist (v2.0.0)

- [ ] P1–P6 merged on `main`, each phase committed + pushed,
      CI green on the final head.
- [ ] `./tests/run_tests.sh` PASS on a clean checkout.
- [ ] Strict golden sha256 =
      `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`.
- [ ] `git ls-files '*.py'` empty.
- [ ] Hash-change manifest (§10) complete: every regenerated
      expectation listed with its phase + cause.
- [ ] `docs/BENCHMARKS.md`, `CHANGELOG.md`,
      `docs/releases/v2.0.md` in place.
- [ ] XR kit (`examples/xr-check.html`, `docs/XR-CHECK.md`)
      ready; C4 still honestly marked Blocked pending the
      user's device check.
- [ ] GitHub Release + tag: **user approval required** (not
      done by this plan).

## 10. Results / hash-change manifest

(Filled in during execution: per phase — what shipped, files,
commit hashes, push/CI status, and every regenerated test
expectation with its cause.)

### P1 — Smooth shading / vertex normals (shipped)

- Engine: `Triangle` gained per-vertex normals `vn(3)` + `smooth`
  flag (`src/mesh.f90`); analytic normals in the curved builders
  (sphere/cylinder/cone in core, `geo_capsule`, `geo_tube`,
  `geo_lathe`, `geo_torusknot`); flat builders set
  `vn = [normal, normal, normal]` (`geo_flat`, `geo_extrude`,
  `geo_poly`). Rasterizer: Gouraud interpolation in the legacy
  path + per-pixel interpolated normals in the env/PBR path
  (`src/renderer.f90`); flat triangles bit-identical. Scene layer
  parses `shading smooth|flat` (`src/scene.f90`).
- Compiler: `shading` object/scene property (`f3dc_parser`,
  `f3dc_validate`, `f3dc_ir`, `f3dc_emit_fortran`); bad value →
  E103, duplicate → E110. Explicit-only emission keeps all
  pre-P1 artifacts byte-identical.
- JS runtime: smooth normals in core + geo builders, Gouraud via
  subdivision in Canvas2D, per-vertex normals (`aNorm`) in the
  WebGL2 sidecar. Minified core 12,486 → 14,387 bytes (budget
  15,360).
- Measured: default sphere scene 159 distinct colours (was ~20
  faceted); explicit `shading smooth` ≡ default; `shading flat`
  restores faceting. Golden byte-identical. Full suite PASS
  (native + 151 JS + 55 e2e + 30 Fortran programs).
- New test: `tests/fortran/test_smooth_normals.f90` (4,022
  assertions: sphere/cylinder/cone/torus analytic normals,
  transform preservation).

Hash changes (cause: P1 JS smooth shading inlined into `.html`
artifacts; nothing else moved — all `.scene`/`.json`/`.js`/
`_scene.f90` artifacts byte-identical, verified against a
pre-P1 build):

- `tests/native/corpus.json` — 91 `.html` artifact hashes.
- `tests/native/examples.json` — 11 `.html` artifact hashes.
- `tests/native/cli_battery.json` — 2 `.html` artifact hashes.

Test re-aims (expectations updated to the new, correct
behaviour; no assertion dropped):

- `tests/compiler/test_f3d_geo_js.js` — tri entries may carry
  the optional normals element; torusknot normals added to
  `runtime/f3d-geo.js`.
- `tests/compiler/test_f3d_webgl2_js.js` — WebGL2 sidecar now
  uploads unshaded colours + `aNorm` attribute and shades in
  the vertex shader (`uLight`/`uAmbient` uniforms).
- `tests/e2e/test_wavea_e2e.sh` — shadow probe pixels moved
  (104,59)/(105,59) → (73,54)/(74,54) with region
  (72–76, 53–56): the old probes sat on the metal sphere,
  whose smooth shading removed the spot delta there; the
  shadow itself is unchanged (exactly 10 darkened pixels,
  0 lightened, soft vs off in both engines; the plane in this
  scene receives no spot light in either engine).
