! f3dc_ext_cameras -- Forge3D Wave C extension: `camera ortho`.
!
! Faithful Fortran port of tools/f3dc/ext_cameras.py (425 lines),
! per compiler/DESIGN.md.  Python is the oracle; function names and
! behaviour mirror the Python module one-to-one:
!
!   extract_camera(props) -> dict     subroutine extract_camera(src, out)
!   validate_camera(d)    -> [str]    subroutine validate_camera(d, errs)
!   camera_lines(d)       -> [str]    subroutine camera_lines(d, lines)
!
! dyn representation (f3dc_dyn): Python dict -> dyn dict, tuple/list
! -> dyn list, None -> dyn_null, True/False -> dyn_bool.  A raw
! token sequence is a dyn list of scalars; a source line is a dyn
! string.  Duck-typed attribute objects have no dyn counterpart
! (compiler nodes are dicts), so non-dict/list/str inputs shape to
! {} exactly as Python's getattr() defaults do for scalars.
!
! Public API also includes DEFAULT_SIZE (= 5.0_real64).
module f3dc_ext_cameras
  use, intrinsic :: iso_fortran_env, only: int64, real64, error_unit
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
       ieee_is_nan, ieee_is_negative, ieee_value, ieee_quiet_nan, &
       ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, dyn_list_push, &
       dyn_list_len, dyn_list_at, dyn_dict_get, dyn_dict_set, &
       dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
       dyn_dict_value_at, DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, &
       DYN_K_REAL, DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
       char_list_at, char_list_clear, fmt_int, fmt_real, to_lower
  implicit none
  private

  public :: DEFAULT_SIZE
  public :: extract_camera, validate_camera, camera_lines
  public :: validate_camera_warnings, W_DEGENERATE_CAMERA

  real(real64), parameter :: DEFAULT_SIZE = 5.0_real64

  ! W302 (v3.0 Phase 5, completing M1): warning code for a
  ! degenerate camera -- 'at' equals 'look' (or an 'up', when a
  ! caller supplies one, parallel to the view direction).  The
  ! E3xx family is this module's error family (E302 via
  ! f3dc_validate's dispatch); W302 is its warning sibling, in
  ! the style of f3dc_optimize's module-local W510/W511 codes.
  ! A warning only: it never enters validate_camera's error
  ! list, so it cannot fail a build, and it changes no emitted
  ! artifact.
  character(4), parameter :: W_DEGENERATE_CAMERA = "W302"

  character(13), parameter :: ORTHO_WORDS(2) = [character(13) :: &
       "ortho", "orthographic"]
  character(13), parameter :: PERSP_WORDS(2) = [character(13) :: &
       "perspective", "persp"]

contains

  ! ================================================================
  ! Small string helpers (Python str.strip / split / replace)
  ! ================================================================

  pure logical function is_ws(c)
    character, intent(in) :: c
    integer :: k
    k = iachar(c)
    is_ws = k == 32 .or. k == 9 .or. k == 10 .or. k == 13 .or. &
            k == 11 .or. k == 12
  end function is_ws

  !> Python s.strip() (ASCII whitespace).
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

  !> Python s.strip(chars): drop leading/trailing chars in the set.
  function strip_chars(s, set) result(out)
    character(*), intent(in) :: s, set
    character(:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (index(set, s(a:a)) == 0) exit
      a = a + 1
    end do
    do while (b >= a)
      if (index(set, s(b:b)) == 0) exit
      b = b - 1
    end do
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_chars

  !> Python s.split(): whitespace-run split.
  subroutine split_ws(s, parts)
    character(*), intent(in) :: s
    type(char_list), intent(inout) :: parts
    integer :: i, start
    call char_list_clear(parts)
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

  !> Python float(text) for the spellings _as_number can meet.
  subroutine parse_float_str(s, x, ok)
    character(*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(:), allocatable :: t, u, w
    integer :: i, ios, ndig, ndot, nexp
    logical :: prev_digit, next_digit
    ok = .false.
    x = 0.0_real64
    t = strip_ws(s)
    u = to_lower(t)
    if (u == "inf" .or. u == "+inf" .or. u == "infinity" .or. &
        u == "+infinity") then
      x = ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (u == "-inf" .or. u == "-infinity") then
      x = -ieee_value(0.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (u == "nan" .or. u == "+nan" .or. u == "-nan") then
      x = ieee_value(0.0_real64, ieee_quiet_nan)
      ok = .true.
      return
    end if
    ! Python float() accepts single underscores between digits.
    w = ""
    do i = 1, len(t)
      if (t(i:i) == "_") then
        prev_digit = (i > 1)
        if (prev_digit) prev_digit = (t(i - 1:i - 1) >= "0" .and. &
                                      t(i - 1:i - 1) <= "9")
        next_digit = (i < len(t))
        if (next_digit) next_digit = (t(i + 1:i + 1) >= "0" .and. &
                                      t(i + 1:i + 1) <= "9")
        if (.not. (prev_digit .and. next_digit)) return
        cycle
      end if
      w = w // t(i:i)
    end do
    t = w
    if (len(t) == 0) return
    ndig = 0
    ndot = 0
    nexp = 0
    do i = 1, len(t)
      select case (t(i:i))
      case ("0":"9")
        ndig = ndig + 1
      case (".")
        ndot = ndot + 1
        if (ndot > 1 .or. nexp > 0) return
      case ("e", "E")
        nexp = nexp + 1
        if (nexp > 1 .or. ndig == 0) return
      case ("+", "-")
        if (i /= 1) then
          if (t(i - 1:i - 1) /= "e" .and. &
              t(i - 1:i - 1) /= "E") return
        end if
      case default
        return
      end select
    end do
    if (ndig == 0) return
    if (t(len(t):len(t)) == "e" .or. t(len(t):len(t)) == "E") return
    read (t, *, iostat=ios) x
    ok = ios == 0
  end subroutine parse_float_str

  !> Python "%.6g" % float(x) (the .scene float spelling).
  function fmt_g6(x) result(out)
    real(real64), intent(in) :: x
    character(:), allocatable :: out
    character(64) :: buf
    character(:), allocatable :: mant, digits, ip, fp
    integer :: i, epos, exp10, ios, sig, zc
    logical :: neg
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
    write (buf, "(ES25.5E3)") x
    mant = strip_ws(buf)
    epos = index(mant, "E")
    read (mant(epos + 1:), *, iostat=ios) exp10
    if (ios /= 0) exp10 = 0
    mant = mant(:epos - 1)
    neg = .false.
    if (len(mant) > 0) then
      if (mant(1:1) == "-") then
        neg = .true.
        mant = mant(2:)
      else if (mant(1:1) == "+") then
        mant = mant(2:)
      end if
    end if
    ! mant is d.ddddd (ES) -- collect the 6 significant digits.
    digits = ""
    do i = 1, len(mant)
      if (mant(i:i) >= "0" .and. mant(i:i) <= "9") digits = digits // mant(i:i)
    end do
    if (len(mant) >= 2) then
     if (mant(1:1) == "0" .and. mant(2:2) == ".") then
      ! 0.ddddd form: value is 0.digits * 10**exp10.
      exp10 = exp10 - 1
      zc = 0
      do i = 1, len(digits)
        if (digits(i:i) /= "0") exit
        zc = zc + 1
      end do
      if (zc > 0) then
        digits = digits(zc + 1:)
        exp10 = exp10 - zc
      end if
     end if
    end if
    do while (len(digits) < 6)
      digits = digits // "0"
    end do
    sig = exp10  ! decimal exponent of the d.ddd form
    if (sig >= -4 .and. sig < 6) then
      if (sig >= 0) then
        ip = digits(:sig + 1)
        fp = digits(sig + 2:)
        do while (len(fp) > 0)
          if (fp(len(fp):len(fp)) /= "0") exit
          fp = fp(:len(fp) - 1)
        end do
        if (len(fp) > 0) then
          out = ip // "." // fp
        else
          out = ip
        end if
      else
        fp = ""
        do i = 1, -sig - 1
          fp = fp // "0"
        end do
        fp = fp // digits
        do while (len(fp) > 0)
          if (fp(len(fp):len(fp)) /= "0") exit
          fp = fp(:len(fp) - 1)
        end do
        out = "0." // fp
      end if
    else
      fp = digits(2:)
      do while (len(fp) > 0)
        if (fp(len(fp):len(fp)) /= "0") exit
        fp = fp(:len(fp) - 1)
      end do
      if (len(fp) > 0) then
        out = digits(1:1) // "." // fp
      else
        out = digits(1:1)
      end if
      if (exp10 < 0) then
        out = out // "e-"
        if (abs(exp10) < 10) out = out // "0"
        out = out // trim(fmt_int(int(-exp10, int64)))
      else
        out = out // "e+"
        if (exp10 < 10) out = out // "0"
        out = out // trim(fmt_int(int(exp10, int64)))
      end if
    end if
    if (neg) out = "-" // out
  end function fmt_g6

  ! ================================================================
  ! Python value adapters (mirror validate.py's py_str / py_repr)
  ! ================================================================

  recursive function py_str_of(val) result(out)
    type(dyn), intent(in) :: val
    character(:), allocatable :: out, acc
    integer :: k
    select case (val%kind)
    case (DYN_K_STR)
      out = val%s
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
      acc = "("
      do k = 1, dyn_list_len(val)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr_of(dyn_list_at(val, k))
      end do
      if (dyn_list_len(val) == 1) acc = acc // ","
      out = acc // ")"
    case (DYN_K_DICT)
      acc = "{"
      do k = 1, dyn_dict_len(val)
        if (k > 1) acc = acc // ", "
        acc = acc // repr_str(dyn_dict_key_at(val, k)) // ": " // &
              py_repr_of(dyn_dict_value_at(val, k))
      end do
      out = acc // "}"
    case default
      out = "None"
    end select
  end function py_str_of

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

  function hex2(c) result(out)
    integer, intent(in) :: c
    character(2) :: out
    character(16), parameter :: HD = "0123456789abcdef"
    out(1:1) = HD(c / 16 + 1:c / 16 + 1)
    out(2:2) = HD(mod(c, 16) + 1:mod(c, 16) + 1)
  end function hex2

  recursive function py_repr_of(val) result(out)
    type(dyn), intent(in) :: val
    character(:), allocatable :: out
    if (val%kind == DYN_K_STR) then
      out = repr_str(val%s)
    else
      out = py_str_of(val)
    end if
  end function py_repr_of

  pure logical function py_truthy(val)
    type(dyn), intent(in) :: val
    select case (val%kind)
    case (DYN_K_BOOL)
      py_truthy = val%b
    case (DYN_K_INT)
      py_truthy = val%i /= 0_int64
    case (DYN_K_REAL)
      py_truthy = val%r /= 0.0_real64
    case (DYN_K_STR)
      py_truthy = len(val%s) > 0
    case (DYN_K_LIST)
      py_truthy = val%n_items > 0
    case (DYN_K_DICT)
      py_truthy = val%n_entries > 0
    case default
      py_truthy = .false.
    end select
  end function py_truthy

  ! ================================================================
  ! Generic value helpers (ext_cameras.py)
  ! ================================================================

  !> _lower_keys(props): copy with string keys lower-cased.
  function lower_keys(props) result(out)
    type(dyn), intent(in) :: props
    type(dyn) :: out
    integer :: k
    out = dyn_dict()
    if (props%kind /= DYN_K_DICT) return
    do k = 1, dyn_dict_len(props)
      call dyn_dict_set(out, to_lower(dyn_dict_key_at(props, k)), &
                        dyn_dict_value_at(props, k))
    end do
  end function lower_keys

  !> _first(props, *names): first present, non-None value.
  subroutine first_of(props, names, val, found)
    type(dyn), intent(in) :: props
    character(*), intent(in) :: names(:)
    type(dyn), intent(out) :: val
    logical, intent(out) :: found
    integer :: k
    val = dyn_null()
    found = .false.
    if (props%kind /= DYN_K_DICT) return
    do k = 1, size(names)
      if (dyn_dict_has(props, trim(names(k)))) then
        val = dyn_dict_get(props, trim(names(k)))
        if (val%kind /= DYN_K_NULL) then
          found = .true.
          return
        end if
        val = dyn_null()
      end if
    end do
  end subroutine first_of

  !> _as_number(value): bool passes through; int/real -> real;
  !! numeric string -> real; anything else passes through.
  function as_number(value) result(out)
    type(dyn), intent(in) :: value
    type(dyn) :: out
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
      call parse_float_str(value%s, x, ok)
      if (ok) then
        out = dyn_real(x)
      else
        out = dyn_copy(value)
      end if
    case default
      out = dyn_copy(value)
    end select
  end function as_number

  pure logical function is_number(v)
    type(dyn), intent(in) :: v
    is_number = v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL
  end function is_number

  pure real(real64) function num_val(v)
    type(dyn), intent(in) :: v
    if (v%kind == DYN_K_INT) then
      num_val = real(v%i, real64)
    else
      num_val = v%r
    end if
  end function num_val

  !> _vec3(value): coerce to a 3-list of _as_number components.
  subroutine vec3_of(value, out, ok)
    type(dyn), intent(in) :: value
    type(dyn), intent(out) :: out
    logical, intent(out) :: ok
    type(dyn) :: lowered, comp
    type(char_list) :: parts
    integer :: k
    out = dyn_null()
    ok = .false.
    select case (value%kind)
    case (DYN_K_STR)
      call split_ws(str_replace_comma(value%s), parts)
      if (char_list_len(parts) /= 3) return
      out = dyn_list()
      do k = 1, 3
        call dyn_list_push(out, as_number(dyn_str(char_list_at(parts, k))))
      end do
      ok = .true.
    case (DYN_K_DICT)
      lowered = lower_keys(value)
      if (.not. dyn_dict_has(lowered, "x") .or. &
          .not. dyn_dict_has(lowered, "y") .or. &
          .not. dyn_dict_has(lowered, "z")) return
      out = dyn_list()
      comp = dyn_dict_get(lowered, "x")
      call dyn_list_push(out, as_number(comp))
      comp = dyn_dict_get(lowered, "y")
      call dyn_list_push(out, as_number(comp))
      comp = dyn_dict_get(lowered, "z")
      call dyn_list_push(out, as_number(comp))
      ok = .true.
    case (DYN_K_LIST)
      if (dyn_list_len(value) < 3) return
      out = dyn_list()
      do k = 1, 3
        call dyn_list_push(out, as_number(dyn_list_at(value, k)))
      end do
      ok = .true.
    end select
  end subroutine vec3_of

  !> Python value.replace(",", " ") for the _vec3 string branch.
  function str_replace_comma(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    integer :: i
    allocate (character(len=len(s)) :: out)
    do i = 1, len(s)
      if (s(i:i) == ",") then
        out(i:i) = " "
      else
        out(i:i) = s(i:i)
      end if
    end do
  end function str_replace_comma

  !> _fmt(value): "%.6g" of a number, else "0".
  function fmt_of(value) result(out)
    type(dyn), intent(in) :: value
    character(:), allocatable :: out
    type(dyn) :: num
    num = as_number(value)
    if (num%kind == DYN_K_BOOL .or. .not. is_number(num)) then
      out = "0"
    else
      out = fmt_g6(num_val(num))
    end if
  end function fmt_of

  !> _float_or(value, default).
  real(real64) function float_or(value, default)
    type(dyn), intent(in) :: value
    real(real64), intent(in) :: default
    type(dyn) :: num
    num = as_number(value)
    if (num%kind == DYN_K_BOOL .or. .not. is_number(num)) then
      float_or = default
    else
      float_or = num_val(num)
    end if
  end function float_or

  ! ================================================================
  ! Input normalisation
  ! ================================================================

  !> _props_from_tokens over an already-split word list.
  function props_from_words(words) result(props)
    type(char_list), intent(in) :: words
    type(dyn) :: props
    character(:), allocatable :: raw, word, key, inline
    integer :: i, n, eqpos
    props = dyn_dict()
    n = char_list_len(words)
    i = 1
    do while (i <= n)
      raw = char_list_at(words, i)
      word = to_lower(strip_ws(raw))
      eqpos = index(word, "=")
      if (eqpos > 0) then
        key = word(:eqpos - 1)
        inline = word(eqpos + 1:)
        if (key == "size" .or. key == "at" .or. key == "look" .or. &
            key == "fov" .or. key == "near" .or. key == "far" .or. &
            key == "type") then
          call dyn_dict_set(props, key, dyn_str(inline))
          i = i + 1
          cycle
        end if
      end if
      if (word == "ortho" .or. word == "orthographic") then
        call dyn_dict_set(props, "ortho", dyn_bool(.true.))
        i = i + 1
      else if (word == "perspective" .or. word == "persp") then
        call dyn_dict_set(props, "type", dyn_str("perspective"))
        i = i + 1
      else if (word == "size" .or. word == "at" .or. word == "look") then
        if (i + 1 <= n) then
          call dyn_dict_set(props, word, dyn_str(char_list_at(words, i + 1)))
          i = i + 2
        else
          i = i + 1
        end if
      else if (word == "fov" .or. word == "near" .or. word == "far") then
        if (i + 1 <= n) then
          i = i + 2
        else
          i = i + 1
        end if
      else
        i = i + 1
      end if
    end do
  end function props_from_words

  !> _props_from_tokens for a whole-line string input.
  function props_from_line(line) result(props)
    character(*), intent(in) :: line
    type(dyn) :: props
    type(char_list) :: toks, joined
    character(:), allocatable :: t
    integer :: i, n
    t = ""
    do i = 1, len(line)
      if (line(i:i) == ",") then
        t = t // " , "
      else
        t = t // line(i:i)
      end if
    end do
    call split_ws(t, toks)
    call char_list_clear(joined)
    n = char_list_len(toks)
    i = 1
    do while (i <= n)
      if (i + 3 < n + 1 .and. i + 4 <= n) then
        if (char_list_at(toks, i + 1) == "," .and. &
            char_list_at(toks, i + 3) == ",") then
          call char_list_append(joined, char_list_at(toks, i) // "," // &
               char_list_at(toks, i + 2) // "," // char_list_at(toks, i + 4))
          i = i + 5
          cycle
        end if
      end if
      call char_list_append(joined, char_list_at(toks, i))
      i = i + 1
    end do
    props = props_from_words(joined)
  end function props_from_line

  !> _props_from(source): dict / token list / line string / other.
  function props_from(source) result(props)
    type(dyn), intent(in) :: source
    type(dyn) :: props
    type(char_list) :: words
    integer :: k
    select case (source%kind)
    case (DYN_K_DICT)
      props = lower_keys(source)
    case (DYN_K_LIST)
      call char_list_clear(words)
      do k = 1, dyn_list_len(source)
        call char_list_append(words, py_str_of(dyn_list_at(source, k)))
      end do
      props = props_from_words(words)
    case (DYN_K_STR)
      props = props_from_line(source%s)
    case default
      props = dyn_dict()
    end select
  end function props_from

  !> _camera_type(props): default perspective.
  function camera_type_of(props) result(out)
    type(dyn), intent(in) :: props
    character(:), allocatable :: out, w
    type(dyn) :: raw
    integer :: k
    character(12), parameter :: NAMES(5) = [character(12) :: &
         "type", "camera_type", "kind", "mode", "projection"]
    do k = 1, size(NAMES)
      raw = dyn_dict_get(props, trim(NAMES(k)))
      if (raw%kind == DYN_K_STR) then
        w = to_lower(strip_ws(strip_chars(strip_ws(raw%s), '"''')))
        if (w == "ortho" .or. w == "orthographic") then
          out = "ortho"
          return
        end if
        if (w == "perspective" .or. w == "persp") then
          out = "perspective"
          return
        end if
      end if
    end do
    raw = dyn_dict_get(props, "ortho")
    if (raw%kind == DYN_K_STR) then
      w = to_lower(strip_ws(raw%s))
      if (w /= "" .and. w /= "false" .and. w /= "no" .and. w /= "0") then
        out = "ortho"
        return
      end if
    else if (py_truthy(raw)) then
      out = "ortho"
      return
    end if
    if (py_truthy(dyn_dict_get(props, "perspective"))) then
      out = "perspective"
      return
    end if
    out = "perspective"
  end function camera_type_of

  !> _position(props, *names): vec3 or the raw value passed through.
  subroutine position_of(props, names, out)
    type(dyn), intent(in) :: props
    character(*), intent(in) :: names(:)
    type(dyn), intent(out) :: out
    type(dyn) :: vec
    logical :: ok
    integer :: k
    out = dyn_null()
    do k = 1, size(names)
      if (dyn_dict_has(props, trim(names(k)))) then
        out = dyn_dict_get(props, trim(names(k)))
        if (out%kind == DYN_K_NULL) then
          out = dyn_null()
          cycle
        end if
        call vec3_of(out, vec, ok)
        if (ok) call dyn_assign(out, vec)
        return
      end if
    end do
    out = dyn_null()
  end subroutine position_of

  ! ================================================================
  ! Extract
  ! ================================================================

  !> extract_camera(props) -> {"type", "size", "at", "look"}.
  subroutine extract_camera(source, out)
    type(dyn), intent(in) :: source
    type(dyn), intent(out) :: out
    type(dyn) :: props, size, pos
    logical :: found
    props = props_from(source)
    out = dyn_dict()
    call dyn_dict_set(out, "type", dyn_str(camera_type_of(props)))
    call first_of(props, [character(10) :: "size", "ortho_size"], &
                  size, found)
    if (.not. found) size = dyn_null()
    if (found) size = as_number(size)
    if (size%kind == DYN_K_NULL) then
      size = as_number(dyn_dict_get(props, "ortho"))
      if (.not. is_number(size)) size = dyn_null()
    end if
    if (size%kind == DYN_K_NULL) size = dyn_real(DEFAULT_SIZE)
    call dyn_dict_set(out, "size", size)
    call position_of(props, [character(9) :: "at", "position", &
                     "pos", "eye"], pos)
    call dyn_dict_set(out, "at", pos)
    call position_of(props, [character(8) :: "look", "target", &
                     "look_at"], pos)
    call dyn_dict_set(out, "look", pos)
  end subroutine extract_camera

  ! ================================================================
  ! Validate
  ! ================================================================

  subroutine validate_position(errors, d, key)
    type(char_list), intent(inout) :: errors
    type(dyn), intent(in) :: d
    character(*), intent(in) :: key
    type(dyn) :: v, vec, comp, num
    logical :: ok
    integer :: j
    character(1), parameter :: AXES(3) = ["x", "y", "z"]
    if (.not. dyn_dict_has(d, key)) return
    v = dyn_dict_get(d, key)
    if (v%kind == DYN_K_NULL) return
    call vec3_of(v, vec, ok)
    if (.not. ok) then
      call char_list_append(errors, key // " " // py_repr_of(v) // &
           " is not a position: '" // key // "' must be three " // &
           "finite coordinates (x, y, z)")
      return
    end if
    do j = 1, 3
      comp = dyn_list_at(vec, j)
      num = as_number(comp)
      if (num%kind == DYN_K_BOOL .or. .not. is_number(num)) then
        call char_list_append(errors, key // " " // AXES(j) // " " // &
             py_repr_of(comp) // " is not a number: '" // key // &
             "' coordinates must be finite")
      else if (.not. ieee_is_finite(num_val(num))) then
        call char_list_append(errors, key // " " // AXES(j) // &
             " is " // fmt_g6(num_val(num)) // ", but '" // key // &
             "' coordinates must be finite")
      end if
    end do
  end subroutine validate_position

  !> Numeric vec3 for key in d: ok=.false. when the key is
  !! absent, null, not coercible to a vec3, or any component is
  !! not a finite number (those cases are validate_camera's
  !! error territory, never a warning's).
  subroutine numeric_vec3(d, key, xyz, ok)
    type(dyn), intent(in) :: d
    character(*), intent(in) :: key
    real(real64), intent(out) :: xyz(3)
    logical, intent(out) :: ok
    type(dyn) :: v, vec, num
    integer :: j
    xyz = 0.0_real64
    ok = .false.
    if (.not. dyn_dict_has(d, key)) return
    v = dyn_dict_get(d, key)
    if (v%kind == DYN_K_NULL) return
    call vec3_of(v, vec, ok)
    if (.not. ok) return
    ok = .false.
    do j = 1, 3
      num = as_number(dyn_list_at(vec, j))
      if (num%kind == DYN_K_BOOL .or. .not. is_number(num)) return
      if (.not. ieee_is_finite(num_val(num))) return
      xyz(j) = num_val(num)
    end do
    ok = .true.
  end subroutine numeric_vec3

  !> validate_camera_warnings(d) -> list of human-readable
  !! WARNING strings (v3.0 Phase 5, M1 diagnostic path).  Kept
  !! separate from validate_camera's error list: the caller in
  !! f3dc_validate turns every entry of that list into an E302
  !! error, and a degenerate camera must warn, never fail.
  !! Detects, after extract_camera's normal parsing:
  !!   * 'at' exactly equal to 'look' -- the camera has no view
  !!     direction (the engine's mat4_look_at cannot form one).
  !!   * an 'up' vector (anti-)parallel to (look - at), using
  !!     the engine guard's threshold |dot| > 1 - 1e-10.  The
  !!     ext-camera DSL itself exposes no 'up' setting (the
  !!     token parser accepts only size/at/look/fov/near/far/
  !!     type, and extract_camera drops anything else), so this
  !!     half fires only when a programmatic caller supplies
  !!     'up' in d; the DSL's main camera line, which does take
  !!     'up', is validated in f3dc_validate (where at == look
  !!     is already the E401 error).
  subroutine validate_camera_warnings(d, warnings)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: warnings
    real(real64) :: at(3), look(3), up(3), dir(3)
    real(real64) :: dn, un, cosang
    logical :: ok_at, ok_look, ok_up
    call char_list_clear(warnings)
    if (d%kind /= DYN_K_DICT) return
    call numeric_vec3(d, "at", at, ok_at)
    call numeric_vec3(d, "look", look, ok_look)
    if (.not. (ok_at .and. ok_look)) return
    if (all(at == look)) then
      call char_list_append(warnings, &
           "camera 'at' (" // fmt_g6(at(1)) // ", " // &
           fmt_g6(at(2)) // ", " // fmt_g6(at(3)) // &
           ") equals 'look': the camera has no view direction " // &
           "(degenerate camera)")
      return
    end if
    call numeric_vec3(d, "up", up, ok_up)
    if (.not. ok_up) return
    dir = look - at
    dn = sqrt(sum(dir * dir))
    un = sqrt(sum(up * up))
    if (dn <= 0.0_real64 .or. un <= 0.0_real64) return
    cosang = sum(dir * up) / (dn * un)
    if (abs(cosang) > 1.0_real64 - 1.0e-10_real64) then
      call char_list_append(warnings, &
           "camera 'up' is parallel to the view direction " // &
           "(degenerate camera; the engine will substitute a " // &
           "fallback up)")
    end if
  end subroutine validate_camera_warnings

  !> validate_camera(d) -> list of human-readable error strings.
  subroutine validate_camera(d, errors)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: errors
    type(dyn) :: tv, sv, num
    type(char_list) :: warns
    character(:), allocatable :: word
    integer :: wi
    call char_list_clear(errors)
    if (d%kind /= DYN_K_DICT) return
    tv = dyn_dict_get(d, "type")
    if (tv%kind == DYN_K_NULL .and. &
        py_truthy(dyn_dict_get(d, "ortho"))) tv = dyn_str("ortho")
    if (tv%kind /= DYN_K_NULL) then
      word = to_lower(strip_ws(py_str_of(tv)))
      if (word == "ortho" .or. word == "orthographic") word = "ortho"
      if (word == "perspective" .or. word == "persp") &
        word = "perspective"
      if (word /= "ortho" .and. word /= "perspective") then
        call char_list_append(errors, "type " // py_repr_of(tv) // &
             " is not a camera type: 'type' must be 'ortho' or " // &
             "'perspective'")
      end if
    end if
    if (dyn_dict_has(d, "size")) then
      sv = dyn_dict_get(d, "size")
      if (sv%kind /= DYN_K_NULL) then
        num = as_number(sv)
        if (num%kind == DYN_K_BOOL .or. .not. is_number(num)) then
          call char_list_append(errors, "size " // py_repr_of(sv) // &
               " is not a number: 'size' must be more than 0")
        else if (.not. ieee_is_finite(num_val(num)) .or. &
                 num_val(num) <= 0.0_real64) then
          call char_list_append(errors, "size is " // &
               fmt_g6(num_val(num)) // &
               ", but 'size' must be more than 0")
        end if
      end if
    end if
    call validate_position(errors, d, "at")
    call validate_position(errors, d, "look")
    ! M1 diagnostic (v3.0 Phase 5): degenerate-camera warnings
    ! go straight to stderr in the compiler's "warning Wxxx:"
    ! format (cf. the corpus stderr spelling).  They are NOT
    ! added to `errors`: f3dc_validate's dispatch maps every
    ! entry there to a build-failing E302, and a warning must
    ! not fail the build or change any artifact.
    call validate_camera_warnings(d, warns)
    do wi = 1, char_list_len(warns)
      write (error_unit, "(A)") "warning " // W_DEGENERATE_CAMERA // &
           ": " // char_list_at(warns, wi)
    end do
  end subroutine validate_camera

  ! ================================================================
  ! Emit lines
  ! ================================================================

  !> camera_lines(d): ["ortho SIZE"] for ortho cameras, else none.
  subroutine camera_lines(d, lines)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: lines
    type(dyn) :: tv
    character(:), allocatable :: ctype
    call char_list_clear(lines)
    if (d%kind /= DYN_K_DICT) return
    tv = dyn_dict_get(d, "type")
    if (tv%kind == DYN_K_NULL) then
      ctype = camera_type_of(lower_keys(d))
    else
      ctype = to_lower(strip_ws(py_str_of(tv)))
    end if
    if (ctype /= "ortho" .and. ctype /= "orthographic") return
    call char_list_append(lines, "ortho " // &
         fmt_of(dyn_real(float_or(dyn_dict_get(d, "size"), &
                                  DEFAULT_SIZE))))
  end subroutine camera_lines

end module f3dc_ext_cameras
