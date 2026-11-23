# Forge3D v3 Golden Registry

The v3 renderer's golden record, per ADR-1 (docs/V3-PLAN.md).
The legacy renderer is frozen and pinned by sha256 in CI (gates
G3a/G3b); this registry is the v3 counterpart.  It is a *record*,
not a CI pin file: CI gate G3c reports the v3 hello-cube hash on
every run, and a human converts a reviewed hash into this table.

## How v3 goldens are judged

Two independent criteria, mirroring ADR-1's split:

1. **Determinism — hard gate, judged by sha256.**  The v3
   renderer must produce byte-identical `output_render.ppm` for
   the same `.scene` regardless of thread count.  CI gate G3c
   renders hello-cube under `FORGE3D_THREADS=1` and
   `FORGE3D_THREADS=8` and fails unless the two sha256 are equal.
   The sha256 recorded below is the deterministic value: any
   future run, at any thread count, must reproduce it exactly
   until the row is deliberately re-pinned.
2. **Quality vs legacy — judged by PSNR.**  The v3 pipeline is a
   new renderer (linear real32 framebuffer, ADR-4), so its output
   is *not* expected to be byte-identical to the legacy render;
   demanding that would freeze v3 to legacy's rounding.  Instead
   each scene's v3 render is compared against the legacy render
   of the same `.scene` with `tools/psnr.f90`
   (`psnr <v3.ppm> <legacy.ppm>`), and the PSNR is recorded
   below.  PSNR is a regression alarm, not a pin: a re-pin review
   must explain any PSNR change, and a drop of more than 3 dB
   against the recorded value — or a value the reviewer cannot
   attribute to an intended pipeline change — blocks the re-pin.
   (For scale: +1-level uniform noise measures 48.13 dB; the
   scenes below span ~19–48 dB because v3 legitimately re-lights
   and re-tonemaps relative to legacy.)

## Registry

Measured 2026-11-23 on the Phase 3 tree (v3 renderer default,
`FORGE3D_THREADS=1`; hello-cube verified identical at
`FORGE3D_THREADS=8`).  PSNR is v3 vs the `--renderer legacy`
render of the same `.scene`, frame 1, via `tools/psnr.f90`.
Textured renders are measured with `assets/checker.ppm`
resolvable from the render working directory.

| scene | renderer | sha256 | PSNR vs legacy | threads | date |
|---|---|---|---|---|---|
| hello-cube (`examples/hello-cube.f3d`) | v3 | `45a5af9d20e53496252a52622527dbcf2f6b6c46770878583d56d78766670f77` | 25.43 dB | 1 (= 8) | 2026-11-23 |
| objects100 (`docs/bench/scenes/objects100.f3d`) | v3 | `07457fa85ee3b15e37b6f674cede15aaff8a7a49bde1fb2fdb20fa9dee046c8e` | 19.72 dB | 1 (= 8) | 2026-11-23 |
| shadowed (`docs/bench/scenes/shadowed.f3d`) | v3 | `ec447b1c1549a407ffd763727f5a5fdcf282b066d2c0ee20ed9fc80b5685e6fa` | 22.87 dB | 1 (= 8) | 2026-11-23 |
| textured (`docs/bench/scenes/textured.f3d`) | v3 | `171e9713d9e4975fb63a3139ad0108350c01d8a94a7cfab1256e48bdb542048d` | 20.32 dB | 1 (= 8) | 2026-11-23 |

Legacy reference hashes for the same renders (for reproduction):
hello-cube `090fa22a7faa670ef98dc16858006d6f0babb243a26e0f77dce471564942d19d`
(the G3b pin), objects100
`75a308e5994da3f2973b16d8bb2595709b2d4249ab82e12bca25ad6502da5a9a`,
shadowed `2d44a9a29fb3fee6172a29dff1a958d48f4ceb06595aa481436d781cf5a9cd68`,
textured `efff6a6ce8c04d83faf7e13f0db4ba5ddf9dc509c017e5c5ba7deb13e849a7e3`
(see the Phase 3 note below).

## Re-pin history

**Phase 4 (2026-11-23).** Only the textured row moved
(`f8632c1d…` → `171e9713…`, PSNR 20.27 → 20.32 dB).  Cause: the
Phase 4 texture path — v3 base-colour sampling switched from
nearest-neighbour in gamma space to filtered (trilinear with
derivative LOD) sampling in linear space, and mip chains are
now built at scene load.  The other three scenes carry no
textures, so their hashes are untouched; hello-cube's CI pin
(G3c) did not change.

**Phase 3 (2026-11-23).** Cause: the Phase 3 colour/lighting
pipeline — per-light shadow maps (shadow_v3), energy-conserving
Lambert + GGX with no 8-bit quantization round-trip and HDR
output (fragment_v3), and the ADR-4 output transform (float
bloom, exposure + tonemapping, sRGB encode at quantize only;
post_v3).  The PSNR drops on hello-cube (47.78 → 25.43 dB) and
objects100 (31.55 → 19.72 dB) are the *intended* transfer-curve
change, not a quality regression: Phase 2 wrote linear values
straight to bytes, so legacy and Phase 2 v3 shared the same
(wrong) gamma; Phase 3 v3 now decodes to sRGB, brightening every
mid-tone (linear 0.25 → byte 137 instead of 64), and the v3
light sum no longer applies legacy's `(1 − ambient)` weighting
(fully-lit up-facing surfaces gain a factor 1 + ambient).  The
shadowed scene's v3 render now contains real per-light shadows
(engine-level check: the same `.scene` with `shadow off` renders
differently, PSNR 69.70 dB between the two v3 renders); its PSNR
vs legacy is dominated by the same global curve shift.
Textured PSNR rose slightly (19.22 → 20.27 dB).  Note on the
textured legacy reference: the Phase 2 record listed
`bfc6256b…`, which does not reproduce on the Phase 3 tree (the
`.scene` bakes an absolute texture path, so the render is
working-directory independent and was reproduced three ways);
the other three legacy hashes reproduce exactly and the legacy
renderer sources are untouched since Phase 2, so the legacy
path has not moved — the Phase 2 textured legacy figure was a
measurement artifact.

**Phase 2 (2026-11-23).** First v3 goldens, measured on the
Phase 2 tree: hello-cube `2907f60a…` (47.78 dB), objects100
`26ecc60b…` (31.55 dB), shadowed `3d3ce217…` (26.97 dB, no
shadow maps yet), textured `5a920c72…` (19.22 dB).

## Re-pinning procedure

Same rule as the legacy blessing: a golden moves only by a
deliberate, human-reviewed change — never as a side effect of a
code change, and never to make a red run green after the fact.

1. Reproduce the change: build the scene, render it with the v3
   renderer at `FORGE3D_THREADS=1` and `FORGE3D_THREADS=8`;
   confirm the two hashes agree (determinism first — a
   non-deterministic render is a bug, not a new golden).
2. Measure PSNR against the legacy render with
   `tools/psnr.f90` and be able to say *why* the pixels moved
   (the intended change that caused it).
3. Update the row in this file (sha256, PSNR, date) in the same
   commit as the code change that caused it, and name that cause
   in the commit message.
4. If the scene is hello-cube, also check CI: the next G3c run's
   reported `v3 hello-cube sha256:` line must match the new row.
