! f3dc_val_materials.f90 -- Forge3D validator, materials family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_materials
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
  use f3dc_ext_materials, only: mat_apply => apply_to_ir_object, &
       mat_validate => validate_material_ext
  implicit none
  private
  public :: dispatch_ext_materials

contains

  !> DISPATCH(ext_materials): apply_to_ir_object +
  !! validate_material_ext (E501 for texture messages, else E301).
  subroutine dispatch_ext_materials(ir_obj, raw_props, material, node)
    type(dyn), intent(inout) :: ir_obj
    type(dyn), intent(in) :: raw_props, node
    character(*), intent(in) :: material
    type(dyn) :: raw, exts, extd, tex
    type(char_list) :: msgs
    character(:), allocatable :: cand, t
    integer :: k, a, b
    raw = dyn_copy(raw_props)
    call dyn_dict_set(raw, "material", dyn_str(material))
    tex = dyn_dict_get(raw, "texture")
    if (tex%kind == DYN_K_STR .and. allocated(tex%s)) then
      t = tex%s
      if (len(t) > 0) then
       if (t(1:1) /= "/") then
        a = 1; b = len(t)
        do while (a <= b)
          if (t(a:a) /= '"' .and. t(a:a) /= "'") exit
          a = a + 1
        end do
        do while (b >= a)
          if (t(b:b) /= '"' .and. t(b:b) /= "'") exit
          b = b - 1
        end do
        if (a > b) then
          cand = ""
        else
          cand = join_path(vs%base_dir, t(a:b))
        end if
        if (len(cand) > 0 .and. path_is_file(cand)) &
          call dyn_dict_set(raw, "texture", dyn_str(cand))
       end if
      end if
    end if
    ! v3.0 Phase 4: the four extra texture-slot paths resolve
    ! exactly like "texture" above (relative paths are made
    ! source-relative when the file exists there).
    block
      character(len=12) :: slot_keys(4)
      integer :: sk
      slot_keys = [character(len=12) :: "normalmap", "mr", &
                   "emissivemap", "occlusionmap"]
      do sk = 1, 4
        tex = dyn_dict_get(raw, trim(slot_keys(sk)))
        if (tex%kind == DYN_K_STR .and. allocated(tex%s)) then
          t = tex%s
          if (len(t) > 0) then
           if (t(1:1) /= "/") then
            a = 1; b = len(t)
            do while (a <= b)
              if (t(a:a) /= '"' .and. t(a:a) /= "'") exit
              a = a + 1
            end do
            do while (b >= a)
              if (t(b:b) /= '"' .and. t(b:b) /= "'") exit
              b = b - 1
            end do
            if (a > b) then
              cand = ""
            else
              cand = join_path(vs%base_dir, t(a:b))
            end if
            if (len(cand) > 0 .and. path_is_file(cand)) &
              call dyn_dict_set(raw, trim(slot_keys(sk)), &
                                dyn_str(cand))
           end if
          end if
        end if
      end do
    end block
    exts = dyn_dict_get(ir_obj, "extensions")
    if (exts%kind /= DYN_K_DICT) exts = dyn_dict()
    call dyn_dict_set(exts, "raw_props", raw)
    call dyn_dict_set(ir_obj, "extensions", exts)
    call mat_apply(ir_obj)
    exts = dyn_dict_get(ir_obj, "extensions")
    extd = dyn_dict_get(exts, "material")
    if (extd%kind == DYN_K_DICT) then
      call mat_validate(material, extd, msgs)
      do k = 1, char_list_len(msgs)
        if (index(char_list_at(msgs, k), "texture") > 0) then
          call verrn("E501", char_list_at(msgs, k), node)
        else
          call verrn("E301", char_list_at(msgs, k), node)
        end if
      end do
    end if
  end subroutine dispatch_ext_materials

end module f3dc_val_materials
