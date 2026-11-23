! f3dc_ext_gltf.f90 -- native port of tools/f3dc/ext_gltf.py
! (Forge3D Wave B glTF/GLB import, MASTER-PLAN row 19).
! Port contract: compiler/DESIGN.md.
!
! The compiler-side loader behind the existing DSL line
!
!     load "model.gltf"
!
! load_gltf converts a glTF 2.0 asset into a flat, format-neutral
! list of coloured triangles; triangles_to_tris_lines renders that
! list in the frozen .scene tris / tri format.  No axis conversion
! (glTF and Forge3D are both right-handed Y-up); every converted
! triangle has its 2nd and 3rd vertices swapped ((v1, v3, v2)) for
! the engine's winding convention -- see ext_gltf.py's docstring.
!
! Public API (mirrors the Python, with the GltfError raise turned
! into an ok/errmsg pair; errmsg carries the GltfError message
! verbatim, and f3dc_validate wraps it as E501 exactly like
! validate.py wraps the exception):
!
!   subroutine load_gltf(path, data, ok, errmsg)
!     data: dyn dict {"triangles": [...], "count": int}; each
!     triangle is a dyn list [ [r, g, b], [[x,y,z],[x,y,z],[x,y,z]] ]
!     (dyn_int colours, dyn_real coords) -- the shape
!     emit_fortran.tri_add recognises as the glTF shape.
!   subroutine triangles_to_tris_lines(name, data, lines, ok, errmsg)
!     lines: f3dc_str char_list of "tris NAME COUNT" / "tri ..." .
!
! JSON parsing reuses f3dc_ir.ir_json_parse (the landed json.loads
! port).  All diagnostics mirror ext_gltf.py message-for-message;
! see the port report for the residual divergences (CPython
! exception suffixes that carry OS / codec detail).
!
! No type-bound procedures.  Single-threaded error channel: the
! first failure wins, mirroring the Python raise.
module f3dc_ext_gltf
  use, intrinsic :: iso_fortran_env, only: int32, int64, real32, &
       real64
  use, intrinsic :: iso_c_binding, only: c_char, c_null_char
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
       ieee_is_nan
  use f3dc_dyn, only: dyn, dyn_str_box, dyn_null, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_dict_get, &
       dyn_dict_has, dyn_dict_set, dyn_dict_len, dyn_dict_key_at, &
       dyn_dict_value_at, dyn_list_push, dyn_list_len, dyn_list_at, &
       DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real, to_lower, char_list, &
       char_list_append
  use f3dc_ir, only: ir_json_parse
  implicit none
  private

  public :: load_gltf, triangles_to_tris_lines
  public :: GLTF_MAX_FILE_BYTES, GLTF_MAX_TRIANGLES

  !> ext_gltf.MAX_FILE_BYTES / MAX_TRIANGLES (MASTER-PLAN P26).
  integer(int64), parameter :: GLTF_MAX_FILE_BYTES = 67108864_int64
  integer(int64), parameter :: GLTF_MAX_TRIANGLES = 500000_int64

  integer(int32), parameter :: CHUNK_JSON = int(z'4E4F534A', int32)
  integer(int32), parameter :: CHUNK_BIN = int(z'004E4942', int32)

  ! GltfError channel: set by fail(), read by the public entries.
  logical :: g_failed = .false.
  character(:), allocatable :: g_errmsg

  ! CPython JSON-error locator state (failure path only; see the
  ! json_error_text section below).
  character(:), allocatable :: j_text
  integer :: j_pos  ! 1-based next-char index into j_text
  logical :: j_bad
  character(:), allocatable :: j_msg

  !> One resolved buffer's raw bytes.
  type :: byte_buf
    character(:), allocatable :: data
  end type byte_buf

  !> _read_accessor result: raw component values, row-major
  !! (count x ncomp); ivals for integer component types, rvals for
  !! FLOAT (float32 widened to real64 exactly, as struct does).
  type :: acc_result
    integer :: comp_type = 0
    integer :: ncomp = 0
    integer(int64) :: count = 0_int64
    integer(int64), allocatable :: ivals(:)
    real(real64), allocatable :: rvals(:)
  end type acc_result

  !> Shared state for one load_gltf call (the Python locals).
  type :: load_ctx
    type(dyn) :: doc
    type(byte_buf), allocatable :: buffers(:)
    type(dyn) :: meshes
    type(dyn) :: nodes
    type(dyn) :: triangles
    character(:), allocatable :: path
  end type load_ctx

  !> Growable string stack (os.path / scene-graph helpers).
  type :: str_stack
    type(dyn_str_box), allocatable :: items(:)
    integer :: n = 0
  end type str_stack

  ! libc getcwd (the f3dc_driver / f3dc_emit_* house pattern:
  ! flang-new-18 has no Fortran getcwd).
  interface
    function c_getcwd(buf, size) bind(C, name="getcwd") result(res)
      import :: c_char
      character(kind=c_char) :: buf(*)
      integer, value :: size
      integer :: res
    end function c_getcwd
  end interface

contains

  ! ==================================================================
  ! Error channel / scalar helpers (ext_gltf.py _fail, _is_int, ...)
  ! ==================================================================

  subroutine fail(msg)
    character(*), intent(in) :: msg
    if (.not. g_failed) then
      g_failed = .true.
      g_errmsg = msg
    end if
  end subroutine fail

  !> _is_int: isinstance(value, int) and not bool.
  pure logical function is_int(d)
    type(dyn), intent(in) :: d
    is_int = d%kind == DYN_K_INT
  end function is_int

  !> _is_number: isinstance(value, (int, float)) and not bool.
  pure logical function is_number(d)
    type(dyn), intent(in) :: d
    is_number = d%kind == DYN_K_INT .or. d%kind == DYN_K_REAL
  end function is_number

  !> float(value) for a numeric dyn.
  pure real(real64) function as_real(d)
    type(dyn), intent(in) :: d
    if (d%kind == DYN_K_INT) then
      as_real = real(d%i, real64)
    else
      as_real = d%r
    end if
  end function as_real

  !> Python `value == n` for a numeric dyn against an integer
  !! (5126.0 == 5126 is True in Python, so reals compare by value).
  pure logical function num_eq_int(d, n)
    type(dyn), intent(in) :: d
    integer(int64), intent(in) :: n
    num_eq_int = .false.
    if (d%kind == DYN_K_INT) then
      num_eq_int = d%i == n
    else if (d%kind == DYN_K_REAL) then
      num_eq_int = d%r == real(n, real64)
    end if
  end function num_eq_int

  !> doc.get(key, default) with Python semantics: a present null
  !! returns null, NOT the default.
  function dict_get_or(d, key, def) result(v)
    type(dyn), intent(in) :: d, def
    character(*), intent(in) :: key
    type(dyn) :: v
    if (dyn_dict_has(d, key)) then
      v = dyn_dict_get(d, key)
    else
      v = dyn_copy(def)
    end if
  end function dict_get_or

  ! ------------------------------------------------------------------
  ! Python repr() / str() of dyn values (for %r / %s in messages)
  ! ------------------------------------------------------------------

  function hex2(c) result(out)
    integer, intent(in) :: c
    character(2) :: out
    character(16), parameter :: HEXD = "0123456789abcdef"
    out(1:1) = HEXD(c / 16 + 1:c / 16 + 1)
    out(2:2) = HEXD(mod(c, 16) + 1:mod(c, 16) + 1)
  end function hex2

  !> repr() of a string: quote choice + escapes (same rules as
  !! f3dc_validate.repr_str).
  function repr_str(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out, body
    character :: quote
    integer :: k, c
    logical :: has_sq, has_dq
    has_sq = index(s, "'") > 0
    has_dq = index(s, '"') > 0
    if (has_sq .and. .not. has_dq) then
      quote = '"'
    else
      quote = "'"
    end if
    body = ""
    do k = 1, len(s)
      c = iachar(s(k:k))
      if (s(k:k) == "\") then
        body = body // "\\"
      else if (s(k:k) == quote) then
        body = body // "\" // quote
      else if (c == 10) then
        body = body // "\n"
      else if (c == 13) then
        body = body // "\r"
      else if (c == 9) then
        body = body // "\t"
      else if (c < 32 .or. c == 127) then
        body = body // "\x" // hex2(c)
      else
        body = body // s(k:k)
      end if
    end do
    out = quote // body // quote
  end function repr_str

  !> repr() of a bytes object (GLB magic diagnostic): b'...' with
  !! \xNN for non-printable bytes.
  function repr_bytes(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out, body
    character :: quote
    integer :: k, c
    logical :: has_sq, has_dq
    has_sq = index(s, "'") > 0
    has_dq = index(s, '"') > 0
    if (has_sq .and. .not. has_dq) then
      quote = '"'
    else
      quote = "'"
    end if
    body = ""
    do k = 1, len(s)
      c = iachar(s(k:k))
      if (s(k:k) == "\") then
        body = body // "\\"
      else if (s(k:k) == quote) then
        body = body // "\" // quote
      else if (c == 10) then
        body = body // "\n"
      else if (c == 13) then
        body = body // "\r"
      else if (c == 9) then
        body = body // "\t"
      else if (c < 32 .or. c >= 127) then
        body = body // "\x" // hex2(c)
      else
        body = body // s(k:k)
      end if
    end do
    out = "b" // quote // body // quote
  end function repr_bytes

  !> repr() of any dyn value.
  recursive function repr_dyn(d) result(out)
    type(dyn), intent(in) :: d
    character(:), allocatable :: out
    integer :: k
    select case (d%kind)
    case (DYN_K_NULL)
      out = "None"
    case (DYN_K_BOOL)
      if (d%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = fmt_int(d%i)
    case (DYN_K_REAL)
      out = fmt_real(d%r)
    case (DYN_K_STR)
      if (allocated(d%s)) then
        out = repr_str(d%s)
      else
        out = "''"
      end if
    case (DYN_K_LIST)
      out = "["
      do k = 1, d%n_items
        if (k > 1) out = out // ", "
        out = out // repr_dyn(d%items(k))
      end do
      out = out // "]"
    case (DYN_K_DICT)
      out = "{"
      do k = 1, d%n_entries
        if (k > 1) out = out // ", "
        out = out // repr_str(d%keys(k)%s) // ": " // &
             repr_dyn(d%dvals(k))
      end do
      out = out // "}"
    case default
      out = "None"
    end select
  end function repr_dyn

  !> str() of any dyn value (asset-version check): strings pass
  !! through raw, containers use repr, as in Python.
  recursive function py_str_dyn(d) result(out)
    type(dyn), intent(in) :: d
    character(:), allocatable :: out
    if (d%kind == DYN_K_STR) then
      if (allocated(d%s)) then
        out = d%s
      else
        out = ""
      end if
    else
      out = repr_dyn(d)
    end if
  end function py_str_dyn

  ! ------------------------------------------------------------------
  ! Number formatting / rounding with Python semantics
  ! ------------------------------------------------------------------

  !> Python round() on a real64: round-half-even on the exact
  !! binary value (x - floor(x) is exact, so the .5 test is exact).
  function py_round(x) result(n)
    real(real64), intent(in) :: x
    integer(int64) :: n
    real(real64) :: f, d
    f = floor(x)
    d = x - f
    if (d > 0.5_real64) then
      f = f + 1.0_real64
    else if (d == 0.5_real64) then
      if (mod(f, 2.0_real64) /= 0.0_real64) f = f + 1.0_real64
    end if
    n = int(f, int64)
  end function py_round

  !> _clamp01.
  pure real(real64) function clamp01(value)
    real(real64), intent(in) :: value
    if (value < 0.0_real64) then
      clamp01 = 0.0_real64
    else if (value > 1.0_real64) then
      clamp01 = 1.0_real64
    else
      clamp01 = value
    end if
  end function clamp01

  !> _to_byte: int(round(_clamp01(float(value)) * 255.0)).
  function to_byte(value) result(n)
    real(real64), intent(in) :: value
    integer(int64) :: n
    n = py_round(clamp01(value) * 255.0_real64)
  end function to_byte

  !> _fmt_float: "%.6g" % float(value), C/Python %g rules.
  function fmt_g6(x) result(out)
    real(real64), intent(in) :: x
    character(:), allocatable :: out
    character(40) :: buf
    character(6) :: digs
    integer :: exp10, i, epos, ipart_len
    logical :: neg
    real(real64) :: ax
    character(:), allocatable :: mant, frac
    if (ieee_is_nan(x)) then
      out = "nan"
      return
    end if
    if (.not. ieee_is_finite(x)) then
      if (x > 0.0_real64) then
        out = "inf"
      else
        out = "-inf"
      end if
      return
    end if
    neg = x < 0.0_real64
    if (x == 0.0_real64) then
      if (transfer(x, 0_int64) < 0_int64) neg = .true.
      if (neg) then
        out = "-0"
      else
        out = "0"
      end if
      return
    end if
    ax = abs(x)
    ! 6 significant digits, normalised mantissa + exponent.
    write (buf, "(ES13.5E3)") ax
    buf = adjustl(buf)
    epos = index(buf, "E")
    read (buf(epos + 1:), *) exp10
    digs = ""
    i = 0
    block
      integer :: k
      do k = 1, epos - 1
        if (buf(k:k) >= "0" .and. buf(k:k) <= "9") then
          i = i + 1
          digs(i:i) = buf(k:k)
        end if
      end do
    end block
    if (exp10 >= -4 .and. exp10 < 6) then
      ! Fixed notation, precision - exponent - 1 fraction digits.
      if (exp10 >= 0) then
        ipart_len = exp10 + 1
        mant = digs(1:ipart_len)
        frac = digs(ipart_len + 1:6)
        frac = strip_trailing_zeros(frac)
        if (len(frac) > 0) then
          out = mant // "." // frac
        else
          out = mant
        end if
      else
        frac = repeat("0", -exp10 - 1) // digs
        frac = strip_trailing_zeros(frac)
        out = "0." // frac
      end if
    else
      ! Scientific: d[.ddd]e+-XX (exponent at least 2 digits).
      frac = strip_trailing_zeros(digs(2:6))
      if (len(frac) > 0) then
        mant = digs(1:1) // "." // frac
      else
        mant = digs(1:1)
      end if
      out = mant // "e" // exp_str(exp10)
    end if
    if (neg) out = "-" // out
  end function fmt_g6

  function strip_trailing_zeros(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    integer :: n
    n = len(s)
    do while (n > 0)
      if (s(n:n) == "0") then
        n = n - 1
      else
        exit
      end if
    end do
    out = s(1:n)
  end function strip_trailing_zeros

  function exp_str(e) result(out)
    integer, intent(in) :: e
    character(:), allocatable :: out, digits
    digits = fmt_int(int(abs(e), int64))
    if (len(digits) < 2) digits = "0" // digits
    if (e < 0) then
      out = "-" // digits
    else
      out = "+" // digits
    end if
  end function exp_str

  ! ------------------------------------------------------------------
  ! String stack (component lists for path handling)
  ! ------------------------------------------------------------------

  subroutine stack_push(st, s)
    type(str_stack), intent(inout) :: st
    character(*), intent(in) :: s
    type(dyn_str_box), allocatable :: tmp(:)
    integer :: k, cap
    cap = 0
    if (allocated(st%items)) cap = size(st%items)
    if (st%n >= cap) then
      allocate (tmp(max(4, 2 * cap)))
      do k = 1, st%n
        if (allocated(st%items(k)%s)) tmp(k)%s = st%items(k)%s
      end do
      call move_alloc(tmp, st%items)
    end if
    st%n = st%n + 1
    st%items(st%n)%s = s
  end subroutine stack_push

  subroutine stack_pop(st)
    type(str_stack), intent(inout) :: st
    if (st%n > 0) st%n = st%n - 1
  end subroutine stack_pop

  function stack_top(st) result(out)
    type(str_stack), intent(in) :: st
    character(:), allocatable :: out
    if (st%n < 1 .or. .not. allocated(st%items(st%n)%s)) then
      out = ""
    else
      out = st%items(st%n)%s
    end if
  end function stack_top

  function stack_join(st, sep) result(out)
    type(str_stack), intent(in) :: st
    character(*), intent(in) :: sep
    character(:), allocatable :: out
    integer :: k
    out = ""
    do k = 1, st%n
      if (k > 1) out = out // sep
      if (allocated(st%items(k)%s)) out = out // st%items(k)%s
    end do
  end function stack_join

  ! ==================================================================
  ! os.path mirrors (POSIX): splitext suffix, dirname, join,
  ! normpath, abspath -- the subset ext_gltf.py uses.
  ! ==================================================================

  !> os.path.splitext(path)[1].lower(): the lowercased final
  !! suffix (with dot), "" when there is none.  Leading dots of
  !! the basename belong to the stem.
  function py_suffix(path) result(out)
    character(*), intent(in) :: path
    character(:), allocatable :: out
    integer :: isep, idot, k
    logical :: all_dots
    isep = 0
    idot = 0
    do k = 1, len(path)
      if (path(k:k) == "/") isep = k
      if (path(k:k) == ".") idot = k
    end do
    out = ""
    if (idot > isep) then
      all_dots = .true.
      do k = isep + 1, idot - 1
        if (path(k:k) /= ".") all_dots = .false.
      end do
      if (.not. all_dots) out = to_lower(path(idot:len(path)))
    end if
  end function py_suffix

  !> os.path.dirname: posixpath.split(path)[0].
  function py_dirname(p) result(out)
    character(*), intent(in) :: p
    character(:), allocatable :: out
    integer :: isep, k, n
    logical :: all_sep
    isep = 0
    do k = 1, len(p)
      if (p(k:k) == "/") isep = k
    end do
    if (isep == 0) then
      out = ""
      return
    end if
    out = p(1:isep)
    all_sep = .true.
    do k = 1, len(out)
      if (out(k:k) /= "/") all_sep = .false.
    end do
    if (all_sep) return
    n = len(out)
    do while (n > 0)
      if (out(n:n) == "/") then
        n = n - 1
      else
        exit
      end if
    end do
    out = out(1:n)
  end function py_dirname

  !> os.path.join(a, b) (POSIX, two parts).
  function py_join(a, b) result(out)
    character(*), intent(in) :: a, b
    character(:), allocatable :: out
    if (len(b) > 0) then
      if (b(1:1) == "/") then
        out = b
        return
      end if
    end if
    if (len(a) == 0) then
      out = a // b
    else if (a(len(a):len(a)) == "/") then
      out = a // b
    else
      out = a // "/" // b
    end if
  end function py_join

  !> os.path.normpath (POSIX): lexical ./.. resolution, redundant
  !! separators collapsed, "//" prefix preserved, "" -> ".".
  function py_normpath(p) result(out)
    character(*), intent(in) :: p
    character(:), allocatable :: out, prefix
    type(str_stack) :: st
    integer :: i, j, n
    logical :: is_abs
    if (len(p) == 0) then
      out = "."
      return
    end if
    is_abs = p(1:1) == "/"
    prefix = ""
    if (is_abs) then
      prefix = "/"
      if (len(p) >= 2) then
        if (p(1:2) == "//") then
          if (len(p) == 2 .or. p(3:3) /= "/") prefix = "//"
        end if
      end if
    end if
    n = len(p)
    i = 1
    do
      j = index(p(i:n), "/")
      block
        character(:), allocatable :: comp
        if (j == 0) then
          comp = p(i:n)
        else
          comp = p(i:i + j - 2)
        end if
        if (len(comp) == 0 .or. comp == ".") then
          continue
        else if (comp == "..") then
          if (st%n > 0 .and. stack_top(st) /= "..") then
            call stack_pop(st)
          else if (.not. is_abs) then
            call stack_push(st, "..")
          end if
        else
          call stack_push(st, comp)
        end if
      end block
      if (j == 0) exit
      i = i + j
      if (i > n) exit
    end do
    out = prefix // stack_join(st, "/")
    if (len(out) == 0) out = "."
  end function py_normpath

  !> Current working directory via libc getcwd (f3dc_driver's
  !! driver_cwd pattern).
  function cwd_str() result(out)
    character(:), allocatable :: out
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
  end function cwd_str

  !> os.path.abspath: normpath(join(cwd, path)) for relative
  !! paths, normpath(path) for absolute ones.
  function py_abspath(p) result(out)
    character(*), intent(in) :: p
    character(:), allocatable :: out
    if (len(p) > 0) then
      if (p(1:1) == "/") then
        out = py_normpath(p)
        return
      end if
    end if
    out = py_normpath(py_join(cwd_str(), p))
  end function py_abspath

  pure logical function is_hex(c)
    character, intent(in) :: c
    is_hex = (c >= "0" .and. c <= "9") .or. (c >= "a" .and. &
         c <= "f") .or. (c >= "A" .and. c <= "F")
  end function is_hex

  pure integer function hex_val1(c)
    character, intent(in) :: c
    if (c >= "0" .and. c <= "9") then
      hex_val1 = iachar(c) - iachar("0")
    else if (c >= "a" .and. c <= "f") then
      hex_val1 = iachar(c) - iachar("a") + 10
    else
      hex_val1 = iachar(c) - iachar("A") + 10
    end if
  end function hex_val1

  ! ==================================================================
  ! UTF-8 decode checks.  Python decodes .gltf text (and the GLB
  ! JSON chunk) as UTF-8 and embeds str(UnicodeDecodeError) in the
  ! diagnostic; utf8_check reproduces that string for the common
  ! failure shapes (invalid start byte / invalid continuation
  ! byte / unexpected end of data, CPython positions + wording).
  ! ==================================================================

  !> Scan one UTF-8 sequence starting at byte i (1-based) of s.
  !! Returns: nbytes (>0) for a valid sequence; on error, nbytes=0
  !! and reason/span describe the CPython failure: err_span is the
  !! number of bytes the error covers starting at i.
  subroutine utf8_seq(s, i, nbytes, reason, err_span)
    character(*), intent(in) :: s
    integer, intent(in) :: i
    integer, intent(out) :: nbytes, err_span
    character(:), allocatable, intent(out) :: reason
    integer :: b, need, k, lo2, hi2, cb
    nbytes = 0
    err_span = 1
    reason = ""
    b = iachar(s(i:i))
    if (b < 128) then
      nbytes = 1
      return
    end if
    lo2 = 128
    hi2 = 191
    if (b >= 194 .and. b <= 223) then
      need = 2
    else if (b == 224) then
      need = 3
      lo2 = 160
    else if ((b >= 225 .and. b <= 236) .or. b == 238 .or. &
         b == 239) then
      need = 3
    else if (b == 237) then
      need = 3
      hi2 = 159
    else if (b == 240) then
      need = 4
      lo2 = 144
    else if (b >= 241 .and. b <= 243) then
      need = 4
    else if (b == 244) then
      need = 4
      hi2 = 143
    else
      reason = "invalid start byte"
      return
    end if
    ! CPython's decoder, probed byte-for-byte: a bad continuation
    ! (including a second byte outside the E0/ED/F0/F4 special
    ! range) is "invalid continuation byte" spanning the valid
    ! prefix of the sequence; running out of bytes mid-sequence
    ! with all present bytes valid is "unexpected end of data"
    ! spanning what is left.
    do k = 2, need
      if (i + k - 1 > len(s)) then
        reason = "unexpected end of data"
        err_span = len(s) - i + 1
        return
      end if
      cb = iachar(s(i + k - 1:i + k - 1))
      if (cb < 128 .or. cb > 191) then
        reason = "invalid continuation byte"
        err_span = k - 1
        return
      end if
      if (k == 2 .and. (cb < lo2 .or. cb > hi2)) then
        reason = "invalid continuation byte"
        err_span = 1
        return
      end if
    end do
    nbytes = need
  end subroutine utf8_seq

  !> Validate s as UTF-8; on failure, msg = str(UnicodeDecodeError)
  !! exactly as CPython formats it.
  subroutine utf8_check(s, ok, msg)
    character(*), intent(in) :: s
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: msg
    integer :: i, nbytes, err_span
    character(:), allocatable :: reason
    ok = .true.
    msg = ""
    i = 1
    do while (i <= len(s))
      call utf8_seq(s, i, nbytes, reason, err_span)
      if (nbytes == 0) then
        ok = .false.
        if (err_span > 1) then
          msg = "'utf-8' codec can't decode bytes in position " // &
               trim(fmt_int(int(i - 1, int64))) // "-" // &
               trim(fmt_int(int(i + err_span - 2, int64))) // ": " // &
               reason
        else
          msg = "'utf-8' codec can't decode byte 0x" // &
               hex2(iachar(s(i:i))) // " in position " // &
               trim(fmt_int(int(i - 1, int64))) // ": " // reason
        end if
        return
      end if
      i = i + nbytes
    end do
  end subroutine utf8_check

  !> Decode UTF-8 with errors="replace" (urllib unquote's decode):
  !! each invalid maximal subpart becomes one U+FFFD.
  function utf8_replace(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out, reason
    integer :: i, nbytes, err_span, k, cb, need, lo2, hi2
    out = ""
    i = 1
    do while (i <= len(s))
      call utf8_seq(s, i, nbytes, reason, err_span)
      if (nbytes > 0) then
        out = out // s(i:i + nbytes - 1)
        i = i + nbytes
      else if (reason == "unexpected end of data") then
        out = out // achar(239) // achar(191) // achar(189)
        i = len(s) + 1
      else
        ! One replacement covers the error span (the lead byte
        ! plus any valid continuation prefix).
        out = out // achar(239) // achar(191) // achar(189)
        i = i + max(err_span, 1)
      end if
    end do
  end function utf8_replace

  !> urllib.parse.unquote(uri): %XX bytes, UTF-8/replace decode.
  function unquote(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out, bytes
    integer :: i, bval
    bytes = ""
    i = 1
    do while (i <= len(s))
      if (s(i:i) == "%" .and. i + 2 <= len(s)) then
        if (is_hex(s(i + 1:i + 1)) .and. is_hex(s(i + 2:i + 2))) then
          bval = hex_val1(s(i + 1:i + 1)) * 16 + &
               hex_val1(s(i + 2:i + 2))
          bytes = bytes // achar(bval)
          i = i + 3
          cycle
        end if
      end if
      bytes = bytes // s(i:i)
      i = i + 1
    end do
    out = utf8_replace(bytes)
  end function unquote

  ! ==================================================================
  ! base64 (base64.b64decode(payload, validate=True))
  ! ==================================================================

  pure integer function b64_val(c)
    character, intent(in) :: c
    if (c >= "A" .and. c <= "Z") then
      b64_val = iachar(c) - iachar("A")
    else if (c >= "a" .and. c <= "z") then
      b64_val = iachar(c) - iachar("a") + 26
    else if (c >= "0" .and. c <= "9") then
      b64_val = iachar(c) - iachar("0") + 52
    else if (c == "+") then
      b64_val = 62
    else if (c == "/") then
      b64_val = 63
    else
      b64_val = -1
    end if
  end function b64_val

  !> Decode a base64 payload; on failure err carries the
  !! binascii.Error / ValueError text Python would raise.
  subroutine b64_decode(payload, out, err)
    character(*), intent(in) :: payload
    character(:), allocatable, intent(out) :: out, err
    integer :: i, n, first_eq, data_chars, pad_chars, v(4), nout
    integer :: cp
    out = ""
    err = ""
    n = len(payload)
    ! Non-ASCII: b64decode encodes the str as ASCII first and the
    ! UnicodeEncodeError (a ValueError) is what _decode_data_uri
    ! catches.
    block
      integer :: bytepos, nbytes_cp, span_cp
      character(:), allocatable :: why_cp
      ! Every byte before the first non-ASCII byte is a one-byte
      ! ASCII character, so its character position is bytepos - 1.
      do bytepos = 1, n
        if (iachar(payload(bytepos:bytepos)) >= 128) then
          call utf8_seq(payload, bytepos, nbytes_cp, why_cp, span_cp)
          if (nbytes_cp == 0) then
            cp = iachar(payload(bytepos:bytepos))
          else
            cp = utf8_codepoint(payload, bytepos, nbytes_cp)
          end if
          if (cp <= 65535) then
            err = "'ascii' codec can't encode character '\\u" // &
                 hex4(cp) // "' in position " // &
                 trim(fmt_int(int(bytepos - 1, int64))) // &
                 ": ordinal not in range(128)"
          else
            err = "'ascii' codec can't encode character '\\U" // &
                 hex8(cp) // "' in position " // &
                 trim(fmt_int(int(bytepos - 1, int64))) // &
                 ": ordinal not in range(128)"
          end if
          return
        end if
      end do
    end block
    ! binascii strict_mode state machine (validate=True),
    ! probed against CPython: padding errors are positional --
    ! "Leading padding" ('=' before any data), "Discontinuous
    ! padding" (data after an unfinished padding run), "Excess
    ! data after padding" (anything after a completed padded
    ! quad); trailing '=' after a complete unpadded quad is
    ! ignored by binascii, as are the end-of-input checks below.
    block
      integer :: quad_data, quad_pad, data_total
      logical :: finished
      quad_data = 0
      quad_pad = 0
      data_total = 0
      finished = .false.
      do i = 1, n
        if (finished) then
          err = "Excess data after padding"
          return
        end if
        if (payload(i:i) == "=") then
          if (data_total == 0) then
            err = "Leading padding not allowed"
            return
          end if
          quad_pad = quad_pad + 1
          if (quad_data + quad_pad == 4 .and. quad_pad <= 2) &
               finished = .true.
        else if (b64_val(payload(i:i)) >= 0) then
          if (quad_pad > 0) then
            err = "Discontinuous padding not allowed"
            return
          end if
          quad_data = quad_data + 1
          data_total = data_total + 1
          if (quad_data == 4) quad_data = 0
        else
          err = "Only base64 data is allowed"
          return
        end if
      end do
      if (mod(data_total, 4) == 1) then
        err = "Invalid base64-encoded string: number of data " // &
             "characters (" // &
             trim(fmt_int(int(data_total, int64))) // &
             ") cannot be 1 more than a multiple of 4"
        return
      end if
      if (.not. finished .and. quad_data /= 0) then
        err = "Incorrect padding"
        return
      end if
      data_chars = data_total
    end block
    ! Decode: in a valid payload every '=' is in the suffix, so
    ! decode the data characters in quads of 4 (last quad may
    ! hold 2 or 3).
    i = 1
    do while (i <= data_chars)
      block
        integer :: g, take
        take = min(4, data_chars - i + 1)
        v = 0
        do g = 1, take
          v(g) = b64_val(payload(i + g - 1:i + g - 1))
        end do
        out = out // achar(v(1) * 4 + v(2) / 16)
        if (take >= 3) out = out // &
             achar(mod(v(2), 16) * 16 + v(3) / 4)
        if (take >= 4) out = out // &
             achar(mod(v(3), 4) * 64 + v(4))
      end block
      i = i + 4
    end do
  end subroutine b64_decode

  !> Code point of the valid UTF-8 sequence at byte i (nbytes
  !! long); 0 when the sequence is invalid.
  pure integer function utf8_codepoint(s, i, nbytes)
    character(*), intent(in) :: s
    integer, intent(in) :: i, nbytes
    integer :: b(4), k
    utf8_codepoint = 0
    if (nbytes < 1 .or. nbytes > 4) return
    if (i + nbytes - 1 > len(s)) return
    do k = 1, nbytes
      b(k) = iachar(s(i + k - 1:i + k - 1))
    end do
    select case (nbytes)
    case (1)
      utf8_codepoint = b(1)
    case (2)
      utf8_codepoint = (b(1) - 192) * 64 + (b(2) - 128)
    case (3)
      utf8_codepoint = (b(1) - 224) * 4096 + (b(2) - 128) * 64 + &
           (b(3) - 128)
    case (4)
      utf8_codepoint = (b(1) - 240) * 262144 + (b(2) - 128) * &
           4096 + (b(3) - 128) * 64 + (b(4) - 128)
    end select
  end function utf8_codepoint

  function hex4(c) result(out)
    integer, intent(in) :: c
    character(4) :: out
    out = hex2(c / 256) // hex2(mod(c, 256))
  end function hex4

  function hex8(c) result(out)
    integer, intent(in) :: c
    character(8) :: out
    out = hex4(c / 65536) // hex4(mod(c, 65536))
  end function hex8

  ! ==================================================================
  ! CPython json error locator.  ir_json_parse reports only
  ! ok / not-ok; when it rejects a document this scanner re-walks
  ! the text with CPython's json scanner rules and formats the
  ! JSONDecodeError string ("<msg>: line L column C (char P)") for
  ! the first error, so the GltfError text matches Python's.  It
  ! runs only on the failure path.  Returns "" when it finds no
  ! error (input ir_json_parse rejected for a grammar corner the
  ! locator does not model, e.g. a lone-surrogate \u escape).
  ! ==================================================================

  subroutine j_make_err(msgtext, pos0)
    character(*), intent(in) :: msgtext
    integer, intent(in) :: pos0  ! 0-based char position
    integer :: k, lineno, colno, last_nl
    if (j_bad) return
    j_bad = .true.
    lineno = 1
    last_nl = -1
    do k = 1, min(pos0, len(j_text))
      if (j_text(k:k) == achar(10)) then
        lineno = lineno + 1
        last_nl = k - 1
      end if
    end do
    colno = pos0 - last_nl
    j_msg = msgtext // ": line " // trim(fmt_int(int(lineno, &
         int64))) // " column " // trim(fmt_int(int(colno, &
         int64))) // " (char " // trim(fmt_int(int(pos0, int64))) // &
         ")"
  end subroutine j_make_err

  subroutine j_skip_ws()
    do while (j_pos <= len(j_text))
      if (j_text(j_pos:j_pos) == " " .or. &
          j_text(j_pos:j_pos) == achar(9) .or. &
          j_text(j_pos:j_pos) == achar(10) .or. &
          j_text(j_pos:j_pos) == achar(13)) then
        j_pos = j_pos + 1
      else
        exit
      end if
    end do
  end subroutine j_skip_ws

  subroutine j_scan_string()
    integer :: start0, c
    start0 = j_pos - 1
    j_pos = j_pos + 1  ! opening quote
    do while (j_pos <= len(j_text))
      c = iachar(j_text(j_pos:j_pos))
      if (j_text(j_pos:j_pos) == '"') then
        j_pos = j_pos + 1
        return
      end if
      if (c < 32) then
        call j_make_err("Invalid control character at", j_pos - 1)
        return
      end if
      if (j_text(j_pos:j_pos) == "\") then
        j_pos = j_pos + 1
        if (j_pos > len(j_text)) then
          call j_make_err("Unterminated string starting at", start0)
          return
        end if
        select case (j_text(j_pos:j_pos))
        case ('"', "\", "/", "b", "f", "n", "r", "t")
          j_pos = j_pos + 1
        case ("u")
          block
            integer :: k
            logical :: okhex
            okhex = j_pos + 4 <= len(j_text)
            if (okhex) then
              do k = 1, 4
                if (.not. is_hex(j_text(j_pos + k:j_pos + k))) &
                     okhex = .false.
              end do
            end if
            if (.not. okhex) then
              call j_make_err("Invalid \uXXXX escape", j_pos - 1)
              return
            end if
            j_pos = j_pos + 5
          end block
        case default
          ! CPython reports the position of the backslash.
          call j_make_err("Invalid \escape", j_pos - 2)
          return
        end select
        cycle
      end if
      j_pos = j_pos + 1
    end do
    call j_make_err("Unterminated string starting at", start0)
  end subroutine j_scan_string

  subroutine j_scan_number()
    integer :: start0, p
    start0 = j_pos - 1
    p = j_pos
    if (j_text(p:p) == "-") then
      p = p + 1
      if (p <= len(j_text)) then
        if (j_text(p:p) == "I") then
          if (p + 7 <= len(j_text)) then
            if (j_text(p:p + 7) == "Infinity") then
              j_pos = p + 8
              return
            end if
          end if
          call j_make_err("Expecting value", start0)
          return
        end if
      end if
    end if
    if (p > len(j_text)) then
      call j_make_err("Expecting value", start0)
      return
    end if
    if (j_text(p:p) == "0") then
      p = p + 1
    else if (j_text(p:p) >= "1" .and. j_text(p:p) <= "9") then
      do while (p <= len(j_text))
        if (j_text(p:p) >= "0" .and. j_text(p:p) <= "9") then
          p = p + 1
        else
          exit
        end if
      end do
    else
      call j_make_err("Expecting value", start0)
      return
    end if
    ! Fraction: consumed only when a digit follows the dot.
    if (p + 1 <= len(j_text)) then
      if (j_text(p:p) == "." .and. j_text(p + 1:p + 1) >= "0" &
          .and. j_text(p + 1:p + 1) <= "9") then
        p = p + 2
        do while (p <= len(j_text))
          if (j_text(p:p) >= "0" .and. j_text(p:p) <= "9") then
            p = p + 1
          else
            exit
          end if
        end do
      end if
    end if
    ! Exponent: consumed only when digits follow e[+-].
    if (p <= len(j_text)) then
      if (j_text(p:p) == "e" .or. j_text(p:p) == "E") then
        block
          integer :: q
          q = p + 1
          if (q <= len(j_text)) then
            if (j_text(q:q) == "+" .or. j_text(q:q) == "-") q = q + 1
          end if
          if (q <= len(j_text)) then
            if (j_text(q:q) >= "0" .and. j_text(q:q) <= "9") then
              p = q
              do while (p <= len(j_text))
                if (j_text(p:p) >= "0" .and. j_text(p:p) <= "9") &
                     then
                  p = p + 1
                else
                  exit
                end if
              end do
            end if
          end if
        end block
      end if
    end if
    j_pos = p
  end subroutine j_scan_number

  subroutine j_scan_literal(word)
    character(*), intent(in) :: word
    integer :: start0
    start0 = j_pos - 1
    if (j_pos + len(word) - 1 <= len(j_text)) then
      if (j_text(j_pos:j_pos + len(word) - 1) == word) then
        j_pos = j_pos + len(word)
        return
      end if
    end if
    call j_make_err("Expecting value", start0)
  end subroutine j_scan_literal

  recursive subroutine j_scan_value()
    character :: ch
    if (j_bad) return
    if (j_pos > len(j_text)) then
      call j_make_err("Expecting value", j_pos - 1)
      return
    end if
    ch = j_text(j_pos:j_pos)
    select case (ch)
    case ("{")
      call j_scan_object()
    case ("[")
      call j_scan_array()
    case ('"')
      call j_scan_string()
    case ("t")
      call j_scan_literal("true")
    case ("f")
      call j_scan_literal("false")
    case ("n")
      call j_scan_literal("null")
    case ("N")
      call j_scan_literal("NaN")
    case ("I")
      call j_scan_literal("Infinity")
    case default
      if (ch == "-" .or. (ch >= "0" .and. ch <= "9")) then
        call j_scan_number()
      else
        call j_make_err("Expecting value", j_pos - 1)
      end if
    end select
  end subroutine j_scan_value

  recursive subroutine j_scan_array()
    j_pos = j_pos + 1  ! '['
    call j_skip_ws()
    if (j_pos <= len(j_text)) then
      if (j_text(j_pos:j_pos) == "]") then
        j_pos = j_pos + 1
        return
      end if
    end if
    do
      call j_scan_value()
      if (j_bad) return
      call j_skip_ws()
      if (j_pos > len(j_text)) then
        call j_make_err("Expecting ',' delimiter", len(j_text))
        return
      end if
      if (j_text(j_pos:j_pos) == ",") then
        j_pos = j_pos + 1
        call j_skip_ws()
        cycle
      end if
      if (j_text(j_pos:j_pos) == "]") then
        j_pos = j_pos + 1
        return
      end if
      call j_make_err("Expecting ',' delimiter", j_pos - 1)
      return
    end do
  end subroutine j_scan_array

  recursive subroutine j_scan_object()
    j_pos = j_pos + 1  ! '{'
    call j_skip_ws()
    if (j_pos <= len(j_text)) then
      if (j_text(j_pos:j_pos) == "}") then
        j_pos = j_pos + 1
        return
      end if
    end if
    do
      call j_skip_ws()
      if (j_pos > len(j_text)) then
        call j_make_err( &
             "Expecting property name enclosed in double quotes", &
             len(j_text))
        return
      end if
      if (j_text(j_pos:j_pos) /= '"') then
        call j_make_err( &
             "Expecting property name enclosed in double quotes", &
             j_pos - 1)
        return
      end if
      call j_scan_string()
      if (j_bad) return
      call j_skip_ws()
      if (j_pos > len(j_text)) then
        call j_make_err("Expecting ':' delimiter", len(j_text))
        return
      end if
      if (j_text(j_pos:j_pos) /= ":") then
        call j_make_err("Expecting ':' delimiter", j_pos - 1)
        return
      end if
      j_pos = j_pos + 1
      call j_skip_ws()
      call j_scan_value()
      if (j_bad) return
      call j_skip_ws()
      if (j_pos > len(j_text)) then
        call j_make_err("Expecting ',' delimiter", len(j_text))
        return
      end if
      if (j_text(j_pos:j_pos) == ",") then
        j_pos = j_pos + 1
        cycle
      end if
      if (j_text(j_pos:j_pos) == "}") then
        j_pos = j_pos + 1
        return
      end if
      call j_make_err("Expecting ',' delimiter", j_pos - 1)
      return
    end do
  end subroutine j_scan_object

  !> The CPython JSONDecodeError string for text, or "" when the
  !! locator finds no error.
  function json_error_text(text) result(out)
    character(*), intent(in) :: text
    character(:), allocatable :: out
    j_text = text
    j_pos = 1
    j_bad = .false.
    j_msg = ""
    call j_skip_ws()
    call j_scan_value()
    if (.not. j_bad) then
      call j_skip_ws()
      if (j_pos <= len(j_text)) &
           call j_make_err("Extra data", j_pos - 1)
    end if
    if (j_bad) then
      out = j_msg
    else
      out = ""
    end if
  end function json_error_text

  ! ==================================================================
  ! File / buffer loading (_read_file_bytes,
  ! _load_external_buffer, _decode_data_uri, _resolve_buffers)
  ! ==================================================================

  !> Read a whole file as raw bytes.  status: 0 ok, 1 not found,
  !! 2 other I/O failure.
  subroutine read_raw_file(path, data, status)
    character(*), intent(in) :: path
    character(:), allocatable, intent(out) :: data
    integer, intent(out) :: status
    integer :: unit, ios
    integer(int64) :: sz
    logical :: there
    data = ""
    status = 2
    inquire (file=path, exist=there, size=sz)
    if (.not. there) then
      status = 1
      return
    end if
    open (newunit=unit, file=path, access="stream", &
         form="unformatted", status="old", iostat=ios)
    if (ios /= 0) return
    if (sz < 0) then
      close (unit)
      return
    end if
    allocate (character(len=int(sz)) :: data)
    if (sz > 0) read (unit, iostat=ios) data
    close (unit)
    if (ios /= 0) then
      status = 2
      return
    end if
    status = 0
  end subroutine read_raw_file

  !> _read_file_bytes: size limit enforced from getsize before
  !! the read, exactly like the Python.
  subroutine read_top_file(path, data)
    character(*), intent(in) :: path
    character(:), allocatable, intent(out) :: data
    logical :: there
    integer(int64) :: sz
    integer :: status
    data = ""
    inquire (file=path, exist=there, size=sz)
    if (.not. there) then
      call fail("glTF file not found: " // path)
      return
    end if
    if (sz > GLTF_MAX_FILE_BYTES) then
      call fail("glTF file " // path // " is " // &
           trim(fmt_int(sz)) // &
           " bytes, exceeding the 64 MB limit")
      return
    end if
    call read_raw_file(path, data, status)
    if (status == 1) then
      call fail("glTF file not found: " // path)
    else if (status /= 0) then
      ! Python appends str(OSError) here; the native port cannot
      ! reproduce the errno text (see port report).
      call fail("cannot read glTF file " // path // ": I/O error")
    end if
  end subroutine read_top_file

  !> _load_external_buffer.
  subroutine load_external_buffer(uri, base_dir, has_decl, decl_len, &
       data)
    character(*), intent(in) :: uri, base_dir
    logical, intent(in) :: has_decl
    integer(int64), intent(in) :: decl_len
    character(:), allocatable, intent(out) :: data
    character(:), allocatable :: rel, full
    logical :: there
    integer(int64) :: sz
    integer :: status
    data = ""
    rel = unquote(uri)
    if (len(rel) > 0) then
      if (rel(1:1) == "/") then
        call fail("buffer URI " // repr_str(uri) // &
             " is absolute; only relative buffer files " // &
             "are supported")
        return
      end if
    end if
    full = py_normpath(py_join(base_dir, rel))
    inquire (file=full, exist=there, size=sz)
    if (.not. there) then
      call fail("buffer file not found: " // full // &
           " (referenced as " // repr_str(uri) // ")")
      return
    end if
    if (sz > GLTF_MAX_FILE_BYTES) then
      call fail("buffer file " // full // " is " // &
           trim(fmt_int(sz)) // &
           " bytes, exceeding the 64 MB limit")
      return
    end if
    call read_raw_file(full, data, status)
    if (status /= 0) then
      call fail("cannot read buffer file " // full // ": I/O error")
      return
    end if
    if (has_decl .and. int(len(data), int64) < decl_len) then
      call fail("buffer file " // full // " is " // &
           trim(fmt_int(int(len(data), int64))) // &
           " bytes but the buffer declares " // &
           trim(fmt_int(decl_len)))
      return
    end if
  end subroutine load_external_buffer

  !> _decode_data_uri.
  subroutine decode_data_uri(uri, data)
    character(*), intent(in) :: uri
    character(:), allocatable, intent(out) :: data
    character(:), allocatable :: header, payload, err
    integer :: sep
    data = ""
    sep = index(uri, ",")
    if (sep == 0) then
      call fail("unsupported buffer data URI " // &
           repr_str(uri(1:min(64, len(uri)))) // &
           ": only base64 data URIs are supported")
      return
    end if
    header = uri(1:sep - 1)
    payload = uri(sep + 1:len(uri))
    if (index(to_lower(header), ";base64") == 0) then
      call fail("unsupported buffer data URI " // &
           repr_str(uri(1:min(64, len(uri)))) // &
           ": only base64 data URIs are supported")
      return
    end if
    call b64_decode(payload, data, err)
    if (len(err) > 0) then
      call fail("invalid base64 in buffer data URI: " // err)
      data = ""
    end if
  end subroutine decode_data_uri

  !> _resolve_buffers: raw bytes for every doc['buffers'] entry.
  subroutine resolve_buffers(ctx, base_dir, glb_bin, has_glb_bin)
    type(load_ctx), intent(inout) :: ctx
    character(*), intent(in) :: base_dir, glb_bin
    logical, intent(in) :: has_glb_bin
    type(dyn) :: defs, entry, blv, uriv
    character(:), allocatable :: data
    integer :: i, n
    logical :: has_bl
    call require_list(ctx%doc, "buffers", .false., defs)
    if (g_failed) return
    n = dyn_list_len(defs)
    allocate (ctx%buffers(n))
    do i = 1, n
      entry = dyn_list_at(defs, i)
      if (entry%kind /= DYN_K_DICT) then
        call fail("buffer " // trim(fmt_int(int(i - 1, int64))) // &
             " must be an object")
        return
      end if
      blv = dyn_dict_get(entry, "byteLength")
      has_bl = blv%kind /= DYN_K_NULL
      if (has_bl) then
        if (.not. is_int(blv) .or. blv%i < 0_int64) then
          call fail("buffer " // trim(fmt_int(int(i - 1, int64))) // &
               " 'byteLength' must be a non-negative integer")
          return
        end if
      end if
      uriv = dyn_dict_get(entry, "uri")
      if (uriv%kind == DYN_K_NULL) then
        if (.not. has_glb_bin) then
          call fail("buffer " // trim(fmt_int(int(i - 1, int64))) // &
               " has no 'uri' and the file has no GLB BIN chunk")
          return
        end if
        if (i /= 1) then
          call fail("buffer " // trim(fmt_int(int(i - 1, int64))) // &
               " has no 'uri'; only the first GLB buffer may " // &
               "omit it")
          return
        end if
        data = glb_bin
      else if (uriv%kind == DYN_K_STR .and. len(uriv%s) >= 5) then
        if (uriv%s(1:5) == "data:") then
          call decode_data_uri(uriv%s, data)
          if (g_failed) return
        else if (len(uriv%s) > 0) then
          call load_external_buffer(uriv%s, base_dir, has_bl, &
               blv%i, data)
          if (g_failed) return
        else
          call fail("buffer " // trim(fmt_int(int(i - 1, int64))) // &
               " has an invalid 'uri'")
          return
        end if
      else if (uriv%kind == DYN_K_STR .and. len(uriv%s) > 0) then
        call load_external_buffer(uriv%s, base_dir, has_bl, &
             blv%i, data)
        if (g_failed) return
      else
        call fail("buffer " // trim(fmt_int(int(i - 1, int64))) // &
             " has an invalid 'uri'")
        return
      end if
      if (has_bl .and. int(len(data), int64) < blv%i) then
        call fail("buffer " // trim(fmt_int(int(i - 1, int64))) // &
             " declares " // trim(fmt_int(blv%i)) // &
             " bytes but only " // &
             trim(fmt_int(int(len(data), int64))) // &
             " are available")
        return
      end if
      if (has_bl) then
        ctx%buffers(i)%data = data(1:int(blv%i))
      else
        ctx%buffers(i)%data = data
      end if
    end do
  end subroutine resolve_buffers

  !> _require_list.
  subroutine require_list(doc, key, required, out)
    type(dyn), intent(in) :: doc
    character(*), intent(in) :: key
    logical, intent(in) :: required
    type(dyn), intent(out) :: out
    type(dyn) :: v
    v = dyn_dict_get(doc, key)
    if (v%kind == DYN_K_NULL) then
      if (required) then
        call fail("glTF document is missing required " // &
             repr_str(key) // " array")
      end if
      out = dyn_list()
      return
    end if
    if (v%kind /= DYN_K_LIST) then
      call fail("glTF " // repr_str(key) // " must be an array")
      out = dyn_list()
      return
    end if
    out = v
  end subroutine require_list

  !> _require_index.
  subroutine require_index(value, length, what, out_idx)
    type(dyn), intent(in) :: value
    integer, intent(in) :: length
    character(*), intent(in) :: what
    integer(int64), intent(out) :: out_idx
    out_idx = -1_int64
    if (.not. is_int(value) .or. value%i < 0_int64 .or. &
         value%i >= int(length, int64)) then
      call fail(what // " index " // repr_dyn(value) // &
           " is out of range (valid: 0.." // &
           trim(fmt_int(int(length - 1, int64))) // ")")
      return
    end if
    out_idx = value%i
  end subroutine require_index

  ! ==================================================================
  ! Matrices (4x4, stored (row, col); world = M * (x, y, z, 1))
  ! ==================================================================

  subroutine identity_mat(m)
    real(real64), intent(out) :: m(4, 4)
    integer :: r, c
    do c = 1, 4
      do r = 1, 4
        if (r == c) then
          m(r, c) = 1.0_real64
        else
          m(r, c) = 0.0_real64
        end if
      end do
    end do
  end subroutine identity_mat

  !> _mat_mul(a, b): apply b first, then a.  Summation order
  !! matches the Python expression exactly.
  subroutine mat_mul(a, b, c)
    real(real64), intent(in) :: a(4, 4), b(4, 4)
    real(real64), intent(out) :: c(4, 4)
    integer :: row, col
    do col = 1, 4
      do row = 1, 4
        c(row, col) = a(row, 1) * b(1, col) + a(row, 2) * b(2, col) &
             + a(row, 3) * b(3, col) + a(row, 4) * b(4, col)
      end do
    end do
  end subroutine mat_mul

  !> _mat_apply.
  subroutine mat_apply(m, x, y, z, ox, oy, oz)
    real(real64), intent(in) :: m(4, 4), x, y, z
    real(real64), intent(out) :: ox, oy, oz
    real(real64) :: o(4)
    integer :: row
    do row = 1, 4
      o(row) = m(row, 1) * x + m(row, 2) * y + m(row, 3) * z + &
           m(row, 4)
    end do
    if (o(4) /= 0.0_real64 .and. o(4) /= 1.0_real64) then
      ox = o(1) / o(4)
      oy = o(2) / o(4)
      oz = o(3) / o(4)
    else
      ox = o(1)
      oy = o(2)
      oz = o(3)
    end if
  end subroutine mat_apply

  !> _node_local_matrix: column-major 'matrix', or TRS.
  subroutine node_local_matrix(node, index, m)
    type(dyn), intent(in) :: node
    integer(int64), intent(in) :: index
    real(real64), intent(out) :: m(4, 4)
    type(dyn) :: raw, v, def
    real(real64) :: vals(16), t(3), q(4), sc(3)
    real(real64) :: norm, s, xx, yy, zz, xy, xz, yz, wx, wy, wz
    real(real64) :: rot(3, 3)
    integer :: k, row, col
    character(16) :: keys(3)
    integer :: wants(3)
    call identity_mat(m)
    if (dyn_dict_has(node, "matrix")) then
      raw = dyn_dict_get(node, "matrix")
      if (raw%kind /= DYN_K_NULL) then
        if (raw%kind /= DYN_K_LIST .or. raw%n_items /= 16) then
          call fail("node " // trim(fmt_int(index)) // &
               " 'matrix' must be 16 numbers (column-major)")
          return
        end if
        do k = 1, 16
          if (.not. is_number(raw%items(k))) then
            call fail("node " // trim(fmt_int(index)) // &
                 " 'matrix' must be 16 numbers (column-major)")
            return
          end if
          vals(k) = as_real(raw%items(k))
        end do
        ! Column-major input -> (row, col) storage:
        ! m(row, col) == vals[col * 4 + row] (0-based Python).
        do col = 1, 4
          do row = 1, 4
            m(row, col) = vals((col - 1) * 4 + row)
          end do
        end do
        return
      end if
    end if
    keys = [character(16) :: "translation", "rotation", "scale"]
    wants = [3, 4, 3]
    do k = 1, 3
      def = dyn_list()
      block
        integer :: c
        real(real64) :: dv(4)
        dv = 0.0_real64
        if (k == 2) dv(4) = 1.0_real64
        if (k == 3) dv = 1.0_real64
        do c = 1, wants(k)
          call dyn_list_push(def, dyn_real(dv(c)))
        end do
      end block
      v = dict_get_or(node, trim(keys(k)), def)
      if (v%kind /= DYN_K_LIST .or. v%n_items /= wants(k)) then
        call fail("node " // trim(fmt_int(index)) // " " // &
             repr_str(trim(keys(k))) // " must be " // &
             trim(fmt_int(int(wants(k), int64))) // " numbers")
        return
      end if
      block
        integer :: c
        do c = 1, wants(k)
          if (.not. is_number(v%items(c))) then
            call fail("node " // trim(fmt_int(index)) // " " // &
                 repr_str(trim(keys(k))) // " must be " // &
                 trim(fmt_int(int(wants(k), int64))) // " numbers")
            return
          end if
        end do
        select case (k)
        case (1)
          do c = 1, 3
            t(c) = as_real(v%items(c))
          end do
        case (2)
          do c = 1, 4
            q(c) = as_real(v%items(c))
          end do
        case (3)
          do c = 1, 3
            sc(c) = as_real(v%items(c))
          end do
        end select
      end block
    end do
    ! Rotation matrix from a (possibly unnormalised) quaternion.
    norm = q(1) * q(1) + q(2) * q(2) + q(3) * q(3) + q(4) * q(4)
    if (norm == 0.0_real64) then
      call fail("node " // trim(fmt_int(index)) // &
           " rotation quaternion has zero length")
      return
    end if
    s = 2.0_real64 / norm
    xx = q(1) * q(1) * s
    yy = q(2) * q(2) * s
    zz = q(3) * q(3) * s
    xy = q(1) * q(2) * s
    xz = q(1) * q(3) * s
    yz = q(2) * q(3) * s
    wx = q(4) * q(1) * s
    wy = q(4) * q(2) * s
    wz = q(4) * q(3) * s
    rot(1, 1) = 1.0_real64 - (yy + zz)
    rot(1, 2) = xy - wz
    rot(1, 3) = xz + wy
    rot(2, 1) = xy + wz
    rot(2, 2) = 1.0_real64 - (xx + zz)
    rot(2, 3) = yz - wx
    rot(3, 1) = xz - wy
    rot(3, 2) = yz + wx
    rot(3, 3) = 1.0_real64 - (xx + yy)
    ! Local = T * R * S.
    do row = 1, 3
      do col = 1, 3
        m(row, col) = rot(row, col) * sc(col)
      end do
      m(row, 4) = t(row)
    end do
    m(4, :) = [0.0_real64, 0.0_real64, 0.0_real64, 1.0_real64]
  end subroutine node_local_matrix

  ! ==================================================================
  ! Accessors (_read_accessor)
  ! ==================================================================

  !> Component table lookup: size in bytes, 0 when unsupported.
  pure integer function comp_size(comp)
    integer, intent(in) :: comp
    select case (comp)
    case (5120, 5121)
      comp_size = 1
    case (5122, 5123)
      comp_size = 2
    case (5125, 5126)
      comp_size = 4
    case default
      comp_size = 0
    end select
  end function comp_size

  !> Accessor type table: component count, 0 when unsupported.
  pure integer function type_ncomp(name)
    character(*), intent(in) :: name
    select case (name)
    case ("SCALAR")
      type_ncomp = 1
    case ("VEC2")
      type_ncomp = 2
    case ("VEC3")
      type_ncomp = 3
    case ("VEC4", "MAT2")
      type_ncomp = 4
    case ("MAT3")
      type_ncomp = 9
    case ("MAT4")
      type_ncomp = 16
    case default
      type_ncomp = 0
    end select
  end function type_ncomp

  !> One little-endian component at 0-based byte offset pos0.
  subroutine read_comp(data, pos0, comp, ival, rval)
    character(*), intent(in) :: data
    integer(int64), intent(in) :: pos0
    integer, intent(in) :: comp
    integer(int64), intent(out) :: ival
    real(real64), intent(out) :: rval
    integer(int64) :: u
    integer(int32) :: bits32
    integer :: p
    ival = 0_int64
    rval = 0.0_real64
    p = int(pos0)
    u = iachar(data(p + 1:p + 1))
    select case (comp)
    case (5120)
      if (u >= 128_int64) u = u - 256_int64
      ival = u
    case (5121)
      ival = u
    case (5122)
      u = u + 256_int64 * iachar(data(p + 2:p + 2))
      if (u >= 32768_int64) u = u - 65536_int64
      ival = u
    case (5123)
      ival = u + 256_int64 * iachar(data(p + 2:p + 2))
    case (5125)
      ival = u + 256_int64 * iachar(data(p + 2:p + 2)) + &
           65536_int64 * iachar(data(p + 3:p + 3)) + &
           16777216_int64 * iachar(data(p + 4:p + 4))
    case (5126)
      u = u + 256_int64 * iachar(data(p + 2:p + 2)) + &
           65536_int64 * iachar(data(p + 3:p + 3)) + &
           16777216_int64 * iachar(data(p + 4:p + 4))
      if (u >= 2147483648_int64) u = u - 4294967296_int64
      bits32 = int(u, int32)
      rval = real(transfer(bits32, 0.0_real32), real64)
    end select
  end subroutine read_comp

  !> Validate one offset field of _read_accessor's triple check.
  !! Python: value is not None and (not _is_int or < 0) -> fail.
  !! null_means_none mirrors byteLength (absent or null both give
  !! Python None); for the byteOffset fields a present-but-null
  !! value crashes Python with a TypeError downstream -- the port
  !! reports it with this message instead (see port report).
  subroutine check_offset(v, has_key, null_means_none, keyname, &
       out, is_none)
    type(dyn), intent(in) :: v
    logical, intent(in) :: has_key, null_means_none
    character(*), intent(in) :: keyname
    integer(int64), intent(out) :: out
    logical, intent(out) :: is_none
    out = 0_int64
    is_none = .false.
    if (.not. has_key) then
      is_none = null_means_none
      return
    end if
    if (v%kind == DYN_K_NULL) then
      if (null_means_none) then
        is_none = .true.
      else
        call fail(keyname // " must be a non-negative integer")
      end if
      return
    end if
    if (.not. is_int(v) .or. v%i < 0_int64) then
      call fail(keyname // " must be a non-negative integer")
      return
    end if
    out = v%i
  end subroutine check_offset

  !> _read_accessor(doc, buffers, index, what).
  subroutine read_accessor(ctx, index_v, what, res)
    type(load_ctx), intent(in) :: ctx
    type(dyn), intent(in) :: index_v
    character(*), intent(in) :: what
    type(acc_result), intent(out) :: res
    type(dyn) :: accessors, accessor, views, view, bv, cv, tv, nv
    type(dyn) :: vov, vlv, aov, strv, bufv
    integer(int64) :: aidx, vidx, bidx
    integer :: csize, ncomp
    integer(int64) :: count, view_offset, view_length, acc_offset
    integer(int64) :: element_size, stride, needed, base, i
    logical :: vl_none, dummy_none
    character(:), allocatable :: data
    res%comp_type = 0
    res%ncomp = 0
    res%count = 0_int64
    call require_list(ctx%doc, "accessors", .true., accessors)
    if (g_failed) return
    call require_index(index_v, dyn_list_len(accessors), &
         what // " accessor", aidx)
    if (g_failed) return
    accessor = dyn_list_at(accessors, int(aidx) + 1)
    if (accessor%kind /= DYN_K_DICT) then
      call fail(what // " accessor " // trim(fmt_int(aidx)) // &
           " must be an object")
      return
    end if
    if (dyn_dict_has(accessor, "sparse")) then
      call fail(what // " accessor " // trim(fmt_int(aidx)) // &
           " uses sparse storage, which is not supported")
      return
    end if
    if (.not. dyn_dict_has(accessor, "bufferView")) then
      call fail(what // " accessor " // trim(fmt_int(aidx)) // &
           " has no 'bufferView'")
      return
    end if
    call require_list(ctx%doc, "bufferViews", .true., views)
    if (g_failed) return
    bv = dyn_dict_get(accessor, "bufferView")
    call require_index(bv, dyn_list_len(views), "bufferView", vidx)
    if (g_failed) return
    view = dyn_list_at(views, int(vidx) + 1)
    if (view%kind /= DYN_K_DICT) then
      call fail("bufferView " // trim(fmt_int(vidx)) // &
           " must be an object")
      return
    end if
    bufv = dict_get_or(view, "buffer", dyn_int(0_int64))
    call require_index(bufv, size(ctx%buffers), "buffer", bidx)
    if (g_failed) return
    data = ctx%buffers(int(bidx) + 1)%data
    cv = dyn_dict_get(accessor, "componentType")
    res%comp_type = 0
    if (cv%kind == DYN_K_INT) then
      if (comp_size(int(cv%i)) > 0) res%comp_type = int(cv%i)
    else if (cv%kind == DYN_K_REAL) then
      if (cv%r == floor(cv%r) .and. abs(cv%r) < 1.0e9_real64) then
        if (comp_size(int(cv%r)) > 0) res%comp_type = int(cv%r)
      end if
    end if
    if (res%comp_type == 0) then
      call fail(what // " accessor " // trim(fmt_int(aidx)) // &
           " has unsupported componentType " // repr_dyn(cv))
      return
    end if
    csize = comp_size(res%comp_type)
    tv = dyn_dict_get(accessor, "type")
    ncomp = 0
    if (tv%kind == DYN_K_STR) then
      if (allocated(tv%s)) ncomp = type_ncomp(tv%s)
    end if
    if (ncomp == 0) then
      call fail(what // " accessor " // trim(fmt_int(aidx)) // &
           " has unsupported type " // repr_dyn(tv))
      return
    end if
    res%ncomp = ncomp
    nv = dyn_dict_get(accessor, "count")
    if (.not. is_int(nv) .or. nv%i < 0_int64) then
      call fail(what // " accessor " // trim(fmt_int(aidx)) // &
           " 'count' must be a non-negative integer")
      return
    end if
    count = nv%i
    res%count = count
    ! Offset triple check, in the Python order.
    vov = dyn_dict_get(view, "byteOffset")
    call check_offset(vov, dyn_dict_has(view, "byteOffset"), &
         .false., "bufferView byteOffset", view_offset, dummy_none)
    if (g_failed) return
    vlv = dyn_dict_get(view, "byteLength")
    call check_offset(vlv, dyn_dict_has(view, "byteLength"), &
         .true., "bufferView byteLength", view_length, vl_none)
    if (g_failed) return
    aov = dyn_dict_get(accessor, "byteOffset")
    call check_offset(aov, dyn_dict_has(accessor, "byteOffset"), &
         .false., "accessor byteOffset", acc_offset, dummy_none)
    if (g_failed) return
    if (vl_none) view_length = int(len(data), int64) - view_offset
    if (view_offset + view_length > int(len(data), int64)) then
      call fail("bufferView " // trim(fmt_int(vidx)) // &
           " extends past its buffer (" // &
           trim(fmt_int(view_offset)) // " + " // &
           trim(fmt_int(view_length)) // " > " // &
           trim(fmt_int(int(len(data), int64))) // ")")
      return
    end if
    element_size = int(csize, int64) * int(ncomp, int64)
    strv = dyn_dict_get(view, "byteStride")
    if (strv%kind == DYN_K_NULL) then
      stride = element_size
    else if (.not. is_int(strv) .or. strv%i < element_size) then
      call fail("bufferView " // trim(fmt_int(vidx)) // &
           " byteStride " // repr_dyn(strv) // &
           " is smaller than one element (" // &
           trim(fmt_int(element_size)) // " bytes)")
      return
    else
      stride = strv%i
    end if
    if (count > 0_int64) then
      needed = acc_offset + (count - 1_int64) * stride + element_size
      if (needed > view_length) then
        call fail(what // " accessor " // trim(fmt_int(aidx)) // &
             " declares " // trim(fmt_int(count)) // &
             " elements but its bufferView holds only " // &
             trim(fmt_int(view_length)) // " bytes (needs " // &
             trim(fmt_int(needed)) // ")")
        return
      end if
    end if
    base = view_offset + acc_offset
    if (res%comp_type == 5126) then
      allocate (res%rvals(count * ncomp))
    else
      allocate (res%ivals(count * ncomp))
    end if
    block
      integer(int64) :: ei, ci, off, dummy_i
      real(real64) :: dummy_r
      integer :: slot
      do ei = 0, count - 1
        do ci = 0, int(ncomp, int64) - 1
          off = base + ei * stride + ci * int(csize, int64)
          slot = int(ei * ncomp + ci) + 1
          if (res%comp_type == 5126) then
            call read_comp(data, off, res%comp_type, dummy_i, &
                 res%rvals(slot))
          else
            call read_comp(data, off, res%comp_type, &
                 res%ivals(slot), dummy_r)
          end if
        end do
      end do
    end block
  end subroutine read_accessor

  ! ==================================================================
  ! Colours (_material_colour, _read_vertex_colours,
  ! _average_colour)
  ! ==================================================================

  !> _material_colour: primitive material baseColorFactor, else
  !! white.
  subroutine material_colour(ctx, primitive, rgb)
    type(load_ctx), intent(in) :: ctx
    type(dyn), intent(in) :: primitive
    integer(int64), intent(out) :: rgb(3)
    type(dyn) :: matv, mats, material, pbr, factor
    integer(int64) :: midx
    integer :: c
    rgb = [255_int64, 255_int64, 255_int64]
    matv = dyn_dict_get(primitive, "material")
    if (matv%kind == DYN_K_NULL) return
    call require_list(ctx%doc, "materials", .false., mats)
    if (g_failed) return
    call require_index(matv, dyn_list_len(mats), "material", midx)
    if (g_failed) return
    material = dyn_list_at(mats, int(midx) + 1)
    if (material%kind /= DYN_K_DICT) then
      call fail("material " // trim(fmt_int(midx)) // &
           " must be an object")
      return
    end if
    pbr = dyn_dict_get(material, "pbrMetallicRoughness")
    if (pbr%kind == DYN_K_NULL) return
    if (pbr%kind /= DYN_K_DICT) then
      call fail("material " // trim(fmt_int(midx)) // &
           " 'pbrMetallicRoughness' must be an object")
      return
    end if
    factor = dyn_dict_get(pbr, "baseColorFactor")
    if (factor%kind == DYN_K_NULL) return
    if (factor%kind /= DYN_K_LIST .or. &
         (factor%n_items /= 3 .and. factor%n_items /= 4)) then
      call fail("material " // trim(fmt_int(midx)) // &
           " 'baseColorFactor' must be 3 or 4 numbers")
      return
    end if
    do c = 1, factor%n_items
      if (.not. is_number(factor%items(c))) then
        call fail("material " // trim(fmt_int(midx)) // &
             " 'baseColorFactor' must be 3 or 4 numbers")
        return
      end if
    end do
    do c = 1, 3
      rgb(c) = to_byte(as_real(factor%items(c)))
    end do
  end subroutine material_colour

  !> _read_vertex_colours: COLOR_0 as (count, 3) reals in 0..1.
  subroutine read_vertex_colours(ctx, index_v, colours, nrows)
    type(load_ctx), intent(in) :: ctx
    type(dyn), intent(in) :: index_v
    real(real64), allocatable, intent(out) :: colours(:, :)
    integer(int64), intent(out) :: nrows
    type(dyn) :: accessors, accessor, cv, tv
    type(acc_result) :: res
    integer(int64) :: aidx, ei
    integer :: ci
    nrows = 0_int64
    allocate (colours(0, 3))
    call require_list(ctx%doc, "accessors", .true., accessors)
    if (g_failed) return
    call require_index(index_v, dyn_list_len(accessors), &
         "COLOR_0 accessor", aidx)
    if (g_failed) return
    accessor = dyn_list_at(accessors, int(aidx) + 1)
    if (accessor%kind /= DYN_K_DICT) then
      call fail("COLOR_0 accessor " // trim(fmt_int(aidx)) // &
           " must be an object")
      return
    end if
    cv = dyn_dict_get(accessor, "componentType")
    tv = dyn_dict_get(accessor, "type")
    if (tv%kind /= DYN_K_STR .or. .not. allocated(tv%s)) then
      call fail("COLOR_0 accessor " // trim(fmt_int(aidx)) // &
           " must be VEC3 or VEC4, got " // repr_dyn(tv))
      return
    end if
    if (tv%s /= "VEC3" .and. tv%s /= "VEC4") then
      call fail("COLOR_0 accessor " // trim(fmt_int(aidx)) // &
           " must be VEC3 or VEC4, got " // repr_dyn(tv))
      return
    end if
    call read_accessor(ctx, index_v, "COLOR_0", res)
    if (g_failed) return
    nrows = res%count
    deallocate (colours)
    allocate (colours(nrows, 3))
    if (res%comp_type == 5126) then
      do ei = 1, nrows
        do ci = 1, 3
          colours(ei, ci) = clamp01( &
               res%rvals((ei - 1) * res%ncomp + ci))
        end do
      end do
    else if (res%comp_type == 5121) then
      do ei = 1, nrows
        do ci = 1, 3
          colours(ei, ci) = real( &
               res%ivals((ei - 1) * res%ncomp + ci), real64) / &
               255.0_real64
        end do
      end do
    else if (res%comp_type == 5123) then
      do ei = 1, nrows
        do ci = 1, 3
          colours(ei, ci) = real( &
               res%ivals((ei - 1) * res%ncomp + ci), real64) / &
               65535.0_real64
        end do
      end do
    else
      call fail("COLOR_0 accessor " // trim(fmt_int(aidx)) // &
           " has unsupported componentType " // repr_dyn(cv) // &
           " (expected float, uint8 or uint16)")
      return
    end if
  end subroutine read_vertex_colours

  !> _average_colour: average three 0..1 colours to RGB 0..255.
  subroutine average_colour(vcolours, i1, i2, i3, rgb)
    real(real64), intent(in) :: vcolours(:, :)
    integer(int64), intent(in) :: i1, i2, i3
    integer(int64), intent(out) :: rgb(3)
    integer :: ch
    do ch = 1, 3
      rgb(ch) = py_round( &
           (vcolours(i1, ch) + vcolours(i2, ch) + &
            vcolours(i3, ch)) / 3.0_real64 * 255.0_real64)
    end do
  end subroutine average_colour

  ! ==================================================================
  ! Primitives (_primitive_triangles) and meshes (add_mesh)
  ! ==================================================================

  !> _primitive_triangles: world-space triangles for one
  !! primitive, appended to new_tris (a dyn list).
  subroutine primitive_triangles(ctx, primitive, mesh_index, &
       prim_index, world, new_tris)
    type(load_ctx), intent(in) :: ctx
    type(dyn), intent(in) :: primitive
    integer(int64), intent(in) :: mesh_index, prim_index
    real(real64), intent(in) :: world(4, 4)
    type(dyn), intent(inout) :: new_tris
    type(dyn) :: modev, attributes, posv, posacc, accessors
    type(dyn) :: idxv, idxdef, colv
    type(acc_result) :: res, ires
    real(real64), allocatable :: positions(:, :), vcolours(:, :)
    integer(int64), allocatable :: indices(:)
    integer(int64) :: npos, iidx, ncol
    integer(int64) :: flat_rgb(3), rgb(3)
    logical :: has_col
    integer(int64) :: s, vi, vindex
    real(real64) :: wv(3, 3), tmp3
    if (primitive%kind /= DYN_K_DICT) then
      call fail("mesh " // trim(fmt_int(mesh_index)) // &
           " primitive " // trim(fmt_int(prim_index)) // &
           " must be an object")
      return
    end if
    modev = dict_get_or(primitive, "mode", dyn_int(4_int64))
    if (.not. num_eq_int(modev, 4_int64)) then
      call fail("mesh " // trim(fmt_int(mesh_index)) // &
           " primitive " // trim(fmt_int(prim_index)) // &
           " has mode " // repr_dyn(modev) // &
           "; only mode 4 (TRIANGLES) is supported")
      return
    end if
    attributes = dyn_dict_get(primitive, "attributes")
    if (attributes%kind /= DYN_K_DICT) then
      call fail("mesh " // trim(fmt_int(mesh_index)) // &
           " primitive " // trim(fmt_int(prim_index)) // &
           " has no 'attributes' object")
      return
    end if
    if (.not. dyn_dict_has(attributes, "POSITION")) then
      call fail("mesh " // trim(fmt_int(mesh_index)) // &
           " primitive " // trim(fmt_int(prim_index)) // &
           " has no POSITION attribute")
      return
    end if
    posv = dyn_dict_get(attributes, "POSITION")
    call read_accessor(ctx, posv, "POSITION", res)
    if (g_failed) return
    npos = res%count
    allocate (positions(npos, 3))
    if (res%ncomp /= 3 .and. npos > 0_int64) then
      call fail("POSITION accessor must be VEC3")
      return
    end if
    block
      integer(int64) :: ei
      integer :: ci
      do ei = 1, npos
        do ci = 1, 3
          if (res%comp_type == 5126) then
            positions(ei, ci) = res%rvals((ei - 1) * res%ncomp + ci)
          else
            positions(ei, ci) = real( &
                 res%ivals((ei - 1) * res%ncomp + ci), real64)
          end if
        end do
      end do
    end block
    call require_list(ctx%doc, "accessors", .true., accessors)
    if (g_failed) return
    posacc = dyn_list_at(accessors, int(posv%i) + 1)
    if (posacc%kind == DYN_K_DICT) then
      block
        type(dyn) :: tv2, cv2
        tv2 = dyn_dict_get(posacc, "type")
        if (.not. (tv2%kind == DYN_K_STR .and. allocated(tv2%s) &
             .and. tv2%s == "VEC3")) then
          call fail("POSITION accessor must be VEC3, got " // &
               repr_dyn(tv2))
          return
        end if
        cv2 = dyn_dict_get(posacc, "componentType")
        if (.not. num_eq_int(cv2, 5126_int64)) then
          call fail("POSITION accessor must be float32 " // &
               "(componentType 5126), got " // repr_dyn(cv2))
          return
        end if
      end block
    end if
    ! Indices (or sequential order).
    if (dyn_dict_has(primitive, "indices")) then
      idxv = dyn_dict_get(primitive, "indices")
    else
      idxv = dyn_null()
    end if
    if (idxv%kind /= DYN_K_NULL) then
      call require_index(idxv, dyn_list_len(accessors), &
           "indices accessor", iidx)
      if (g_failed) return
      idxdef = dyn_list_at(accessors, int(iidx) + 1)
      block
        logical :: okdef
        type(dyn) :: cv3, tv3
        okdef = idxdef%kind == DYN_K_DICT
        if (okdef) then
          cv3 = dyn_dict_get(idxdef, "componentType")
          tv3 = dyn_dict_get(idxdef, "type")
          okdef = (num_eq_int(cv3, 5121_int64) .or. &
               num_eq_int(cv3, 5123_int64) .or. &
               num_eq_int(cv3, 5125_int64)) .and. &
               tv3%kind == DYN_K_STR .and. allocated(tv3%s) .and. &
               tv3%s == "SCALAR"
        end if
        if (.not. okdef) then
          call fail("indices accessor " // trim(fmt_int(iidx)) // &
               " must be SCALAR with componentType 5121, 5123 " // &
               "or 5125")
          return
        end if
      end block
      call read_accessor(ctx, idxv, "indices", ires)
      if (g_failed) return
      allocate (indices(ires%count))
      block
        integer(int64) :: ei
        do ei = 1, ires%count
          indices(ei) = ires%ivals((ei - 1) * ires%ncomp + 1)
        end do
      end block
      if (mod(size(indices), 3) /= 0) then
        call fail("mesh " // trim(fmt_int(mesh_index)) // &
             " primitive " // trim(fmt_int(prim_index)) // &
             " index count " // &
             trim(fmt_int(int(size(indices), int64))) // &
             " is not a multiple of 3")
        return
      end if
    else
      if (mod(npos, 3_int64) /= 0_int64) then
        call fail("mesh " // trim(fmt_int(mesh_index)) // &
             " primitive " // trim(fmt_int(prim_index)) // &
             " has " // trim(fmt_int(npos)) // &
             " non-indexed vertices, not a multiple of 3")
        return
      end if
      allocate (indices(npos))
      block
        integer(int64) :: ei
        do ei = 1, npos
          indices(ei) = ei - 1
        end do
      end block
    end if
    ! Colours: per-vertex COLOR_0, else the material colour.
    has_col = .false.
    if (dyn_dict_has(attributes, "COLOR_0")) then
      colv = dyn_dict_get(attributes, "COLOR_0")
      if (colv%kind /= DYN_K_NULL) has_col = .true.
    end if
    flat_rgb = [255_int64, 255_int64, 255_int64]
    if (has_col) then
      call read_vertex_colours(ctx, colv, vcolours, ncol)
      if (g_failed) return
      if (ncol /= npos) then
        call fail("mesh " // trim(fmt_int(mesh_index)) // &
             " primitive " // trim(fmt_int(prim_index)) // &
             " COLOR_0 count " // trim(fmt_int(ncol)) // &
             " does not match POSITION count " // &
             trim(fmt_int(npos)))
        return
      end if
    else
      call material_colour(ctx, primitive, flat_rgb)
      if (g_failed) return
    end if
    ! Triangle assembly (winding swap v2 <-> v3, see header).
    do s = 0, size(indices) - 1, 3
      block
        integer(int64) :: ti(3)
        type(dyn) :: tri, cold, vertl, vlist
        integer :: a, b
        ti = [indices(s + 1), indices(s + 2), indices(s + 3)]
        do a = 1, 3
          if (ti(a) < 0_int64 .or. ti(a) >= npos) then
            call fail("mesh " // trim(fmt_int(mesh_index)) // &
                 " primitive " // trim(fmt_int(prim_index)) // &
                 " references vertex " // trim(fmt_int(ti(a))) // &
                 " but POSITION has only " // trim(fmt_int(npos)) // &
                 " vertices")
            return
          end if
        end do
        do a = 1, 3
          vi = ti(a) + 1
          call mat_apply(world, positions(vi, 1), positions(vi, 2), &
               positions(vi, 3), wv(a, 1), wv(a, 2), wv(a, 3))
        end do
        ! (v1, v3, v2)
        do b = 1, 3
          tmp3 = wv(2, b)
          wv(2, b) = wv(3, b)
          wv(3, b) = tmp3
        end do
        if (has_col) then
          call average_colour(vcolours, ti(1) + 1, ti(2) + 1, &
               ti(3) + 1, rgb)
        else
          rgb = flat_rgb
        end if
        cold = dyn_list()
        do b = 1, 3
          call dyn_list_push(cold, dyn_int(rgb(b)))
        end do
        vertl = dyn_list()
        do a = 1, 3
          vlist = dyn_list()
          do b = 1, 3
            call dyn_list_push(vlist, dyn_real(wv(a, b)))
          end do
          call dyn_list_push(vertl, vlist)
        end do
        tri = dyn_list()
        call dyn_list_push(tri, cold)
        call dyn_list_push(tri, vertl)
        call dyn_list_push(new_tris, tri)
      end block
    end do
  end subroutine primitive_triangles

  !> add_mesh (the load_gltf closure): every primitive of one
  !! mesh, with the running triangle-limit check.
  subroutine add_mesh(ctx, mesh_index_v, world)
    type(load_ctx), intent(inout) :: ctx
    type(dyn), intent(in) :: mesh_index_v
    real(real64), intent(in) :: world(4, 4)
    type(dyn) :: mesh, prims, new_tris
    integer(int64) :: midx
    integer :: pi, k
    call require_index(mesh_index_v, dyn_list_len(ctx%meshes), &
         "mesh", midx)
    if (g_failed) return
    mesh = dyn_list_at(ctx%meshes, int(midx) + 1)
    if (mesh%kind /= DYN_K_DICT) then
      call fail("mesh " // trim(fmt_int(midx)) // &
           " must be an object")
      return
    end if
    prims = dyn_dict_get(mesh, "primitives")
    if (prims%kind /= DYN_K_LIST .or. prims%n_items == 0) then
      call fail("mesh " // trim(fmt_int(midx)) // &
           " has no 'primitives' array")
      return
    end if
    do pi = 1, prims%n_items
      new_tris = dyn_list()
      call primitive_triangles(ctx, dyn_list_at(prims, pi), midx, &
           int(pi - 1, int64), world, new_tris)
      if (g_failed) return
      if (int(dyn_list_len(ctx%triangles), int64) + &
           int(dyn_list_len(new_tris), int64) > GLTF_MAX_TRIANGLES) &
           then
        call fail("glTF file " // ctx%path // &
             " exceeds the " // trim(fmt_int(GLTF_MAX_TRIANGLES)) // &
             " triangle limit")
        return
      end if
      do k = 1, dyn_list_len(new_tris)
        call dyn_list_push(ctx%triangles, dyn_list_at(new_tris, k))
      end do
    end do
  end subroutine add_mesh

  !> visit (the load_gltf closure): node-graph walk with the
  !! path-set cycle check (on_path mirrors the Python stack set).
  recursive subroutine visit_node(ctx, node_index_v, parent_world, &
       on_path)
    type(load_ctx), intent(inout) :: ctx
    type(dyn), intent(in) :: node_index_v
    real(real64), intent(in) :: parent_world(4, 4)
    logical, intent(inout) :: on_path(:)
    type(dyn) :: node, children, meshv
    integer(int64) :: nidx
    real(real64) :: local(4, 4), world(4, 4)
    integer :: k
    call require_index(node_index_v, dyn_list_len(ctx%nodes), &
         "node", nidx)
    if (g_failed) return
    if (on_path(int(nidx) + 1)) then
      call fail("node graph contains a cycle at node " // &
           trim(fmt_int(nidx)))
      return
    end if
    node = dyn_list_at(ctx%nodes, int(nidx) + 1)
    if (node%kind /= DYN_K_DICT) then
      call fail("node " // trim(fmt_int(nidx)) // &
           " must be an object")
      return
    end if
    call node_local_matrix(node, nidx, local)
    if (g_failed) return
    call mat_mul(parent_world, local, world)
    if (dyn_dict_has(node, "mesh")) then
      meshv = dyn_dict_get(node, "mesh")
      if (meshv%kind /= DYN_K_NULL) then
        call add_mesh(ctx, meshv, world)
        if (g_failed) return
      end if
    end if
    children = dict_get_or(node, "children", dyn_list())
    if (children%kind == DYN_K_NULL) children = dyn_list()
    if (children%kind /= DYN_K_LIST) then
      call fail("node " // trim(fmt_int(nidx)) // &
           " 'children' must be an array")
      return
    end if
    on_path(int(nidx) + 1) = .true.
    do k = 1, children%n_items
      call visit_node(ctx, children%items(k), world, on_path)
      if (g_failed) return
    end do
    on_path(int(nidx) + 1) = .false.
  end subroutine visit_node

  ! ==================================================================
  ! Parsing (_parse_glb, _parse_gltf_json, _check_asset)
  ! ==================================================================

  !> Little-endian uint32 at 0-based byte offset off0 of s.
  function u32le(s, off0) result(v)
    character(*), intent(in) :: s
    integer(int64), intent(in) :: off0
    integer(int64) :: v
    integer :: p
    p = int(off0)
    v = int(iachar(s(p + 1:p + 1)), int64) + &
         256_int64 * iachar(s(p + 2:p + 2)) + &
         65536_int64 * iachar(s(p + 3:p + 3)) + &
         16777216_int64 * iachar(s(p + 4:p + 4))
  end function u32le

  !> Strip trailing characters in " \t\r\n\0" (GLB JSON padding).
  function rstrip_pad(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    integer :: n, c
    n = len(s)
    do while (n > 0)
      c = iachar(s(n:n))
      if (c == 32 .or. c == 9 .or. c == 13 .or. c == 10 .or. &
           c == 0) then
        n = n - 1
      else
        exit
      end if
    end do
    out = s(1:n)
  end function rstrip_pad

  !> _parse_glb: split GLB bytes into (json_doc, bin_or_none).
  subroutine parse_glb(raw, path, doc, glb_bin, has_bin)
    character(*), intent(in) :: raw, path
    type(dyn), intent(out) :: doc
    character(:), allocatable, intent(out) :: glb_bin
    logical, intent(out) :: has_bin
    integer(int64) :: version, total, offset, clen
    integer(int32) :: ctype
    type(dyn) :: json_doc
    logical :: json_is_none, first_chunk
    character(:), allocatable :: chunk, text, uerr, jerr
    logical :: ok_utf8, ok_json
    doc = dyn_null()
    glb_bin = ""
    has_bin = .false.
    json_doc = dyn_null()
    json_is_none = .true.
    if (len(raw) < 12) then
      call fail("GLB file " // path // " is too short (" // &
           trim(fmt_int(int(len(raw), int64))) // &
           " bytes) to hold a header")
      return
    end if
    if (raw(1:4) /= "glTF") then
      call fail("GLB file " // path // " has bad magic " // &
           repr_bytes(raw(1:4)) // " (expected b'glTF')")
      return
    end if
    version = u32le(raw, 4_int64)
    if (version /= 2_int64) then
      call fail("GLB file " // path // " has version " // &
           trim(fmt_int(version)) // &
           "; only glTF version 2 is supported")
      return
    end if
    total = u32le(raw, 8_int64)
    if (total > int(len(raw), int64)) then
      call fail("GLB file " // path // " declares " // &
           trim(fmt_int(total)) // " bytes but the file is " // &
           trim(fmt_int(int(len(raw), int64))) // " bytes")
      return
    end if
    offset = 12_int64
    first_chunk = .true.
    do while (offset < total)
      if (offset + 8_int64 > total) then
        call fail("GLB file " // path // &
             " has a truncated chunk header at byte " // &
             trim(fmt_int(offset)))
        return
      end if
      clen = u32le(raw, offset)
      ctype = int(u32le(raw, offset + 4_int64), int32)
      offset = offset + 8_int64
      if (offset + clen > total) then
        call fail("GLB file " // path // &
             " has a truncated chunk at byte " // &
             trim(fmt_int(offset - 8_int64)))
        return
      end if
      if (clen > 0_int64) then
        chunk = raw(int(offset) + 1:int(offset + clen))
      else
        chunk = ""
      end if
      offset = offset + clen
      if (first_chunk .and. ctype /= CHUNK_JSON) then
        call fail("GLB file " // path // &
             " first chunk is not the JSON chunk")
        return
      end if
      first_chunk = .false.
      if (ctype == CHUNK_JSON) then
        if (.not. json_is_none) then
          call fail("GLB file " // path // &
               " has more than one JSON chunk")
          return
        end if
        text = rstrip_pad(chunk)
        call utf8_check(text, ok_utf8, uerr)
        if (.not. ok_utf8) then
          call fail("GLB file " // path // &
               " has invalid JSON chunk: " // uerr)
          return
        end if
        call ir_json_parse(text, json_doc, ok_json)
        jerr = ""
        if (ok_json) then
          ! ir_json_parse is lenient in corners CPython rejects
          ! (e.g. leading-zero numbers); the locator's verdict
          ! wins, exactly as json.loads would have raised.
          jerr = json_error_text(text)
          if (len(jerr) > 0) ok_json = .false.
        end if
        if (.not. ok_json) then
          if (len(jerr) == 0) jerr = json_error_text(text)
          if (len(jerr) == 0) jerr = "Expecting value: line 1 " // &
               "column 1 (char 0)"
          call fail("GLB file " // path // &
               " has invalid JSON chunk: " // jerr)
          return
        end if
        json_is_none = json_doc%kind == DYN_K_NULL
      else if (ctype == CHUNK_BIN) then
        if (has_bin) then
          call fail("GLB file " // path // &
               " has more than one BIN chunk")
          return
        end if
        has_bin = .true.
        glb_bin = chunk
      end if
      ! Unknown chunk types are extension chunks: skipped.
    end do
    if (json_is_none) then
      call fail("GLB file " // path // " has no JSON chunk")
      return
    end if
    if (json_doc%kind /= DYN_K_DICT) then
      call fail("GLB file " // path // &
           " JSON chunk is not an object")
      return
    end if
    doc = json_doc
  end subroutine parse_glb

  !> _parse_gltf_json.
  subroutine parse_gltf_json(raw, path, doc)
    character(*), intent(in) :: raw, path
    type(dyn), intent(out) :: doc
    character(:), allocatable :: uerr, jerr
    logical :: ok_utf8, ok_json
    doc = dyn_null()
    call utf8_check(raw, ok_utf8, uerr)
    if (.not. ok_utf8) then
      call fail("glTF file " // path // " is not valid UTF-8: " // &
           uerr)
      return
    end if
    call ir_json_parse(raw, doc, ok_json)
    jerr = ""
    if (ok_json) then
      ! Post-scan, as in parse_glb: CPython strictness wins over
      ! ir_json_parse leniency.
      jerr = json_error_text(raw)
      if (len(jerr) > 0) ok_json = .false.
    end if
    if (.not. ok_json) then
      if (len(jerr) == 0) jerr = json_error_text(raw)
      if (len(jerr) == 0) jerr = "Expecting value: line 1 " // &
           "column 1 (char 0)"
      call fail("glTF file " // path // " is not valid JSON: " // &
           jerr)
      return
    end if
    if (doc%kind /= DYN_K_DICT) then
      call fail("glTF file " // path // &
           " JSON root is not an object")
      return
    end if
  end subroutine parse_gltf_json

  !> _check_asset.
  subroutine check_asset(doc)
    type(dyn), intent(in) :: doc
    type(dyn) :: asset, version
    asset = dyn_dict_get(doc, "asset")
    if (asset%kind == DYN_K_NULL) return
    if (asset%kind /= DYN_K_DICT) then
      call fail("glTF 'asset' must be an object")
      return
    end if
    version = dyn_dict_get(asset, "version")
    if (version%kind == DYN_K_NULL) return
    block
      character(:), allocatable :: vs
      vs = py_str_dyn(version)
      if (vs /= "2.0" .and. vs /= "2") then
        call fail("unsupported glTF asset version " // &
             repr_dyn(version) // &
             " (only 2.0 is supported)")
      end if
    end block
  end subroutine check_asset

  ! ==================================================================
  ! Public API
  ! ==================================================================

  !> load_gltf(path) -> {"triangles": [...], "count": int}.
  !! ok=.false. + errmsg (the GltfError text) on any unsupported
  !! or malformed input, mirroring the Python raise.
  subroutine load_gltf(path, data, ok, errmsg)
    character(*), intent(in) :: path
    type(dyn), intent(out) :: data
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: errmsg
    type(load_ctx) :: ctx
    character(:), allocatable :: lpath, suffix, raw, base_dir
    character(:), allocatable :: glb_bin
    logical :: has_bin
    type(dyn) :: scenes, scene, roots_v
    integer(int64) :: sidx
    integer :: k
    g_failed = .false.
    g_errmsg = ""
    data = dyn_null()
    ok = .false.
    errmsg = ""
    lpath = path
    ctx%path = lpath
    suffix = py_suffix(lpath)
    if (suffix /= ".gltf" .and. suffix /= ".glb") then
      block
        character(:), allocatable :: shown
        if (len(suffix) == 0) then
          shown = "(none)"
        else
          shown = suffix
        end if
        call fail("unsupported file extension " // &
             repr_str(shown) // " for " // lpath // &
             ": only .gltf and .glb are supported")
      end block
      errmsg = g_errmsg
      return
    end if
    call read_top_file(lpath, raw)
    if (g_failed) then
      errmsg = g_errmsg
      return
    end if
    base_dir = py_dirname(py_abspath(lpath))
    has_bin = .false.
    glb_bin = ""
    if (suffix == ".glb") then
      call parse_glb(raw, lpath, ctx%doc, glb_bin, has_bin)
    else
      call parse_gltf_json(raw, lpath, ctx%doc)
    end if
    if (g_failed) then
      errmsg = g_errmsg
      return
    end if
    call check_asset(ctx%doc)
    if (g_failed) then
      errmsg = g_errmsg
      return
    end if
    call resolve_buffers(ctx, base_dir, glb_bin, has_bin)
    if (g_failed) then
      errmsg = g_errmsg
      return
    end if
    call require_list(ctx%doc, "meshes", .true., ctx%meshes)
    if (g_failed) then
      errmsg = g_errmsg
      return
    end if
    if (dyn_list_len(ctx%meshes) == 0) then
      call fail("glTF file " // lpath // " contains no meshes")
      errmsg = g_errmsg
      return
    end if
    call require_list(ctx%doc, "nodes", .false., ctx%nodes)
    if (g_failed) then
      errmsg = g_errmsg
      return
    end if
    ctx%triangles = dyn_list()
    if (dyn_list_len(ctx%nodes) > 0) then
      call require_list(ctx%doc, "scenes", .false., scenes)
      if (g_failed) then
        errmsg = g_errmsg
        return
      end if
      if (dyn_list_len(scenes) > 0) then
        block
          type(dyn) :: sidx_v
          sidx_v = dict_get_or(ctx%doc, "scene", dyn_int(0_int64))
          call require_index(sidx_v, dyn_list_len(scenes), &
               "scene", sidx)
          if (g_failed) then
            errmsg = g_errmsg
            return
          end if
          scene = dyn_list_at(scenes, int(sidx) + 1)
          if (scene%kind /= DYN_K_DICT) then
            call fail("scene " // trim(fmt_int(sidx)) // &
                 " must be an object")
            errmsg = g_errmsg
            return
          end if
          roots_v = dict_get_or(scene, "nodes", dyn_list())
          if (roots_v%kind /= DYN_K_LIST) then
            call fail("scene " // trim(fmt_int(sidx)) // &
                 " 'nodes' must be an array")
            errmsg = g_errmsg
            return
          end if
          block
            logical, allocatable :: on_path(:)
            real(real64) :: ident(4, 4)
            integer :: r
            allocate (on_path(dyn_list_len(ctx%nodes)))
            on_path = .false.
            call identity_mat(ident)
            do r = 1, roots_v%n_items
              if (.not. is_int(roots_v%items(r))) then
                call fail("scene node reference " // &
                     repr_dyn(roots_v%items(r)) // &
                     " is not an integer")
                exit
              end if
              call visit_node(ctx, roots_v%items(r), ident, &
                   on_path)
              if (g_failed) exit
            end do
          end block
        end block
        if (g_failed) then
          errmsg = g_errmsg
          return
        end if
      else
        ! No scene table: every node that is nobody's child is a
        ! root.
        block
          logical, allocatable :: is_child(:), on_path(:)
          real(real64) :: ident(4, 4)
          integer :: nn, r, c
          type(dyn) :: nd, ch
          nn = dyn_list_len(ctx%nodes)
          allocate (is_child(nn), on_path(nn))
          is_child = .false.
          on_path = .false.
          do r = 1, nn
            nd = dyn_list_at(ctx%nodes, r)
            if (nd%kind /= DYN_K_DICT) cycle
            ch = dyn_dict_get(nd, "children")
            if (ch%kind /= DYN_K_LIST) cycle
            do c = 1, ch%n_items
              if (is_int(ch%items(c))) then
                if (ch%items(c)%i >= 0_int64 .and. &
                     ch%items(c)%i < int(nn, int64)) &
                     is_child(int(ch%items(c)%i) + 1) = .true.
              end if
            end do
          end do
          call identity_mat(ident)
          do r = 1, nn
            if (is_child(r)) cycle
            call visit_node(ctx, dyn_int(int(r - 1, int64)), &
                 ident, on_path)
            if (g_failed) exit
          end do
        end block
        if (g_failed) then
          errmsg = g_errmsg
          return
        end if
      end if
    else
      ! No node graph at all: meshes stand alone at the origin.
      block
        real(real64) :: ident(4, 4)
        integer :: mi
        call identity_mat(ident)
        do mi = 1, dyn_list_len(ctx%meshes)
          call add_mesh(ctx, dyn_int(int(mi - 1, int64)), ident)
          if (g_failed) exit
        end do
      end block
      if (g_failed) then
        errmsg = g_errmsg
        return
      end if
    end if
    if (dyn_list_len(ctx%triangles) == 0) then
      call fail("glTF file " // lpath // " contains no triangles")
      errmsg = g_errmsg
      return
    end if
    data = dyn_dict()
    call dyn_dict_set(data, "triangles", ctx%triangles)
    call dyn_dict_set(data, "count", &
         dyn_int(int(dyn_list_len(ctx%triangles), int64)))
    ok = .true.
    errmsg = ""
  end subroutine load_gltf

  !> triangles_to_tris_lines(name, data) -> list[str], rendered
  !! into a char_list: "tris NAME COUNT" then one "tri ..." line
  !! per triangle, coordinates in %.6g (fmt_g6).
  subroutine triangles_to_tris_lines(name, data, lines, ok, errmsg)
    character(*), intent(in) :: name
    type(dyn), intent(in) :: data
    type(char_list), intent(out) :: lines
    logical, intent(out) :: ok
    character(:), allocatable, intent(out) :: errmsg
    type(dyn) :: tris, tri, cold, vertl, vtx
    integer :: i, a, b, ncoords
    integer(int64) :: rgb(3)
    real(real64) :: coords(9)
    logical :: bad
    character(:), allocatable :: line
    g_failed = .false.
    g_errmsg = ""
    ok = .false.
    errmsg = ""
    lines%n = 0
    if (allocated(lines%items)) deallocate (lines%items)
    lines%cap = 0
    if (data%kind /= DYN_K_DICT .or. &
         .not. dyn_dict_has(data, "triangles")) then
      call fail("triangles_to_tris_lines: data must be a dict " // &
           "with a 'triangles' list (as returned by load_gltf)")
      errmsg = g_errmsg
      return
    end if
    tris = dyn_dict_get(data, "triangles")
    if (tris%kind /= DYN_K_LIST) then
      call fail("triangles_to_tris_lines: 'triangles' must be " // &
           "a list")
      errmsg = g_errmsg
      return
    end if
    call char_list_append(lines, "tris " // name // " " // &
         trim(fmt_int(int(dyn_list_len(tris), int64))))
    do i = 1, tris%n_items
      tri = tris%items(i)
      ! Python: colour, verts = triangle; int() per colour
      ! component; float() per vertex component -- TypeError /
      ! ValueError there is "malformed", a flattened coordinate
      ! count other than 9 is "does not have 3 vertices".  (The
      ! Python exception text after "malformed:" varies by shape;
      ! the port uses a fixed suffix -- see port report.)
      bad = tri%kind /= DYN_K_LIST .or. tri%n_items /= 2
      ncoords = 0
      if (.not. bad) then
        cold = tri%items(1)
        vertl = tri%items(2)
        bad = cold%kind /= DYN_K_LIST .or. cold%n_items /= 3 .or. &
             vertl%kind /= DYN_K_LIST
      end if
      if (.not. bad) then
        do a = 1, 3
          if (.not. is_number(cold%items(a))) bad = .true.
        end do
        do a = 1, vertl%n_items
          vtx = vertl%items(a)
          if (vtx%kind /= DYN_K_LIST) then
            bad = .true.
            exit
          end if
          do b = 1, vtx%n_items
            if (.not. is_number(vtx%items(b))) bad = .true.
          end do
          if (bad) exit
          ncoords = ncoords + vtx%n_items
        end do
      end if
      if (bad) then
        call fail("triangles_to_tris_lines: triangle " // &
             trim(fmt_int(int(i - 1, int64))) // &
             " is malformed: cannot unpack triangle data")
        errmsg = g_errmsg
        return
      end if
      if (ncoords /= 9) then
        call fail("triangles_to_tris_lines: triangle " // &
             trim(fmt_int(int(i - 1, int64))) // &
             " does not have 3 vertices")
        errmsg = g_errmsg
        return
      end if
      do a = 1, 3
        ! Python int(c): truncation toward zero.
        if (cold%items(a)%kind == DYN_K_INT) then
          rgb(a) = cold%items(a)%i
        else
          rgb(a) = int(cold%items(a)%r, int64)
        end if
        vtx = vertl%items(a)
        do b = 1, 3
          coords((a - 1) * 3 + b) = as_real(vtx%items(b))
        end do
      end do
      line = "tri " // trim(fmt_int(rgb(1))) // " " // &
           trim(fmt_int(rgb(2))) // " " // trim(fmt_int(rgb(3)))
      do a = 1, 9
        line = line // " " // fmt_g6(coords(a))
      end do
      call char_list_append(lines, line)
    end do
    ok = .true.
    errmsg = ""
  end subroutine triangles_to_tris_lines

end module f3dc_ext_gltf
