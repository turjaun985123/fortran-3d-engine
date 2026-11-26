#!/bin/sh
# Wave 4 Slice S4 -- preview PLAYBACK end-to-end tests.
#
# Drives the REAL `f3dc preview` server (the same live-server
# pattern as the native layer's SECTION preview in
# tests/native/test_native_compiler.f90: start on --port 0, read
# the URL from the log, curl the routes, SIGINT at the end) and
# asserts the Wave 4 playback surface from ANIM-PLAN 4.4 + the
# Wave 4 exit criteria:
#
#   * GET /__timeline for a film: 200 + the film's Timeline IR
#     document (dialogue / tracks / markers, duration_frames,
#     fps {num, den}). The film used is a SINGLE-SCENE film
#     written by this suite, because the preview pipeline is
#     single-scene by design (pv_compile_pipeline has no
#     multi-scene chunk split): the two-scene
#     examples/anim-golden.f3d fails preview compile with E401
#     "two scene lines", so for it /__timeline serves the empty
#     document -- asserted as a shape-only check below, and the
#     golden film's full timeline content is asserted at build
#     level by tests/compiler/test_playback_js.js. If preview
#     ever gains multi-scene support, strengthen the golden
#     check to the full content assertions.
#   * GET /__timeline for a still: 200 + the well-formed EMPTY
#     document (never a 404), so the page can poll it uniformly.
#   * Non-GET on /__timeline: 501 (pv_route's method gate).
#   * The served / page carries the S3 playback UI by its real
#     element ids: transport bar (f3d-transport / f3d-play /
#     f3d-scrub / f3d-readout), subtitle overlay (f3d-subtitle),
#     action lanes (f3d-lanes), diagnostics drawer (f3d-diags /
#     f3d-diag-toggle / f3d-diag-list), the /__status poll, the
#     /__timeline fetch, and the #t= hash playhead (read via
#     location.hash, written via history.replaceState).
#   * Same request twice -> byte-identical body (page and
#     /__timeline): the HTTP-level form of "same t twice ->
#     identical frame" for a deterministic preview state.
#
# Level note: pv_route lives in the Fortran module
# compiler/src/f3dc_preview.f90, NOT in compiler/preview_http.c,
# so the C harness (tests/native/preview_http_test.c) cannot
# drive it; a real server over loopback HTTP is the honest
# level, and the JS-side seek/frame determinism is covered at
# player + evaluator level by tests/compiler/test_playback_js.js.
#
# JSON bodies are asserted with node (the repo's JS test tool);
# if node is absent those checks fail loudly rather than pass
# on grep alone.
#
# Standalone-runnable from any CWD:  sh tests/e2e/test_playback_e2e.sh
# Discovered by tests/run_tests.sh (e2e layer globs test_*.sh and
# counts the ": PASS (N checks)" line).
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BASE=$(basename -- "$0")

# F3DC resolution mirrors the other e2e suites.
if [ "${F3DC:-}" ]; then
    F3DC_BIN=$F3DC
elif [ -f "$REPO_ROOT/bin/f3dc" ]; then
    F3DC_BIN=$REPO_ROOT/bin/f3dc
else
    F3DC_BIN=$REPO_ROOT/compiler/f3dc
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

# --- JSON assertion helper (node) --------------------------------
cat > "$TMP/json_assert.js" <<'JSEOF'
// usage: node json_assert.js <mode> <file>
// modes: film | still | status
const fs = require('fs');
const mode = process.argv[2];
let doc;
try { doc = JSON.parse(fs.readFileSync(process.argv[3], 'utf8')); }
catch (e) { console.error('not JSON: ' + e.message); process.exit(1); }
const tl = (doc && doc.timeline) ? doc.timeline : doc;
function bad(m) { console.error(m); process.exit(1); }
if (mode === 'film') {
  // The suite's single-scene film: walk 18f + dialogue 24f +
  // wave 10f at 24 fps = 52 frames; dialogue span [18, 42).
  if (tl.format && tl.format !== 'forge3d-timeline')
    bad('format is ' + tl.format);
  if (tl.duration_frames !== 52) bad('duration_frames ' + tl.duration_frames);
  if (!tl.fps || tl.fps.num !== 24 || tl.fps.den !== 1)
    bad('fps ' + JSON.stringify(tl.fps));
  for (const k of ['dialogue', 'tracks', 'markers'])
    if (!Array.isArray(tl[k])) bad(k + ' is not an array');
  if (!tl.tracks.some(t => t.kind === 'camera')) bad('no camera track');
  if (!tl.tracks.some(t => t.kind === 'action' && t.action === 'walk'))
    bad('no walk action track');
  if (!tl.tracks.some(t => t.kind === 'action' && t.action === 'wave'))
    bad('no wave action track');
  if (tl.dialogue.length !== 1) bad('dialogue length ' + tl.dialogue.length);
  const d = tl.dialogue[0] || {};
  if (d.speaker !== 'ada' || d.text !== 'Hello bench' ||
      d.start_frame !== 18 || d.end_frame !== 42)
    bad('dialogue cue ' + JSON.stringify(d));
} else if (mode === 'golden') {
  // Shape only (see header): a multi-scene film does not compile
  // in the single-scene preview, so today this is the empty
  // document; the route must still answer 200 + well-formed IR.
  if (tl.format !== 'forge3d-timeline') bad('format is ' + tl.format);
  for (const k of ['dialogue', 'tracks', 'markers', 'characters'])
    if (!Array.isArray(tl[k])) bad(k + ' is not an array');
  if (typeof tl.duration_frames !== 'number')
    bad('duration_frames is not a number');
} else if (mode === 'still') {
  for (const k of ['dialogue', 'tracks', 'markers'])
    if (!Array.isArray(tl[k]) || tl[k].length !== 0)
      bad(k + ' should be an empty array, got ' + JSON.stringify(tl[k]));
  if (tl.duration_frames != null && tl.duration_frames !== 0)
    bad('duration_frames should be 0/absent, got ' + tl.duration_frames);
} else if (mode === 'status') {
  if (!Array.isArray(doc.diagnostics)) bad('status has no diagnostics array');
  if (doc.ok !== true) bad('status ok should be true for a valid scene');
} else { bad('unknown mode ' + mode); }
JSEOF
json_assert() { # mode file
    if ! command -v node >/dev/null 2>&1; then
        fail_msg "node absent: cannot assert JSON ($1)"; return 1
    fi
    node "$TMP/json_assert.js" "$1" "$2" 2>"$TMP/json.err" || {
        fail_msg "JSON assertion ($1): $(cat "$TMP/json.err")"; return 1; }
}

# --- preview server management -----------------------------------
PV_PID=""; PV_BASE=""
start_preview() { # srcfile workname
    _work=$TMP/$2; mkdir -p "$_work"
    cp "$1" "$_work/scene.f3d"
    (cd "$_work" && nohup "$F3DC_BIN" preview --port 0 --no-browser \
        scene.f3d > preview.log 2>&1 < /dev/null & echo $! > "$TMP/pv.pid")
    PV_PID=$(cat "$TMP/pv.pid")
    PV_BASE=""
    _i=0
    while [ $_i -lt 100 ]; do
        if [ -f "$_work/preview.log" ]; then
            PV_BASE=$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9][0-9]*\).*|\1|p' \
                      "$_work/preview.log" | head -n 1)
            [ -n "$PV_BASE" ] && break
        fi
        sleep 0.2; _i=$((_i + 1))
    done
    [ -n "$PV_BASE" ]
}
stop_preview() {
    if [ -n "$PV_PID" ]; then
        kill -INT "$PV_PID" 2>/dev/null
        _i=0
        while [ $_i -lt 25 ]; do
            kill -0 "$PV_PID" 2>/dev/null || break
            sleep 0.2; _i=$((_i + 1))
        done
        kill -KILL "$PV_PID" 2>/dev/null
        PV_PID=""
    fi
}
http_get() { # path outfile -> prints status
    curl -s -m 5 -o "$2" -w '%{http_code}' "$PV_BASE$1"
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# --- film server --------------------------------------------------
# Single-scene film (see header): walk+camera pan together (18f),
# one dialogue line (24f, frames 18-42), wave (10f) = 52 frames.
cat > "$TMP/film-src.f3d" <<'F3DEOF'
film "Preview Film" size 320 240 fps 24
scene "only" size 320 240 background white
camera at 0 3 10 look 0 1 0
plane ground gray at 0 -2 0 size 16
cube bench red at 3 0 0 size 2
place bench-front at 1 0 2
character ada blue at -3 0 2 tall head round wears cap red
together
  ada walks to bench-front in 0.75 seconds ease smooth
  camera pans to bench in 0.75 seconds ease smooth
end
ada says "Hello bench" for 1 second
ada waves for 0.417 seconds
render "output_render.ppm"
F3DEOF
FILM_OK=0
if start_preview "$TMP/film-src.f3d" film; then
    FILM_OK=1
else
    fail_msg "film preview server did not print a URL in 20s"
fi

check_film_timeline_200() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    _st=$(http_get /__timeline "$TMP/film.timeline.json")
    assert_eq "$_st" 200 "GET /__timeline (film) status"
}
check_film_timeline_content() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    http_get /__timeline "$TMP/film.timeline.json" >/dev/null
    json_assert film "$TMP/film.timeline.json"
}
check_film_timeline_nonget_501() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    _st=$(curl -s -m 5 -X POST -o "$TMP/post.body" -w '%{http_code}' \
          "$PV_BASE/__timeline")
    assert_eq "$_st" 501 "POST /__timeline status"
}
check_film_page_transport() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    http_get / "$TMP/film.page.html" >/dev/null
    assert_contains "$TMP/film.page.html" 'id="f3d-transport"' "transport bar" && \
    assert_contains "$TMP/film.page.html" 'id="f3d-play"' "play button" && \
    assert_contains "$TMP/film.page.html" 'id="f3d-scrub"' "scrub slider" && \
    assert_contains "$TMP/film.page.html" 'type="range"' "scrub is a range input" && \
    assert_contains "$TMP/film.page.html" 'id="f3d-readout"' "t/duration readout"
}
check_film_page_subtitle_lanes() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    http_get / "$TMP/film.page.html" >/dev/null
    assert_contains "$TMP/film.page.html" 'id="f3d-subtitle"' "subtitle overlay" && \
    assert_contains "$TMP/film.page.html" 'id="f3d-lanes"' "action lanes" && \
    assert_contains "$TMP/film.page.html" "fetch('/__timeline'" "page fetches /__timeline"
}
check_film_page_hash_playhead() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    http_get / "$TMP/film.page.html" >/dev/null
    assert_contains "$TMP/film.page.html" 'location.hash' "playhead read from location.hash" && \
    assert_contains "$TMP/film.page.html" '#t=' "hash playhead format #t=<seconds>" && \
    assert_contains "$TMP/film.page.html" 'history.replaceState' "playhead written back to the hash"
}
check_film_page_status_poll_drawer() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    http_get / "$TMP/film.page.html" >/dev/null
    assert_contains "$TMP/film.page.html" "fetch('/__status'" "page polls /__status" && \
    assert_contains "$TMP/film.page.html" 'id="f3d-diags"' "diagnostics drawer" && \
    assert_contains "$TMP/film.page.html" 'id="f3d-diag-toggle"' "drawer toggle" && \
    assert_contains "$TMP/film.page.html" 'id="f3d-diag-list"' "drawer list"
}
check_film_same_request_twice_identical() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    http_get / "$TMP/page.a" >/dev/null; http_get / "$TMP/page.b" >/dev/null
    assert_eq "$(sha_of "$TMP/page.a")" "$(sha_of "$TMP/page.b")" \
        "GET / twice must be byte-identical" || return 1
    http_get /__timeline "$TMP/tl.a" >/dev/null
    http_get /__timeline "$TMP/tl.b" >/dev/null
    assert_eq "$(sha_of "$TMP/tl.a")" "$(sha_of "$TMP/tl.b")" \
        "GET /__timeline twice must be byte-identical"
}
check_film_status_route() {
    [ "$FILM_OK" = 1 ] || { fail_msg "no film server"; return 1; }
    _st=$(http_get /__status "$TMP/film.status.json")
    assert_eq "$_st" 200 "GET /__status (film) status" || return 1
    json_assert status "$TMP/film.status.json"
}

run_check film_timeline_route_200 check_film_timeline_200
run_check film_timeline_content check_film_timeline_content
run_check film_timeline_nonget_501 check_film_timeline_nonget_501
run_check film_page_transport_controls check_film_page_transport
run_check film_page_subtitle_and_lanes check_film_page_subtitle_lanes
run_check film_page_hash_playhead check_film_page_hash_playhead
run_check film_page_status_poll_and_drawer check_film_page_status_poll_drawer
run_check film_same_request_twice_identical check_film_same_request_twice_identical
run_check film_status_route_json check_film_status_route
stop_preview

# --- golden film server (shape only, see header) --------------------
GOLDEN_OK=0
if start_preview "$REPO_ROOT/examples/anim-golden.f3d" golden; then
    GOLDEN_OK=1
else
    fail_msg "golden preview server did not print a URL in 20s"
fi
check_golden_timeline_wellformed() {
    [ "$GOLDEN_OK" = 1 ] || { fail_msg "no golden server"; return 1; }
    _st=$(http_get /__timeline "$TMP/golden.timeline.json")
    assert_eq "$_st" 200 "GET /__timeline (anim-golden) status" || return 1
    json_assert golden "$TMP/golden.timeline.json"
}
run_check golden_timeline_route_wellformed check_golden_timeline_wellformed
stop_preview

# --- still server ---------------------------------------------------
printf 'cube red\nrender\n' > "$TMP/still.f3d"
STILL_OK=0
if start_preview "$TMP/still.f3d" still; then
    STILL_OK=1
else
    fail_msg "still preview server did not print a URL in 20s"
fi

check_still_timeline_empty_doc() {
    [ "$STILL_OK" = 1 ] || { fail_msg "no still server"; return 1; }
    _st=$(http_get /__timeline "$TMP/still.timeline.json")
    assert_eq "$_st" 200 "GET /__timeline (still) status" || return 1
    json_assert still "$TMP/still.timeline.json"
}
check_still_page_transport_shell() {
    [ "$STILL_OK" = 1 ] || { fail_msg "no still server"; return 1; }
    http_get / "$TMP/still.page.html" >/dev/null
    assert_contains "$TMP/still.page.html" 'id="f3d-transport"' \
        "transport shell present for a still" && \
    assert_contains "$TMP/still.page.html" 'id="f3d-subtitle"' \
        "subtitle overlay present for a still"
}

run_check still_timeline_empty_doc check_still_timeline_empty_doc
run_check still_page_transport_shell check_still_page_transport_shell
stop_preview

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
