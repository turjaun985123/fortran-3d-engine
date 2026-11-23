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

Measured 2026-11-23 on the Phase 2 tree (v3 renderer default,
`FORGE3D_THREADS=1`; every hash verified identical at
`FORGE3D_THREADS=8`).  PSNR is v3 vs the `--renderer legacy`
render of the same `.scene`, frame 1, via `tools/psnr.f90`.

| scene | renderer | sha256 | PSNR vs legacy | threads | date |
|---|---|---|---|---|---|
| hello-cube (`examples/hello-cube.f3d`) | v3 | `2907f60a0ea5e5c02512cb270e416778c0c11a4c082d156f32d1f4c070e16239` | 47.78 dB | 1 (= 8) | 2026-11-23 |
| objects100 (`docs/bench/scenes/objects100.f3d`) | v3 | `26ecc60bd9ed86fd529d4982e31c3f6bff81482a2b347d07e7e7964d307f2a14` | 31.55 dB | 1 (= 8) | 2026-11-23 |
| shadowed (`docs/bench/scenes/shadowed.f3d`) | v3 | `3d3ce21742a0e9fda885b1db0522073efdd81c3e5372abc8eba3e984318aded5` | 26.97 dB | 1 (= 8) | 2026-11-23 |
| textured (`docs/bench/scenes/textured.f3d`) | v3 | `5a920c72736b1a66d155bf262611b00f8f2030b70b539bff91476a60246e783e` | 19.22 dB | 1 (= 8) | 2026-11-23 |

Legacy reference hashes for the same renders (for reproduction):
hello-cube `090fa22a7faa670ef98dc16858006d6f0babb243a26e0f77dce471564942d19d`
(the G3b pin), objects100
`75a308e5994da3f2973b16d8bb2595709b2d4249ab82e12bca25ad6502da5a9a`,
shadowed `2d44a9a29fb3fee6172a29dff1a958d48f4ceb06595aa481436d781cf5a9cd68`,
textured `bfc6256b75006074b0d32cb6a07a4ca1c33a9e5a7b128c28df03f9850940cbed`.

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
