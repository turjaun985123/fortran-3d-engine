! f3dc_val_Wave B section.f90 -- Forge3D validator, Wave B section family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_waveb
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
  use f3dc_val_sprites, only: val_waveb_sprites, &
       val_waveb_particles
  use f3dc_val_keys, only: val_waveb_keys
  implicit none
  private
  public :: val_sec_waveb

contains
  subroutine val_sec_waveb()
    type(dyn) :: waveb, seen
    waveb = dyn_dict()
    seen = dyn_dict()
    call val_waveb_sprites(waveb, seen)
    call val_waveb_particles(waveb)
    call val_waveb_keys(waveb)
    call set_scene_extension("waveb", waveb)
  end subroutine val_sec_waveb

end module f3dc_val_waveb
