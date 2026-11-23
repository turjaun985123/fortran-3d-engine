! f3dc_ext_particles -- Forge3D Wave B extension: deterministic
! ``particles`` statements.  Faithful Fortran port of
! tools/f3dc/ext_particles.py (583 lines), per compiler/DESIGN.md.
! Python is the oracle; function-by-function mirror, same names:
!
!   extract_particles(props) -> dict
!   validate_particles(d) -> list[str]      (char_list here)
!   particles_line(name, d) -> str
!   particle_hash01(seed, i, k) -> float
!   particle_state(d, i, t) -> (pos, scale)
!
! Dyn representation notes (see f3dc_dyn / DESIGN.md):
! * Python tuples are dyn lists; dict keys are lower-cased copies in
!   _lower_keys, exactly as in Python.
! * Python None is dyn_null; a stored null and an absent key are
!   distinguished with dyn_dict_has, as Python's ``in`` / ``.get``.
! * Unconvertible / non-finite values pass through extract unchanged
!   (as dyn values) so validate can report them, mirroring
!   _as_number / _as_int.
! * ColourLit-style attribute objects have no dyn counterpart; a dyn
!   DICT carrying rgb / channels / name / value / text keys takes
!   that branch of _parse_color instead.
! * Python %r in the diagnostic strings is repr_dyn below (dyn lists
!   render tuple-style, the same conflation f3dc_ir documents).
! * "%.6g" / "%g" is fmt_g6 below (C printf %g semantics).
!
! Wiring (validate.py / emit_fortran.py call sites) lives in
! f3dc_validate / f3dc_emit_fortran; see the port report for the
! exact patches that replace their DISPATCH / EXT HOOK stubs with
! calls into this module.
module f3dc_ext_particles
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
  use f3dc_str, only: fmt_int, fmt_real, to_lower, char_list, &
       char_list_append, char_list_len, char_list_at, str_builder, &
       sb_init, sb_add, sb_text
  use f3dc_ir, only: ir_parse_color_nobag
  use f3dc_emit_common, only: parse_color_str
  implicit none
  private

  public :: extract_particles, validate_particles, particles_line
  public :: particle_hash01, particle_state

  ! Defaults / limits (frozen: particles.f90 ParticleSystem).
  real(real64), parameter :: DEF_ORIGIN(3) = [0.0_real64, 0.0_real64, &
                                              0.0_real64]
  integer(int64), parameter :: DEF_COUNT = 100_int64
  real(real64), parameter :: DEF_LIFE = 2.0_real64
  real(real64), parameter :: DEF_SPEED = 3.0_real64
  real(real64), parameter :: DEF_SIZE = 0.2_real64
  integer, parameter :: DEF_COLOR(3) = [255, 180, 60]
  real(real64), parameter :: DEF_SPREAD = 0.5_real64
  real(real64), parameter :: DEF_GRAVITY = 0.0_real64
  integer(int64), parameter :: DEF_SEED = 1_int64
  integer(int64), parameter :: HASH_MOD = 2147483648_int64
  integer(int64), parameter :: MIN_COUNT = 1_int64
  integer(int64), parameter :: MAX_COUNT = 10000_int64
  real(real64), parameter :: MAX_LIFE = 3600.0_real64
  real(real64), parameter :: MAX_SPEED = 1000.0_real64
  real(real64), parameter :: MAX_SIZE = 10.0_real64
  real(real64), parameter :: MAX_SPREAD = 10.0_real64
  real(real64), parameter :: MIN_GRAVITY = -100.0_real64
  real(real64), parameter :: MAX_GRAVITY = 100.0_real64
  integer(int64), parameter :: MIN_SEED = 0_int64
  integer(int64), parameter :: MAX_SEED = 100000_int64

contains

  ! ==================================================================
  ! Small text helpers
  ! ==================================================================

  !> Python str.strip() (ASCII whitespace subset).
  function strip_ws(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b, c
    a = 1
    b = len(s)
    do while (a <= b)
      c = iachar(s(a:a))
      if (c == 32 .or. (c >= 9 .and. c <= 13)) then
        a = a + 1
      else
        exit
      end if
    end do
    do while (b >= a)
      c = iachar(s(b:b))
      if (c == 32 .or. (c >= 9 .and. c <= 13)) then
        b = b - 1
      else
        exit
      end if
    end do
    if (b < a) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws

  pure logical function is_digit(ch)
    character(len=1), intent(in) :: ch
    is_digit = ch >= "0" .and. ch <= "9"
  end function is_digit

  !> Python float(text) for a string: full-string grammar
  !! [sign] (digits [. [digits]] | . digits) [eE [sign] digits], or
  !! inf / infinity / nan words (case-insensitive).  Underscores
  !! between digits are accepted, as in Python numeric literals.
  subroutine parse_py_float(text, x, ok)
    character(len=*), intent(in) :: text
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, low, clean
    type(str_builder) :: sb
    integer :: i, n, ios
    logical :: any_digit, any_frac
    ok = .false.
    x = 0.0_real64
    t = strip_ws(text)
    low = to_lower(t)
    if (low == "inf" .or. low == "+inf" .or. low == "infinity" &
        .or. low == "+infinity") then
      x = ieee_value(1.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (low == "-inf" .or. low == "-infinity") then
      x = -ieee_value(1.0_real64, ieee_positive_inf)
      ok = .true.
      return
    end if
    if (low == "nan" .or. low == "+nan" .or. low == "-nan") then
      x = ieee_value(1.0_real64, ieee_quiet_nan)
      ok = .true.
      return
    end if
    ! Drop underscores that sit between two digits (Python rule,
    ! approximated: any other underscore placement fails below
    ! because the cleaned string is re-scanned strictly).
    call sb_init(sb)
    n = len(t)
    do i = 1, n
      if (t(i:i) == "_") then
        if (i > 1 .and. i < n) then
          if (is_digit(t(i - 1:i - 1)) .and. is_digit(t(i + 1:i + 1))) &
            cycle
        end if
        return
      end if
      call sb_add(sb, t(i:i))
    end do
    clean = sb_text(sb)
    ! Strict scan of the cleaned string.
    block
      integer :: pos, m
      logical :: exp_digits
      pos = 1
      m = len(clean)
      if (pos <= m) then
        if (clean(pos:pos) == "+" .or. clean(pos:pos) == "-") &
          pos = pos + 1
      end if
      any_digit = .false.
      do while (pos <= m)
        if (.not. is_digit(clean(pos:pos))) exit
        any_digit = .true.
        pos = pos + 1
      end do
      any_frac = .false.
      if (pos <= m) then
        if (clean(pos:pos) == ".") then
          pos = pos + 1
          do while (pos <= m)
            if (.not. is_digit(clean(pos:pos))) exit
            any_frac = .true.
            pos = pos + 1
          end do
        end if
      end if
      if (.not. (any_digit .or. any_frac)) return
      if (pos <= m) then
        if (clean(pos:pos) == "e" .or. clean(pos:pos) == "E") then
          pos = pos + 1
          if (pos <= m) then
            if (clean(pos:pos) == "+" .or. clean(pos:pos) == "-") &
              pos = pos + 1
          end if
          exp_digits = .false.
          do while (pos <= m)
            if (.not. is_digit(clean(pos:pos))) exit
            exp_digits = .true.
            pos = pos + 1
          end do
          if (.not. exp_digits) return
        end if
      end if
      if (pos /= m + 1) return
    end block
    read (clean, *, iostat=ios) x
    if (ios /= 0) then
      x = 0.0_real64
      return
    end if
    ok = .true.
  end subroutine parse_py_float

  !> Python int(text): [sign] digits (underscores between digits
  !! allowed).  Overflow of int64 reports failure (Python ints are
  !! unbounded -- a noted divergence for absurd inputs).
  subroutine parse_py_int(text, v, ok)
    character(len=*), intent(in) :: text
    integer(int64), intent(out) :: v
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, clean
    type(str_builder) :: sb
    integer :: i, n, ios
    ok = .false.
    v = 0_int64
    t = strip_ws(text)
    call sb_init(sb)
    n = len(t)
    do i = 1, n
      if (t(i:i) == "_") then
        if (i > 1 .and. i < n) then
          if (is_digit(t(i - 1:i - 1)) .and. is_digit(t(i + 1:i + 1))) &
            cycle
        end if
        return
      end if
      call sb_add(sb, t(i:i))
    end do
    clean = sb_text(sb)
    block
      integer :: pos, m
      pos = 1
      m = len(clean)
      if (m == 0) return
      if (clean(pos:pos) == "+" .or. clean(pos:pos) == "-") pos = pos + 1
      if (pos > m) return
      do while (pos <= m)
        if (.not. is_digit(clean(pos:pos))) return
        pos = pos + 1
      end do
    end block
    read (clean, *, iostat=ios) v
    if (ios /= 0) then
      v = 0_int64
      return
    end if
    ok = .true.
  end subroutine parse_py_int

  !> C printf "%.6g" / "%g" (precision 6): 6 significant digits,
  !! trailing zeros stripped, fixed notation unless the decimal
  !! exponent is < -4 or >= 6, exponent at least two digits.
  function fmt_g6(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out, body, digits
    type(str_builder) :: sb
    character(len=64) :: buf
    character(len=16) :: ebuf
    integer :: epos, dec_exp, ndig, i, j
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
    neg = ieee_is_negative(x)
    write (buf, "(ES16.5E3)") x
    epos = index(buf, "E")
    call sb_init(sb)
    j = 0
    do i = 1, epos - 1
      if (is_digit(buf(i:i))) then
        j = j + 1
        call sb_add(sb, buf(i:i))
      end if
    end do
    digits = sb_text(sb)
    ndig = len(digits)
    read (buf(epos + 1:), *) dec_exp
    do while (ndig > 1 .and. digits(ndig:ndig) == "0")
      ndig = ndig - 1
    end do
    digits = digits(1:ndig)
    if (dec_exp < -4 .or. dec_exp >= 6) then
      if (ndig > 1) then
        body = digits(1:1) // "." // digits(2:ndig)
      else
        body = digits(1:1)
      end if
      if (dec_exp >= 0) then
        write (ebuf, "(A,I0)") "e+", dec_exp
      else
        write (ebuf, "(A,I0)") "e-", -dec_exp
      end if
      block
        character(len=:), allocatable :: enum
        type(str_builder) :: sb2
        integer :: ei
        ei = index(ebuf, "e")
        enum = ebuf(ei + 2:len_trim(ebuf))
        if (len(enum) < 2) enum = "0" // enum
        call sb_init(sb2)
        call sb_add(sb2, body)
        call sb_add(sb2, ebuf(1:ei + 1))
        call sb_add(sb2, enum)
        body = sb_text(sb2)
      end block
    else if (dec_exp >= 0) then
      if (ndig > dec_exp + 1) then
        body = digits(1:dec_exp + 1) // "." // digits(dec_exp + 2:ndig)
      else
        body = digits(1:ndig) // repeat("0", dec_exp + 1 - ndig)
      end if
    else
      body = "0." // repeat("0", -dec_exp - 1) // digits(1:ndig)
    end if
    if (neg) then
      out = "-" // body
    else
      out = body
    end if
  end function fmt_g6

  !> Python repr(str): single quotes unless the string contains a
  !! single quote and no double quote; ASCII escape subset (the
  !! same implementation f3dc_ir carries for E202 messages).
  function repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out, body
    type(str_builder) :: sb
    character(len=1) :: quote
    integer :: i, c
    if (index(s, "'") > 0 .and. index(s, '"') == 0) then
      quote = '"'
    else
      quote = "'"
    end if
    call sb_init(sb)
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (s(i:i) == quote .or. c == 92) then
        call sb_add(sb, "\")
        call sb_add(sb, s(i:i))
      else if (c == 10) then
        call sb_add(sb, "\n")
      else if (c == 13) then
        call sb_add(sb, "\r")
      else if (c == 9) then
        call sb_add(sb, "\t")
      else if (c < 32 .or. c == 127) then
        block
          character(len=8) :: hb
          write (hb, "(A,Z2.2)") "\x", c
          call sb_add(sb, trim(hb))
        end block
      else
        call sb_add(sb, s(i:i))
      end if
    end do
    body = sb_text(sb)
    out = quote // body // quote
  end function repr_str

  !> Python repr() of a dyn value, for the %r diagnostic slots.
  !! Dyn lists render tuple-style (see the header note).
  recursive function repr_dyn(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: k
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
      out = trim(fmt_int(v%i))
    case (DYN_K_REAL)
      out = trim(fmt_real(v%r))
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = repr_str(v%s)
      else
        out = "''"
      end if
    case (DYN_K_LIST)
      call sb_init(sb)
      call sb_add(sb, "(")
      do k = 1, dyn_list_len(v)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, repr_dyn(dyn_list_at(v, k)))
      end do
      if (dyn_list_len(v) == 1) call sb_add(sb, ",")
      call sb_add(sb, ")")
      out = sb_text(sb)
    case (DYN_K_DICT)
      call sb_init(sb)
      call sb_add(sb, "{")
      do k = 1, dyn_dict_len(v)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, repr_str(dyn_dict_key_at(v, k)))
        call sb_add(sb, ": ")
        call sb_add(sb, repr_dyn(dyn_dict_value_at(v, k)))
      end do
      call sb_add(sb, "}")
      out = sb_text(sb)
    case default
      out = "None"
    end select
  end function repr_dyn

  !> Python round() (banker's rounding), as in f3dc_emit_common.
  pure integer function py_round(x) result(r)
    real(real64), intent(in) :: x
    real(real64) :: fl, frac
    integer(int64) :: base
    fl = floor(x)
    base = int(fl, int64)
    frac = x - fl
    if (frac > 0.5_real64) then
      r = int(base + 1_int64)
    else if (frac < 0.5_real64) then
      r = int(base)
    else if (mod(base, 2_int64) == 0_int64) then
      r = int(base)
    else
      r = int(base + 1_int64)
    end if
  end function py_round

  ! ==================================================================
  ! Generic value helpers (same tolerant shapes as ext_sprites_text)
  ! ==================================================================

  !> _lower_keys: copy of props with string keys lower-cased; a
  !! non-dict yields an empty dict.
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

  !> _first: first non-None value among names, else null / found=F.
  subroutine first_val(props, names, out, found)
    type(dyn), intent(in) :: props
    character(len=*), intent(in) :: names(:)
    type(dyn), intent(out) :: out
    logical, intent(out) :: found
    integer :: k
    out = dyn_null()
    found = .false.
    if (props%kind /= DYN_K_DICT) return
    do k = 1, size(names)
      if (dyn_dict_has(props, trim(names(k)))) then
        out = dyn_dict_get(props, trim(names(k)))
        if (out%kind /= DYN_K_NULL) then
          found = .true.
          return
        end if
        out = dyn_null()
      end if
    end do
  end subroutine first_val

  !> _as_number: best-effort float conversion; unconvertible values
  !! pass through.  Non-finite floats are kept as-is so validation
  !! can report them.
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
  end function as_number

  !> _as_int: best-effort int conversion; unconvertible values pass
  !! through unchanged.
  function as_int(value) result(out)
    type(dyn), intent(in) :: value
    type(dyn) :: out
    integer(int64) :: iv
    real(real64) :: x
    logical :: ok
    select case (value%kind)
    case (DYN_K_BOOL)
      out = dyn_copy(value)
    case (DYN_K_INT)
      out = dyn_copy(value)
    case (DYN_K_REAL)
      if (ieee_is_finite(value%r) .and. &
          value%r == floor(value%r) .and. &
          abs(value%r) < 9.2233720368547758e18_real64) then
        out = dyn_int(int(value%r, int64))
      else
        out = dyn_copy(value)
      end if
    case (DYN_K_STR)
      if (allocated(value%s)) then
        call parse_py_int(value%s, iv, ok)
        if (ok) then
          out = dyn_int(iv)
          return
        end if
        call parse_py_float(value%s, x, ok)
        if (ok) then
          if (ieee_is_finite(x) .and. x == floor(x) .and. &
              abs(x) < 9.2233720368547758e18_real64) then
            out = dyn_int(int(x, int64))
            return
          end if
        end if
      end if
      out = dyn_copy(value)
    case default
      out = dyn_copy(value)
    end select
  end function as_int

  !> Whitespace/comma tokeniser for _vec3's string branch
  !! (Python: value.replace(",", " ").split()).
  subroutine split_ws_commas(s, toks, ntok)
    character(len=*), intent(in) :: s
    character(len=:), allocatable, intent(out) :: toks(:)
    integer, intent(out) :: ntok
    character(len=:), allocatable :: t
    integer :: i, a, c, cap
    cap = 8
    allocate (character(len=max(1, len(s))) :: toks(cap))
    ntok = 0
    t = s
    do i = 1, len(t)
      if (t(i:i) == ",") t(i:i) = " "
    end do
    i = 1
    do while (i <= len(t))
      c = iachar(t(i:i))
      if (c == 32 .or. (c >= 9 .and. c <= 13)) then
        i = i + 1
        cycle
      end if
      a = i
      do while (i <= len(t))
        c = iachar(t(i:i))
        if (c == 32 .or. (c >= 9 .and. c <= 13)) exit
        i = i + 1
      end do
      ntok = ntok + 1
      if (ntok <= cap) toks(ntok) = t(a:i - 1)
    end do
  end subroutine split_ws_commas

  !> _vec3: coerce value to a 3-list, else ok=.false. (Python None).
  !! Components are _as_number-converted where possible and
  !! otherwise passed through unchanged.
  subroutine vec3(value, out, ok)
    type(dyn), intent(in) :: value
    type(dyn), intent(out) :: out
    logical, intent(out) :: ok
    character(len=:), allocatable :: toks(:)
    type(dyn) :: lowered, comp
    integer :: k, ntok
    character(len=1), parameter :: AXES(3) = ["x", "y", "z"]
    ok = .false.
    out = dyn_null()
    select case (value%kind)
    case (DYN_K_NULL)
      return
    case (DYN_K_STR)
      if (.not. allocated(value%s)) return
      call split_ws_commas(value%s, toks, ntok)
      if (ntok /= 3) return
      out = dyn_list()
      do k = 1, 3
        call dyn_list_push(out, as_number(dyn_str(trim(toks(k)))))
      end do
      ok = .true.
    case (DYN_K_DICT)
      lowered = lower_keys(value)
      do k = 1, 3
        if (.not. dyn_dict_has(lowered, AXES(k))) return
      end do
      out = dyn_list()
      do k = 1, 3
        comp = dyn_dict_get(lowered, AXES(k))
        call dyn_list_push(out, as_number(comp))
      end do
      ok = .true.
    case (DYN_K_LIST)
      if (dyn_list_len(value) < 3) return
      out = dyn_list()
      do k = 1, 3
        call dyn_list_push(out, as_number(dyn_list_at(value, k)))
      end do
      ok = .true.
    case default
      return
    end select
  end subroutine vec3

  !> _parse_color: resolve value to an (r,g,b) int triple, else
  !! ok=.false. (Python None; the caller falls back to the default
  !! colour -- reporting an unknown colour by name is validate.py's
  !! E202 job, as elsewhere in the compiler).
  recursive subroutine parse_color(value, rgb, ok)
    type(dyn), intent(in) :: value
    integer, intent(out) :: rgb(3)
    logical, intent(out) :: ok
    type(dyn) :: num, inner, parsed
    character(len=:), allocatable :: text, raised_msg
    integer :: k
    logical :: is_null, raised
    character(len=10), parameter :: ATTRS1(2) = [character(len=10) :: &
                                                 "rgb", "channels"]
    character(len=10), parameter :: ATTRS2(3) = [character(len=10) :: &
                                                 "name", "value", &
                                                 "text"]
    ok = .false.
    rgb = 0
    select case (value%kind)
    case (DYN_K_NULL)
      return
    case (DYN_K_LIST)
      if (dyn_list_len(value) /= 3) return
      do k = 1, 3
        num = as_number(dyn_list_at(value, k))
        if (num%kind /= DYN_K_INT .and. num%kind /= DYN_K_REAL) return
        if (.not. (num%r >= 0.0_real64 .and. &
                   num%r <= 255.0_real64)) return
        rgb(k) = py_round(num%r)
      end do
      ok = .true.
      return
    case (DYN_K_DICT)
      ! ColourLit-style node: rgb / channels, then name/value/text.
      do k = 1, 2
        if (dyn_dict_has(value, trim(ATTRS1(k)))) then
          inner = dyn_dict_get(value, trim(ATTRS1(k)))
          if (inner%kind /= DYN_K_NULL) then
            call parse_color(inner, rgb, ok)
            return
          end if
        end if
      end do
      do k = 1, 3
        if (dyn_dict_has(value, trim(ATTRS2(k)))) then
          inner = dyn_dict_get(value, trim(ATTRS2(k)))
          if (inner%kind == DYN_K_STR) then
            call parse_color(inner, rgb, ok)
            return
          end if
        end if
      end do
      return
    case (DYN_K_STR)
      if (.not. allocated(value%s)) return
      ! Frozen parser in ir_nodes first (f3dc_ir's nobag form: a
      ! Python ValueError there is caught by ext_particles and the
      ! local path below runs, exactly as in Python).
      call ir_parse_color_nobag(value, parsed, is_null, raised, &
                                raised_msg)
      if (.not. is_null .and. .not. raised) then
        if (dyn_list_len(parsed) == 3) then
          do k = 1, 3
            inner = dyn_list_at(parsed, k)
            rgb(k) = int(inner%i)
          end do
          ok = .true.
        end if
        return
      end if
      ! Local path: strip whitespace, then quote chars, then
      ! whitespace again (Python .strip().strip("\"'").strip()).
      text = strip_ws(value%s)
      text = strip_quote_chars(text)
      text = strip_ws(text)
      call parse_color_str(text, rgb, ok)
      return
    case default
      return
    end select
  end subroutine parse_color

  !> Python .strip("\"'"): remove any leading/trailing chars that
  !! are a double or single quote.
  function strip_quote_chars(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (s(a:a) == '"' .or. s(a:a) == "'") then
        a = a + 1
      else
        exit
      end if
    end do
    do while (b >= a)
      if (s(b:b) == '"' .or. s(b:b) == "'") then
        b = b - 1
      else
        exit
      end if
    end do
    if (b < a) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_quote_chars

  !> _fmt: "%.6g" of a number; "0" for non-numbers.
  function fmt_val(value) result(out)
    type(dyn), intent(in) :: value
    character(len=:), allocatable :: out
    type(dyn) :: num
    num = as_number(value)
    if (num%kind /= DYN_K_INT .and. num%kind /= DYN_K_REAL) then
      out = "0"
      return
    end if
    if (num%kind == DYN_K_INT) then
      out = fmt_g6(real(num%i, real64))
    else
      out = fmt_g6(num%r)
    end if
  end function fmt_val

  !> _fmt_vec: space-joined _fmt over the components.
  function fmt_vec(vec) result(out)
    type(dyn), intent(in) :: vec
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: k
    call sb_init(sb)
    do k = 1, dyn_list_len(vec)
      if (k > 1) call sb_add(sb, " ")
      call sb_add(sb, fmt_val(dyn_list_at(vec, k)))
    end do
    out = sb_text(sb)
  end function fmt_vec

  !> _fmt_color: "%d %d %d" of the parsed colour or the default.
  function fmt_color(color) result(out)
    type(dyn), intent(in) :: color
    character(len=:), allocatable :: out
    integer :: rgb(3)
    logical :: ok
    call parse_color(color, rgb, ok)
    if (.not. ok) rgb = DEF_COLOR
    out = trim(fmt_int(int(rgb(1), int64))) // " " // &
          trim(fmt_int(int(rgb(2), int64))) // " " // &
          trim(fmt_int(int(rgb(3), int64)))
  end function fmt_color

  !> _float_or: float(value) when numeric, else the default.
  function float_or(value, def) result(x)
    type(dyn), intent(in) :: value
    real(real64), intent(in) :: def
    real(real64) :: x
    type(dyn) :: num
    num = as_number(value)
    if (num%kind == DYN_K_INT) then
      x = real(num%i, real64)
    else if (num%kind == DYN_K_REAL) then
      x = num%r
    else
      x = def
    end if
  end function float_or

  !> _int_or: int(value) when an int, else the default.
  function int_or(value, def) result(v)
    type(dyn), intent(in) :: value
    integer(int64), intent(in) :: def
    integer(int64) :: v
    type(dyn) :: num
    num = as_int(value)
    if (num%kind == DYN_K_INT) then
      v = num%i
    else
      v = def
    end if
  end function int_or

  !> Dict .get with Python semantics: absent and stored-null both
  !! yield dyn_null here (callers that must distinguish use
  !! dyn_dict_has, as Python does).
  function dget(d, key) result(v)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(dyn) :: v
    if (d%kind == DYN_K_DICT) then
      v = dyn_dict_get(d, key)
    else
      v = dyn_null()
    end if
  end function dget

  function default_origin() result(v)
    type(dyn) :: v
    integer :: k
    v = dyn_list()
    do k = 1, 3
      call dyn_list_push(v, dyn_real(DEF_ORIGIN(k)))
    end do
  end function default_origin

  function default_color() result(v)
    type(dyn) :: v
    integer :: k
    v = dyn_list()
    do k = 1, 3
      call dyn_list_push(v, dyn_int(int(DEF_COLOR(k), int64)))
    end do
  end function default_color

  ! ==================================================================
  ! Extract
  ! ==================================================================

  !> extract_particles(props) -> the normalised particles dict
  !! {origin, count, life, speed, size, color, spread, gravity,
  !! seed} with the frozen defaults.  Pure; props is never mutated.
  subroutine extract_particles(props_in, out)
    type(dyn), intent(in) :: props_in
    type(dyn), intent(out) :: out
    type(dyn) :: props, v, origin, colv
    integer :: rgb(3), k
    logical :: found, ok
    character(len=12), parameter :: ORIGIN_SPELL(4) = &
         [character(len=12) :: "at", "origin", "position", "pos"]
    character(len=12), parameter :: COLOR_SPELL(6) = &
         [character(len=12) :: "color", "colour", "color_raw", &
          "colour_raw", "color_value", "colour_value"]
    props = lower_keys(props_in)
    call first_val(props, ORIGIN_SPELL, v, found)
    call vec3(v, origin, ok)
    if (.not. ok) then
      if (dyn_dict_has(props, "x") .or. dyn_dict_has(props, "y") &
          .or. dyn_dict_has(props, "z")) then
        block
          type(dyn) :: xyz
          character(len=1), parameter :: AX(3) = ["x", "y", "z"]
          xyz = dyn_dict()
          do k = 1, 3
            call dyn_dict_set(xyz, AX(k), dget(props, AX(k)))
          end do
          call vec3(xyz, origin, ok)
        end block
      end if
    end if
    if (.not. ok) origin = default_origin()
    out = dyn_dict()
    call dyn_dict_set(out, "origin", origin)
    call first_val(props, [character(len=12) :: "count"], v, found)
    v = as_int(v)
    if (v%kind == DYN_K_NULL) v = dyn_int(DEF_COUNT)
    call dyn_dict_set(out, "count", v)
    call first_val(props, [character(len=12) :: "life"], v, found)
    v = as_number(v)
    if (v%kind == DYN_K_NULL) v = dyn_real(DEF_LIFE)
    call dyn_dict_set(out, "life", v)
    call first_val(props, [character(len=12) :: "speed"], v, found)
    v = as_number(v)
    if (v%kind == DYN_K_NULL) v = dyn_real(DEF_SPEED)
    call dyn_dict_set(out, "speed", v)
    call first_val(props, [character(len=12) :: "size"], v, found)
    v = as_number(v)
    if (v%kind == DYN_K_NULL) v = dyn_real(DEF_SIZE)
    call dyn_dict_set(out, "size", v)
    call first_val(props, COLOR_SPELL, colv, found)
    call parse_color(colv, rgb, ok)
    if (ok) then
      v = dyn_list()
      do k = 1, 3
        call dyn_list_push(v, dyn_int(int(rgb(k), int64)))
      end do
    else
      v = default_color()
    end if
    call dyn_dict_set(out, "color", v)
    call first_val(props, [character(len=12) :: "spread"], v, found)
    v = as_number(v)
    if (v%kind == DYN_K_NULL) v = dyn_real(DEF_SPREAD)
    call dyn_dict_set(out, "spread", v)
    call first_val(props, [character(len=12) :: "gravity"], v, found)
    v = as_number(v)
    if (v%kind == DYN_K_NULL) v = dyn_real(DEF_GRAVITY)
    call dyn_dict_set(out, "gravity", v)
    call first_val(props, [character(len=12) :: "seed"], v, found)
    v = as_int(v)
    if (v%kind == DYN_K_NULL) v = dyn_int(DEF_SEED)
    call dyn_dict_set(out, "seed", v)
  end subroutine extract_particles

  ! ==================================================================
  ! Validate
  ! ==================================================================

  subroutine validate_int(errors, d, key, low, high)
    type(char_list), intent(inout) :: errors
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    integer(int64), intent(in) :: low, high
    type(dyn) :: raw, value
    if (.not. dyn_dict_has(d, key)) return
    raw = dyn_dict_get(d, key)
    if (raw%kind == DYN_K_NULL) return
    value = as_int(raw)
    if (value%kind /= DYN_K_INT) then
      call char_list_append(errors, key // " " // repr_dyn(raw) // &
           " is not an integer: '" // key // &
           "' must be in the range " // trim(fmt_int(low)) // ".." // &
           trim(fmt_int(high)))
    else if (value%i < low .or. value%i > high) then
      call char_list_append(errors, key // " " // &
           trim(fmt_int(value%i)) // " is out of range: '" // key // &
           "' must be in the range " // trim(fmt_int(low)) // ".." // &
           trim(fmt_int(high)))
    end if
  end subroutine validate_int

  subroutine validate_float(errors, d, key, low, high, low_inclusive)
    type(char_list), intent(inout) :: errors
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    real(real64), intent(in) :: low, high
    logical, intent(in) :: low_inclusive
    type(dyn) :: raw, value
    real(real64) :: number
    logical :: in_range
    character(len=:), allocatable :: bound_word
    if (.not. dyn_dict_has(d, key)) return
    raw = dyn_dict_get(d, key)
    if (raw%kind == DYN_K_NULL) return
    value = as_number(raw)
    if (value%kind /= DYN_K_INT .and. value%kind /= DYN_K_REAL) then
      call char_list_append(errors, key // " " // repr_dyn(raw) // &
           " is not a number: '" // key // "' must be in the range " &
           // fmt_g6(low) // ".." // fmt_g6(high))
      return
    end if
    if (value%kind == DYN_K_INT) then
      number = real(value%i, real64)
    else
      number = value%r
    end if
    if (low_inclusive) then
      in_range = low <= number
      bound_word = "at least"
    else
      in_range = low < number
      bound_word = "more than"
    end if
    in_range = in_range .and. number <= high
    if (.not. ieee_is_finite(number) .or. .not. in_range) then
      call char_list_append(errors, key // " is " // fmt_g6(number) &
           // ", but '" // key // "' must be " // bound_word // " " &
           // fmt_g6(low) // " and at most " // fmt_g6(high))
    end if
  end subroutine validate_float

  !> validate_particles(d) -> human-readable error strings, in
  !! Python's order: origin, count, life, speed, size, spread,
  !! gravity, seed.  An empty list means valid.
  subroutine validate_particles(d, errors)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: errors
    type(dyn) :: origin, vec, comp, num
    logical :: ok
    integer :: k
    character(len=1), parameter :: AXES(3) = ["x", "y", "z"]
    if (d%kind /= DYN_K_DICT) return
    origin = dget(d, "origin")
    if (origin%kind == DYN_K_NULL) origin = dget(d, "at")
    if (origin%kind /= DYN_K_NULL) then
      call vec3(origin, vec, ok)
      if (.not. ok) then
        call char_list_append(errors, "origin " // repr_dyn(origin) &
             // " is not a position: 'origin' must be three finite " &
             // "coordinates (x, y, z)")
      else
        do k = 1, 3
          comp = dyn_list_at(vec, k)
          num = as_number(comp)
          if (num%kind /= DYN_K_INT .and. num%kind /= DYN_K_REAL) then
            call char_list_append(errors, "origin " // AXES(k) // &
                 " " // repr_dyn(comp) // &
                 " is not a number: 'origin' coordinates must be " &
                 // "finite")
          else
            block
              real(real64) :: x
              if (num%kind == DYN_K_INT) then
                x = real(num%i, real64)
              else
                x = num%r
              end if
              if (.not. ieee_is_finite(x)) then
                call char_list_append(errors, "origin " // AXES(k) &
                     // " is " // fmt_g6(x) // &
                     ", but 'origin' coordinates must be finite")
              end if
            end block
          end if
        end do
      end if
    end if
    call validate_int(errors, d, "count", MIN_COUNT, MAX_COUNT)
    call validate_float(errors, d, "life", 0.0_real64, MAX_LIFE, &
                        .false.)
    call validate_float(errors, d, "speed", 0.0_real64, MAX_SPEED, &
                        .true.)
    call validate_float(errors, d, "size", 0.0_real64, MAX_SIZE, &
                        .false.)
    call validate_float(errors, d, "spread", 0.0_real64, MAX_SPREAD, &
                        .true.)
    call validate_float(errors, d, "gravity", MIN_GRAVITY, &
                        MAX_GRAVITY, .true.)
    call validate_int(errors, d, "seed", MIN_SEED, MAX_SEED)
  end subroutine validate_particles

  ! ==================================================================
  ! Emit line
  ! ==================================================================

  !> particles_line(name, d): the .scene line
  !!   particles NAME PX PY PZ COUNT LIFE SPEED SIZE R G B SPREAD
  !!   GRAVITY SEED
  !! Floats are "%.6g"; count / seed and colour channels are ints.
  !! Missing fields fall back to the frozen defaults.
  subroutine particles_line(name, d_in, line)
    character(len=*), intent(in) :: name
    type(dyn), intent(in) :: d_in
    character(len=:), allocatable, intent(out) :: line
    type(dyn) :: d, origin
    logical :: ok
    call dyn_assign(d, d_in)
    if (d%kind /= DYN_K_DICT) d = dyn_dict()
    call vec3(dget(d, "origin"), origin, ok)
    if (.not. ok) call vec3(dget(d, "at"), origin, ok)
    if (.not. ok) origin = default_origin()
    line = "particles " // name // " " // fmt_vec(origin) // " " // &
           trim(fmt_int(int_or(dget(d, "count"), DEF_COUNT))) // &
           " " // &
           fmt_val(dyn_real(float_or(dget(d, "life"), DEF_LIFE))) // &
           " " // &
           fmt_val(dyn_real(float_or(dget(d, "speed"), DEF_SPEED))) &
           // " " // &
           fmt_val(dyn_real(float_or(dget(d, "size"), DEF_SIZE))) // &
           " " // fmt_color(dget(d, "color")) // " " // &
           fmt_val(dyn_real(float_or(dget(d, "spread"), &
                                     DEF_SPREAD))) // " " // &
           fmt_val(dyn_real(float_or(dget(d, "gravity"), &
                                     DEF_GRAVITY))) // " " // &
           trim(fmt_int(int_or(dget(d, "seed"), DEF_SEED)))
  end subroutine particles_line

  ! ==================================================================
  ! Particle math (mirror of src/particles.f90 -- frozen contract)
  ! ==================================================================

  !> particle_hash01(seed, i, k): frozen integer hash -> [0, 1).
  !! i is the 0-based particle index, k the channel (0, 1, 2).
  function particle_hash01(seed, i, k) result(h)
    integer(int64), intent(in) :: seed, i, k
    real(real64) :: h
    integer(int64) :: x
    x = modulo(seed * 1103515245_int64 + i * 12345_int64 &
               + k * 67890_int64, HASH_MOD)
    x = modulo(x * 1103515245_int64 + 12345_int64, HASH_MOD)
    h = real(x, real64) / real(HASH_MOD, real64)
  end function particle_hash01

  !> particle_state(d, i, t): state of particle i (0-based) at
  !! time t; pos is an (x, y, z) triple and scale = 1 - age/life.
  !! If life <= 0 the particle is dead: pos is the origin, scale 0.
  subroutine particle_state(d_in, idx, t, pos, scale)
    type(dyn), intent(in) :: d_in
    integer(int64), intent(in) :: idx
    real(real64), intent(in) :: t
    real(real64), intent(out) :: pos(3), scale
    type(dyn) :: d, origin
    logical :: ok
    integer :: k
    integer(int64) :: count, n, seed
    real(real64) :: life, speed, spread, gravity, age
    real(real64) :: h0, h1, h2, vel(3), org(3)
    call dyn_assign(d, d_in)
    if (d%kind /= DYN_K_DICT) d = dyn_dict()
    call vec3(dget(d, "origin"), origin, ok)
    if (.not. ok) call vec3(dget(d, "at"), origin, ok)
    if (.not. ok) origin = default_origin()
    do k = 1, 3
      org(k) = float_or(dyn_list_at(origin, k), 0.0_real64)
    end do
    life = float_or(dget(d, "life"), DEF_LIFE)
    if (life <= 0.0_real64) then
      pos = org
      scale = 0.0_real64
      return
    end if
    count = int_or(dget(d, "count"), DEF_COUNT)
    n = max(count, 1_int64)
    speed = float_or(dget(d, "speed"), DEF_SPEED)
    spread = float_or(dget(d, "spread"), DEF_SPREAD)
    gravity = float_or(dget(d, "gravity"), DEF_GRAVITY)
    seed = int_or(dget(d, "seed"), DEF_SEED)
    age = modulo(t + real(idx, real64) * (life / real(n, real64)), &
                 life)
    h0 = particle_hash01(seed, idx, 0_int64)
    h1 = particle_hash01(seed, idx, 1_int64)
    h2 = particle_hash01(seed, idx, 2_int64)
    vel(1) = (h0 - 0.5_real64) * 2.0_real64 * spread * speed
    vel(2) = speed * (0.5_real64 + 0.5_real64 * h1)
    vel(3) = (h2 - 0.5_real64) * 2.0_real64 * spread * speed
    pos(1) = org(1) + vel(1) * age
    pos(2) = org(2) + vel(2) * age &
             - 0.5_real64 * gravity * age * age
    pos(3) = org(3) + vel(3) * age
    scale = 1.0_real64 - age / life
  end subroutine particle_state

end module f3dc_ext_particles
