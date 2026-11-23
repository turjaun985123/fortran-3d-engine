! property_tests.f90 -- property tests + curated golden set for the
! NATIVE Forge3D compiler (bin/f3dc), v3.0 Phase 6 (finding C3:
! replace the baked 914 KB corpus with property tests + a small
! curated golden set).
!
! Build (from the repo root; same mechanism as
! test_native_compiler.f90 -- black-box, no compiler modules linked):
!   gfortran -O2 -o /tmp/property_tests \
!     tests/native/json_parse.f90 tests/native/property_tests.f90
! Run (from the repo root; the runner cds there):
!   /tmp/property_tests
!
! Environment: F3DC / FORGE3D_ROOT as in test_native_compiler.f90.
! Scratch dirs come from `mktemp -d`, which honours TMPDIR (the
! caller sets TMPDIR; nothing here hardcodes /tmp).
!
! Sections:
!   strict    -- embedded battery of 46 representative sources; for
!                EVERY one: fmt(fmt(x)) == fmt(x) byte-for-byte AND
!                build(x).scene == build(fmt(x)).scene (sha256).
!   sweep     -- the same two properties over EVERY examples/*.f3d
!                file and EVERY corpus.json case whose src parses
!                (`f3dc check` exit 0; srcs extracted with the
!                layer's own json_parse reader).  Against the
!                shipped binary the properties do NOT hold for the
!                full set: `f3dc fmt` prints a desugared form that
!                often does not re-parse (tuple syntax for tube /
!                lathe / extrude paths, unquoted texture paths,
!                rgb(...) tuples, `XxxStmt` fallback lines for
!                morph/keys/filter/shader statements, a duplicated
!                `background` key) and sometimes drops semantics
!                (camera `at`, grid/ring/repeat counts, light
!                positions).  Those cases are classified XFAIL by
!                failure class and RATCHETED: the section fails if
!                the pass count drops or the xfail count grows
!                past the baselines below, so the suite is green
!                today, catches regressions, and tightens itself
!                the moment a compiler fix lands (lower the
!                baselines in the same commit as the fix).
!   codes     -- every diagnostic code found in compiler/src
!                (26 codes: the 22-entry ERROR_CODES table in
!                f3dc_errors.f90 plus W202, W302, W510, W511) has a
!                minimal triggering input asserted here, EXCEPT
!                five codes with no CLI-reachable trigger, listed
!                in the section output with their evidence:
!                E203, E204, W102, W201 (named only in the
!                ERROR_CODES table / section comments; no emission
!                site exists in compiler/src) and W202 (emitted by
!                f3dc_emit_json's warn_w202, but the only call site
!                of emit_json_legacy, f3dc_cli's json_legacy_text,
!                never passes the optional bag, and warn_w202
!                returns immediately when bag is absent).
!   curated   -- tests/native/curated.json (60 cases, corpus.json
!                schema) run through the same capture/artifact
!                comparisons as the corpus section of
!                test_native_compiler.f90.
!   jsondiag  -- `f3dc check --json`: an error case emits exactly
!                one JSON document on stdout (array of records with
!                code/severity/message/file/line/col/span/why/help);
!                a warning-only case emits one JSON document
!                followed by the usual OK line (the document is
!                extracted and parsed separately -- see section).
!
! Every section prints a "SECTION <name>: PASS/FAIL (...)" line;
! the program ends with "PROPERTY RESULT: PASS" or stops 1.

module sha256_mod
  use iso_fortran_env, only: int64
  implicit none
  private
  public :: sha256_hex
  integer(int64), parameter :: M32 = 4294967295_int64
  integer(int64), parameter :: K(64) = [ &
    1116352408_int64, 1899447441_int64, 3049323471_int64, &
    3921009573_int64, 961987163_int64, 1508970993_int64, &
    2453635748_int64, 2870763221_int64, 3624381080_int64, &
    310598401_int64, 607225278_int64, 1426881987_int64, &
    1925078388_int64, 2162078206_int64, 2614888103_int64, &
    3248222580_int64, 3835390401_int64, 4022224774_int64, &
    264347078_int64, 604807628_int64, 770255983_int64, &
    1249150122_int64, 1555081692_int64, 1996064986_int64, &
    2554220882_int64, 2821834349_int64, 2952996808_int64, &
    3210313671_int64, 3336571891_int64, 3584528711_int64, &
    113926993_int64, 338241895_int64, 666307205_int64, &
    773529912_int64, 1294757372_int64, 1396182291_int64, &
    1695183700_int64, 1986661051_int64, 2177026350_int64, &
    2456956037_int64, 2730485921_int64, 2820302411_int64, &
    3259730800_int64, 3345764771_int64, 3516065817_int64, &
    3600352804_int64, 4094571909_int64, 275423344_int64, &
    430227734_int64, 506948616_int64, 659060556_int64, &
    883997877_int64, 958139571_int64, 1322822218_int64, &
    1537002063_int64, 1747873779_int64, 1955562222_int64, &
    2024104815_int64, 2227730452_int64, 2361852424_int64, &
    2428436474_int64, 2756734187_int64, 3204031479_int64, &
    3329325298_int64]
contains
  pure function rotr(x, n) result(r)
    integer(int64), intent(in) :: x
    integer, intent(in) :: n
    integer(int64) :: r
    r = iand(ior(ishft(x, -n), ishft(x, 32 - n)), M32)
  end function rotr

  subroutine sha256_hex(data, hex)
    character(len=*), intent(in) :: data
    character(len=64), intent(out) :: hex
    integer(int64) :: h(8), w(64), a, b, c, d, e, f, g, hh
    integer(int64) :: s0, s1, ch, maj, t1, t2, sg0, sg1
    integer, allocatable :: msg(:)
    integer :: L, total, blk, i, j, byte
    character(len=16), parameter :: HD = '0123456789abcdef'

    h = [1779033703_int64, 3144134277_int64, 1013904242_int64, &
         2773480762_int64, 1359893119_int64, 2600822924_int64, &
         528734635_int64, 1541459225_int64]
    L = len(data)
    total = ((L + 9 + 63) / 64) * 64
    allocate(msg(total))
    msg = 0
    do i = 1, L
      msg(i) = iachar(data(i:i))
    end do
    msg(L + 1) = 128
    do i = 0, 7
      msg(total - i) = int(mod(int(L, int64) * 8_int64 / &
        256_int64**i, 256_int64))
    end do

    do blk = 0, total / 64 - 1
      do i = 1, 16
        j = blk * 64 + (i - 1) * 4
        w(i) = int(msg(j + 1), int64) * 16777216_int64 + &
               int(msg(j + 2), int64) * 65536_int64 + &
               int(msg(j + 3), int64) * 256_int64 + &
               int(msg(j + 4), int64)
      end do
      do i = 17, 64
        sg0 = ieor(ieor(rotr(w(i - 15), 7), rotr(w(i - 15), 18)), &
                   ishft(w(i - 15), -3))
        sg1 = ieor(ieor(rotr(w(i - 2), 17), rotr(w(i - 2), 19)), &
                   ishft(w(i - 2), -10))
        w(i) = iand(w(i - 16) + sg0 + w(i - 7) + sg1, M32)
      end do
      a = h(1); b = h(2); c = h(3); d = h(4)
      e = h(5); f = h(6); g = h(7); hh = h(8)
      do i = 1, 64
        s1 = ieor(ieor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
        ch = ieor(iand(e, f), iand(not(e), g))
        t1 = iand(hh + s1 + ch + K(i) + w(i), M32)
        s0 = ieor(ieor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
        maj = ieor(ieor(iand(a, b), iand(a, c)), iand(b, c))
        t2 = iand(s0 + maj, M32)
        hh = g; g = f; f = e
        e = iand(d + t1, M32)
        d = c; c = b; b = a
        a = iand(t1 + t2, M32)
      end do
      h(1) = iand(h(1) + a, M32); h(2) = iand(h(2) + b, M32)
      h(3) = iand(h(3) + c, M32); h(4) = iand(h(4) + d, M32)
      h(5) = iand(h(5) + e, M32); h(6) = iand(h(6) + f, M32)
      h(7) = iand(h(7) + g, M32); h(8) = iand(h(8) + hh, M32)
    end do
    deallocate(msg)

    hex = ''
    do i = 1, 8
      do j = 7, 0, -1
        byte = int(mod(ishft(h(i), -4 * j), 16_int64))
        hex((i - 1) * 8 + (8 - j):(i - 1) * 8 + (8 - j)) = HD(byte + 1:byte + 1)
      end do
    end do
  end subroutine sha256_hex
end module sha256_mod

! ===============================================================
program property_tests
  use iso_fortran_env, only: int64
  use json_parse
  use sha256_mod
  implicit none

  character(len=:), allocatable :: repo, f3dc, scratch
  integer :: total_fails = 0
  integer :: print_budget = 8

  call setup_paths()
  call selftest_sha()
  call section_strict()
  call section_sweep()
  call section_codes()
  call section_curated()
  call section_jsondiag()

  if (total_fails == 0) then
    write(*, '(A)') 'PROPERTY RESULT: PASS'
  else
    write(*, '(A)') 'PROPERTY RESULT: FAIL'
    stop 1
  end if

contains

  ! -------------------------------------------------------------
  ! Setup / generic helpers (mirrors test_native_compiler.f90)
  ! -------------------------------------------------------------
  subroutine setup_paths()
    character(len=4096) :: buf
    integer :: n, ios
    logical :: ex
    call get_environment_variable('FORGE3D_ROOT', buf, length=n, &
                                  status=ios)
    if (ios == 0 .and. n > 0) then
      allocate(character(len=n) :: repo)
      repo = buf(1:n)
    else
      call getcwd(buf, ios)
      if (ios /= 0) then
        write(*, '(A)') 'FATAL: cannot determine repo root (getcwd)'
        stop 1
      end if
      n = len_trim(buf)
      allocate(character(len=n) :: repo)
      repo = buf(1:n)
    end if
    call get_environment_variable('F3DC', buf, length=n, status=ios)
    if (ios == 0 .and. n > 0) then
      allocate(character(len=n) :: f3dc)
      f3dc = buf(1:n)
    else
      inquire(file=repo // '/bin/f3dc', exist=ex)
      if (ex) then
        f3dc = repo // '/bin/f3dc'
      else
        f3dc = repo // '/compiler/f3dc'
      end if
    end if
    inquire(file=f3dc, exist=ex)
    if (.not. ex) then
      write(*, '(A)') 'FATAL: native compiler not built: ' // f3dc
      stop 1
    end if
    call make_temp_dir(scratch)
    write(*, '(A)') 'f3dc under test: ' // f3dc
    write(*, '(A)') 'repo root: ' // repo
  end subroutine setup_paths

  subroutine selftest_sha()
    character(len=64) :: hex
    call sha256_hex('', hex)
    if (hex /= 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') then
      write(*, '(A)') 'FATAL: internal SHA-256 failed empty vector'
      stop 1
    end if
    call sha256_hex('abc', hex)
    if (hex /= 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') then
      write(*, '(A)') 'FATAL: internal SHA-256 failed "abc" vector'
      stop 1
    end if
  end subroutine selftest_sha

  subroutine sh(cmd, rc)
    character(len=*), intent(in) :: cmd
    integer, intent(out) :: rc
    call execute_command_line(cmd, exitstat=rc)
  end subroutine sh

  subroutine make_temp_dir(dir)
    character(len=:), allocatable, intent(out) :: dir
    character(len=:), allocatable :: cap
    integer :: rc
    if (allocated(scratch)) then
      cap = scratch // '/mktemp.out'
    else
      ! mktemp honours TMPDIR; the capture file lands in a fresh
      ! sibling once scratch exists -- bootstrap via mktemp's own
      ! stdout through a file in the current (repo) dir is avoided:
      ! use a named pipe-free approach: capture into TMPDIR file.
      block
        character(len=4096) :: td
        integer :: tn, tios
        call get_environment_variable('TMPDIR', td, length=tn, &
                                      status=tios)
        if (tios == 0 .and. tn > 0) then
          cap = td(1:tn) // '/mktemp.out'
        else
          cap = './mktemp.out'
        end if
      end block
    end if
    call execute_command_line("mktemp -d > '" // cap // "'", &
                              exitstat=rc)
    if (rc /= 0) then
      write(*, '(A)') 'FATAL: mktemp -d failed'
      stop 1
    end if
    call read_all(cap, dir, rc)
    if (rc /= 0) then
      write(*, '(A)') 'FATAL: cannot read mktemp output'
      stop 1
    end if
    do while (len(dir) > 0)
      if (dir(len(dir):len(dir)) == char(10) .or. &
          dir(len(dir):len(dir)) == char(13)) then
        dir = dir(1:len(dir) - 1)
      else
        exit
      end if
    end do
  end subroutine make_temp_dir

  subroutine read_all(path, buf, rc)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: buf
    integer, intent(out) :: rc
    integer :: u, ios
    integer(int64) :: sz
    logical :: ex
    rc = 0
    inquire(file=path, exist=ex, size=sz)
    if (.not. ex) then
      allocate(character(len=0) :: buf)
      rc = 1
      return
    end if
    allocate(character(len=int(max(sz, 0_int64))) :: buf)
    open(newunit=u, file=path, access='stream', form='unformatted', &
         status='old', iostat=ios)
    if (ios /= 0) then
      rc = 1
      return
    end if
    if (sz > 0) read(u) buf
    close(u)
  end subroutine read_all

  subroutine write_all(path, data)
    character(len=*), intent(in) :: path, data
    integer :: u, ios
    open(newunit=u, file=path, access='stream', form='unformatted', &
         status='replace', iostat=ios)
    if (ios /= 0) then
      write(*, '(A)') 'FATAL: cannot write ' // path
      stop 1
    end if
    if (len(data) > 0) write(u) data
    close(u)
  end subroutine write_all

  subroutine read_json_file(path, root, ok)
    character(len=*), intent(in) :: path
    integer, intent(out) :: root
    logical, intent(out) :: ok
    character(len=:), allocatable :: text
    integer :: rc
    call read_all(path, text, rc)
    if (rc /= 0) then
      ok = .false.
      root = 0
      return
    end if
    call json_parse_text(text, root, ok)
  end subroutine read_json_file

  subroutine run_f3dc(argv_str, cwd, rc, out_s, err_s)
    character(len=*), intent(in) :: argv_str, cwd
    integer, intent(out) :: rc
    character(len=:), allocatable, intent(out) :: out_s, err_s
    character(len=:), allocatable :: cmd
    integer :: drc
    cmd = "cd '" // cwd // "' && '" // f3dc // "' " // argv_str // &
          " > '" // scratch // "/run.out' 2> '" // scratch // &
          "/run.err'"
    call execute_command_line(cmd, exitstat=rc)
    call read_all(scratch // '/run.out', out_s, drc)
    call read_all(scratch // '/run.err', err_s, drc)
  end subroutine run_f3dc

  subroutine note_fail(label, detail)
    character(len=*), intent(in) :: label, detail
    if (print_budget > 0) then
      print_budget = print_budget - 1
      write(*, '(A)') '  FAIL ' // label // ': ' // detail
    end if
  end subroutine note_fail

  function itoa(v) result(s)
    integer, intent(in) :: v
    character(len=:), allocatable :: s
    character(len=32) :: buf
    write(buf, '(I0)') v
    s = trim(buf)
  end function itoa

  subroutine extract_codes(data, joined)
    character(len=*), intent(in) :: data
    character(len=:), allocatable, intent(out) :: joined
    integer :: i, L
    logical :: first
    allocate(character(len=0) :: joined)
    first = .true.
    L = len(data)
    i = 1
    do while (i + 3 <= L)
      if ((data(i:i) == 'E' .or. data(i:i) == 'W') .and. &
          data(i + 1:i + 1) >= '0' .and. data(i + 1:i + 1) <= '9' .and. &
          data(i + 2:i + 2) >= '0' .and. data(i + 2:i + 2) <= '9' .and. &
          data(i + 3:i + 3) >= '0' .and. data(i + 3:i + 3) <= '9') then
        if (.not. first) joined = joined // ','
        joined = joined // data(i:i + 3)
        first = .false.
        i = i + 4
      else
        i = i + 1
      end if
    end do
  end subroutine extract_codes

  logical function has_code(data, code)
    character(len=*), intent(in) :: data, code
    has_code = index(data, code) > 0
  end function has_code

  ! -------------------------------------------------------------
  ! Round-trip classification for one source text.
  !   cls = 0  full pass (fmt idempotent + .scene identical)
  !   cls = 1  fmt output does not re-parse (fmt2 exit /= 0)
  !   cls = 2  fmt output re-parses but differs (not idempotent)
  !   cls = 3  fmt stable but build semantics differ (build exit
  !            differs, scene.scene missing, or .scene hash differs)
  !   cls = 9  fmt itself failed on a parsing source (hard failure)
  ! -------------------------------------------------------------
  subroutine classify(src, work, cls)
    character(len=*), intent(in) :: src, work
    integer, intent(out) :: cls
    integer :: rc, drc
    character(len=:), allocatable :: out_s, err_s, f1, f2
    character(len=:), allocatable :: s1, s2
    character(len=64) :: h1, h2
    logical :: ex
    call sh("mkdir -p '" // work // "/a' '" // work // "/b'", rc)
    call write_all(work // '/a/scene.f3d', src)
    call run_f3dc('fmt scene.f3d', work // '/a', rc, f1, err_s)
    if (rc /= 0) then
      cls = 9
      return
    end if
    call write_all(work // '/b/scene.f3d', f1)
    call run_f3dc('fmt scene.f3d', work // '/b', rc, f2, err_s)
    if (rc /= 0) then
      cls = 1
      return
    end if
    if (f2 /= f1) then
      cls = 2
      return
    end if
    call run_f3dc('build -o out scene.f3d', work // '/a', rc, &
                  out_s, err_s)
    if (rc /= 0) then
      cls = 3
      return
    end if
    call run_f3dc('build -o out scene.f3d', work // '/b', rc, &
                  out_s, err_s)
    if (rc /= 0) then
      cls = 3
      return
    end if
    inquire(file=work // '/a/out/scene.scene', exist=ex)
    if (.not. ex) then
      cls = 3
      return
    end if
    inquire(file=work // '/b/out/scene.scene', exist=ex)
    if (.not. ex) then
      cls = 3
      return
    end if
    call read_all(work // '/a/out/scene.scene', s1, drc)
    call read_all(work // '/b/out/scene.scene', s2, drc)
    call sha256_hex(s1, h1)
    call sha256_hex(s2, h2)
    if (h1 /= h2) then
      cls = 3
      return
    end if
    cls = 0
  end subroutine classify

  ! -------------------------------------------------------------
  ! SECTION strict: embedded representative battery (46 sources).
  ! Every one must FULLY pass both properties -- no xfail allowed.
  ! -------------------------------------------------------------
  subroutine section_strict()
    integer, parameter :: N = 46
    character(len=:), allocatable :: srcs(:)
    character(len=1) :: nl
    integer :: i, cls, fails
    character(len=:), allocatable :: work
    allocate(character(len=96) :: srcs(N))
    nl = char(10)
    srcs(1) = 'cube red' // nl
    srcs(2) = 'sphere blue' // nl
    srcs(3) = 'cone orange' // nl
    srcs(4) = 'cylinder green' // nl
    srcs(5) = 'plane white' // nl
    srcs(6) = 'pyramid yellow' // nl
    srcs(7) = 'torus purple' // nl
    srcs(8) = 'capsule red' // nl
    srcs(9) = 'circle red' // nl
    srcs(10) = 'icosahedron red' // nl
    srcs(11) = 'torusknot red' // nl
    srcs(12) = 'cube hero red at 1 2 3' // nl
    srcs(13) = 'cube red size 2' // nl
    srcs(14) = 'sphere blue radius 2' // nl
    srcs(15) = 'scene size 320x240' // nl // 'cube red' // nl
    srcs(16) = 'camera look 0 0 0' // nl // 'cube red' // nl
    srcs(17) = 'camera fov 45' // nl // 'cube red' // nl
    srcs(18) = 'light dir 1 0 0' // nl // 'cube red' // nl
    srcs(19) = 'cube red' // nl // 'spin it' // nl
    srcs(20) = 'cube red' // nl // 'render' // nl
    srcs(21) = 'cube red material phong' // nl
    srcs(22) = 'cube red material standard' // nl
    srcs(23) = 'sphere green at -1 0 0' // nl
    srcs(24) = 'cube red' // nl // 'sphere blue' // nl
    srcs(25) = 'cube red rotate 0 45 0' // nl
    srcs(26) = 'cube red scale 2 1 1' // nl
    srcs(27) = 'cone orange height 3' // nl
    srcs(28) = nl
    srcs(29) = '# hi' // nl // 'cube red' // nl
    srcs(30) = 'cube red at 0.1 0.25 -3.5' // nl
    srcs(31) = 'cube red size 1.5' // nl
    srcs(32) = 'sphere blue at -2 -1 -3' // nl
    srcs(33) = 'cube red' // nl // 'spin it speed 2' // nl
    srcs(34) = 'group duo' // nl // 'end' // nl // 'cube red' // nl
    srcs(35) = 'cube red' // nl // 'spin it' // nl // 'render' // nl
    srcs(36) = 'cube red wireframe' // nl
    srcs(37) = 'cube red material standard metalness 0.8 ' // &
               'roughness 0.2' // nl
    srcs(38) = 'sphere blue detail high' // nl
    srcs(39) = 'cylinder green segments 8' // nl
    srcs(40) = 'light intensity 2' // nl // 'cube red' // nl
    srcs(41) = 'camera near 0.5 far 50' // nl // 'cube red' // nl
    srcs(42) = 'light dir 1 0 0' // nl // 'light dir 0 1 0' // nl // &
               'cube red' // nl
    srcs(43) = 'torus purple radius 2 tube 0.5' // nl
    srcs(44) = 'camera fov 45.5' // nl // 'cube red' // nl
    srcs(45) = 'cube red at 0.0001 0 0' // nl
    srcs(46) = 'cube red' // nl // 'spin it axis y' // nl

    fails = 0
    print_budget = 8
    call make_temp_dir(work)
    do i = 1, N
      call classify(trim(srcs(i)), work // '/w', cls)
      if (cls /= 0) then
        fails = fails + 1
        call note_fail('strict[' // itoa(i) // ']', &
                       'round-trip class ' // itoa(cls))
      end if
      call sh("rm -rf '" // work // "/w'", cls)
    end do
    if (fails == 0) then
      write(*, '(A,I0,A)') 'SECTION strict: PASS (', N, &
        ' sources: fmt idempotent + build .scene stable)'
    else
      write(*, '(A,I0,A,I0,A)') 'SECTION strict: FAIL (', fails, &
        ' of ', N, ' sources)'
      total_fails = total_fails + fails
    end if
  end subroutine section_strict

  ! -------------------------------------------------------------
  ! SECTION sweep: all examples + all parsing corpus sources,
  ! with the xfail ratchet described in the file header.
  ! Baselines vs the shipped bin/f3dc (2026-11-23, pre-fmt-fix):
  !   examples: 15 files, 1 full pass, 14 xfail (all class 1)
  !   corpus:   91 parsing sources, 39 full pass, 52 xfail
  !             (42 class 1, 0 class 2, 10 class 3)
  ! Tightened 2026-11-23 after the fmt round-trip fix (Phase 6):
  !   examples: 11 full pass, 4 xfail (all class 3, structural:
  !             the originals reference assets by relative path or
  !             are multi-scene, so classify() cannot see a clean
  !             isolated build; all 4 verified fmt-idempotent with
  !             byte-identical artifacts in a real examples tree)
  !   corpus:   91 parsing sources, 91 full pass, 0 xfail
  ! -------------------------------------------------------------
  subroutine section_sweep()
    integer, parameter :: EX_PASS_MIN = 11, EX_XFAIL_MAX = 4
    integer, parameter :: CO_PASS_MIN = 91, CO_XFAIL_MAX = 0
    integer :: fails, rc, i, cc, cls
    integer :: ex_n, ex_pass, ex_x(3), co_n, co_pass, co_x(3)
    integer :: root, cases_node, node, src_node
    logical :: ok
    character(len=:), allocatable :: work, listing, name, src
    character(len=:), allocatable :: out_s, err_s, path
    integer :: start, llen, p
    fails = 0
    print_budget = 8
    ex_n = 0; ex_pass = 0; ex_x = 0
    co_n = 0; co_pass = 0; co_x = 0
    call make_temp_dir(work)

    ! --- examples/*.f3d (listed with find, sorted) ---
    call sh("find '" // repo // "/examples' -maxdepth 1 " // &
            "-name '*.f3d' | LC_ALL=C sort > '" // scratch // &
            "/exlist.txt'", rc)
    call read_all(scratch // '/exlist.txt', listing, rc)
    llen = len(listing)
    start = 1
    do p = 1, llen
      if (listing(p:p) == char(10)) then
        if (p > start) then
          path = listing(start:p - 1)
          call read_all(path, src, rc)
          ex_n = ex_n + 1
          call classify(src, work // '/w', cls)
          call sh("rm -rf '" // work // "/w'", rc)
          select case (cls)
          case (0)
            ex_pass = ex_pass + 1
          case (1, 2, 3)
            ex_x(cls) = ex_x(cls) + 1
          case default
            fails = fails + 1
            call note_fail('sweep example ' // path, &
                           'fmt failed on a parsing source')
          end select
        end if
        start = p + 1
      end if
    end do

    ! --- corpus.json srcs that parse (check exit 0) ---
    call read_json_file(repo // '/tests/native/corpus.json', &
                        root, ok)
    if (.not. ok) then
      write(*, '(A)') 'SECTION sweep: FAIL (corpus.json parse error)'
      total_fails = total_fails + 1
      return
    end if
    call json_get(root, 'cases', cases_node)
    cc = json_child_count(cases_node)
    do i = 1, cc
      node = json_child_at(cases_node, i)
      call json_get(node, 'src', src_node)
      call json_as_string(src_node, src)
      call sh("mkdir -p '" // work // "/chk'", rc)
      call write_all(work // '/chk/scene.f3d', src)
      call run_f3dc('check scene.f3d', work // '/chk', rc, &
                    out_s, err_s)
      if (rc /= 0) cycle
      co_n = co_n + 1
      call classify(src, work // '/w', cls)
      call sh("rm -rf '" // work // "/w'", rc)
      select case (cls)
      case (0)
        co_pass = co_pass + 1
      case (1, 2, 3)
        co_x(cls) = co_x(cls) + 1
      case default
        fails = fails + 1
        call note_fail('sweep corpus[' // itoa(i - 1) // ']', &
                       'fmt failed on a parsing source')
      end select
    end do

    write(*, '(A,I0,A,I0,A,I0,A,I0,A,I0,A,I0,A)') &
      '  sweep examples: ', ex_n, ' files, pass ', ex_pass, &
      ', xfail class1/2/3 = ', ex_x(1), '/', ex_x(2), '/', ex_x(3)
    write(*, '(A,I0,A,I0,A,I0,A,I0,A,I0,A,I0,A)') &
      '  sweep corpus: ', co_n, ' parsing sources, pass ', co_pass, &
      ', xfail class1/2/3 = ', co_x(1), '/', co_x(2), '/', co_x(3)
    if (ex_n /= 15) fails = fails + 1
    if (ex_pass < EX_PASS_MIN) fails = fails + 1
    if (sum(ex_x) > EX_XFAIL_MAX) fails = fails + 1
    if (co_n < 90) fails = fails + 1
    if (co_pass < CO_PASS_MIN) fails = fails + 1
    if (sum(co_x) > CO_XFAIL_MAX) fails = fails + 1
    if (fails == 0) then
      write(*, '(A,I0,A)') 'SECTION sweep: PASS (', &
        ex_pass + co_pass, ' full round-trips; xfail ratchet held)'
    else
      write(*, '(A,I0,A)') 'SECTION sweep: FAIL (', fails, &
        ' ratchet violations)'
      total_fails = total_fails + fails
    end if
  end subroutine section_sweep

  ! -------------------------------------------------------------
  ! SECTION codes: minimal trigger per diagnostic code.
  ! Census (grep compiler/src, 2026-11-23): 26 distinct codes --
  ! the 22 in f3dc_errors' ERROR_CODES table plus W202
  ! (f3dc_emit_json), W302 (f3dc_ext_cameras), W510/W511
  ! (f3dc_optimize).  21 are triggered below; 5 have no
  ! CLI-reachable trigger (listed in the output, evidence in the
  ! file header): E203, E204, W102, W201, W202.
  ! -------------------------------------------------------------
  subroutine section_codes()
    integer :: fails, rc
    character(len=:), allocatable :: work, out_s, err_s, jbase, jobj
    character(len=1) :: nl
    fails = 0
    print_budget = 8
    nl = char(10)
    call make_temp_dir(work)

    call code_case(work, 'E101', ';' // nl, fails)
    call code_case(work, 'E102', 'cube red at x 0 0' // nl, fails)
    call code_case(work, 'E103', '1,2' // nl, fails)
    call code_case(work, 'E104', 'x y' // nl, fails)
    call code_case(work, 'E110', &
                   'cube red at 0 0 0 at 1 1 1' // nl, fails)
    call code_case(work, 'E201', 'skin hero arm' // nl, fails)
    call code_case(work, 'E202', 'cube gold' // nl, fails)
    call code_case(work, 'E205', &
                   'cube red material nosuchmat' // nl, fails)
    call code_case(work, 'E301', 'tube red' // nl, fails)
    call code_case(work, 'E302', 'light spot' // nl // &
                   'cube red' // nl, fails)
    call code_case(work, 'E303', 'cube red' // nl // &
                   'spin it speed 99999' // nl, fails)
    call code_case(work, 'E401', 'group outer' // nl // &
                   'group inner' // nl // 'cube red' // nl // &
                   'end' // nl // 'end' // nl, fails)
    call code_case(work, 'E402', 'light spot' // nl, fails)
    call code_case(work, 'E501', &
                   'load "definitely_missing.obj"' // nl, fails)
    call code_case(work, 'E820', '#' // repeat('x', 4999) // nl // &
                   'cube red' // nl, fails)
    call code_case(work, 'W101', nl, fails)
    call code_case(work, 'W302', &
                   'camera ortho at 0 0 0 look 0 0 0' // nl // &
                   'cube red' // nl, fails)

    ! E502: build into a path blocked by a regular file.
    call write_all(work // '/blocker', 'x')
    call write_all(work // '/s.f3d', 'cube red' // nl)
    call run_f3dc('build -o blocker/out s.f3d', work, rc, &
                  out_s, err_s)
    if (.not. has_code(err_s // out_s, 'E502')) then
      fails = fails + 1
      call note_fail('codes E502', 'build-blocked case did not emit')
    end if

    ! E504: two-file import cycle.
    call write_all(work // '/a.f3d', &
                   'import "b.f3d" as b' // nl // 'cube red' // nl)
    call write_all(work // '/b.f3d', &
                   'import "a.f3d" as a' // nl // 'sphere blue' // nl)
    call run_f3dc('check a.f3d', work, rc, out_s, err_s)
    if (.not. has_code(err_s // out_s, 'E504')) then
      fails = fails + 1
      call note_fail('codes E504', 'import cycle did not emit')
    end if

    ! W510 / W511: via a minimal v2 scene JSON (the .f3d validator
    ! rejects these shapes earlier with E301, so the optimizer
    ! warnings are only reachable through the JSON input path).
    jbase = '{"format":"forge3d-scene","ir_version":1,' // &
            '"name":"t","width":64,"height":64,"bg":[0,0,0],' // &
            '"camera":{"pos":[3,2.5,4],"target":[0,0,0],' // &
            '"up":[0,1,0],"fov":60,"near":0.1,"far":100},' // &
            '"lights":[{"kind":"directional",' // &
            '"direction":[-0.5,-1,-0.7],"intensity":1.0,' // &
            '"color":[255,255,255]}],"objects":['
    jobj = jbase // '{"name":"c1","prim":"cube",' // &
           '"color":[255,0,0],"pos":[0,0,0],' // &
           '"scale":[0,1,1]}],"animations":[]}'
    call write_all(work // '/v.json', jobj)
    call run_f3dc('build -o o1 v.json', work, rc, out_s, err_s)
    if (.not. has_code(err_s // out_s, 'W510')) then
      fails = fails + 1
      call note_fail('codes W510', 'zero-scale JSON case did not emit')
    end if
    jobj = jbase // '{"name":"t1","prim":"tris",' // &
           '"color":[255,0,0],' // &
           '"triangles":[[[0,0,0],[0,0,0],[1,0,0]]]}],' // &
           '"animations":[]}'
    call write_all(work // '/v.json', jobj)
    call run_f3dc('build -o o2 v.json', work, rc, out_s, err_s)
    if (.not. has_code(err_s // out_s, 'W511')) then
      fails = fails + 1
      call note_fail('codes W511', &
                     'degenerate-tris JSON case did not emit')
    end if

    write(*, '(A)') '  codes with no CLI-reachable trigger ' // &
      '(evidence in file header): E203, E204, W102, W201, W202'
    if (fails == 0) then
      write(*, '(A)') 'SECTION codes: PASS (21 of 26 codes ' // &
        'triggered by minimal inputs; 5 unreachable, documented)'
    else
      write(*, '(A,I0,A)') 'SECTION codes: FAIL (', fails, &
        ' code cases)'
      total_fails = total_fails + fails
    end if

  end subroutine section_codes

  subroutine code_case(wdir, code, src, fails)
    character(len=*), intent(in) :: wdir, code, src
    integer, intent(inout) :: fails
    integer :: crc
    character(len=:), allocatable :: o, e
    call write_all(wdir // '/s.f3d', src)
    call run_f3dc('check s.f3d', wdir, crc, o, e)
    if (.not. has_code(e // o, code)) then
      fails = fails + 1
      call note_fail('codes ' // code, &
                     'minimal input did not emit the code')
    end if
  end subroutine code_case

  ! -------------------------------------------------------------
  ! SECTION curated: run tests/native/curated.json through the
  ! same comparisons the corpus section of
  ! test_native_compiler.f90 applies to corpus.json (check capture
  ! sha256 + codes; build artifact sha256 set).
  ! -------------------------------------------------------------
  subroutine section_curated()
    integer :: root, cases_node, kept_node, fails, i, cc, node, brc
    logical :: ok
    character(len=:), allocatable :: work, src, out_s, err_s
    character(len=:), allocatable :: bout, berr
    integer :: check_node, build_node, art_node, hashes
    fails = 0
    hashes = 0
    print_budget = 8
    call read_json_file(repo // '/tests/native/curated.json', &
                        root, ok)
    if (.not. ok) then
      write(*, '(A)') 'SECTION curated: FAIL (curated.json parse)'
      total_fails = total_fails + 1
      return
    end if
    call json_get(root, 'cases', cases_node)
    call json_get(root, 'kept', kept_node)
    cc = json_child_count(cases_node)
    if (cc /= int(json_as_int(kept_node))) then
      fails = fails + 1
      call note_fail('curated', 'case count != kept')
    end if
    call make_temp_dir(work)
    do i = 1, cc
      node = json_child_at(cases_node, i)
      call json_get(node, 'src', check_node)
      call json_as_string(check_node, src)
      call write_all(work // '/scene.f3d', src)
      call run_f3dc('check scene.f3d', work, brc, out_s, err_s)
      call json_get(node, 'check', check_node)
      call check_capture(check_node, brc, out_s, err_s, &
                         'curated[' // itoa(i - 1) // '] check', &
                         fails)
      if (json_has(node, 'build')) then
        call sh("rm -rf '" // work // "/out'", brc)
        call run_f3dc('build -o out scene.f3d', work, brc, &
                      bout, berr)
        if (brc /= 0) then
          fails = fails + 1
          call note_fail('curated[' // itoa(i - 1) // '] build', &
                         'nonzero build exit')
        else
          call json_get(node, 'build', build_node)
          call json_get(build_node, 'artifacts', art_node)
          call check_artifacts(work // '/out', art_node, &
            'curated[' // itoa(i - 1) // '] build', fails, hashes)
        end if
      end if
    end do
    if (fails == 0) then
      write(*, '(A,I0,A,I0,A)') 'SECTION curated: PASS (', cc, &
        ' cases, ', hashes, ' artifact hashes)'
    else
      write(*, '(A,I0,A,I0,A)') 'SECTION curated: FAIL (', fails, &
        ' failures in ', cc, ' cases)'
      total_fails = total_fails + fails
    end if
  end subroutine section_curated

  subroutine check_capture(exp, rc, out_s, err_s, label, fails)
    integer, intent(in) :: exp, rc
    character(len=*), intent(in) :: out_s, err_s, label
    integer, intent(inout) :: fails
    integer :: node
    character(len=:), allocatable :: exp_s, got_codes, exp_codes, tmp
    character(len=64) :: hex
    logical :: bad
    integer :: i, cc
    bad = .false.
    call json_get(exp, 'exit', node)
    if (int(json_as_int(node)) /= rc) bad = .true.
    call sha256_hex(out_s, hex)
    call json_get(exp, 'stdout_sha256', node)
    call json_as_string(node, exp_s)
    if (hex /= exp_s) bad = .true.
    call sha256_hex(err_s, hex)
    call json_get(exp, 'stderr_sha256', node)
    call json_as_string(node, exp_s)
    if (hex /= exp_s) bad = .true.
    call extract_codes(err_s, got_codes)
    call json_get(exp, 'codes', node)
    cc = json_child_count(node)
    allocate(character(len=0) :: exp_codes)
    do i = 1, cc
      call json_as_string(json_child_at(node, i), tmp)
      if (i > 1) exp_codes = exp_codes // ','
      exp_codes = exp_codes // tmp
    end do
    if (got_codes /= exp_codes) bad = .true.
    if (bad) then
      fails = fails + 1
      call note_fail(label, 'capture mismatch (exit/stdout/stderr/codes)')
    end if
  end subroutine check_capture

  subroutine list_files(dir, rels, n)
    character(len=*), intent(in) :: dir
    character(len=1024), allocatable, intent(out) :: rels(:)
    integer, intent(out) :: n
    character(len=:), allocatable :: cmd, listing
    integer :: rc, i, start, cnt, llen
    cmd = "find '" // dir // "' -type f | LC_ALL=C sort > '" // &
          scratch // "/list.txt'"
    call execute_command_line(cmd, exitstat=rc)
    call read_all(scratch // '/list.txt', listing, rc)
    n = 0
    if (len(listing) == 0) then
      allocate(rels(0))
      return
    end if
    cnt = 0
    do i = 1, len(listing)
      if (listing(i:i) == char(10)) cnt = cnt + 1
    end do
    allocate(rels(max(cnt, 1)))
    start = 1
    llen = len(listing)
    do i = 1, llen
      if (listing(i:i) == char(10)) then
        if (i > start) then
          n = n + 1
          rels(n) = listing(start + len(dir) + 1:i - 1)
        end if
        start = i + 1
      end if
    end do
  end subroutine list_files

  subroutine check_artifacts(dir, exp_artifacts, label, fails, &
                             hash_counter)
    character(len=*), intent(in) :: dir, label
    integer, intent(in) :: exp_artifacts
    integer, intent(inout) :: fails, hash_counter
    character(len=1024), allocatable :: rels(:)
    character(len=:), allocatable :: data, exp_s, rel
    integer :: n, i, node
    character(len=64) :: hex
    logical :: bad
    call list_files(dir, rels, n)
    ! v3.0 Phase 6 (C5): exclude the compiler's incremental-build
    ! manifest (.f3dc-manifest-<stem>) -- driver bookkeeping in
    ! the output directory, not a build artifact (mirrors the
    ! same exclusion in test_native_compiler.f90).
    block
      integer :: m, j
      m = 0
      do j = 1, n
        if (index(trim(rels(j)), '.f3dc-manifest-') == 1) cycle
        m = m + 1
        rels(m) = rels(j)
      end do
      n = m
    end block
    bad = .false.
    if (n /= json_child_count(exp_artifacts)) bad = .true.
    do i = 1, n
      rel = trim(rels(i))
      call json_get(exp_artifacts, rel, node)
      if (node == 0) then
        bad = .true.
        cycle
      end if
      call json_as_string(node, exp_s)
      call read_all(dir // '/' // rel, data, node)
      call sha256_hex(data, hex)
      hash_counter = hash_counter + 1
      if (hex /= exp_s) bad = .true.
    end do
    if (bad) then
      fails = fails + 1
      call note_fail(label, 'artifact set/hash mismatch')
    end if
  end subroutine check_artifacts

  ! -------------------------------------------------------------
  ! SECTION jsondiag: `f3dc check --json` diagnostics.
  ! Error case: stdout is EXACTLY one JSON document (a top-level
  ! array of diagnostic records), stderr empty, exit 1.
  ! Warning-only case: stdout is one JSON document followed by the
  ! usual "OK: ..." line (the CLI prints the OK summary after the
  ! diagnostics in text and JSON mode alike); the document is cut
  ! at its closing bracket line, parsed with json_parse, and its
  ! records checked for code/severity/message/span fields.
  ! -------------------------------------------------------------
  subroutine section_jsondiag()
    integer :: fails, rc, root, node, rec, span_node
    logical :: ok
    character(len=:), allocatable :: work, out_s, err_s, doc, s
    character(len=1) :: nl
    fails = 0
    print_budget = 8
    nl = char(10)
    call make_temp_dir(work)

    ! --- error case ---
    call write_all(work // '/err.f3d', 'cubee red' // nl // &
                   'render' // nl)
    call run_f3dc('check --json err.f3d', work, rc, out_s, err_s)
    if (rc /= 1) fails = fails + 1
    if (len(err_s) /= 0) fails = fails + 1
    ! Exactly one document: starts with '[', ends with ']' + NL.
    if (len(out_s) < 2) then
      fails = fails + 1
    else if (out_s(1:1) /= '[' .or. &
             out_s(len(out_s) - 1:len(out_s)) /= ']' // nl) then
      fails = fails + 1
      call note_fail('jsondiag error', 'stdout is not a lone JSON doc')
    end if
    call json_parse_text(out_s, root, ok)
    if (.not. ok .or. json_kind(root) /= JARR) then
      fails = fails + 1
      call note_fail('jsondiag error', 'stdout does not parse as array')
    else
      if (json_child_count(root) /= 1) fails = fails + 1
      rec = json_child_at(root, 1)
      call json_get(rec, 'code', node)
      call json_as_string(node, s)
      if (s /= 'E104') fails = fails + 1
      call json_get(rec, 'severity', node)
      call json_as_string(node, s)
      if (s /= 'error') fails = fails + 1
      call json_get(rec, 'message', node)
      call json_as_string(node, s)
      if (len(s) == 0) fails = fails + 1
      call json_get(rec, 'span', span_node)
      if (json_kind(span_node) /= JOBJ) then
        fails = fails + 1
        call note_fail('jsondiag error', 'span is not an object')
      else
        call json_get(span_node, 'source', node)
        call json_as_string(node, s)
        if (s /= 'err.f3d') fails = fails + 1
        call json_get(span_node, 'line', node)
        if (int(json_as_int(node)) /= 1) fails = fails + 1
        call json_get(span_node, 'col', node)
        if (int(json_as_int(node)) /= 1) fails = fails + 1
        call json_get(span_node, 'length', node)
        if (int(json_as_int(node)) /= 1) fails = fails + 1
      end if
    end if

    ! --- warning-only case ---
    call write_all(work // '/warn.f3d', nl)
    call run_f3dc('check --json warn.f3d', work, rc, out_s, err_s)
    if (rc /= 0) fails = fails + 1
    if (len(err_s) /= 0) fails = fails + 1
    ! Cut the document at the first line that is exactly "]".
    block
      integer :: i, cut
      cut = 0
      i = 1
      do while (i + 1 <= len(out_s))
        if (out_s(i:i) == ']' .and. out_s(i + 1:i + 1) == nl) then
          cut = i + 1
          exit
        end if
        i = i + 1
      end do
      if (cut == 0) then
        fails = fails + 1
        call note_fail('jsondiag warn', 'no closing bracket line')
        doc = ''
      else
        doc = out_s(1:cut)
        if (index(out_s(cut + 1:), 'OK: warn.f3d') == 0) then
          fails = fails + 1
          call note_fail('jsondiag warn', 'OK line missing after doc')
        end if
      end if
    end block
    call json_parse_text(doc, root, ok)
    if (.not. ok .or. json_kind(root) /= JARR) then
      fails = fails + 1
      call note_fail('jsondiag warn', 'document does not parse')
    else
      if (json_child_count(root) /= 4) fails = fails + 1
      rec = json_child_at(root, 1)
      call json_get(rec, 'code', node)
      call json_as_string(node, s)
      if (s /= 'W101') fails = fails + 1
      call json_get(rec, 'severity', node)
      call json_as_string(node, s)
      if (s /= 'warning') fails = fails + 1
      call json_get(rec, 'message', node)
      call json_as_string(node, s)
      if (len(s) == 0) fails = fails + 1
      call json_get(rec, 'span', span_node)
      if (json_kind(span_node) /= JNULL) then
        fails = fails + 1
        call note_fail('jsondiag warn', &
                       'span should be null for W101 defaults')
      end if
    end if

    if (fails == 0) then
      write(*, '(A)') 'SECTION jsondiag: PASS (check --json: ' // &
        'error case = single JSON document; warning case = JSON ' // &
        'document + OK line; code/severity/message/span verified)'
    else
      write(*, '(A,I0,A)') 'SECTION jsondiag: FAIL (', fails, &
        ' failures)'
      total_fails = total_fails + fails
    end if
  end subroutine section_jsondiag

end program property_tests
