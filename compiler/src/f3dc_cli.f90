! f3dc_cli.f90 -- program main for the native Forge3D compiler.
!
! Port of tools/f3dc/cli.py behaviour (see compiler/DESIGN.md, the
! binding contract).  This is the build-skeleton version: argument
! parsing, --version, --help and the usage-error surface match cli.py
! today; the individual commands dispatch through the single
! select-case in the main program and currently land in
! not_yet_implemented() until their modules (f3dc_driver & friends)
! are ported.  Extend by replacing a stub branch -- do not grow a
! second dispatch site.
!
! Exit codes (cli.py): 0 ok, 1 scene errors, 2 usage, 3 IO,
! 4 toolchain, 70 unexpected internal error.  The not-yet-ported
! commands use 70 with an E9000 diagnostic, mirroring cli.py's
! internal-error surface, so scripts can tell "not built yet" apart
! from a usage error.
!
! VERSION must match VERSION in tools/f3dc/cli.py ("0.1.0").

program f3dc
  use, intrinsic :: iso_fortran_env, only: output_unit, error_unit
  implicit none

  character(len=*), parameter :: VERSION = "0.1.0"
  ! _COMMANDS in cli.py, in cli.py's order (used in the error text).
  character(len=*), parameter :: COMMAND_LIST = &
       "run, build, check, new, fmt, doctor, preview"

  integer :: nargs, len_arg, stat
  character(len=4096) :: arg

  nargs = command_argument_count()

  ! No arguments: cli.py discovers a scene in the cwd (scene.f3d /
  ! main.f3d preferred) and runs it; with no scene it prints the
  ! help to stderr plus an error line and exits 2.  The single-*.f3d
  ! glob fallback of _discover_scene() is not replicated yet.
  if (nargs == 0) then
     if (file_exists("scene.f3d")) then
        call not_yet_implemented("run")
     else if (file_exists("main.f3d")) then
        call not_yet_implemented("run")
     else
        call print_help(error_unit)
        write (error_unit, '(A)') &
             "error: no .f3d file here -- create one:  f3dc new hello"
        call exit(2)
     end if
  end if

  call get_command_argument(1, arg, len_arg, stat)
  if (stat /= 0) then
     write (error_unit, '(A)') "error E9000: internal f3dc error --&
          & could not read command arguments"
     call exit(70)
  end if
  arg = arg(1:len_arg)

  ! The one and only command dispatch (cli.py: _dispatch + argparse).
  select case (trim(arg))
  case ("--version")
     write (output_unit, '(A)') "f3dc "//VERSION
  case ("-h", "--help")
     call print_help(output_unit)
  case ("run")
     call not_yet_implemented("run")
  case ("build")
     call not_yet_implemented("build")
  case ("check")
     call not_yet_implemented("check")
  case ("new")
     call not_yet_implemented("new")
  case ("fmt")
     call not_yet_implemented("fmt")
  case ("doctor")
     call not_yet_implemented("doctor")
  case ("preview")
     call not_yet_implemented("preview")
  case default
     if (len_trim(arg) > 0 .and. arg(1:1) == "-") then
        ! argparse: an unrecognised option is a usage error.
        call usage_error("unrecognized arguments: "//trim(arg))
     else if (is_scene_file(trim(arg))) then
        ! Bare form: f3dc <file.f3d> == f3dc run <file.f3d>.
        call not_yet_implemented("run")
     else
        call usage_error("unknown command '"//trim(arg)//&
             "' (commands: "//COMMAND_LIST//&
             "; or pass a scene file to run it)")
     end if
  end select

contains

  subroutine print_help(unit)
    integer, intent(in) :: unit
    ! Byte-for-byte the argparse --help text of cli.py (Python 3.12
    ! argparse layout, help position column 24).
    write (unit, '(A)') "usage: f3dc [-h] [--version] {run,build,check,new,preview,fmt,doctor} ..."
    write (unit, '(A)') ""
    write (unit, '(A)') "Forge3D compiler -- compile and run .f3d scenes, the easy way"
    write (unit, '(A)') ""
    write (unit, '(A)') "positional arguments:"
    write (unit, '(A)') "  {run,build,check,new,preview,fmt,doctor}"
    write (unit, '(A)') "    run                 build, compile the engine and render"
    write (unit, '(A)') "    build               compile to build/ (Fortran + JSON + JS + HTML)"
    write (unit, '(A)') "    check               validate only -- no files written"
    write (unit, '(A)') "    new                 create <name>.f3d from the starter template"
    write (unit, '(A)') "    preview             real-time preview in the browser -- recompiles and"
    write (unit, '(A)') "                        reloads on save"
    write (unit, '(A)') "    fmt                 print the canonical .f3d form to stdout"
    write (unit, '(A)') "    doctor              check python / gfortran / make / convert and print"
    write (unit, '(A)') "                        fixes"
    write (unit, '(A)') ""
    write (unit, '(A)') "options:"
    write (unit, '(A)') "  -h, --help            show this help message and exit"
    write (unit, '(A)') "  --version             show program's version number and exit"
  end subroutine print_help

  subroutine usage_error(msg)
    ! argparse parser.error(): usage line, then "f3dc: error: ...",
    ! both on stderr; exit code 2.
    character(len=*), intent(in) :: msg
    write (error_unit, '(A)') "usage: f3dc [-h] [--version] {run,build,check,new,preview,fmt,doctor} ..."
    write (error_unit, '(A)') "f3dc: error: "//msg
    call exit(2)
  end subroutine usage_error

  subroutine not_yet_implemented(command)
    character(len=*), intent(in) :: command
    write (error_unit, '(A)') "error E9000: command '"//command//&
         "' is not yet implemented in the native f3dc"//&
         " (Fortran port in progress -- the Python tools/f3dc"//&
         " still provides it)"
    call exit(70)
  end subroutine not_yet_implemented

  logical function file_exists(path)
    character(len=*), intent(in) :: path
    inquire (file=path, exist=file_exists)
  end function file_exists

  logical function is_scene_file(name)
    ! cli.py: a bare argument ending in .f3d/.json/.obj (any case)
    ! or naming an existing file is treated as `f3dc run <file>`.
    character(len=*), intent(in) :: name
    is_scene_file = ends_with_ci(name, ".f3d") .or. &
                    ends_with_ci(name, ".json") .or. &
                    ends_with_ci(name, ".obj") .or. &
                    file_exists(name)
  end function is_scene_file

  logical function ends_with_ci(str, suffix)
    character(len=*), intent(in) :: str, suffix
    integer :: ls, lf, i, ca, cf
    ls = len_trim(str)
    lf = len(suffix)
    ends_with_ci = .false.
    if (lf > ls) return
    do i = 1, lf
       ca = iachar(str(ls - lf + i:ls - lf + i))
       cf = iachar(suffix(i:i))
       if (ca >= iachar("A") .and. ca <= iachar("Z")) ca = ca + 32
       if (cf >= iachar("A") .and. cf <= iachar("Z")) cf = cf + 32
       if (ca /= cf) return
    end do
    ends_with_ci = .true.
  end function ends_with_ci

end program f3dc
