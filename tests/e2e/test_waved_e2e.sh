#!/bin/sh
# Wave D end-to-end tests: f3dc CLI + the real Fortran engine.
# POSIX shell port of tests/e2e/test_waved_e2e.py (13 checks, 1:1).
# Standalone-runnable from any CWD:  sh tests/e2e/test_waved_e2e.sh
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
MIN_FAMILY_PIXELS=300

fail_msg() { FAILED_THIS=1; echo "  # $*" >&2; }
assert_eq() { if [ "$1" != "$2" ]; then fail_msg "expected [$2], got [$1] ${3:-}"; fi }
assert_gt_int() { if [ "$1" -le "$2" ]; then fail_msg "expected $1 > $2 ${3:-}"; fi }
assert_ge_int() { if [ "$1" -lt "$2" ]; then fail_msg "expected $1 >= $2 ${3:-}"; fi }

stats() {
    _f=$1; shift
    STATS=$(awk -v bgr=25 -v bgg=25 -v bgb=35 "$@" -f "$TMP/ppmstats.awk" "$_f")
}
get() { printf '%s\n' "$STATS" | sed -n "s/^$1=//p"; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }

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

# run_example NAME EXAMPLE -- sets EX_BUILD and EX_PPM (the example's
# own stem-named PPM, as in the Python).
run_example() {
    _work=$TMP/$1
    mkdir -p "$_work"
    cp "$REPO_ROOT/examples/$2" "$_work/$2"
    run_cli "$_work" "$_work/$2" || return 1
    _stem=${2%.f3d}
    EX_BUILD=$_work/build
    EX_PPM=$_work/build/$_stem.ppm
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
    echo "SKIP: bin/engine3d missing and gfortran/make unavailable to build it: cannot run Wave D e2e" >&2
    echo "$BASE: SKIP (0 checks)"
    exit 0
fi
if [ ! -f "$F3DC_BIN" ]; then
    echo "SKIP: native f3dc binary missing (looked for \$F3DC, bin/f3dc, compiler/f3dc): cannot run Wave D e2e" >&2
    echo "$BASE: SKIP (0 checks)"
    exit 0
fi

CAM='scene size 320 240
camera at 0 3 10 look 0 0 0
'

# -- per-primitive pixel proofs ------------------------------------------
# Mirrors the Python check_prim: family pixels > 300 and >= 3 distinct
# colours for the prim's single-object scene.

check_prim() { # prim family source
    render "prim_$1" "$3" || return
    stats "$TMP/prim_$1/build/output_render.ppm" -v fam=$2
    _fam=$(get fam_count); _distinct=$(get distinct); _nonbg=$(get nonbg)
    echo "  # $1 ($2): family=$_fam non-bg=$_nonbg distinct=$_distinct"
    assert_gt_int "$_fam" "$MIN_FAMILY_PIXELS" \
        "$1 rendered only $_fam $2-family pixels (need > $MIN_FAMILY_PIXELS)"
    assert_ge_int "$_distinct" 3 \
        "$1 image is flat: only $_distinct distinct colours"
}

test_circle_pixels() {
    check_prim circle red "${CAM}filter vignette 0.6
circle red radius 2 rotate 90 0 0
render still
"
}
test_ring_pixels() {
    check_prim ring orange "${CAM}filter vignette 0.6
ring orange inner 1 outer 2 rotate 90 0 0
render still
"
}
test_capsule_pixels() {
    check_prim capsule green "${CAM}capsule green radius 1 height 2
render still
"
}
test_tube_pixels() {
    check_prim tube blue "${CAM}tube blue radius 0.5 path -2,0,0 0,1.5,0 2,0,0
render still
"
}
test_lathe_pixels() {
    check_prim lathe cyan "${CAM}lathe cyan points 0,0 1,0.2 1,1.5 0,2 at 0 -1 0
render still
"
}
test_extrude_pixels() {
    check_prim extrude magenta 'scene size 320 240
camera at 5 5 9 look 0 0.5 0
extrude magenta shape -1,-1 1,-1 1,1 -1,1 extrude_depth 1
render still
'
}
test_tetrahedron_pixels() {
    check_prim tetrahedron yellow "${CAM}tetrahedron yellow radius 2
render still
"
}
test_octahedron_pixels() {
    check_prim octahedron purple "${CAM}octahedron purple radius 2
render still
"
}
test_icosahedron_pixels() {
    check_prim icosahedron pink "${CAM}icosahedron pink radius 2
render still
"
}
test_dodecahedron_pixels() {
    check_prim dodecahedron cyan "${CAM}dodecahedron cyan radius 2
render still
"
}
test_torusknot_pixels() {
    check_prim torusknot gray "${CAM}torusknot gray radius 1.5 tube 0.5
render still
"
}

# -- the shipped showcase ---------------------------------------------------

test_geometries_example_end_to_end() {
    run_example geometries geometries.f3d || return
    if [ ! -f "$EX_PPM" ]; then fail_msg "no geometries.ppm"; return; fi
    stats "$EX_PPM"
    _distinct=$(get distinct); _dom=$(get dominant200); _nonbgm=$(get nonbg_mode)
    echo "  # geometries: distinct=$_distinct dominant(>=200px)=$_dom non-bg=$_nonbgm"
    assert_ge_int "$_dom" 8 \
        "geometries showcase has only $_dom dominant colours"
}

test_geometries_deterministic() {
    run_example geometries_a geometries.f3d || return
    _ppm1=$EX_PPM
    if [ ! -f "$_ppm1" ]; then fail_msg "no geometries.ppm (run a)"; return; fi
    run_example geometries_b geometries.f3d || return
    if [ ! -f "$EX_PPM" ]; then fail_msg "no geometries.ppm (run b)"; return; fi
    assert_eq "$(sha_of "$_ppm1")" "$(sha_of "$EX_PPM")" \
        "geometries showcase must render deterministically"
}

run_check test_circle_pixels test_circle_pixels
run_check test_ring_pixels test_ring_pixels
run_check test_capsule_pixels test_capsule_pixels
run_check test_tube_pixels test_tube_pixels
run_check test_lathe_pixels test_lathe_pixels
run_check test_extrude_pixels test_extrude_pixels
run_check test_tetrahedron_pixels test_tetrahedron_pixels
run_check test_octahedron_pixels test_octahedron_pixels
run_check test_icosahedron_pixels test_icosahedron_pixels
run_check test_dodecahedron_pixels test_dodecahedron_pixels
run_check test_torusknot_pixels test_torusknot_pixels
run_check test_geometries_example_end_to_end test_geometries_example_end_to_end
run_check test_geometries_deterministic test_geometries_deterministic

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
