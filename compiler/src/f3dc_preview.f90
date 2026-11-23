! f3dc_preview.f90 -- native port of tools/f3dc/preview.py (268 lines,
! read in full; see compiler/DESIGN.md, the binding contract).
!
! `f3dc preview scene.f3d` serves the compiled viewer on a local port
! and watches the scene file: every save recompiles through the same
! pipeline stages `f3dc build` uses and any open browser tab reloads
! itself.  A scene that fails to compile does not kill the preview:
! the tab shows the diagnostics and recovers by itself.
!
! Architecture (C/Fortran boundary, see compiler/preview_http.c):
!   - preview_http.c owns sockets, HTTP/1.1 parsing and response
!     writing ONLY.  It knows nothing about scenes.
!   - This module owns all state and body generation.  The C serve
!     loop calls back into pv_handler (bind(C)) once per request;
!     pv_handler routes on the path and produces the body, content
!     type and status, exactly like preview.py's Handler.do_GET.
!   - The watcher is driven from the serve loop: serve_once polls
!     with a 100 ms timeout and each timeout runs one watcher tick
!     (mtime poll + 150 ms debounce, like preview.py's _watch with
!     POLL_SECONDS=0.4 / DEBOUNCE_SECONDS=0.15; the tick runs more
!     often than Python's 0.4 s poll, so a save is noticed sooner --
!     timing-only divergence, same debounce and semantics).
!
! Pipeline note: cli.py's compile_pipeline is a program-internal
! procedure of f3dc_cli.f90 and cannot be called from a module, so
! pv_compile_pipeline below mirrors it statement for statement,
! composing the SAME module entry points it composes (f3dc_parse /
! ast_from_obj / ast_from_legacy_json / ir_from_json /
! f3dc_validate / optimize) and pv_html_text mirrors cli.py's
! _html_text (driver_repo_root + emit_html_runtime_js + emit_js +
! emit_html).  driver_repo_root itself lives after this module in
! the build order, so pv_repo_root mirrors its rule (parent of the
! directory holding the binary) using preview_http_self_exe.
!
! Divergences from preview.py (named, per DESIGN.md):
!   - No exceptions exist in Fortran, so compile_now's E9000
!     "internal compiler error" crash branch cannot trigger; a
!     pipeline failure is reported through the ErrorBag instead.
!   - Browser opening: Python uses webbrowser.open on a 0.3 s timer
!     (which itself usually resolves to xdg-open on Linux); here
!     xdg-open is launched asynchronously right after startup.
!   - E502 bind-failure text: Python embeds str(OSError) including
!     "[Errno 98]"; the C helper supplies strerror() text only.
!   - HTTP: one request per connection (Connection: close) instead
!     of Python's keep-alive threading server; non-GET methods get
!     a plain-text 501 instead of BaseHTTPRequestHandler's HTML.
!   - The startup line prints the scene path as passed on the
!     command line; Python prints str(Path(scene_path)).
!   - Ctrl+C: the C helper's SIGINT flag ends the loop, then the
!     same "\npreview stopped" line is printed and exit code is 0.
!
! v2.0 P5 extension (native-only; preview.py watched only the scene
! file): the watcher also watches the scene's dependency files --
! imported part files (the "_import_deps" list recorded by desugar
! and exposed through f3dc_validate's side-channel accessor
! f3dc_validate_import_deps -- deliberately NOT a scene-dyn key,
! because the .scene/_scene.f90 header stamps hash the whole IR)
! and asset files
! referenced by the compiled IR (each object's "source_file" for
! load-ed OBJ/glTF and "extensions.material.texture" for textures,
! resolved against the scene's "base_dir" when relative).  A dep
! whose mtime changes, appears or vanishes takes the same debounced
! recompile path as a scene save.  The dep set is rebuilt from every
! successful compile; on a failed compile the previous set stays in
! force (its stored mtimes are refreshed to the values just seen,
! so a broken dep does not retrigger a compile every tick).
module f3dc_preview
  use, intrinsic :: iso_fortran_env, only: output_unit, int64
  use, intrinsic :: iso_c_binding, only: c_char, c_int, c_int64_t, &
       c_ptr, c_funptr, c_funloc, c_f_pointer, c_associated, &
       c_null_char, c_null_ptr
  use f3dc_str, only: fmt_int, path_stem, path_dirname, &
       path_extension, to_lower, str_replace, str_builder, &
       sb_init, sb_add, sb_text, sb_len
  use f3dc_dyn, only: dyn, dyn_null, dyn_copy, dyn_dict_get, &
       dyn_list_len, dyn_list_at, DYN_K_STR, DYN_K_DICT
  use f3dc_errors, only: error_bag_t, diagnostic_t, make_span, &
       make_diagnostic_span, error_bag_add, error_bag_set_source, &
       error_bag_len, error_bag_at, error_bag_has_errors, &
       json_escape
  use f3dc_parser, only: f3dc_parse
  use f3dc_validate, only: validate_program, f3dc_validate_import_deps
  use f3dc_optimize, only: optimize
  use f3dc_compat, only: ast_from_obj, ast_from_legacy_json, &
       is_legacy_json
  use f3dc_ir, only: ir_from_json
  use f3dc_emit_js, only: emit_js
  use f3dc_emit_html, only: emit_html, emit_html_runtime_js
  implicit none
  private

  public :: preview_serve

  character(len=*), parameter :: NL = achar(10)
  character(len=*), parameter :: HOST = "127.0.0.1"

  ! PreviewState (preview.py): module-level singleton state.
  character(len=:), allocatable :: p_path, p_stem
  integer :: p_version = 0
  logical :: p_ok = .false.
  character(len=:), allocatable :: p_html
  logical :: p_has_html = .false.
  type(diagnostic_t), allocatable :: p_diags(:)
  integer :: p_ndiag = 0
  integer :: p_compile_count = 0
  integer(c_int64_t) :: p_mtime_ns = 0
  logical :: p_mtime_ok = .false.

  ! v2.0 P5: dependency watch set (imported parts + referenced
  ! assets), rebuilt by pv_collect_deps after each successful
  ! compile.  Capped so a pathological scene cannot grow the set
  ! without bound; entries past the cap are simply not watched.
  integer, parameter :: PV_MAX_DEPS = 512
  type :: pv_dep_t
    character(len=:), allocatable :: path
    integer(c_int64_t) :: mtime_ns = 0
    logical :: ok = .false.
  end type pv_dep_t
  type(pv_dep_t), allocatable :: p_deps(:)
  integer :: p_ndeps = 0

  interface
    function ph_open(host, port, actual, errbuf, errcap, errlen) &
        bind(C, name="preview_http_open") result(fd)
      import :: c_char, c_int
      character(kind=c_char) :: host(*)
      character(kind=c_char) :: errbuf(*)
      integer(c_int), value :: port, errcap
      integer(c_int) :: actual, errlen
      integer(c_int) :: fd
    end function ph_open

    function ph_serve_once(fd, handler, timeout_ms) &
        bind(C, name="preview_http_serve_once") result(rc)
      import :: c_int, c_funptr
      integer(c_int), value :: fd, timeout_ms
      type(c_funptr), value :: handler
      integer(c_int) :: rc
    end function ph_serve_once

    subroutine ph_close(fd) bind(C, name="preview_http_close")
      import :: c_int
      integer(c_int), value :: fd
    end subroutine ph_close

    function ph_mtime(path, out_ns) &
        bind(C, name="preview_http_mtime_ns") result(rc)
      import :: c_char, c_int, c_int64_t
      character(kind=c_char) :: path(*)
      integer(c_int64_t) :: out_ns
      integer(c_int) :: rc
    end function ph_mtime

    subroutine ph_sleep_ms(ms) bind(C, name="preview_http_sleep_ms")
      import :: c_int
      integer(c_int), value :: ms
    end subroutine ph_sleep_ms

    function ph_self_exe(buf, cap) &
        bind(C, name="preview_http_self_exe") result(n)
      import :: c_char, c_int
      character(kind=c_char) :: buf(*)
      integer(c_int), value :: cap
      integer(c_int) :: n
    end function ph_self_exe
  end interface

contains

  ! ------------------------------------------------------------------
  ! preview.py _CLIENT_JS / _TOOLBAR, byte for byte.
  ! ------------------------------------------------------------------
  function client_js() result(out)
    character(len=:), allocatable :: out
    out = NL// &
      "(function () {"//NL// &
      "  var seen = __VERSION__;"//NL// &
      "  var pill = document.getElementById('f3d-pill');"//NL// &
      "  var fpsEl = document.getElementById('f3d-fps');"//NL// &
      "  var frames = 0, last = performance.now();"//NL// &
      "  function tick(now) {"//NL// &
      "    frames++;"//NL// &
      "    if (now - last >= 500) {"//NL// &
      "      if (fpsEl) fpsEl.textContent = Math.round(frames * 1000 / (now - last)) + ' fps';"//NL// &
      "      frames = 0; last = now;"//NL// &
      "    }"//NL// &
      "    requestAnimationFrame(tick);"//NL// &
      "  }"//NL// &
      "  requestAnimationFrame(tick);"//NL// &
      "  setInterval(function () {"//NL// &
      "    fetch('/__version', {cache: 'no-store'}).then(function (r) { return r.json(); })"//NL// &
      "      .then(function (v) {"//NL// &
      "        if (v.version !== seen) { location.reload(); return; }"//NL// &
      "        if (pill) {"//NL// &
      "          pill.textContent = v.ok ? '"//achar(226)//achar(151)// &
      achar(143)//" LIVE' : '"//achar(226)//achar(151)//achar(143)// &
      " ERROR';"//NL// &
      "          pill.style.color = v.ok ? '#4ade80' : '#f87171';"//NL// &
      "        }"//NL// &
      "      }).catch(function () {"//NL// &
      "        if (pill) { pill.textContent = '"//achar(226)// &
      achar(151)//achar(143)//" OFFLINE'; pill.style.color = '#f87171'; }"//NL// &
      "      });"//NL// &
      "  }, 600);"//NL// &
      "})();"//NL
  end function client_js

  function toolbar() result(out)
    character(len=:), allocatable :: out
    ! The bullet below is U+25CF (E2 97 8F), the em dash U+2014
    ! (E2 80 94) and the middle dot U+00B7 (C2 B7), written as byte
    ! escapes so this source stays pure ASCII.
    out = NL// &
      '<div id="f3d-preview-bar" style="position:fixed;top:0;left:0;right:0;z-index:9999;'//NL// &
      '  display:flex;gap:14px;align-items:center;padding:6px 12px;'//NL// &
      '  background:rgba(13,13,20,.88);color:#e5e7eb;font:13px/1.4 system-ui,sans-serif;">'//NL// &
      "  <strong>Forge3D Preview</strong>"//NL// &
      "  <span>__STEM__.f3d</span>"//NL// &
      '  <span id="f3d-pill" style="color:#4ade80">'// &
      achar(226)//achar(151)//achar(143)//" LIVE</span>"//NL// &
      '  <span id="f3d-fps" style="color:#9ca3af"></span>'//NL// &
      '  <span style="margin-left:auto;color:#9ca3af">edit &amp; save '// &
      achar(226)//achar(128)//achar(148)// &
      " the preview reloads itself "//achar(194)//achar(183)// &
      " drag to orbit "//achar(194)//achar(183)// &
      " scroll to zoom</span>"//NL// &
      "</div>"//NL// &
      '<div style="height:30px"></div>'//NL// &
      "<script>__CLIENT__</script>"//NL
  end function toolbar

  function make_bar() result(out)
    character(len=:), allocatable :: out
    character(len=:), allocatable :: client
    client = str_replace(client_js(), "__VERSION__", &
                         trim(fmt_int(int(p_version, int64))))
    out = str_replace(str_replace(toolbar(), "__STEM__", p_stem), &
                      "__CLIENT__", client)
  end function make_bar

  ! ------------------------------------------------------------------
  ! File helpers (mirrors of the CLI's private ones)
  ! ------------------------------------------------------------------
  logical function pv_exists(path)
    character(len=*), intent(in) :: path
    inquire (file=path, exist=pv_exists)
  end function pv_exists

  subroutine pv_read_file(path, text, ok)
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
  end subroutine pv_read_file

  ! driver_repo_root mirror: parent of the binary's directory.
  subroutine pv_repo_root(root)
    character(len=:), allocatable, intent(out) :: root
    character(kind=c_char) :: buf(4096)
    integer(c_int) :: n
    character(len=:), allocatable :: exe
    integer :: i, slash
    n = ph_self_exe(buf, 4096_c_int)
    if (n <= 0) then
       root = "."
       return
    end if
    allocate (character(len=int(n)) :: exe)
    do i = 1, int(n)
       exe(i:i) = buf(i)
    end do
    ! parent_dir twice
    do i = 1, 2
       slash = index(exe, "/", back=.true.)
       if (slash <= 1) then
          exe = "."
          exit
       end if
       exe = exe(1:slash - 1)
    end do
    root = exe
  end subroutine pv_repo_root

  ! ------------------------------------------------------------------
  ! The compile pipeline: statement-for-statement mirror of
  ! f3dc_cli.f90's compile_pipeline (cli.py compile_pipeline).
  ! ------------------------------------------------------------------
  subroutine pv_compile_pipeline(path, bag, ir, ok)
    character(len=*), intent(in) :: path
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: ir
    logical, intent(out) :: ok
    character(len=:), allocatable :: text, ext, stem
    type(dyn) :: prog, ir_opt
    logical :: rok, vok, j_ok
    ir = dyn_null()
    ok = .false.
    if (.not. pv_exists(path)) then
       stem = path_stem(path)
       call error_bag_add(bag, make_diagnostic_span( &
            "E501", "error", "file not found: "//path, &
            make_span(path, 1, 1), &
            why="f3dc can only compile a file that exists", &
            help="check the path, or create a scene with:  "// &
                 "f3dc new "//stem))
       return
    end if
    call pv_read_file(path, text, rok)
    if (.not. rok) then
       call error_bag_add(bag, make_diagnostic_span( &
            "E501", "error", "cannot read "//path//": i/o error", &
            make_span(path, 1, 1), &
            help="check the file permissions and try again"))
       return
    end if
    call error_bag_set_source(bag, text)
    ext = to_lower(path_extension(path))
    if (ext == ".obj") then
       call ast_from_obj(text, bag, prog)
    else if (ext == ".json") then
       if (.not. is_legacy_json(text)) then
          if (index(text, '"ir_version"') > 0) then
             call ir_from_json(text, ir, j_ok)
             if (j_ok) then
                if (error_bag_has_errors(bag)) return
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
    if (error_bag_has_errors(bag)) return
    call validate_program(prog, bag, path_dirname(path), ir, vok)
    if (.not. vok .or. error_bag_has_errors(bag)) return
    call optimize(ir, bag, 1, ir_opt)
    ir = dyn_copy(ir_opt)
    ok = .true.
  end subroutine pv_compile_pipeline

  ! ------------------------------------------------------------------
  ! v2.0 P5: dependency-set collection from a compiled scene dyn.
  !
  ! Fields collected (exactly these):
  !   - f3dc_validate_import_deps(): the "_import_deps" list of
  !     canonical resolved part-file paths recorded by desugar
  !     during the validate stage of this compile (side channel,
  !     not a scene-dyn key).  Already resolved; used verbatim.
  !   - scene "objects"[] "source_file": the load-ed OBJ/glTF path
  !     as written in the scene (dyn_str; null for plain objects).
  !   - scene "objects"[] "extensions" "material" "texture": the
  !     material extension's texture path (dyn_str).  This value is
  !     usually already base_dir-joined by validate (it rewrites
  !     the raw prop to the resolved path when the file exists);
  !     pv_resolve leaves an already-prefixed path alone.
  ! Relative asset paths are resolved against the scene's
  ! "base_dir" (also stamped by validate).
  ! ------------------------------------------------------------------
  function pv_resolve(base_dir, s) result(out)
    character(len=*), intent(in) :: base_dir, s
    character(len=:), allocatable :: out
    logical :: is_abs, already
    is_abs = .false.
    if (len(s) > 0) is_abs = s(1:1) == "/"
    already = .false.
    if (len(base_dir) > 0 .and. base_dir /= ".") then
       if (len(s) > len(base_dir) + 1) &
          already = s(1:len(base_dir) + 1) == base_dir//"/"
    end if
    if (is_abs) then
       out = s
    else if (already) then
       out = s  ! already resolved against base_dir by validate
    else if (len(base_dir) == 0) then
       out = s
    else if (base_dir(len(base_dir):len(base_dir)) == "/") then
       out = base_dir//s
    else
       out = base_dir//"/"//s
    end if
  end function pv_resolve

  subroutine pv_dep_push(arr, n, path)
    type(pv_dep_t), allocatable, intent(inout) :: arr(:)
    integer, intent(inout) :: n
    character(*), intent(in) :: path
    type(pv_dep_t), allocatable :: tmp(:)
    integer :: i
    if (n >= PV_MAX_DEPS) return
    do i = 1, n
       if (arr(i)%path == path) return  ! dedupe
    end do
    if (.not. allocated(arr)) allocate (arr(16))
    if (n == size(arr)) then
       allocate (tmp(2 * size(arr)))
       do i = 1, n
          tmp(i)%path = arr(i)%path
          tmp(i)%mtime_ns = arr(i)%mtime_ns
          tmp(i)%ok = arr(i)%ok
       end do
       call move_alloc(tmp, arr)
    end if
    n = n + 1
    arr(n)%path = path
    arr(n)%mtime_ns = 0
    arr(n)%ok = .false.
  end subroutine pv_dep_push

  subroutine pv_collect_deps(ir)
    type(dyn), intent(in) :: ir
    type(pv_dep_t), allocatable :: fresh(:)
    integer :: nfresh, i
    type(dyn) :: deps, objs, obj, exts, mat, v
    character(len=:), allocatable :: base_dir, s
    nfresh = 0
    if (ir%kind == DYN_K_DICT) then
       base_dir = "."
       v = dyn_dict_get(ir, "base_dir")
       if (v%kind == DYN_K_STR .and. allocated(v%s)) base_dir = v%s
       deps = f3dc_validate_import_deps()
       do i = 1, dyn_list_len(deps)
          v = dyn_list_at(deps, i)
          if (v%kind == DYN_K_STR .and. allocated(v%s)) then
             if (len(v%s) > 0) call pv_dep_push(fresh, nfresh, v%s)
          end if
       end do
       objs = dyn_dict_get(ir, "objects")
       do i = 1, dyn_list_len(objs)
          obj = dyn_list_at(objs, i)
          if (obj%kind /= DYN_K_DICT) cycle
          v = dyn_dict_get(obj, "source_file")
          if (v%kind == DYN_K_STR .and. allocated(v%s)) then
             if (len(v%s) > 0) &
                call pv_dep_push(fresh, nfresh, &
                                 pv_resolve(base_dir, v%s))
          end if
          exts = dyn_dict_get(obj, "extensions")
          if (exts%kind == DYN_K_DICT) then
             mat = dyn_dict_get(exts, "material")
             if (mat%kind == DYN_K_DICT) then
                v = dyn_dict_get(mat, "texture")
                if (v%kind == DYN_K_STR .and. allocated(v%s)) then
                   s = trim(v%s)
                   if (len(s) > 0) &
                      call pv_dep_push(fresh, nfresh, &
                                       pv_resolve(base_dir, s))
                end if
             end if
          end if
       end do
    end if
    ! Baseline-stat each fresh dep so the watcher only fires on
    ! changes from this moment on.
    do i = 1, nfresh
       call pv_stat_path(fresh(i)%path, fresh(i)%ok, &
                         fresh(i)%mtime_ns)
    end do
    if (allocated(p_deps)) deallocate (p_deps)
    if (nfresh > 0) then
       allocate (p_deps(nfresh))
       do i = 1, nfresh
          p_deps(i)%path = fresh(i)%path
          p_deps(i)%mtime_ns = fresh(i)%mtime_ns
          p_deps(i)%ok = fresh(i)%ok
       end do
    else
       allocate (p_deps(0))
    end if
    p_ndeps = nfresh
  end subroutine pv_collect_deps

  ! cli.py _html_text, mirrored like f3dc_cli.f90's html_text.
  subroutine pv_html_text(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    character(len=:), allocatable :: runtime, root, scene_js
    call pv_repo_root(root)
    call emit_html_runtime_js(root, runtime)
    call emit_js(ir, scene_js)
    call emit_html(ir, runtime, scene_js, "", root, text)
  end subroutine pv_html_text

  ! ------------------------------------------------------------------
  ! PreviewState.compile_now / snapshot / page (preview.py)
  ! ------------------------------------------------------------------
  subroutine pv_compile_now()
    type(error_bag_t) :: bag
    type(dyn) :: ir
    logical :: okc
    integer :: k
    call pv_compile_pipeline(p_path, bag, ir, okc)
    p_ndiag = error_bag_len(bag)
    if (allocated(p_diags)) deallocate (p_diags)
    allocate (p_diags(max(p_ndiag, 1)))
    do k = 1, p_ndiag
       p_diags(k) = error_bag_at(bag, k)
    end do
    p_ok = okc
    if (okc) then
       ! v2.0 P5: rebuild the dependency watch set from this fresh
       ! compile.  On failure the previous set is kept (see the
       ! module header note).
       call pv_collect_deps(ir)
       call pv_html_text(ir, p_html)
       p_has_html = .true.
    else
       p_has_html = .false.
       p_html = ""
    end if
    p_compile_count = p_compile_count + 1
    p_version = p_version + 1
  end subroutine pv_compile_now

  function diag_str(s) result(out)
    character(len=:), allocatable, intent(in) :: s
    character(len=:), allocatable :: out
    if (allocated(s)) then
       out = s
    else
       out = ""
    end if
  end function diag_str

  function json_bool(b) result(out)
    logical, intent(in) :: b
    character(len=:), allocatable :: out
    if (b) then
       out = "true"
    else
       out = "false"
    end if
  end function json_bool

  function json_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    out = '"'//json_escape(s)//'"'
  end function json_str

  ! _diag_dict + json.dumps for one diagnostic (key order as Python).
  function diag_json(d) result(out)
    type(diagnostic_t), intent(in) :: d
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    call sb_init(sb)
    call sb_add(sb, '{"code": ')
    call sb_add(sb, json_str(diag_str(d%code)))
    call sb_add(sb, ', "severity": ')
    call sb_add(sb, json_str(diag_str(d%severity)))
    call sb_add(sb, ', "message": ')
    call sb_add(sb, json_str(diag_str(d%message)))
    call sb_add(sb, ', "why": ')
    call sb_add(sb, json_str(diag_str(d%why)))
    call sb_add(sb, ', "help": ')
    call sb_add(sb, json_str(diag_str(d%help)))
    call sb_add(sb, ', "line": ')
    if (d%has_span) then
       call sb_add(sb, trim(fmt_int(int(d%span%line, int64))))
       call sb_add(sb, ', "col": ')
       call sb_add(sb, trim(fmt_int(int(d%span%col, int64))))
    else
       call sb_add(sb, "null")
       call sb_add(sb, ', "col": null')
    end if
    call sb_add(sb, "}")
    out = sb_text(sb)
  end function diag_json

  function version_json() result(out)
    character(len=:), allocatable :: out
    integer :: k, nerr
    nerr = 0
    do k = 1, p_ndiag
       if (diag_str(p_diags(k)%severity) == "error") nerr = nerr + 1
    end do
    out = '{"version": '//trim(fmt_int(int(p_version, int64)))// &
          ', "ok": '//json_bool(p_ok)// &
          ', "errors": '//trim(fmt_int(int(nerr, int64)))//"}"
  end function version_json

  function status_json() result(out)
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: k
    call sb_init(sb)
    call sb_add(sb, '{"version": ')
    call sb_add(sb, trim(fmt_int(int(p_version, int64))))
    call sb_add(sb, ', "ok": ')
    call sb_add(sb, json_bool(p_ok))
    call sb_add(sb, ', "compile_count": ')
    call sb_add(sb, trim(fmt_int(int(p_compile_count, int64))))
    call sb_add(sb, ', "diagnostics": [')
    do k = 1, p_ndiag
       if (k > 1) call sb_add(sb, ", ")
       call sb_add(sb, diag_json(p_diags(k)))
    end do
    call sb_add(sb, "]}")
    out = sb_text(sb)
  end function status_json

  ! PreviewState.page()
  function pv_page() result(out)
    character(len=:), allocatable :: out
    character(len=:), allocatable :: bar, body, line
    type(str_builder) :: sb_line, sb_body
    integer :: k, idx
    type(diagnostic_t) :: d
    bar = make_bar()
    if (p_ok .and. p_has_html) then
       idx = index(p_html, "</body>")
       if (idx > 0) then
          out = p_html(1:idx - 1)//bar//p_html(idx:)
       else
          out = p_html//bar
       end if
       return
    end if
    ! v3.0 Phase 6 (C4): body accumulates in sb_body; the
    ! separator guard reads sb_len (== len(body)) instead of the
    ! string itself, so semantics are unchanged.
    call sb_init(sb_body)
    do k = 1, p_ndiag
       d = p_diags(k)
       call sb_init(sb_line)
       call sb_add(sb_line, diag_str(d%code))
       call sb_add(sb_line, " ")
       call sb_add(sb_line, diag_str(d%severity))
       if (d%has_span) then
          call sb_add(sb_line, ":")
          call sb_add(sb_line, trim(fmt_int(int(d%span%line, int64))))
          call sb_add(sb_line, ":")
          call sb_add(sb_line, trim(fmt_int(int(d%span%col, int64))))
       end if
       call sb_add(sb_line, ": ")
       call sb_add(sb_line, diag_str(d%message))
       line = sb_text(sb_line)
       if (sb_len(sb_body) > 0) call sb_add(sb_body, NL)
       call sb_add(sb_body, line)
       if (len(diag_str(d%why)) > 0) then
          call sb_add(sb_body, NL)
          call sb_add(sb_body, "  why: "//diag_str(d%why))
       end if
       if (len(diag_str(d%help)) > 0) then
          call sb_add(sb_body, NL)
          call sb_add(sb_body, "  help: "//diag_str(d%help))
       end if
    end do
    body = sb_text(sb_body)
    if (p_ndiag == 0) body = "scene failed to compile (no diagnostics)"
    out = "<!DOCTYPE html>"//NL// &
          '<html><head><meta charset="utf-8">'// &
          "<title>Forge3D Preview "//achar(226)//achar(128)// &
          achar(148)//" "//p_stem//" (error)</title>"// &
          '</head><body style="background:#0d0d14;color:#e5e7eb;'// &
          'font:14px/1.5 ui-monospace,monospace;padding:16px">'// &
          bar// &
          '<h2 style="color:#f87171">Scene error '// &
          achar(226)//achar(128)//achar(148)// &
          " fix the file and save; this page recovers by itself.</h2>"// &
          "<pre>"//body//"</pre>"// &
          "</body></html>"//NL
  end function pv_page

  ! ------------------------------------------------------------------
  ! Routing (preview.py Handler.do_GET) + the bind(C) handler the
  ! C serve loop calls.
  ! ------------------------------------------------------------------
  subroutine pv_route(method, path, body, ctype, status)
    character(len=*), intent(in) :: method, path
    character(len=:), allocatable, intent(out) :: body, ctype
    integer, intent(out) :: status
    if (method /= "GET") then
       status = 501
       ctype = "text/plain"
       body = "Unsupported method ('"//method//"')"//NL
       return
    end if
    select case (path)
    case ("/", "/index.html")
       status = 200
       ctype = "text/html; charset=utf-8"
       body = pv_page()
    case ("/__version")
       status = 200
       ctype = "application/json"
       body = version_json()
    case ("/__status")
       status = 200
       ctype = "application/json"
       body = status_json()
    case default
       status = 404
       ctype = "text/plain"
       body = "not found"//NL
    end select
  end subroutine pv_route

  subroutine cstr_to_f(ptr, n, out)
    type(c_ptr), intent(in) :: ptr
    integer(c_int), intent(in) :: n
    character(len=:), allocatable, intent(out) :: out
    character(kind=c_char), pointer :: arr(:)
    integer :: i
    allocate (character(len=max(int(n), 0)) :: out)
    if (n <= 0) return
    if (.not. c_associated(ptr)) return
    call c_f_pointer(ptr, arr, [int(n)])
    do i = 1, int(n)
       out(i:i) = arr(i)
    end do
  end subroutine cstr_to_f

  subroutine f_to_cstr(s, ptr, cap)
    character(len=*), intent(in) :: s
    type(c_ptr), intent(in) :: ptr
    integer(c_int), intent(in) :: cap
    character(kind=c_char), pointer :: arr(:)
    integer :: i, n
    if (cap <= 0 .or. .not. c_associated(ptr)) return
    call c_f_pointer(ptr, arr, [int(cap)])
    n = min(len(s), int(cap))
    do i = 1, n
       arr(i) = s(i:i)
    end do
  end subroutine f_to_cstr

  subroutine pv_handler(method_ptr, method_len, path_ptr, path_len, &
                        body_ptr, body_cap, body_len, status, &
                        ctype_ptr, ctype_cap, ctype_len) &
       bind(C, name="f3d_preview_handler")
    type(c_ptr), value :: method_ptr, path_ptr, body_ptr, ctype_ptr
    integer(c_int), value :: method_len, path_len, body_cap, ctype_cap
    integer(c_int), intent(out) :: body_len, status, ctype_len
    character(len=:), allocatable :: method, path, body, ctype
    integer :: st
    call cstr_to_f(method_ptr, method_len, method)
    call cstr_to_f(path_ptr, path_len, path)
    call pv_route(method, path, body, ctype, st)
    body_len = int(len(body), c_int)
    status = int(st, c_int)
    ctype_len = int(len(ctype), c_int)
    if (body_cap > 0) call f_to_cstr(body, body_ptr, body_cap)
    if (ctype_cap > 0) call f_to_cstr(ctype, ctype_ptr, ctype_cap)
  end subroutine pv_handler

  ! ------------------------------------------------------------------
  ! Watcher tick (preview.py _watch): mtime poll + debounce.
  ! ------------------------------------------------------------------
  subroutine pv_stat_path(path, ok, ns)
    character(len=*), intent(in) :: path
    logical, intent(out) :: ok
    integer(c_int64_t), intent(out) :: ns
    character(kind=c_char) :: cpath(4097)
    integer :: i
    integer(c_int) :: rc
    ok = .false.
    ns = 0
    if (len(path) >= size(cpath)) return
    do i = 1, len(path)
       cpath(i) = path(i:i)
    end do
    cpath(len(path) + 1) = c_null_char
    rc = ph_mtime(cpath, ns)
    ok = (rc == 0)
    if (.not. ok) ns = 0
  end subroutine pv_stat_path

  subroutine pv_stat_now(ok, ns)
    logical, intent(out) :: ok
    integer(c_int64_t), intent(out) :: ns
    call pv_stat_path(p_path, ok, ns)
  end subroutine pv_stat_now

  subroutine pv_watch_tick()
    logical :: ok, changed
    integer(c_int64_t) :: ns
    integer :: i
    call pv_stat_now(ok, ns)
    ! NB: parentheses are load-bearing -- in Fortran .neqv. binds
    ! looser than .or., unlike the Python `!=`/`or` reading.
    changed = (ok .neqv. p_mtime_ok) .or. &
              (ok .and. ns /= p_mtime_ns)
    ! v2.0 P5: poll every watched dependency the same way.  A dep
    ! whose stored stat is refreshed here keeps its (possibly
    ! stale-path) entry when the recompile below fails: the set is
    ! only rebuilt on success (pv_collect_deps), but the refreshed
    ! mtimes stop a broken dep from retriggering every tick.
    if (allocated(p_deps)) then
       do i = 1, p_ndeps
          call pv_stat_path(p_deps(i)%path, ok, ns)
          if ((ok .neqv. p_deps(i)%ok) .or. &
              (ok .and. ns /= p_deps(i)%mtime_ns)) then
             changed = .true.
             p_deps(i)%ok = ok
             p_deps(i)%mtime_ns = ns
          end if
       end do
    end if
    if (changed) then
       call ph_sleep_ms(150_c_int)
       call pv_stat_now(ok, ns)
       p_mtime_ok = ok
       p_mtime_ns = ns
       call pv_compile_now()
    end if
  end subroutine pv_watch_tick

  ! ------------------------------------------------------------------
  ! serve() (preview.py serve): returns a process exit code.
  ! ------------------------------------------------------------------
  subroutine preview_serve(scene_path, port, open_browser, code)
    character(len=*), intent(in) :: scene_path
    integer, intent(in) :: port
    logical, intent(in) :: open_browser
    integer, intent(out) :: code
    character(kind=c_char) :: chost(10)
    character(kind=c_char) :: errbuf(256)
    integer(c_int) :: fd, actual, errlen
    integer :: i
    character(len=:), allocatable :: url, errtext
    logical :: ok0
    integer(c_int) :: rc

    p_path = scene_path
    p_stem = path_stem(scene_path)
    p_version = 0
    p_compile_count = 0
    p_ndiag = 0
    p_ndeps = 0
    if (allocated(p_deps)) deallocate (p_deps)
    call pv_compile_now()
    ok0 = p_ok

    chost = [character(kind=c_char) :: &
         "1", "2", "7", ".", "0", ".", "0", ".", "1", c_null_char]
    fd = ph_open(chost, int(port, c_int), actual, errbuf, &
                 256_c_int, errlen)
    if (fd < 0) then
       allocate (character(len=max(int(errlen), 0)) :: errtext)
       do i = 1, int(errlen)
          errtext(i:i) = errbuf(i)
       end do
       write (output_unit, '(A)') "error E502: cannot start preview "// &
            "server on "//HOST//":"//trim(fmt_int(int(port, int64)))// &
            ": "//errtext
       flush (output_unit)
       code = 3
       return
    end if
    url = "http://"//HOST//":"//trim(fmt_int(int(actual, int64)))//"/"

    call pv_stat_now(p_mtime_ok, p_mtime_ns)

    if (ok0) then
       write (output_unit, '(A)') "Forge3D preview: "//p_path//" (ok)"
    else
       write (output_unit, '(A)') "Forge3D preview: "//p_path// &
            " (COMPILE ERROR "//achar(226)//achar(128)//achar(148)// &
            " see browser)"
    end if
    write (output_unit, '(A)') "  open  "//url
    write (output_unit, '(A)') "  watching for saves "// &
         achar(226)//achar(128)//achar(148)// &
         " the browser reloads itself. Ctrl+C to stop."
    flush (output_unit)

    if (open_browser) then
       call execute_command_line("xdg-open "//url// &
            " >/dev/null 2>&1", wait=.false.)
    end if

    do
       rc = ph_serve_once(fd, c_funloc(pv_handler), 100_c_int)
       if (rc == -2_c_int) exit
       call pv_watch_tick()
    end do
    write (output_unit, '(A)') NL//"preview stopped"
    flush (output_unit)
    call ph_close(fd)
    code = 0
  end subroutine preview_serve

end module f3dc_preview
