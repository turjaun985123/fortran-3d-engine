#!/bin/sh
# Forge3D fuzz runner (POSIX shell, zero Python) -- Phase 9 hardening.
#
# Usage (from the repository root, or anywhere -- paths are resolved
# from this script's own location):
#
#     sh tests/fuzz/run_fuzz.sh [iterations] [seed]
#     sh tests/fuzz/run_fuzz.sh 2000          # 2,000 iterations, default seed
#     sh tests/fuzz/run_fuzz.sh 50000 42      # longer run, explicit seed
#
#   iterations   Cases per harness.  Default: 2000.
#   seed         Base seed for every harness.  Default: 12345 (fixed on
#                purpose, so the default run is reproducible).
#
# What it does, per harness in tests/fuzz/fuzz_*.f90:
#   1. Builds the harness plus its SOURCES (see the explicit lists
#      below) with AddressSanitizer + UndefinedBehaviorSanitizer and
#      gfortran's runtime checks into a fresh temporary directory.
#   2. Runs it as:  <harness> <iterations> <seed>
#   3. Prints PASS or FAIL for the harness.  A crash, a sanitizer
#      report, a runtime-check failure, a timeout, or any other
#      non-zero exit is a FAIL -- a fuzz harness must reject hostile
#      input gracefully, never crash on it.
# The script exits non-zero if any harness FAILs (build or run).
# A harness file that does not exist yet is reported as SKIP and does
# not by itself fail the run.
#
# COST NOTE: sanitizer builds (-fsanitize=address,undefined plus
# -fcheck=all) are SLOW -- expect the build and the run each to take
# several times longer than a normal -O2 build, and the default 2,000
# iterations per harness is a smoke-sized fuzz run, not a campaign.
# This script is a hardening tool to run by hand (or in a dedicated,
# generously-timed job) before a release.  It is deliberately NOT part
# of the default tests/run_tests.sh run, and nothing in the default
# test flow calls it.
#
# REPRODUCING A CRASH: every case a harness generates is derived
# deterministically from its seed (and the iteration count), so a
# failure reproduces exactly by re-running this script with the same
# arguments:
#
#     sh tests/fuzz/run_fuzz.sh <iterations-from-the-failing-run> <seed>
#
# The runner prints the iterations and seed at startup and again in
# each harness's PASS/FAIL line.  To debug one harness in isolation,
# rebuild just that harness with the SOURCES list below (same flags),
# then run:  ./<harness> <iterations> <seed>
# Keep the seed (and, if the harness prints one, the failing case
# index) in the bug report and in the regression test that the fix
# must add -- see tests/fuzz/README.md for that policy.
#
# Environment:
#   FC        Fortran compiler to use.  Default: gfortran.
#             (Must support -fsanitize=address,undefined; in practice
#             that means gfortran with libasan/libubsan installed.)
#   TMPDIR    Honoured for the build directory (mktemp template
#             below); defaults to /tmp when unset.
#   FUZZ_TIMEOUT
#             Per-harness run timeout in seconds, applied only when
#             the `timeout` command is available.  Default: 600.
#   ASAN_OPTIONS / UBSAN_OPTIONS
#             Respected if already set; otherwise strict defaults are
#             installed below (abort/halt on the first error, so a
#             finding can never slip past as a zero exit status).

set -u

# ---------------------------------------------------------------------------
# Locations and arguments
# ---------------------------------------------------------------------------

FUZZ_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$FUZZ_DIR/../.." && pwd)

ITERATIONS=${1:-2000}
SEED=${2:-12345}
FUZZ_TIMEOUT=${FUZZ_TIMEOUT:-600}
FC=${FC:-gfortran}

case $ITERATIONS in
    ''|*[!0-9]*)
        echo "run_fuzz.sh: iterations must be a non-negative integer, got: $ITERATIONS" >&2
        exit 2
        ;;
esac
case $SEED in
    ''|*[!0-9-]*)
        echo "run_fuzz.sh: seed must be an integer, got: $SEED" >&2
        exit 2
        ;;
esac

# Strict sanitizer defaults (only when the caller has not set their own).
: "${ASAN_OPTIONS:=abort_on_error=1:detect_leaks=1}"
: "${UBSAN_OPTIONS:=halt_on_error=1:print_stacktrace=1}"
export ASAN_OPTIONS UBSAN_OPTIONS

# Sanitizer + runtime-check flags, used for both compiling and linking.
FFLAGS="-O1 -g -fsanitize=address,undefined -fcheck=all -fno-omit-frame-pointer"

# ---------------------------------------------------------------------------
# Per-harness SOURCES lists -- EXPLICIT ON PURPOSE.
#
# These lists MUST match the link set documented in the header comment
# of each fuzz_*.f90 harness.  Nothing is extracted or globbed from the
# harness files automatically: if a harness's header link set changes,
# edit its list here in the same change.  If a build fails with an
# unresolved module, the harness header is the authority -- fix the
# list below to match it.
#
# Compiler harnesses link only compiler/src modules (never the f3dc
# driver/CLI/emitters unless a harness header says otherwise).
# Engine harnesses link ENGINE_SOURCES: the full engine module set
# (every src/*.f90 except src/main.f90, which is the engine's own
# program unit and would collide with the harness's).  That full set
# is the most likely link set for loaders/PNG/scene code; a maintainer
# may trim ENGINE_SOURCES for a harness whose header documents a
# smaller set -- trimming only speeds the build, it must never drop a
# module the harness (transitively) uses.
# ---------------------------------------------------------------------------

CSRC=$REPO_ROOT/compiler/src
ESRC=$REPO_ROOT/src

# Shared compiler-module prefix for the .f3d front end.
COMPILER_BASE="$CSRC/f3dc_str.f90 $CSRC/f3dc_dyn.f90 $CSRC/f3dc_errors.f90"

SOURCES_fuzz_lexer="$COMPILER_BASE $CSRC/f3dc_lexer.f90"

# Compiler front-end set (parser + desugar and everything they
# pull in since the plugin registry landed: f3dc_parser and
# f3dc_desugar use f3dc_plugins, which uses f3dc_ir and
# f3dc_driver, which uses f3dc_emit_common).
COMPILER_FRONT="$COMPILER_BASE $CSRC/f3dc_lexer.f90 $CSRC/f3dc_ast.f90 $CSRC/f3dc_ir.f90 $CSRC/f3dc_emit_common.f90 $CSRC/f3dc_driver.f90 $CSRC/f3dc_plugins.f90 $CSRC/f3dc_parser.f90 $CSRC/f3dc_desugar.f90"

SOURCES_fuzz_parser=$COMPILER_FRONT

# fuzz_timeline: same front end as fuzz_parser (parse + desugar
# own timeline resolution; see its header).
SOURCES_fuzz_timeline=$COMPILER_FRONT

# fuzz_desugar: a standalone DRIVER harness -- it links no
# production modules and instead drives the real bin/f3dc as a
# subprocess (see its header).  It must run with the repository
# root as working directory (or F3DC set to an absolute path).
SOURCES_fuzz_desugar=""

# fuzz_ir: the engine Timeline IR reader only -- the exact
# load path of bin/engine3d's .timeline.json --report mode
# (timeline_ir_3d uses json_reader_3d, which is standalone).
SOURCES_fuzz_ir="$ESRC/json_reader.f90 $ESRC/timeline_ir.f90"

# Engine module set: src/*.f90 minus src/main.f90.
ENGINE_SOURCES="\
$ESRC/math_3d.f90 \
$ESRC/mesh_data.f90 \
$ESRC/mesh.f90 \
$ESRC/material.f90 \
$ESRC/material_pbr.f90 \
$ESRC/texture.f90 \
$ESRC/camera.f90 \
$ESRC/camera_ortho.f90 \
$ESRC/lighting.f90 \
$ESRC/fog.f90 \
$ESRC/shader.f90 \
$ESRC/animation.f90 \
$ESRC/keyframe.f90 \
$ESRC/skinning.f90 \
$ESRC/instancing.f90 \
$ESRC/particles.f90 \
$ESRC/sprite.f90 \
$ESRC/text_render.f90 \
$ESRC/geo_capsule.f90 \
$ESRC/geo_extrude.f90 \
$ESRC/geo_flat.f90 \
$ESRC/geo_lathe.f90 \
$ESRC/geo_poly.f90 \
$ESRC/geo_torusknot.f90 \
$ESRC/geo_tube.f90 \
$ESRC/json_reader.f90 \
$ESRC/obj_loader.f90 \
$ESRC/gltf_loader.f90 \
$ESRC/scene.f90 \
$ESRC/scene_json.f90 \
$ESRC/shadow.f90 \
$ESRC/shadow_v3.f90 \
$ESRC/postprocess.f90 \
$ESRC/post_v3.f90 \
$ESRC/tonemapping.f90 \
$ESRC/fragment_v3.f90 \
$ESRC/png_write.f90 \
$ESRC/raycast.f90 \
$ESRC/renderer.f90 \
$ESRC/renderer_v3.f90"

SOURCES_fuzz_loaders=$ENGINE_SOURCES
SOURCES_fuzz_png=$ENGINE_SOURCES
SOURCES_fuzz_scene=$ENGINE_SOURCES

# The harness list, in run order.  Keep in step with tests/fuzz/*.f90.
HARNESSES="fuzz_lexer fuzz_parser fuzz_loaders fuzz_png fuzz_scene fuzz_timeline fuzz_desugar fuzz_ir"

# ---------------------------------------------------------------------------
# Build / run helpers
# ---------------------------------------------------------------------------

have_timeout=0
command -v timeout >/dev/null 2>&1 && have_timeout=1

run_harness() {
    # run_harness NAME SOURCES -- build NAME.f90 + SOURCES, run it,
    # print a PASS/FAIL/SKIP line, return 0 (pass/skip) or 1 (fail).
    _name=$1
    _sources=$2
    _src=$FUZZ_DIR/$_name.f90

    if [ ! -f "$_src" ]; then
        echo "SKIP $_name (no $_name.f90 in tests/fuzz/ yet)"
        return 0
    fi

    _dir=$BUILD_ROOT/$_name
    mkdir -p "$_dir"

    # Compile the module sources to objects, retrying in passes so a
    # module's provider compiles before its users regardless of the
    # order the sources are listed in (same approach as the Fortran
    # layer of tests/run_tests.sh).  The harness program is compiled
    # last, once every module it uses exists.
    _pending=$_sources
    _objects=""
    _pass=1
    while [ -n "${_pending# }" ] && [ "$_pass" -le 12 ]; do
        _progressed=0
        _next=""
        for _f in $_pending; do
            _obj=$_dir/$(basename "$_f" .f90).o
            # shellcheck disable=SC2086 # FFLAGS is a word list by design
            if "$FC" $FFLAGS -J"$_dir" -I"$_dir" -c "$_f" -o "$_obj" \
                    >"$_dir/build.log" 2>&1; then
                _objects="$_objects $_obj"
                _progressed=1
            else
                _next="$_next $_f"
            fi
        done
        _pending=$_next
        [ "$_progressed" -eq 0 ] && break
        _pass=$((_pass + 1))
    done
    if [ -n "${_pending# }" ]; then
        echo "FAIL $_name (build failed for:$_pending -- see below; iterations=$ITERATIONS seed=$SEED)"
        sed 's/^/    /' "$_dir/build.log" | head -n 40
        echo "    (if this is an unresolved module, the SOURCES list in"
        echo "     run_fuzz.sh has drifted from $_name.f90's header link set)"
        return 1
    fi

    # Compiler harnesses also need the preview_http.o C helper
    # (f3dc_isatty_stderr, referenced by f3dc_errors).
    case $_name in
        fuzz_lexer|fuzz_parser|fuzz_timeline)
            [ -n "$PREVIEW_HTTP_OBJ" ] && _objects="$_objects $PREVIEW_HTTP_OBJ"
            ;;
    esac

    _exe=$_dir/$_name
    # shellcheck disable=SC2086 # FFLAGS/_objects are word lists by design
    if ! "$FC" $FFLAGS -J"$_dir" -I"$_dir" "$_src" $_objects -o "$_exe" \
            >"$_dir/build.log" 2>&1; then
        echo "FAIL $_name (harness failed to compile/link -- see below; iterations=$ITERATIONS seed=$SEED)"
        sed 's/^/    /' "$_dir/build.log" | head -n 40
        return 1
    fi

    echo "RUN  $_name (iterations=$ITERATIONS seed=$SEED)"
    if [ "$have_timeout" -eq 1 ]; then
        timeout "$FUZZ_TIMEOUT" "$_exe" "$ITERATIONS" "$SEED" >"$_dir/run.log" 2>&1
    else
        "$_exe" "$ITERATIONS" "$SEED" >"$_dir/run.log" 2>&1
    fi
    _code=$?
    sed 's/^/    /' "$_dir/run.log" | tail -n 20
    if [ "$_code" -ne 0 ]; then
        echo "FAIL $_name (exit $_code; crash/sanitizer/timeout -- reproduce: sh tests/fuzz/run_fuzz.sh $ITERATIONS $SEED)"
        return 1
    fi
    echo "PASS $_name (iterations=$ITERATIONS seed=$SEED)"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ! command -v "$FC" >/dev/null 2>&1; then
    echo "run_fuzz.sh: Fortran compiler '$FC' not found on PATH." >&2
    echo "Install gfortran (with AddressSanitizer/UBSan runtime libraries)" >&2
    echo "or set FC to a compiler that supports -fsanitize=address,undefined." >&2
    exit 2
fi

# One temporary build root for the whole run; honours TMPDIR.
BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/forge3d-fuzz.XXXXXX")

# The compiler harnesses link f3dc_errors, which references the
# bind(C) helper f3dc_isatty_stderr from compiler/preview_http.c.
# Build that one C file once (system cc, per ADR-2) and add the
# object to the compiler-harness links in run_harness below.
CC=${CC:-cc}
PREVIEW_HTTP_OBJ=$BUILD_ROOT/preview_http.o
if command -v "$CC" >/dev/null 2>&1; then
    "$CC" -O1 -g -fsanitize=address,undefined -c \
        "$REPO_ROOT/compiler/preview_http.c" -o "$PREVIEW_HTTP_OBJ" \
        >"$BUILD_ROOT/preview_http.log" 2>&1 || PREVIEW_HTTP_OBJ=""
else
    PREVIEW_HTTP_OBJ=""
fi
trap 'rm -rf "$BUILD_ROOT"' EXIT INT TERM

echo "Forge3D fuzz run -- iterations=$ITERATIONS seed=$SEED"
echo "  compiler: $FC"
echo "  flags:    $FFLAGS"
echo "  build dir: $BUILD_ROOT (temporary, removed on exit)"
echo "  note: sanitizer builds are slow; this is a hardening tool and"
echo "        is NOT part of the default tests/run_tests.sh run."
echo ""

failures=0
ran=0
for harness in $HARNESSES; do
    # Resolve this harness's SOURCES list (named SOURCES_<harness>).
    eval "_srcs=\$SOURCES_$harness"
    ran=$((ran + 1))
    # A failing harness must not stop the others: collect the verdict.
    run_harness "$harness" "$_srcs" || failures=$((failures + 1))
    echo ""
done

echo "================ FUZZ SUMMARY ================"
if [ "$failures" -gt 0 ]; then
    echo "RESULT: FAIL ($failures of $ran harness(es) failed; iterations=$ITERATIONS seed=$SEED)"
    echo "Reproduce with: sh tests/fuzz/run_fuzz.sh $ITERATIONS $SEED"
    exit 1
fi
echo "RESULT: PASS ($ran harness(es), iterations=$ITERATIONS seed=$SEED)"
exit 0
