#!/bin/sh
# Wave E end-to-end tests: f3dc CLI + the real Fortran engine.
# POSIX shell port of tests/e2e/test_wavee_e2e.py (10 checks, 1:1).
# Standalone-runnable from any CWD:  sh tests/e2e/test_wavee_e2e.sh
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
    echo "SKIP: bin/engine3d missing and gfortran/make unavailable to build it: cannot run Wave E e2e" >&2
    echo "$BASE: SKIP (0 checks)"
    exit 0
fi
if [ ! -f "$F3DC_BIN" ]; then
    echo "SKIP: native f3dc binary missing (looked for \$F3DC, bin/f3dc, compiler/f3dc): cannot run Wave E e2e" >&2
    echo "$BASE: SKIP (0 checks)"
    exit 0
fi

CAM='scene size 320 240
camera at 0 3 10 look 0 0 0
'
CUBE='cube red at 0 0 0 size 2'
CYL='cylinder p yellow at 0 0 0 radius 1 height 3'

# -- custom shaders ---------------------------------------------------------

test_shader_constant_exact() {
    _src="${CAM}shader half expr \"0.5\"
${CUBE} shader half
render still
"
    render shader_const "$_src" || return
    # every covered pixel must be exactly (128,128,128)
    stats "$TMP/shader_const/build/output_render.ppm"
    assert_gt_int "$(get covered_n)" 0 "constant-shader cube covered no pixels"
    assert_eq "$(get covered_distinct)" 1 "covered set must be exactly {(128,128,128)}"
    assert_eq "$(get covered_r)" 128 "covered colour R"
    assert_eq "$(get covered_g)" 128 "covered colour G"
    assert_eq "$(get covered_b)" 128 "covered colour B"
}

test_two_shaders_differ() {
    render shader_c "${CAM}shader ident expr \"c\"
${CUBE} shader ident
render still
" || return
    render shader_0 "${CAM}shader zero expr \"0\"
${CUBE} shader zero
render still
" || return
    render shader_none "${CAM}${CUBE}
render still
" || return
    _hc=$(sha_of "$TMP/shader_c/build/output_render.ppm")
    _h0=$(sha_of "$TMP/shader_0/build/output_render.ppm")
    _hn=$(sha_of "$TMP/shader_none/build/output_render.ppm")
    if [ "$_hc" = "$_h0" ] || [ "$_hc" = "$_hn" ] || [ "$_h0" = "$_hn" ]; then
        fail_msg "shader c / shader 0 / no shader must be pairwise different renders"
    fi
    # shader 0 covered pixels must all be (0,0,0)
    stats "$TMP/shader_0/build/output_render.ppm"
    assert_gt_int "$(get covered_n)" 0 "zero-shader cube covered no pixels"
    assert_eq "$(get covered_distinct)" 1 "covered set must be exactly {(0,0,0)}"
    assert_eq "$(get covered_r)" 0 "covered colour R"
    assert_eq "$(get covered_g)" 0 "covered colour G"
    assert_eq "$(get covered_b)" 0 "covered colour B"
}

test_checker_pattern_two_values() {
    _src="${CAM}shader checker expr \"c * step(0.5, fract((x + y) * 2))\"
${CUBE} shader checker
render still
"
    render shader_checker "$_src" || return
    stats "$TMP/shader_checker/build/output_render.ppm"
    assert_ge_int "$(get covered_distinct)" 2 \
        "checker must produce >= 2 distinct covered colours"
    # (0,0,0) is a covered colour: it differs from the (25,25,35)
    # background, so has_black here means a covered black pixel exists.
    assert_eq "$(get has_black)" 1 "one checker colour must be (0,0,0)"
}

test_shader_identity_matches_unlit() {
    render shader_ident "${CAM}shader ident expr \"c\"
${CUBE} shader ident
render still
" || return
    render shader_basic "${CAM}${CUBE} material basic
render still
" || return
    if ! cmp -s "$TMP/shader_ident/build/output_render.ppm" "$TMP/shader_basic/build/output_render.ppm"; then
        fail_msg "shader 'c' render is not byte-identical to the material basic render"
    fi
}

# -- morph targets ------------------------------------------------------------

test_morph_factor_zero_is_identity() {
    render morph_plain "${CAM}sphere s green at 0 0 0 radius 1
render still
" || return
    render morph_zero "${CAM}sphere s green at 0 0 0 radius 1
morph s bulge 0
render still
" || return
    if ! cmp -s "$TMP/morph_plain/build/output_render.ppm" "$TMP/morph_zero/build/output_render.ppm"; then
        fail_msg "morph bulge 0 must be a byte-identical identity"
    fi
}

test_morph_changes_render() {
    render morph_cone_plain "${CAM}cone s orange at 0 0 0 radius 1 height 3
render still
" || return
    render morph_cone_bulge "${CAM}cone s orange at 0 0 0 radius 1 height 3
morph s bulge 1
render still
" || return
    if [ "$(sha_of "$TMP/morph_cone_plain/build/output_render.ppm")" = \
         "$(sha_of "$TMP/morph_cone_bulge/build/output_render.ppm")" ]; then
        fail_msg "bulge 1 must change the render"
    fi
    stats "$TMP/morph_cone_plain/build/output_render.ppm"; _np=$(get nonbg)
    stats "$TMP/morph_cone_bulge/build/output_render.ppm"; _nb=$(get nonbg)
    if [ "$_np" = "$_nb" ]; then
        fail_msg "bulge 1 must change the covered-pixel count ($_np vs $_nb)"
    fi
}

# -- skinning ---------------------------------------------------------------------

test_skin_zero_rotation_is_identity() {
    render skin_plain "${CAM}${CYL}
render still
" || return
    render skin_zero "${CAM}${CYL}
bone b at 0,0,0 rotate 0,0,0 radius 3
skin p b
render still
" || return
    if ! cmp -s "$TMP/skin_plain/build/output_render.ppm" "$TMP/skin_zero/build/output_render.ppm"; then
        fail_msg "skin with a zero-rotation bone must be a byte-identical identity"
    fi
}

test_skin_bends_render() {
    render skin_plain_bend "${CAM}${CYL}
render still
" || return
    render skin_bent "${CAM}${CYL}
bone b at 0,0,0 rotate 0,0,30 radius 3
skin p b
render still
" || return
    if [ "$(sha_of "$TMP/skin_plain_bend/build/output_render.ppm")" = \
         "$(sha_of "$TMP/skin_bent/build/output_render.ppm")" ]; then
        fail_msg "a 30-degree bone must bend the render"
    fi
}

# -- the shipped showcase -------------------------------------------------------------

test_showcase_renders_and_deterministic() {
    run_example showcase_a wavee-showcase.f3d || return
    _ppm1=$EX_PPM
    if [ ! -f "$_ppm1" ]; then fail_msg "no wavee-showcase.ppm"; return; fi
    run_example showcase_b wavee-showcase.f3d || return
    if [ ! -f "$EX_PPM" ]; then fail_msg "no wavee-showcase.ppm"; return; fi
    assert_eq "$(sha_of "$_ppm1")" "$(sha_of "$EX_PPM")" \
        "showcase must render deterministically"
    # Background = most frequent colour, so non-bg = npix - bg_count.
    stats "$_ppm1"
    assert_gt_int "$(get nonbg_mode)" 5000 "showcase covers too few non-bg pixels"
    assert_ge_int "$(get distinct)" 8 "showcase has too few distinct colours"
}

# -- golden regression --------------------------------------------------------------------

test_golden_unchanged() {
    _work=$TMP/golden_noarg
    mkdir -p "$_work"
    (cd "$_work" && "$REPO_ROOT/bin/engine3d") >"$_work/out.txt" 2>"$_work/err.txt"
    assert_eq "$?" 0 "engine output: $(cat "$_work/out.txt" "$_work/err.txt")"
    if [ ! -f "$_work/output_render.ppm" ]; then fail_msg "no output_render.ppm from no-arg engine"; return; fi
    assert_eq "$(sha_of "$_work/output_render.ppm")" "$GOLDEN_SHA256" "golden hash"
}

run_check test_shader_constant_exact test_shader_constant_exact
run_check test_two_shaders_differ test_two_shaders_differ
run_check test_checker_pattern_two_values test_checker_pattern_two_values
run_check test_shader_identity_matches_unlit test_shader_identity_matches_unlit
run_check test_morph_factor_zero_is_identity test_morph_factor_zero_is_identity
run_check test_morph_changes_render test_morph_changes_render
run_check test_skin_zero_rotation_is_identity test_skin_zero_rotation_is_identity
run_check test_skin_bends_render test_skin_bends_render
run_check test_showcase_renders_and_deterministic test_showcase_renders_and_deterministic
run_check test_golden_unchanged test_golden_unchanged

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    echo "$BASE: PASS ($TOTAL checks)"
    exit 0
else
    echo "$BASE: FAIL ($FAIL of $TOTAL checks failed)"
    exit 1
fi
