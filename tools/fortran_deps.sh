#!/bin/sh
# fortran_deps.sh -- generate GNU make rules with module dependencies
# for a set of Fortran sources (v3.0 Phase 0; replaces hand-written
# per-object rules and hand-ordered source lists in the Makefiles).
#
# Usage:
#   sh tools/fortran_deps.sh OBJDIR RECIPEVAR ORDERONLY file.f90 [...]
#
# For each source file it emits:
#
#   FORTRAN_OBJS += OBJDIR/<obj>.o                      (once per file)
#   OBJDIR/<obj>.o: <file> OBJDIR/<dep1>.o ... [| ORDERONLY]
#       $(RECIPEVAR)
#
# where <obj> is the first module the file defines, or the file's
# basename when it defines none (e.g. a program).  <depN> are the
# objects of the files providing the modules this file USEs.
# Intrinsic modules (iso_*, ieee_*, omp_lib, ...) have no provider in
# the set and are ignored, as are modules provided by the file itself.
#
# The scan is line-based: a `use`/`module` statement is recognised
# when it is the first token on a line (all in-tree code follows this
# convention; a wrapped `use` still names its module on the first
# line).  Over-approximation is safe (an extra prerequisite only ever
# rebuilds more); both Makefiles keep a from-clean CI build that
# would catch a missing edge immediately.
#
# Zero-Python: POSIX sh + awk only (plus the standard file
# utilities dirname/mktemp/find/mv for the direct-output mode
# below).  The file list is fed to awk twice: pass 1 maps modules
# to files, pass 2 collects USEs.
#
# Output modes:
#   * Default: rules are written to stdout; the caller redirects.
#   * Direct (FORTRAN_DEPS_OUTPUT=<path> in the environment): the
#     rules are written to <path> INCREMENTALLY and ATOMICALLY --
#       - skip: if <path> exists and no input (this script or any
#         source) is newer than it (find -newer timestamp check),
#         exit 0 without touching it, so no-op builds stay fast
#         and make does not re-exec itself over an unchanged
#         included makefile;
#       - per-invocation temp: generation goes to a UNIQUE temp
#         file created by mktemp in the SAME directory as <path>
#         (never a fixed shared path such as "<path>.tmp", which
#         concurrent `make -j` / concurrent make invocations in
#         one tree would race on), then mv renames it over <path>
#         atomically (same filesystem), so readers only ever see
#         the old file or the complete new one.  A trap removes
#         the temp file if generation fails or is interrupted.
#     Both Makefiles use this mode for their deps.mk rule.

set -eu

objdir=$1
recipevar=$2
orderonly=$3
shift 3

out=${FORTRAN_DEPS_OUTPUT:-}
tmp=
if [ -n "$out" ]; then
    if [ -f "$out" ]; then
        # Incremental skip: regenerate only if some input is
        # strictly newer than the existing output.  A find error
        # (e.g. a missing input) must NOT be read as "up to date":
        # force regeneration so awk reports the real error.
        stale=$(find "$0" "$@" -newer "$out" -print) || stale=find-error
        if [ -z "$stale" ]; then
            echo "fortran_deps.sh: $out up to date, skipping regeneration" >&2
            exit 0
        fi
    fi
    outdir=$(dirname "$out")
    [ -d "$outdir" ] || mkdir -p "$outdir"
    tmp=$(mktemp "$outdir/.fortran_deps.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    # Send the awk output below to the temp file; fd 3 keeps the
    # original stdout so it can be restored before the rename.
    exec 3>&1
    exec > "$tmp"
fi

awk -v objdir="$objdir" -v recipevar="$recipevar" -v orderonly="$orderonly" '
function base(path,   n, parts) {
    n = split(path, parts, "/")
    return parts[n]
}
function strip_ext(name) {
    sub(/\.[fF]90$/, "", name)
    sub(/\.[fF]$/, "", name)
    return name
}
BEGIN { nsrc = (ARGC - 1) / 2; fc = 0; prev = "" }
FILENAME != prev {
    # File transition (mawk has no BEGINFILE; detect it directly).
    fc++
    pass = (fc <= nsrc) ? 1 : 2
    if (pass == 1) files[++nfiles] = FILENAME
    prev = FILENAME
}
pass == 1 {
    line = $0
    sub(/!.*/, "", line)
    if (line ~ /^[ \t]*module[ \t]+[A-Za-z][A-Za-z0-9_]*[ \t]*$/) {
        m = line
        sub(/^[ \t]*module[ \t]+/, "", m)
        sub(/[ \t]+$/, "", m)
        m = tolower(m)
        if (!(FILENAME in firstmod)) firstmod[FILENAME] = m
        provider[m] = FILENAME
    }
    next
}
pass == 2 {
    line = $0
    sub(/!.*/, "", line)
    if (line ~ /^[ \t]*use[ \t]*,/) next            # use, intrinsic :: ...
    if (line ~ /^[ \t]*use[ \t]+::/) {
        m = line
        sub(/^[ \t]*use[ \t]+::[ \t]*/, "", m)
        sub(/[^A-Za-z0-9_].*/, "", m)
        used[FILENAME SUBSEP tolower(m)] = 1
        next
    }
    if (line ~ /^[ \t]*use[ \t]+[A-Za-z]/) {
        m = line
        sub(/^[ \t]*use[ \t]+/, "", m)
        sub(/[^A-Za-z0-9_].*/, "", m)
        used[FILENAME SUBSEP tolower(m)] = 1
    }
    next
}
END {
    for (i = 1; i <= nfiles; i++) {
        f = files[i]
        if (f in firstmod) stem[f] = firstmod[f]
        else stem[f] = strip_ext(base(f))
    }
    for (i = 1; i <= nfiles; i++) {
        f = files[i]
        obj = objdir "/" stem[f] ".o"
        printf "FORTRAN_OBJS += %s\n", obj
        printf "%s: %s", obj, f
        for (k in used) {
            split(k, parts, SUBSEP)
            if (parts[1] != f) continue
            m = parts[2]
            if (!(m in provider)) continue
            pf = provider[m]
            if (pf == f) continue
            printf " %s/%s.o", objdir, stem[pf]
        }
        if (orderonly != "") printf " | %s", orderonly
        printf "\n\t$(%s)\n\n", recipevar
    }
}
' "$@" "$@"

if [ -n "$tmp" ]; then
    # Direct-output mode: restore stdout, make the temp file
    # normally readable (mktemp creates it 0600), then atomically
    # rename it over the target and disarm the cleanup trap.
    exec >&3
    exec 3>&-
    chmod 644 "$tmp"
    mv -f "$tmp" "$out"
    trap - EXIT HUP INT TERM
fi
