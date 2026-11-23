! f3dc_val_controls/output sections.f90 -- Forge3D validator, controls/output sections family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_output
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
  public :: val_sec_controls
  public :: val_sec_outputs

contains
  subroutine val_sec_controls()
    type(dyn) :: node, props, v
    character(:), allocatable :: controls_kind
    ! ---- controls (E201 / E205 / E302) ------------------------------
    controls_kind = ""
    if (vs%has_controls) then
      call dyn_assign(node, vs%controls_node)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "kind", "type", &
                               "mode"], v)
      if (v%kind == DYN_K_NULL) then
        controls_kind = "orbit"
      else
        controls_kind = to_lower(py_str(v))
      end if
      if (.not. in_words(controls_kind, CONTROLS_KINDS)) then
        call verrn("E205", "controls " // repr_str(controls_kind) &
             // " are not built yet; v1 has orbit and none", node)
      end if
      block
        real(real64) :: cmin, cmax
        logical :: has_min, has_max
        call vfield(node, props, [character(12) :: "min"], v)
        call get_num(v, cmin, has_min)
        call vfield(node, props, [character(12) :: "max"], v)
        call get_num(v, cmax, has_max)
        if (has_min .and. has_max .and. cmin >= cmax) then
          call verrn("E302", "controls min (" // rstr(cmin) // &
               ") must be smaller than max (" // rstr(cmax) // &
               ")", node)
        end if
      end block
    end if
  end subroutine val_sec_controls

  subroutine val_sec_outputs()
    type(dyn) :: node, props, v, ir_output
    integer :: k
    ! ---- outputs (E301) ----------------------------------------------
    do k = 1, dyn_list_len(vs%output_nodes)
      node = dyn_list_at(vs%output_nodes, k)
      props = props_of(node)
      block
        type(dyn) :: fmtv, pathv, sizev
        character(:), allocatable :: fmt, ekind
        integer(int64) :: ow, oh
        logical :: has_ow, has_oh
        call vfield(node, props, [character(12) :: "format", &
             "kind", "type"], fmtv)
        if (fmtv%kind == DYN_K_NULL) then
          fmt = "render"
        else
          fmt = to_lower(py_str(fmtv))
        end if
        call vfield(node, props, [character(12) :: "path", &
             "file", "to", "output", "filename"], pathv)
        call vfield(node, props, [character(12) :: "width", "w"], v)
        call get_int(v, ow, has_ow)
        call vfield(node, props, [character(12) :: "height", &
                                  "h"], v)
        call get_int(v, oh, has_oh)
        call vfield(node, props, [character(12) :: "size"], sizev)
        if (sizev%kind == DYN_K_LIST .and. &
            dyn_list_len(sizev) >= 2) then
          block
            integer(int64) :: sw, sh
            logical :: okw, okh
            call get_int(dyn_list_at(sizev, 1), sw, okw)
            if (okw) then
              ow = sw
              has_ow = .true.
            end if
            call get_int(dyn_list_at(sizev, 2), sh, okh)
            if (okh) then
              oh = sh
              has_oh = .true.
            end if
          end block
        end if
        if (fmt == "export" .or. in_words(fmt, EXPORT_KINDS)) then
          if (in_words(fmt, EXPORT_KINDS)) then
            ekind = fmt
          else
            call vfield(node, props, [character(12) :: &
                         "export_kind"], v)
            if (v%kind == DYN_K_NULL) then
              ekind = "json"
            else
              ekind = to_lower(py_str(v))
            end if
          end if
          ir_output = dyn_dict()
          call dyn_dict_set(ir_output, "kind", dyn_str("export"))
          call dyn_dict_set(ir_output, "path", pathv)
          call dyn_dict_set(ir_output, "format", dyn_str(ekind))
          if (has_ow) then
            call dyn_dict_set(ir_output, "width", dyn_int(ow))
          else
            call dyn_dict_set(ir_output, "width", dyn_null())
          end if
          if (has_oh) then
            call dyn_dict_set(ir_output, "height", dyn_int(oh))
          else
            call dyn_dict_set(ir_output, "height", dyn_null())
          end if
          call dyn_list_push(vs%ir_outputs, ir_output)
          cycle
        end if
        if (pathv%kind /= DYN_K_NULL) then
          if (.not. in_words(path_ext_lower(py_str(pathv)), &
               RENDER_EXTS)) then
            call verrn("E301", "a render can only be written " // &
                 "to .ppm or .png, not " // py_repr(pathv), node)
          end if
        end if
        call check_image_dim("render width", ow, has_ow, node)
        call check_image_dim("render height", oh, has_oh, node)
        block
          integer(int64) :: ofps
          logical :: has_ofps
          real(real64) :: odur
          logical :: has_odur
          call vfield(node, props, [character(12) :: "fps"], v)
          call get_int(v, ofps, has_ofps)
          if (has_ofps .and. (ofps < MIN_FPS .or. &
              ofps > MAX_FPS)) then
            call verrn("E303", "fps is " // istr(ofps) // &
                 ", but it must be " // istr(MIN_FPS) // " to " // &
                 istr(MAX_FPS), node)
          end if
          call vfield(node, props, [character(12) :: "duration"], v)
          call get_num(v, odur, has_odur)
          if (has_odur .and. (odur <= 0.0_real64 .or. &
              odur > MAX_DURATION)) then
            call verrn("E303", "duration is " // rstr(odur) // &
                 ", but it must be more than 0 and at most " // &
                 istr(int(MAX_DURATION, int64)) // " seconds", node)
          end if
        end block
        ir_output = dyn_dict()
        call dyn_dict_set(ir_output, "kind", dyn_str("render"))
        if (py_truthy(pathv)) then
          call dyn_dict_set(ir_output, "path", pathv)
        else
          call dyn_dict_set(ir_output, "path", &
               dyn_str(DEFAULT_OUTPUT))
        end if
        call dyn_dict_set(ir_output, "format", dyn_str("render"))
        if (has_ow .and. ow /= 0_int64) then
          call dyn_dict_set(ir_output, "width", dyn_int(ow))
        else
          call dyn_dict_set(ir_output, "width", &
               dyn_int(vs%width))
        end if
        if (has_oh .and. oh /= 0_int64) then
          call dyn_dict_set(ir_output, "height", dyn_int(oh))
        else
          call dyn_dict_set(ir_output, "height", &
               dyn_int(vs%height))
        end if
        call dyn_list_push(vs%ir_outputs, ir_output)
      end block
    end do
    if (dyn_list_len(vs%ir_outputs) == 0) then
      ir_output = dyn_dict()
      call dyn_dict_set(ir_output, "kind", dyn_str("render"))
      call dyn_dict_set(ir_output, "path", dyn_str(DEFAULT_OUTPUT))
      call dyn_dict_set(ir_output, "format", dyn_str("render"))
      call dyn_dict_set(ir_output, "width", dyn_int(vs%width))
      call dyn_dict_set(ir_output, "height", dyn_int(vs%height))
      call dyn_list_push(vs%ir_outputs, ir_output)
    end if
  end subroutine val_sec_outputs

end module f3dc_val_output
