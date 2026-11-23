# ADR-2: Standardize on gfortran ≥ 13; flang becomes an optional CI job

- Status: **APPROVED** (user decision, 2026-11-23)
- Context: v3.0 "Real Pipeline" (docs/V3-PLAN.md), Phase 0

## Context

The engine builds with gfortran, but the native compiler (`compiler/`)
was developed under `flang-new-18` (LLVM Flang 18.1.3, pre-1.0) and its
Makefile also requires `clang-18` for `preview_http.c`. Two toolchains —
one of them experimental — must be kept working (finding C5). Worse,
flang silently tolerates non-standard constructs that gfortran rejects
or mis-executes, so the compiler sources carry latent portability bugs:

- a module/procedure name collision (`f3dc_validate` module containing
  a subroutine of the same name) that gfortran refuses outright;
- `allocate` on an already-allocated deferred-length string in
  `f3dc_cli.f90:read_file` (gfortran runtime error);
- widespread reliance on `.and.`/`.or.` short-circuit evaluation for
  bounds guards — Fortran does not guarantee short-circuiting, and
  under gfortran these read out of bounds (confirmed with
  `-fcheck=all`: substring out of bounds in `first_word`).

## Decision

1. **gfortran ≥ 13 is the standard toolchain** for both the engine and
   the compiler. All sources must build cleanly under gfortran-13 at
   `-O2` and pass the full test suite under a `-fcheck=all` build.
2. flang-new remains buildable where practical but becomes an
   **optional, non-blocking CI job**.
3. `preview_http.c` is built with the **system C compiler** (`cc`/`gcc`)
   via the existing `iso_c_binding` interface; `clang-18` is no longer
   required anywhere in the default path.

## Consequences

- Phase 0 includes a portability sweep of `compiler/src`: fix the name
  collision, the double-allocation, and every non-short-circuit guard
  site where the second operand can go out of bounds. All fixes must be
  standard-conforming so both compilers accept them, and compiler
  output artifacts must stay byte-identical to the flang-built binary
  (differential gate).
- CI installs one Fortran toolchain by default; the flang job may fail
  without blocking merges, and any flang-only breakage is fixed
  forward as hygiene, not as a gate.
