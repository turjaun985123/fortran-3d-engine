#!/bin/sh
# Wave 5 Slice X3 -- VIDEO EXPORT end-to-end tests.
#
# Drives the REAL engine (`bin/engine3d`) on the REAL golden film
# (examples/anim-golden.f3d, built by this suite with the real
# f3dc): 48 frames at 24 fps, 320x240, two spans, the second
# opening with an 8-frame DISSOLVE transition -- so a digest match
# against a plain render also proves transitions are rendered
# through the export path, not skipped or re-implemented.
#
# Spec: ANIM-PLAN 4.5 + Wave 5 exit criteria, hardened in X3:
#   * `engine3d <film>.timeline.json --video out.mp4` assembles
#     the numbered frames (frame 1 = the un-numbered base file;
#     ffmpeg image2 over '<base>_%04d<ext>') at the FILM fps.
#     Before X3, film mode ignored --video entirely: exit 0, no
#     mp4, no message -- silent success-without-video.
#   * Export is a render, not a re-implementation: the exported
#     frames' sequence digest (G3e method: sha256 of the
#     concatenation of the numbered frames in order) equals the
#     digest of a plain (non-video) render of the same timeline
#     in the same suite run, and a second export is identical.
#   * The documented 2-frame smoke check on the %04d pattern
#     construction (ANIM-PLAN 4.5): frames _0001/_0002 alone,
#     assembled with the exact documented command, make a
#     2-frame mp4 (or, without ffmpeg, the pattern target files
#     themselves are asserted present).
#   * ffmpeg ABSENT (PATH without ffmpeg): exit 0, all frames
#     kept, NO mp4, and a LOUD stderr warning naming ffmpeg,
#     stating the frames are kept, and printing the exact
#     assembly command the user can run.
#   * ffmpeg present but FAILING (fake ffmpeg that answers
#     -version but fails assembly): exit 0, frames kept, stderr
#     note -- the Phase-8 design, kept by X3.
#   * Frame WRITE failure (render CWD = /proc, unwritable even
#     for root): non-zero exit with a 'failed to write'
#     diagnostic, not a runtime crash or silent success.
#   * If ffmpeg IS present on this machine, the exported .mp4
#     must exist, be non-trivial in size, and (when ffprobe is
#     present) contain exactly 48 frames. If ffmpeg is absent
#     here, that check instead asserts the absent-path behaviour
#     on the main export (frames + warning, no mp4).
#
# Standalone-runnable from any CWD:  sh tests/e2e/test_export_e2e.sh
# Discovered by tests/run_tests.sh (e2e layer globs test_*.sh and
# counts the ": PASS (N checks)" line).
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BASE=$(basename -- "$0")

# F3DC / engine resolution mirrors the other e2e suites.
if [ "${F3DC:-}" ]; then
    F3DC_BIN=$F3DC
elif [ -f "$REPO_ROOT/bin/f3dc" ]; then
    F3DC_BIN=$REPO_ROOT/bin/f3dc
else
    F3DC_BIN=$REPO_ROOT/compiler/f3dc
fi
if [ "${ENGINE3D:-}" ]; then
    ENGINE_BIN=$ENGINE3D
else
    ENGINE_BIN=$REPO_ROOT/bin/engine3d
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
fail_msg() { echo "  FAIL: $1"; }
run_check() {
    _name=$1; shift
    echo "check: $_name"
    if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
assert_eq() { # got want msg
    if [ "$1" != "$2" ]; then fail_msg "$3 (got '$1', want '$2')"; return 1; fi
}
assert_contains() { # file needle msg
    if ! grep -qF "$2" "$1"; then fail_msg "$3 (missing: $2)"; return 1; fi
}

HAVE_FFMPEG=0
command -v ffmpeg >/dev/null 2>&1 && HAVE_FFMPEG=1
HAVE_FFPROBE=0
command -v ffprobe >/dev/null 2>&1 && HAVE_FFPROBE=1

# --- build the golden film's timeline -----------------------------
mkdir -p "$TMP/src"
cp "$REPO_ROOT/examples/anim-golden.f3d" "$TMP/src/"
( cd "$TMP/src" && "$F3DC_BIN" build anim-golden.f3d >build.log 2>&1 )
TIMELINE=$TMP/src/build/anim-golden.timeline.json

# render_plain DIR | render_video DIR VIDEO_NAME [extra env via env(1) at call site]
render_in() { # dir args...
    _dir=$1; shift
    mkdir -p "$_dir"
    ( cd "$_dir" && "$ENGINE_BIN" "$@" >stdout.log 2>stderr.log )
    echo $?
}
seq_digest() { # dir -> sha256 of cat of numbered frames in order (G3e method)
    ( cd "$1" && cat output_render_[0-9]*.ppm ) | sha256sum | cut -d' ' -f1
}
frame_count() { # dir -> number of numbered frame files
    ls "$1"/output_render_[0-9]*.ppm 2>/dev/null | wc -l | tr -d ' '
}
file_sha() { sha256sum "$1" | cut -d' ' -f1; }

check_build_timeline() {
    [ -f "$TIMELINE" ] || { fail_msg "f3dc build produced no timeline (see $TMP/src/build.log)"; return 1; }
    grep -q '"duration_frames":48' "$TIMELINE" || \
        { fail_msg "timeline duration_frames is not 48"; return 1; }
    grep -q '"num":24' "$TIMELINE" || \
        { fail_msg "timeline fps is not 24"; return 1; }
}

# --- plain (non-video) render: the reference ----------------------
PLAIN_RC=$(render_in "$TMP/plain" "$TIMELINE")
PLAIN_DIGEST=$(seq_digest "$TMP/plain")

check_plain_frame_count_and_base() {
    assert_eq "$PLAIN_RC" 0 "plain render exit code" || return 1
    assert_eq "$(frame_count "$TMP/plain")" 48 "plain render numbered frame count" || return 1
    [ -f "$TMP/plain/output_render.ppm" ] || \
        { fail_msg "frame 1 base file output_render.ppm missing"; return 1; }
    assert_eq "$(file_sha "$TMP/plain/output_render.ppm")" \
        "$(file_sha "$TMP/plain/output_render_0001.ppm")" \
        "base file must be byte-identical to frame _0001 (frame 1 convention)"
}
check_plain_digest_wellformed() {
    case $PLAIN_DIGEST in
        ????????????????????????????????????????????????????????????????) ;;
        *) fail_msg "plain sequence digest malformed: '$PLAIN_DIGEST'"; return 1 ;;
    esac
    # Frame _0032 is the dissolve midpoint (V4-GOLDENS): it must
    # differ from its neighbours or no transition was blended.
    [ "$(file_sha "$TMP/plain/output_render_0032.ppm")" != \
      "$(file_sha "$TMP/plain/output_render_0028.ppm")" ] || \
        { fail_msg "frame 0032 equals the last pre-transition frame; dissolve not rendered"; return 1; }
}

# --- export 1: --video ---------------------------------------------
EXP1_RC=$(render_in "$TMP/exp1" "$TIMELINE" --video out.mp4)
EXP1_DIGEST=$(seq_digest "$TMP/exp1")

check_export_frame_count() {
    assert_eq "$EXP1_RC" 0 "export exit code" || return 1
    assert_eq "$(frame_count "$TMP/exp1")" 48 "export numbered frame count" || return 1
    [ -f "$TMP/exp1/output_render.ppm" ] || \
        { fail_msg "export frame 1 base file missing"; return 1; }
}
check_export_digest_matches_plain() {
    assert_eq "$EXP1_DIGEST" "$PLAIN_DIGEST" \
        "export sequence digest must equal the plain render's (export is a render)"
}
check_export_transition_frame_matches_plain() {
    assert_eq "$(file_sha "$TMP/exp1/output_render_0032.ppm")" \
        "$(file_sha "$TMP/plain/output_render_0032.ppm")" \
        "dissolve midpoint frame 0032 must match the plain render byte-for-byte"
}
check_export_mp4_or_absent_behaviour() {
    if [ "$HAVE_FFMPEG" = 1 ]; then
        [ -f "$TMP/exp1/out.mp4" ] || { fail_msg "ffmpeg present but no out.mp4 written"; return 1; }
        _sz=$(wc -c < "$TMP/exp1/out.mp4" | tr -d ' ')
        [ "$_sz" -gt 10000 ] || { fail_msg "out.mp4 trivially small: $_sz bytes"; return 1; }
        if [ "$HAVE_FFPROBE" = 1 ]; then
            _nf=$(ffprobe -v error -count_frames -select_streams v:0 \
                  -show_entries stream=nb_read_frames -of csv=p=0 \
                  "$TMP/exp1/out.mp4" 2>/dev/null | tr -d ' \r')
            assert_eq "$_nf" 48 "mp4 frame count via ffprobe (proves the %04d pattern matched all frames)" || return 1
        fi
    else
        # ffmpeg absent on this machine: the main export itself
        # must show the documented absent behaviour.
        [ ! -e "$TMP/exp1/out.mp4" ] || { fail_msg "no ffmpeg, yet an mp4 appeared"; return 1; }
        assert_contains "$TMP/exp1/stderr.log" "ffmpeg not found" \
            "absent-ffmpeg export must warn loudly" || return 1
    fi
}

# --- export 2: determinism ------------------------------------------
EXP2_RC=$(render_in "$TMP/exp2" "$TIMELINE" --video out.mp4)
check_second_export_identical() {
    assert_eq "$EXP2_RC" 0 "second export exit code" || return 1
    assert_eq "$(seq_digest "$TMP/exp2")" "$EXP1_DIGEST" \
        "second export sequence digest must equal the first"
}

# --- documented 2-frame smoke check on the %04d pattern -------------
check_pattern_smoke_2frame() {
    mkdir -p "$TMP/smoke"
    cp "$TMP/exp1/output_render_0001.ppm" "$TMP/exp1/output_render_0002.ppm" \
       "$TMP/smoke/"
    if [ "$HAVE_FFMPEG" = 1 ]; then
        ( cd "$TMP/smoke" && ffmpeg -y -framerate 24 -f image2 \
            -i 'output_render_%04d.ppm' -c:v libx264 -pix_fmt yuv420p \
            smoke.mp4 >ffmpeg.log 2>&1 ) || \
            { fail_msg "2-frame pattern smoke: ffmpeg assembly failed"; return 1; }
        [ -s "$TMP/smoke/smoke.mp4" ] || \
            { fail_msg "2-frame pattern smoke produced no mp4"; return 1; }
        if [ "$HAVE_FFPROBE" = 1 ]; then
            _nf=$(ffprobe -v error -count_frames -select_streams v:0 \
                  -show_entries stream=nb_read_frames -of csv=p=0 \
                  "$TMP/smoke/smoke.mp4" 2>/dev/null | tr -d ' \r')
            assert_eq "$_nf" 2 "2-frame smoke mp4 frame count" || return 1
        fi
    else
        # No ffmpeg: the pattern's targets are the assertion.
        [ -f "$TMP/smoke/output_render_0001.ppm" ] && \
        [ -f "$TMP/smoke/output_render_0002.ppm" ] || \
            { fail_msg "pattern target frames _0001/_0002 missing"; return 1; }
    fi
}

# --- ffmpeg absent: minimal PATH without ffmpeg ----------------------
# A PATH dir holding only a harmless placeholder: the engine binary
# itself is invoked by absolute path; inside, its ffmpeg probe must
# find nothing. (Deliberately NOT symlinking ffmpeg.)
mkdir -p "$TMP/nobin"
ln -s /bin/true "$TMP/nobin/true" 2>/dev/null || cp /bin/true "$TMP/nobin/true"
mkdir -p "$TMP/noff"
NOFF_RC=$( cd "$TMP/noff" && env PATH="$TMP/nobin" \
    "$ENGINE_BIN" "$TIMELINE" --video out.mp4 >stdout.log 2>stderr.log; echo $? )

check_ffmpeg_absent_frames_and_warning() {
    assert_eq "$NOFF_RC" 0 "ffmpeg-absent export exit code (documented: 0 with frames)" || return 1
    assert_eq "$(frame_count "$TMP/noff")" 48 "ffmpeg-absent frame count" || return 1
    [ ! -e "$TMP/noff/out.mp4" ] || { fail_msg "ffmpeg absent but an mp4 was written"; return 1; }
    assert_contains "$TMP/noff/stderr.log" "warning:" \
        "absent warning must be a warning" || return 1
    assert_contains "$TMP/noff/stderr.log" "ffmpeg not found on PATH" \
        "absent warning must name ffmpeg" || return 1
    assert_contains "$TMP/noff/stderr.log" "frame files kept" \
        "absent warning must state the frames are kept" || return 1
    assert_contains "$TMP/noff/stderr.log" \
        "ffmpeg -y -framerate 24 -f image2 -i 'output_render_%04d.ppm' -c:v libx264 -pix_fmt yuv420p 'out.mp4'" \
        "absent warning must print the exact assembly command" || return 1
    # And the kept frames are the real film, digest included.
    assert_eq "$(seq_digest "$TMP/noff")" "$PLAIN_DIGEST" \
        "ffmpeg-absent frames must be the full film render"
}

# --- ffmpeg present but failing ---------------------------------------
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/ffmpeg" <<'EOF'
#!/bin/sh
# Answers -version like a working ffmpeg, fails anything else:
# "present but failing" for the assembly step.
case "$1" in
    -version|--version) echo "ffmpeg version fake-e2e"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/fakebin/ffmpeg"
mkdir -p "$TMP/fakefail"
FAKE_RC=$( cd "$TMP/fakefail" && env PATH="$TMP/fakebin:$PATH" \
    "$ENGINE_BIN" "$TIMELINE" --video out.mp4 >stdout.log 2>stderr.log; echo $? )

check_ffmpeg_failing_frames_kept_note() {
    assert_eq "$FAKE_RC" 0 "ffmpeg-failing export exit code (Phase-8 design: non-fatal)" || return 1
    assert_eq "$(frame_count "$TMP/fakefail")" 48 "ffmpeg-failing frame count" || return 1
    assert_contains "$TMP/fakefail/stderr.log" "ffmpeg failed" \
        "ffmpeg-failing must note the failure on stderr" || return 1
    assert_contains "$TMP/fakefail/stderr.log" "frame files kept" \
        "ffmpeg-failing note must state the frames are kept" || return 1
}

# --- frame write failure: non-zero exit + diagnostic -------------------
check_write_failure_nonzero() {
    [ -d /proc ] || { fail_msg "/proc unavailable for the unwritable-CWD check"; return 1; }
    ( cd /proc && "$ENGINE_BIN" "$TIMELINE" >"$TMP/wfail.out" 2>"$TMP/wfail.err" )
    _rc=$?
    [ "$_rc" -ne 0 ] || { fail_msg "write failure exited 0 (silent success)"; return 1; }
    assert_contains "$TMP/wfail.err" "failed to write" \
        "write failure must print a 'failed to write' diagnostic" || return 1
    if grep -q "Fortran runtime error" "$TMP/wfail.err"; then
        fail_msg "write failure still aborts with a Fortran runtime error"; return 1
    fi
}

run_check build_golden_timeline check_build_timeline
run_check plain_frame_count_and_base_convention check_plain_frame_count_and_base
run_check plain_digest_and_dissolve_present check_plain_digest_wellformed
run_check export_frame_count check_export_frame_count
run_check export_digest_matches_plain check_export_digest_matches_plain
run_check export_transition_frame_matches_plain check_export_transition_frame_matches_plain
run_check export_mp4_or_absent_behaviour check_export_mp4_or_absent_behaviour
run_check second_export_identical_digest check_second_export_identical
run_check pattern_smoke_2frame check_pattern_smoke_2frame
run_check ffmpeg_absent_frames_and_loud_warning check_ffmpeg_absent_frames_and_warning
run_check ffmpeg_failing_frames_kept_note check_ffmpeg_failing_frames_kept_note
run_check write_failure_nonzero_with_diagnostic check_write_failure_nonzero

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
