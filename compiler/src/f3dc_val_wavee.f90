! f3dc_val_Wave E section (shader/skin).f90 -- Forge3D validator, Wave E section (shader/skin) family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_wavee
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
  use f3dc_str, only: to_lower, fmt_int, fmt_real
  use f3dc_str, only: char_list, char_list_len, char_list_at, &
       char_list_clear
  use f3dc_val_skin, only: dispatch_ext_shader_rpn, &
       dispatch_ext_bone, dispatch_ext_morph, dispatch_ext_skin
  implicit none
  private
  public :: val_sec_wavee

contains

  !> Wave E section of validate() (shaders + bindings + skinning).
  subroutine val_sec_wavee()
    type(dyn) :: wavee, shaders, bindings, bones, morphs, skins
    type(dyn) :: node, props, v, entry, ext_in
    type(dyn) :: obj_names, seen_shaders, bone_names
    character(:), allocatable :: sname, target
    logical :: has_target, rpn_ok, shader_no_expr
    integer :: k, m
    type(dyn) :: rpn
    type(char_list) :: msgs
    wavee = dyn_dict()
    obj_names = dyn_dict()
    do k = 1, dyn_list_len(vs%ir_objects)
      v = dyn_dict_get(dyn_list_at(vs%ir_objects, k), "name")
      if (v%kind == DYN_K_STR .and. len(v%s) > 0) &
        call dyn_dict_set(obj_names, v%s, dyn_bool(.true.))
    end do
    ! Shader definitions.
    shaders = dyn_list()
    seen_shaders = dyn_dict()
    do k = 1, dyn_list_len(vs%shader_nodes)
      node = dyn_list_at(vs%shader_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "name", "id"], v)
      if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
        sname = v%s
      else
        sname = ""
      end if
      call vfield(node, props, [character(12) :: "expr", &
                               "expression"], v)
      if (len(sname) == 0) then
        call verrn("E201", "'shader' needs a name", node)
        cycle
      end if
      if (dyn_dict_has(seen_shaders, sname)) then
        call verrn("E201", "there is already a shader called " // &
             repr_str(sname), node)
        cycle
      end if
      shader_no_expr = v%kind /= DYN_K_STR
      if (.not. shader_no_expr) &
        shader_no_expr = len(strip_ws(v%s)) == 0
      if (shader_no_expr) then
        call verrn("E301", "shader " // repr_str(sname) // &
             " needs an expression, like: shader " // sname // &
             " expr ""c * ndl""", node)
        cycle
      end if
      ! DISPATCH(ext_shader): tokenize_expr + to_rpn (ValueError ->
      ! E301 "shader %r: %s") and validate_shader (E301 messages).
      call dispatch_ext_shader_rpn(sname, v%s, node, rpn, msgs, &
                                   rpn_ok)
      if (.not. rpn_ok) then
        call verrn("E301", "shader " // repr_str(sname) // ": " // &
             char_list_at(msgs, 1), node)
        cycle
      end if
      do m = 1, char_list_len(msgs)
        call verrn("E301", "shader " // repr_str(sname) // ": " // &
             char_list_at(msgs, m), node)
      end do
      call dyn_dict_set(seen_shaders, sname, dyn_bool(.true.))
      entry = dyn_dict()
      call dyn_dict_set(entry, "name", dyn_str(sname))
      call dyn_dict_set(entry, "rpn", rpn)
      call dyn_dict_set(entry, "expr", v)
      call dyn_list_push(shaders, entry)
    end do
    if (dyn_list_len(shaders) > 0) &
      call dyn_dict_set(wavee, "shaders", shaders)
    ! Object-line `shader <name>` bindings (core checks).
    bindings = dyn_dict()
    do k = 1, dyn_list_len(vs%object_nodes)
      node = dyn_list_at(vs%object_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "shader"], v)
      if (v%kind == DYN_K_NULL) cycle
      block
        type(dyn) :: nv
        character(:), allocatable :: oname, bound
        bound = py_str(v)
        call vfield(node, props, [character(12) :: "name", &
                                   "id"], nv)
        if (nv%kind == DYN_K_STR .and. len(nv%s) > 0) then
          oname = nv%s
        else
          oname = ""
        end if
        if (len(oname) == 0) then
          call verrn("E201", "an object using 'shader " // &
               bound // "' needs a name, like: cube hero red " // &
               "shader " // bound, node)
          cycle
        end if
        if (.not. dyn_dict_has(seen_shaders, bound)) then
          call verrn("E201", "object " // repr_str(oname) // &
               " uses shader " // repr_str(bound) // &
               ", but no shader is called that", node)
          cycle
        end if
        call dyn_dict_set(bindings, oname, dyn_str(bound))
      end block
    end do
    if (dyn_dict_len(bindings) > 0) &
      call dyn_dict_set(wavee, "bindings", bindings)
    ! Skinning / morph.
    if (dyn_list_len(vs%morph_nodes) > 0 .or. &
        dyn_list_len(vs%bone_nodes) > 0 .or. &
        dyn_list_len(vs%skin_nodes) > 0) then
      bones = dyn_list()
      bone_names = dyn_dict()
      do k = 1, dyn_list_len(vs%bone_nodes)
        node = dyn_list_at(vs%bone_nodes, k)
        props = props_of(node)
        ext_in = dyn_dict()
        call vfield(node, props, [character(12) :: "name", &
                                   "id"], v)
        call dyn_dict_set(ext_in, "name", v)
        call vfield(node, props, [character(12) :: "at", "pos", &
                                   "position"], v)
        call dyn_dict_set(ext_in, "at", v)
        call vfield(node, props, [character(12) :: "rotate", &
                                   "rot"], v)
        call dyn_dict_set(ext_in, "rotate", v)
        call vfield(node, props, [character(12) :: "radius"], v)
        call dyn_dict_set(ext_in, "radius", v)
        ! DISPATCH(ext_skin): extract_bone + validate_bone (E301).
        block
          character(:), allocatable :: bname
          logical :: has_bname
          call dispatch_ext_bone(ext_in, node, bone_names, &
               bname, has_bname)
          if (has_bname) &
            call dyn_dict_set(bone_names, bname, dyn_bool(.true.))
        end block
        call dyn_list_push(bones, ext_in)
      end do
      morphs = dyn_list()
      do k = 1, dyn_list_len(vs%morph_nodes)
        node = dyn_list_at(vs%morph_nodes, k)
        props = props_of(node)
        ext_in = dyn_dict()
        call vfield(node, props, [character(12) :: "target", &
                                   "name"], v)
        call dyn_dict_set(ext_in, "target", v)
        call vfield(node, props, [character(12) :: "kind"], v)
        call dyn_dict_set(ext_in, "kind", v)
        call vfield(node, props, [character(12) :: "factor"], v)
        call dyn_dict_set(ext_in, "factor", v)
        ! DISPATCH(ext_skin): extract_morph + validate_morph
        ! (E301 messages).
        call dispatch_ext_morph(ext_in, node, target, has_target)
        if (has_target .and. &
            .not. dyn_dict_has(obj_names, target)) then
          call verrn("E201", "morph targets " // &
               repr_str(target) // &
               ", but no object is called that", node)
          cycle
        end if
        call dyn_list_push(morphs, ext_in)
      end do
      skins = dyn_list()
      do k = 1, dyn_list_len(vs%skin_nodes)
        node = dyn_list_at(vs%skin_nodes, k)
        props = props_of(node)
        ext_in = dyn_dict()
        call vfield(node, props, [character(12) :: "target", &
                                   "name"], v)
        call dyn_dict_set(ext_in, "target", v)
        call vfield(node, props, [character(12) :: "bone"], v)
        call dyn_dict_set(ext_in, "bone", v)
        ! DISPATCH(ext_skin): extract_skin + validate_skin (E301).
        call dispatch_ext_skin(ext_in, node, bone_names, target, &
             has_target)
        if (has_target .and. &
            .not. dyn_dict_has(obj_names, target)) then
          call verrn("E201", "skin targets " // &
               repr_str(target) // &
               ", but no object is called that", node)
          cycle
        end if
        call dyn_list_push(skins, ext_in)
      end do
      if (dyn_list_len(bones) > 0) &
        call dyn_dict_set(wavee, "bones", bones)
      if (dyn_list_len(morphs) > 0) &
        call dyn_dict_set(wavee, "morphs", morphs)
      if (dyn_list_len(skins) > 0) &
        call dyn_dict_set(wavee, "skins", skins)
    end if
    call set_scene_extension("wavee", wavee)
  end subroutine val_sec_wavee

end module f3dc_val_wavee
