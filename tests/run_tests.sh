#!/bin/sh
# Forge3D test orchestrator (POSIX shell; zero-Python rewrite of the
# former tests/run_tests.py -- see compiler/REPLACEMENT.md).
#
# Run from the repository root:
#
#     ./tests/run_tests.sh        (or: sh tests/run_tests.sh)
#
# Layers (each is discovered at runtime; nothing is hardcoded beyond
# the conventional locations below):
#
#   a) Native-compiler black-box suite under tests/native/ -- a
#      Fortran driver (tests/native/test_native_compiler.f90 +
#      json_parse.f90, built with gfortran) drives the bin/f3dc
#      binary against expectations baked into corpus.json /
#      examples.json / cli_battery.json, including the preview
#      live-reload cycle.
#   b) JS runtime + governance suites under tests/compiler/ --
#      standalone Node.js scripts (tests for the runtime/*.js
#      sidecars, written in JS).  Skipped loudly if node is absent.
#   c) End-to-end suites under tests/e2e/ -- POSIX shell scripts
#      driving bin/f3dc (55 checks).
#   d) Fortran tests under tests/fortran/*.f90 -- test *programs*
#      (files containing a `program` statement) are compiled together
#      with the support sources in the same directory and the module
#      sources under src/ (files under src/ that contain a `program`
#      statement, e.g. a demo main, are excluded) and executed.  If
#      gfortran is not on PATH this layer is skipped loudly.
#   e) Golden-image check via tests/golden/check_image.f90 if a
#      golden image is present.
#
#   f) Timeline IR contract layer under tests/ir/ -- standalone
#      Node.js contract tests (tests/ir/run_ir_tests.js): the
#      purpose schema + validator, golden IR fixtures built with
#      the real bin/f3dc, a host-simulation consumer, adversarial
#      conformance cases, and a corpus sweep over the native anim
#      build cases.  Skipped loudly if node is absent.
#
# Every layer reports PASS, FAIL or SKIP.  A missing/empty layer is a
# SKIP (with a reason), never a failure.  The process exits non-zero
# if and only if at least one layer FAILs.

set -u

TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$TESTS_DIR/.." && pwd)
cd "$REPO_ROOT"

# Timeouts (seconds), mirroring the Python runner's.
T_LONG=600
T_FC=300
T_FRUN=120

PASS=0; FAIL=1; SKIP=2

RESULTS_FILE=$(mktemp "${TMPDIR:-/tmp}/forge3d-results.XXXXXX")
trap 'rm -f "$RESULTS_FILE"' EXIT INT TERM

have_timeout=0
command -v timeout >/dev/null 2>&1 && have_timeout=1

# run_with_timeout SECONDS CMD... -- echo output, return exit code (124 on timeout)
run_with_timeout() {
    _t=$1; shift
    echo "    \$ $*"
    if [ "$have_timeout" -eq 1 ]; then
        timeout "$_t" "$@"
    else
        "$@"
    fi
    return $?
}

record() {
    # record STATUS LABEL DETAIL
    case $1 in
        0) _s=PASS ;; 1) _s=FAIL ;; *) _s=SKIP ;;
    esac
    echo "-- $2: $_s ($3)"
    printf '%s\t%s\t%s\n' "$_s" "$2" "$3" >> "$RESULTS_FILE"
}

contains_program() {
    grep -qiE '^[[:space:]]*program[[:space:]]+[A-Za-z]' "$1"
}

# ---------------------------------------------------------------------------
# (a) Native compiler layer: tests/native/ (black-box, bin/f3dc)
# ---------------------------------------------------------------------------

run_native_layer() {
    label="native compiler (black-box, tests/native/)"
    if [ ! -d tests/native ]; then
        record $SKIP "$label" "directory tests/native does not exist yet"; return
    fi
    if [ ! -f tests/native/test_native_compiler.f90 ]; then
        record $SKIP "$label" "no test_native_compiler.f90 under tests/native"; return
    fi
    if [ ! -x bin/f3dc ]; then
        echo "    bin/f3dc missing -- building via \`make f3dc\`"
        if ! run_with_timeout 600 make f3dc || [ ! -x bin/f3dc ]; then
            record $FAIL "$label" "bin/f3dc missing and \`make f3dc\` failed"; return
        fi
    fi
    if ! command -v gfortran >/dev/null 2>&1; then
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "    SKIP: gfortran not available (needed to build the test driver)"
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        record $SKIP "$label" "gfortran not available"; return
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/forge3d-native-tests.XXXXXX")
    if ! run_with_timeout $T_FC gfortran -O2 -o "$tmp/test_native_compiler" \
            tests/native/json_parse.f90 tests/native/test_native_compiler.f90; then
        rm -rf "$tmp"
        record $FAIL "$label" "test driver failed to compile"; return
    fi
    FORGE3D_ROOT=$REPO_ROOT run_with_timeout $T_LONG "$tmp/test_native_compiler"
    code=$?
    if [ $code -ne 0 ]; then
        rm -rf "$tmp"
        record $FAIL "$label" "native black-box driver exited $code"; return
    fi
    # Phase 6 (C3): property tests + curated golden set, same
    # black-box mechanism (json_parse + a Fortran driver program).
    if [ -f tests/native/property_tests.f90 ]; then
        if ! run_with_timeout $T_FC gfortran -O2 -J"$tmp" -o "$tmp/property_tests" \
                tests/native/json_parse.f90 tests/native/property_tests.f90; then
            rm -rf "$tmp"
            record $FAIL "$label" "property test driver failed to compile"; return
        fi
        FORGE3D_ROOT=$REPO_ROOT run_with_timeout $T_LONG "$tmp/property_tests"
        code=$?
        if [ $code -ne 0 ]; then
            rm -rf "$tmp"
            record $FAIL "$label" "property tests exited $code"; return
        fi
    fi
    # Phase 6 (C3): direct fmt_real/fmt_int tests; the one place the
    # native layer links a compiler module (f3dc_str is standalone).
    if [ -f tests/native/property_fmt.f90 ]; then
        if ! run_with_timeout $T_FC gfortran -O2 -J"$tmp" -o "$tmp/property_fmt" \
                compiler/src/f3dc_str.f90 tests/native/property_fmt.f90; then
            rm -rf "$tmp"
            record $FAIL "$label" "property_fmt failed to compile"; return
        fi
        run_with_timeout $T_FRUN "$tmp/property_fmt"
        code=$?
        if [ $code -ne 0 ]; then
            rm -rf "$tmp"
            record $FAIL "$label" "property_fmt exited $code"; return
        fi
    fi
    rm -rf "$tmp"
    record $PASS "$label" "Fortran black-box suites passed (corpus/examples/CLI/determinism/preview + properties/curated/fmt)"
}

# ---------------------------------------------------------------------------
# (b) JS runtime + governance layer: tests/compiler/*.js via node
# ---------------------------------------------------------------------------

run_compiler_layer() {
    label="compiler-js + governance (Node.js, tests/compiler/)"
    if [ ! -d tests/compiler ]; then
        record $SKIP "$label" "directory tests/compiler does not exist yet"; return
    fi
    set -- tests/compiler/test_*.js
    if [ ! -e "$1" ]; then
        record $SKIP "$label" "no test_*.js files under tests/compiler"; return
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "    SKIP: node not available (JS runtime checks cannot run)"
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        record $SKIP "$label" "node not available"; return
    fi
    total=0; failed=0
    for f in "$@"; do
        out=$(run_with_timeout $T_LONG node "$f" 2>&1)
        code=$?
        printf '%s\n' "$out" | sed 's/^/    /'
        n=$(printf '%s\n' "$out" | sed -n 's/.*PASS (\([0-9][0-9]*\) tests).*/\1/p' | tail -n 1)
        case $n in ''|*[!0-9]*) n=0 ;; esac
        total=$((total + n))
        if [ $code -ne 0 ]; then
            echo "    !! $f exited $code"
            failed=1
        fi
    done
    if [ $failed -ne 0 ]; then
        record $FAIL "$label" "one or more Node suites failed"; return
    fi
    if [ $total -eq 0 ]; then
        record $FAIL "$label" "test files present but 0 tests ran"; return
    fi
    record $PASS "$label" "Node suites passed ($total tests)"
}

# ---------------------------------------------------------------------------
# (c) e2e layer: tests/e2e/*.sh
# ---------------------------------------------------------------------------

run_e2e_layer() {
    label="e2e (native subprocess, tests/e2e/)"
    if [ ! -d tests/e2e ]; then
        record $SKIP "$label" "directory tests/e2e does not exist yet"; return
    fi
    set -- tests/e2e/test_*.sh
    if [ ! -e "$1" ]; then
        record $SKIP "$label" "no test_*.sh files under tests/e2e"; return
    fi
    total=0; failed=0
    for f in "$@"; do
        out=$(run_with_timeout $T_LONG sh "$f" 2>&1)
        code=$?
        printf '%s\n' "$out" | sed 's/^/    /'
        n=$(printf '%s\n' "$out" | sed -n 's/.*: PASS (\([0-9][0-9]*\) checks).*/\1/p' | tail -n 1)
        case $n in ''|*[!0-9]*) n=0 ;; esac
        total=$((total + n))
        if [ $code -ne 0 ]; then
            echo "    !! $f exited $code"
            failed=1
        fi
    done
    if [ $failed -ne 0 ]; then
        record $FAIL "$label" "one or more e2e suites failed"; return
    fi
    record $PASS "$label" "shell suites passed ($total checks)"
}

# ---------------------------------------------------------------------------
# (d) Fortran layer: tests/fortran/*.f90
# ---------------------------------------------------------------------------

run_fortran_layer() {
    label="fortran (tests/fortran/*.f90)"
    if [ ! -d tests/fortran ]; then
        record $SKIP "$label" "directory tests/fortran does not exist yet"; return
    fi
    sources=""
    for f in tests/fortran/*.f90 tests/fortran/*.f95 tests/fortran/*.f03 tests/fortran/*.f08; do
        [ -e "$f" ] && sources="$sources $f"
    done
    if [ -z "$sources" ]; then
        record $SKIP "$label" "no .f90 test sources under tests/fortran"; return
    fi
    programs=""; support=""
    for f in $sources; do
        if contains_program "$f"; then programs="$programs $f"; else support="$support $f"; fi
    done
    if [ -z "$programs" ]; then
        record $SKIP "$label" "no Fortran test programs (no 'program' statement) under tests/fortran"; return
    fi
    if ! command -v gfortran >/dev/null 2>&1; then
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "    SKIP: gfortran not available"
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        record $SKIP "$label" "gfortran not available"; return
    fi
    modules=""
    if [ -d src ]; then
        for f in src/*.f90; do
            [ -e "$f" ] || continue
            contains_program "$f" || modules="$modules $f"
        done
    fi

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/forge3d-fortran-tests.XXXXXX")
    # Compile the shared sources (src modules + tests/fortran support)
    # to objects once, retrying in passes so module providers land
    # before their users (the Python runner topo-sorted the sources
    # into a single command per program; the verdict is the same).
    pending="$modules $support"
    objects=""
    pass=1
    while [ -n "${pending# }" ] && [ $pass -le 12 ]; do
        progressed=0; next=""
        for f in $pending; do
            obj="$tmp/$(basename "$f").o"
            if gfortran -O2 -Wall -Wextra -fcheck=all -J"$tmp" -I"$tmp" \
                    -c "$f" -o "$obj" >"$tmp/last_cc.log" 2>&1; then
                objects="$objects $obj"; progressed=1
            else
                next="$next $f"
            fi
        done
        pending=$next
        [ $progressed -eq 0 ] && break
        pass=$((pass + 1))
    done
    if [ -n "${pending# }" ]; then
        echo "    !! shared sources failed to compile:$pending"
        sed 's/^/    /' "$tmp/last_cc.log" | head -n 40
        rm -rf "$tmp"
        record $FAIL "$label" "shared module/support sources failed to compile:$pending"
        return
    fi

    failures=""; nprog=0
    for prog in $programs; do
        nprog=$((nprog + 1))
        exe="$tmp/$(basename "$prog" .f90).exe"
        if ! run_with_timeout $T_FC gfortran -O2 -Wall -Wextra -fcheck=all \
                -J"$tmp" -I"$tmp" "$prog" $objects -o "$exe"; then
            failures="$failures $(basename "$prog"): compile failed;"
            continue
        fi
        if ! run_with_timeout $T_FRUN "$exe"; then
            failures="$failures $(basename "$prog"): run failed;"
        fi
    done
    rm -rf "$tmp"
    if [ -n "$failures" ]; then
        record $FAIL "$label" "$failures"; return
    fi
    record $PASS "$label" "$nprog Fortran test program(s) compiled and passed"
}

# ---------------------------------------------------------------------------
# (e) Golden layer: tests/golden/check_image.f90
# ---------------------------------------------------------------------------

run_golden_layer() {
    label="golden (tests/golden/check_image.f90)"
    if [ ! -f tests/golden/check_image.f90 ]; then
        record $SKIP "$label" "tests/golden/check_image.f90 does not exist yet"; return
    fi
    if [ -n "${FORGE3D_GOLDEN:-}" ]; then
        case $FORGE3D_GOLDEN in
            /*) golden=$FORGE3D_GOLDEN ;;
            *)  golden=$REPO_ROOT/$FORGE3D_GOLDEN ;;
        esac
    else
        golden=$TESTS_DIR/golden/golden.ppm
    fi
    if [ ! -f "$golden" ]; then
        record $SKIP "$label" "no golden image committed (generated at integration)"; return
    fi
    if ! command -v gfortran >/dev/null 2>&1; then
        record $SKIP "$label" "gfortran not available"; return
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/forge3d-golden-tests.XXXXXX")
    if ! run_with_timeout $T_FC gfortran -O2 -o "$tmp/check_image" tests/golden/check_image.f90; then
        rm -rf "$tmp"
        record $FAIL "$label" "check_image.f90 failed to compile"; return
    fi
    run_with_timeout $T_LONG "$tmp/check_image" "$golden" --expect-nonflat
    code=$?
    rm -rf "$tmp"
    if [ $code -ne 0 ]; then
        record $FAIL "$label" "check_image exited $code"; return
    fi
    record $PASS "$label" "golden image check passed"
}

# ---------------------------------------------------------------------------
# (f) Timeline IR contract layer: tests/ir/run_ir_tests.js via node
# ---------------------------------------------------------------------------

run_ir_layer() {
    label="ir (Timeline IR contract, Node.js, tests/ir/)"
    if [ ! -d tests/ir ]; then
        record $SKIP "$label" "directory tests/ir does not exist yet"; return
    fi
    if [ ! -f tests/ir/run_ir_tests.js ]; then
        record $SKIP "$label" "no run_ir_tests.js under tests/ir"; return
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "    SKIP: node not available (IR contract checks cannot run)"
        echo "    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        record $SKIP "$label" "node not available"; return
    fi
    if [ ! -x bin/f3dc ]; then
        echo "    bin/f3dc missing -- building via \`make f3dc\`"
        if ! run_with_timeout 600 make f3dc || [ ! -x bin/f3dc ]; then
            record $FAIL "$label" "bin/f3dc missing and \`make f3dc\` failed"; return
        fi
    fi
    out=$(run_with_timeout $T_LONG node tests/ir/run_ir_tests.js 2>&1)
    code=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    n=$(printf '%s\n' "$out" | sed -n 's/.*PASS (\([0-9][0-9]*\) tests).*/\1/p' | tail -n 1)
    case $n in ''|*[!0-9]*) n=0 ;; esac
    if [ $code -ne 0 ]; then
        record $FAIL "$label" "IR contract suite failed"; return
    fi
    if [ $n -eq 0 ]; then
        record $FAIL "$label" "IR suite present but 0 tests ran"; return
    fi
    record $PASS "$label" "Timeline IR contract suite passed ($n tests)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

echo "Forge3D test run -- repo root: $REPO_ROOT"

for layer in native compiler e2e fortran golden ir; do
    case $layer in
        native)   lbl="native compiler (black-box, tests/native/)" ;;
        compiler) lbl="compiler-js + governance (Node.js, tests/compiler/)" ;;
        e2e)      lbl="e2e (native subprocess, tests/e2e/)" ;;
        fortran)  lbl="fortran (tests/fortran/*.f90)" ;;
        golden)   lbl="golden (tests/golden/check_image.f90)" ;;
        ir)       lbl="ir (Timeline IR contract, Node.js, tests/ir/)" ;;
    esac
    echo ""
    echo "== $lbl =="
    # A broken layer is a FAIL, not a crash of the whole run.
    ( run_${layer}_layer ) || record $FAIL "$lbl" "orchestrator error"
done

echo ""
echo "================ SUMMARY ================"
npass=0; nfail=0; nskip=0
while IFS="$(printf '\t')" read -r st lbl detail; do
    printf '%-4s  %s -- %s\n' "$st" "$lbl" "$detail"
    case $st in
        PASS) npass=$((npass + 1)) ;;
        FAIL) nfail=$((nfail + 1)) ;;
        SKIP) nskip=$((nskip + 1)) ;;
    esac
done < "$RESULTS_FILE"
echo "Layers: $npass passed, $nfail failed, $nskip skipped"
if [ $nfail -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS (no layer failed)"
exit 0
