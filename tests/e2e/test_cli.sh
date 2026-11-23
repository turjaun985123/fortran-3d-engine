#!/bin/sh
# End-to-end tests for the Forge3D CLI (the native bin/f3dc binary).
# POSIX shell port of tests/e2e/test_cli.py (10 checks, 1:1).
# Standalone-runnable from any CWD:  sh tests/e2e/test_cli.sh
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BASE=$(basename -- "$0")

# F3DC resolution mirrors the Python: $F3DC, else bin/f3dc, else compiler/f3dc.
if [ "${F3DC:-}" ]; then
    F3DC_BIN=$F3DC
elif [ -f "$REPO_ROOT/bin/f3dc" ]; then
    F3DC_BIN=$REPO_ROOT/bin/f3dc
else
    F3DC_BIN=$REPO_ROOT/compiler/f3dc
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# The 3-line starter contract written by `f3dc new`.
STARTER='cube red
spin it
render'
# A one-frame render: `render still` suppresses animation frames.
STILL_SCENE='scene size 64 48
cube red
render still'

printf '%s\n' "$STARTER" > "$TMP/valid.f3d"
printf '%s\n' "$STILL_SCENE" > "$TMP/still.f3d"
printf 'cube gold\n' > "$TMP/bad.f3d"
BUILD_DIR=$TMP/build-out
RUN_DIR=$TMP/run-out

PASS=0
FAIL=0
FAILED_THIS=0

fail_msg() { FAILED_THIS=1; echo "  # $*" >&2; }

assert_eq() { # got want [msg]
    if [ "$1" != "$2" ]; then fail_msg "expected [$2], got [$1] ${3:-}"; fi
}
assert_contains() { # haystack needle [msg]
    case $1 in
        *"$2"*) ;;
        *) fail_msg "expected to contain [$2]: ${3:-} [$1]" ;;
    esac
}
assert_file() { # path
    if [ ! -f "$1" ]; then fail_msg "missing file $1"; fi
}
assert_nonempty_file() { # path (is_file + size > 0)
    if [ ! -s "$1" ]; then fail_msg "missing or empty file $1"; fi
}

# Run the native f3dc binary with cwd=REPO_ROOT; sets RC, OUT, ERR.
call_cli() {
    OUT=$(cd "$REPO_ROOT" && "$F3DC_BIN" "$@" 2>"$TMP/stderr.txt")
    RC=$?
    ERR=$(cat "$TMP/stderr.txt")
}

run_check() { # name func
    _name=$1; shift
    FAILED_THIS=0
    "$@"
    if [ "$FAILED_THIS" -eq 0 ]; then
        PASS=$((PASS + 1)); echo "ok $_name"
    else
        FAIL=$((FAIL + 1)); echo "not ok $_name"
    fi
}

# -- new ---------------------------------------------------------------

test_01_new_creates_file_with_three_line_content() {
    call_cli new "$TMP/hello"   # no suffix: f3dc appends .f3d
    assert_eq "$RC" 0
    assert_file "$TMP/hello.f3d"
    assert_eq "$(cat "$TMP/hello.f3d")" "$STARTER"
    assert_eq "$(wc -l < "$TMP/hello.f3d" | tr -d ' ')" 3
}

test_02_new_again_exits_3_and_keeps_original() {
    call_cli new "$TMP/twice"
    assert_eq "$RC" 0
    call_cli new "$TMP/twice"
    assert_eq "$RC" 3
    assert_contains "$ERR" "already exists"
    assert_eq "$(cat "$TMP/twice.f3d")" "$STARTER"
}

# -- check -------------------------------------------------------------

test_03_check_valid_scene_exits_0() {
    call_cli check "$TMP/valid.f3d"
    assert_eq "$RC" 0
    assert_contains "$OUT" "OK:"
}

test_04_check_unknown_colour_exits_1_with_e202() {
    call_cli check "$TMP/bad.f3d"
    assert_eq "$RC" 1
    assert_contains "$OUT$ERR" "E202"
}

test_05_check_missing_file_exits_3() {
    call_cli check "$TMP/nope.f3d"
    assert_eq "$RC" 3
}

# -- build -------------------------------------------------------------

test_06_build_produces_six_artifacts_and_spares_repo_scene() {
    _repo_scene=$REPO_ROOT/scene.json
    _before_hash=$(sha256sum "$_repo_scene" | awk '{print $1}')
    _before_mtime=$(stat -c %y "$_repo_scene")
    call_cli build "$TMP/still.f3d" -o "$BUILD_DIR"
    assert_eq "$RC" 0
    for _suffix in .scene .json .legacy.json .js .html _scene.f90; do
        assert_nonempty_file "$BUILD_DIR/still$_suffix"
    done
    assert_eq "$(sha256sum "$_repo_scene" | awk '{print $1}')" "$_before_hash"
    assert_eq "$(stat -c %y "$_repo_scene")" "$_before_mtime"
}

# -- run ---------------------------------------------------------------

test_07_run_exits_0_and_produces_output_render_ppm() {
    call_cli run "$TMP/still.f3d" -o "$RUN_DIR"
    assert_eq "$RC" 0 "stderr: $ERR"
    assert_nonempty_file "$RUN_DIR/output_render.ppm"
    assert_eq "$(head -c 2 "$RUN_DIR/output_render.ppm")" "P3"
}

test_08_bare_invocation_behaves_as_run() {
    call_cli "$TMP/still.f3d" -o "$TMP/bare-out"
    assert_eq "$RC" 0 "stderr: $ERR"
    assert_nonempty_file "$TMP/bare-out/output_render.ppm"
}

# -- doctor / fmt --------------------------------------------------------

test_09_doctor_exits_0() {
    call_cli doctor
    assert_eq "$RC" 0
    assert_contains "$OUT" "gfortran"
}

test_10_fmt_prints_canonical_line_containing_cube() {
    call_cli fmt "$TMP/valid.f3d"
    assert_eq "$RC" 0
    _line=$(printf '%s\n' "$OUT" | grep cube | head -n 1)
    if [ -z "$_line" ]; then fail_msg "no line containing 'cube' in fmt output: $OUT"; fi
    assert_contains "$_line" "cube red"
}

run_check test_01_new_creates_file_with_three_line_content test_01_new_creates_file_with_three_line_content
run_check test_02_new_again_exits_3_and_keeps_original test_02_new_again_exits_3_and_keeps_original
run_check test_03_check_valid_scene_exits_0 test_03_check_valid_scene_exits_0
run_check test_04_check_unknown_colour_exits_1_with_e202 test_04_check_unknown_colour_exits_1_with_e202
run_check test_05_check_missing_file_exits_3 test_05_check_missing_file_exits_3
run_check test_06_build_produces_six_artifacts_and_spares_repo_scene test_06_build_produces_six_artifacts_and_spares_repo_scene
run_check test_07_run_exits_0_and_produces_output_render_ppm test_07_run_exits_0_and_produces_output_render_ppm
run_check test_08_bare_invocation_behaves_as_run test_08_bare_invocation_behaves_as_run
run_check test_09_doctor_exits_0 test_09_doctor_exits_0
run_check test_10_fmt_prints_canonical_line_containing_cube test_10_fmt_prints_canonical_line_containing_cube

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
