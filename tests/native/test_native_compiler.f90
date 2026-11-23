! test_native_compiler.f90 -- black-box tests for the NATIVE
! Forge3D compiler (bin/f3dc), ported from
! tests/native/test_native_compiler.py to Fortran.
!
! Build (from the repo root):
!   gfortran -O2 -o /tmp/test_native_compiler \
!     tests/native/json_parse.f90 tests/native/test_native_compiler.f90
! Run (from the repo root; the runner cds there):
!   /tmp/test_native_compiler
!
! Environment:
!   F3DC         -- binary under test (else <repo>/bin/f3dc, else
!                   <repo>/compiler/f3dc)
!   FORGE3D_ROOT -- repo root (else the current working directory)
!
! Differences from the Python original (named, per the port brief):
!   * Hashing uses an in-program SHA-256 (module sha256_mod below)
!     instead of hashlib; it is verified below against the known
!     empty-string and "abc" digests before any section runs.
!     (sha256sum is therefore not needed at runtime.)
!   * Temp dirs come from `mktemp -d`, file listings from `find`,
!     HTTP from `curl -s`, sleeps from `sleep`, and the preview
!     process is launched with `nohup ... & echo $!` and stopped
!     with `kill -INT <pid>` -- the shell equivalents of Python's
!     tempfile / pathlib / urllib / subprocess / signal plumbing.
!   * Failure reporting collects and prints the first few failures
!     per section instead of unittest subTest entries; coverage
!     (every case, capture field, artifact hash) is identical.

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
program test_native_compiler
  use iso_fortran_env, only: int64
  use json_parse
  use sha256_mod
  implicit none

  character(len=:), allocatable :: repo, f3dc, scratch
  integer :: total_fails = 0
  integer :: corpus_artifacts = 0, examples_artifacts = 0
  integer :: cli_artifacts = 0
  integer :: print_budget = 8

  call setup_paths()
  call selftest_sha()
  call section_corpus()
  call section_examples()
  call section_cli()
  call section_determinism()
  call section_preview()

  write(*, '(A,I0,A,I0,A,I0)') 'ARTIFACT HASHES: corpus ', &
    corpus_artifacts, ' + examples ', examples_artifacts, &
    ' = ', corpus_artifacts + examples_artifacts
  if (total_fails == 0) then
    write(*, '(A)') 'NATIVE RESULT: PASS'
  else
    write(*, '(A)') 'NATIVE RESULT: FAIL'
    stop 1
  end if

contains

  ! -------------------------------------------------------------
  ! Setup / generic helpers
  ! -------------------------------------------------------------
  subroutine setup_paths()
    character(len=4096) :: buf
    integer :: n, ios
    logical :: ex
    call get_environment_variable('FORGE3D_ROOT', buf, length=n, status=ios)
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
        inquire(file=repo // '/compiler/f3dc', exist=ex)
        if (ex) then
          f3dc = repo // '/compiler/f3dc'
        else
          f3dc = repo // '/bin/f3dc'
        end if
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
      write(*, '(A)') 'FATAL: internal SHA-256 failed empty-string vector'
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
    cap = scratch_or_tmp() // '/mktemp.out'
    call execute_command_line("mktemp -d > '" // cap // "'", exitstat=rc)
    if (rc /= 0) then
      write(*, '(A)') 'FATAL: mktemp -d failed'
      stop 1
    end if
    call read_all(cap, dir, rc)
    if (rc /= 0) then
      write(*, '(A)') 'FATAL: cannot read mktemp output'
      stop 1
    end if
    ! strip trailing newline(s)
    do while (len(dir) > 0)
      if (dir(len(dir):len(dir)) == char(10) .or. &
          dir(len(dir):len(dir)) == char(13)) then
        dir = dir(1:len(dir) - 1)
      else
        exit
      end if
    end do
  end subroutine make_temp_dir

  function scratch_or_tmp() result(p)
    character(len=:), allocatable :: p
    if (allocated(scratch)) then
      p = scratch
    else
      p = '/tmp'
    end if
  end function scratch_or_tmp

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

  ! Run f3dc with argv_str in cwd; capture exit code and streams.
  subroutine run_f3dc(argv_str, cwd, rc, out_s, err_s)
    character(len=*), intent(in) :: argv_str, cwd
    integer, intent(out) :: rc
    character(len=:), allocatable, intent(out) :: out_s, err_s
    character(len=:), allocatable :: cmd
    integer :: drc
    cmd = "cd '" // cwd // "' && '" // f3dc // "' " // argv_str // &
          " > '" // scratch // "/run.out' 2> '" // scratch // "/run.err'"
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

  ! Diagnostic codes [EW][0-9]{3} from a byte string, in order,
  ! joined with ',' (mirrors Python CODE_RE.findall + list ==).
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

  ! Compare one (rc, out, err) against a baked capture node.
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

  ! Sorted recursive file list of dir (relative paths).
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

  ! Compare every file under dir against an artifacts object
  ! (relpath -> sha256).  canon_flag applies canon() first.
  subroutine check_artifacts(dir, exp_artifacts, canon_flag, label, &
                             fails, hash_counter)
    character(len=*), intent(in) :: dir, label
    integer, intent(in) :: exp_artifacts
    logical, intent(in) :: canon_flag
    integer, intent(inout) :: fails, hash_counter
    character(len=1024), allocatable :: rels(:)
    character(len=:), allocatable :: data, cdata, exp_s, rel
    integer :: n, i, node
    character(len=64) :: hex
    logical :: bad
    call list_files(dir, rels, n)
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
      if (canon_flag) then
        call canon(data, cdata)
        call sha256_hex(cdata, hex)
      else
        call sha256_hex(data, hex)
      end if
      hash_counter = hash_counter + 1
      if (hex /= exp_s) bad = .true.
    end do
    ! Also catch baked paths missing on disk.
    if (json_child_count(exp_artifacts) /= n) bad = .true.
    if (bad) then
      fails = fails + 1
      call note_fail(label, 'artifact set/hash mismatch')
    end if
  end subroutine check_artifacts

  ! canon(): repo-root bytes -> <REPO>, then
  ! `sha256: [0-9a-f]{64}` -> `sha256: <EMBEDDED>`.
  subroutine canon(data, out)
    character(len=*), intent(in) :: data
    character(len=:), allocatable, intent(out) :: out
    character(len=:), allocatable :: step1
    integer :: i, L, rL, start
    ! Pass 1: replace repo path.
    allocate(character(len=0) :: step1)
    L = len(data)
    rL = len(repo)
    start = 1
    i = 1
    do while (i + rL - 1 <= L)
      if (data(i:i + rL - 1) == repo) then
        step1 = step1 // data(start:i - 1) // '<REPO>'
        i = i + rL
        start = i
      else
        i = i + 1
      end if
    end do
    step1 = step1 // data(start:L)
    ! Pass 2: replace embedded sha256 headers.
    allocate(character(len=0) :: out)
    L = len(step1)
    start = 1
    i = 1
    do while (i + 7 + 64 - 1 <= L)
      if (step1(i:i + 7) == 'sha256: ' .and. is_hex64(step1, i + 8)) then
        out = out // step1(start:i - 1) // 'sha256: <EMBEDDED>'
        i = i + 8 + 64
        start = i
      else
        i = i + 1
      end if
    end do
    out = out // step1(start:L)
  end subroutine canon

  logical function is_hex64(s, p)
    character(len=*), intent(in) :: s
    integer, intent(in) :: p
    integer :: k
    character(len=1) :: c
    is_hex64 = .false.
    if (p + 63 > len(s)) return
    do k = 0, 63
      c = s(p + k:p + k)
      if (.not. ((c >= '0' .and. c <= '9') .or. &
                 (c >= 'a' .and. c <= 'f'))) return
    end do
    is_hex64 = .true.
  end function is_hex64

  function stem_of(name) result(stem)
    character(len=*), intent(in) :: name
    character(len=:), allocatable :: stem
    integer :: dot
    dot = index(name, '.', back=.true.)
    if (dot > 1) then
      stem = name(1:dot - 1)
    else
      stem = name
    end if
  end function stem_of

  function itoa(v) result(s)
    integer, intent(in) :: v
    character(len=:), allocatable :: s
    character(len=32) :: buf
    write(buf, '(I0)') v
    s = trim(buf)
  end function itoa

  ! -------------------------------------------------------------
  ! SECTION: corpus (896 cases)
  ! -------------------------------------------------------------
  subroutine section_corpus()
    integer :: root, cases_node, kept_node, fails, i, cc, node, brc
    logical :: ok
    character(len=:), allocatable :: work, src, out_s, err_s
    character(len=:), allocatable :: bout, berr
    integer :: check_node, build_node, art_node
    fails = 0
    print_budget = 8
    call read_json_file(repo // '/tests/native/corpus.json', root, ok)
    if (.not. ok) then
      write(*, '(A)') 'SECTION corpus: FAIL (corpus.json parse error)'
      total_fails = total_fails + 1
      return
    end if
    call json_get(root, 'cases', cases_node)
    call json_get(root, 'kept', kept_node)
    cc = json_child_count(cases_node)
    if (cc /= int(json_as_int(kept_node))) then
      fails = fails + 1
      call note_fail('corpus', 'case count != kept')
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
                         'corpus[' // itoa(i - 1) // '] check', fails)
      if (json_has(node, 'build')) then
        call sh("rm -rf '" // work // "/out'", brc)
        call run_f3dc('build -o out scene.f3d', work, brc, bout, berr)
        if (brc /= 0) then
          fails = fails + 1
          call note_fail('corpus[' // itoa(i - 1) // '] build', &
                         'nonzero build exit')
        else
          call json_get(node, 'build', build_node)
          call json_get(build_node, 'artifacts', art_node)
          call check_artifacts(work // '/out', art_node, .false., &
            'corpus[' // itoa(i - 1) // '] build', fails, corpus_artifacts)
        end if
      end if
    end do
    if (fails == 0) then
      write(*, '(A,I0,A,I0,A)') 'SECTION corpus: PASS (', cc, &
        ' cases, ', corpus_artifacts, ' artifact hashes)'
    else
      write(*, '(A,I0,A,I0,A,I0,A)') 'SECTION corpus: FAIL (', fails, &
        ' failures in ', cc, ' cases, ', corpus_artifacts, &
        ' artifact hashes)'
      total_fails = total_fails + fails
    end if
  end subroutine section_corpus

  ! -------------------------------------------------------------
  ! SECTION: examples
  ! -------------------------------------------------------------
  subroutine section_examples()
    integer :: root, scenes_node, fails, i, cc, scene_node, node
    integer :: check_node, build_node, art_node, brc
    logical :: ok
    character(len=:), allocatable :: tmpbase, name, abspath, outdir
    character(len=:), allocatable :: out_s, err_s, cout, cerr, bout, berr
    fails = 0
    print_budget = 8
    call read_json_file(repo // '/tests/native/examples.json', root, ok)
    if (.not. ok) then
      write(*, '(A)') 'SECTION examples: FAIL (examples.json parse error)'
      total_fails = total_fails + 1
      return
    end if
    call json_get(root, 'scenes', scenes_node)
    cc = json_child_count(scenes_node)
    call make_temp_dir(tmpbase)
    do i = 1, cc
      scene_node = json_child_at(scenes_node, i)
      call json_key_at(scenes_node, i, name)
      abspath = repo // '/examples/' // name
      call run_f3dc('check ' // abspath, repo, brc, out_s, err_s)
      call canon(out_s, cout)
      call canon(err_s, cerr)
      call json_get(scene_node, 'check', check_node)
      call check_capture(check_node, brc, cout, cerr, &
                         'example ' // name // ' check', fails)
      outdir = tmpbase // '/' // stem_of(name)
      call run_f3dc('build -o ' // outdir // ' ' // abspath, repo, &
                    brc, bout, berr)
      if (brc /= 0) then
        fails = fails + 1
        call note_fail('example ' // name // ' build', 'nonzero exit')
      else
        call json_get(scene_node, 'build', build_node)
        call json_get(build_node, 'artifacts', art_node)
        call check_artifacts(outdir, art_node, .true., &
          'example ' // name // ' build', fails, examples_artifacts)
      end if
      node = scene_node  ! keep compiler quiet about intent
    end do
    if (fails == 0) then
      write(*, '(A,I0,A,I0,A)') 'SECTION examples: PASS (', cc, &
        ' scenes, ', examples_artifacts, ' artifact hashes)'
    else
      write(*, '(A,I0,A,I0,A,I0,A)') 'SECTION examples: FAIL (', &
        fails, ' failures in ', cc, ' scenes, ', examples_artifacts, &
        ' artifact hashes)'
      total_fails = total_fails + fails
    end if
  end subroutine section_examples

  ! -------------------------------------------------------------
  ! SECTION: CLI battery
  ! -------------------------------------------------------------
  subroutine section_cli()
    integer :: root, cases_node, fails, i, cc, case_node, node
    integer :: exp_node, setup_node, argv_node, brc, j, nc
    logical :: ok
    character(len=:), allocatable :: work, name, kind, argv_str, tmp
    character(len=:), allocatable :: out_s, err_s, key, val, exp_s
    character(len=64) :: hex
    integer :: dummy_hashes
    fails = 0
    print_budget = 8
    dummy_hashes = 0
    call read_json_file(repo // '/tests/native/cli_battery.json', root, ok)
    if (.not. ok) then
      write(*, '(A)') 'SECTION cli_battery: FAIL (parse error)'
      total_fails = total_fails + 1
      return
    end if
    call json_get(root, 'cases', cases_node)
    cc = json_child_count(cases_node)
    do i = 1, cc
      case_node = json_child_at(cases_node, i)
      call json_get(case_node, 'name', node)
      call json_as_string(node, name)
      call json_get(case_node, 'kind', node)
      call json_as_string(node, kind)
      call make_temp_dir(work)
      call json_get(case_node, 'setup', setup_node)
      nc = json_child_count(setup_node)
      do j = 1, nc
        call json_key_at(setup_node, j, key)
        call json_as_string(json_child_at(setup_node, j), val)
        call write_all(work // '/' // key, val)
      end do
      call json_get(case_node, 'argv', argv_node)
      nc = json_child_count(argv_node)
      argv_str = ''
      do j = 1, nc
        call json_as_string(json_child_at(argv_node, j), tmp)
        if (j > 1) argv_str = argv_str // ' '
        argv_str = argv_str // tmp
      end do
      call run_f3dc(argv_str, work, brc, out_s, err_s)
      call json_get(case_node, 'expect', exp_node)
      if (kind == 'doctor') then
        if (brc /= 0 .or. (len(out_s) == 0 .and. len(err_s) == 0)) then
          fails = fails + 1
          call note_fail('cli ' // name, 'doctor: exit/output check')
        end if
        cycle
      end if
      call check_capture(exp_node, brc, out_s, err_s, &
                         'cli ' // name, fails)
      if (json_has(case_node, 'build_artifacts')) then
        block
          integer :: flag_node, art_node2
          call json_get(case_node, 'build_artifacts', flag_node)
          if (json_as_bool(flag_node)) then
            call json_get(exp_node, 'artifacts', art_node2)
            call check_artifacts(work // '/out', art_node2, .false., &
              'cli ' // name // ' artifacts', fails, cli_artifacts)
          end if
        end block
      end if
      if (kind == 'new') then
        call read_all(work // '/myscene.f3d', val, brc)
        if (brc /= 0) then
          fails = fails + 1
          call note_fail('cli ' // name, 'myscene.f3d not created')
        else
          call sha256_hex(val, hex)
          call json_get(exp_node, 'created_sha256', node)
          call json_as_string(node, exp_s)
          if (hex /= exp_s) then
            fails = fails + 1
            call note_fail('cli ' // name, 'created file hash differs')
          end if
        end if
      end if
    end do
    if (fails == 0) then
      write(*, '(A,I0,A,I0,A)') 'SECTION cli_battery: PASS (', cc, &
        ' cases, ', cli_artifacts, ' artifact hashes)'
    else
      write(*, '(A,I0,A,I0,A,I0,A)') 'SECTION cli_battery: FAIL (', &
        fails, ' failures in ', cc, ' cases)'
      total_fails = total_fails + fails
    end if
  end subroutine section_cli

  ! -------------------------------------------------------------
  ! SECTION: determinism
  ! -------------------------------------------------------------
  subroutine section_determinism()
    integer :: fails, brc, drc
    character(len=:), allocatable :: tmp, out_s, err_s, s1, s2
    character(len=64) :: h1, h2
    fails = 0
    call make_temp_dir(tmp)
    call run_f3dc('build -o ' // tmp // '/a examples/hello-cube.f3d', &
                  repo, brc, out_s, err_s)
    if (brc /= 0) fails = fails + 1
    call run_f3dc('build -o ' // tmp // '/b examples/hello-cube.f3d', &
                  repo, brc, out_s, err_s)
    if (brc /= 0) fails = fails + 1
    call read_all(tmp // '/a/hello-cube.scene', s1, drc)
    if (drc /= 0) fails = fails + 1
    call read_all(tmp // '/b/hello-cube.scene', s2, drc)
    if (drc /= 0) fails = fails + 1
    if (fails == 0) then
      call sha256_hex(s1, h1)
      call sha256_hex(s2, h2)
      if (h1 /= h2) fails = fails + 1
    end if
    if (fails == 0) then
      write(*, '(A)') 'SECTION determinism: PASS (hello-cube.scene identical)'
    else
      write(*, '(A)') 'SECTION determinism: FAIL'
      total_fails = total_fails + fails
    end if
  end subroutine section_determinism

  ! -------------------------------------------------------------
  ! SECTION: preview live-reload cycle
  ! -------------------------------------------------------------
  subroutine http_get(base, path, status, body)
    character(len=*), intent(in) :: base, path
    integer, intent(out) :: status
    character(len=:), allocatable, intent(out) :: body
    character(len=:), allocatable :: cmd, code_s
    integer :: rc
    cmd = "curl -s -m 5 -o '" // scratch // "/http.body' -w " // &
          "'%{http_code}' '" // base // path // "' > '" // &
          scratch // "/http.code'"
    call execute_command_line(cmd, exitstat=rc)
    call read_all(scratch // '/http.code', code_s, rc)
    status = 0
    if (len(code_s) >= 3) read(code_s(1:3), '(I3)', iostat=rc) status
    call read_all(scratch // '/http.body', body, rc)
  end subroutine http_get

  subroutine parse_version_body(body, okv, errors, version, good)
    character(len=*), intent(in) :: body
    logical, intent(out) :: okv, good
    integer, intent(out) :: errors, version
    integer :: root, node
    logical :: pok
    okv = .false.; errors = -1; version = -1; good = .false.
    call json_parse_text(body, root, pok)
    if (.not. pok) return
    good = .true.
    call json_get(root, 'ok', node)
    okv = json_as_bool(node)
    call json_get(root, 'errors', node)
    errors = int(json_as_int(node))
    call json_get(root, 'version', node)
    version = int(json_as_int(node))
  end subroutine parse_version_body

  ! Poll /__version until version > gt (or timeout). Returns the
  ! parsed fields of the first body that passes gt.
  subroutine wait_version(base, gt, timeout_s, found, okv, errors, version)
    character(len=*), intent(in) :: base
    integer, intent(in) :: gt, timeout_s
    logical, intent(out) :: found, okv
    integer, intent(out) :: errors, version
    integer :: status, tries, k
    character(len=:), allocatable :: body
    logical :: good
    found = .false.; okv = .false.; errors = -1; version = -1
    tries = timeout_s * 5
    do k = 1, tries
      call http_get(base, '/__version', status, body)
      if (status == 200) then
        call parse_version_body(body, okv, errors, version, good)
        if (good .and. version > gt) then
          found = .true.
          return
        end if
      end if
      call execute_command_line('sleep 0.2')
    end do
  end subroutine wait_version

  subroutine section_preview()
    integer :: fails, rc, status, i, p
    character(len=:), allocatable :: work, logtxt, base, pid_s, body
    character(len=:), allocatable :: cmd
    logical :: found, okv, good
    integer :: errors, version, v0, v1, v2, sroot, snode
    fails = 0
    print_budget = 8
    call make_temp_dir(work)
    call write_all(work // '/scene.f3d', &
                   'cube red' // char(10) // 'spin it' // char(10) // &
                   'render' // char(10))
    cmd = "cd '" // work // "' && nohup '" // f3dc // &
          "' preview --port 0 --no-browser scene.f3d " // &
          "> preview.log 2>&1 < /dev/null & echo $! > '" // &
          scratch // "/preview.pid'"
    call execute_command_line(cmd, exitstat=rc)
    call read_all(scratch // '/preview.pid', pid_s, rc)
    ! strip trailing newline
    do while (len(pid_s) > 0)
      if (pid_s(len(pid_s):len(pid_s)) == char(10) .or. &
          pid_s(len(pid_s):len(pid_s)) == char(13) .or. &
          pid_s(len(pid_s):len(pid_s)) == ' ') then
        pid_s = pid_s(1:len(pid_s) - 1)
      else
        exit
      end if
    end do

    ! Poll the log up to 20 s for http://127.0.0.1:(\d+)/
    allocate(character(len=0) :: base)
    do i = 1, 100
      call read_all(work // '/preview.log', logtxt, rc)
      p = index(logtxt, 'http://127.0.0.1:')
      if (p > 0) then
        block
          integer :: q, e
          q = p + len('http://127.0.0.1:')
          e = q
          do while (e <= len(logtxt))
            if (logtxt(e:e) >= '0' .and. logtxt(e:e) <= '9') then
              e = e + 1
            else
              exit
            end if
          end do
          if (e > q) base = 'http://127.0.0.1:' // logtxt(q:e - 1)
        end block
        if (len(base) > 0) exit
      end if
      call execute_command_line('sleep 0.2')
    end do
    if (len(base) == 0) then
      fails = fails + 1
      call note_fail('preview', 'server did not print a URL in 20s')
    else
      call http_get(base, '/', status, body)
      if (status /= 200) fails = fails + 1
      if (index(body, 'f3d-preview-bar') == 0) fails = fails + 1
      if (index(body, 'Forge3D Preview') == 0) fails = fails + 1
      if (index(body, '__VERSION__') /= 0) fails = fails + 1
      if (fails > 0) call note_fail('preview', 'initial page checks')

      call http_get(base, '/__version', status, body)
      call parse_version_body(body, okv, errors, version, good)
      if (.not. good .or. .not. okv .or. errors /= 0) then
        fails = fails + 1
        call note_fail('preview', 'initial /__version not ok')
      end if
      v0 = version
      if (v0 < 1) then
        fails = fails + 1
        call note_fail('preview', 'initial version < 1')
      end if

      call write_all(work // '/scene.f3d', &
                     'sphere blue' // char(10) // 'render' // char(10))
      call wait_version(base, v0, 15, found, okv, errors, version)
      if (.not. found .or. .not. okv) then
        fails = fails + 1
        call note_fail('preview', 'edit did not bump to ok version')
      end if
      v1 = version

      call write_all(work // '/scene.f3d', &
                     'cubee red' // char(10) // 'render' // char(10))
      call wait_version(base, v1, 15, found, okv, errors, version)
      if (.not. found .or. okv .or. errors < 1) then
        fails = fails + 1
        call note_fail('preview', 'broken scene did not error')
      end if
      v2 = version
      call http_get(base, '/', status, body)
      if (index(body, 'Scene error') == 0) then
        fails = fails + 1
        call note_fail('preview', 'error page lacks "Scene error"')
      end if
      call http_get(base, '/__status', status, body)
      call json_parse_text(body, sroot, good)
      if (.not. good) then
        fails = fails + 1
        call note_fail('preview', '/__status not JSON')
      else
        call json_get(sroot, 'ok', snode)
        if (json_as_bool(snode)) then
          fails = fails + 1
          call note_fail('preview', '/__status ok should be false')
        end if
        call json_get(sroot, 'diagnostics', snode)
        if (json_child_count(snode) == 0) then
          fails = fails + 1
          call note_fail('preview', '/__status diagnostics empty')
        end if
      end if

      call write_all(work // '/scene.f3d', &
                     'cube green' // char(10) // 'render' // char(10))
      call wait_version(base, v2, 15, found, okv, errors, version)
      if (.not. found .or. .not. okv) then
        fails = fails + 1
        call note_fail('preview', 'fixed scene did not recover')
      end if
    end if

    ! SIGINT the preview process and wait for it to exit.
    if (len(pid_s) > 0) then
      call execute_command_line('kill -INT ' // pid_s, exitstat=rc)
      do i = 1, 25
        call execute_command_line('kill -0 ' // pid_s // &
                                  ' 2>/dev/null', exitstat=rc)
        if (rc /= 0) exit
        call execute_command_line('sleep 0.2')
      end do
      if (rc == 0) then
        call execute_command_line('kill -KILL ' // pid_s, exitstat=rc)
        fails = fails + 1
        call note_fail('preview', 'process did not exit on SIGINT')
      end if
    end if

    if (fails == 0) then
      write(*, '(A)') 'SECTION preview: PASS (live reload cycle)'
    else
      write(*, '(A,I0,A)') 'SECTION preview: FAIL (', fails, ' failures)'
      total_fails = total_fails + fails
    end if
  end subroutine section_preview

end program test_native_compiler
