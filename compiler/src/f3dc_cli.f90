! f3dc_cli.f90 -- program main for the native Forge3D compiler.
!
! Full port of tools/f3dc/cli.py (1,082 lines, read in full; see
! compiler/DESIGN.md, the binding contract).  Python is the oracle.
! The single select-case dispatch of the build skeleton is kept --
! extend by replacing a branch, never by adding a second dispatch.
!
! Exit codes (cli.py): 0 ok, 1 scene errors, 2 usage (argparse),
! 3 IO, 4 toolchain, 70 unexpected internal error.
!
! The compiler version is defined here (the VERSION parameter
! below); it is the single source of truth for the version string.
!
! ---------------------------------------------------------------------
! Sibling entry points this file uses (all LANDED in compiler/src
! during this seat, with these real signatures):
!
!   f3dc_validate :: subroutine f3dc_validate(prog, bag, base_dir,
!                        ir, ok)      ! validate.validate(...)
!   f3dc_optimize :: subroutine optimize(scene_in, bag, level,
!                        scene_out)   ! optimize.optimize(scene,bag)
!   f3dc_desugar  :: subroutine desugar(prog_in, bag, base_dir, prog_out)
!   f3dc_compat   :: function is_legacy_json(text) result(logical)
!                    subroutine ast_from_legacy_json(text, bag, prog)
!                    subroutine ast_from_obj(text, bag, prog)
!   f3dc_ir       :: subroutine ir_from_json(text, ir, ok)
!   f3dc_emit_fortran :: subroutine emit_scene_text(ir, text)
!                        subroutine emit_fortran_program(ir, text)
!   f3dc_emit_json    :: subroutine emit_json_v2(ir, text)
!                        subroutine emit_json_legacy(ir, text [,bag])
!   f3dc_emit_js      :: subroutine emit_js(ir, text [,source_name])
!   f3dc_emit_html    :: subroutine emit_html(ir, runtime_js,
!                        scene_js, template_arg, repo_root, text)
!                        subroutine emit_html_runtime_js(root, text)
!   f3dc_preview  :: subroutine preview_serve(scene_path, port,
!                        open_browser, code) -- native port of
!                    preview.py serve(), with compiler/preview_http.c
!                    as its socket helper.
!
! IR / AST values are dyn dicts (DESIGN.md): IR keys mirror the
! ir_nodes dataclass fields (name, width, height, bg, camera,
! lights, objects, animations, outputs, extensions); AST statement
! kinds are discriminated by key presence (the parser's dyn dicts
! carry no class tag -- see format_stmt).
!
! Known divergences from the Python oracle (all flagged in the
! seat report): _tri_estimate uses cli.py's fallback table only
! (validate._estimate_triangles is not callable until f3dc_validate
! exports a mirror); the emitter fallbacks inside cli.py cannot
! trigger here (a missing emitter module is a link failure, not a
! runtime fallback); doctor's "python:" line is reconstructed from
! python3 on PATH; OSError message texts in E501/E502 paths are
! iostat-based approximations.
program f3dc
  use, intrinsic :: iso_fortran_env, only: output_unit, error_unit, &
       int64, real64
  use f3dc_str, only: fmt_int, fmt_real, to_lower, path_stem, &
       path_dirname, path_basename, path_extension
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_list_push, &
       dyn_list_len, dyn_list_at, dyn_dict_set, dyn_dict_get, &
       dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
       DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, make_span, make_diagnostic, &
       make_diagnostic_span, error_bag_add, error_bag_set_source, &
       error_bag_len, error_bag_has_errors, error_bag_fail_code, &
       error_bag_format_text, error_bag_format_json, &
       error_bag_use_color, error_bag_debug_text
  use f3dc_parser, only: f3dc_parse
  use f3dc_validate, only: f3dc_validate
  use f3dc_ext_geometry, only: eg_estimate => estimate_triangles
  use f3dc_optimize, only: optimize
  use f3dc_desugar, only: desugar
  use f3dc_compat, only: ast_from_obj, ast_from_legacy_json, &
       is_legacy_json
  use f3dc_ir, only: ir_from_json
  use f3dc_emit_fortran, only: emit_scene_text, emit_fortran_program
  use f3dc_emit_json, only: emit_json_v2, emit_json_legacy
  use f3dc_emit_js, only: emit_js
  use f3dc_emit_html, only: emit_html, emit_html_runtime_js
  use f3dc_driver, only: driver_repo_root, driver_find_tool, &
       driver_ensure_engine, driver_run_engine, driver_run_capture, &
       driver_quote, driver_cwd, driver_file_exists, driver_is_dir, &
       driver_abs_path
  use f3dc_preview, only: preview_serve
  implicit none

  character(len=*), parameter :: VERSION = "2.0.0"
  ! _COMMANDS in cli.py, in cli.py's order (used in the error text).
  character(len=*), parameter :: COMMAND_LIST = &
       "run, build, check, new, fmt, doctor, preview"

  ! _LAST in cli.py: state from the most recent compile_pipeline().
  type(dyn) :: last_program
  logical :: last_program_set = .false.
  character(len=:), allocatable :: last_path, last_text

  integer :: rc_main

  call dispatch(rc_main)
  call finish(rc_main)

contains

  ! ------------------------------------------------------------------
  ! Process exit (flush first: Fortran buffers may be lost on exit())
  ! ------------------------------------------------------------------
  subroutine finish(code)
    integer, intent(in) :: code
    flush (output_unit)
    flush (error_unit)
    call exit(code)
  end subroutine finish

  ! ------------------------------------------------------------------
  ! Output helpers (Python print(): text + "\n"; the text itself may
  ! contain newlines, which pass through the formatted write)
  ! ------------------------------------------------------------------
  subroutine out_line(s)
    character(len=*), intent(in) :: s
    write (output_unit, '(A)') s
  end subroutine out_line

  subroutine err_line(s)
    character(len=*), intent(in) :: s
    write (error_unit, '(A)') s
  end subroutine err_line

  ! ------------------------------------------------------------------
  ! Argument access
  ! ------------------------------------------------------------------
  function arg_at(i) result(out)
    integer, intent(in) :: i
    character(len=:), allocatable :: out
    character(len=8192) :: buf
    integer :: ln, stat
    call get_command_argument(i, buf, ln, stat)
    if (stat /= 0) then
       out = ""
    else
       out = buf(1:ln)
    end if
  end function arg_at

  function join_args(first, last) result(out)
    integer, intent(in) :: first, last
    character(len=:), allocatable :: out
    integer :: i
    out = ""
    do i = first, last
       if (i > first) out = out//" "
       out = out//arg_at(i)
    end do
  end function join_args

  ! ------------------------------------------------------------------
  ! Help texts -- byte-for-byte the argparse output of cli.py
  ! (Python 3.12 argparse layout).
  ! ------------------------------------------------------------------
  subroutine print_help(unit)
    integer, intent(in) :: unit
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

  subroutine print_sub_help(cmd)
    character(len=*), intent(in) :: cmd
    select case (cmd)
    case ("run")
       call out_line("usage: f3dc run [-h] [-o OUT] file")
       call out_line("")
       call out_line("positional arguments:")
       call out_line("  file               scene file (.f3d, .json or .obj)")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help         show this help message and exit")
       call out_line("  -o OUT, --out OUT  output directory (default: build/)")
    case ("build")
       call out_line("usage: f3dc build [-h] [-o OUT] [--explain] file")
       call out_line("")
       call out_line("positional arguments:")
       call out_line("  file               scene file (.f3d, .json or .obj)")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help         show this help message and exit")
       call out_line("  -o OUT, --out OUT  output directory (default: build/)")
       call out_line("  --explain          also print the desugared program summary")
    case ("check")
       call out_line("usage: f3dc check [-h] [--explain] [--json] file")
       call out_line("")
       call out_line("positional arguments:")
       call out_line("  file        scene file (.f3d, .json or .obj)")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help  show this help message and exit")
       call out_line("  --explain   also print the desugared program summary")
       call out_line("  --json      print diagnostics as JSON")
    case ("new")
       call out_line("usage: f3dc new [-h] name")
       call out_line("")
       call out_line("positional arguments:")
       call out_line("  name        scene name, with or without .f3d")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help  show this help message and exit")
    case ("preview")
       call out_line("usage: f3dc preview [-h] [--port PORT] [--no-browser] file")
       call out_line("")
       call out_line("positional arguments:")
       call out_line("  file          scene file (.f3d, .json or .obj)")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help    show this help message and exit")
       call out_line("  --port PORT   local port to serve on (default: 8765; 0 picks a free one)")
       call out_line("  --no-browser  do not open a browser tab automatically")
    case ("fmt")
       call out_line("usage: f3dc fmt [-h] file")
       call out_line("")
       call out_line("positional arguments:")
       call out_line("  file        scene file (.f3d, .json or .obj)")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help  show this help message and exit")
    case ("doctor")
       call out_line("usage: f3dc doctor [-h]")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help  show this help message and exit")
    end select
  end subroutine print_sub_help

  function sub_usage(cmd) result(out)
    character(len=*), intent(in) :: cmd
    character(len=:), allocatable :: out
    select case (cmd)
    case ("run");    out = "usage: f3dc run [-h] [-o OUT] file"
    case ("build");  out = "usage: f3dc build [-h] [-o OUT] [--explain] file"
    case ("check");  out = "usage: f3dc check [-h] [--explain] [--json] file"
    case ("new");    out = "usage: f3dc new [-h] name"
    case ("preview"); out = "usage: f3dc preview [-h] [--port PORT] [--no-browser] file"
    case ("fmt");    out = "usage: f3dc fmt [-h] file"
    case ("doctor"); out = "usage: f3dc doctor [-h]"
    case default;    out = "usage: f3dc [-h] [--version] {run,build,check,new,preview,fmt,doctor} ..."
    end select
  end function sub_usage

  ! argparse parser.error() on the TOP parser (unrecognized args in
  ! cli.py surface here because _dispatch re-parses with the main
  ! parser): main usage + "f3dc: error: ..." on stderr, exit 2.
  subroutine usage_error_main(msg)
    character(len=*), intent(in) :: msg
    call err_line("usage: f3dc [-h] [--version] {run,build,check,new,preview,fmt,doctor} ...")
    call err_line("f3dc: error: "//msg)
    call finish(2)
  end subroutine usage_error_main

  ! argparse error on a sub-parser: sub usage + "f3dc <cmd>: error:".
  subroutine usage_error_sub(cmd, msg)
    character(len=*), intent(in) :: cmd, msg
    call err_line(sub_usage(cmd))
    call err_line("f3dc "//cmd//": error: "//msg)
    call finish(2)
  end subroutine usage_error_sub

  ! ------------------------------------------------------------------
  ! Small string helpers
  ! ------------------------------------------------------------------
  subroutine sadd(buf, piece)
    character(len=:), allocatable, intent(inout) :: buf
    character(len=*), intent(in) :: piece
    if (.not. allocated(buf)) buf = ""
    buf = buf//piece
  end subroutine sadd

  logical function starts_with(s, prefix)
    character(len=*), intent(in) :: s, prefix
    starts_with = .false.
    if (len(prefix) > len(s)) return
    starts_with = (s(1:len(prefix)) == prefix)
  end function starts_with

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

  ! Python str.strip() approximation (space/tab/CR/LF).
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
  ! File helpers
  ! ------------------------------------------------------------------
  logical function file_exists(path)
    character(len=*), intent(in) :: path
    file_exists = driver_file_exists(path)
  end function file_exists

  subroutine read_file(path, text, ok)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: text
    logical, intent(out) :: ok
    integer :: unit, ios, sz
    logical :: there
    ok = .false.
    text = ""
    inquire (file=path, exist=there, size=sz)
    if (.not. there) return
    open (newunit=unit, file=path, access="stream", &
          form="unformatted", status="old", iostat=ios)
    if (ios /= 0) return
    allocate (character(len=max(sz, 0)) :: text)
    if (sz > 0) read (unit, iostat=ios) text
    close (unit)
    ok = (ios == 0)
  end subroutine read_file

  subroutine write_file(path, text, ok)
    character(len=*), intent(in) :: path, text
    logical, intent(out) :: ok
    integer :: unit, ios
    open (newunit=unit, file=path, access="stream", &
          form="unformatted", status="replace", iostat=ios)
    if (ios /= 0) then
       ok = .false.
       return
    end if
    if (len(text) > 0) write (unit, iostat=ios) text
    close (unit, iostat=ios)
    ok = (ios == 0)
  end subroutine write_file

  subroutine delete_quiet(path)
    character(len=*), intent(in) :: path
    integer :: unit, ios
    open (newunit=unit, file=path, status="old", iostat=ios)
    if (ios == 0) close (unit, status="delete")
  end subroutine delete_quiet

  subroutine mkdir_p(path)
    character(len=*), intent(in) :: path
    integer :: rc
    call execute_command_line("mkdir -p "//driver_quote(path), &
                              exitstat=rc)
  end subroutine mkdir_p

  ! Lowercased final suffix of a path (pathlib suffix.lower()).
  function suffix_lower(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    out = to_lower(path_extension(path))
  end function suffix_lower

  ! cli.py _get(obj, *names, default): first non-null dyn value among
  ! the named dict keys; dyn_null when none / not a dict.
  function dget(d, key) result(v)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(dyn) :: v
    v = dyn_copy(dyn_dict_get(d, key))
  end function dget

  function dget2(d, key1, key2) result(v)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key1, key2
    type(dyn) :: v
    v = dget(d, key1)
    if (v%kind == DYN_K_NULL) v = dget(d, key2)
  end function dget2

  logical function dhas(d, key)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    dhas = dyn_dict_has(d, key)
  end function dhas

  logical function dnonnull(d, key)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(dyn) :: v
    v = dget(d, key)
    dnonnull = v%kind /= DYN_K_NULL
  end function dnonnull

  function dstr(d, key, default) result(out)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key, default
    character(len=:), allocatable :: out
    type(dyn) :: v
    v = dget(d, key)
    if (v%kind == DYN_K_STR) then
       out = v%s
    else
       out = default
    end if
  end function dstr

  ! cli.py _fmt_num: bool -> true/false, int -> str, float -> int
  ! spelling when integral else repr, str -> itself.
  function fmt_num(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    select case (v%kind)
    case (DYN_K_BOOL)
       if (v%b) then
          out = "true"
       else
          out = "false"
       end if
    case (DYN_K_INT)
       out = fmt_int(v%i)
    case (DYN_K_REAL)
       if (v%r == aint(v%r) .and. abs(v%r) < 9.0e15_real64) then
          out = fmt_int(int(v%r, int64))
       else
          out = fmt_real(v%r)
       end if
    case (DYN_K_STR)
       out = v%s
    case (DYN_K_DICT)
       out = py_repr(v)
    case default
       out = ""
    end select
  end function fmt_num

  ! Python repr() of a dyn value, for the dict-valued prop corner
  ! (compat "tris" objects): _fmt_num(dict) is str(dict) in cli.py,
  ! which is repr with single-quoted strings, True/False/None and
  ! float reprs ("0.0", not the canonical .f3d "0").
  recursive function py_repr(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer :: i
    type(dyn) :: el
    select case (v%kind)
    case (DYN_K_NULL)
       out = "None"
    case (DYN_K_BOOL)
       if (v%b) then
          out = "True"
       else
          out = "False"
       end if
    case (DYN_K_INT)
       out = fmt_int(v%i)
    case (DYN_K_REAL)
       out = fmt_real(v%r)
    case (DYN_K_STR)
       out = "'"//v%s//"'"
    case (DYN_K_LIST)
       out = "["
       do i = 1, dyn_list_len(v)
          el = dyn_list_at(v, i)
          if (i > 1) out = out//", "
          out = out//py_repr(el)
       end do
       out = out//"]"
    case (DYN_K_DICT)
       out = "{"
       do i = 1, dyn_dict_len(v)
          if (i > 1) out = out//", "
          out = out//"'"//dyn_dict_key_at(v, i)//"': "// &
                 py_repr(dyn_copy(dyn_dict_get(v, &
                         dyn_dict_key_at(v, i))))
       end do
       out = out//"}"
    case default
       out = ""
    end select
  end function py_repr

  ! cli.py _fmt_vec: list -> space-joined _fmt_num, else _fmt_num.
  ! A nested list element is a Python tuple there, and _fmt_num
  ! renders it with str(): "(0, 0, 0)".
  recursive function fmt_vec(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer :: i
    type(dyn) :: el
    if (v%kind /= DYN_K_LIST) then
       out = fmt_num(v)
       return
    end if
    out = ""
    do i = 1, dyn_list_len(v)
       el = dyn_list_at(v, i)
       if (i > 1) out = out//" "
       if (el%kind == DYN_K_LIST) then
          out = out//fmt_tuple(el)
       else
          out = out//fmt_num(el)
       end if
    end do
  end function fmt_vec


  ! Python str() of a tuple: "(a, b, c)".
  recursive function fmt_tuple(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer :: i
    type(dyn) :: el
    out = "("
    do i = 1, dyn_list_len(v)
       el = dyn_list_at(v, i)
       if (i > 1) out = out//", "
       if (el%kind == DYN_K_LIST) then
          out = out//fmt_tuple(el)
       else
          out = out//fmt_num(el)
       end if
    end do
    out = out//")"
  end function fmt_tuple

  ! Class name for the extension statement kinds, whose dyn dicts
  ! carry no tag: discriminated by their parser key signatures
  ! (cli.py's unknown-kind branch prints type(stmt).__name__).
  function ext_class_name(stmt) result(out)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable :: out
    type(dyn) :: props
    props = dget(stmt, "props")
    if (dhas(stmt, "amount")) then
       out = "FilterStmt"
    else if (dhas(stmt, "expr")) then
       out = "ShaderStmt"
    else if (dhas(stmt, "factor")) then
       out = "MorphStmt"
    else if (dhas(stmt, "bone")) then
       out = "SkinStmt"
    else if (dhas(stmt, "source")) then
       out = "InstanceStmt"
    else if (dhas(stmt, "content")) then
       out = "TextStmt"
    else if (dhas(stmt, "time")) then
       out = "KeyStmt"
    else if (dhas(stmt, "duration") .and. dhas(stmt, "loop")) then
       out = "KeysStmt"
    else if (dhas(stmt, "colour")) then
       if (dhas(props, "count")) then
          out = "ParticlesStmt"
       else
          out = "SpriteStmt"
       end if
    else if (dhas(props, "name")) then
       out = "BoneStmt"
    else
       out = ""
    end if
  end function ext_class_name

  ! String form of a colour-ish value: str passes through, a list
  ! renders Python-list style "[r, g, b]" (str() of a tuple in
  ! cli.py's colour slot is an edge case; approximation).
  function fmt_colour(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer :: i
    if (v%kind == DYN_K_STR) then
       out = v%s
    else if (v%kind == DYN_K_LIST) then
       out = "["
       do i = 1, dyn_list_len(v)
          if (i > 1) out = out//", "
          out = out//fmt_num(dyn_list_at(v, i))
       end do
       out = out//"]"
    else
       out = fmt_num(v)
    end if
  end function fmt_colour

  ! ------------------------------------------------------------------
  ! Diagnostics (cli.py _print_diagnostics / _fail_code)
  ! ------------------------------------------------------------------
  subroutine print_diagnostics(bag, as_json)
    type(error_bag_t), intent(in) :: bag
    logical, intent(in) :: as_json
    character(len=:), allocatable :: text, dbg
    if (as_json) then
       call out_line(error_bag_format_json(bag))
    else
       ! v2.0 P4: colour when stderr is a TTY unless NO_COLOR is
       ! present (error_bag_use_color); F3DC_DEBUG adds the internal
       ! debug dump after the normal text ("" when unset).
       text = error_bag_format_text(bag, error_bag_use_color())
       if (len(text) > 0) call err_line(text)
       dbg = error_bag_debug_text(bag)
       if (len(dbg) > 0) call err_line(dbg)
    end if
  end subroutine print_diagnostics

  ! ------------------------------------------------------------------
  ! The compile pipeline (cli.py compile_pipeline)
  ! ------------------------------------------------------------------
  subroutine compile_pipeline(path, bag, ir, ok)
    character(len=*), intent(in) :: path
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: ir
    logical, intent(out) :: ok
    character(len=:), allocatable :: text, ext, stem
    type(dyn) :: prog, ir_opt
    logical :: rok, vok, j_ok
    ir = dyn_null()
    ok = .false.
    last_program_set = .false.
    if (.not. file_exists(path)) then
       stem = path_stem(path)
       call error_bag_add(bag, make_diagnostic_span( &
            "E501", "error", "file not found: "//path, &
            make_span(path, 1, 1), &
            why="f3dc can only compile a file that exists", &
            help="check the path, or create a scene with:  "// &
                 "f3dc new "//stem))
       return
    end if
    call read_file(path, text, rok)
    if (.not. rok) then
       call error_bag_add(bag, make_diagnostic_span( &
            "E501", "error", "cannot read "//path//": i/o error", &
            make_span(path, 1, 1), &
            help="check the file permissions and try again"))
       return
    end if
    call error_bag_set_source(bag, text)
    last_path = path
    last_text = text
    ext = suffix_lower(path)
    if (ext == ".obj") then
       call ast_from_obj(text, bag, prog)
    else if (ext == ".json") then
       if (.not. is_legacy_json(text)) then
          ! A v2 IR dump (has "ir_version"): load directly, still
          ! optimize.  Python probes with json.loads + key check;
          ! ir_from_json + a key probe mirrors that here.
          if (index(text, '"ir_version"') > 0) then
             call ir_from_json(text, ir, j_ok)
             if (j_ok) then
                if (error_bag_has_errors(bag)) return
                last_program_set = .false.
                call optimize(ir, bag, 1, ir_opt)
                ir = dyn_copy(ir_opt)
                ok = .true.
                return
             end if
          end if
       end if
       call ast_from_legacy_json(text, bag, prog)
    else
       call f3dc_parse(text, path, bag, prog)
    end if
    last_program = dyn_copy(prog)
    last_program_set = .true.
    if (error_bag_has_errors(bag)) return
    call f3dc_validate(prog, bag, path_dirname(path), ir, vok)
    if (.not. vok .or. error_bag_has_errors(bag)) return
    call optimize(ir, bag, 1, ir_opt)
    ir = dyn_copy(ir_opt)
    ok = .true.
  end subroutine compile_pipeline

  ! ------------------------------------------------------------------
  ! --explain (cli.py _explain_text)
  ! ------------------------------------------------------------------
  function explain_text() result(out)
    character(len=:), allocatable :: out
    type(error_bag_t) :: tmp_bag
    type(dyn) :: desugared, stmts
    character(len=:), allocatable :: line
    integer :: i
    out = ""
    if (.not. last_program_set) return
    if (allocated(last_path)) then
       call desugar(last_program, tmp_bag, path_dirname(last_path), &
                    desugared)
    else
       call desugar(last_program, tmp_bag, ".", desugared)
    end if
    if (desugared%kind /= DYN_K_DICT) return
    out = "desugared program:"
    stmts = dget(desugared, "statements")
    do i = 1, dyn_list_len(stmts)
       call format_stmt(dyn_list_at(stmts, i), line)
       out = out//achar(10)//"  "//line
    end do
  end function explain_text

  ! ------------------------------------------------------------------
  ! Triangle estimate (cli.py _tri_estimate, with validate.py's
  ! _estimate_triangles and ext_geometry.py's estimate_triangles
  ! ported inline below -- f3dc_validate exports only f3dc_validate,
  ! so the estimator cannot be called across the module boundary;
  ! the formulas are mirrored exactly, including the detail
  ! presets.  Python falls back to the table in tri_default when
  ! the estimator raises; here the fallback is used when a prop
  ! has an unexpected dyn kind (the cases that raise in Python).
  ! ------------------------------------------------------------------
  function tri_estimate(ir) result(total)
    type(dyn), intent(in) :: ir
    integer :: total, i, k
    type(dyn) :: objs, obj, tris, props, exts, geom
    character(len=:), allocatable :: prim, gkey
    total = 0
    objs = dget(ir, "objects")
    do i = 1, dyn_list_len(objs)
       obj = dyn_list_at(objs, i)
       tris = dget(obj, "triangles")
       if (tris%kind == DYN_K_LIST) then
          total = total + dyn_list_len(tris)
          cycle
       end if
       prim = dstr(obj, "prim", "")
       if (len(prim) == 0) prim = dstr(obj, "primitive", "")
       props = dyn_dict()
       call dyn_dict_set(props, "segments", dget(obj, "segments"))
       call dyn_dict_set(props, "detail", dget(obj, "detail"))
       call dyn_dict_set(props, "capped", dget(obj, "capped"))
       exts = dget(obj, "extensions")
       geom = dget(exts, "geometry")
       if (geom%kind == DYN_K_DICT) then
          do k = 1, dyn_dict_len(geom)
             gkey = dyn_dict_key_at(geom, k)
             if (dnonnull(geom, gkey)) &
                call dyn_dict_set(props, gkey, dget(geom, gkey))
          end do
       end if
       total = total + estimate_triangles(prim, props)
    end do
  end function tri_estimate

  ! _int(value, None) of validate.py: int/float -> truncated int,
  ! anything else -> "none" (has=.false.).
  subroutine int_or_none(v, val, has)
    type(dyn), intent(in) :: v
    integer, intent(out) :: val
    logical, intent(out) :: has
    has = .true.
    val = 0
    select case (v%kind)
    case (DYN_K_INT)
       val = int(v%i)
    case (DYN_K_REAL)
       val = int(v%r)
    case default
       has = .false.
    end select
  end subroutine int_or_none

  ! _field_from(props, *names): first non-null value among names.
  function field_from(props, names) result(v)
    type(dyn), intent(in) :: props
    character(len=*), intent(in) :: names(:)
    type(dyn) :: v
    integer :: i
    v = dyn_null()
    do i = 1, size(names)
       v = dget(props, trim(names(i)))
       if (v%kind /= DYN_K_NULL) return
    end do
  end function field_from

  integer function estimate_triangles(prim_in, props)
    character(len=*), intent(in) :: prim_in
    type(dyn), intent(in) :: props
    character(len=:), allocatable :: prim, detail
    integer :: segments, rings, s, r, h, sides, ds, tmp
    logical :: has_seg, has_ring, has_tmp, capped
    type(dyn) :: v
    prim = to_lower(prim_in)
    ! Wave D prims: ext_geometry.estimate_triangles.
    select case (prim)
    case ("circle", "ring", "capsule", "tube", "lathe", "extrude", &
          "icosahedron", "octahedron", "tetrahedron", &
          "dodecahedron", "torusknot")
       estimate_triangles = ext_estimate(prim, props)
       return
    end select
    call int_or_none(dget(props, "segments"), segments, has_seg)
    v = field_from(props, [character(len=16) :: "rings", &
                           "height_segments", "height_segs"])
    call int_or_none(v, rings, has_ring)
    v = dget(props, "detail")
    if (v%kind == DYN_K_STR) then
       detail = to_lower(v%s)
       ! _DETAIL (torus: _DETAIL_TORUS; only "low" differs).
       s = 0
       r = 0
       select case (detail)
       case ("low")
          if (prim == "torus") then
             s = 10
          else
             s = 8
          end if
          if (prim == "torus") then
             r = 8
          else
             r = 6
          end if
       case ("med", "medium")
          s = 16
          r = 12
       case ("high")
          s = 32
          r = 24
       end select
       if (s > 0) then
          if (.not. has_seg) then
             segments = s
             has_seg = .true.
          end if
          if (.not. has_ring) then
             rings = r
             has_ring = .true.
          end if
       end if
    end if
    ! capped = not props.get("open") and props.get("capped", True)
    ! is not False.
    capped = .true.
    v = dget(props, "open")
    if (v%kind == DYN_K_BOOL .and. v%b) capped = .false.
    if (v%kind == DYN_K_INT .and. v%i /= 0) capped = .false.
    if (v%kind == DYN_K_STR .and. len(v%s) > 0) capped = .false.
    v = dget(props, "capped")
    if (v%kind == DYN_K_BOOL .and. .not. v%b) capped = .false.
    if (.not. has_seg) segments = 0
    if (.not. has_ring) rings = 0
    select case (prim)
    case ("cube")
       estimate_triangles = 12
    case ("sphere")
       s = segments
       if (s == 0) s = 16
       r = rings
       if (r == 0) r = 12
       estimate_triangles = 2 * s * max(r - 1, 1)
    case ("cylinder")
       s = segments
       if (s == 0) s = 16
       h = rings
       if (h == 0) h = 1
       estimate_triangles = 2 * s * h
       if (capped) estimate_triangles = estimate_triangles + 2 * s
    case ("cone")
       s = segments
       if (s == 0) s = 16
       h = rings
       if (h == 0) h = 1
       estimate_triangles = s * (2 * h - 1)
       if (capped) estimate_triangles = estimate_triangles + s
    case ("plane")
       s = segments
       if (s == 0) s = 1
       call int_or_none(dget(props, "depth_segments"), ds, has_tmp)
       if (.not. has_tmp .or. ds == 0) ds = s
       estimate_triangles = 4 * s * ds
    case ("pyramid")
       call int_or_none(dget(props, "sides"), sides, has_tmp)
       if (.not. has_tmp .or. sides == 0) sides = 4
       estimate_triangles = max(2 * sides - 2, 0)
    case ("torus")
       s = segments
       if (s == 0) s = 16
       r = rings
       if (r == 0) r = 12
       estimate_triangles = 2 * s * r
    case ("tris")
       v = dget(props, "tris")
       if (v%kind /= DYN_K_LIST) v = dget(props, "triangles")
       if (v%kind == DYN_K_LIST) then
          estimate_triangles = dyn_list_len(v)
       else
          v = dget(props, "tri_count")
          if (v%kind == DYN_K_NULL) v = dget(props, "count")
          call int_or_none(v, tmp, has_tmp)
          if (.not. has_tmp) tmp = 0
          estimate_triangles = tmp
       end if
    case ("load")
       call int_or_none(dget(props, "_load_tris"), tmp, has_tmp)
       if (.not. has_tmp) tmp = 0
       estimate_triangles = tmp
    case default
       estimate_triangles = 0
    end select
  end function estimate_triangles

  ! ext_geometry.estimate_triangles + normalize_geometry's segment
  ! defaults (DEFAULT_SEGMENTS) for the Wave D prims.
  integer function ext_estimate(prim, props)
    character(len=*), intent(in) :: prim
    type(dyn), intent(in) :: props
    ext_estimate = int(eg_estimate(prim, props))
  end function ext_estimate

  integer function tri_default(prim)
    character(len=*), intent(in) :: prim
    select case (prim)
    case ("cube");       tri_default = 12
    case ("sphere");     tri_default = 352
    case ("cylinder");   tri_default = 64
    case ("plane");      tri_default = 4
    case ("pyramid");    tri_default = 6
    case ("cone");       tri_default = 32
    case ("torus");      tri_default = 384
    case ("circle");     tri_default = 64
    case ("ring");       tri_default = 128
    case ("capsule");    tri_default = 256
    case ("tube");       tri_default = 0
    case ("lathe");      tri_default = 0
    case ("extrude");    tri_default = 0
    case ("tetrahedron"); tri_default = 4
    case ("octahedron"); tri_default = 8
    case ("icosahedron"); tri_default = 20
    case ("dodecahedron"); tri_default = 36
    case ("torusknot");  tri_default = 1152
    case default;        tri_default = 0
    end select
  end function tri_default

  ! ------------------------------------------------------------------
  ! Canonical .f3d formatting (cli.py _format_props / _format_stmt)
  !
  ! The dyn dicts carry no class tag (Python dispatches on
  ! type(stmt).__name__), so kinds are discriminated by the key
  ! signatures f3dc_desugar's is_node documents (they cover both
  ! the parser's node shapes and desugar's injected defaults):
  !   Object "prim"; Group "children"; Repeat "obj"+"mode";
  !   Anim "verb"; Light "direction"+"kind";
  !   Output "format"+"kind"; Load "path"+"file" and no "kind";
  !   Scene "bg"+"width" and no "kind"; Controls "autorotate";
  !   Camera "fov"+"pos"+"target".
  ! ------------------------------------------------------------------
  subroutine format_props(props, parts, excl1, excl2)
    type(dyn), intent(in) :: props
    character(len=:), allocatable, intent(out) :: parts
    character(len=*), intent(in), optional :: excl1, excl2
    character(len=64) :: eff_keys(256)
    type(dyn) :: eff_vals(256)
    integer :: n_eff, i, k
    logical :: dup
    character(len=:), allocatable :: key, canon
    character(len=*), parameter :: PROP_ORDER(15) = [character(len=16) :: &
         "at", "pos", "position", "size", "radius", "height", &
         "rotate", "rot", "scale", "material", "segments", "detail", &
         "capped", "open", "texture"]
    parts = ""
    if (props%kind /= DYN_K_DICT) return
    n_eff = 0
    do i = 1, dyn_dict_len(props)
       key = dyn_dict_key_at(props, i)
       if (present(excl1)) then
          if (key == excl1) cycle
       end if
       if (present(excl2)) then
          if (key == excl2) cycle
       end if
       ! Alias map of cli.py: pos/position -> at, rot -> rotate,
       ! colour/color -> dropped.
       select case (key)
       case ("colour", "color")
          cycle
       case ("pos", "position")
          canon = "at"
       case ("rot")
          canon = "rotate"
       case default
          canon = key
       end select
       dup = .false.
       do k = 1, n_eff
          if (trim(eff_keys(k)) == canon) dup = .true.
       end do
       if (dup) cycle
       n_eff = n_eff + 1
       eff_keys(n_eff) = canon
       eff_vals(n_eff) = dyn_copy(dyn_dict_get(props, key))
    end do
    ! _PROP_ORDER keys first (in that order), then the rest in
    ! insertion order.
    do k = 1, size(PROP_ORDER)
       do i = 1, n_eff
          if (trim(eff_keys(i)) == trim(PROP_ORDER(k))) then
             call append_prop(parts, trim(eff_keys(i)), eff_vals(i))
          end if
       end do
    end do
    do i = 1, n_eff
       dup = .false.
       do k = 1, size(PROP_ORDER)
          if (trim(eff_keys(i)) == trim(PROP_ORDER(k))) dup = .true.
       end do
       if (.not. dup) call append_prop(parts, trim(eff_keys(i)), &
                                       eff_vals(i))
    end do
  end subroutine format_props

  subroutine append_prop(parts, key, value)
    character(len=:), allocatable, intent(inout) :: parts
    character(len=*), intent(in) :: key
    type(dyn), intent(in) :: value
    character(len=:), allocatable :: piece
    if (value%kind == DYN_K_NULL) return
    if (value%kind == DYN_K_BOOL) then
       if (.not. value%b) return
       piece = key
    else if (value%kind == DYN_K_LIST) then
       piece = key//" "//fmt_vec(value)
    else
       piece = key//" "//fmt_num(value)
    end if
    if (len(parts) > 0) parts = parts//" "
    parts = parts//piece
  end subroutine append_prop

  recursive subroutine format_stmt(stmt, out)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable, intent(out) :: out
    type(dyn) :: props, v, w
    character(len=:), allocatable :: parts, body_line
    integer :: i
    out = ""
    props = dget(stmt, "props")
    if (dhas(stmt, "prim")) then
       ! ObjectStmt
       parts = dstr(stmt, "prim", "cube")
       if (dnonnull(stmt, "name")) parts = parts//" "//dstr(stmt, "name", "")
       v = dget2(stmt, "color_raw", "color")
       if (v%kind /= DYN_K_NULL) then
          if (.not. (v%kind == DYN_K_STR .and. len(v%s) == 0)) &
             parts = parts//" "//fmt_colour(v)
       end if
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "children")) then
       ! GroupStmt: header, indented body lines, "end".  Python
       ! reads the dataclass "body" (always empty from the parser),
       ! mirrored faithfully here.
       parts = "group"
       if (dnonnull(stmt, "name")) parts = parts//" "//dstr(stmt, "name", "")
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
       v = dget(stmt, "body")
       do i = 1, dyn_list_len(v)
          call format_stmt(dyn_list_at(v, i), body_line)
          out = out//achar(10)//"  "//body_line
       end do
       out = out//achar(10)//"end"
    else if (dhas(stmt, "obj") .and. dhas(stmt, "mode")) then
       ! RepeatStmt: Python uses a (dataclass default 0) and b
       ! (None), so the head is "<mode> 0" / "grid 0" in practice.
       block
         character(len=:), allocatable :: mode, head
         type(dyn) :: a, b, obj
         mode = dstr(stmt, "mode", "repeat")
         a = dget(stmt, "a")
         if (a%kind == DYN_K_NULL) a = dyn_int(0_int64)
         b = dget(stmt, "b")
         if (mode == "grid" .and. b%kind /= DYN_K_NULL .and. &
             .not. (b%kind == DYN_K_INT .and. b%i == 0) .and. &
             .not. (b%kind == DYN_K_BOOL .and. .not. b%b)) then
            head = "grid "//fmt_num(a)//"x"//fmt_num(b)
         else
            head = mode//" "//fmt_num(a)
         end if
         obj = dget(stmt, "obj")
         if (obj%kind /= DYN_K_NULL) then
            call format_stmt(obj, body_line)
            out = head//" "//body_line
         else
            out = head
         end if
       end block
    else if (dhas(stmt, "verb")) then
       ! AnimStmt
       parts = dstr(stmt, "kind", "spin")
       if (dnonnull(stmt, "target")) parts = parts//" "//dstr(stmt, "target", "")
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "direction") .and. dhas(stmt, "kind")) then
       ! LightStmt
       parts = "light "//dstr(stmt, "kind", "directional")
       v = dget2(stmt, "direction", "dir")
       if (v%kind /= DYN_K_NULL) parts = parts//" "//fmt_vec(v)
       v = dget2(stmt, "color", "color_raw")
       if (v%kind /= DYN_K_NULL) parts = parts//" "//fmt_colour(v)
       if (dnonnull(stmt, "intensity")) &
          parts = parts//" intensity "//fmt_num(dget(stmt, "intensity"))
       out = parts
    else if (dhas(stmt, "format") .and. dhas(stmt, "kind")) then
       ! OutputStmt
       if (dstr(stmt, "kind", "render") == "export") then
          parts = "export "//dstr(stmt, "format", "json")
       else
          parts = "render"
       end if
       if (dnonnull(stmt, "path")) parts = parts//" "//dstr(stmt, "path", "")
       v = dget(stmt, "width")
       w = dget(stmt, "height")
       if (v%kind /= DYN_K_NULL .and. w%kind /= DYN_K_NULL) &
          parts = parts//" size "//fmt_num(v)//"x"//fmt_num(w)
       out = parts
    else if (dhas(stmt, "import_path")) then
       ! ImportStmt (v2.0 P3, native-only): printed in source form,
       ! so `f3dc fmt` round-trips an import statement.
       parts = "import """//dstr(stmt, "import_path", "")// &
               """ as "//dstr(stmt, "name", "")
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "file") .and. .not. dhas(stmt, "kind")) then
       ! LoadStmt
       parts = "load """//dstr(stmt, "path", "")//""""
       if (dnonnull(stmt, "name")) parts = parts//" "//dstr(stmt, "name", "")
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "bg") .and. dhas(stmt, "width") .and. &
             .not. dhas(stmt, "kind")) then
       ! SceneStmt
       parts = "scene"
       if (dnonnull(stmt, "name")) parts = parts//" "//dstr(stmt, "name", "")
       v = dget(stmt, "width")
       w = dget(stmt, "height")
       if (v%kind /= DYN_K_NULL .and. w%kind /= DYN_K_NULL) &
          parts = parts//" size "//fmt_num(v)//"x"//fmt_num(w)
       if (dnonnull(stmt, "bg")) parts = parts//" bg "//dstr(stmt, "bg", "")
       call format_props(props, body_line, "size", "bg")
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "autorotate")) then
       ! ControlsStmt ("kind" holds the dataclass default "orbit")
       parts = "controls "//dstr(stmt, "kind", "orbit")
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "fov") .and. dhas(stmt, "pos") .and. &
             dhas(stmt, "target")) then
       ! CameraStmt: Python reads "pos" (always None from the
       ! parser, set on desugar's injected default), "target",
       ! "up", then fov/near/far.
       parts = "camera"
       v = dget(stmt, "pos")
       if (v%kind /= DYN_K_NULL) parts = parts//" at "//fmt_vec(v)
       v = dget(stmt, "target")
       if (v%kind /= DYN_K_NULL) parts = parts//" look "//fmt_vec(v)
       v = dget(stmt, "up")
       if (v%kind /= DYN_K_NULL) parts = parts//" up "//fmt_vec(v)
       if (dnonnull(stmt, "fov")) parts = parts//" fov "//fmt_num(dget(stmt, "fov"))
       if (dnonnull(stmt, "near")) parts = parts//" near "//fmt_num(dget(stmt, "near"))
       if (dnonnull(stmt, "far")) parts = parts//" far "//fmt_num(dget(stmt, "far"))
       out = parts
    else
       ! Unknown / extension statement kind: Python prints the
       ! class name + formatted props; the class name is recovered
       ! from the parser's key signatures (ext_class_name).
       parts = ext_class_name(stmt)
       call format_props(props, body_line)
       if (len(body_line) > 0) then
          if (len(parts) > 0) parts = parts//" "
          parts = parts//body_line
       end if
       out = parts
    end if
  end subroutine format_stmt

  ! ------------------------------------------------------------------
  ! Emitters (cli.py _scene_text / _fortran_program_text /
  ! _json_v2_text / _json_legacy_text / _js_text / _html_text).
  ! Python tries the real emit_* module, then falls back to a local
  ! minimal emitter.  Here the emit_* modules are linked, so the
  ! primary call is the only path (see the header divergence note);
  ! the JS fallback is the one place cli.py's own text is mirrored
  ! because emit_js's Python signature takes an optional
  ! source_name the Fortran mirror drops.
  ! ------------------------------------------------------------------
  subroutine scene_text(ir, stem, text)
    type(dyn), intent(in) :: ir
    character(len=*), intent(in) :: stem
    character(len=:), allocatable, intent(out) :: text
    call emit_scene_text(ir, text)
    ! stem is only used by cli.py's local fallback, not here.
    if (len(stem) < 0) text = text
  end subroutine scene_text

  subroutine fortran_program_text(ir, stem, text)
    type(dyn), intent(in) :: ir
    character(len=*), intent(in) :: stem
    character(len=:), allocatable, intent(out) :: text
    call emit_fortran_program(ir, text)
    if (len(stem) < 0) text = text
  end subroutine fortran_program_text

  subroutine json_v2_text(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    call emit_json_v2(ir, text)
  end subroutine json_v2_text

  subroutine json_legacy_text(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    call emit_json_legacy(ir, text)
  end subroutine json_legacy_text

  subroutine js_text(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    call emit_js(ir, text)
  end subroutine js_text

  subroutine html_text(ir, stem, text)
    type(dyn), intent(in) :: ir
    character(len=*), intent(in) :: stem
    character(len=:), allocatable, intent(out) :: text
    character(len=:), allocatable :: runtime, root, scene_js
    call driver_repo_root(root)
    ! cli.py _html_text reads runtime/f3d.js itself ("" == None).
    call emit_html_runtime_js(root, runtime)
    call emit_js(ir, scene_js)
    call emit_html(ir, runtime, scene_js, "", root, text)
    if (len(stem) < 0) text = text
  end subroutine html_text

  ! ------------------------------------------------------------------
  ! Multi-scene files (cli.py _scene_chunks / _chunk_scene_name /
  ! _multi_chunks / _write_chunks / _drop_chunks)
  ! ------------------------------------------------------------------
  ! Split TEXT into lines WITH their "\n" terminators kept.
  subroutine split_keepends(text, lines, n)
    character(len=*), intent(in) :: text
    character(len=:), allocatable, intent(out) :: lines(:)
    integer, intent(out) :: n
    integer :: i, start, cap
    cap = 1
    do i = 1, len(text)
       if (text(i:i) == achar(10)) cap = cap + 1
    end do
    allocate (character(len=max(len(text), 1)) :: lines(cap))
    n = 0
    start = 1
    do i = 1, len(text)
       if (text(i:i) == achar(10)) then
          n = n + 1
          lines(n) = text(start:i)
          start = i + 1
       end if
    end do
    if (start <= len(text)) then
       n = n + 1
       lines(n) = text(start:)
    end if
  end subroutine split_keepends

  ! First whitespace-delimited word of an already-stripped line.
  function first_word(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i
    i = 1
    do while (i <= len(s) .and. .not. is_ws(s(i:i)))
       i = i + 1
    end do
    out = s(1:i - 1)
  end function first_word

  ! Python: word.rstrip(":").lower() == "scene"
  logical function is_scene_line(raw)
    character(len=*), intent(in) :: raw
    character(len=:), allocatable :: s, w
    s = strip_ws(raw)
    is_scene_line = .false.
    if (len(s) == 0) return
    if (s(1:1) == "#") return
    if (len(s) >= 2 .and. s(1:2) == "//") return
    w = first_word(s)
    do while (len(w) > 0 .and. w(len(w):len(w)) == ":")
       w = w(1:len(w) - 1)
    end do
    is_scene_line = (to_lower(w) == "scene")
  end function is_scene_line

  subroutine scene_chunks(text, chunks, n_chunks, multi)
    character(len=*), intent(in) :: text
    character(len=:), allocatable, intent(out) :: chunks(:)
    integer, intent(out) :: n_chunks
    logical, intent(out) :: multi
    character(len=:), allocatable :: lines(:)
    integer :: starts(512), n_starts, n_lines, k, e, i
    call split_keepends(text, lines, n_lines)
    n_starts = 0
    do i = 1, n_lines
       if (is_scene_line(trim(lines(i)))) then
          n_starts = n_starts + 1
          starts(n_starts) = i
       end if
    end do
    multi = (n_starts > 1)
    n_chunks = 0
    if (.not. multi) return
    allocate (character(len=max(len(text), 1)) :: chunks(n_starts))
    do k = 1, n_starts
       if (k < n_starts) then
          e = starts(k + 1) - 1
       else
          e = n_lines
       end if
       block
         character(len=:), allocatable :: acc
         acc = ""
         if (k == 1) then
            do i = 1, starts(1) - 1
               acc = acc//trim(lines(i))
            end do
         end if
         do i = starts(k), e
            acc = acc//trim(lines(i))
         end do
         chunks(k) = acc
       end block
       n_chunks = n_chunks + 1
    end do
  end subroutine scene_chunks

  function chunk_scene_name(chunk, index) result(out)
    character(len=*), intent(in) :: chunk
    integer, intent(in) :: index
    character(len=:), allocatable :: out, s, w
    character(len=:), allocatable :: lines(:)
    integer :: n, i, j
    call split_keepends(chunk, lines, n)
    do i = 1, n
       s = strip_ws(trim(lines(i)))
       if (len(s) == 0) cycle
       w = first_word(s)
       do while (len(w) > 0 .and. w(len(w):len(w)) == ":")
          w = w(1:len(w) - 1)
       end do
       if (to_lower(w) /= "scene") cycle
       ! parts = s.replace('"', " ").split(); name = parts[2]
       block
         character(len=:), allocatable :: t
         integer :: cnt, a, b
         t = ""
         do j = 1, len(s)
            if (s(j:j) == '"') then
               t = t//" "
            else
               t = t//s(j:j)
            end if
         end do
         cnt = 0
         a = 1
         do j = 1, len(t) + 1
            if (j > len(t) .or. is_ws(t(j:j))) then
               if (j > a) then
                  cnt = cnt + 1
                  if (cnt == 2) then
                     out = t(a:j - 1)
                     return
                  end if
               end if
               a = j + 1
            end if
         end do
         b = cnt
       end block
    end do
    out = "scene"//trim(fmt_int(int(index + 1, int64)))
  end function chunk_scene_name

  ! _multi_chunks(path): chunks when PATH is a multi-scene .f3d.
  subroutine multi_chunks(path, chunks, n_chunks, multi)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: chunks(:)
    integer, intent(out) :: n_chunks
    logical, intent(out) :: multi
    character(len=:), allocatable :: text
    logical :: rok
    multi = .false.
    n_chunks = 0
    if (suffix_lower(path) /= ".f3d") return
    if (.not. file_exists(path)) return
    call read_file(path, text, rok)
    if (.not. rok) return
    call scene_chunks(text, chunks, n_chunks, multi)
  end subroutine multi_chunks

  subroutine write_chunks(path, chunks, n_chunks, temps)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(in) :: chunks(:)
    integer, intent(in) :: n_chunks
    character(len=:), allocatable, intent(out) :: temps(:)
    integer :: i
    logical :: wok
    allocate (character(len=len(path) + 32) :: temps(n_chunks))
    do i = 1, n_chunks
       temps(i) = path_dirname(path)//"/."//path_stem(path)// &
                  ".multi"//trim(fmt_int(int(i - 1, int64)))//".f3d"
       if (path_dirname(path) == ".") &
          temps(i) = "."//path_stem(path)// &
                     ".multi"//trim(fmt_int(int(i - 1, int64)))//".f3d"
       call write_file(trim(temps(i)), trim(chunks(i)), wok)
    end do
  end subroutine write_chunks

  subroutine drop_chunks(temps, n)
    character(len=:), allocatable, intent(in) :: temps(:)
    integer, intent(in) :: n
    integer :: i
    do i = 1, n
       call delete_quiet(trim(temps(i)))
    end do
  end subroutine drop_chunks

  ! ------------------------------------------------------------------
  ! Glob helper (Python sorted(Path.glob(pattern))): names in DIR
  ! matching a simple "prefix*.suffix" pattern, sorted.
  ! ------------------------------------------------------------------
  subroutine glob_names(dir, pattern, names, n_names)
    character(len=*), intent(in) :: dir, pattern
    character(len=:), allocatable, intent(out) :: names(:)
    integer, intent(out) :: n_names
    character(len=:), allocatable :: out_t, err_t, line
    integer :: rc, i, start
    logical :: timed_out
    ! PATTERN is an internal glob (never user text): leave it
    ! unquoted so the shell expands it.
    call driver_run_capture("ls -1 "//pattern, dir, 0, &
                            rc, out_t, err_t, timed_out)
    n_names = 0
    if (rc /= 0) then
       allocate (character(len=1) :: names(1))
       return
    end if
    ! Count lines.
    block
      integer :: cnt
      cnt = 0
      do i = 1, len(out_t)
         if (out_t(i:i) == achar(10)) cnt = cnt + 1
      end do
      allocate (character(len=1024) :: names(max(cnt, 1)))
      start = 1
      do i = 1, len(out_t)
         if (out_t(i:i) == achar(10)) then
            if (i > start) then
               n_names = n_names + 1
               names(n_names) = out_t(start:i - 1)
            end if
            start = i + 1
         end if
      end do
      line = ""
    end block
  end subroutine glob_names

  ! ------------------------------------------------------------------
  ! check (cli.py _do_check)
  ! ------------------------------------------------------------------
  recursive subroutine do_check(path, as_json, explain, code)
    character(len=*), intent(in) :: path
    logical, intent(in) :: as_json, explain
    integer, intent(out) :: code
    character(len=:), allocatable :: chunks(:), temps(:)
    integer :: n_chunks, i, sub_code
    logical :: multi
    type(error_bag_t) :: bag
    type(dyn) :: ir
    logical :: ok
    character(len=:), allocatable :: summary
    call multi_chunks(path, chunks, n_chunks, multi)
    if (multi) then
       call write_chunks(path, chunks, n_chunks, temps)
       code = 0
       do i = 1, n_chunks
          call do_check(trim(temps(i)), as_json, explain, sub_code)
          call out_line("scene "//trim(fmt_int(int(i, int64)))//"/"// &
               trim(fmt_int(int(n_chunks, int64)))//": "// &
               chunk_scene_name(trim(chunks(i)), i - 1))
          if (sub_code /= 0 .and. code == 0) code = sub_code
       end do
       call out_line("multi-scene: "// &
            trim(fmt_int(int(n_chunks, int64)))//" scenes in "//path)
       call drop_chunks(temps, n_chunks)
       return
    end if
    call compile_pipeline(path, bag, ir, ok)
    if (.not. ok) then
       call print_diagnostics(bag, as_json)
       code = error_bag_fail_code(bag)
       return
    end if
    if (error_bag_len(bag) > 0) then
       call print_diagnostics(bag, as_json)
    else if (as_json) then
       call out_line(error_bag_format_json(bag))
    end if
    if (explain) then
       summary = explain_text()
       if (len(summary) > 0) call err_line(summary)
    end if
    call out_line("OK: "//path//" ("// &
         trim(fmt_int(int(dyn_list_len(dget(ir, "objects")), int64)))// &
         " objects, "//trim(fmt_int(int(tri_estimate(ir), int64)))// &
         " triangles est.)")
    code = 0
  end subroutine do_check

  ! ------------------------------------------------------------------
  ! build (cli.py _do_build): returns code plus (out_dir, ir, stem)
  ! ------------------------------------------------------------------
  recursive subroutine do_build(path, out_dir_in, has_out, explain, &
                                stem_override, has_stem_override, &
                                code, out_dir, ir, stem)
    character(len=*), intent(in) :: path, out_dir_in, stem_override
    logical, intent(in) :: has_out, explain, has_stem_override
    integer, intent(out) :: code
    character(len=:), allocatable, intent(out) :: out_dir, stem
    type(dyn), intent(out) :: ir
    character(len=:), allocatable :: chunks(:), temps(:), sub
    integer :: n_chunks, i, sub_code
    logical :: multi
    type(error_bag_t) :: bag
    logical :: ok
    character(len=256) :: names(6)
    character(len=:), allocatable :: c_scene, c_json, c_legacy, &
         c_js, c_html, c_f90, content_k, root, target, summary
    integer :: k
    logical :: wok
    ir = dyn_null()
    out_dir = ""
    stem = ""
    call multi_chunks(path, chunks, n_chunks, multi)
    if (multi) then
       call write_chunks(path, chunks, n_chunks, temps)
       code = 0
       if (has_out) then
          out_dir = out_dir_in
       else
          out_dir = "build"
       end if
       do i = 1, n_chunks
          sub = path_stem(path)//"-"// &
                chunk_scene_name(trim(chunks(i)), i - 1)
          call do_build(trim(temps(i)), out_dir_in, has_out, explain, &
                        sub, .true., sub_code, out_dir, ir, stem)
          if (sub_code /= 0 .and. code == 0) code = sub_code
       end do
       call drop_chunks(temps, n_chunks)
       return
    end if
    call compile_pipeline(path, bag, ir, ok)
    if (.not. ok) then
       call print_diagnostics(bag, .false.)
       code = error_bag_fail_code(bag)
       ir = dyn_null()
       return
    end if
    if (error_bag_len(bag) > 0) call print_diagnostics(bag, .false.)
    if (has_out) then
       out_dir = out_dir_in
    else
       out_dir = "build"
    end if
    if (has_stem_override) then
       stem = stem_override
    else
       stem = path_stem(path)
    end if
    names(1) = stem//".scene"
    names(2) = stem//".json"
    names(3) = stem//".legacy.json"
    names(4) = stem//".js"
    names(5) = stem//".html"
    names(6) = stem//"_scene.f90"
    call scene_text(ir, stem, c_scene)
    call json_v2_text(ir, c_json)
    call json_legacy_text(ir, c_legacy)
    call js_text(ir, c_js)
    call html_text(ir, stem, c_html)
    call fortran_program_text(ir, stem, c_f90)
    ! Protected repo-root scene.json / viewer.html (E502).
    call driver_repo_root(root)
    do k = 1, 6
       target = driver_abs_path(out_dir//"/"//trim(names(k)))
       if (target == root//"/scene.json" .or. &
           target == root//"/viewer.html") then
          call err_line("error E502: refusing to write "// &
               out_dir//"/"//trim(names(k))//" -- f3dc never "// &
               "overwrites the repo-root scene.json/viewer.html; "// &
               "use the default build/ output directory")
          code = 3
          return
       end if
    end do
    call mkdir_p(out_dir)
    do k = 1, 6
       select case (k)
       case (1); content_k = c_scene
       case (2); content_k = c_json
       case (3); content_k = c_legacy
       case (4); content_k = c_js
       case (5); content_k = c_html
       case (6); content_k = c_f90
       end select
       call write_file(out_dir//"/"//trim(names(k)), content_k, wok)
       if (.not. wok) then
          call err_line("error E502: cannot write output: i/o error")
          code = 3
          return
       end if
    end do
    if (explain) then
       summary = explain_text()
       if (len(summary) > 0) call err_line(summary)
    end if
    do k = 1, 6
       call out_line(out_dir//"/"//trim(names(k)))
    end do
    code = 0
  end subroutine do_build

  ! ------------------------------------------------------------------
  ! run (cli.py _render_output_name / _do_run)
  ! ------------------------------------------------------------------
  function render_output_name(ir, stem, scene_path) result(out)
    type(dyn), intent(in) :: ir
    character(len=*), intent(in) :: stem, scene_path
    character(len=:), allocatable :: out, text
    logical :: rok
    type(dyn) :: outs, o
    integer :: i
    call read_file(scene_path, text, rok)
    if (rok) then
       block
         character(len=:), allocatable :: lines(:)
         integer :: n, j
         call split_keepends(text, lines, n)
         do j = 1, n
            block
              character(len=:), allocatable :: s, w1, w2
              integer :: p
              s = strip_ws(trim(lines(j)))
              w1 = first_word(s)
              if (w1 == "output") then
                 p = index(s, " ")
                 if (p == 0) p = index(s, achar(9))
                 if (p > 0) then
                    w2 = first_word(strip_ws(s(p + 1:)))
                    if (len(w2) > 0) then
                       out = w2
                       return
                    end if
                 end if
              end if
            end block
         end do
         i = 0
       end block
    end if
    outs = dget(ir, "outputs")
    do i = 1, dyn_list_len(outs)
       o = dyn_list_at(outs, i)
       if (dstr(o, "kind", "render") == "render" .and. &
           dnonnull(o, "path")) then
          out = path_basename(dstr(o, "path", ""))
          return
       end if
    end do
    out = stem//".ppm"
  end function render_output_name

  recursive subroutine do_run(path, out_dir_in, has_out, &
                              stem_override, has_stem_override, code)
    character(len=*), intent(in) :: path, out_dir_in, stem_override
    logical, intent(in) :: has_out, has_stem_override
    integer, intent(out) :: code
    character(len=:), allocatable :: chunks(:), temps(:), sub, &
         out_dir, stem, scene_path, msg, eng_out, eng_err, &
         output_name, ppm_name, ppm_path, tail, conv, cout, cerr
    integer :: n_chunks, i, sub_code, eng_rc, crc
    logical :: multi, failed, timed_out, is_png
    type(dyn) :: ir
    code = 0
    call multi_chunks(path, chunks, n_chunks, multi)
    if (multi) then
       call write_chunks(path, chunks, n_chunks, temps)
       if (has_out) then
          out_dir = out_dir_in
       else
          out_dir = "build"
       end if
       do i = 1, n_chunks
          sub = path_stem(path)//"-"// &
                chunk_scene_name(trim(chunks(i)), i - 1)
          call do_run(trim(temps(i)), out_dir_in, has_out, sub, &
                      .true., sub_code)
          if (sub_code /= 0 .and. code == 0) code = sub_code
          if (sub_code == 0) then
             ! Rename this scene's output_render*.ppm to its stem.
             block
               character(len=:), allocatable :: ppms(:)
               integer :: n_ppms, j
               character(len=:), allocatable :: tgt
               call glob_names(out_dir, "output_render*.ppm", ppms, &
                               n_ppms)
               do j = 1, n_ppms
                  block
                    character(len=:), allocatable :: nm
                    nm = trim(ppms(j))
                    tgt = sub//nm(len("output_render") + 1:)
                  end block
                  if (trim(ppms(j)) /= tgt) then
                     call execute_command_line("mv "// &
                          driver_quote(out_dir//"/"//trim(ppms(j)))// &
                          " "//driver_quote(out_dir//"/"//tgt), &
                          exitstat=crc)
                     call out_line(out_dir//"/"//tgt)
                  end if
               end do
             end block
          end if
       end do
       call drop_chunks(temps, n_chunks)
       return
    end if
    call do_build(path, out_dir_in, has_out, .false., stem_override, &
                  has_stem_override, code, out_dir, ir, stem)
    if (code /= 0) return
    ! The engine runs with cwd=out_dir; hand it an absolute .scene.
    scene_path = driver_abs_path(out_dir//"/"//stem//".scene")
    call driver_run_engine(scene_path, out_dir, 120, eng_rc, eng_out, &
                           eng_err, msg, failed)
    if (failed) then
       call err_line("error: toolchain failure -- engine run "// &
                     "failed: "//msg)
       code = 4
       return
    end if
    if (eng_rc /= 0) then
       tail = strip_ws(eng_err)
       if (len(tail) > 0) then
          block
            integer :: p
            p = index(tail, achar(10), back=.true.)
            if (p > 0) tail = tail(p + 1:)
          end block
          call err_line("error: toolchain failure -- engine exited "// &
               "with status "//trim(fmt_int(int(eng_rc, int64)))// &
               ": "//tail)
       else
          call err_line("error: toolchain failure -- engine exited "// &
               "with status "//trim(fmt_int(int(eng_rc, int64))))
       end if
       code = 4
       return
    end if
    output_name = render_output_name(ir, stem, scene_path)
    is_png = ends_with_ci(output_name, ".png")
    ! v2.0 P2: the engine writes PNG natively when the output name
    ! ends in .png, so the primary output IS the requested file --
    ! no PPM twin and no ImageMagick conversion any more.
    ppm_name = output_name
    ppm_path = out_dir//"/"//path_basename(ppm_name)
    if (file_exists(ppm_path)) then
       call out_line(ppm_path)
    else
       call err_line("error: toolchain failure -- the engine "// &
            "reported success but produced no output file at "// &
            ppm_path)
       code = 4
       return
    end if
    ! Animation frame reporting.
    block
      type(dyn) :: anims, anim, dur, fps
      integer :: frames, j
      character(len=:), allocatable :: frames_list(:)
      integer :: n_frames
      anims = dget(ir, "animations")
      if (dyn_list_len(anims) > 0) then
         frames = 0
         do j = 1, dyn_list_len(anims)
            anim = dyn_list_at(anims, j)
            dur = dget(anim, "duration")
            if (dur%kind == DYN_K_NULL) dur = dyn_int(5_int64)
            if (dur%kind == DYN_K_INT .and. dur%i == 0) dur = dyn_int(5_int64)
            if (dur%kind == DYN_K_REAL .and. dur%r == 0.0_real64) dur = dyn_int(5_int64)
            fps = dget(anim, "fps")
            if (fps%kind == DYN_K_NULL) fps = dyn_int(30_int64)
            if (fps%kind == DYN_K_INT .and. fps%i == 0) fps = dyn_int(30_int64)
            frames = max(frames, int(num_as_real(dur) * &
                                     num_as_int(fps)))
         end do
         if (frames > 1) then
            call glob_names(out_dir, &
                 path_stem(ppm_name)//"_*"//suffix_lower(ppm_name), &
                 frames_list, n_frames)
            if (n_frames > 0) then
               do j = 1, n_frames
                  call out_line(out_dir//"/"//trim(frames_list(j)))
               end do
               call out_line("animation: "// &
                    trim(fmt_int(int(n_frames, int64)))// &
                    " frame files for "// &
                    trim(fmt_int(int(frames, int64)))//" frames")
            else
               call out_line("animation: "// &
                    trim(fmt_int(int(frames, int64)))// &
                    " frames expected as "//out_dir//"/"// &
                    path_stem(ppm_name)//"_%04d"//suffix_lower(ppm_name))
            end if
         end if
      end if
    end block
    code = 0
  end subroutine do_run

  real(real64) function num_as_real(v)
    type(dyn), intent(in) :: v
    select case (v%kind)
    case (DYN_K_INT);  num_as_real = real(v%i, real64)
    case (DYN_K_REAL); num_as_real = v%r
    case default;      num_as_real = 0.0_real64
    end select
  end function num_as_real

  integer function num_as_int(v)
    type(dyn), intent(in) :: v
    select case (v%kind)
    case (DYN_K_INT);  num_as_int = int(v%i)
    case (DYN_K_REAL); num_as_int = int(v%r)
    case default;      num_as_int = 0
    end select
  end function num_as_int

  ! ------------------------------------------------------------------
  ! new (cli.py _do_new)
  ! ------------------------------------------------------------------
  subroutine do_new(name, code)
    character(len=*), intent(in) :: name
    integer, intent(out) :: code
    character(len=:), allocatable :: target, parent
    logical :: wok
    target = name
    if (suffix_lower(name) /= ".f3d") then
       ! Path.with_name(name + ".f3d")
       parent = path_dirname(name)
       if (parent == ".") then
          target = path_basename(name)//".f3d"
       else if (parent == "/") then
          target = "/"//path_basename(name)//".f3d"
       else
          target = parent//"/"//path_basename(name)//".f3d"
       end if
    end if
    if (file_exists(target)) then
       call err_line("error: "//target//" already exists -- f3dc "// &
                     "new never overwrites an existing file")
       code = 3
       return
    end if
    parent = path_dirname(target)
    if (parent /= "" .and. parent /= ".") call mkdir_p(parent)
    call write_file(target, "cube red"//achar(10)//"spin it"// &
                    achar(10)//"render"//achar(10), wok)
    if (.not. wok) then
       call err_line("error E502: cannot write "//target// &
                     ": i/o error")
       code = 3
       return
    end if
    call out_line("created "//target//" -- next: f3dc run "//target)
    code = 0
  end subroutine do_new

  ! ------------------------------------------------------------------
  ! fmt (cli.py _do_fmt)
  ! ------------------------------------------------------------------
  subroutine do_fmt(path, code)
    character(len=*), intent(in) :: path
    integer, intent(out) :: code
    type(error_bag_t) :: bag
    character(len=:), allocatable :: text, ext, line
    logical :: rok
    type(dyn) :: prog, stmts
    integer :: i
    if (.not. file_exists(path)) then
       call error_bag_add(bag, make_diagnostic_span( &
            "E501", "error", "file not found: "//path, &
            make_span(path, 1, 1), &
            help="check the path and try again"))
       call print_diagnostics(bag, .false.)
       code = 3
       return
    end if
    call read_file(path, text, rok)
    if (.not. rok) then
       call err_line("error E501: cannot read "//path//": i/o error")
       code = 3
       return
    end if
    call error_bag_set_source(bag, text)
    ext = suffix_lower(path)
    if (ext == ".obj") then
       call ast_from_obj(text, bag, prog)
    else if (ext == ".json") then
       call ast_from_legacy_json(text, bag, prog)
    else
       call f3dc_parse(text, path, bag, prog)
    end if
    if (error_bag_has_errors(bag)) then
       call print_diagnostics(bag, .false.)
       code = 1
       return
    end if
    stmts = dget(prog, "statements")
    if (dyn_list_len(stmts) == 0) then
       call out_line("")
    else
       do i = 1, dyn_list_len(stmts)
          call format_stmt(dyn_list_at(stmts, i), line)
          call out_line(line)
       end do
    end if
    code = 0
  end subroutine do_fmt

  ! ------------------------------------------------------------------
  ! doctor (cli.py _do_doctor).  DIVERGENCE: the "python:" line --
  ! Python prints its own interpreter; the native binary reports
  ! the python3 found on PATH (version via `python3 --version`),
  ! or "python: MISSING" when absent (a case Python cannot hit).
  ! ------------------------------------------------------------------
  subroutine do_doctor(code)
    integer, intent(out) :: code
    character(len=:), allocatable :: root, tool, ver, out_t, err_t
    logical :: found, timed_out
    integer :: rc, missing_required
    character(len=*), parameter :: tools(3) = &
         [character(len=9) :: "gfortran", "make", "convert"]
    integer :: k
    call driver_repo_root(root)
    call out_line("f3dc "//VERSION)
    call driver_find_tool("python3", tool, found)
    if (found) then
       call driver_run_capture(driver_quote(tool)//" --version", "", &
                               0, rc, out_t, err_t, timed_out)
       ver = strip_ws(out_t)
       if (starts_with(ver, "Python ")) ver = ver(8:)
       call out_line("python: "//ver//" ("//tool//")")
    else
       call out_line("python: MISSING")
    end if
    missing_required = 0
    do k = 1, 3
       call driver_find_tool(trim(tools(k)), tool, found)
       if (found) then
          call out_line(trim(tools(k))//": "//tool)
       else if (k <= 2) then
          call out_line(trim(tools(k))//": MISSING (required)")
          missing_required = missing_required + 1
       else
          call out_line(trim(tools(k))//": MISSING (optional)")
       end if
    end do
    call out_line("repo root: "//root)
    if (driver_is_dir(root//"/src")) then
       call out_line("engine sources: "//root//"/src (present)")
    else
       call out_line("engine sources: "//root//"/src (MISSING)")
    end if
    if (missing_required == 2) then
       call err_line("error: neither gfortran nor make was found "// &
            "-- 'f3dc run' cannot work; install a Fortran toolchain "// &
            "and re-run 'f3dc doctor'")
       code = 4
       return
    end if
    code = 0
  end subroutine do_doctor

  ! ------------------------------------------------------------------
  ! Scene discovery (cli.py _discover_scene)
  ! ------------------------------------------------------------------
  subroutine discover_scene(found_path, found)
    character(len=:), allocatable, intent(out) :: found_path
    logical, intent(out) :: found
    character(len=:), allocatable :: names(:)
    integer :: n
    found = .false.
    found_path = ""
    if (file_exists("scene.f3d")) then
       found_path = "scene.f3d"
       found = .true.
       return
    end if
    if (file_exists("main.f3d")) then
       found_path = "main.f3d"
       found = .true.
       return
    end if
    call glob_names(".", "*.f3d", names, n)
    if (n == 1) then
       found_path = trim(names(1))
       found = .true.
    end if
  end subroutine discover_scene

  logical function is_scene_file(name)
    ! cli.py: a bare argument ending in .f3d/.json/.obj (any case)
    ! or naming an existing file is treated as `f3dc run <file>`.
    character(len=*), intent(in) :: name
    is_scene_file = ends_with_ci(name, ".f3d") .or. &
                    ends_with_ci(name, ".json") .or. &
                    ends_with_ci(name, ".obj") .or. &
                    file_exists(name)
  end function is_scene_file

  ! ------------------------------------------------------------------
  ! Subcommand argument parsing.  Mirrors argparse as cli.py wires
  ! it: unknown tokens are collected and reported by the MAIN
  ! parser ("f3dc: error: unrecognized arguments: ...", main usage,
  ! exit 2); a missing required positional is reported by the SUB
  ! parser ("f3dc <cmd>: error: the following arguments are
  ! required: ...", sub usage, exit 2); -h/--help prints the sub
  ! help on stdout and exits 0.
  ! ------------------------------------------------------------------
  subroutine parse_file_args(cmd, allow_out, allow_explain, &
                             allow_json, file, out_dir, has_out, &
                             explain, as_json)
    character(len=*), intent(in) :: cmd
    logical, intent(in) :: allow_out, allow_explain, allow_json
    character(len=:), allocatable, intent(out) :: file, out_dir
    logical, intent(out) :: has_out, explain, as_json
    integer :: nargs, i, n_extra
    character(len=:), allocatable :: tok, extras
    logical :: have_file
    nargs = command_argument_count()
    file = ""
    out_dir = ""
    has_out = .false.
    explain = .false.
    as_json = .false.
    have_file = .false.
    extras = ""
    n_extra = 0
    i = 2
    do while (i <= nargs)
       tok = arg_at(i)
       if (tok == "-h" .or. tok == "--help") then
          call print_sub_help(cmd)
          call finish(0)
       else if (allow_out .and. (tok == "-o" .or. tok == "--out")) then
          if (i == nargs) call usage_error_sub(cmd, &
               "argument -o/--out: expected one argument")
          i = i + 1
          out_dir = arg_at(i)
          has_out = .true.
       else if (allow_out .and. starts_with(tok, "--out=")) then
          out_dir = tok(7:)
          has_out = .true.
       else if (allow_explain .and. tok == "--explain") then
          explain = .true.
       else if (allow_json .and. tok == "--json") then
          as_json = .true.
       else if (len(tok) > 0 .and. tok(1:1) == "-") then
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       else if (.not. have_file) then
          file = tok
          have_file = .true.
       else
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       end if
       i = i + 1
    end do
    if (n_extra > 0) call usage_error_main( &
         "unrecognized arguments: "//extras)
    if (.not. have_file) call usage_error_sub(cmd, &
         "the following arguments are required: file")
  end subroutine parse_file_args

  ! Bare form: f3dc <file> [-o DIR] == f3dc run <file> [-o DIR].
  ! cli.py builds a separate ArgumentParser(prog="f3dc run") for
  ! this, so its errors carry the "f3dc run" label.
  subroutine parse_bare_args(file, out_dir, has_out)
    character(len=:), allocatable, intent(out) :: file, out_dir
    logical, intent(out) :: has_out
    integer :: nargs, i, n_extra
    character(len=:), allocatable :: tok, extras
    nargs = command_argument_count()
    file = arg_at(1)
    out_dir = ""
    has_out = .false.
    extras = ""
    n_extra = 0
    i = 2
    do while (i <= nargs)
       tok = arg_at(i)
       if (tok == "-h" .or. tok == "--help") then
          call print_sub_help("run")
          call finish(0)
       else if (tok == "-o" .or. tok == "--out") then
          if (i == nargs) call usage_error_sub("run", &
               "argument -o/--out: expected one argument")
          i = i + 1
          out_dir = arg_at(i)
          has_out = .true.
       else if (starts_with(tok, "--out=")) then
          out_dir = tok(7:)
          has_out = .true.
       else
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       end if
       i = i + 1
    end do
    if (n_extra > 0) then
       call err_line(sub_usage("run"))
       call err_line("f3dc run: error: unrecognized arguments: "// &
                     extras)
       call finish(2)
    end if
  end subroutine parse_bare_args

  subroutine parse_new_args(name)
    character(len=:), allocatable, intent(out) :: name
    integer :: nargs, i, n_extra
    character(len=:), allocatable :: tok, extras
    logical :: have_name
    nargs = command_argument_count()
    name = ""
    have_name = .false.
    extras = ""
    n_extra = 0
    i = 2
    do while (i <= nargs)
       tok = arg_at(i)
       if (tok == "-h" .or. tok == "--help") then
          call print_sub_help("new")
          call finish(0)
       else if (len(tok) > 0 .and. tok(1:1) == "-") then
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       else if (.not. have_name) then
          name = tok
          have_name = .true.
       else
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       end if
       i = i + 1
    end do
    if (n_extra > 0) call usage_error_main( &
         "unrecognized arguments: "//extras)
    if (.not. have_name) call usage_error_sub("new", &
         "the following arguments are required: name")
  end subroutine parse_new_args

  subroutine parse_preview_args(file, port, no_browser)
    character(len=:), allocatable, intent(out) :: file
    integer, intent(out) :: port
    logical, intent(out) :: no_browser
    integer :: nargs, i, n_extra, ios
    character(len=:), allocatable :: tok, extras, val
    logical :: have_file
    nargs = command_argument_count()
    file = ""
    port = 8765
    no_browser = .false.
    have_file = .false.
    extras = ""
    n_extra = 0
    i = 2
    do while (i <= nargs)
       tok = arg_at(i)
       if (tok == "-h" .or. tok == "--help") then
          call print_sub_help("preview")
          call finish(0)
       else if (tok == "--port" .or. starts_with(tok, "--port=")) then
          if (tok == "--port") then
             if (i == nargs) call usage_error_sub("preview", &
                  "argument --port: expected one argument")
             i = i + 1
             val = arg_at(i)
          else
             val = tok(8:)
          end if
          read (val, *, iostat=ios) port
          if (ios /= 0) call usage_error_sub("preview", &
               "argument --port: invalid int value: '"//val//"'")
       else if (tok == "--no-browser") then
          no_browser = .true.
       else if (len(tok) > 0 .and. tok(1:1) == "-") then
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       else if (.not. have_file) then
          file = tok
          have_file = .true.
       else
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       end if
       i = i + 1
    end do
    if (n_extra > 0) call usage_error_main( &
         "unrecognized arguments: "//extras)
    if (.not. have_file) call usage_error_sub("preview", &
         "the following arguments are required: file")
  end subroutine parse_preview_args

  subroutine parse_doctor_args()
    integer :: nargs, i, n_extra
    character(len=:), allocatable :: tok, extras
    nargs = command_argument_count()
    extras = ""
    n_extra = 0
    do i = 2, nargs
       tok = arg_at(i)
       if (tok == "-h" .or. tok == "--help") then
          call print_sub_help("doctor")
          call finish(0)
       else
          n_extra = n_extra + 1
          if (n_extra > 1) extras = extras//" "
          extras = extras//tok
       end if
    end do
    if (n_extra > 0) call usage_error_main( &
         "unrecognized arguments: "//extras)
  end subroutine parse_doctor_args

  ! ------------------------------------------------------------------
  ! preview (cli.py: _import_sibling("preview") -> serve(...)).
  ! ------------------------------------------------------------------
  subroutine do_preview(file, port, no_browser, code)
    character(len=*), intent(in) :: file
    integer, intent(in) :: port
    logical, intent(in) :: no_browser
    integer, intent(out) :: code
    call preview_serve(file, port, .not. no_browser, code)
  end subroutine do_preview

  ! ------------------------------------------------------------------
  ! Dispatch (cli.py _dispatch + main).  The ONE select case.
  ! ------------------------------------------------------------------
  subroutine dispatch(code)
    integer, intent(out) :: code
    integer :: nargs
    character(len=:), allocatable :: a1, file, out_dir, name, scene
    logical :: has_out, explain, as_json, found, no_browser
    integer :: port
    code = 0
    nargs = command_argument_count()
    if (nargs == 0) then
       call discover_scene(scene, found)
       if (.not. found) then
          call print_help(error_unit)
          call err_line("error: no .f3d file here -- create one:  "// &
                        "f3dc new hello")
          code = 2
          return
       end if
       call do_run(scene, "", .false., "", .false., code)
       return
    end if
    a1 = arg_at(1)
    select case (a1)
    case ("--version")
       call out_line("f3dc "//VERSION)
       code = 0
    case ("-h", "--help")
       call print_help(output_unit)
       code = 0
    case ("run")
       call parse_file_args("run", .true., .false., .false., file, &
                            out_dir, has_out, explain, as_json)
       call do_run(file, out_dir, has_out, "", .false., code)
    case ("build")
       call parse_file_args("build", .true., .true., .false., file, &
                            out_dir, has_out, explain, as_json)
       block
         character(len=:), allocatable :: od, st
         type(dyn) :: ir
         call do_build(file, out_dir, has_out, explain, "", .false., &
                       code, od, ir, st)
       end block
    case ("check")
       call parse_file_args("check", .false., .true., .true., file, &
                            out_dir, has_out, explain, as_json)
       call do_check(file, as_json, explain, code)
    case ("new")
       call parse_new_args(name)
       call do_new(name, code)
    case ("fmt")
       call parse_file_args("fmt", .false., .false., .false., file, &
                            out_dir, has_out, explain, as_json)
       call do_fmt(file, code)
    case ("doctor")
       call parse_doctor_args()
       call do_doctor(code)
    case ("preview")
       call parse_preview_args(file, port, no_browser)
       call do_preview(file, port, no_browser, code)
    case default
       if (len(a1) > 0 .and. a1(1:1) == "-") then
          call usage_error_main("unrecognized arguments: "// &
                                join_args(1, nargs))
       else if (is_scene_file(a1)) then
          call parse_bare_args(file, out_dir, has_out)
          call do_run(file, out_dir, has_out, "", .false., code)
       else
          call usage_error_main("unknown command '"//a1// &
               "' (commands: "//COMMAND_LIST// &
               "; or pass a scene file to run it)")
       end if
    end select
  end subroutine dispatch

end program f3dc
