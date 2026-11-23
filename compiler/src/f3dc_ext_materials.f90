! f3dc_ext_materials.f90 -- port of tools/f3dc/ext_materials.py
!
! Forge3D Wave A material extension: ``standard`` material + PPM
! textures.  Mirror of the Python module, function by function:
!
!   WAVEA_MATERIALS        -> MAT_WAVEA_MATERIALS parameter
!   DEFAULTS               -> MAT_DEFAULTS parameter (MAT_NUMERIC_KEYS
!                             gives the key order)
!   extract_material_ext(props) -> dict
!   validate_material_ext(material, ext) -> list[str]  (char_list out)
!   objmat_line(name, material, ext) -> str | None     (line + found)
!   apply_to_ir_object(obj) -> None                    (in place)
!
! Python dicts/objects are dyn values (module f3dc_dyn): IR objects
! are dyn DICTS, so ``obj.extensions["raw_props"]`` is the dict key
! "extensions" -> "raw_props", ``obj.material`` is the dict key
! "material", and the duck-typed attribute fallbacks in
! apply_to_ir_object read the object's own top-level dict keys.
!
! This module does NOT register with f3dc_ir's extension registry:
! the Python module never calls ir_nodes.register_extension either.
! It is wired by the coordinator at the guarded-import sites in
! validate.py / emit_fortran.py -- in Fortran, the DISPATCH site in
! f3dc_validate (dispatch_ext_materials) and the EXT HOOK in
! f3dc_emit_fortran (hook_objmat_line); see the port report for the
! exact patches.
!
! No type-bound procedures anywhere (flang-18 constraint): free
! subroutines/functions only.
module f3dc_ext_materials
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, &
                      dyn_dict_get, dyn_dict_set, dyn_dict_has, &
                      dyn_dict_len, dyn_dict_key_at, &
                      dyn_dict_value_at, dyn_list_at, dyn_list_len, &
                      dyn_list_push, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real, to_lower, char_list, &
                      char_list_append, str_builder, sb_init, &
                      sb_add, sb_text
  implicit none
  private

  public :: extract_material_ext, validate_material_ext, objmat_line
  public :: apply_to_ir_object
  public :: material_extra_lines
  public :: MAT_SLOT_KEYS

  !> v3.0 Phase 4 texture-slot prop keys, in .scene 'objtex' order
  !! (the matching SLOT names emitted are normal/mr/emissive/
  !! occlusion -- see slot_line_name).
  character(len=12), parameter :: MAT_SLOT_KEYS(4) = &
    [character(len=12) :: "normalmap", "mr", "emissivemap", &
     "occlusionmap"]

  ! _NAMED_COLORS fallback table for the emissive colour key
  ! (identical to ir_nodes.NAMED_COLORS, as copied in
  ! f3dc_ext_lights_env).
  integer, parameter :: MAT_N_NAMED = 13
  character(len=8), parameter :: MAT_NAMED_KEYS(MAT_N_NAMED) = [ &
    "red     ", "green   ", "blue    ", "yellow  ", "magenta ", &
    "cyan    ", "orange  ", "purple  ", "pink    ", "white   ", &
    "black   ", "gray    ", "grey    "]
  integer, parameter :: MAT_NAMED_RGB(3, MAT_N_NAMED) = reshape([ &
    220, 60, 60,    60, 220, 60,    60, 100, 240,  240, 220, 50, &
    200, 80, 220,   60, 220, 220,   240, 140, 40,  140, 80, 200, &
    240, 150, 190,  240, 240, 240,  20, 20, 25,    140, 140, 145, &
    140, 140, 145], [3, MAT_N_NAMED])
  public :: MAT_WAVEA_MATERIALS, MAT_NUMERIC_KEYS, MAT_DEFAULTS, &
            MAT_RANGES_LO, MAT_RANGES_HI

  !> WAVEA_MATERIALS = ("standard",)
  character(len=8), parameter :: MAT_WAVEA_MATERIALS(1) = ["standard"]

  !> _NUMERIC_KEYS, in the Python tuple's order.
  character(len=9), parameter :: MAT_NUMERIC_KEYS(4) = &
    [character(len=9) :: "metalness", "roughness", "specular", &
     "shininess"]

  !> DEFAULTS[key] per MAT_NUMERIC_KEYS.
  real(real64), parameter :: MAT_DEFAULTS(4) = &
    [0.0_real64, 1.0_real64, 0.5_real64, 32.0_real64]

  !> _RANGES[key] = (low, high) per MAT_NUMERIC_KEYS.
  real(real64), parameter :: MAT_RANGES_LO(4) = &
    [0.0_real64, 0.0_real64, 0.0_real64, 0.0_real64]
  real(real64), parameter :: MAT_RANGES_HI(4) = &
    [1.0_real64, 1.0_real64, 1.0_real64, 1000.0_real64]

  ! _RELEVANT: standard -> keys 1,2 ; phong -> keys 3,4.
  ! _TEXTURE_EXTS = (".ppm", ".png")  ! .png added v3.0 Phase 4

contains

  ! ================================================================
  ! Small Python-semantics helpers
  ! ================================================================

  !> Python str.strip() (ASCII whitespace set).
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

  pure logical function is_ws(ch)
    character, intent(in) :: ch
    is_ws = ch == " " .or. ch == achar(9) .or. ch == achar(10) .or. &
            ch == achar(13) .or. ch == achar(11) .or. ch == achar(12)
  end function is_ws

  !> Python s.strip(chars): strip any of chars from both ends.
  function strip_chars(s, chars) result(out)
    character(*), intent(in) :: s, chars
    character(:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (index(chars, s(a:a)) == 0) exit
      a = a + 1
    end do
    do while (b >= a)
      if (index(chars, s(b:b)) == 0) exit
      b = b - 1
    end do
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_chars

  !> Python str(value) for a dyn value.
  recursive function py_str(v) result(out)
    type(dyn), intent(in) :: v
    character(:), allocatable :: out
    integer :: k
    character(:), allocatable :: acc
    type(str_builder) :: sb
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
      out = fmt_int(v%i)
    case (DYN_K_REAL)
      out = fmt_real(v%r)
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = v%s
      else
        out = ""
      end if
    case (DYN_K_LIST)
      call sb_init(sb)
      call sb_add(sb, "[")
      do k = 1, dyn_list_len(v)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, py_repr(dyn_list_at(v, k)))
      end do
      acc = sb_text(sb)
      out = acc // "]"
    case (DYN_K_DICT)
      call sb_init(sb)
      call sb_add(sb, "{")
      do k = 1, dyn_dict_len(v)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, py_repr(dyn_str(dyn_dict_key_at(v, k))))
        call sb_add(sb, ": ")
        call sb_add(sb, py_repr(dyn_dict_value_at(v, k)))
      end do
      acc = sb_text(sb)
      out = acc // "}"
    case default
      out = ""
    end select
  end function py_str

  !> Python repr(value) for a dyn value.
  recursive function py_repr(v) result(out)
    type(dyn), intent(in) :: v
    character(:), allocatable :: out
    if (v%kind == DYN_K_STR) then
      if (allocated(v%s)) then
        out = repr_str(v%s)
      else
        out = repr_str("")
      end if
    else if (v%kind == DYN_K_LIST .or. v%kind == DYN_K_DICT) then
      out = py_str(v)  ! str() of a container IS its repr in Python
    else
      out = py_str(v)
    end if
  end function py_repr

  !> Python repr(str): single quotes unless the string contains a
  !! single quote and no double quote; backslash escapes.
  function repr_str(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out, body
    type(str_builder) :: sb
    character :: q
    integer :: k, code
    character(len=2) :: hexd
    if (index(s, "'") > 0 .and. index(s, '"') == 0) then
      q = '"'
    else
      q = "'"
    end if
    call sb_init(sb)
    do k = 1, len(s)
      code = iachar(s(k:k))
      if (s(k:k) == "\") then
        call sb_add(sb, "\\")
      else if (s(k:k) == q) then
        call sb_add(sb, "\")
        call sb_add(sb, q)
      else if (code == 10) then
        call sb_add(sb, "\n")
      else if (code == 13) then
        call sb_add(sb, "\r")
      else if (code == 9) then
        call sb_add(sb, "\t")
      else if (code < 32 .or. code == 127) then
        write(hexd, "(Z2.2)") code
        call sb_add(sb, "\x")
        call sb_add(sb, to_lower(hexd))
      else
        call sb_add(sb, s(k:k))
      end if
    end do
    body = sb_text(sb)
    out = q // body // q
  end function repr_str

  !> Python "%g" % x  (C printf %g, precision 6).
  function fmt_g(x) result(out)
    real(real64), intent(in) :: x
    character(:), allocatable :: out
    type(str_builder) :: sb
    character(len=40) :: buf
    character(len=17) :: digs
    integer :: exp10, k, last, ios
    logical :: neg
    if (x /= x) then
      out = "nan"
      return
    end if
    if (abs(x) > huge(x) / 2.0_real64) then
      if (x < 0.0_real64) then
        out = "-inf"
      else
        out = "inf"
      end if
      return
    end if
    if (x == 0.0_real64) then
      ! Python: "%g" % -0.0 == "-0"; % 0.0 == "0".
      if (transfer(x, 0_int64) < 0_int64) then
        out = "-0"
      else
        out = "0"
      end if
      return
    end if
    neg = x < 0.0_real64
    ! 17 significant digits, correctly rounded by the runtime:
    ! buf looks like "d.ddddddddddddddddE+XXX" (ES format, possibly
    ! with a leading blank); locate the exponent marker explicitly.
    write(buf, "(ES24.16E3)", iostat=ios) abs(x)
    buf = adjustl(buf)
    digs = ""
    digs(1:1) = buf(1:1)
    digs(2:17) = buf(3:18)
    read(buf(index(buf, "E") + 1:), *) exp10
    ! Round the 17-digit string to 6 significant digits
    ! (round-half-even on an exact tie of the printed digits).
    call round_digits(digs, exp10)
    ! Strip trailing zeros for rendering decisions.
    last = 6
    do while (last > 1)
      if (digs(last:last) /= "0") exit
      last = last - 1
    end do
    if (exp10 < -4 .or. exp10 >= 6) then
      ! Scientific: d[.ddd]e+-XX (exponent at least 2 digits).
      call sb_init(sb)
      call sb_add(sb, digs(1:1))
      if (last > 1) then
        call sb_add(sb, ".")
        call sb_add(sb, digs(2:last))
      end if
      call sb_add(sb, "e")
      if (exp10 < 0) then
        call sb_add(sb, "-")
      else
        call sb_add(sb, "+")
      end if
      if (abs(exp10) < 10) call sb_add(sb, "0")
      call sb_add(sb, trim(adjustl(fmt_int(int(abs(exp10), int64)))))
      out = sb_text(sb)
    else if (exp10 >= 0) then
      ! Fixed, integer part has exp10+1 digits.
      if (exp10 + 1 >= 6) then
        call sb_init(sb)
        call sb_add(sb, digs(1:6))
        do k = 1, exp10 + 1 - 6
          call sb_add(sb, "0")
        end do
        out = sb_text(sb)
      else
        call sb_init(sb)
        call sb_add(sb, digs(1:exp10 + 1))
        if (last > exp10 + 1) then
          call sb_add(sb, ".")
          call sb_add(sb, digs(exp10 + 2:last))
        end if
        out = sb_text(sb)
      end if
    else
      ! Fixed, 0.000ddd form.
      call sb_init(sb)
      call sb_add(sb, "0.")
      do k = 1, -exp10 - 1
        call sb_add(sb, "0")
      end do
      call sb_add(sb, digs(1:last))
      out = sb_text(sb)
    end if
    if (neg) out = "-" // out
  end function fmt_g

  !> Round a 17-char digit string (value d.ddd... x 10^exp10) to 6
  !! significant digits in place; exp10 adjusted on carry.
  subroutine round_digits(digs, exp10)
    character(len=17), intent(inout) :: digs
    integer, intent(inout) :: exp10
    integer :: k, carry
    logical :: up
    up = .false.
    if (digs(7:7) > "5") then
      up = .true.
    else if (digs(7:7) == "5") then
      if (verify(digs(8:17), "0") /= 0) then
        up = .true.
      else if (mod(iachar(digs(6:6)) - iachar("0"), 2) == 1) then
        up = .true.  ! exact tie: round half to even
      end if
    end if
    digs(7:17) = "00000000000"
    if (up) then
      carry = 1
      do k = 6, 1, -1
        if (carry == 0) exit
        if (digs(k:k) == "9") then
          digs(k:k) = "0"
        else
          digs(k:k) = achar(iachar(digs(k:k)) + 1)
          carry = 0
        end if
      end do
      if (carry == 1) then
        digs(1:6) = "100000"
        exp10 = exp10 + 1
      end if
    end if
  end subroutine round_digits

  !> Python float(text) attempt: ok=.false. when ValueError.
  !! Underscores between digits are accepted, as in Python.
  subroutine parse_py_float(text, val, ok)
    character(*), intent(in) :: text
    real(real64), intent(out) :: val
    logical, intent(out) :: ok
    character(:), allocatable :: t, u, low
    type(str_builder) :: sb
    integer :: k, ios
    val = 0.0_real64
    ok = .false.
    t = strip_ws(text)
    ! Remove "_" separators that sit between digits (Python rule,
    ! approximated: between two digits).
    call sb_init(sb)
    do k = 1, len(t)
      if (t(k:k) == "_" .and. k > 1 .and. k < len(t)) then
        if (is_digit(t(k - 1:k - 1)) .and. is_digit(t(k + 1:k + 1))) &
          cycle
      end if
      call sb_add(sb, t(k:k))
    end do
    u = sb_text(sb)
    t = u
    low = to_lower(t)
    if (low == "inf" .or. low == "+inf" .or. low == "infinity" .or. &
        low == "+infinity") then
      val = transfer(int(z'7FF0000000000000', int64), val)
      ok = .true.
      return
    end if
    if (low == "-inf" .or. low == "-infinity") then
      val = transfer(int(z'FFF0000000000000', int64), val)
      ok = .true.
      return
    end if
    if (low == "nan" .or. low == "+nan" .or. low == "-nan") then
      val = transfer(int(z'7FF8000000000000', int64), val)
      ok = .true.
      return
    end if
    if (.not. float_syntax_ok(t)) return
    read(t, *, iostat=ios) val
    ok = ios == 0
  end subroutine parse_py_float

  pure logical function is_digit(ch)
    character, intent(in) :: ch
    is_digit = ch >= "0" .and. ch <= "9"
  end function is_digit

  !> Grammar check mirroring float(): [+-] (d[.d*] | .d) [eE[+-]d].
  pure logical function float_syntax_ok(t) result(ok)
    character(*), intent(in) :: t
    integer :: k, n, ndig
    ok = .false.
    n = len(t)
    k = 1
    if (k <= n) then
      if (t(k:k) == "+" .or. t(k:k) == "-") k = k + 1
    end if
    ndig = 0
    do while (k <= n)
      if (.not. is_digit(t(k:k))) exit
      k = k + 1
      ndig = ndig + 1
    end do
    if (k <= n) then
      if (t(k:k) == ".") then
        k = k + 1
        do while (k <= n)
          if (.not. is_digit(t(k:k))) exit
          k = k + 1
          ndig = ndig + 1
        end do
      end if
    end if
    if (ndig == 0) return
    if (k <= n) then
      if (t(k:k) == "e" .or. t(k:k) == "E") then
        k = k + 1
        if (k <= n) then
          if (t(k:k) == "+" .or. t(k:k) == "-") k = k + 1
        end if
        ndig = 0
        do while (k <= n)
          if (.not. is_digit(t(k:k))) exit
          k = k + 1
          ndig = ndig + 1
        end do
        if (ndig == 0) return
      end if
    end if
    ok = k > n
  end function float_syntax_ok

  ! ================================================================
  ! Python helpers: _material_of / _as_number / _clean_texture
  ! ================================================================

  !> _material_of(props): normalised material name, or found=.false.
  subroutine material_of(props, text, found)
    type(dyn), intent(in) :: props
    character(:), allocatable, intent(out) :: text
    logical, intent(out) :: found
    type(dyn) :: raw
    text = ""
    found = .false.
    if (props%kind /= DYN_K_DICT) return
    raw = dyn_dict_get(props, "material")
    if (raw%kind == DYN_K_NULL) return
    text = to_lower(strip_ws(strip_chars(strip_ws(py_str(raw)), &
                                         "\""'")))
    found = len(text) > 0
  end subroutine material_of

  !> _as_number(value): bool passes through (is_number stays false,
  !! mirroring Python's explicit bool exclusion at the call sites);
  !! int/real become real; a str is float()-converted when possible
  !! and passes through unchanged otherwise; anything else passes
  !! through unchanged.
  subroutine as_number(value, res, is_number, num)
    type(dyn), intent(in) :: value
    type(dyn), intent(out) :: res
    logical, intent(out) :: is_number
    real(real64), intent(out) :: num
    real(real64) :: parsed
    logical :: ok
    is_number = .false.
    num = 0.0_real64
    select case (value%kind)
    case (DYN_K_BOOL)
      res = dyn_copy(value)
    case (DYN_K_INT)
      num = real(value%i, real64)
      res = dyn_real(num)
      is_number = .true.
    case (DYN_K_REAL)
      num = value%r
      res = dyn_real(num)
      is_number = .true.
    case (DYN_K_STR)
      if (allocated(value%s)) then
        call parse_py_float(value%s, parsed, ok)
      else
        ok = .false.
        parsed = 0.0_real64
      end if
      if (ok) then
        num = parsed
        res = dyn_real(num)
        is_number = .true.
      else
        res = dyn_copy(value)
      end if
    case default
      res = dyn_copy(value)
    end select
  end subroutine as_number

  !> _clean_texture(value): texture path with quotes stripped, or
  !! dyn_null when the input is None.
  function clean_texture(value) result(out)
    type(dyn), intent(in) :: value
    type(dyn) :: out
    character(:), allocatable :: text
    type(dyn) :: inner
    integer :: k
    character(len=4), parameter :: attrs(4) = &
      [character(len=4) :: "value", "text", "path", "name"]
    if (value%kind == DYN_K_NULL) then
      out = dyn_null()
      return
    end if
    if (value%kind == DYN_K_STR) then
      if (allocated(value%s)) then
        text = value%s
      else
        text = ""
      end if
    else if (value%kind == DYN_K_DICT) then
      ! Duck-typed payload: first str among value/text/path/name.
      text = ""
      do k = 1, 4
        inner = dyn_dict_get(value, trim(attrs(k)))
        if (inner%kind == DYN_K_STR) then
          if (allocated(inner%s)) text = inner%s
          exit
        end if
      end do
      if (k > 4) text = py_str(value)
    else
      text = py_str(value)
    end if
    text = strip_ws(text)
    if (len(text) >= 2) then
      if (text(1:1) == text(len(text):len(text)) .and. &
          (text(1:1) == '"' .or. text(1:1) == "'")) then
        if (len(text) == 2) then
          text = ""
        else
          text = strip_ws(text(2:len(text) - 1))
        end if
      end if
    end if
    out = dyn_str(text)
  end function clean_texture

  !> Index of key in MAT_NUMERIC_KEYS (0 when absent).
  pure integer function numeric_key_index(key) result(idx)
    character(*), intent(in) :: key
    integer :: k
    idx = 0
    do k = 1, 4
      if (key == trim(MAT_NUMERIC_KEYS(k))) then
        idx = k
        return
      end if
    end do
  end function numeric_key_index

  !> _RELEVANT lookup: is numeric key idx relevant for material?
  pure logical function is_relevant(material, idx) result(rel)
    character(*), intent(in) :: material
    integer, intent(in) :: idx
    rel = .false.
    if (material == "standard") then
      rel = idx == 1 .or. idx == 2
    else if (material == "phong") then
      rel = idx == 3 .or. idx == 4
    end if
  end function is_relevant

  ! ================================================================
  ! extract_material_ext
  ! ================================================================

  !> extract_material_ext(props) -> dict with keys metalness,
  !! roughness, specular, shininess (in that order) and texture.
  !! Defaults are filled only for keys relevant to the declared
  !! material; a present key keeps its float-converted value;
  !! irrelevant absent keys are null.  props is never mutated.
  function extract_material_ext(props_in) result(ext)
    type(dyn), intent(in) :: props_in
    type(dyn) :: ext
    type(dyn) :: props, v, conv
    character(:), allocatable :: material
    logical :: has_mat, is_num
    real(real64) :: num
    integer :: k
    character(len=9) :: key
    if (props_in%kind == DYN_K_DICT) then
      props = dyn_copy(props_in)
    else
      props = dyn_dict()
    end if
    call material_of(props, material, has_mat)
    if (.not. has_mat) material = ""
    ext = dyn_dict()
    do k = 1, 4
      key = MAT_NUMERIC_KEYS(k)
      v = dyn_dict_get(props, trim(key))
      if (dyn_dict_has(props, trim(key)) .and. &
          v%kind /= DYN_K_NULL) then
        call as_number(v, conv, is_num, num)
        call dyn_dict_set(ext, trim(key), conv)
      else if (is_relevant(material, k)) then
        call dyn_dict_set(ext, trim(key), dyn_real(MAT_DEFAULTS(k)))
      else
        call dyn_dict_set(ext, trim(key), dyn_null())
      end if
    end do
    call dyn_dict_set(ext, "texture", &
                      clean_texture(dyn_dict_get(props, "texture")))
    ! v3.0 Phase 4 (additive): the four extra texture slots ride
    ! the same clean_texture path as "texture", and every new key
    ! is present-only (no defaults filled, no null entries), so
    ! an ext dict built from a pre-Phase-4 source is byte-for-
    ! byte the old dict -- in the .scene AND the JSON alike.
    do k = 1, 4
      if (dyn_dict_has(props, trim(MAT_SLOT_KEYS(k)))) &
        call dyn_dict_set(ext, trim(MAT_SLOT_KEYS(k)), &
                          clean_texture(dyn_dict_get(props, &
                                                     trim(MAT_SLOT_KEYS(k)))))
    end do
    v = dyn_dict_get(props, "emissive")
    if (v%kind /= DYN_K_NULL) then
      block
        type(dyn) :: resolved
        real(real64) :: rgb(3)
        logical :: has_rgb
        call emissive_of(v, rgb, has_rgb)
        if (has_rgb) then
          resolved = dyn_list()
          do k = 1, 3
            call dyn_list_push(resolved, dyn_real(rgb(k)))
          end do
          call dyn_dict_set(ext, "emissive", resolved)
        else
          ! Unresolvable: keep the raw value so
          ! validate_material_ext can quote it in its message.
          call dyn_dict_set(ext, "emissive", dyn_copy(v))
        end if
      end block
    end if
    v = dyn_dict_get(props, "opacity")
    if (v%kind /= DYN_K_NULL) then
      call as_number(v, conv, is_num, num)
      call dyn_dict_set(ext, "opacity", conv)
    end if
    v = dyn_dict_get(props, "cutoff")
    if (v%kind /= DYN_K_NULL) then
      call as_number(v, conv, is_num, num)
      call dyn_dict_set(ext, "cutoff", conv)
    end if
    v = dyn_dict_get(props, "alpha")
    if (v%kind == DYN_K_STR) then
      if (allocated(v%s)) then
        call dyn_dict_set(ext, "alpha", &
                          dyn_str(to_lower(strip_ws(v%s))))
      else
        call dyn_dict_set(ext, "alpha", dyn_str(""))
      end if
    else if (v%kind /= DYN_K_NULL) then
      call dyn_dict_set(ext, "alpha", dyn_copy(v))
    end if
  end function extract_material_ext

  !> Resolve an `emissive` colour value to 0..1 floats.  Accepted
  !! shapes (the compiler's colour conventions, as produced by the
  !! parser's lp_colour): a 3-number list (0..255 ints, or 0..1
  !! floats when every component is <= 1), a colour-name string
  !! from the frozen NAMED_COLORS table, or a "#rrggbb" string.
  !! has_rgb=.false. when the value is none of those.
  subroutine emissive_of(value, rgb, has_rgb)
    type(dyn), intent(in) :: value
    real(real64), intent(out) :: rgb(3)
    logical, intent(out) :: has_rgb
    type(dyn) :: comp, conv
    logical :: is_num
    real(real64) :: num
    integer :: k, ints(3)
    character(:), allocatable :: t, low
    rgb = 0.0_real64
    has_rgb = .false.
    if (value%kind == DYN_K_LIST) then
      if (dyn_list_len(value) < 3) return
      do k = 1, 3
        comp = dyn_list_at(value, k)
        call as_number(comp, conv, is_num, num)
        if (.not. is_num) return
        rgb(k) = num
      end do
      if (any(rgb < 0.0_real64)) return
      if (any(rgb > 1.0_real64)) rgb = rgb / 255.0_real64
      if (any(rgb > 1.0_real64)) return
      has_rgb = .true.
      return
    end if
    if (value%kind /= DYN_K_STR) return
    if (allocated(value%s)) then
      t = strip_ws(value%s)
    else
      t = ""
    end if
    low = to_lower(t)
    do k = 1, MAT_N_NAMED
      if (low == trim(MAT_NAMED_KEYS(k))) then
        ints = MAT_NAMED_RGB(:, k)
        rgb = real(ints, real64) / 255.0_real64
        has_rgb = .true.
        return
      end if
    end do
    if (len(t) == 7 .and. t(1:1) == "#") then
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
            ints(k) = (index("0123456789abcdef", &
                             low(2 * k:2 * k)) - 1) * 16 &
                      + (index("0123456789abcdef", &
                               low(2 * k + 1:2 * k + 1)) - 1)
          end do
          rgb = real(ints, real64) / 255.0_real64
          has_rgb = .true.
        end if
      end block
    end if
  end subroutine emissive_of

  ! ================================================================
  ! validate_material_ext
  ! ================================================================

  !> os.path.splitext(path)[1] (POSIX rules).
  function splitext_suffix(path) result(out)
    character(*), intent(in) :: path
    character(:), allocatable :: out
    integer :: slash, dot, k
    logical :: all_dots
    out = ""
    slash = 0
    do k = 1, len(path)
      if (path(k:k) == "/") slash = k
    end do
    dot = 0
    do k = slash + 1, len(path)
      if (path(k:k) == ".") dot = k
    end do
    if (dot == 0) return
    ! Leading dots of the basename do not start an extension.
    all_dots = .true.
    do k = slash + 1, dot - 1
      if (path(k:k) /= ".") all_dots = .false.
    end do
    if (all_dots) return
    out = path(dot:len(path))
  end function splitext_suffix

  !> validate_material_ext(material, ext) -> list of error strings
  !! (appended to the errors char_list).  `material` is unused by
  !! the Python original and kept only for signature parity.
  subroutine validate_material_ext(material, ext, errors)
    character(*), intent(in) :: material
    type(dyn), intent(in) :: ext
    type(char_list), intent(inout) :: errors
    type(dyn) :: v, conv, texture
    logical :: is_num
    real(real64) :: num, low, high
    integer :: k
    character(len=9) :: key
    character(:), allocatable :: msg, suffix, tex_text
    if (len(material) < 0) continue  ! unused, as in Python
    if (ext%kind /= DYN_K_DICT) return
    do k = 1, 4
      key = MAT_NUMERIC_KEYS(k)
      if (.not. dyn_dict_has(ext, trim(key))) cycle
      v = dyn_dict_get(ext, trim(key))
      if (v%kind == DYN_K_NULL) cycle
      low = MAT_RANGES_LO(k)
      high = MAT_RANGES_HI(k)
      call as_number(v, conv, is_num, num)
      if (.not. is_num) then
        msg = trim(key) // " " // py_repr(v) // &
              " is not a number: " // trim(key) // &
              " must be in the range " // fmt_g(low) // ".." // &
              fmt_g(high)
        call char_list_append(errors, msg)
      else if (.not. (low <= num .and. num <= high)) then
        msg = trim(key) // " " // fmt_g(num) // &
              " is out of range: " // trim(key) // &
              " must be in the range " // fmt_g(low) // ".." // &
              fmt_g(high)
        call char_list_append(errors, msg)
      end if
    end do
    texture = dyn_dict_get(ext, "texture")
    if (texture%kind /= DYN_K_NULL) then
      if (texture%kind /= DYN_K_STR) then
        call char_list_append(errors, &
          "texture path is empty: texture must name a .ppm or .png file " // &
          "(only .ppm and .png textures are supported)")
      else
        if (allocated(texture%s)) then
          tex_text = texture%s
        else
          tex_text = ""
        end if
        if (len(strip_ws(tex_text)) == 0) then
          call char_list_append(errors, &
            "texture path is empty: texture must name a .ppm or .png file " // &
            "(only .ppm and .png textures are supported)")
        else
          suffix = to_lower(splitext_suffix(strip_ws(tex_text)))
          if (suffix /= ".ppm" .and. suffix /= ".png") then
            if (len(suffix) == 0) suffix = "(none)"
            msg = "texture " // py_repr(texture) // &
                  " has unsupported extension " // &
                  repr_str(suffix) // &
                  ": only .ppm or .png textures are supported"
            call char_list_append(errors, msg)
          end if
        end if
      end if
    end if
    ! v3.0 Phase 4: extra texture slots (same .ppm rule and message
    ! shape as "texture" above, keyed by slot name).
    do k = 1, 4
      texture = dyn_dict_get(ext, trim(MAT_SLOT_KEYS(k)))
      call validate_tex_slot(errors, trim(MAT_SLOT_KEYS(k)), texture)
    end do
    ! v3.0 Phase 4: emissive must have resolved to a 3-number list
    ! in extract_material_ext; anything else kept raw is an error.
    v = dyn_dict_get(ext, "emissive")
    if (v%kind /= DYN_K_NULL) then
      block
        real(real64) :: rgb(3)
        logical :: has_rgb
        call emissive_of(v, rgb, has_rgb)
        if (.not. has_rgb) then
          msg = "emissive " // py_repr(v) // &
                " is not a colour: emissive must be a colour " // &
                "(a name, #rrggbb or rgb r g b)"
          call char_list_append(errors, msg)
        end if
      end block
    end if
    ! v3.0 Phase 4: opacity / cutoff are numbers in 0..1 (same
    ! message shape as the numeric keys above).
    do k = 1, 2
      if (k == 1) then
        key = "opacity"
      else
        key = "cutoff"
      end if
      if (.not. dyn_dict_has(ext, trim(key))) cycle
      v = dyn_dict_get(ext, trim(key))
      if (v%kind == DYN_K_NULL) cycle
      call as_number(v, conv, is_num, num)
      if (.not. is_num) then
        msg = trim(key) // " " // py_repr(v) // &
              " is not a number: " // trim(key) // &
              " must be in the range 0..1"
        call char_list_append(errors, msg)
      else if (.not. (0.0_real64 <= num .and. num <= 1.0_real64)) &
        then
        msg = trim(key) // " " // fmt_g(num) // &
              " is out of range: " // trim(key) // &
              " must be in the range 0..1"
        call char_list_append(errors, msg)
      end if
    end do
    ! v3.0 Phase 4: alpha mode word.
    v = dyn_dict_get(ext, "alpha")
    if (v%kind /= DYN_K_NULL) then
      block
        character(:), allocatable :: amode
        amode = ""
        if (v%kind == DYN_K_STR .and. allocated(v%s)) &
          amode = to_lower(strip_ws(v%s))
        if (.not. (amode == "opaque" .or. amode == "mask" .or. &
                   amode == "blend")) then
          msg = "alpha " // py_repr(v) // &
                " is not a mode: alpha must be opaque, mask " // &
                "or blend"
          call char_list_append(errors, msg)
        end if
      end block
    end if
  end subroutine validate_material_ext

  !> The .ppm texture check of validate_material_ext, keyed by an
  !! arbitrary slot name ("texture" messages above are the base
  !! slot's own inline copy; these are the Phase 4 slots).
  subroutine validate_tex_slot(errors, key, texture)
    type(char_list), intent(inout) :: errors
    character(*), intent(in) :: key
    type(dyn), intent(in) :: texture
    character(:), allocatable :: msg, suffix, tex_text
    if (texture%kind == DYN_K_NULL) return
    if (texture%kind /= DYN_K_STR) then
      call char_list_append(errors, &
        key // " texture path is empty: " // key // &
        " texture must name a .ppm or .png file " // &
        "(only .ppm and .png textures are supported)")
      return
    end if
    if (allocated(texture%s)) then
      tex_text = texture%s
    else
      tex_text = ""
    end if
    if (len(strip_ws(tex_text)) == 0) then
      call char_list_append(errors, &
        key // " texture path is empty: " // key // &
        " texture must name a .ppm or .png file " // &
        "(only .ppm and .png textures are supported)")
      return
    end if
    suffix = to_lower(splitext_suffix(strip_ws(tex_text)))
    if (suffix /= ".ppm" .and. suffix /= ".png") then
      if (len(suffix) == 0) suffix = "(none)"
      msg = key // " texture " // py_repr(texture) // &
            " has unsupported extension " // &
            repr_str(suffix) // &
            ": only .ppm or .png textures are supported"
      call char_list_append(errors, msg)
    end if
  end subroutine validate_tex_slot

  ! ================================================================
  ! objmat_line
  ! ================================================================

  !> _value_or_default(ext, key)
  function value_or_default(ext, key) result(out)
    type(dyn), intent(in) :: ext
    character(*), intent(in) :: key
    type(dyn) :: out
    integer :: idx
    out = dyn_dict_get(ext, key)
    if (out%kind == DYN_K_NULL) then
      idx = numeric_key_index(key)
      if (idx > 0) out = dyn_real(MAT_DEFAULTS(idx))
    end if
  end function value_or_default

  !> _fmt(value, key): "%g" of the number, DEFAULTS on non-numbers.
  function fmt_field(value, key) result(out)
    type(dyn), intent(in) :: value
    character(*), intent(in) :: key
    character(:), allocatable :: out
    type(dyn) :: conv
    logical :: is_num
    real(real64) :: num
    integer :: idx
    call as_number(value, conv, is_num, num)
    if (.not. is_num) then
      idx = numeric_key_index(key)
      num = MAT_DEFAULTS(idx)
    end if
    out = fmt_g(num)
  end function fmt_field

  !> _is_non_default(ext, key)
  logical function is_non_default(ext, key) result(res)
    type(dyn), intent(in) :: ext
    character(*), intent(in) :: key
    type(dyn) :: v, conv
    logical :: is_num
    real(real64) :: num
    integer :: idx
    v = dyn_dict_get(ext, key)
    if (v%kind == DYN_K_NULL) then
      res = .false.
      return
    end if
    call as_number(v, conv, is_num, num)
    if (.not. is_num) then
      res = .true.
      return
    end if
    idx = numeric_key_index(key)
    res = num /= MAT_DEFAULTS(idx)
  end function is_non_default

  !> objmat_line(name, material, ext) -> line, or found=.false.
  !! (Python's None).  Line shape:
  !!   objmat <name> <material> <metalness> <roughness> <specular>
  !!          <shininess> <texture-or-dash>
  subroutine objmat_line(name, material, ext_in, line, found)
    character(*), intent(in) :: name, material
    type(dyn), intent(in) :: ext_in
    character(:), allocatable, intent(out) :: line
    logical, intent(out) :: found
    type(dyn) :: ext, texture
    character(:), allocatable :: material_text, tex_text
    logical :: has_tex
    if (ext_in%kind == DYN_K_DICT) then
      ext = dyn_copy(ext_in)
    else
      ext = dyn_dict()
    end if
    if (len(material) == 0) then
      material_text = "lambert"
    else
      material_text = to_lower(strip_ws(material))
    end if
    texture = dyn_dict_get(ext, "texture")
    has_tex = .false.
    tex_text = ""
    if (texture%kind == DYN_K_STR) then
      if (allocated(texture%s)) tex_text = strip_ws(texture%s)
      has_tex = len(tex_text) > 0
      if (.not. has_tex) tex_text = ""
    else if (texture%kind /= DYN_K_NULL) then
      tex_text = py_str(texture)
      has_tex = .true.
    end if
    found = material_text == "standard" .or. has_tex .or. &
            is_non_default(ext, "specular") .or. &
            is_non_default(ext, "shininess")
    if (.not. found) then
      line = ""
      return
    end if
    if (.not. has_tex) tex_text = "-"
    line = "objmat " // name // " " // material_text // " " // &
      fmt_field(value_or_default(ext, "metalness"), "metalness") // &
      " " // &
      fmt_field(value_or_default(ext, "roughness"), "roughness") // &
      " " // &
      fmt_field(value_or_default(ext, "specular"), "specular") // &
      " " // &
      fmt_field(value_or_default(ext, "shininess"), "shininess") // &
      " " // tex_text
  end subroutine objmat_line

  ! ================================================================
  ! material_extra_lines (v3.0 Phase 4)
  ! ================================================================

  !> The .scene SLOT word for texture-slot prop key idx.
  pure function slot_line_name(idx) result(out)
    integer, intent(in) :: idx
    character(len=9) :: out
    select case (idx)
    case (1)
      out = "normal"
    case (2)
      out = "mr"
    case (3)
      out = "emissive"
    case default
      out = "occlusion"
    end select
  end function slot_line_name

  !> material_extra_lines(name, ext) -> the v3.0 Phase 4 .scene
  !! lines for one object, appended to `lines`:
  !!   objtex NAME SLOT PATH        (per non-empty texture slot)
  !!   objemissive NAME R G B       (emissive present; %g floats)
  !!   objalpha NAME MODE CUTOFF OPACITY
  !!     (any of alpha/opacity/cutoff present; missing pieces take
  !!      the MaterialPBR defaults: mode 0, cutoff 0.5, opacity 1)
  !! Nothing is appended when the source used none of the new
  !! keys -- the antialias precedent: zero artifact drift for
  !! pre-Phase-4 sources.
  subroutine material_extra_lines(name, ext_in, lines)
    character(*), intent(in) :: name
    type(dyn), intent(in) :: ext_in
    type(char_list), intent(inout) :: lines
    type(dyn) :: ext, v, comp, conv
    character(:), allocatable :: tex_text, amode
    logical :: is_num
    real(real64) :: num, rgb(3), cutoff, opacity
    integer :: k, mode
    if (ext_in%kind == DYN_K_DICT) then
      ext = dyn_copy(ext_in)
    else
      return
    end if
    do k = 1, 4
      v = dyn_dict_get(ext, trim(MAT_SLOT_KEYS(k)))
      if (v%kind /= DYN_K_STR) cycle
      if (allocated(v%s)) then
        tex_text = strip_ws(v%s)
      else
        tex_text = ""
      end if
      if (len(tex_text) == 0) cycle
      call char_list_append(lines, &
        "objtex " // name // " " // trim(slot_line_name(k)) // &
        " " // tex_text)
    end do
    v = dyn_dict_get(ext, "emissive")
    if (v%kind == DYN_K_LIST .and. dyn_list_len(v) >= 3) then
      rgb = 0.0_real64
      do k = 1, 3
        comp = dyn_list_at(v, k)
        call as_number(comp, conv, is_num, num)
        if (is_num) rgb(k) = num
      end do
      call char_list_append(lines, &
        "objemissive " // name // " " // fmt_g(rgb(1)) // " " // &
        fmt_g(rgb(2)) // " " // fmt_g(rgb(3)))
    end if
    if (dyn_dict_has(ext, "alpha") .or. &
        dyn_dict_has(ext, "opacity") .or. &
        dyn_dict_has(ext, "cutoff")) then
      mode = 0
      v = dyn_dict_get(ext, "alpha")
      if (v%kind == DYN_K_STR .and. allocated(v%s)) then
        amode = to_lower(strip_ws(v%s))
        if (amode == "mask") mode = 1
        if (amode == "blend") mode = 2
      end if
      cutoff = 0.5_real64
      v = dyn_dict_get(ext, "cutoff")
      if (v%kind /= DYN_K_NULL) then
        call as_number(v, conv, is_num, num)
        if (is_num) cutoff = num
      end if
      opacity = 1.0_real64
      v = dyn_dict_get(ext, "opacity")
      if (v%kind /= DYN_K_NULL) then
        call as_number(v, conv, is_num, num)
        if (is_num) opacity = num
      end if
      call char_list_append(lines, &
        "objalpha " // name // " " // &
        trim(fmt_int(int(mode, int64))) // " " // fmt_g(cutoff) // &
        " " // fmt_g(opacity))
    end if
  end subroutine material_extra_lines

  ! ================================================================
  ! apply_to_ir_object
  ! ================================================================

  !> apply_to_ir_object(obj): attach extensions["material"] to one
  !! IR object (a dyn dict) in place, when anything Wave A is
  !! relevant.  Raw props come from extensions["raw_props"] when
  !! that is a dict; the object's own top-level keys "material",
  !! "metalness", "roughness", "specular", "shininess" and
  !! "texture" are honoured as the Python getattr fallbacks.
  !! A plain lambert object with nothing set is a strict no-op.
  subroutine apply_to_ir_object(obj)
    type(dyn), intent(inout) :: obj
    type(dyn) :: extensions, raw_props, props, v
    logical :: has_ext, relevant
    character(:), allocatable :: material_text
    logical :: has_mat
    integer :: k
    character(len=9) :: key
    if (obj%kind /= DYN_K_DICT) return
    extensions = dyn_dict_get(obj, "extensions")
    has_ext = extensions%kind == DYN_K_DICT
    if (.not. has_ext) extensions = dyn_dict()
    props = dyn_dict()
    if (has_ext) then
      raw_props = dyn_dict_get(extensions, "raw_props")
      if (raw_props%kind == DYN_K_DICT) then
        do k = 1, dyn_dict_len(raw_props)
          call dyn_dict_set(props, dyn_dict_key_at(raw_props, k), &
                            dyn_dict_value_at(raw_props, k))
        end do
      end if
    end if
    v = dyn_dict_get(props, "material")
    if (v%kind == DYN_K_NULL) then
      v = dyn_dict_get(obj, "material")
      if (v%kind /= DYN_K_NULL) &
        call dyn_dict_set(props, "material", v)
    end if
    do k = 1, 4
      key = MAT_NUMERIC_KEYS(k)
      v = dyn_dict_get(props, trim(key))
      if (v%kind == DYN_K_NULL) then
        v = dyn_dict_get(obj, trim(key))
        if (v%kind /= DYN_K_NULL) &
          call dyn_dict_set(props, trim(key), v)
      end if
    end do
    v = dyn_dict_get(props, "texture")
    if (v%kind == DYN_K_NULL) then
      v = dyn_dict_get(obj, "texture")
      if (v%kind /= DYN_K_NULL) &
        call dyn_dict_set(props, "texture", v)
    end if
    ! v3.0 Phase 4: the same top-level fallbacks for the new keys.
    block
      character(len=12) :: p4keys(8)
      integer :: pk
      p4keys = [character(len=12) :: "normalmap", "mr", &
                "emissivemap", "occlusionmap", "emissive", &
                "opacity", "alpha", "cutoff"]
      do pk = 1, 8
        v = dyn_dict_get(props, trim(p4keys(pk)))
        if (v%kind == DYN_K_NULL) then
          v = dyn_dict_get(obj, trim(p4keys(pk)))
          if (v%kind /= DYN_K_NULL) &
            call dyn_dict_set(props, trim(p4keys(pk)), v)
        end if
      end do
    end block
    call material_of(props, material_text, has_mat)
    if (.not. has_mat) material_text = ""
    v = dyn_dict_get(props, "texture")
    relevant = material_text == "standard" .or. &
               v%kind /= DYN_K_NULL
    if (.not. relevant) then
      do k = 1, 4
        v = dyn_dict_get(props, trim(MAT_NUMERIC_KEYS(k)))
        if (v%kind /= DYN_K_NULL) relevant = .true.
      end do
    end if
    if (.not. relevant) then
      ! v3.0 Phase 4: any new key alone also makes the extension
      ! relevant (e.g. a lambert object with only a normal map).
      block
        character(len=12) :: p4keys(8)
        integer :: pk
        p4keys = [character(len=12) :: "normalmap", "mr", &
                  "emissivemap", "occlusionmap", "emissive", &
                  "opacity", "alpha", "cutoff"]
        do pk = 1, 8
          v = dyn_dict_get(props, trim(p4keys(pk)))
          if (v%kind /= DYN_K_NULL) relevant = .true.
        end do
      end block
    end if
    if (.not. relevant) return
    call dyn_dict_set(extensions, "material", &
                      extract_material_ext(props))
    call dyn_dict_set(obj, "extensions", extensions)
  end subroutine apply_to_ir_object

end module f3dc_ext_materials
