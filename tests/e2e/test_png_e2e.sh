#!/bin/sh
# End-to-end tests for Forge3D v2.0 P2: native PNG output.
# The engine writes PNG directly when the render output name ends
# in .png (no ImageMagick, no external tools); decoded PNG pixels
# must equal the PPM render of the same scene exactly.
# Standalone-runnable from any CWD:  sh tests/e2e/test_png_e2e.sh
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

PNG_SCENE='scene size 64 48
cube red
render to "out.png" still'
PPM_SCENE='scene size 64 48
cube red
render to "out.ppm" still'
ANIM_SCENE='scene size 64 48
cube spinner red
animate spinner spin y speed 180 duration 1 fps 4
render to "anim.png" duration 1 fps 4'

printf '%s\n' "$PNG_SCENE" > "$TMP/png.f3d"
printf '%s\n' "$PPM_SCENE" > "$TMP/ppm.f3d"
printf '%s\n' "$ANIM_SCENE" > "$TMP/anim.f3d"

PASS=0
FAIL=0
FAILED_THIS=0

fail_msg() { FAILED_THIS=1; echo "  # $*" >&2; }

assert_eq() { # got want [msg]
    if [ "$1" != "$2" ]; then fail_msg "expected [$2], got [$1] ${3:-}"; fi
}
assert_file() { # path
    if [ ! -f "$1" ]; then fail_msg "missing file $1"; fi
}
assert_nonempty_file() { # path
    if [ ! -s "$1" ]; then fail_msg "missing or empty file $1"; fi
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
    OUT=$(cd "$REPO_ROOT" && "$F3DC_BIN" "$@" 2>"$TMP/stderr.txt")
    RC=$?
    ERR=$(cat "$TMP/stderr.txt")
}

png_sig() { # path -> hex of first 8 bytes
    od -An -tx1 -N8 "$1" | tr -d ' \n'
}

# -- checks --------------------------------------------------------------

test_png_run_writes_native_png() {
    call_cli run "$TMP/png.f3d" -o "$TMP/png-out"
    assert_eq "$RC" 0 "stderr: $ERR"
    assert_nonempty_file "$TMP/png-out/out.png"
    assert_eq "$(png_sig "$TMP/png-out/out.png")" "89504e470d0a1a0a" \
        "PNG signature"
    case $OUT in
        *out.png*) ;;
        *) fail_msg "run output does not report out.png: $OUT" ;;
    esac
}

test_png_pixels_equal_ppm() {
    call_cli run "$TMP/ppm.f3d" -o "$TMP/ppm-out"
    assert_eq "$RC" 0 "stderr: $ERR"
    assert_nonempty_file "$TMP/ppm-out/out.ppm"
    if [ ! -f "$TMP/png-out/out.png" ]; then
        call_cli run "$TMP/png.f3d" -o "$TMP/png-out"
        assert_eq "$RC" 0 "stderr: $ERR"
    fi
    if ! command -v node >/dev/null 2>&1; then
        fail_msg "node is required for the PNG pixel comparison"
        return
    fi
    cat > "$TMP/cmp.js" <<'EOF'
const fs = require('fs'), zlib = require('zlib');
const png = fs.readFileSync(process.argv[2]);
if (png.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') process.exit(2);
let off = 8, w = 0, h = 0; const idat = [];
while (off < png.length) {
  const len = png.readUInt32BE(off), type = png.toString('ascii', off + 4, off + 8);
  const data = png.subarray(off + 8, off + 8 + len);
  if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4);
    if (data[8] !== 8 || data[9] !== 2) process.exit(3); }
  if (type === 'IDAT') idat.push(data);
  off += 12 + len;
}
const raw = zlib.inflateSync(Buffer.concat(idat));
const stride = 1 + w * 3;
if (raw.length !== stride * h) process.exit(4);
const pix = [];
for (let y = 0; y < h; y++) {
  if (raw[y * stride] !== 0) process.exit(5); // filter byte must be 0
  for (let i = 0; i < w * 3; i++) pix.push(raw[y * stride + 1 + i]);
}
const toks = fs.readFileSync(process.argv[3], 'ascii').split(/\s+/).filter(s => s.length);
if (toks[0] !== 'P3') process.exit(6);
const pw = +toks[1], ph = +toks[2];
if (pw !== w || ph !== h) process.exit(7);
const vals = toks.slice(4).map(Number);
if (vals.length !== pix.length) process.exit(8);
for (let i = 0; i < pix.length; i++) if (vals[i] !== pix[i]) process.exit(9);
EOF
    node "$TMP/cmp.js" "$TMP/png-out/out.png" "$TMP/ppm-out/out.ppm" \
        || fail_msg "decoded PNG pixels differ from PPM pixels"
}

test_png_animation_frames_numbered() {
    call_cli run "$TMP/anim.f3d" -o "$TMP/anim-out"
    assert_eq "$RC" 0 "stderr: $ERR"
    assert_nonempty_file "$TMP/anim-out/anim.png"
    assert_nonempty_file "$TMP/anim-out/anim_0001.png"
    assert_eq "$(png_sig "$TMP/anim-out/anim_0001.png")" "89504e470d0a1a0a" \
        "numbered frame PNG signature"
}

test_ppm_default_still_ppm() {
    call_cli run "$TMP/ppm.f3d" -o "$TMP/ppm-out2"
    assert_eq "$RC" 0 "stderr: $ERR"
    assert_nonempty_file "$TMP/ppm-out2/out.ppm"
    assert_eq "$(head -c 2 "$TMP/ppm-out2/out.ppm")" "P3"
}

run_check test_png_run_writes_native_png test_png_run_writes_native_png
run_check test_png_pixels_equal_ppm test_png_pixels_equal_ppm
run_check test_png_animation_frames_numbered test_png_animation_frames_numbered
run_check test_ppm_default_still_ppm test_ppm_default_still_ppm

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
