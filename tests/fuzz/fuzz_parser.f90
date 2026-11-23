! fuzz_parser.f90 -- mutation fuzz harness for the Forge3D compiler
! parser + desugar pipeline (v3.0 Phase 9, hardening).
!
! Purpose
! -------
! Feed byte-level mutations of a small set of realistic, embedded
! .f3d seed sources through the REAL front end of the native
! compiler:
!
!     f3dc_parse  (f3dc_parser)   text -> Program dyn dict + bag
!     desugar     (f3dc_desugar)  Program -> flattened Program
!
! and require that neither stage ever crashes, hangs on a bounded
! input, or corrupts memory -- no matter how malformed the mutated
! text is.  Parse ERRORS are expected and are not failures: almost
! every mutant is invalid .f3d, and a correct outcome is a filled
! error bag, not a clean parse.  A failure of this harness is a
! crash (segfault, sanitizer report, Fortran runtime abort), which
! is exactly what a fuzz run is meant to surface.
!
! The run is fully deterministic for a given seed: the PRNG below
! is the only source of randomness, seed selection and every
! mutation draw come from its stream, and the pipeline stages are
! deterministic.  Re-running with the same arguments replays the
! exact same mutants in the exact same order, so a crashing
! iteration can be reproduced (and bisected with the iteration
! count) from the seed alone.  Progress lines print every 250
! iterations, so the last progress line before a crash brackets
! the offending iteration range.
!
! Deliberate scope limits
! -----------------------
! * No `import` statement appears in any seed, and no seed is a
!   valid import line: desugar EXPANDS imports by reading part
!   files from disk (resolved against base_dir, here "."), which
!   is file IO this harness does not want -- a mutant that turned
!   a line into a working import could make a "parser" fuzz run
!   depend on whatever .f3d files happen to sit in the working
!   directory.  `load` IS seeded: desugar treats a load as a plain
!   node and performs no IO for it.  Import expansion has its own
!   curated tests; it is out of scope here on purpose.
! * Mutants are bounded: the working buffer is capped (MAX_SOURCE
!   below), each iteration applies at most 8 mutations to a fresh
!   copy of one seed, and the iteration count is an argument with
!   a hard ceiling.  A single iteration therefore cannot turn a
!   ~700-byte seed into an unbounded input, and desugar's own
!   10,000-placement cap bounds repeat/grid/ring expansion.
!
! Build (sanitizers are the point -- run me under ASan + UBSan)
! --------------------------------------------------------------
! From the repo root (flang-18 or gfortran; NOT built by the
! normal test suite, this is a standalone hardening tool):
!
!   clang-18 -c compiler/preview_http.c -o preview_http.o
!   flang-new-18 -g -O1 -fsanitize=address,undefined \
!     compiler/src/f3dc_str.f90    \
!     compiler/src/f3dc_dyn.f90    \
!     compiler/src/f3dc_errors.f90 \
!     compiler/src/f3dc_lexer.f90  \
!     compiler/src/f3dc_ast.f90    \
!     compiler/src/f3dc_parser.f90 \
!     compiler/src/f3dc_desugar.f90 \
!     tests/fuzz/fuzz_parser.f90 preview_http.o \
!     -o fuzz_parser
!   ./fuzz_parser            ! 5000 iterations, default seed
!   ./fuzz_parser 200000 42  ! iterations, seed
!
! No signed-integer-overflow carve-out is needed for the
! splitmix64 PRNG below: splitmix64 is defined over unsigned
! 64-bit wrap-around arithmetic, and Fortran has no unsigned
! integer type, so its add and multiplications are done in
! 16-bit limbs (add64/mul64 helpers, bit-exact modulo 2^64)
! over int64 bit patterns instead of trapping.  Everything in
! the run stays under full ASan + UBSan.
!
! Exact module link set (traced from the `use` statements)
! ---------------------------------------------------------
!   this program : f3dc_parser (f3dc_parse), f3dc_desugar
!                  (desugar), f3dc_dyn (dyn, dyn_free,
!                  DYN_K_DICT), f3dc_errors (error_bag_t,
!                  error_bag_len)
!   f3dc_parser  : f3dc_dyn, f3dc_errors, f3dc_str, f3dc_lexer,
!                  f3dc_ast
!   f3dc_desugar : f3dc_dyn, f3dc_str, f3dc_errors, f3dc_parser,
!                  f3dc_ast
!   f3dc_ast     : f3dc_dyn, f3dc_str
!   f3dc_lexer   : f3dc_errors
!   f3dc_errors  : f3dc_str, plus the C helper f3dc_isatty_stderr
!                  from compiler/preview_http.c (linked into every
!                  f3dc binary for the same reason)
!   f3dc_dyn     : (standalone)
!   f3dc_str     : (standalone)
! So the object set is: f3dc_str, f3dc_dyn, f3dc_errors,
! f3dc_lexer, f3dc_ast, f3dc_parser, f3dc_desugar, preview_http.o.
!
! Fortran traps honoured throughout (compiler house rules)
! ---------------------------------------------------------
! * .and. / .or. do NOT short-circuit: no guard is ever written as
!   `allocated(x) .and. <something touching x>`, and no index is
!   validated by the left half of a compound condition.  Every
!   check that protects a later statement is a separate, sequential
!   if, exactly as the compiler sources themselves do it.
! * No dyn value is ever copied with intrinsic dyn-to-dyn
!   assignment (the dyn_assign rule): this harness keeps no dyn
!   across iterations at all.  The two dyns each iteration
!   produces arrive fresh through intent(out) dummies and are
!   released with dyn_free before the next iteration, so a long
!   run does not grow without bound and ASan's leak checker
!   stays meaningful.
program fuzz_parser
  use, intrinsic :: iso_fortran_env, only: int64, output_unit
  use f3dc_dyn, only: dyn, dyn_free, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, error_bag_len
  use f3dc_parser, only: f3dc_parse
  use f3dc_desugar, only: desugar
  implicit none

  ! Working-buffer cap.  The largest seed is ~700 bytes and one
  ! iteration applies at most MAX_MUTATIONS mutations, of which
  ! only line duplication grows the text by more than one byte
  ! (at most one seed line each), so 4096 is generous headroom;
  ! mutations that would pass the cap are skipped, never wrapped.
  integer, parameter :: MAX_SOURCE = 4096
  integer, parameter :: MAX_LINES = 512
  integer, parameter :: MAX_MUTATIONS = 8
  integer, parameter :: N_SEEDS = 6
  integer, parameter :: DEFAULT_ITERATIONS = 5000
  integer(int64), parameter :: DEFAULT_SEED = 20261123_int64
  integer(int64), parameter :: MAX_ITERATIONS = 100000000_int64

  ! Byte alphabet for replace/insert: mostly .f3d-shaped characters
  ! (word letters, digits, and the language's punctuation), so a
  ! good share of mutants stay near-valid and reach deep parser
  ! paths instead of dying in the lexer.  pick_byte() additionally
  ! deals out raw control / high bytes a small share of the time.
  character(len=*), parameter :: ALPHABET = &
    'abcdefghijklmnoprstuwxyzABCDEFGH' // &
    '0123456789 "#:,().-_+*/=<>'

  ! One embedded seed source (boxed so the seeds can have
  ! different lengths in one array).
  type :: seed_box
    character(len=:), allocatable :: text
  end type seed_box

  type(seed_box) :: seeds(N_SEEDS)

  ! PRNG state (splitmix64; see prng_next).
  integer(int64) :: rng_state = 0_int64

  ! Mutation working buffers (host-associated into the internal
  ! procedures below, which is why they live here and not in them).
  character(len=MAX_SOURCE) :: buf
  character(len=MAX_SOURCE) :: scratch
  integer :: blen = 0        ! valid bytes in buf are buf(1:blen)
  integer :: spos = 0        ! append cursor for scratch assembly

  ! Run configuration and counters.
  integer(int64) :: seed_arg, iter_arg, iter
  integer :: n_dict, n_desugar, n_clean
  integer(int64) :: total_diags

  ! Per-iteration pipeline values.
  type(error_bag_t) :: bag
  type(dyn) :: program, flat_program
  integer :: si, nmut, m

  ! ----------------------------------------------------------------
  ! Setup: arguments, PRNG, seeds.
  ! ----------------------------------------------------------------
  call read_args(iter_arg, seed_arg)
  rng_state = seed_arg
  call init_seeds()

  write (output_unit, '(A,I0,A,I0)') &
    'fuzz_parser: seed=', seed_arg, ' iterations=', iter_arg
  flush (output_unit)

  n_dict = 0
  n_desugar = 0
  n_clean = 0
  total_diags = 0_int64

  ! ----------------------------------------------------------------
  ! Main fuzz loop.  Each iteration starts from a PRISTINE copy of
  ! one seed (mutations never accumulate across iterations), applies
  ! 1..MAX_MUTATIONS mutations, then runs parse (+ desugar when the
  ! parse produced a program dict).
  ! ----------------------------------------------------------------
  do iter = 1_int64, iter_arg
    si = rand_below(N_SEEDS) + 1
    blen = len(seeds(si)%text)
    buf(1:blen) = seeds(si)%text

    nmut = rand_below(MAX_MUTATIONS) + 1
    do m = 1, nmut
      call apply_one_mutation()
    end do

    call reset_bag(bag)
    if (blen > 0) then
      call f3dc_parse(buf(1:blen), 'fuzz.f3d', bag, program)
    else
      call f3dc_parse('', 'fuzz.f3d', bag, program)
    end if

    ! Desugar gate, written sequentially on purpose: kind is
    ! checked first, and only a real program DICT goes on to the
    ! desugar stage -- the same shape the CLI pipeline feeds it.
    if (program%kind == DYN_K_DICT) then
      n_dict = n_dict + 1
      call desugar(program, bag, '.', flat_program)
      n_desugar = n_desugar + 1
      if (flat_program%kind == DYN_K_DICT) then
        if (error_bag_len(bag) == 0) n_clean = n_clean + 1
      end if
      call dyn_free(flat_program)
    end if
    total_diags = total_diags + int(error_bag_len(bag), int64)
    call dyn_free(program)

    if (mod(iter, 250_int64) == 0_int64) then
      write (output_unit, '(A,I0,A,I0)') &
        'fuzz_parser: ', iter, '/', iter_arg
      flush (output_unit)
    end if
  end do

  write (output_unit, '(A,I0,A)') &
    'fuzz_parser: ', iter_arg, ' iterations, no crash'
  write (output_unit, '(A,I0,A,I0,A,I0,A,I0)') &
    'fuzz_parser: program dicts=', int(n_dict, int64), &
    ', desugared=', int(n_desugar, int64), &
    ', diagnostics collected=', total_diags, &
    ', fully clean runs=', int(n_clean, int64)
  flush (output_unit)

contains

  ! ================================================================
  ! Arguments: fuzz_parser [iterations] [seed]
  ! Both optional; an unparsable or out-of-range value falls back
  ! to the default rather than aborting (a fuzz driver should never
  ! die on its own command line).
  ! ================================================================
  subroutine read_args(iters, sd)
    integer(int64), intent(out) :: iters, sd
    character(len=64) :: arg
    integer :: ios, st
    integer(int64) :: v
    iters = int(DEFAULT_ITERATIONS, int64)
    sd = DEFAULT_SEED
    if (command_argument_count() >= 1) then
      call get_command_argument(1, arg, status=st)
      if (st == 0) then
        read (arg, *, iostat=ios) v
        if (ios == 0) then
          if (v >= 1_int64) then
            if (v <= MAX_ITERATIONS) then
              iters = v
            else
              iters = MAX_ITERATIONS
            end if
          end if
        end if
      end if
    end if
    if (command_argument_count() >= 2) then
      call get_command_argument(2, arg, status=st)
      if (st == 0) then
        read (arg, *, iostat=ios) v
        if (ios == 0) sd = v
      end if
    end if
  end subroutine read_args

  ! ================================================================
  ! splitmix64 PRNG (Stafford / Vigna): state advances by the
  ! golden-gamma constant, the result is the state passed through
  ! three xor-shift / multiply mixing rounds.  All arithmetic is
  ! over the int64 BIT PATTERN modulo 2^64, done in 16-bit limbs
  ! (add64/mul64 below, bit-exact; see the build note in the
  ! header).  The BOZ -> int64 conversions below are the standard
  ! way to spell those bit patterns.
  ! ================================================================
  function prng_next() result(z)
    integer(int64) :: z
    rng_state = add64(rng_state, int(z'9E3779B97F4A7C15', int64))
    z = rng_state
    z = ieor(z, ishft(z, -30))
    z = mul64(z, int(z'BF58476D1CE4E5B9', int64))
    z = ieor(z, ishft(z, -27))
    z = mul64(z, int(z'94D049BB133111EB', int64))
    z = ieor(z, ishft(z, -31))
  end function prng_next

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

  ! Uniform draw in 0 .. n-1 (n >= 1).  The sign bit is shifted
  ! out first (ishft is a bit shift: vacated bits are zero), so
  ! the value reduced mod n is never negative.
  function rand_below(n) result(r)
    integer, intent(in) :: n
    integer :: r
    integer(int64) :: v
    v = prng_next()
    v = ishft(v, -1)
    r = int(mod(v, int(n, int64)))
  end function rand_below

  ! ================================================================
  ! Embedded seed sources.  Every line is modelled on the shipped
  ! examples (examples/multi-object.f3d, animated.f3d,
  ! waveb-showcase.f3d, hello-cube.f3d) so the unmutated seeds are
  ! realistic .f3d.  NL is achar(10), the line ending the lexer
  ! splits on.
  ! ================================================================
  subroutine init_seeds()
    character :: NL
    NL = achar(10)

    ! Seed 1: scene / camera / light line set + one object.
    seeds(1)%text = &
      'scene fuzz size 800 600 bg black' // NL // &
      'camera at 0 5 12 look 0 0 0 fov 60' // NL // &
      'light directional dir -0.5 -1 -0.7 strength 1.6' // NL // &
      'light ambient strength 0.45' // NL // &
      'cube hero red at 0 0 0 size 2' // NL // &
      'render' // NL

    ! Seed 2: objects with props (transform, material, geometry).
    seeds(2)%text = &
      'scene props size 640 480 background #191923' // NL // &
      'camera at 4 3 6 look 0 0 0' // NL // &
      'light point white at 4 2 8 intensity 60 distance 0 ' // &
        'decay 2' // NL // &
      'cube box red at -2 0 0 size 2 rotate 20 35 0 ' // &
        'material standard metalness 0.2 roughness 0.8' // NL // &
      'sphere orb blue at 0 1 0 radius 1 segments 24' // NL // &
      'cylinder tower green at 4 0 0 radius 1 height 3' // NL // &
      'torus ringlet pink at 0 -2 0 radius 1 tube 0.3' // NL // &
      'cone spike orange at 2 2 0 radius 0.8 height 2 ' // &
        'detail high' // NL // &
      'render "props.ppm"' // NL

    ! Seed 3: a group ... end block and a repeat statement.
    seeds(3)%text = &
      'scene grouped size 800 600 bg black' // NL // &
      'camera at 0 5 12 look 0 0 0 fov 60' // NL // &
      'group duo' // NL // &
      '  cone hat orange at -2 0 3 radius 1 height 2' // NL // &
      '  pyramid peak purple at 2 0 3 size 2 height 2' // NL // &
      'end' // NL // &
      'repeat 3 torus ringlet pink at -3 -2 -2 radius 1' // NL // &
      'cube solo teal at 0 0 0 size 1' // NL // &
      'render' // NL

    ! Seed 4: keys keyframe block + spin / animate animation.
    seeds(4)%text = &
      'scene anim size 320 240 background black' // NL // &
      'camera at 4 3 6 look 0 0 0' // NL // &
      'cube spinner red at -2 0 0' // NL // &
      'cube mover blue at 0 -1 0' // NL // &
      'animate spinner spin y speed 180 duration 2 fps 15' // NL // &
      'spin it' // NL // &
      'keys mover duration 2 loop pingpong' // NL // &
      'key mover at 0 pos 0 -1.2 0 rot 0 0 0 scale 1' // NL // &
      'key mover at 1 pos 1.5 -0.2 0 rot 0 90 0 scale 1.2 ' // &
        'ease smooth' // NL // &
      'key mover at 2 pos 0 -1.2 0 rot 0 180 0 scale 1' // NL // &
      'render duration 2 fps 15' // NL

    ! Seed 5: load lines (model files are referenced, never read
    ! by parse or desugar -- see the scope note in the header).
    seeds(5)%text = &
      'scene loader size 640 480 bg black' // NL // &
      'camera at 0 5 12 look 0 0 0' // NL // &
      'light directional dir -0.5 -1 -0.7 strength 1.2' // NL // &
      'load "../model.obj" imported at 0 0 -5' // NL // &
      'load "assets/pyramid.gltf" pyramid at 3.2 -1 0' // NL // &
      'cube anchor teal at 0 0 0 size 1' // NL // &
      'controls orbit' // NL // &
      'render "loader.ppm"' // NL

    ! Seed 6: minimal source -- comment, one bare object, spin,
    ! render.  Small seeds make truncation and line mutations hit
    ! proportionally harder.
    seeds(6)%text = &
      '# just a comment and one object' // NL // &
      'cube red' // NL // &
      'spin it' // NL // &
      'render' // NL
  end subroutine init_seeds

  ! ================================================================
  ! Error-bag reset: a fresh bag per iteration without relying on
  ! block-scope finalisation.  Deallocating the diags array also
  ! releases every diagnostic's allocatable string components.
  ! ================================================================
  subroutine reset_bag(b)
    type(error_bag_t), intent(inout) :: b
    if (allocated(b%diags)) deallocate (b%diags)
    b%n = 0
    b%cap = 0
    if (allocated(b%source_text)) deallocate (b%source_text)
    b%has_source = .false.
  end subroutine reset_bag

  ! ================================================================
  ! Mutations.  All of them operate on buf(1:blen) in place, keep
  ! blen within 0..MAX_SOURCE, and are no-ops (not errors) when
  ! their precondition does not hold (empty buffer, < 2 lines,
  ! no room to grow).  Reproduction is unaffected by the no-op
  ! cases: the buffer contents that decide them are themselves a
  ! deterministic function of the PRNG stream.
  ! ================================================================
  subroutine apply_one_mutation()
    integer :: kind
    kind = rand_below(6) + 1
    select case (kind)
    case (1)
      call mut_replace_byte()
    case (2)
      call mut_insert_byte()
    case (3)
      call mut_delete_byte()
    case (4)
      call mut_truncate()
    case (5)
      call mut_duplicate_line()
    case (6)
      call mut_swap_lines()
    end select
  end subroutine apply_one_mutation

  ! Replace one byte with a drawn byte.  On an empty buffer this
  ! degrades to an insert, so early iterations of a heavily
  ! truncated mutant still do something.
  subroutine mut_replace_byte()
    integer :: pos
    if (blen == 0) then
      call mut_insert_byte()
      return
    end if
    pos = rand_below(blen) + 1
    buf(pos:pos) = pick_byte()
  end subroutine mut_replace_byte

  ! Insert one drawn byte at a drawn position (1..blen+1).
  subroutine mut_insert_byte()
    integer :: pos, i
    if (blen >= MAX_SOURCE) return
    pos = rand_below(blen + 1) + 1
    ! Shift the tail one byte right, last byte first.  These are
    ! single-byte assignments executed in order, so no overlapping
    ! substring self-assignment is involved.
    do i = blen, pos, -1
      buf(i + 1:i + 1) = buf(i:i)
    end do
    buf(pos:pos) = pick_byte()
    blen = blen + 1
  end subroutine mut_insert_byte

  ! Delete one byte.
  subroutine mut_delete_byte()
    integer :: pos, i
    if (blen == 0) return
    pos = rand_below(blen) + 1
    ! Shift the tail one byte left, first byte first (same
    ! single-byte, in-order reasoning as mut_insert_byte).
    do i = pos, blen - 1
      buf(i:i) = buf(i + 1:i + 1)
    end do
    blen = blen - 1
  end subroutine mut_delete_byte

  ! Truncate to a drawn length in 0..blen (0 and blen included:
  ! empty input is a first-class parser case, and a no-op
  ! truncation keeps the draw sequence uniform).
  subroutine mut_truncate()
    if (blen == 0) return
    blen = rand_below(blen + 1)
  end subroutine mut_truncate

  ! Line spans of buf(1:blen): line k occupies
  ! [starts(k), ends(k)], where ends(k) is the position of the
  ! line's newline, or blen for a final unterminated line.  A
  ! trailing newline does NOT create an extra empty line.
  subroutine line_spans(starts, ends, nl)
    integer, intent(out) :: starts(MAX_LINES), ends(MAX_LINES)
    integer, intent(out) :: nl
    integer :: i, st
    nl = 0
    st = 1
    do i = 1, blen
      if (buf(i:i) == achar(10)) then
        if (nl < MAX_LINES) then
          nl = nl + 1
          starts(nl) = st
          ends(nl) = i
        end if
        st = i + 1
      end if
    end do
    if (st <= blen) then
      if (nl < MAX_LINES) then
        nl = nl + 1
        starts(nl) = st
        ends(nl) = blen
      end if
    end if
  end subroutine line_spans

  ! Append buf(lo:hi) to scratch at the spos cursor (no-op for an
  ! empty range).  Used to rebuild the buffer for line swaps.
  subroutine scratch_append(lo, hi)
    integer, intent(in) :: lo, hi
    integer :: k
    if (hi < lo) return
    do k = lo, hi
      spos = spos + 1
      scratch(spos:spos) = buf(k:k)
    end do
  end subroutine scratch_append

  ! Duplicate one drawn line immediately after itself.  A line
  ! that ends in a newline duplicates verbatim; a final
  ! unterminated line gains a newline separator first.
  subroutine mut_duplicate_line()
    integer :: starts(MAX_LINES), ends(MAX_LINES)
    integer :: nl, li, as, ae, need, i, out
    logical :: terminated
    call line_spans(starts, ends, nl)
    if (nl == 0) return
    li = rand_below(nl) + 1
    as = starts(li)
    ae = ends(li)
    terminated = .false.
    if (ae >= as) then
      if (buf(ae:ae) == achar(10)) terminated = .true.
    end if
    need = ae - as + 1
    if (.not. terminated) need = need + 1
    if (blen + need > MAX_SOURCE) return
    ! Assemble: prefix through the end of the line, the duplicate,
    ! then the untouched remainder.
    spos = 0
    call scratch_append(1, ae)
    if (.not. terminated) then
      spos = spos + 1
      scratch(spos:spos) = achar(10)
    end if
    do i = as, ae
      spos = spos + 1
      scratch(spos:spos) = buf(i:i)
    end do
    call scratch_append(ae + 1, blen)
    out = spos
    do i = 1, out
      buf(i:i) = scratch(i:i)
    end do
    blen = out
  end subroutine mut_duplicate_line

  ! Swap two distinct drawn lines.  Total length is unchanged:
  ! the rebuilt text is prefix / line B / middle / line A /
  ! suffix, assembled in scratch and copied back.
  subroutine mut_swap_lines()
    integer :: starts(MAX_LINES), ends(MAX_LINES)
    integer :: nl, a, b, tmp, as, ae, bs, be, i, out
    call line_spans(starts, ends, nl)
    if (nl < 2) return
    a = rand_below(nl) + 1
    b = rand_below(nl) + 1
    if (a == b) return
    if (a > b) then
      tmp = a
      a = b
      b = tmp
    end if
    as = starts(a)
    ae = ends(a)
    bs = starts(b)
    be = ends(b)
    spos = 0
    call scratch_append(1, as - 1)
    call scratch_append(bs, be)
    call scratch_append(ae + 1, bs - 1)
    call scratch_append(as, ae)
    call scratch_append(be + 1, blen)
    out = spos
    do i = 1, out
      buf(i:i) = scratch(i:i)
    end do
    blen = out
  end subroutine mut_swap_lines

  ! One mutation byte: mostly ALPHABET, sometimes a newline, tab,
  ! carriage return, NUL, DEL, or a high (128..191) byte -- the
  ! bytes most likely to upset a lexer that assumes clean text.
  ! The alphabet index is drawn ONCE, into a variable, before
  ! slicing: a substring range must never be two separate draws.
  function pick_byte() result(ch)
    character :: ch
    integer :: roll, idx
    roll = rand_below(100)
    if (roll < 78) then
      idx = rand_below(len(ALPHABET)) + 1
      ch = ALPHABET(idx:idx)
    else if (roll < 84) then
      ch = achar(10)
    else if (roll < 88) then
      ch = achar(9)
    else if (roll < 92) then
      ch = achar(13)
    else if (roll < 96) then
      ch = achar(0)
    else if (roll < 98) then
      ch = achar(127)
    else
      ch = achar(128 + rand_below(64))
    end if
  end function pick_byte

end program fuzz_parser
