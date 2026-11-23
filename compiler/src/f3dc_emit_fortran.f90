! f3dc_emit_fortran.f90 -- Forge3D Fortran back ends.
!
! Port of tools/f3dc/emit_fortran.py (read in full; 1,055 lines).
! Two outputs from the frozen Typed IR (dyn dicts, f3dc_dyn):
!
!   emit_scene_text(ir, text)      -- the .scene text format parsed by
!                                     src/scene.f90 (cli.py _scene_text
!                                     calls exactly this).
!   emit_fortran_program(ir, text) -- the standalone <stem>_scene.f90
!                                     program (static frame 0 only).
!   emit_scene / emit_fortran      -- the Python aliases.
!
! Free subroutines only (no type-bound procedures), per the port rules.
!
! Number formatting: emit_fortran.py formats through
! emit_common.fmt_num (ints plainly, integral reals without ".0",
! other reals via repr trimmed).  f3dc_str's fmt_real is Python
! repr(float); fmt_num is layered on top of it here (the
! f3dc_emit_common seat has not landed, so fmt_num / header_stamp /
! source_hash are implemented privately in this module -- canonical
! JSON + SHA-256 included -- and can be re-pointed at f3dc_emit_common
! when it lands without changing any output byte).
!
! EXT HOOK POINTS: emit_fortran.py delegates whole line families to
! the ext_*.py modules (ports: f3dc_ext_* seats, not yet landed).
! Each delegation site below calls a clearly marked hook subroutine
! that currently produces NO output -- the same result Python gives
! when the ext import fails (every call site is try/except-guarded
! in Python).  Scenes using those features therefore diverge from
! the Python oracle until the ext seats land; core scenes are
! byte-identical.  Hook sites:
!   * point/spot light lines        (ext_lights_env.light_line)
!   * scene environment lines       (ext_lights_env.env_lines)
!   * per-object material lines     (ext_materials.objmat_line)
!   * sprite / text lines           (ext_sprites_text)
!   * particle lines                (ext_particles.particles_line)
!   * keyframe track lines          (ext_keys.track_lines)
!   * ortho camera lines            (ext_cameras.camera_lines)
!   * post chain lines              (ext_post.post_lines)
!   * shader defs + bindings        (ext_shader)
!   * morph / bone / skin lines     (ext_skin.scene_lines)
! ext_geometry.scene_extra_values is a 10-line flatten and is
! INLINED at its call site (ext_scene_extra_values below).
! Wave C instance lines are inline in emit_fortran.py and are
! implemented inline here (no hook).
module f3dc_emit_fortran
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_nan, ieee_is_finite, &
                                           ieee_is_negative, &
                                           ieee_value, ieee_quiet_nan, &
                                           ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, &
                      dyn_dict_get, dyn_dict_set, dyn_dict_has, dyn_list_at, &
                      dyn_list_len, dyn_list_push, dyn_kind, &
                      dyn_dict_len, dyn_dict_key_at, &
                      dyn_dict_value_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
                      char_list_at, char_list_clear, &
                      int_list, int_list_append, int_list_at, &
                      fmt_int, fmt_real, to_lower, str_replace
  use f3dc_ext_shader, only: shader_scene_lines, shader_binding_line
  use f3dc_ext_materials, only: mat_objmat => objmat_line
  use f3dc_ext_geometry, only: eg_scene_extra => scene_extra_values
  use f3dc_ext_sprites_text, only: sprite_line, text_line
  use f3dc_ext_particles, only: particles_line
  use f3dc_ext_lights_env, only: light_line, env_lines
  use f3dc_ext_keys, only: ext_keys_track_lines => track_lines
  use f3dc_ext_skin, only: ext_skin_scene_lines => scene_lines
  use f3dc_ext_cameras, only: ext_camera_lines => camera_lines
  use f3dc_ext_post, only: ext_post_lines => post_lines
  implicit none
  private

  public :: emit_scene_text, emit_fortran_program
  public :: emit_scene, emit_fortran

  character(len=*), parameter :: NL = achar(10)
  character(len=*), parameter :: DEFAULT_OUTPUT = "output_render.ppm"

  ! One normalised raw triangle: 3 colour channels + 9 vertex dyns.
  type :: tri_list_t
    integer :: n = 0
    integer(int64), allocatable :: cols(:, :)   ! (3, n)
    type(dyn), allocatable :: pts(:)            ! 9 per tri, vertex-major
  end type tri_list_t

contains

  ! ==================================================================
  ! Python value helpers (duck-typed access over dyn dicts)
  ! ==================================================================

  !> emit_fortran._get(obj, key): value for key, dyn_null when the key
  !! is absent OR stored null (Python _get skips None values, so the
  !! two are indistinguishable at every _get call site).
  function gv(obj, key) result(val)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: key
    type(dyn) :: val
    val = dyn_dict_get(obj, key)
  end function gv

  !> _get(obj, key1, key2, ...): first non-null of the keys.
  function gv2(obj, key1, key2) result(val)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: key1, key2
    type(dyn) :: val
    val = gv(obj, key1)
    if (val%kind == DYN_K_NULL) val = gv(obj, key2)
  end function gv2

  function gv3(obj, key1, key2, key3) result(val)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: key1, key2, key3
    type(dyn) :: val
    val = gv2(obj, key1, key2)
    if (val%kind == DYN_K_NULL) val = gv(obj, key3)
  end function gv3

  !> _get(obj, key, default=dv): dv when the value is null/absent.
  function gvd(obj, key, dv) result(val)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: key
    type(dyn), intent(in) :: dv
    type(dyn) :: val
    val = gv(obj, key)
    if (val%kind == DYN_K_NULL) val = dyn_copy(dv)
  end function gvd

  !> Python str(value) for the scalar dyn kinds.
  function py_str(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    select case (v%kind)
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = v%s
      else
        out = ""
      end if
    case (DYN_K_INT)
      out = fmt_int(v%i)
    case (DYN_K_REAL)
      out = fmt_real(v%r)
    case (DYN_K_BOOL)
      if (v%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_NULL)
      out = "None"
    case default
      out = ""
    end select
  end function py_str

  !> Python truthiness.
  pure logical function py_truthy(v)
    type(dyn), intent(in) :: v
    select case (v%kind)
    case (DYN_K_NULL)
      py_truthy = .false.
    case (DYN_K_BOOL)
      py_truthy = v%b
    case (DYN_K_INT)
      py_truthy = v%i /= 0_int64
    case (DYN_K_REAL)
      py_truthy = v%r /= 0.0_real64  ! NaN /= 0 -> .true., as in Python
    case (DYN_K_STR)
      py_truthy = allocated(v%s)
      if (py_truthy) py_truthy = len(v%s) > 0
    case (DYN_K_LIST)
      py_truthy = v%n_items > 0
    case (DYN_K_DICT)
      py_truthy = v%n_entries > 0
    case default
      py_truthy = .false.
    end select
  end function py_truthy

  !> Python float(value); ok=.false. where Python raises TypeError /
  !! ValueError.  Strings: surrounding whitespace and the inf/nan
  !! words are handled; digit underscores are stripped (Python also
  !! accepts them between digits -- a superset here, see report).
  subroutine py_float(v, x, ok)
    type(dyn), intent(in) :: v
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    character(len=:), allocatable :: t, low
    integer :: ios, i
    x = 0.0_real64
    ok = .true.
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
    case (DYN_K_REAL)
      x = v%r
    case (DYN_K_BOOL)
      x = merge(1.0_real64, 0.0_real64, v%b)
    case (DYN_K_STR)
      if (.not. allocated(v%s)) then
        ok = .false.
        return
      end if
      t = trim(adjustl(v%s))
      low = to_lower(t)
      if (low == "inf" .or. low == "+inf" .or. low == "infinity" &
          .or. low == "+infinity") then
        x = ieee_value(0.0_real64, ieee_positive_inf)
        return
      end if
      if (low == "-inf" .or. low == "-infinity") then
        x = -ieee_value(0.0_real64, ieee_positive_inf)
        return
      end if
      if (low == "nan" .or. low == "+nan" .or. low == "-nan") then
        x = ieee_value(0.0_real64, ieee_quiet_nan)
        return
      end if
      ! Strip underscores and reject any character float() rejects.
      t = ""
      do i = 1, len(low)
        if (low(i:i) == "_") cycle
        if (index("0123456789.eE+-", low(i:i)) == 0) then
          ok = .false.
          return
        end if
        t = t // low(i:i)
      end do
      if (len(t) == 0) then
        ok = .false.
        return
      end if
      read (t, *, iostat=ios) x
      if (ios /= 0) ok = .false.
    case default
      ok = .false.
    end select
  end subroutine py_float

  !> Python int(value): truncation toward zero for reals; strings
  !! must be plain integers (whitespace/sign/digits).  ok=.false.
  !! where Python raises.  (Python ints are unbounded; int64 range
  !! is assumed -- see report.)
  subroutine py_int(v, n, ok)
    type(dyn), intent(in) :: v
    integer(int64), intent(out) :: n
    logical, intent(out) :: ok
    character(len=:), allocatable :: t
    integer :: i, sgn
    n = 0_int64
    ok = .true.
    select case (v%kind)
    case (DYN_K_INT)
      n = v%i
    case (DYN_K_BOOL)
      n = merge(1_int64, 0_int64, v%b)
    case (DYN_K_REAL)
      if (ieee_is_nan(v%r) .or. .not. ieee_is_finite(v%r)) then
        ok = .false.
        return
      end if
      n = int(v%r, int64)  ! Fortran int() truncates toward zero
    case (DYN_K_STR)
      if (.not. allocated(v%s)) then
        ok = .false.
        return
      end if
      t = trim(adjustl(v%s))
      i = 1
      sgn = 1
      if (i <= len(t)) then
        if (t(i:i) == "+") then
          i = i + 1
        else if (t(i:i) == "-") then
          sgn = -1
          i = i + 1
        end if
      end if
      if (i > len(t)) then
        ok = .false.
        return
      end if
      n = 0_int64
      do while (i <= len(t))
        if (t(i:i) < "0" .or. t(i:i) > "9") then
          ok = .false.
          return
        end if
        n = n * 10_int64 + int(iachar(t(i:i)) - iachar("0"), int64)
        i = i + 1
      end do
      n = sgn * n
    case default
      ok = .false.
    end select
  end subroutine py_int

  !> int(value) with the Python default when absent; a failed
  !! conversion falls back to the default too (Python would raise --
  !! unreachable for pipeline-produced IR; see report).
  function int_or(v, def) result(n)
    type(dyn), intent(in) :: v
    integer(int64), intent(in) :: def
    integer(int64) :: n
    logical :: ok
    if (v%kind == DYN_K_NULL) then
      n = def
      return
    end if
    call py_int(v, n, ok)
    if (.not. ok) n = def
  end function int_or

  !> Python round(float) -> int: round half to even on the exact
  !! binary value.
  function py_round(x) result(n)
    real(real64), intent(in) :: x
    integer(int64) :: n
    real(real64) :: fl, diff
    fl = floor(x)
    diff = x - fl
    if (diff > 0.5_real64) then
      n = int(fl, int64) + 1_int64
    else if (diff < 0.5_real64) then
      n = int(fl, int64)
    else
      if (mod(int(fl, int64), 2_int64) == 0_int64) then
        n = int(fl, int64)
      else
        n = int(fl, int64) + 1_int64
      end if
    end if
  end function py_round

  ! ------------------------------------------------------------------
  ! emit_common.fmt_num, layered on f3dc_str fmt_real (repr)
  ! ------------------------------------------------------------------

  !> fmt_num for a real64 (emit_common.fmt_num float branch).
  function fmt_num_real(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out, t
    integer :: i
    if (x == 0.0_real64) then
      out = "0"
      return
    end if
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
    if (x == floor(x) .and. abs(x) < 1.0e16_real64) then
      out = fmt_int(int(x, int64))
      return
    end if
    t = fmt_real(x)
    if (index(t, "e") > 0 .or. index(t, "E") > 0) then
      out = t
      return
    end if
    if (index(t, ".") > 0) then
      i = len(t)
      do while (i > 0)
        if (t(i:i) /= "0") exit
        i = i - 1
      end do
      t = t(1:i)
      if (len(t) > 0) then
        if (t(len(t):len(t)) == ".") t = t(1:len(t) - 1)
      end if
    end if
    if (len(t) == 0 .or. t == "-0") then
      out = "0"
    else
      out = t
    end if
  end function fmt_num_real

  !> emit_common.fmt_num(value) for a dyn value.
  function fmt_num(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    real(real64) :: x
    logical :: ok
    select case (v%kind)
    case (DYN_K_BOOL)
      out = fmt_int(merge(1_int64, 0_int64, v%b))
    case (DYN_K_INT)
      out = fmt_int(v%i)
    case (DYN_K_REAL)
      out = fmt_num_real(v%r)
    case (DYN_K_STR)
      ! fmt_num falls back to float(value), then str(value).
      call py_float(v, x, ok)
      if (ok) then
        out = fmt_num_real(x)
      else if (allocated(v%s)) then
        out = v%s
      else
        out = ""
      end if
    case (DYN_K_NULL)
      out = "None"
    case default
      out = ""
    end select
  end function fmt_num

  ! ------------------------------------------------------------------
  ! vec3 access (emit_fortran._vec3 / _fmt_vec)
  ! ------------------------------------------------------------------

  !> Fill comp(1..3) from a dyn sequence (len >= 3) or the defaults.
  subroutine vec3_of(v, d1, d2, d3, comp)
    type(dyn), intent(in) :: v
    type(dyn), intent(in) :: d1, d2, d3
    type(dyn), intent(out) :: comp(3)
    if (v%kind == DYN_K_LIST .and. v%n_items >= 3) then
      comp(1) = dyn_list_at(v, 1)
      comp(2) = dyn_list_at(v, 2)
      comp(3) = dyn_list_at(v, 3)
    else
      comp(1) = dyn_copy(d1)
      comp(2) = dyn_copy(d2)
      comp(3) = dyn_copy(d3)
    end if
  end subroutine vec3_of

  !> Convenience: vec3 from an object key chain with real defaults.
  subroutine vec3_key(obj, key1, key2, def, comp)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: key1, key2
    real(real64), intent(in) :: def(3)
    type(dyn), intent(out) :: comp(3)
    type(dyn) :: v
    if (len(key2) > 0) then
      v = gv2(obj, key1, key2)
    else
      v = gv(obj, key1)
    end if
    call vec3_of(v, dyn_real(def(1)), dyn_real(def(2)), &
                 dyn_real(def(3)), comp)
  end subroutine vec3_key

  function fmt_vec(comp) result(out)
    type(dyn), intent(in) :: comp(3)
    character(len=:), allocatable :: out
    out = fmt_num(comp(1)) // " " // fmt_num(comp(2)) // " " // &
          fmt_num(comp(3))
  end function fmt_vec

  !> Numeric equality of a vec3 against real defaults (Python tuple
  !! ==, where 0 == 0.0).  Non-numeric components count as unequal.
  logical function vec3_eq(comp, def)
    type(dyn), intent(in) :: comp(3)
    real(real64), intent(in) :: def(3)
    real(real64) :: x
    logical :: ok
    integer :: i
    vec3_eq = .true.
    do i = 1, 3
      call py_float(comp(i), x, ok)
      if (.not. ok .or. x /= def(i)) then
        vec3_eq = .false.
        return
      end if
    end do
  end function vec3_eq

  ! ------------------------------------------------------------------
  ! Colours (emit_fortran._color_ints / _color_text)
  ! ------------------------------------------------------------------

  !> (r, g, b) ints for a colour sequence, ok=.false. for Python None.
  subroutine color_ints(v, ints, ok)
    type(dyn), intent(in) :: v
    integer(int64), intent(out) :: ints(3)
    logical, intent(out) :: ok
    type(dyn) :: c
    integer :: i
    ints = 0_int64
    ok = .false.
    if (v%kind /= DYN_K_LIST .or. v%n_items < 3) return
    do i = 1, 3
      c = dyn_list_at(v, i)
      call py_int(c, ints(i), ok)
      if (.not. ok) then
        ints = 0_int64
        return
      end if
    end do
    ok = .true.
  end subroutine color_ints

  function color_text(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer(int64) :: ints(3)
    logical :: ok
    call color_ints(v, ints, ok)
    if (.not. ok) then
      out = "-1 -1 -1"  ! palette sentinel
    else
      out = fmt_int(ints(1)) // " " // fmt_int(ints(2)) // " " // &
            fmt_int(ints(3))
    end if
  end function color_text

  !> fmt_num(value) if not null, else the sentinel string.
  function num_or(v, sentinel) result(out)
    type(dyn), intent(in) :: v
    character(len=*), intent(in) :: sentinel
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_NULL) then
      out = sentinel
    else
      out = fmt_num(v)
    end if
  end function num_or

  !> emit_fortran._scalar: first component of a sequence, else value.
  function scalar_of(v) result(out)
    type(dyn), intent(in) :: v
    type(dyn) :: out
    if (v%kind == DYN_K_LIST) then
      if (v%n_items >= 1) then
        out = dyn_list_at(v, 1)
      else
        out = dyn_null()
      end if
    else
      out = dyn_copy(v)
    end if
  end function scalar_of

  !> emit_fortran._extension(obj, keys...): extensions dict first
  !! (every key), then the object's own keys (every key).
  function extension_of(obj, keys) result(val)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: keys(:)
    type(dyn) :: val, ext
    integer :: i
    val = dyn_null()
    ext = gvd(obj, "extensions", dyn_dict())
    ! Keys arrive as a fixed-length character array (padded); IR
    ! keys never carry trailing blanks, so trim before lookup.
    if (ext%kind == DYN_K_DICT) then
      do i = 1, size(keys)
        val = gv(ext, trim(keys(i)))
        if (val%kind /= DYN_K_NULL) return
      end do
    end if
    do i = 1, size(keys)
      val = gv(obj, trim(keys(i)))
      if (val%kind /= DYN_K_NULL) return
    end do
    val = dyn_null()
  end function extension_of

  !> emit_fortran._geometry(obj): the extensions.geometry dict.
  subroutine geometry_of(obj, geom, has)
    type(dyn), intent(in) :: obj
    type(dyn), intent(out) :: geom
    logical, intent(out) :: has
    type(dyn) :: ext
    geom = dyn_null()
    has = .false.
    ext = gvd(obj, "extensions", dyn_dict())
    if (ext%kind /= DYN_K_DICT) return
    geom = gv(ext, "geometry")
    if (geom%kind == DYN_K_DICT) then
      has = .true.
    else
      geom = dyn_null()
    end if
  end subroutine geometry_of

  ! ==================================================================
  ! Canonical JSON + SHA-256 (emit_common.source_hash) + header stamp
  ! ==================================================================

  !> JSON string escaping with ensure_ascii=False (emit_common
  !! _canonical_json): only ", \, and control chars are escaped;
  !! bytes >= 0x20 (including UTF-8 sequences) pass through raw.
  function json_escape_raw(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    character(len=6) :: hexbuf
    integer :: i, b
    out = ""
    do i = 1, len(s)
      b = iachar(s(i:i))
      select case (b)
      case (34)
        out = out // '\"'
      case (92)
        out = out // '\\'
      case (10)
        out = out // '\n'
      case (13)
        out = out // '\r'
      case (9)
        out = out // '\t'
      case (8)
        out = out // '\b'
      case (12)
        out = out // '\f'
      case (0:7, 11, 14:31)
        write (hexbuf, "(A,Z4.4)") "\u", b
        out = out // trim(hexbuf)
      case default
        out = out // s(i:i)
      end select
    end do
  end function json_escape_raw

  !> Unsigned byte-wise less-than (Python str sort = code points;
  !! UTF-8 byte order preserves code-point order).
  pure logical function key_lt(a, b)
    character(len=*), intent(in) :: a, b
    integer :: i, n, ca, cb
    n = min(len(a), len(b))
    key_lt = .false.
    do i = 1, n
      ca = iachar(a(i:i))
      cb = iachar(b(i:i))
      if (ca /= cb) then
        key_lt = ca < cb
        return
      end if
    end do
    key_lt = len(a) < len(b)
  end function key_lt

  !> emit_common._canonical_json for a dyn value: sorted dict keys,
  !! compact separators, ensure_ascii=False.  Floats use Python
  !! json's repr spelling (fmt_real), with json's Infinity/NaN words.
  recursive function canonical_json(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    integer :: i, j, n
    character(len=:), allocatable :: key, sub_json
    type(dyn) :: val
    integer, allocatable :: order(:)
    select case (v%kind)
    case (DYN_K_NULL)
      out = "null"
    case (DYN_K_BOOL)
      if (v%b) then
        out = "true"
      else
        out = "false"
      end if
    case (DYN_K_INT)
      out = fmt_int(v%i)
    case (DYN_K_REAL)
      if (ieee_is_nan(v%r)) then
        out = "NaN"
      else if (.not. ieee_is_finite(v%r)) then
        if (ieee_is_negative(v%r)) then
          out = "-Infinity"
        else
          out = "Infinity"
        end if
      else
        out = fmt_real(v%r)
      end if
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = '"' // json_escape_raw(v%s) // '"'
      else
        out = '""'
      end if
    case (DYN_K_LIST)
      out = "["
      do i = 1, v%n_items
        if (i > 1) out = out // ","
        val = dyn_list_at(v, i)
        sub_json = canonical_json(val)
        out = out // sub_json
      end do
      out = out // "]"
    case (DYN_K_DICT)
      n = v%n_entries
      allocate (order(n))
      do i = 1, n
        order(i) = i
      end do
      ! Selection sort of entry indices by key (n is small).
      block
        integer :: a, b, tmp, best
        do a = 1, n - 1
          best = a
          do b = a + 1, n
            if (key_lt(dyn_key_of(v, order(b)), &
                       dyn_key_of(v, order(best)))) best = b
          end do
          if (best /= a) then
            tmp = order(a)
            order(a) = order(best)
            order(best) = tmp
          end if
        end do
      end block
      out = "{"
      do i = 1, n
        if (i > 1) out = out // ","
        key = dyn_key_of(v, order(i))
        val = dyn_dict_value_copy(v, order(i))
        sub_json = canonical_json(val)
        out = out // '"' // json_escape_raw(key) // '":' // sub_json
      end do
      out = out // "}"
      deallocate (order)
    case default
      out = "null"
    end select
  end function canonical_json

  function dyn_key_of(v, idx) result(out)
    type(dyn), intent(in) :: v
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > v%n_entries) then
      out = ""
    else if (allocated(v%keys(idx)%s)) then
      out = v%keys(idx)%s
    else
      out = ""
    end if
  end function dyn_key_of

  function dyn_dict_value_copy(v, idx) result(out)
    type(dyn), intent(in) :: v
    integer, intent(in) :: idx
    type(dyn) :: out
    if (idx < 1 .or. idx > v%n_entries) then
      out = dyn_null()
    else
      out = dyn_copy(v%dvals(idx))
    end if
  end function dyn_dict_value_copy

  !> SHA-256 (FIPS 180-4) of a byte string, lowercase hex digest.
  !! int64 arithmetic masked to 32 bits (no reliance on overflow).
  function sha256_hex(text) result(digest)
    character(len=*), intent(in) :: text
    character(len=64) :: digest
    integer(int64), parameter :: M32 = int(z'FFFFFFFF', int64)
    integer(int64), parameter :: K(64) = [ &
      int(z'428a2f98', int64), int(z'71374491', int64), &
      int(z'b5c0fbcf', int64), int(z'e9b5dba5', int64), &
      int(z'3956c25b', int64), int(z'59f111f1', int64), &
      int(z'923f82a4', int64), int(z'ab1c5ed5', int64), &
      int(z'd807aa98', int64), int(z'12835b01', int64), &
      int(z'243185be', int64), int(z'550c7dc3', int64), &
      int(z'72be5d74', int64), int(z'80deb1fe', int64), &
      int(z'9bdc06a7', int64), int(z'c19bf174', int64), &
      int(z'e49b69c1', int64), int(z'efbe4786', int64), &
      int(z'0fc19dc6', int64), int(z'240ca1cc', int64), &
      int(z'2de92c6f', int64), int(z'4a7484aa', int64), &
      int(z'5cb0a9dc', int64), int(z'76f988da', int64), &
      int(z'983e5152', int64), int(z'a831c66d', int64), &
      int(z'b00327c8', int64), int(z'bf597fc7', int64), &
      int(z'c6e00bf3', int64), int(z'd5a79147', int64), &
      int(z'06ca6351', int64), int(z'14292967', int64), &
      int(z'27b70a85', int64), int(z'2e1b2138', int64), &
      int(z'4d2c6dfc', int64), int(z'53380d13', int64), &
      int(z'650a7354', int64), int(z'766a0abb', int64), &
      int(z'81c2c92e', int64), int(z'92722c85', int64), &
      int(z'a2bfe8a1', int64), int(z'a81a664b', int64), &
      int(z'c24b8b70', int64), int(z'c76c51a3', int64), &
      int(z'd192e819', int64), int(z'd6990624', int64), &
      int(z'f40e3585', int64), int(z'106aa070', int64), &
      int(z'19a4c116', int64), int(z'1e376c08', int64), &
      int(z'2748774c', int64), int(z'34b0bcb5', int64), &
      int(z'391c0cb3', int64), int(z'4ed8aa4a', int64), &
      int(z'5b9cca4f', int64), int(z'682e6ff3', int64), &
      int(z'748f82ee', int64), int(z'78a5636f', int64), &
      int(z'84c87814', int64), int(z'8cc70208', int64), &
      int(z'90befffa', int64), int(z'a4506ceb', int64), &
      int(z'bef9a3f7', int64), int(z'c67178f2', int64)]
    integer(int64) :: h(8), w(64), a, b, c, d, e, f, g, hh
    integer(int64) :: s0, s1, ss0, ss1, ch, maj, t1, t2
    integer :: i, j, blk, nblk, total, pos, byte
    integer(int64) :: msglen
    character(len=16), parameter :: HEXD = "0123456789abcdef"

    h = [int(z'6a09e667', int64), int(z'bb67ae85', int64), &
         int(z'3c6ef372', int64), int(z'a54ff53a', int64), &
         int(z'510e527f', int64), int(z'9b05688c', int64), &
         int(z'1f83d9ab', int64), int(z'5be0cd19', int64)]
    msglen = int(len(text), int64)
    total = ((len(text) + 9 + 63) / 64) * 64
    nblk = total / 64
    do blk = 1, nblk
      do i = 1, 16
        w(i) = 0_int64
        do j = 1, 4
          pos = (blk - 1) * 64 + (i - 1) * 4 + j
          byte = sha_byte(text, pos, msglen, total)
          w(i) = ior(ishft(w(i), 8), int(byte, int64))
        end do
      end do
      do i = 17, 64
        ss0 = ieor(ieor(rotr32(w(i - 15), 7), rotr32(w(i - 15), 18)), &
                   ishft(w(i - 15), -3))
        ss1 = ieor(ieor(rotr32(w(i - 2), 17), rotr32(w(i - 2), 19)), &
                   ishft(w(i - 2), -10))
        w(i) = iand(w(i - 16) + ss0 + w(i - 7) + ss1, M32)
      end do
      a = h(1); b = h(2); c = h(3); d = h(4)
      e = h(5); f = h(6); g = h(7); hh = h(8)
      do i = 1, 64
        s1 = ieor(ieor(rotr32(e, 6), rotr32(e, 11)), rotr32(e, 25))
        ch = ieor(iand(e, f), iand(ieor(e, M32), g))
        t1 = iand(hh + s1 + ch + K(i) + w(i), M32)
        s0 = ieor(ieor(rotr32(a, 2), rotr32(a, 13)), rotr32(a, 22))
        maj = ieor(ieor(iand(a, b), iand(a, c)), iand(b, c))
        t2 = iand(s0 + maj, M32)
        hh = g; g = f; f = e
        e = iand(d + t1, M32)
        d = c; c = b; b = a
        a = iand(t1 + t2, M32)
      end do
      h(1) = iand(h(1) + a, M32); h(2) = iand(h(2) + b, M32)
      h(3) = iand(h(3) + c, M32); h(4) = iand(h(4) + d, M32)
      h(5) = iand(h(5) + e, M32); h(6) = iand(h(6) + f, M32)
      h(7) = iand(h(7) + g, M32); h(8) = iand(h(8) + hh, M32)
    end do
    digest = ""
    do i = 1, 8
      do j = 7, 0, -1
        byte = int(iand(ishft(h(i), -4 * j), 15_int64))
        digest((i - 1) * 8 + (8 - j):(i - 1) * 8 + (8 - j)) = &
          HEXD(byte + 1:byte + 1)
      end do
    end do
  end function sha256_hex

  pure integer(int64) function rotr32(x, n)
    integer(int64), intent(in) :: x
    integer, intent(in) :: n
    rotr32 = iand(ior(ishft(x, -n), ishft(x, 32 - n)), &
                  int(z'FFFFFFFF', int64))
  end function rotr32

  !> Byte at 1-based position pos of the padded message.
  pure integer function sha_byte(text, pos, msglen, total)
    character(len=*), intent(in) :: text
    integer, intent(in) :: pos, total
    integer(int64), intent(in) :: msglen
    integer(int64) :: bitlen
    if (pos <= len(text)) then
      sha_byte = iachar(text(pos:pos))
    else if (pos == len(text) + 1) then
      sha_byte = 128
    else if (pos > total - 8) then
      bitlen = msglen * 8_int64
      sha_byte = int(iand(ishft(bitlen, -8 * (total - pos)), &
                          255_int64))
    else
      sha_byte = 0
    end if
  end function sha_byte

  !> emit_fortran._stamp: header_stamp(name, ir, comment) lines.
  !! (Python's try/except fallback to a 2-line stamp fires only when
  !! header_stamp itself raises; canonical JSON of a dyn cannot --
  !! see report.)
  subroutine stamp_lines(ir, comment, lines)
    type(dyn), intent(in) :: ir
    character(len=*), intent(in) :: comment
    type(char_list), intent(inout) :: lines
    character(len=:), allocatable :: name, canon
    type(dyn) :: nv
    nv = gv(ir, "name")
    if (nv%kind == DYN_K_NULL) then
      name = "untitled"
    else
      name = py_str(nv)
    end if
    canon = canonical_json(ir)
    call char_list_append(lines, &
      comment // " Forge3D generated file - do not edit")
    call char_list_append(lines, comment // " source: " // name)
    call char_list_append(lines, &
      comment // " sha256: " // sha256_hex(canon))
  end subroutine stamp_lines

  !> Join a char_list with "\n" and append the trailing "\n"
  !! (Python "\n".join(lines) + "\n").
  function join_lines(lines) result(out)
    type(char_list), intent(in) :: lines
    character(len=:), allocatable :: out
    integer :: i
    out = ""
    do i = 1, char_list_len(lines)
      out = out // char_list_at(lines, i) // NL
    end do
  end function join_lines

  ! ==================================================================
  ! Output / frame helpers (emit_fortran._render_output & friends)
  ! ==================================================================

  !> The first output (kind == 'render'); found=.false. for None.
  subroutine render_output(ir, out, found)
    type(dyn), intent(in) :: ir
    type(dyn), intent(out) :: out
    logical, intent(out) :: found
    type(dyn) :: outputs, o
    integer :: i
    out = dyn_null()
    found = .false.
    outputs = gvd(ir, "outputs", dyn_list())
    if (outputs%kind /= DYN_K_LIST) return
    do i = 1, outputs%n_items
      o = dyn_list_at(outputs, i)
      if (to_lower(py_str(gvd(o, "kind", dyn_str("")))) == "render") &
        then
        call dyn_assign(out, o)
        found = .true.
        return
      end if
    end do
  end subroutine render_output

  !> emit_fortran._is_still.
  logical function is_still(ir)
    type(dyn), intent(in) :: ir
    type(dyn) :: outputs, o, cand(64)
    integer :: i, nc
    logical :: found
    is_still = .false.
    nc = 0
    call render_output(ir, o, found)
    if (found) then
      nc = nc + 1
      call dyn_assign(cand(nc), o)
    end if
    outputs = gvd(ir, "outputs", dyn_list())
    if (outputs%kind == DYN_K_LIST) then
      do i = 1, outputs%n_items
        o = dyn_list_at(outputs, i)
        if (to_lower(py_str(gvd(o, "kind", dyn_str("")))) == "still") &
          then
          if (nc < 64) then
            nc = nc + 1
            call dyn_assign(cand(nc), o)
          end if
        end if
      end do
    end if
    do i = 1, nc
      if (py_truthy(gvd(cand(i), "still", dyn_bool(.false.)))) then
        is_still = .true.
        return
      end if
      if (to_lower(py_str(gvd(cand(i), "kind", dyn_str("")))) == &
          "still") then
        is_still = .true.
        return
      end if
      if (to_lower(py_str(gvd(cand(i), "format", dyn_str("")))) == &
          "still") then
        is_still = .true.
        return
      end if
      if (to_lower(py_str(gvd(cand(i), "mode", dyn_str("")))) == &
          "still") then
        is_still = .true.
        return
      end if
    end do
  end function is_still

  !> emit_fortran._output_path.
  function output_path(ir) result(out)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable :: out
    type(dyn) :: render, p
    logical :: found
    call render_output(ir, render, found)
    if (found) then
      p = gv(render, "path")
    else
      p = dyn_null()
    end if
    if (.not. py_truthy(p)) then
      out = DEFAULT_OUTPUT
    else
      out = py_str(p)
    end if
  end function output_path

  !> emit_fortran._frame_count.
  function frame_count(ir) result(frames)
    type(dyn), intent(in) :: ir
    integer(int64) :: frames
    type(dyn) :: anims, anim, dv, fv
    real(real64) :: dur, fps
    logical :: ok1, ok2
    integer :: i
    frames = 1_int64
    anims = gv2(ir, "animations", "anims")
    if (anims%kind /= DYN_K_LIST .or. anims%n_items == 0) return
    if (is_still(ir)) return
    do i = 1, anims%n_items
      anim = dyn_list_at(anims, i)
      dv = gvd(anim, "duration", dyn_real(5.0_real64))
      fv = gvd(anim, "fps", dyn_int(30_int64))
      call py_float(dv, dur, ok1)
      call py_float(fv, fps, ok2)
      if (.not. (ok1 .and. ok2)) cycle
      frames = max(frames, py_round(dur * fps))
    end do
    frames = max(1_int64, frames)
  end function frame_count

  ! ==================================================================
  ! Raw triangle soups (emit_fortran._tri_parts / _triangles)
  ! ==================================================================

  pure logical function is_num(v)
    type(dyn), intent(in) :: v
    is_num = v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL
  end function is_num

  !> A dyn sequence of exactly 3 numerics (a vertex / colour triple).
  pure logical function is_num3(v)
    type(dyn), intent(in) :: v
    integer :: i
    is_num3 = .false.
    if (v%kind /= DYN_K_LIST .or. v%n_items /= 3) return
    do i = 1, 3
      if (.not. is_num(v%items(i))) return
    end do
    is_num3 = .true.
  end function is_num3

  !> A dyn sequence of exactly 3 numeric vec3 sequences.
  pure logical function is_vec3_list(v)
    type(dyn), intent(in) :: v
    integer :: i, j
    is_vec3_list = .false.
    if (v%kind /= DYN_K_LIST .or. v%n_items /= 3) return
    do i = 1, 3
      if (v%items(i)%kind /= DYN_K_LIST) return
      if (v%items(i)%n_items /= 3) return
      do j = 1, 3
        if (.not. is_num(v%items(i)%items(j))) return
      end do
    end do
    is_vec3_list = .true.
  end function is_vec3_list

  !> Normalise one raw triangle into tris (emit_fortran._tri_parts).
  subroutine tri_add(tris, tri, obj_color)
    type(tri_list_t), intent(inout) :: tris
    type(dyn), intent(in) :: tri, obj_color
    type(dyn) :: verts, colorv, item, pt
    integer(int64) :: cols(3)
    logical :: ok, have_color, have_verts
    integer :: i, j, nseq
    integer :: seq_idx(64)
    type(dyn) :: vlist(3)

    have_color = .false.
    have_verts = .false.
    cols = 0_int64
    if (tri%kind == DYN_K_DICT) then
      block
        character(len=*), parameter :: KEYS(4) = [ &
          "v       ", "verts   ", "vertices", "points  "]
        do i = 1, 4
          item = gv(tri, trim(KEYS(i)))
          if (item%kind == DYN_K_LIST) then
            call dyn_assign(verts, item)
            have_verts = .true.
            exit
          end if
        end do
      end block
      ! tri.get("color", tri.get("colour")): a present-but-null
      ! "color" wins over "colour" in Python; gv() cannot tell the
      ! two apart -- dyn_dict_has can.
      if (dyn_dict_has(tri, "color")) then
        colorv = gv(tri, "color")
      else
        colorv = gv(tri, "colour")
      end if
      call color_ints(colorv, cols, have_color)
    else if (tri%kind == DYN_K_LIST) then
      nseq = 0
      do i = 1, min(tri%n_items, 64)
        if (is_num3(tri%items(i))) then
          nseq = nseq + 1
          seq_idx(nseq) = i
        end if
      end do
      if (tri%n_items == 2 .and. nseq == 1) then
        item = dyn_list_at(tri, 2)
        if (is_vec3_list(item)) then
          call dyn_assign(verts, item)
          have_verts = .true.
          call color_ints(dyn_list_at(tri, 1), cols, have_color)
        end if
      end if
      if (.not. have_verts .and. tri%n_items == 3 .and. nseq == 3) then
        verts = dyn_copy(tri)
        have_verts = .true.
      end if
      if (.not. have_verts .and. tri%n_items == 4 .and. nseq == 4) then
        verts = dyn_list()
        do i = 2, 4
          call dyn_list_push(verts, tri%items(i))
        end do
        have_verts = .true.
        call color_ints(dyn_list_at(tri, 1), cols, have_color)
      end if
      if (.not. have_verts .and. nseq >= 3) then
        verts = dyn_list()
        do i = 1, 3
          call dyn_list_push(verts, tri%items(seq_idx(i)))
        end do
        have_verts = .true.
      end if
    end if
    if (.not. have_verts) return
    if (verts%kind /= DYN_K_LIST .or. verts%n_items < 3) return
    do i = 1, 3
      pt = dyn_list_at(verts, i)
      if (pt%kind /= DYN_K_LIST .or. pt%n_items < 3) return
      call dyn_assign(vlist(i), pt)
    end do
    if (.not. have_color) then
      call color_ints(obj_color, cols, ok)
      if (.not. ok) cols = [255_int64, 255_int64, 255_int64]
    end if
    ! Append.
    block
      integer(int64), allocatable :: ncols(:, :)
      type(dyn), allocatable :: npts(:)
      integer :: oldn
      oldn = tris%n
      allocate (ncols(3, oldn + 1))
      allocate (npts(9 * (oldn + 1)))
      do i = 1, oldn
        ncols(:, i) = tris%cols(:, i)
        do j = 1, 9
          npts((i - 1) * 9 + j) = dyn_copy(tris%pts((i - 1) * 9 + j))
        end do
      end do
      ncols(:, oldn + 1) = cols
      do i = 1, 3
        do j = 1, 3
          npts(oldn * 9 + (i - 1) * 3 + j) = &
            dyn_list_at(vlist(i), j)
        end do
      end do
      if (allocated(tris%cols)) deallocate (tris%cols)
      if (allocated(tris%pts)) deallocate (tris%pts)
      call move_alloc(ncols, tris%cols)
      call move_alloc(npts, tris%pts)
      tris%n = oldn + 1
    end block
  end subroutine tri_add

  !> emit_fortran._triangles(obj).
  subroutine triangles_of(obj, tris)
    type(dyn), intent(in) :: obj
    type(tri_list_t), intent(out) :: tris
    type(dyn) :: raw, oc
    integer :: i
    tris%n = 0
    raw = gv2(obj, "triangles", "tris")
    if (raw%kind /= DYN_K_LIST) return
    oc = gv2(obj, "color", "colour")
    do i = 1, raw%n_items
      call tri_add(tris, raw%items(i), oc)
    end do
  end subroutine triangles_of

  ! ==================================================================
  ! Path handling for loadobj (os.path mirror, POSIX)
  ! ==================================================================

  pure logical function path_isabs(p)
    character(len=*), intent(in) :: p
    path_isabs = len(p) >= 1
    if (path_isabs) path_isabs = p(1:1) == "/"
  end function path_isabs

  function path_join(a, b) result(out)
    character(len=*), intent(in) :: a, b
    character(len=:), allocatable :: out
    if (path_isabs(b)) then
      out = b
    else if (len(a) == 0) then
      out = b
    else if (a(len(a):len(a)) == "/") then
      out = a // b
    else
      out = a // "/" // b
    end if
  end function path_join

  !> os.path.normpath (POSIX): collapse ".", "..", duplicate "/".
  function path_normpath(p) result(out)
    character(len=*), intent(in) :: p
    character(len=:), allocatable :: out, part
    type(char_list) :: parts, kept
    integer :: i
    logical :: absolute
    absolute = path_isabs(p)
    call str_split_keep(p, parts)
    do i = 1, char_list_len(parts)
      part = char_list_at(parts, i)
      if (len(part) == 0 .or. part == ".") cycle
      if (part == "..") then
        if (char_list_len(kept) > 0 .and. &
            char_list_at(kept, char_list_len(kept)) /= "..") then
          ! pop last
          block
            type(char_list) :: nk
            integer :: k
            do k = 1, char_list_len(kept) - 1
              call char_list_append(nk, char_list_at(kept, k))
            end do
            kept = nk
          end block
        else if (.not. absolute) then
          call char_list_append(kept, "..")
        end if
      else
        call char_list_append(kept, part)
      end if
    end do
    out = ""
    if (absolute) out = "/"
    do i = 1, char_list_len(kept)
      if (i > 1) out = out // "/"
      out = out // char_list_at(kept, i)
    end do
    if (len(out) == 0) then
      if (absolute) then
        out = "/"
      else
        out = "."
      end if
    end if
  end function path_normpath

  !> Split on "/" keeping empties (local helper; str_split in
  !! f3dc_str has the same contract but is not imported for this).
  subroutine str_split_keep(s, parts)
    character(len=*), intent(in) :: s
    type(char_list), intent(inout) :: parts
    integer :: start, hit
    call char_list_clear(parts)
    start = 1
    do
      if (start > len(s)) then
        call char_list_append(parts, "")
        exit
      end if
      hit = index(s(start:), "/")
      if (hit == 0) then
        call char_list_append(parts, s(start:))
        exit
      end if
      call char_list_append(parts, s(start:start + hit - 2))
      start = start + hit
    end do
  end subroutine str_split_keep

  !> Current working directory via libc getcwd (flang-new-18 has
  !! no GETCWD intrinsic); "" on failure.
  function get_cwd() result(out)
    use, intrinsic :: iso_c_binding, only: c_char, c_size_t, c_ptr, &
                                           c_associated, c_null_char
    character(len=:), allocatable :: out
    interface
      function c_getcwd(buf, size) bind(C, name="getcwd") result(res)
        import :: c_char, c_size_t, c_ptr
        type(c_ptr) :: res
        character(kind=c_char) :: buf(*)
        integer(c_size_t), value :: size
      end function c_getcwd
    end interface
    character(kind=c_char) :: buf(4096)
    type(c_ptr) :: res
    integer :: i, n
    res = c_getcwd(buf, 4096_c_size_t)
    if (.not. c_associated(res)) then
      out = ""
      return
    end if
    n = 0
    do i = 1, 4096
      if (buf(i) == c_null_char) exit
      n = i
    end do
    allocate (character(len=n) :: out)
    do i = 1, n
      out(i:i) = achar(iachar(buf(i)))
    end do
  end function get_cwd

  !> os.path.abspath: normpath(join(cwd, p)) unless p is absolute.
  function path_abspath(p) result(out)
    character(len=*), intent(in) :: p
    character(len=:), allocatable :: out
    character(len=:), allocatable :: cwd
    if (path_isabs(p)) then
      out = path_normpath(p)
      return
    end if
    cwd = get_cwd()
    if (len(cwd) == 0) then
      out = path_normpath(p)
      return
    end if
    out = path_normpath(cwd // "/" // p)
  end function path_abspath

  logical function file_exists(p)
    character(len=*), intent(in) :: p
    inquire (file=p, exist=file_exists)
  end function file_exists

  ! ==================================================================
  ! EXT HOOK POINTS (see module header; all currently produce no
  ! output, mirroring Python's guarded-import failure path)
  ! ==================================================================

  !> EXT HOOK: ext_lights_env.light_line(kind, ext, color, intensity)
  !! for point/spot lights.
  subroutine hook_light_line(kind, light, line, found)
    character(len=*), intent(in) :: kind
    type(dyn), intent(in) :: light
    character(len=:), allocatable, intent(out) :: line
    logical, intent(out) :: found
    type(dyn) :: ext, colord, iv
    integer(int64) :: lc(3)
    logical :: ok
    integer :: j
    real(real64) :: inten
    line = ""
    found = .false.
    ext = dyn_dict()
    call dyn_dict_set(ext, "position", gv2(light, "position", "at"))
    call dyn_dict_set(ext, "target", gv2(light, "target", "look"))
    call dyn_dict_set(ext, "distance", &
                      gvd(light, "distance", dyn_real(0.0_real64)))
    call dyn_dict_set(ext, "decay", &
                      gvd(light, "decay", dyn_real(2.0_real64)))
    call dyn_dict_set(ext, "angle", &
                      gvd(light, "angle", dyn_real(45.0_real64)))
    call dyn_dict_set(ext, "penumbra", &
                      gvd(light, "penumbra", dyn_real(0.0_real64)))
    call color_ints(gv2(light, "color", "colour"), lc, ok)
    if (.not. ok) lc = [255_int64, 255_int64, 255_int64]
    colord = dyn_list()
    do j = 1, 3
      call dyn_list_push(colord, dyn_int(lc(j)))
    end do
    iv = gvd(light, "intensity", dyn_real(1.0_real64))
    inten = 1.0_real64
    if (iv%kind == DYN_K_INT) inten = real(iv%i, real64)
    if (iv%kind == DYN_K_REAL) inten = iv%r
    call light_line(kind, ext, colord, inten, line, found)
  end subroutine hook_light_line

  !> EXT HOOK: ext_materials.objmat_line(name, material, extd).
  subroutine hook_objmat_line(name, material, extd, line, found)
    character(len=*), intent(in) :: name, material
    type(dyn), intent(in) :: extd
    character(len=:), allocatable, intent(out) :: line
    logical, intent(out) :: found
    call mat_objmat(name, material, extd, line, found)
  end subroutine hook_objmat_line

  !> EXT HOOK: ext_lights_env.env_lines(env) -> list of lines.
  subroutine hook_env_lines(env, lines)
    type(dyn), intent(in) :: env
    type(char_list), intent(inout) :: lines
    call env_lines(env, lines)
  end subroutine hook_env_lines

  !> EXT HOOK: ext_sprites_text.sprite_line(name, entry).
  subroutine hook_sprite_line(name, entry, line)
    character(len=*), intent(in) :: name
    type(dyn), intent(in) :: entry
    character(len=:), allocatable, intent(out) :: line
    call sprite_line(name, entry, line)
  end subroutine hook_sprite_line

  !> EXT HOOK: ext_sprites_text.text_line(name, entry).
  subroutine hook_text_line(name, entry, line)
    character(len=*), intent(in) :: name
    type(dyn), intent(in) :: entry
    character(len=:), allocatable, intent(out) :: line
    call text_line(name, entry, line)
  end subroutine hook_text_line

  !> EXT HOOK: ext_particles.particles_line(name, entry).
  subroutine hook_particles_line(name, entry, line)
    character(len=*), intent(in) :: name
    type(dyn), intent(in) :: entry
    character(len=:), allocatable, intent(out) :: line
    call particles_line(name, entry, line)
  end subroutine hook_particles_line

  !> EXT HOOK: ext_keys.track_lines(target, track) -> lines.
  subroutine hook_track_lines(target, track, lines)
    character(len=*), intent(in) :: target
    type(dyn), intent(in) :: track
    type(char_list), intent(inout) :: lines
    call ext_keys_track_lines(target, track, lines)
  end subroutine hook_track_lines

  !> EXT HOOK: ext_cameras.camera_lines(cam_ext) -> lines.
  subroutine hook_camera_lines(cam_ext, lines)
    type(dyn), intent(in) :: cam_ext
    type(char_list), intent(inout) :: lines
    type(char_list) :: extra
    integer :: k
    call ext_camera_lines(cam_ext, extra)
    do k = 1, char_list_len(extra)
      call char_list_append(lines, char_list_at(extra, k))
    end do
  end subroutine hook_camera_lines

  !> EXT HOOK: ext_post.post_lines(chain) -> lines.
  subroutine hook_post_lines(chain, lines)
    type(dyn), intent(in) :: chain
    type(char_list), intent(inout) :: lines
    type(char_list) :: extra
    integer :: k
    call ext_post_lines(chain, extra)
    do k = 1, char_list_len(extra)
      call char_list_append(lines, char_list_at(extra, k))
    end do
  end subroutine hook_post_lines

  !> EXT HOOK: ext_shader.scene_lines(defs) + binding_line.
  subroutine hook_shader_lines(we, lines)
    type(dyn), intent(in) :: we
    type(char_list), intent(inout) :: lines
    type(dyn) :: defs, bindings
    type(char_list) :: def_lines
    integer :: k
    defs = gv(we, "shaders")
    call shader_scene_lines(defs, def_lines)
    do k = 1, char_list_len(def_lines)
      call char_list_append(lines, char_list_at(def_lines, k))
    end do
    bindings = gv(we, "bindings")
    if (bindings%kind == DYN_K_DICT) then
      do k = 1, dyn_dict_len(bindings)
        call char_list_append(lines, shader_binding_line( &
          dyn_dict_key_at(bindings, k), &
          py_str(dyn_dict_value_at(bindings, k))))
      end do
    end if
  end subroutine hook_shader_lines

  !> EXT HOOK: ext_skin.scene_lines(morphs, bones, skins).
  subroutine hook_skin_lines(we, lines)
    type(dyn), intent(in) :: we
    type(char_list), intent(inout) :: lines
    call ext_skin_scene_lines(gv(we, "morphs"), gv(we, "bones"), &
                              gv(we, "skins"), lines)
  end subroutine hook_skin_lines

  !> ext_geometry.scene_extra_values(prim, geom), INLINED: the
  !! Python function is a 10-line flatten (flat components of
  !! geom["path"|"points"|"shape"] for tube/lathe/extrude), small
  !! enough to port here exactly rather than leave as a hook.
  !! ok=.false. mirrors a Python exception inside the call (a
  !! non-sequence point), which _scene_extra_values catches and
  !! falls back to the raw-attribute path.
  subroutine ext_scene_extra_values(prim, geom, vals, ok)
    character(len=*), intent(in) :: prim
    type(dyn), intent(in) :: geom
    type(char_list), intent(inout) :: vals
    logical, intent(out) :: ok
    type(dyn) :: flat
    integer :: i
    ok = .true.
    flat = eg_scene_extra(prim, geom)
    do i = 1, dyn_list_len(flat)
      call char_list_append(vals, fmt_num(dyn_list_at(flat, i)))
    end do
  end subroutine ext_scene_extra_values

  ! ==================================================================
  ! Wave D extra tokens (emit_fortran._scene_extra_values)
  ! ==================================================================

  !> Formatted extra values (fmt_num applied) for an object line.
  subroutine scene_extra_values(obj, prim, vals)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: prim
    type(char_list), intent(inout) :: vals
    type(dyn) :: geom, raw, point, item
    logical :: has
    integer :: i, j
    call char_list_clear(vals)
    call geometry_of(obj, geom, has)
    if (has .and. py_truthy(geom)) then
      ! Python: `if geom:` (non-empty dict) -> ext call; an
      ! exception inside it falls through to the fallback below.
      block
        logical :: okx
        call ext_scene_extra_values(prim, geom, vals, okx)
        if (okx) return
      end block
    end if
    ! Fallback: raw point lists carried as attributes / extensions.
    if (prim /= "tube" .and. prim /= "lathe" .and. &
        prim /= "extrude") return
    block
      character(len=8) :: key
      if (prim == "tube") key = "path"
      if (prim == "lathe") key = "points"
      if (prim == "extrude") key = "shape"
      raw = extension_of(obj, [key])
    end block
    if (raw%kind /= DYN_K_LIST) return
    do i = 1, raw%n_items
      point = dyn_list_at(raw, i)
      if (point%kind == DYN_K_LIST) then
        do j = 1, point%n_items
          item = dyn_list_at(point, j)
          call char_list_append(vals, fmt_num(item))
        end do
      else if (is_num(point) .or. point%kind == DYN_K_BOOL) then
        call char_list_append(vals, fmt_num(point))
      end if
    end do
  end subroutine scene_extra_values

  ! ==================================================================
  ! 1. The .scene text format (emit_fortran.emit_scene_text)
  ! ==================================================================

  subroutine emit_scene_text(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    type(char_list) :: lines
    type(dyn) :: camera, lights, light, objects, obj, anims, anim
    type(dyn) :: comp(3), tcomp(3), scomp(3), colord, exts, extd
    character(len=:), allocatable :: kind, intensity_s, name, prim
    character(len=:), allocatable :: material, transform, line
    character(len=:), allocatable :: path_s, base
    integer(int64) :: bg(3), lc(3)
    logical :: ok
    integer :: i, j
    type(tri_list_t) :: tris

    call char_list_append(lines, "forge3d-scene 1")
    call stamp_lines(ir, "#", lines)

    call char_list_append(lines, "size " // &
      fmt_int(int_or(gv(ir, "width"), 640_int64)) // " " // &
      fmt_int(int_or(gv(ir, "height"), 480_int64)))

    call color_ints(gvd(ir, "bg", dyn_null()), bg, ok)
    if (.not. ok) then
      ! _get(ir, "bg", "background", default=(25,25,35)) chain.
      block
        type(dyn) :: bgv
        bgv = gv2(ir, "bg", "background")
        call color_ints(bgv, bg, ok)
      end block
    end if
    if (.not. ok) bg = [25_int64, 25_int64, 35_int64]
    call char_list_append(lines, "bg " // fmt_int(bg(1)) // " " // &
      fmt_int(bg(2)) // " " // fmt_int(bg(3)))

    camera = gv(ir, "camera")
    call vec3_key(camera, "pos", "position", &
                  [3.0_real64, 2.5_real64, 4.0_real64], comp)
    line = "camera " // fmt_vec(comp)
    call vec3_key(camera, "target", "", &
                  [0.0_real64, 0.0_real64, 0.0_real64], comp)
    line = line // " " // fmt_vec(comp)
    call vec3_key(camera, "up", "", &
                  [0.0_real64, 1.0_real64, 0.0_real64], comp)
    line = line // " " // fmt_vec(comp)
    line = line // " " // &
      fmt_num(gvd(camera, "fov", dyn_real(60.0_real64))) // " " // &
      fmt_num(gvd(camera, "near", dyn_real(0.1_real64))) // " " // &
      fmt_num(gvd(camera, "far", dyn_real(100.0_real64)))
    call char_list_append(lines, line)

    lights = gvd(ir, "lights", dyn_list())
    if (lights%kind == DYN_K_LIST) then
      do i = 1, lights%n_items
        light = dyn_list_at(lights, i)
        kind = to_lower(py_str(gvd(light, "kind", &
                                   dyn_str("directional"))))
        intensity_s = fmt_num(gvd(light, "intensity", &
                                  dyn_real(1.0_real64)))
        if (kind == "point" .or. kind == "spot") then
          ! EXT HOOK: ext_lights_env.light_line.
          call hook_light_line(kind, light, line, ok)
          if (ok) call char_list_append(lines, line)
          cycle
        end if
        if (kind == "ambient") then
          call char_list_append(lines, "light ambient " // intensity_s)
        else
          call vec3_key(light, "direction", "dir", &
                        [-0.5_real64, -1.0_real64, -0.7_real64], comp)
          call color_ints(gv2(light, "color", "colour"), lc, ok)
          if (.not. ok) then
            block
              type(dyn) :: cv
              cv = gv2(light, "color", "colour")
              if (cv%kind == DYN_K_NULL) then
                lc = [255_int64, 255_int64, 255_int64]
                ok = .true.
              end if
            end block
          end if
          if (.not. ok) lc = [255_int64, 255_int64, 255_int64]
          call char_list_append(lines, "light " // kind // " " // &
            fmt_vec(comp) // " " // fmt_int(lc(1)) // " " // &
            fmt_int(lc(2)) // " " // fmt_int(lc(3)) // " " // &
            intensity_s)
        end if
      end do
    end if

    call char_list_append(lines, &
      "frames " // fmt_int(frame_count(ir)))
    call char_list_append(lines, "output " // output_path(ir))

    objects = gvd(ir, "objects", dyn_list())
    if (objects%kind == DYN_K_LIST) then
      do i = 1, objects%n_items
        obj = dyn_list_at(objects, i)
        name = py_str(gvd(obj, "name", dyn_str("object")))
        block
          type(dyn) :: pv
          pv = gv2(obj, "prim", "primitive")
          if (pv%kind == DYN_K_NULL) then
            prim = "cube"
          else
            prim = to_lower(py_str(pv))
          end if
        end block
        material = to_lower(py_str(gvd(obj, "material", &
                                       dyn_str("lambert"))))
        colord = gv2(obj, "color", "colour")
        call vec3_key(obj, "pos", "position", &
                      [0.0_real64, 0.0_real64, 0.0_real64], comp)
        call vec3_key(obj, "rotate", "rotation", &
                      [0.0_real64, 0.0_real64, 0.0_real64], tcomp)
        call vec3_key(obj, "scale", "", &
                      [1.0_real64, 1.0_real64, 1.0_real64], scomp)
        transform = fmt_vec(comp) // " " // fmt_vec(tcomp) // " " // &
                    fmt_vec(scomp)
        if (prim == "tris") then
          call triangles_of(obj, tris)
          if (.not. (vec3_eq(comp, [0.0_real64, 0.0_real64, &
                                    0.0_real64]) .and. &
                     vec3_eq(tcomp, [0.0_real64, 0.0_real64, &
                                     0.0_real64]) .and. &
                     vec3_eq(scomp, [1.0_real64, 1.0_real64, &
                                     1.0_real64]))) then
            call char_list_append(lines, "tris " // name // " " // &
              fmt_int(int(tris%n, int64)) // " " // transform)
          else
            call char_list_append(lines, "tris " // name // " " // &
              fmt_int(int(tris%n, int64)))
          end if
          do j = 1, tris%n
            line = "tri " // fmt_int(tris%cols(1, j)) // " " // &
              fmt_int(tris%cols(2, j)) // " " // &
              fmt_int(tris%cols(3, j))
            block
              type(dyn) :: pc(3)
              integer :: a, b
              do a = 1, 3
                do b = 1, 3
                  pc(b) = dyn_copy(tris%pts((j - 1) * 9 + &
                                             (a - 1) * 3 + b))
                end do
                line = line // " " // fmt_vec(pc)
              end do
            end block
            call char_list_append(lines, line)
          end do
        else if (prim == "load") then
          block
            type(dyn) :: pv, bv
            pv = gv3(obj, "source_file", "path", "file")
            if (.not. py_truthy(pv)) then
              path_s = "model.obj"
            else
              path_s = py_str(pv)
            end if
            ! Wave A housekeeping: resolve relative OBJ paths
            ! against the .f3d file's directory (ir base_dir).
            bv = gv(ir, "base_dir")
            if (bv%kind /= DYN_K_NULL) then
              base = py_str(bv)
              if (len(base) > 0 .and. .not. path_isabs(path_s)) then
                block
                  character(len=:), allocatable :: cand
                  cand = path_join(base, path_s)
                  if (file_exists(cand)) path_s = path_abspath(cand)
                end block
              end if
            end if
          end block
          call char_list_append(lines, "loadobj " // name // " " // &
            material // " " // color_text(colord) // " " // &
            transform // " " // path_s)
        else
          block
            type(dyn) :: sizev, radv, hv, segv
            type(char_list) :: extra
            character(len=:), allocatable :: segs
            sizev = scalar_of(gv(obj, "size"))
            if (sizev%kind == DYN_K_NULL) &
              sizev = scalar_of(gv(obj, "size3"))
            radv = gv(obj, "radius")
            hv = gv(obj, "height")
            segv = gv(obj, "segments")
            if (segv%kind == DYN_K_NULL) then
              segs = "0"
            else
              segs = fmt_int(int_or(segv, 0_int64))
            end if
            line = "object " // prim // " " // name // " " // &
              material // " " // color_text(colord) // " " // &
              transform // " " // num_or(sizev, "-1") // " " // &
              num_or(radv, "-1") // " " // num_or(hv, "-1") // " " // &
              segs
            call scene_extra_values(obj, prim, extra)
            if (char_list_len(extra) > 0) then
              do j = 1, char_list_len(extra)
                line = line // " " // char_list_at(extra, j)
              end do
            end if
            ! P1: explicit shading token goes last on the line.
            block
              type(dyn) :: shv
              shv = gv(obj, "shading")
              if (shv%kind == DYN_K_STR) &
                line = line // " shading " // to_lower(py_str(shv))
            end block
            ! P3: explicit mirror token goes after shading.
            block
              type(dyn) :: mrv
              mrv = gv(obj, "mirror")
              if (mrv%kind == DYN_K_STR) &
                line = line // " mirror " // to_lower(py_str(mrv))
            end block
            call char_list_append(lines, line)
          end block
        end if
      end do
    end if

    anims = gv2(ir, "animations", "anims")
    if (anims%kind == DYN_K_LIST) then
      do i = 1, anims%n_items
        anim = dyn_list_at(anims, i)
        line = "anim " // &
          to_lower(py_str(gvd(anim, "kind", dyn_str("spin")))) // &
          " " // py_str(gvd(anim, "target", dyn_str("all"))) // &
          " " // &
          to_lower(py_str(gvd(anim, "axis", dyn_str("y")))) // &
          " " // fmt_num(gvd(anim, "speed", &
                             dyn_real(90.0_real64))) // &
          " " // fmt_num(gvd(anim, "duration", &
                             dyn_real(5.0_real64))) // &
          " " // fmt_int(int_or(gv(anim, "fps"), 30_int64)) // &
          " " // &
          to_lower(py_str(gvd(anim, "ease", dyn_str("linear")))) // &
          " " // &
          to_lower(py_str(gvd(anim, "loop", dyn_str("forever"))))
        call char_list_append(lines, line)
      end do
    end if

    ! Wave A: per-object material lines + scene env lines (EXT).
    exts = gvd(ir, "extensions", dyn_dict())
    if (exts%kind == DYN_K_DICT) then
      if (objects%kind == DYN_K_LIST) then
        do i = 1, objects%n_items
          obj = dyn_list_at(objects, i)
          block
            type(dyn) :: oext
            oext = gvd(obj, "extensions", dyn_dict())
            if (oext%kind /= DYN_K_DICT) cycle
            extd = gv(oext, "material")
            if (.not. py_truthy(extd)) cycle
            call hook_objmat_line( &
              py_str(gvd(obj, "name", dyn_str("object"))), &
              to_lower(py_str(gvd(obj, "material", &
                                  dyn_str("lambert")))), &
              extd, line, ok)
            if (ok) call char_list_append(lines, line)
          end block
        end do
      end if
      block
        type(dyn) :: env
        env = gv(exts, "env")
        if (py_truthy(env)) call hook_env_lines(env, lines)
      end block
    end if

    ! Wave B: sprite / text / particles / keyframe lines (EXT).
    if (exts%kind == DYN_K_DICT) then
      block
        type(dyn) :: wb, lst, entry
        integer :: k
        wb = gv(exts, "waveb")
        if (py_truthy(wb) .and. wb%kind == DYN_K_DICT) then
          lst = gv(wb, "sprites")
          if (lst%kind == DYN_K_LIST) then
            do k = 1, lst%n_items
              entry = dyn_list_at(lst, k)
              call hook_sprite_line( &
                py_str(gvd(entry, "name", dyn_str("sprite"))), &
                entry, line)
              if (len(line) > 0) call char_list_append(lines, line)
            end do
          end if
          lst = gv(wb, "texts")
          if (lst%kind == DYN_K_LIST) then
            do k = 1, lst%n_items
              entry = dyn_list_at(lst, k)
              call hook_text_line( &
                py_str(gvd(entry, "name", dyn_str("text"))), &
                entry, line)
              if (len(line) > 0) call char_list_append(lines, line)
            end do
          end if
          lst = gv(wb, "particles")
          if (lst%kind == DYN_K_LIST) then
            do k = 1, lst%n_items
              entry = dyn_list_at(lst, k)
              call hook_particles_line( &
                py_str(gvd(entry, "name", dyn_str("particles"))), &
                entry, line)
              if (len(line) > 0) call char_list_append(lines, line)
            end do
          end if
          block
            type(dyn) :: keys
            integer :: e
            keys = gv(wb, "keys")
            if (keys%kind == DYN_K_DICT) then
              do e = 1, keys%n_entries
                call hook_track_lines(dyn_key_of(keys, e), &
                  dyn_dict_value_copy(keys, e), lines)
              end do
            end if
          end block
        end if
      end block
    end if

    ! Wave C: ortho camera (EXT), post chain (EXT), instances (inline).
    if (exts%kind == DYN_K_DICT) then
      block
        type(dyn) :: wc, camext, lst, entry, sc
        type(dyn) :: pc(3), rc(3)
        integer :: k
        real(real64) :: sx
        logical :: okf
        wc = gv(exts, "wavec")
        if (py_truthy(wc) .and. wc%kind == DYN_K_DICT) then
          camext = gv(wc, "camera")
          if (py_truthy(camext) .and. camext%kind == DYN_K_DICT) then
            if (py_str(gvd(camext, "type", dyn_str(""))) == "ortho") &
              call hook_camera_lines(camext, lines)
          end if
          if (py_truthy(gv(wc, "post"))) &
            call hook_post_lines(gv(wc, "post"), lines)
          lst = gv(wc, "instances")
          if (lst%kind == DYN_K_LIST) then
            do k = 1, lst%n_items
              entry = dyn_list_at(lst, k)
              call vec3_key(entry, "pos", "", &
                            [0.0_real64, 0.0_real64, 0.0_real64], pc)
              call vec3_key(entry, "rot", "", &
                            [0.0_real64, 0.0_real64, 0.0_real64], rc)
              sc = gv(entry, "scale")
              if (sc%kind == DYN_K_LIST) then
                block
                  type(dyn) :: vc(3)
                  call vec3_of(sc, dyn_real(1.0_real64), &
                               dyn_real(1.0_real64), &
                               dyn_real(1.0_real64), vc)
                  sc = dyn_copy(vc(1))
                end block
              end if
              if (sc%kind == DYN_K_NULL) sc = dyn_real(1.0_real64)
              call py_float(sc, sx, okf)
              if (.not. okf) sx = 0.0_real64
              line = "instance " // &
                py_str(gvd(entry, "name", dyn_str(""))) // " " // &
                py_str(gvd(entry, "source", dyn_str(""))) // " " // &
                fmt_vec(pc) // " " // fmt_vec(rc) // " " // &
                fmt_num(dyn_real(sx))
              call char_list_append(lines, line)
            end do
          end if
        end if
      end block
    end if

    ! Wave E: shader defs + bindings (EXT), morph/bone/skin (EXT).
    if (exts%kind == DYN_K_DICT) then
      block
        type(dyn) :: we
        we = gv(exts, "wavee")
        if (py_truthy(we) .and. we%kind == DYN_K_DICT) then
          if (py_truthy(gv(we, "shaders"))) &
            call hook_shader_lines(we, lines)
          if (py_truthy(gv(we, "morphs")) .or. &
              py_truthy(gv(we, "bones")) .or. &
              py_truthy(gv(we, "skins"))) &
            call hook_skin_lines(we, lines)
        end if
      end block
    end if

    text = join_lines(lines)
  end subroutine emit_scene_text

  !> Alias for emit_scene_text (Python emit_scene).
  subroutine emit_scene(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    call emit_scene_text(ir, text)
  end subroutine emit_scene

  ! ==================================================================
  ! 2. Standalone Fortran program (emit_fortran.emit_fortran_program)
  ! ==================================================================

  !> emit_fortran._f for a real64: "%.6f" trimmed, ".0" appended when
  !! integral, "_dp" suffixed.  (Python "%.6f" of inf/nan is
  !! "inf"/"nan", which then gains ".0" -- mirrored.)
  function f_real(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out, t
    character(len=512) :: buf
    integer :: i
    if (ieee_is_nan(x)) then
      t = "nan"
    else if (.not. ieee_is_finite(x)) then
      if (ieee_is_negative(x)) then
        t = "-inf"
      else
        t = "inf"
      end if
    else
      write (buf, "(F512.6)") x
      t = trim(adjustl(buf))
      i = len(t)
      do while (i > 0)
        if (t(i:i) /= "0") exit
        i = i - 1
      end do
      t = t(1:i)
      if (len(t) > 0) then
        if (t(len(t):len(t)) == ".") t = t(1:len(t) - 1)
      end if
      if (len(t) == 0 .or. t == "-0") t = "0"
    end if
    if (index(t, ".") == 0) t = t // ".0"
    out = t // "_dp"
  end function f_real

  !> emit_fortran._f(value): float(value), 0.0 where Python raises.
  function f_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    real(real64) :: x
    logical :: ok
    call py_float(v, x, ok)
    if (.not. ok) x = 0.0_real64
    out = f_real(x)
  end function f_of

  !> emit_fortran._f_vec.
  function f_vec(comp) result(out)
    type(dyn), intent(in) :: comp(3)
    character(len=:), allocatable :: out
    out = "vec3_create(" // f_of(comp(1)) // ", " // f_of(comp(2)) // &
          ", " // f_of(comp(3)) // ")"
  end function f_vec

  !> emit_fortran._f_str.
  function f_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    out = "'" // str_replace(s, "'", "''") // "'"
  end function f_str

  !> emit_fortran._f_array over a flat dyn list.
  function f_array(vals) result(out)
    type(dyn), intent(in) :: vals
    character(len=:), allocatable :: out
    integer :: i
    out = "["
    if (vals%kind == DYN_K_LIST) then
      do i = 1, vals%n_items
        if (i > 1) out = out // ", "
        out = out // f_of(dyn_list_at(vals, i))
      end do
    end if
    out = out // "]"
  end function f_array

  !> Flatten a list of point sequences into one flat dyn list
  !! ([c for point in path for c in point]).
  function flatten_points(pts) result(out)
    type(dyn), intent(in) :: pts
    type(dyn) :: out, point
    integer :: i, j
    out = dyn_list()
    if (pts%kind /= DYN_K_LIST) return
    do i = 1, pts%n_items
      point = dyn_list_at(pts, i)
      if (point%kind == DYN_K_LIST) then
        do j = 1, point%n_items
          call dyn_list_push(out, dyn_list_at(point, j))
        end do
      end if
    end do
  end function flatten_points

  !> emit_fortran._program_name.
  function program_name(ir) result(out)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable :: out, raw, stem
    type(dyn) :: nv
    integer :: i, c, lo, hi
    nv = gv(ir, "name")
    if (nv%kind == DYN_K_NULL) then
      raw = "untitled"
    else
      raw = py_str(nv)
    end if
    if (len(raw) == 0) raw = "untitled"
    allocate (character(len=len(raw)) :: stem)
    do i = 1, len(raw)
      c = iachar(raw(i:i))
      if ((c >= iachar("A") .and. c <= iachar("Z")) .or. &
          (c >= iachar("a") .and. c <= iachar("z")) .or. &
          (c >= iachar("0") .and. c <= iachar("9")) .or. &
          raw(i:i) == "_") then
        stem(i:i) = raw(i:i)
      else
        stem(i:i) = "_"
      end if
    end do
    ! str.strip("_"): strip leading/trailing underscores only.
    lo = 1
    hi = len(stem)
    do while (lo <= hi)
      if (stem(lo:lo) /= "_") exit
      lo = lo + 1
    end do
    do while (hi >= lo)
      if (stem(hi:hi) /= "_") exit
      hi = hi - 1
    end do
    if (lo > hi) then
      stem = "forge3d"
    else
      stem = stem(lo:hi)
    end if
    if (len(stem) > 0) then
      c = iachar(stem(1:1))
      if (c >= iachar("0") .and. c <= iachar("9")) &
        stem = "s_" // stem
    end if
    out = to_lower(stem) // "_scene"
  end function program_name

  !> emit_fortran._rgb_array.
  function rgb_array(ints, has) result(out)
    integer(int64), intent(in) :: ints(3)
    logical, intent(in) :: has
    character(len=:), allocatable :: out
    if (.not. has) then
      out = "[" // f_real(1.0_real64) // ", " // &
            f_real(1.0_real64) // ", " // f_real(1.0_real64) // "]"
    else
      out = "[" // &
        f_real(real(ints(1), real64) / 255.0_real64) // ", " // &
        f_real(real(ints(2), real64) / 255.0_real64) // ", " // &
        f_real(real(ints(3), real64) / 255.0_real64) // "]"
    end if
  end function rgb_array

  !> emit_fortran._material_call.
  function material_call(obj) result(out)
    type(dyn), intent(in) :: obj
    character(len=:), allocatable :: out, material, rgb
    integer(int64) :: ints(3)
    logical :: has
    material = to_lower(py_str(gvd(obj, "material", &
                                   dyn_str("lambert"))))
    call color_ints(gv2(obj, "color", "colour"), ints, has)
    rgb = rgb_array(ints, has)
    if (material == "basic") then
      out = "material_basic(" // rgb // ")"
    else if (material == "phong") then
      out = "material_phong(" // rgb // ", " // &
            f_real(32.0_real64) // ")"
    else if (.not. has) then
      out = "material_lambert(" // rgb // ", .true.)"
    else
      out = "material_lambert(" // rgb // ", .false.)"
    end if
  end function material_call

  !> emit_fortran._material_needs_palette_comment.
  logical function material_needs_palette_comment(obj)
    type(dyn), intent(in) :: obj
    character(len=:), allocatable :: material
    integer(int64) :: ints(3)
    logical :: has
    material = to_lower(py_str(gvd(obj, "material", &
                                   dyn_str("lambert"))))
    call color_ints(gv2(obj, "color", "colour"), ints, has)
    material_needs_palette_comment = &
      (material == "basic" .or. material == "phong") .and. &
      .not. has
  end function material_needs_palette_comment

  !> seg-or-default: Python `seg or def` (None and 0 both fall back).
  pure integer(int64) function seg_or(has_seg, seg, def)
    logical, intent(in) :: has_seg
    integer(int64), intent(in) :: seg, def
    if (has_seg .and. seg /= 0_int64) then
      seg_or = seg
    else
      seg_or = def
    end if
  end function seg_or

  !> A dyn that is dyn_real(def) when v is null, else v.
  function or_real(v, def) result(out)
    type(dyn), intent(in) :: v
    real(real64), intent(in) :: def
    type(dyn) :: out
    if (v%kind == DYN_K_NULL) then
      out = dyn_real(def)
    else
      out = dyn_copy(v)
    end if
  end function or_real

  !> emit_fortran._build_call; found=.false. for Python None.
  subroutine build_call(obj, prim, call_text, found)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: prim
    character(len=:), allocatable, intent(out) :: call_text
    logical, intent(out) :: found
    type(dyn) :: sizev, size3v, radv, hv, segv, geom, tv, pts
    type(dyn) :: s3(3)
    logical :: has_size3, has_seg, has_geom, okb
    integer(int64) :: seg, ring_seg, tube_seg
    character(len=:), allocatable :: capped
    real(real64) :: major
    type(dyn) :: flat

    call_text = ""
    found = .true.
    sizev = scalar_of(gv(obj, "size"))
    size3v = gv(obj, "size3")
    has_size3 = size3v%kind == DYN_K_LIST .and. size3v%n_items >= 3
    if (has_size3) then
      s3(1) = dyn_list_at(size3v, 1)
      s3(2) = dyn_list_at(size3v, 2)
      s3(3) = dyn_list_at(size3v, 3)
    end if
    if (sizev%kind == DYN_K_NULL .and. has_size3) &
      sizev = dyn_copy(s3(1))
    radv = gv(obj, "radius")
    hv = gv(obj, "height")
    segv = gv(obj, "segments")
    has_seg = segv%kind /= DYN_K_NULL
    seg = 0_int64
    if (has_seg) seg = int_or(segv, 0_int64)
    if (py_truthy(gvd(obj, "capped", dyn_bool(.true.)))) then
      capped = ".true."
    else
      capped = ".false."
    end if
    call geometry_of(obj, geom, has_geom)

    select case (prim)
    case ("cube")
      if (has_size3) then
        call_text = "call create_box(msh, " // f_of(s3(1)) // ", " // &
                    f_of(s3(2)) // ", " // f_of(s3(3)) // ")"
      else
        call_text = "call create_cube(msh, " // &
                    f_of(or_real(sizev, 2.0_real64)) // ")"
      end if
    case ("box")
      if (has_size3) then
        call_text = "call create_box(msh, " // f_of(s3(1)) // ", " // &
                    f_of(s3(2)) // ", " // f_of(s3(3)) // ")"
      else
        block
          type(dyn) :: edge
          edge = or_real(sizev, 2.0_real64)
          call_text = "call create_box(msh, " // f_of(edge) // ", " // &
                      f_of(edge) // ", " // f_of(edge) // ")"
        end block
      end if
    case ("sphere")
      call_text = "call create_sphere(msh, " // &
        f_of(or_real(radv, 1.0_real64)) // ", " // &
        fmt_int(seg_or(has_seg, seg, 16_int64)) // ")"
    case ("cylinder")
      call_text = "call create_cylinder(msh, " // &
        f_of(or_real(radv, 1.0_real64)) // ", " // &
        f_of(or_real(hv, 2.0_real64)) // ", " // &
        fmt_int(seg_or(has_seg, seg, 16_int64)) // ", " // &
        capped // ")"
    case ("cone")
      call_text = "call create_cone(msh, " // &
        f_of(or_real(radv, 1.0_real64)) // ", " // &
        f_of(or_real(hv, 2.0_real64)) // ", " // &
        fmt_int(seg_or(has_seg, seg, 16_int64)) // ", " // &
        capped // ")"
    case ("plane")
      if (has_size3) then
        call_text = "call create_plane(msh, " // f_of(s3(1)) // &
                    ", " // f_of(s3(3)) // ")"
      else
        block
          type(dyn) :: w
          w = or_real(sizev, 4.0_real64)
          call_text = "call create_plane(msh, " // f_of(w) // ", " // &
                      f_of(w) // ")"
        end block
      end if
    case ("pyramid")
      call_text = "call create_pyramid(msh, " // &
        f_of(or_real(sizev, 2.0_real64)) // ", " // &
        f_of(or_real(hv, 2.0_real64)) // ")"
    case ("torus")
      block
        type(dyn) :: majv, tubev, tsv
        real(real64) :: majx
        logical :: okf
        majv = or_real(radv, 1.5_real64)
        call py_float(majv, majx, okf)
        if (.not. okf) majx = 0.0_real64
        tubev = extension_of(obj, &
          ["tube        ", "tube_radius ", "minor_radius"])
        if (tubev%kind == DYN_K_NULL) &
          tubev = dyn_real(majx / 3.0_real64)
        ring_seg = seg_or(has_seg, seg, 24_int64)
        tsv = extension_of(obj, ["tube_segments", "rings        "])
        if (tsv%kind /= DYN_K_NULL) then
          tube_seg = int_or(tsv, 0_int64)
        else
          tube_seg = max(3_int64, ring_seg / 2_int64)
        end if
        call_text = "call create_torus(msh, " // f_of(majv) // ", " // &
          f_of(tubev) // ", " // fmt_int(ring_seg) // ", " // &
          fmt_int(tube_seg) // ")"
      end block
    case ("circle")
      call_text = "call create_circle(msh, " // &
        f_of(or_real(radv, 1.0_real64)) // ", " // &
        fmt_int(seg_or(has_seg, seg, 32_int64)) // ")"
    case ("ring")
      block
        type(dyn) :: innerv
        innerv = dyn_null()
        if (has_geom) innerv = gv(geom, "inner")
        if (innerv%kind == DYN_K_NULL) then
          if (sizev%kind /= DYN_K_NULL) then
            innerv = dyn_copy(sizev)
          else
            innerv = dyn_real(0.5_real64)
          end if
        end if
        call_text = "call create_ring(msh, " // &
          f_of(or_real(radv, 1.0_real64)) // ", " // f_of(innerv) // &
          ", " // fmt_int(seg_or(has_seg, seg, 32_int64)) // ")"
      end block
    case ("capsule")
      call_text = "call create_capsule(msh, " // &
        f_of(or_real(radv, 0.5_real64)) // ", " // &
        f_of(or_real(hv, 2.0_real64)) // ", " // &
        fmt_int(seg_or(has_seg, seg, 16_int64)) // ")"
    case ("tube")
      pts = dyn_null()
      if (has_geom) pts = gv(geom, "path")
      if (.not. py_truthy(pts)) &
        pts = extension_of(obj, ["path"])
      if (pts%kind /= DYN_K_LIST) pts = dyn_list()
      flat = flatten_points(pts)
      call_text = "call create_tube(msh, " // &
        f_of(or_real(radv, 0.2_real64)) // ", " // &
        fmt_int(seg_or(has_seg, seg, 12_int64)) // ", " // &
        f_array(flat) // ", " // &
        fmt_int(int(pts%n_items, int64)) // ")"
    case ("lathe")
      pts = dyn_null()
      if (has_geom) pts = gv(geom, "points")
      if (.not. py_truthy(pts)) &
        pts = extension_of(obj, ["points"])
      if (pts%kind /= DYN_K_LIST) pts = dyn_list()
      flat = flatten_points(pts)
      call_text = "call create_lathe(msh, " // &
        fmt_int(seg_or(has_seg, seg, 24_int64)) // ", " // &
        f_array(flat) // ", " // &
        fmt_int(int(pts%n_items, int64)) // ")"
    case ("extrude")
      block
        type(dyn) :: depthv
        pts = dyn_null()
        if (has_geom) pts = gv(geom, "shape")
        if (.not. py_truthy(pts)) &
          pts = extension_of(obj, ["shape"])
        if (pts%kind /= DYN_K_LIST) pts = dyn_list()
        flat = flatten_points(pts)
        depthv = dyn_null()
        if (has_geom) depthv = gv(geom, "extrude_depth")
        if (depthv%kind == DYN_K_NULL) &
          depthv = or_real(hv, 0.5_real64)
        call_text = "call create_extrude(msh, " // f_of(depthv) // &
          ", " // f_array(flat) // ", " // &
          fmt_int(int(pts%n_items, int64)) // ")"
      end block
    case ("tetrahedron", "octahedron", "icosahedron", "dodecahedron")
      call_text = "call create_" // prim // "(msh, " // &
        f_of(or_real(radv, 1.0_real64)) // ")"
    case ("torusknot")
      block
        type(dyn) :: majv, tubev, tsv
        real(real64) :: majx
        logical :: okf
        majv = or_real(radv, 1.0_real64)
        call py_float(majv, majx, okf)
        if (.not. okf) majx = 0.0_real64
        tubev = dyn_null()
        if (has_geom) tubev = gv(geom, "tube")
        if (tubev%kind == DYN_K_NULL) then
          if (sizev%kind /= DYN_K_NULL) then
            tubev = dyn_copy(sizev)
          else
            tubev = dyn_real(majx * 0.3_real64)
          end if
        end if
        ring_seg = seg_or(has_seg, seg, 48_int64)
        tsv = dyn_null()
        if (has_geom) tsv = gv(geom, "tube_segments")
        if (tsv%kind /= DYN_K_NULL) then
          tube_seg = int_or(tsv, 0_int64)
        else
          tube_seg = max(6_int64, ring_seg / 4_int64)
        end if
        call_text = "call create_torusknot(msh, " // f_of(majv) // &
          ", " // f_of(tubev) // ", " // fmt_int(ring_seg) // ", " // &
          fmt_int(tube_seg) // ")"
      end block
    case default
      found = .false.
      call_text = ""
    end select
    if (.false.) print *, okb  ! silence unused dummy warning pattern
  end subroutine build_call

  ! ------------------------------------------------------------------
  ! Line wrapping (emit_fortran._wrap_fortran_line, limit 120)
  ! ------------------------------------------------------------------

  pure integer function lstrip_len(s)
    character(len=*), intent(in) :: s
    integer :: i
    lstrip_len = len(s)
    do i = 1, len(s)
      if (s(i:i) /= " " .and. s(i:i) /= achar(9)) then
        lstrip_len = i - 1
        return
      end if
    end do
    lstrip_len = len(s)
  end function lstrip_len

  function lstrip_s(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: n
    n = lstrip_len(s)
    if (n >= len(s)) then
      out = ""
    else
      out = s(n + 1:)
    end if
  end function lstrip_s

  !> Split on whitespace runs (Python str.split()).
  subroutine split_ws(s, parts)
    character(len=*), intent(in) :: s
    type(char_list), intent(inout) :: parts
    integer :: i, start
    call char_list_clear(parts)
    i = 1
    do while (i <= len(s))
      do while (i <= len(s))
        if (.not. (s(i:i) == " " .or. &
                   s(i:i) == achar(9) .or. &
                   s(i:i) == achar(10) .or. &
                   s(i:i) == achar(13))) exit
        i = i + 1
      end do
      if (i > len(s)) exit
      start = i
      do while (i <= len(s))
        if (s(i:i) == " " .or. &
            s(i:i) == achar(9) .or. &
            s(i:i) == achar(10) .or. &
            s(i:i) == achar(13)) exit
        i = i + 1
      end do
      call char_list_append(parts, s(start:i - 1))
    end do
  end subroutine split_ws

  !> True when s contains a character other than '!' and ' '
  !! (Python: bool(s.strip("! "))).
  pure logical function strip_bang_nonempty(s)
    character(len=*), intent(in) :: s
    integer :: i
    strip_bang_nonempty = .false.
    do i = 1, len(s)
      if (s(i:i) /= "!" .and. s(i:i) /= " ") then
        strip_bang_nonempty = .true.
        return
      end if
    end do
  end function strip_bang_nonempty

  !> Indices (1-based positions) of commas outside '...' strings.
  subroutine commas_outside_quotes(text, idxs)
    character(len=*), intent(in) :: text
    type(int_list), intent(inout) :: idxs
    logical :: in_string
    integer :: i
    if (allocated(idxs%items)) deallocate (idxs%items)
    idxs%n = 0
    idxs%cap = 0
    in_string = .false.
    i = 1
    do while (i <= len(text))
      if (in_string) then
        if (text(i:i) == "'") then
          if (i + 1 <= len(text)) then
            if (text(i + 1:i + 1) == "'") then
              i = i + 1
            else
              in_string = .false.
            end if
          else
            in_string = .false.
          end if
        end if
      else if (text(i:i) == "'") then
        in_string = .true.
      else if (text(i:i) == ",") then
        call int_list_append(idxs, int(i, int64))
      end if
      i = i + 1
    end do
  end subroutine commas_outside_quotes

  subroutine wrap_fortran_line(line, limit, out_lines)
    character(len=*), intent(in) :: line
    integer, intent(in) :: limit
    type(char_list), intent(inout) :: out_lines
    character(len=:), allocatable :: stripped, indent, remaining
    character(len=:), allocatable :: cont_indent, current, cand, word
    type(char_list) :: words
    type(int_list) :: commas
    integer :: i, cut, nsp
    logical :: found_cut

    if (len(line) <= limit) then
      call char_list_append(out_lines, line)
      return
    end if
    nsp = lstrip_len(line)
    indent = line(1:nsp)
    stripped = line(nsp + 1:)
    if (len(stripped) >= 1) then
      if (stripped(1:1) == "!") then
        call split_ws(stripped(2:), words)
        current = indent // "!"
        do i = 1, char_list_len(words)
          word = char_list_at(words, i)
          cand = current // " " // word
          if (len(cand) > limit .and. &
              strip_bang_nonempty(current)) then
            call char_list_append(out_lines, current)
            current = indent // "! " // word
          else
            current = cand
          end if
        end do
        call char_list_append(out_lines, current)
        return
      end if
    end if
    cont_indent = indent // "    "
    remaining = line
    do while (len(remaining) > limit)
      call commas_outside_quotes(remaining, commas)
      cut = 0
      do i = 1, commas%n
        ! Python: comma index i0 (0-based) kept when i0 + 3 <= limit;
        ! 1-based position p = i0 + 1, condition p + 2 <= limit.
        if (int_list_at(commas, i) + 2 <= limit) &
          cut = int(int_list_at(commas, i))
      end do
      if (cut > 0) then
        call char_list_append(out_lines, &
          remaining(1:cut) // " &")
        remaining = cont_indent // lstrip_s(remaining(cut + 1:))
        cycle
      end if
      ! Spaces fallback.
      cut = 0
      found_cut = .false.
      do i = 1, len(remaining)
        if (remaining(i:i) /= " ") cycle
        ! Python space index i0 = i - 1; conditions:
        !   cont_indent != remaining[:i0]  (prefix of length i-1)
        !   i0 + 2 <= limit  ->  i + 1 <= limit
        !   "'" not in remaining[:i0]
        if (i + 1 > limit) cycle
        if (i - 1 == len(cont_indent)) then
          if (remaining(1:i - 1) == cont_indent) cycle
        end if
        if (index(remaining(1:i - 1), "'") > 0) cycle
        cut = i
        found_cut = .true.
      end do
      if (found_cut) then
        call char_list_append(out_lines, &
          remaining(1:cut - 1) // " &")
        remaining = cont_indent // lstrip_s(remaining(cut + 1:))
        cycle
      end if
      ! Inside an over-long string literal.
      call char_list_append(out_lines, &
        remaining(1:limit - 1) // "&")
      remaining = cont_indent // "&" // remaining(limit:)
    end do
    call char_list_append(out_lines, remaining)
  end subroutine wrap_fortran_line

  ! ------------------------------------------------------------------
  ! emit_fortran_program proper
  ! ------------------------------------------------------------------

  subroutine emit_fortran_program(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    type(char_list) :: out, wrapped
    type(dyn) :: camera, objects, obj, lights, light
    type(dyn) :: comp(3), tcomp(3), scomp(3), ld(3)
    character(len=:), allocatable :: name, pname, prim, line, build
    character(len=:), allocatable :: modname
    integer(int64) :: width, height, bg(3)
    logical :: ok, found
    integer :: i, j, nmod
    character(len=16) :: mods(8)
    type(tri_list_t) :: tris
    real(real64) :: aspect

    pname = program_name(ir)
    width = int_or(gv(ir, "width"), 640_int64)
    height = int_or(gv(ir, "height"), 480_int64)
    block
      type(dyn) :: bgv
      bgv = gv2(ir, "bg", "background")
      call color_ints(bgv, bg, ok)
      if (.not. ok) bg = [25_int64, 25_int64, 35_int64]
    end block
    camera = gv(ir, "camera")
    if (height /= 0_int64) then
      aspect = real(width, real64) / real(height, real64)
    else
      aspect = 1.0_real64
    end if

    ! light_dir: first non-ambient light's direction.
    ld(1) = dyn_real(-0.5_real64)
    ld(2) = dyn_real(-1.0_real64)
    ld(3) = dyn_real(-0.7_real64)
    lights = gvd(ir, "lights", dyn_list())
    if (lights%kind == DYN_K_LIST) then
      do i = 1, lights%n_items
        light = dyn_list_at(lights, i)
        if (to_lower(py_str(gvd(light, "kind", &
                                dyn_str("directional")))) /= &
            "ambient") then
          block
            type(dyn) :: dv
            dv = gv2(light, "direction", "dir")
            call vec3_of(dv, ld(1), ld(2), ld(3), ld)
          end block
          exit
        end if
      end do
    end if

    call stamp_lines(ir, "!", out)
    call char_list_append(out, &
      "! Static frame 0 only: animation is rendered via the")
    call char_list_append(out, &
      "! .scene path (emit_scene_text / scene.f90 frame loop),")
    call char_list_append(out, "! not by this generated program.")
    call char_list_append(out, "program " // pname)
    call char_list_append(out, "    use math_3d")
    call char_list_append(out, "    use mesh_3d")
    call char_list_append(out, "    use camera_3d")
    call char_list_append(out, "    use material_3d")
    call char_list_append(out, "    use renderer_3d")
    ! Wave D geo modules actually used, first-use order.
    nmod = 0
    mods = ""
    objects = gvd(ir, "objects", dyn_list())
    if (objects%kind == DYN_K_LIST) then
      do i = 1, objects%n_items
        obj = dyn_list_at(objects, i)
        block
          type(dyn) :: pv
          character(len=:), allocatable :: p
          pv = gv2(obj, "prim", "primitive")
          if (pv%kind == DYN_K_NULL) then
            p = ""
          else
            p = to_lower(py_str(pv))
          end if
          modname = ""
          select case (p)
          case ("circle", "ring")
            modname = "geo_flat_3d"
          case ("capsule")
            modname = "geo_capsule_3d"
          case ("tube")
            modname = "geo_tube_3d"
          case ("lathe")
            modname = "geo_lathe_3d"
          case ("extrude")
            modname = "geo_extrude_3d"
          case ("tetrahedron", "octahedron", "icosahedron", &
                "dodecahedron")
            modname = "geo_poly_3d"
          case ("torusknot")
            modname = "geo_torusknot_3d"
          end select
          if (len(modname) > 0) then
            found = .false.
            do j = 1, nmod
              if (mods(j) == modname) found = .true.
            end do
            if (.not. found) then
              nmod = nmod + 1
              mods(nmod) = modname
            end if
          end if
        end block
      end do
    end if
    do i = 1, nmod
      call char_list_append(out, "    use " // trim(mods(i)))
    end do
    call char_list_append(out, "    implicit none")
    call char_list_append(out, "")
    call char_list_append(out, "    type(Mesh) :: msh")
    call char_list_append(out, "    type(Camera) :: cam")
    call char_list_append(out, "    type(FrameBuffer) :: fb")
    call char_list_append(out, "    type(mat4) :: model")
    call char_list_append(out, "    type(Material) :: mat")
    call char_list_append(out, "    type(vec3) :: light_dir")
    call char_list_append(out, "")
    call char_list_append(out, "    call framebuffer_init(fb, " // &
      fmt_int(width) // ", " // fmt_int(height) // ")")
    call char_list_append(out, "    call framebuffer_clear(fb, " // &
      fmt_int(bg(1)) // ", " // fmt_int(bg(2)) // ", " // &
      fmt_int(bg(3)) // ")")
    call vec3_key(camera, "pos", "position", &
                  [3.0_real64, 2.5_real64, 4.0_real64], comp)
    call vec3_key(camera, "target", "", &
                  [0.0_real64, 0.0_real64, 0.0_real64], tcomp)
    line = "    call camera_init(cam, " // f_vec(comp) // ", " // &
      f_vec(tcomp) // ", " // &
      f_of(gvd(camera, "fov", dyn_real(60.0_real64))) // ", " // &
      f_real(aspect) // ", " // &
      f_of(gvd(camera, "near", dyn_real(0.1_real64))) // ", " // &
      f_of(gvd(camera, "far", dyn_real(100.0_real64))) // ")"
    call char_list_append(out, line)
    call vec3_key(camera, "up", "", &
                  [0.0_real64, 1.0_real64, 0.0_real64], comp)
    if (.not. vec3_eq(comp, [0.0_real64, 1.0_real64, 0.0_real64])) &
      then
      call char_list_append(out, "    cam%up = " // f_vec(comp))
      call char_list_append(out, "    call camera_update_matrices(cam)")
    end if
    call char_list_append(out, "    light_dir = " // f_vec(ld))
    call char_list_append(out, "")

    if (objects%kind == DYN_K_LIST) then
      do i = 1, objects%n_items
        obj = dyn_list_at(objects, i)
        name = py_str(gvd(obj, "name", dyn_str("object")))
        block
          type(dyn) :: pv
          pv = gv2(obj, "prim", "primitive")
          if (pv%kind == DYN_K_NULL) then
            prim = "cube"
          else
            prim = to_lower(py_str(pv))
          end if
        end block
        call vec3_key(obj, "pos", "position", &
                      [0.0_real64, 0.0_real64, 0.0_real64], comp)
        call vec3_key(obj, "rotate", "rotation", &
                      [0.0_real64, 0.0_real64, 0.0_real64], tcomp)
        call vec3_key(obj, "scale", "", &
                      [1.0_real64, 1.0_real64, 1.0_real64], scomp)
        call char_list_append(out, "    ! object " // name // &
                              " (" // prim // ")")
        if (prim == "load") then
          block
            type(dyn) :: pv2
            character(len=:), allocatable :: src
            pv2 = gv2(obj, "source_file", "path")
            if (.not. py_truthy(pv2)) then
              src = "model.obj"
            else
              src = py_str(pv2)
            end if
            call char_list_append(out, &
              "    ! loadobj " // src // &
              " is loaded by the .scene path " // &
              "(scene.f90 / obj_loader); skipped here")
          end block
          call char_list_append(out, "")
          cycle
        end if
        if (prim == "tris") then
          call triangles_of(obj, tris)
          call char_list_append(out, &
            "    if (allocated(msh%triangles)) " // &
            "deallocate(msh%triangles)")
          call char_list_append(out, "    msh%num_triangles = " // &
            fmt_int(int(tris%n, int64)))
          call char_list_append(out, "    allocate(msh%triangles(" // &
            fmt_int(int(tris%n, int64)) // "))")
          do j = 1, tris%n
            block
              type(dyn) :: pc(3)
              character(len=:), allocatable :: verts_s
              integer :: a, b
              verts_s = ""
              do a = 1, 3
                do b = 1, 3
                  pc(b) = dyn_copy(tris%pts((j - 1) * 9 + &
                                            (a - 1) * 3 + b))
                end do
                if (a > 1) verts_s = verts_s // ", "
                verts_s = verts_s // f_vec(pc)
              end do
              call char_list_append(out, &
                "    msh%triangles(" // fmt_int(int(j, int64)) // &
                ")%v = [" // verts_s // "]")
              call char_list_append(out, &
                "    msh%triangles(" // fmt_int(int(j, int64)) // &
                ")%color = [" // fmt_int(tris%cols(1, j)) // ", " // &
                fmt_int(tris%cols(2, j)) // ", " // &
                fmt_int(tris%cols(3, j)) // "]")
              call char_list_append(out, &
                "    msh%triangles(" // fmt_int(int(j, int64)) // &
                ")%normal = compute_triangle_normal(" // &
                "msh%triangles(" // fmt_int(int(j, int64)) // &
                ")%v(1), msh%triangles(" // fmt_int(int(j, int64)) // &
                ")%v(2), msh%triangles(" // fmt_int(int(j, int64)) // &
                ")%v(3))")
            end block
          end do
        else
          call build_call(obj, prim, build, found)
          if (.not. found) then
            call char_list_append(out, &
              "    ! unknown primitive '" // prim // &
              "': cube fallback")
            block
              type(dyn) :: sv
              sv = scalar_of(gv(obj, "size"))
              if (.not. py_truthy(sv)) sv = dyn_real(2.0_real64)
              build = "call create_cube(msh, " // f_of(sv) // ")"
            end block
          end if
          call char_list_append(out, "    " // build)
        end if
        if (material_needs_palette_comment(obj)) then
          call char_list_append(out, &
            "    ! palette colour cannot show through " // &
            "basic/phong (use_tri_color=.false.): white used")
        end if
        call char_list_append(out, &
          "    mat = " // material_call(obj))
        call char_list_append(out, &
          "    model = mat4_compose_trs(" // f_vec(comp) // ", " // &
          f_vec(tcomp) // ", " // f_vec(scomp) // ")")
        call char_list_append(out, &
          "    call framebuffer_render_mesh_mat(fb, msh, model, " // &
          "cam, light_dir, mat)")
        call char_list_append(out, "")
      end do
    end if

    call char_list_append(out, &
      "    call framebuffer_save_ppm(fb, " // &
      f_str(output_path(ir)) // ")")
    call char_list_append(out, "end program " // pname)

    do i = 1, char_list_len(out)
      call wrap_fortran_line(char_list_at(out, i), 120, wrapped)
    end do
    text = join_lines(wrapped)
  end subroutine emit_fortran_program

  !> Alias for emit_fortran_program (Python emit_fortran).
  subroutine emit_fortran(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    call emit_fortran_program(ir, text)
  end subroutine emit_fortran

end module f3dc_emit_fortran
