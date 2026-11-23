! fuzz_loaders.f90 -- mutation fuzz harness for the Forge3D model
! loaders (Forge3D v3.0 Phase 9, hardening).
!
! Purpose
! -------
! Feed byte-level mutations of two small, KNOWN-VALID seed assets --
! a Wavefront OBJ and a glTF 2.0 JSON file -- to the REAL engine
! loaders, over and over, looking for crashes, hangs, out-of-bounds
! accesses and leaks rather than for wrong answers.  The loaders
! promise (see their headers) that any failure returns ok=.false.
! with a 0-triangle mesh and that they never stop on bad input; this
! harness is the adversarial check of that promise.  A run that
! finishes prints its summary line; a run that does not has found
! something, and the printed seed + iteration let anyone replay the
! exact byte stream that did it (the PRNG is deterministic).
!
! Usage
! -----
!   fuzz_loaders [iterations [seed]]
!     iterations  bounded iteration count (default 5000, min 1)
!     seed        int64 splitmix64 seed   (default 305419896)
!   Each iteration mutates ONE seed (chosen by the PRNG), writes it
!   to a scratch file in the CURRENT directory
!   ("fuzz_load_tmp.obj" or "fuzz_load_tmp.gltf", deleted after the
!   iteration), calls the matching extended loader, discards the
!   result with the proper frees, and moves on.  Before the loop the
!   two unmutated seeds are loaded once as a sanity check: if a seed
!   itself fails, the harness says so (the seed, not the loader, is
!   then the first suspect) but still fuzzes.
!
! Build (sanitizers are the whole point; run from a scratch dir)
! ---------------------------------------------------------------
!   gfortran -g -O1 -fsanitize=address,undefined \
!            -o fuzz_loaders tests/fuzz/fuzz_loaders.f90 <link set>
!   No signed-integer-overflow carve-out is needed: the splitmix64
!   PRNG below does its add and multiplies in 16-bit limbs
!   (add64/mul64 helpers, bit-exact modulo 2**64), so the harness
!   itself never commits signed overflow; every undefined-behaviour
!   check stays on, and ASan stays on in full.
!   Leak checking (ASan's default) matters here: every iteration
!   frees its mesh + info, so a leak report points at a loader path
!   that kept something.
!
! Link set (the modules the two loaders pull in, in order)
! ---------------------------------------------------------
!   src/math_3d.f90       (module math_3d: dp, vec3, mat4)
!   src/mesh_data.f90     (module mesh_data_3d, used by mesh_3d)
!   src/mesh.f90          (module mesh_3d: Mesh, Triangle, free_mesh)
!   src/json_reader.f90   (module json_reader_3d, used by gltf_loader)
!   src/obj_loader.f90    (module obj_loader)
!   src/gltf_loader.f90   (module gltf_loader)
! Nothing else: the loaders need no renderer, texture, scene or
! material modules.
!
! Future work
! -----------
!   * A .glb seed.  The glTF seed below is the .gltf JSON path with
!     an embedded base64 data-URI buffer.  Building the equivalent
!     .glb (12-byte header + JSON chunk + BIN chunk, 4-byte aligned
!     and space/NUL padded) as an in-code byte array is doable but
!     fiddly enough that it is left as a follow-up; the loader's GLB
!     container path (magic / version / chunk headers in
!     load_gltf_ex) is therefore NOT covered by this harness yet.
!     Note the BIN-chunk payload itself would be the same 36 bytes
!     the base64 below decodes to.
!   * Structure-aware mutations (swap whole JSON members / OBJ
!     lines, splice two mutations together).  v1 is pure byte level.
!
! Fortran trap honoured throughout: .and. / .or. do NOT short-
! circuit, so no array index is ever guarded by a compound
! condition -- every bounds check is a nested if.
program fuzz_loaders
    use, intrinsic :: iso_fortran_env, only: int8, int64, output_unit
    use mesh_3d, only: Mesh, free_mesh
    use obj_loader, only: load_obj_ex, ObjInfo, obj_free_info
    use gltf_loader, only: load_gltf_ex, GltfInfo, gltf_free_info
    implicit none

    integer, parameter :: DEFAULT_ITERS = 5000
    integer(int64), parameter :: DEFAULT_SEED = 305419896_int64
    integer, parameter :: MAX_WORK = 8192   ! hard cap on mutated size
    integer, parameter :: PROGRESS_EVERY = 1000

    integer(int64) :: rng_state
    integer(int64) :: seed
    integer :: n_iters, iter, n_ok, n_fail, n_obj, n_gltf
    integer(int64) :: total_tris
    integer, allocatable :: seed_obj(:), seed_gltf(:), work(:)
    logical :: use_obj, ok
    type(Mesh) :: fmesh
    type(ObjInfo) :: oinfo
    type(GltfInfo) :: ginfo
    character(len=64) :: arg
    integer :: ios, arglen

    ! ----------------------------------------------------------------
    ! Arguments: [iterations [seed]], both optional and forgiving --
    ! an unparseable argument falls back to the default, it never
    ! stops the harness before it starts.  (Order matches
    ! run_fuzz.sh and the other harnesses; it was [seed [iterations]]
    ! until the v3.0 verification pass aligned it.)
    ! ----------------------------------------------------------------
    seed = DEFAULT_SEED
    n_iters = DEFAULT_ITERS
    if (command_argument_count() >= 1) then
        call get_command_argument(1, arg, arglen, ios)
        if (ios == 0) then
            block
                integer :: v
                read (arg, *, iostat=ios) v
                if (ios == 0) then
                    if (v >= 1) n_iters = v
                end if
            end block
        end if
    end if
    if (command_argument_count() >= 2) then
        call get_command_argument(2, arg, arglen, ios)
        if (ios == 0) then
            block
                integer(int64) :: v
                read (arg, *, iostat=ios) v
                if (ios == 0) seed = v
            end block
        end if
    end if
    rng_state = seed

    call build_seeds(seed_obj, seed_gltf)

    write (output_unit, '(A,I0,A,I0)') &
        'fuzz_loaders: seed=', seed, ' iterations=', n_iters
    write (output_unit, '(A,I0,A,I0,A)') &
        'fuzz_loaders: seed sizes: obj=', size(seed_obj), &
        ' bytes, gltf=', size(seed_gltf), ' bytes'

    ! Sanity: the unmutated seeds must load.  Results are counted
    ! separately (not in the fuzz tallies below).
    call run_one(seed_obj, .true., ok, fmesh, oinfo, ginfo)
    write (output_unit, '(A,L1,A,I0,A)') &
        'fuzz_loaders: sanity OBJ seed ok=', ok, &
        ' triangles=', fmesh%num_triangles, ' (failure = suspect seed)'
    call free_mesh(fmesh)
    call obj_free_info(oinfo)
    call run_one(seed_gltf, .false., ok, fmesh, oinfo, ginfo)
    write (output_unit, '(A,L1,A,I0,A)') &
        'fuzz_loaders: sanity glTF seed ok=', ok, &
        ' triangles=', fmesh%num_triangles, ' (failure = suspect seed)'
    call free_mesh(fmesh)
    call gltf_free_info(ginfo)

    ! ----------------------------------------------------------------
    ! Fuzz loop.
    ! ----------------------------------------------------------------
    n_ok = 0; n_fail = 0; n_obj = 0; n_gltf = 0
    total_tris = 0_int64
    do iter = 1, n_iters
        use_obj = (rand_below(2) == 0)
        if (use_obj) then
            call copy_bytes(seed_obj, work)
        else
            call copy_bytes(seed_gltf, work)
        end if
        call mutate(work)

        call run_one(work, use_obj, ok, fmesh, oinfo, ginfo)
        if (use_obj) then
            n_obj = n_obj + 1
            call obj_free_info(oinfo)
        else
            n_gltf = n_gltf + 1
            call gltf_free_info(ginfo)
        end if
        if (ok) then
            n_ok = n_ok + 1
            total_tris = total_tris + int(fmesh%num_triangles, int64)
        else
            n_fail = n_fail + 1
        end if
        call free_mesh(fmesh)
        if (allocated(work)) deallocate (work)

        if (mod(iter, PROGRESS_EVERY) == 0) then
            write (output_unit, '(A,I0,A,I0,A,I0,A,I0)') &
                'fuzz_loaders: ', iter, '/', n_iters, &
                ' ok=', n_ok, ' rejected=', n_fail
            flush (output_unit)
        end if
    end do

    write (output_unit, '(A,I0,A,I0,A,I0,A,I0,A,I0,A,I0)') &
        'fuzz_loaders: DONE seed=', seed, ' iterations=', n_iters, &
        ' obj=', n_obj, ' gltf=', n_gltf, ' ok=', n_ok, &
        ' rejected=', n_fail
    write (output_unit, '(A,I0)') &
        'fuzz_loaders: total triangles from accepted mutations=', &
        total_tris

    if (allocated(seed_obj)) deallocate (seed_obj)
    if (allocated(seed_gltf)) deallocate (seed_gltf)

contains

    ! ================================================================
    ! Deterministic PRNG: splitmix64 (Stafford / Vigna).  All
    ! arithmetic is modulo 2**64 by design; the add and the two
    ! multiplies are done in 16-bit limbs (add64/mul64 below), so
    ! no signed overflow occurs under UBSan.  Only the xor/shift
    ! mixing touches the raw int64 bit pattern.
    ! ================================================================
    function next_u64() result(z)
        integer(int64) :: z
        rng_state = add64(rng_state, -7046029254386353131_int64)  ! 9E3779B97F4A7C15
        z = rng_state
        z = ieor(z, ishft(z, -30))
        z = mul64(z, -4658895280553007687_int64)                  ! BF58476D1CE4E5B9
        z = ieor(z, ishft(z, -27))
        z = mul64(z, -7723592293110705685_int64)                  ! 94D049BB133111EB
        z = ieor(z, ishft(z, -31))
    end function next_u64

    ! Split an int64 bit pattern into four 16-bit limbs (limb 1 is
    ! least significant), each a non-negative value in 0..65535.
    pure function limbs_of(x) result(l)
        integer(int64), intent(in) :: x
        integer(int64) :: l(4)
        integer :: i
        do i = 1, 4
            l(i) = iand(ishft(x, -16 * (i - 1)), 65535_int64)
        end do
    end function limbs_of

    ! Reassemble four 16-bit limbs into an int64 bit pattern, using
    ! only shifts and ors.
    pure function from_limbs(l) result(x)
        integer(int64), intent(in) :: l(4)
        integer(int64) :: x
        integer :: i
        x = 0_int64
        do i = 4, 1, -1
            x = ior(ishft(x, 16), l(i))
        end do
    end function from_limbs

    ! (a + b) mod 2**64, limb by limb.
    pure function add64(a, b) result(r)
        integer(int64), intent(in) :: a, b
        integer(int64) :: r, la(4), lb(4), lr(4), s, carry
        integer :: i
        la = limbs_of(a)
        lb = limbs_of(b)
        carry = 0_int64
        do i = 1, 4
            s = la(i) + lb(i) + carry
            lr(i) = iand(s, 65535_int64)
            carry = ishft(s, -16)
        end do
        r = from_limbs(lr)
    end function add64

    ! (a * b) mod 2**64, limb by limb.  Partial sums stay below
    ! 4 * 65535**2 + carry (about 2**35), far inside int64.
    pure function mul64(a, b) result(r)
        integer(int64), intent(in) :: a, b
        integer(int64) :: r, la(4), lb(4), lr(4), s, carry
        integer :: i, j, k
        la = limbs_of(a)
        lb = limbs_of(b)
        carry = 0_int64
        do k = 1, 4
            s = carry
            do i = 1, 4
                j = k + 1 - i
                if (j < 1) cycle
                if (j > 4) cycle
                s = s + la(i) * lb(j)
            end do
            lr(k) = iand(s, 65535_int64)
            carry = ishft(s, -16)
        end do
        r = from_limbs(lr)
    end function mul64

    ! Uniform-enough draw in [0, n); n must be >= 1.  The draw is
    ! masked to a non-negative int64 first, so mod never sees a
    ! negative dividend.
    function rand_below(n) result(v)
        integer, intent(in) :: n
        integer :: v
        v = int(mod(iand(next_u64(), huge(0_int64)), int(n, int64)))
    end function rand_below

    ! One random byte 0..255.
    function rand_byte() result(v)
        integer :: v
        v = rand_below(256)
    end function rand_byte

    ! A byte chosen to stress parsers: NUL, whitespace, JSON and OBJ
    ! punctuation, sign / exponent / slash characters, DEL, 0xFF and
    ! plain digits and letters.
    function interesting_byte() result(v)
        integer :: v
        integer, parameter :: TABLE(24) = [ &
            0, 9, 10, 13, 32, 34, 35, 44, 45, 46, 47, 58, &
            91, 93, 123, 125, 127, 255, &
            iachar('0'), iachar('9'), iachar('e'), iachar('E'), &
            iachar('.'), iachar('/')]
        v = TABLE(rand_below(size(TABLE)) + 1)
    end function interesting_byte

    ! ================================================================
    ! Seeds
    ! ================================================================
    subroutine string_to_bytes(s, bytes)
        character(len=*), intent(in) :: s
        integer, allocatable, intent(out) :: bytes(:)
        integer :: i
        allocate (bytes(len(s)))
        do i = 1, len(s)
            bytes(i) = iachar(s(i:i))
        end do
    end subroutine string_to_bytes

    subroutine build_seeds(obj_bytes, gltf_bytes)
        integer, allocatable, intent(out) :: obj_bytes(:), gltf_bytes(:)
        character(len=:), allocatable :: obj_text, gltf_text
        character(len=1), parameter :: NL = char(10)

        ! Small valid OBJ: one quad (fan-triangulated by the loader)
        ! plus one triangle written with NEGATIVE (relative) indices,
        ! every face corner in full v/vt/vn form, under a group.
        obj_text = &
            '# fuzz seed: quad + negative-index triangle' // NL // &
            'v 0.0 0.0 0.0' // NL // &
            'v 1.0 0.0 0.0' // NL // &
            'v 1.0 1.0 0.0' // NL // &
            'v 0.0 1.0 0.0' // NL // &
            'vt 0.0 0.0' // NL // &
            'vt 1.0 0.0' // NL // &
            'vt 1.0 1.0' // NL // &
            'vt 0.0 1.0' // NL // &
            'vn 0.0 0.0 1.0' // NL // &
            'g quad' // NL // &
            'f 1/1/1 2/2/1 3/3/1 4/4/1' // NL // &
            'f -4/-4/-1 -3/-3/-1 -2/-2/-1' // NL
        call string_to_bytes(obj_text, obj_bytes)
        deallocate (obj_text)

        ! Small valid glTF 2.0 JSON: one node, one mesh, one
        ! primitive whose only attribute is POSITION (accessor 0,
        ! float VEC3, 3 vertices = one triangle, no indices so the
        ! loader synthesises the sequential index list).  The single
        ! buffer is a base64 data URI holding exactly the 36 bytes of
        ! the three positions (0,0,0) (1,0,0) (0,1,0) as little-
        ! endian float32:
        !   0.0f = 00 00 00 00,  1.0f = 00 00 80 3F
        !   bytes: 00000000 00000000 00000000 | 0000803F 00000000
        !          00000000 | 00000000 0000803F 00000000
        !   base64 (36 bytes -> 48 chars, no padding needed):
        !   AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA
        gltf_text = &
            '{"asset":{"version":"2.0"},' // &
            '"scene":0,"scenes":[{"nodes":[0]}],' // &
            '"nodes":[{"mesh":0}],' // &
            '"meshes":[{"primitives":[{"attributes":' // &
            '{"POSITION":0}}]}],' // &
            '"accessors":[{"bufferView":0,"componentType":5126,' // &
            '"count":3,"type":"VEC3","min":[0.0,0.0,0.0],' // &
            '"max":[1.0,1.0,0.0]}],' // &
            '"bufferViews":[{"buffer":0,"byteOffset":0,' // &
            '"byteLength":36}],' // &
            '"buffers":[{"byteLength":36,"uri":' // &
            '"data:application/octet-stream;base64,' // &
            'AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA"}]}'
        call string_to_bytes(gltf_text, gltf_bytes)
        deallocate (gltf_text)
    end subroutine build_seeds

    subroutine copy_bytes(src, dst)
        integer, intent(in) :: src(:)
        integer, allocatable, intent(out) :: dst(:)
        allocate (dst(size(src)))
        if (size(src) > 0) dst = src
    end subroutine copy_bytes

    ! ================================================================
    ! Mutation: 1..4 single-byte operations per iteration, each one
    ! of replace / replace-with-interesting / flip / insert /
    ! delete / truncate.  Every index is bounds-checked with nested
    ! ifs (no short-circuit compound guards -- see the header).
    ! ================================================================
    subroutine mutate(buf)
        integer, allocatable, intent(inout) :: buf(:)
        integer :: nmut, k, op
        nmut = rand_below(4) + 1
        do k = 1, nmut
            if (.not. allocated(buf)) return
            op = rand_below(6)
            select case (op)
            case (0)  ! replace one byte with a random byte
                call mut_replace(buf, rand_byte())
            case (1)  ! replace one byte with an interesting byte
                call mut_replace(buf, interesting_byte())
            case (2)  ! flip: xor one byte with a random nonzero mask
                call mut_flip(buf)
            case (3)  ! insert one byte at a random position
                call mut_insert(buf, interesting_byte())
            case (4)  ! delete one byte
                call mut_delete(buf)
            case (5)  ! truncate to a random shorter length
                call mut_truncate(buf)
            end select
        end do
    end subroutine mutate

    subroutine mut_replace(buf, val)
        integer, allocatable, intent(inout) :: buf(:)
        integer, intent(in) :: val
        integer :: pos
        if (size(buf) > 0) then
            pos = rand_below(size(buf)) + 1
            if (pos >= 1) then
                if (pos <= size(buf)) buf(pos) = val
            end if
        end if
    end subroutine mut_replace

    subroutine mut_flip(buf)
        integer, allocatable, intent(inout) :: buf(:)
        integer :: pos, mask
        if (size(buf) > 0) then
            pos = rand_below(size(buf)) + 1
            mask = rand_below(255) + 1
            if (pos >= 1) then
                if (pos <= size(buf)) &
                    buf(pos) = ieor(buf(pos), mask)
            end if
        end if
    end subroutine mut_flip

    subroutine mut_insert(buf, val)
        integer, allocatable, intent(inout) :: buf(:)
        integer, intent(in) :: val
        integer, allocatable :: tmp(:)
        integer :: pos, n
        n = size(buf)
        if (n >= MAX_WORK) return
        pos = rand_below(n + 1) + 1        ! 1..n+1 (n+1 = append)
        allocate (tmp(n + 1))
        if (pos > 1) then
            if (n > 0) tmp(1:pos - 1) = buf(1:pos - 1)
        end if
        tmp(pos) = val
        if (pos <= n) tmp(pos + 1:n + 1) = buf(pos:n)
        call move_alloc(tmp, buf)
    end subroutine mut_insert

    subroutine mut_delete(buf)
        integer, allocatable, intent(inout) :: buf(:)
        integer, allocatable :: tmp(:)
        integer :: pos, n
        n = size(buf)
        if (n <= 1) return
        pos = rand_below(n) + 1
        allocate (tmp(n - 1))
        if (pos > 1) tmp(1:pos - 1) = buf(1:pos - 1)
        if (pos < n) tmp(pos:n - 1) = buf(pos + 1:n)
        call move_alloc(tmp, buf)
    end subroutine mut_delete

    subroutine mut_truncate(buf)
        integer, allocatable, intent(inout) :: buf(:)
        integer, allocatable :: tmp(:)
        integer :: n, newn
        n = size(buf)
        if (n <= 1) return
        newn = rand_below(n)               ! 0..n-1; 0 = empty file
        allocate (tmp(newn))
        if (newn > 0) tmp = buf(1:newn)
        call move_alloc(tmp, buf)
    end subroutine mut_truncate

    ! ================================================================
    ! One load: write the bytes to the scratch file for the format,
    ! call the REAL extended loader, delete the scratch file.  The
    ! caller owns mesh / oinfo / ginfo and frees them (only the info
    ! matching is_obj is meaningful after the call).
    ! ================================================================
    subroutine run_one(bytes, is_obj, ok_out, mesh_out, oi, gi)
        integer, intent(in) :: bytes(:)
        logical, intent(in) :: is_obj
        logical, intent(out) :: ok_out
        type(Mesh), intent(inout) :: mesh_out
        type(ObjInfo), intent(out) :: oi
        type(GltfInfo), intent(out) :: gi
        character(len=32) :: path
        integer :: u, i, ios, v
        integer(int8) :: b8

        if (is_obj) then
            path = 'fuzz_load_tmp.obj'
        else
            path = 'fuzz_load_tmp.gltf'
        end if

        open (newunit=u, file=trim(path), status='replace', &
              action='write', access='stream', form='unformatted', &
              iostat=ios)
        if (ios /= 0) then
            ok_out = .false.
            oi = ObjInfo()
            gi = GltfInfo()
            return
        end if
        do i = 1, size(bytes)
            v = bytes(i)
            ! Store the byte value 0..255 as a raw stream byte.
            if (v >= 128) then
                b8 = int(v - 256, int8)
            else
                b8 = int(v, int8)
            end if
            write (u, iostat=ios) b8
            if (ios /= 0) exit
        end do
        close (u)

        if (is_obj) then
            gi = GltfInfo()
            call load_obj_ex(trim(path), mesh_out, ok_out, oi)
        else
            oi = ObjInfo()
            call load_gltf_ex(trim(path), mesh_out, ok_out, gi)
        end if

        ! Delete the scratch file (best effort: a leftover is untidy,
        ! not a fuzz finding).
        open (newunit=u, file=trim(path), status='old', iostat=ios)
        if (ios == 0) close (u, status='delete')
    end subroutine run_one

end program fuzz_loaders
