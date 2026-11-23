# Forge3D fuzz harnesses — Phase 9 hardening

Standalone Fortran fuzz programs for the parts of Forge3D that consume
untrusted input: the `.f3d` compiler front end and the engine's asset
and scene loaders. Each harness generates deterministic pseudo-random
and mutated inputs, feeds them to the real production modules, and
asserts the one property that matters for hostile input:

> **Any input — valid, invalid, truncated, or absurd — must be either
> accepted correctly or rejected with a proper error. It must never
> crash, read or write out of bounds, overflow, leak its way to a
> non-zero death, or hang.**

The harnesses are built with AddressSanitizer, UndefinedBehaviorSanitizer
and gfortran's `-fcheck=all` runtime checks, so memory errors, undefined
behaviour and Fortran-level violations (bounds, unallocated accesses,
bad procedure arguments) abort the harness instead of passing silently.

Zero Python is involved anywhere in this directory: the harnesses are
Fortran and the runner is POSIX `sh`.

## The harnesses

| Harness | Target | What it covers |
|---|---|---|
| `fuzz_lexer.f90` | `f3dc_lexer` (with `f3dc_str`, `f3dc_dyn`, `f3dc_errors`) | Random and mutated `.f3d` source text through the lexer: unterminated strings and comments, stray and non-ASCII bytes, malformed numbers, over-long identifiers and literals, pathological whitespace, truncated final tokens. The lexer must tokenise or report a positioned error — never crash. |
| `fuzz_parser.f90` | `f3dc_parser` + `f3dc_desugar` (over the lexer modules) | Mutated token streams and source snippets through parsing and desugaring: unbalanced blocks, missing/extra arguments, unknown commands, deeply nested expressions, extreme numeric values, duplicated declarations. Grammar errors must surface as diagnostics, and desugaring must not corrupt or crash on partially valid trees. |
| `fuzz_loaders.f90` | Engine asset loaders (`obj_loader`, `gltf_loader`, `json_reader`) | Synthetic and mutated OBJ / glTF / JSON byte streams: truncated files, lying counts and offsets, negative or huge indices, malformed numbers, missing sections, embedded NULs. Loaders must fail cleanly with no partial, corrupt mesh escaping as if it were valid. |
| `fuzz_png.f90` | `png_write` (engine PNG encoder) | Random image dimensions (including zero, one, and very large), random and edge-case framebuffer contents, and row/size combinations near overflow. Encoding must produce a structurally valid PNG or a clean error — never an out-of-bounds write or a corrupt stream written silently. |
| `fuzz_scene.f90` | Scene loading (`scene_json`, `json_reader`, `scene`) | Mutated scene JSON / `.scene` data: wrong types, missing required fields, out-of-range references, extreme transforms and counts, duplicate names, deeply nested structures. A bad scene must be rejected field-by-field with errors, not trusted into renderer state. |

Each harness is a self-contained program: it links only the production
modules listed in its own header comment, generates its inputs itself
(no corpus files are read), and takes the same two optional arguments:

```
./fuzz_<name> [iterations] [seed]
```

## Running

Prerequisites: `gfortran` with the AddressSanitizer and
UndefinedBehaviorSanitizer runtime libraries installed (the usual
`libasan` / `libubsan` packages for your distribution).

Run everything with the runner script, from anywhere:

```sh
sh tests/fuzz/run_fuzz.sh              # 2,000 iterations/harness, default seed
sh tests/fuzz/run_fuzz.sh 50000        # a longer run
sh tests/fuzz/run_fuzz.sh 50000 42     # a longer run, explicit seed
```

The runner builds each harness plus the module sources it needs into
a temporary directory (honouring `TMPDIR`), runs it, prints a
per-harness `PASS` / `FAIL` line (a crash is a `FAIL`), and exits
non-zero if any harness fails. The per-harness source lists are written
out explicitly in `run_fuzz.sh` and must match the link set documented
in each harness's header — if you change a header, change the script in
the same commit.

**Cost note:** sanitizer builds are slow — several times slower to
build and to run than the normal `-O2` build, and the default 2,000
iterations per harness is a smoke-sized run, not an overnight campaign.
Treat fuzzing as a deliberate hardening step before a release (or when
touching a parser/loader), not as an everyday check. For that reason
this runner is **not** part of the default `tests/run_tests.sh` run and
nothing in the default test flow calls it.

## Seeds and reproduction

Generation is fully deterministic. A harness seeds its pseudo-random
generator from the `seed` argument (plus its case index), so:

- The **same seed and same iteration count always produce the same
  sequence of inputs**, on any machine, in any order the harnesses run.
- The runner uses a fixed default seed (`12345`) precisely so the
  default run is reproducible rather than different every time.
- The runner prints the iterations and seed at startup and on every
  `PASS` / `FAIL` line. A failing run therefore carries its own
  reproduction command:

  ```sh
  sh tests/fuzz/run_fuzz.sh <iterations> <seed>
  ```

- To debug a single harness, rebuild just that harness with the flags
  and source list from `run_fuzz.sh`, then run
  `./fuzz_<name> <iterations> <seed>` under your debugger. If the
  harness prints a failing case index, quote the seed **and** that
  index in the bug report — together they identify the exact input.

When you go hunting rather than smoke-testing, vary the seed: each new
seed explores a different input space. Record any seed that finds
something; a found seed is never thrown away (see the policy below).

## What a finding means

A finding is any of:

- a non-zero harness exit, an AddressSanitizer or UBSan report, or a
  `-fcheck=all` runtime error;
- a hang (the runner's per-harness timeout kills it and reports FAIL);
- a harness assertion that invalid input was accepted into a state it
  should never reach (for example a loader returning success with a
  corrupt mesh).

A finding is a real bug in the production code, not a fuzz-harness
artefact to be waved away: the input that triggered it is by
construction something an attacker, a corrupt file, or a hand-editing
mistake could supply. "The input was invalid" is never a defence — the
code's job on invalid input is a clean, positioned error.

Triage a finding like this:

1. Reproduce it with the recorded seed (and case index, if printed).
2. Minimise it: reduce the iteration count / case to the smallest input
   that still triggers the report, and keep that input.
3. Fix the root cause in the owning production module — validate at the
   boundary (lexer, parser, loader, scene reader), don't paper over
   the crash site downstream.

## Policy: no fix closes without a regression test

**A fuzz finding is not closed by the fix alone. Before the fix is
considered done, the minimised failing input must land as a regression
test in the owning layer's normal test suite**, so the default test run
— not just a future fuzz run — keeps it fixed forever:

| Finding in | Regression test goes in |
|---|---|
| `fuzz_lexer` / `fuzz_parser` (compiler front end) | The native compiler suite (`tests/native/`) or the Fortran tests (`tests/fortran/`), matching where that module's other tests live |
| `fuzz_loaders` / `fuzz_png` / `fuzz_scene` (engine) | The Fortran tests (`tests/fortran/`) for the owning engine module |

The regression test should cite the seed (and case index) it came from
in a comment, so anyone can regenerate the original fuzz case. The fix
commit should reference that test. A finding whose regression test does
not fail on the pre-fix code is not yet minimised — keep reducing until
it does.
