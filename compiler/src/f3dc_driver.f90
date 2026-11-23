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
module f3dc_driver
  use, intrinsic :: iso_fortran_env, only: int64
  use, intrinsic :: iso_c_binding, only: c_int, c_char, c_null_char
  implicit none
  private

  public :: driver_repo_root, driver_find_tool
  public :: driver_ensure_engine, driver_run_engine
  public :: driver_run_capture, driver_quote, driver_cwd
  public :: driver_file_exists, driver_is_dir, driver_abs_path

  ! _TAIL_CHARS / _TAIL_LINES in driver.py.
  integer, parameter :: TAIL_CHARS = 2000
  integer, parameter :: TAIL_LINES = 30

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
    integer :: n, i, top
    logical :: absolute
    if (len(path) > 0 .and. path(1:1) == "/") then
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
         if (j > len(full) .or. full(j:j) == "/") then
            n = n + 1
            if (j > start) then
               parts(n) = full(start:j - 1)
            else
               parts(n) = ""
            end if
            start = j + 1
         end if
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
    out = ""
    if (absolute) out = "/"
    do i = 1, top
       if (i > 1) out = out//"/"
       out = out//trim(parts(i))
    end do
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
    integer :: i
    out = "'"
    do i = 1, len(s)
       if (s(i:i) == "'") then
          out = out//"'\''"
       else
          out = out//s(i:i)
       end if
    end do
    out = out//"'"
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
    logical :: have_timeout
    integer :: pid
    pid = c_getpid()
    base = "/tmp/f3dc_driver_"//trim(int_str(int(pid, int64)))
    call driver_find_tool("timeout", tpath, have_timeout)
    full = ""
    if (len_trim(cwd) > 0) full = "cd "//driver_quote(cwd)//" && "
    if (have_timeout .and. timeout > 0) then
       full = full//"timeout -k 5 "//trim(int_str(int(timeout, int64)))//" "
    end if
    full = full//cmd//" >"//driver_quote(base//".out")// &
           " 2>"//driver_quote(base//".err")
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
    integer :: i, nlines, keep_from, pos
    combined = ""
    if (len(out_text) > 0) combined = out_text
    if (len(err_text) > 0) then
       if (len(combined) > 0) combined = combined//achar(10)
       combined = combined//err_text
    end if
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
    do while (a <= b .and. is_ws(s(a:a)))
       a = a + 1
    end do
    do while (b >= a .and. is_ws(s(b:b)))
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
       if (len(tail) > 0) msg = msg//achar(10)//"last build output:"// &
                                achar(10)//tail
       failed = .true.
       return
    end if
    if (rc /= 0) then
       tail = output_tail(out_t, err_t)
       msg = "building the Forge3D engine failed: 'make' exited "// &
             "with code "//trim(int_str(int(rc, int64)))//" in '"// &
             root_path//"'. help: run 'make' by hand there and fix "// &
             "the errors shown, then try again."
       if (len(tail) > 0) msg = msg//achar(10)//"last build output:"// &
                                achar(10)//tail
       failed = .true.
       return
    end if
    if (.not. driver_file_exists(engine)) then
       tail = output_tail(out_t, err_t)
       msg = "building the Forge3D engine did not produce the "// &
             "expected file '"//engine//"', even though 'make' "// &
             "reported success. help: run 'make' by hand in '"// &
             root_path//"' and check that it creates bin/engine3d."
       if (len(tail) > 0) msg = msg//achar(10)//"last build output:"// &
                                achar(10)//tail
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

end module f3dc_driver
