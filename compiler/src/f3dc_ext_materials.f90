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
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real, to_lower, char_list, &
                      char_list_append
  implicit none
  private

  public :: extract_material_ext, validate_material_ext, objmat_line
  public :: apply_to_ir_object
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
  ! _TEXTURE_EXTS = (".ppm",)

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
      acc = "["
      do k = 1, dyn_list_len(v)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr(dyn_list_at(v, k))
      end do
      out = acc // "]"
    case (DYN_K_DICT)
      acc = "{"
      do k = 1, dyn_dict_len(v)
        if (k > 1) acc = acc // ", "
        acc = acc // py_repr(dyn_str(dyn_dict_key_at(v, k))) // &
              ": " // py_repr(dyn_dict_value_at(v, k))
      end do
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
    character :: q
    integer :: k, code
    character(len=2) :: hexd
    if (index(s, "'") > 0 .and. index(s, '"') == 0) then
      q = '"'
    else
      q = "'"
    end if
    body = ""
    do k = 1, len(s)
      code = iachar(s(k:k))
      if (s(k:k) == "\") then
        body = body // "\\"
      else if (s(k:k) == q) then
        body = body // "\" // q
      else if (code == 10) then
        body = body // "\n"
      else if (code == 13) then
        body = body // "\r"
      else if (code == 9) then
        body = body // "\t"
      else if (code < 32 .or. code == 127) then
        write(hexd, "(Z2.2)") code
        body = body // "\x" // to_lower(hexd)
      else
        body = body // s(k:k)
      end if
    end do
    out = q // body // q
  end function repr_str

  !> Python "%g" % x  (C printf %g, precision 6).
  function fmt_g(x) result(out)
    real(real64), intent(in) :: x
    character(:), allocatable :: out
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
      out = digs(1:1)
      if (last > 1) out = out // "." // digs(2:last)
      out = out // "e"
      if (exp10 < 0) then
        out = out // "-"
      else
        out = out // "+"
      end if
      if (abs(exp10) < 10) out = out // "0"
      out = out // trim(adjustl(fmt_int(int(abs(exp10), int64))))
    else if (exp10 >= 0) then
      ! Fixed, integer part has exp10+1 digits.
      if (exp10 + 1 >= 6) then
        out = digs(1:6)
        do k = 1, exp10 + 1 - 6
          out = out // "0"
        end do
      else
        out = digs(1:exp10 + 1)
        if (last > exp10 + 1) out = out // "." // digs(exp10 + 2:last)
      end if
    else
      ! Fixed, 0.000ddd form.
      out = "0."
      do k = 1, -exp10 - 1
        out = out // "0"
      end do
      out = out // digs(1:last)
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
    integer :: k, ios
    val = 0.0_real64
    ok = .false.
    t = strip_ws(text)
    ! Remove "_" separators that sit between digits (Python rule,
    ! approximated: between two digits).
    u = ""
    do k = 1, len(t)
      if (t(k:k) == "_" .and. k > 1 .and. k < len(t)) then
        if (is_digit(t(k - 1:k - 1)) .and. is_digit(t(k + 1:k + 1))) &
          cycle
      end if
      u = u // t(k:k)
    end do
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
  end function extract_material_ext

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
          "texture path is empty: texture must name a .ppm file " // &
          "(only .ppm textures are supported in Wave A)")
      else
        if (allocated(texture%s)) then
          tex_text = texture%s
        else
          tex_text = ""
        end if
        if (len(strip_ws(tex_text)) == 0) then
          call char_list_append(errors, &
            "texture path is empty: texture must name a .ppm file " // &
            "(only .ppm textures are supported in Wave A)")
        else
          suffix = to_lower(splitext_suffix(strip_ws(tex_text)))
          if (suffix /= ".ppm") then
            if (len(suffix) == 0) suffix = "(none)"
            msg = "texture " // py_repr(texture) // &
                  " has unsupported extension " // &
                  repr_str(suffix) // &
                  ": only .ppm textures are supported in Wave A"
            call char_list_append(errors, msg)
          end if
        end if
      end if
    end if
  end subroutine validate_material_ext

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
    if (.not. relevant) return
    call dyn_dict_set(extensions, "material", &
                      extract_material_ext(props))
    call dyn_dict_set(obj, "extensions", extensions)
  end subroutine apply_to_ir_object

end module f3dc_ext_materials
