! f3dc_ext_lights_env.f90 -- Wave A extension: point/spot lights +
! scene environment (fog / tonemap / shadow).
!
! Port of tools/f3dc/ext_lights_env.py (658 lines, read in full).
! Function-by-function mirror, same names as the Python:
!
!   extract_light_ext(props)            -> dyn dict payload
!   validate_light_ext(kind, ext, msgs) -> char_list of message strs
!   light_line(kind, ext, color, intensity, line, found)
!   extract_env(props)                  -> dyn dict payload
!   validate_env(env, msgs)             -> char_list of message strs
!   env_lines(env, lines)               -> char_list of .scene lines
!
! Python lists/tuples are dyn lists; Python None is dyn_null; Python
! dicts are dyn dicts (insertion order preserved, as in Python).
! validate_* return Python's list[str]; the caller (f3dc_validate
! dispatch) wraps each message in an E302 diagnostic.  light_line's
! Python None return is found=.false. here.
!
! The Python module is pure and bag-free: colours resolve through
! f3dc_ir.ir_parse_color_nobag (the frozen ir_nodes.parse_color
! contract the Python _parse_color delegates to), with the module's
! own local fallback table/grammar applied when the frozen parser
! raises, exactly as in Python.
!
! No type-bound procedures anywhere (flang build rule).
module f3dc_ext_lights_env
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
                      ieee_is_nan, ieee_value, ieee_positive_inf, &
                      ieee_quiet_nan
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
                      char_list_at, char_list_clear, to_lower, &
                      fmt_int, fmt_real, str_builder, sb_init, &
                      sb_add, sb_text
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, dyn_dict_get, &
                      dyn_dict_set, dyn_dict_has, dyn_dict_len, &
                      dyn_dict_key_at, dyn_dict_value_at, &
                      dyn_list_push, dyn_list_len, dyn_list_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_ir, only: ir_parse_color_nobag
  implicit none
  private

  public :: extract_light_ext, validate_light_ext, light_line
  public :: extract_env, validate_env, env_lines
  public :: fmt_g

  ! Light-ext defaults (Three.js punctual-light defaults).
  real(real64), parameter :: DEFAULT_DISTANCE = 0.0_real64
  real(real64), parameter :: DEFAULT_DECAY = 2.0_real64
  real(real64), parameter :: DEFAULT_ANGLE = 45.0_real64
  real(real64), parameter :: DEFAULT_PENUMBRA = 0.0_real64

  ! Environment defaults.
  integer, parameter :: DEFAULT_FOG_COLOR(3) = [255, 255, 255]
  real(real64), parameter :: DEFAULT_FOG_NEAR = 0.0_real64
  real(real64), parameter :: DEFAULT_FOG_FAR = 100.0_real64
  real(real64), parameter :: DEFAULT_FOG_DENSITY = 0.05_real64
  real(real64), parameter :: DEFAULT_EXPOSURE = 1.0_real64
  real(real64), parameter :: DEFAULT_SHADOW_SIZE = 512.0_real64

  ! _NAMED_COLORS fallback table (identical to ir_nodes.NAMED_COLORS).
  integer, parameter :: N_NAMED = 13
  character(len=8), parameter :: NAMED_KEYS(N_NAMED) = [ &
    "red     ", "green   ", "blue    ", "yellow  ", "magenta ", &
    "cyan    ", "orange  ", "purple  ", "pink    ", "white   ", &
    "black   ", "gray    ", "grey    "]
  integer, parameter :: NAMED_RGB(3, N_NAMED) = reshape([ &
    220, 60, 60,    60, 220, 60,    60, 100, 240,  240, 220, 50, &
    200, 80, 220,   60, 220, 220,   240, 140, 40,  140, 80, 200, &
    240, 150, 190,  240, 240, 240,  20, 20, 25,    140, 140, 145, &
    140, 140, 145], [3, N_NAMED])

contains

  ! ==================================================================
  ! Generic value helpers (same tolerant shapes as validate.py's
  ! adapters, mirroring ext_lights_env's own _lower_keys/_first/_num/
  ! _vec3/_parse_color)
  ! ==================================================================

  pure logical function is_ws(c)
    character(len=1), intent(in) :: c
    is_ws = (c == " " .or. c == achar(9) .or. c == achar(10) .or. &
             c == achar(11) .or. c == achar(12) .or. c == achar(13))
  end function is_ws

  !> Python str.strip() for ASCII whitespace.
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
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws

  !> Python str.split(): split on runs of whitespace, no empties.
  subroutine split_ws(s, parts)
    character(len=*), intent(in) :: s
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
  function replace_commas(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i
    out = s
    do i = 1, len(out)
      if (out(i:i) == ",") out(i:i) = " "
    end do
  end function replace_commas

  !> Python truthiness for dyn values.
  pure logical function py_truthy(v)
    type(dyn), intent(in) :: v
    select case (v%kind)
    case (DYN_K_NULL)
      py_truthy = .false.
    case (DYN_K_BOOL)
      py_truthy = v%b
    case (DYN_K_INT)
      py_truthy = (v%i /= 0_int64)
    case (DYN_K_REAL)
      py_truthy = (v%r /= 0.0_real64)
    case (DYN_K_STR)
      py_truthy = allocated(v%s)
      if (py_truthy) py_truthy = (len(v%s) > 0)
    case (DYN_K_LIST)
      py_truthy = (v%n_items > 0)
    case (DYN_K_DICT)
      py_truthy = (v%n_entries > 0)
    case default
      py_truthy = .false.
    end select
  end function py_truthy

  !> _lower_keys(props): copy of a dict with lower-cased keys;
  !! empty dict for non-dict input.
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

  !> _first(props, *names): first value that is present and not
  !! None; found=.false. mirrors a None return.
  subroutine first_val(props, names, val, found)
    type(dyn), intent(in) :: props
    character(len=*), intent(in) :: names(:)
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
      end if
    end do
    val = dyn_null()
  end subroutine first_val

  !> Python float(text) for a string: ok=.false. on ValueError.
  !! Accepts the inf/infinity/nan words and single underscores
  !! between digits, like CPython.  (Exotic spellings CPython also
  !! accepts, e.g. underscores adjacent to the exponent marker, are
  !! not reproduced; see the port report.)
  subroutine parse_py_float(s, x, ok)
    character(len=*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, low, clean
    type(str_builder) :: sb
    integer :: i, ios, ndig
    logical :: prev_digit, next_digit
    x = 0.0_real64
    ok = .false.
    t = strip_ws(s)
    if (len(t) == 0) return
    low = to_lower(t)
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
    ! Charset + underscore validation, then a list-directed read.
    call sb_init(sb)
    ndig = 0
    do i = 1, len(t)
      if (t(i:i) == "_") then
        prev_digit = (i > 1)
        if (prev_digit) prev_digit = (t(i - 1:i - 1) >= "0" .and. &
                                      t(i - 1:i - 1) <= "9")
        next_digit = (i < len(t))
        if (next_digit) next_digit = (t(i + 1:i + 1) >= "0" .and. &
                                      t(i + 1:i + 1) <= "9")
        if (.not. (prev_digit .and. next_digit)) return
        cycle  ! drop the underscore
      end if
      if ((t(i:i) >= "0" .and. t(i:i) <= "9") .or. t(i:i) == "." &
          .or. t(i:i) == "e" .or. t(i:i) == "E" .or. t(i:i) == "+" &
          .or. t(i:i) == "-") then
        if (t(i:i) >= "0" .and. t(i:i) <= "9") ndig = ndig + 1
        call sb_add(sb, t(i:i))
      else
        return
      end if
    end do
    if (ndig == 0) return
    clean = sb_text(sb)
    read (clean, *, iostat=ios) x
    if (ios /= 0) then
      x = 0.0_real64
      return
    end if
    ok = .true.
  end subroutine parse_py_float

  !> _num(value) with default None: has=.false. mirrors None.
  subroutine num_or(val, has, x)
    type(dyn), intent(in) :: val
    logical, intent(out) :: has
    real(real64), intent(out) :: x
    has = .false.
    x = 0.0_real64
    select case (val%kind)
    case (DYN_K_INT)
      x = real(val%i, real64)
      has = .true.
    case (DYN_K_REAL)
      if (ieee_is_finite(val%r)) then
        x = val%r
        has = .true.
      end if
    case (DYN_K_STR)
      if (allocated(val%s)) then
        call parse_py_float(val%s, x, has)
        if (has .and. .not. ieee_is_finite(x)) has = .false.
        if (.not. has) x = 0.0_real64
      end if
    case default
      has = .false.
    end select
  end subroutine num_or

  !> _num(value, default): default when _num would return None.
  subroutine num_def(val, default, x)
    type(dyn), intent(in) :: val
    real(real64), intent(in) :: default
    real(real64), intent(out) :: x
    logical :: has
    call num_or(val, has, x)
    if (.not. has) x = default
  end subroutine num_def

  !> _vec3(value): has=.false. mirrors a None return.
  subroutine vec3_or(val, vec, has)
    type(dyn), intent(in) :: val
    real(real64), intent(out) :: vec(3)
    logical, intent(out) :: has
    type(char_list) :: parts
    type(dyn) :: item
    character(len=1), parameter :: AXES(3) = ["x", "y", "z"]
    integer :: k
    logical :: ok1
    has = .false.
    vec = 0.0_real64
    select case (val%kind)
    case (DYN_K_STR)
      if (.not. allocated(val%s)) return
      call split_ws(replace_commas(val%s), parts)
      if (char_list_len(parts) /= 3) return
      do k = 1, 3
        call num_or(dyn_str(char_list_at(parts, k)), ok1, vec(k))
        if (.not. ok1) return
      end do
      has = .true.
    case (DYN_K_DICT)
      do k = 1, 3
        call num_or(dyn_dict_get(val, AXES(k)), ok1, vec(k))
        if (.not. ok1) return
      end do
      has = .true.
    case (DYN_K_LIST)
      if (dyn_list_len(val) < 3) return
      do k = 1, 3
        item = dyn_list_at(val, k)
        call num_or(item, ok1, vec(k))
        if (.not. ok1) return
      end do
      has = .true.
    case default
      has = .false.
    end select
  end subroutine vec3_or

  !> Python round(): round-half-to-even, as an int64.
  pure integer(int64) function py_round_he(x)
    real(real64), intent(in) :: x
    real(real64) :: fl, frac
    integer(int64) :: base
    fl = floor(x)
    base = int(fl, int64)
    frac = x - fl
    if (frac > 0.5_real64) then
      py_round_he = base + 1_int64
    else if (frac < 0.5_real64) then
      py_round_he = base
    else if (mod(base, 2_int64) == 0_int64) then
      py_round_he = base
    else
      py_round_he = base + 1_int64
    end if
  end function py_round_he

  !> Local fallback colour grammar (ext_lights_env._NAMED_COLORS /
  !! _HEX_RE / _RGB_RE), used when the frozen ir parser raises.
  subroutine parse_color_fallback(text, rgb, has)
    character(len=*), intent(in) :: text
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: has
    character(len=:), allocatable :: t, low, inner
    type(char_list) :: parts
    integer :: k, v
    logical :: all_digits
    has = .false.
    rgb = 0
    t = strip_ws(text)
    low = to_lower(t)
    do k = 1, N_NAMED
      if (low == trim(NAMED_KEYS(k))) then
        rgb = NAMED_RGB(:, k)
        has = .true.
        return
      end if
    end do
    ! ^#([0-9a-fA-F]{6})$
    if (len(t) == 7) then
     if (t(1:1) == "#") then
      block
        logical :: okhex
        integer :: j, d
        okhex = .true.
        do j = 2, 7
          d = index("0123456789abcdef", low(j:j))
          if (d == 0) okhex = .false.
        end do
        if (okhex) then
          do k = 1, 3
            rgb(k) = (index("0123456789abcdef", low(2 * k:2 * k)) &
                      - 1) * 16 &
                     + (index("0123456789abcdef", &
                              low(2 * k + 1:2 * k + 1)) - 1)
          end do
          has = .true.
          return
        end if
      end block
     end if
    end if
    ! ^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)$
    if (len(low) >= 5) then
     if (low(1:4) == "rgb(" .and. &
        low(len(low):len(low)) == ")") then
      inner = t(5:len(t) - 1)
      block
        type(char_list) :: raw_parts
        integer :: j
        character(len=:), allocatable :: piece
        call char_list_clear(raw_parts)
        ! split on commas, keeping empty pieces (regex would fail)
        block
          integer :: start, pos
          start = 1
          do
            pos = index(inner(start:), ",")
            if (pos == 0) then
              call char_list_append(raw_parts, inner(start:))
              exit
            end if
            call char_list_append(raw_parts, &
                                  inner(start:start + pos - 2))
            start = start + pos
            if (start > len(inner) + 1) exit
            if (start == len(inner) + 1) then
              call char_list_append(raw_parts, "")
              exit
            end if
          end do
        end block
        if (char_list_len(raw_parts) /= 3) return
        do k = 1, 3
          piece = strip_ws(char_list_at(raw_parts, k))
          if (len(piece) < 1 .or. len(piece) > 3) return
          all_digits = .true.
          v = 0
          do j = 1, len(piece)
            if (piece(j:j) < "0" .or. piece(j:j) > "9") &
              all_digits = .false.
            if (all_digits) &
              v = v * 10 + (iachar(piece(j:j)) - iachar("0"))
          end do
          if (.not. all_digits) return
          rgb(k) = v
        end do
        if (any(rgb < 0) .or. any(rgb > 255)) then
          rgb = 0
          return
        end if
        has = .true.
        return
      end block
     end if
    end if
  end subroutine parse_color_fallback

  !> _parse_color(value): has=.false. mirrors a None return.
  subroutine parse_color_or(val, rgb, has)
    type(dyn), intent(in) :: val
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: has
    type(dyn) :: res, item
    logical :: is_null, raised
    character(len=:), allocatable :: msg
    real(real64) :: x
    logical :: ok1
    integer :: k
    has = .false.
    rgb = 0
    select case (val%kind)
    case (DYN_K_LIST)
      if (dyn_list_len(val) /= 3) return
      do k = 1, 3
        item = dyn_list_at(val, k)
        call num_or(item, ok1, x)
        if (.not. ok1) return
        if (x < 0.0_real64 .or. x > 255.0_real64) return
        rgb(k) = int(py_round_he(x))
      end do
      has = .true.
    case (DYN_K_STR)
      if (.not. allocated(val%s)) return
      call ir_parse_color_nobag(val, res, is_null, raised, msg)
      if (.not. is_null) then
        do k = 1, 3
          item = dyn_list_at(res, k)
          if (item%kind == DYN_K_INT) then
            rgb(k) = int(item%i)
          else if (item%kind == DYN_K_REAL) then
            rgb(k) = int(item%r)
          else
            return
          end if
        end do
        has = .true.
        return
      end if
      ! Frozen parser raised (or returned None): local fallback.
      call parse_color_fallback(val%s, rgb, has)
    case default
      has = .false.
    end select
  end subroutine parse_color_or

  ! ==================================================================
  ! Formatting: _fmt is Python "%g" % float(value)
  ! ==================================================================

  !> "%g" % float(x): 6 significant digits, trailing zeros removed,
  !! fixed notation for -4 <= decimal exponent < 6, else scientific
  !! with a signed at-least-2-digit exponent.
  function fmt_g(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=32) :: buf
    character(len=:), allocatable :: digs, mant
    integer :: epos, exp10, ios, nd
    logical :: neg
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
    neg = (transfer(x, 0_int64) < 0_int64)
    if (x == 0.0_real64) then
      if (neg) then
        out = "-0"
      else
        out = "0"
      end if
      return
    end if
    write (buf, "(ES13.5E3)", iostat=ios) abs(x)
    buf = strip_ws(buf)
    epos = index(buf, "E")
    mant = buf(1:epos - 1)              ! d.ddddd
    read (buf(epos + 1:), *, iostat=ios) exp10
    digs = mant(1:1) // mant(3:7)       ! 6 significant digits
    nd = 6
    do while (nd > 1)
      if (digs(nd:nd) /= "0") exit
      nd = nd - 1
    end do
    digs = digs(1:nd)
    if (exp10 >= -4 .and. exp10 < 6) then
      if (exp10 >= 0) then
        if (nd > exp10 + 1) then
          out = digs(1:exp10 + 1) // "." // digs(exp10 + 2:nd)
        else if (nd == exp10 + 1) then
          out = digs
        else
          out = digs // repeat("0", exp10 + 1 - nd)
        end if
      else
        out = "0." // repeat("0", -exp10 - 1) // digs
      end if
    else
      block
        character(len=:), allocatable :: es
        type(str_builder) :: sb
        call sb_init(sb)
        call sb_add(sb, digs(1:1))
        if (nd > 1) then
          call sb_add(sb, ".")
          call sb_add(sb, digs(2:nd))
        end if
        if (exp10 < 0) then
          call sb_add(sb, "e-")
        else
          call sb_add(sb, "e+")
        end if
        es = trim(fmt_int(int(abs(exp10), int64)))
        if (len(es) < 2) es = "0" // es
        call sb_add(sb, es)
        out = sb_text(sb)
      end block
    end if
    if (neg) out = "-" // out
  end function fmt_g

  !> _fmt_vec(vec): space-joined _fmt.
  function fmt_vec3(vec) result(out)
    real(real64), intent(in) :: vec(3)
    character(len=:), allocatable :: out
    out = fmt_g(vec(1)) // " " // fmt_g(vec(2)) // " " // &
          fmt_g(vec(3))
  end function fmt_vec3

  !> _fmt_color(color): "%d %d %d", white when unparseable.
  function fmt_color_of(val) result(out)
    type(dyn), intent(in) :: val
    character(len=:), allocatable :: out
    integer :: rgb(3)
    logical :: has
    call parse_color_or(val, rgb, has)
    if (.not. has) rgb = DEFAULT_FOG_COLOR
    out = trim(fmt_int(int(rgb(1), int64))) // " " // &
          trim(fmt_int(int(rgb(2), int64))) // " " // &
          trim(fmt_int(int(rgb(3), int64)))
  end function fmt_color_of

  !> Python str(value) for the two validate_env messages that use
  !! %s on the raw value.
  recursive function py_str_of(val) result(out)
    type(dyn), intent(in) :: val
    character(len=:), allocatable :: out
    integer :: k
    select case (val%kind)
    case (DYN_K_NULL)
      out = "None"
    case (DYN_K_BOOL)
      if (val%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = trim(fmt_int(val%i))
    case (DYN_K_REAL)
      out = trim(fmt_real(val%r))
    case (DYN_K_STR)
      if (allocated(val%s)) then
        out = val%s
      else
        out = ""
      end if
    case (DYN_K_LIST)
      block
        type(str_builder) :: sb
        call sb_init(sb)
        call sb_add(sb, "[")
        do k = 1, dyn_list_len(val)
          if (k > 1) call sb_add(sb, ", ")
          call sb_add(sb, py_repr_of(dyn_list_at(val, k)))
        end do
        call sb_add(sb, "]")
        out = sb_text(sb)
      end block
    case (DYN_K_DICT)
      block
        type(str_builder) :: sb
        call sb_init(sb)
        call sb_add(sb, "{")
        do k = 1, dyn_dict_len(val)
          if (k > 1) call sb_add(sb, ", ")
          call sb_add(sb, "'")
          call sb_add(sb, dyn_dict_key_at(val, k))
          call sb_add(sb, "': ")
          call sb_add(sb, py_repr_of(dyn_dict_value_at(val, k)))
        end do
        call sb_add(sb, "}")
        out = sb_text(sb)
      end block
    case default
      out = ""
    end select
  end function py_str_of

  !> Python repr(value) (used inside str() of containers).
  recursive function py_repr_of(val) result(out)
    type(dyn), intent(in) :: val
    character(len=:), allocatable :: out
    if (val%kind == DYN_K_STR) then
      if (allocated(val%s)) then
        out = "'" // val%s // "'"
      else
        out = "''"
      end if
    else
      out = py_str_of(val)
    end if
  end function py_repr_of

  !> dyn list of 3 reals (a Python float tuple) / 3 ints (colour).
  function vec3_dyn(vec) result(out)
    real(real64), intent(in) :: vec(3)
    type(dyn) :: out
    out = dyn_list()
    call dyn_list_push(out, dyn_real(vec(1)))
    call dyn_list_push(out, dyn_real(vec(2)))
    call dyn_list_push(out, dyn_real(vec(3)))
  end function vec3_dyn

  function rgb_dyn(rgb) result(out)
    integer, intent(in) :: rgb(3)
    type(dyn) :: out
    out = dyn_list()
    call dyn_list_push(out, dyn_int(int(rgb(1), int64)))
    call dyn_list_push(out, dyn_int(int(rgb(2), int64)))
    call dyn_list_push(out, dyn_int(int(rgb(3), int64)))
  end function rgb_dyn

  ! ==================================================================
  ! Point / spot lights
  ! ==================================================================

  !> extract_light_ext(props) -> normalised light extension dict.
  subroutine extract_light_ext(props_in, ext)
    type(dyn), intent(in) :: props_in
    type(dyn), intent(out) :: ext
    type(dyn) :: props, nested, merged, v
    real(real64) :: vec(3), x
    logical :: found, has
    integer :: k
    props = lower_keys(props_in)
    ! A coordinator may nest the extension dict; flat keys win.
    nested = dyn_dict_get(props, "ext")
    if (.not. py_truthy(nested)) &
      nested = dyn_dict_get(props, "light_ext")
    if (nested%kind == DYN_K_DICT) then
      merged = lower_keys(nested)
      do k = 1, dyn_dict_len(props)
        call dyn_dict_set(merged, dyn_dict_key_at(props, k), &
                          dyn_dict_value_at(props, k))
      end do
      call dyn_assign(props, merged)
    end if
    ext = dyn_dict()
    call first_val(props, [character(len=16) :: "at", "position", &
                           "from"], v, found)
    call vec3_or(v, vec, has)
    if (has) then
      call dyn_dict_set(ext, "position", vec3_dyn(vec))
    else
      call dyn_dict_set(ext, "position", dyn_null())
    end if
    call first_val(props, [character(len=16) :: "look", "target", &
                           "look_at"], v, found)
    call vec3_or(v, vec, has)
    if (has) then
      call dyn_dict_set(ext, "target", vec3_dyn(vec))
    else
      call dyn_dict_set(ext, "target", dyn_null())
    end if
    call first_val(props, [character(len=16) :: "distance", &
                           "range"], v, found)
    call num_def(v, DEFAULT_DISTANCE, x)
    call dyn_dict_set(ext, "distance", dyn_real(x))
    call first_val(props, [character(len=16) :: "decay"], v, found)
    call num_def(v, DEFAULT_DECAY, x)
    call dyn_dict_set(ext, "decay", dyn_real(x))
    call first_val(props, [character(len=16) :: "angle"], v, found)
    call num_def(v, DEFAULT_ANGLE, x)
    call dyn_dict_set(ext, "angle", dyn_real(x))
    call first_val(props, [character(len=16) :: "penumbra"], v, &
                   found)
    call num_def(v, DEFAULT_PENUMBRA, x)
    call dyn_dict_set(ext, "penumbra", dyn_real(x))
  end subroutine extract_light_ext

  !> validate_light_ext(kind, ext) -> list of error message strings.
  subroutine validate_light_ext(kind_in, ext_in, msgs)
    character(len=*), intent(in) :: kind_in
    type(dyn), intent(in) :: ext_in
    type(char_list), intent(inout) :: msgs
    character(len=:), allocatable :: kind
    type(dyn) :: ext, v
    real(real64) :: x
    logical :: has
    kind = to_lower(strip_ws(kind_in))
    if (ext_in%kind == DYN_K_DICT) then
      call dyn_assign(ext, ext_in)
    else
      ext = dyn_dict()
    end if
    if (kind == "point" .or. kind == "spot") then
      v = dyn_dict_get(ext, "position")
      if (v%kind == DYN_K_NULL) call char_list_append(msgs, &
        kind // " light requires a position: 'position' must be " // &
        "given (via 'at' or 'from')")
    end if
    if (kind == "spot") then
      v = dyn_dict_get(ext, "target")
      if (v%kind == DYN_K_NULL) call char_list_append(msgs, &
        "spot light requires a target: 'target' must be given " // &
        "(via 'look' or 'target')")
    end if
    call num_or(dyn_dict_get(ext, "angle"), has, x)
    if (has .and. .not. (x > 0.0_real64 .and. &
                         x < 180.0_real64)) &
      call char_list_append(msgs, &
        "angle is " // fmt_g(x) // ", but 'angle' must be between " // &
        "0 and 180 degrees (exclusive)")
    call num_or(dyn_dict_get(ext, "penumbra"), has, x)
    if (has .and. .not. (x >= 0.0_real64 .and. &
                         x <= 1.0_real64)) &
      call char_list_append(msgs, &
        "penumbra is " // fmt_g(x) // ", but 'penumbra' must be " // &
        "between 0 and 1")
    call num_or(dyn_dict_get(ext, "distance"), has, x)
    if (has .and. x < 0.0_real64) &
      call char_list_append(msgs, &
        "distance is " // fmt_g(x) // ", but 'distance' must be 0 " // &
        "or more (0 means no cutoff)")
    call num_or(dyn_dict_get(ext, "decay"), has, x)
    if (has .and. x < 0.0_real64) &
      call char_list_append(msgs, &
        "decay is " // fmt_g(x) // ", but 'decay' must be 0 or more")
  end subroutine validate_light_ext

  !> light_line(kind, ext, color, intensity): the .scene line, or
  !! found=.false. when Python returns None.
  subroutine light_line(kind_in, ext_in, color, intensity, line, &
                        found)
    character(len=*), intent(in) :: kind_in
    type(dyn), intent(in) :: ext_in, color
    real(real64), intent(in) :: intensity
    character(len=:), allocatable, intent(out) :: line
    logical, intent(out) :: found
    character(len=:), allocatable :: kind, head
    type(dyn) :: ext
    real(real64) :: position(3), target(3), delta(3), direction(3)
    real(real64) :: distance, decay, angle, penumbra, length
    logical :: has
    line = ""
    found = .false.
    kind = to_lower(strip_ws(kind_in))
    if (kind /= "point" .and. kind /= "spot") return
    if (ext_in%kind == DYN_K_DICT) then
      call dyn_assign(ext, ext_in)
    else
      ext = dyn_dict()
    end if
    call vec3_or(dyn_dict_get(ext, "position"), position, has)
    if (.not. has) return
    call num_def(dyn_dict_get(ext, "distance"), DEFAULT_DISTANCE, &
                 distance)
    call num_def(dyn_dict_get(ext, "decay"), DEFAULT_DECAY, decay)
    head = "light " // kind // " " // fmt_vec3(position) // " " // &
           fmt_color_of(color) // " " // fmt_g(intensity)
    if (kind == "point") then
      line = head // " " // fmt_g(distance) // " " // fmt_g(decay)
      found = .true.
      return
    end if
    ! spot
    call vec3_or(dyn_dict_get(ext, "target"), target, has)
    if (.not. has) return
    delta = target - position
    length = sqrt(sum(delta * delta))
    if (length == 0.0_real64 .or. &
        .not. ieee_is_finite(length)) return
    direction = delta / length
    call num_def(dyn_dict_get(ext, "angle"), DEFAULT_ANGLE, angle)
    call num_def(dyn_dict_get(ext, "penumbra"), DEFAULT_PENUMBRA, &
                 penumbra)
    line = "light spot " // fmt_vec3(position) // " " // &
           fmt_vec3(direction) // " " // fmt_color_of(color) // &
           " " // fmt_g(intensity) // " " // fmt_g(distance) // &
           " " // fmt_g(decay) // " " // fmt_g(angle) // " " // &
           fmt_g(penumbra)
    found = .true.
  end subroutine light_line

  ! ==================================================================
  ! Scene environment: fog / tonemap / shadow
  ! ==================================================================

  !> _clause_words(value): split a clause string to a dict.  Bare
  !! words become True flags; key/value pairs (numeric or colour
  !! value) are consumed as pairs.
  subroutine clause_words(value, out)
    character(len=*), intent(in) :: value
    type(dyn), intent(out) :: out
    type(char_list) :: toks
    character(len=:), allocatable :: word, nxt
    integer :: i, rgb(3)
    logical :: has_num, has_col
    real(real64) :: xv
    out = dyn_dict()
    call split_ws(replace_commas(value), toks)
    i = 1
    do while (i <= char_list_len(toks))
      word = to_lower(char_list_at(toks, i))
      if (i + 1 <= char_list_len(toks)) then
        nxt = char_list_at(toks, i + 1)
        call num_or(dyn_str(nxt), has_num, xv)
        call parse_color_or(dyn_str(nxt), rgb, has_col)
        if (has_num .or. has_col) then
          call dyn_dict_set(out, word, dyn_str(nxt))
          i = i + 2
          cycle
        end if
      end if
      call dyn_dict_set(out, word, dyn_bool(.true.))
      i = i + 1
    end do
  end subroutine clause_words

  !> _mode_word(value, *dict_keys): a mode word from a str / dict /
  !! bool prop value; found=.false. mirrors a None return.
  subroutine mode_word(val, key1, key2, word, found)
    type(dyn), intent(in) :: val
    character(len=*), intent(in) :: key1, key2
    character(len=:), allocatable, intent(out) :: word
    logical, intent(out) :: found
    type(char_list) :: toks
    type(dyn) :: lowered, w
    character(len=16) :: keys(2)
    integer :: k
    word = ""
    found = .false.
    select case (val%kind)
    case (DYN_K_STR)
      if (.not. allocated(val%s)) return
      block
        character(len=:), allocatable :: t
        t = strip_ws(to_lower(val%s))
        if (len(t) == 0) return
        call split_ws(t, toks)
        word = char_list_at(toks, 1)
        found = .true.
      end block
    case (DYN_K_DICT)
      lowered = lower_keys(val)
      keys = [character(len=16) :: key1, key2]
      do k = 1, 2
        w = dyn_dict_get(lowered, trim(keys(k)))
        if (w%kind == DYN_K_STR .and. allocated(w%s)) then
          if (len(strip_ws(w%s)) > 0) then
            word = to_lower(strip_ws(w%s))
            found = .true.
            return
          end if
        end if
      end do
    case (DYN_K_BOOL)
      if (val%b) then
        word = "on"
      else
        word = "off"
      end if
      found = .true.
    end select
  end subroutine mode_word

  !> _sub_props(props, primary, *aliases): merged sub-prop dict for
  !! a clause: string words + dict forms, in key order.
  subroutine sub_props(props, names, merged)
    type(dyn), intent(in) :: props
    character(len=*), intent(in) :: names(:)
    type(dyn), intent(out) :: merged
    type(dyn) :: v, part
    integer :: k, j
    merged = dyn_dict()
    do k = 1, size(names)
      v = dyn_dict_get(props, trim(names(k)))
      if (v%kind == DYN_K_DICT) then
        part = lower_keys(v)
        do j = 1, dyn_dict_len(part)
          call dyn_dict_set(merged, dyn_dict_key_at(part, j), &
                            dyn_dict_value_at(part, j))
        end do
      else if (v%kind == DYN_K_STR .and. allocated(v%s)) then
        call clause_words(v%s, part)
        do j = 1, dyn_dict_len(part)
          call dyn_dict_set(merged, dyn_dict_key_at(part, j), &
                            dyn_dict_value_at(part, j))
        end do
      end if
    end do
  end subroutine sub_props

  !> _TONEMAP_ALIASES lookup.
  function tonemap_alias(mode) result(out)
    character(len=*), intent(in) :: mode
    character(len=:), allocatable :: out
    select case (mode)
    case ("", "off", "none")
      out = "none"
    case ("reinhard")
      out = "reinhard"
    case ("aces", "acesfilmic", "aces_filmic", "aces-filmic")
      out = "aces"
    case default
      out = mode
    end select
  end function tonemap_alias

  !> Python str(value or default).strip().lower() for a mode field.
  function mode_str_of(val, default) result(out)
    type(dyn), intent(in) :: val
    character(len=*), intent(in) :: default
    character(len=:), allocatable :: out, s
    if (.not. py_truthy(val)) then
      s = default
    else if (val%kind == DYN_K_STR .and. allocated(val%s)) then
      s = val%s
    else
      s = py_str_of(val)
    end if
    out = to_lower(strip_ws(s))
  end function mode_str_of

  !> ^[+-]?\d+$ full match (the shadow clause-string size token).
  pure logical function is_int_token(s)
    character(len=*), intent(in) :: s
    integer :: i, start
    is_int_token = .false.
    if (len(s) == 0) return
    start = 1
    if (s(1:1) == "+" .or. s(1:1) == "-") start = 2
    if (start > len(s)) return
    do i = start, len(s)
      if (s(i:i) < "0" .or. s(i:i) > "9") return
    end do
    is_int_token = .true.
  end function is_int_token

  subroutine extract_fog(props, fog)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: fog
    type(dyn) :: raw, sub, v, dh
    character(len=:), allocatable :: mode
    logical :: have_mode, has_detail, found, has
    integer :: rgb(3), k
    real(real64) :: near, far, density
    character(len=16), parameter :: DETAIL_FLAT(7) = [ &
      character(len=16) :: "fog_near", "fog_far", "fog_density", &
      "fog_color", "near", "far", "density"]
    character(len=16), parameter :: DETAIL_SUB(4) = [ &
      character(len=16) :: "near", "far", "density", "color"]
    fog = dyn_null()
    call first_val(props, [character(len=16) :: "fog"], raw, found)
    if (raw%kind == DYN_K_BOOL .and. .not. raw%b) return
    call sub_props(props, [character(len=16) :: "fog"], sub)
    have_mode = .false.
    mode = ""
    v = dyn_null()
    call first_val(props, [character(len=16) :: "fog_mode"], v, &
                   found)
    if (found .and. v%kind == DYN_K_STR .and. allocated(v%s)) then
      if (len(strip_ws(v%s)) > 0) then
        mode = v%s
        have_mode = .true.
      end if
    end if
    if (.not. have_mode) &
      call mode_word(raw, "mode", "kind", mode, have_mode)
    if (.not. have_mode) then
      if (raw%kind == DYN_K_BOOL .and. raw%b) then
        mode = "linear"
        have_mode = .true.
      end if
    end if
    ! Any fog_* detail key implies fog even without an explicit mode.
    has_detail = .false.
    do k = 1, size(DETAIL_FLAT)
      if (dyn_dict_has(props, trim(DETAIL_FLAT(k)))) then
        v = dyn_dict_get(props, trim(DETAIL_FLAT(k)))
        if (v%kind /= DYN_K_NULL) has_detail = .true.
      end if
    end do
    do k = 1, size(DETAIL_SUB)
      if (dyn_dict_has(sub, trim(DETAIL_SUB(k)))) then
        v = dyn_dict_get(sub, trim(DETAIL_SUB(k)))
        if (v%kind /= DYN_K_NULL) has_detail = .true.
      end if
    end do
    if (.not. have_mode .and. has_detail) then
      call first_val(props, [character(len=16) :: "fog_density", &
                             "density"], dh, found)
      if (.not. found) dh = dyn_dict_get(sub, "density")
      if (dh%kind /= DYN_K_NULL) then
        mode = "exp2"
      else
        mode = "linear"
      end if
      have_mode = .true.
    end if
    if (.not. have_mode) return
    mode = to_lower(strip_ws(mode))
    if (mode == "none" .or. mode == "off" .or. mode == "") return
    if (mode == "exp" .or. mode == "exp2" .or. mode == "fogexp2" &
        .or. mode == "fog_exp2") then
      mode = "exp2"
    else if (mode /= "linear") then
      ! Unknown fog mode: keep it verbatim.
      fog = dyn_dict()
      call dyn_dict_set(fog, "mode", dyn_str(mode))
      return
    end if
    call first_val(props, [character(len=16) :: "fog_color"], v, &
                   found)
    call parse_color_or(v, rgb, has)
    if (.not. has) then
      call first_val(sub, [character(len=16) :: "color", &
                           "colour"], v, found)
      call parse_color_or(v, rgb, has)
    end if
    if (.not. has .and. raw%kind == DYN_K_STR) &
      call parse_color_or(raw, rgb, has)
    if (.not. has) rgb = DEFAULT_FOG_COLOR
    fog = dyn_dict()
    call dyn_dict_set(fog, "mode", dyn_str(mode))
    if (mode == "linear") then
      call first_val(props, [character(len=16) :: "fog_near"], v, &
                     found)
      call num_or(v, has, near)
      if (.not. has) &
        call num_def(dyn_dict_get(sub, "near"), DEFAULT_FOG_NEAR, &
                     near)
      call first_val(props, [character(len=16) :: "fog_far"], v, &
                     found)
      call num_or(v, has, far)
      if (.not. has) &
        call num_def(dyn_dict_get(sub, "far"), DEFAULT_FOG_FAR, far)
      call dyn_dict_set(fog, "near", dyn_real(near))
      call dyn_dict_set(fog, "far", dyn_real(far))
    else
      call first_val(props, [character(len=16) :: "fog_density"], &
                     v, found)
      call num_or(v, has, density)
      if (.not. has) &
        call num_def(dyn_dict_get(sub, "density"), &
                     DEFAULT_FOG_DENSITY, density)
      call dyn_dict_set(fog, "density", dyn_real(density))
    end if
    call dyn_dict_set(fog, "color", rgb_dyn(rgb))
  end subroutine extract_fog

  subroutine extract_tonemap(props, tm)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: tm
    type(dyn) :: sub, raw, v
    character(len=:), allocatable :: mode
    logical :: found, has
    real(real64) :: exposure
    call sub_props(props, [character(len=16) :: "tonemap", &
                           "tone"], sub)
    call first_val(props, [character(len=16) :: "tonemap", &
                           "tone"], raw, found)
    call mode_word(raw, "mode", "kind", mode, has)
    if (.not. has) mode = "none"
    mode = tonemap_alias(mode)
    call first_val(props, [character(len=16) :: "exposure", &
                   "tonemap_exposure", "tone_exposure"], v, found)
    call num_or(v, has, exposure)
    if (.not. has) &
      call num_def(dyn_dict_get(sub, "exposure"), &
                   DEFAULT_EXPOSURE, exposure)
    tm = dyn_dict()
    call dyn_dict_set(tm, "mode", dyn_str(mode))
    call dyn_dict_set(tm, "exposure", dyn_real(exposure))
  end subroutine extract_tonemap

  subroutine extract_shadow(props, sh)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: sh
    type(dyn) :: sub, raw, v
    type(char_list) :: toks
    character(len=:), allocatable :: mode, last
    logical :: found, has
    real(real64) :: size
    integer :: k
    character(len=16), parameter :: SIZE_KEYS(6) = [ &
      character(len=16) :: "on", "soft", "off", "pcf", &
      "soft_pcf", "soft-pcf"]
    call sub_props(props, [character(len=16) :: "shadow", &
                           "shadows"], sub)
    call first_val(props, [character(len=16) :: "shadow", &
                           "shadows"], raw, found)
    call mode_word(raw, "mode", "kind", mode, has)
    if (.not. has) then
      v = dyn_dict_get(props, "shadow_mode")
      if (v%kind == DYN_K_STR .and. allocated(v%s)) then
        mode = to_lower(strip_ws(v%s))
        has = .true.
      end if
    end if
    if (.not. has) mode = "off"
    if (mode == "none" .or. mode == "") then
      mode = "off"
    else if (mode == "pcf" .or. mode == "soft_pcf" .or. &
             mode == "soft-pcf") then
      mode = "soft"  ! soft shadows = PCF filtering
    end if
    call first_val(props, [character(len=16) :: "shadow_size", &
                           "shadow_map_size"], v, found)
    call num_or(v, has, size)
    if (.not. has) then
      call first_val(sub, [character(len=16) :: "size", &
                     "map_size", "shadow_size"], v, found)
      call num_or(v, has, size)
    end if
    if (.not. has) then
      ! Clause-string form: size rides under the mode word.
      call num_or(dyn_dict_get(sub, mode), has, size)
      k = 1
      do while (.not. has .and. k <= 6)
        call num_or(dyn_dict_get(sub, trim(SIZE_KEYS(k))), has, &
                    size)
        k = k + 1
      end do
    end if
    if (.not. has .and. raw%kind == DYN_K_STR &
        .and. allocated(raw%s)) then
      call split_ws(replace_commas(raw%s), toks)
      if (char_list_len(toks) >= 2) then
        last = char_list_at(toks, char_list_len(toks))
        if (is_int_token(last)) &
          call num_or(dyn_str(last), has, size)
      end if
    end if
    if (.not. has) size = DEFAULT_SHADOW_SIZE
    ! A bare integer shadow prop reads as a map size, shadows on.
    if (raw%kind == DYN_K_INT .or. raw%kind == DYN_K_REAL) then
      call num_def(raw, DEFAULT_SHADOW_SIZE, size)
      if (mode == "off") mode = "on"
    end if
    sh = dyn_dict()
    call dyn_dict_set(sh, "mode", dyn_str(mode))
    if (abs(size) > 9.0e18_real64) size = &
      sign(9.0e18_real64, size)  ! int64 range guard (Python: bigint)
    call dyn_dict_set(sh, "size", dyn_int(int(size, int64)))
  end subroutine extract_shadow

  !> v3.0 Phase 2: the scene `antialias N` clause (SSAA factor).
  !! The env payload carries the "antialias" key ONLY when the
  !! clause was written in the source, so scenes without it keep
  !! byte-identical artifacts.  A parseable integer is normalised
  !! to dyn_int; anything else is stored raw so validate_env can
  !! quote it in its E302 message.
  subroutine extract_antialias(props, env)
    type(dyn), intent(in) :: props
    type(dyn), intent(inout) :: env
    type(dyn) :: raw
    character(len=:), allocatable :: t
    integer :: ios
    integer(int64) :: n
    raw = dyn_dict_get(props, "antialias")
    if (raw%kind == DYN_K_NULL) return
    select case (raw%kind)
    case (DYN_K_INT)
      call dyn_dict_set(env, "antialias", dyn_int(raw%i))
    case (DYN_K_STR)
      if (allocated(raw%s)) then
        t = strip_ws(raw%s)
        if (is_int_token(t)) then
          read (t, *, iostat=ios) n
          if (ios == 0) then
            call dyn_dict_set(env, "antialias", dyn_int(n))
            return
          end if
        end if
      end if
      call dyn_dict_set(env, "antialias", raw)
    case default
      call dyn_dict_set(env, "antialias", raw)
    end select
  end subroutine extract_antialias

  !> extract_env(props) -> normalised environment dict.
  subroutine extract_env(props_in, env)
    type(dyn), intent(in) :: props_in
    type(dyn), intent(out) :: env
    type(dyn) :: props, part
    props = lower_keys(props_in)
    env = dyn_dict()
    call extract_fog(props, part)
    call dyn_dict_set(env, "fog", part)
    call extract_tonemap(props, part)
    call dyn_dict_set(env, "tonemap", part)
    call extract_shadow(props, part)
    call dyn_dict_set(env, "shadow", part)
    call extract_antialias(props, env)
  end subroutine extract_env

  !> validate_env(env) -> list of error message strings.
  subroutine validate_env(env_in, msgs)
    type(dyn), intent(in) :: env_in
    type(char_list), intent(inout) :: msgs
    type(dyn) :: fog, tm, sh, raw
    character(len=:), allocatable :: mode
    real(real64) :: near, far, density, x
    logical :: has_near, has_far, has, bad
    integer(int64) :: isize
    if (env_in%kind /= DYN_K_DICT) return
    fog = dyn_dict_get(env_in, "fog")
    if (fog%kind == DYN_K_DICT) then
      mode = mode_str_of(dyn_dict_get(fog, "mode"), "")
      if (mode == "linear") then
        call num_or(dyn_dict_get(fog, "near"), has_near, near)
        call num_or(dyn_dict_get(fog, "far"), has_far, far)
        if (.not. has_near .or. .not. has_far) then
          call char_list_append(msgs, &
            "linear fog requires 'near' and 'far': fog near and " // &
            "fog far must both be given")
        else if (.not. (near < far)) then
          call char_list_append(msgs, &
            "fog near is " // fmt_g(near) // ", but 'near' must " // &
            "be smaller than 'far' (" // fmt_g(far) // ") for " // &
            "linear fog")
        end if
      else if (mode == "exp2") then
        call num_or(dyn_dict_get(fog, "density"), has, density)
        if (.not. has) then
          call char_list_append(msgs, &
            "exp2 fog requires a 'density': fog density must be " // &
            "given")
        else if (density < 0.0_real64) then
          call char_list_append(msgs, &
            "fog density is " // fmt_g(density) // ", but " // &
            "'density' must be 0 or more")
        end if
      end if
    end if
    tm = dyn_dict_get(env_in, "tonemap")
    if (tm%kind == DYN_K_DICT) then
      raw = dyn_dict_get(tm, "exposure")
      if (raw%kind /= DYN_K_NULL) then
        call num_or(raw, has, x)
        if (.not. has .or. x <= 0.0_real64) &
          call char_list_append(msgs, &
            "exposure is " // py_str_of(raw) // ", but 'exposure' " // &
            "must be more than 0")
      end if
    end if
    sh = dyn_dict_get(env_in, "shadow")
    if (sh%kind == DYN_K_DICT) then
      raw = dyn_dict_get(sh, "size")
      if (raw%kind /= DYN_K_NULL) then
        call num_or(raw, has, x)
        bad = .not. has
        if (has) then
          if (x /= floor(x)) then
            bad = .true.
          else if (x < 64.0_real64 .or. x > 4096.0_real64) then
            bad = .true.
          else
            isize = int(x, int64)
            if (iand(isize, isize - 1_int64) /= 0_int64) &
              bad = .true.
          end if
        end if
        if (bad) call char_list_append(msgs, &
          "shadow size is " // py_str_of(raw) // ", but 'size' " // &
          "must be a power of two between 64 and 4096")
      end if
    end if
    if (dyn_dict_has(env_in, "antialias")) then
      raw = dyn_dict_get(env_in, "antialias")
      if (raw%kind /= DYN_K_NULL) then
        call num_or(raw, has, x)
        bad = .not. has
        if (has) then
          if (x /= floor(x)) then
            bad = .true.
          else if (x /= 1.0_real64 .and. x /= 2.0_real64 .and. &
                   x /= 4.0_real64 .and. x /= 8.0_real64) then
            bad = .true.
          end if
        end if
        if (bad) call char_list_append(msgs, &
          "antialias is " // py_str_of(raw) // ", but " // &
          "'antialias' must be one of 1, 2, 4 or 8")
      end if
    end if
  end subroutine validate_env

  !> env_lines(env) -> .scene lines for non-default entries only.
  subroutine env_lines(env_in, lines)
    type(dyn), intent(in) :: env_in
    type(char_list), intent(inout) :: lines
    type(dyn) :: fog, tm, sh
    character(len=:), allocatable :: mode
    real(real64) :: near, far, density, exposure, size
    if (env_in%kind /= DYN_K_DICT) return
    fog = dyn_dict_get(env_in, "fog")
    if (fog%kind == DYN_K_DICT) then
      mode = mode_str_of(dyn_dict_get(fog, "mode"), "")
      if (mode == "linear") then
        call num_def(dyn_dict_get(fog, "near"), DEFAULT_FOG_NEAR, &
                     near)
        call num_def(dyn_dict_get(fog, "far"), DEFAULT_FOG_FAR, far)
        call char_list_append(lines, &
          "fog linear " // fmt_g(near) // " " // fmt_g(far) // &
          " " // fmt_color_of(dyn_dict_get(fog, "color")))
      else if (mode == "exp2") then
        call num_def(dyn_dict_get(fog, "density"), &
                     DEFAULT_FOG_DENSITY, density)
        call char_list_append(lines, &
          "fog exp2 " // fmt_g(density) // " " // &
          fmt_color_of(dyn_dict_get(fog, "color")))
      else if (mode == "none" .or. mode == "off") then
        call char_list_append(lines, "fog none")
      else if (len(mode) > 0) then
        call char_list_append(lines, "fog " // mode)
      end if
    end if
    tm = dyn_dict_get(env_in, "tonemap")
    if (tm%kind == DYN_K_DICT) then
      mode = tonemap_alias(mode_str_of(dyn_dict_get(tm, "mode"), &
                                       "none"))
      if (mode /= "none") then
        call num_def(dyn_dict_get(tm, "exposure"), &
                     DEFAULT_EXPOSURE, exposure)
        call char_list_append(lines, &
          "tonemap " // mode // " " // fmt_g(exposure))
      end if
    end if
    sh = dyn_dict_get(env_in, "shadow")
    if (sh%kind == DYN_K_DICT) then
      mode = mode_str_of(dyn_dict_get(sh, "mode"), "off")
      if (mode == "none" .or. mode == "") mode = "off"
      if (mode /= "off") then
        call num_def(dyn_dict_get(sh, "size"), &
                     DEFAULT_SHADOW_SIZE, size)
        if (abs(size) > 9.0e18_real64) size = &
          sign(9.0e18_real64, size)
        call char_list_append(lines, &
          "shadow " // mode // " " // &
          trim(fmt_int(int(size, int64))))
      end if
    end if
    ! v3.0 Phase 2: emitted whenever the clause was set in the
    ! source (the key exists only then), even for antialias 1.
    if (dyn_dict_has(env_in, "antialias")) then
      block
        type(dyn) :: raw
        real(real64) :: n
        logical :: has_n
        raw = dyn_dict_get(env_in, "antialias")
        call num_or(raw, has_n, n)
        if (has_n) call char_list_append(lines, &
          "antialias " // trim(fmt_int(int(n, int64))))
      end block
    end if
  end subroutine env_lines

end module f3dc_ext_lights_env
