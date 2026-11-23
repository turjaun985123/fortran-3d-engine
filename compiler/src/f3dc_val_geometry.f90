! f3dc_val_geometry.f90 -- Forge3D validator, geometry family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_geometry
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite, &
       ieee_value, ieee_quiet_nan, ieee_positive_inf
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, &
       dyn_real, dyn_str, dyn_list, dyn_dict, dyn_copy, &
       dyn_assign, dyn_list_push, dyn_list_len, dyn_list_at, &
       dyn_dict_get, dyn_dict_set, dyn_dict_has, dyn_dict_len, &
       dyn_dict_key_at, dyn_dict_value_at, DYN_K_NULL, &
       DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_val_common
  use f3dc_str, only: to_lower, fmt_int, fmt_real, &
       char_list, char_list_len, char_list_at, char_list_clear
  use f3dc_ext_geometry, only: eg_estimate => estimate_triangles, &
       eg_normalize => normalize_geometry, &
       eg_validate => validate_geometry
  implicit none
  private
  public :: field_from
  public :: estimate_triangles
  public :: detail_preset
  public :: count_obj_triangles
  public :: dispatch_ext_geometry_estimate
  public :: dispatch_ext_geometry

contains

  ! ================================================================
  ! Triangle estimate (validate.py _estimate_triangles /
  ! _field_from) + .obj face counter (_count_obj_triangles)
  ! ================================================================

  subroutine field_from(props, names, val)
    type(dyn), intent(in) :: props
    character(*), intent(in) :: names(:)
    type(dyn), intent(out) :: val
    call vget(props, names, val)
  end subroutine field_from


  function estimate_triangles(prim, props) result(total)
    character(*), intent(in) :: prim
    type(dyn), intent(in) :: props
    integer(int64) :: total
    type(dyn) :: v
    integer(int64) :: segments, rings, sides, cnt
    logical :: has_s, has_r, has_detail
    character(:), allocatable :: detail
    logical :: capped
    total = 0_int64
    if (in_words(prim, GEOM_PRIMS)) then
      ! DISPATCH(ext_geometry): estimate_triangles(prim, props)
      ! replaces this 0 when f3dc_ext_geometry lands.
      total = dispatch_ext_geometry_estimate(prim, props)
      return
    end if
    call field_from(props, [character(16) :: "segments"], v)
    call get_int(v, segments, has_s)
    if (.not. has_s) segments = 0_int64
    call field_from(props, [character(16) :: "rings", &
                            "height_segments", "height_segs"], v)
    call get_int(v, rings, has_r)
    if (.not. has_r) rings = 0_int64
    v = dyn_dict_get(props, "detail")
    has_detail = v%kind == DYN_K_STR
    if (has_detail) then
      detail = to_lower(v%s)
      block
        integer(int64) :: ps, pr
        logical :: found
        call detail_preset(prim == "torus", detail, ps, pr, found)
        if (found) then
          if (.not. has_s) then
            segments = ps
            has_s = .true.
          end if
          if (.not. has_r) then
            rings = pr
            has_r = .true.
          end if
        end if
      end block
    end if
    ! capped = not props.get("open") and props.get("capped", True)
    ! is not False   (identity check against the False singleton)
    capped = .not. py_truthy(dyn_dict_get(props, "open"))
    v = dyn_dict_get(props, "capped")
    if (v%kind == DYN_K_BOOL .and. .not. v%b) capped = .false.
    select case (prim)
    case ("cube")
      total = 12_int64
    case ("sphere")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 12_int64
      total = 2_int64 * segments * max(rings - 1_int64, 1_int64)
    case ("cylinder")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 1_int64
      total = 2_int64 * segments * rings
      if (capped) total = total + 2_int64 * segments
    case ("cone")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 1_int64
      total = segments * (2_int64 * rings - 1_int64)
      if (capped) total = total + segments
    case ("plane")
      if (.not. has_s .or. segments == 0_int64) segments = 1_int64
      call get_int(dyn_dict_get(props, "depth_segments"), cnt, has_s)
      if (.not. has_s .or. cnt == 0_int64) cnt = segments
      total = 4_int64 * segments * cnt
    case ("pyramid")
      call get_int(dyn_dict_get(props, "sides"), sides, has_s)
      if (.not. has_s .or. sides == 0_int64) sides = 4_int64
      total = max(2_int64 * sides - 2_int64, 0_int64)
    case ("torus")
      if (.not. has_s .or. segments == 0_int64) segments = 16_int64
      if (.not. has_r .or. rings == 0_int64) rings = 12_int64
      total = 2_int64 * segments * rings
    case ("tris")
      v = dyn_dict_get(props, "tris")
      if (.not. py_truthy(v)) v = dyn_dict_get(props, "triangles")
      if (v%kind == DYN_K_LIST) then
        total = int(dyn_list_len(v), int64)
        return
      end if
      ! Python: _int(props.get("tri_count", props.get("count"))) --
      ! the default only applies when the key is absent entirely.
      if (dyn_dict_has(props, "tri_count")) then
        v = dyn_dict_get(props, "tri_count")
      else
        v = dyn_dict_get(props, "count")
      end if
      call get_int(v, cnt, has_s)
      if (has_s) total = cnt
    case ("load")
      call get_int(dyn_dict_get(props, "_load_tris"), cnt, has_s)
      if (has_s) total = cnt
    end select
  end function estimate_triangles


  !> Detail presets -> (segments, rings): validate._DETAIL /
  !! _DETAIL_TORUS.
  subroutine detail_preset(is_torus, detail, ps, pr, found)
    logical, intent(in) :: is_torus
    character(*), intent(in) :: detail
    integer(int64), intent(out) :: ps, pr
    logical, intent(out) :: found
    found = .true.
    ps = 0_int64
    pr = 0_int64
    if (is_torus) then
      select case (detail)
      case ("low")
        ps = 10_int64; pr = 8_int64
      case ("med", "medium")
        ps = 16_int64; pr = 12_int64
      case ("high")
        ps = 32_int64; pr = 24_int64
      case default
        found = .false.
      end select
    else
      select case (detail)
      case ("low")
        ps = 8_int64; pr = 6_int64
      case ("med", "medium")
        ps = 16_int64; pr = 12_int64
      case ("high")
        ps = 32_int64; pr = 24_int64
      case default
        found = .false.
      end select
    end if
  end subroutine detail_preset


  !> validate._count_obj_triangles: face count for a loaded .obj
  !! (lines starting with 'f '; each contributes max(words-3, 1)).
  function count_obj_triangles(path) result(total)
    character(*), intent(in) :: path
    integer(int64) :: total
    integer :: unit, ios, words, k
    character(65536) :: line
    logical :: in_word
    total = 0_int64
    open (newunit=unit, file=path, status="old", action="read", &
          iostat=ios)
    if (ios /= 0) return
    do
      read (unit, "(A)", iostat=ios) line
      if (ios /= 0) exit
      if (len_trim(line) >= 2 .and. line(1:2) == "f ") then
        words = 0
        in_word = .false.
        do k = 1, len_trim(line)
          if (is_ws(line(k:k))) then
            in_word = .false.
          else if (.not. in_word) then
            in_word = .true.
            words = words + 1
          end if
        end do
        total = total + int(max(words - 3, 1), int64)
      end if
    end do
    close (unit)
  end function count_obj_triangles



  ! ================================================================
  ! Extension dispatch points (see the header list).  Each stub is
  ! the exact call site of the Python ext_* function named; the
  ! extension batch replaces the stub body with the real port.
  ! Until then the stub contributes no diagnostics and no payload,
  ! which matches the Python oracle on every input the ext check
  ! accepts silently.
  ! ================================================================

  !> DISPATCH(ext_geometry): ext_geometry.estimate_triangles.
  function dispatch_ext_geometry_estimate(prim, props) result(n)
    character(*), intent(in) :: prim
    type(dyn), intent(in) :: props
    integer(int64) :: n
    n = eg_estimate(prim, props)
    if (len(prim) < 0) continue  ! silence warnings
  end function dispatch_ext_geometry_estimate


  !> DISPATCH(ext_geometry): normalize_geometry + validate_geometry
  !! (E301 messages + IR folding of radius/size/height/segments).
  subroutine dispatch_ext_geometry(prim, props, node, geom, &
      radius, has_radius, size, has_size, obj_height, has_height, &
      segments, has_segments)
    character(*), intent(in) :: prim
    type(dyn), intent(in) :: props, node
    type(dyn), intent(out) :: geom
    real(real64), intent(inout) :: radius, size, obj_height
    logical, intent(inout) :: has_radius, has_size, has_height, &
         has_segments
    integer(int64), intent(inout) :: segments
    type(char_list) :: codes, messages
    type(dyn) :: v
    integer :: k
    geom = eg_normalize(prim, props)
    call eg_validate(prim, props, geom, codes, messages)
    do k = 1, char_list_len(codes)
      call verrn(char_list_at(codes, k), &
                 char_list_at(messages, k), node)
    end do
    call char_list_clear(codes); call char_list_clear(messages)
    v = dyn_dict_get(geom, "radius")
    if (v%kind /= DYN_K_NULL) call get_num(v, radius, has_radius)
    if (prim == "ring") then
      v = dyn_dict_get(geom, "inner")
      call get_num(v, size, has_size)
    end if
    if (prim == "torusknot") then
      v = dyn_dict_get(geom, "tube")
      call get_num(v, size, has_size)
    end if
    if (prim == "capsule" .or. prim == "extrude") then
      v = dyn_dict_get(geom, "height")
      call get_num(v, obj_height, has_height)
    end if
    v = dyn_dict_get(geom, "segments")
    if (v%kind /= DYN_K_NULL) &
      call get_int(v, segments, has_segments)
  end subroutine dispatch_ext_geometry

end module f3dc_val_geometry
