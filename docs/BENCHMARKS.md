# Forge3D Benchmarks — Native `f3dc` vs the Deleted Python Compiler

**Date:** 2026-11-23
**Native compiler:** `bin/f3dc` at HEAD `01f8664` (Forge3D v2.0, feature-complete)
**Python compiler (oracle):** `tools/f3dc/` at commit `ea40376`
("Forge3D: built-in real-time previewer") — the last full tree before the
Python compiler was deleted from the repo on 2026-11-23. Invoked as
`python3 tools/f3dc/f3dc.py <command> …` with Python 3.12.3.

## Machine note

All timings were taken on this build VM: Linux x86-64, **1.5 shared vCPU**
(with `nproc` reporting 4), shared / throttled CPU. Absolute numbers are
therefore **indicative only** — they show the relative shape on a small,
noisy, shared machine, not performance on a dedicated workstation. Re-run
on target hardware for decision-grade numbers.

## Method

- **Corpus:** the 10 examples that existed in the Python era (see table).
- **Same sources for both compilers:** `git diff ea40376 HEAD -- examples/`
  shows no change to any of these 10 files (the only additions since
  `ea40376` are `examples/rocket-parts.f3d` and `examples/parts/`, both
  v2.0). Both compilers were therefore run against the oracle tree's
  copies in `/tmp/oracle-p6/examples/`, so inputs were byte-identical and
  relative loads (e.g. `multi-object.f3d` loading `../model.obj`) resolved
  identically for both sides.
- **Operations:** `check` (validate only, no files written) and `build`
  (compile to a fresh temporary output directory, removed between runs).
- **Timing:** wall-clock seconds around each subprocess invocation
  (`time.perf_counter()`), **1 warm-up run, then 5 timed runs; the median
  of the 5 is reported**. Runs were performed in a temporary working
  directory outside the repo.
- **Totals:** sum of the per-example medians for that compiler/operation.
- **Speedup:** Python median ÷ native median. `> 1.00×` means the native
  compiler was faster; `< 1.00×` means it was slower on that row.
- **Sanity:** every Python-oracle run in the corpus exited `0`, including
  the initial `hello-cube` `check` smoke test. No example failed under
  the Python oracle, so there are no `n/a` rows.

### Excluded: `rocket-parts.f3d`

`examples/rocket-parts.f3d` (and `examples/parts/`) are **excluded**.
They use the v2.0 `import "parts/…" as …` / `mirror` component syntax
(Phase P3), which did not exist in the Python era and which the Python
compiler cannot parse. There is no like-for-like comparison for them.

## Results — wall-clock seconds (median of 5, after 1 warm-up)

| Example | check — Python (s) | check — Native (s) | check speedup | build — Python (s) | build — Native (s) | build speedup |
|---|---:|---:|---:|---:|---:|---:|
| animated | 0.1099 | 0.0324 | 3.39× | 0.1244 | 0.0693 | 1.79× |
| geometries | 0.1122 | 0.1338 | 0.84× | 0.1370 | 0.2579 | 0.53× |
| hello-cube | 0.1045 | 0.0099 | 10.52× | 0.1189 | 0.0358 | 3.32× |
| lighting-showcase | 0.1136 | 0.0673 | 1.69× | 0.1231 | 0.1387 | 0.89× |
| materials | 0.1130 | 0.0537 | 2.10× | 0.1246 | 0.1049 | 1.19× |
| multi-object | 0.1115 | 0.0843 | 1.32× | 0.1258 | 0.1547 | 0.81× |
| multi-scene | 0.1069 | 0.0680 | 1.57× | 0.1237 | 0.1345 | 0.92× |
| post-ortho | 0.1081 | 0.0773 | 1.40× | 0.1212 | 0.1597 | 0.76× |
| waveb-showcase | 0.1141 | 0.0974 | 1.17× | 0.1278 | 0.2135 | 0.60× |
| wavee-showcase | 0.1194 | 0.0472 | 2.53× | 0.1265 | 0.0954 | 1.33× |
| **Total (sum of medians)** | **1.1131** | **0.6714** | **1.66×** | **1.2528** | **1.3642** | **0.92×** |

### Reading the results (honest summary)

- **`check`: native is faster overall — 1.66× on the total**
  (1.1131 s Python vs 0.6714 s native). The native compiler won 9 of 10
  examples, most dramatically on the smallest scene (`hello-cube`,
  10.52×), which is consistent with the Python side paying a fixed
  interpreter/start-up cost of roughly 0.10 s on every invocation. The
  one exception was `geometries` (0.84×).
- **`build`: native is *not* faster overall on this machine — 0.92× on
  the total** (1.2528 s Python vs 1.3642 s native). Native won 4 of 10
  examples (`animated`, `hello-cube`, `materials`, `wavee-showcase`) and
  lost 6, most notably `geometries` (0.53×) and `waveb-showcase`
  (0.60×). No claim of a build-speed win is made: on this corpus and
  this VM, build times are at rough parity, with the advantage going to
  Python in aggregate.
- All 40 measured combinations (10 examples × 2 operations × 2 compilers)
  exited `0`. Both compilers produced the same set of build artefacts
  for the smoke-tested example (`hello-cube`: `.scene`, `.json`,
  `.legacy.json`, `.js`, `.html`, `_scene.f90`).

## Sizes

| Artefact | Size (bytes) | Notes |
|---|---:|---|
| Native compiler `bin/f3dc` | 4,275,512 | Single self-contained binary; no interpreter required |
| Native engine `bin/engine3d` | 931,792 | Fortran renderer binary |
| JS runtime `runtime/f3d.min.js` | 15,335 | Regenerated with `make minjs`; git-ignored. Unminified `runtime/f3d.js` is 20,097 bytes |
| Python compiler sources `tools/f3dc/*.py` (oracle, `ea40376`) | 598,909 | 29 `.py` files, standard library only |
| Python interpreter `/usr/bin/python3.12` | 8,020,928 | **Shared system component** — not Forge3D code; counted here only because the Python compiler cannot run without an interpreter installed. It is normally already present on a Linux system, so this is not a like-for-like distribution-size comparison |

The factual contrast is one of *deployment shape*, not just bytes: the
native compiler ships as one 4,275,512-byte binary with no runtime
dependency, whereas the Python compiler was 598,909 bytes of source that
additionally required a Python 3 interpreter (8,020,928 bytes for the
`/usr/bin/python3.12` binary alone, excluding its standard library) to
be installed and on `PATH`.

## Reproducing

```sh
# Oracle (Python) tree, outside the repo:
git -C . archive ea40376 | tar -x -C /tmp/oracle-p6
python3 /tmp/oracle-p6/tools/f3dc/f3dc.py check /tmp/oracle-p6/examples/hello-cube.f3d
python3 /tmp/oracle-p6/tools/f3dc/f3dc.py build /tmp/oracle-p6/examples/hello-cube.f3d -o /tmp/out-py

# Native:
bin/f3dc check /tmp/oracle-p6/examples/hello-cube.f3d
bin/f3dc build /tmp/oracle-p6/examples/hello-cube.f3d -o /tmp/out-native
```

The oracle checkout and all benchmark scratch used for this document
were removed after the measurements were taken.

## Update — 2026-11-23: Phase 6 compiler timings

**Recorded:** 2026-11-23, on the build VM.

> **Note on all figures in the dated updates below:** all figures are
> build-VM measurements (1.5 shared vCPUs) and are regression
> references, not absolute performance claims. Absolute numbers will
> differ on dedicated or target hardware.

| Measurement | Phase 6 (2026-11-23) | Phase 5 baseline | Notes |
|---|---:|---:|---|
| Clean compiler build | 95.6 s | 81.29 s | Slower because of 16 added compilation units from the validator split + typed-IR growth |
| `f3dc check` ×5 on `lighting-showcase` | 0.039 s | 0.04 s | Unchanged |
| Per-example build | ~130 ms | ~27 ms implied by the Phase 5 0.40 s / 15 baseline | See below |

The per-example build delta is the C5 manifest SHA-256 over all
dependencies, including the 3.8 MB `f3dc` binary: ~100 ms, from a
byte-wise implementation. A block-wise rewrite of that hashing is
Phase 8 work.

## Update — 2026-11-23: Phase 7 runtime sizes

**Recorded:** 2026-11-23, on the build VM (see the note above: these
figures are regression references, not absolute performance claims).

| Measurement | Size (bytes) | Notes |
|---|---:|---|
| Total runtime, unminified | 139,928 | Across all 15 runtime files |
| Total runtime budget | 143,872 | Total in `runtime/module-budgets.json` |
| Minified core `f3d.min.js` | 15,335 | Core only — not the whole runtime |

The minified figure is for the core file alone and is labelled as
such; it must not be read as the size of the full runtime, which is
the 139,928-byte unminified total across all 15 runtime files above.

## Engine frame-time baselines (reference)

Engine frame-time baselines live in `docs/bench/BASELINES.md` and are
not duplicated here. That document records the Phase 0 baselines for
the legacy renderer at 640×480 (`hello-cube`, `objects-100`,
`textured-plane`, and `shadowed`, in ms/frame). Refer to that file
for the recorded values and their method; like the figures above,
they are build-VM regression references, not absolute performance
claims.
