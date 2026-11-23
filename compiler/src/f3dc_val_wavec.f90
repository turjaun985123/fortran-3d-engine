! f3dc_val_Wave C section + post dispatch.f90 -- Forge3D validator, Wave C section + post dispatch family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_wavec
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
  use f3dc_ext_post, only: extract_post, validate_post
  use f3dc_val_camera, only: dispatch_ext_camera
  implicit none
  private
  public :: dispatch_ext_post
  public :: val_sec_wavec

contains

  !> DISPATCH(ext_post): extract_post + validate_post (E301).
  subroutine dispatch_ext_post(ext_in, node, chain)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(inout) :: chain
    type(dyn) :: ext
    type(char_list) :: msgs
    integer :: k
    call extract_post(ext_in, ext)
    call validate_post(ext, msgs)
    do k = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, k), node)
    end do
    call dyn_list_push(chain, ext)
  end subroutine dispatch_ext_post

  subroutine val_sec_wavec()
    type(dyn) :: node, props, v
    integer :: k
    ! ---- Wave C entities (rows 3/22/26/30) ---------------------------
    block
      type(dyn) :: wavec, insts, entry, snode, sprops, chain
      character(:), allocatable :: iname, source
      real(real64) :: tv(3)
      logical :: has3
      type(dyn) :: kv2
      wavec = dyn_dict()
      chain = dyn_list()
      if (vs%has_camera) then
        call dyn_assign(node, vs%camera_node)
        props = props_of(node)
        call vfield(node, props, [character(12) :: "ortho"], v)
        if (py_truthy(v)) then
          block
            type(dyn) :: ext_in2
            ext_in2 = dyn_dict()
            call dyn_dict_set(ext_in2, "ortho", dyn_bool(.true.))
            call vfield(node, props, [character(12) :: "size"], v)
            call dyn_dict_set(ext_in2, "size", v)
            call vfield(node, props, [character(12) :: "at", &
                 "pos", "position"], v)
            call dyn_dict_set(ext_in2, "at", v)
            call vfield(node, props, [character(12) :: "look", &
                                       "target"], v)
            call dyn_dict_set(ext_in2, "look", v)
            ! DISPATCH(ext_cameras): extract_camera +
            ! validate_camera (E302 messages).
            call dispatch_ext_camera(ext_in2, node, wavec)
          end block
        end if
      end if
      if (dyn_list_len(vs%filter_nodes) > 0) then
        do k = 1, dyn_list_len(vs%filter_nodes)
          snode = dyn_list_at(vs%filter_nodes, k)
          sprops = props_of(snode)
          block
            type(dyn) :: ext_in2
            ext_in2 = dyn_dict()
            call vfield(snode, sprops, [character(12) :: "name"], v)
            call dyn_dict_set(ext_in2, "name", v)
            call vfield(snode, sprops, [character(12) :: &
                         "amount"], v)
            if (v%kind /= DYN_K_NULL) &
              call dyn_dict_set(ext_in2, "amount", v)
            ! DISPATCH(ext_post): extract_post + validate_post
            ! (E301 messages).
            call dispatch_ext_post(ext_in2, snode, chain)
          end block
        end do
      end if
      if (dyn_list_len(chain) > 0) &
        call dyn_dict_set(wavec, "post", chain)
      ! Instances are pure validate.py core (no ext call).
      insts = dyn_list()
      do k = 1, dyn_list_len(vs%instance_nodes)
        snode = dyn_list_at(vs%instance_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          iname = v%s
        else
          iname = ""
        end if
        call vfield(snode, sprops, [character(12) :: "source", &
             "of", "target"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          source = v%s
        else
          source = ""
        end if
        if (len(iname) == 0) then
          call verrn("E201", "'instance' needs a name for the " // &
               "new object", snode)
          cycle
        end if
        if (len(source) == 0) then
          call verrn("E201", "'instance " // iname // &
               "' needs 'of <object>'", snode)
          cycle
        end if
        if (.not. dyn_dict_has(vs%names, source)) then
          call verrn("E201", "instance " // repr_str(iname) // &
               " copies " // repr_str(source) // &
               ", but no object is called that", snode)
          cycle
        end if
        if (dyn_dict_has(vs%names, iname)) then
          call verrn("E201", "there is already an object called " &
               // repr_str(iname), snode)
          cycle
        end if
        entry = dyn_dict()
        call dyn_dict_set(entry, "name", dyn_str(iname))
        call dyn_dict_set(entry, "source", dyn_str(source))
        call vfield(snode, sprops, [character(12) :: "at", "pos", &
                                   "position"], kv2)
        call get_vec3(kv2, tv, has3)
        if (has3) call dyn_dict_set(entry, "pos", vec3_dyn(tv))
        call vfield(snode, sprops, [character(12) :: "rotate", &
                                   "rot"], kv2)
        call get_vec3(kv2, tv, has3)
        if (has3) call dyn_dict_set(entry, "rot", vec3_dyn(tv))
        call vfield(snode, sprops, [character(12) :: "scale"], kv2)
        if (kv2%kind /= DYN_K_NULL) &
          call dyn_dict_set(entry, "scale", kv2)
        call dyn_list_push(insts, entry)
        call dyn_dict_set(vs%names, iname, snode)
      end do
      if (dyn_list_len(insts) > 0) &
        call dyn_dict_set(wavec, "instances", insts)
      call set_scene_extension("wavec", wavec)
    end block
  end subroutine val_sec_wavec

end module f3dc_val_wavec
