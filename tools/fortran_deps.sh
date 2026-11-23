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
# Zero-Python: POSIX sh + awk only.  The file list is fed to awk
# twice: pass 1 maps modules to files, pass 2 collects USEs.

set -eu

objdir=$1
recipevar=$2
orderonly=$3
shift 3

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
