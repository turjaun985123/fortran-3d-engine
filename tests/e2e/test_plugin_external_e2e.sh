#!/bin/sh
# Wave 5 Slice E2 -- plugin EXTERNALIZATION absent-plugin PROOF tests.
#
# These tests are the gate that makes the user ruling in
# docs/ANIM-WAVES.md ("Plugin externalization (user ruling,
# 2026-11-26)": stickman is an external package under plugins/,
# NOT built into the core) real:
#
#   (a) with the stickman package ABSENT, the core still works,
#       and a film using a stickman character fails with a clean
#       diagnostic NAMING the missing plugin;
#   (b) with the package PRESENT, outputs are byte-identical to
#       today (asserted here as determinism within the present
#       world -- see the byte-identity note below).
#
# The loader interface these tests are written against is FIXED
# by the Wave 5 coordinator (the implementation lands in slice
# E1, in parallel):
#
#   * F3DC_PLUGIN_PATH, when set, is the COMPLETE plugin search
#     list: colon-separated directories, each a package ROOT
#     containing <plugin-id>/ package directories (mirroring the
#     default roots below, which contain stickman/). An EMPTY
#     STRING means no plugins load at all.
#   * When F3DC_PLUGIN_PATH is unset, the defaults apply: the
#     repo plugins/ directory plus ./plugins.
#   * Packages live at plugins/stickman/ in the repo.
#   * A film using a character whose plugin is not loaded fails
#     with a clean diagnostic naming the missing plugin id
#     `stickman` and carrying a new E2xx code.
#   * With plugins present, outputs are byte-identical to today.
#
# Builds run with cwd=$REPO_ROOT so that BOTH default roots are
# reachable in the present world (repo plugins/ relative to the
# repo, and ./plugins = $REPO_ROOT/plugins), whichever anchor the
# E1 loader uses for the repo default.
#
# Timeline IR field shape (verified against an existing build,
# build/anim-golden.timeline.json, and a fresh build of the film
# below): the IR is compact JSON; each characters[] entry carries
# the plugin id as  "plugin":"stickman"  and each resolved action
# track carries a non-empty "keys":[...] array and omits
# "resolved":false. Those are the exact shapes asserted here.
#
# Byte-identity choice (check 7): this suite asserts DETERMINISM
# within the present world (the same plain `f3dc build` of the
# same source file, twice, into two clean output dirs, must give
# identical .timeline.json / .scene / .json hashes) plus the
# present-world structure (check 2). It deliberately does NOT pin
# hashes recorded from today's pre-externalization binary: such
# pins would couple this gate to every legitimate future pin
# rebake, and byte-identity against HISTORY is already carried by
# the native corpus pins and the tests/ir fixtures. The one
# pre-existing wrinkle: a .scene file embeds a `# sha256:` header
# line whose value is sensitive to the source file's PATH (same
# content at a different path hashes differently -- verified by
# hand, unrelated to plugins), so both builds use the SAME source
# path and differ only in output dir, which is the variable the
# plugin ruling cares about.
#
# Standalone-runnable from any CWD:
#   sh tests/e2e/test_plugin_external_e2e.sh
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

# =====================================================================
# CONFIG -- the ONE place the integration pins live.
#
# MISSING_PLUGIN_ECODE: the E2xx code the E1 loader emits when a
# film needs a plugin that is not loaded. The diagnostics census
# currently tops out at E213, so the expected next-free code is
# E214. *** PIN AT INTEGRATION: when E1 lands, set this to the
# exact code E1 chose (here, or via the F3DC_MISSING_PLUGIN_ECODE
# environment override) -- do not weaken the checks to match. ***
#
# DIAGNOSTIC_EXIT: this repo's normal diagnostic exit code. E-code
# diagnostics exit 1 (e.g. an E202 build failure exits 1, writes
# the diagnostic to stderr, and emits no artifacts); usage / file
# errors exit 3 and crashes would surface as >=128 or a timeout
# (124). A clean plugin diagnostic must be DIAGNOSTIC_EXIT.
# =====================================================================
MISSING_PLUGIN_ECODE=${F3DC_MISSING_PLUGIN_ECODE:-E214}
DIAGNOSTIC_EXIT=1

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
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
rc_of() { cat "$TMP/$1.rc"; }

# --- build runner --------------------------------------------------
# do_build <tag> <mode> <src> <outdir>
#   mode "unset" : F3DC_PLUGIN_PATH removed from the environment
#                  (defaults apply: repo plugins/ + ./plugins)
#   mode "empty" : F3DC_PLUGIN_PATH="" (complete list = no plugins)
#   mode <path>  : F3DC_PLUGIN_PATH=<path> (complete list)
# Captures stdout/stderr to $TMP/<tag>.out / .err and the exit code
# to $TMP/<tag>.rc. Every build is wrapped in `timeout 60` when
# timeout(1) is available, so a loader hang surfaces as rc 124 and
# fails the diagnostic checks instead of hanging the suite.
if command -v timeout >/dev/null 2>&1; then TIMEOUT="timeout 60"; else TIMEOUT=""; fi
do_build() {
    _tag=$1; _mode=$2; _src=$3; _out=$4
    case $_mode in
        unset)
            (cd "$REPO_ROOT" && env -u F3DC_PLUGIN_PATH $TIMEOUT \
                "$F3DC_BIN" build "$_src" -o "$_out" \
                >"$TMP/$_tag.out" 2>"$TMP/$_tag.err"); echo $? > "$TMP/$_tag.rc" ;;
        empty)
            (cd "$REPO_ROOT" && F3DC_PLUGIN_PATH= $TIMEOUT \
                "$F3DC_BIN" build "$_src" -o "$_out" \
                >"$TMP/$_tag.out" 2>"$TMP/$_tag.err"); echo $? > "$TMP/$_tag.rc" ;;
        *)
            (cd "$REPO_ROOT" && F3DC_PLUGIN_PATH="$_mode" $TIMEOUT \
                "$F3DC_BIN" build "$_src" -o "$_out" \
                >"$TMP/$_tag.out" 2>"$TMP/$_tag.err"); echo $? > "$TMP/$_tag.rc" ;;
    esac
}

# --- sources ---------------------------------------------------------
mkdir -p "$TMP/src"

# The stickman film (checks 1, 2, 3, 4, 7, 8): a single-scene film
# with one stickman character, one dialogue line (24 frames) and
# one resolved plugin verb (waves, 0.417 s = 10 frames) = 34
# frames at 24 fps. ONE canonical file at ONE path is used for
# every build of it (see the .scene path note in the header).
cat > "$TMP/src/plugin-film.f3d" <<'F3DEOF'
film "Plugin Film" size 320 240 fps 24
scene "only" size 320 240 background white
camera at 0 3 10 look 0 1 0
plane ground gray at 0 -2 0 size 16
cube bench red at 3 0 0 size 2
place bench-front at 1 0 2
character ada blue at -3 0 2 tall head round wears cap red
ada says "Hello bench" for 1 second
ada waves for 0.417 seconds
render "output_render.ppm"
F3DEOF

# A plain non-film scene (check 5): the 3-line starter contract.
cat > "$TMP/src/plugin-cube.f3d" <<'F3DEOF'
cube red
spin it
render
F3DEOF

# A film with NO characters (check 6): camera moves only. The
# language accepts this today (verified: it builds, its timeline
# carries "characters":[] and one camera track), so no fallback
# to an objects-only non-film scene is needed.
cat > "$TMP/src/plugin-nochar.f3d" <<'F3DEOF'
film "No Characters" size 320 240 fps 24
scene "only" size 320 240 background white
camera at 0 3 10 look 0 1 0
plane ground gray at 0 -2 0 size 16
cube bench red at 3 0 0 size 2
together
  camera pans to bench in 0.75 seconds ease smooth
end
render "output_render.ppm"
F3DEOF

FILM_SRC=$TMP/src/plugin-film.f3d
FILM_TL=plugin-film.timeline.json

# --- JSON assertion helper (node, as in test_playback_e2e.sh) -------
cat > "$TMP/json_assert.js" <<'JSEOF'
// usage: node json_assert.js present <timeline.json>
const fs = require('fs');
let doc;
try { doc = JSON.parse(fs.readFileSync(process.argv[3], 'utf8')); }
catch (e) { console.error('not JSON: ' + e.message); process.exit(1); }
function bad(m) { console.error(m); process.exit(1); }
if (!Array.isArray(doc.characters)) bad('characters is not an array');
const ada = doc.characters.find(c => c.id === 'ada');
if (!ada) bad('no character ada in ' + JSON.stringify(doc.characters));
if (ada.plugin !== 'stickman')
  bad('ada.plugin is ' + JSON.stringify(ada.plugin) + ', want "stickman"');
if (!Array.isArray(doc.dialogue) || doc.dialogue.length !== 1)
  bad('dialogue length ' + (doc.dialogue || []).length);
const d = doc.dialogue[0] || {};
if (d.speaker !== 'ada' || d.text !== 'Hello bench')
  bad('dialogue cue ' + JSON.stringify(d));
if (!Array.isArray(doc.tracks)) bad('tracks is not an array');
const wave = doc.tracks.find(t => t.kind === 'action' && t.action === 'wave');
if (!wave) bad('no wave action track');
if (wave.resolved === false) bad('wave track is still resolved:false');
if (!Array.isArray(wave.keys) || wave.keys.length === 0)
  bad('wave track has no resolved keys');
JSEOF
json_assert_present() { # timelinefile
    if ! command -v node >/dev/null 2>&1; then
        fail_msg "node absent: cannot assert timeline JSON"; return 1
    fi
    node "$TMP/json_assert.js" present "$1" 2>"$TMP/json.err" || {
        fail_msg "timeline JSON assertion: $(cat "$TMP/json.err")"; return 1; }
}

# --- scenario builds (run once, asserted by the checks below) --------
do_build present unset "$FILM_SRC" "$TMP/out-present-a"
do_build absent  empty "$FILM_SRC" "$TMP/out-absent"
do_build nonfilm empty "$TMP/src/plugin-cube.f3d" "$TMP/out-nonfilm"
do_build nochar  empty "$TMP/src/plugin-nochar.f3d" "$TMP/out-nochar"

# --- check 1: PRESENT world -- the stickman film builds --------------
check_present_film_builds() {
    assert_eq "$(rc_of present)" 0 \
        "present-world film build must exit 0 (stderr: $(cat "$TMP/present.err"))" || return 1
    [ -s "$TMP/out-present-a/$FILM_TL" ] || {
        fail_msg "present build emitted no $FILM_TL"; return 1; }
}

# --- check 2: PRESENT world -- IR names the plugin, actions resolved -
check_present_timeline_plugin_and_resolved() {
    _tl=$TMP/out-present-a/$FILM_TL
    [ -s "$_tl" ] || { fail_msg "no present timeline to inspect"; return 1; }
    assert_contains "$_tl" '"plugin":"stickman"' \
        "timeline characters must carry the stickman plugin id" || return 1
    json_assert_present "$_tl"
}

# --- check 3: ABSENT world -- film fails, diagnostic names the plugin
check_absent_film_fails_naming_plugin() {
    _rc=$(rc_of absent)
    if [ "$_rc" = 124 ]; then
        fail_msg "absent-world film build TIMED OUT (loader hang?)"; return 1
    fi
    if [ "$_rc" -ge 128 ]; then
        fail_msg "absent-world film build died by signal (rc $_rc -- crash, not a diagnostic)"; return 1
    fi
    assert_eq "$_rc" "$DIAGNOSTIC_EXIT" \
        "absent-world film build must fail with the normal diagnostic exit" || return 1
    assert_contains "$TMP/absent.err" 'stickman' \
        "absent-world diagnostic must NAME the missing plugin id" || return 1
    assert_contains "$TMP/absent.err" "$MISSING_PLUGIN_ECODE" \
        "absent-world diagnostic must carry the missing-plugin code (PIN AT INTEGRATION if E1 chose another code -- see CONFIG)" || return 1
}

# --- check 4: ABSENT world -- no successful build artifacts ----------
check_absent_film_emits_no_timeline() {
    if [ -e "$TMP/out-absent/$FILM_TL" ]; then
        fail_msg "absent-world build emitted $FILM_TL despite failing"; return 1
    fi
    if [ -d "$TMP/out-absent" ]; then
        _found=$(find "$TMP/out-absent" \( -name '*.timeline.json' -o -name '*.scene' \) -print | head -n 1)
        if [ -n "$_found" ]; then
            fail_msg "absent-world build left a successful-build artifact: $_found"; return 1
        fi
    fi
}

# --- check 5: ABSENT world -- core works without any plugin ----------
check_absent_nonfilm_scene_builds() {
    assert_eq "$(rc_of nonfilm)" 0 \
        "non-film scene must build with F3DC_PLUGIN_PATH=\"\" (stderr: $(cat "$TMP/nonfilm.err"))" || return 1
    [ -s "$TMP/out-nonfilm/plugin-cube.scene" ] || {
        fail_msg "non-film absent-world build emitted no .scene"; return 1; }
}

# --- check 6: ABSENT world -- a characterless film builds ------------
check_absent_characterless_film_builds() {
    assert_eq "$(rc_of nochar)" 0 \
        "characterless film must build with F3DC_PLUGIN_PATH=\"\" (stderr: $(cat "$TMP/nochar.err"))" || return 1
    _tl=$TMP/out-nochar/plugin-nochar.timeline.json
    [ -s "$_tl" ] || { fail_msg "characterless film emitted no timeline"; return 1; }
    assert_contains "$_tl" '"characters":[]' \
        "characterless film timeline must have no characters"
}

# --- check 7: PRESENT world -- byte-identity (determinism) -----------
check_present_byte_identity_two_dirs() {
    do_build present2 unset "$FILM_SRC" "$TMP/out-present-b"
    assert_eq "$(rc_of present2)" 0 \
        "second present-world build must exit 0 (stderr: $(cat "$TMP/present2.err"))" || return 1
    for _suffix in timeline.json scene json; do
        _a=$TMP/out-present-a/plugin-film.$_suffix
        _b=$TMP/out-present-b/plugin-film.$_suffix
        [ -s "$_a" ] && [ -s "$_b" ] || {
            fail_msg "missing artifact for byte-identity: plugin-film.$_suffix"; return 1; }
        assert_eq "$(sha_of "$_a")" "$(sha_of "$_b")" \
            "plugin-film.$_suffix must be byte-identical across two clean present-world builds" || return 1
    done
}

# --- check 8: bogus package -- clean diagnostic, never a crash -------
check_bogus_package_fails_cleanly() {
    # A package ROOT holding a stickman/ directory with no valid
    # manifest under any plausible package format: every candidate
    # manifest/declaration file is malformed garbage. Any loader
    # must reject this with a diagnostic -- silently loading it,
    # crashing, or hanging all fail this check.
    _root=$TMP/bogusroot
    mkdir -p "$_root/stickman"
    printf 'this is not a valid plugin manifest [[[ \n' > "$_root/stickman/plugin.toml"
    printf '{ this is not json \n' > "$_root/stickman/manifest.json"
    printf 'not a manifest at all\n' > "$_root/stickman/plugin.json"
    printf 'garbage declarations, no structure\n' > "$_root/stickman/declarations.txt"
    do_build bogus "$_root" "$FILM_SRC" "$TMP/out-bogus"
    _rc=$(rc_of bogus)
    if [ "$_rc" = 124 ]; then
        fail_msg "bogus-package build TIMED OUT (loader hang?)"; return 1
    fi
    if [ "$_rc" -ge 128 ]; then
        fail_msg "bogus-package build died by signal (rc $_rc -- crash, not a diagnostic)"; return 1
    fi
    assert_eq "$_rc" "$DIAGNOSTIC_EXIT" \
        "bogus package must fail the build with the normal diagnostic exit" || return 1
    [ -s "$TMP/bogus.err" ] || {
        fail_msg "bogus-package failure wrote nothing to stderr"; return 1; }
    if grep -qi 'segmentation' "$TMP/bogus.err" "$TMP/bogus.out"; then
        fail_msg "bogus-package failure mentions a segmentation fault"; return 1
    fi
    if [ -e "$TMP/out-bogus/$FILM_TL" ]; then
        fail_msg "bogus-package build emitted $FILM_TL despite failing"; return 1
    fi
}

run_check present_film_builds check_present_film_builds
run_check present_timeline_plugin_and_resolved check_present_timeline_plugin_and_resolved
run_check absent_film_fails_naming_plugin check_absent_film_fails_naming_plugin
run_check absent_film_emits_no_timeline check_absent_film_emits_no_timeline
run_check absent_nonfilm_scene_builds check_absent_nonfilm_scene_builds
run_check absent_characterless_film_builds check_absent_characterless_film_builds
run_check present_byte_identity_two_dirs check_present_byte_identity_two_dirs
run_check bogus_package_fails_cleanly check_bogus_package_fails_cleanly

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
