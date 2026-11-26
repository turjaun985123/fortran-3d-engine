! f3dc_driver.f90 -- toolchain driver for the native Forge3D compiler.
!
! Port of tools/f3dc/driver.py (237 lines, read in full; see
! compiler/DESIGN.md, the binding contract).  Mirrors the Python
! function by function:
!
!   repo_root()    -> driver_repo_root(root)
!   find_tool()    -> driver_find_tool(name, path, found)
!   ToolchainError -> the (msg, failed) pair every fallible routine
!                     returns: failed=.true. + msg = the exception's
!                     message.  ToolchainError.exit_code == 4 is a
!                     Python class attribute; the CLI maps a failed
!                     driver call to exit 4 exactly as cli.py does.
!   ensure_engine()-> driver_ensure_engine(engine, msg, failed
!                     [, root])
!   run_engine()   -> driver_run_engine(scene_path, cwd, timeout,
!                     rc, out_text, err_text, msg, failed)
!   _output_tail() -> output_tail (private)
!
! HARD RULE (DESIGN.md): no type-bound procedures -- free
! subroutines/functions only.
!
! repo_root semantics: Python takes Path(__file__).resolve()
! .parents[2] for <root>/tools/f3dc/driver.py.  The native binary
! lives at <root>/compiler/f3dc (DESIGN.md layout; installing it
! means compiler/f3dc -> <root>/bin/f3dc, one level shallower), so
! the mirror rule used here is: take argv[0], make it absolute,
! resolve "." / ".." components textually, and return the PARENT
! OF THE BINARY'S DIRECTORY -- i.e. for <root>/compiler/f3dc and
! for <root>/bin/f3dc alike the result is <root>.  Symlinks in the
! path are NOT resolved (Python .resolve() does resolve them) --
! documented divergence.
!
! Subprocess work: Python uses subprocess with argv lists and never
! a shell.  Fortran has no argv-list spawn; execute_command_line()
! goes through /bin/sh by definition, so commands are built as
! single-quoted strings (driver_quote) -- the argv-list guarantee
! becomes a quoting guarantee.  Documented divergence.
! Timeouts use the coreutils `timeout` program when present
! (exit 124 == timed out; a child that exits 124 by itself would be
! misread as a timeout -- documented approximation).  Without
! `timeout`, commands run unbounded.
!
! Stage timing (v3.0 Phase 8): driver_timing_reset / _mark / _ms
! below are a pure-bookkeeping stage-timing registry (no I/O, no
! effect on any existing driver procedure).  Consumers are the
! `f3dc profile` command and the preview toolbar, which read the
! accumulated per-stage milliseconds for the stage names "parse",
! "desugar", "validate", "emit", "write" and "total"; the
! registry itself accepts any stage name.
module f3dc_driver
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: iso_c_binding, only: c_int, c_char, c_null_char
  use f3dc_str, only: str_builder, sb_init, sb_add, sb_text, sb_len
  ! v3.0 Phase 6 (Seat X): the compiler already has a pure-Fortran
  ! SHA-256 (f3dc_emit_common, FIPS 180-4, used for the emitter
  ! header stamps); the incremental-build manifest reuses it rather
  ! than growing a second, weaker hash in the driver.
  use f3dc_emit_common, only: sha256_hex, sha256_file_hex
  implicit none
  private

  public :: driver_repo_root, driver_find_tool
  public :: driver_ensure_engine, driver_run_engine
  public :: driver_run_capture, driver_quote, driver_cwd
  public :: driver_file_exists, driver_is_dir, driver_abs_path
  public :: driver_file_sha256
  public :: driver_manifest_check, driver_manifest_write
  public :: driver_timing_reset, driver_timing_mark
  public :: driver_timing_ms

  ! _TAIL_CHARS / _TAIL_LINES in driver.py.
  integer, parameter :: TAIL_CHARS = 2000
  integer, parameter :: TAIL_LINES = 30

  ! Stage-timing registry (see the header note): fixed-size
  ! module-level tables, no allocation and no I/O.  Stage names
  ! are stored in fixed-length entries, so a name longer than
  ! TIMING_NAME_LEN is truncated when it is recorded.
  integer, parameter :: TIMING_MAX_STAGES = 32
  integer, parameter :: TIMING_NAME_LEN = 32
  character(len=TIMING_NAME_LEN) :: timing_names(TIMING_MAX_STAGES)
  real(real64) :: timing_totals(TIMING_MAX_STAGES) = 0.0_real64
  integer :: timing_n = 0
  integer(int64) :: timing_last = 0_int64
  integer(int64) :: timing_rate = 0_int64
  integer(int64) :: timing_max = 0_int64
  logical :: timing_started = .false.

  interface
     function c_getcwd(buf, size) bind(C, name="getcwd") result(res)
       import :: c_char
       character(kind=c_char) :: buf(*)
       integer, value :: size
       integer :: res
     end function c_getcwd
     function c_getpid() bind(C, name="getpid") result(res)
       integer :: res
     end function c_getpid
  end interface

contains

  ! ------------------------------------------------------------------
  ! Small filesystem / string helpers (shared with f3dc_cli)
  ! ------------------------------------------------------------------

  logical function driver_file_exists(path)
    character(len=*), intent(in) :: path
    inquire (file=path, exist=driver_file_exists)
  end function driver_file_exists

  logical function driver_is_dir(path)
    character(len=*), intent(in) :: path
    integer :: rc
    call execute_command_line("test -d "//driver_quote(path), &
                              exitstat=rc)
    driver_is_dir = (rc == 0)
  end function driver_is_dir

  !> Current working directory (libc getcwd).
  function driver_cwd() result(out)
    character(len=:), allocatable :: out
    character(kind=c_char) :: buf(8192)
    integer :: res, i
    res = c_getcwd(buf, 8192)
    if (res == 0) then
       out = "."
       return
    end if
    do i = 1, 8192
       if (buf(i) == c_null_char) exit
    end do
    allocate (character(len=i - 1) :: out)
    out = transfer(buf(1:i - 1), out)
  end function driver_cwd

  !> Resolve "." / ".." components textually; make absolute using
  !! the cwd when the path is relative.  No symlink resolution.
  function driver_abs_path(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out, full
    character(len=256) :: parts(512)
    type(str_builder) :: sb
    integer :: n, i, top
    logical :: absolute
    absolute = .false.
    if (len(path) > 0) absolute = path(1:1) == "/"
    if (absolute) then
       full = path
       absolute = .true.
    else
       full = driver_cwd()//"/"//path
       absolute = .true.
    end if
    ! Split on '/'.
    n = 0
    block
      integer :: start, j
      start = 1
      do j = 1, len(full) + 1
         if (j <= len(full)) then
            if (full(j:j) /= "/") cycle
         end if
         n = n + 1
         if (j > start) then
            parts(n) = full(start:j - 1)
         else
            parts(n) = ""
         end if
         start = j + 1
      end do
    end block
    top = 0
    do i = 1, n
       if (len_trim(parts(i)) == 0 .or. trim(parts(i)) == ".") then
          cycle
       else if (trim(parts(i)) == "..") then
          if (top > 0) top = top - 1
       else
          top = top + 1
          parts(top) = parts(i)
       end if
    end do
    call sb_init(sb)
    if (absolute) call sb_add(sb, "/")
    do i = 1, top
       if (i > 1) call sb_add(sb, "/")
       call sb_add(sb, trim(parts(i)))
    end do
    out = sb_text(sb)
    if (len(out) == 0) out = "/"
  end function driver_abs_path

  !> Parent directory of a path (textual; "." when there is no '/').
  function parent_dir(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    integer :: slash
    slash = index(path, "/", back=.true.)
    if (slash == 0) then
       out = "."
    else if (slash == 1) then
       out = "/"
    else
       out = path(1:slash - 1)
    end if
  end function parent_dir

  !> Single-quote a string for /bin/sh (driver.py never uses a shell;
  !! execute_command_line always does -- see the header note).
  function driver_quote(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: i
    call sb_init(sb)
    call sb_add(sb, "'")
    do i = 1, len(s)
       if (s(i:i) == "'") then
          call sb_add(sb, "'\''")
       else
          call sb_add(sb, s(i:i))
       end if
    end do
    call sb_add(sb, "'")
    out = sb_text(sb)
  end function driver_quote

  ! ------------------------------------------------------------------
  ! Subprocess capture (subprocess.run with capture_output=True)
  ! ------------------------------------------------------------------

  !> Read a whole file into an allocatable string ("" when absent).
  function read_all(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    integer :: unit, ios, sz
    logical :: there
    inquire (file=path, size=sz, exist=there)
    if (.not. there) then
       out = ""
       return
    end if
    open (newunit=unit, file=path, access="stream", form="unformatted", &
          status="old", iostat=ios)
    if (ios /= 0) then
       out = ""
       return
    end if
    allocate (character(len=max(sz, 0)) :: out)
    if (sz > 0) read (unit, iostat=ios) out
    close (unit)
  end function read_all

  subroutine delete_quiet(path)
    character(len=*), intent(in) :: path
    integer :: unit, ios
    open (newunit=unit, file=path, status="old", iostat=ios)
    if (ios == 0) close (unit, status="delete")
  end subroutine delete_quiet

  !> Run CMD (a shell string; quote arguments with driver_quote) in
  !! directory CWD, capturing stdout/stderr.  RC is the child's exit
  !! status; TIMED_OUT is set when the `timeout` wrapper reports 124.
  !! TIMEOUT <= 0 means no limit.  SPAWN_FAILED is set when the shell
  !! itself reports it could not start the command (exit 127 with no
  !! output is NOT proof of that, so callers mostly ignore it; kept
  !! for parity with Python's OSError branch documentation).
  subroutine driver_run_capture(cmd, cwd, timeout, rc, out_text, &
                                err_text, timed_out)
    character(len=*), intent(in) :: cmd, cwd
    integer, intent(in) :: timeout
    integer, intent(out) :: rc
    character(len=:), allocatable, intent(out) :: out_text, err_text
    logical, intent(out) :: timed_out
    character(len=:), allocatable :: base, full, tpath
    character(len=1024) :: tmpdir
    type(str_builder) :: sb
    logical :: have_timeout
    integer :: pid, tlen, tstat
    pid = c_getpid()
    ! Scratch files honour TMPDIR (the capture mechanism must not
    ! depend on a writable /tmp: a full or read-only /tmp would
    ! silently empty every captured listing/output).
    call get_environment_variable("TMPDIR", tmpdir, length=tlen, &
                                  status=tstat)
    if (tstat == 0 .and. tlen > 0 .and. tlen <= len(tmpdir)) then
       base = trim(tmpdir)//"/f3dc_driver_"// &
              trim(int_str(int(pid, int64)))
    else
       base = "/tmp/f3dc_driver_"//trim(int_str(int(pid, int64)))
    end if
    call driver_find_tool("timeout", tpath, have_timeout)
    call sb_init(sb)
    if (len_trim(cwd) > 0) then
       call sb_add(sb, "cd ")
       call sb_add(sb, driver_quote(cwd))
       call sb_add(sb, " && ")
    end if
    if (have_timeout .and. timeout > 0) then
       call sb_add(sb, "timeout -k 5 ")
       call sb_add(sb, trim(int_str(int(timeout, int64))))
       call sb_add(sb, " ")
    end if
    call sb_add(sb, cmd)
    call sb_add(sb, " >")
    call sb_add(sb, driver_quote(base//".out"))
    call sb_add(sb, " 2>")
    call sb_add(sb, driver_quote(base//".err"))
    full = sb_text(sb)
    call execute_command_line(full, exitstat=rc)
    timed_out = (have_timeout .and. timeout > 0 .and. rc == 124)
    out_text = read_all(base//".out")
    err_text = read_all(base//".err")
    call delete_quiet(base//".out")
    call delete_quiet(base//".err")
  end subroutine driver_run_capture

  function int_str(x) result(out)
    integer(int64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=32) :: buf
    write (buf, '(I0)') x
    out = trim(buf)
  end function int_str

  ! ------------------------------------------------------------------
  ! repo_root() / find_tool()
  ! ------------------------------------------------------------------

  !> The repository root: parent of the directory holding this
  !! binary (see the header for the mirror rule vs driver.py).
  subroutine driver_repo_root(root)
    character(len=:), allocatable, intent(out) :: root
    character(len=4096) :: argv0
    integer :: ln, stat
    character(len=:), allocatable :: exe
    call get_command_argument(0, argv0, ln, stat)
    if (stat /= 0 .or. ln <= 0) then
       root = driver_cwd()
       return
    end if
    exe = driver_abs_path(trim(argv0(1:ln)))
    root = parent_dir(parent_dir(exe))
  end subroutine driver_repo_root

  !> shutil.which(): search PATH for an executable NAME.
  subroutine driver_find_tool(name, path, found)
    character(len=*), intent(in) :: name
    character(len=:), allocatable, intent(out) :: path
    logical, intent(out) :: found
    character(len=8192) :: pathenv
    integer :: stat, i, start, rc
    found = .false.
    path = ""
    if (len_trim(name) == 0) return
    if (index(name, "/") > 0) then
       call execute_command_line("test -x "//driver_quote(name), &
                                 exitstat=rc)
       if (rc == 0) then
          path = name
          found = .true.
       end if
       return
    end if
    call get_environment_variable("PATH", pathenv, status=stat)
    if (stat /= 0) return
    start = 1
    do i = 1, len_trim(pathenv) + 1
       if (i > len_trim(pathenv) .or. pathenv(i:i) == ":") then
          block
            character(len=:), allocatable :: dir, cand
            if (i > start) then
               dir = pathenv(start:i - 1)
            else
               dir = "."
            end if
            cand = dir//"/"//name
            call execute_command_line("test -x "//driver_quote(cand), &
                                      exitstat=rc)
            if (rc == 0) then
               path = cand
               found = .true.
               return
            end if
          end block
          start = i + 1
       end if
    end do
  end subroutine driver_find_tool

  ! ------------------------------------------------------------------
  ! _output_tail()
  ! ------------------------------------------------------------------

  !> Tail of the combined output texts: last TAIL_LINES lines, then
  !! last TAIL_CHARS characters (driver.py _output_tail over the
  !! non-empty texts joined by "\n" and stripped).
  function output_tail(out_text, err_text) result(tail)
    character(len=*), intent(in) :: out_text, err_text
    character(len=:), allocatable :: tail, combined
    type(str_builder) :: sb
    integer :: i, nlines, keep_from, pos
    call sb_init(sb)
    if (len(out_text) > 0) call sb_add(sb, out_text)
    if (len(err_text) > 0) then
       if (sb_len(sb) > 0) call sb_add(sb, achar(10))
       call sb_add(sb, err_text)
    end if
    combined = sb_text(sb)
    ! strip() -- leading/trailing whitespace (space, tab, CR, LF).
    combined = strip_ws(combined)
    if (len(combined) == 0) then
       tail = ""
       return
    end if
    ! Count lines; keep from the start of the last TAIL_LINES lines.
    nlines = 1
    do i = 1, len(combined)
       if (combined(i:i) == achar(10)) nlines = nlines + 1
    end do
    keep_from = 1
    if (nlines > TAIL_LINES) then
       pos = 0
       do i = 1, nlines - TAIL_LINES
          pos = pos + index(combined(pos + 1:), achar(10))
       end do
       keep_from = pos + 1
    end if
    tail = combined(keep_from:)
    if (len(tail) > TAIL_CHARS) tail = tail(len(tail) - TAIL_CHARS + 1:)
  end function output_tail

  function strip_ws(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
       if (.not. is_ws(s(a:a))) exit
       a = a + 1
    end do
    do while (b >= a)
       if (.not. is_ws(s(b:b))) exit
       b = b - 1
    end do
    if (b < a) then
       out = ""
    else
       out = s(a:b)
    end if
  end function strip_ws

  pure logical function is_ws(c)
    character(len=1), intent(in) :: c
    is_ws = (c == " " .or. c == achar(9) .or. c == achar(10) &
             .or. c == achar(13))
  end function is_ws

  ! ------------------------------------------------------------------
  ! ensure_engine()
  ! ------------------------------------------------------------------

  !> Return <root>/bin/engine3d, running `make` in ROOT first when
  !! the engine is missing.  ROOT defaults to driver_repo_root().
  !! (Python: an existing engine is returned as-is -- no staleness
  !! check; "missing/stale" in the seat brief is decided by
  !! existence exactly as driver.py decides.)
  subroutine driver_ensure_engine(engine, msg, failed, root)
    character(len=:), allocatable, intent(out) :: engine, msg
    logical, intent(out) :: failed
    character(len=*), intent(in), optional :: root
    character(len=:), allocatable :: root_path, tool, out_t, err_t, tail
    type(str_builder) :: sb_msg
    integer :: rc
    logical :: found, timed_out
    failed = .false.
    msg = ""
    if (present(root)) then
       root_path = driver_abs_path(root)
    else
       call driver_repo_root(root_path)
    end if
    engine = root_path//"/bin/engine3d"
    if (driver_file_exists(engine)) return

    if (.not. driver_is_dir(root_path)) then
       msg = "cannot build the Forge3D engine: repository root '"// &
             root_path//"' does not exist or is not a directory. "// &
             "help: run f3dc from inside a Forge3D checkout, or pass "// &
             "the checkout's root directory."
       failed = .true.
       return
    end if

    call driver_find_tool("make", tool, found)
    if (.not. found) then
       msg = "cannot build the Forge3D engine: 'make' was not found "// &
             "on your PATH. help: install make (e.g. 'sudo apt "// &
             "install make' on Debian/Ubuntu) and try again."
       failed = .true.
       return
    end if
    call driver_find_tool("gfortran", tool, found)
    if (.not. found) then
       msg = "cannot build the Forge3D engine: 'gfortran' was not "// &
             "found on your PATH. help: install gfortran (e.g. "// &
             "'sudo apt install gfortran' on Debian/Ubuntu) and "// &
             "try again."
       failed = .true.
       return
    end if

    call driver_run_capture("make", root_path, 600, rc, out_t, err_t, &
                            timed_out)
    if (timed_out) then
       tail = output_tail(out_t, err_t)
       msg = "building the Forge3D engine with 'make' timed out. "// &
             "help: run 'make' by hand in '"//root_path//"' to see "// &
             "what is happening."
       if (len(tail) > 0) then
          call sb_init(sb_msg)
          call sb_add(sb_msg, msg)
          call sb_add(sb_msg, achar(10))
          call sb_add(sb_msg, "last build output:")
          call sb_add(sb_msg, achar(10))
          call sb_add(sb_msg, tail)
          msg = sb_text(sb_msg)
       end if
       failed = .true.
       return
    end if
    if (rc /= 0) then
       tail = output_tail(out_t, err_t)
       msg = "building the Forge3D engine failed: 'make' exited "// &
             "with code "//trim(int_str(int(rc, int64)))//" in '"// &
             root_path//"'. help: run 'make' by hand there and fix "// &
             "the errors shown, then try again."
       if (len(tail) > 0) then
          call sb_init(sb_msg)
          call sb_add(sb_msg, msg)
          call sb_add(sb_msg, achar(10))
          call sb_add(sb_msg, "last build output:")
          call sb_add(sb_msg, achar(10))
          call sb_add(sb_msg, tail)
          msg = sb_text(sb_msg)
       end if
       failed = .true.
       return
    end if
    if (.not. driver_file_exists(engine)) then
       tail = output_tail(out_t, err_t)
       msg = "building the Forge3D engine did not produce the "// &
             "expected file '"//engine//"', even though 'make' "// &
             "reported success. help: run 'make' by hand in '"// &
             root_path//"' and check that it creates bin/engine3d."
       if (len(tail) > 0) then
          call sb_init(sb_msg)
          call sb_add(sb_msg, msg)
          call sb_add(sb_msg, achar(10))
          call sb_add(sb_msg, "last build output:")
          call sb_add(sb_msg, achar(10))
          call sb_add(sb_msg, tail)
          msg = sb_text(sb_msg)
       end if
       failed = .true.
       return
    end if
  end subroutine driver_ensure_engine

  ! ------------------------------------------------------------------
  ! run_engine()
  ! ------------------------------------------------------------------

  !> Run [engine, scene_path] with working directory CWD (default:
  !! the repo root) and return (RC, OUT_TEXT, ERR_TEXT).  A non-zero
  !! engine exit is returned, not raised.  FAILED+MSG mirror a
  !! ToolchainError (engine unbuildable, unexecutable, timeout).
  !! TIMEOUT is in seconds (Python default 120).
  subroutine driver_run_engine(scene_path, cwd, timeout, rc, &
                               out_text, err_text, msg, failed)
    character(len=*), intent(in) :: scene_path, cwd
    integer, intent(in) :: timeout
    integer, intent(out) :: rc
    character(len=:), allocatable, intent(out) :: out_text, err_text
    character(len=:), allocatable, intent(out) :: msg
    logical, intent(out) :: failed
    character(len=:), allocatable :: engine, workdir
    logical :: timed_out
    failed = .false.
    msg = ""
    rc = 0
    out_text = ""
    err_text = ""
    call driver_ensure_engine(engine, msg, failed)
    if (failed) return
    if (len_trim(cwd) > 0) then
       workdir = cwd
    else
       call driver_repo_root(workdir)
    end if
    call driver_run_capture(driver_quote(engine)//" "// &
                            driver_quote(scene_path), workdir, &
                            timeout, rc, out_text, err_text, timed_out)
    if (timed_out) then
       msg = "the Forge3D engine timed out after "// &
             trim(int_str(int(timeout, int64)))//" seconds while "// &
             "running '"//scene_path//"'. help: try a smaller "// &
             "scene, or increase the timeout."
       failed = .true.
       return
    end if
    ! Python's OSError branch (engine not executable): the shell
    ! reports 126/127 for a non-executable/missing file.  This is an
    ! approximation -- a scene could make the engine exit 126/127
    ! itself, in which case Python would return it and we raise.
    ! Documented divergence.
    if (rc == 126 .or. rc == 127) then
       if (.not. driver_file_exists(engine)) then
          msg = "cannot run the Forge3D engine '"//engine//"'. "// &
                "help: check that bin/engine3d exists and is "// &
                "executable; delete it and try again to force a "// &
                "rebuild if it is corrupt."
          failed = .true.
          return
       end if
    end if
  end subroutine driver_run_engine

  ! ------------------------------------------------------------------
  ! Incremental build manifest (v3.0 Phase 6, Seat X)
  !
  ! A build records, next to its outputs, a small line-based text
  ! manifest (written by the CLI into the output directory as
  ! .f3dc-manifest-<stem>):
  !
  !   f3dc-manifest 1
  !   stem <stem>
  !   out <output file name>            (one per expected output)
  !   dep <sha256hex> <size> <abs path> (one per dependency)
  !   dep MISSING 0 <abs path>          (dependency absent at build)
  !
  ! Dependencies are every file whose content can change the build
  ! artifacts: the source file, imported part files, loaded OBJ /
  ! glTF files (+ a glTF's external buffer/image URIs), texture
  ! slot files, the HTML runtime/template inputs, and the f3dc
  ! binary itself.  driver_manifest_check recomputes every entry:
  ! the manifest matches only when the header/stem are intact,
  ! the recorded output set equals the expected one, every output
  ! still exists, and every dependency is byte-identical (same
  ! size + SHA-256) or still missing.  Anything else -- absent or
  ! corrupt manifest, changed/missing/extra dependency, missing
  ! output -- is a miss and the caller performs a full build.
  ! ------------------------------------------------------------------

  !> SHA-256 hex digest of a file's bytes; OK=.false. when the
  !! file does not exist or cannot be read.  NOTE: the file must
  !! be opened read-only (as sha256_file_hex does) -- a helper
  !! that opens without ACTION= makes gfortran open read-write,
  !! and the kernel refuses a read-write open of a RUNNING
  !! executable (ETXTBSY), which would silently hash "" for the
  !! f3dc binary itself (one of the manifest's dependencies).
  subroutine driver_file_sha256(path, hex, ok)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: hex
    logical, intent(out) :: ok
    ! Phase 8: delegate to the streaming file hasher in
    ! f3dc_emit_common (64 KiB chunks through the block-wise
    ! context API; the file is never held whole).  Digests are
    ! bit-identical to the sha256_hex path this replaces.
    hex = ""
    call sha256_file_hex(path, hex, ok)
  end subroutine driver_file_sha256

  subroutine driver_file_size(path, sz, ok)
    character(len=*), intent(in) :: path
    integer, intent(out) :: sz
    logical, intent(out) :: ok
    logical :: there
    inquire (file=path, exist=there, size=sz)
    ok = there
    if (.not. there) sz = -1
  end subroutine driver_file_size

  !> Write MANIFEST_PATH for STEM with the given output names and
  !! dependency paths (duplicates dropped).  Best effort: a failed
  !! write simply means the next build cannot skip.
  subroutine driver_manifest_write(manifest_path, stem, out_names, &
                                   dep_paths, n_deps)
    character(len=*), intent(in) :: manifest_path, stem
    character(len=*), intent(in) :: out_names(:), dep_paths(:)
    integer, intent(in) :: n_deps
    character(len=:), allocatable :: text, hex, p
    type(str_builder) :: sb
    integer :: i, j, unit, ios, sz
    logical :: ok, dup
    call sb_init(sb)
    call sb_add(sb, "f3dc-manifest 1")
    call sb_add(sb, achar(10))
    call sb_add(sb, "stem ")
    call sb_add(sb, stem)
    call sb_add(sb, achar(10))
    do i = 1, size(out_names)
       call sb_add(sb, "out ")
       call sb_add(sb, trim(out_names(i)))
       call sb_add(sb, achar(10))
    end do
    do i = 1, n_deps
       p = trim(dep_paths(i))
       if (len_trim(p) == 0) cycle
       dup = .false.
       do j = 1, i - 1
          if (trim(dep_paths(j)) == p) dup = .true.
       end do
       if (dup) cycle
       call driver_file_size(p, sz, ok)
       if (ok) then
          call driver_file_sha256(p, hex, ok)
       end if
       if (ok) then
          call sb_add(sb, "dep ")
          call sb_add(sb, hex)
          call sb_add(sb, " ")
          call sb_add(sb, trim(int_str(int(sz, int64))))
          call sb_add(sb, " ")
          call sb_add(sb, p)
          call sb_add(sb, achar(10))
       else
          call sb_add(sb, "dep MISSING 0 ")
          call sb_add(sb, p)
          call sb_add(sb, achar(10))
       end if
    end do
    text = sb_text(sb)
    open (newunit=unit, file=manifest_path, access="stream", &
          form="unformatted", status="replace", iostat=ios)
    if (ios /= 0) return
    if (len(text) > 0) write (unit, iostat=ios) text
    close (unit)
  end subroutine driver_manifest_write

  !> MATCH=.true. only when the stored manifest is a genuine match
  !! for STEM and the expected outputs (see the section header).
  subroutine driver_manifest_check(manifest_path, stem, out_dir, &
                                   exp_outs, match)
    character(len=*), intent(in) :: manifest_path, stem, out_dir
    character(len=*), intent(in) :: exp_outs(:)
    logical, intent(out) :: match
    character(len=:), allocatable :: text, line, hex, p, stored_hex
    integer :: pos, nl, i, n_out_seen, n_dep_seen, f1, f2, f3, sz
    integer :: stored_sz
    logical :: ok, seen
    match = .false.
    if (.not. driver_file_exists(manifest_path)) return
    text = read_all(manifest_path)
    if (len(text) == 0) return
    n_out_seen = 0
    n_dep_seen = 0
    pos = 1
    block
      logical :: first_line
      first_line = .true.
      do while (pos <= len(text))
       nl = index(text(pos:), achar(10))
       if (nl == 0) then
          line = text(pos:)
          pos = len(text) + 1
       else
          line = text(pos:pos + nl - 2)
          pos = pos + nl
       end if
       if (len(line) == 0) cycle
       if (first_line) then
          first_line = .false.
          if (line /= "f3dc-manifest 1") return
          cycle
       end if
       if (starts_with_str(line, "stem ")) then
          if (line(6:) /= stem) return
       else if (starts_with_str(line, "out ")) then
          n_out_seen = n_out_seen + 1
          seen = .false.
          do i = 1, size(exp_outs)
             if (trim(exp_outs(i)) == line(5:)) seen = .true.
          end do
          if (.not. seen) return
          if (.not. driver_file_exists(out_dir//"/"//line(5:))) &
             return
       else if (starts_with_str(line, "dep ")) then
          n_dep_seen = n_dep_seen + 1
          ! Fields: dep <hex|MISSING> <size> <path (may hold spaces)>
          f1 = index(line(5:), " ")
          if (f1 == 0) return
          stored_hex = line(5:5 + f1 - 2)
          f2 = 5 + f1
          f3 = index(line(f2:), " ")
          if (f3 == 0) return
          read (line(f2:f2 + f3 - 2), *, iostat=sz) stored_sz
          if (sz /= 0) return
          p = line(f2 + f3:)
          if (stored_hex == "MISSING") then
             if (driver_file_exists(p)) return
          else
             call driver_file_size(p, sz, ok)
             if (.not. ok) return
             if (sz /= stored_sz) return
             call driver_file_sha256(p, hex, ok)
             if (.not. ok) return
             if (hex /= stored_hex) return
          end if
       else
          return  ! unknown line: corrupt manifest
       end if
      end do
    end block
    if (n_out_seen /= size(exp_outs)) return
    if (n_dep_seen == 0) return
    match = .true.
  end subroutine driver_manifest_check

  pure logical function starts_with_str(s, prefix)
    character(len=*), intent(in) :: s, prefix
    starts_with_str = .false.
    if (len(prefix) > len(s)) return
    starts_with_str = (s(1:len(prefix)) == prefix)
  end function starts_with_str

  ! ------------------------------------------------------------------
  ! Stage timing (v3.0 Phase 8)
  !
  ! Pure bookkeeping for `f3dc profile` and the preview toolbar:
  ! no I/O and no behaviour change to any procedure above.
  !
  !   driver_timing_reset()   clears all recorded stages and
  !                           restarts the master clock.
  !   driver_timing_mark(s)   records the elapsed milliseconds
  !                           since the previous mark (or since
  !                           reset, for the first mark) under the
  !                           stage name S; repeated marks for the
  !                           same stage accumulate.
  !   driver_timing_ms(s)     accumulated milliseconds for S, or
  !                           -1.0_real64 when S was never marked.
  !
  ! The clock is system_clock (real64 milliseconds).  COUNT_RATE
  ! and COUNT_MAX are read once, at reset; a mark made without a
  ! preceding reset implicitly starts the clock and records zero
  ! elapsed time for that mark.  Wraparound is handled by counting
  ! through COUNT_MAX back to zero.  At most TIMING_MAX_STAGES
  ! distinct stages are kept; marks for a new stage beyond that
  ! cap are dropped (the master clock still advances, so later
  ! marks for known stages are not charged for the dropped time).
  ! ------------------------------------------------------------------

  subroutine driver_timing_reset()
    integer(int64) :: now_count, rate, max_count
    call system_clock(count=now_count, count_rate=rate, &
                      count_max=max_count)
    timing_names = ""
    timing_totals = 0.0_real64
    timing_n = 0
    timing_last = now_count
    timing_rate = rate
    timing_max = max_count
    timing_started = .true.
  end subroutine driver_timing_reset

  subroutine driver_timing_mark(stage)
    character(len=*), intent(in) :: stage
    integer(int64) :: now_count, delta
    real(real64) :: elapsed_ms
    integer :: i, idx
    if (.not. timing_started) call driver_timing_reset()
    call system_clock(count=now_count)
    if (now_count >= timing_last) then
       delta = now_count - timing_last
    else if (timing_max > 0_int64) then
       ! Wrapped: ticks left before the wrap, plus the tick that
       ! lands on zero, plus the ticks already past zero.
       delta = (timing_max - timing_last) + now_count + 1_int64
    else
       delta = 0_int64
    end if
    timing_last = now_count
    elapsed_ms = 0.0_real64
    if (timing_rate > 0_int64) then
       elapsed_ms = real(delta, real64) * 1000.0_real64 / &
                    real(timing_rate, real64)
    end if
    idx = 0
    do i = 1, timing_n
       if (timing_names(i) == stage) then
          idx = i
          exit
       end if
    end do
    if (idx == 0) then
       if (timing_n >= TIMING_MAX_STAGES) return
       timing_n = timing_n + 1
       idx = timing_n
       timing_names(idx) = stage
       timing_totals(idx) = 0.0_real64
    end if
    timing_totals(idx) = timing_totals(idx) + elapsed_ms
  end subroutine driver_timing_mark

  function driver_timing_ms(stage) result(ms)
    character(len=*), intent(in) :: stage
    real(real64) :: ms
    integer :: i
    ms = -1.0_real64
    do i = 1, timing_n
       if (timing_names(i) == stage) then
          ms = timing_totals(i)
          return
       end if
    end do
  end function driver_timing_ms

end module f3dc_driver
