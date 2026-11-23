! f3dc_ext_sprites_text -- Forge3D Wave B extension: sprite + text.
!
! Faithful Fortran port of tools/f3dc/ext_sprites_text.py (481 lines),
! per compiler/DESIGN.md.  Python is the oracle; every function below
! mirrors its Python namesake function-by-function:
!
!   extract_sprite(props)   -> subroutine extract_sprite(props, d)
!   validate_sprite(d)      -> subroutine validate_sprite(d, errors)
!   sprite_line(name, d)    -> subroutine sprite_line(name, d, line)
!   extract_text(props)     -> subroutine extract_text(props, d)
!   validate_text(d)        -> subroutine validate_text(d, errors)
!   text_line(name, d)      -> subroutine text_line(name, d, line)
!
! Values are dyn (f3dc_dyn): Python tuples are dyn lists, dicts are
! dyn dicts, None is dyn_null.  validate_* return their plain
! human-readable messages (no diagnostic codes) in a char_list;
! validate.py wraps them in E301 diagnostics at the DISPATCH site.
! Extracted dict shapes (insertion order mirrors Python):
!   sprite: {"at": [x, y, z], "size": float, "color": [r, g, b]}
!   text:   same + {"text": str, "content": str} (both spellings).
!
! Colour strings: ext_sprites_text._parse_color first delegates to
! ir_nodes.parse_color (bag=None), which RAISES on unknown colours;
! the ext module catches that and falls back to its local parser.
! The net observable behaviour for strings is exactly the local
! parser (strip, strip quote chars, strip; named palette / #rrggbb /
! rgb(r,g,b)), which is what parse_color_dyn implements.  Sequence
! colours never reach ir_nodes in the ext module: the local path
! (float channels, round-half-even, 0..255 range on the raw value)
! handles them, and is implemented here directly.
!
! Known representation divergences (dyn conflations, shared with the
! landed f3dc_validate / f3dc_ir ports):
!   * Python repr() of a genuine list uses [] where dyn renders the
!     tuple style () -- only visible inside %r diagnostic messages
!     for hand-built list values; parser/validate values are tuples.
!   * Attribute-carrying colour/text objects (ColourLit-style nodes
!     with .rgb / .name / .value / .text attributes) have no dyn
!     form; the parser only ever produces strings / int tuples for
!     colours and plain strings for text content, so this path is
!     unreachable in the compiler pipeline.
!   * Python str.strip / str.split / str.lower / re \s and \d are
!     Unicode-aware; the helpers here cover the ASCII subsets.
!   * len(text) counts Unicode code points in Python, bytes here;
!     equal for the ASCII the text font can draw (non-ASCII content
!     is a validation error either way, but the %d in the length
!     message can differ for multi-byte input).
module f3dc_ext_sprites_text
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_nan, &
       ieee_is_finite, ieee_is_negative, ieee_value, &
       ieee_quiet_nan, ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_dict_get, &
       dyn_dict_set, dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
       dyn_dict_value_at, dyn_list_push, dyn_list_len, dyn_list_at, &
       DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
       char_list_at, fmt_int, fmt_real, to_lower
  implicit none
  private

  public :: extract_sprite, validate_sprite, sprite_line
  public :: extract_text, validate_text, text_line
  public :: ST_TEXT_CHARSET, ST_MAX_SIZE, ST_MAX_TEXT_LEN

  ! Defaults / limits (ext_sprites_text.py module constants).
  real(real64), parameter :: ST_MAX_SIZE = 100.0_real64
  integer, parameter :: ST_MAX_TEXT_LEN = 200
  character(*), parameter :: ST_TEXT_CHARSET = &
       " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!?-:'"
  real(real64), parameter :: DEFAULT_SIZE = 1.0_real64
  integer, parameter :: DEFAULT_COLOR(3) = [255, 255, 255]

  ! NAMED_COLORS: the frozen ir_nodes palette (same table as
  ! f3dc_ir / the ext module's embedded fallback copy).
  integer, parameter :: N_COLORS = 13
  character(8), parameter :: COLOR_NAMES(N_COLORS) = [ &
       "red     ", "green   ", "blue    ", "yellow  ", "magenta ", &
       "cyan    ", "orange  ", "purple  ", "pink    ", "white   ", &
       "black   ", "gray    ", "grey    "]
  integer, parameter :: COLOR_RGB(3, N_COLORS) = reshape([ &
       220, 60, 60,    60, 220, 60,    60, 100, 240,  240, 220, 50, &
       200, 80, 220,   60, 220, 220,  240, 140, 40,  140, 80, 200, &
       240, 150, 190,  240, 240, 240, 20, 20, 25,    140, 140, 145, &
       140, 140, 145], [3, N_COLORS])

contains

  ! ================================================================
  ! Generic value helpers (ext_sprites_text.py: _lower_keys /
  ! _first / _as_number / _vec3 / _parse_color / _fmt)
  ! ================================================================

  pure logical function is_ws(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    is_ws = (c == 32 .or. (c >= 9 .and. c <= 13))
  end function is_ws

  !> Python str.strip() (ASCII whitespace subset).
  function strip_ws(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
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
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws

  !> Split s on runs of whitespace (Python str.split() with no args).
  subroutine split_ws(s, parts)
    character(*), intent(in) :: s
    type(char_list), intent(inout) :: parts
    integer :: i, start
    parts%n = 0
    i = 1
    do while (i <= len(s))
      do while (i <= len(s))
        if (.not. is_ws(s(i:i))) exit
        i = i + 1
      end do
      if (i > len(s)) exit
      start = i
      do while (i <= len(s))
        if (is_ws(s(i:i))) exit
        i = i + 1
      end do
      call char_list_append(parts, s(start:i - 1))
    end do
  end subroutine split_ws

  !> _lower_keys(props): copy with string keys lower-cased; a
  !! non-dict yields an empty dict.
  subroutine lower_keys(props, out)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: out
    integer :: k
    out = dyn_dict()
    if (props%kind /= DYN_K_DICT) return
    do k = 1, dyn_dict_len(props)
      call dyn_dict_set(out, to_lower(dyn_dict_key_at(props, k)), &
                        dyn_dict_value_at(props, k))
    end do
  end subroutine lower_keys

  !> _first(props, *names): first present, non-None value; the
  !! result is dyn_null when none applies (Python None).
  subroutine first_of(props, names, val)
    type(dyn), intent(in) :: props
    character(*), intent(in) :: names(:)
    type(dyn), intent(out) :: val
    integer :: k
    val = dyn_null()
    if (props%kind /= DYN_K_DICT) return
    do k = 1, size(names)
      if (dyn_dict_has(props, trim(names(k)))) then
        val = dyn_dict_get(props, trim(names(k)))
        if (val%kind /= DYN_K_NULL) return
        val = dyn_null()
      end if
    end do
  end subroutine first_of

  !> Python float(str) for _as_number: inf / infinity / nan words,
  !! underscores between digits, decimal + exponent grammar.
  subroutine parse_py_float(s, x, ok)
    character(*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(:), allocatable :: t, low, clean
    integer :: i, ios, ndig, ndot
    logical :: neg
    ok = .false.
    x = 0.0_real64
    t = strip_ws(s)
    low = to_lower(t)
    neg = .false.
    if (len(low) > 0) then
      if (low(1:1) == "-") neg = .true.
    end if
    if (low == "inf" .or. low == "+inf" .or. low == "infinity" .or. &
        low == "+infinity") then
      x = ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (low == "-inf" .or. low == "-infinity") then
      x = -ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (low == "nan" .or. low == "+nan" .or. low == "-nan") then
      x = ieee_value(0.0_real64, ieee_quiet_nan)
      ok = .true.
      return
    end if
    ! Underscores are legal only between two digits.
    do i = 1, len(t)
      if (t(i:i) == "_") then
        if (i == 1 .or. i == len(t)) return
        if (t(i - 1:i - 1) < "0" .or. t(i - 1:i - 1) > "9") return
        if (t(i + 1:i + 1) < "0" .or. t(i + 1:i + 1) > "9") return
      end if
    end do
    clean = ""
    do i = 1, len(t)
      if (t(i:i) /= "_") clean = clean // t(i:i)
    end do
    ! Grammar: [+-]? (digits [. digits*] | . digits) ([eE][+-]?digits)?
    i = 1
    if (i <= len(clean)) then
      if (clean(i:i) == "+" .or. clean(i:i) == "-") i = i + 1
    end if
    ndig = 0
    ndot = 0
    do while (i <= len(clean))
      if (clean(i:i) >= "0" .and. clean(i:i) <= "9") then
        ndig = ndig + 1
        i = i + 1
      else if (clean(i:i) == "." .and. ndot == 0) then
        ndot = 1
        i = i + 1
      else
        exit
      end if
    end do
    if (ndig == 0) return
    if (i <= len(clean)) then
      if (clean(i:i) /= "e" .and. clean(i:i) /= "E") return
      i = i + 1
      if (i <= len(clean)) then
        if (clean(i:i) == "+" .or. clean(i:i) == "-") i = i + 1
      end if
      ndig = 0
      do while (i <= len(clean))
        if (clean(i:i) < "0" .or. clean(i:i) > "9") return
        ndig = ndig + 1
        i = i + 1
      end do
      if (ndig == 0) return
    end if
    if (i /= len(clean) + 1) return
    read (clean, *, iostat=ios) x
    if (ios /= 0) then
      x = 0.0_real64
      return
    end if
    ok = .true.
  end subroutine parse_py_float

  !> _as_number(value): bool passes through; int/real become real;
  !! a string becomes float(str.strip()) when parseable and passes
  !! through unchanged otherwise; anything else passes through.
  subroutine as_number(value, out)
    type(dyn), intent(in) :: value
    type(dyn), intent(out) :: out
    real(real64) :: x
    logical :: ok
    select case (value%kind)
    case (DYN_K_BOOL)
      out = dyn_copy(value)
    case (DYN_K_INT)
      out = dyn_real(real(value%i, real64))
    case (DYN_K_REAL)
      out = dyn_copy(value)
    case (DYN_K_STR)
      if (allocated(value%s)) then
        call parse_py_float(value%s, x, ok)
      else
        ok = .false.
      end if
      if (ok) then
        out = dyn_real(x)
      else
        out = dyn_copy(value)
      end if
    case default
      out = dyn_copy(value)
    end select
  end subroutine as_number

  !> Is v a Python number (int/float, not bool) after _as_number?
  pure logical function is_number(v)
    type(dyn), intent(in) :: v
    is_number = (v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL)
  end function is_number

  !> float(v) for a dyn known to be int/real.
  pure real(real64) function num_val(v)
    type(dyn), intent(in) :: v
    if (v%kind == DYN_K_INT) then
      num_val = real(v%i, real64)
    else
      num_val = v%r
    end if
  end function num_val

  !> _vec3(value): coerce to a 3-element dyn list, ok=.false. when
  !! Python returns None.  Components are _as_number-converted
  !! where possible and otherwise passed through unchanged.
  subroutine vec3_of(value, out, ok)
    type(dyn), intent(in) :: value
    type(dyn), intent(out) :: out
    logical, intent(out) :: ok
    type(dyn) :: lowered, comp
    type(char_list) :: parts
    character(:), allocatable :: replaced
    integer :: k
    out = dyn_null()
    ok = .false.
    select case (value%kind)
    case (DYN_K_STR)
      if (.not. allocated(value%s)) return
      replaced = ""
      do k = 1, len(value%s)
        if (value%s(k:k) == ",") then
          replaced = replaced // " "
        else
          replaced = replaced // value%s(k:k)
        end if
      end do
      call split_ws(replaced, parts)
      if (char_list_len(parts) /= 3) return
      out = dyn_list()
      do k = 1, 3
        call as_number(dyn_str(char_list_at(parts, k)), comp)
        call dyn_list_push(out, comp)
      end do
      ok = .true.
    case (DYN_K_DICT)
      call lower_keys(value, lowered)
      if (.not. dyn_dict_has(lowered, "x")) return
      if (.not. dyn_dict_has(lowered, "y")) return
      if (.not. dyn_dict_has(lowered, "z")) return
      out = dyn_list()
      do k = 1, 3
        call as_number(dyn_dict_get(lowered, &
             achar(119 + k)), comp)
        call dyn_list_push(out, comp)
      end do
      ok = .true.
    case (DYN_K_LIST)
      if (dyn_list_len(value) < 3) return
      out = dyn_list()
      do k = 1, 3
        call as_number(dyn_list_at(value, k), comp)
        call dyn_list_push(out, comp)
      end do
      ok = .true.
    case default
      ! Python: objects with x/y/z attributes; dyn scalars and
      ! null have none, so they coerce to None.
      return
    end select
  end subroutine vec3_of

  !> Python round() on a real64: round-half-even, result as integer.
  pure integer function py_round(x)
    real(real64), intent(in) :: x
    real(real64) :: f, frac
    integer(int64) :: n
    f = floor(x)
    frac = x - f
    if (frac > 0.5_real64) then
      n = int(f, int64) + 1_int64
    else if (frac < 0.5_real64) then
      n = int(f, int64)
    else if (mod(int(f, int64), 2_int64) == 0_int64) then
      n = int(f, int64)
    else
      n = int(f, int64) + 1_int64
    end if
    py_round = int(n)
  end function py_round

  pure integer function hex_val(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    if (c >= iachar("0") .and. c <= iachar("9")) then
      hex_val = c - iachar("0")
    else if (c >= iachar("a") .and. c <= iachar("f")) then
      hex_val = c - iachar("a") + 10
    else if (c >= iachar("A") .and. c <= iachar("F")) then
      hex_val = c - iachar("A") + 10
    else
      hex_val = -1
    end if
  end function hex_val

  !> Match ^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\)$
  !! case-insensitively (ASCII \s / \d subsets).
  subroutine match_rgb(text, rgb, ok)
    character(*), intent(in) :: text
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: ok
    character(:), allocatable :: low
    integer :: pos, part, ndig, v
    ok = .false.
    rgb = 0
    low = to_lower(text)
    if (len(low) < 4) return
    if (low(1:4) /= "rgb(") return
    pos = 5
    do part = 1, 3
      do while (pos <= len(low))
        if (.not. is_ws(low(pos:pos))) exit
        pos = pos + 1
      end do
      ndig = 0
      v = 0
      do while (pos <= len(low) .and. ndig < 4)
        if (low(pos:pos) < "0" .or. low(pos:pos) > "9") exit
        v = v * 10 + (iachar(low(pos:pos)) - iachar("0"))
        ndig = ndig + 1
        pos = pos + 1
      end do
      if (ndig == 0 .or. ndig > 3) return
      rgb(part) = v
      do while (pos <= len(low))
        if (.not. is_ws(low(pos:pos))) exit
        pos = pos + 1
      end do
      if (part < 3) then
        if (pos > len(low)) return
        if (low(pos:pos) /= ",") return
        pos = pos + 1
      end if
    end do
    if (pos > len(low)) return
    if (low(pos:pos) /= ")") return
    pos = pos + 1
    if (pos /= len(low) + 1) return
    ok = .true.
  end subroutine match_rgb

  !> _parse_color(value): resolve to (r, g, b) ints, ok=.false.
  !! when Python returns None.
  subroutine parse_color_dyn(value, rgb, ok)
    type(dyn), intent(in) :: value
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: ok
    type(dyn) :: number
    character(:), allocatable :: text, low
    integer :: k, hi, lo
    ok = .false.
    rgb = 0
    select case (value%kind)
    case (DYN_K_LIST)
      if (dyn_list_len(value) /= 3) return
      do k = 1, 3
        call as_number(dyn_list_at(value, k), number)
        if (number%kind == DYN_K_BOOL) return
        if (.not. is_number(number)) return
        if (.not. (0.0_real64 <= num_val(number) .and. &
                   num_val(number) <= 255.0_real64)) return
        rgb(k) = py_round(num_val(number))
      end do
      ok = .true.
    case (DYN_K_STR)
      if (.not. allocated(value%s)) return
      ! Local path: strip, strip quote chars, strip again.
      text = strip_ws(value%s)
      do while (len(text) > 0)
        if (text(1:1) /= '"' .and. text(1:1) /= "'") exit
        if (len(text) == 1) then
          text = ""
        else
          text = text(2:)
        end if
      end do
      do while (len(text) > 0)
        if (text(len(text):len(text)) /= '"' .and. &
            text(len(text):len(text)) /= "'") exit
        if (len(text) == 1) then
          text = ""
        else
          text = text(1:len(text) - 1)
        end if
      end do
      text = strip_ws(text)
      low = to_lower(text)
      do k = 1, N_COLORS
        if (low == trim(COLOR_NAMES(k))) then
          rgb = COLOR_RGB(:, k)
          ok = .true.
          return
        end if
      end do
      if (len(text) == 7 .and. text(1:1) == "#") then
        ok = .true.
        do k = 1, 3
          hi = hex_val(text(2 * k:2 * k))
          lo = hex_val(text(2 * k + 1:2 * k + 1))
          if (hi < 0 .or. lo < 0) then
            ok = .false.
            return
          end if
          rgb(k) = hi * 16 + lo
        end do
        return
      end if
      call match_rgb(text, rgb, ok)
      if (ok) then
        do k = 1, 3
          if (rgb(k) < 0 .or. rgb(k) > 255) ok = .false.
        end do
      end if
    case default
      ! Python: ColourLit-style objects resolve via attributes;
      ! dyn dicts/scalars carry none, so they return None.
      return
    end select
  end subroutine parse_color_dyn

  ! ----------------------------------------------------------------
  ! Python "%.6g" % float(x) -- the .scene float spelling (_fmt)
  ! ----------------------------------------------------------------

  !> Round a 17-significant-digit string to 6 significant digits
  !! (round-half-even on the digit string, C printf semantics).
  subroutine round6(digits, ndig, exp10)
    character(*), intent(inout) :: digits
    integer, intent(inout) :: ndig, exp10
    integer :: i
    logical :: up
    if (ndig <= 6) return
    up = .false.
    if (digits(7:7) > "5") then
      up = .true.
    else if (digits(7:7) == "5") then
      up = .false.
      do i = 8, ndig
        if (digits(i:i) /= "0") up = .true.
      end do
      if (.not. up) then
        ! Exactly half: round to even.
        up = (index("13579", digits(6:6)) > 0)
      end if
    end if
    ndig = 6
    if (up) then
      i = 6
      do while (i >= 1)
        if (digits(i:i) == "9") then
          digits(i:i) = "0"
          i = i - 1
        else
          digits(i:i) = achar(iachar(digits(i:i)) + 1)
          exit
        end if
      end do
      if (i == 0) then
        digits(1:1) = "1"
        ndig = 1
        exp10 = exp10 + 1
      end if
    end if
  end subroutine round6

  !> "%.6g" % float(x), byte-identical to CPython for real64.
  !! (Python renders NaN as "nan" regardless of its sign bit.)
  function fmt_6g(x) result(out)
    real(real64), intent(in) :: x
    character(:), allocatable :: out
    character(len=64) :: buf
    character(len=32) :: digits
    character(len=16) :: ebuf
    integer :: exp10, ndig, i, j, epos
    if (ieee_is_nan(x)) then
      out = "nan"
      return
    end if
    if (.not. ieee_is_finite(x)) then
      if (ieee_is_negative(x)) then
        out = "-inf"
      else
        out = "inf"
      end if
      return
    end if
    if (x == 0.0_real64) then
      if (ieee_is_negative(x)) then
        out = "-0"
      else
        out = "0"
      end if
      return
    end if
    write (buf, "(ES25.16E3)") abs(x)
    epos = index(buf, "E")
    digits = ""
    j = 0
    do i = 1, epos - 1
      if (buf(i:i) >= "0" .and. buf(i:i) <= "9") then
        j = j + 1
        digits(j:j) = buf(i:i)
      end if
    end do
    ndig = j
    read (buf(epos + 1:), *) exp10
    call round6(digits, ndig, exp10)
    do while (ndig > 1 .and. digits(ndig:ndig) == "0")
      ndig = ndig - 1
    end do
    if (exp10 >= -4 .and. exp10 < 6) then
      if (exp10 >= 0) then
        if (ndig > exp10 + 1) then
          out = digits(1:exp10 + 1) // "." // digits(exp10 + 2:ndig)
        else
          out = digits(1:ndig) // repeat("0", exp10 + 1 - ndig)
        end if
      else
        out = "0." // repeat("0", -exp10 - 1) // digits(1:ndig)
      end if
    else
      if (ndig > 1) then
        out = digits(1:1) // "." // digits(2:ndig)
      else
        out = digits(1:1)
      end if
      if (exp10 >= 0) then
        write (ebuf, "(I0)") exp10
        out = out // "e+"
      else
        write (ebuf, "(I0)") -exp10
        out = out // "e-"
      end if
      if (len_trim(ebuf) < 2) out = out // "0"
      out = out // trim(ebuf)
    end if
    if (ieee_is_negative(x)) out = "-" // out
  end function fmt_6g

  !> _fmt(value): "%.6g" of _as_number(value); "0" for non-numbers.
  function fmt_dyn(value) result(out)
    type(dyn), intent(in) :: value
    character(:), allocatable :: out
    type(dyn) :: number
    call as_number(value, number)
    if (number%kind == DYN_K_BOOL .or. .not. is_number(number)) then
      out = "0"
    else
      out = fmt_6g(num_val(number))
    end if
  end function fmt_dyn

  !> _fmt_vec(vec): space-joined _fmt of the components.
  function fmt_vec(vec) result(out)
    type(dyn), intent(in) :: vec
    character(:), allocatable :: out
    integer :: k
    out = ""
    do k = 1, dyn_list_len(vec)
      if (k > 1) out = out // " "
      out = out // fmt_dyn(dyn_list_at(vec, k))
    end do
  end function fmt_vec

  !> _fmt_color(color): "%d %d %d" of _parse_color(color), with
  !! DEFAULT_COLOR when unparseable.
  function fmt_color(value) result(out)
    type(dyn), intent(in) :: value
    character(:), allocatable :: out
    character(len=32) :: buf
    integer :: rgb(3)
    logical :: ok
    call parse_color_dyn(value, rgb, ok)
    if (.not. ok) rgb = DEFAULT_COLOR
    write (buf, "(I0,1X,I0,1X,I0)") rgb(1), rgb(2), rgb(3)
    out = trim(buf)
  end function fmt_color

  ! ----------------------------------------------------------------
  ! Python str() / repr() of dyn values (message interpolation)
  ! ----------------------------------------------------------------

  !> Python repr() of a string (quote choice + escapes), mirroring
  !! the ASCII subset used by f3dc_validate's repr_str.
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
        block
          character(len=2) :: hb
          character(len=16), parameter :: HD = "0123456789abcdef"
          hb(1:1) = HD(c / 16 + 1:c / 16 + 1)
          hb(2:2) = HD(mod(c, 16) + 1:mod(c, 16) + 1)
          body = body // "\x" // hb
        end block
      else
        body = body // s(k:k)
      end if
    end do
    out = quote // body // quote
  end function repr_str

  !> Python str(value) of a dyn (str(float) == repr(float)).
  recursive function py_str_dyn(val) result(out)
    type(dyn), intent(in) :: val
    character(:), allocatable :: out
    integer :: k
    select case (val%kind)
    case (DYN_K_STR)
      if (allocated(val%s)) then
        out = val%s
      else
        out = ""
      end if
    case (DYN_K_BOOL)
      if (val%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = fmt_int(val%i)
    case (DYN_K_REAL)
      out = fmt_real(val%r)
    case (DYN_K_LIST)
      out = "("
      do k = 1, dyn_list_len(val)
        if (k > 1) out = out // ", "
        out = out // py_repr_dyn(dyn_list_at(val, k))
      end do
      if (dyn_list_len(val) == 1) out = out // ","
      out = out // ")"
    case (DYN_K_DICT)
      out = "{"
      do k = 1, dyn_dict_len(val)
        if (k > 1) out = out // ", "
        out = out // repr_str(dyn_dict_key_at(val, k)) // ": " // &
              py_repr_dyn(dyn_dict_value_at(val, k))
      end do
      out = out // "}"
    case default
      out = "None"
    end select
  end function py_str_dyn

  !> Python repr(value) of a dyn (%r in the ext messages).
  recursive function py_repr_dyn(val) result(out)
    type(dyn), intent(in) :: val
    character(:), allocatable :: out
    if (val%kind == DYN_K_STR) then
      if (allocated(val%s)) then
        out = repr_str(val%s)
      else
        out = "''"
      end if
    else
      out = py_str_dyn(val)
    end if
  end function py_repr_dyn

  ! ================================================================
  ! Shared extraction: at / size / color (_extract_common)
  ! ================================================================

  subroutine extract_common(props, d)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: d
    type(dyn) :: lowered, raw, at, xyz, size, colorv
    integer :: rgb(3)
    logical :: ok
    integer :: k
    call lower_keys(props, lowered)
    call first_of(lowered, [character(12) :: "at", "position", &
                            "pos"], raw)
    call vec3_of(raw, at, ok)
    if (.not. ok) then
      if (dyn_dict_has(lowered, "x") .or. &
          dyn_dict_has(lowered, "y") .or. &
          dyn_dict_has(lowered, "z")) then
        xyz = dyn_dict()
        do k = 1, 3
          if (dyn_dict_has(lowered, achar(119 + k))) then
            call dyn_dict_set(xyz, achar(119 + k), &
                              dyn_dict_get(lowered, achar(119 + k)))
          else
            call dyn_dict_set(xyz, achar(119 + k), dyn_null())
          end if
        end do
        call vec3_of(xyz, at, ok)
      end if
    end if
    if (.not. ok) then
      at = dyn_list()
      call dyn_list_push(at, dyn_real(0.0_real64))
      call dyn_list_push(at, dyn_real(0.0_real64))
      call dyn_list_push(at, dyn_real(0.0_real64))
    end if
    call first_of(lowered, [character(12) :: "size"], raw)
    if (raw%kind == DYN_K_NULL) then
      size = dyn_real(DEFAULT_SIZE)
    else
      call as_number(raw, size)
    end if
    call first_of(lowered, [character(12) :: "color", "colour", &
                            "color_raw", "colour_raw", &
                            "color_value", "colour_value"], raw)
    call parse_color_dyn(raw, rgb, ok)
    if (.not. ok) rgb = DEFAULT_COLOR
    colorv = dyn_list()
    do k = 1, 3
      call dyn_list_push(colorv, dyn_int(int(rgb(k), int64)))
    end do
    d = dyn_dict()
    call dyn_dict_set(d, "at", at)
    call dyn_dict_set(d, "size", size)
    call dyn_dict_set(d, "color", colorv)
  end subroutine extract_common

  !> _clean_text(value): unquote, single-space, keep case.
  function clean_text(value) result(out)
    type(dyn), intent(in) :: value
    character(:), allocatable :: out, text
    type(char_list) :: parts
    integer :: k
    if (value%kind == DYN_K_NULL) then
      out = ""
      return
    end if
    if (value%kind == DYN_K_STR) then
      if (allocated(value%s)) then
        text = value%s
      else
        text = ""
      end if
    else
      ! Python: attribute spellings (value/text/content) on objects,
      ! else str(value); dyn non-strings take the str() path.
      text = py_str_dyn(value)
    end if
    text = strip_ws(text)
    if (len(text) >= 2) then
      if (text(1:1) == text(len(text):len(text)) .and. &
          (text(1:1) == '"' .or. text(1:1) == "'")) then
        if (len(text) == 2) then
          text = ""
        else
          text = text(2:len(text) - 1)
        end if
      end if
    end if
    call split_ws(text, parts)
    out = ""
    do k = 1, char_list_len(parts)
      if (k > 1) out = out // " "
      out = out // char_list_at(parts, k)
    end do
  end function clean_text

  !> _text_of(d): the content string of a normalised text dict.
  function text_of(d) result(out)
    type(dyn), intent(in) :: d
    character(:), allocatable :: out
    type(dyn) :: v
    integer :: k
    character(8) :: keys(2)
    out = ""
    if (d%kind /= DYN_K_DICT) return
    keys = [character(8) :: "content", "text"]
    do k = 1, 2
      if (.not. dyn_dict_has(d, trim(keys(k)))) cycle
      v = dyn_dict_get(d, trim(keys(k)))
      if (v%kind == DYN_K_STR) then
        if (allocated(v%s)) out = v%s
        return
      else if (v%kind /= DYN_K_NULL) then
        out = py_str_dyn(v)
        return
      end if
    end do
  end function text_of

  ! ================================================================
  ! Shared validation: at / size (_validate_common)
  ! ================================================================

  subroutine validate_common(d, errors)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: errors
    type(dyn) :: at, vec, comp, size, number
    character(:), allocatable :: axis
    integer :: k
    logical :: ok_flag
    if (d%kind /= DYN_K_DICT) return
    if (dyn_dict_has(d, "at")) then
      at = dyn_dict_get(d, "at")
      if (at%kind /= DYN_K_NULL) then
        call vec3_of(at, vec, ok_flag)
        if (.not. ok_flag) then
          call char_list_append(errors, &
               "at " // py_repr_dyn(at) // &
               " is not a position: 'at' must be three finite " // &
               "coordinates (x, y, z)")
        else
          do k = 1, 3
            axis = achar(119 + k)
            comp = dyn_list_at(vec, k)
            call as_number(comp, number)
            if (number%kind == DYN_K_BOOL .or. &
                .not. is_number(number)) then
              call char_list_append(errors, &
                   "at " // axis // " " // py_repr_dyn(comp) // &
                   " is not a number: 'at' coordinates must be " // &
                   "finite")
            else if (.not. ieee_is_finite(num_val(number))) then
              call char_list_append(errors, &
                   "at " // axis // " is " // &
                   fmt_6g(num_val(number)) // &
                   ", but 'at' coordinates must be finite")
            end if
          end do
        end if
      end if
    end if
    if (dyn_dict_has(d, "size")) then
      size = dyn_dict_get(d, "size")
      if (size%kind /= DYN_K_NULL) then
        call as_number(size, number)
        if (number%kind == DYN_K_BOOL .or. &
            .not. is_number(number)) then
          call char_list_append(errors, &
               "size " // py_repr_dyn(size) // &
               " is not a number: 'size' must be more than 0 " // &
               "and at most " // fmt_6g(ST_MAX_SIZE))
        else if (.not. ieee_is_finite(num_val(number)) .or. &
                 .not. (0.0_real64 < num_val(number) .and. &
                        num_val(number) <= ST_MAX_SIZE)) then
          call char_list_append(errors, &
               "size is " // fmt_6g(num_val(number)) // &
               ", but 'size' must be more than 0 and at most " // &
               fmt_6g(ST_MAX_SIZE))
        end if
      end if
    end if
  end subroutine validate_common

  ! ================================================================
  ! Sprites
  ! ================================================================

  !> extract_sprite(props): normalise raw sprite props into
  !! {"at": (x, y, z), "size": float, "color": (r, g, b)} with
  !! defaults at (0, 0, 0), size 1.0, color (255, 255, 255).
  subroutine extract_sprite(props, d)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: d
    call extract_common(props, d)
  end subroutine extract_sprite

  !> validate_sprite(d): size in (0, 100] and finite at coords.
  subroutine validate_sprite(d, errors)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: errors
    errors%n = 0
    call validate_common(d, errors)
  end subroutine validate_sprite

  !> sprite_line(name, d): "sprite NAME PX PY PZ SIZE R G B"
  !! with %.6g floats; missing fields fall back to the defaults.
  subroutine sprite_line(name, d, line)
    character(*), intent(in) :: name
    type(dyn), intent(in) :: d
    character(:), allocatable, intent(out) :: line
    type(dyn) :: dd, at, sizev, number
    logical :: ok
    real(real64) :: sz
    if (d%kind == DYN_K_DICT) then
      dd = dyn_copy(d)
    else
      dd = dyn_dict()
    end if
    call vec3_of(dyn_dict_get(dd, "at"), at, ok)
    if (.not. ok) then
      at = dyn_list()
      call dyn_list_push(at, dyn_real(0.0_real64))
      call dyn_list_push(at, dyn_real(0.0_real64))
      call dyn_list_push(at, dyn_real(0.0_real64))
    end if
    sizev = dyn_dict_get(dd, "size")
    call as_number(sizev, number)
    if (number%kind == DYN_K_BOOL .or. .not. is_number(number)) then
      sz = DEFAULT_SIZE
    else
      sz = num_val(number)
    end if
    line = "sprite " // name // " " // fmt_vec(at) // " " // &
           fmt_6g(sz) // " " // fmt_color(dyn_dict_get(dd, "color"))
  end subroutine sprite_line

  ! ================================================================
  ! Text
  ! ================================================================

  !> extract_text(props): as extract_sprite, plus the content read
  !! from the first present of content / text / label / value /
  !! string / caption / text_content, stored under both "text"
  !! and "content" (unquoted, single-spaced, case preserved).
  subroutine extract_text(props, d)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: d
    type(dyn) :: lowered, raw
    character(:), allocatable :: content
    call lower_keys(props, lowered)
    call extract_common(lowered, d)
    call first_of(lowered, [character(12) :: "content", "text", &
                            "label", "value", "string", "caption", &
                            "text_content"], raw)
    content = clean_text(raw)
    call dyn_dict_set(d, "text", dyn_str(content))
    call dyn_dict_set(d, "content", dyn_str(content))
  end subroutine extract_text

  !> validate_text(d): the at/size checks, plus content required,
  !! at most 200 characters, and only font-drawable characters.
  subroutine validate_text(d, errors)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: errors
    character(:), allocatable :: content, ch
    type(char_list) :: seen
    integer :: i, j
    logical :: dup
    errors%n = 0
    call validate_common(d, errors)
    content = text_of(d)
    if (len(strip_ws(content)) == 0) then
      call char_list_append(errors, &
           "text is empty: text content must not be empty " // &
           "(a quoted string is required)")
      return
    end if
    if (len(content) > ST_MAX_TEXT_LEN) then
      call char_list_append(errors, &
           "text is " // trim(fmt_int(int(len(content), int64))) // &
           " characters, but 'text' must be at most " // &
           trim(fmt_int(int(ST_MAX_TEXT_LEN, int64))) // &
           " characters")
    end if
    seen%n = 0
    do i = 1, len(content)
      ch = content(i:i)
      if (allowed_char(ch)) cycle
      dup = .false.
      do j = 1, char_list_len(seen)
        if (char_list_at(seen, j) == ch) dup = .true.
      end do
      if (.not. dup) call char_list_append(seen, ch)
    end do
    do j = 1, char_list_len(seen)
      ch = char_list_at(seen, j)
      call char_list_append(errors, &
           "text contains unsupported character " // &
           repr_str(ch) // &
           ": the text font supports only " // &
           repr_str(ST_TEXT_CHARSET) // " plus lowercase letters")
    end do
  end subroutine validate_text

  pure logical function allowed_char(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    allowed_char = (c >= iachar("a") .and. c <= iachar("z")) .or. &
                   index(ST_TEXT_CHARSET, ch) > 0
  end function allowed_char

  !> text_line(name, d): "text NAME PX PY PZ SIZE R G B CONTENT"
  !! with %.6g floats; CONTENT is single-spaced, case preserved,
  !! and omitted entirely when empty.
  subroutine text_line(name, d, line)
    character(*), intent(in) :: name
    type(dyn), intent(in) :: d
    character(:), allocatable, intent(out) :: line
    type(dyn) :: dd, at, sizev, number
    type(char_list) :: parts
    character(:), allocatable :: content, head
    logical :: ok
    real(real64) :: sz
    integer :: k
    if (d%kind == DYN_K_DICT) then
      dd = dyn_copy(d)
    else
      dd = dyn_dict()
    end if
    call vec3_of(dyn_dict_get(dd, "at"), at, ok)
    if (.not. ok) then
      at = dyn_list()
      call dyn_list_push(at, dyn_real(0.0_real64))
      call dyn_list_push(at, dyn_real(0.0_real64))
      call dyn_list_push(at, dyn_real(0.0_real64))
    end if
    sizev = dyn_dict_get(dd, "size")
    call as_number(sizev, number)
    if (number%kind == DYN_K_BOOL .or. .not. is_number(number)) then
      sz = DEFAULT_SIZE
    else
      sz = num_val(number)
    end if
    head = "text " // name // " " // fmt_vec(at) // " " // &
           fmt_6g(sz) // " " // fmt_color(dyn_dict_get(dd, "color"))
    call split_ws(text_of(dd), parts)
    content = ""
    do k = 1, char_list_len(parts)
      if (k > 1) content = content // " "
      content = content // char_list_at(parts, k)
    end do
    if (len(content) > 0) then
      line = head // " " // content
    else
      line = head
    end if
  end subroutine text_line

end module f3dc_ext_sprites_text
