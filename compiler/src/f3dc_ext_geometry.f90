! f3dc_ext_geometry.f90 -- Wave D geometry primitives for the native
! Forge3D compiler.  Port of tools/f3dc/ext_geometry.py (411 lines,
! read in full), per compiler/DESIGN.md.  Python is the oracle.
!
! Mirror map (ext_geometry.py -> this module):
!   GEOM_PRIMS / GEOM_PRIM_SET   -> geom_prim_count / geom_prim_at /
!                                   geom_is_prim
!   POLY_PRIMS                   -> geom_is_poly
!   DEFAULT_SEGMENTS             -> geom_default_segments(prim, seg,
!                                   found)
!   fortran_module(prim)         -> fortran_module(prim, name, found)
!                                   (found=.false. == Python None)
!   normalize_geometry(prim, props) -> normalize_geometry (dyn func)
!   validate_geometry(prim, props, geom=None)
!                                -> validate_geometry(prim, props,
!                                   geom_in, codes, messages):
!                                   geom_in == dyn_null() means the
!                                   Python geom=None (normalise here);
!                                   the Python [(code, message)] list
!                                   is returned as two parallel
!                                   char_lists, in emission order.
!   estimate_triangles(prim, props) -> estimate_triangles (int64 func)
!   scene_extra_values(prim, geom)  -> scene_extra_values (dyn func:
!                                   a dyn LIST of the flat components,
!                                   dyn_null for a Python None item)
!
! dyn conventions (f3dc_dyn): props / geom are dyn DICTS; Python
! floats are dyn_real, ints dyn_int, None dyn_null, and the
! path/points/shape tuples are dyn lists of dyn lists.  All dict keys
! are lower-cased on entry, exactly like the Python
! {str(k).lower(): v} comprehensions.  No type-bound procedures.
!
! Known divergences (flagged, never silent):
!   * _int() on a non-finite number: Python int(float("inf")) /
!     int(nan) RAISES; here the value falls back to the caller's
!     default instead (int64 conversion of inf/NaN is undefined in
!     Fortran).  Unreachable from parser-produced numbers.
!   * float(str) accepts Unicode digits / whitespace in Python; the
!     parser here accepts ASCII spellings only.
!   * scene_extra_values on a non-sequence point: Python raises
!     TypeError; here the point contributes nothing.
module f3dc_ext_geometry
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
                                           ieee_is_nan, &
                                           ieee_value, &
                                           ieee_quiet_nan, &
                                           ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, &
                      dyn_dict_get, dyn_dict_set, dyn_dict_has, &
                      dyn_dict_len, dyn_dict_key_at, &
                      dyn_dict_value_at, dyn_list_push, &
                      dyn_list_len, dyn_list_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
                      char_list_at, char_list_clear, fmt_int, &
                      fmt_real, to_lower
  implicit none
  private

  public :: normalize_geometry, validate_geometry, &
            estimate_triangles, scene_extra_values, fortran_module
  public :: geom_is_prim, geom_is_poly, geom_prim_count, &
            geom_prim_at, geom_default_segments

  ! GEOM_PRIMS, declaration order (ext_geometry.py).
  integer, parameter :: N_GEOM_PRIMS = 11
  character(16), parameter :: GEOM_PRIMS(N_GEOM_PRIMS) = &
    [character(16) :: "circle", "ring", "capsule", "tube", &
     "lathe", "extrude", "icosahedron", "octahedron", &
     "tetrahedron", "dodecahedron", "torusknot"]
  ! DEFAULT_SEGMENTS aligned with GEOM_PRIMS; 0 == no entry.
  integer, parameter :: GEOM_DEF_SEG(N_GEOM_PRIMS) = &
    [32, 32, 16, 12, 24, 0, 0, 0, 0, 0, 48]
  character(16), parameter :: POLY_PRIMS(4) = [character(16) :: &
    "icosahedron", "octahedron", "tetrahedron", "dodecahedron"]
  character(16), parameter :: COMMON_PROPS(22) = [character(16) :: &
    "at", "pos", "position", "rotate", "rot", "scale", "material", &
    "segments", "detail", "capped", "open", "texture", "colour", &
    "color", "metalness", "roughness", "specular", "shininess", &
    "name", "named", "shading", "mirror"]

contains

  ! ================================================================
  ! Primitive tables
  ! ================================================================

  pure integer function geom_prim_count()
    geom_prim_count = N_GEOM_PRIMS
  end function geom_prim_count

  function geom_prim_at(idx) result(out)
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > N_GEOM_PRIMS) then
      out = ""
    else
      out = trim(GEOM_PRIMS(idx))
    end if
  end function geom_prim_at

  !> Lower-cased prim string (Python str(prim).lower(); dyn prims are
  !! plain character values here, trailing blanks are not Python's).
  function lower_prim(prim) result(out)
    character(len=*), intent(in) :: prim
    character(len=:), allocatable :: out
    if (len_trim(prim) == 0) then
      out = ""
    else
      out = to_lower(prim(1:len_trim(prim)))
    end if
  end function lower_prim

  logical function geom_is_prim(prim)
    character(len=*), intent(in) :: prim
    character(len=:), allocatable :: pl
    integer :: k
    pl = lower_prim(prim)
    geom_is_prim = .false.
    do k = 1, N_GEOM_PRIMS
      if (pl == trim(GEOM_PRIMS(k))) geom_is_prim = .true.
    end do
  end function geom_is_prim

  logical function geom_is_poly(prim)
    character(len=*), intent(in) :: prim
    character(len=:), allocatable :: pl
    integer :: k
    pl = lower_prim(prim)
    geom_is_poly = .false.
    do k = 1, 4
      if (pl == trim(POLY_PRIMS(k))) geom_is_poly = .true.
    end do
  end function geom_is_poly

  !> DEFAULT_SEGMENTS lookup; found=.false. == prim not in the dict.
  subroutine geom_default_segments(prim, seg, found)
    character(len=*), intent(in) :: prim
    integer(int64), intent(out) :: seg
    logical, intent(out) :: found
    character(len=:), allocatable :: pl
    integer :: k
    pl = lower_prim(prim)
    seg = 0_int64
    found = .false.
    do k = 1, N_GEOM_PRIMS
      if (pl == trim(GEOM_PRIMS(k)) .and. &
          GEOM_DEF_SEG(k) /= 0) then
        seg = int(GEOM_DEF_SEG(k), int64)
        found = .true.
      end if
    end do
  end subroutine geom_default_segments

  !> _FORTRAN_MODULES lookup (fortran_module in Python).
  subroutine fortran_module(prim, name, found)
    character(len=*), intent(in) :: prim
    character(len=:), allocatable, intent(out) :: name
    logical, intent(out) :: found
    character(len=:), allocatable :: pl
    pl = lower_prim(prim)
    found = .true.
    select case (pl)
    case ("circle", "ring")
      name = "geo_flat_3d"
    case ("capsule")
      name = "geo_capsule_3d"
    case ("tube")
      name = "geo_tube_3d"
    case ("lathe")
      name = "geo_lathe_3d"
    case ("extrude")
      name = "geo_extrude_3d"
    case ("icosahedron", "octahedron", "tetrahedron", &
          "dodecahedron")
      name = "geo_poly_3d"
    case ("torusknot")
      name = "geo_torusknot_3d"
    case default
      name = ""
      found = .false.
    end select
  end subroutine fortran_module

  ! ================================================================
  ! Tolerant value helpers (_num / _int / _pairs / _segments)
  ! ================================================================

  !> Python float(str) for ASCII spellings: surrounding whitespace,
  !! inf / infinity / nan (any case, optional sign), and single
  !! underscores between digits are accepted, as in Python.
  subroutine parse_float_str(s, x, ok)
    character(len=*), intent(in) :: s
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, u, clean
    integer :: a, b, k, ios
    logical :: prev_digit, next_digit
    ok = .false.
    x = 0.0_real64
    a = 1
    b = len(s)
    do while (a <= b .and. is_py_space(s(a:a)))
      a = a + 1
    end do
    do while (b >= a .and. is_py_space(s(b:b)))
      b = b - 1
    end do
    if (a > b) return
    t = s(a:b)
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
    clean = ""
    do k = 1, len(t)
      if (t(k:k) == "_") then
        prev_digit = .false.
        next_digit = .false.
        if (k > 1) prev_digit = is_digit(t(k - 1:k - 1))
        if (k < len(t)) next_digit = is_digit(t(k + 1:k + 1))
        if (.not. (prev_digit .and. next_digit)) return
        cycle
      end if
      if (index("0123456789.+-eE", t(k:k)) == 0) return
      clean = clean // t(k:k)
    end do
    if (len(clean) == 0) return
    read (clean, *, iostat=ios) x
    if (ios /= 0) then
      x = 0.0_real64
      return
    end if
    ok = .true.
  end subroutine parse_float_str

  pure logical function is_py_space(c)
    character(len=1), intent(in) :: c
    is_py_space = (c == " " .or. c == achar(9) .or. c == achar(10) &
                   .or. c == achar(13) .or. c == achar(11) .or. &
                   c == achar(12))
  end function is_py_space

  pure logical function is_digit(c)
    character(len=1), intent(in) :: c
    is_digit = (c >= "0" .and. c <= "9")
  end function is_digit

  !> _num(value, default): bool -> default; int/float -> real;
  !! str -> float(str) or default; anything else -> default.
  !! has=.false. on return means the Python result is None (the
  !! default itself was None); out then holds 0.0.
  subroutine py_num(v, def, has_def, out, has)
    type(dyn), intent(in) :: v
    real(real64), intent(in) :: def
    logical, intent(in) :: has_def
    real(real64), intent(out) :: out
    logical, intent(out) :: has
    has = .true.
    select case (v%kind)
    case (DYN_K_INT)
      out = real(v%i, real64)
      return
    case (DYN_K_REAL)
      out = v%r
      return
    case (DYN_K_STR)
      call parse_float_str(v%s, out, has)
      if (has) return
    end select
    if (has_def) then
      out = def
      has = .true.
    else
      out = 0.0_real64
      has = .false.
    end if
  end subroutine py_num

  !> _int(value, default): int(_num(value)) -- truncation toward
  !! zero; non-finite numbers fall back to the default (Python
  !! raises; see the header divergence note).
  subroutine py_int_val(v, def, has_def, out, has)
    type(dyn), intent(in) :: v
    integer(int64), intent(in) :: def
    logical, intent(in) :: has_def
    integer(int64), intent(out) :: out
    logical, intent(out) :: has
    real(real64) :: x
    logical :: has_num
    call py_num(v, 0.0_real64, .false., x, has_num)
    if (has_num .and. ieee_is_finite(x)) then
      if (x >= -9.0e18_real64 .and. x < 9.0e18_real64) then
        out = int(x, int64)
        has = .true.
        return
      end if
    end if
    if (has_def) then
      out = def
      has = .true.
    else
      out = 0_int64
      has = .false.
    end if
  end subroutine py_int_val

  !> {str(k).lower(): v for k, v in (props or {}).items()}; a
  !! non-dict props (incl. dyn_null) becomes the empty dict.
  function norm_props(props) result(out)
    type(dyn), intent(in) :: props
    type(dyn) :: out
    integer :: k
    out = dyn_dict()
    if (props%kind /= DYN_K_DICT) return
    do k = 1, dyn_dict_len(props)
      call dyn_dict_set(out, to_lower(dyn_dict_key_at(props, k)), &
                        dyn_dict_value_at(props, k))
    end do
  end function norm_props

  !> _pairs(value, width): None for a non-sequence; a dyn list of
  !! dyn lists otherwise (nested input keeps each tuple's own
  !! length; flat input is chunked by width, trailing short tuple
  !! kept).  Components are dyn_real, or dyn_null where _num fails.
  function py_pairs(v, width) result(out)
    type(dyn), intent(in) :: v
    integer, intent(in) :: width
    type(dyn) :: out
    type(dyn) :: item, comp, tup
    real(real64) :: x
    logical :: has, all_nested
    integer :: i, j, start
    out = dyn_null()
    if (v%kind /= DYN_K_LIST) return
    out = dyn_list()
    all_nested = dyn_list_len(v) > 0
    do i = 1, dyn_list_len(v)
      item = dyn_list_at(v, i)
      if (item%kind /= DYN_K_LIST) all_nested = .false.
    end do
    if (all_nested) then
      do i = 1, dyn_list_len(v)
        item = dyn_list_at(v, i)
        tup = dyn_list()
        do j = 1, dyn_list_len(item)
          comp = dyn_list_at(item, j)
          call py_num(comp, 0.0_real64, .false., x, has)
          if (has) then
            call dyn_list_push(tup, dyn_real(x))
          else
            call dyn_list_push(tup, dyn_null())
          end if
        end do
        call dyn_list_push(out, tup)
      end do
    else
      start = 1
      do while (start <= dyn_list_len(v))
        tup = dyn_list()
        do j = start, min(start + width - 1, dyn_list_len(v))
          comp = dyn_list_at(v, j)
          call py_num(comp, 0.0_real64, .false., x, has)
          if (has) then
            call dyn_list_push(tup, dyn_real(x))
          else
            call dyn_list_push(tup, dyn_null())
          end if
        end do
        call dyn_list_push(out, tup)
        start = start + width
      end do
    end if
  end function py_pairs

  !> _segments(props, prim): dyn_int, or dyn_null when neither the
  !! prop nor DEFAULT_SEGMENTS provides one.
  function segments_of(props, prim) result(out)
    type(dyn), intent(in) :: props
    character(len=*), intent(in) :: prim
    type(dyn) :: out
    integer(int64) :: seg
    logical :: has, found
    call py_int_val(dyn_dict_get(props, "segments"), 0_int64, &
                    .false., seg, has)
    if (has) then
      out = dyn_int(seg)
      return
    end if
    call geom_default_segments(prim, seg, found)
    if (found) then
      out = dyn_int(seg)
    else
      out = dyn_null()
    end if
  end function segments_of

  !> Python round(x, 10): round-half-even at the 10th decimal.
  function round10(x) result(out)
    real(real64), intent(in) :: x
    real(real64) :: out, scaled, fl, frac
    if (.not. ieee_is_finite(x)) then
      out = x
      return
    end if
    scaled = x * 1.0e10_real64
    if (abs(scaled) >= 9.0e15_real64) then
      out = x
      return
    end if
    fl = real(floor(scaled, int64), real64)  ! FLOOR() alone is int
    frac = scaled - fl
    if (frac > 0.5_real64) then
      fl = fl + 1.0_real64
    else if (frac == 0.5_real64) then
      if (mod(fl, 2.0_real64) /= 0.0_real64) fl = fl + 1.0_real64
    end if
    out = fl / 1.0e10_real64
  end function round10

  !> Python floor division for int64 (a // b).
  pure function floor_div(a, b) result(q)
    integer(int64), intent(in) :: a, b
    integer(int64) :: q
    q = a / b
    if (mod(a, b) /= 0_int64 .and. &
        ((a < 0_int64) .neqv. (b < 0_int64))) q = q - 1_int64
  end function floor_div

  ! ================================================================
  ! Normalisation (normalize_geometry)
  ! ================================================================

  function normalize_geometry(prim_in, props_in) result(geom)
    character(len=*), intent(in) :: prim_in
    type(dyn), intent(in) :: props_in
    type(dyn) :: geom
    type(dyn) :: props, v
    character(len=:), allocatable :: prim
    real(real64) :: x, y
    logical :: has, has2
    integer(int64) :: iseg

    prim = lower_prim(prim_in)
    props = norm_props(props_in)
    geom = dyn_dict()
    call dyn_dict_set(geom, "prim", dyn_str(prim))
    call dyn_dict_set(geom, "radius", dyn_null())
    call dyn_dict_set(geom, "height", dyn_null())
    call dyn_dict_set(geom, "segments", dyn_null())
    call dyn_dict_set(geom, "size", dyn_null())
    call dyn_dict_set(geom, "inner", dyn_null())
    call dyn_dict_set(geom, "outer", dyn_null())
    call dyn_dict_set(geom, "tube", dyn_null())
    call dyn_dict_set(geom, "tube_segments", dyn_null())
    call dyn_dict_set(geom, "extrude_depth", dyn_null())
    call dyn_dict_set(geom, "path", dyn_null())
    call dyn_dict_set(geom, "points", dyn_null())
    call dyn_dict_set(geom, "shape", dyn_null())

    select case (prim)
    case ("circle")
      call py_num(dyn_dict_get(props, "radius"), 1.0_real64, &
                  .true., x, has)
      call dyn_dict_set(geom, "radius", dyn_real(x))
      call dyn_dict_set(geom, "segments", segments_of(props, prim))
    case ("ring")
      call py_num(dyn_dict_get(props, "outer"), 0.0_real64, &
                  .false., x, has)
      if (.not. has) then
        call py_num(dyn_dict_get(props, "radius"), 1.0_real64, &
                    .true., x, has)
      end if
      call dyn_dict_set(geom, "outer", dyn_real(x))
      call dyn_dict_set(geom, "radius", dyn_real(x))
      call py_num(dyn_dict_get(props, "inner"), 0.5_real64, &
                  .true., y, has)
      call dyn_dict_set(geom, "inner", dyn_real(y))
      call dyn_dict_set(geom, "size", dyn_real(y))
      call dyn_dict_set(geom, "segments", segments_of(props, prim))
    case ("capsule")
      call py_num(dyn_dict_get(props, "radius"), 0.5_real64, &
                  .true., x, has)
      call dyn_dict_set(geom, "radius", dyn_real(x))
      call py_num(dyn_dict_get(props, "height"), 2.0_real64, &
                  .true., x, has)
      call dyn_dict_set(geom, "height", dyn_real(x))
      call dyn_dict_set(geom, "segments", segments_of(props, prim))
    case ("tube")
      call py_num(dyn_dict_get(props, "radius"), 0.2_real64, &
                  .true., x, has)
      call dyn_dict_set(geom, "radius", dyn_real(x))
      call dyn_dict_set(geom, "segments", segments_of(props, prim))
      call dyn_dict_set(geom, "path", &
                        py_pairs(dyn_dict_get(props, "path"), 3))
    case ("lathe")
      call dyn_dict_set(geom, "segments", segments_of(props, prim))
      call dyn_dict_set(geom, "points", &
                        py_pairs(dyn_dict_get(props, "points"), 2))
    case ("extrude")
      call py_num(dyn_dict_get(props, "extrude_depth"), &
                  0.0_real64, .false., x, has)
      if (.not. has) then
        call py_num(dyn_dict_get(props, "depth"), 0.5_real64, &
                    .true., x, has)
      end if
      call dyn_dict_set(geom, "extrude_depth", dyn_real(x))
      call dyn_dict_set(geom, "height", dyn_real(x))
      call dyn_dict_set(geom, "shape", &
                        py_pairs(dyn_dict_get(props, "shape"), 2))
    case ("icosahedron", "octahedron", "tetrahedron", &
          "dodecahedron")
      call py_num(dyn_dict_get(props, "radius"), 1.0_real64, &
                  .true., x, has)
      call dyn_dict_set(geom, "radius", dyn_real(x))
    case ("torusknot")
      call py_num(dyn_dict_get(props, "radius"), 1.0_real64, &
                  .true., x, has)
      call dyn_dict_set(geom, "radius", dyn_real(x))
      call py_num(dyn_dict_get(props, "tube"), 0.0_real64, &
                  .false., y, has)
      if (.not. has) y = round10(x * 0.3_real64)
      call dyn_dict_set(geom, "tube", dyn_real(y))
      call dyn_dict_set(geom, "size", dyn_real(y))
      v = segments_of(props, prim)
      call dyn_dict_set(geom, "segments", v)
      call py_int_val(dyn_dict_get(props, "tube_segments"), &
                      0_int64, .false., iseg, has)
      if (.not. has) then
        call py_int_val(dyn_dict_get(props, "rings"), 0_int64, &
                        .false., iseg, has)
      end if
      if (.not. has) then
        ! max(6, (seg or 48) // 4): seg is None or 0 -> 48.
        if (v%kind == DYN_K_INT .and. v%i /= 0_int64) then
          iseg = floor_div(v%i, 4_int64)
        else
          iseg = 12_int64  ! 48 // 4
        end if
        iseg = max(6_int64, iseg)
      end if
      call dyn_dict_set(geom, "tube_segments", dyn_int(iseg))
      has2 = has  ! silence any unused-variable noise paths
    end select
  end function normalize_geometry

  ! ================================================================
  ! Validation (validate_geometry -> [(code, message)])
  ! ================================================================

  subroutine add_err(codes, messages, code, msg)
    type(char_list), intent(inout) :: codes, messages
    character(len=*), intent(in) :: code, msg
    call char_list_append(codes, code)
    call char_list_append(messages, msg)
  end subroutine add_err

  !> Python str(value) for the %s slots of the E301 messages.
  recursive function py_str_val(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    character(len=:), allocatable :: acc
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
      out = v%s
    case (DYN_K_LIST)
      acc = "("
      do k = 1, dyn_list_len(v)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr_val(dyn_list_at(v, k))
      end do
      if (dyn_list_len(v) == 1) acc = acc // ","
      out = acc // ")"
    case default
      out = "None"
    end select
  end function py_str_val

  !> Python repr(value) (only the %r slot: a prop key string).
  recursive function py_repr_val(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_STR) then
      out = repr_str(v%s)
    else
      out = py_str_val(v)
    end if
  end function py_repr_val

  !> Python repr() of a string: quote choice + escapes (ASCII;
  !! mirrors f3dc_validate's repr_str).
  function repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out, body
    character :: quote
    integer :: k, c
    logical :: has_sq, has_dq
    character(16), parameter :: HD = "0123456789abcdef"
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
        body = body // "\x" // HD(c / 16 + 1:c / 16 + 1) // &
               HD(mod(c, 16) + 1:mod(c, 16) + 1)
      else
        body = body // s(k:k)
      end if
    end do
    out = quote // body // quote
  end function repr_str

  !> C printf "%g" (Python "%g" % float): 6 significant digits,
  !! trailing zeros stripped, scientific outside [-4, 6).
  function fmt_g(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=64) :: buf
    character(len=16) :: digits, ebuf
    integer :: epos, dec_exp, ndig, i, j
    logical :: neg
    if (ieee_is_nan(x)) then
      out = "nan"
      return
    end if
    if (.not. ieee_is_finite(x)) then
      if (x < 0.0_real64) then
        out = "-inf"
      else
        out = "inf"
      end if
      return
    end if
    if (x == 0.0_real64) then
      out = "0"
      return
    end if
    neg = x < 0.0_real64
    write (buf, "(ES25.5E3)") abs(x)
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
    read (buf(epos + 1:), *) dec_exp
    do while (ndig > 1 .and. digits(ndig:ndig) == "0")
      ndig = ndig - 1
    end do
    if (dec_exp >= -4 .and. dec_exp < 6) then
      if (dec_exp >= 0) then
        if (ndig > dec_exp + 1) then
          out = digits(1:dec_exp + 1) // "." // &
                digits(dec_exp + 2:ndig)
        else
          out = digits(1:ndig) // &
                repeat("0", dec_exp + 1 - ndig)
        end if
      else
        out = "0." // repeat("0", -dec_exp - 1) // digits(1:ndig)
      end if
    else
      if (ndig > 1) then
        out = digits(1:1) // "." // digits(2:ndig)
      else
        out = digits(1:1)
      end if
      if (dec_exp >= 0) then
        write (ebuf, "(A,I0)") "e+", dec_exp
      else
        write (ebuf, "(A,I0)") "e-", -dec_exp
      end if
      block
        character(len=:), allocatable :: enum
        enum = ebuf(3:len_trim(ebuf))
        if (len(enum) < 2) enum = "0" // enum
        out = out // ebuf(1:2) // enum
      end block
    end if
    if (neg) out = "-" // out
  end function fmt_g

  !> Numeric view of a geom component for checks: has=.false. for
  !! None / non-numbers (Python None after _num / a missing key).
  subroutine geom_num(geom, key, x, has)
    type(dyn), intent(in) :: geom
    character(len=*), intent(in) :: key
    real(real64), intent(out) :: x
    logical, intent(out) :: has
    type(dyn) :: v
    v = dyn_dict_get(geom, key)
    call py_num(v, 0.0_real64, .false., x, has)
    ! A stored string stays a string in Python's geom dict, and
    ! math.isfinite(str) would raise; normalised geoms never store
    ! one, so treating it via _num above is the tolerant choice.
    if (v%kind == DYN_K_BOOL) has = .false.
  end subroutine geom_num

  !> _check_positive: value None / non-finite / <= 0 -> E301.
  subroutine check_positive(codes, messages, prim, label, geom, key)
    type(char_list), intent(inout) :: codes, messages
    character(len=*), intent(in) :: prim, label, key
    type(dyn), intent(in) :: geom
    real(real64) :: x
    logical :: has
    type(dyn) :: v
    v = dyn_dict_get(geom, key)
    call geom_num(geom, key, x, has)
    if (.not. has .or. .not. ieee_is_finite(x) .or. x <= 0.0_real64) &
      then
      call add_err(codes, messages, "E301", prim // " " // label // &
                   " is " // py_str_val(v) // &
                   ", but it must be more than 0")
    end if
  end subroutine check_positive

  !> _EXAMPLES[prim].
  function example_for(prim) result(out)
    character(len=*), intent(in) :: prim
    character(len=:), allocatable :: out
    select case (prim)
    case ("tube")
      out = "path 0,0,0 1,1,0"
    case ("lathe")
      out = "points 0,0 0.5,1"
    case ("extrude")
      out = "shape 0,0 1,0 0,1"
    case default
      out = ""
    end select
  end function example_for

  !> _check_points: shared point-list checks; ok=.true. when usable.
  subroutine check_points(codes, messages, prim, label, points, &
                          minimum, width, ok)
    type(char_list), intent(inout) :: codes, messages
    character(len=*), intent(in) :: prim, label
    type(dyn), intent(in) :: points
    integer, intent(in) :: minimum, width
    logical, intent(out) :: ok
    type(dyn) :: point, comp
    integer :: i, j, npts
    real(real64) :: x
    logical :: has, bad
    ok = .false.
    npts = 0
    if (points%kind == DYN_K_LIST) npts = dyn_list_len(points)
    if (points%kind /= DYN_K_LIST .or. npts < minimum) then
      call add_err(codes, messages, "E301", prim // &
        " needs at least " // trim(fmt_int(int(minimum, int64))) // &
        " " // label // " points, got " // &
        trim(fmt_int(int(npts, int64))) // "; write e.g. " // &
        prim // " " // example_for(prim))
      return
    end if
    do i = 1, npts
      point = dyn_list_at(points, i)
      bad = .false.
      if (point%kind /= DYN_K_LIST) then
        bad = .true.
      else if (dyn_list_len(point) /= width) then
        bad = .true.
      else
        do j = 1, dyn_list_len(point)
          comp = dyn_list_at(point, j)
          call py_num(comp, 0.0_real64, .false., x, has)
          if (.not. has .or. .not. ieee_is_finite(x)) bad = .true.
        end do
      end if
      if (bad) then
        call add_err(codes, messages, "E301", prim // " " // &
          label // " points must be groups of " // &
          trim(fmt_int(int(width, int64))) // " plain numbers")
        return
      end if
    end do
    ok = .true.
  end subroutine check_points

  !> _PRIM_PROPS[prim] membership (declaration order is only used
  !! sorted, for the message; membership is order-free).
  logical function prim_prop_allowed(prim, key)
    character(len=*), intent(in) :: prim, key
    character(16) :: props(4)
    integer :: n, k
    n = 0
    select case (prim)
    case ("circle")
      props(1) = "radius"; n = 1
    case ("ring")
      props(1) = "radius"; props(2) = "outer"; props(3) = "inner"
      n = 3
    case ("capsule")
      props(1) = "radius"; props(2) = "height"; n = 2
    case ("tube")
      props(1) = "radius"; props(2) = "path"; n = 2
    case ("lathe")
      props(1) = "points"; n = 1
    case ("extrude")
      props(1) = "shape"; props(2) = "extrude_depth"
      props(3) = "depth"; n = 3
    case ("icosahedron", "octahedron", "tetrahedron", &
          "dodecahedron")
      props(1) = "radius"; n = 1
    case ("torusknot")
      props(1) = "radius"; props(2) = "tube"
      props(3) = "tube_segments"; props(4) = "rings"; n = 4
    end select
    prim_prop_allowed = .false.
    do k = 1, n
      if (key == trim(props(k))) prim_prop_allowed = .true.
    end do
  end function prim_prop_allowed

  !> ", ".join(sorted(_PRIM_PROPS[prim])).
  function prim_props_sorted_csv(prim) result(out)
    character(len=*), intent(in) :: prim
    character(len=:), allocatable :: out
    type(char_list) :: items
    integer :: k
    select case (prim)
    case ("circle")
      call char_list_append(items, "radius")
    case ("ring")
      call char_list_append(items, "inner")
      call char_list_append(items, "outer")
      call char_list_append(items, "radius")
    case ("capsule")
      call char_list_append(items, "height")
      call char_list_append(items, "radius")
    case ("tube")
      call char_list_append(items, "path")
      call char_list_append(items, "radius")
    case ("lathe")
      call char_list_append(items, "points")
    case ("extrude")
      call char_list_append(items, "depth")
      call char_list_append(items, "extrude_depth")
      call char_list_append(items, "shape")
    case ("icosahedron", "octahedron", "tetrahedron", &
          "dodecahedron")
      call char_list_append(items, "radius")
    case ("torusknot")
      call char_list_append(items, "radius")
      call char_list_append(items, "rings")
      call char_list_append(items, "tube")
      call char_list_append(items, "tube_segments")
    end select
    out = ""
    do k = 1, char_list_len(items)
      if (k > 1) out = out // ", "
      out = out // char_list_at(items, k)
    end do
    call char_list_clear(items)
  end function prim_props_sorted_csv

  !> Python str sort order: code-point (== byte) lexicographic.
  pure logical function py_str_less(a, b)
    character(len=*), intent(in) :: a, b
    integer :: k, n
    n = min(len(a), len(b))
    py_str_less = .false.
    do k = 1, n
      if (iachar(a(k:k)) /= iachar(b(k:k))) then
        py_str_less = iachar(a(k:k)) < iachar(b(k:k))
        return
      end if
    end do
    py_str_less = len(a) < len(b)
  end function py_str_less

  subroutine validate_geometry(prim_in, props_in, geom_in, codes, &
                               messages)
    character(len=*), intent(in) :: prim_in
    type(dyn), intent(in) :: props_in, geom_in
    type(char_list), intent(inout) :: codes, messages
    character(len=:), allocatable :: prim, key, joined
    type(dyn) :: props, geom, points, point, comp
    type(char_list) :: keys
    real(real64) :: x, outer
    logical :: has, has_outer, ok, allowed
    integer :: i, j, k
    character(len=:), allocatable :: tmp

    call char_list_clear(codes)
    call char_list_clear(messages)
    prim = lower_prim(prim_in)
    if (.not. geom_is_prim(prim)) return
    props = norm_props(props_in)
    if (geom_in%kind == DYN_K_DICT) then
      geom = dyn_copy(geom_in)
    else
      geom = normalize_geometry(prim, props)
    end if

    ! Unknown-prop errors, in sorted(props) order.
    do k = 1, dyn_dict_len(props)
      call char_list_append(keys, dyn_dict_key_at(props, k))
    end do
    do i = 1, char_list_len(keys)  ! insertion sort (lists are tiny)
      do j = i + 1, char_list_len(keys)
        if (py_str_less(char_list_at(keys, j), &
                        char_list_at(keys, i))) then
          tmp = char_list_at(keys, i)
          keys%items(i)%s = char_list_at(keys, j)
          keys%items(j)%s = tmp
        end if
      end do
    end do
    do k = 1, char_list_len(keys)
      key = char_list_at(keys, k)
      allowed = prim_prop_allowed(prim, key)
      if (.not. allowed) then
        do i = 1, 22
          if (key == trim(COMMON_PROPS(i))) allowed = .true.
        end do
      end if
      if (.not. allowed) then
        call add_err(codes, messages, "E301", &
          repr_str(key) // " is not a " // prim // &
          " property; " // prim // " properties are: " // &
          prim_props_sorted_csv(prim))
      end if
    end do
    call char_list_clear(keys)

    if (prim == "circle" .or. prim == "capsule" .or. &
        geom_is_poly(prim)) then
      call check_positive(codes, messages, prim, "radius", geom, &
                          "radius")
    end if
    if (prim == "capsule") then
      call check_positive(codes, messages, prim, "height", geom, &
                          "height")
    end if
    if (prim == "ring") then
      call check_positive(codes, messages, prim, "outer radius", &
                          geom, "outer")
      block
        type(dyn) :: innerv
        innerv = dyn_dict_get(geom, "inner")
        call geom_num(geom, "inner", x, has)
        call geom_num(geom, "outer", outer, has_outer)
        if (.not. has .or. .not. ieee_is_finite(x) .or. &
            x < 0.0_real64) then
          call add_err(codes, messages, "E301", &
            "ring inner radius is " // py_str_val(innerv) // &
            ", but it must be 0 or more")
        else if (has_outer .and. x >= outer) then
          call add_err(codes, messages, "E301", &
            "ring inner radius " // py_str_val(innerv) // &
            " must be smaller than the outer radius " // &
            py_str_val(dyn_dict_get(geom, "outer")))
        end if
      end block
    end if
    if (prim == "tube") then
      call check_positive(codes, messages, prim, "radius", geom, &
                          "radius")
      points = dyn_dict_get(geom, "path")
      call check_points(codes, messages, prim, "path", points, 2, &
                        3, ok)
    end if
    if (prim == "lathe") then
      points = dyn_dict_get(geom, "points")
      call check_points(codes, messages, prim, "profile", points, &
                        2, 2, ok)
      if (ok) then
        do i = 1, dyn_list_len(points)
          point = dyn_list_at(points, i)
          comp = dyn_list_at(point, 1)
          call py_num(comp, 0.0_real64, .false., x, has)
          if (has .and. x < 0.0_real64) then
            joined = ""
            do j = 1, dyn_list_len(point)
              if (j > 1) joined = joined // ", "
              block
                real(real64) :: cx
                logical :: chas
                call py_num(dyn_list_at(point, j), 0.0_real64, &
                            .false., cx, chas)
                joined = joined // trim(fmt_g(cx))
              end block
            end do
            call add_err(codes, messages, "E301", &
              "lathe point " // joined // &
              " has a negative radius (" // py_str_val(comp) // &
              "); lathe x values are radii and must be 0 or more")
            exit
          end if
        end do
      end if
    end if
    if (prim == "extrude") then
      call check_positive(codes, messages, prim, "extrude_depth", &
                          geom, "extrude_depth")
      points = dyn_dict_get(geom, "shape")
      call check_points(codes, messages, prim, "shape", points, 3, &
                        2, ok)
    end if
    if (prim == "torusknot") then
      call check_positive(codes, messages, prim, "radius", geom, &
                          "radius")
      call check_positive(codes, messages, prim, "tube", geom, &
                          "tube")
    end if
  end subroutine validate_geometry

  ! ================================================================
  ! Triangle estimates (estimate_triangles)
  ! ================================================================

  function estimate_triangles(prim_in, props_in) result(total)
    character(len=*), intent(in) :: prim_in
    type(dyn), intent(in) :: props_in
    integer(int64) :: total
    type(dyn) :: props, geom, v
    character(len=:), allocatable :: prim
    integer(int64) :: seg, npts, rounded, hr, tseg

    prim = lower_prim(prim_in)
    props = norm_props(props_in)
    geom = normalize_geometry(prim, props)
    total = 0_int64
    seg = 0_int64
    v = dyn_dict_get(geom, "segments")
    if (v%kind == DYN_K_INT) seg = v%i
    select case (prim)
    case ("circle")
      total = 2_int64 * seg
    case ("ring")
      total = 4_int64 * seg
    case ("capsule")
      rounded = int(ceiling(real(seg, real64) / 4.0_real64), &
                    int64) * 4_int64
      hr = floor_div(rounded, 4_int64)
      total = 2_int64 * rounded + &
              2_int64 * rounded * (2_int64 * hr - 1_int64)
    case ("tube")
      npts = 0_int64
      v = dyn_dict_get(geom, "path")
      if (v%kind == DYN_K_LIST) npts = int(dyn_list_len(v), int64)
      if (npts >= 2_int64) &
        total = (npts - 1_int64) * seg * 2_int64 + 2_int64 * seg
    case ("lathe")
      npts = 0_int64
      v = dyn_dict_get(geom, "points")
      if (v%kind == DYN_K_LIST) npts = int(dyn_list_len(v), int64)
      if (npts >= 2_int64) &
        total = (npts - 1_int64) * seg * 2_int64
    case ("extrude")
      npts = 0_int64
      v = dyn_dict_get(geom, "shape")
      if (v%kind == DYN_K_LIST) npts = int(dyn_list_len(v), int64)
      if (npts >= 3_int64) total = 4_int64 * npts - 4_int64
    case ("tetrahedron")
      total = 4_int64
    case ("octahedron")
      total = 8_int64
    case ("icosahedron")
      total = 20_int64
    case ("dodecahedron")
      total = 36_int64
    case ("torusknot")
      tseg = 0_int64
      v = dyn_dict_get(geom, "tube_segments")
      if (v%kind == DYN_K_INT) tseg = v%i
      total = seg * tseg * 2_int64
    end select
  end function estimate_triangles

  ! ================================================================
  ! .scene trailing values (scene_extra_values)
  ! ================================================================

  function scene_extra_values(prim_in, geom) result(out)
    character(len=*), intent(in) :: prim_in
    type(dyn), intent(in) :: geom
    type(dyn) :: out
    type(dyn) :: raw, point
    character(len=:), allocatable :: prim, key
    integer :: i, j
    out = dyn_list()
    if (geom%kind /= DYN_K_DICT) return
    prim = lower_prim(prim_in)
    select case (prim)
    case ("tube")
      key = "path"
    case ("lathe")
      key = "points"
    case ("extrude")
      key = "shape"
    case default
      return
    end select
    raw = dyn_dict_get(geom, key)
    if (raw%kind /= DYN_K_LIST) return
    do i = 1, dyn_list_len(raw)
      point = dyn_list_at(raw, i)
      if (point%kind /= DYN_K_LIST) cycle
      do j = 1, dyn_list_len(point)
        call dyn_list_push(out, dyn_list_at(point, j))
      end do
    end do
  end function scene_extra_values

end module f3dc_ext_geometry
