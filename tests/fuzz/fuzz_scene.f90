! ======================================================================
! fuzz_scene.f90 -- Forge3D mutation fuzz harness for the engine scene
! readers (v3.0 Phase 9, hardening).
!
! PURPOSE
!   Feed deterministically mutated copies of two known-good seed
!   scenes to the REAL engine readers and verify the readers'
!   standing contract: garbage in, warning/error out -- NEVER a
!   crash, a hang, an out-of-bounds access, or a sanitizer report.
!
!     format 1: the v1 text format  ->  scene_3d%scene_load
!               (src/scene.f90; signature
!                scene_load(path, sc, ok, errmsg))
!     format 2: the forge3d-scene JSON format
!               ->  scene_json_3d%scene_load_json
!               (src/scene_json.f90; same signature; format and
!                ir_version contract per docs/SCENE-FORMAT.md)
!
!   Every iteration rebuilds a fresh seed, applies 1..5 mutations,
!   writes the result to a temp file, loads it through the real
!   reader, and releases the result with scene_3d%scene_free --
!   whether the load reported success or failure (a partially built
!   Scene must still be freeable; that is part of the contract).
!   The mutated temp file is written BEFORE the load and is left on
!   disk, so if the process dies the file at the reported path is
!   the exact reproducer for the crashing iteration.
!
!   A crash, an ASan/UBSan report, a Fortran runtime bounds error,
!   or a hang IS the finding: rerun with the same seed, reduce the
!   iteration count, and keep the temp file.
!
! USAGE
!   ./fuzz_scene [iterations] [seed] [mode]
!     iterations  bounded count, default 5000, clamped to
!                 1 .. 1000000 so a typo cannot start an endless run
!     seed        splitmix64 seed (integer), default 12345; the
!                 same (iterations, seed, mode) triple always
!                 produces the same mutation sequence
!     mode        'scene' (text only), 'json' (JSON only), or
!                 'both' (default; the format alternates per
!                 iteration, chosen by the PRNG)
!
! BUILD (sanitizers are the point -- do not fuzz an -O3 release
! build; -fcheck=all adds Fortran-level bounds/dangling checks):
!
!   gfortran -O1 -g -fcheck=all -Wall -Wextra \
!       -fsanitize=address,undefined \
!       -fno-sanitize=signed-integer-overflow \
!       -Jinclude -Iinclude \
!       <engine sources, see LINK SET> \
!       tests/fuzz/fuzz_scene.f90 -o fuzz_scene
!
!   The signed-integer-overflow exclusion exists for ONE reason:
!   splitmix64 below is defined over modulo-2**64 wrap-around
!   arithmetic, and gfortran's wrapping behaviour is what the
!   algorithm specifies.  Every other UB class stays sanitized.
!
! LINK SET
!   This program is a standalone program unit: link it INSTEAD of
!   src/main.f90 (two programs cannot link together), plus every
!   engine module the two readers pull in.  From the readers' own
!   USE statements:
!
!     scene_3d (src/scene.f90) uses:
!       math_3d, mesh_3d, camera_3d, material_3d, material_pbr_3d,
!       texture_3d, lighting_3d, obj_loader (load_obj),
!       sprite_3d, text_render_3d, particles_3d, keyframe_3d,
!       geo_flat_3d, geo_capsule_3d, geo_tube_3d, geo_lathe_3d,
!       geo_extrude_3d, geo_poly_3d, geo_torusknot_3d,
!       shader_3d, skinning_3d
!     scene_json_3d (src/scene_json.f90) uses:
!       math_3d, mesh_3d, camera_3d, material_3d, material_pbr_3d,
!       texture_3d, lighting_3d, particles_3d, keyframe_3d,
!       shader_3d, skinning_3d, scene_3d, json_reader_3d
!
!   plus their transitive providers (mesh_data_3d, camera_ortho_3d,
!   fog_3d, shadow_3d / shadow_v3_3d, postprocess_3d and friends).
!   In practice the link set is: every src/*.f90 EXCEPT src/main.f90.
!
! TRAPS THIS FILE IS WRITTEN AROUND
!   * Fortran .AND. / .OR. do NOT short-circuit: an expression like
!       if (i <= n .and. a(i) == x)
!     may evaluate a(i) with i out of bounds.  Every index in this
!     file is therefore guarded by a NESTED if, never by .AND.
!   * Character substring assignment with overlapping ranges is
!     avoided: all inserts/deletes shift byte-by-byte in an explicit
!     loop, from the end that cannot overwrite data still needed.
!   * Mutated counts/sizes reach the readers unclamped ON PURPOSE
!     (huge 'tris' counts, negative sizes, absurd segments are the
!     interesting inputs); this harness's own buffers, by contrast,
!     are hard-bounded by MAXBUF / MAXLINES and every mutation
!     re-checks them.
!
! Zero Python.  No test framework: the process exit path (clean
! summary line vs. crash/sanitizer abort) is the verdict.
! ======================================================================

! ----------------------------------------------------------------------
! Deterministic PRNG: splitmix64 (Steele / Lea / Flood), period
! 2**64, entirely defined by the seed -- no time, no /dev/urandom,
! so any finding reproduces exactly from its (seed, iteration).
! ----------------------------------------------------------------------
module fuzz_rng
    use, intrinsic :: iso_fortran_env, only: int64
    implicit none
    private
    public :: rng_seed, rng_next, rng_below, rng_between

    integer(int64) :: rng_state = 0_int64

contains

    subroutine rng_seed(seed)
        integer(int64), intent(in) :: seed
        rng_state = seed
    end subroutine rng_seed

    function rng_next() result(z)
        integer(int64) :: z
        ! 0x9E3779B97F4A7C15, 0xBF58476D1CE4E5B9, 0x94D049BB133111EB
        ! written as signed decimal int64 literals (same bit
        ! patterns); the multiplications wrap modulo 2**64.
        rng_state = rng_state + (-7046029254386353131_int64)
        z = rng_state
        z = ieor(z, ishft(z, -30))
        z = z * (-4658895280553007687_int64)
        z = ieor(z, ishft(z, -27))
        z = z * (-7723592293110705685_int64)
        z = ieor(z, ishft(z, -31))
    end function rng_next

    ! Uniform-enough draw in 0 .. n-1 (n >= 1).  Modulo bias is
    ! irrelevant for fuzzing.  ishft(..., -1) is a LOGICAL shift in
    ! Fortran, so the result is always >= 0 before the mod.
    function rng_below(n) result(r)
        integer, intent(in) :: n
        integer :: r
        integer(int64) :: z
        z = ishft(rng_next(), -1)
        r = int(mod(z, int(n, int64)))
    end function rng_below

    ! Draw in lo .. hi inclusive (requires lo <= hi).
    function rng_between(lo, hi) result(r)
        integer, intent(in) :: lo, hi
        integer :: r
        r = lo + rng_below(hi - lo + 1)
    end function rng_between

end module fuzz_rng

! ----------------------------------------------------------------------
! The harness proper.
! ----------------------------------------------------------------------
program fuzz_scene
    use, intrinsic :: iso_fortran_env, only: int64, output_unit
    use fuzz_rng, only: rng_seed, rng_below, rng_between
    use scene_3d, only: Scene, scene_load, scene_free
    use scene_json_3d, only: scene_load_json
    implicit none

    integer, parameter :: MAXBUF = 16384   ! hard cap on a mutated input
    integer, parameter :: MAXLINES = 512   ! hard cap for line-op tables
    integer, parameter :: DEFAULT_ITERS = 5000
    integer, parameter :: MAX_ITERS = 1000000
    integer(int64), parameter :: DEFAULT_SEED = 12345_int64

    character(len=MAXBUF) :: buf          ! current (mutated) input
    integer :: buflen                     ! live bytes in buf (1..buflen)
    character(len=MAXBUF) :: seedbuf      ! pristine seed, rebuilt per iter
    integer :: seedlen

    type(Scene) :: sc
    logical :: ok
    character(len=512) :: errmsg

    integer :: niters, iter, i, nmut, choice
    integer(int64) :: seed
    character(len=16) :: mode             ! 'scene' | 'json' | 'both'
    logical :: use_json                   ! format of this iteration
    integer :: n_accepted, n_rejected     ! reader verdicts (both are fine)
    integer :: n_scene, n_json            ! iterations per format
    character(len=64) :: tmp_scene, tmp_json, tmpfile

    tmp_scene = 'fuzz_scene_tmp.scene'
    tmp_json = 'fuzz_scene_tmp.json'

    call parse_args(niters, seed, mode)
    call rng_seed(seed)

    write(output_unit, '(A)') 'fuzz_scene: mutation fuzz harness'
    write(output_unit, '(A,I0,A,I0,A,A)') &
        'fuzz_scene: iterations=', niters, ' seed=', seed, &
        ' mode=', trim(mode)
    write(output_unit, '(A)') &
        'fuzz_scene: a crash / sanitizer abort before the SUMMARY' // &
        ' line is the finding; the temp file named below is the' // &
        ' reproducer for the iteration in flight.'

    ! ---- sanity leg: both UNMUTATED seeds must load (ok may still
    ! be .false. only if a seed here is wrong -- that is a harness
    ! bug, reported loudly, not a reader finding). ------------------
    call build_seed_scene(seedbuf, seedlen)
    buf = seedbuf
    buflen = seedlen
    call write_temp(tmp_scene, buf, buflen)
    sc = Scene()
    call scene_load(trim(tmp_scene), sc, ok, errmsg)
    write(output_unit, '(A,L1,A,A)') &
        'fuzz_scene: seed .scene load ok=', ok, ' errmsg=', trim(errmsg)
    call scene_free(sc)

    call build_seed_json(seedbuf, seedlen)
    buf = seedbuf
    buflen = seedlen
    call write_temp(tmp_json, buf, buflen)
    sc = Scene()
    call scene_load_json(trim(tmp_json), sc, ok, errmsg)
    write(output_unit, '(A,L1,A,A)') &
        'fuzz_scene: seed .json load ok=', ok, ' errmsg=', trim(errmsg)
    call scene_free(sc)

    ! ---- main loop -------------------------------------------------
    n_accepted = 0
    n_rejected = 0
    n_scene = 0
    n_json = 0

    do iter = 1, niters
        ! Format choice.  Nested ifs only (see header trap note).
        use_json = .false.
        if (trim(mode) == 'json') then
            use_json = .true.
        else if (trim(mode) == 'both') then
            if (rng_below(2) == 1) use_json = .true.
        end if

        if (use_json) then
            call build_seed_json(seedbuf, seedlen)
            tmpfile = tmp_json
            n_json = n_json + 1
        else
            call build_seed_scene(seedbuf, seedlen)
            tmpfile = tmp_scene
            n_scene = n_scene + 1
        end if
        buf = seedbuf
        buflen = seedlen

        ! 1..5 mutations: byte ops always; the format-specific op
        ! (line ops for text, token swaps for JSON) with p = 0.4.
        nmut = 1 + rng_below(5)
        do i = 1, nmut
            choice = rng_below(100)
            if (choice < 40) then
                if (use_json) then
                    call mutate_json_tokens(buf, buflen)
                else
                    call mutate_lines(buf, buflen)
                end if
            else
                call mutate_bytes(buf, buflen)
            end if
        end do

        ! Write BEFORE the load: on a crash this file is the case.
        call write_temp(tmpfile, buf, buflen)

        sc = Scene()
        if (use_json) then
            call scene_load_json(trim(tmpfile), sc, ok, errmsg)
        else
            call scene_load(trim(tmpfile), sc, ok, errmsg)
        end if
        if (ok) then
            n_accepted = n_accepted + 1
        else
            n_rejected = n_rejected + 1
        end if
        ! Freed unconditionally: a rejected or partial load must
        ! still leave a Scene that scene_free can release.
        call scene_free(sc)

        if (mod(iter, 250) == 0) then
            write(output_unit, '(A,I0,A,I0,A,I0,A,I0)') &
                'fuzz_scene: progress iter=', iter, '/', niters, &
                ' accepted=', n_accepted, ' rejected=', n_rejected
            flush(output_unit)
        end if
    end do

    write(output_unit, &
        '(A,A,A,I0,A,I0,A,I0,A,I0,A,I0,A,I0,A)') &
        'fuzz_scene: SUMMARY mode=', trim(mode), &
        ' seed=', seed, &
        ' iterations=', niters, &
        ' scene_iters=', n_scene, &
        ' json_iters=', n_json, &
        ' accepted=', n_accepted, &
        ' rejected=', n_rejected, &
        ' crashes=0'

contains

    ! ------------------------------------------------------------------
    ! Command line: [iterations] [seed] [mode], all optional.
    ! Bad values fall back to the defaults (with the iteration count
    ! clamped); a fuzzer that refuses to start over a typo wastes
    ! more findings than it saves.
    ! ------------------------------------------------------------------
    subroutine parse_args(p_niters, p_seed, p_mode)
        integer, intent(out) :: p_niters
        integer(int64), intent(out) :: p_seed
        character(len=*), intent(out) :: p_mode
        character(len=64) :: arg
        integer :: nargs, ios, ival
        integer(int64) :: sval

        p_niters = DEFAULT_ITERS
        p_seed = DEFAULT_SEED
        p_mode = 'both'

        nargs = command_argument_count()
        if (nargs >= 1) then
            call get_command_argument(1, arg)
            read(arg, *, iostat=ios) ival
            if (ios == 0) p_niters = ival
        end if
        if (nargs >= 2) then
            call get_command_argument(2, arg)
            read(arg, *, iostat=ios) sval
            if (ios == 0) p_seed = sval
        end if
        if (nargs >= 3) then
            call get_command_argument(3, arg)
            if (trim(arg) == 'scene') p_mode = 'scene'
            if (trim(arg) == 'json') p_mode = 'json'
            if (trim(arg) == 'both') p_mode = 'both'
        end if

        if (p_niters < 1) p_niters = 1
        if (p_niters > MAX_ITERS) p_niters = MAX_ITERS
    end subroutine parse_args

    ! ------------------------------------------------------------------
    ! Seed construction.  Lines are appended with add_line (which
    ! appends len_trim(text) + LF); leading spaces survive, so JSON
    ! indentation and .scene layout are exactly as written here.
    ! ------------------------------------------------------------------
    subroutine add_bytes(b, blen, s, n)
        character(len=*), intent(inout) :: b
        integer, intent(inout) :: blen
        character(len=*), intent(in) :: s
        integer, intent(in) :: n
        integer :: k, take
        take = n
        if (blen + take > MAXBUF) take = MAXBUF - blen
        if (take <= 0) return
        do k = 1, take
            b(blen + k:blen + k) = s(k:k)
        end do
        blen = blen + take
    end subroutine add_bytes

    subroutine add_line(b, blen, s)
        character(len=*), intent(inout) :: b
        integer, intent(inout) :: blen
        character(len=*), intent(in) :: s
        call add_bytes(b, blen, s, len_trim(s))
        call add_bytes(b, blen, achar(10), 1)
    end subroutine add_line

    ! Small VALID .scene v1 seed.  Grammar mirrors src/scene.f90's
    ! reader (see its header comment): version line, size, bg,
    ! camera (13 fields), light directional / ambient / point,
    ! frames, fps, output, object (20 tokens), objmat (8 tokens),
    ! objalpha / objemissive, tris + tri lines, keys + key lines,
    ! anim (9 tokens).  No texture or loadobj paths: the seed must
    ! load identically from any working directory.
    subroutine build_seed_scene(b, blen)
        character(len=*), intent(out) :: b
        integer, intent(out) :: blen
        b = ' '
        blen = 0
        call add_line(b, blen, 'forge3d-scene 1')
        call add_line(b, blen, '# fuzz_scene seed (valid v1 text)')
        call add_line(b, blen, 'size 64 48')
        call add_line(b, blen, 'bg 25 25 35')
        call add_line(b, blen, &
            'camera 3 2.5 4 0 0 0 0 1 0 60 0.1 100')
        call add_line(b, blen, &
            'light directional -0.5 -1 -0.7 255 255 255 1')
        call add_line(b, blen, 'light ambient 0.25')
        call add_line(b, blen, &
            'light point 2 3 4 255 200 150 1 10 2')
        call add_line(b, blen, 'frames 30')
        call add_line(b, blen, 'fps 30')
        call add_line(b, blen, 'output fuzz_out.ppm')
        call add_line(b, blen, &
            'object cube cube1 lambert 220 60 60 0 0 0 20 35 0' // &
            ' 1 1 1 2 -1 -1 0')
        call add_line(b, blen, &
            'objmat cube1 standard 0.1 0.8 0.5 32 -')
        call add_line(b, blen, 'objalpha cube1 0 0.5 1')
        call add_line(b, blen, 'objemissive cube1 0 0 0')
        call add_line(b, blen, &
            'object sphere ball lambert 60 100 240 2 0 0 0 0 0' // &
            ' 1 1 1 -1 1 -1 16')
        call add_line(b, blen, 'tris patch 2')
        call add_line(b, blen, &
            'tri 255 0 0 0 0 0 1 0 0 0 1 0')
        call add_line(b, blen, &
            'tri 0 255 0 0 0 1 1 0 1 0 1 1')
        call add_line(b, blen, 'keys cube1 5 forever 2')
        call add_line(b, blen, 'key 0 0 0 0 0 0 0 1 linear')
        call add_line(b, blen, 'key 2.5 0 1 0 0 90 0 1 linear')
        call add_line(b, blen, &
            'anim spin cube1 y 90 5 30 linear forever')
    end subroutine build_seed_scene

    ! Small VALID forge3d-scene JSON seed.  Shape mirrors
    ! docs/SCENE-FORMAT.md and src/scene_json.f90: required
    ! "format" / "ir_version", width / height / bg, camera object,
    ! lights array, objects array (the objmat data living in
    ! extensions.material, as the JSON format specifies), an
    ! animations array, outputs, and extensions.waveb key tracks
    ! (an object keyed by target name, per the format contract).
    subroutine build_seed_json(b, blen)
        character(len=*), intent(out) :: b
        integer, intent(out) :: blen
        b = ' '
        blen = 0
        call add_line(b, blen, '{')
        call add_line(b, blen, ' "format": "forge3d-scene",')
        call add_line(b, blen, ' "ir_version": 1,')
        call add_line(b, blen, ' "version": 2,')
        call add_line(b, blen, ' "name": "fuzz-seed",')
        call add_line(b, blen, ' "width": 64,')
        call add_line(b, blen, ' "height": 48,')
        call add_line(b, blen, ' "bg": [25, 25, 35],')
        call add_line(b, blen, ' "camera": {')
        call add_line(b, blen, '  "pos": [3.0, 2.5, 4.0],')
        call add_line(b, blen, '  "target": [0.0, 0.0, 0.0],')
        call add_line(b, blen, '  "up": [0.0, 1.0, 0.0],')
        call add_line(b, blen, '  "fov": 60.0,')
        call add_line(b, blen, '  "near": 0.1,')
        call add_line(b, blen, '  "far": 100.0')
        call add_line(b, blen, ' },')
        call add_line(b, blen, ' "lights": [')
        call add_line(b, blen, &
            '  {"kind": "directional",' // &
            ' "direction": [-0.5, -1.0, -0.7],' // &
            ' "color": [255, 255, 255], "intensity": 1.0},')
        call add_line(b, blen, &
            '  {"kind": "ambient", "intensity": 0.25}')
        call add_line(b, blen, ' ],')
        call add_line(b, blen, ' "objects": [')
        call add_line(b, blen, '  {')
        call add_line(b, blen, '   "prim": "cube",')
        call add_line(b, blen, '   "name": "cube1",')
        call add_line(b, blen, '   "material": "lambert",')
        call add_line(b, blen, '   "color": [220, 60, 60],')
        call add_line(b, blen, '   "pos": [0.0, 0.0, 0.0],')
        call add_line(b, blen, '   "rotate": [20.0, 35.0, 0.0],')
        call add_line(b, blen, '   "scale": [1.0, 1.0, 1.0],')
        call add_line(b, blen, '   "size": 2.0,')
        call add_line(b, blen, '   "radius": null,')
        call add_line(b, blen, '   "height": null,')
        call add_line(b, blen, '   "segments": null,')
        call add_line(b, blen, '   "source_file": null,')
        call add_line(b, blen, '   "triangles": null,')
        call add_line(b, blen, '   "extensions": {')
        call add_line(b, blen, '    "material": {')
        call add_line(b, blen, '     "metalness": 0.1,')
        call add_line(b, blen, '     "roughness": 0.8,')
        call add_line(b, blen, '     "specular": 0.5,')
        call add_line(b, blen, '     "shininess": 32.0,')
        call add_line(b, blen, '     "texture": null')
        call add_line(b, blen, '    }')
        call add_line(b, blen, '   }')
        call add_line(b, blen, '  },')
        call add_line(b, blen, '  {')
        call add_line(b, blen, '   "prim": "sphere",')
        call add_line(b, blen, '   "name": "ball",')
        call add_line(b, blen, '   "material": "lambert",')
        call add_line(b, blen, '   "color": [60, 100, 240],')
        call add_line(b, blen, '   "pos": [2.0, 0.0, 0.0],')
        call add_line(b, blen, '   "rotate": [0.0, 0.0, 0.0],')
        call add_line(b, blen, '   "scale": [1.0, 1.0, 1.0],')
        call add_line(b, blen, '   "size": null,')
        call add_line(b, blen, '   "radius": 1.0,')
        call add_line(b, blen, '   "height": null,')
        call add_line(b, blen, '   "segments": 16,')
        call add_line(b, blen, '   "source_file": null,')
        call add_line(b, blen, '   "triangles": null,')
        call add_line(b, blen, '   "extensions": {}')
        call add_line(b, blen, '  }')
        call add_line(b, blen, ' ],')
        call add_line(b, blen, ' "animations": [')
        call add_line(b, blen, &
            '  {"kind": "spin", "target": "cube1", "axis": "y",' // &
            ' "speed": 90.0, "duration": 5.0, "fps": 30,' // &
            ' "ease": "linear", "loop": "forever"}')
        call add_line(b, blen, ' ],')
        call add_line(b, blen, ' "outputs": [')
        call add_line(b, blen, &
            '  {"kind": "render", "format": "render",' // &
            ' "path": "fuzz_out.ppm", "width": 64, "height": 48}')
        call add_line(b, blen, ' ],')
        call add_line(b, blen, ' "extensions": {')
        call add_line(b, blen, '  "waveb": {')
        call add_line(b, blen, '   "keys": {')
        call add_line(b, blen, '    "cube1": {')
        call add_line(b, blen, '     "duration": 5.0,')
        call add_line(b, blen, '     "loop": "forever",')
        call add_line(b, blen, '     "keys": [')
        call add_line(b, blen, &
            '      {"time": 0.0, "pos": [0.0, 0.0, 0.0],' // &
            ' "rot": [0.0, 0.0, 0.0], "scale": 1.0,' // &
            ' "ease": "linear"},')
        call add_line(b, blen, &
            '      {"time": 2.5, "pos": [0.0, 1.0, 0.0],' // &
            ' "rot": [0.0, 90.0, 0.0], "scale": 1.0,' // &
            ' "ease": "linear"}')
        call add_line(b, blen, '     ]')
        call add_line(b, blen, '    }')
        call add_line(b, blen, '   }')
        call add_line(b, blen, '  }')
        call add_line(b, blen, ' }')
        call add_line(b, blen, '}')
    end subroutine build_seed_json

    ! ------------------------------------------------------------------
    ! Temp-file write: one formatted record carrying the whole
    ! buffer (embedded LFs make it many physical lines, which is
    ! exactly what the text reader consumes; the JSON reader reads
    ! the file as a stream, so record structure is irrelevant).
    ! ------------------------------------------------------------------
    subroutine write_temp(path, b, blen)
        character(len=*), intent(in) :: path
        character(len=*), intent(in) :: b
        integer, intent(in) :: blen
        integer :: u, ios
        open(newunit=u, file=trim(path), status='replace', &
             action='write', iostat=ios)
        if (ios /= 0) then
            write(output_unit, '(A,A)') &
                'fuzz_scene: FATAL: cannot write temp file ', &
                trim(path)
            stop 2
        end if
        if (blen > 0) then
            write(u, '(A)', iostat=ios) b(1:blen)
        else
            write(u, '(A)', iostat=ios) ''
        end if
        close(u)
    end subroutine write_temp

    ! ------------------------------------------------------------------
    ! Slice primitives.  pos is 1-based; insert allows pos == blen+1
    ! (append).  All shifting is byte-by-byte (see header traps).
    ! ------------------------------------------------------------------
    subroutine insert_slice(b, blen, pos, src, srclen)
        character(len=*), intent(inout) :: b
        integer, intent(inout) :: blen
        integer, intent(in) :: pos, srclen
        character(len=*), intent(in) :: src
        integer :: k, take, p
        take = srclen
        if (take <= 0) return
        if (blen + take > MAXBUF) take = MAXBUF - blen
        if (take <= 0) return
        p = pos
        if (p < 1) p = 1
        if (p > blen + 1) p = blen + 1
        do k = blen, p, -1
            b(k + take:k + take) = b(k:k)
        end do
        do k = 1, take
            b(p + k - 1:p + k - 1) = src(k:k)
        end do
        blen = blen + take
    end subroutine insert_slice

    subroutine delete_slice(b, blen, pos, count)
        character(len=*), intent(inout) :: b
        integer, intent(inout) :: blen
        integer, intent(in) :: pos, count
        integer :: k, take, p
        take = count
        if (take <= 0) return
        p = pos
        if (p < 1) p = 1
        if (p > blen) return
        if (p + take - 1 > blen) take = blen - p + 1
        do k = p, blen - take
            b(k:k) = b(k + take:k + take)
        end do
        blen = blen - take
    end subroutine delete_slice

    ! ------------------------------------------------------------------
    ! A mutation-flavoured byte: mostly printable ASCII (the shape
    ! of both formats), sometimes a digit / structural character /
    ! whitespace, occasionally a control or high byte.
    ! ------------------------------------------------------------------
    function random_byte() result(ch)
        character(len=1) :: ch
        integer :: pick, idx
        character(len=26), parameter :: POOL = &
            '0123456789.eE+-"{}[]:,#xyz'
        pick = rng_below(100)
        if (pick < 55) then
            ch = achar(rng_between(32, 126))
        else if (pick < 75) then
            idx = 1 + rng_below(len(POOL))
            ch = POOL(idx:idx)
        else if (pick < 85) then
            select case (rng_below(3))
            case (0)
                ch = achar(10)
            case (1)
                ch = achar(9)
            case default
                ch = achar(13)
            end select
        else if (pick < 95) then
            ch = achar(rng_between(1, 31))
        else
            ch = achar(rng_between(128, 255))
        end if
    end function random_byte

    ! ------------------------------------------------------------------
    ! Byte-level mutations (both formats): replace, insert, delete,
    ! duplicate, truncate, and splice a short random run.  1..4 ops
    ! per call.  Every position draw is guarded by a nested if on
    ! blen -- never by .AND. (see header traps).
    ! ------------------------------------------------------------------
    subroutine mutate_bytes(b, blen)
        character(len=*), intent(inout) :: b
        integer, intent(inout) :: blen
        integer :: op, nops, pos, run, k
        character(len=1) :: ch
        character(len=16) :: junk

        nops = 1 + rng_below(4)
        do op = 1, nops
            if (blen <= 0) then
                ! Empty input: only insertion is meaningful.
                ch = random_byte()
                call insert_slice(b, blen, 1, ch, 1)
                cycle
            end if
            select case (rng_below(6))
            case (0)  ! replace one byte
                pos = 1 + rng_below(blen)
                b(pos:pos) = random_byte()
            case (1)  ! insert one byte
                pos = 1 + rng_below(blen + 1)
                ch = random_byte()
                call insert_slice(b, blen, pos, ch, 1)
            case (2)  ! delete a short run
                pos = 1 + rng_below(blen)
                run = 1 + rng_below(min(16, blen - pos + 1))
                call delete_slice(b, blen, pos, run)
            case (3)  ! duplicate one byte in place
                pos = 1 + rng_below(blen)
                ch = b(pos:pos)
                call insert_slice(b, blen, pos, ch, 1)
            case (4)  ! truncate at a random point
                blen = rng_below(blen + 1)
            case default  ! splice a short random run
                run = 1 + rng_below(12)
                junk = ' '
                do k = 1, run
                    junk(k:k) = random_byte()
                end do
                pos = 1 + rng_below(blen + 1)
                call insert_slice(b, blen, pos, junk, run)
            end select
        end do
    end subroutine mutate_bytes

    ! ------------------------------------------------------------------
    ! Line table for the text format: lstart(i) = first byte of
    ! line i, llen(i) = its length INCLUDING the trailing LF when
    ! one is present.
    ! ------------------------------------------------------------------
    subroutine line_table(b, blen, lstart, llen, nlines)
        character(len=*), intent(in) :: b
        integer, intent(in) :: blen
        integer, intent(out) :: lstart(:), llen(:), nlines
        integer :: k, cur
        nlines = 0
        if (blen <= 0) return
        cur = 1
        do k = 1, blen
            if (b(k:k) == achar(10)) then
                if (nlines < size(lstart)) then
                    nlines = nlines + 1
                    lstart(nlines) = cur
                    llen(nlines) = k - cur + 1
                end if
                cur = k + 1
            end if
        end do
        if (cur <= blen) then
            if (nlines < size(lstart)) then
                nlines = nlines + 1
                lstart(nlines) = cur
                llen(nlines) = blen - cur + 1
            end if
        end if
    end subroutine line_table

    ! Copy line `idx` (per the table) into `out`; guarantees the
    ! copy ends with an LF so it can be inserted as a whole line.
    subroutine copy_line(b, lstart, llen, idx, out, outlen)
        character(len=*), intent(in) :: b
        integer, intent(in) :: lstart(:), llen(:), idx
        character(len=*), intent(out) :: out
        integer, intent(out) :: outlen
        integer :: k, n
        n = llen(idx)
        if (n > len(out)) n = len(out)
        do k = 1, n
            out(k:k) = b(lstart(idx) + k - 1:lstart(idx) + k - 1)
        end do
        outlen = n
        if (outlen > 0) then
            if (out(outlen:outlen) /= achar(10)) then
                if (outlen < len(out)) then
                    outlen = outlen + 1
                    out(outlen:outlen) = achar(10)
                end if
            end if
        end if
    end subroutine copy_line

    ! ------------------------------------------------------------------
    ! Line-level mutations (text format only): duplicate a line,
    ! delete a line, move a line elsewhere (reordering exercises
    ! order-sensitive paths: objmat/objtex after object, key after
    ! keys, tri after tris), replace one line with another, or
    ! truncate at a line boundary.  Short lines are where the v1
    ! reader's per-line token-count guards live, so whole-line
    ! damage is at least as interesting as byte damage.
    ! ------------------------------------------------------------------
    subroutine mutate_lines(b, blen)
        character(len=*), intent(inout) :: b
        integer, intent(inout) :: blen
        integer :: lstart(MAXLINES), llen(MAXLINES), nlines
        integer :: src, dst, op
        character(len=2048) :: linecopy
        integer :: copylen

        call line_table(b, blen, lstart, llen, nlines)
        if (nlines < 2) return

        op = rng_below(5)
        src = 1 + rng_below(nlines)
        dst = 1 + rng_below(nlines)

        select case (op)
        case (0)  ! duplicate src line at dst line's position
            call copy_line(b, lstart, llen, src, linecopy, copylen)
            call insert_slice(b, blen, lstart(dst), linecopy, copylen)
        case (1)  ! delete src line
            call delete_slice(b, blen, lstart(src), llen(src))
        case (2)  ! move src line to dst (cut, then insert)
            call copy_line(b, lstart, llen, src, linecopy, copylen)
            call delete_slice(b, blen, lstart(src), llen(src))
            call line_table(b, blen, lstart, llen, nlines)
            if (nlines >= 1) then
                dst = 1 + rng_below(nlines)
                call insert_slice(b, blen, lstart(dst), linecopy, &
                                  copylen)
            else
                call insert_slice(b, blen, 1, linecopy, copylen)
            end if
        case (3)  ! replace dst line with a copy of src line
            if (src /= dst) then
                call copy_line(b, lstart, llen, src, linecopy, &
                               copylen)
                call delete_slice(b, blen, lstart(dst), llen(dst))
                call insert_slice(b, blen, lstart(dst), linecopy, &
                                  copylen)
            end if
        case default  ! truncate at the end of line src
            blen = lstart(src) + llen(src) - 1
        end select
    end subroutine mutate_lines

    ! ------------------------------------------------------------------
    ! Token-level mutations (JSON only): find a known token from the
    ! seed vocabulary and swap it for a same-class troublemaker --
    ! another prim / material / light kind, a type change (null <->
    ! number <-> string <-> array), or an extreme number.  This
    ! reaches type confusion paths that random bytes rarely build
    ! (valid JSON, wrong types), complementing mutate_bytes, which
    ! mostly builds invalid JSON.
    ! ------------------------------------------------------------------
    subroutine mutate_json_tokens(b, blen)
        character(len=*), intent(inout) :: b
        integer, intent(inout) :: blen
        integer, parameter :: NTOK = 14
        character(len=20) :: from_tok(NTOK), to_tok(NTOK)
        integer :: try, pick, pos, fromlen, tolen
        character(len=20) :: needle

        from_tok = [character(len=20) :: &
            '"forge3d-scene"', '"cube"', '"sphere"', '"lambert"', &
            '"directional"', '"ambient"', '"spin"', '"render"', &
            'null', 'true', '60.0', '2.0', '"cube1"', '"forever"']
        to_tok = [character(len=20) :: &
            '"forge3d-scenf"', '"torusknot"', '"tris"', '"standard"', &
            '"spot"', '"bogus"', '"bogus"', '"still"', &
            '0', 'false', '1e999', '-1', '"ball"', 'null']

        ! A few attempts: the picked token may have been destroyed
        ! by an earlier mutation in this same iteration.
        do try = 1, 6
            pick = 1 + rng_below(NTOK)
            needle = from_tok(pick)
            fromlen = len_trim(needle)
            tolen = len_trim(to_tok(pick))
            if (blen < fromlen) return
            pos = index(b(1:blen), needle(1:fromlen))
            if (pos <= 0) cycle
            call delete_slice(b, blen, pos, fromlen)
            call insert_slice(b, blen, pos, to_tok(pick), tolen)
            return
        end do
    end subroutine mutate_json_tokens

end program fuzz_scene
