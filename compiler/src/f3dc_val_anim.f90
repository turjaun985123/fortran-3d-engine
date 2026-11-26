! f3dc_val_animation section.f90 -- Forge3D validator, animation section family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_anim
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
  implicit none
  private
  public :: val_sec_anims

contains
  subroutine val_sec_anims()
    type(dyn) :: node, props, v, ir_anim
    integer :: k
    ! ---- animations (E201 / E303) ----------------------------------
    do k = 1, dyn_list_len(vs%anim_nodes)
      node = dyn_list_at(vs%anim_nodes, k)
      props = props_of(node)
      block
        type(dyn) :: kind_raw, targetv, axisv, easev, loopv
        character(:), allocatable :: akind, target, axis_s, ease_s
        real(real64) :: speed, duration
        logical :: has_speed, has_duration
        real(real64) :: anim_start
        logical :: has_anim_start
        integer(int64) :: fps
        logical :: has_fps
        call vfield(node, props, [character(12) :: "kind", &
             "motion", "action", "type"], kind_raw)
        if (kind_raw%kind == DYN_K_NULL) then
          akind = ""
        else
          akind = to_lower(strip_ws(py_str(kind_raw)))
        end if
        ! ANIM Wave 1 (ANIM-PLAN SS2.2/SS2.4): a timeline-resolved
        ! AnimStmt carries a fields-bag `start`; such anims may use
        ! the sentence verbs (ANIM_KINDS_EXT) beyond the legacy
        ! ANIM_KINDS.  Legacy anims (no `start`) keep the legacy
        ! rule and message, unchanged.
        anim_start = 0.0_real64
        has_anim_start = .false.
        block
          type(dyn) :: startv
          call vfield(node, props, [character(12) :: "start"], &
                      startv)
          call get_num(startv, anim_start, has_anim_start)
        end block
        if (.not. in_words(akind, ANIM_KINDS)) then
          if (.not. (has_anim_start .and. &
               in_words(akind, ANIM_KINDS_EXT))) then
            call verrn("E201", "animation kind " // &
                 py_repr(kind_raw) // &
                 " is missing or unknown; v1 has: " // &
                 join_words(ANIM_KINDS), node)
            cycle
          end if
        end if
        call vfield(node, props, [character(12) :: "target", &
             "target_name", "object", "name"], targetv)
        if (targetv%kind == DYN_K_NULL) then
          target = "it"
        else
          target = py_str(targetv)
        end if
        if (target == "it" .or. target == "last") then
          if (.not. vs%has_last_obj) then
            call verrn("E201", repr_str(akind) // &
                 " has nothing to animate; there is no object " // &
                 "before it", node)
            cycle
          end if
          target = vs%last_obj_name
        else if (target /= "all" .and. &
                 .not. dyn_dict_has(vs%names, target)) then
          ! ANIM Wave 1: for a timeline-resolved anim the unknown-
          ! target diagnostic is E209, raised by the timeline
          ! section (ANIM-PLAN SS2.4 keeps E201 for plain anim/key
          ! targets); do not double-report it here.
          if (.not. has_anim_start) then
            call verrn("E201", akind // " targets " // &
                 repr_str(target) // &
                 ", but no object is called that", node)
            cycle
          end if
        end if
        call vfield(node, props, [character(12) :: "axis"], axisv)
        if (axisv%kind /= DYN_K_NULL) then
          axis_s = to_lower(py_str(axisv))
          if (axis_s /= "x" .and. axis_s /= "y" .and. &
              axis_s /= "z") then
            call verrn("E303", "axis " // py_repr(axisv) // &
                 " is not one of x, y, z", node)
          end if
        else
          axis_s = "y"
        end if
        call vfield(node, props, [character(12) :: "speed"], v)
        call get_num(v, speed, has_speed)
        if (has_speed .and. (.not. ieee_is_finite(speed) .or. &
            abs(speed) > MAX_SPEED)) then
          call verrn("E303", "speed is " // rstr(speed) // &
               ", but it must be between -" // &
               istr(int(MAX_SPEED, int64)) // " and " // &
               istr(int(MAX_SPEED, int64)), node)
        end if
        call vfield(node, props, [character(12) :: "duration"], v)
        call get_num(v, duration, has_duration)
        if (has_duration .and. (.not. ieee_is_finite(duration) &
            .or. duration <= 0.0_real64 .or. &
            duration > MAX_DURATION)) then
          call verrn("E303", "duration is " // rstr(duration) // &
               ", but it must be more than 0 and at most " // &
               istr(int(MAX_DURATION, int64)) // " seconds", node)
        end if
        call vfield(node, props, [character(12) :: "fps"], v)
        call get_int(v, fps, has_fps)
        if (has_fps .and. (fps < MIN_FPS .or. fps > MAX_FPS)) then
          call verrn("E303", "fps is " // istr(fps) // &
               ", but it must be " // istr(MIN_FPS) // " to " // &
               istr(MAX_FPS), node)
        end if
        call vfield(node, props, [character(12) :: "ease"], easev)
        if (easev%kind /= DYN_K_NULL) then
          ease_s = to_lower(py_str(easev))
          if (.not. in_words(ease_s, EASES)) then
            call verrn("E201", "there is no easing called " // &
                 py_repr(easev), node)
          end if
        else
          ease_s = "linear"
        end if
        call vfield(node, props, [character(12) :: "loop", &
                                  "loop_mode"], loopv)
        ir_anim = dyn_dict()
        call dyn_dict_set(ir_anim, "kind", dyn_str(akind))
        call dyn_dict_set(ir_anim, "target", dyn_str(target))
        call dyn_dict_set(ir_anim, "axis", dyn_str(axis_s))
        if (has_speed) then
          call dyn_dict_set(ir_anim, "speed", dyn_real(speed))
        else
          call dyn_dict_set(ir_anim, "speed", &
               dyn_real(90.0_real64))
        end if
        if (has_duration) then
          call dyn_dict_set(ir_anim, "duration", dyn_real(duration))
        else
          call dyn_dict_set(ir_anim, "duration", &
               dyn_real(5.0_real64))
        end if
        if (has_fps) then
          call dyn_dict_set(ir_anim, "fps", dyn_int(fps))
        else
          call dyn_dict_set(ir_anim, "fps", dyn_int(30_int64))
        end if
        call dyn_dict_set(ir_anim, "ease", dyn_str(ease_s))
        if (loopv%kind /= DYN_K_NULL) then
          call dyn_dict_set(ir_anim, "loop", loopv)
        else
          call dyn_dict_set(ir_anim, "loop", dyn_str("forever"))
        end if
        ! ANIM Wave 1: ir_anim `start` (ANIM-PLAN SS2.2).  Set only
        ! when the resolved anim carries one and it is non-zero --
        ! f3dc_ir's ir_anim_to_dict likewise omits a zero start, so
        ! non-timeline scenes stay byte-stable.
        if (has_anim_start) then
          if (anim_start /= 0.0_real64) &
            call dyn_dict_set(ir_anim, "start", &
                 dyn_real(anim_start))
        end if
        call dyn_list_push(vs%ir_anims, ir_anim)
      end block
    end do
  end subroutine val_sec_anims

end module f3dc_val_anim
