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

## v3 renderer baselines (measured 2026-11-26, ANIM Wave 5)

Recorded 2026-11-26 on the throttled build VM, 1.5 shared CPUs
(gfortran 13.3, `-O3` engine) — **a regression reference, not a
performance claim**, for the same reason as the legacy table above.
These are the first measured v3 rows (ANIM-PLAN §4.5/§6 Wave 5:
"measured, not extrapolated"); the §4.5 export-cost estimate can
now be re-based on them.

Method, 640×480 rows: `bin/f3dc bench --runs 3 --json` (median of
3 runs), the same whole-engine-run wall-clock-per-frame method as
the legacy rows (so each number includes writing the frame's PPM).
`f3dc bench` passes no `--renderer` flag; the engine default is
v3 (`src/main.f90`), and none of these four scenes use sprites,
text or particles, so the v3→legacy hybrid fallback did not fire
(bench stderr was empty). The bench scenes are the same sources
as the legacy table.

Method, 1080×1920 row: bounded measurement on the smallest bench
scene (hello-cube, one cube). `bin/engine3d` has no width/height
flags — resolution is the compiled `.scene`'s `size` line — so
the compiled hello-cube `.scene` was copied to bench scratch with
`size 1080 1920` and `frames 1`, then run 3 times as
`bin/engine3d --renderer v3` (one frame per run, median of the 3
runs). Raw runs: 2137, 1595, 2209 ms. Output verified as a
1080×1920 P3 PPM.

| Scene | Renderer | Resolution | Frames | ms/frame (median) |
|---|---|---|---|---|
| hello-cube | v3 | 640×480 | 150 | 444.108 |
| objects-100 | v3 | 640×480 | 1 | 265.389 |
| textured-plane | v3 | 640×480 | 1 | 201.448 |
| shadowed | v3 | 640×480 | 1 | 262.492 |
| hello-cube | v3 | 1080×1920 | 1 | 2137 |

Notes:

- The 1-frame scenes' numbers include engine start-up and the
  single frame's PPM write, exactly as in the legacy rows.
- The 1080×1920 frame is 6.75× the pixels of 640×480; its PPM is
  ~24.9 MB of ASCII, so that row's write cost is proportionally
  larger than the 640×480 rows'.
