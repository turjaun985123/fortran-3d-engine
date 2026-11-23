! f3dc_compat.f90 -- compatibility readers for the native Forge3D
! compiler.  Port of tools/f3dc/compat.py (read in full): legacy
! scene.json (v1) and Wavefront OBJ -> AST.
!
! Both readers produce the compat-only shape (dyn dicts, mirroring
! the Python dataclass __dict__ key order):
!   Program    { "statements": [ObjectStmt], "span": null }
!   ObjectStmt { "prim": "tris", "name": null, "color_raw": null,
!                "props": {"triangles": [...]}, "span": null }
! Legacy-JSON triangles are {"v": [[x,y,z] x3], "color": [r,g,b]}
! (plus "id" when the source id is an int); OBJ triangles are
! {"v": [[x,y,z] x3]}.  Synthetic nodes carry span=null; diagnostics
! carry spans against "<scene.json>" / "<model.obj>".
!
! Entry points (mirror the Python names):
!   logical function is_legacy_json(text)
!   subroutine ast_from_legacy_json(text, bag, program)
!   subroutine ast_from_obj(text, bag, program)
! Errors are collected into bag, never raised: malformed content ->
! E101/E301; OBJ security limits (> 64 MB, > 500k faces) -> E820 and
! an empty Program.
!
! Python compat.py parses JSON with json.loads, so this module
! carries a private JSON parser (json_parse) producing dyn values
! with Python's int/float distinction.  Its error strings imitate
! CPython's json error messages ("Expecting value: line .. column ..
! (char ..)" etc.), which ast_from_legacy_json embeds in E101.
!
! Known divergences from the Python (reported, never silent):
!  * JSON integers beyond int64 fall back to real64 (Python ints are
!    arbitrary precision); likewise int(color channel) for a float
!    beyond int64 range is clamped before the E301 range check
!    (Python int() would raise OverflowError and abort the read).
!  * CPython json error *positions* for invalid escapes are
!    approximated (message text and line/column otherwise match);
!    line/column count bytes, CPython counts code points (identical
!    for ASCII input).
!  * Lone \uXXXX surrogates in JSON strings are stored CESU-style
!    (Python keeps a lone-surrogate str, unrepresentable in bytes).
!  * str.splitlines()/split() treat \x1c-\x1f, \x85, U+2028/U+2029
!    as breaks/whitespace too; this port splits OBJ lines on
!    \n \r \x0b \x0c only (the formats in the wild are LF/CRLF).
!  * Python float()/int() accept a few spellings this port also
!    accepts (underscores between digits, inf/infinity/nan); float
!    conversion goes through the Fortran runtime reader after
!    grammar validation, so results are correctly rounded.
module f3dc_compat
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_value, ieee_positive_inf, &
                      ieee_quiet_nan
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, &
                      dyn_list_push, dyn_list_len, dyn_list_at, &
                      dyn_dict_set, dyn_dict_get, dyn_dict_has, &
                      dyn_dict_key_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real, char_list, char_list_append, &
                      char_list_len, char_list_at
  use f3dc_errors, only: error_bag_t, span_t, make_span, &
                         make_diagnostic, make_diagnostic_span, &
                         error_bag_add
  implicit none
  private

  public :: MAX_OBJ_BYTES, MAX_OBJ_FACES
  public :: is_legacy_json, ast_from_legacy_json, ast_from_obj

  !> OBJ size limit in bytes (64 MiB).
  integer(int64), parameter :: MAX_OBJ_BYTES = 67108864_int64
  !> OBJ face limit, counted pre-triangulation (`f` lines).
  integer(int64), parameter :: MAX_OBJ_FACES = 500000_int64

  character(len=*), parameter :: JSON_SOURCE = "<scene.json>"
  character(len=*), parameter :: OBJ_SOURCE = "<model.obj>"

  !> State of the private JSON parser (see json_parse below).
  type :: jparser
    character(len=:), allocatable :: text
    integer :: pos = 1  ! 1-based index of the next unconsumed byte
    logical :: failed = .false.
    character(len=:), allocatable :: errmsg
  end type jparser

contains

  ! ------------------------------------------------------------------
  ! _error (compat.py): append one diagnostic to the bag
  ! ------------------------------------------------------------------

  subroutine compat_error(bag, code, message, span, why, help)
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: code, message
    type(span_t), intent(in), optional :: span
    character(len=*), intent(in), optional :: why, help
    character(len=:), allocatable :: w, h
    w = ""
    h = ""
    if (present(why)) w = why
    if (present(help)) h = help
    if (present(span)) then
      call error_bag_add(bag, make_diagnostic_span(code, "error", &
                                                   message, span, w, h))
    else
      call error_bag_add(bag, make_diagnostic(code, "error", message, &
                                              w, h))
    end if
  end subroutine compat_error

  ! ------------------------------------------------------------------
  ! _tris_program / empty program
  ! ------------------------------------------------------------------

  function tris_program(triangles) result(prog)
    type(dyn), intent(in) :: triangles
    type(dyn) :: prog
    type(dyn) :: stmt, props, stmts
    stmt = dyn_dict()
    call dyn_dict_set(stmt, "prim", dyn_str("tris"))
    call dyn_dict_set(stmt, "name", dyn_null())
    call dyn_dict_set(stmt, "color_raw", dyn_null())
    props = dyn_dict()
    call dyn_dict_set(props, "triangles", triangles)
    call dyn_dict_set(stmt, "props", props)
    call dyn_dict_set(stmt, "span", dyn_null())
    stmts = dyn_list()
    call dyn_list_push(stmts, stmt)
    prog = dyn_dict()
    call dyn_dict_set(prog, "statements", stmts)
    call dyn_dict_set(prog, "span", dyn_null())
  end function tris_program

  function empty_program() result(prog)
    type(dyn) :: prog
    prog = dyn_dict()
    call dyn_dict_set(prog, "statements", dyn_list())
    call dyn_dict_set(prog, "span", dyn_null())
  end function empty_program

  ! ------------------------------------------------------------------
  ! Python value helpers (_is_number / _as_vec3 / str() / repr())
  ! ------------------------------------------------------------------

  !> _is_number: int/float but NOT bool.
  pure logical function is_number(d)
    type(dyn), intent(in) :: d
    is_number = d%kind == DYN_K_INT .or. d%kind == DYN_K_REAL
  end function is_number

  subroutine as_vec3(d, out, ok)
    type(dyn), intent(in) :: d
    type(dyn), intent(out) :: out
    logical, intent(out) :: ok
    integer :: k
    type(dyn) :: comp
    ok = .false.
    out = dyn_null()
    if (d%kind /= DYN_K_LIST .or. d%n_items /= 3) return
    out = dyn_list()
    do k = 1, 3
      comp = dyn_list_at(d, k)
      if (.not. is_number(comp)) then
        out = dyn_null()
        return
      end if
      if (comp%kind == DYN_K_INT) then
        call dyn_list_push(out, dyn_real(real(comp%i, real64)))
      else
        call dyn_list_push(out, dyn_real(comp%r))
      end if
    end do
    ok = .true.
  end subroutine as_vec3

  !> CPython repr of a string (same rules as f3dc_optimize's copy).
  function py_repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    character :: q
    integer :: i, b
    character(len=4) :: hexbuf
    if (index(s, "'") > 0 .and. index(s, '"') == 0) then
      q = '"'
    else
      q = "'"
    end if
    out = q
    do i = 1, len(s)
      b = iachar(s(i:i))
      if (s(i:i) == "\") then
        out = out // "\\"
      else if (s(i:i) == q) then
        out = out // "\" // q
      else if (b == 10) then
        out = out // "\n"
      else if (b == 13) then
        out = out // "\r"
      else if (b == 9) then
        out = out // "\t"
      else if (b < 32 .or. b == 127) then
        write (hexbuf, "(A,Z2.2)") "\x", b
        out = out // trim(hexbuf)
      else
        out = out // s(i:i)
      end if
    end do
    out = out // q
  end function py_repr_str

  recursive function py_repr(d) result(out)
    type(dyn), intent(in) :: d
    character(len=:), allocatable :: out
    integer :: k
    character(len=:), allocatable :: key
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
      out = trim(fmt_int(d%i))
    case (DYN_K_REAL)
      out = trim(fmt_real(d%r))
    case (DYN_K_STR)
      if (allocated(d%s)) then
        out = py_repr_str(d%s)
      else
        out = py_repr_str("")
      end if
    case (DYN_K_LIST)
      out = "["
      do k = 1, d%n_items
        if (k > 1) out = out // ", "
        out = out // py_repr(d%items(k))
      end do
      out = out // "]"
    case (DYN_K_DICT)
      out = "{"
      do k = 1, d%n_entries
        if (k > 1) out = out // ", "
        key = dyn_dict_key_at(d, k)
        out = out // py_repr_str(key) // ": " // py_repr(d%dvals(k))
      end do
      out = out // "}"
    case default
      out = "None"
    end select
  end function py_repr

  !> Python str(value): strings pass through, everything else reprs.
  function py_str(d) result(out)
    type(dyn), intent(in) :: d
    character(len=:), allocatable :: out
    if (d%kind == DYN_K_STR .and. allocated(d%s)) then
      out = d%s
    else
      out = py_repr(d)
    end if
  end function py_str

  ! ------------------------------------------------------------------
  ! Private JSON parser (mirrors json.loads -> dyn)
  ! ------------------------------------------------------------------

  !> Record a CPython-style json error: "msg: line L column C (char N)"
  !! where N is the 0-based offset of the offending position.
  subroutine jerr(p, msg, at)
    type(jparser), intent(inout) :: p
    character(len=*), intent(in) :: msg
    integer, intent(in) :: at  ! 1-based byte index of the position
    integer :: cpy, line, col, i, last_nl
    if (p%failed) return
    p%failed = .true.
    cpy = at - 1  ! CPython counts 0-based
    if (cpy < 0) cpy = 0
    line = 1
    last_nl = -1
    do i = 1, min(cpy, len(p%text))
      if (p%text(i:i) == achar(10)) then
        line = line + 1
        last_nl = i - 1
      end if
    end do
    col = cpy - last_nl
    p%errmsg = msg // ": line " // trim(fmt_int(int(line, int64))) // &
               " column " // trim(fmt_int(int(col, int64))) // &
               " (char " // trim(fmt_int(int(cpy, int64))) // ")"
  end subroutine jerr

  subroutine jskip_ws(p)
    type(jparser), intent(inout) :: p
    character :: c
    do while (p%pos <= len(p%text))
      c = p%text(p%pos:p%pos)
      if (c == " " .or. c == achar(9) .or. c == achar(10) .or. &
          c == achar(13)) then
        p%pos = p%pos + 1
      else
        exit
      end if
    end do
  end subroutine jskip_ws

  pure logical function is_digit(c)
    character, intent(in) :: c
    is_digit = c >= "0" .and. c <= "9"
  end function is_digit

  pure integer function hex_val(c)
    character, intent(in) :: c
    if (c >= "0" .and. c <= "9") then
      hex_val = iachar(c) - iachar("0")
    else if (c >= "a" .and. c <= "f") then
      hex_val = iachar(c) - iachar("a") + 10
    else if (c >= "A" .and. c <= "F") then
      hex_val = iachar(c) - iachar("A") + 10
    else
      hex_val = -1
    end if
  end function hex_val

  !> Append the UTF-8 encoding of code point cp to out.
  subroutine append_utf8(out, cp)
    character(len=:), allocatable, intent(inout) :: out
    integer, intent(in) :: cp
    if (cp < 128) then
      out = out // achar(cp)
    else if (cp < 2048) then
      out = out // achar(192 + cp / 64) // achar(128 + mod(cp, 64))
    else if (cp < 65536) then
      out = out // achar(224 + cp / 4096) // &
            achar(128 + mod(cp / 64, 64)) // achar(128 + mod(cp, 64))
    else
      out = out // achar(240 + cp / 262144) // &
            achar(128 + mod(cp / 4096, 64)) // &
            achar(128 + mod(cp / 64, 64)) // achar(128 + mod(cp, 64))
    end if
  end subroutine append_utf8

  !> Parse a \uXXXX escape body (pos is at the first hex digit).
  !! Returns the code point, or -1 after recording the error.
  function parse_u_escape(p) result(cp)
    type(jparser), intent(inout) :: p
    integer :: cp
    integer :: k, hv
    cp = 0
    do k = 0, 3
      if (p%pos + k > len(p%text)) then
        call jerr(p, "Invalid \uXXXX escape", p%pos)
        cp = -1
        return
      end if
      hv = hex_val(p%text(p%pos + k:p%pos + k))
      if (hv < 0) then
        call jerr(p, "Invalid \uXXXX escape", p%pos)
        cp = -1
        return
      end if
      cp = cp * 16 + hv
    end do
    p%pos = p%pos + 4
  end function parse_u_escape

  !> Parse a JSON string (pos at the opening quote) -> decoded bytes.
  subroutine jparse_string(p, out, ok)
    type(jparser), intent(inout) :: p
    character(len=:), allocatable, intent(out) :: out
    logical, intent(out) :: ok
    integer :: start, cp, cp2, save
    character :: c, e
    ok = .false.
    out = ""
    start = p%pos
    p%pos = p%pos + 1
    do while (p%pos <= len(p%text))
      c = p%text(p%pos:p%pos)
      if (c == '"') then
        p%pos = p%pos + 1
        ok = .true.
        return
      else if (c == "\") then
        if (p%pos + 1 > len(p%text)) exit  ! unterminated
        e = p%text(p%pos + 1:p%pos + 1)
        select case (e)
        case ('"')
          out = out // '"'
          p%pos = p%pos + 2
        case ("\")
          out = out // "\"
          p%pos = p%pos + 2
        case ("/")
          out = out // "/"
          p%pos = p%pos + 2
        case ("b")
          out = out // achar(8)
          p%pos = p%pos + 2
        case ("f")
          out = out // achar(12)
          p%pos = p%pos + 2
        case ("n")
          out = out // achar(10)
          p%pos = p%pos + 2
        case ("r")
          out = out // achar(13)
          p%pos = p%pos + 2
        case ("t")
          out = out // achar(9)
          p%pos = p%pos + 2
        case ("u")
          p%pos = p%pos + 2
          cp = parse_u_escape(p)
          if (cp < 0) return
          if (cp >= 55296 .and. cp <= 56319) then
            ! High surrogate: combine with a following \uXXXX low one.
            save = p%pos
            if (p%pos + 1 <= len(p%text)) then
              if (p%text(p%pos:p%pos) == "\" .and. &
                  p%text(p%pos + 1:p%pos + 1) == "u") then
                p%pos = p%pos + 2
                cp2 = parse_u_escape(p)
                if (cp2 < 0) return
                if (cp2 >= 56320 .and. cp2 <= 57343) then
                  cp = 65536 + (cp - 55296) * 1024 + (cp2 - 56320)
                else
                  call append_utf8(out, cp)  ! lone high surrogate
                  cp = cp2
                end if
              end if
            end if
            if (p%pos == save) then
              call append_utf8(out, cp)
              cycle
            end if
            call append_utf8(out, cp)
            cycle
          end if
          call append_utf8(out, cp)
        case default
          call jerr(p, "Invalid \escape", p%pos + 1)
          return
        end select
      else if (iachar(c) < 32) then
        call jerr(p, "Invalid control character at", p%pos)
        return
      else
        out = out // c
        p%pos = p%pos + 1
      end if
    end do
    call jerr(p, "Unterminated string starting at", start)
  end subroutine jparse_string

  !> Parse a JSON number (pos at '-' or a digit).
  subroutine jparse_number(p, val)
    type(jparser), intent(inout) :: p
    type(dyn), intent(out) :: val
    integer :: start, i, j
    logical :: is_int, overflow
    character(len=:), allocatable :: tok
    integer(int64) :: iv, dig
    real(real64) :: rv
    integer :: ios
    val = dyn_null()
    start = p%pos
    i = p%pos
    if (i <= len(p%text) .and. p%text(i:i) == "-") i = i + 1
    if (i > len(p%text) .or. .not. is_digit(p%text(i:i))) then
      call jerr(p, "Expecting value", start)
      return
    end if
    if (p%text(i:i) == "0") then
      i = i + 1
    else
      do while (i <= len(p%text) .and. is_digit(p%text(i:i)))
        i = i + 1
      end do
    end if
    is_int = .true.
    ! Fraction: taken only when a digit follows the dot (CPython's
    ! number regex backtracks the same way).
    if (i + 1 <= len(p%text) .and. p%text(i:i) == "." .and. &
        is_digit(p%text(i + 1:i + 1))) then
      is_int = .false.
      i = i + 2
      do while (i <= len(p%text) .and. is_digit(p%text(i:i)))
        i = i + 1
      end do
    end if
    ! Exponent: taken only when digits (after an optional sign) follow.
    if (i <= len(p%text)) then
      if (p%text(i:i) == "e" .or. p%text(i:i) == "E") then
        j = i + 1
        if (j <= len(p%text)) then
          if (p%text(j:j) == "+" .or. p%text(j:j) == "-") j = j + 1
        end if
        if (j <= len(p%text) .and. is_digit(p%text(j:j))) then
          is_int = .false.
          i = j
          do while (i <= len(p%text) .and. is_digit(p%text(i:i)))
            i = i + 1
          end do
        end if
      end if
    end if
    tok = p%text(start:i - 1)
    p%pos = i
    if (is_int) then
      ! Manual int64 parse with overflow detection.
      overflow = .false.
      iv = 0_int64
      j = 1
      if (tok(1:1) == "-") j = 2
      do while (j <= len(tok))
        dig = iachar(tok(j:j)) - iachar("0")
        if (iv > (huge(iv) - dig) / 10_int64) overflow = .true.
        if (.not. overflow) iv = iv * 10_int64 + dig
        j = j + 1
      end do
      if (overflow) then
        read (tok, *, iostat=ios) rv
        if (ios /= 0) rv = ieee_value(0.0_real64, ieee_positive_inf)
        if (tok(1:1) == "-") rv = -abs(rv)
        val = dyn_real(rv)
      else
        if (tok(1:1) == "-") iv = -iv
        val = dyn_int(iv)
      end if
    else
      read (tok, *, iostat=ios) rv
      if (ios /= 0) then
        ! e.g. 1e999 -> CPython float() gives inf
        rv = ieee_value(0.0_real64, ieee_positive_inf)
        if (tok(1:1) == "-") rv = -rv
      end if
      val = dyn_real(rv)
    end if
  end subroutine jparse_number

  recursive subroutine jparse_value(p, val)
    type(jparser), intent(inout) :: p
    type(dyn), intent(out) :: val
    integer :: start, n
    character :: c
    character(len=:), allocatable :: key, sval
    type(dyn) :: item
    logical :: ok
    val = dyn_null()
    call jskip_ws(p)
    if (p%failed) return
    n = len(p%text)
    if (p%pos > n) then
      call jerr(p, "Expecting value", p%pos)
      return
    end if
    start = p%pos
    c = p%text(p%pos:p%pos)
    select case (c)
    case ("{")
      val = dyn_dict()
      p%pos = p%pos + 1
      call jskip_ws(p)
      if (p%pos <= n .and. p%text(p%pos:p%pos) == "}") then
        p%pos = p%pos + 1
        return
      end if
      do
        call jskip_ws(p)
        if (p%pos > n .or. p%text(p%pos:p%pos) /= '"') then
          call jerr(p, "Expecting property name enclosed in " // &
                    "double quotes", p%pos)
          return
        end if
        call jparse_string(p, key, ok)
        if (.not. ok) return
        call jskip_ws(p)
        if (p%pos > n .or. p%text(p%pos:p%pos) /= ":") then
          call jerr(p, "Expecting ':' delimiter", p%pos)
          return
        end if
        p%pos = p%pos + 1
        call jparse_value(p, item)
        if (p%failed) return
        call dyn_dict_set(val, key, item)
        call jskip_ws(p)
        if (p%pos <= n .and. p%text(p%pos:p%pos) == ",") then
          p%pos = p%pos + 1
          cycle
        end if
        if (p%pos <= n .and. p%text(p%pos:p%pos) == "}") then
          p%pos = p%pos + 1
          return
        end if
        call jerr(p, "Expecting ',' delimiter", p%pos)
        return
      end do
    case ("[")
      val = dyn_list()
      p%pos = p%pos + 1
      call jskip_ws(p)
      if (p%pos <= n .and. p%text(p%pos:p%pos) == "]") then
        p%pos = p%pos + 1
        return
      end if
      do
        call jparse_value(p, item)
        if (p%failed) return
        call dyn_list_push(val, item)
        call jskip_ws(p)
        if (p%pos <= n .and. p%text(p%pos:p%pos) == ",") then
          p%pos = p%pos + 1
          cycle
        end if
        if (p%pos <= n .and. p%text(p%pos:p%pos) == "]") then
          p%pos = p%pos + 1
          return
        end if
        call jerr(p, "Expecting ',' delimiter", p%pos)
        return
      end do
    case ('"')
      call jparse_string(p, sval, ok)
      if (.not. ok) return
      val = dyn_str(sval)
    case ("t")
      if (p%pos + 3 <= n .and. p%text(p%pos:p%pos + 3) == "true") then
        val = dyn_bool(.true.)
        p%pos = p%pos + 4
      else
        call jerr(p, "Expecting value", start)
      end if
    case ("f")
      if (p%pos + 4 <= n .and. p%text(p%pos:p%pos + 4) == "false") then
        val = dyn_bool(.false.)
        p%pos = p%pos + 5
      else
        call jerr(p, "Expecting value", start)
      end if
    case ("n")
      if (p%pos + 3 <= n .and. p%text(p%pos:p%pos + 3) == "null") then
        val = dyn_null()
        p%pos = p%pos + 4
      else
        call jerr(p, "Expecting value", start)
      end if
    case ("N")
      if (p%pos + 2 <= n .and. p%text(p%pos:p%pos + 2) == "NaN") then
        val = dyn_real(ieee_value(0.0_real64, ieee_quiet_nan))
        p%pos = p%pos + 3
      else
        call jerr(p, "Expecting value", start)
      end if
    case ("I")
      if (p%pos + 7 <= n .and. p%text(p%pos:p%pos + 7) == "Infinity") &
        then
        val = dyn_real(ieee_value(0.0_real64, ieee_positive_inf))
        p%pos = p%pos + 8
      else
        call jerr(p, "Expecting value", start)
      end if
    case ("-")
      if (p%pos + 8 <= n .and. &
          p%text(p%pos:p%pos + 8) == "-Infinity") then
        val = dyn_real(-ieee_value(0.0_real64, ieee_positive_inf))
        p%pos = p%pos + 9
      else
        call jparse_number(p, val)
      end if
    case default
      if (is_digit(c)) then
        call jparse_number(p, val)
      else
        call jerr(p, "Expecting value", start)
      end if
    end select
  end subroutine jparse_value

  !> json.loads(text) -> dyn; ok=.false. + CPython-style errmsg.
  subroutine json_parse(text, val, ok, errmsg)
    character(len=*), intent(in) :: text
    type(dyn), intent(out) :: val
    logical, intent(out) :: ok
    character(len=:), allocatable, intent(out) :: errmsg
    type(jparser) :: p
    p%text = text
    p%pos = 1
    p%failed = .false.
    p%errmsg = ""
    call jparse_value(p, val)
    if (.not. p%failed) then
      call jskip_ws(p)
      if (p%pos <= len(p%text)) call jerr(p, "Extra data", p%pos)
    end if
    ok = .not. p%failed
    if (p%failed) then
      errmsg = p%errmsg
      val = dyn_null()
    else
      errmsg = ""
    end if
  end subroutine json_parse

  ! ------------------------------------------------------------------
  ! Legacy scene.json (v1)
  ! ------------------------------------------------------------------

  logical function is_legacy_json(text)
    character(len=*), intent(in) :: text
    type(dyn) :: data, triangles, entry
    logical :: ok
    character(len=:), allocatable :: errmsg
    integer :: k
    is_legacy_json = .false.
    call json_parse(text, data, ok, errmsg)
    if (.not. ok) return
    if (data%kind /= DYN_K_DICT) return
    if (dyn_dict_has(data, "ir_version")) return
    if (dyn_dict_has(data, "objects")) return
    if (.not. dyn_dict_has(data, "triangles")) return
    triangles = dyn_dict_get(data, "triangles")
    if (triangles%kind /= DYN_K_LIST) return
    do k = 1, triangles%n_items
      entry = dyn_list_at(triangles, k)
      if (entry%kind /= DYN_K_DICT) return
      if (.not. dyn_dict_has(entry, "v")) return
      if (.not. dyn_dict_has(entry, "color")) return
    end do
    is_legacy_json = .true.
  end function is_legacy_json

  subroutine ast_from_legacy_json(text, bag, program)
    character(len=*), intent(in) :: text
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: program
    type(dyn) :: data, tris_in, entry, vraw, verts, vert, craw, tri
    type(dyn) :: idv, col_list
    logical :: ok, vok
    character(len=:), allocatable :: errmsg, where, prefix
    type(span_t) :: span
    integer :: idx, k, ch
    integer(int64) :: civ(3)
    real(real64) :: rv
    span = make_span(JSON_SOURCE, 1, 1)
    call json_parse(text, data, ok, errmsg)
    if (.not. ok) then
      call compat_error(bag, "E101", &
        "legacy scene JSON is not valid JSON: " // errmsg, span=span, &
        why="the compat reader only accepts the v1 " // &
            "{triangles: [...]} shape", &
        help="export the scene again, or convert it to .f3d")
      program = empty_program()
      return
    end if
    if (data%kind /= DYN_K_DICT .or. &
        .not. dyn_dict_has(data, "triangles")) then
      call compat_error(bag, "E101", &
        "legacy scene JSON has no 'triangles' list", span=span, &
        why="the v1 format is {triangles: [{v, color}, ...]}", &
        help="check the file is a v1 scene.json, not a v2 export")
      program = empty_program()
      return
    end if
    tris_in = dyn_dict_get(data, "triangles")
    if (tris_in%kind /= DYN_K_LIST) then
      call compat_error(bag, "E101", &
        "legacy scene JSON has no 'triangles' list", span=span, &
        why="the v1 format is {triangles: [{v, color}, ...]}", &
        help="check the file is a v1 scene.json, not a v2 export")
      program = empty_program()
      return
    end if
    block
      type(dyn) :: triangles
      triangles = dyn_list()
      do idx = 1, tris_in%n_items
        entry = dyn_list_at(tris_in, idx)
        ! where = f"triangle {entry.get('id', idx) if dict else idx}"
        if (entry%kind == DYN_K_DICT .and. dyn_dict_has(entry, "id")) &
          then
          where = py_str(dyn_dict_get(entry, "id"))
        else
          where = trim(fmt_int(int(idx, int64)))
        end if
        prefix = "triangle " // where
        if (entry%kind /= DYN_K_DICT) then
          call compat_error(bag, "E101", prefix // ": not an object", &
                            span=span)
          cycle
        end if
        vraw = dyn_dict_get(entry, "v")
        if (vraw%kind /= DYN_K_LIST .or. vraw%n_items /= 3) then
          call compat_error(bag, "E101", prefix // &
            ": 'v' must have exactly 3 vertices", span=span)
          cycle
        end if
        verts = dyn_list()
        vok = .true.
        do k = 1, 3
          call as_vec3(dyn_list_at(vraw, k), vert, ok)
          if (.not. ok) then
            vok = .false.
            exit
          end if
          call dyn_list_push(verts, vert)
        end do
        if (.not. vok) then
          call compat_error(bag, "E101", prefix // &
            ": each vertex must be [x, y, z] numbers", span=span)
          cycle
        end if
        craw = dyn_dict_get(entry, "color")
        if (craw%kind /= DYN_K_LIST .or. craw%n_items /= 3) then
          call compat_error(bag, "E101", prefix // &
            ": 'color' must be [r, g, b] numbers", span=span)
          cycle
        end if
        vok = .true.
        do k = 1, 3
          if (.not. is_number(dyn_list_at(craw, k))) vok = .false.
        end do
        if (.not. vok) then
          call compat_error(bag, "E101", prefix // &
            ": 'color' must be [r, g, b] numbers", span=span)
          cycle
        end if
        ! color = [int(c) for c in color_raw]  (truncation, as Python)
        do k = 1, 3
          vert = dyn_list_at(craw, k)
          if (vert%kind == DYN_K_INT) then
            civ(k) = vert%i
          else
            rv = vert%r
            if (rv /= rv) then
              civ(k) = 0_int64  ! int(NaN) raises in Python; unreachable
            else if (rv >= 9223372036854775807.0_real64) then
              civ(k) = huge(civ(k))
            else if (rv <= -9223372036854775807.0_real64) then
              civ(k) = -huge(civ(k))
            else
              civ(k) = int(rv, int64)
            end if
          end if
        end do
        if (any(civ < 0_int64 .or. civ > 255_int64)) then
          col_list = dyn_list()
          do k = 1, 3
            call dyn_list_push(col_list, dyn_int(civ(k)))
          end do
          call compat_error(bag, "E301", prefix // &
            ": colour channels must be 0-255, got " // &
            py_repr(col_list), span=span)
          cycle
        end if
        tri = dyn_dict()
        call dyn_dict_set(tri, "v", verts)
        col_list = dyn_list()
        do k = 1, 3
          call dyn_list_push(col_list, dyn_int(civ(k)))
        end do
        call dyn_dict_set(tri, "color", col_list)
        if (dyn_dict_has(entry, "id")) then
          idv = dyn_dict_get(entry, "id")
          ! isinstance(id, int) -- bool is an int subclass in Python.
          if (idv%kind == DYN_K_INT .or. idv%kind == DYN_K_BOOL) &
            call dyn_dict_set(tri, "id", idv)
        end if
        call dyn_list_push(triangles, tri)
      end do
      program = tris_program(triangles)
    end block
  end subroutine ast_from_legacy_json

  ! ------------------------------------------------------------------
  ! Wavefront OBJ helpers: Python float()/int()/split()/splitlines()
  ! ------------------------------------------------------------------

  pure logical function is_py_space(c)
    character, intent(in) :: c
    integer :: b
    b = iachar(c)
    is_py_space = b == 32 .or. b == 9 .or. b == 10 .or. b == 13 .or. &
                  b == 11 .or. b == 12 .or. (b >= 28 .and. b <= 31)
  end function is_py_space

  !> Split a line on Python-whitespace runs -> tokens (char_list).
  subroutine split_ws(line, tokens)
    character(len=*), intent(in) :: line
    type(char_list), intent(out) :: tokens
    integer :: i, start
    i = 1
    do while (i <= len(line))
      do while (i <= len(line) .and. is_py_space(line(i:i)))
        i = i + 1
      end do
      if (i > len(line)) exit
      start = i
      do while (i <= len(line) .and. .not. is_py_space(line(i:i)))
        i = i + 1
      end do
      call char_list_append(tokens, line(start:i - 1))
    end do
  end subroutine split_ws

  !> Split text into lines, Python splitlines() for \n \r \r\n \x0b
  !! \x0c breaks (see header for the exotic-break divergence).
  subroutine split_lines(text, lines)
    character(len=*), intent(in) :: text
    type(char_list), intent(out) :: lines
    integer :: i, start
    logical :: broke
    start = 1
    i = 1
    broke = .false.
    do while (i <= len(text))
      if (text(i:i) == achar(10) .or. text(i:i) == achar(13) .or. &
          text(i:i) == achar(11) .or. text(i:i) == achar(12)) then
        call char_list_append(lines, text(start:i - 1))
        if (text(i:i) == achar(13) .and. i < len(text)) then
          if (text(i + 1:i + 1) == achar(10)) i = i + 1
        end if
        i = i + 1
        start = i
        broke = .true.
      else
        i = i + 1
        broke = .false.
      end if
    end do
    if (.not. broke) then
      if (len(text) > 0) call char_list_append(lines, text(start:))
    end if
  end subroutine split_lines

  !> Validate a Python float() digit part with single underscores
  !! allowed only between digits.  Scans s(b:e); ok and digit count.
  subroutine scan_digitpart(s, b, e, ok, ndig)
    character(len=*), intent(in) :: s
    integer, intent(in) :: b
    integer, intent(out) :: e
    logical, intent(out) :: ok
    integer, intent(out) :: ndig
    integer :: i
    logical :: prev_digit, prev_us
    ok = .false.
    ndig = 0
    i = b
    prev_digit = .false.
    prev_us = .false.
    do while (i <= len(s))
      if (is_digit(s(i:i))) then
        ndig = ndig + 1
        prev_digit = .true.
        prev_us = .false.
        i = i + 1
      else if (s(i:i) == "_" .and. prev_digit .and. i < len(s)) then
        if (.not. is_digit(s(i + 1:i + 1))) exit
        prev_digit = .false.
        prev_us = .true.
        i = i + 1
      else
        exit
      end if
    end do
    e = i - 1
    ok = ndig > 0 .and. .not. prev_us
  end subroutine scan_digitpart

  !> Python float(token): ok=.false. mirrors a ValueError.
  subroutine parse_py_float(tok, x, ok)
    character(len=*), intent(in) :: tok
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, clean, low
    integer :: i, e, ndig, ios
    logical :: okk
    ok = .false.
    x = 0.0_real64
    t = trim(tok)
    ! Python float() also strips other whitespace; tokens from
    ! split() carry none, so blank-trimming suffices here.
    if (len(t) == 0) return
    low = t
    block
      integer :: k, b
      do k = 1, len(low)
        b = iachar(low(k:k))
        if (b >= 65 .and. b <= 90) low(k:k) = achar(b + 32)
      end do
    end block
    block
      character(len=:), allocatable :: body
      logical :: neg
      neg = .false.
      body = low
      if (body(1:1) == "+" .or. body(1:1) == "-") then
        neg = body(1:1) == "-"
        body = body(2:)
      end if
      if (body == "inf" .or. body == "infinity") then
        x = ieee_value(0.0_real64, ieee_positive_inf)
        if (neg) x = -x
        ok = .true.
        return
      end if
      if (body == "nan") then
        x = ieee_value(0.0_real64, ieee_quiet_nan)
        ok = .true.
        return
      end if
    end block
    ! Grammar: digitpart ['.' [digitpart]] | '.' digitpart,
    ! then optional [eE][+-]digitpart.  Validate, strip underscores,
    ! and let the runtime reader do the correctly-rounded convert.
    i = 1
    if (t(i:i) == "+" .or. t(i:i) == "-") i = i + 1
    if (i > len(t)) return
    block
      logical :: intpart_ok, frac_ok
      integer :: nd
      intpart_ok = .false.
      frac_ok = .false.
      if (is_digit(t(i:i))) then
        call scan_digitpart(t, i, e, okk, nd)
        if (.not. okk) return
        intpart_ok = .true.
        i = e + 1
      end if
      if (i <= len(t) .and. t(i:i) == ".") then
        i = i + 1
        if (i <= len(t) .and. is_digit(t(i:i))) then
          call scan_digitpart(t, i, e, okk, nd)
          if (.not. okk) return
          frac_ok = .true.
          i = e + 1
        end if
      end if
      if (.not. intpart_ok .and. .not. frac_ok) return
      if (i <= len(t) .and. (t(i:i) == "e" .or. t(i:i) == "E")) then
        i = i + 1
        if (i <= len(t)) then
          if (t(i:i) == "+" .or. t(i:i) == "-") i = i + 1
        end if
        if (i > len(t)) return
        call scan_digitpart(t, i, e, okk, nd)
        if (.not. okk) return
        i = e + 1
      end if
      if (i <= len(t)) return
    end block
    clean = ""
    do i = 1, len(t)
      if (t(i:i) /= "_") clean = clean // t(i:i)
    end do
    read (clean, *, iostat=ios) x
    if (ios /= 0) return
    ok = .true.
  end subroutine parse_py_float

  !> Python int(token): status 0 = ValueError, 1 = ok, 2 = overflow
  !! (value saturated; Python would keep the exact big int, and the
  !! caller's range check then reports E301, as Python does).
  subroutine parse_py_int(tok, v, status)
    character(len=*), intent(in) :: tok
    integer(int64), intent(out) :: v
    integer, intent(out) :: status
    integer :: i, e, ndig
    logical :: okk, neg
    integer(int64) :: dig
    status = 0
    v = 0_int64
    i = 1
    neg = .false.
    if (len(tok) == 0) return
    if (tok(1:1) == "+" .or. tok(1:1) == "-") then
      neg = tok(1:1) == "-"
      i = 2
    end if
    if (i > len(tok)) return
    call scan_digitpart(tok, i, e, okk, ndig)
    if (.not. okk .or. e /= len(tok)) return
    status = 1
    do i = i, e
      if (tok(i:i) == "_") cycle
      dig = iachar(tok(i:i)) - iachar("0")
      if (status == 1) then
        if (v > (huge(v) - dig) / 10_int64) then
          status = 2
          v = huge(v)
        else
          v = v * 10_int64 + dig
        end if
      end if
    end do
    if (neg) v = -v
  end subroutine parse_py_int

  !> Split a face token on '/', keeping empty fields.
  subroutine split_slash(tok, fields, nfields)
    character(len=*), intent(in) :: tok
    type(char_list), intent(out) :: fields
    integer, intent(out) :: nfields
    integer :: i, start
    nfields = 0
    start = 1
    do i = 1, len(tok) + 1
      if (i > len(tok) .or. tok(i:i) == "/") then
        call char_list_append(fields, tok(start:i - 1))
        nfields = nfields + 1
        start = i + 1
      end if
    end do
  end subroutine split_slash

  ! ------------------------------------------------------------------
  ! Wavefront OBJ
  ! ------------------------------------------------------------------

  subroutine ast_from_obj(text, bag, program)
    character(len=*), intent(in) :: text
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: program
    type(char_list) :: lines, tokens, fields
    type(dyn) :: vertices, triangles, vert, tri, tri_v, cvert
    character(len=:), allocatable :: line, keyword, tok, joined
    integer(int64) :: size, face_count
    integer :: lineno, li, ti, fi, ci, status
    integer(int64) :: index
    integer :: resolved, nfields
    logical :: okk, bad
    real(real64) :: fv(3)
    integer, allocatable :: corners(:)
    integer :: n_corners, cap_corners

    size = int(len(text), int64)
    if (size > MAX_OBJ_BYTES) then
      call compat_error(bag, "E820", &
        "OBJ input is " // trim(fmt_int(size)) // " bytes, over the " &
        // trim(fmt_int(MAX_OBJ_BYTES)) // "-byte (64 MB) limit", &
        span=make_span(OBJ_SOURCE, 1, 1), &
        why="oversized assets are a security/resource limit, " // &
            "not a scene the compiler will de-index", &
        help="split or simplify the model and try again")
      program = empty_program()
      return
    end if

    call split_lines(text, lines)
    face_count = 0_int64
    do li = 1, char_list_len(lines)
      line = char_list_at(lines, li)
      call split_ws(line, tokens)
      if (char_list_len(tokens) >= 1) then
        if (char_list_at(tokens, 1) == "f") &
          face_count = face_count + 1_int64
      end if
    end do
    if (face_count > MAX_OBJ_FACES) then
      call compat_error(bag, "E820", &
        "OBJ input has " // trim(fmt_int(face_count)) // &
        " faces, over the " // trim(fmt_int(MAX_OBJ_FACES)) // &
        "-face limit", &
        span=make_span(OBJ_SOURCE, 1, 1), &
        why="oversized assets are a security/resource limit, " // &
            "not a scene the compiler will de-index", &
        help="split or simplify the model and try again")
      program = empty_program()
      return
    end if

    vertices = dyn_list()
    triangles = dyn_list()
    allocate (corners(64))
    cap_corners = 64
    do lineno = 1, char_list_len(lines)
      line = char_list_at(lines, lineno)
      call split_ws(line, tokens)
      if (char_list_len(tokens) == 0) cycle
      keyword = char_list_at(tokens, 1)
      if (len(keyword) > 0) then
        if (keyword(1:1) == "#") cycle
      end if
      if (keyword == "v") then
        if (char_list_len(tokens) - 1 < 3) then
          call compat_error(bag, "E101", &
            "line " // trim(fmt_int(int(lineno, int64))) // &
            ": 'v' needs 3 coordinates", &
            span=make_span(OBJ_SOURCE, lineno, 1))
          cycle
        end if
        okk = .true.
        do ti = 1, 3
          tok = char_list_at(tokens, ti + 1)
          call parse_py_float(tok, fv(ti), okk)
          if (.not. okk) exit
        end do
        if (.not. okk) then
          joined = char_list_at(tokens, 2) // " " // &
                   char_list_at(tokens, 3) // " " // &
                   char_list_at(tokens, 4)
          call compat_error(bag, "E101", &
            "line " // trim(fmt_int(int(lineno, int64))) // &
            ": bad vertex number in " // py_repr_str(joined), &
            span=make_span(OBJ_SOURCE, lineno, 1))
          cycle
        end if
        vert = dyn_list()
        do ti = 1, 3
          call dyn_list_push(vert, dyn_real(fv(ti)))
        end do
        call dyn_list_push(vertices, vert)
      else if (keyword == "f") then
        if (char_list_len(tokens) - 1 < 3) then
          call compat_error(bag, "E101", &
            "line " // trim(fmt_int(int(lineno, int64))) // &
            ": face needs at least 3 corners", &
            span=make_span(OBJ_SOURCE, lineno, 1))
          cycle
        end if
        n_corners = 0
        bad = .false.
        do ti = 2, char_list_len(tokens)
          tok = char_list_at(tokens, ti)
          call split_slash(tok, fields, nfields)
          if (nfields > 3) then
            bad = .true.
            exit
          end if
          if (len(char_list_at(fields, 1)) == 0) then
            bad = .true.
            exit
          end if
          call parse_py_int(char_list_at(fields, 1), index, status)
          if (status == 0) then
            bad = .true.
            exit
          end if
          if (index == 0_int64) then
            bad = .true.
            exit
          end if
          if (index > 0_int64) then
            resolved = int(index - 1_int64)
            if (status == 2) resolved = dyn_list_len(vertices)
          else
            resolved = dyn_list_len(vertices) + int(index)
            if (status == 2) resolved = -1
          end if
          if (resolved < 0 .or. resolved >= dyn_list_len(vertices)) &
            then
            call compat_error(bag, "E301", &
              "line " // trim(fmt_int(int(lineno, int64))) // &
              ": vertex index " // trim(fmt_int(index)) // &
              " out of range (1.." // &
              trim(fmt_int(int(dyn_list_len(vertices), int64))) // &
              ")", span=make_span(OBJ_SOURCE, lineno, 1))
            bad = .true.
            exit
          end if
          n_corners = n_corners + 1
          if (n_corners > cap_corners) then
            block
              integer, allocatable :: tmp(:)
              allocate (tmp(2 * cap_corners))
              tmp(1:cap_corners) = corners
              call move_alloc(tmp, corners)
              cap_corners = 2 * cap_corners
            end block
          end if
          corners(n_corners) = resolved
        end do
        if (bad) cycle
        ! Fan triangulation: (c0, ci, ci+1) for i = 1 .. n-2.
        do ci = 2, n_corners - 1
          tri_v = dyn_list()
          cvert = dyn_list_at(vertices, corners(1) + 1)
          call dyn_list_push(tri_v, cvert)
          cvert = dyn_list_at(vertices, corners(ci) + 1)
          call dyn_list_push(tri_v, cvert)
          cvert = dyn_list_at(vertices, corners(ci + 1) + 1)
          call dyn_list_push(tri_v, cvert)
          tri = dyn_dict()
          call dyn_dict_set(tri, "v", tri_v)
          call dyn_list_push(triangles, tri)
        end do
      end if
      ! Everything else (vt/vn/o/g/s/usemtl/mtllib/unknown) ignored.
    end do
    program = tris_program(triangles)
  end subroutine ast_from_obj

end module f3dc_compat
