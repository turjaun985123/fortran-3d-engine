! fuzz_png.f90 -- mutation fuzz harness for the Forge3D PNG codec
! (Forge3D v3.0, Phase 9 hardening).
!
! Purpose
! -------
! Throw deterministically mutated PNG byte streams at the engine's
! PNG decoder (texture_3d%png_decode in src/texture.f90) and randomly
! shaped pixel arrays at the engine's PNG writer (png_write_3d%
! png_save_file in src/png_write.f90), looking for the failures a
! fuzzer exists to find:
!
!   * crashes / out-of-bounds reads or writes inside the decoder's
!     chunk walk, its CRC-32 path, its DEFLATE/inflate code or its
!     unfilter/reconstruction code (caught by ASan/UBSan below);
!   * hangs on hostile chunk lengths or zlib streams (caught by the
!     runner's timeout);
!   * CORRECTNESS bugs in the writer->decoder round-trip: a valid
!     pixel array written by png_save_file MUST decode back to the
!     same (clamped) pixels.  A round-trip mismatch is not a crash,
!     so the harness prints a FINDING line and stops with a non-zero
!     exit the moment one is observed.
!
! Design
! ------
!   * Deterministic PRNG: splitmix64 over an int64 state, seeded
!     from the command line.  Every byte this program generates is a
!     pure function of (seed, iteration), so any finding reproduces
!     by re-running with the same arguments.
!   * Seed corpus, built IN CODE at startup:
!       1. a valid 8x8 RGB gradient PNG produced by the engine's own
!          writer (png_save_file to a temp file, bytes read back);
!       2. a hand-built 1x1 RGB PNG (stored-deflate IDAT, correct
!          CRC-32s) embedded below as a byte-value array;
!       3. a hand-built 1x1 greyscale PNG (colour type 0, stored-
!          deflate IDAT, correct CRC-32s), likewise embedded.
!     The hand-built files exercise decoder paths the writer never
!     emits (greyscale colour type, a second chunk layout).
!   * Per iteration: pick a corpus entry, copy it, apply 1..8
!     mutations biased toward the structural fields a decoder trusts
!     -- the signature, chunk LENGTH fields, chunk TYPE fields,
!     chunk CRC fields and the IDAT payload -- with occasional
!     truncation or junk extension, then call png_decode.  The
!     optional crc_check argument is exercised BOTH ways on
!     alternating iterations (absent on even, .true. on odd), so the
!     Phase 8 CRC-verifying path is fuzzed as hard as the default.
!     The decoded texture (if any) is always released with
!     texture_free before the next iteration.
!   * Writer fuzzing runs alongside: random pixel arrays with
!     widths/heights in 0..17 (raw draws can go negative; abs/mod
!     guards fold them into range, so 0 and the small sizes are hit
!     often) and channel values drawn slightly OUTSIDE 0..255 (the
!     writer clamps, so the expected decode is the clamped array)
!     are saved with png_save_file, read back and decoded with
!     crc_check=.true. (the writer's CRCs must verify).  Positive
!     sizes must round-trip exactly; a zero width or height must be
!     REJECTED by the decoder (a zero dimension is not a legal PNG).
!     Either violation is a FINDING and a non-zero exit.
!
! Usage
! -----
!   ./fuzz_png [iterations] [seed]
!     iterations  bounded iteration count (default 5000)
!     seed        splitmix64 seed (default 12345)
!   (Argument order matches tests/fuzz/run_fuzz.sh, which invokes
!   every harness as:  <harness> <iterations> <seed>.)
!
! Build (sanitizers are the whole point -- run under them)
! --------------------------------------------------------
!   gfortran -O1 -g -fsanitize=address,undefined -fcheck=all \
!       -fno-omit-frame-pointer -fno-sanitize-recover=all \
!       src/math_3d.f90 src/texture.f90 src/png_write.f90 \
!       tests/fuzz/fuzz_png.f90 -o fuzz_png
!
! Link set
! --------
!   tests/fuzz/fuzz_png.f90   (this program)
!   src/texture.f90           (module texture_3d: png_decode,
!                              texture_free, TextureImage)
!   src/math_3d.f90           (module math_3d -- texture_3d's only
!                              `use` dependency: dp, vec3, PI)
!   src/png_write.f90         (module png_write_3d: png_save_file;
!                              depends only on iso_fortran_env)
! tests/fuzz/run_fuzz.sh links this harness against its full
! ENGINE_SOURCES set (every src/*.f90 except src/main.f90), a
! superset of the minimal set above; either link must work.
!
! Fortran trap honoured throughout: .and./.or. do NOT short-circuit,
! so no array index is ever guarded by a compound logical -- every
! bounds-sensitive test below is a nested if (the same discipline
! texture.f90's own Phase 8 peek code follows).
program fuzz_png
    use, intrinsic :: iso_fortran_env, only: int8, int64
    use texture_3d, only: TextureImage, png_decode, texture_free
    use png_write_3d, only: png_save_file
    implicit none

    ! -----------------------------------------------------------------
    ! Hand-built seed corpora (byte values 0..255, converted to int8
    ! at startup by to_bytes).
    !
    ! HAND_RGB: 1x1 truecolour PNG, one red pixel.
    !   signature, IHDR (1x1, depth 8, colour type 2, CRC 0x907753DE),
    !   IDAT (15-byte stored-deflate zlib stream for the scanline
    !   00 FF 00 00, CRC 0x8D1DE582), IEND (CRC 0xAE426082).
    ! HAND_GREY: 1x1 greyscale PNG, one mid-grey pixel.
    !   signature, IHDR (1x1, depth 8, colour type 0, CRC 0x3A7E9B55),
    !   IDAT (13-byte stored-deflate zlib stream for the scanline
    !   00 80, CRC 0xC36E25E0), IEND (CRC 0xAE426082).
    ! -----------------------------------------------------------------
    integer, parameter :: HAND_RGB(72) = [ &
        137, 80, 78, 71, 13, 10, 26, 10, &
        0, 0, 0, 13, 73, 72, 68, 82, &
        0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, &
        144, 119, 83, 222, &
        0, 0, 0, 15, 73, 68, 65, 84, &
        120, 1, 1, 4, 0, 251, 255, 0, 255, 0, 0, 3, 1, 1, 0, &
        141, 29, 229, 130, &
        0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
    integer, parameter :: HAND_GREY(70) = [ &
        137, 80, 78, 71, 13, 10, 26, 10, &
        0, 0, 0, 13, 73, 72, 68, 82, &
        0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0, &
        58, 126, 155, 85, &
        0, 0, 0, 13, 73, 68, 65, 84, &
        120, 1, 1, 2, 0, 253, 255, 0, 128, 0, 130, 0, 129, &
        195, 110, 37, 224, &
        0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]

    character(len=*), parameter :: SEED_TMP = 'fuzz_png_seed.tmp'
    character(len=*), parameter :: RT_TMP   = 'fuzz_png_roundtrip.tmp'

    integer(int64) :: rng_state
    integer :: iterations, iter, seed_in
    integer :: n_decode_ok, n_decode_reject, n_crc_iters
    integer :: n_roundtrip, n_roundtrip_zero
    integer(int8), allocatable :: seed_main(:), seed_rgb(:), seed_grey(:)

    rng_state = 12345_int64
    iterations = 5000
    seed_in = 12345
    call read_args(iterations, seed_in)
    rng_state = int(seed_in, int64)

    write(*, '(A,I0,A,I0)') 'fuzz_png: iterations=', iterations, &
        ' seed=', seed_in

    ! ---- Seed corpus ------------------------------------------------
    call build_writer_seed(seed_main)
    allocate(seed_rgb(size(HAND_RGB)), seed_grey(size(HAND_GREY)))
    seed_rgb = to_bytes(HAND_RGB)
    seed_grey = to_bytes(HAND_GREY)
    write(*, '(A,I0,A,I0,A,I0,A)') 'fuzz_png: corpus bytes: writer=', &
        size(seed_main), ' hand_rgb=', size(seed_rgb), &
        ' hand_grey=', size(seed_grey), ' (all generated in code)'

    ! The unmutated corpus must decode (with and without CRC checks);
    ! if it does not, the harness itself is broken -- say so loudly
    ! instead of fuzzing a decoder against garbage assumptions.
    call check_corpus(seed_main, 'writer')
    call check_corpus(seed_rgb, 'hand_rgb')
    call check_corpus(seed_grey, 'hand_grey')

    ! ---- Mutation fuzz loop -----------------------------------------
    n_decode_ok = 0
    n_decode_reject = 0
    n_crc_iters = 0
    n_roundtrip = 0
    n_roundtrip_zero = 0
    do iter = 1, iterations
        call fuzz_one_decode(iter)
        call fuzz_one_roundtrip(iter)
        if (mod(iter, 500) == 0) then
            write(*, '(A,I0,A,I0,A,I0,A,I0)') &
                'fuzz_png: progress iter=', iter, &
                ' decode_ok=', n_decode_ok, &
                ' decode_reject=', n_decode_reject, &
                ' roundtrips=', n_roundtrip
        end if
    end do

    call delete_tmp(SEED_TMP)
    call delete_tmp(RT_TMP)
    write(*, '(A,I0,A,I0,A,I0,A,I0,A,I0,A,I0,A)') &
        'fuzz_png: SUMMARY iterations=', iterations, &
        ' decode_ok=', n_decode_ok, &
        ' decode_reject=', n_decode_reject, &
        ' crc_check_iters=', n_crc_iters, &
        ' roundtrips=', n_roundtrip, &
        ' zero_size_rejected=', n_roundtrip_zero, &
        ' findings=0'

contains

    ! =================================================================
    ! Command line: [iterations] [seed] (run_fuzz.sh's order).
    ! =================================================================
    subroutine read_args(iters_out, seed_out)
        integer, intent(out) :: iters_out, seed_out
        character(len=64) :: arg
        integer :: ios, v
        if (command_argument_count() >= 1) then
            call get_command_argument(1, arg)
            read(arg, *, iostat=ios) v
            if (ios == 0) then
                if (v > 0) iters_out = v
            end if
        end if
        if (command_argument_count() >= 2) then
            call get_command_argument(2, arg)
            read(arg, *, iostat=ios) v
            if (ios == 0) seed_out = v
        end if
    end subroutine read_args

    ! =================================================================
    ! splitmix64 PRNG (Stafford / Vigna): the state advances by the
    ! golden-ratio constant and the output is the standard two-round
    ! xor-shift/multiply mix, all modulo 2**64.
    !
    ! The add and the two multiplies are done in 16-bit limbs
    ! (add64/mul64 below): every intermediate stays a small
    ! non-negative int64, so the harness itself never commits the
    ! signed-overflow that UBSan -- the whole point of this file --
    ! would otherwise flag in the PRNG.  Only the xor/shift mixing
    ! touches the raw int64 bit pattern, and those are bit
    ! operations, not arithmetic.
    ! =================================================================
    function next_u64() result(x)
        integer(int64) :: x
        rng_state = add64(rng_state, -7046029254386353131_int64) ! 0x9E3779B97F4A7C15
        x = rng_state
        x = ieor(x, ishft(x, -30))
        x = mul64(x, -4658895280553007687_int64)                 ! 0xBF58476D1CE4E5B9
        x = ieor(x, ishft(x, -27))
        x = mul64(x, -7723592293110705685_int64)                 ! 0x94D049BB133111EB
        x = ieor(x, ishft(x, -31))
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

    ! Uniform draw in 0..n-1 (n >= 1).  The sign bit is masked off so
    ! the mod is taken of a non-negative value.
    function rand_below(n) result(r)
        integer, intent(in) :: n
        integer :: r
        r = 0
        if (n > 1) then
            r = int(mod(iand(next_u64(), huge(1_int64)), int(n, int64)))
        end if
    end function rand_below

    ! One random byte value, 0..255.
    function rand_byte() result(b)
        integer :: b
        b = int(iand(next_u64(), 255_int64))
    end function rand_byte

    ! Unsigned byte value (0..255) held in an int8 element.
    pure function ub(b) result(v)
        integer(int8), intent(in) :: b
        integer :: v
        v = int(b)
        if (v < 0) v = v + 256
    end function ub

    ! Convert a 0..255 integer byte list to int8 storage.
    pure function to_bytes(vals) result(out)
        integer, intent(in) :: vals(:)
        integer(int8), allocatable :: out(:)
        integer :: i, v
        allocate(out(size(vals)))
        do i = 1, size(vals)
            v = mod(vals(i), 256)
            if (v > 127) v = v - 256
            out(i) = int(v, int8)
        end do
    end function to_bytes

    ! =================================================================
    ! Seed corpus construction.
    ! =================================================================

    ! A valid PNG from the engine writer itself: 8x8 RGB gradient to
    ! a temp file, bytes read straight back.
    subroutine build_writer_seed(bytes)
        integer(int8), allocatable, intent(out) :: bytes(:)
        integer :: pix(3, 8, 8), x, y, k
        logical :: ok
        do y = 1, 8
            do x = 1, 8
                do k = 1, 3
                    pix(k, x, y) = mod((x - 1) * 36 + (y - 1) * 11 &
                                       + (k - 1) * 67, 256)
                end do
            end do
        end do
        call png_save_file(SEED_TMP, 8, 8, pix)
        call read_all(SEED_TMP, bytes, ok)
        if (.not. ok) then
            write(*, '(A)') 'fuzz_png: FATAL: writer seed unreadable'
            stop 2
        end if
        if (size(bytes) < 64) then
            write(*, '(A)') 'fuzz_png: FATAL: writer seed too small'
            stop 2
        end if
    end subroutine build_writer_seed

    ! Read a whole file into a byte array; ok=.false. on any failure.
    subroutine read_all(path, bytes, ok)
        character(len=*), intent(in) :: path
        integer(int8), allocatable, intent(out) :: bytes(:)
        logical, intent(out) :: ok
        integer :: u, ios, fsize, i
        ok = .false.
        open(newunit=u, file=path, status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) return
        inquire(unit=u, size=fsize)
        if (fsize <= 0) then
            close(u)
            return
        end if
        allocate(bytes(fsize))
        read(u, iostat=ios) (bytes(i), i = 1, fsize)
        close(u)
        if (ios /= 0) then
            deallocate(bytes)
            return
        end if
        ok = .true.
    end subroutine read_all

    subroutine delete_tmp(path)
        character(len=*), intent(in) :: path
        integer :: u, ios
        open(newunit=u, file=path, status='old', iostat=ios)
        if (ios == 0) close(u, status='delete')
    end subroutine delete_tmp

    ! Sanity gate: the pristine corpus must decode both ways.
    subroutine check_corpus(bytes, name)
        integer(int8), intent(in) :: bytes(:)
        character(len=*), intent(in) :: name
        type(TextureImage) :: tex
        logical :: ok
        call png_decode(bytes, tex, ok)
        if (.not. ok) then
            write(*, '(A,A)') 'fuzz_png: FATAL: corpus rejected: ', name
            stop 2
        end if
        call texture_free(tex)
        call png_decode(bytes, tex, ok, crc_check=.true.)
        if (.not. ok) then
            write(*, '(A,A)') &
                'fuzz_png: FATAL: corpus rejected (crc): ', name
            stop 2
        end if
        call texture_free(tex)
    end subroutine check_corpus

    ! =================================================================
    ! Decoder mutation fuzzing.
    ! =================================================================

    ! Pick a mutation target position, biased to the fields the
    ! decoder trusts: the first 33 bytes hold the signature and the
    ! whole IHDR chunk (length, type, data, CRC); the tail holds the
    ! last chunk's CRC and IEND; the middle is mostly IDAT payload.
    function biased_pos(n) result(pos)
        integer, intent(in) :: n
        integer :: pos, r, head_n, tail_lo
        pos = 1
        if (n <= 1) return
        r = rand_below(100)
        head_n = min(n, 33)
        tail_lo = max(1, n - 16)
        if (r < 40) then
            pos = 1 + rand_below(head_n)
        else if (r < 60) then
            pos = tail_lo + rand_below(n - tail_lo + 1)
        else if (r < 80) then
            ! Chunk-boundary neighbourhoods past the header: length
            ! and type fields of the second chunk in the writer and
            ! hand layouts (offsets 34..41), when they exist.
            if (n > 41) then
                pos = 34 + rand_below(8)
            else
                pos = 1 + rand_below(n)
            end if
        else
            pos = 1 + rand_below(n)
        end if
        if (pos < 1) pos = 1
        if (pos > n) pos = n
    end function biased_pos

    ! Apply one in-place mutation to work(1:n): bit flip, byte set
    ! (with 0 / 255 / chunk-ASCII favourites), increment, decrement.
    subroutine mutate_byte(work, n)
        integer(int8), intent(inout) :: work(:)
        integer, intent(in) :: n
        integer :: pos, strat, v
        if (n < 1) return
        pos = biased_pos(n)
        strat = rand_below(100)
        v = ub(work(pos))
        if (strat < 30) then
            v = ieor(v, ishft(1, rand_below(8)))          ! bit flip
        else if (strat < 50) then
            v = rand_byte()                                ! random set
        else if (strat < 62) then
            v = 0                                          ! NUL
        else if (strat < 74) then
            v = 255                                        ! all ones
        else if (strat < 82) then
            ! A printable ASCII byte: forges chunk-type fields.
            v = 65 + rand_below(58)
        else if (strat < 91) then
            v = mod(v + 1, 256)
        else
            v = mod(v + 255, 256)
        end if
        if (v > 127) v = v - 256
        work(pos) = int(v, int8)
    end subroutine mutate_byte

    subroutine fuzz_one_decode(iter_no)
        integer, intent(in) :: iter_no
        integer(int8), allocatable :: work(:), grown(:)
        type(TextureImage) :: tex
        logical :: ok
        integer :: src, n, eff, nmut, i, extra

        ! Choose the corpus entry for this iteration.
        src = rand_below(3)
        if (src == 0) then
            allocate(work(size(seed_main)))
            work = seed_main
        else if (src == 1) then
            allocate(work(size(seed_rgb)))
            work = seed_rgb
        else
            allocate(work(size(seed_grey)))
            work = seed_grey
        end if
        n = size(work)
        eff = n

        ! 1..8 point mutations.
        nmut = 1 + rand_below(8)
        do i = 1, nmut
            call mutate_byte(work, n)
        end do

        ! Occasional truncation (the decoder must notice the stream
        ! ends early) or junk extension (trailing bytes after IEND,
        ! or a forged extra chunk's worth of noise).
        if (rand_below(100) < 12) then
            if (n > 1) eff = 1 + rand_below(n - 1)
        else if (rand_below(100) < 10) then
            extra = 1 + rand_below(24)
            allocate(grown(n + extra))
            grown(1:n) = work
            do i = 1, extra
                block
                    integer :: bv
                    bv = rand_byte()
                    if (bv > 127) bv = bv - 256
                    grown(n + i) = int(bv, int8)
                end block
            end do
            call move_alloc(grown, work)
            n = size(work)
            eff = n
        end if

        ! png_decode with crc_check ABSENT on even iterations and
        ! crc_check=.true. on odd ones: both documented modes fuzzed.
        if (mod(iter_no, 2) == 0) then
            call png_decode(work(1:eff), tex, ok)
        else
            n_crc_iters = n_crc_iters + 1
            call png_decode(work(1:eff), tex, ok, crc_check=.true.)
        end if

        if (ok) then
            n_decode_ok = n_decode_ok + 1
            ! A "successful" decode must still describe a sane image:
            ! positive bounded dimensions and allocated pixels.  Each
            ! test is a separate nested if -- never an .and. chain
            ! guarding an array access.
            if (tex%w < 1) call finding(iter_no, &
                'decode ok with non-positive width')
            if (tex%h < 1) call finding(iter_no, &
                'decode ok with non-positive height')
            if (tex%w > 16384) call finding(iter_no, &
                'decode ok with width over decoder limit')
            if (tex%h > 16384) call finding(iter_no, &
                'decode ok with height over decoder limit')
            if (.not. tex%loaded) call finding(iter_no, &
                'decode ok but texture not marked loaded')
            if (tex%loaded) then
                if (.not. allocated(tex%pixels)) call finding(iter_no, &
                    'decode ok but pixels not allocated')
            end if
            if (allocated(tex%pixels)) then
                if (size(tex%pixels, 2) /= tex%w) call finding(iter_no, &
                    'pixel array width disagrees with texture width')
                if (size(tex%pixels, 3) /= tex%h) call finding(iter_no, &
                    'pixel array height disagrees with texture height')
            end if
        else
            n_decode_reject = n_decode_reject + 1
        end if
        call texture_free(tex)
        deallocate(work)
    end subroutine fuzz_one_decode

    ! =================================================================
    ! Writer round-trip fuzzing.
    ! =================================================================

    ! A dimension in 0..17.  The raw draw spans -17..17 on purpose:
    ! the abs/mod guard folds the negatives back into range, which is
    ! exactly the negative-guard case, and 0 stays reachable.
    function fuzz_dim() result(d)
        integer :: d
        d = abs(rand_below(35) - 17)
        d = mod(d, 18)
    end function fuzz_dim

    ! Write a PNG whose width or height is zero, passing a genuinely
    ! zero-extent pixel array (the dummy in png_save_file is
    ! pixels(3, width, height), so the extents must agree exactly
    ! with the width/height arguments).
    subroutine save_zero_extent(w, h)
        integer, intent(in) :: w, h
        integer, allocatable :: zpix(:, :, :)
        allocate(zpix(3, w, h))
        call png_save_file(RT_TMP, w, h, zpix)
        deallocate(zpix)
    end subroutine save_zero_extent

    subroutine fuzz_one_roundtrip(iter_no)
        integer, intent(in) :: iter_no
        integer :: w, h, x, y, k, expect
        integer, allocatable :: pix(:, :, :)
        integer(int8), allocatable :: bytes(:)
        type(TextureImage) :: tex
        logical :: ok, rok

        w = fuzz_dim()
        h = fuzz_dim()
        allocate(pix(3, max(w, 1), max(h, 1)))
        pix = 0
        if (w > 0) then
            if (h > 0) then
                do y = 1, h
                    do x = 1, w
                        do k = 1, 3
                            ! -32..287: out-of-range values included
                            ! so the writer's clamp is part of the
                            ! round-trip contract checked below.
                            pix(k, x, y) = rand_below(320) - 32
                        end do
                    end do
                end do
            end if
        end if

        if (w > 0) then
            if (h > 0) then
                call png_save_file(RT_TMP, w, h, pix)
            else
                call save_zero_extent(w, h)
            end if
        else
            call save_zero_extent(w, h)
        end if

        call read_all(RT_TMP, bytes, rok)
        if (.not. rok) then
            call finding(iter_no, 'writer produced no readable file')
        end if
        call png_decode(bytes, tex, ok, crc_check=.true.)
        deallocate(bytes)

        if (w > 0) then
            if (h > 0) then
                n_roundtrip = n_roundtrip + 1
                if (.not. ok) then
                    call texture_free(tex)
                    call finding(iter_no, &
                        'round-trip decode rejected a writer PNG')
                end if
                if (tex%w /= w) call finding(iter_no, &
                    'round-trip width mismatch')
                if (tex%h /= h) call finding(iter_no, &
                    'round-trip height mismatch')
                if (allocated(tex%pixels)) then
                    do y = 1, h
                        do x = 1, w
                            do k = 1, 3
                                expect = min(255, max(0, pix(k, x, y)))
                                if (tex%pixels(k, x, y) /= expect) then
                                    write(*, '(A,3(I0,A),I0,A,I0)') &
                                        'fuzz_png: pixel at (', k, ',', &
                                        x, ',', y, ') got=', &
                                        tex%pixels(k, x, y), &
                                        ' expected=', expect
                                    call texture_free(tex)
                                    call finding(iter_no, &
                                        'round-trip pixel mismatch')
                                end if
                            end do
                        end do
                    end do
                else
                    call texture_free(tex)
                    call finding(iter_no, &
                        'round-trip decode left pixels unallocated')
                end if
            else
                ! Zero height: the PNG on disk carries height 0, which
                ! is not a legal PNG; the decoder must reject it.
                if (ok) then
                    call texture_free(tex)
                    call finding(iter_no, &
                        'decoder accepted a zero-height writer PNG')
                end if
                n_roundtrip_zero = n_roundtrip_zero + 1
            end if
        else
            if (ok) then
                call texture_free(tex)
                call finding(iter_no, &
                    'decoder accepted a zero-width writer PNG')
            end if
            n_roundtrip_zero = n_roundtrip_zero + 1
        end if
        call texture_free(tex)
        deallocate(pix)
    end subroutine fuzz_one_roundtrip

    ! A true correctness finding: report it with the exact repro
    ! (iteration + the program's seed identifies every generated
    ! byte) and stop non-zero -- a fuzz harness must never exit 0
    ! after observing one.
    subroutine finding(iter_no, what)
        integer, intent(in) :: iter_no
        character(len=*), intent(in) :: what
        write(*, '(A,I0,A,A,A,I0,A)') 'fuzz_png: FINDING at iteration ', &
            iter_no, ': ', what, ' (reproduce: ./fuzz_png ', &
            iterations, ' <seed above>)'
        stop 1
    end subroutine finding

end program fuzz_png
