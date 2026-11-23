! f3dc_ext_post -- Forge3D Wave C extension: post `filter` chain.
!
! Faithful Fortran port of tools/f3dc/ext_post.py (494 lines), per
! compiler/DESIGN.md.  Python is the oracle; function names and
! behaviour mirror the Python module one-to-one:
!
!   extract_post(props)  -> dict     subroutine extract_post(src, out)
!   validate_post(d)     -> [str]    subroutine validate_post(d, errs)
!   post_line(d)         -> str      subroutine post_line(d, line)
!   collect_post(items)  -> [dict]   subroutine collect_post(src, out)
!   post_lines(chain)    -> [str]    subroutine post_lines(chain, lines)
!
! dyn representation (f3dc_dyn): Python dict -> dyn dict, list/tuple
! -> dyn list, None -> dyn_null, True/False -> dyn_bool.  A token
! list is a dyn list of scalars; a source line is a dyn string.
! Token-ish objects (lexer Token with .text) have no dyn counterpart;
! in dyn form tokens are plain scalars, exactly what the compiler
! passes.
module f3dc_ext_post
  use, intrinsic :: iso_fortran_env, only: int64, real64
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
       char_list_at, char_list_clear, fmt_int, fmt_real, to_lower, &
       str_builder, sb_init, sb_add, sb_text
  implicit none
  private

  public :: extract_post, validate_post, post_line, collect_post, &
            post_lines
  public :: DEFAULT_BLUR, DEFAULT_BLOOM, DEFAULT_VIGNETTE, &
            DEFAULT_GAMMA, DEFAULT_GRAYSCALE, DEFAULT_SEPIA
  public :: FILTER_NAMES_STR

  integer(int64), parameter :: DEFAULT_BLUR = 1_int64
  real(real64), parameter :: DEFAULT_BLOOM = 0.5_real64
  real(real64), parameter :: DEFAULT_VIGNETTE = 0.5_real64
  real(real64), parameter :: DEFAULT_GAMMA = 2.2_real64
  real(real64), parameter :: DEFAULT_GRAYSCALE = 1.0_real64
  real(real64), parameter :: DEFAULT_SEPIA = 1.0_real64

  ! FILTERS in declaration order (", ".join(FILTERS) in messages).
  character(*), parameter :: FILTER_NAMES_STR = &
       "blur, bloom, vignette, gamma, grayscale, sepia"
  character(10), parameter :: FILTERS(6) = [character(10) :: &
       "blur", "bloom", "vignette", "gamma", "grayscale", "sepia"]
  character(10), parameter :: AMOUNT_KEYS(6) = [character(10) :: &
       "amount", "value", "passes", "strength", "factor", "intensity"]
  character(7), parameter :: NAME_KEYS(5) = [character(7) :: &
       "name", "filter", "type", "kind", "effect"]

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

  !> Python s.replace(",", " ").
  function comma_to_space(s) result(out)
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
  end function comma_to_space

  !> Python float(text) for the spellings _as_number can meet.
  subroutine parse_float_str(s, x, ok)
    character(*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(:), allocatable :: t, u, w
    type(str_builder) :: sb
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
    call sb_init(sb)
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
      call sb_add(sb, t(i:i))
    end do
    w = sb_text(sb)
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

  !> Python int(text): strict integer spelling (sign, digits,
  !! single underscores between digits).  Overflow passes through
  !! as failure (Python ints are unbounded; int64 is the dyn range).
  subroutine parse_int_str(s, v, ok)
    character(*), intent(in) :: s
    integer(int64), intent(out) :: v
    logical, intent(out) :: ok
    character(:), allocatable :: t, w
    type(str_builder) :: sb
    integer :: i, ios
    logical :: prev_digit, next_digit
    ok = .false.
    v = 0_int64
    t = strip_ws(s)
    if (len(t) == 0) return
    call sb_init(sb)
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
      call sb_add(sb, t(i:i))
    end do
    w = sb_text(sb)
    t = w
    do i = 1, len(t)
      if (t(i:i) >= "0" .and. t(i:i) <= "9") cycle
      if ((t(i:i) == "+" .or. t(i:i) == "-") .and. i == 1 .and. &
          len(t) > 1) cycle
      return
    end do
    read (t, *, iostat=ios) v
    ok = ios == 0
  end subroutine parse_int_str

  !> Python "%.6g" % float(x) (the .scene float spelling).
  function fmt_g6(x) result(out)
    real(real64), intent(in) :: x
    character(:), allocatable :: out
    character(64) :: buf
    character(:), allocatable :: mant, digits, ip, fp
    type(str_builder) :: sb
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
    ! Collect the significant digits (v3.0 Phase 6, C4: builder
    ! accumulation; zero-strip/padding below unchanged).
    call sb_init(sb)
    do i = 1, len(mant)
      if (mant(i:i) >= "0" .and. mant(i:i) <= "9") &
        call sb_add(sb, mant(i:i))
    end do
    digits = sb_text(sb)
    if (len(mant) >= 2) then
     if (mant(1:1) == "0" .and. mant(2:2) == ".") then
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
    if (len(digits) < 6) then
      block
        character(:), allocatable :: padded
        padded = digits // repeat("0", 6 - len(digits))
        digits = padded
      end block
    end if
    sig = exp10
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
        call sb_init(sb)
        do i = 1, -sig - 1
          call sb_add(sb, "0")
        end do
        call sb_add(sb, digits)
        fp = sb_text(sb)
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
      call sb_init(sb)
      call sb_add(sb, out)
      if (exp10 < 0) then
        call sb_add(sb, "e-")
        if (abs(exp10) < 10) call sb_add(sb, "0")
        call sb_add(sb, trim(fmt_int(int(-exp10, int64))))
      else
        call sb_add(sb, "e+")
        if (exp10 < 10) call sb_add(sb, "0")
        call sb_add(sb, trim(fmt_int(int(exp10, int64))))
      end if
      out = sb_text(sb)
    end if
    if (neg) out = "-" // out
  end function fmt_g6

  ! ================================================================
  ! Python value adapters (mirror validate.py's py_str / py_repr)
  ! ================================================================

  recursive function py_str_of(val) result(out)
    type(dyn), intent(in) :: val
    character(:), allocatable :: out, acc
    type(str_builder) :: sb
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
      call sb_init(sb)
      call sb_add(sb, "(")
      do k = 1, dyn_list_len(val)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, py_repr_of(dyn_list_at(val, k)))
      end do
      if (dyn_list_len(val) == 1) call sb_add(sb, ",")
      acc = sb_text(sb)
      out = acc // ")"
    case (DYN_K_DICT)
      call sb_init(sb)
      call sb_add(sb, "{")
      do k = 1, dyn_dict_len(val)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, repr_str(dyn_dict_key_at(val, k)))
        call sb_add(sb, ": ")
        call sb_add(sb, py_repr_of(dyn_dict_value_at(val, k)))
      end do
      acc = sb_text(sb)
      out = acc // "}"
    case default
      out = "None"
    end select
  end function py_str_of

  function repr_str(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out, body
    type(str_builder) :: sb
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
    call sb_init(sb)
    do k = 1, len(s)
      c = iachar(s(k:k))
      if (s(k:k) == "\") then
        call sb_add(sb, "\\")
      else if (s(k:k) == quote) then
        call sb_add(sb, "\")
        call sb_add(sb, quote)
      else if (c == 10) then
        call sb_add(sb, "\n")
      else if (c == 13) then
        call sb_add(sb, "\r")
      else if (c == 9) then
        call sb_add(sb, "\t")
      else if (c < 32 .or. c == 127) then
        call sb_add(sb, "\x")
        call sb_add(sb, hex2(c))
      else
        call sb_add(sb, s(k:k))
      end if
    end do
    body = sb_text(sb)
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

  ! ================================================================
  ! Generic value helpers (ext_post.py)
  ! ================================================================

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

  !> _as_number(value).
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

  !> _as_int(value).
  function as_int(value) result(out)
    type(dyn), intent(in) :: value
    type(dyn) :: out
    real(real64) :: x
    integer(int64) :: iv
    logical :: ok
    select case (value%kind)
    case (DYN_K_BOOL)
      out = dyn_copy(value)
    case (DYN_K_INT)
      out = dyn_copy(value)
    case (DYN_K_REAL)
      if (ieee_is_finite(value%r) .and. &
          value%r == floor(value%r) .and. &
          abs(value%r) < 9.223372036854776e18_real64) then
        out = dyn_int(int(value%r, int64))
      else
        out = dyn_copy(value)
      end if
    case (DYN_K_STR)
      call parse_int_str(value%s, iv, ok)
      if (ok) then
        out = dyn_int(iv)
        return
      end if
      call parse_float_str(value%s, x, ok)
      if (ok .and. ieee_is_finite(x) .and. x == floor(x) .and. &
          abs(x) < 9.223372036854776e18_real64) then
        out = dyn_int(int(x, int64))
      else
        out = dyn_copy(value)
      end if
    case default
      out = dyn_copy(value)
    end select
  end function as_int

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

  !> _word(value): normalised filter-name word.
  function word_of(value) result(out)
    type(dyn), intent(in) :: value
    character(:), allocatable :: out
    select case (value%kind)
    case (DYN_K_STR)
      out = to_lower(strip_ws(strip_chars(strip_ws(value%s), '"''')))
    case (DYN_K_INT)
      out = to_lower(strip_ws(fmt_int(value%i)))
    case (DYN_K_REAL)
      out = to_lower(strip_ws(fmt_real(value%r)))
    case default
      ! None, bools, dicts/lists and token objects without a text
      ! payload all give "" (Python _word's fall-through).
      out = ""
    end select
  end function word_of

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

  !> _int_or(value, default).
  integer(int64) function int_or(value, default)
    type(dyn), intent(in) :: value
    integer(int64), intent(in) :: default
    type(dyn) :: num
    num = as_int(value)
    if (num%kind == DYN_K_BOOL .or. num%kind /= DYN_K_INT) then
      int_or = default
    else
      int_or = num%i
    end if
  end function int_or

  pure logical function is_filter_name(w)
    character(*), intent(in) :: w
    integer :: k
    is_filter_name = .false.
    do k = 1, size(FILTERS)
      if (w == trim(FILTERS(k))) is_filter_name = .true.
    end do
  end function is_filter_name

  !> DEFAULTS[name] as a dyn, or dyn_null for unknown names.
  function default_amount(name) result(out)
    character(*), intent(in) :: name
    type(dyn) :: out
    select case (name)
    case ("blur")
      out = dyn_int(DEFAULT_BLUR)
    case ("bloom")
      out = dyn_real(DEFAULT_BLOOM)
    case ("vignette")
      out = dyn_real(DEFAULT_VIGNETTE)
    case ("gamma")
      out = dyn_real(DEFAULT_GAMMA)
    case ("grayscale")
      out = dyn_real(DEFAULT_GRAYSCALE)
    case ("sepia")
      out = dyn_real(DEFAULT_SEPIA)
    case default
      out = dyn_null()
    end select
  end function default_amount

  !> _convert_amount(name, raw).
  function convert_amount(name, raw) result(out)
    character(*), intent(in) :: name
    type(dyn), intent(in) :: raw
    type(dyn) :: out
    if (name == "blur") then
      out = as_int(raw)
    else
      out = as_number(raw)
    end if
  end function convert_amount

  ! ================================================================
  ! Input shaping
  ! ================================================================

  !> _props_dict(props): lower-cased dict, or {} for non-dicts
  !! (dyn scalars carry none of the name/amount attributes).
  function props_dict_of(props) result(out)
    type(dyn), intent(in) :: props
    type(dyn) :: out
    if (props%kind == DYN_K_DICT) then
      out = lower_keys(props)
    else
      out = dyn_dict()
    end if
  end function props_dict_of

  !> _tokens_of(props): token list for str / list inputs; the
  !! `is_tokens` flag is Python's None return for other shapes.
  subroutine tokens_of(props, tokens, is_tokens)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: tokens
    logical, intent(out) :: is_tokens
    type(char_list) :: parts
    type(dyn) :: item, rest
    character(:), allocatable :: w
    integer :: k, j
    tokens = dyn_list()
    is_tokens = .false.
    select case (props%kind)
    case (DYN_K_STR)
      call split_ws(comma_to_space(props%s), parts)
      do k = 1, char_list_len(parts)
        call dyn_list_push(tokens, dyn_str(char_list_at(parts, k)))
      end do
      is_tokens = .true.
    case (DYN_K_LIST)
      do k = 1, dyn_list_len(props)
        item = dyn_list_at(props, k)
        select case (item%kind)
        case (DYN_K_STR)
          call split_ws(comma_to_space(item%s), parts)
          do j = 1, char_list_len(parts)
            call dyn_list_push(tokens, dyn_str(char_list_at(parts, j)))
          end do
        case (DYN_K_INT, DYN_K_REAL)
          call dyn_list_push(tokens, item)
        case default
          w = word_of(item)
          if (len(w) > 0) call dyn_list_push(tokens, dyn_str(w))
        end select
      end do
      is_tokens = .true.
    end select
    if (.not. is_tokens) return
    if (dyn_list_len(tokens) > 0) then
      item = dyn_list_at(tokens, 1)
      if (item%kind == DYN_K_STR) then
        w = to_lower(strip_ws(item%s))
        if (w == "filter" .or. w == "post") then
          rest = dyn_list()
          do k = 2, dyn_list_len(tokens)
            call dyn_list_push(rest, dyn_list_at(tokens, k))
          end do
          call dyn_assign(tokens, rest)
        end if
      end if
    end if
  end subroutine tokens_of

  ! ================================================================
  ! Extract
  ! ================================================================

  !> extract_post(props) -> {"name", "amount"}.
  subroutine extract_post(props, out)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: out
    type(dyn) :: tokens, shaped, raw_v
    logical :: is_tokens, raw_found
    character(:), allocatable :: name
    integer :: k
    call tokens_of(props, tokens, is_tokens)
    out = dyn_dict()
    if (is_tokens) then
      if (dyn_list_len(tokens) == 0) then
        call dyn_dict_set(out, "name", dyn_str(""))
        call dyn_dict_set(out, "amount", dyn_null())
        return
      end if
      name = word_of(dyn_list_at(tokens, 1))
      call dyn_dict_set(out, "name", dyn_str(name))
      if (dyn_list_len(tokens) > 1) then
        call dyn_dict_set(out, "amount", &
             convert_amount(name, dyn_list_at(tokens, 2)))
      else
        call dyn_dict_set(out, "amount", default_amount(name))
      end if
      return
    end if
    shaped = props_dict_of(props)
    call first_of(shaped, NAME_KEYS, raw_v, raw_found)
    if (raw_found) then
      name = word_of(raw_v)
    else
      name = word_of(dyn_null())
    end if
    call first_of(shaped, AMOUNT_KEYS, raw_v, raw_found)
    if (len(name) == 0) then
      do k = 1, dyn_dict_len(shaped)
        if (is_filter_name(dyn_dict_key_at(shaped, k))) then
          name = dyn_dict_key_at(shaped, k)
          if (.not. raw_found) then
            raw_v = dyn_dict_value_at(shaped, k)
            raw_found = .true.
          end if
          exit
        end if
      end do
    end if
    call dyn_dict_set(out, "name", dyn_str(name))
    if (.not. raw_found) then
      call dyn_dict_set(out, "amount", default_amount(name))
    else
      call dyn_dict_set(out, "amount", convert_amount(name, raw_v))
    end if
  end subroutine extract_post

  !> collect_post(items) -> [extract_post(item), ...] in order.
  subroutine collect_post(items, out)
    type(dyn), intent(in) :: items
    type(dyn), intent(out) :: out
    type(dyn) :: inner, one
    integer :: k, j
    logical :: all_scalar
    character(:), allocatable :: first
    character(7), parameter :: CHAIN_KEYS(3) = [character(7) :: &
         "filters", "chain", "post"]
    out = dyn_list()
    select case (items%kind)
    case (DYN_K_NULL)
      return
    case (DYN_K_DICT)
      do k = 1, 3
        inner = dyn_dict_get(items, trim(CHAIN_KEYS(k)))
        if (inner%kind == DYN_K_LIST) then
          do j = 1, dyn_list_len(inner)
            call extract_post(dyn_list_at(inner, j), one)
            call dyn_list_push(out, one)
          end do
          return
        end if
      end do
      call extract_post(items, one)
      call dyn_list_push(out, one)
    case (DYN_K_STR)
      call extract_post(items, one)
      call dyn_list_push(out, one)
    case (DYN_K_LIST)
      all_scalar = dyn_list_len(items) > 0
      do k = 1, dyn_list_len(items)
        one = dyn_list_at(items, k)
        select case (one%kind)
        case (DYN_K_STR, DYN_K_INT, DYN_K_REAL)
        case default
          all_scalar = .false.
        end select
      end do
      if (all_scalar) then
        first = word_of(dyn_list_at(items, 1))
        if (first == "filter" .or. first == "post" .or. &
            is_filter_name(first)) then
          call extract_post(items, one)
          call dyn_list_push(out, one)
          return
        end if
      end if
      do k = 1, dyn_list_len(items)
        call extract_post(dyn_list_at(items, k), one)
        call dyn_list_push(out, one)
      end do
    case default
      call extract_post(items, one)
      call dyn_list_push(out, one)
    end select
  end subroutine collect_post

  ! ================================================================
  ! Validate
  ! ================================================================

  !> validate_post(d) -> list of human-readable error strings.
  subroutine validate_post(d, errors)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: errors
    type(dyn) :: amount, value
    character(:), allocatable :: name
    real(real64) :: number
    call char_list_clear(errors)
    if (d%kind /= DYN_K_DICT) then
      call char_list_append(errors, "post " // py_repr_of(d) // &
           " is not a filter dict: a filter must have 'name' " // &
           "and 'amount'")
      return
    end if
    name = word_of(dyn_dict_get(d, "name"))
    if (len(name) == 0) then
      call char_list_append(errors, "filter has no name: " // &
           "'filter' must name one of " // FILTER_NAMES_STR)
      return
    end if
    if (.not. is_filter_name(name)) then
      call char_list_append(errors, "unknown filter " // &
           py_repr_of(dyn_dict_get(d, "name")) // &
           ": 'filter' must name one of " // FILTER_NAMES_STR)
    end if
    amount = dyn_dict_get(d, "amount")
    if (amount%kind == DYN_K_NULL) return
    if (name == "blur") then
      value = as_int(amount)
      if (value%kind == DYN_K_BOOL .or. value%kind /= DYN_K_INT) then
        call char_list_append(errors, "blur amount " // &
             py_repr_of(amount) // " is not an integer: 'blur' " // &
             "amount must be an integer number of passes at least 1")
      else if (value%i < 1_int64) then
        call char_list_append(errors, "blur amount " // &
             trim(fmt_int(value%i)) // " is out of range: 'blur' " // &
             "amount must be an integer number of passes at least 1")
      end if
      return
    end if
    value = as_number(amount)
    if (value%kind == DYN_K_BOOL .or. .not. is_number(value)) then
      call char_list_append(errors, name // " amount " // &
           py_repr_of(amount) // " is not a number: '" // name // &
           "' amount must be a finite number")
      return
    end if
    number = num_val(value)
    if (.not. ieee_is_finite(number)) then
      call char_list_append(errors, name // " amount is " // &
           fmt_g6(number) // ", but '" // name // &
           "' amount must be finite")
      return
    end if
    if (name == "grayscale" .or. name == "sepia") then
      if (number < 0.0_real64 .or. number > 1.0_real64) then
        call char_list_append(errors, name // " amount is " // &
             fmt_g6(number) // ", but '" // name // &
             "' amount must be in the range 0..1")
      end if
    else if (name == "gamma") then
      if (number <= 0.0_real64) then
        call char_list_append(errors, "gamma amount is " // &
             fmt_g6(number) // &
             ", but 'gamma' amount must be more than 0")
      end if
    else if (name == "bloom" .or. name == "vignette") then
      if (number < 0.0_real64) then
        call char_list_append(errors, name // " amount is " // &
             fmt_g6(number) // ", but '" // name // &
             "' amount must be at least 0")
      end if
    end if
  end subroutine validate_post

  ! ================================================================
  ! Emit lines
  ! ================================================================

  !> post_line(d) -> "post NAME AMOUNT".
  subroutine post_line(d, line)
    type(dyn), intent(in) :: d
    character(:), allocatable, intent(out) :: line
    type(dyn) :: dd, raw
    character(:), allocatable :: name
    if (d%kind == DYN_K_DICT) then
      call dyn_assign(dd, d)
    else
      dd = dyn_dict()
    end if
    name = word_of(dyn_dict_get(dd, "name"))
    raw = dyn_dict_get(dd, "amount")
    if (raw%kind == DYN_K_NULL) raw = default_amount(name)
    if (name == "blur") then
      line = "post " // name // " " // &
             trim(fmt_int(int_or(raw, DEFAULT_BLUR)))
    else
      line = "post " // name // " " // fmt_of(dyn_real(float_or(raw, &
             0.0_real64)))
    end if
  end subroutine post_line

  !> post_lines(chain) -> one post_line per filter, in chain order.
  subroutine post_lines(chain, lines)
    type(dyn), intent(in) :: chain
    type(char_list), intent(inout) :: lines
    character(:), allocatable :: line
    integer :: k
    call char_list_clear(lines)
    if (chain%kind /= DYN_K_LIST) return
    do k = 1, dyn_list_len(chain)
      call post_line(dyn_list_at(chain, k), line)
      call char_list_append(lines, line)
    end do
  end subroutine post_lines

end module f3dc_ext_post
