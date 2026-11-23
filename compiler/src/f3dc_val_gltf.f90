! f3dc_val_gltf.f90 -- Forge3D validator, gltf family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_gltf
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
  use f3dc_ext_gltf, only: load_gltf
  use f3dc_ir, only: ir_object, ir_object_to_dict, &
       ir_object_typed_default, ir_scalar_from_dyn, &
       ir_vec3_from_dyn
  implicit none
  private
  public :: dispatch_ext_gltf

contains

  !> DISPATCH(ext_gltf): load_gltf(full) -> 'tris' IR object
  !! (validate.py's glTF branch of the load loop: E501 on load
  !! failure; name / material / transform handling; total_tris).
  subroutine dispatch_ext_gltf(node, lpath, full)
    type(dyn), intent(in) :: node
    character(*), intent(in) :: lpath, full
    type(dyn) :: props, v, gdata, countv, ir_obj, exts
    type(dyn) :: gscale_raw
    type(ir_object) :: tobj
    character(:), allocatable :: gname, gmaterial, errmsg
    logical :: ok, has_gscale_vec, has_gscale_num
    real(real64) :: gpos(3), grot(3), gscale3(3), gscale_vec(3)
    real(real64) :: gscale_num

    call load_gltf(full, gdata, ok, errmsg)
    if (.not. ok) then
      call verrn("E501", "could not load glTF " // &
           repr_str(lpath) // ": " // errmsg, node)
      return
    end if
    props = props_of(node)
    call vfield(node, props, [character(12) :: "name", "id"], v)
    if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
      gname = v%s
    else
      gname = "gltf" // istr(int(dyn_list_len(vs%ir_objects), &
           int64) + 1_int64)
    end if
    if (dyn_dict_has(vs%names, gname)) then
      call verrn("E201", "there are two objects called " // &
           repr_str(gname) // &
           "; give each object its own name", node)
      return
    end if
    call vfield(node, props, [character(12) :: "material"], v)
    if (v%kind /= DYN_K_NULL) then
      gmaterial = to_lower(py_str(v))
      if (.not. in_words(gmaterial, MATERIALS)) then
        call verrn("E205", "material " // repr_str(gmaterial) // &
             " is not built yet", node)
        gmaterial = "lambert"
      end if
    else
      gmaterial = "lambert"
    end if
    call vfield(node, props, [character(12) :: "at", "pos", &
                             "position"], v)
    call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], gpos)
    call vfield(node, props, [character(12) :: "rotate", &
                             "rotation", "rot"], v)
    call vec3_or(v, [0.0_real64, 0.0_real64, 0.0_real64], grot)
    call vfield(node, props, [character(12) :: "scale"], gscale_raw)
    call get_vec3(gscale_raw, gscale_vec, has_gscale_vec)
    call get_num(gscale_raw, gscale_num, has_gscale_num)
    if (has_gscale_vec) then
      gscale3 = gscale_vec
    else if (has_gscale_num) then
      gscale3 = [gscale_num, gscale_num, gscale_num]
    else
      gscale3 = [1.0_real64, 1.0_real64, 1.0_real64]
    end if
    call dyn_dict_set(vs%names, gname, node)
    countv = dyn_dict_get(gdata, "count")
    vs%total_tris = vs%total_tris + countv%i
    ! Typed construction (C1): fill an ir_object field by field
    ! and convert once; the dict pushed below is exactly the one
    ! the old dyn_dict_set chain built (same keys, order and leaf
    ! kinds: pos / rotate / scale stay dyn_real triples via
    ! vec3_dyn, the null fields stay dyn_null via raw scalars /
    ! vec3s, source_file stays a dyn_str scalar).
    tobj = ir_object_typed_default(gname, "tris")
    tobj%name%s = gname
    tobj%name%present = .true.
    tobj%prim%s = "tris"
    tobj%prim%present = .true.
    tobj%color = ir_vec3_from_dyn(dyn_null())
    tobj%pos = ir_vec3_from_dyn(vec3_dyn(gpos))
    tobj%rotate = ir_vec3_from_dyn(vec3_dyn(grot))
    tobj%scale = ir_vec3_from_dyn(vec3_dyn(gscale3))
    tobj%size = ir_scalar_from_dyn(dyn_null())
    tobj%size3 = ir_vec3_from_dyn(dyn_null())
    tobj%radius = ir_scalar_from_dyn(dyn_null())
    tobj%height = ir_scalar_from_dyn(dyn_null())
    tobj%segments = ir_scalar_from_dyn(dyn_null())
    tobj%detail%s = "med"
    tobj%detail%present = .true.
    tobj%capped = .true.
    tobj%material%s = gmaterial
    tobj%material%present = .true.
    call dyn_assign(tobj%triangles, &
         dyn_dict_get(gdata, "triangles"))
    tobj%source_file = ir_scalar_from_dyn(dyn_str(lpath))
    exts = dyn_dict()
    call dyn_assign(tobj%ext, exts)
    ir_obj = ir_object_to_dict(tobj)
    call dyn_list_push(vs%ir_objects, ir_obj)
    vs%last_obj_name = gname
    vs%has_last_obj = .true.
  end subroutine dispatch_ext_gltf

end module f3dc_val_gltf
