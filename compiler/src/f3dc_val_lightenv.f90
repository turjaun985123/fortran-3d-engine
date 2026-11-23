! f3dc_val_light/env dispatch + sections.f90 -- Forge3D validator, light/env dispatch + sections family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_lightenv
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
  use f3dc_ext_lights_env, only: extract_light_ext, &
       validate_light_ext, extract_env, validate_env
  implicit none
  private
  public :: dispatch_ext_light
  public :: dispatch_ext_env
  public :: val_sec_lights
  public :: val_sec_env

contains

  !> DISPATCH(ext_lights_env): extract_light_ext +
  !! validate_light_ext (E302 messages for point/spot lights).
  subroutine dispatch_ext_light(kind, ext_in, node)
    character(*), intent(in) :: kind
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node
    type(dyn) :: ext
    type(char_list) :: msgs
    integer :: j
    call extract_light_ext(ext_in, ext)
    call validate_light_ext(kind, ext, msgs)
    do j = 1, char_list_len(msgs)
      call verrn("E302", char_list_at(msgs, j), node)
    end do
    call dyn_assign(ext_in, ext)
  end subroutine dispatch_ext_light


  !> DISPATCH(ext_lights_env): extract_env + validate_env
  !! (E302 messages for scene fog/tonemap/shadow clauses).
  subroutine dispatch_ext_env(env_in)
    type(dyn), intent(in) :: env_in
    type(dyn) :: env
    type(char_list) :: msgs
    integer :: j
    call extract_env(env_in, env)
    call validate_env(env, msgs)
    do j = 1, char_list_len(msgs)
      call verr("E302", char_list_at(msgs, j))
    end do
    call set_scene_extension("env", env)
  end subroutine dispatch_ext_env

  subroutine val_sec_lights()
    type(dyn) :: node, props, v, ir_light, ext_in
    character(:), allocatable :: lkind
    real(real64) :: direction(3), intensity
    integer :: lrgb(3)
    logical :: has_lrgb, is_default_light
    integer :: k
    ! ---- lights (E302 / E205) -------------------------------------
    do k = 0, max(dyn_list_len(vs%light_nodes), 1) - 1
      is_default_light = dyn_list_len(vs%light_nodes) == 0
      if (is_default_light) then
        lkind = "directional"
        direction = [-0.5_real64, -1.0_real64, -0.7_real64]
        intensity = 1.0_real64
        lrgb = [255, 255, 255]
      else
        node = dyn_list_at(vs%light_nodes, k + 1)
        props = props_of(node)
        call vfield(node, props, [character(12) :: "kind", &
             "type", "mode"], v)
        if (v%kind == DYN_K_NULL) then
          lkind = "directional"
        else
          lkind = to_lower(py_str(v))
        end if
        if (.not. in_words(lkind, LIGHT_KINDS_V1)) then
          call verrn("E205", "light " // repr_str(lkind) // &
               " is not built yet; lights are: " // &
               join_words(LIGHT_KINDS_V1), node)
          cycle
        end if
        if (lkind == "point" .or. lkind == "spot") then
          ext_in = dyn_dict()
          call vfield(node, props, [character(12) :: "at", &
                                   "position"], v)
          call dyn_dict_set(ext_in, "at", v)
          call vfield(node, props, [character(12) :: "look", &
               "target", "look_at"], v)
          call dyn_dict_set(ext_in, "look", v)
          call vfield(node, props, [character(12) :: "distance"], v)
          call dyn_dict_set(ext_in, "distance", v)
          call vfield(node, props, [character(12) :: "decay"], v)
          call dyn_dict_set(ext_in, "decay", v)
          call vfield(node, props, [character(12) :: "angle"], v)
          call dyn_dict_set(ext_in, "angle", v)
          call vfield(node, props, [character(12) :: "penumbra"], v)
          call dyn_dict_set(ext_in, "penumbra", v)
          ! DISPATCH(ext_lights_env): extract_light_ext builds the
          ! payload; validate_light_ext's messages are E302 here.
          call dispatch_ext_light(lkind, ext_in, node)
        end if
        call vfield(node, props, [character(12) :: "dir", &
             "direction", "from", "position"], v)
        call vec3_or(v, [-0.5_real64, -1.0_real64, -0.7_real64], &
             direction)
        call vfield(node, props, [character(12) :: "intensity", &
                                  "strength"], v)
        block
          logical :: has
          call get_num(v, intensity, has)
          if (.not. has) intensity = 1.0_real64
        end block
        call vfield(node, props, [character(12) :: "color", &
                                  "colour"], v)
        if (v%kind /= DYN_K_NULL) then
          call parse_color_val(v, node, lrgb, has_lrgb)
          if (.not. has_lrgb) lrgb = [255, 255, 255]
        else
          lrgb = [255, 255, 255]
        end if
        if (lkind == "directional" .and. &
            (.not. finite_vec(direction) .or. &
             all(direction == 0.0_real64))) then
          call verrn("E302", "a light direction of 0 0 0 points " // &
               "nowhere", node)
        end if
        if (.not. ieee_is_finite(intensity) .or. &
            intensity < 0.0_real64 .or. &
            intensity > 100.0_real64) then
          call verrn("E302", "light intensity is " // &
               rstr(intensity) // ", but it must be 0 to 100", node)
        end if
      end if
      ir_light = dyn_dict()
      call dyn_dict_set(ir_light, "kind", dyn_str(lkind))
      call dyn_dict_set(ir_light, "direction", vec3_dyn(direction))
      call dyn_dict_set(ir_light, "color", rgb_dyn(lrgb))
      call dyn_dict_set(ir_light, "intensity", dyn_real(intensity))
      if (lkind == "point" .or. lkind == "spot") then
        ! Wave A payload rides on the IR light (ext_in now holds
        ! the extract_light_ext product; see dispatch_ext_light).
        block
          integer :: q
          character(12) :: pkeys(6)
          pkeys = [character(12) :: "position", "target", &
                   "distance", "decay", "angle", "penumbra"]
          do q = 1, 6
            call dyn_dict_set(ir_light, trim(pkeys(q)), &
                 dyn_dict_get(ext_in, trim(pkeys(q))))
          end do
        end block
      end if
      call dyn_list_push(vs%ir_lights, ir_light)
    end do
  end subroutine val_sec_lights

  subroutine val_sec_env()
    integer :: k
    ! ---- Wave A environment clauses --------------------------------
    if (dyn_dict_len(vs%env_props) > 0) then
      block
        type(dyn) :: stripped, ev
        character(:), allocatable :: key, first, rest
        integer :: sp
        stripped = dyn_dict()
        do k = 1, dyn_dict_len(vs%env_props)
          key = dyn_dict_key_at(vs%env_props, k)
          ev = dyn_dict_value_at(vs%env_props, k)
          if (ev%kind == DYN_K_STR) then
            ! value.split(None, 1): first word + remainder.
            block
              character(:), allocatable :: t
              t = strip_ws(ev%s)
              sp = 0
              do sp = 1, len(t)
                if (is_ws(t(sp:sp))) exit
              end do
              if (sp > len(t)) then
                first = t
                rest = ""
              else
                first = t(1:sp - 1)
                rest = strip_ws(t(sp:))
              end if
              if (in_words(to_lower(first), [character(12) :: &
                   "fog", "tonemap", "tone", "shadow", &
                   "antialias"])) then
                ev = dyn_str(rest)
              end if
            end block
          end if
          call dyn_dict_set(stripped, key, ev)
        end do
        ! DISPATCH(ext_lights_env): extract_env + validate_env
        ! (E302 messages, span-less in Python).
        call dispatch_ext_env(stripped)
      end block
    end if
  end subroutine val_sec_env

end module f3dc_val_lightenv
