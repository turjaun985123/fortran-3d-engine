! f3dc_ext_skin.f90 -- skinning + morph extension for the native
! Forge3D compiler.  Port of tools/f3dc/ext_skin.py (read in full,
! 595 lines), per compiler/DESIGN.md.  Python is the oracle.
!
! Public API (exact Python names, dyn representation):
!   extract_morph(props, out) / extract_bone(props, out) /
!   extract_skin(props, out)
!       Normalised dyn dicts.  Bone defaults (at 0,0,0 / rotate
!       0,0,0 / radius 2) are filled by extract_bone; present-but-
!       malformed values pass through unchanged for the validators.
!       _as_number pass-through rule: a bool stays a dyn_bool, an
!       unconvertible string stays a dyn_str.
!   validate_morph(d, errors) / validate_bone(d, existing, errors) /
!   validate_skin(d, known, errors)
!       errors: char_list out (appended).  existing / known are dyn:
!       dyn_null mirrors Python None (no membership check); a dyn
!       list of names / bone dicts, a single dyn_str or a single
!       bone dyn_dict mirror the Python collections.
!   morph_line(d, line) / bone_line(d, line) / skin_line(d, line)
!   scene_lines(morphs, bones, skins, lines)
!       lines: char_list out (appended), morphs then bones then
!       skins, input order preserved within each group.
!
! Documented morph / skin MATH (ext_skin.py docstring; the runtime
! owners are src/skinning.f90 and runtime/f3d-skin.js): this module
! also provides flat-array mirrors whose arithmetic is written
! EXACTLY as the Python docstring / JS mirror spell it -- order of
! operations included -- because a silent no-op in these formulas
! (e.g. dropping the (1 - q*q) falloff term) still "works" while
! deforming nothing like the oracle:
!   morph_apply_flat(verts_in, kind, factor, verts_out)
!       bulge:  s = 1 + factor*0.5*(1 - q*q), q = (y - cy)/halfh,
!               halfh = max |y - cy| (0 -> copy); x/z about centroid,
!               y unchanged.
!       taper:  h = (y - ymin)/(ymax - ymin) (flat -> copy);
!               s = 1 - factor*0.5*h; x/z about centroid.
!       squash: y scale (1 - 0.5*factor), x/z scale
!               (1 + 0.25*factor), about the centroid.
!       factor == 0 is an exact copy; unknown kind -> copy (the
!       engine skinning.f90 rule; the JS mirror throws instead --
!       validate_morph rejects unknown kinds before emit, so this
!       path is unreachable for validated scenes).
!   skin_weight(dist, radius)
!       s = clamp(1 - dist/radius, 0, 1); w = s*s*(3 - 2*s);
!       radius <= 0 (or NaN) -> 0.
!   skin_apply_flat(verts_in, pivot, rot_deg, radius, verts_out)
!       p' = (1 - w)*p + w*(M*p), M = T(pivot)*Rz*Ry*Rx*T(-pivot),
!       angles in degrees, Rx/Ry/Rz conventions of f3d-skin.js.
!
! No type-bound procedures.  Number spelling in .scene lines and
! %.6g diagnostic slots is Python "%.6g" (fmt_g6 below).
module f3dc_ext_skin
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
       ieee_is_nan, ieee_is_negative, ieee_value, ieee_quiet_nan, &
       ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_list_push, &
       dyn_list_len, dyn_list_at, dyn_dict_get, dyn_dict_set, &
       dyn_dict_has, dyn_dict_len, dyn_dict_key_at, dyn_dict_value_at, &
       DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: char_list, char_list_append, fmt_int, fmt_real, &
       to_lower
  implicit none
  private

  public :: extract_morph, extract_bone, extract_skin
  public :: validate_morph, validate_bone, validate_skin
  public :: morph_line, bone_line, skin_line, scene_lines
  public :: morph_apply_flat, skin_weight, skin_apply_flat

  real(real64), parameter :: FACTOR_MIN = -2.0_real64
  real(real64), parameter :: FACTOR_MAX = 2.0_real64
  real(real64), parameter :: DEF_AT(3) = [0.0_real64, 0.0_real64, &
                                          0.0_real64]
  real(real64), parameter :: DEF_ROT(3) = [0.0_real64, 0.0_real64, &
                                           0.0_real64]
  real(real64), parameter :: DEF_RADIUS = 2.0_real64
  real(real64), parameter :: PI = 3.141592653589793_real64

  ! Accepted dict spellings, in priority order (ext_skin.py).
  character(9), parameter :: TARGET_KEYS(4) = [character(9) :: &
       "target", "object", "obj", "name"]
  character(5), parameter :: KIND_KEYS(2) = [character(5) :: &
       "kind", "type"]
  character(6), parameter :: FACTOR_KEYS(3) = [character(6) :: &
       "factor", "amount", "value"]
  character(9), parameter :: BONE_NAME_KEYS(4) = [character(9) :: &
       "name", "bone", "bonename", "bone_name"]
  character(9), parameter :: SKIN_BONE_KEYS(3) = [character(9) :: &
       "bone", "bonename", "bone_name"]
  character(9), parameter :: AT_KEYS(4) = [character(9) :: &
       "at", "position", "pos", "pivot"]
  character(8), parameter :: ROTATE_KEYS(3) = [character(8) :: &
       "rotate", "rotation", "rot"]
  character(9), parameter :: RADIUS_KEYS(2) = [character(9) :: &
       "radius", "influence"]

contains

  ! =================================================================
  ! Small Python-semantics helpers
  ! =================================================================

  function dget(d, key) result(v)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(dyn) :: v
    v = dyn_dict_get(d, key)
  end function dget

  function s_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_STR .and. allocated(v%s)) then
      out = v%s
    else
      out = ""
    end if
  end function s_of

  pure logical function is_ws(c)
    character, intent(in) :: c
    integer :: k
    k = iachar(c)
    is_ws = (k == 32 .or. k == 9 .or. k == 10 .or. k == 13 .or. &
             k == 11 .or. k == 12)
  end function is_ws

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

  !> Python .strip("\"'"): remove any leading/trailing ' or ".
  function strip_quotes(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (s(a:a) /= "'" .and. s(a:a) /= '"') exit
      a = a + 1
    end do
    do while (b >= a)
      if (s(b:b) /= "'" .and. s(b:b) /= '"') exit
      b = b - 1
    end do
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_quotes

  subroutine parse_py_float(s, x, ok)
    character(len=*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, u, w
    integer :: i, ios
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
    w = ""
    do i = 1, len(t)
      if (t(i:i) == "_") cycle
      if (index("0123456789.eE+-", t(i:i)) == 0) return
      w = w // t(i:i)
    end do
    if (len(w) == 0) return
    read (w, *, iostat=ios) x
    if (ios /= 0) then
      x = 0.0_real64
      return
    end if
    ok = .true.
  end subroutine parse_py_float

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
        val = dyn_null()
      end if
    end do
  end subroutine first_of

  !> _as_number(value): float conversion; bools and unconvertible
  !! values pass through unchanged; non-finite floats are kept.
  function as_number(v) result(out)
    type(dyn), intent(in) :: v
    type(dyn) :: out
    real(real64) :: x
    logical :: ok
    select case (v%kind)
    case (DYN_K_INT)
      out = dyn_real(real(v%i, real64))
    case (DYN_K_REAL)
      out = dyn_copy(v)
    case (DYN_K_STR)
      call parse_py_float(s_of(v), x, ok)
      if (ok) then
        out = dyn_real(x)
      else
        out = dyn_copy(v)
      end if
    case default
      out = dyn_copy(v)
    end select
  end function as_number

  !> _word(value): stripped string, case preserved.  Numbers (not
  !! bools) stringify; a dict carrying a non-empty text/value/name
  !! string mirrors the token-ish object branch.
  function word_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    type(dyn) :: inner
    integer :: k
    character(5) :: attrs(3)
    out = ""
    select case (v%kind)
    case (DYN_K_STR)
      out = strip_ws(strip_quotes(strip_ws(s_of(v))))
    case (DYN_K_INT)
      out = strip_ws(fmt_int(v%i))
    case (DYN_K_REAL)
      out = strip_ws(fmt_real(v%r))
    case (DYN_K_DICT)
      attrs = [character(5) :: "text", "value", "name"]
      do k = 1, 3
        inner = dget(v, trim(attrs(k)))
        if (inner%kind == DYN_K_STR) then
          if (len(strip_ws(s_of(inner))) > 0) then
            out = strip_ws(strip_quotes(strip_ws(s_of(inner))))
            return
          end if
        end if
      end do
    end select
  end function word_of

  !> _kind(value): _word lower-cased.
  function kind_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    out = to_lower(word_of(v))
  end function kind_of

  subroutine split_ws_commas(s, parts)
    character(len=*), intent(in) :: s
    type(char_list), intent(out) :: parts
    character(len=:), allocatable :: t
    integer :: i, a
    t = s
    do i = 1, len(t)
      if (t(i:i) == ",") t(i:i) = " "
    end do
    parts = char_list()
    i = 1
    do while (i <= len(t))
      do while (i <= len(t))
        if (.not. is_ws(t(i:i))) exit
        i = i + 1
      end do
      if (i > len(t)) exit
      a = i
      do while (i <= len(t))
        if (is_ws(t(i:i))) exit
        i = i + 1
      end do
      call char_list_append(parts, t(a:i - 1))
    end do
  end subroutine split_ws_commas

  function cl_at(parts, idx) result(out)
    type(char_list), intent(in) :: parts
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > parts%n) then
      out = ""
    else if (allocated(parts%items(idx)%s)) then
      out = parts%items(idx)%s
    else
      out = ""
    end if
  end function cl_at

  !> _vec3(value): ok=.false. mirrors a None result; otherwise out
  !! is a dyn list of the 3 _as_number-converted components
  !! (components may pass through as strings / bools / nulls).
  subroutine vec3_of(v, out, ok)
    type(dyn), intent(in) :: v
    type(dyn), intent(out) :: out
    logical, intent(out) :: ok
    type(char_list) :: parts
    type(dyn) :: lowered, comp
    integer :: i
    out = dyn_null()
    ok = .false.
    select case (v%kind)
    case (DYN_K_STR)
      call split_ws_commas(s_of(v), parts)
      if (parts%n /= 3) return
      out = dyn_list()
      do i = 1, 3
        call dyn_list_push(out, as_number(dyn_str(cl_at(parts, i))))
      end do
      ok = .true.
    case (DYN_K_DICT)
      lowered = lower_keys(v)
      if (.not. dyn_dict_has(lowered, "x") .or. &
          .not. dyn_dict_has(lowered, "y") .or. &
          .not. dyn_dict_has(lowered, "z")) return
      out = dyn_list()
      call dyn_list_push(out, as_number(dget(lowered, "x")))
      call dyn_list_push(out, as_number(dget(lowered, "y")))
      call dyn_list_push(out, as_number(dget(lowered, "z")))
      ok = .true.
    case (DYN_K_LIST)
      if (dyn_list_len(v) /= 3) return
      out = dyn_list()
      do i = 1, 3
        comp = dyn_list_at(v, i)
        call dyn_list_push(out, as_number(comp))
      end do
      ok = .true.
    end select
  end subroutine vec3_of

  !> Python "%.6g" % float(x).
  function fmt_g6(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=32) :: buf
    character(len=6) :: digits
    character(len=:), allocatable :: dig, mant, esign, enum
    integer :: epos, exp10, i, nd, ip_end
    real(real64) :: ax
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
    ax = abs(x)
    if (ax == 0.0_real64) then
      if (ieee_is_negative(x)) then
        out = "-0"
      else
        out = "0"
      end if
      return
    end if
    write (buf, "(ES14.5E3)") ax
    epos = index(buf, "E")
    digits = buf(3:3) // buf(5:9)
    read (buf(epos + 1:), *) exp10
    dig = digits
    nd = 6
    do while (nd > 1 .and. dig(nd:nd) == "0")
      nd = nd - 1
    end do
    dig = dig(1:nd)
    if (exp10 >= -4 .and. exp10 < 6) then
      if (exp10 >= 0) then
        ip_end = exp10 + 1
        if (nd > ip_end) then
          out = dig(1:ip_end) // "." // dig(ip_end + 1:nd)
        else
          out = dig
          do i = nd + 1, ip_end
            out = out // "0"
          end do
        end if
      else
        out = "0."
        do i = 1, -exp10 - 1
          out = out // "0"
        end do
        out = out // dig
      end if
    else
      if (nd > 1) then
        mant = dig(1:1) // "." // dig(2:nd)
      else
        mant = dig
      end if
      if (exp10 < 0) then
        esign = "-"
      else
        esign = "+"
      end if
      enum = fmt_int(int(abs(exp10), int64))
      if (len(enum) < 2) enum = "0" // enum
      out = mant // "e" // esign // enum
    end if
    if (ieee_is_negative(x)) out = "-" // out
  end function fmt_g6

  !> _fmt(value): %.6g for numbers, "0" for anything else / bools.
  function fmt_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    type(dyn) :: n
    n = as_number(v)
    if (n%kind == DYN_K_INT) then
      out = fmt_g6(real(n%i, real64))
    else if (n%kind == DYN_K_REAL) then
      out = fmt_g6(n%r)
    else
      out = "0"
    end if
  end function fmt_of

  !> Numeric value of an _as_number result; ok=.false. for bools
  !! and non-numbers (Python isinstance checks).
  subroutine num_value(n, x, ok)
    type(dyn), intent(in) :: n
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    x = 0.0_real64
    ok = .true.
    select case (n%kind)
    case (DYN_K_INT)
      x = real(n%i, real64)
    case (DYN_K_REAL)
      x = n%r
    case default
      ok = .false.
    end select
  end subroutine num_value

  !> _float_or(value, default).
  function float_or(v, def) result(x)
    type(dyn), intent(in) :: v
    real(real64), intent(in) :: def
    real(real64) :: x
    logical :: ok
    call num_value(as_number(v), x, ok)
    if (.not. ok) x = def
  end function float_or

  !> _vec_or(value, default).
  subroutine vec_or(v, def, out)
    type(dyn), intent(in) :: v
    real(real64), intent(in) :: def(3)
    real(real64), intent(out) :: out(3)
    type(dyn) :: vec
    logical :: ok
    integer :: i
    call vec3_of(v, vec, ok)
    if (.not. ok) then
      out = def
      return
    end if
    do i = 1, 3
      out(i) = float_or(dyn_list_at(vec, i), 0.0_real64)
    end do
  end subroutine vec_or

  ! -----------------------------------------------------------------
  ! Python repr() helpers for %r diagnostic slots
  ! -----------------------------------------------------------------
  function repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out, body
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

  recursive function py_repr(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out, acc
    integer :: k
    select case (v%kind)
    case (DYN_K_STR)
      out = repr_str(s_of(v))
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
    case (DYN_K_LIST)
      acc = "("
      do k = 1, dyn_list_len(v)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr(dyn_list_at(v, k))
      end do
      if (dyn_list_len(v) == 1) acc = acc // ","
      out = acc // ")"
    case (DYN_K_DICT)
      acc = "{"
      do k = 1, dyn_dict_len(v)
        if (k > 1) acc = acc // ", "
        acc = acc // repr_str(dyn_dict_key_at(v, k)) // ": " // &
              py_repr(dyn_dict_value_at(v, k))
      end do
      out = acc // "}"
    case default
      out = "None"
    end select
  end function py_repr

  !> _known_bone_names(known_bones): is_none mirrors a Python None
  !! return; otherwise names is a dyn dict used as a name set.
  subroutine known_bone_names(known, names, is_none)
    type(dyn), intent(in) :: known
    type(dyn), intent(out) :: names
    logical, intent(out) :: is_none
    type(dyn) :: item, raw
    character(len=:), allocatable :: nm
    logical :: found
    integer :: i
    names = dyn_dict()
    is_none = .false.
    select case (known%kind)
    case (DYN_K_NULL)
      is_none = .true.
    case (DYN_K_STR, DYN_K_DICT)
      if (known%kind == DYN_K_DICT) then
        call first_of(lower_keys(known), BONE_NAME_KEYS, raw, found)
        nm = word_of(raw)
      else
        nm = word_of(known)
      end if
      if (len(nm) > 0) call dyn_dict_set(names, nm, dyn_bool(.true.))
    case (DYN_K_LIST)
      do i = 1, dyn_list_len(known)
        item = dyn_list_at(known, i)
        if (item%kind == DYN_K_DICT) then
          call first_of(lower_keys(item), BONE_NAME_KEYS, raw, found)
          nm = word_of(raw)
        else
          nm = word_of(item)
        end if
        if (len(nm) > 0) call dyn_dict_set(names, nm, dyn_bool(.true.))
      end do
    end select
  end subroutine known_bone_names

  function vec3_list(a) result(out)
    real(real64), intent(in) :: a(3)
    type(dyn) :: out
    integer :: i
    out = dyn_list()
    do i = 1, 3
      call dyn_list_push(out, dyn_real(a(i)))
    end do
  end function vec3_list

  ! =================================================================
  ! Extract (ext_skin.extract_*)
  ! =================================================================
  subroutine extract_morph(props, out)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: out
    type(dyn) :: shaped, raw
    logical :: found
    shaped = lower_keys(props)
    out = dyn_dict()
    call first_of(shaped, TARGET_KEYS, raw, found)
    call dyn_dict_set(out, "target", dyn_str(word_of(raw)))
    call first_of(shaped, KIND_KEYS, raw, found)
    call dyn_dict_set(out, "kind", dyn_str(kind_of(raw)))
    call first_of(shaped, FACTOR_KEYS, raw, found)
    call dyn_dict_set(out, "factor", as_number(raw))
  end subroutine extract_morph

  subroutine extract_bone(props, out)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: out
    type(dyn) :: shaped, raw, vec
    logical :: found, ok
    shaped = lower_keys(props)
    out = dyn_dict()
    call first_of(shaped, BONE_NAME_KEYS, raw, found)
    call dyn_dict_set(out, "name", dyn_str(word_of(raw)))
    call first_of(shaped, AT_KEYS, raw, found)
    if (.not. found) then
      call dyn_dict_set(out, "at", vec3_list(DEF_AT))
    else
      call vec3_of(raw, vec, ok)
      if (ok) then
        call dyn_dict_set(out, "at", vec)
      else
        call dyn_dict_set(out, "at", raw)
      end if
    end if
    call first_of(shaped, ROTATE_KEYS, raw, found)
    if (.not. found) then
      call dyn_dict_set(out, "rotate", vec3_list(DEF_ROT))
    else
      call vec3_of(raw, vec, ok)
      if (ok) then
        call dyn_dict_set(out, "rotate", vec)
      else
        call dyn_dict_set(out, "rotate", raw)
      end if
    end if
    call first_of(shaped, RADIUS_KEYS, raw, found)
    if (.not. found) then
      call dyn_dict_set(out, "radius", dyn_real(DEF_RADIUS))
    else
      call dyn_dict_set(out, "radius", as_number(raw))
    end if
  end subroutine extract_bone

  subroutine extract_skin(props, out)
    type(dyn), intent(in) :: props
    type(dyn), intent(out) :: out
    type(dyn) :: shaped, raw, bone_raw
    character(len=:), allocatable :: target
    logical :: found, bone_found
    shaped = lower_keys(props)
    call first_of(shaped, TARGET_KEYS, raw, found)
    target = word_of(raw)
    call first_of(shaped, SKIN_BONE_KEYS, bone_raw, bone_found)
    if (.not. bone_found .and. len(target) == 0) then
      bone_raw = dget(shaped, "name")
    end if
    out = dyn_dict()
    call dyn_dict_set(out, "target", dyn_str(target))
    call dyn_dict_set(out, "bone", dyn_str(word_of(bone_raw)))
  end subroutine extract_skin

  ! =================================================================
  ! Validate (ext_skin.validate_*)
  ! =================================================================

  !> _validate_vec3(errors, owner, key, value).
  subroutine validate_vec3(errors, owner, key, value, present)
    type(char_list), intent(inout) :: errors
    character(len=*), intent(in) :: owner, key
    type(dyn), intent(in) :: value
    logical, intent(in) :: present
    type(dyn) :: vec, comp, num
    character(1) :: axis(3)
    real(real64) :: x
    logical :: ok
    integer :: i
    if (.not. present) return
    call vec3_of(value, vec, ok)
    if (.not. ok) then
      call char_list_append(errors, "bone " // repr_str(owner) // &
           " " // key // " " // py_repr(value) // &
           " is not a vec3: '" // key // &
           "' must be three finite coordinates (x, y, z)")
      return
    end if
    axis = ["x", "y", "z"]
    do i = 1, 3
      comp = dyn_list_at(vec, i)
      num = as_number(comp)
      call num_value(num, x, ok)
      if (.not. ok) then
        call char_list_append(errors, "bone " // repr_str(owner) // &
             " " // key // " " // axis(i) // " " // py_repr(comp) // &
             " is not a number: '" // key // &
             "' coordinates must be finite numbers")
      else if (.not. ieee_is_finite(x)) then
        call char_list_append(errors, "bone " // repr_str(owner) // &
             " " // key // " " // axis(i) // " is " // fmt_g6(x) // &
             ", but '" // key // "' coordinates must be finite")
      end if
    end do
  end subroutine validate_vec3

  subroutine validate_morph(d, errors)
    type(dyn), intent(in) :: d
    type(char_list), intent(inout) :: errors
    type(dyn) :: shaped, raw, kind_raw, factor_raw, num
    character(len=:), allocatable :: target, kind, who
    real(real64) :: x
    logical :: found, ok
    if (d%kind /= DYN_K_DICT) then
      call char_list_append(errors, "morph " // py_repr(d) // &
           " is not a morph dict: a morph must have 'target', " // &
           "'kind' and 'factor'")
      return
    end if
    shaped = lower_keys(d)
    call first_of(shaped, TARGET_KEYS, raw, found)
    target = word_of(raw)
    if (len(target) == 0) then
      call char_list_append(errors, "morph has no target: 'morph' " // &
           "must name an object or group to deform")
      who = "?"
    else
      who = target
    end if
    call first_of(shaped, KIND_KEYS, kind_raw, found)
    kind = kind_of(kind_raw)
    if (len(kind) == 0) then
      call char_list_append(errors, "morph " // repr_str(who) // &
           " has no kind: 'morph' kind must be one of bulge, " // &
           "taper, squash")
    else if (.not. (kind == "bulge" .or. kind == "taper" .or. &
                    kind == "squash")) then
      call char_list_append(errors, "morph " // repr_str(who) // &
           " kind " // py_repr(kind_raw) // &
           " is unknown: 'morph' kind must be one of bulge, " // &
           "taper, squash")
    end if
    call first_of(shaped, FACTOR_KEYS, factor_raw, found)
    if (.not. found) then
      call char_list_append(errors, "morph " // repr_str(who) // &
           " has no factor: 'morph' factor must be a number in " // &
           "the range -2..2")
      return
    end if
    num = as_number(factor_raw)
    call num_value(num, x, ok)
    if (.not. ok) then
      call char_list_append(errors, "morph " // repr_str(who) // &
           " factor " // py_repr(factor_raw) // &
           " is not a number: 'morph' factor must be a number " // &
           "in the range -2..2")
    else if (.not. ieee_is_finite(x)) then
      call char_list_append(errors, "morph " // repr_str(who) // &
           " factor is " // fmt_g6(x) // &
           ", but 'morph' factor must be a finite number in the " // &
           "range -2..2")
    else if (.not. (FACTOR_MIN <= x .and. x <= FACTOR_MAX)) then
      call char_list_append(errors, "morph " // repr_str(who) // &
           " factor is " // fmt_g6(x) // &
           ", but 'morph' factor must be in the range -2..2")
    end if
  end subroutine validate_morph

  subroutine validate_bone(d, existing_names, errors)
    type(dyn), intent(in) :: d, existing_names
    type(char_list), intent(inout) :: errors
    type(dyn) :: shaped, raw, names, num
    character(len=:), allocatable :: name, owner
    real(real64) :: x
    logical :: found, ok, is_none
    if (d%kind /= DYN_K_DICT) then
      call char_list_append(errors, "bone " // py_repr(d) // &
           " is not a bone dict: a bone must have a 'name'")
      return
    end if
    shaped = lower_keys(d)
    call first_of(shaped, BONE_NAME_KEYS, raw, found)
    name = word_of(raw)
    if (len(name) == 0) then
      call char_list_append(errors, "bone has no name: 'bone' " // &
           "must name the bone")
      owner = "?"
    else
      owner = name
      call known_bone_names(existing_names, names, is_none)
      if (.not. is_none .and. dyn_dict_has(names, name)) then
        call char_list_append(errors, "bone " // repr_str(name) // &
             " is a duplicate: a bone named " // repr_str(name) // &
             " already exists")
      end if
    end if
    call first_of(shaped, AT_KEYS, raw, found)
    call validate_vec3(errors, owner, "at", raw, found)
    call first_of(shaped, ROTATE_KEYS, raw, found)
    call validate_vec3(errors, owner, "rotate", raw, found)
    call first_of(shaped, RADIUS_KEYS, raw, found)
    if (found) then
      num = as_number(raw)
      call num_value(num, x, ok)
      if (.not. ok) then
        call char_list_append(errors, "bone " // repr_str(owner) // &
             " radius " // py_repr(raw) // &
             " is not a number: 'radius' must be more than 0")
      else if (.not. ieee_is_finite(x)) then
        call char_list_append(errors, "bone " // repr_str(owner) // &
             " radius is " // fmt_g6(x) // &
             ", but 'radius' must be a finite number more than 0")
      else if (x <= 0.0_real64) then
        call char_list_append(errors, "bone " // repr_str(owner) // &
             " radius is " // fmt_g6(x) // &
             ", but 'radius' must be more than 0")
      end if
    end if
  end subroutine validate_bone

  subroutine validate_skin(d, known_bones, errors)
    type(dyn), intent(in) :: d, known_bones
    type(char_list), intent(inout) :: errors
    type(dyn) :: shaped, raw, bone_raw, names
    character(len=:), allocatable :: target, bone, who
    logical :: found, bone_found, is_none
    if (d%kind /= DYN_K_DICT) then
      call char_list_append(errors, "skin " // py_repr(d) // &
           " is not a skin dict: a skin binding must have " // &
           "'target' and 'bone'")
      return
    end if
    shaped = lower_keys(d)
    call first_of(shaped, TARGET_KEYS, raw, found)
    target = word_of(raw)
    if (len(target) == 0) then
      call char_list_append(errors, "skin has no target: 'skin' " // &
           "must name an object or group to bind")
      who = "?"
    else
      who = target
    end if
    call first_of(shaped, SKIN_BONE_KEYS, bone_raw, bone_found)
    if (.not. bone_found .and. len(target) == 0) then
      bone_raw = dget(shaped, "name")
    end if
    bone = word_of(bone_raw)
    if (len(bone) == 0) then
      call char_list_append(errors, "skin " // repr_str(who) // &
           " has no bone: 'skin' must name a bone to bind to")
      return
    end if
    call known_bone_names(known_bones, names, is_none)
    if (.not. is_none .and. .not. dyn_dict_has(names, bone)) then
      call char_list_append(errors, "skin " // repr_str(who) // &
           " references unknown bone " // repr_str(bone) // &
           ": 'skin' bone must be a declared bone")
    end if
  end subroutine validate_skin

  ! =================================================================
  ! Emit lines (ext_skin.*_line / scene_lines)
  ! =================================================================
  subroutine morph_line(d, line)
    type(dyn), intent(in) :: d
    character(len=:), allocatable, intent(out) :: line
    type(dyn) :: e
    if (d%kind == DYN_K_DICT) then
      call extract_morph(d, e)
    else
      e = dyn_dict()
      call dyn_dict_set(e, "target", dyn_str(""))
      call dyn_dict_set(e, "kind", dyn_str(""))
      call dyn_dict_set(e, "factor", dyn_null())
    end if
    line = "morph " // s_of(dget(e, "target")) // " " // &
           s_of(dget(e, "kind")) // " " // &
           fmt_of(dyn_real(float_or(dget(e, "factor"), 0.0_real64)))
  end subroutine morph_line

  subroutine bone_line(d, line)
    type(dyn), intent(in) :: d
    character(len=:), allocatable, intent(out) :: line
    type(dyn) :: e
    real(real64) :: at(3), rot(3), radius
    if (d%kind == DYN_K_DICT) then
      call extract_bone(d, e)
    else
      e = dyn_dict()
      call dyn_dict_set(e, "name", dyn_str(""))
      call dyn_dict_set(e, "at", dyn_null())
      call dyn_dict_set(e, "rotate", dyn_null())
      call dyn_dict_set(e, "radius", dyn_null())
    end if
    call vec_or(dget(e, "at"), DEF_AT, at)
    call vec_or(dget(e, "rotate"), DEF_ROT, rot)
    radius = float_or(dget(e, "radius"), DEF_RADIUS)
    line = "bone " // s_of(dget(e, "name")) // " " // &
           fmt_g6(at(1)) // " " // fmt_g6(at(2)) // " " // &
           fmt_g6(at(3)) // " " // &
           fmt_g6(rot(1)) // " " // fmt_g6(rot(2)) // " " // &
           fmt_g6(rot(3)) // " " // fmt_g6(radius)
  end subroutine bone_line

  subroutine skin_line(d, line)
    type(dyn), intent(in) :: d
    character(len=:), allocatable, intent(out) :: line
    type(dyn) :: e
    if (d%kind == DYN_K_DICT) then
      call extract_skin(d, e)
    else
      e = dyn_dict()
      call dyn_dict_set(e, "target", dyn_str(""))
      call dyn_dict_set(e, "bone", dyn_str(""))
    end if
    line = "skin " // s_of(dget(e, "target")) // " " // &
           s_of(dget(e, "bone"))
  end subroutine skin_line

  !> _as_list(items): single dict (or other value) wrapped.
  function as_list(items) result(out)
    type(dyn), intent(in) :: items
    type(dyn) :: out
    if (items%kind == DYN_K_NULL) then
      out = dyn_list()
    else if (items%kind == DYN_K_LIST) then
      out = dyn_copy(items)
    else
      out = dyn_list()
      call dyn_list_push(out, items)
    end if
  end function as_list

  subroutine scene_lines(morphs, bones, skins, lines)
    type(dyn), intent(in) :: morphs, bones, skins
    type(char_list), intent(inout) :: lines
    type(dyn) :: lst
    character(len=:), allocatable :: line
    integer :: i
    lst = as_list(morphs)
    do i = 1, dyn_list_len(lst)
      call morph_line(dyn_list_at(lst, i), line)
      call char_list_append(lines, line)
    end do
    lst = as_list(bones)
    do i = 1, dyn_list_len(lst)
      call bone_line(dyn_list_at(lst, i), line)
      call char_list_append(lines, line)
    end do
    lst = as_list(skins)
    do i = 1, dyn_list_len(lst)
      call skin_line(dyn_list_at(lst, i), line)
      call char_list_append(lines, line)
    end do
  end subroutine scene_lines

  ! =================================================================
  ! Documented morph / skin math (flat arrays; see module header).
  ! Arithmetic mirrors ext_skin.py's docstring and the JS mirror
  ! operation for operation.
  ! =================================================================

  !> Centroid = mean of all vertices, summed in input order.
  subroutine flat_centroid(verts, n, c)
    real(real64), intent(in) :: verts(:)
    integer, intent(in) :: n
    real(real64), intent(out) :: c(3)
    integer :: i
    c = [0.0_real64, 0.0_real64, 0.0_real64]
    do i = 1, n
      c(1) = c(1) + verts(3 * i - 2)
      c(2) = c(2) + verts(3 * i - 1)
      c(3) = c(3) + verts(3 * i)
    end do
    if (n > 0) then
      c(1) = c(1) / real(n, real64)
      c(2) = c(2) / real(n, real64)
      c(3) = c(3) / real(n, real64)
    end if
  end subroutine flat_centroid

  subroutine morph_apply_flat(verts_in, kind, factor, verts_out)
    real(real64), intent(in) :: verts_in(:)
    character(len=*), intent(in) :: kind
    real(real64), intent(in) :: factor
    real(real64), allocatable, intent(out) :: verts_out(:)
    real(real64) :: c(3), halfh, q, s, ymin, ymax, h, ys, xzs
    real(real64) :: px, py, pz
    integer :: n, i
    verts_out = verts_in
    n = size(verts_in) / 3
    if (n == 0) return
    if (factor == 0.0_real64) return
    if (.not. (kind == "bulge" .or. kind == "taper" .or. &
               kind == "squash")) return
    call flat_centroid(verts_in, n, c)
    select case (kind)
    case ("bulge")
      halfh = 0.0_real64
      do i = 1, n
        halfh = max(halfh, abs(verts_in(3 * i - 1) - c(2)))
      end do
      if (halfh == 0.0_real64) return
      do i = 1, n
        px = verts_in(3 * i - 2)
        py = verts_in(3 * i - 1)
        pz = verts_in(3 * i)
        q = (py - c(2)) / halfh
        s = 1.0_real64 + factor * 0.5_real64 * (1.0_real64 - q * q)
        verts_out(3 * i - 2) = c(1) + (px - c(1)) * s
        verts_out(3 * i - 1) = py
        verts_out(3 * i) = c(3) + (pz - c(3)) * s
      end do
    case ("taper")
      ymin = verts_in(2)
      ymax = verts_in(2)
      do i = 1, n
        ymin = min(ymin, verts_in(3 * i - 1))
        ymax = max(ymax, verts_in(3 * i - 1))
      end do
      if (ymax == ymin) return
      do i = 1, n
        px = verts_in(3 * i - 2)
        py = verts_in(3 * i - 1)
        pz = verts_in(3 * i)
        h = (py - ymin) / (ymax - ymin)
        s = 1.0_real64 - factor * 0.5_real64 * h
        verts_out(3 * i - 2) = c(1) + (px - c(1)) * s
        verts_out(3 * i - 1) = py
        verts_out(3 * i) = c(3) + (pz - c(3)) * s
      end do
    case ("squash")
      ys = 1.0_real64 - 0.5_real64 * factor
      xzs = 1.0_real64 + 0.25_real64 * factor
      do i = 1, n
        px = verts_in(3 * i - 2)
        py = verts_in(3 * i - 1)
        pz = verts_in(3 * i)
        verts_out(3 * i - 2) = c(1) + (px - c(1)) * xzs
        verts_out(3 * i - 1) = c(2) + (py - c(2)) * ys
        verts_out(3 * i) = c(3) + (pz - c(3)) * xzs
      end do
    end select
  end subroutine morph_apply_flat

  !> Smoothstep falloff: s = clamp(1 - dist/radius, 0, 1),
  !! w = s*s*(3 - 2*s); radius <= 0 / NaN -> 0 (JS: !(radius > 0)).
  pure function skin_weight(dist, radius) result(w)
    real(real64), intent(in) :: dist, radius
    real(real64) :: w, s
    if (.not. (radius > 0.0_real64)) then
      w = 0.0_real64
      return
    end if
    s = 1.0_real64 - dist / radius
    if (s < 0.0_real64) s = 0.0_real64
    if (s > 1.0_real64) s = 1.0_real64
    w = s * s * (3.0_real64 - 2.0_real64 * s)
  end function skin_weight

  subroutine skin_apply_flat(verts_in, pivot, rot_deg, radius, &
                             verts_out)
    real(real64), intent(in) :: verts_in(:)
    real(real64), intent(in) :: pivot(3), rot_deg(3), radius
    real(real64), allocatable, intent(out) :: verts_out(:)
    real(real64) :: cx, sx, cy, sy, cz, sz, t
    real(real64) :: px, py, pz, dx, dy, dz, w, x, y, z, mx, my, mz
    integer :: n, i
    verts_out = verts_in
    n = size(verts_in) / 3
    cx = cos(rot_deg(1) * (PI / 180.0_real64))
    sx = sin(rot_deg(1) * (PI / 180.0_real64))
    cy = cos(rot_deg(2) * (PI / 180.0_real64))
    sy = sin(rot_deg(2) * (PI / 180.0_real64))
    cz = cos(rot_deg(3) * (PI / 180.0_real64))
    sz = sin(rot_deg(3) * (PI / 180.0_real64))
    do i = 1, n
      px = verts_in(3 * i - 2)
      py = verts_in(3 * i - 1)
      pz = verts_in(3 * i)
      dx = px - pivot(1)
      dy = py - pivot(2)
      dz = pz - pivot(3)
      w = skin_weight(sqrt(dx * dx + dy * dy + dz * dz), radius)
      if (w == 0.0_real64) cycle
      x = dx
      y = dy
      z = dz
      t = cx * y - sx * z
      z = sx * y + cx * z
      y = t
      t = cy * x + sy * z
      z = -sy * x + cy * z
      x = t
      t = cz * x - sz * y
      y = sz * x + cz * y
      x = t
      mx = pivot(1) + x
      my = pivot(2) + y
      mz = pivot(3) + z
      verts_out(3 * i - 2) = (1.0_real64 - w) * px + w * mx
      verts_out(3 * i - 1) = (1.0_real64 - w) * py + w * my
      verts_out(3 * i) = (1.0_real64 - w) * pz + w * mz
    end do
  end subroutine skin_apply_flat

end module f3dc_ext_skin
