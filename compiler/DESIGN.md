# Forge3D native compiler (f3dc) — port contract

Goal: byte-identical re-implementation of tools/f3dc/*.py in Fortran
(flang-new-18) + clang C helpers. Python is the oracle; NEVER diverge
silently — report any behaviour you cannot replicate.

## Layout (all inside compiler/)
- src/f3dc_str.f90    string helpers + growable lists (char/real/int/str)
- src/f3dc_dyn.f90    dynamic value type (mirrors Python objects)
- src/f3dc_errors.f90 diagnostic bag (port of errors.py)
- src/f3dc_lexer.f90  port of lexer.py
- src/f3dc_parser.f90 port of ast_nodes.py + parser.py (AST = dyn dicts)
- src/f3dc_desugar.f90 port of desugar.py
- src/f3dc_ir.f90     port of ir_nodes.py (IR = dyn dicts + helpers)
- src/f3dc_validate.f90 port of validate.py
- src/f3dc_optimize.f90 port of optimize.py
- src/f3dc_compat.f90 port of compat.py
- src/f3dc_emit_common.f90 / _json / _js / _html / _fortran / _scene
- src/f3dc_ext_*.f90  ports of ext_*.py
- src/f3dc_driver.f90 port of driver.py
- src/f3dc_cli.f90    program main; port of cli.py behaviour
- preview_http.c      clang C HTTP server helper for `preview`
- Makefile            FC=flang-new-18 CC=clang-18 -> ./f3dc

## dyn value (f3dc_dyn) — the universal representation
AST and IR nodes are dyn DICTS with the same keys the Python dataclasses
serialise to. kind tags: 0 null, 1 bool, 2 int(int64), 3 real(real64),
4 string, 5 list, 6 dict(string->dyn). Provide constructors
(dyn_int, dyn_real, dyn_str, dyn_bool, dyn_list, dyn_dict, dyn_null),
dict get/set/has, list push/len/at, deep copy, and equality.
Recursive allocatable components are F2003-legal; flang-18 accepts them.

## Float formatting — CRITICAL for byte parity
Python emits floats with repr(): shortest string that round-trips,
e.g. 1.0->"1.0", 0.1->"0.1", 1e16->"1e+16", 1e-5->"1e-05",
123456789.0->"123456789.0". f3dc_str must provide fmt_real(x) that:
tries 1..17 significant digits (ES format internal write + read back,
bit-compare via transfer), picks the shortest round-tripping digit
string, then renders in Python style: fixed notation when
-4 <= decimal_exp < 16 (appending ".0" for integral values),
else scientific "d.dddde±XX" (exponent at least 2 digits, sign always).
Also fmt_int for int64. Where Python uses json.dumps for numbers the
same repr rules apply. Int-valued reals that Python stores as int must
stay dyn_int — mirror the Python types exactly.

## Diagnostics
Match errors.py exactly: codes (E1xx lex, E2xx parse, ...), severity,
span (line/col), message/why/help texts, the printed format of
_print_diagnostics in cli.py and the JSON form. Exit codes per cli.py:
scene errors -> 1, E5xx IO -> 3, usage -> 2, internal -> 70.

## Rules for every port
- Read the Python file(s) you port IN FULL first. Mirror function-by-
  function; keep the same names (snake_case) for subroutines.
- No Python dependency at runtime. No modifying anything outside
  compiler/. Compile-check your module with flang-new-18 -c (stubs for
  not-yet-written siblings are allowed in /tmp, never committed).
- Report: file(s) written, line counts, compile status, and every
  Python behaviour you approximated or could not replicate.
