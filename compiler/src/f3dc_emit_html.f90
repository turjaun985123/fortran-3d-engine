! f3dc_emit_html.f90 -- Forge3D standalone HTML emitter.
!
! Port of tools/f3dc/emit_html.py (read in full; 260 lines) plus the
! runtime-loading half of tools/f3dc/cli.py::_html_text.
!
!   subroutine emit_html(ir, runtime_js, scene_js, template_arg, &
!                        repo_root, text)
!     ir           : IR scene (dyn dict)
!     runtime_js   : runtime/f3d.js source to inline; "" mirrors
!                    Python's None (cli.py passes `runtime or None`)
!                    and selects the missing-runtime fallback.
!     scene_js     : the emit_js(ir) payload, precomputed by the
!                    caller; pass "" to have this module call the
!                    sibling f3dc_emit_js seat itself, exactly like
!                    emit_html.py's _scene_js calling emit_js.
!                    (emit_html.py's deeper fallback --
!                    _fallback_scene_js via ir_nodes.to_json -- only
!                    fires in Python when emit_js has not landed;
!                    f3dc_emit_js HAS landed, so that path is not
!                    reproduced here.)
!     template_arg : "" mirrors Python template=None (load the B18
!                    viewer_template.html from disk, else the
!                    built-in template).  A non-empty argument follows
!                    _load_template exactly: text naming an existing
!                    file (and containing neither "<" nor "{{") is
!                    read from disk; anything else is template text.
!     repo_root    : repository root (parent of compiler/ -- see
!                    emit_html_repo_root).  The on-disk template
!                    search mirrors Python's module-relative lookup:
!                    Python finds viewer_template.html next to
!                    emit_html.py, i.e. <root>/tools/f3dc/, so the
!                    candidates are <root>/tools/f3dc/... first and
!                    <root>/compiler/... (the native module's home)
!                    second.  "" skips the disk search.
!
! EXT SIDECAR NOTE: emit_html.py inlines ONLY the single runtime_js
! text it is given (cli.py reads runtime/f3d.js).  The extension
! runtimes runtime/f3d-*.js (f3d-pbr.js, f3d-post.js, ...) are NOT
! pulled in by emit_html.py -- they are separate <script> loads a
! page performs itself.  P5-B adds ONE deliberate exception: the
! WebGL2 sidecar runtime/f3d-webgl2.js is loaded from repo_root
! by emit_html itself (emit_html_webgl2_js) and substituted into
! the {{WEBGL2_JS}} slot, so the viewer boot can default to
! WebGL2 with the core Canvas2D player as fallback.
module f3dc_emit_html
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_dict_get, dyn_kind, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real, to_lower, str_replace
  use f3dc_emit_js, only: emit_js
  implicit none
  private

  public :: emit_html, emit_html_repo_root, emit_html_runtime_js
  public :: emit_html_webgl2_js
  public :: FALLBACK_COMMENT

  !> Exact marker required when no runtime is supplied.
  character(len=*), parameter :: FALLBACK_COMMENT = &
    "<!-- f3d.js runtime not supplied: link runtime/f3d.js -->"

  character(len=*), parameter :: FALLBACK_MESSAGE = &
    "F3D runtime not supplied: this file was built without the " // &
    "f3d.js runtime, so the scene cannot be rendered. Rebuild with " // &
    "the runtime (runtime/f3d.js) inlined."

  character(len=*), parameter :: NL = achar(10)

contains

  ! ==================================================================
  ! Small local helpers
  ! ==================================================================

  !> Python str(value) for scalar dyn kinds (as in emit_fortran).
  function py_str(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    select case (v%kind)
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = v%s
      else
        out = ""
      end if
    case (DYN_K_INT)
      out = fmt_int(v%i)
    case (DYN_K_REAL)
      out = fmt_real(v%r)
    case (DYN_K_BOOL)
      if (v%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_NULL)
      out = "None"
    case default
      out = ""
    end select
  end function py_str

  pure logical function py_truthy(v)
    type(dyn), intent(in) :: v
    select case (v%kind)
    case (DYN_K_NULL)
      py_truthy = .false.
    case (DYN_K_BOOL)
      py_truthy = v%b
    case (DYN_K_INT)
      py_truthy = v%i /= 0_int64
    case (DYN_K_REAL)
      py_truthy = v%r /= 0.0_real64
    case (DYN_K_STR)
      py_truthy = allocated(v%s)
      if (py_truthy) py_truthy = len(v%s) > 0
    case (DYN_K_LIST)
      py_truthy = v%n_items > 0
    case (DYN_K_DICT)
      py_truthy = v%n_entries > 0
    case default
      py_truthy = .false.
    end select
  end function py_truthy

  !> html.escape(s, quote=True): & < > " ' in that precedence
  !! (char-by-char here, which is equivalent).
  function html_escape(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i
    out = ""
    do i = 1, len(s)
      select case (s(i:i))
      case ("&")
        out = out // "&amp;"
      case ("<")
        out = out // "&lt;"
      case (">")
        out = out // "&gt;"
      case ('"')
        out = out // "&quot;"
      case ("'")
        out = out // "&#x27;"
      case default
        out = out // s(i:i)
      end select
    end do
  end function html_escape

  !> Read a whole file as bytes; ok=.false. on any failure
  !! (Python's OSError paths).
  subroutine read_file(path, text, ok)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: text
    logical, intent(out) :: ok
    integer :: unit, ios
    integer(int64) :: sz
    ok = .false.
    inquire (file=path, exist=ok)
    if (.not. ok) then
      text = ""
      return
    end if
    ok = .false.
    open (newunit=unit, file=path, status="old", access="stream", &
          form="unformatted", iostat=ios)
    if (ios /= 0) return
    inquire (unit=unit, size=sz)
    if (sz < 0) then
      close (unit)
      return
    end if
    if (sz == 0) then
      close (unit)
      ok = .true.
      text = ""
      return
    end if
    allocate (character(len=int(sz)) :: text)
    read (unit, iostat=ios) text
    close (unit)
    if (ios /= 0) then
      text = ""
      return
    end if
    ok = .true.
  end subroutine read_file

  ! ==================================================================
  ! Repo root + runtime loading (cli.py::_repo_root / _html_text)
  ! ==================================================================

  !> Directory part of a path (pathlib .parent, POSIX): "." when
  !! there is no slash, "/" for a root-level name.
  function path_dirname(p) result(out)
    character(len=*), intent(in) :: p
    character(len=:), allocatable :: out
    integer :: slash
    slash = index(p, "/", back=.true.)
    if (slash == 0) then
      out = "."
    else if (slash == 1) then
      out = "/"
    else
      out = p(1:slash - 1)
    end if
  end function path_dirname

  !> Repo root for the native binary.  Python cli.py: parents[2] of
  !! tools/f3dc/cli.py.  The native f3dc binary lives in compiler/
  !! (Makefile target ./f3dc), so the mirror is: directory of the
  !! executable, then its parent.  When argv[0] carries no directory
  !! (bare "f3dc" via PATH), the current directory is treated as
  !! compiler/ -- the driver seat may refine this; documented in
  !! the port report.
  function emit_html_repo_root() result(root)
    character(len=:), allocatable :: root
    character(len=4096) :: arg0
    character(len=:), allocatable :: cwd
    integer :: l, stat, slash
    call get_command_argument(0, arg0, l, stat)
    if (stat /= 0 .or. l == 0) then
      root = "."
      return
    end if
    slash = index(arg0(1:l), "/", back=.true.)
    if (slash == 0) then
      cwd = get_cwd()
      if (len(cwd) == 0) then
        root = "."
        return
      end if
      root = path_dirname(cwd)
    else
      root = path_dirname(path_dirname(arg0(1:l)))
    end if
  end function emit_html_repo_root

  !> Current working directory via libc getcwd (flang-new-18 has
  !! no GETCWD intrinsic); "" on failure.
  function get_cwd() result(out)
    use, intrinsic :: iso_c_binding, only: c_char, c_size_t, c_ptr, &
                                           c_associated, c_null_char
    character(len=:), allocatable :: out
    interface
      function c_getcwd(buf, size) bind(C, name="getcwd") result(res)
        import :: c_char, c_size_t, c_ptr
        type(c_ptr) :: res
        character(kind=c_char) :: buf(*)
        integer(c_size_t), value :: size
      end function c_getcwd
    end interface
    character(kind=c_char) :: buf(4096)
    type(c_ptr) :: res
    integer :: i, n
    res = c_getcwd(buf, 4096_c_size_t)
    if (.not. c_associated(res)) then
      out = ""
      return
    end if
    n = 0
    do i = 1, 4096
      if (buf(i) == c_null_char) exit
      n = i
    end do
    allocate (character(len=n) :: out)
    do i = 1, n
      out(i:i) = achar(iachar(buf(i)))
    end do
  end function get_cwd

  !> cli.py::_html_text runtime loading: the text of
  !! <repo_root>/runtime/f3d.js, or "" when missing/unreadable.
  subroutine emit_html_runtime_js(repo_root, runtime_js)
    character(len=*), intent(in) :: repo_root
    character(len=:), allocatable, intent(out) :: runtime_js
    logical :: ok
    call read_file(repo_root // "/runtime/f3d.js", runtime_js, ok)
    if (.not. ok) runtime_js = ""
  end subroutine emit_html_runtime_js

  !> P5-B: the text of <repo_root>/runtime/f3d-webgl2.js (the
  !! WebGL2 sidecar inlined into the {{WEBGL2_JS}} slot), or ""
  !! when missing/unreadable -- the viewer boot then degrades
  !! to the core Canvas2D player only.
  subroutine emit_html_webgl2_js(repo_root, webgl2_js)
    character(len=*), intent(in) :: repo_root
    character(len=:), allocatable, intent(out) :: webgl2_js
    logical :: ok
    call read_file(repo_root // "/runtime/f3d-webgl2.js", &
                   webgl2_js, ok)
    if (.not. ok) webgl2_js = ""
  end subroutine emit_html_webgl2_js

  ! ==================================================================
  ! Fallback JS + built-in template (emit_html.py constants)
  ! ==================================================================

  !> emit_html._FALLBACK_JS (json.dumps of the message is a plain
  !! double-quoted ASCII string here -- the message has no character
  !! json.dumps would escape).
  function fallback_js() result(out)
    character(len=:), allocatable :: out
    out = "console.error('F3D: runtime not supplied - " // &
          "link runtime/f3d.js');" // NL // &
          "(function () {" // NL // &
          "  var el = document.getElementById('f3d-fallback');" // &
          NL // &
          "  if (el) { el.textContent = """ // FALLBACK_MESSAGE // &
          """; }" // NL // &
          "})();"
  end function fallback_js

  !> emit_html.BUILTIN_TEMPLATE, byte for byte.
  function builtin_template() result(t)
    character(len=:), allocatable :: t
    t = "<!DOCTYPE html>" // NL // &
      "<html lang=""en"">" // NL // &
      "<head>" // NL // &
      "<meta charset=""utf-8"">" // NL // &
      "<meta name=""viewport"" content=""width=device-width, " // &
      "initial-scale=1"">" // NL // &
      "<title>{{TITLE}}</title>" // NL // &
      "<style>" // NL // &
      "  body { margin: 0; background: #191923; color: #f0f0f0;" // &
      NL // &
      "         font-family: system-ui, sans-serif; }" // NL // &
      "  main { max-width: 960px; margin: 0 auto; padding: 1rem; }" // &
      NL // &
      "  canvas { display: block; background: #000; " // &
      "max-width: 100%; }" // NL // &
      "  #f3d-fallback:empty { display: none; }" // NL // &
      "</style>" // NL // &
      "</head>" // NL // &
      "<body>" // NL // &
      "<main>" // NL // &
      "<h1>{{TITLE}}</h1>" // NL // &
      "<canvas id=""f3d-canvas"" width=""640"" height=""480"">" // &
      "</canvas>" // NL // &
      "<div id=""f3d-fallback"" role=""alert"">{{FALLBACK}}</div>" // &
      NL // &
      "</main>" // NL // &
      "{{F3D_JS}}" // NL // &
      "{{WEBGL2_JS}}" // NL // &
      "{{SCENE_JS}}" // NL // &
      "<script>" // NL // &
      "(function () {" // NL // &
      "  // Forge3D viewer boot v2: WebGL2 first (via the inlined" // NL // &
      "  // f3d-webgl2.js sidecar + F3D.worldTris), Canvas2D core" // NL // &
      "  // player as automatic fallback. F3DBoot exposes the pure" // NL // &
      "  // decision / MVP helpers for headless tests." // NL // &
      "  function v3(v, d) {" // NL // &
      "    if (v == null) return d.slice();" // NL // &
      "    if (typeof v === ""number"") return [v, v, v];" // NL // &
      "    return [+v[0] || 0, +v[1] || 0, +v[2] || 0];" // NL // &
      "  }" // NL // &
      "  function sub(a, b) {" // NL // &
      "    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];" // NL // &
      "  }" // NL // &
      "  function cross(a, b) {" // NL // &
      "    return [a[1] * b[2] - a[2] * b[1]," // NL // &
      "      a[2] * b[0] - a[0] * b[2]," // NL // &
      "      a[0] * b[1] - a[1] * b[0]];" // NL // &
      "  }" // NL // &
      "  function dot(a, b) {" // NL // &
      "    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];" // NL // &
      "  }" // NL // &
      "  function norm(a) {" // NL // &
      "    var l = Math.hypot(a[0], a[1], a[2]);" // NL // &
      "    return l > 1e-12 ? [a[0] / l, a[1] / l, a[2] / l]" // NL // &
      "      : [0, 0, 0];" // NL // &
      "  }" // NL // &
      "  function mul(a, b) { // column-major a * b" // NL // &
      "    var o = new Array(16), c, r, k, s;" // NL // &
      "    for (c = 0; c < 4; c++) for (r = 0; r < 4; r++) {" // NL // &
      "      s = 0;" // NL // &
      "      for (k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];" // NL // &
      "      o[c * 4 + r] = s;" // NL // &
      "    }" // NL // &
      "    return o;" // NL // &
      "  }" // NL // &
      "  function mvpForCamera(cam, aspect) {" // NL // &
      "    cam = cam || {};" // NL // &
      "    var eye = v3(cam.pos || cam.position, [3, 2.5, 4]);" // NL // &
      "    var tgt = v3(cam.target, [0, 0, 0]);" // NL // &
      "    var up = v3(cam.up, [0, 1, 0]);" // NL // &
      "    var fov = cam.fov || 60;" // NL // &
      "    var near = cam.near != null ? +cam.near : 0.1;" // NL // &
      "    var far = cam.far != null ? +cam.far : 100;" // NL // &
      "    var f = norm(sub(tgt, eye)), r = norm(cross(f, up));" // NL // &
      "    var u = cross(r, f);" // NL // &
      "    var view = [r[0], u[0], -f[0], 0," // NL // &
      "      r[1], u[1], -f[1], 0," // NL // &
      "      r[2], u[2], -f[2], 0," // NL // &
      "      -dot(r, eye), -dot(u, eye), dot(f, eye), 1];" // NL // &
      "    var t = 1 / Math.tan(fov * Math.PI / 360);" // NL // &
      "    var a = aspect || 1;" // NL // &
      "    var persp = [t / a, 0, 0, 0," // NL // &
      "      0, t, 0, 0," // NL // &
      "      0, 0, (far + near) / (near - far), -1," // NL // &
      "      0, 0, 2 * far * near / (near - far), 0];" // NL // &
      "    return mul(persp, view);" // NL // &
      "  }" // NL // &
      "  function canUseWebGL2(scene, gl, f3d) {" // NL // &
      "    return !!(gl && f3d &&" // NL // &
      "      typeof f3d.worldTris === ""function"" &&" // NL // &
      "      scene && scene.camera && !scene.controls);" // NL // &
      "  }" // NL // &
      "  window.F3DBoot = { mvpForCamera: mvpForCamera," // NL // &
      "    canUseWebGL2: canUseWebGL2 };" // NL // &
      "  var scene = window.F3D_SCENE ||" // NL // &
      "    (typeof SCENE !== ""undefined"" ? SCENE : window.SCENE);" // NL // &
      "  var canvas = document.getElementById(""f3d-canvas"");" // NL // &
      "  if (!canvas || !scene) { return; }" // NL // &
      "  var fb = document.getElementById(""f3d-fallback"");" // NL // &
      "  function done() {" // NL // &
      "    // The scene JS bootstrap would otherwise auto-start the" // NL // &
      "    // Canvas2D player on DOMContentLoaded; the boot owns the" // NL // &
      "    // canvas now, so neutralise that second start." // NL // &
      "    if (window.F3D) window.F3D.auto = function () {" // NL // &
      "      return null;" // NL // &
      "    };" // NL // &
      "    if (fb) fb.style.display = ""none"";" // NL // &
      "  }" // NL // &
      "  var used = false, glTried = false;" // NL // &
      "  if (canUseWebGL2(scene, window.Forge3DWebGL2, window.F3D)) {" // NL // &
      "    try {" // NL // &
      "      var tris = window.F3D.worldTris(scene, 0);" // NL // &
      "      if (tris.length &&" // NL // &
      "          window.Forge3DWebGL2.isAvailable()) {" // NL // &
      "        if (canvas.clientWidth) {" // NL // &
      "          canvas.width = canvas.clientWidth;" // NL // &
      "        }" // NL // &
      "        if (canvas.clientHeight) {" // NL // &
      "          canvas.height = canvas.clientHeight;" // NL // &
      "        }" // NL // &
      "        glTried = true;" // NL // &
      "        var renderer = window.Forge3DWebGL2.create(canvas);" // NL // &
      "        if (renderer) {" // NL // &
      "          if (scene.bg && scene.bg.length) {" // NL // &
      "            renderer.clearColor = scene.bg;" // NL // &
      "          }" // NL // &
      "          var opts = {};" // NL // &
      "          var L = (scene.lights && scene.lights[0]) || {};" // NL // &
      "          if (L.direction || L.dir) {" // NL // &
      "            opts.lightDir = L.direction || L.dir;" // NL // &
      "          }" // NL // &
      "          var aspect = function () {" // NL // &
      "            return canvas.width /" // NL // &
      "              Math.max(1, canvas.height);" // NL // &
      "          };" // NL // &
      "          var drawn = window.Forge3DWebGL2.renderScene(" // NL // &
      "            renderer, tris," // NL // &
      "            mvpForCamera(scene.camera, aspect()), opts);" // NL // &
      "          if (drawn > 0) {" // NL // &
      "            used = true;" // NL // &
      "            done();" // NL // &
      "            var anims = scene.animations || scene.anims" // NL // &
      "              || [];" // NL // &
      "            if (anims.length &&" // NL // &
      "                window.requestAnimationFrame) {" // NL // &
      "              var start = Date.now();" // NL // &
      "              var frame = function () {" // NL // &
      "                var t = (Date.now() - start) / 1000;" // NL // &
      "                window.Forge3DWebGL2.renderScene(renderer," // NL // &
      "                  window.F3D.worldTris(scene, t)," // NL // &
      "                  mvpForCamera(scene.camera, aspect())," // NL // &
      "                  opts);" // NL // &
      "                window.requestAnimationFrame(frame);" // NL // &
      "              };" // NL // &
      "              window.requestAnimationFrame(frame);" // NL // &
      "            }" // NL // &
      "          }" // NL // &
      "        }" // NL // &
      "      }" // NL // &
      "    } catch (e) { used = false; }" // NL // &
      "  }" // NL // &
      "  if (!used) {" // NL // &
      "    var target = canvas;" // NL // &
      "    if (glTried && canvas.parentNode) {" // NL // &
      "      // The failed WebGL2 attempt claimed this canvas's" // NL // &
      "      // context mode; a fresh element is needed for 2D." // NL // &
      "      target = document.createElement(""canvas"");" // NL // &
      "      target.id = canvas.id;" // NL // &
      "      target.className = canvas.className;" // NL // &
      "      target.width = canvas.width;" // NL // &
      "      target.height = canvas.height;" // NL // &
      "      canvas.parentNode.replaceChild(target, canvas);" // NL // &
      "    }" // NL // &
      "    try {" // NL // &
      "      if (window.F3D &&" // NL // &
      "          typeof window.F3D.create === ""function"") {" // NL // &
      "        window.F3D.create(target, scene);" // NL // &
      "        done();" // NL // &
      "      } else if (window.F3D &&" // NL // &
      "          typeof window.F3D.mount === ""function"") {" // NL // &
      "        window.F3D.mount(target, scene);" // NL // &
      "        done();" // NL // &
      "      }" // NL // &
      "    } catch (e) { /* both paths failed: fallback stays */ }" // NL // &
      "  }" // NL // &
      "})();" // NL // &
      "</script>" // NL // &
      "</body>" // NL // &
      "</html>" // NL
  end function builtin_template

  ! ==================================================================
  ! Template loading (emit_html._load_template)
  ! ==================================================================

  function load_template(template_arg, repo_root) result(t)
    character(len=*), intent(in) :: template_arg, repo_root
    character(len=:), allocatable :: t
    logical :: ok, exists
    integer :: c
    character(len=:), allocatable :: cand
    if (len(template_arg) > 0) then
      if (index(template_arg, "<") == 0 .and. &
          index(template_arg, "{{") == 0) then
        inquire (file=template_arg, exist=exists)
        if (exists) then
          call read_file(template_arg, t, ok)
          if (ok) return
        end if
      end if
      t = template_arg
      return
    end if
    if (len(repo_root) > 0) then
      do c = 1, 4
        select case (c)
        case (1)
          cand = repo_root // "/tools/f3dc/viewer_template.html"
        case (2)
          cand = repo_root // &
                 "/tools/f3dc/templates/viewer_template.html"
        case (3)
          cand = repo_root // "/tools/f3dc/templates/viewer.html.tmpl"
        case (4)
          cand = repo_root // "/compiler/viewer_template.html"
        end select
        call read_file(cand, t, ok)
        if (ok) return
      end do
    end if
    t = builtin_template()
  end function load_template

  ! ==================================================================
  ! Placeholder substitution (emit_html._substitute_js & friends)
  ! ==================================================================

  !> emit_html._inside_script: offset pos (1-based) lies inside a
  !! <script>...</script> element (case-insensitive, like Python's
  !! lower()ed scan; rfind comparisons carry over to 1-based index).
  logical function inside_script(text, pos)
    character(len=*), intent(in) :: text
    integer, intent(in) :: pos
    character(len=:), allocatable :: before
    if (pos <= 1) then
      before = ""
    else
      before = to_lower(text(1:pos - 1))
    end if
    inside_script = index(before, "<script", back=.true.) > &
                    index(before, "</script", back=.true.)
  end function inside_script

  !> emit_html._substitute_js.
  function substitute_js(text, placeholder, js_code, missing) &
      result(out)
    character(len=*), intent(in) :: text, placeholder, js_code
    logical, intent(in) :: missing
    character(len=:), allocatable :: out, repl
    integer :: pos
    out = text
    do while (index(out, placeholder) > 0)
      pos = index(out, placeholder)
      if (inside_script(out, pos)) then
        if (missing) then
          repl = FALLBACK_COMMENT // NL // fallback_js()
        else
          repl = js_code
        end if
      else
        if (missing) then
          repl = FALLBACK_COMMENT // NL // "<script>" // NL // &
                 fallback_js() // NL // "</script>"
        else
          repl = "<script>" // NL // js_code // NL // "</script>"
        end if
      end if
      out = out(1:pos - 1) // repl // out(pos + len(placeholder):)
    end do
  end function substitute_js

  !> emit_html._scene_name.
  function scene_name(ir) result(out)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable :: out
    type(dyn) :: nv
    nv = dyn_dict_get(ir, "name")
    if (.not. py_truthy(nv)) then
      out = "untitled"
    else
      out = py_str(nv)
    end if
  end function scene_name

  ! ==================================================================
  ! Public API (emit_html.emit_html)
  ! ==================================================================

  subroutine emit_html(ir, runtime_js, scene_js, template_arg, &
                       repo_root, text)
    type(dyn), intent(in) :: ir
    character(len=*), intent(in) :: runtime_js, scene_js
    character(len=*), intent(in) :: template_arg, repo_root
    character(len=:), allocatable, intent(out) :: text
    character(len=:), allocatable :: out, fallback_html, scene
    character(len=:), allocatable :: webgl2_js

    out = load_template(template_arg, repo_root)

    if (len(runtime_js) > 0) then
      out = substitute_js(out, "{{F3D_JS}}", runtime_js, .false.)
      fallback_html = ""
    else
      out = substitute_js(out, "{{F3D_JS}}", "", .true.)
      fallback_html = html_escape(FALLBACK_MESSAGE)
    end if

    ! P5-B: inline the WebGL2 sidecar ("" when the file is
    ! missing; the boot degrades to the core player alone).
    call emit_html_webgl2_js(repo_root, webgl2_js)
    out = substitute_js(out, "{{WEBGL2_JS}}", webgl2_js, .false.)

    if (len(scene_js) > 0) then
      scene = scene_js
    else
      call emit_js(ir, scene)
    end if
    out = substitute_js(out, "{{SCENE_JS}}", scene, .false.)
    out = str_replace(out, "{{FALLBACK}}", fallback_html)
    out = str_replace(out, "{{TITLE}}", html_escape(scene_name(ir)))
    text = out
  end subroutine emit_html

end module f3dc_emit_html
