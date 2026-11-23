# Forge3D engine frame-time baselines (v3.0 Phase 0)

Recorded 2026-11-23 with `bin/f3dc bench --runs 3` (median of 3
runs) on the build VM (1.5 shared vCPUs, gfortran 13.3, `-O3`
engine).  **These numbers are a regression reference, not a
performance claim**: the VM is CPU-throttled and shared, so absolute
values will differ on real hardware.  Per the v3.0 quality gates, a
phase that regresses any scene by more than 10% against this table
must explain why in its phase report.  Machine-readable copy of the
recording run: `baseline-run.json`.

| Scene | Source | Frames | ms/frame (median) |
|---|---|---|---|
| hello-cube | `examples/hello-cube.f3d` | 150 | 165.603 |
| objects-100 | `docs/bench/scenes/objects100.f3d` | 1 | 171.828 |
| textured-plane | `docs/bench/scenes/textured.f3d` | 1 | 208.488 |
| shadowed | `docs/bench/scenes/shadowed.f3d` | 1 | 226.894 |

Notes:

- All scenes render at 640×480 through the legacy pipeline (ADR-1);
  the v3 pipeline gets its own baseline row set when Phase 2 lands.
- `f3dc bench` builds each scene with the installed `bin/f3dc` into
  `docs/bench/.work-<scene>/` (gitignored) and times
  `bin/engine3d` on the compiled `.scene`.
- Bench scratch deliberately lives on a real filesystem, not
  `/tmp`: one animated scene writes ~3.5 MB of ASCII PPM per frame,
  which overflows a small tmpfs — and the engine currently does not
  detect the failed writes (it exits 0 with frames missing and its
  buffered stdout lost).  That silent-write-failure behaviour is
  recorded as a Phase 9 hardening item in `docs/V3-PLAN.md`.
