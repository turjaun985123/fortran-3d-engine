# P27 — Performance Plan: Parallel Rasterizer, Flags, Layout, Culling, Profiling

> **Status:** PLAN ONLY — no `src/`, `Makefile`, or build change made by this
> document. Every number in §8 is a *hypothesis to be measured*, not a claim.
> **Goal:** make the CPU rasterizer fast enough for large scenes at
> 1080p, in that order: (1) measure, (2) remove wasted work, (3) fix the
> inner loop, (4) parallelise. Never parallelise an unmeasured loop.
> **Repo baseline (verified 2026-11-23 by reading the tree):**
> `Makefile`: `gfortran -O3 -Wall -Wextra -fcheck=all -Jinclude`, 5 sources,
> 629 LOC total. `src/main.f90`: one cube, 12 triangles, 640×480, one frame,
> then PPM + `scene.json` + `model.obj` export. `src/renderer.f90` (161 LOC)
> is the whole hot path: `framebuffer_render_mesh` + `draw_triangle`.
> `src/mesh.f90`: unindexed triangle soup (see §4). No benchmark, no timer,
> no `tests/`, no OpenMP anywhere. `gfortran` is not installed in the
> planning VM, so **no baseline timing exists yet** — §2 is step zero for a
> reason.

---

## 1. Where Time Goes Today (code reading, to be confirmed by §2)

Ranked by expected cost on a *large* scene. On today's 12-triangle cube all
of this is noise (§2.2) — the ranking is for the scenes in §2.3.

| # | Hot spot | Evidence in current code | Why it costs |
|---|---|---|---|
| H1 | Per-pixel barycentric recomputation in `draw_triangle` | Inner `px` loop recomputes `w0`,`w1` from scratch: 4 multiplies + **2 divisions by `denom`** per pixel, plus a third division-free `w2=1-w0-w1` | Division is ~10–30× a multiply; every covered *and uncovered* bbox pixel pays it. This is the classic software-rasterizer bottleneck |
| H2 | Full bounding-box scan, no edge functions | `draw_triangle` scans the whole clamped bbox `min_x..max_x × min_y..max_y` and tests all pixels; no early row rejection, no incremental stepping | A long thin diagonal triangle scans ~½ its bbox for nothing; cost is bbox area, not triangle area |
| H3 | Bounds/runtime checks in the release build | `Makefile` `FFLAGS` includes `-fcheck=all` unconditionally alongside `-O3` | Array-bounds, pointer, and recursion checks fire in the per-pixel `fb%z_buffer(px,py)` / `fb%pixels(:,px,py)` accesses — exactly H1's loop. `-fcheck=all` is a debug setting shipped as the only setting |
| H4 | Whole-triangle copy per triangle | `framebuffer_render_mesh`: `tri = target_mesh%triangles(i)` copies the full `Triangle` (`v(3)` + `normal` + `color`, ~120+ B with padding) before any work | Cache traffic and a copy that culling (§6) should have made unnecessary for most triangles |
| H5 | Redundant transforms + normal recompute | Per triangle: 3× `mat4_transform_vec3(model_matrix,…)` for world verts, a fresh `compute_triangle_normal` (cross + `sqrt` + normalise), then 3× `mat4_transform_vec3(mvp,…)` — 6 transforms, each ending in a `w` divide for points | `Mesh%triangles(i)%normal` is already computed at build time in `create_cube` and never read by the renderer. World normal can be derived once per mesh from the model rotation for flat shading, or at least the stored normal transformed — not rebuilt from edges per frame |
| H6 | No culling before projection | Only cull is the screen-space signed-area test *after* all 6 transforms, plus per-pixel `depth ∈ [-1,1]` rejection inside `draw_triangle` | Off-screen, behind-camera, and frustum-outside triangles pay full transform + bbox setup. There is no frustum test, no NDC reject, no degenerate reject before `draw_triangle` (the `abs(denom) < 1.0e-6` check is inside it, after bbox work) |
| H7 | Formatted PPM I/O dominates end-to-end wall time | `framebuffer_save_ppm`: one formatted `write` per pixel (307,200 writes at 640×480; output file is 3.6 MB of ASCII) | Not a rasterizer cost, but if anyone times `./engine3d` end-to-end, I/O *is* the measurement. Benchmarks must exclude it (§2.1) or every other result is fiction |
| H8 | Layout: AoS soup, unfriendly framebuffer access order | §4 (mesh) and §4.3 (framebuffer) | Strided field access defeats SIMD in the vertex stage; see §4 for the measured-decision rule, not dogma |

Non-issues today, do not optimise: `mat4_mult` for `model_view`/`mvp`
(once per mesh per frame), `framebuffer_clear` (whole-array assignments,
already vectorisable), camera setup.

---

## 2. Profiling Method — Baseline First, No Exceptions

### 2.1 Benchmark harness (first implementation slice, before any optimisation)

- New standalone driver (e.g. `bench/bench.f90`, its own `make bench`
  target): builds the scene once, renders **N frames without any file I/O**,
  times only `framebuffer_render_mesh` (+ `framebuffer_clear` reported
  separately). PPM/JSON/OBJ export is timed once, separately, and never
  mixed into a render number.
- Timing source: `cpu_time` for single-thread work **and**
  `system_clock(count_rate=…)` wall time; once OpenMP lands (§5),
  `omp_get_wtime()` is the only valid wall clock and `cpu_time` (sum over
  threads) must be reported alongside it so parallel "speedups" that are
  really just more CPU are visible.
- Protocol per configuration: ≥3 warm-up frames (page faults, first-touch),
  then ≥15 timed frames; report **median and min**, never a single run and
  never mean-only. Pin the machine state in the report: `gfortran --version`,
  full `FFLAGS`, CPU model, core/thread count, `OMP_NUM_THREADS`, governor
  if known. Interleave baseline/optimised runs (A/B/A/B) on long sessions
  to expose thermal/machine drift instead of attributing it to code.
- Correctness gate on every timed run: checksum (e.g. SHA-256) of the raw
  framebuffer bytes + a pixel-diff count against the §2.4 golden. A faster
  run that changes one pixel is a bug report, not a result.

### 2.2 Why the shipped demo cannot be the benchmark

12 triangles at 640×480: rasterized area is a few thousand pixels, total
render time is expected to be well under a millisecond — timer resolution,
process start-up, and I/O swamp it, and OpenMP thread wake-up alone would
make the parallel version *slower*. Anyone quoting a speedup on the cube
is measuring noise. The cube stays as the correctness golden only.

### 2.3 Benchmark scenes (all generated procedurally, committed as generators, not blobs)

| Scene | Geometry | Resolution | What it isolates |
|---|---|---|---|
| S1 `cube` | 12 tris (current demo) | 640×480 | Correctness golden; overhead sanity only |
| S2 `grid` | ~10k tris, many small triangles, low overdraw | 640×480, 1920×1080 | Vertex stage, culling, per-triangle overhead (H4–H6) |
| S3 `stress` | ~100k–1M tris (subdivided/replicated mesh), mixed sizes | 1920×1080 | Rasterizer throughput, cache behaviour, OpenMP scaling |
| S4 `overdraw` | ~50 large overlapping triangles covering the screen many times | 1920×1080 | Fill rate, depth rejection, sorting payoff (§7) — worst case for H1/H2 |
| S5 `offscreen` | S2 geometry, camera facing away / mostly out of frustum | 640×480 | Culling payoff (§6) in isolation: optimised time should collapse, unculled time must not |

### 2.4 Golden and profilers

- Golden: S1 (and one fixed S2 view) rendered by the *unmodified* code at
  the *release* flags of §3 — note `-fcheck=all` removal must itself be
  proven pixel-identical first, since it is the first "optimisation".
- First profiler is the harness itself (stage timers: vertex / cull /
  rasterize / clear, behind a compile-time or env switch, removed or
  zero-cost when off). Second, where available on the user's Linux box:
  `perf stat` (cycles, instructions, cache-misses, branch-misses) and
  `perf record`/`gprofng` or `gprof -pg` build for call attribution;
  `valgrind --tool=cachegrind` for a deterministic cache picture on S2
  only (far too slow for S3/S4). No profiler output, no optimisation PR —
  each slice in §9 names the counter it expects to move.

---

## 3. Compiler Flags (`-O3` Is Already There — the Win Is What Rides With It)

Current: `FFLAGS = -O3 -Wall -Wextra -fcheck=all -Jinclude`. `-O3` itself
is not the problem and `-O2` vs `-O3` is not the opportunity.

| Change | Proposal | Expected effect / risk |
|---|---|---|
| Split build modes | `make` / `make release`: `-O3`, **no `-fcheck=all`**; `make debug`: `-O0 -g -fcheck=all -Wall -Wextra`. Keep `-Wall -Wextra` in both | Likely the single cheapest win (H3); must pass the §2.4 pixel-identical gate. Debug keeps today's safety net — nothing is lost, it just stops taxing release |
| Architecture | Release-only, opt-in `NATIVE=1`: `-march=native` | Enables the host's SIMD/ISA in vertex math and clear loops. **Never the default in a committed Makefile/CI**: a binary built for one CPU may fault on another, and CI goldens become machine-specific |
| LTO | Trial `-flto` at compile + link in release, measured on S2/S3 | Lets the small `pure` helpers in `math_3d.f90` (`vec3_dot`, `vec3_cross`, `mat4_transform_vec3`) actually inline across modules into the rasterizer — plausibly worth more than any `-O` level change here. Keep only if the harness shows it; LTO can also do nothing |
| Loop flags | Trial, individually measured: `-funroll-loops` | Helps fixed-trip loops (3-vertex, 4×4) if the compiler has not already unrolled them; trial-and-keep-if-measured, not cargo |
| OpenMP flag | `-fopenmp` only on the release/bench targets that use §5; also link it — a compile-only flag silently serialises | See §5; gate all directives so a non-OpenMP build still compiles and runs identically |
| `-ffast-math` family | **Rejected by default.** If ever trialled, only as an explicit opt-in target with its own tolerance-based (not byte-exact) golden | It permits reassociation/reciprocal substitution: breaks the §2.1 byte-exact gate, can change depth ties and cull sign outcomes, and invalidates comparisons with every prior baseline. The H1 fix (§9, slice 3) removes the divisions legally instead |
| PGO (`-fprofile-generate`/`-use`) | Out of scope for v1; revisit only if branch behaviour in the rasterizer proves erratic under `perf` | Two-stage builds complicate the beginner-facing `make` story for usually single-digit gains |
| Precision audit (not a flag) | Trial `real32` for screen-space edge/depth work in the rasterizer only, keeping `real64` world/view math | Halves depth/edge bandwidth and doubles SIMD width where it is safe; changes rounding, so it needs the tolerance golden and a z-fighting check on S3. A measured experiment, not an assumption |

Rule: **one flag change per benchmark run.** Bundled flag changes with a
good result teach nothing and cannot be bisected when they regress.

---

## 4. Data Layout — SoA vs AoS, Decided by Scene, Not by Slogan

### 4.1 Current layout (AoS soup)

```fortran
type :: Triangle          ! mesh_3d, src/mesh.f90
    type(vec3) :: v(3)    ! 3 × 24 B
    type(vec3) :: normal  ! 24 B (stored, currently unused by renderer)
    integer    :: color(3)
end type
type :: Mesh
    integer :: num_triangles
    type(Triangle), allocatable :: triangles(:)
end type
```

Consequences: no shared vertices (a cube is 36 vertex copies, not 8),
fields the rasterizer wants together (the 9 vertex coordinates) are
interleaved with fields it does not (per-triangle `normal`, `color`
stride), the vertex stage cannot load coordinates contiguously for SIMD,
and H4's whole-struct copy drags all of it through cache per triangle.

### 4.2 Proposed layout (indexed SoA as the render-side form)

```fortran
! Render-side mesh (authoring/export form may stay as-is; convert once at load)
real(dp), allocatable :: vx(:), vy(:), vz(:)      ! vertex SoA, n_vertices
integer,  allocatable :: idx(:,:)                 ! (3, n_triangles) 1-based
real(dp), allocatable :: fnx(:), fny(:), fnz(:)   ! per-face normal SoA
integer,  allocatable :: cr(:), cg(:), cb(:)      ! per-face colour SoA
! Screen-space scratch, rebuilt per frame, also SoA:
integer,  allocatable :: sx(:), sy(:)             ! per projected vertex
real(dp), allocatable :: sz(:)
logical,  allocatable :: tri_alive(:)             ! §6 cull result
```

- Vertex stage becomes three contiguous streams + an index gather —
  vectorisable, prefetchable, and each vertex shared by ~6 triangles is
  transformed **once**, not once per incident triangle (up to ~6× less
  vertex work on real meshes; exactly 3× on the cube's soup→indexed form).
- Cull, sort (§7), and rasterize stages each touch only the arrays they
  need; a culled triangle costs one `logical`, not a 120 B struct copy.
- Cost/risk: a conversion step at load (amortised over frames; for the
  one-frame demo it is pure overhead — say so in the report), a bigger
  refactor than any other slice here, and index indirection can *hurt* on
  tiny meshes. **Decision rule:** implement behind the same render entry
  point, keep the AoS path, and adopt SoA only if S2/S3 medians improve
  beyond run-to-run noise; if only S3 improves, adopt it for the render
  path and keep AoS as the authoring/export representation (exports in
  `mesh.f90` iterate triangles and must stay byte-identical).

### 4.3 Framebuffer layout (smaller, safer change)

`pixels(3,width,height)` is already Fortran-friendly for
`pixels(:,px,py)` (channel-contiguous) and `z_buffer(width,height)` matches
the current `py`-outer/`px`-inner loop (first index contiguous). Two
measured trials, in order: (a) interleave colour+depth into one
per-pixel record so the depth test and colour write touch one cache line
instead of two arrays; (b) a single `integer` packed-RGB buffer written
once per pixel instead of three separate channel stores. Either can also
regress (clear and PPM export get less convenient) — harness decides.

---

## 5. OpenMP Parallel Rasterizer — Parallelise Tiles, Not Triangles

### 5.1 The race that rules out the naïve version

`!$omp parallel do` over triangles into one shared framebuffer is a data
race: two triangles covering the same pixel interleave their
read-test-write of `z_buffer(px,py)` and the nearer surface can lose.
Wrapping the pixel write in `critical`/`atomic` serialises exactly the
hottest code and is expected to be slower than serial on S4. Reject both.

### 5.2 Recommended design: screen tiling + binning (no locks, deterministic)

1. Divide the framebuffer into tiles (start: 32×32 or 64×64 px, tuned on
   S3/S4; tiles also bound the §4.3 cache working set).
2. After vertex+cull (§6), *bin* each surviving triangle into every tile
   its screen bbox overlaps, recording per-tile triangle lists.
3. `!$omp parallel do schedule(dynamic)` over **tiles**: each thread
   rasterizes its tile's list into the shared framebuffer. Tiles are
   disjoint pixel sets, so there are no races, no atomics, and — because
   depth resolution inside a tile is still order-independent (min-depth
   wins, colour written with the winning depth) — the output is
   **bit-identical to the serial render regardless of thread count or
   schedule**. That determinism is a hard requirement, not a nicety: it
   keeps the §2.1 golden valid at any `OMP_NUM_THREADS`.
4. Binning cost is O(triangles × tiles overlapped) and is itself
   parallelisable later (per-thread bins + merge) if `perf` shows it;
   v1 bins serially and measures the fraction honestly (Amdahl, §8).

Alternatives considered: per-thread private framebuffers + depth-merge
reduction (correct and simple, but memory is `threads × (colour+depth)`
— ~33 MB/thread at 1080p — and the merge pass re-reads all of it; viable
fallback if binning's bookkeeping proves worse); scanline-band split
without binning (each band still needs every triangle tested against it —
fine for S4, wasteful for S2/S3, and load balance is poor when geometry
clusters in one band).

### 5.3 Details that decide whether it actually scales

- **Thread count / oversubscription:** default `OMP_NUM_THREADS` unset
  (runtime chooses); document testing at 1/2/4/…/physical-cores. This VM
  reports 4 cores; the user's desktop will differ — scaling claims must
  name the machine (§2.1 protocol).
- **False sharing:** tile rows at framebuffer edges and per-thread bin
  counters need padding/alignment care; assign whole tiles, never
  individual scanlines from adjacent rows to different threads in v1.
- **NUMA / first touch:** framebuffer and bins allocated and first-touched
  in parallel by the threads that will own them, if `perf` shows remote
  traffic; skip on a single-socket desktop if unmeasurable.
- **Small-work cutoff:** below a measured triangle/pixel threshold (S1
  certainly), run serially — thread wake-up and binning exceed the work.
  The cutoff is a tuned constant reported by the bench, not a guess.
- **Also parallel, cheaply, and earlier:** the vertex+cull stage (§6) is
  embarrassingly parallel over vertices/triangles (writes are disjoint
  SoA slots) and can land before tiling with `!$omp parallel do
  schedule(static)` + `simd` hints on the SoA loops — but only after §4,
  since AoS makes it pointless.
- Fortran/OpenMP hygiene: all loop temporaries `private` by construction
  (prefer `default(none)` and explicit lists), no `print`/I/O inside
  parallel regions, directives guarded so the non-`-fopenmp` build is the
  same source.

---

## 6. Early Culling — Delete Work Before It Costs Anything

Ordered cheapest-first; each stage writes `tri_alive` (§4.2) and a counter
(culled-by-stage counts are a required bench output — a cull stage that
never fires is deleted, not kept on faith). All tests must be
*conservative*: a triangle is rejected only when provably invisible, with
the same padding discipline as any bounds test.

| Stage | Test | Replaces / saves | Notes |
|---|---|---|---|
| C1 Mesh frustum | Per-mesh bounding sphere/AABB (computed once at load, transformed per frame) vs 6 frustum planes from `Camera` view/proj | Whole meshes in S5-class views | Biggest win per line of code when it fires; does nothing for a single centred cube — measure on S5, claim nothing on S1 |
| C2 Backface, in view space | Stored face normal (§4.2) transformed once, dotted with view direction — *before* projection | H5's per-frame normal rebuild + the 3 projections of culled tris | Must reproduce the current screen-space signed-area verdict (`<= 0` culls) on every golden triangle; a disagreement is a bug in C2, by definition. Double-sided/open meshes opt out explicitly |
| C3 Clip-space reject | After projection (now per-vertex, §4.2): all 3 verts outside the same frustum plane (`x<-w`, `x>w`, `y`, `z`, behind-camera `w<=0`) → reject | Full raster setup for off-screen tris | Current code has *no* clipping: partially-out triangles must still rasterize (per-pixel depth/NDC handling as today) — C3 rejects only the all-out case, it does not introduce a clipper |
| C4 Degenerate + off-screen bbox | Zero/near-zero signed area (`abs(denom)` test hoisted here), and screen bbox fully outside `[1,width]×[1,height]` → reject | The clamped-but-still-entered `draw_triangle` calls of today | Hoisting only; identical thresholds to today's in-`draw_triangle` check |
| C5 Small-triangle path | Bbox area below a tuned threshold → direct pixel plot instead of the general edge-function setup | Setup overhead on S2's many tiny tris | Optional, last, and only if S2 profiling shows setup dominating |

Expected shape of the win: scene-dependent by construction — large on S5,
moderate on S2, ~zero on S1/S4. The plan reports per-scene, never a single
"culling gives ×N" headline.

---

## 7. Triangle Sorting — a Tool for Overdraw, Not a Default

| Order | Cost | Benefit | Verdict |
|---|---|---|---|
| Front-to-back (by centroid/view depth, ascending) | One key per triangle + `O(n log n)` sort per frame | Depth test rejects occluded pixels *before* colour/depth writes; large on S4, small elsewhere. With the §9 incremental rasterizer the saving shrinks to the write side only — re-measure after slice 3, not before | **Trial on S4/S3 after slices 3–4.** Adopt only if sort time < time saved at 100k tris; sorting 12 triangles proves nothing |
| Back-to-front (painter's) | Same | None for a z-buffered renderer; would only matter for future transparency | Reject for this engine today |
| Tile-local order | Free by-product of §5.2 binning (sort each bin front-to-back) | Same early-z benefit, scoped to where pixels actually compete; sort cost is per-bin and parallel | Preferred form if sorting is adopted at all — combined with §5, not a separate global pass |
| Spatial (Morton/Hilbert by screen centroid) | Similar sort cost | Cache locality for framebuffer access on scattered geometry | Only if `perf` cache-miss counters on S3 implicate access order after tiling (tiling already buys most of this) |

Sorting never changes the image (depth buffer resolves visibility
independent of order, modulo exact-depth ties: equal-depth coplanar
triangles can flip colour with order — the golden check must use a scene
without coplanar overlaps, and ties must be called out if S3 shows diffs).

---

## 8. Honest Targets — Conditional, Per-Scene, and Modest

No target below is a promise. Each is stated as "if §2's baseline and
`perf` confirm the hot spot, expect roughly this, on that scene" — and the
slice is reverted or reworked if the measured result is not there.

| Slice (§9) | Scene | Plausible range | Basis / caveat |
|---|---|---|---|
| Release flags: drop `-fcheck=all` (§3) | S2–S4 | 1.1–1.5× | Bounds checks sit in the innermost loop; range depends on how much of runtime they are vs arithmetic — H1 may dominate instead |
| Incremental edge-function rasterizer (replaces H1/H2: per-pixel work becomes a few integer adds + sign tests, divisions only in per-triangle setup; step `w`/depth incrementally, reject whole rows by edge signs) | S4, S3 | 2–5× single-thread | The standard software-rasterizer result; the top of the range needs large triangles (S4), the bottom is small-triangle scenes where setup dominates |
| Culling C1–C4 (§6) | S5 / S2 | S5: up to "most of the frame time disappears"; S2: 1.1–1.4×; S1/S4: ~1.0× | Entirely a function of how much invisible geometry a scene has |
| SoA + indexed vertices (§4) | S3 / S2 | 1.2–2× on the vertex stage only | Frame-level effect is that fraction × vertex-stage share (Amdahl) — if raster is 80% of frame, even 2× vertex is ~1.1× frame |
| OpenMP tiling (§5) | S3/S4, 4 threads | 2.5–3.5× on the raster stage; less at frame level | Perfect 4× is unreachable: binning, serial stages, and memory bandwidth on shared depth/colour cap it. On S1 expect a *slowdown* without the §5.3 cutoff |
| Front-to-back / tile-local sort (§7) | S4 | 1.1–1.6× incremental | Only where overdraw is real; can be a net loss on S2 |

Combined, these do **not** multiply into a headline number: they attack
overlapping fractions of the same frame time (Amdahl's law), and the
fill-rate ceiling at 1080p is memory bandwidth, not arithmetic. A credible
end-state claim, to be replaced by measurements, is: *S3/S4-class scenes
several times faster than the §2 baseline on the same machine, S1
unchanged, every intermediate step pixel-identical (or tie-explained, §7).*
Anything like "10×" or "real-time 1M triangles" stated before the S3
baseline exists would be fabrication, and this plan does not state it.

Explicit non-targets: no GPU, no resolution/FPS reduction to claim speed,
no `-ffast-math` in the default build (§3), no change to shading, cull
sign convention, or export bytes at any step.

---

## 9. Implementation Order (each slice: bench before → change → bench after → golden gate)

| Slice | Work | Gate to proceed |
|---|---|---|
| 0 | Bench harness + scenes S1–S5 + stage timers + golden (§2) | Baseline table published in the PR/report; S1 golden committed |
| 1 | Release/debug flag split, `-fcheck=all` out of release (§3); trial `-flto`, `-funroll-loops` one at a time | Pixel-identical on all goldens; keep only flags that move a median |
| 2 | Culling C1–C4 + counters, still AoS (§6) | Golden-identical; S5 collapse demonstrated; per-stage cull counts reported |
| 3 | Incremental edge-function `draw_triangle` (integer screen-space edges, incremental depth; keep the old path behind a switch for A/B) | Golden-identical; S4/S3 medians vs baseline; old path deleted only after a full green run |
| 4 | SoA/indexed render mesh + parallel vertex/cull (§4, §5.3) | Golden-identical incl. exports; S2/S3 vertex-stage time from stage timers |
| 5 | Tile binning + OpenMP raster (§5.2) + small-work cutoff | Bit-identical at 1/2/4/max threads; scaling table on S3/S4; S1 not regressed |
| 6 | Optional, evidence-only: tile-local front-to-back sort (§7); packed framebuffer (§4.3); `real32` screen-space trial (§3) | Each adopted or dropped on its own A/B numbers; a dropped experiment is recorded in one line, not silently kept |

## 10. Risks and Open Questions

- **Determinism vs speed:** any optimisation that makes output depend on
  thread count, sort stability, or FP reassociation breaks the golden
  model the rest of the project relies on — §5.2's tiling and §3's
  fast-math rejection exist specifically to protect it.
- **Refactor risk in slice 4:** SoA touches `mesh.f90` consumers
  (exporters, future loaders). Keep the conversion at the render boundary
  so `scene.json`/`model.obj` bytes cannot change.
- **Machine variance:** results from the planning VM (4 cores, shared,
  no local `gfortran` at planning time) do not transfer to the user's
  desktop; baselines must be re-taken on the machine the claim is about.
- **Open questions for the maintainer:** (1) Is a future transparency /
  blending feature planned? If yes, §7's verdict and the z-order
  assumptions need revisiting before slice 6. (2) Target scene size the
  engine is actually aiming at — if it is "thousands of triangles", slices
  4–5 are over-engineering and slices 0–3 are the whole plan. (3) Is
  multi-frame/animation rendering coming (conversion and binning costs
  amortise completely differently than in today's one-frame demo)?

*End of plan — no `src/`, `Makefile`, or other file changed.*
