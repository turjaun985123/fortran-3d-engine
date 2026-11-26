! fuzz_ir.f90 -- mutation fuzz harness for the Forge3D Timeline IR
! engine reader (Animation Compiler Wave 6, ANIM-PLAN 5.6).
!
! Purpose
! -------
! Feed deterministically mutated copies of known-good Timeline IR
! documents to the REAL engine reader:
!
!     timeline_ir_3d%read_timeline   (src/timeline_ir.f90)
!
! -- the exact reader bin/engine3d's `.timeline.json --report`
! path uses (src/main.f90) -- and verify the ADR-5 reader
! contract on hostile input:
!
!   * no crash, no hang (per-case wall-clock bound,
!     CASE_WALL_SECONDS, enforced with system_clock);
!   * the VERSION GATE holds under mutation: whenever this
!     harness's token operator rewrites ir_version to a value
!     other than 1, the reader MUST reject the document with an
!     error message that names ir_version -- never accept it,
!     never reject it silently or for an unrelated reason that
!     masks the gate;
!   * NO SILENT DROPS: whenever the token operator rewrites a
!     track kind to an unknown kind, an accepted document MUST
!     record the skip (tl%n_skipped_tracks >= 1 AND at least one
!     diagnostic note in tl%notes); whenever it rewrites an ease
!     name to an unknown one, an accepted document MUST record
!     a note for the linear fallback.  A rejected document must
!     always carry a non-empty errmsg;
!   * bounds behaviour: an accepted document satisfies the
!     reader's own sanity rules as observable invariants --
!     fps num/den > 0, duration_frames >= 0, every dialogue cue
!     has end > start, every scene span ends within the timeline
!     duration, every stored key frame is >= 0.  (A reader that
!     silently accepted a corrupt count would break these.)
!
! Mutations: byte-level ops (replace / insert / delete /
! duplicate / truncate / splice, as in fuzz_scene) plus
! token-level swaps over the Timeline IR vocabulary (format
! string, ir_version, fps num/den, duration_frames, frame
! numbers, track kinds, ease names, character/scene ids).
! Token swaps that set an expectation flag above only set it
! when the swap actually landed, and token cases are exactly
! ONE swap with no byte mutations on top, so no earlier
! corruption can legitimately be reported before the gate
! under test (byte cases carry only the general invariants).
!
! Determinism / PRNG / traps: exactly the house discipline of
! fuzz_parser / fuzz_scene -- splitmix64 in 16-bit limbs,
! MAXBUF-capped buffers, nested-if guards (no .AND. guards),
! byte-by-byte slice shifts.  The mutated file is written BEFORE
! the read, so on a crash fuzz_ir_tmp.timeline.json in the
! working directory is the exact reproducer for the case in
! flight (seed + iteration identify it deterministically).
!
! Build: see tests/fuzz/run_fuzz.sh (ASan + UBSan + -fcheck=all).
! Exact module link set (traced from the `use` statements):
!   this program : timeline_ir_3d (read_timeline, timeline_free,
!                  tl_timeline and component types)
!   timeline_ir_3d : json_reader_3d (src/json_reader.f90)
!   json_reader_3d : (standalone)
! So the object set is: json_reader, timeline_ir.  That is the
! whole engine-side load path for a .timeline.json report; the
! film evaluator (timeline_eval_3d) is downstream of a successful
! read and is exercised by the engine's own tests, not here.
program fuzz_ir
  use, intrinsic :: iso_fortran_env, only: int64, output_unit
  use timeline_ir_3d, only: tl_timeline, read_timeline, timeline_free
  implicit none

  integer, parameter :: MAXBUF = 16384
  integer, parameter :: MAXLINES = 512
  integer, parameter :: DEFAULT_ITERATIONS = 5000
  integer(int64), parameter :: DEFAULT_SEED = 20261126_int64
  integer(int64), parameter :: MAX_ITERATIONS = 100000000_int64
  integer(int64), parameter :: CASE_WALL_SECONDS = 5_int64

  type :: seed_box
    character(len=:), allocatable :: text
  end type seed_box
  integer, parameter :: N_SEEDS = 2
  type(seed_box) :: seeds(N_SEEDS)

  integer(int64) :: rng_state = 0_int64
  character(len=MAXBUF) :: buf
  integer :: buflen = 0

  integer(int64) :: seed_arg, iter_arg, iter
  integer :: n_accepted, n_rejected, n_vgate, n_kind, n_ease
  integer :: si, nmut, m, choice
  logical :: exp_bad_version, exp_bad_format, exp_bad_fps
  logical :: exp_bad_duration, exp_unknown_kind, exp_unknown_ease

  type(tl_timeline) :: tl
  logical :: ok
  character(len=1024) :: errmsg
  integer(int64) :: clock0, clock1, clock_rate
  character(len=*), parameter :: TMPFILE = 'fuzz_ir_tmp.timeline.json'

  call read_args(iter_arg, seed_arg)
  rng_state = seed_arg
  call init_seeds()
  call system_clock(count_rate=clock_rate)

  write (output_unit, '(A,I0,A,I0)') &
    'fuzz_ir: seed=', seed_arg, ' iterations=', iter_arg
  flush (output_unit)

  ! Sanity leg: both UNMUTATED seeds must be accepted.  A failure
  ! here is a harness bug, reported loudly (stop 2), not a
  ! reader finding.
  do si = 1, N_SEEDS
    buflen = len(seeds(si)%text)
    buf(1:buflen) = seeds(si)%text
    call write_temp(buf, buflen)
    call read_timeline(TMPFILE, tl, ok, errmsg)
    if (.not. ok) then
      write (output_unit, '(A,I0,A,A)') &
        'fuzz_ir: FATAL: unmutated seed ', si, &
        ' rejected: ', trim(errmsg)
      stop 2
    end if
    call timeline_free(tl)
  end do
  write (output_unit, '(A)') 'fuzz_ir: sanity leg ok (seeds accepted)'

  n_accepted = 0; n_rejected = 0
  n_vgate = 0; n_kind = 0; n_ease = 0

  do iter = 1_int64, iter_arg
    si = rand_below(N_SEEDS) + 1
    buflen = len(seeds(si)%text)
    buf(1:buflen) = seeds(si)%text

    exp_bad_version = .false.
    exp_bad_format = .false.
    exp_bad_fps = .false.
    exp_bad_duration = .false.
    exp_unknown_kind = .false.
    exp_unknown_ease = .false.

    ! Case classes are kept separate on purpose: a TOKEN case is
    ! exactly one token swap and nothing else, so the expectation
    ! flags below are sound (no earlier corruption can legitimately
    ! be reported before the gate under test).  A BYTE case carries
    ! only the general invariants.
    if (rand_below(100) < 40) then
      ! Token cases always start from the full seed (seed 1):
      ! the minimal seed lacks most of the vocabulary tokens.
      buflen = len(seeds(1)%text)
      buf(1:buflen) = seeds(1)%text
      call mut_token()
    else
      nmut = rand_below(5) + 1
      do m = 1, nmut
        call mut_bytes()
      end do
    end if

    call write_temp(buf, buflen)
    call system_clock(clock0)
    call read_timeline(TMPFILE, tl, ok, errmsg)
    call system_clock(clock1)
    if (clock_rate > 0) then
      if (clock1 - clock0 > CASE_WALL_SECONDS * clock_rate) &
        call fail_case('case exceeded wall-clock bound (hang?)')
    end if

    if (ok) then
      n_accepted = n_accepted + 1
      call check_accepted()
    else
      n_rejected = n_rejected + 1
      if (len_trim(errmsg) == 0) &
        call fail_case('rejected with EMPTY errmsg (silent failure)')
    end if

    ! Version gate: a mutated ir_version must be named.
    if (exp_bad_version) then
      n_vgate = n_vgate + 1
      if (ok) call fail_case('bad ir_version ACCEPTED (gate broken)')
      if (index(errmsg, 'ir_version') == 0) &
        call fail_case('bad ir_version not named in errmsg')
    end if
    if (exp_bad_format) then
      if (ok) call fail_case('bad format ACCEPTED')
      if (index(errmsg, 'format') == 0) &
        call fail_case('bad format not named in errmsg')
    end if
    if (exp_bad_fps) then
      if (ok) call fail_case('non-positive fps ACCEPTED')
      if (index(errmsg, 'fps') == 0) &
        call fail_case('bad fps not named in errmsg')
    end if
    if (exp_bad_duration) then
      if (ok) call fail_case('negative duration_frames ACCEPTED')
    end if

    ! No silent drops: unknown kinds / eases must leave a trace.
    if (exp_unknown_kind) then
      n_kind = n_kind + 1
      if (ok) then
        if (tl%n_skipped_tracks < 1) &
          call fail_case('unknown track kind silently kept/dropped')
        if (tl%n_notes < 1) &
          call fail_case('unknown track kind left no note')
      end if
    end if
    if (exp_unknown_ease) then
      n_ease = n_ease + 1
      if (ok) then
        if (tl%n_notes < 1) &
          call fail_case('unknown ease fell back with no note')
      end if
    end if

    call timeline_free(tl)

    if (mod(iter, 250_int64) == 0_int64) then
      write (output_unit, '(A,I0,A,I0)') 'fuzz_ir: ', iter, '/', iter_arg
      flush (output_unit)
    end if
  end do

  write (output_unit, '(A,I0,A)') &
    'fuzz_ir: ', iter_arg, ' iterations, no crash'
  write (output_unit, '(A,I0,A,I0,A,I0,A,I0,A,I0)') &
    'fuzz_ir: accepted=', int(n_accepted, int64), &
    ', rejected=', int(n_rejected, int64), &
    ', version-gate assertions=', int(n_vgate, int64), &
    ', unknown-kind assertions=', int(n_kind, int64), &
    ', unknown-ease assertions=', int(n_ease, int64)
  flush (output_unit)

contains

  subroutine fail_case(why)
    character(len=*), intent(in) :: why
    write (output_unit, '(A,I0,A,I0,A,A)') &
      'fuzz_ir: FAIL iter=', iter, ' seed=', seed_arg, &
      ' reason: ', why
    write (output_unit, '(A,A)') &
      'fuzz_ir: reproducer file: ', TMPFILE
    write (output_unit, '(A,A)') &
      'fuzz_ir: reader errmsg was: ', trim(errmsg)
    write (output_unit, '(A)') '--- mutant (between markers) ---'
    if (buflen > 0) write (output_unit, '(A)') buf(1:buflen)
    write (output_unit, '(A)') '--- end mutant ---'
    flush (output_unit)
    stop 1
  end subroutine fail_case

  ! Observable bounds invariants of an accepted document.
  subroutine check_accepted()
    integer :: i, j
    if (tl%fps_num <= 0) call fail_case('accepted with fps_num <= 0')
    if (tl%fps_den <= 0) call fail_case('accepted with fps_den <= 0')
    if (tl%duration_frames < 0) &
      call fail_case('accepted with duration_frames < 0')
    do i = 1, tl%n_dialogue
      if (tl%dialogue(i)%end_frame <= tl%dialogue(i)%start_frame) &
        call fail_case('accepted dialogue cue with end <= start')
    end do
    do i = 1, tl%n_scenes
      if (tl%scenes(i)%end_frame > tl%duration_frames) &
        call fail_case('accepted scene span past timeline duration')
      if (tl%scenes(i)%start_frame < 0) &
        call fail_case('accepted scene span with negative start')
    end do
    do i = 1, tl%n_tracks
      do j = 1, tl%tracks(i)%n_keys
        if (tl%tracks(i)%keys(j)%frame < 0) &
          call fail_case('accepted key with negative frame')
      end do
    end do
    do i = 1, tl%n_markers
      if (tl%markers(i)%frame < 0) &
        call fail_case('accepted marker with negative frame')
    end do
  end subroutine check_accepted

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
  ! Seeds: compact but complete Timeline IR documents (shape per
  ! docs/TIMELINE-FORMAT.md / ANIM-PLAN 3.5, mirroring what
  ! f3dc emits for examples/anim-golden.f3d).
  ! ================================================================
  subroutine init_seeds()
    character :: NL
    NL = achar(10)
    seeds(1)%text = &
      '{"format":"forge3d-timeline","ir_version":1,' // &
      '"name":"gate-scene","fps":{"num":24,"den":1},' // &
      '"duration_frames":48,' // &
      '"generator":{"tool":"f3dc","version":"4.0.0",' // &
      '"source":"gate.f3d"},' // &
      '"characters":[' // &
      '{"id":"mira","name":"Mira","color":[90,140,220],' // &
      '"rig":{"kind":"stick","topology":"humanoid11"}},' // &
      '{"id":"finn","name":"Finn","color":[230,170,60],' // &
      '"rig":{"kind":"stick","topology":"humanoid11"}}],' // &
      '"scenes":[{"id":"s1","name":"gate-one",' // &
      '"scene_file":"gate.json","scene_ir_version":1,' // &
      '"start_frame":0,"duration_frames":48,' // &
      '"bindings":{"mira":"mira_body","finn":"finn_body"}}],' // &
      '"tracks":[' // &
      '{"kind":"action","scene":"s1","character":"mira",' // &
      '"action":"wave","start_frame":24,"end_frame":48,' // &
      '"keys":[{"frame":24,"channel":"arm.r.upper",' // &
      '"value_deg":-10.0,"ease":"linear"},' // &
      '{"frame":48,"channel":"arm.r.upper",' // &
      '"value_deg":-10.0,"ease":"smooth"}]},' // &
      '{"kind":"pose_keys","scene":"s1","character":"finn",' // &
      '"keys":[{"frame":0,"pos":[1.5,0,0],' // &
      '"rot_deg":[0,-20,0],"scale":1.0,"ease":"linear"},' // &
      '{"frame":48,"pos":[1.5,0,0],"rot_deg":[0,-35,0],' // &
      '"scale":1.0,"ease":"smooth"}]},' // &
      '{"kind":"camera","scene":"s1","keys":[' // &
      '{"frame":0,"pos":[5,3,7],"target":[0,0,0],"fov":60,' // &
      '"ease":"linear"},' // &
      '{"frame":48,"pos":[3,2,4],"target":[0,0.5,0],' // &
      '"fov":50,"ease":"smooth"}]},' // &
      '{"kind":"verb","scene":"s1","target":"gate",' // &
      '"verb":"spin","start_frame":0,"end_frame":48},' // &
      '{"kind":"visibility","scene":"s1","target":"gate",' // &
      '"visible":true,"start_frame":0,"end_frame":48}],' // &
      '"dialogue":[{"id":"d1","scene":"s1","start_frame":12,' // &
      '"end_frame":48,"speaker":"mira",' // &
      '"text":"Finn -- over here!"}],' // &
      '"markers":[{"frame":24,"name":"the wave","kind":"beat"}]}'

    seeds(2)%text = &
      '{"format":"forge3d-timeline","ir_version":1,' // &
      '"name":"tiny","fps":{"num":24,"den":1},' // &
      '"duration_frames":24,"characters":[],"scenes":[],' // &
      '"tracks":[],"dialogue":[],"markers":[]}'
  end subroutine init_seeds

  subroutine write_temp(b, blen)
    character(len=*), intent(in) :: b
    integer, intent(in) :: blen
    integer :: u, ios
    open (newunit=u, file=TMPFILE, status='replace', &
      action='write', iostat=ios)
    if (ios /= 0) then
      write (output_unit, '(A)') 'fuzz_ir: FATAL: cannot write temp file'
      stop 2
    end if
    if (blen > 0) then
      write (u, '(A)', iostat=ios) b(1:blen)
    else
      write (u, '(A)', iostat=ios) ''
    end if
    close (u)
  end subroutine write_temp

  ! Slice primitives (byte-by-byte shifts; see header traps).
  subroutine insert_slice(pos, src, srclen)
    integer, intent(in) :: pos, srclen
    character(len=*), intent(in) :: src
    integer :: k, take, p
    take = srclen
    if (take <= 0) return
    if (buflen + take > MAXBUF) take = MAXBUF - buflen
    if (take <= 0) return
    p = pos
    if (p < 1) p = 1
    if (p > buflen + 1) p = buflen + 1
    do k = buflen, p, -1
      buf(k + take:k + take) = buf(k:k)
    end do
    do k = 1, take
      buf(p + k - 1:p + k - 1) = src(k:k)
    end do
    buflen = buflen + take
  end subroutine insert_slice

  subroutine delete_slice(pos, count)
    integer, intent(in) :: pos, count
    integer :: k, take, p
    take = count
    if (take <= 0) return
    p = pos
    if (p < 1) p = 1
    if (p > buflen) return
    if (p + take - 1 > buflen) take = buflen - p + 1
    do k = p, buflen - take
      buf(k:k) = buf(k + take:k + take)
    end do
    buflen = buflen - take
  end subroutine delete_slice

  ! Replace the first occurrence of needle with repl; returns
  ! .true. when the needle was found and the swap landed.
  function swap_first(needle, repl) result(done)
    character(len=*), intent(in) :: needle, repl
    logical :: done
    integer :: pos
    done = .false.
    if (buflen < len(needle)) return
    pos = index(buf(1:buflen), needle)
    if (pos <= 0) return
    call delete_slice(pos, len(needle))
    call insert_slice(pos, repl, len(repl))
    done = .true.
  end function swap_first

  ! Token-level mutation over the Timeline IR vocabulary.  Each
  ! branch sets its expectation flag ONLY on a landed swap.
  subroutine mut_token()
    integer :: pick
    logical :: done
    pick = rand_below(10)
    select case (pick)
    case (0)
      done = swap_first('"ir_version":1', '"ir_version":2')
      if (done) exp_bad_version = .true.
    case (1)
      done = swap_first('"ir_version":1', '"ir_version":0')
      if (done) exp_bad_version = .true.
    case (2)
      done = swap_first('"ir_version":1', '"ir_version":"1"')
      if (done) exp_bad_version = .true.
    case (3)
      done = swap_first('"forge3d-timeline"', '"forge3d-timelinf"')
      if (done) exp_bad_format = .true.
    case (4)
      done = swap_first('"num":24', '"num":0')
      if (done) exp_bad_fps = .true.
    case (5)
      done = swap_first('"den":1', '"den":-1')
      if (done) exp_bad_fps = .true.
    case (6)
      done = swap_first('"duration_frames":48', &
        '"duration_frames":-1')
      if (done) exp_bad_duration = .true.
    case (7)
      done = swap_first('"kind":"action"', '"kind":"bogus-kind"')
      if (done) exp_unknown_kind = .true.
    case (8)
      done = swap_first('"ease":"smooth"', '"ease":"smoothe"')
      if (done) exp_unknown_ease = .true.
    case default
      ! Frame-number corruption: no fixed expectation (a huge
      ! duration may still be a legal document) -- the general
      ! accepted-document invariants police this branch.
      done = swap_first('"duration_frames":48', &
        '"duration_frames":999999999')
      done = swap_first('"frame":48', '"frame":-48')
    end select
  end subroutine mut_token

  function random_byte() result(ch)
    character(len=1) :: ch
    integer :: pick, idx
    character(len=26), parameter :: POOL = &
      '0123456789.eE+-"{}[]:,xyz'
    pick = rand_below(100)
    if (pick < 55) then
      ch = achar(32 + rand_below(95))
    else if (pick < 75) then
      idx = 1 + rand_below(len(POOL))
      ch = POOL(idx:idx)
    else if (pick < 85) then
      ch = achar(10)
    else if (pick < 95) then
      ch = achar(rand_below(31) + 1)
    else
      ch = achar(128 + rand_below(128))
    end if
  end function random_byte

  subroutine mut_bytes()
    integer :: op, nops, pos, run, k
    character(len=1) :: ch
    character(len=16) :: junk
    nops = 1 + rand_below(4)
    do op = 1, nops
      if (buflen <= 0) then
        ch = random_byte()
        call insert_slice(1, ch, 1)
        cycle
      end if
      select case (rand_below(6))
      case (0)
        pos = 1 + rand_below(buflen)
        buf(pos:pos) = random_byte()
      case (1)
        pos = 1 + rand_below(buflen + 1)
        ch = random_byte()
        call insert_slice(pos, ch, 1)
      case (2)
        pos = 1 + rand_below(buflen)
        run = 1 + rand_below(min(16, buflen - pos + 1))
        call delete_slice(pos, run)
      case (3)
        pos = 1 + rand_below(buflen)
        ch = buf(pos:pos)
        call insert_slice(pos, ch, 1)
      case (4)
        buflen = rand_below(buflen + 1)
      case default
        run = 1 + rand_below(12)
        junk = ' '
        do k = 1, run
          junk(k:k) = random_byte()
        end do
        pos = 1 + rand_below(buflen + 1)
        call insert_slice(pos, junk, run)
      end select
    end do
  end subroutine mut_bytes

end program fuzz_ir
