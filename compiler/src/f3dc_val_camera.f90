! f3dc_val_camera dispatch + section.f90 -- Forge3D validator, camera dispatch + section family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_camera
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
  use f3dc_ext_cameras, only: extract_camera, validate_camera
  implicit none
  private
  public :: dispatch_ext_camera
  public :: val_sec_camera

contains

  !> DISPATCH(ext_cameras): extract_camera + validate_camera
  !! (E302 messages for ortho cameras).
  subroutine dispatch_ext_camera(ext_in, node, wavec)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(inout) :: wavec
    type(dyn) :: ext, tv
    type(char_list) :: msgs
    integer :: k
    call extract_camera(ext_in, ext)
    call validate_camera(ext, msgs)
    do k = 1, char_list_len(msgs)
      call verrn("E302", char_list_at(msgs, k), node)
    end do
    tv = dyn_dict_get(ext, "type")
    if (tv%kind == DYN_K_STR .and. tv%s == "ortho") &
      call dyn_dict_set(wavec, "camera", ext)
  end subroutine dispatch_ext_camera

  subroutine val_sec_camera()
    type(dyn) :: node, props, v
    real(real64) :: cam_pos(3), cam_look(3), cam_up(3)
    real(real64) :: fov, near, far
    ! ---- camera (E302) -------------------------------------------
    cam_pos = [3.0_real64, 2.5_real64, 4.0_real64]
    cam_look = [0.0_real64, 0.0_real64, 0.0_real64]
    cam_up = [0.0_real64, 1.0_real64, 0.0_real64]
    fov = 60.0_real64
    near = 0.1_real64
    far = 100.0_real64
    if (vs%has_camera) then
      call dyn_assign(node, vs%camera_node)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "at", "pos", &
                               "position", "eye"], v)
      call vec3_or(v, [3.0_real64, 2.5_real64, 4.0_real64], cam_pos)
      call vfield(node, props, [character(12) :: "look", "target", &
                               "look_at"], v)
      call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], cam_look)
      call vfield(node, props, [character(12) :: "up"], v)
      call vec3_or(v, [0.0_real64, 1.0_real64, 0.0_real64], cam_up)
      call vfield(node, props, [character(12) :: "fov"], v)
      block
        real(real64) :: x
        logical :: has
        call get_num(v, x, has)
        if (has) fov = x
        call vfield(node, props, [character(12) :: "near"], v)
        call get_num(v, x, has)
        if (has) near = x
        call vfield(node, props, [character(12) :: "far"], v)
        call get_num(v, x, has)
        if (has) far = x
      end block
      if (.not. finite_vec(cam_pos) .or. &
          .not. finite_vec(cam_look)) then
        call verrn("E302", "camera positions must be plain " // &
             "finite numbers", node)
      end if
      if (.not. (fov > 0.0_real64 .and. fov < 180.0_real64)) then
        call verrn("E302", "fov is " // rstr(fov) // &
             ", but a camera can only see between 0 and 180 " // &
             "degrees", node)
      end if
      if (.not. (ieee_is_finite(near) .and. near > 0.0_real64)) then
        call verrn("E302", "near is " // rstr(near) // &
             ", but it must be more than 0", node)
      end if
      if (.not. (ieee_is_finite(far) .and. far > near)) then
        call verrn("E302", "'far' (" // rstr(far) // &
             ") must be bigger than 'near' (" // rstr(near) // &
             ")", node)
      end if
      if (all(cam_pos == cam_look)) then
        call verrn("E401", "the camera is standing at the place " // &
             "it is looking at, so it cannot see anything", node)
      end if
    end if
    vctx%ir_camera = dyn_dict()
    call dyn_dict_set(vctx%ir_camera, "pos", vec3_dyn(cam_pos))
    call dyn_dict_set(vctx%ir_camera, "target", vec3_dyn(cam_look))
    call dyn_dict_set(vctx%ir_camera, "up", vec3_dyn(cam_up))
    call dyn_dict_set(vctx%ir_camera, "fov", dyn_real(fov))
    call dyn_dict_set(vctx%ir_camera, "near", dyn_real(near))
    call dyn_dict_set(vctx%ir_camera, "far", dyn_real(far))
  end subroutine val_sec_camera

end module f3dc_val_camera
