#!/bin/sh
# Wave A end-to-end tests: f3dc CLI + the real Fortran engine.
# POSIX shell port of tests/e2e/test_wavea_e2e.py (9 checks, 1:1).
# Standalone-runnable from any CWD:  sh tests/e2e/test_wavea_e2e.sh
#
# PPM pixel statistics (the Python used tests/golden/check_image.py's
# read_ppm) are computed by an embedded mawk program below that parses
# the P3 token stream exactly the same way.
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

GOLDEN_SHA256=28b6a81dd052a740f3a395ea41b3e0dd37e02eeff585a56fa90e05ac7697cec1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# --- P3 PPM statistics program (mawk-compatible) -----------------------
# Vars in:  bgr bgg bgb (background, default 25 25 35), dom_ch (-1/0/1/2),
#           fam (colour-family name or ""), pts ("x,y;x,y"),
#           rx0 rx1 ry0 ry1 (region, rx0=-1 disables).
# Prints key=value lines: w h npix sum_all mean max_sample distinct
# distinct_greys nonbg nonbg_mode has_black distfog_mean covered_n
# covered_distinct covered_r/g/b bg_r/g/b bg_count dom_count fam_count
# reg_mean pix_<x>_<y> dominant200.
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
assert_lt_int() { if [ "$1" -ge "$2" ]; then fail_msg "expected $1 < $2 ${3:-}"; fi }
flt_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
flt_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }
assert_flt_gt() { if ! flt_gt "$1" "$2"; then fail_msg "expected $1 > $2 ${3:-}"; fi }
assert_flt_lt() { if ! flt_lt "$1" "$2"; then fail_msg "expected $1 < $2 ${3:-}"; fi }

# stats PPMFILE [extra awk -v args...] -> sets STATS; get KEY extracts.
stats() {
    _f=$1; shift
    STATS=$(awk -v bgr=25 -v bgg=25 -v bgb=35 "$@" -f "$TMP/ppmstats.awk" "$_f")
}
get() { printf '%s\n' "$STATS" | sed -n "s/^$1=//p"; }

sha_of() { sha256sum "$1" | awk '{print $1}'; }

# render NAME SOURCE -- writes scene, runs f3dc run, requires the PPM.
render() {
    _work=$TMP/$1
    mkdir -p "$_work"
    printf '%s' "$2" > "$_work/scene.f3d"
    (cd "$REPO_ROOT" && "$F3DC_BIN" run "$_work/scene.f3d" -o "$_work/build") \
        >"$_work/run.out" 2>"$_work/run.err"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        fail_msg "render $1 exited $_rc: $(cat "$_work/run.err")"; return 1
    fi
    if [ ! -f "$_work/build/output_render.ppm" ]; then
        fail_msg "no output_render.ppm for $1"; return 1
    fi
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
    echo "SKIP: bin/engine3d missing and gfortran/make unavailable to build it: cannot run Wave A e2e" >&2
    echo "$BASE: SKIP (0 checks)"
    exit 0
fi

# -- row 13: attenuation -------------------------------------------------

test_attenuation_point_light_near_vs_far() {
    _pre='scene size 160 120
camera at 3 2.5 4 look 0 0 0
light point at '
    _post=' intensity 5
cube hero red at 0 0 0 size 2
render still
'
    render att_near "${_pre}-2 -2 -2${_post}" || return
    render att_far "${_pre}-9 -9 -9${_post}" || return
    stats "$TMP/att_near/build/output_render.ppm"; _near_mean=$(get mean)
    stats "$TMP/att_far/build/output_render.ppm"; _far_mean=$(get mean)
    assert_flt_gt "$_near_mean" "$_far_mean" "near light must be brighter"
}

test_spot_cone_inside_vs_outside() {
    _pre='scene size 160 120
camera at 3 2.5 4 look 0 0 0
light spot at -4 -4 -4 look 0 0 0 angle 25 penumbra 0 intensity 20
light ambient strength 0.25
cube hero red at '
    _post=' size 2
render still
'
    render spot_in "${_pre}0 0 0${_post}" || return
    render spot_out "${_pre}4 -2 0${_post}" || return
    stats "$TMP/spot_in/build/output_render.ppm"; _in_mean=$(get mean); _in_max=$(get max_sample)
    stats "$TMP/spot_out/build/output_render.ppm"; _out_mean=$(get mean); _out_max=$(get max_sample)
    assert_flt_gt "$_in_mean" "$_out_mean" "inside cone must be brighter"
    assert_gt_int "$_in_max" "$_out_max" "inside cone max must exceed outside"
}

# -- row 14: fog -----------------------------------------------------------

test_fog_moves_object_pixels_toward_fog_colour() {
    _plain='scene size 160 120
camera at 3 2.5 4 look 0 0 0
light directional
cube hero red at 0 0 0 size 2
render still
'
    _fog='scene size 160 120 fog linear near 2 far 12
camera at 3 2.5 4 look 0 0 0
light directional
cube hero red at 0 0 0 size 2
render still
'
    render fog_plain "$_plain" || return
    render fog_fogged "$_fog" || return
    stats "$TMP/fog_plain/build/output_render.ppm"
    _p_dist=$(get distfog_mean); _p_mean=$(get mean); _p_nonbg=$(get nonbg)
    assert_gt_int "$_p_nonbg" 0 "plain render has no object pixels"
    stats "$TMP/fog_fogged/build/output_render.ppm"
    _f_dist=$(get distfog_mean); _f_mean=$(get mean); _f_nonbg=$(get nonbg)
    assert_gt_int "$_f_nonbg" 0 "fogged render has no object pixels"
    assert_flt_lt "$_f_dist" "$_p_dist" "fog must move pixels toward fog colour"
    assert_flt_gt "$_f_mean" "$_p_mean" "fog must raise mean brightness"
}

# -- row 25: tonemapping -----------------------------------------------------

test_tonemap_aces_differs_and_caps_white() {
    _pre='scene size 160 120'
    _post='
camera at 3 2.5 4 look 0 0 0
cube #FFFFFF material basic
render still
'
    render tm_plain "${_pre}${_post}" || return
    render tm_aces "${_pre} tonemap aces${_post}" || return
    if cmp -s "$TMP/tm_plain/build/output_render.ppm" "$TMP/tm_aces/build/output_render.ppm"; then
        fail_msg "tonemap aces render is byte-identical to plain render"
    fi
    stats "$TMP/tm_plain/build/output_render.ppm"; _p_max=$(get max_sample)
    stats "$TMP/tm_aces/build/output_render.ppm"; _a_max=$(get max_sample)
    assert_eq "$_p_max" 255 "plain brightest pixel"
    _diff=$((_a_max - 205)); if [ $_diff -lt 0 ]; then _diff=$((-_diff)); fi
    if [ $_diff -gt 3 ]; then fail_msg "aces max $_a_max not within 3 of 205"; fi
}

# -- row 11: PBR ----------------------------------------------------------------

test_pbr_metalness_changes_render() {
    _pre='scene size 160 120
camera at 3 2.5 4 look 0 0 0
light point at 3 4 3 intensity 3
sphere gray at 0 0 0 radius 1 material standard metalness '
    _post=' roughness 0.3
render still
'
    render pbr_m0 "${_pre}0${_post}" || return
    render pbr_m1 "${_pre}1${_post}" || return
    if cmp -s "$TMP/pbr_m0/build/output_render.ppm" "$TMP/pbr_m1/build/output_render.ppm"; then
        fail_msg "metalness 0 and 1 renders are byte-identical"
    fi
    stats "$TMP/pbr_m0/build/output_render.ppm"; _s0=$(get sum_all); _m0=$(get max_sample)
    stats "$TMP/pbr_m1/build/output_render.ppm"; _s1=$(get sum_all); _m1=$(get max_sample)
    # Same pixel count, so sum_all equality == mean-brightness equality.
    if [ "$_s0" = "$_s1" ] && [ "$_m0" = "$_m1" ]; then
        fail_msg "metalness changed neither mean brightness nor max sample"
    fi
}

# -- row 15: texture --------------------------------------------------------------

test_texture_checker_card_colours_present() {
    mkdir -p "$TMP/texture"
    {
        printf 'P3\n4 4\n255\n'
        _y=0
        while [ $_y -lt 4 ]; do
            _x=0; _line=''
            while [ $_x -lt 4 ]; do
                if [ $(((_x + _y) % 2)) -eq 0 ]; then _cell='255 255 255'; else _cell='0 0 0'; fi
                if [ $_x -eq 0 ]; then _line=$_cell; else _line="$_line $_cell"; fi
                _x=$((_x + 1))
            done
            printf '%s\n' "$_line"
            _y=$((_y + 1))
        done
    } > "$TMP/texture/checker.ppm"
    _src='scene size 160 120
camera at 3 2.5 4 look 0 0 0
light point at -2 -2 -2 intensity 5
cube hero white at 0 0 0 size 2 texture "checker.ppm"
render still
'
    render texture "$_src" || return
    stats "$TMP/texture/build/output_render.ppm"
    assert_eq "$(get has_black)" 1 "(0,0,0) texel colour must be present"
    assert_ge_int "$(get max_sample)" 250 "near-white texel colour must be present"
    assert_ge_int "$(get distinct_greys)" 4 "at least 4 distinct greys"
}

# -- row 16: shadows -----------------------------------------------------------------

test_shadow_soft_darkens_plane_pixels() {
    _pre='scene "shadowtest" size 160 120 background black fog linear near 14 far 34 tonemap aces shadow '
    _post='
camera at 6 4 9 look 0 -1 0
light spot at 2 7 5 look 0 -1 0 angle 38 penumbra 0.5 intensity 45 decay 2
light point orange at -6 2 5 intensity 30 distance 0 decay 2
light ambient strength 0.12
plane ground gray at 0 -2 0 size 18 material standard metalness 0 roughness 0.95
cube hero white at -3.2 -1 0 size 2 material standard metalness 0 roughness 0.8
sphere ball blue at 0 -1 0 radius 1 material standard metalness 0 roughness 0.15
sphere metal gray at 2.8 -1.1 0 radius 0.9 material standard metalness 1 roughness 0.3
render still
'
    render shadow_soft "${_pre}soft${_post}" || return
    render shadow_off "${_pre}off${_post}" || return
    if cmp -s "$TMP/shadow_soft/build/output_render.ppm" "$TMP/shadow_off/build/output_render.ppm"; then
        fail_msg "shadow soft and off renders are byte-identical"
    fi
    stats "$TMP/shadow_soft/build/output_render.ppm" -v pts=104,59\;105,59 -v rx0=100 -v rx1=110 -v ry0=55 -v ry1=65
    _s1=$(get pix_104_59); _s2=$(get pix_105_59); _s_reg=$(get reg_mean)
    stats "$TMP/shadow_off/build/output_render.ppm" -v pts=104,59\;105,59 -v rx0=100 -v rx1=110 -v ry0=55 -v ry1=65
    _o1=$(get pix_104_59); _o2=$(get pix_105_59); _o_reg=$(get reg_mean)
    assert_lt_int "$_s1" "$_o1" "plane pixel (104,59) not darkened by shadow"
    assert_lt_int "$_s2" "$_o2" "plane pixel (105,59) not darkened by shadow"
    assert_flt_lt "$_s_reg" "$_o_reg" "shadow region mean must drop"
}

# -- golden regression ------------------------------------------------------------------

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

run_check test_attenuation_point_light_near_vs_far test_attenuation_point_light_near_vs_far
run_check test_spot_cone_inside_vs_outside test_spot_cone_inside_vs_outside
run_check test_fog_moves_object_pixels_toward_fog_colour test_fog_moves_object_pixels_toward_fog_colour
run_check test_tonemap_aces_differs_and_caps_white test_tonemap_aces_differs_and_caps_white
run_check test_pbr_metalness_changes_render test_pbr_metalness_changes_render
run_check test_texture_checker_card_colours_present test_texture_checker_card_colours_present
run_check test_shadow_soft_darkens_plane_pixels test_shadow_soft_darkens_plane_pixels
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
