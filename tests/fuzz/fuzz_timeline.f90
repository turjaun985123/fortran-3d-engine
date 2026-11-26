! fuzz_timeline.f90 -- mutation fuzz harness for Forge3D film-mode
! timeline blocks (Animation Compiler Wave 6, ANIM-PLAN 5.6).
!
! Purpose
! -------
! Feed structured mutations of realistic FILM-mode .f3d seeds
! (modelled on examples/anim-golden.f3d and the ANIM-PLAN 1.10
! scripts) through the REAL compiler front end:
!
!     f3dc_parse  (f3dc_parser)   text -> Program dyn dict + bag
!     desugar     (f3dc_desugar)  Program -> flattened Program
!                                 (desugar owns timeline resolution,
!                                  ANIM-PLAN D1: the validator never
!                                  sees a `then`)
!
! Mutation operators (drawn per mutation, 1..8 per iteration):
!   1-6. the fuzz_parser byte/line operators (replace / insert /
!        delete byte, truncate, duplicate line, swap lines --
!        statement REORDERING is operator 6, drawn at double
!        weight),
!   7.   time-expression mutation: a drawn numeric token or unit
!        word (seconds/beats/second) in the buffer is replaced by
!        an adversarial value (0, -1, 1e999, 99:99, 2147483648,
!        a different unit word, an unknown unit word, empty),
!   8.   loop-bound corruption: a drawn `repeat ... times` /
!        `together` / `end` line is duplicated or deleted, so loop
!        and block structure is unbalanced on purpose; combined
!        with operator 7 rewriting the repeat count itself, this
!        targets the E820-family expansion budget and any
!        non-termination in timeline resolution.
!
! Invariants asserted on EVERY case (a violation stops the run
! with the iteration, the seed, and the mutant printed):
!   * no crash, no hang: each case is wall-clock bounded
!     (CASE_WALL_SECONDS, system_clock); exceeding it is a FAIL,
!     not a slow pass -- adversarial loop bounds must hit the
!     resource-limit diagnostic, not spin (ANIM-PLAN 5.6);
!   * every failure is a NAMED diagnostic: if the pipeline left
!     no program dict, the bag must be non-empty, and EVERY
!     diagnostic in the bag must carry a code of the form
!     [EW]ddd that exists in the f3dc_errors census table
!     (error_code_title) -- an unnamed or unknown-code failure
!     is a harness FAIL;
!   * double-desugar idempotence (ANIM-PLAN 2.6): desugaring the
!     flattened program a second time (what validate does) must
!     produce a dyn_equal program and add no new error
!     diagnostics.
!
! Determinism, buffers, dyn ownership, and the no-short-circuit
! discipline are exactly fuzz_parser's: splitmix64 PRNG in 16-bit
! limbs, MAX_SOURCE-capped working buffer, no dyn kept across
! iterations, sequential guards only.  No `import` appears in any
! seed (desugar import expansion is file IO; see fuzz_parser).
!
! Build: see tests/fuzz/run_fuzz.sh (ASan + UBSan + -fcheck=all).
! Exact module link set = fuzz_parser's (updated for the plugin
! registry the parser/desugar now use): f3dc_str, f3dc_dyn,
! f3dc_errors, f3dc_lexer, f3dc_ast, f3dc_ir, f3dc_emit_common,
! f3dc_driver, f3dc_plugins, f3dc_parser, f3dc_desugar,
! preview_http.o.
program fuzz_timeline
  use, intrinsic :: iso_fortran_env, only: int64, output_unit
  use f3dc_dyn, only: dyn, dyn_free, dyn_assign, dyn_equal, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, error_bag_len, error_bag_at, &
    diagnostic_t, error_code_title, error_bag_has_errors
  use f3dc_parser, only: f3dc_parse
  use f3dc_desugar, only: desugar
  implicit none

  integer, parameter :: MAX_SOURCE = 8192
  integer, parameter :: MAX_LINES = 512
  integer, parameter :: MAX_MUTATIONS = 8
  integer, parameter :: N_SEEDS = 4
  integer, parameter :: DEFAULT_ITERATIONS = 5000
  integer(int64), parameter :: DEFAULT_SEED = 20261126_int64
  integer(int64), parameter :: MAX_ITERATIONS = 100000000_int64
  ! Per-case wall-clock bound, in seconds (ANIM-PLAN 5.6).
  integer(int64), parameter :: CASE_WALL_SECONDS = 5_int64

  character(len=*), parameter :: ALPHABET = &
    'abcdefghijklmnoprstuwxyzABCDEFGH' // &
    '0123456789 "#:,().-_+*/=<>'

  type :: seed_box
    character(len=:), allocatable :: text
  end type seed_box

  type(seed_box) :: seeds(N_SEEDS)
  integer(int64) :: rng_state = 0_int64

  character(len=MAX_SOURCE) :: buf
  character(len=MAX_SOURCE) :: scratch
  integer :: blen = 0
  integer :: spos = 0

  integer(int64) :: seed_arg, iter_arg, iter
  integer :: n_dict, n_desugar, n_clean, n_reject, n_idem
  integer(int64) :: total_diags

  type(error_bag_t) :: bag, bag2
  type(dyn) :: program, flat_program, flat_copy, flat2
  integer :: si, nmut, m
  integer(int64) :: clock0, clock1, clock_rate
  logical :: named_ok, idem_ok

  call read_args(iter_arg, seed_arg)
  rng_state = seed_arg
  call init_seeds()
  call system_clock(count_rate=clock_rate)

  write (output_unit, '(A,I0,A,I0)') &
    'fuzz_timeline: seed=', seed_arg, ' iterations=', iter_arg
  flush (output_unit)

  n_dict = 0; n_desugar = 0; n_clean = 0; n_reject = 0; n_idem = 0
  total_diags = 0_int64

  do iter = 1_int64, iter_arg
    si = rand_below(N_SEEDS) + 1
    blen = len(seeds(si)%text)
    buf(1:blen) = seeds(si)%text

    nmut = rand_below(MAX_MUTATIONS) + 1
    do m = 1, nmut
      call apply_one_mutation()
    end do

    call system_clock(clock0)
    call reset_bag(bag)
    if (blen > 0) then
      call f3dc_parse(buf(1:blen), 'fuzz.f3d', bag, program)
    else
      call f3dc_parse('', 'fuzz.f3d', bag, program)
    end if

    idem_ok = .true.
    if (program%kind == DYN_K_DICT) then
      n_dict = n_dict + 1
      call desugar(program, bag, '.', flat_program)
      n_desugar = n_desugar + 1
      if (flat_program%kind == DYN_K_DICT) then
        if (.not. error_bag_has_errors(bag)) then
          ! Double-desugar idempotence: a second pass over the
          ! flattened program must change nothing and add no
          ! new errors (validate re-runs desugar, ANIM-PLAN 2.6).
          call dyn_assign(flat_copy, flat_program)
          call reset_bag(bag2)
          call desugar(flat_copy, bag2, '.', flat2)
          if (flat2%kind == DYN_K_DICT) then
            if (.not. dyn_equal(flat_program, flat2)) idem_ok = .false.
          else
            idem_ok = .false.
          end if
          if (error_bag_has_errors(bag2)) idem_ok = .false.
          n_idem = n_idem + 1
          call dyn_free(flat_copy)
          call dyn_free(flat2)
        end if
        if (error_bag_len(bag) == 0) n_clean = n_clean + 1
      end if
      call dyn_free(flat_program)
    end if
    call system_clock(clock1)

    ! Invariant: per-case wall-clock bound (no hang).
    if (clock_rate > 0) then
      if (clock1 - clock0 > CASE_WALL_SECONDS * clock_rate) then
        call fail_case('case exceeded wall-clock bound (hang?)')
      end if
    end if

    ! Invariant: every failure is a named E-code diagnostic.
    call check_bag_named(bag, named_ok)
    if (.not. named_ok) call fail_case('unnamed/unknown-code diagnostic')
    if (program%kind /= DYN_K_DICT) then
      if (error_bag_len(bag) == 0) &
        call fail_case('no program and no diagnostic (silent failure)')
    end if
    if (.not. idem_ok) call fail_case('double-desugar not idempotent')

    if (error_bag_has_errors(bag)) n_reject = n_reject + 1
    total_diags = total_diags + int(error_bag_len(bag), int64)
    call dyn_free(program)

    if (mod(iter, 250_int64) == 0_int64) then
      write (output_unit, '(A,I0,A,I0)') &
        'fuzz_timeline: ', iter, '/', iter_arg
      flush (output_unit)
    end if
  end do

  write (output_unit, '(A,I0,A)') &
    'fuzz_timeline: ', iter_arg, ' iterations, no crash'
  write (output_unit, '(A,I0,A,I0,A,I0,A,I0,A,I0,A,I0)') &
    'fuzz_timeline: program dicts=', int(n_dict, int64), &
    ', desugared=', int(n_desugar, int64), &
    ', rejected with named diagnostics=', int(n_reject, int64), &
    ', diagnostics collected=', total_diags, &
    ', idempotence checks=', int(n_idem, int64), &
    ', fully clean runs=', int(n_clean, int64)
  flush (output_unit)

contains

  ! Report a violating case with its full reproducer, then stop
  ! non-zero (the runner turns any non-zero exit into FAIL).
  subroutine fail_case(why)
    character(len=*), intent(in) :: why
    write (output_unit, '(A,I0,A,I0,A,A)') &
      'fuzz_timeline: FAIL iter=', iter, ' seed=', seed_arg, &
      ' reason: ', why
    write (output_unit, '(A)') '--- mutant source (between markers) ---'
    if (blen > 0) write (output_unit, '(A)') buf(1:blen)
    write (output_unit, '(A)') '--- end mutant source ---'
    flush (output_unit)
    stop 1
  end subroutine fail_case

  ! Every diagnostic must carry a census-known [EW]ddd code.
  subroutine check_bag_named(b, ok)
    type(error_bag_t), intent(in) :: b
    logical, intent(out) :: ok
    type(diagnostic_t) :: d
    character(len=:), allocatable :: title
    logical :: found
    integer :: i, j
    ok = .true.
    do i = 1, error_bag_len(b)
      d = error_bag_at(b, i)
      if (.not. allocated(d%code)) then
        ok = .false.
        return
      end if
      if (len(d%code) /= 4) then
        ok = .false.
        return
      end if
      if (d%code(1:1) /= 'E') then
        if (d%code(1:1) /= 'W') then
          ok = .false.
          return
        end if
      end if
      do j = 2, 4
        if (d%code(j:j) < '0') then
          ok = .false.
          return
        end if
        if (d%code(j:j) > '9') then
          ok = .false.
          return
        end if
      end do
      call error_code_title(d%code, title, found)
      if (.not. found) then
        ok = .false.
        return
      end if
    end do
  end subroutine check_bag_named

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

    pure function limbs_of(x) result(l)
        integer(int64), intent(in) :: x
        integer(int64) :: l(4)
        integer :: i
        do i = 1, 4
            l(i) = iand(ishft(x, -16 * (i - 1)), 65535_int64)
        end do
    end function limbs_of

    pure function from_limbs(l) result(x)
        integer(int64), intent(in) :: l(4)
        integer(int64) :: x
        integer :: i
        x = 0_int64
        do i = 4, 1, -1
            x = ior(ishft(x, 16), l(i))
        end do
    end function from_limbs

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

  function rand_below(n) result(r)
    integer, intent(in) :: n
    integer :: r
    integer(int64) :: v
    v = prng_next()
    v = ishft(v, -1)
    r = int(mod(v, int(n, int64)))
  end function rand_below

  ! ================================================================
  ! Film-mode seed sources, modelled on examples/anim-golden.f3d
  ! and the ANIM-PLAN 1.10 scripts.  No `import` anywhere (see
  ! the header scope note).
  ! ================================================================
  subroutine init_seeds()
    character :: NL
    NL = achar(10)

    ! Seed 1: the anim-golden film, condensed (two scenes,
    ! together blocks, a transition, camera cue).
    seeds(1)%text = &
      'film "Anim Golden" size 320 240 fps 24' // NL // &
      'scene "stage" size 320 240 background white' // NL // &
      'camera at 0 3 10 look 0 1 0' // NL // &
      'plane ground gray at 0 -2 0 size 16' // NL // &
      'cube bench red at 3 0 0 size 2' // NL // &
      'place bench-front at 1 0 2' // NL // &
      'character ada blue at -3 0 2 tall head round ' // &
        'wears cap red' // NL // &
      'together' // NL // &
      '  ada walks to bench-front in 0.75 seconds ease smooth' // &
        NL // &
      '  camera pans to bench in 0.75 seconds ease smooth' // NL // &
      'end' // NL // &
      'ada waves for 0.417 seconds' // NL // &
      'scene "leap" size 320 240 background white ' // &
        'transition dissolve 0.333 seconds' // NL // &
      'camera at 0 3 10 look 0 1 0' // NL // &
      'plane ground gray at 0 -2 0 size 16' // NL // &
      'character ada blue at -1 0 2 tall head round ' // &
        'wears cap red' // NL // &
      'character mira pink at 3 0 2 kid head round hair bun' // &
        NL // &
      'together' // NL // &
      '  ada jumps for 0.5 seconds' // NL // &
      '  mira waves for 0.5 seconds' // NL // &
      'end' // NL // &
      'ada smiles for 0.334 seconds' // NL // &
      'render "output_render.ppm"' // NL

    ! Seed 2: let variable, custom action, repeat block, `with`,
    ! dialogue (the "Bus Is Late" shape, ANIM-PLAN Script B).
    seeds(2)%text = &
      'film "The Bus Is Late" size 320 240 fps 24' // NL // &
      'let wait-time be 3 seconds' // NL // &
      'action celebrate' // NL // &
      '  it jumps' // NL // &
      '  it waves both hands' // NL // &
      '  it spins speed 360' // NL // &
      'end' // NL // &
      'scene "bus stop" size 320 240 background white' // NL // &
      'camera at 0 3 10 look 0 1 0' // NL // &
      'plane ground gray at 0 -2 0 size 16' // NL // &
      'cube bench gray at -2 0 0 size 2' // NL // &
      'cube bus yellow at -14 0 0 size 4' // NL // &
      'place stop at 3 0 2' // NL // &
      'character rafi green at -2 0 2 short face determined' // &
        NL // &
      'rafi sits on bench for wait-time' // NL // &
      'repeat 2 times' // NL // &
      '  rafi taps foot for 1 second' // NL // &
      'end' // NL // &
      'bus moves to stop in 4 seconds ease out' // NL // &
      'with rafi stands for 1 second' // NL // &
      'rafi says "Finally!" for 2 seconds' // NL // &
      'rafi does celebrate for 2 seconds' // NL // &
      'rafi walks to bus in 2 seconds' // NL // &
      'render "bus.mp4"' // NL

    ! Seed 3: caption/title, absolute timecodes, wait, beats,
    ! adverbs, camera follows/zooms, loop forever cue.
    seeds(3)%text = &
      'film "Lost Key" size 320 240 fps 24 tempo 120' // NL // &
      'scene "park" size 320 240 background white ' // &
        'transition fade 1 second' // NL // &
      'camera at 0 3 10 look 0 1 0' // NL // &
      'plane ground gray at 0 -2 0 size 16' // NL // &
      'cube bench gray at 2 0 0 size 2' // NL // &
      'character lloyd blue at -5 0 2 tall head round' // NL // &
      'caption "One sunny morning." for 2 seconds' // NL // &
      'lloyd walks to bench in 3 seconds slowly' // NL // &
      'at 0:05 lloyd jumps' // NL // &
      'wait 1 second' // NL // &
      'lloyd dances for 8 beats gently' // NL // &
      'with camera follows lloyd' // NL // &
      'lloyd says "Found it!" for 2 seconds' // NL // &
      'title "The Lost Key" for 3 seconds' // NL // &
      'render "key.mp4"' // NL

    ! Seed 4: minimal film -- one scene, one character, one cue.
    seeds(4)%text = &
      'film "Tiny" size 320 240 fps 24' // NL // &
      'scene "only" size 320 240 background white' // NL // &
      'camera at 0 3 10 look 0 1 0' // NL // &
      'character ada blue at 0 0 2' // NL // &
      'ada waves for 1 second' // NL // &
      'render "tiny.mp4"' // NL
  end subroutine init_seeds

  subroutine reset_bag(b)
    type(error_bag_t), intent(inout) :: b
    if (allocated(b%diags)) deallocate (b%diags)
    b%n = 0
    b%cap = 0
    if (allocated(b%source_text)) deallocate (b%source_text)
    b%has_source = .false.
  end subroutine reset_bag

  ! ================================================================
  ! Mutations.  Operators 1-6 are fuzz_parser's; 7 (time
  ! expression) and 8 (loop corruption) are timeline-specific.
  ! ================================================================
  subroutine apply_one_mutation()
    integer :: kind
    kind = rand_below(9) + 1
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
    case (6, 9)
      call mut_swap_lines()      ! reordering, double weight
    case (7)
      call mut_time_expr()
    case (8)
      call mut_loop_corrupt()
    end select
  end subroutine apply_one_mutation

  subroutine mut_replace_byte()
    integer :: pos
    if (blen == 0) then
      call mut_insert_byte()
      return
    end if
    pos = rand_below(blen) + 1
    buf(pos:pos) = pick_byte()
  end subroutine mut_replace_byte

  subroutine mut_insert_byte()
    integer :: pos, i
    if (blen >= MAX_SOURCE) return
    pos = rand_below(blen + 1) + 1
    do i = blen, pos, -1
      buf(i + 1:i + 1) = buf(i:i)
    end do
    buf(pos:pos) = pick_byte()
    blen = blen + 1
  end subroutine mut_insert_byte

  subroutine mut_delete_byte()
    integer :: pos, i
    if (blen == 0) return
    pos = rand_below(blen) + 1
    do i = pos, blen - 1
      buf(i:i) = buf(i + 1:i + 1)
    end do
    blen = blen - 1
  end subroutine mut_delete_byte

  subroutine mut_truncate()
    if (blen == 0) return
    blen = rand_below(blen + 1)
  end subroutine mut_truncate

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

  subroutine scratch_append(lo, hi)
    integer, intent(in) :: lo, hi
    integer :: k
    if (hi < lo) return
    do k = lo, hi
      spos = spos + 1
      scratch(spos:spos) = buf(k:k)
    end do
  end subroutine scratch_append

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

  ! Replace buf(pos:pos+span-1) with repl(1:rlen), rebuilding in
  ! scratch.  No-op when the result would pass MAX_SOURCE.
  subroutine replace_span(pos, span, repl, rlen)
    integer, intent(in) :: pos, span, rlen
    character(len=*), intent(in) :: repl
    integer :: i, out
    if (blen - span + rlen > MAX_SOURCE) return
    spos = 0
    call scratch_append(1, pos - 1)
    do i = 1, rlen
      spos = spos + 1
      scratch(spos:spos) = repl(i:i)
    end do
    call scratch_append(pos + span, blen)
    out = spos
    do i = 1, out
      buf(i:i) = scratch(i:i)
    end do
    blen = out
  end subroutine replace_span

  ! Operator 7: time-expression mutation.  Half the time a drawn
  ! numeric token (digit run, including the inside of an M:SS
  ! timecode) is replaced by an adversarial value; the other half
  ! a drawn unit word is swapped for another / an unknown unit.
  subroutine mut_time_expr()
    integer, parameter :: NVAL = 10
    character(len=16) :: vals(NVAL)
    integer :: starts(256), ends(256), ntok, i, pick, pos
    logical :: in_tok
    vals = [character(len=16) :: '0', '-1', '999999', '1e999', &
      '0.000001', '99', '2147483648', '3.14159265359', '1e-999', '']
    if (rand_below(2) == 0) then
      ! Numeric token branch.
      ntok = 0
      in_tok = .false.
      do i = 1, blen
        if (buf(i:i) >= '0') then
          if (buf(i:i) <= '9') then
            if (.not. in_tok) then
              if (ntok < 256) then
                ntok = ntok + 1
                starts(ntok) = i
              end if
              in_tok = .true.
            end if
            if (ntok >= 1) ends(ntok) = i
            cycle
          end if
        end if
        in_tok = .false.
      end do
      if (ntok == 0) then
        call mut_replace_byte()
        return
      end if
      pick = rand_below(ntok) + 1
      pos = starts(pick)
      i = ends(pick) - pos + 1
      ! The value index is drawn ONCE: trim/len of two different
      ! draws would splice one value with another's length.
      pick = rand_below(NVAL) + 1
      call replace_span(pos, i, trim(vals(pick)), &
        len_trim(vals(pick)))
    else
      ! Unit-word branch: seconds -> beats/frames/minutes/secondz.
      call mut_unit_word()
    end if
  end subroutine mut_time_expr

  subroutine mut_unit_word()
    integer, parameter :: NUNIT = 5
    character(len=8) :: units(NUNIT)
    integer :: pos, pick, i
    units = [character(len=8) :: 'beats', 'frames', 'minutes', &
      'secondz', 'second']
    pos = index(buf(1:blen), 'seconds')
    if (pos <= 0) pos = index(buf(1:blen), 'second')
    if (pos <= 0) pos = index(buf(1:blen), 'beats')
    if (pos <= 0) then
      call mut_replace_byte()
      return
    end if
    pick = rand_below(NUNIT) + 1
    ! Span length decided by nested length guards first: a
    ! substring past blen would itself trip -fcheck=all.
    i = 5
    if (pos + 5 <= blen) then
      if (buf(pos:pos + 5) == 'second') i = 6
    end if
    if (i == 6) then
      if (pos + 6 <= blen) then
        if (buf(pos:pos + 6) == 'seconds') i = 7
      end if
    end if
    call replace_span(pos, i, trim(units(pick)), &
      len_trim(units(pick)))
  end subroutine mut_unit_word

  ! Operator 8: loop-bound corruption at line level -- duplicate
  ! or delete a drawn structural line (`repeat`, `together`,
  ! `end`, `action`), unbalancing blocks and multiplying loop
  ! bodies.  Falls back to a plain duplicate when no structural
  ! line survives earlier mutations.
  subroutine mut_loop_corrupt()
    integer :: starts(MAX_LINES), ends(MAX_LINES)
    integer :: nl, cand(MAX_LINES), nc, i, li, as, ae
    call line_spans(starts, ends, nl)
    if (nl == 0) return
    nc = 0
    do i = 1, nl
      as = starts(i)
      ae = ends(i)
      if (index(buf(as:ae), 'repeat') > 0) then
        nc = nc + 1
        cand(nc) = i
        cycle
      end if
      if (index(buf(as:ae), 'together') > 0) then
        nc = nc + 1
        cand(nc) = i
        cycle
      end if
      if (index(buf(as:ae), 'action') > 0) then
        nc = nc + 1
        cand(nc) = i
        cycle
      end if
      if (trim(buf(as:ae)) == 'end') then
        nc = nc + 1
        cand(nc) = i
      end if
    end do
    if (nc == 0) then
      call mut_duplicate_line()
      return
    end if
    li = cand(rand_below(nc) + 1)
    if (rand_below(2) == 0) then
      ! Delete the structural line.
      as = starts(li)
      ae = ends(li)
      call replace_span(as, ae - as + 1, '', 0)
    else
      ! Duplicate it (a second `repeat`/`together`/`end`).
      as = starts(li)
      ae = ends(li)
      spos = 0
      call scratch_append(1, ae)
      if (buf(ae:ae) /= achar(10)) then
        spos = spos + 1
        scratch(spos:spos) = achar(10)
      end if
      call scratch_append(as, ae)
      call scratch_append(ae + 1, blen)
      if (spos <= MAX_SOURCE) then
        do i = 1, spos
          buf(i:i) = scratch(i:i)
        end do
        blen = spos
      end if
    end if
  end subroutine mut_loop_corrupt

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

end program fuzz_timeline
