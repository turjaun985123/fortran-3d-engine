! fuzz_desugar.f90 -- plain-word vs numeric equivalence fuzz
! harness for the Forge3D animation compiler (Wave 6,
! ANIM-PLAN 5.6).
!
! Purpose
! -------
! The film language promises that its plain-word forms are
! EXACTLY their numeric/canonical equivalents (ANIM-PLAN 1.4,
! 1.8, 5.7): `walks` = `walk`, `2 seconds` = `2`, `1 second` =
! `1 seconds`, `slowly` = `ease out`, `gently` = `ease
! cubic-in-out`, `4 beats` at tempo 120 = `2 seconds`,
! `at 0:05` = `at 5 seconds` = `at 5`, `for wait-time` (a `let`
! bound to `2 seconds`) = `for 2 seconds`.  This harness checks
! that promise mechanically, the way ANIM-PLAN 5.6 specifies:
!
!   For every generated case it builds TWO sources with the
!   real bin/f3dc -- a plain-word variant and its numeric twin
!   -- and compares the emitted build/twin.timeline.json
!   bytes.  The invariant is:
!
!     desugared output is either IDENTICAL IR or a NAMED
!     diagnostic -- never different-but-silent IR.
!
!   The single masked byte range is the generator provenance
!   field "source_sha256": it hashes the source TEXT, which
!   differs between the twins by construction, and ANIM-PLAN
!   3.6 declares generator data provenance-only.  Every other
!   byte -- the whole normative payload -- must match exactly.
!
! Case generation (splitmix64, deterministic per seed): the
! shared parameters (two durations from a frame-exact table at
! 24 fps, an at-offset, the character/place/scene scaffold)
! are drawn once, then each equivalence dimension is drawn
! independently and applied to the plain variant in its word
! form and to the twin in its numeric form:
!   T1 verb form    walks/waves        vs walk/wave (either way)
!   T2 unit form    `N seconds`        vs bare `N` (either way)
!   T3 ease adverb  slowly / gently    vs ease out / cubic-in-out
!   T4 beats        `B beats`, tempo 120 (B = 2*duration)
!                                      vs `D seconds`
!   T5 at form      `at 0:0S`          vs `at S seconds` / `at S`
!   T6 let form     `for wait-time`    vs the literal duration
! About 15% of cases are CORRUPTION cases: one word token of
! the plain variant is damaged (seconds->secondz, walks->wavs,
! beats->beatz, slowly->slowlee, bench-front->bench-fron,
! wait-time->wait-tyme).  A corruption case passes iff the
! plain build either still produces the twin's exact IR
! (benign damage) or fails with a NAMED `error Eddd`
! diagnostic and a compiler exit code (1 or 3) -- a crash
! (signal / exit >= 124), a timeout, or an unnamed failure
! is a harness FAIL.
!
! Mechanics: this harness is a DRIVER, not an in-process
! harness like fuzz_parser/fuzz_timeline -- the equivalence
! lives in the full build pipeline (parse -> desugar ->
! validate -> timeline emit), so it drives bin/f3dc as a
! subprocess (execute_command_line), each build wrapped in
! `timeout 10` as the per-build wall-clock bound (a hang is a
! FAIL, per ANIM-PLAN 5.6's non-termination rule), with the
! case's total wall time also bounded (25 s).  It links NO
! production modules; run_fuzz.sh builds it alone (plus the
! usual sanitizer flags, which police the harness itself).
! f3dc is located via, in order: $F3DC, $PWD/bin/f3dc,
! ./bin/f3dc -- i.e. run from the repository root (as
! run_fuzz.sh is), or set F3DC to an absolute path.
!
! Work files live in ./fuzz_desugar_work/{a,b}/ (twin.f3d,
! build.log, build/twin.timeline.json).  On a FAIL the whole
! directory is left in place as the reproducer and both
! variant sources are printed; on success it is removed.
!
! Usage: ./fuzz_desugar [iterations] [seed]   (iterations are
! CASES, each costing two f3dc builds; capped at 300 -- see
! MAX_ITERATIONS below for why.)
program fuzz_desugar
  use, intrinsic :: iso_fortran_env, only: int64, output_unit
  implicit none

  integer, parameter :: MAXBUF = 8192
  integer, parameter :: MAXFILE = 1048576
  integer, parameter :: DEFAULT_ITERATIONS = 200
  integer(int64), parameter :: DEFAULT_SEED = 20261126_int64
  ! Hard cap on cases: each case costs two full f3dc builds
  ! (~0.5 s each on a throttled VM), so an uncapped shared
  ! iteration count from run_fuzz.sh would blow its per-harness
  ! timeout through no fault of the code under test.
  integer(int64), parameter :: MAX_ITERATIONS = 300_int64
  integer(int64), parameter :: CASE_WALL_SECONDS = 25_int64

  ! Frame-exact durations at 24 fps, and their beat counts at
  ! tempo 120 (beats = 2 x seconds, always whole here).
  integer, parameter :: NDUR = 7
  character(len=4) :: DURS(NDUR)
  character(len=2) :: BEATS(NDUR)

  integer(int64) :: rng_state = 0_int64
  character(len=1024) :: f3dc_path
  character(len=MAXBUF) :: plain_buf, twin_buf, scratch
  integer :: plain_len, twin_len

  integer(int64) :: seed_arg, iter_arg, iter
  integer :: n_ident, n_both_reject, n_corrupt_named, n_corrupt_benign
  integer(int64) :: clock0, clock1, clock_rate

  DURS = [character(len=4) :: '0.5', '1', '1.5', '2', '2.5', '3', '4']
  BEATS = [character(len=2) :: '1', '2', '3', '4', '5', '6', '8']

  call read_args(iter_arg, seed_arg)
  rng_state = seed_arg
  call system_clock(count_rate=clock_rate)
  call locate_f3dc()
  call setup_workdirs()

  write (output_unit, '(A,I0,A,I0)') &
    'fuzz_desugar: seed=', seed_arg, ' iterations=', iter_arg
  write (output_unit, '(A,A)') 'fuzz_desugar: f3dc: ', trim(f3dc_path)
  flush (output_unit)

  n_ident = 0; n_both_reject = 0
  n_corrupt_named = 0; n_corrupt_benign = 0

  ! Sanity leg (iter 0): the unmutated, dimension-free pair must
  ! build identically -- otherwise the harness or the tree is
  ! broken before fuzzing starts.
  iter = 0_int64
  call run_case(.false., .true.)   ! counters skip the sanity leg

  do iter = 1_int64, iter_arg
    call run_case(rand_below(100) < 15, .false.)
    if (mod(iter, 25_int64) == 0_int64) then
      write (output_unit, '(A,I0,A,I0)') &
        'fuzz_desugar: ', iter, '/', iter_arg
      flush (output_unit)
    end if
  end do

  call cleanup_workdirs()
  write (output_unit, '(A,I0,A)') &
    'fuzz_desugar: ', iter_arg, ' cases, no crash, no silent divergence'
  write (output_unit, '(A,I0,A,I0,A,I0,A,I0)') &
    'fuzz_desugar: identical-IR=', int(n_ident, int64), &
    ', both-rejected-same-code=', int(n_both_reject, int64), &
    ', corruption-named-diagnostic=', int(n_corrupt_named, int64), &
    ', corruption-benign-identical=', int(n_corrupt_benign, int64)
  flush (output_unit)

contains

  ! ================================================================
  ! One case: generate the pair, build both, apply the invariant.
  ! ================================================================
  subroutine run_case(corrupt, sanity)
    logical, intent(in) :: corrupt, sanity
    integer :: code_a, code_b
    character(len=8) :: ecode_a, ecode_b
    character(len=:), allocatable :: tl_a, tl_b, log_a, log_b
    logical :: have_a, have_b

    call gen_pair(corrupt, sanity)
    call write_source('fuzz_desugar_work/a/twin.f3d', &
      plain_buf, plain_len)
    call write_source('fuzz_desugar_work/b/twin.f3d', &
      twin_buf, twin_len)

    call system_clock(clock0)
    call build_one('a', code_a)
    call build_one('b', code_b)
    call system_clock(clock1)
    if (clock_rate > 0) then
      if (clock1 - clock0 > CASE_WALL_SECONDS * clock_rate) &
        call fail_case('case exceeded wall-clock bound (hang?)')
    end if

    ! Crash / timeout / exec failure is never a diagnostic.
    if (code_a >= 124) call fail_case('plain build crashed/timed out')
    if (code_b >= 124) call fail_case('twin build crashed/timed out')
    if (code_a == 126) call fail_case('plain build not executable')
    if (code_b == 126) call fail_case('twin build not executable')
    if (code_a == 127) call fail_case('f3dc not found (env failure)')
    if (code_b == 127) call fail_case('f3dc not found (env failure)')

    call read_file('fuzz_desugar_work/a/build.log', log_a, have_a)
    if (.not. have_a) log_a = ''
    call read_file('fuzz_desugar_work/b/build.log', log_b, have_b)
    if (.not. have_b) log_b = ''
    call first_ecode(log_a, ecode_a)
    call first_ecode(log_b, ecode_b)
    call read_timeline_file('a', tl_a, have_a)
    call read_timeline_file('b', tl_b, have_b)

    if (corrupt) then
      ! Twin is the uncorrupted reference and must build clean.
      if (code_b /= 0) &
        call fail_case('corruption case: numeric twin failed to build')
      if (.not. have_b) &
        call fail_case('corruption case: twin produced no timeline')
      if (code_a == 0) then
        if (.not. have_a) &
          call fail_case('corrupt plain built but produced no timeline')
        if (tl_a /= tl_b) &
          call fail_case('corrupt plain: DIFFERENT-but-silent IR')
        if (.not. sanity) n_corrupt_benign = n_corrupt_benign + 1
      else
        if (code_a /= 1) then
          if (code_a /= 3) &
            call fail_case('corrupt plain: non-compiler exit code')
        end if
        if (ecode_a == '') &
          call fail_case('corrupt plain: failure with no named E-code')
        if (.not. sanity) n_corrupt_named = n_corrupt_named + 1
      end if
      return
    end if

    ! Equivalence case.
    if (code_a == 0) then
      if (code_b /= 0) &
        call fail_case('plain built, twin rejected (divergent verdict)')
      if (.not. have_a) call fail_case('plain built, no timeline file')
      if (.not. have_b) call fail_case('twin built, no timeline file')
      if (tl_a /= tl_b) &
        call fail_case('DIFFERENT-but-silent IR (equivalence broken)')
      if (.not. sanity) n_ident = n_ident + 1
    else
      if (code_b == 0) &
        call fail_case('plain rejected, twin built (divergent verdict)')
      if (ecode_a == '') &
        call fail_case('plain failure with no named E-code')
      if (ecode_b == '') &
        call fail_case('twin failure with no named E-code')
      if (ecode_a /= ecode_b) &
        call fail_case('twins rejected with DIFFERENT E-codes')
      if (.not. sanity) n_both_reject = n_both_reject + 1
    end if
  end subroutine run_case

  subroutine fail_case(why)
    character(len=*), intent(in) :: why
    write (output_unit, '(A,I0,A,I0,A,A)') &
      'fuzz_desugar: FAIL iter=', iter, ' seed=', seed_arg, &
      ' reason: ', why
    write (output_unit, '(A)') &
      'fuzz_desugar: work dir kept: fuzz_desugar_work/ (a=plain, b=twin)'
    write (output_unit, '(A)') '--- plain variant ---'
    if (plain_len > 0) &
      write (output_unit, '(A)') plain_buf(1:plain_len)
    write (output_unit, '(A)') '--- numeric twin ---'
    if (twin_len > 0) &
      write (output_unit, '(A)') twin_buf(1:twin_len)
    flush (output_unit)
    stop 1
  end subroutine fail_case

  ! ================================================================
  ! Pair generation.  All draws come from the one PRNG stream;
  ! `sanity` forces every dimension off (the canonical pair).
  ! ================================================================
  subroutine gen_pair(corrupt, sanity)
    logical, intent(in) :: corrupt, sanity
    integer :: d1, d2, ats, ease_dim, unit_dim, at_dim
    logical :: beats_dim, let_dim, s_first
    ! 128, not 64: the longest cue (`at 2 seconds ada walks to
    ! bench-front in 0.5 seconds ease cubic-in-out`) is ~70
    ! chars, and a len=64 buffer truncated it mid-word in the
    ! first extended run (harness bug, found by that run).
    character(len=128) :: cue1_plain, cue1_twin, cue2_plain, cue2_twin
    character(len=16) :: ats_txt
    character :: NL

    NL = achar(10)
    d1 = rand_below(NDUR) + 1
    d2 = rand_below(NDUR) + 1
    ats = rand_below(5) + 1
    ease_dim = rand_below(3)     ! 0 none, 1 slowly/out, 2 gently/cubic
    unit_dim = rand_below(2)     ! 0 plain=word, 1 plain=bare
    at_dim = rand_below(3)       ! 0 none, 1 at on cue1
    beats_dim = rand_below(3) == 0
    let_dim = rand_below(3) == 0
    s_first = rand_below(2) == 0
    if (sanity) then
      ease_dim = 0
      at_dim = 0
      beats_dim = .false.
      let_dim = .false.
    end if
    if (beats_dim) let_dim = .false.   ! one special form per cue2

    ! ---- cue 1: walk to the place, duration d1, ease dimension.
    ! Every appended segment carries its own LEADING space:
    ! trim() on the left operand would eat a trailing one.
    cue1_plain = 'ada'
    cue1_twin = 'ada'
    if (at_dim == 1) then
      write (ats_txt, '(A,I1)') '0:0', ats
      cue1_plain = 'at ' // trim(ats_txt) // ' ada'
      if (rand_below(2) == 0) then
        write (ats_txt, '(I1,A)') ats, ' seconds'
        cue1_twin = 'at ' // trim(ats_txt) // ' ada'
      else
        write (ats_txt, '(I1)') ats
        cue1_twin = 'at ' // trim(ats_txt) // ' ada'
      end if
    end if
    if (s_first) then
      cue1_plain = trim(cue1_plain) // ' walks to bench-front in'
      cue1_twin = trim(cue1_twin) // ' walk to bench-front in'
    else
      cue1_plain = trim(cue1_plain) // ' walk to bench-front in'
      cue1_twin = trim(cue1_twin) // ' walks to bench-front in'
    end if
    if (unit_dim == 0) then
      cue1_plain = trim(cue1_plain) // ' ' // trim(DURS(d1)) // &
        ' ' // unit_word(DURS(d1))
      cue1_twin = trim(cue1_twin) // ' ' // trim(DURS(d1))
    else
      cue1_plain = trim(cue1_plain) // ' ' // trim(DURS(d1))
      cue1_twin = trim(cue1_twin) // ' ' // trim(DURS(d1)) // &
        ' ' // unit_word(DURS(d1))
    end if
    select case (ease_dim)
    case (1)
      cue1_plain = trim(cue1_plain) // ' slowly'
      cue1_twin = trim(cue1_twin) // ' ease out'
    case (2)
      cue1_plain = trim(cue1_plain) // ' gently'
      cue1_twin = trim(cue1_twin) // ' ease cubic-in-out'
    case default
      cue1_plain = trim(cue1_plain) // ' ease smooth'
      cue1_twin = trim(cue1_twin) // ' ease smooth'
    end select

    ! ---- cue 2: wave, duration d2 (beats / let / unit forms)
    if (s_first) then
      cue2_plain = 'ada waves for'
      cue2_twin = 'ada wave for'
    else
      cue2_plain = 'ada wave for'
      cue2_twin = 'ada waves for'
    end if
    if (beats_dim) then
      cue2_plain = trim(cue2_plain) // ' ' // trim(BEATS(d2)) // &
        ' beats'
      cue2_twin = trim(cue2_twin) // ' ' // trim(DURS(d2)) // &
        ' seconds'
    else if (let_dim) then
      cue2_plain = trim(cue2_plain) // ' wait-time'
      cue2_twin = trim(cue2_twin) // ' ' // trim(DURS(d2)) // &
        ' seconds'
    else if (unit_dim == 0) then
      cue2_plain = trim(cue2_plain) // ' ' // trim(DURS(d2)) // &
        ' ' // unit_word(DURS(d2))
      cue2_twin = trim(cue2_twin) // ' ' // trim(DURS(d2))
    else
      cue2_plain = trim(cue2_plain) // ' ' // trim(DURS(d2))
      cue2_twin = trim(cue2_twin) // ' ' // trim(DURS(d2)) // &
        ' ' // unit_word(DURS(d2))
    end if

    ! ---- assemble both sources on the shared scaffold
    plain_len = 0
    plain_buf = ' '
    call add_line(plain_buf, plain_len, &
      'film "Twin" size 320 240 fps 24' // tempo_suffix(beats_dim))
    if (let_dim) then
      call add_line(plain_buf, plain_len, &
        'let wait-time be ' // trim(DURS(d2)) // ' seconds')
    end if
    call add_scaffold(plain_buf, plain_len)
    call add_line(plain_buf, plain_len, trim(cue1_plain))
    call add_line(plain_buf, plain_len, trim(cue2_plain))
    call add_line(plain_buf, plain_len, 'render "x.ppm"')

    twin_len = 0
    twin_buf = ' '
    call add_line(twin_buf, twin_len, &
      'film "Twin" size 320 240 fps 24' // tempo_suffix(beats_dim))
    call add_scaffold(twin_buf, twin_len)
    call add_line(twin_buf, twin_len, trim(cue1_twin))
    call add_line(twin_buf, twin_len, trim(cue2_twin))
    call add_line(twin_buf, twin_len, 'render "x.ppm"')

    if (corrupt) call corrupt_plain()
  end subroutine gen_pair

  function tempo_suffix(beats) result(s)
    logical, intent(in) :: beats
    character(len=10) :: s
    if (beats) then
      s = ' tempo 120'
    else
      s = ''
    end if
  end function tempo_suffix

  function unit_word(dur) result(w)
    character(len=*), intent(in) :: dur
    character(len=8) :: w
    if (trim(dur) == '1') then
      w = 'second'
    else
      w = 'seconds'
    end if
  end function unit_word

  subroutine add_scaffold(b, blen)
    character(len=*), intent(inout) :: b
    integer, intent(inout) :: blen
    call add_line(b, blen, 'scene "s" size 320 240 background white')
    call add_line(b, blen, 'camera at 0 3 10 look 0 1 0')
    call add_line(b, blen, 'plane ground gray at 0 -2 0 size 16')
    call add_line(b, blen, 'place bench-front at 1 0 2')
    call add_line(b, blen, &
      'character ada blue at -3 0 2 tall head round')
  end subroutine add_scaffold

  subroutine add_line(b, blen, s)
    character(len=*), intent(inout) :: b
    integer, intent(inout) :: blen
    character(len=*), intent(in) :: s
    integer :: k, n
    n = len_trim(s)
    if (blen + n + 1 > MAXBUF) return
    do k = 1, n
      b(blen + k:blen + k) = s(k:k)
    end do
    blen = blen + n
    blen = blen + 1
    b(blen:blen) = achar(10)
  end subroutine add_line

  ! Corruption: damage ONE word token of the plain variant.
  subroutine corrupt_plain()
    integer, parameter :: NCOR = 7
    character(len=12) :: from_tok(NCOR), to_tok(NCOR)
    integer :: pick, pos, i, out
    from_tok = [character(len=12) :: 'seconds', 'walks', 'waves', &
      'beats', 'slowly', 'gently', 'bench-front']
    to_tok = [character(len=12) :: 'secondz', 'wavs', 'wavs', &
      'beatz', 'slowlee', 'gentlee', 'bench-fron']
    ! `let` cases carry one extra corruptible token.
    if (index(plain_buf(1:plain_len), 'wait-time') > 0) then
      if (rand_below(4) == 0) then
        pos = index(plain_buf(1:plain_len), 'wait-time')
        call replace_span_plain(pos, 9, 'wait-tyme', 9)
        return
      end if
    end if
    do i = 1, NCOR
      pick = rand_below(NCOR) + 1
      pos = index(plain_buf(1:plain_len), trim(from_tok(pick)))
      if (pos > 0) then
        call replace_span_plain(pos, len_trim(from_tok(pick)), &
          trim(to_tok(pick)), len_trim(to_tok(pick)))
        return
      end if
    end do
    out = 0  ! no token found: case degrades to an equivalence case
  end subroutine corrupt_plain

  subroutine replace_span_plain(pos, span, repl, rlen)
    integer, intent(in) :: pos, span, rlen
    character(len=*), intent(in) :: repl
    integer :: i, k, spos
    if (plain_len - span + rlen > MAXBUF) return
    spos = 0
    do k = 1, pos - 1
      spos = spos + 1
      scratch(spos:spos) = plain_buf(k:k)
    end do
    do i = 1, rlen
      spos = spos + 1
      scratch(spos:spos) = repl(i:i)
    end do
    do k = pos + span, plain_len
      spos = spos + 1
      scratch(spos:spos) = plain_buf(k:k)
    end do
    do i = 1, spos
      plain_buf(i:i) = scratch(i:i)
    end do
    plain_len = spos
  end subroutine replace_span_plain

  ! ================================================================
  ! Subprocess / file plumbing.
  ! ================================================================
  subroutine locate_f3dc()
    character(len=1024) :: env
    integer :: st, ln
    logical :: exists
    call get_environment_variable('F3DC', env, ln, st)
    if (st == 0) then
      if (ln > 0) then
        f3dc_path = env(1:ln)
        return
      end if
    end if
    call get_environment_variable('PWD', env, ln, st)
    if (st == 0) then
      if (ln > 0) then
        inquire (file=trim(env(1:ln)) // '/bin/f3dc', &
          exist=exists)
        if (exists) then
          f3dc_path = trim(env(1:ln)) // '/bin/f3dc'
          return
        end if
      end if
    end if
    inquire (file='bin/f3dc', exist=exists)
    if (exists) then
      f3dc_path = 'bin/f3dc'
      return
    end if
    write (output_unit, '(A)') &
      'fuzz_desugar: FATAL: bin/f3dc not found (set F3DC, or run ' // &
      'from the repository root)'
    stop 2
  end subroutine locate_f3dc

  subroutine setup_workdirs()
    integer :: cs, es
    call execute_command_line( &
      'mkdir -p fuzz_desugar_work/a fuzz_desugar_work/b', &
      wait=.true., exitstat=es, cmdstat=cs)
    if (cs /= 0) then
      write (output_unit, '(A)') &
        'fuzz_desugar: FATAL: cannot create fuzz_desugar_work/'
      stop 2
    end if
  end subroutine setup_workdirs

  subroutine cleanup_workdirs()
    integer :: cs, es
    call execute_command_line('rm -rf fuzz_desugar_work', &
      wait=.true., exitstat=es, cmdstat=cs)
  end subroutine cleanup_workdirs

  subroutine build_one(which, code)
    character(len=1), intent(in) :: which
    integer, intent(out) :: code
    character(len=2048) :: cmd
    integer :: cs
    cmd = 'cd fuzz_desugar_work/' // which // &
      ' && timeout 10 ' // trim(f3dc_path) // &
      ' build twin.f3d > build.log 2>&1'
    call execute_command_line(trim(cmd), wait=.true., &
      exitstat=code, cmdstat=cs)
    if (cs /= 0) then
      write (output_unit, '(A)') &
        'fuzz_desugar: FATAL: could not execute f3dc build'
      stop 2
    end if
  end subroutine build_one

  subroutine write_source(path, b, blen)
    character(len=*), intent(in) :: path, b
    integer, intent(in) :: blen
    integer :: u, ios
    open (newunit=u, file=path, status='replace', action='write', &
      iostat=ios)
    if (ios /= 0) then
      write (output_unit, '(A,A)') &
        'fuzz_desugar: FATAL: cannot write ', path
      stop 2
    end if
    if (blen > 0) write (u, '(A)') b(1:blen)
    close (u)
  end subroutine write_source

  ! Whole-file read (stream access, size from inquire -- the
  ! timeline_ir reader's pattern).  ok=.false. when absent.
  subroutine read_file(path, text, ok)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: text
    logical, intent(out) :: ok
    integer :: u, ios
    integer(int64) :: fsize
    ok = .false.
    inquire (file=path, size=fsize, iostat=ios)
    if (ios /= 0) return
    if (fsize <= 0) then
      allocate (character(len=0) :: text)
      ok = .true.
      return
    end if
    if (fsize > MAXFILE) return
    open (newunit=u, file=path, status='old', action='read', &
      access='stream', form='unformatted', iostat=ios)
    if (ios /= 0) return
    allocate (character(len=int(fsize)) :: text)
    read (u, iostat=ios) text
    close (u)
    if (ios /= 0) then
      deallocate (text)
      return
    end if
    ok = .true.
  end subroutine read_file

  ! Read one variant's timeline file and mask the provenance
  ! hash (see the header: the ONLY masked bytes).
  subroutine read_timeline_file(which, text, ok)
    character(len=1), intent(in) :: which
    character(len=:), allocatable, intent(out) :: text
    logical, intent(out) :: ok
    character(len=64) :: path
    integer :: pos, i
    path = 'fuzz_desugar_work/' // which // '/build/twin.timeline.json'
    call read_file(path, text, ok)
    if (.not. ok) return
    pos = index(text, '"source_sha256":"')
    if (pos > 0) then
      pos = pos + 17
      do i = pos, min(pos + 63, len(text))
        text(i:i) = 'X'
      end do
    end if
  end subroutine read_timeline_file

  ! First `error Eddd` code in a build log ('' when none).
  subroutine first_ecode(log_text, code)
    character(len=*), intent(in) :: log_text
    character(len=8), intent(out) :: code
    integer :: pos, i
    logical :: digits
    code = ''
    pos = index(log_text, 'error E')
    if (pos <= 0) return
    pos = pos + 6
    if (pos + 3 > len(log_text)) return
    digits = .true.
    do i = pos + 1, pos + 3
      if (log_text(i:i) < '0') digits = .false.
      if (log_text(i:i) > '9') digits = .false.
    end do
    if (.not. digits) return
    code = 'E' // log_text(pos + 1:pos + 3)
  end subroutine first_ecode

  ! ================================================================
  ! Arguments + PRNG (house splitmix64, 16-bit limbs).
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

end program fuzz_desugar
