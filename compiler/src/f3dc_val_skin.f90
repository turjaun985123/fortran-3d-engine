! f3dc_val_skin/shader dispatch.f90 -- Forge3D validator, skin/shader dispatch family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_skin
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
  use f3dc_str, only: char_list, char_list_len, char_list_at, &
       char_list_clear, to_lower, fmt_int, fmt_real
  use f3dc_ext_skin, only: extract_bone, validate_bone, &
       extract_morph, validate_morph, extract_skin, validate_skin
  use f3dc_ext_shader, only: shader_compile
  implicit none
  private
  public :: dispatch_ext_shader_rpn
  public :: dispatch_ext_bone
  public :: dispatch_ext_morph
  public :: dispatch_ext_skin

contains

  !> DISPATCH(ext_shader): tokenize_expr + to_rpn + validate_shader
  !! (E301 messages).  ok=.false. mirrors a ValueError from to_rpn.
  subroutine dispatch_ext_shader_rpn(name, expr, node, rpn, msgs, ok)
    character(*), intent(in) :: name, expr
    type(dyn), intent(in) :: node
    type(dyn), intent(out) :: rpn
    type(char_list), intent(inout) :: msgs
    logical, intent(out) :: ok
    if (node%kind < 0) continue
    call shader_compile(name, expr, rpn, msgs, ok)
  end subroutine dispatch_ext_shader_rpn


  !> DISPATCH(ext_skin): extract_bone + validate_bone (E301).
  subroutine dispatch_ext_bone(ext_in, node, bone_names, bone_name, &
                               has_name)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node, bone_names
    character(:), allocatable, intent(out) :: bone_name
    logical, intent(out) :: has_name
    type(dyn) :: ext, known, v
    type(char_list) :: errs
    integer :: i
    call extract_bone(ext_in, ext)
    known = dyn_list()
    do i = 1, dyn_dict_len(bone_names)
      call dyn_list_push(known, &
           dyn_str(dyn_dict_key_at(bone_names, i)))
    end do
    errs = char_list()
    call validate_bone(ext, known, errs)
    do i = 1, char_list_len(errs)
      call verrn("E301", char_list_at(errs, i), node)
    end do
    call dyn_assign(ext_in, ext)
    v = dyn_dict_get(ext, "name")
    has_name = v%kind == DYN_K_STR .and. len(v%s) > 0
    bone_name = ""
    if (has_name) bone_name = v%s
  end subroutine dispatch_ext_bone


  !> DISPATCH(ext_skin): extract_morph + validate_morph (E301).
  !! target_out mirrors extract_morph's "target" (the statement's
  !! target/name field) for validate.py's core E201 check.
  subroutine dispatch_ext_morph(ext_in, node, target_out, has_target)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node
    character(:), allocatable, intent(out) :: target_out
    logical, intent(out) :: has_target
    type(dyn) :: ext, v
    type(char_list) :: errs
    integer :: i
    call extract_morph(ext_in, ext)
    errs = char_list()
    call validate_morph(ext, errs)
    do i = 1, char_list_len(errs)
      call verrn("E301", char_list_at(errs, i), node)
    end do
    call dyn_assign(ext_in, ext)
    v = dyn_dict_get(ext, "target")
    has_target = v%kind == DYN_K_STR .and. len(v%s) > 0
    target_out = ""
    if (has_target) target_out = v%s
  end subroutine dispatch_ext_morph


  !> DISPATCH(ext_skin): extract_skin + validate_skin (E301).
  !! target_out mirrors extract_skin's "target" as above.
  subroutine dispatch_ext_skin(ext_in, node, bone_names, target_out, &
                               has_target)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node, bone_names
    character(:), allocatable, intent(out) :: target_out
    logical, intent(out) :: has_target
    type(dyn) :: ext, known, v
    type(char_list) :: errs
    integer :: i
    call extract_skin(ext_in, ext)
    known = dyn_list()
    do i = 1, dyn_dict_len(bone_names)
      call dyn_list_push(known, &
           dyn_str(dyn_dict_key_at(bone_names, i)))
    end do
    errs = char_list()
    call validate_skin(ext, known, errs)
    do i = 1, char_list_len(errs)
      call verrn("E301", char_list_at(errs, i), node)
    end do
    call dyn_assign(ext_in, ext)
    v = dyn_dict_get(ext, "target")
    has_target = v%kind == DYN_K_STR .and. len(v%s) > 0
    target_out = ""
    if (has_target) target_out = v%s
  end subroutine dispatch_ext_skin

end module f3dc_val_skin
