#!/bin/sh
# End-to-end tests for Forge3D v2.0 P3: model components --
# `import "part.f3d" as name` (compile-time parts with group
# semantics) and the `mirror x|y|z` object prop.
# Standalone-runnable from any CWD:  sh tests/e2e/test_components_e2e.sh
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BASE=$(basename -- "$0")

if [ "${F3DC:-}" ]; then
    F3DC_BIN=$F3DC
elif [ -f "$REPO_ROOT/bin/f3dc" ]; then
    F3DC_BIN=$REPO_ROOT/bin/f3dc
else
    F3DC_BIN=$REPO_ROOT/compiler/f3dc
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/parts"

# A part: two named objects, one animated by explicit target.
cat > "$TMP/parts/widget.f3d" <<'EOF'
cube blade red at 1 0 0
sphere hub blue at 0 1 0
spin blade speed 90
EOF

# The same content as an import and as a hand-written group.
cat > "$TMP/imp.f3d" <<'EOF'
scene size 64 48
import "parts/widget.f3d" as w at 0 0 0 rotate 0 0 0
render still
EOF
cat > "$TMP/grp.f3d" <<'EOF'
scene size 64 48
group w at 0 0 0 rotate 0 0 0
  cube blade red at 1 0 0
  sphere hub blue at 0 1 0
  spin blade speed 90
end
render still
EOF

# Cycle pair and a restricted part.
cat > "$TMP/a.f3d" <<'EOF'
import "b.f3d" as b
cube x red
EOF
cat > "$TMP/b.f3d" <<'EOF'
import "a.f3d" as a
cube y blue
EOF
cat > "$TMP/cyc.f3d" <<'EOF'
scene size 64 48
import "a.f3d" as a
render still
EOF
cat > "$TMP/badpart.f3d" <<'EOF'
scene size 64 48
cube x red
EOF
cat > "$TMP/usebad.f3d" <<'EOF'
scene size 64 48
import "badpart.f3d" as bp
render still
EOF
cat > "$TMP/missing.f3d" <<'EOF'
scene size 64 48
import "nope.f3d" as np
render still
EOF

# Mirror scenes: asymmetric extrude at the origin, symmetric camera
# (on +z) and an x-symmetric light, so a correct local mirror x must
# render as the horizontal flip of the unmirrored render.
cat > "$TMP/mir.f3d" <<'EOF'
scene size 120 90
camera at 0 0 6 look 0 0 0
light dir 0 -1 -0.7
extrude fin red shape 0,0 1.3,0.25 1.3,1.5 0,2.1 depth 0.18 at 0 -1 -0.09 rotate 0 0 0 mirror x
render still
EOF
sed 's/ mirror x//' "$TMP/mir.f3d" > "$TMP/plain.f3d"

PASS=0
FAIL=0
FAILED_THIS=0

fail_msg() { FAILED_THIS=1; echo "  # $*" >&2; }
assert_eq() { # got want [msg]
    if [ "$1" != "$2" ]; then fail_msg "expected [$2], got [$1] ${3:-}"; fi
}
assert_contains() { # haystack needle
    case $1 in
        *"$2"*) ;;
        *) fail_msg "expected to contain [$2]: [$1]" ;;
    esac
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

call_cli() {
    OUT=$(cd "$TMP" && "$F3DC_BIN" "$@" 2>"$TMP/stderr.txt")
    RC=$?
    ERR=$(cat "$TMP/stderr.txt")
}

# -- checks --------------------------------------------------------------

test_import_matches_group() {
    call_cli build imp.f3d -o imp-out
    assert_eq "$RC" 0 "stderr: $ERR"
    call_cli build grp.f3d -o grp-out
    assert_eq "$RC" 0 "stderr: $ERR"
    for _s in .scene .json .legacy.json .js .html _scene.f90; do
        if ! cmp -s "$TMP/imp-out/imp$_s" "$TMP/grp-out/grp$_s"; then
            fail_msg "import vs group artifact imp$_s differs"
        fi
    done
}

test_import_cycle_e504() {
    call_cli check cyc.f3d
    if [ "$RC" -eq 0 ]; then fail_msg "cycle check exited 0"; fi
    assert_contains "$ERR" "E504"
    assert_contains "$ERR" "import cycle"
}

test_import_missing_e501() {
    call_cli check missing.f3d
    if [ "$RC" -eq 0 ]; then fail_msg "missing-import check exited 0"; fi
    assert_contains "$ERR" "E501"
}

test_import_restricted_part_e103() {
    call_cli check usebad.f3d
    if [ "$RC" -eq 0 ]; then fail_msg "restricted-part check exited 0"; fi
    assert_contains "$ERR" "E103"
}

test_mirror_in_scene_and_json() {
    call_cli build mir.f3d -o mir-out
    assert_eq "$RC" 0 "stderr: $ERR"
    case $(cat "$TMP/mir-out/mir.scene") in
        *"mirror x"*) ;;
        *) fail_msg ".scene line lacks 'mirror x'" ;;
    esac
    case $(cat "$TMP/mir-out/mir.json") in
        *'"mirror": "x"'*) ;;
        *) fail_msg ".json lacks mirror prop" ;;
    esac
}

test_mirror_flips_render() {
    call_cli run mir.f3d -o mir-run
    assert_eq "$RC" 0 "stderr: $ERR"
    call_cli run plain.f3d -o plain-run
    assert_eq "$RC" 0 "stderr: $ERR"
    if cmp -s "$TMP/mir-run/output_render.ppm" "$TMP/plain-run/output_render.ppm"; then
        fail_msg "mirrored render is identical to unmirrored"
    fi
    if ! command -v node >/dev/null 2>&1; then
        fail_msg "node is required for the flip comparison"
        return
    fi
    cat > "$TMP/flip.js" <<'EOF'
const fs = require('fs');
function read(p) {
  const t = fs.readFileSync(p, 'ascii').split(/\s+/).filter(s => s.length);
  return { w: +t[1], h: +t[2], v: t.slice(4).map(Number) };
}
const a = read(process.argv[2]); // mirrored
const b = read(process.argv[3]); // plain
if (a.w !== b.w || a.h !== b.h) process.exit(2);
let diff = 0;
for (let y = 0; y < a.h; y++)
  for (let x = 0; x < a.w; x++)
    for (let c = 0; c < 3; c++) {
      const ia = (y * a.w + x) * 3 + c;
      const ib = (y * a.w + (a.w - 1 - x)) * 3 + c;
      if (a.v[ia] !== b.v[ib]) diff++;
    }
const total = a.w * a.h * 3;
// Rasterizer edge tie-breaking is not flip-invariant; a correct
// mirror matches the flipped image on >= 99% of channel values.
if (diff / total > 0.01) { console.error('flip diff ratio', diff / total); process.exit(1); }
EOF
    node "$TMP/flip.js" "$TMP/mir-run/output_render.ppm" \
        "$TMP/plain-run/output_render.ppm" \
        || fail_msg "mirrored render is not the horizontal flip of the plain render"
}

run_check test_import_matches_group test_import_matches_group
run_check test_import_cycle_e504 test_import_cycle_e504
run_check test_import_missing_e501 test_import_missing_e501
run_check test_import_restricted_part_e103 test_import_restricted_part_e103
run_check test_mirror_in_scene_and_json test_mirror_in_scene_and_json
run_check test_mirror_flips_render test_mirror_flips_render

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
