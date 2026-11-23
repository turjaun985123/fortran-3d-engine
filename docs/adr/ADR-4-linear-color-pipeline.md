# ADR-4: Linear-light color pipeline for the v3 renderer

- Status: **APPROVED** (user decision, 2026-11-23)
- Context: v3.0 "Real Pipeline" (docs/V3-PLAN.md), Phase 3

## Context

Today all shading math runs on 8-bit sRGB-encoded integers: light
colors are integers 0–255, the framebuffer is `integer ×3` plus a
`real64` depth, and tone mapping runs on the already-clamped 8-bit
buffer, so ACES/Reinhard can never recover highlights (findings L3,
L4, R7). Specular is not energy-normalized and the `(1 - ambient)`
diffuse weighting exists only to reproduce the legacy formula.

## Decision

1. The v3 renderer uses a **`real32` linear-RGB framebuffer** (plus
   float depth). All lighting is computed in linear space with real
   light colors and intensities.
2. **sRGB (output transform + tone mapping) is applied once, at the
   end** of the pipeline, before quantization to 8-bit output formats.
3. The legacy renderer keeps its 8-bit integer pipeline unchanged
   (ADR-1 freeze).

## Consequences

- HDR values above 1.0 survive to tone mapping (Phase 3 exit test);
  energy-conserving Lambert + GGX replaces the legacy weighting in v3.
- Framebuffer memory grows (16 bytes/pixel for RGBA32F + depth vs
  20 bytes/pixel today — comparable, and layout becomes SoA-friendly
  for the Phase 2 rasterizer).
- Textures are decoded to linear space on sample (Phase 4 sRGB-aware
  decode), and material/light authoring in `.f3d` gains real-valued
  intensities under the versioned schema (ADR-3).
