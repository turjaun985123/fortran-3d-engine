#!/bin/sh
# Wave C end-to-end tests: f3dc CLI + the real Fortran engine.
# POSIX shell port of tests/e2e/test_wavec_e2e.py (6 checks, 1:1).
# Standalone-runnable from any CWD:  sh tests/e2e/test_wavec_e2e.sh
#
# PPM pixel statistics (the Python used tests/golden/check_image.py's
# read_ppm) are computed by an embedded mawk program below that parses
# the P3 token stream exactly the same way.
set -u

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# v3.0 Phase 2: these wave suites assert LEGACY renderer behaviour;
# the engine default is now v3, so pin the legacy path via the env
# fallback (an explicit --renderer flag would win over this).
export FORGE3D_RENDERER=legacy
BASE=$(basename -- "$0")

# F3DC resolution mirrors the Python: $F3DC, else bin/f3dc, else compiler/f3dc.
if [ "${F3DC:-}" ]; then
    F3DC_BIN=$F3DC
elif [ -f "$REPO_ROOT/bin/f3dc" ]; then
    F3DC_BIN=$REPO_ROOT/bin/f3dc
else
    F3DC_BIN=$REPO_ROOT/compiler/f3dc
fi

GOLDEN_SHA256=28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- P3 PPM statistics program (mawk-compatible) -----------------------
cat > "$TMP/ppmstats.awk" <<'AWKEOF'
BEGIN {
    hdr=0; ncomp=0; npix=0; sum_all=0; max_sample=0
    distinct=0; distinct_greys=0; nonbg=0; has_black=0
    distfog_sum=0; covered_distinct=0; covered_n=0
    dom_count=0; fam_count=0; reg_sum=0; reg_n=0; npts=0
    if (dom_ch == "") dom_ch=-1
    if (rx0 == "") rx0=-1
    if (pts != "") {
        npts=split(pts, parr, ";")
        for (i=1; i<=npts; i++) { split(parr[i], xy, ","); px_[i]=xy[1]; py_[i]=xy[2]; psum[i]=-1 }
    }
}
function feed(tok,   v,comp,pix,r,g,b,x,y,key,i,mx,mn) {
    if (hdr < 4) {
        if (hdr==1) W=tok+0; else if (hdr==2) H=tok+0; else if (hdr==3) MAXV=tok+0
        hdr++; return
    }
    v=tok+0
    if (MAXV != 255) v=int(v*255/MAXV + 0.5)
    comp=ncomp%3; pix=int(ncomp/3)
    if (comp==0) { cr=v }
    else if (comp==1) { cg=v }
    else {
        r=cr; g=cg; b=v
        npix++; sum_all+=r+g+b
        if (r>max_sample) max_sample=r
        if (g>max_sample) max_sample=g
        if (b>max_sample) max_sample=b
        key=r","g","b
        if (!(key in cnt)) { cnt[key]=0; first[key]=pix; distinct++ }
        cnt[key]++
        if (r==g && g==b && !(key in grey_seen)) { grey_seen[key]=1; distinct_greys++ }
        if (r==0 && g==0 && b==0) has_black=1
        if (r!=bgr || g!=bgg || b!=bgb) {
            nonbg++; distfog_sum += (255-r)+(255-g)+(255-b)
            if (!(key in cov)) { cov[key]=1; covered_distinct++ }
            if (covered_n==0) { fr=r; fg=g; fb=b }
            covered_n++
        }
        if (dom_ch==0) { if (r>g+20 && r>b+20) dom_count++ }
        else if (dom_ch==1) { if (g>r+20 && g>b+20) dom_count++ }
        else if (dom_ch==2) { if (b>r+20 && b>g+20) dom_count++ }
        if (fam=="red") { if (r>g+10 && r>b+10) fam_count++ }
        else if (fam=="orange") { if (r>g+10 && g>b+5) fam_count++ }
        else if (fam=="green") { if (g>r+20 && g>b+20) fam_count++ }
        else if (fam=="blue") { if (b>r+20 && b>g+20) fam_count++ }
        else if (fam=="cyan") { if (g>r+20 && b>r+20) fam_count++ }
        else if (fam=="magenta") { if (r>g+15 && b>g+15) fam_count++ }
        else if (fam=="yellow") { if (r>b+20 && g>b+20) fam_count++ }
        else if (fam=="purple") { if (b>r+10 && r>g+10) fam_count++ }
        else if (fam=="pink") { if (r>g+15 && r>b+10) fam_count++ }
        else if (fam=="gray") {
            mx=r; if (g>mx) mx=g; if (b>mx) mx=b
            mn=r; if (g<mn) mn=g; if (b<mn) mn=b
            if (mx-mn<=12 && r>28) fam_count++
        }
        x=pix%W; y=int(pix/W)
        for (i=1; i<=npts; i++) if (x==px_[i] && y==py_[i]) psum[i]=r+g+b
        if (rx0>=0 && x>=rx0 && x<=rx1 && y>=ry0 && y<=ry1) { reg_sum+=r+g+b; reg_n++ }
    }
    ncomp++
}
{
    line=$0; sub(/#.*/, "", line)
    nt=split(line, toks, " ")
    for (t=1; t<=nt; t++) if (toks[t] != "") feed(toks[t])
}
END {
    bgkey=""; bgcount=-1; bgfirst=0
    for (k in cnt) {
        if (cnt[k]>bgcount || (cnt[k]==bgcount && first[k]<bgfirst)) {
            bgcount=cnt[k]; bgkey=k; bgfirst=first[k]
        }
    }
    split(bgkey, bgc, ",")
    domc=0; for (k in cnt) if (k!=bgkey && cnt[k]>=200) domc++
    printf "w=%d\nh=%d\nnpix=%d\nsum_all=%d\nmax_sample=%d\n", W, H, npix, sum_all, max_sample
    printf "mean=%.10f\n", (npix>0 ? sum_all/(npix*3) : 0)
    printf "distinct=%d\ndistinct_greys=%d\nnonbg=%d\nnonbg_mode=%d\nhas_black=%d\n", distinct, distinct_greys, nonbg, npix-bgcount, has_black
    printf "distfog_mean=%.10f\n", (nonbg>0 ? distfog_sum/nonbg : 0)
    printf "covered_n=%d\ncovered_distinct=%d\ncovered_r=%d\ncovered_g=%d\ncovered_b=%d\n", covered_n, covered_distinct, fr, fg, fb
    printf "bg_r=%d\nbg_g=%d\nbg_b=%d\nbg_count=%d\n", bgc[1], bgc[2], bgc[3], bgcount
    printf "dom_count=%d\nfam_count=%d\ndominant200=%d\n", dom_count, fam_count, domc
    printf "reg_mean=%.10f\nreg_n=%d\n", (reg_n>0 ? reg_sum/reg_n : 0), reg_n
    for (i=1; i<=npts; i++) printf "pix_%d_%d=%d\n", px_[i], py_[i], psum[i]
}
AWKEOF

PASS=0
FAIL=0
FAILED_THIS=0

fail_msg() { FAILED_THIS=1; echo "  # $*" >&2; }
assert_eq() { if [ "$1" != "$2" ]; then fail_msg "expected [$2], got [$1] ${3:-}"; fi }
assert_gt_int() { if [ "$1" -le "$2" ]; then fail_msg "expected $1 > $2 ${3:-}"; fi }
assert_lt_int() { if [ "$1" -ge "$2" ]; then fail_msg "expected $1 < $2 ${3:-}"; fi }

stats() {
    _f=$1; shift
    STATS=$(awk -v bgr=25 -v bgg=25 -v bgb=35 "$@" -f "$TMP/ppmstats.awk" "$_f")
}
get() { printf '%s\n' "$STATS" | sed -n "s/^$1=//p"; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }

# run_cli WORK SCENE_PATH -- f3dc run into WORK/build; asserts exit 0.
run_cli() {
    (cd "$REPO_ROOT" && "$F3DC_BIN" run "$2" -o "$1/build") \
        >"$1/run.out" 2>"$1/run.err"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        fail_msg "f3dc run $2 exited $_rc: $(cat "$1/run.out" "$1/run.err")"
        return 1
    fi
    return 0
}

render() {
    _work=$TMP/$1
    mkdir -p "$_work"
    printf '%s' "$2" > "$_work/scene.f3d"
    run_cli "$_work" "$_work/scene.f3d" || return 1
    if [ ! -f "$_work/build/output_render.ppm" ]; then
        fail_msg "no output_render.ppm for $1"; return 1
    fi
    return 0
}

# run_example NAME EXAMPLE -- copy shipped example into work dir, run it.
# Sets EX_BUILD and EX_PPM (generic output_render.ppm path).
run_example() {
    _work=$TMP/$1
    mkdir -p "$_work"
    cp "$REPO_ROOT/examples/$2" "$_work/$2"
    run_cli "$_work" "$_work/$2" || return 1
    EX_BUILD=$_work/build
    EX_PPM=$_work/build/output_render.ppm
    return 0
}

run_check() {
    _name=$1; shift
    FAILED_THIS=0
    "$@"
    if [ "$FAILED_THIS" -eq 0 ]; then
        PASS=$((PASS + 1)); echo "ok $_name"
    else
        FAIL=$((FAIL + 1)); echo "not ok $_name"
    fi
}

# --- setUpClass equivalent ---------------------------------------------
if command -v gfortran >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
    if ! make -C "$REPO_ROOT" >"$TMP/make.log" 2>&1; then
        echo "make failed:" >&2; cat "$TMP/make.log" >&2
        echo "$BASE: FAIL (setup: make failed)"
        exit 1
    fi
fi
if [ ! -f "$REPO_ROOT/bin/engine3d" ]; then
    echo "SKIP: bin/engine3d missing and gfortran/make unavailable to build it: cannot run Wave C e2e" >&2
    echo "$BASE: SKIP (0 checks)"
    exit 0
fi
if [ ! -f "$F3DC_BIN" ]; then
    echo "SKIP: native f3dc binary missing (looked for \$F3DC, bin/f3dc, compiler/f3dc): cannot run Wave C e2e" >&2
    echo "$BASE: SKIP (0 checks)"
    exit 0
fi

# -- rows 30 + 3 + 22: the post-ortho showcase ----------------------------

test_post_ortho_example_end_to_end() {
    run_example post_ortho post-ortho.f3d || return
    if [ ! -f "$EX_PPM" ]; then fail_msg "no output_render.ppm"; return; fi
    stats "$EX_PPM"
    assert_gt_int "$(get distinct)" 20 "post-ortho image is too flat"
    for _ch in 0 1 2; do
        stats "$EX_PPM" -v dom_ch=$_ch
        assert_gt_int "$(get dom_count)" 500 \
            "depth sphere channel $_ch barely visible"
    done
}

test_post_ortho_deterministic() {
    run_example post_ortho_a post-ortho.f3d || return
    _ppm1=$EX_PPM
    run_example post_ortho_b post-ortho.f3d || return
    assert_eq "$(sha_of "$_ppm1")" "$(sha_of "$EX_PPM")" \
        "post-ortho must render deterministically"
}

# -- row 26: multi-scene -----------------------------------------------------

test_multi_scene_run_produces_two_distinct_outputs() {
    run_example multi_scene multi-scene.f3d || return
    _one=$EX_BUILD/multi-scene-multi-scene-one.ppm
    _two=$EX_BUILD/multi-scene-multi-scene-two.ppm
    if [ ! -f "$_one" ]; then fail_msg "missing $_one"; return; fi
    if [ ! -f "$_two" ]; then fail_msg "missing $_two"; return; fi
    stats "$_one"
    assert_eq "$(get w)" 320 "scene 1 width"
    assert_eq "$(get h)" 240 "scene 1 height"
    _bg1=$(( $(get bg_r) + $(get bg_g) + $(get bg_b) ))
    stats "$_two"
    assert_eq "$(get w)" 640 "scene 2 width"
    assert_eq "$(get h)" 480 "scene 2 height"
    _bg2=$(( $(get bg_r) + $(get bg_g) + $(get bg_b) ))
    assert_lt_int "$_bg1" 100 "scene 1 bg not dark"
    assert_gt_int "$_bg2" 600 "scene 2 bg not light"
    if cmp -s "$_one" "$_two"; then
        fail_msg "multi-scene outputs are byte-identical"
    fi
}

# -- housekeeping: lone-plane regression (B98 repro) ----------------------------

test_plane_regression_lone_plane_sizes_render() {
    _c8=0; _c15=0
    for _size in 8 15; do
        _src="scene size 320 240
plane ground gray at 0 -2 0 size $_size
render still
"
        render "plane_$_size" "$_src" || return
        stats "$TMP/plane_$_size/build/output_render.ppm"
        _n=$(get nonbg)
        assert_gt_int "$_n" 0 "lone plane size $_size rendered nothing"
        if [ "$_size" -eq 8 ]; then _c8=$_n; else _c15=$_n; fi
    done
    assert_gt_int "$_c15" "$_c8" "larger plane must cover more pixels"
}

# -- golden regression -------------------------------------------------------------

test_golden_legacy_no_arg_engine() {
    _work=$TMP/golden_noarg
    mkdir -p "$_work"
    (cd "$_work" && "$REPO_ROOT/bin/engine3d") >"$_work/out.txt" 2>"$_work/err.txt"
    assert_eq "$?" 0 "engine output: $(cat "$_work/out.txt" "$_work/err.txt")"
    if [ ! -f "$_work/output_render.ppm" ]; then fail_msg "no output_render.ppm from no-arg engine"; return; fi
    assert_eq "$(sha_of "$_work/output_render.ppm")" "$GOLDEN_SHA256" "golden hash"
}

test_golden_one_line_cube_cli_render() {
    render golden_cube 'cube
' || return
    assert_eq "$(sha_of "$TMP/golden_cube/build/output_render.ppm")" "$GOLDEN_SHA256" "golden hash"
}

run_check test_post_ortho_example_end_to_end test_post_ortho_example_end_to_end
run_check test_post_ortho_deterministic test_post_ortho_deterministic
run_check test_multi_scene_run_produces_two_distinct_outputs test_multi_scene_run_produces_two_distinct_outputs
run_check test_plane_regression_lone_plane_sizes_render test_plane_regression_lone_plane_sizes_render
run_check test_golden_legacy_no_arg_engine test_golden_legacy_no_arg_engine
run_check test_golden_one_line_cube_cli_render test_golden_one_line_cube_cli_render

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
