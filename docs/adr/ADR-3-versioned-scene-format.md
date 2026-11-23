# ADR-3: Versioned, keyed scene interchange format with a typed reader

- Status: **APPROVED** (user decision, 2026-11-23)
- Context: v3.0 "Real Pipeline" (docs/V3-PLAN.md)

## Context

The engine consumes a positional, whitespace-token `.scene` text format
parsed by a single ~800-line procedure (`scene_load` in `src/scene.f90`,
finding S1) with `-1` sentinels and fixed caps (32 extra lights, 64
shader defs, 64 bones, 256 binds/morphs/skins, 256 tokens per line,
2,048-char lines); over-cap items are silently dropped or fall through
to a generic unknown-line warning. The compiler already emits a keyed
v2 JSON scene representation alongside the legacy text.

## Decision

1. The interchange format between `f3dc` and `engine3d` becomes a
   **versioned, keyed format** (the existing v2 JSON, evolved under an
   explicit schema version), read by a **typed reader** in the engine
   (one parser per record kind, growable storage, no silent drops —
   unknown or over-limit content produces diagnostics).
2. The legacy `.scene` v1 text format stays **readable behind the
   legacy path** (`--renderer legacy` / explicit v1 input), so existing
   artifacts and the frozen golden pipeline keep working unchanged.
3. Schema changes after v3.0 require a version bump and migration
   notes in the changelog.

## Consequences

- `scene_load` is replaced incrementally (Phase 1 data model + Phase 6
  compiler schema work); the monolith and its fixed caps are retired
  for the v3 path (finding S1 closed there; Phase 9 raises/removes the
  remaining caps via growable storage).
- The compiler's emitters gain a single canonical target format
  instead of parallel positional text.
