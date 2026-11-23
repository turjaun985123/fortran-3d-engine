# ADR-1: Freeze the legacy renderer; v3 goldens judged by PSNR/SSIM

- Status: **APPROVED** (user decision, 2026-11-23)
- Context: v3.0 "Real Pipeline" (docs/V3-PLAN.md)

## Context

The original demo render (`output_render.ppm`, sha256
`28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`) has
been a byte-identical, never-re-baselined gate since v1. Preserving that
exact arithmetic forced every later feature into side branches: three
near-duplicate render paths in `main.f90`, integer-truncated
rasterization, 8-bit lighting math with the legacy `(1 - ambient)`
weighting, and no room for perspective-correct interpolation,
anti-aliasing, or a linear-light pipeline. The external v3.0 analysis
identified this single constraint as the root cause behind most
rendering findings (R1–R7, L1–L4).

## Decision

1. The current renderer is frozen as the **legacy renderer**, selectable
   via `--renderer legacy`. Its pinned hash
   `28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1`
   stays in CI as a permanent regression gate for that mode.
2. A new **v3 renderer** (Phases 2–3 of the v3.0 plan) becomes the
   default when Phase 2 lands.
3. v3 renders are judged by **PSNR/SSIM thresholds** against committed
   reference images, not by byte equality — except determinism:
4. **Determinism remains a hard gate in both modes.** Same scene, same
   seed, same thread count → byte-identical output. Thread-count
   determinism (1 vs 2 vs 8 threads → identical hash) is an explicit
   Phase 2 exit test.

## Consequences

- The rasterizer, color pipeline, and lighting model can be redesigned
  for correctness (perspective-correct interpolation, sub-pixel
  precision, linear HDR) without contorting around legacy arithmetic.
- Legacy mode must be kept compiling and passing its pinned gate; bug
  fixes that would change legacy output are only allowed in v3 mode
  (e.g. the `int()` → `nint()` color-rounding change, deferred from
  Phase 0 quick wins to the v3 pipeline for exactly this reason).
- Two render paths exist until legacy mode is retired by a future ADR;
  new features target v3 first.
