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
!   f3dc_parser   :: subroutine parse_program_ast(text, source_name,
!                        bag, prog_ast, ok)   ! v3.0 C1 typed AST entry
!   f3dc_desugar  :: subroutine desugar(prog_in, bag, base_dir, prog_out)
!                    subroutine desugar_program_ast(prog_ast_in, bag,
!                        base_dir, prog_ast_out, ok)  ! v3.0 C1 typed
!   f3dc_ast      :: type ast_program
!                    function ast_program_to_dyn(prog_ast) result(dyn)
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
       path_dirname, path_basename, path_extension, &
       char_list, char_list_len, char_list_at
  use f3dc_plugins, only: plugin_configure, plugin_take_warnings
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, dyn_list_push, &
       dyn_list_len, dyn_list_at, dyn_dict_set, dyn_dict_get, &
       dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
       DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, make_span, make_diagnostic, &
       make_diagnostic_span, error_bag_add, error_bag_set_source, &
       error_bag_len, error_bag_has_errors, error_bag_fail_code, &
       error_bag_format_text, error_bag_format_json, &
       error_bag_use_color, error_bag_debug_text
  use f3dc_parser, only: parse_program_ast
  use f3dc_ast, only: ast_program, ast_program_to_dyn
  use f3dc_validate, only: validate_program, &
       f3dc_validate_import_deps
  use f3dc_ext_geometry, only: eg_estimate => estimate_triangles
  use f3dc_optimize, only: optimize
  use f3dc_desugar, only: desugar, desugar_program_ast
  use f3dc_compat, only: ast_from_obj, ast_from_legacy_json, &
       is_legacy_json
  use f3dc_ir, only: ir_from_json
  use f3dc_emit_fortran, only: emit_scene_text, emit_fortran_program
  use f3dc_emit_json, only: emit_json_v2, emit_json_legacy
  use f3dc_emit_js, only: emit_js
  use f3dc_emit_html, only: emit_html, emit_html_runtime_js
  use f3dc_emit_timeline, only: tl_reset, tl_add_scene, &
       tl_finalize
  use f3dc_val_timeline, only: timeline_fragment
  use f3dc_driver, only: driver_repo_root, driver_find_tool, &
       driver_ensure_engine, driver_run_engine, driver_run_capture, &
       driver_quote, driver_cwd, driver_file_exists, driver_is_dir, &
       driver_abs_path, driver_manifest_check, driver_manifest_write, &
       driver_timing_reset, driver_timing_mark, driver_timing_ms
  use f3dc_preview, only: preview_serve
  implicit none

  character(len=*), parameter :: VERSION = "3.0.0"
  ! _COMMANDS in cli.py, in cli.py's order (used in the error text).
  character(len=*), parameter :: COMMAND_LIST = &
       "run, build, check, new, fmt, doctor, preview, bench, profile"

  ! _LAST in cli.py: state from the most recent compile_pipeline().
  type(dyn) :: last_program
  logical :: last_program_set = .false.
  ! Dependencies dep_add had to drop because the dep array was
  ! full (reset by collect_build_deps, read by do_build, which
  ! reports the overflow with a named error -- never silently).
  integer :: dep_overflow_count = 0
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
    write (unit, '(A)') "usage: f3dc [-h] [--version] {run,build,check,new,preview,fmt,doctor,bench,profile} ..."
    write (unit, '(A)') ""
    write (unit, '(A)') "Forge3D compiler -- compile and run .f3d scenes, the easy way"
    write (unit, '(A)') ""
    write (unit, '(A)') "positional arguments:"
    write (unit, '(A)') "  {run,build,check,new,preview,fmt,doctor,bench,profile}"
    write (unit, '(A)') "    run                 build, compile the engine and render"
    write (unit, '(A)') "    build               compile to build/ (Fortran + JSON + JS + HTML)"
    write (unit, '(A)') "    check               validate only -- no files written"
    write (unit, '(A)') "    new                 create <name>.f3d from the starter template"
    write (unit, '(A)') "    preview             real-time preview in the browser -- recompiles and"
    write (unit, '(A)') "                        reloads on save"
    write (unit, '(A)') "    fmt                 print the canonical .f3d form to stdout"
    write (unit, '(A)') "    doctor              check gfortran / make / cc and print fixes"
    write (unit, '(A)') "    bench               run the engine frame-time benchmarks (repo"
    write (unit, '(A)') "                        scenes under docs/bench/)"
    write (unit, '(A)') "    profile             build a scene and print per-stage compile"
    write (unit, '(A)') "                        timings (parse, desugar, validate, emit, write)"
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
       call out_line("  --force            rebuild even if the outputs are up to date")
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
    case ("bench")
       call out_line("usage: f3dc bench [-h] [--runs N] [--json]")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help  show this help message and exit")
       call out_line("  --runs N    timed runs per scene (default 3, median reported)")
       call out_line("  --json      print results as JSON")
    case ("profile")
       call out_line("usage: f3dc profile [-h] [-o OUT] file")
       call out_line("")
       call out_line("positional arguments:")
       call out_line("  file               scene file (.f3d, .json or .obj)")
       call out_line("")
       call out_line("options:")
       call out_line("  -h, --help         show this help message and exit")
       call out_line("  -o OUT, --out OUT  output directory (default: build/)")
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
    case ("bench");  out = "usage: f3dc bench [-h] [--runs N] [--json]"
    case ("profile"); out = "usage: f3dc profile [-h] [-o OUT] file"
    case default;    out = "usage: f3dc [-h] [--version] {run,build,check,new,preview,fmt,doctor,bench,profile} ..."
    end select
  end function sub_usage

  ! argparse parser.error() on the TOP parser (unrecognized args in
  ! cli.py surface here because _dispatch re-parses with the main
  ! parser): main usage + "f3dc: error: ..." on stderr, exit 2.
  subroutine usage_error_main(msg)
    character(len=*), intent(in) :: msg
    call err_line("usage: f3dc [-h] [--version] {run,build,check,new,preview,fmt,doctor,bench,profile} ...")
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
    inquire (file=path, exist=there, size=sz)
    if (.not. there) then
       text = ""
       return
    end if
    open (newunit=unit, file=path, access="stream", &
          form="unformatted", status="old", iostat=ios)
    if (ios /= 0) then
       text = ""
       return
    end if
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

  ! (The old fmt_colour helper rendered a colour list in Python
  ! "[r, g, b]" style, which the .f3d lexer rejects; its callers
  ! now use fmt_colour_val / fmt_obj_colour in the fmt section,
  ! which emit the grammar's spaced 'rgb r g b' form.)

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
  ! Typed-AST front end (v3.0 Phase 6 / C1)
  !
  ! .f3d sources no longer parse straight into dyn dicts here:
  ! parse_program_ast (f3dc_parser) builds a typed ast_program,
  ! desugar_program_ast (f3dc_desugar) rewrites that typed tree,
  ! and ast_program_to_dyn (f3dc_ast) converts it to dyn ONCE.
  !
  ! DYN BOUNDARY (intentional, do not "fix" by converting further):
  ! everything past that single conversion still consumes dyn --
  ! validate_program (which still runs its own dyn desugar pass
  ! internally, exactly as before) and the Fortran / JSON / JS /
  ! HTML emitters.  The boundary therefore sits between
  ! desugar_program_ast and validate_program in compile_pipeline.
  ! The .obj / legacy-.json compat loaders have no typed entry
  ! point, so they still enter directly at the dyn side of the
  ! boundary, unchanged.
  ! ------------------------------------------------------------------

  ! Parse only, via the typed AST, converted once to dyn.  Used by
  ! do_fmt, which prints the program as written and must NOT see a
  ! desugared tree (groups/repeats/defaults would change its output).
  subroutine parse_typed_to_dyn(text, source_name, bag, prog)
    character(len=*), intent(in) :: text, source_name
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: prog
    type(ast_program) :: prog_ast
    logical :: ast_ok
    call parse_program_ast(text, source_name, bag, prog_ast, ast_ok)
    call dyn_assign(prog, ast_program_to_dyn(prog_ast))
  end subroutine parse_typed_to_dyn

  ! Parse + desugar, both on the typed AST, converted once to dyn.
  ! On a parse error the desugar step is skipped (nested tests, not
  ! a compound .and.: Fortran does not short-circuit) and the raw
  ! typed tree is converted instead, so last_program and the error
  ! path in compile_pipeline see the same shape as before.
  subroutine compile_typed_to_dyn(text, source_name, base_dir, &
                                  bag, prog)
    character(len=*), intent(in) :: text, source_name, base_dir
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: prog
    type(ast_program) :: prog_ast, desugared_ast
    logical :: ast_ok
    ! v3.0 Phase 8 (profile): the two halves ARE separable here, so
    ! "parse" marks the end of parse_program_ast and "desugar" the
    ! end of desugar_program_ast; the single ast_program_to_dyn
    ! conversion is counted in the desugar half.  On a parse error
    ! desugar is skipped and no "desugar" mark is made.
    call parse_program_ast(text, source_name, bag, prog_ast, ast_ok)
    call driver_timing_mark("parse")
    if (error_bag_has_errors(bag)) then
       call dyn_assign(prog, ast_program_to_dyn(prog_ast))
    else
       call desugar_program_ast(prog_ast, bag, base_dir, &
                                desugared_ast, ast_ok)
       call dyn_assign(prog, ast_program_to_dyn(desugared_ast))
       call driver_timing_mark("desugar")
    end if
  end subroutine compile_typed_to_dyn

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
    ! v3.0 Phase 8 (profile): every compile starts a fresh timing
    ! registry; the marks below are clock reads only, so all other
    ! commands pay nothing beyond those reads.
    call driver_timing_reset()
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
       ! Approximation: the compat loaders parse and desugar in a
       ! single step, so "parse" and "desugar" both mark here.
       call driver_timing_mark("parse")
       call driver_timing_mark("desugar")
    else if (ext == ".json") then
       if (.not. is_legacy_json(text)) then
          ! A v2 IR dump (has "ir_version"): load directly, still
          ! optimize.  Python probes with json.loads + key check;
          ! ir_from_json + a key probe mirrors that here.
          if (index(text, '"ir_version"') > 0) then
             call ir_from_json(text, ir, j_ok)
             if (j_ok) then
                if (error_bag_has_errors(bag)) return
                ! Approximation: an IR dump has no parse/desugar/
                ! validate stages; "parse" and "desugar" mark the
                ! load, and "validate" marks the optimize below.
                call driver_timing_mark("parse")
                call driver_timing_mark("desugar")
                last_program_set = .false.
                call optimize(ir, bag, 1, ir_opt)
                ir = dyn_copy(ir_opt)
                call driver_timing_mark("validate")
                ok = .true.
                return
             end if
          end if
       end if
       call ast_from_legacy_json(text, bag, prog)
       ! Approximation: as for .obj above, the legacy-JSON loader
       ! parses and desugars in a single step.
       call driver_timing_mark("parse")
       call driver_timing_mark("desugar")
    else
       ! .f3d: typed pipeline -- parse_program_ast, then
       ! desugar_program_ast, then ONE ast_program_to_dyn
       ! conversion (see compile_typed_to_dyn above).
       call compile_typed_to_dyn(text, path, path_dirname(path), &
                                 bag, prog)
    end if
    last_program = dyn_copy(prog)
    last_program_set = .true.
    if (error_bag_has_errors(bag)) return
    ! DYN BOUNDARY: prog is dyn from here on.  validate_program and
    ! the emitters still consume dyn by design (C1 remainder), so
    ! this call and everything downstream are unchanged.
    call validate_program(prog, bag, path_dirname(path), ir, vok)
    call driver_timing_mark("validate")
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
    ! This call site stays on the dyn desugar on purpose: it runs
    ! on last_program, which is already past the dyn boundary (the
    ! .f3d path stored the converted typed-desugared tree; the
    ! .obj/.json paths stored a raw compat dyn tree), and f3dc_ast
    ! provides no dyn -> ast_program converter to re-enter the
    ! typed pipeline from here.  For .f3d inputs this re-applies
    ! desugar to an already-desugared program; for compat inputs
    ! it is the only desugar --explain performs, as before.
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
  ! Quote a string value for .f3d output (the lexer has no escape
  ! sequences: a value containing '"' cannot be represented and is
  ! passed through unchanged).
  function quote_str(v) result(out)
    character(len=*), intent(in) :: v
    character(len=:), allocatable :: out
    if (index(v, '"') > 0) then
       out = v
    else
       out = '"'//v//'"'
    end if
  end function quote_str

  ! True for a bare-identifier spelling [A-Za-z_][A-Za-z0-9_-]*.
  logical function is_ident(s)
    character(len=*), intent(in) :: s
    integer :: i, c
    is_ident = .false.
    if (len(s) == 0) return
    c = iachar(s(1:1))
    if (.not. ((c >= iachar('A') .and. c <= iachar('Z')) .or. &
               (c >= iachar('a') .and. c <= iachar('z')) .or. &
               c == iachar('_'))) return
    do i = 2, len(s)
       c = iachar(s(i:i))
       if (.not. ((c >= iachar('A') .and. c <= iachar('Z')) .or. &
                  (c >= iachar('a') .and. c <= iachar('z')) .or. &
                  (c >= iachar('0') .and. c <= iachar('9')) .or. &
                  c == iachar('_') .or. c == iachar('-'))) return
    end do
    is_ident = .true.
  end function is_ident

  ! Colour value in surface syntax: a name / #hex string passes
  ! through; an [r,g,b] list prints in the grammar's spaced rgb
  ! form ('rgb 60 220 120'), which lp_colour accepts.
  function fmt_colour_val(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_STR) then
       out = v%s
    else if (v%kind == DYN_K_LIST) then
       out = "rgb "//fmt_vec(v)
    else
       out = fmt_num(v)
    end if
  end function fmt_colour_val

  ! Object colour head: colour_raw is canonical except for its
  ! 'rgb(r,g,b)' spelling, which the lexer rejects; print the
  ! spaced rgb form from the colour list instead.
  function fmt_obj_colour(stmt) result(out)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable :: out
    type(dyn) :: raw, col
    out = ""
    raw = dget(stmt, "color_raw")
    if (raw%kind /= DYN_K_STR) return
    if (len(raw%s) == 0) return
    if (len(raw%s) >= 4) then
       if (raw%s(1:4) == "rgb(") then
          col = dget(stmt, "color")
          if (col%kind == DYN_K_LIST) then
             out = "rgb "//fmt_vec(col)
             return
          end if
       end if
    end if
    out = raw%s
  end function fmt_obj_colour

  ! List-of-points in surface syntax: each point comma-joined,
  ! points space-separated ('0,0,0 1,1,0'), as lp_numbers_ahead
  ! grouping in object_props accepts for path/points/shape.
  recursive function fmt_points(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer :: i, j
    type(dyn) :: el, sub
    out = ""
    if (v%kind /= DYN_K_LIST) then
       out = fmt_num(v)
       return
    end if
    do i = 1, dyn_list_len(v)
       el = dyn_list_at(v, i)
       if (i > 1) out = out//" "
       if (el%kind == DYN_K_LIST) then
          do j = 1, dyn_list_len(el)
             sub = dyn_list_at(el, j)
             if (j > 1) out = out//","
             out = out//fmt_num(sub)
          end do
       else
          out = out//fmt_num(el)
       end if
    end do
  end function fmt_points

  ! Numeric list equality (int/real tolerant), for the light
  ! position-vs-from dedup.
  logical function vec_eq(a, b)
    type(dyn), intent(in) :: a, b
    integer :: i
    type(dyn) :: x, y
    vec_eq = .false.
    if (a%kind /= DYN_K_LIST .or. b%kind /= DYN_K_LIST) return
    if (dyn_list_len(a) /= dyn_list_len(b)) return
    do i = 1, dyn_list_len(a)
       x = dyn_list_at(a, i)
       y = dyn_list_at(b, i)
       if (x%kind == DYN_K_INT .and. y%kind == DYN_K_INT) then
          if (x%i /= y%i) return
       else if ((x%kind == DYN_K_INT .or. x%kind == DYN_K_REAL) &
          .and. (y%kind == DYN_K_INT .or. y%kind == DYN_K_REAL)) then
          if (fmt_num(x) /= fmt_num(y)) return
       else
          return
       end if
    end do
    vec_eq = .true.
  end function vec_eq

  subroutine format_props(props, parts, excl1, excl2, excl3, excl4, &
                          excl5, excl6, excl7, excl8)
    type(dyn), intent(in) :: props
    character(len=:), allocatable, intent(out) :: parts
    character(len=*), intent(in), optional :: excl1, excl2, &
         excl3, excl4, excl5, excl6, excl7, excl8
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
       if (present(excl3)) then
          if (key == excl3) cycle
       end if
       if (present(excl4)) then
          if (key == excl4) cycle
       end if
       if (present(excl5)) then
          if (key == excl5) cycle
       end if
       if (present(excl6)) then
          if (key == excl6) cycle
       end if
       if (present(excl7)) then
          if (key == excl7) cycle
       end if
       if (present(excl8)) then
          if (key == excl8) cycle
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
    else if ((key == "fog" .or. key == "tonemap" .or. &
              key == "shadow" .or. key == "antialias") .and. &
             value%kind == DYN_K_STR) then
       ! Scene environment clauses are stored as full clause text
       ! ('fog linear near 30 far 80'); print verbatim, not keyed.
       piece = value%s
    else if ((key == "texture" .or. key == "normalmap" .or. &
              key == "mr" .or. key == "emissivemap" .or. &
              key == "occlusionmap") .and. &
             value%kind == DYN_K_STR) then
       ! Texture paths need quoting: a bare path's '/' / '.' are
       ! lexer errors.
       piece = key//" "//quote_str(value%s)
    else if ((key == "path" .or. key == "points" .or. &
              key == "shape") .and. value%kind == DYN_K_LIST) then
       piece = key//" "//fmt_points(value)
    else if (key == "loop" .and. value%kind == DYN_K_STR .and. &
             len(value%s) > 8) then
       ! A counted loop is stored as "repeat(N)" (lp_loop_repeat),
       ! which does not lex back; the surface form is 'repeat N'
       ! (same conversion as fmt_loop_tail, for the generic
       ! format_props path used by legacy AnimStmt).
       if (value%s(1:7) == "repeat(" .and. &
           value%s(len(value%s):len(value%s)) == ")") then
          piece = key//" repeat "//value%s(8:len(value%s) - 1)
       else
          piece = key//" "//fmt_num(value)
       end if
    else if (key == "emissive") then
       piece = key//" "//fmt_colour_val(value)
    else if (value%kind == DYN_K_LIST) then
       piece = key//" "//fmt_vec(value)
    else
       piece = key//" "//fmt_num(value)
    end if
    if (len(parts) > 0) parts = parts//" "
    parts = parts//piece
  end subroutine append_prop

  ! ------------------------------------------------------------------
  ! Animation-compiler statements (ANIM-PLAN SS1 / SS2.1): canonical
  ! forms for the ten new kinds, recognised by their ONE marker key,
  ! checked FIRST (before every older signature, exactly as
  ! f3dc_ast's classify_stmt orders them -- a dialogue node's
  ! "content" would otherwise read as a TextStmt).  Marker keys
  ! never occur on a pre-animation node, so programs without the
  ! new statements format byte-identically to before.
  !
  ! Canonicalisation (SS1): verbs print in the "-s" sentence form
  ! (walk -> walks); the adverb aliases print canonical (slowly ->
  ! ease out, gently -> ease ease-in-out); a cue tail prints in
  ! the SS1.3 grammar order -- verb arguments, ordinary anim
  ! props, [in|for <duration>], [ease <name>], [loop <mode>].
  ! ------------------------------------------------------------------
  function canon_ease(e) result(out)
    character(len=*), intent(in) :: e
    character(len=:), allocatable :: out
    select case (trim(e))
    case ("slowly")
       out = "out"
    case ("gently")
       out = "ease-in-out"
    case default
       out = trim(e)
    end select
  end function canon_ease

  ! SS1.3: the canonical verb form is the natural "-s" sentence
  ! form; the base form is an accepted alias.  Only the first word
  ! of a verb phrase is mapped ("pick up" -> "picks up"); a word
  ! already in "-s" form, and any unknown word (a custom action
  ! name), passes through verbatim.
  function canon_verb_phrase(verb) result(out)
    character(len=*), intent(in) :: verb
    character(len=:), allocatable :: out, first, canon
    integer :: sp
    sp = index(trim(verb), " ")
    if (sp == 0) then
       first = trim(verb)
    else
       first = trim(verb(1:sp - 1))
    end if
    select case (first)
    case ("walk");   canon = "walks"
    case ("run");    canon = "runs"
    case ("wave");   canon = "waves"
    case ("sit");    canon = "sits"
    case ("stand");  canon = "stands"
    case ("jump");   canon = "jumps"
    case ("fall");   canon = "falls"
    case ("look");   canon = "looks"
    case ("face");   canon = "faces"
    case ("point");  canon = "points"
    case ("nod");    canon = "nods"
    case ("shake");  canon = "shakes"
    case ("dance");  canon = "dances"
    case ("sleep");  canon = "sleeps"
    case ("smile");  canon = "smiles"
    case ("pick");   canon = "picks"
    case ("give");   canon = "gives"
    case ("tap");    canon = "taps"
    case ("spin");   canon = "spins"
    case ("move");   canon = "moves"
    case ("exit");   canon = "exits"
    case ("do");     canon = "does"
    case ("follow"); canon = "follows"
    case ("zoom");   canon = "zooms"
    case ("pan");    canon = "pans"
    case ("orbit");  canon = "orbits"
    case ("bob");    canon = "bobs"
    case ("pulse");  canon = "pulses"
    case ("turn");   canon = "turns"
    case ("grow");   canon = "grows"
    case ("say");    canon = "says"
    case default;    canon = first
    end select
    if (sp == 0) then
       out = canon
    else
       out = canon//trim(verb(sp:))
    end if
  end function canon_verb_phrase

  ! "second" for a numeric 1, else "seconds" (SS1 writes
  ! '1 second', '4 seconds').
  function seconds_word(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    out = "seconds"
    if (v%kind == DYN_K_INT) then
       if (v%i == 1_int64) out = "second"
    else if (v%kind == DYN_K_REAL) then
       if (v%r == 1.0_real64) out = "second"
    end if
  end function seconds_word

  ! The unit word for a duration value: "beat"/"beats" when the
  ! unit field says beats, else "second"/"seconds" (singular for
  ! a numeric 1 in both cases).
  function dur_unit_word(v, unit) result(out)
    type(dyn), intent(in) :: v
    character(len=*), intent(in) :: unit
    character(len=:), allocatable :: out
    if (trim(unit) == "beats" .or. trim(unit) == "beat") then
       if (seconds_word(v) == "second") then
          out = "beat"
       else
          out = "beats"
       end if
    else
       out = seconds_word(v)
    end if
  end function dur_unit_word

  ! SS1.4 timing prefix: "with " / "at <time> " / "after <anchor> ";
  ! the default ("then") prints nothing.
  function fmt_timing_prefix(stmt) result(out)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable :: out
    character(len=:), allocatable :: timing
    type(dyn) :: a, o
    out = ""
    timing = dstr(stmt, "timing", "then")
    select case (trim(timing))
    case ("with")
       out = "with "
    case ("at")
       o = dget(stmt, "offset")
       if (o%kind == DYN_K_INT .or. o%kind == DYN_K_REAL) then
          out = "at "//fmt_num(o)//" "// &
                dur_unit_word(o, dstr(stmt, "offset_unit", ""))//" "
       else
          a = dget(stmt, "anchor")
          if (a%kind == DYN_K_STR) out = "at "//a%s//" "
       end if
    case ("after")
       a = dget(stmt, "anchor")
       if (a%kind == DYN_K_STR) then
          out = "after "//a%s//" "
          o = dget(stmt, "offset")
          if (o%kind == DYN_K_INT .or. o%kind == DYN_K_REAL) then
             if (fmt_num(o) /= "0") &
                out = "after "//a%s//" "//fmt_num(o)//" "// &
                      seconds_word(o)//" "
          end if
       end if
    end select
  end function fmt_timing_prefix

  ! The SS1.3 duration tail: " <prep> <duration>", where the
  ! duration value is a number of seconds (a "duration_unit" of
  ! "beats" prints beats, SS1.4), a verbatim string (a duration
  ! phrase or a let-bound name, SS1.8), or absent (no tail).  An
  ! explicit "duration_prep" field wins over the caller's default
  ! preposition ("in" for movement / camera, "for" for sustained
  ! actions and dialogue).
  function fmt_duration_tail(stmt, prep_default) result(out)
    type(dyn), intent(in) :: stmt
    character(len=*), intent(in) :: prep_default
    character(len=:), allocatable :: out, prep, unit
    type(dyn) :: v
    out = ""
    v = dget(stmt, "duration")
    if (v%kind == DYN_K_NULL) return
    prep = dstr(stmt, "duration_prep", "")
    if (len(prep) == 0) prep = prep_default
    if (v%kind == DYN_K_STR) then
       out = " "//prep//" "//trim(v%s)
    else if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) then
       unit = dstr(stmt, "duration_unit", "")
       out = " "//prep//" "//fmt_num(v)//" "//dur_unit_word(v, unit)
    end if
  end function fmt_duration_tail

  ! A duration with no preposition (" 3 seconds" / " wait-time"),
  ! for the forms whose grammar takes the duration bare: the
  ! `wait` cue and the `action` header.
  function fmt_duration_bare(stmt) result(out)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable :: out, unit
    type(dyn) :: v
    out = ""
    v = dget(stmt, "duration")
    if (v%kind == DYN_K_STR) then
       out = " "//trim(v%s)
    else if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) then
       unit = dstr(stmt, "duration_unit", "")
       out = " "//fmt_num(v)//" "//dur_unit_word(v, unit)
    end if
  end function fmt_duration_bare

  ! The ' loop <mode>' tail from a props bag.  The parser stores
  ! a counted loop as the string "repeat(N)" (lp_loop_repeat),
  ! which does NOT lex back -- the surface form is 'repeat N'.
  ! The plain loop words (once / forever / pingpong) and a bare
  ! "repeat" print verbatim.
  function fmt_loop_tail(props) result(out)
    type(dyn), intent(in) :: props
    character(len=:), allocatable :: out
    type(dyn) :: v
    out = ""
    v = dget(props, "loop")
    if (v%kind /= DYN_K_STR) return
    if (len(v%s) > 8) then
       if (v%s(1:7) == "repeat(" .and. &
           v%s(len(v%s):len(v%s)) == ")") then
          out = " loop repeat "//v%s(8:len(v%s) - 1)
          return
       end if
    end if
    out = " loop "//v%s
  end function fmt_loop_tail

  ! A cue destination / target value in surface form: a bare name
  ! or a space-joined vec3 (parse_dest accepts both back).
  function fmt_dest(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    out = ""
    if (v%kind == DYN_K_STR) then
       out = v%s
    else if (v%kind == DYN_K_LIST) then
       out = fmt_vec(v)
    else if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) then
       out = fmt_num(v)
    end if
  end function fmt_dest

  ! The props a named tail already consumed (ease / loop / style /
  ! ...) are excluded via a ",key,key," list; the rest print in
  ! insertion order through append_prop, as format_props does.
  subroutine fmt_extra_props(props, excl_csv, parts)
    type(dyn), intent(in) :: props
    character(len=*), intent(in) :: excl_csv
    character(len=:), allocatable, intent(out) :: parts
    character(len=:), allocatable :: key
    integer :: i
    parts = ""
    if (props%kind /= DYN_K_DICT) return
    do i = 1, dyn_dict_len(props)
       key = dyn_dict_key_at(props, i)
       if (index(excl_csv, ","//trim(key)//",") > 0) cycle
       call append_prop(parts, trim(key), &
                        dyn_copy(dyn_dict_get(props, key)))
    end do
  end subroutine fmt_extra_props

  ! A container's children (under "body" for the animation kinds,
  ! else "children"), indented two spaces, plus the closing "end"
  ! -- the GroupStmt printer's shape.
  subroutine append_body_lines(stmt, out)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable, intent(inout) :: out
    type(dyn) :: v
    character(len=:), allocatable :: body_line
    integer :: i
    v = dget(stmt, "body")
    if (dyn_list_len(v) == 0) v = dget(stmt, "children")
    do i = 1, dyn_list_len(v)
       call format_stmt(dyn_list_at(v, i), body_line)
       out = out//achar(10)//"  "//body_line
    end do
    out = out//achar(10)//"end"
  end subroutine append_body_lines

  recursive subroutine format_stmt(stmt, out)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable, intent(out) :: out
    type(dyn) :: props, v, w
    character(len=:), allocatable :: parts, body_line
    integer :: i
    out = ""
    props = dget(stmt, "props")
    if (dhas(stmt, "film_def") .or. dhas(stmt, "char_def") .or. &
        dhas(stmt, "action_def") .or. &
        dhas(stmt, "timeline_def") .or. dhas(stmt, "cue") .or. &
        dhas(stmt, "cam_move") .or. dhas(stmt, "say") .or. &
        dhas(stmt, "transition") .or. dhas(stmt, "loop_block") &
        .or. dhas(stmt, "let_name") .or. dhas(stmt, "place")) then
       ! Animation-compiler kinds (ANIM-PLAN SS2.1), marker-checked
       ! first, in classify_stmt's order.
       call format_anim_stmt(stmt, props, out)
    else if (dhas(stmt, "prim")) then
       ! ObjectStmt
       parts = dstr(stmt, "prim", "cube")
       if (dnonnull(stmt, "name")) parts = parts//" "//dstr(stmt, "name", "")
       body_line = fmt_obj_colour(stmt)
       if (len(body_line) > 0) parts = parts//" "//body_line
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
       ! The parser stores the block's statements under "children"
       ! ("body" is the dataclass default, always empty); the old
       ! printer read "body" and silently dropped every child.
       v = dget(stmt, "children")
       if (dyn_list_len(v) == 0) v = dget(stmt, "body")
       do i = 1, dyn_list_len(v)
          call format_stmt(dyn_list_at(v, i), body_line)
          out = out//achar(10)//"  "//body_line
       end do
       out = out//achar(10)//"end"
    else if (dhas(stmt, "obj") .and. dhas(stmt, "mode")) then
       ! RepeatStmt: the parser stores the real counts under
       ! "count" (repeat/ring) and "rows"/"cols" (grid); the old
       ! printer read the dataclass defaults a=0 / b=None and so
       ! printed 'repeat 0' / 'grid 0', losing the counts.
       block
         character(len=:), allocatable :: mode, head
         type(dyn) :: a, b, obj
         mode = dstr(stmt, "mode", "repeat")
         if (mode == "grid") then
            a = dget(stmt, "rows")
            b = dget(stmt, "cols")
            if (a%kind == DYN_K_NULL) a = dyn_int(0_int64)
            if (b%kind == DYN_K_NULL) b = a
            head = "grid "//fmt_num(a)//"x"//fmt_num(b)
         else
            a = dget(stmt, "count")
            if (a%kind == DYN_K_NULL) a = dyn_int(0_int64)
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
       ! LightStmt: kind, direction (bare vec3, as the parser
       ! accepts), colour, then the fields the old printer dropped:
       ! position ('at'), target ('look'), and the Wave A extras
       ! (angle/penumbra/distance/decay, held in props).  A 'from'
       ! light prints 'from' (direction/position derive from it);
       ! 'at' is skipped when it merely restates 'from'.
       parts = "light "//dstr(stmt, "kind", "directional")
       v = dget(stmt, "from_")
       if (v%kind /= DYN_K_NULL) then
          parts = parts//" from "//fmt_vec(v)
       else
          v = dget2(stmt, "direction", "dir")
          if (v%kind /= DYN_K_NULL) parts = parts//" "//fmt_vec(v)
       end if
       v = dget(stmt, "color")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" "//fmt_colour_val(v)
       v = dget(stmt, "position")
       if (v%kind /= DYN_K_NULL) then
          w = dget(stmt, "from_")
          if (w%kind == DYN_K_NULL) then
             parts = parts//" at "//fmt_vec(v)
          else if (.not. vec_eq(v, w)) then
             parts = parts//" at "//fmt_vec(v)
          end if
       end if
       v = dget(stmt, "target")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" look "//fmt_vec(v)
       props = dget(stmt, "props")
       v = dget(props, "angle")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" angle "//fmt_num(v)
       v = dget(props, "penumbra")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" penumbra "//fmt_num(v)
       v = dget(props, "distance")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" distance "//fmt_num(v)
       v = dget(props, "decay")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" decay "//fmt_num(v)
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
       if (dnonnull(stmt, "path")) &
          parts = parts//" "//quote_str(dstr(stmt, "path", ""))
       v = dget(stmt, "width")
       w = dget(stmt, "height")
       if (v%kind /= DYN_K_NULL .and. w%kind /= DYN_K_NULL) &
          parts = parts//" size "//fmt_num(v)//"x"//fmt_num(w)
       v = dget(stmt, "still")
       if (v%kind == DYN_K_BOOL .and. v%b) parts = parts//" still"
       if (dnonnull(stmt, "duration")) &
          parts = parts//" duration "//fmt_num(dget(stmt, "duration"))
       if (dnonnull(stmt, "fps")) &
          parts = parts//" fps "//fmt_num(dget(stmt, "fps"))
       if (dnonnull(stmt, "frames")) &
          parts = parts//" frames "//fmt_num(dget(stmt, "frames"))
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
       ! SceneStmt: 'background' lives in props under its long
       ! name (and colour/color aliases), so excluding only "bg"
       ! printed it twice ('bg black background black', E110 on
       ! re-parse).  Print bg once, from the node's bg value (any
       ! colour form), and exclude every alias from the props.
       parts = "scene"
       if (dnonnull(stmt, "name")) then
          body_line = dstr(stmt, "name", "")
          if (is_ident(body_line)) then
             parts = parts//" "//body_line
          else
             parts = parts//" "//quote_str(body_line)
          end if
       end if
       v = dget(stmt, "width")
       w = dget(stmt, "height")
       if (v%kind /= DYN_K_NULL .and. w%kind /= DYN_K_NULL) &
          parts = parts//" size "//fmt_num(v)//"x"//fmt_num(w)
       v = dget(stmt, "bg")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" bg "//fmt_colour_val(v)
       call format_props(props, body_line, "size", "background", &
                         "colour", "color", "transition", &
                         "transition_variant", &
                         "transition_duration", &
                         "transition_duration_unit")
       if (len(body_line) > 0) parts = parts//" "//body_line
       ! Film-mode transition prop (SS1.7): the parser homes it in
       ! the props bag under internal key names; print the surface
       ! clause 'transition <kind> [variant] [<dur> <unit>]'.
       v = dget(props, "transition")
       if (v%kind == DYN_K_STR) then
          parts = parts//" transition "//v%s
          v = dget(props, "transition_variant")
          if (v%kind == DYN_K_STR) parts = parts//" "//v%s
          v = dget(props, "transition_duration")
          if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) &
             parts = parts//" "//fmt_num(v)//" "// &
                     dur_unit_word(v, &
                        dstr(props, "transition_duration_unit", ""))
       end if
       out = parts
    else if (dhas(stmt, "autorotate")) then
       ! ControlsStmt: "kind" holds the dataclass default
       ! ("orbit"); the parsed mode is under "mode" -- printing
       ! "kind" turned 'controls none' into 'controls orbit'.
       parts = "controls "//dstr(stmt, "mode", &
                                 dstr(stmt, "kind", "orbit"))
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "fov") .and. dhas(stmt, "pos") .and. &
             dhas(stmt, "target")) then
       ! CameraStmt: the parser stores the position under "at"
       ! ("pos" is always null on a parsed node), so the old
       ! printer dropped every camera position; 'ortho' and the
       ! ortho 'size' live only in props and were dropped too.
       parts = "camera"
       v = dget(props, "ortho")
       if (v%kind == DYN_K_BOOL .and. v%b) parts = parts//" ortho"
       v = dget(props, "size")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" size "//fmt_num(v)
       v = dget(stmt, "at")
       if (v%kind /= DYN_K_NULL) parts = parts//" at "//fmt_vec(v)
       v = dget(stmt, "target")
       if (v%kind /= DYN_K_NULL) parts = parts//" look "//fmt_vec(v)
       v = dget(stmt, "up")
       if (v%kind /= DYN_K_NULL) parts = parts//" up "//fmt_vec(v)
       if (dnonnull(stmt, "fov")) parts = parts//" fov "//fmt_num(dget(stmt, "fov"))
       if (dnonnull(stmt, "near")) parts = parts//" near "//fmt_num(dget(stmt, "near"))
       if (dnonnull(stmt, "far")) parts = parts//" far "//fmt_num(dget(stmt, "far"))
       out = parts
    else if (dhas(stmt, "amount")) then
       ! FilterStmt: 'filter <name> [amount]'
       parts = "filter "//dstr(stmt, "name", "")
       v = dget(stmt, "amount")
       if (v%kind /= DYN_K_NULL) parts = parts//" "//fmt_num(v)
       out = parts
    else if (dhas(stmt, "expr")) then
       ! ShaderStmt: 'shader <name> expr "<expr>"'
       parts = "shader "//dstr(stmt, "name", "")//" expr "// &
               quote_str(dstr(stmt, "expr", ""))
       out = parts
    else if (dhas(stmt, "factor")) then
       ! MorphStmt: 'morph <target> <kind> <factor>'
       parts = "morph "//dstr(stmt, "target", "")//" "// &
               dstr(stmt, "kind", "")//" "// &
               fmt_num(dget(stmt, "factor"))
       out = parts
    else if (dhas(stmt, "bone")) then
       ! SkinStmt: 'skin <target> <bone>'
       parts = "skin "//dstr(stmt, "target", "")//" "// &
               dstr(stmt, "bone", "")
       out = parts
    else if (dhas(stmt, "source")) then
       ! InstanceStmt: 'instance <name> of <source> [props]'
       parts = "instance "//dstr(stmt, "name", "")//" of "// &
               dstr(stmt, "source", "")
       call format_props(props, body_line, "source")
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "content")) then
       ! TextStmt: 'text [name] "<content>" [colour] [props]'
       parts = "text"
       if (dnonnull(stmt, "name")) &
          parts = parts//" "//dstr(stmt, "name", "")
       parts = parts//" "//quote_str(dstr(stmt, "content", ""))
       v = dget(stmt, "colour")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" "//fmt_colour_val(v)
       call format_props(props, body_line, "content")
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(stmt, "time")) then
       ! KeyStmt: 'key <target> at <t> [pos ..] [rot ..]
       ! [scale ..] [ease ..]' (props keys pos/rot, not at/rotate)
       parts = "key "//dstr(stmt, "target", "")//" at "// &
               fmt_num(dget(stmt, "time"))
       v = dget(stmt, "pos")
       if (v%kind /= DYN_K_NULL) parts = parts//" pos "//fmt_vec(v)
       v = dget(stmt, "rot")
       if (v%kind /= DYN_K_NULL) parts = parts//" rot "//fmt_vec(v)
       v = dget(stmt, "scale")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" scale "//fmt_num(v)
       if (dnonnull(stmt, "ease")) &
          parts = parts//" ease "//dstr(stmt, "ease", "")
       out = parts
    else if (dhas(stmt, "duration") .and. dhas(stmt, "loop")) then
       ! KeysStmt: 'keys <target> [duration N] [loop X] [fps N]'
       parts = "keys "//dstr(stmt, "target", "")
       if (dnonnull(stmt, "duration")) &
          parts = parts//" duration "// &
                  fmt_num(dget(stmt, "duration"))
       if (dnonnull(stmt, "loop")) &
          parts = parts//" loop "//dstr(stmt, "loop", "")
       if (dnonnull(stmt, "fps")) &
          parts = parts//" fps "//fmt_num(dget(stmt, "fps"))
       out = parts
    else if (dhas(stmt, "colour")) then
       ! SpriteStmt / ParticlesStmt (particles carry a count
       ! prop): '<kw> [name] [colour] [props]'; the old fallback
       ! dropped both the name and the colour.
       if (dhas(props, "count")) then
          parts = "particles"
       else
          parts = "sprite"
       end if
       if (dnonnull(stmt, "name")) &
          parts = parts//" "//dstr(stmt, "name", "")
       v = dget(stmt, "colour")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" "//fmt_colour_val(v)
       call format_props(props, body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else if (dhas(props, "name") .and. dhas(stmt, "name")) then
       ! BoneStmt: 'bone <name> [props]' (props carry a duplicate
       ! "name" key, excluded here)
       parts = "bone "//dstr(stmt, "name", "")
       call format_props(props, body_line, "name")
       if (len(body_line) > 0) parts = parts//" "//body_line
       out = parts
    else
       ! Unknown statement kind: Python prints the class name +
       ! formatted props; the class name is recovered from the
       ! parser's key signatures (ext_class_name).  Every kind the
       ! parser produces has a real printer above; this remains
       ! only for foreign (compat/obj) nodes.
       parts = ext_class_name(stmt)
       call format_props(props, body_line)
       if (len(body_line) > 0) then
          if (len(parts) > 0) parts = parts//" "
          parts = parts//body_line
       end if
       out = parts
    end if
  end subroutine format_stmt

  ! Canonical forms for the ten animation-compiler kinds
  ! (ANIM-PLAN SS1 / SS2.1).  Key homes are SS2.6's table, as
  ! landed in f3dc_ast: payload in the props bag, everything else
  ! in fields (read here as top-level dyn keys), children under
  ! "body".  Every field read is guarded, so a partially populated
  ! node still prints its recognisable head.
  recursive subroutine format_anim_stmt(stmt, props, out)
    type(dyn), intent(in) :: stmt, props
    character(len=:), allocatable, intent(out) :: out
    type(dyn) :: v, w
    character(len=:), allocatable :: parts, body_line, act, sp
    integer :: i
    out = ""
    if (dhas(stmt, "film_def")) then
       ! FilmStmt: 'film "<title>" [size W H] [fps N] [tempo N]'
       parts = "film"
       body_line = dstr(stmt, "title", "")
       if (len(body_line) == 0) body_line = dstr(stmt, "name", "")
       if (len(body_line) > 0) parts = parts//" "//quote_str(body_line)
       v = dget(stmt, "size")
       if (v%kind == DYN_K_LIST) then
          parts = parts//" size "//fmt_vec(v)
       else if (v%kind == DYN_K_STR) then
          parts = parts//" size "//v%s
       else if (v%kind /= DYN_K_NULL) then
          parts = parts//" size "//fmt_num(v)
       end if
       if (dnonnull(stmt, "fps")) &
          parts = parts//" fps "//fmt_num(dget(stmt, "fps"))
       if (dnonnull(stmt, "tempo")) &
          parts = parts//" tempo "//fmt_num(dget(stmt, "tempo"))
       out = parts
    else if (dhas(stmt, "char_def")) then
       ! CharacterStmt: 'character <name> [colour] [proportions]
       ! [props]'; member statements (a non-empty body) print as
       ! an indented block closed by "end", like a group.
       parts = "character"
       if (dnonnull(stmt, "name")) &
          parts = parts//" "//dstr(stmt, "name", "")
       v = dget(props, "colour")
       if (v%kind == DYN_K_NULL) v = dget(props, "color")
       if (v%kind /= DYN_K_NULL) &
          parts = parts//" "//fmt_colour_val(v)
       v = dget(props, "proportions")
       if (v%kind == DYN_K_STR) then
          ! 'tall' / 'short' / 'kid' print as the bare word.
          parts = parts//" "//v%s
       else if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) then
          parts = parts//" height "//fmt_num(v)
       end if
       call format_props(props, body_line, "proportions", "wears")
       if (len(body_line) > 0) parts = parts//" "//body_line
       ! `wears` rides the props bag as a list of {item, colour}
       ! dicts (SS1.2); print one 'wears <item> [colour]' clause
       ! per entry, never the dict literal.
       v = dget(props, "wears")
       if (v%kind == DYN_K_LIST) then
          do i = 1, dyn_list_len(v)
             w = dyn_list_at(v, i)
             if (w%kind /= DYN_K_DICT) cycle
             parts = parts//" wears "//dstr(w, "item", "")
             w = dget(w, "colour")
             if (w%kind /= DYN_K_NULL) &
                parts = parts//" "//fmt_colour_val(w)
          end do
       end if
       out = parts
       v = dget(stmt, "body")
       if (dyn_list_len(v) == 0) v = dget(stmt, "children")
       if (dyn_list_len(v) > 0) call append_body_lines(stmt, out)
    else if (dhas(stmt, "action_def")) then
       ! ActionDefStmt: 'action <name> [for <duration>]' + indented
       ! cue body + "end"; the header duration is the declared
       ! duration field (SS2.1), null = sum of the steps.
       parts = "action"
       if (dnonnull(stmt, "name")) &
          parts = parts//" "//dstr(stmt, "name", "")
       parts = parts//fmt_duration_tail(stmt, "for")
       out = parts
       call append_body_lines(stmt, out)
    else if (dhas(stmt, "place")) then
       ! PlaceStmt (SS1.1): 'place <name> at <vec3>' -- the name
       ! and the position are fields, not props.
       parts = "place"
       if (dnonnull(stmt, "name")) &
          parts = parts//" "//dstr(stmt, "name", "")
       v = dget(stmt, "at")
       if (v%kind == DYN_K_NULL) v = dget(props, "at")
       if (v%kind /= DYN_K_NULL) parts = parts//" at "//fmt_vec(v)
       out = parts
    else if (dhas(stmt, "timeline_def")) then
       ! TimelineStmt: implicit (authors never write it) -- print
       ! the shot's cues bare, in source order, no header / "end".
       v = dget(stmt, "body")
       if (dyn_list_len(v) == 0) v = dget(stmt, "children")
       do i = 1, dyn_list_len(v)
          call format_stmt(dyn_list_at(v, i), body_line)
          if (i > 1) out = out//achar(10)
          out = out//body_line
       end do
    else if (dhas(stmt, "cue")) then
       ! CueStmt: '[with|at ..|after ..] <target> <verb-s> [args]
       ! [props] [in|for <duration>] [ease <name>] [loop <mode>]'.
       ! The parser's shape (SS2.1): "action" is a FIELD holding
       ! the canonical BASE-form verb (or a custom action name
       ! for `does`, or "enter" for 'walks in from', or "wait"
       ! with a null target); the verb arguments ride the PROPS
       ! bag (to / on / from / target / expression / hand /
       ! object / give_to / direction), as do duration and
       ! duration_unit -- none of those internal keys may print.
       parts = fmt_timing_prefix(stmt)
       act = dstr(stmt, "action", "")
       if (len(act) == 0) act = dstr(stmt, "verb", "")
       if (act == "wait") then
          ! The SS1.4 pause: 'wait <duration>', duration bare.
          parts = parts//"wait"//fmt_duration_bare(stmt)
          out = parts
          return
       end if
       parts = parts//dstr(stmt, "target", "")
       select case (trim(act))
       case ("walk")
          parts = parts//" walks to "//fmt_dest(dget(props, "to"))
       case ("enter")
          parts = parts//" walks in from "// &
                  fmt_dest(dget(props, "from"))
       case ("run")
          parts = parts//" runs to "//fmt_dest(dget(props, "to"))
       case ("move")
          parts = parts//" moves to "//fmt_dest(dget(props, "to"))
       case ("wave")
          parts = parts//" waves"
          sp = dstr(props, "hand", "")
          if (sp == "left" .or. sp == "right") then
             parts = parts//" "//trim(sp)//" hand"
          else if (sp == "both") then
             parts = parts//" both hands"
          end if
       case ("sit")
          parts = parts//" sits"
          if (dnonnull(props, "on")) &
             parts = parts//" on "//dstr(props, "on", "")
       case ("stand")
          parts = parts//" stands"
       case ("jump")
          parts = parts//" jumps"
       case ("nod")
          parts = parts//" nods"
       case ("fall")
          parts = parts//" falls"
       case ("look")
          parts = parts//" looks at "// &
                  fmt_dest(dget(props, "target"))
       case ("point")
          parts = parts//" points at "// &
                  fmt_dest(dget(props, "target"))
       case ("face")
          v = dget(props, "expression")
          if (v%kind == DYN_K_STR) then
             parts = parts//" faces "//v%s
          else
             parts = parts//" faces "// &
                     fmt_dest(dget(props, "target"))
          end if
       case ("shake")
          parts = parts//" shakes head"
       case ("dance")
          parts = parts//" dances"
       case ("sleep")
          parts = parts//" sleeps"
       case ("smile")
          parts = parts//" smiles"
       case ("pick")
          parts = parts//" picks up "//dstr(props, "object", "")
       case ("give")
          parts = parts//" gives "//dstr(props, "object", "")// &
                  " to "//dstr(props, "give_to", "")
       case ("tap")
          parts = parts//" taps foot"
       case ("spin")
          parts = parts//" spins"
       case ("exit")
          parts = parts//" exits"
          if (dnonnull(props, "direction")) &
             parts = parts//" "//dstr(props, "direction", "")
       case default
          ! A custom action name (SS1.3 `does <name>`); the
          ! parser stores the name itself in "action".
          parts = parts//" does "//trim(act)
       end select
       call fmt_extra_props(props, &
            ",to,on,from,target,expression,hand,object,give_to,"// &
            "direction,duration,duration_unit,ease,loop,", &
            body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       ! Movement verbs take "in <duration>", the rest "for".
       select case (trim(act))
       case ("walk", "enter", "run", "move", "exit")
          parts = parts//fmt_duration_tail(stmt, "in")
       case default
          parts = parts//fmt_duration_tail(stmt, "for")
       end select
       v = dget(props, "ease")
       if (v%kind == DYN_K_STR) &
          parts = parts//" ease "//canon_ease(v%s)
       parts = parts//fmt_loop_tail(props)
       out = parts
    else if (dhas(stmt, "cam_move")) then
       ! CamMoveStmt: '[timing] camera <move> [target] [props]
       ! [in <duration>] [ease <name>]'.  The parser's shape
       ! (SS2.1): "move" is a FIELD holding follow / zoom_in /
       ! zoom_out / pan / orbit / look; the followed name rides
       ! "follow", a named target rides "target_name", a vec3
       ! target rides "to_look" (the fov / to_pos fields are
       ! null on parsed nodes -- they are desugar's homes).
       parts = fmt_timing_prefix(stmt)//"camera"
       act = dstr(stmt, "move", "")
       if (len(act) == 0) act = dstr(stmt, "action", "")
       select case (trim(act))
       case ("follow")
          parts = parts//" follows "//dstr(stmt, "follow", "")
       case ("zoom_in", "zoom_out")
          if (act == "zoom_in") then
             parts = parts//" zooms in"
          else
             parts = parts//" zooms out"
          end if
          if (dnonnull(stmt, "target_name")) then
             parts = parts//" on "//dstr(stmt, "target_name", "")
          else if (dnonnull(stmt, "to_look")) then
             parts = parts//" on "//fmt_vec(dget(stmt, "to_look"))
          end if
       case ("pan")
          parts = parts//" pans to "
          if (dnonnull(stmt, "target_name")) then
             parts = parts//dstr(stmt, "target_name", "")
          else
             parts = parts//fmt_vec(dget(stmt, "to_look"))
          end if
       case ("orbit")
          parts = parts//" orbits "
          if (dnonnull(stmt, "target_name")) then
             parts = parts//dstr(stmt, "target_name", "")
          else
             parts = parts//fmt_vec(dget(stmt, "to_look"))
          end if
       case ("look")
          parts = parts//" looks at "
          if (dnonnull(stmt, "target_name")) then
             parts = parts//dstr(stmt, "target_name", "")
          else
             parts = parts//fmt_vec(dget(stmt, "to_look"))
          end if
       case default
          ! Foreign / desugared shapes: fall back to the followed
          ! name, then a look target, then a position target.
          if (dnonnull(stmt, "follow")) then
             parts = parts//" follows "//dstr(stmt, "follow", "")
          else if (dnonnull(stmt, "to_look")) then
             parts = parts//" looks at "// &
                     fmt_vec(dget(stmt, "to_look"))
          else if (dnonnull(stmt, "to_pos")) then
             parts = parts//" moves to "// &
                     fmt_vec(dget(stmt, "to_pos"))
          end if
       end select
       call fmt_extra_props(props, &
            ",move,follow,target_name,duration,duration_unit,"// &
            "ease,loop,", body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       parts = parts//fmt_duration_tail(stmt, "in")
       v = dget(stmt, "ease")
       if (v%kind /= DYN_K_STR) v = dget(props, "ease")
       if (v%kind == DYN_K_STR) &
          parts = parts//" ease "//canon_ease(v%s)
       parts = parts//fmt_loop_tail(props)
       out = parts
    else if (dhas(stmt, "say")) then
       ! DialogueStmt: '[timing] <speaker> says "<content>"
       ! [props] [for <duration>] [style]'; a speaker of
       ! "caption" / "title" (or none) prints the SS1.6
       ! screen-text forms instead.
       parts = fmt_timing_prefix(stmt)
       sp = dstr(stmt, "speaker", "")
       if (sp == "caption" .or. len(sp) == 0) then
          parts = parts//"caption"
       else if (sp == "title") then
          parts = parts//"title"
       else
          parts = parts//sp//" says"
       end if
       parts = parts//" "//quote_str(dstr(stmt, "content", ""))
       ! The props bag also carries duration / duration_unit /
       ! voice; only the style prints, and as its SS1.6 surface
       ! form ('bubble only', not the stored word 'bubble').
       call fmt_extra_props(props, &
            ",style,duration,duration_unit,voice,", body_line)
       if (len(body_line) > 0) parts = parts//" "//body_line
       parts = parts//fmt_duration_tail(stmt, "for")
       v = dget(props, "style")
       if (v%kind == DYN_K_STR) then
          select case (trim(v%s))
          case ("bubble")
             parts = parts//" bubble only"
          case ("subtitle")
             parts = parts//" subtitle only"
          case default
             parts = parts//" "//v%s
          end select
       end if
       out = parts
    else if (dhas(stmt, "transition")) then
       ! TransitionStmt: the only standalone transition node the
       ! parser emits is the SS1.7 closing cue, kind "fade_out",
       ! whose surface form is the cue 'fade out [in <duration>]'
       ! (with any timing prefix) -- there is no 'transition ...'
       ! line in the grammar.  Any other kind is a foreign node
       ! and keeps the bare fallback spelling.
       if (dstr(stmt, "kind", "") == "fade_out") then
          parts = fmt_timing_prefix(stmt)//"fade out"
          call fmt_extra_props(props, &
               ",duration,duration_unit,ease,loop,", body_line)
          if (len(body_line) > 0) parts = parts//" "//body_line
          parts = parts//fmt_duration_tail(stmt, "in")
          v = dget(props, "ease")
          if (v%kind == DYN_K_STR) &
             parts = parts//" ease "//canon_ease(v%s)
          parts = parts//fmt_loop_tail(props)
       else
          parts = "transition "//dstr(stmt, "kind", "cut")
          v = dget(stmt, "duration")
          if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) &
             parts = parts//" "//fmt_num(v)//" "// &
                     dur_unit_word(v, &
                        dstr(stmt, "duration_unit", ""))
       end if
       out = parts
    else if (dhas(stmt, "loop_block")) then
       ! LoopBlockStmt: 'repeat <count> times' + body + "end".
       ! The count is a number, or a string naming a `let`
       ! binding (kept verbatim; desugar substitutes it); a null
       ! count is the SS1.4 parallel block, 'together'.
       v = dget(stmt, "count")
       if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) then
          parts = "repeat "//fmt_num(v)//" times"
       else if (v%kind == DYN_K_STR) then
          parts = "repeat "//v%s//" times"
       else
          parts = "together"
       end if
       out = parts
       call append_body_lines(stmt, out)
    else if (dhas(stmt, "let_name")) then
       ! LetStmt: 'let <name> be <value>' (SS1.8) -- the value is
       ! a field: a name prints bare, any other string quoted, a
       ! list is an rgb colour (lp_colour's vec3 form) and prints
       ! 'rgb r g b', and a number carries its "value_unit"
       ! field -- a beats duration must print 'beats', or the
       ! re-parse silently turns it into seconds.
       parts = "let "//dstr(stmt, "let_name", "")//" be"
       v = dget(stmt, "value")
       if (v%kind == DYN_K_STR) then
          if (is_ident(v%s)) then
             parts = parts//" "//v%s
          else
             parts = parts//" "//quote_str(v%s)
          end if
       else if (v%kind == DYN_K_LIST) then
          parts = parts//" "//fmt_colour_val(v)
       else if (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL) then
          if (dhas(stmt, "value_unit")) then
             parts = parts//" "//fmt_num(v)//" "// &
                     dur_unit_word(v, dstr(stmt, "value_unit", ""))
          else
             parts = parts//" "//fmt_num(v)
          end if
       else if (v%kind /= DYN_K_NULL) then
          parts = parts//" "//fmt_num(v)
       end if
       out = parts
    end if
  end subroutine format_anim_stmt

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
    do while (i <= len(s))
       if (is_ws(s(i:i))) exit
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
    if (len(s) >= 2) then
       if (s(1:2) == "//") return
    end if
    w = first_word(s)
    do while (len(w) > 0)
       if (w(len(w):len(w)) /= ":") exit
       w = w(1:len(w) - 1)
    end do
    is_scene_line = (to_lower(w) == "scene")
  end function is_scene_line

  ! Same shape as is_scene_line, for the word "film": true when the
  ! first word of a (non-blank, non-comment) line is "film".
  logical function is_film_line(raw)
    character(len=*), intent(in) :: raw
    character(len=:), allocatable :: s, w
    s = strip_ws(raw)
    is_film_line = .false.
    if (len(s) == 0) return
    if (s(1:1) == "#") return
    if (len(s) >= 2) then
       if (s(1:2) == "//") return
    end if
    w = first_word(s)
    do while (len(w) > 0)
       if (w(len(w):len(w)) /= ":") exit
       w = w(1:len(w) - 1)
    end do
    is_film_line = (to_lower(w) == "film")
  end function is_film_line

  ! A file is a film file (ANIM-PLAN SS1.1) only when its FIRST
  ! statement is "film": scan past blank lines and comments and
  ! test the first remaining line.  Anything else -- including a
  ! "film" word appearing later -- is legacy, and legacy chunking
  ! must stay byte-identical.
  logical function text_is_film(lines, n_lines)
    character(len=:), allocatable, intent(in) :: lines(:)
    integer, intent(in) :: n_lines
    character(len=:), allocatable :: s
    integer :: i
    text_is_film = .false.
    do i = 1, n_lines
       s = strip_ws(trim(lines(i)))
       if (len(s) == 0) cycle
       if (s(1:1) == "#") cycle
       if (len(s) >= 2) then
          if (s(1:2) == "//") cycle
       end if
       text_is_film = is_film_line(trim(lines(i)))
       return
    end do
  end function text_is_film

  subroutine scene_chunks(text, chunks, n_chunks, multi)
    character(len=*), intent(in) :: text
    character(len=:), allocatable, intent(out) :: chunks(:)
    integer, intent(out) :: n_chunks
    logical, intent(out) :: multi
    character(len=:), allocatable :: lines(:)
    integer :: starts(512), n_starts, n_lines, k, e, i
    logical :: film_file
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
    ! Film files (ANIM-PLAN SS0 fact 8, SS1.7, SS8 Q3/Q6): the
    ! pre-scene prelude -- every line before the first "scene",
    ! i.e. the "film" statement plus the film-level definitions
    ! that precede it/follow it there (character declarations,
    ! action definitions including their whole "end"-terminated
    ! blocks, and let bindings, all copied verbatim in source
    ! order) -- is film-level, not scene-1-level.  Q3 rules
    ! characters are declared once per film, so that prelude must
    ! head EVERY chunk, or chunk 2+ would start at their "scene"
    ! line in legacy mode and their film lines (characters, cues)
    ! would fail to parse (E103/E104).  Legacy (non-film) files
    ! take the exact pre-existing path below: only chunk 1 gets
    ! the prelude, byte-identical to before.
    film_file = text_is_film(lines, n_lines)
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
         if (k == 1 .or. film_file) then
            do i = 1, starts(1) - 1
               acc = acc//trim(lines(i))
            end do
         end if
         ! The chunk's own lines follow verbatim, starting with
         ! its "scene" line -- so a scene's transition prop
         ! (SS1.7 / Q6: transitions are per-chunk metadata riding
         ! in the scene node's props bag) is never stripped by
         ! chunking; it reaches the chunk's parse untouched.
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
       do while (len(w) > 0)
          if (w(len(w):len(w)) /= ":") exit
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
            if (j <= len(t)) then
               if (.not. is_ws(t(j:j))) cycle
            end if
            if (j > a) then
               cnt = cnt + 1
               if (cnt == 2) then
                  out = t(a:j - 1)
                  return
               end if
            end if
            a = j + 1
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
                                force, stem_override, &
                                has_stem_override, &
                                code, out_dir, ir, stem)
    character(len=*), intent(in) :: path, out_dir_in, stem_override
    logical, intent(in) :: has_out, explain, force, &
         has_stem_override
    integer, intent(out) :: code
    character(len=:), allocatable, intent(out) :: out_dir, stem
    type(dyn), intent(out) :: ir
    character(len=:), allocatable :: chunks(:), temps(:), sub
    integer :: n_chunks, i, sub_code
    logical :: multi
    ! v3.0 Phase 6 (Seat X): incremental-build cache state.
    character(len=:), allocatable :: mpath
    ! Heap-allocated: 8192 x 4096 chars is far too big for the
    ! stack of this recursive subroutine.
    character(len=4096), allocatable :: dep_paths(:)
    integer :: n_deps
    logical :: cache_hit, cacheable, cache_protected, manifestable
    type(error_bag_t) :: bag
    logical :: ok
    character(len=256) :: names(7)
    character(len=:), allocatable :: c_scene, c_json, c_legacy, &
         c_js, c_html, c_f90, content_k, root, target, summary
    integer :: k
    logical :: wok
    ! ANIM Wave 2 slice B1: Timeline IR state for this build.
    character(len=:), allocatable :: tl_text, tl_err, tl_stem
    logical :: tl_made, tl_has
    integer :: n_out_names
    ir = dyn_null()
    out_dir = ""
    stem = ""
    tl_made = .false.
    call multi_chunks(path, chunks, n_chunks, multi)
    if (multi) then
       call write_chunks(path, chunks, n_chunks, temps)
       code = 0
       if (has_out) then
          out_dir = out_dir_in
       else
          out_dir = "build"
       end if
       ! Slice B1: the timeline aggregates ALL chunks into ONE
       ! file named after the build stem; chunk sub-builds only
       ! accumulate their scenes (tl_add_scene below).
       call tl_reset()
       do i = 1, n_chunks
          sub = path_stem(path)//"-"// &
                chunk_scene_name(trim(chunks(i)), i - 1)
          call do_build(trim(temps(i)), out_dir_in, has_out, explain, &
                        force, sub, .true., sub_code, out_dir, ir, stem)
          if (sub_code /= 0 .and. code == 0) code = sub_code
       end do
       call drop_chunks(temps, n_chunks)
       if (code == 0) then
          tl_stem = path_stem(path)
          call tl_finalize(tl_stem, VERSION, path_basename(path), &
                           path, tl_text, tl_has, tl_err)
          if (len(tl_err) > 0) then
             call err_line("error E201: "//tl_err)
             code = 1
             return
          end if
          if (tl_has) then
             call write_file(out_dir//"/"//tl_stem// &
                  ".timeline.json", tl_text, wok)
             if (.not. wok) then
                call err_line("error E502: cannot write output: "// &
                     "i/o error")
                code = 3
                return
             end if
          else
             ! Absence = still: remove any stale timeline file.
             call delete_quiet(out_dir//"/"//tl_stem// &
                  ".timeline.json")
          end if
       end if
       return
    end if
    ! Slice B1: a top-level (non-chunk) build starts a fresh
    ! timeline accumulation; chunk sub-builds append to it.
    if (.not. has_stem_override) call tl_reset()
    ! v3.0 Phase 6 (Seat X): incremental compile.  A plain
    ! `f3dc build` (no --force, no --explain, not a multi-scene
    ! chunk sub-build) may skip the compile when the manifest in
    ! the output directory proves every input byte-identical and
    ! every output present.  `run` passes force=.true. (it needs
    ! the IR and fresh outputs), and preview never calls do_build
    ! at all (f3dc_preview has its own in-memory pipeline), so
    ! neither can be served stale output by this cache.
    manifestable = .not. explain .and. .not. has_stem_override
    cacheable = manifestable .and. .not. force
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
    ! Slice B1: the timeline file is a SEVENTH, conditional
    ! output -- present in the manifest's output set exactly when
    ! the recorded build emitted one (see the manifest write).
    names(7) = stem//".timeline.json"
    if (cacheable) then
       ! The E502 protected-target refusal below must not be
       ! bypassed by a cache hit, so it is checked first here.
       call driver_repo_root(root)
       cache_protected = .false.
       do k = 1, 6
          target = driver_abs_path(out_dir//"/"//trim(names(k)))
          if (target == root//"/scene.json" .or. &
              target == root//"/viewer.html") &
             cache_protected = .true.
       end do
       cache_hit = .false.
       if (.not. cache_protected) then
          mpath = out_dir//"/.f3dc-manifest-"//stem
          ! Slice B1: a hit is a manifest whose recorded output
          ! set matches THIS build's possible outputs -- six
          ! names when the recorded build was a still (no
          ! timeline file), seven when it emitted a timeline
          ! (whose presence the check then verifies like any
          ! other output).  Pre-B1 manifests have six names and
          ! keep hitting.
          call driver_manifest_check(mpath, stem, out_dir, &
                                     names(1:6), cache_hit)
          if (cache_hit) then
             ! Six-name hit: the recorded build was a still, so
             ! a timeline file here could only be stale -- the
             ! absence rule (no file = still) removes it.
             call delete_quiet(out_dir//"/"//trim(names(7)))
          else
             call driver_manifest_check(mpath, stem, out_dir, &
                                        names(1:7), cache_hit)
          end if
       end if
       if (cache_hit) then
          ir = dyn_null()
          call out_line("up to date: "//path//" (manifest match)")
          code = 0
          return
       end if
    end if
    call compile_pipeline(path, bag, ir, ok)
    if (.not. ok) then
       call print_diagnostics(bag, .false.)
       code = error_bag_fail_code(bag)
       ir = dyn_null()
       return
    end if
    if (error_bag_len(bag) > 0) call print_diagnostics(bag, .false.)
    call scene_text(ir, stem, c_scene)
    call json_v2_text(ir, c_json)
    call json_legacy_text(ir, c_legacy)
    call js_text(ir, c_js)
    call html_text(ir, stem, c_html)
    call fortran_program_text(ir, stem, c_f90)
    ! v3.0 Phase 8 (profile): all six emitters have run.
    call driver_timing_mark("emit")
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
    ! v3.0 Phase 8 (profile): all six outputs are on disk.
    call driver_timing_mark("write")
    ! ANIM Wave 2 slice B1: Timeline IR.  Every successful build
    ! records its scene with the emitter (chunk sub-builds only
    ! accumulate; the multi-scene parent in the branch above
    ! finalizes).  A top-level single-scene build finalizes here:
    ! the file is written when the source has timeline content,
    ! and a stale file is removed when it does not (absence =
    ! still).  `check` never reaches this code, so it writes
    ! nothing.
    call tl_add_scene(ir, timeline_fragment(), trim(names(2)))
    n_out_names = 6
    if (.not. has_stem_override) then
       call tl_finalize(stem, VERSION, path_basename(path), path, &
                        tl_text, tl_has, tl_err)
       if (len(tl_err) > 0) then
          call err_line("error E201: "//tl_err)
          code = 1
          return
       end if
       if (tl_has) then
          call write_file(out_dir//"/"//trim(names(7)), tl_text, &
                          wok)
          if (.not. wok) then
             call err_line("error E502: cannot write output: "// &
                  "i/o error")
             code = 3
             return
          end if
          tl_made = .true.
          n_out_names = 7
       else
          call delete_quiet(out_dir//"/"//trim(names(7)))
       end if
    end if
    ! v3.0 Phase 6 (Seat X): record the incremental manifest for
    ! the next build.  Best effort and silent: a failed manifest
    ! write changes nothing about this build's outputs or exit
    ! code, it only forfeits a future skip.  A --force build
    ! still refreshes the manifest (it is a full build like any
    ! other); only the skip CHECK above honours --force.
    if (manifestable) then
       if (.not. allocated(dep_paths)) allocate (dep_paths(8192))
       call collect_build_deps(path, ir, dep_paths, n_deps)
       if (dep_overflow_count > 0) then
          ! A truncated dep list would prove a false "up to
          ! date" later, so the overflow is a named error and no
          ! manifest is written (the build's outputs are
          ! unaffected; only the future skip is forfeited, as
          ! with any manifest failure).
          call err_line("error E502: build dependency list "// &
               "overflow: "// &
               trim(fmt_int(int(dep_overflow_count, int64)))// &
               " dependencies did not fit the "// &
               trim(fmt_int(int(size(dep_paths), int64)))// &
               "-entry limit; skipping the incremental manifest "// &
               "for this build")
       else
          mpath = out_dir//"/.f3dc-manifest-"//stem
          ! Slice B1: record six output names for a still, seven
          ! when this build emitted a timeline file, so a later
          ! cache check verifies the timeline's presence too.
          call driver_manifest_write(mpath, stem, &
                                     names(1:n_out_names), &
                                     dep_paths, n_deps)
       end if
    end if
    if (explain) then
       summary = explain_text()
       if (len(summary) > 0) call err_line(summary)
    end if
    do k = 1, 6
       call out_line(out_dir//"/"//trim(names(k)))
    end do
    ! v3.0 Phase 8 (profile): end of the whole build path, from
    ! the driver_timing_reset at the top of compile_pipeline.
    call driver_timing_mark("total")
    code = 0
  end subroutine do_build

  ! ------------------------------------------------------------------
  ! profile (v3.0 Phase 8): build exactly as `build` does -- with
  ! force=.true., so the incremental cache can never serve a
  ! profiled build stale output and skip the work being timed --
  ! then print one line per compile stage from the timing
  ! registry f3dc_driver collected during that build.  A failed
  ! build prints no timings: do_build has already reported the
  ! diagnostics and its code is propagated unchanged.  For a
  ! multi-scene file the registry holds the LAST chunk's timings
  ! (each chunk's compile_pipeline resets it).
  ! ------------------------------------------------------------------
  subroutine do_profile(path, out_dir_in, has_out, code)
    character(len=*), intent(in) :: path, out_dir_in
    logical, intent(in) :: has_out
    integer, intent(out) :: code
    character(len=:), allocatable :: od, st
    type(dyn) :: ir
    integer :: i
    character(len=*), parameter :: PROFILE_STAGES(6) = &
         [character(len=8) :: "parse", "desugar", "validate", &
         "emit", "write", "total"]
    call do_build(path, out_dir_in, has_out, .false., .true., "", &
                  .false., code, od, ir, st)
    if (code /= 0) return
    do i = 1, size(PROFILE_STAGES)
       call profile_print_stage(trim(PROFILE_STAGES(i)))
    end do
  end subroutine do_profile

  ! One profile line, e.g. "  parse      12.3 ms"; a stage the
  ! registry does not know (driver_timing_ms < 0) prints "- ms".
  subroutine profile_print_stage(stage)
    character(len=*), intent(in) :: stage
    real(real64) :: ms
    character(len=32) :: num
    character(len=11) :: field
    ms = driver_timing_ms(stage)
    field = stage
    if (ms < 0.0_real64) then
       call out_line("  "//field//"- ms")
    else
       write (num, '(F0.1)') ms
       call out_line("  "//field//trim(num)//" ms")
    end if
  end subroutine profile_print_stage

  ! ------------------------------------------------------------------
  ! Incremental-build dependency collection (v3.0 Phase 6, Seat X)
  !
  ! The dependency set of a build -- every file whose bytes can
  ! change the six artifacts -- mirroring what the pipeline
  ! actually reads (the same set f3dc_preview's watcher collects,
  ! plus the HTML inputs and the compiler binary itself):
  !   * the source file itself;
  !   * imported part files (f3dc_validate_import_deps: desugar's
  !     resolved, recursive import list from this compile);
  !   * each object's "source_file" (load-ed OBJ / glTF), plus,
  !     for a .gltf, every non-data: "uri" in the file (external
  !     buffers and images);
  !   * each object's material texture slots (extensions.material:
  !     texture + the Phase 4 normalmap / mr / emissivemap /
  !     occlusionmap), resolved against the scene's base_dir
  !     exactly as the preview watcher resolves them;
  !   * the whole runtime family the HTML emitter inlines
  !     (<root>/runtime/f3d.js plus every runtime/f3d-*.js
  !     sidecar -- ANIM-PLAN SS2.5 risk 1) and the viewer
  !     template candidates emit_html reads for the .html output;
  !   * the f3dc binary itself, so a compiler upgrade invalidates.
  ! Texture CONTENTS never reach the artifacts (only the resolved
  ! path is emitted), but the files are hashed anyway: an edited
  ! texture must rebuild, per the Phase 6 brief.
  ! ------------------------------------------------------------------
  subroutine dep_add(deps, n_deps, p)
    character(len=4096), intent(inout) :: deps(:)
    integer, intent(inout) :: n_deps
    character(len=*), intent(in) :: p
    character(len=:), allocatable :: ap
    integer :: i
    if (len_trim(p) == 0) return
    ap = driver_abs_path(trim(p))
    do i = 1, n_deps
       if (trim(deps(i)) == ap) return
    end do
    if (n_deps >= size(deps)) then
       ! Never silent: count the drop; do_build turns a nonzero
       ! count into a named E502 and skips the manifest write.
       dep_overflow_count = dep_overflow_count + 1
       return
    end if
    n_deps = n_deps + 1
    deps(n_deps) = ap
  end subroutine dep_add

  ! Preview's pv_resolve, mirrored: absolute paths pass through,
  ! an already base_dir-prefixed path is left alone, anything else
  ! is joined onto base_dir.
  function dep_resolve(base_dir, s) result(out)
    character(len=*), intent(in) :: base_dir, s
    character(len=:), allocatable :: out
    logical :: already
    already = .false.
    if (len(base_dir) > 0 .and. base_dir /= ".") then
       if (len(s) > len(base_dir) + 1) &
          already = s(1:len(base_dir) + 1) == base_dir//"/"
    end if
    if (len(s) > 0) then
       if (s(1:1) == "/") then
          out = s
          return
       end if
    end if
    if (already) then
       out = s
    else if (len(base_dir) == 0) then
       out = s
    else if (base_dir(len(base_dir):len(base_dir)) == "/") then
       out = base_dir//s
    else
       out = base_dir//"/"//s
    end if
  end function dep_resolve

  subroutine collect_build_deps(path, ir, deps, n_deps)
    character(len=*), intent(in) :: path
    type(dyn), intent(in) :: ir
    character(len=4096), intent(out) :: deps(:)
    integer, intent(out) :: n_deps
    character(len=:), allocatable :: base_dir, root, s, exe
    type(dyn) :: ideps, objs, obj, exts, mat, v
    integer :: i, k
    character(len=12) :: slot_keys(5)
    n_deps = 0
    deps = ""
    dep_overflow_count = 0
    base_dir = dstr(ir, "base_dir", path_dirname(path))
    call dep_add(deps, n_deps, driver_abs_path(path))
    exe = arg_at(0)
    if (len_trim(exe) > 0) call dep_add(deps, n_deps, exe)
    call driver_repo_root(root)
    ! ANIM-PLAN SS2.5 risk 1: hash EVERY runtime file the HTML
    ! emitter inlines, not just the core.  f3dc_emit_html inlines
    ! runtime/f3d.js (emit_html_runtime_js, substituted into
    ! {{F3D_JS}}) and runtime/f3d-webgl2.js (emit_html_webgl2_js,
    ! {{WEBGL2_JS}}), and its header names the extension family
    ! runtime/f3d-*.js as the runtime the viewer is assembled
    ! from; the family is enumerated by the runtime aggregator
    ! runtime/f3d.mjs (mirrored in tools/build_runtime.mjs's
    ! MODULES): the core plus all fourteen sidecars.  Hashing the
    ! whole family means a runtime-only fix -- e.g. a new
    ! animation module -- can never be served a stale
    ! "up to date" skip.  (f3d.min.js is a build artifact of
    ! f3d.js, and f3d.mjs / f3d.d.ts are not inlined, so they
    ! are not deps.)
    block
      character(len=*), parameter :: RUNTIME_DEPS(16) = &
           [character(len=20) :: &
           "f3d.js", "f3d-geo.js", "f3d-env.js", "f3d-pbr.js", &
           "f3d-keys.js", "f3d-timeline.js", "f3d-instanced.js", &
           "f3d-post.js", &
           "f3d-shader.js", "f3d-skin.js", "f3d-sprites-text.js", &
           "f3d-particles.js", "f3d-webgl2.js", "f3d-xr.js", &
           "f3d-raycast.js", "f3d-ortho.js"]
      integer :: r
      do r = 1, size(RUNTIME_DEPS)
         call dep_add(deps, n_deps, &
                      root//"/runtime/"//trim(RUNTIME_DEPS(r)))
      end do
    end block
    call dep_add(deps, n_deps, &
                 root//"/tools/f3dc/viewer_template.html")
    call dep_add(deps, n_deps, &
                 root//"/tools/f3dc/templates/viewer_template.html")
    call dep_add(deps, n_deps, &
                 root//"/tools/f3dc/templates/viewer.html.tmpl")
    call dep_add(deps, n_deps, &
                 root//"/compiler/viewer_template.html")
    ideps = f3dc_validate_import_deps()
    do i = 1, dyn_list_len(ideps)
       v = dyn_list_at(ideps, i)
       if (v%kind == DYN_K_STR) then
          if (len_trim(v%s) > 0) call dep_add(deps, n_deps, v%s)
       end if
    end do
    slot_keys = [character(len=12) :: "texture", "normalmap", &
                 "mr", "emissivemap", "occlusionmap"]
    objs = dget(ir, "objects")
    do i = 1, dyn_list_len(objs)
       obj = dyn_list_at(objs, i)
       if (obj%kind /= DYN_K_DICT) cycle
       v = dget(obj, "source_file")
       if (v%kind == DYN_K_STR) then
          if (len_trim(v%s) > 0) then
             s = dep_resolve(base_dir, trim(v%s))
             call dep_add(deps, n_deps, s)
             if (suffix_lower(s) == ".gltf") &
                call gltf_uri_deps(s, deps, n_deps)
          end if
       end if
       exts = dget(obj, "extensions")
       if (exts%kind == DYN_K_DICT) then
          mat = dget(exts, "material")
          if (mat%kind == DYN_K_DICT) then
             do k = 1, 5
                v = dget(mat, trim(slot_keys(k)))
                if (v%kind == DYN_K_STR) then
                   if (len_trim(v%s) > 0) call dep_add(deps, &
                        n_deps, dep_resolve(base_dir, trim(v%s)))
                end if
             end do
          end if
       end if
    end do
  end subroutine collect_build_deps

  ! Every non-"data:" "uri" value in a .gltf text (external
  ! buffers and images), resolved against the .gltf's directory.
  subroutine gltf_uri_deps(gltf_path, deps, n_deps)
    character(len=*), intent(in) :: gltf_path
    character(len=4096), intent(inout) :: deps(:)
    integer, intent(inout) :: n_deps
    character(len=:), allocatable :: text, uri, dir
    logical :: rok
    integer :: pos, k, q1, q2
    call read_file(gltf_path, text, rok)
    if (.not. rok) return
    dir = path_dirname(gltf_path)
    pos = 1
    do while (pos <= len(text))
       k = index(text(pos:), '"uri"')
       if (k == 0) exit
       pos = pos + k - 1 + 5
       q1 = index(text(pos:), '"')
       if (q1 == 0) exit
       pos = pos + q1
       q2 = index(text(pos:), '"')
       if (q2 <= 1) exit
       uri = text(pos:pos + q2 - 2)
       pos = pos + q2
       if (len(uri) >= 5) then
          if (uri(1:5) == "data:") cycle
       end if
       if (len_trim(uri) > 0) &
          call dep_add(deps, n_deps, dep_resolve(dir, trim(uri)))
    end do
  end subroutine gltf_uri_deps

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
    ! force=.true.: `run` always compiles fresh (it consumes the
    ! IR and the outputs), so the incremental cache never serves
    ! it -- build semantics for run are exactly as before.
    call do_build(path, out_dir_in, has_out, .false., .true., &
                  stem_override, has_stem_override, code, out_dir, &
                  ir, stem)
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
       ! Typed parse + one conversion to dyn (parse_typed_to_dyn);
       ! deliberately NO desugar here -- fmt prints the source
       ! program, and the dyn formatter below is past the same
       ! intentional dyn boundary as validate / the emitters.
       call parse_typed_to_dyn(text, path, bag, prog)
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
         [character(len=9) :: "gfortran", "make", "cc"]
    integer :: k
    call driver_repo_root(root)
    call out_line("f3dc "//VERSION)
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
  ! bench (v3.0 Phase 0): frame-time baselines for the engine.
  ! Compiles each benchmark scene in-process (do_build) into a temp
  ! dir and times driver_run_engine over --runs runs, reporting the
  ! median wall-clock ms per frame.  Scenes live in the repo tree
  ! (examples/hello-cube.f3d + docs/bench/scenes/*.f3d); baselines
  ! recorded on a given machine go in docs/bench/BASELINES.md.
  ! ------------------------------------------------------------------
  subroutine parse_bench_args(runs, as_json)
    integer, intent(out) :: runs
    logical, intent(out) :: as_json
    integer :: nargs, i, ios
    character(len=:), allocatable :: tok, val
    runs = 3
    as_json = .false.
    nargs = command_argument_count()
    i = 2
    do while (i <= nargs)
       tok = arg_at(i)
       if (tok == "-h" .or. tok == "--help") then
          call print_sub_help("bench")
          call finish(0)
       else if (tok == "--runs" .or. starts_with(tok, "--runs=")) then
          if (tok == "--runs") then
             if (i == nargs) call usage_error_sub("bench", &
                  "argument --runs: expected one argument")
             i = i + 1
             val = arg_at(i)
          else
             val = tok(8:)
          end if
          read (val, *, iostat=ios) runs
          if (ios /= 0 .or. runs < 1 .or. runs > 25) &
             call usage_error_sub("bench", &
                  "argument --runs: invalid value: '"//val//"'")
       else if (tok == "--json") then
          as_json = .true.
       else
          call usage_error_sub("bench", &
               "unrecognized arguments: "//tok)
       end if
       i = i + 1
    end do
  end subroutine parse_bench_args

  subroutine do_bench(runs, as_json, code)
    integer, intent(in) :: runs
    logical, intent(in) :: as_json
    integer, intent(out) :: code
    character(len=*), parameter :: names(4) = [character(len=16) :: &
         "hello-cube", "objects-100", "textured-plane", "shadowed"]
    character(len=*), parameter :: rels(4) = [character(len=48) :: &
         "examples/hello-cube.f3d", &
         "docs/bench/scenes/objects100.f3d", &
         "docs/bench/scenes/textured.f3d", &
         "docs/bench/scenes/shadowed.f3d"]
    character(len=:), allocatable :: root, engine, msg
    logical :: failed
    integer :: s
    code = 0
    call driver_repo_root(root)
    call driver_ensure_engine(engine, msg, failed, root)
    if (failed) then
       call err_line("bench: "//trim(msg))
       code = 1
       return
    end if
    if (.not. as_json) then
       call out_line("f3dc bench -- engine frame times (median of "// &
                     trim(int_str(runs))//" runs)")
    else
       call out_line('{"tool": "f3dc bench", "version": "'//VERSION// &
                     '", "runs": '//trim(int_str(runs))//', "scenes": [')
    end if
    do s = 1, 4
       call bench_one(root, trim(names(s)), trim(rels(s)), runs, &
                      as_json, s == 4, code)
       if (code /= 0) return
    end do
    if (as_json) call out_line("]}")
  end subroutine do_bench

  subroutine bench_one(root, name, rel, runs, as_json, last, code)
    character(len=*), intent(in) :: root, name, rel
    integer, intent(in) :: runs
    logical, intent(in) :: as_json, last
    integer, intent(inout) :: code
    character(len=:), allocatable :: src, scratch, out_t, err_t, msg, &
         f3dc_path, scene_path
    integer :: r, rc, frames, p, ios
    logical :: failed, timed_out, found
    integer(int64) :: t0, t1, rate
    real(real64) :: secs(25), med
    character(len=32) :: num
    src = root//"/"//rel
    if (.not. driver_file_exists(src)) then
       call err_line("bench: scene not found: "//src)
       code = 1
       return
    end if
    ! Scratch lives under the repo, NOT /tmp: an animated scene
    ! writes one ASCII PPM per frame (~3.5 MB at 640x480), which
    ! overflows a small tmpfs and silently eats the engine's
    ! buffered stdout (and its last frames) on the failed flush.
    scratch = root//"/docs/bench/.work-"//name
    call execute_command_line("mkdir -p "//driver_quote(scratch))
    ! Build via the installed bin/f3dc with output captured, so the
    ! build's file listing cannot pollute bench's own output
    ! (in particular --json).  This also benches the real user path.
    call driver_find_tool(root//"/bin/f3dc", f3dc_path, found)
    if (.not. found) then
       call err_line("bench: bin/f3dc not found -- run 'make f3dc' first")
       code = 1
       return
    end if
    call driver_run_capture(driver_quote(f3dc_path)//" build -o "// &
         driver_quote(scratch)//" "//driver_quote(src), "", 600, rc, &
         out_t, err_t, timed_out)
    if (rc /= 0) then
       call err_line("bench: build failed for "//rel)
       code = 1
       return
    end if
    scene_path = scratch//"/"//stem_of(src)//".scene"
    frames = 1
    call system_clock(count_rate=rate)
    do r = 1, runs
       call system_clock(t0)
       call driver_run_engine(scene_path, scratch, 600, rc, out_t, &
                              err_t, msg, failed)
       call system_clock(t1)
       if (failed .or. rc /= 0) then
          call err_line("bench: engine run failed for "//rel)
          code = 1
          return
       end if
       secs(r) = real(t1 - t0, real64)/real(rate, real64)
       if (r == 1) then
          p = index(out_t, "Frames:")
          if (p > 0) then
             read (out_t(p + 7:), *, iostat=ios) frames
             if (ios /= 0 .or. frames < 1) frames = 1
          end if
       end if
    end do
    call sort_reals(secs, runs)
    if (mod(runs, 2) == 1) then
       med = secs(runs/2 + 1)
    else
       med = 0.5_real64*(secs(runs/2) + secs(runs/2 + 1))
    end if
    write (num, '(F0.3)') med*1000.0_real64/max(frames, 1)
    if (as_json) then
       call out_line('    {"scene": "'//name//'", "frames": '// &
            trim(int_str(frames))//', "ms_per_frame": '//trim(num)// &
            '}'//merge(',', ' ', .not. last))
    else
       call out_line("  "//name//": "//trim(int_str(frames))// &
            " frame(s), "//trim(num)//" ms/frame")
    end if
    call execute_command_line("rm -rf "//driver_quote(scratch))
  end subroutine bench_one

  function stem_of(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    integer :: slash, dot
    slash = index(path, "/", back=.true.)
    dot = index(path, ".", back=.true.)
    if (dot > slash) then
       out = path(slash + 1:dot - 1)
    else
       out = path(slash + 1:)
    end if
  end function stem_of

  subroutine sort_reals(a, n)
    real(real64), intent(inout) :: a(:)
    integer, intent(in) :: n
    integer :: i, j
    real(real64) :: tmp
    do i = 2, n
       tmp = a(i)
       j = i - 1
       do while (j >= 1)
          if (a(j) <= tmp) exit
          a(j + 1) = a(j)
          j = j - 1
       end do
       a(j + 1) = tmp
    end do
  end subroutine sort_reals

  function int_str(n) result(out)
    integer, intent(in) :: n
    character(len=:), allocatable :: out
    character(len=16) :: buf
    write (buf, '(I0)') n
    out = trim(buf)
  end function int_str

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
                             allow_json, allow_force, file, &
                             out_dir, has_out, explain, as_json, &
                             force)
    character(len=*), intent(in) :: cmd
    logical, intent(in) :: allow_out, allow_explain, allow_json, &
         allow_force
    character(len=:), allocatable, intent(out) :: file, out_dir
    logical, intent(out) :: has_out, explain, as_json, force
    integer :: nargs, i, n_extra
    character(len=:), allocatable :: tok, extras
    logical :: have_file
    nargs = command_argument_count()
    file = ""
    out_dir = ""
    has_out = .false.
    explain = .false.
    as_json = .false.
    force = .false.
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
       else if (allow_force .and. tok == "--force") then
          force = .true.
       else if (allow_json .and. tok == "--json") then
          as_json = .true.
       else if (starts_with(tok, "-")) then
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
       else if (starts_with(tok, "-")) then
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
       else if (starts_with(tok, "-")) then
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
  ! Wave 5 (docs/PLUGINS.md SS4/SS6): drain the plugin loader's
  ! collected warnings into stderr as W205 diagnostics, in the
  ! house format, once.  Draining forces the one-time package
  ! load, so this runs at dispatch entry, before any command
  ! output; with only well-formed packages (or none) it prints
  ! nothing and no command's behaviour changes.
  subroutine drain_plugin_warnings()
    type(error_bag_t) :: bag
    type(char_list) :: msgs
    character(len=:), allocatable :: text
    integer :: k
    call plugin_take_warnings(msgs)
    if (char_list_len(msgs) == 0) return
    do k = 1, char_list_len(msgs)
       call error_bag_add(bag, make_diagnostic( &
            "W205", "warning", char_list_at(msgs, k), &
            why="a plugin package must be a directory "// &
                "plugins/<id>/ containing a plugin.json this "// &
                "compiler can read", &
            help="fix the package or remove it from the plugin "// &
                 "search path"))
    end do
    text = error_bag_format_text(bag, error_bag_use_color())
    if (len(text) > 0) call err_line(text)
  end subroutine drain_plugin_warnings

  subroutine dispatch(code)
    integer, intent(out) :: code
    integer :: nargs
    character(len=:), allocatable :: a1, file, out_dir, name, scene
    logical :: has_out, explain, as_json, found, no_browser, force
    integer :: port, bench_runs
    logical :: bench_json
    code = 0
    ! Wave 5 (docs/PLUGINS.md SS4): resolve the repo root once and
    ! configure the plugin loader before dispatching any command,
    ! so build / check / fmt / preview (preview_serve is entered
    ! only from here -- f3dc_preview has no entry of its own) all
    ! see the same registry; then drain loader warnings once.
    block
      character(len=:), allocatable :: root
      call driver_repo_root(root)
      call plugin_configure(root)
    end block
    call drain_plugin_warnings()
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
       call parse_file_args("run", .true., .false., .false., &
                            .false., file, out_dir, has_out, &
                            explain, as_json, force)
       call do_run(file, out_dir, has_out, "", .false., code)
    case ("build")
       call parse_file_args("build", .true., .true., .false., &
                            .true., file, out_dir, has_out, &
                            explain, as_json, force)
       block
         character(len=:), allocatable :: od, st
         type(dyn) :: ir
         call do_build(file, out_dir, has_out, explain, force, "", &
                       .false., code, od, ir, st)
       end block
    case ("check")
       call parse_file_args("check", .false., .true., .true., &
                            .false., file, out_dir, has_out, &
                            explain, as_json, force)
       call do_check(file, as_json, explain, code)
    case ("new")
       call parse_new_args(name)
       call do_new(name, code)
    case ("fmt")
       call parse_file_args("fmt", .false., .false., .false., &
                            .false., file, out_dir, has_out, &
                            explain, as_json, force)
       call do_fmt(file, code)
    case ("doctor")
       call parse_doctor_args()
       call do_doctor(code)
    case ("preview")
       call parse_preview_args(file, port, no_browser)
       call do_preview(file, port, no_browser, code)
    case ("bench")
       call parse_bench_args(bench_runs, bench_json)
       call do_bench(bench_runs, bench_json, code)
    case ("profile")
       call parse_file_args("profile", .true., .false., .false., &
                            .false., file, out_dir, has_out, &
                            explain, as_json, force)
       call do_profile(file, out_dir, has_out, code)
    case default
       if (starts_with(a1, "-")) then
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
