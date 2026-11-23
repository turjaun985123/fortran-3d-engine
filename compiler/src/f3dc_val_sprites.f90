! f3dc_val_sprites/text/particles.f90 -- Forge3D validator, sprites/text/particles family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_sprites
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
  use f3dc_ext_sprites_text, only: extract_sprite, &
       validate_sprite, extract_text, validate_text
  use f3dc_ext_particles, only: extract_particles, &
       validate_particles
  implicit none
  private
  public :: dispatch_ext_sprite
  public :: dispatch_ext_text
  public :: dispatch_ext_particles
  public :: val_waveb_sprites
  public :: val_waveb_particles

contains

  !> DISPATCH(ext_sprites_text): extract_sprite + validate_sprite
  !! (E301 messages); the normalised payload is IR-only.
  subroutine dispatch_ext_sprite(ext_in, node, ext)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(out) :: ext
    type(char_list) :: msgs
    integer :: mi
    call extract_sprite(ext_in, ext)
    call validate_sprite(ext, msgs)
    do mi = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, mi), node)
    end do
  end subroutine dispatch_ext_sprite


  !> DISPATCH(ext_sprites_text): extract_text + validate_text (E301).
  subroutine dispatch_ext_text(ext_in, node, ext)
    type(dyn), intent(in) :: ext_in, node
    type(dyn), intent(out) :: ext
    type(char_list) :: msgs
    integer :: mi
    call extract_text(ext_in, ext)
    call validate_text(ext, msgs)
    do mi = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, mi), node)
    end do
  end subroutine dispatch_ext_text


  !> DISPATCH(ext_particles): extract_particles +
  !! validate_particles (E301 messages).
  subroutine dispatch_ext_particles(ext_in, node)
    type(dyn), intent(inout) :: ext_in
    type(dyn), intent(in) :: node
    type(dyn) :: ext
    type(char_list) :: msgs
    integer :: k
    call extract_particles(ext_in, ext)
    call validate_particles(ext, msgs)
    do k = 1, char_list_len(msgs)
      call verrn("E301", char_list_at(msgs, k), node)
    end do
    call char_list_clear(msgs)
    call dyn_assign(ext_in, ext)
  end subroutine dispatch_ext_particles

  subroutine val_waveb_sprites(waveb, seen)
    type(dyn), intent(inout) :: waveb, seen
    type(dyn) :: wb_list, ext_in, ext_out, snode, sprops, v
    character(:), allocatable :: sname
    integer :: k
      ! Sprites.
      wb_list = dyn_list()
      do k = 1, dyn_list_len(vs%sprite_nodes)
        snode = dyn_list_at(vs%sprite_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          sname = v%s
        else
          sname = "sprite" // istr(int(dyn_list_len(wb_list), &
               int64) + 1_int64)
        end if
        if (dyn_dict_has(seen, sname)) then
          call verrn("E201", "there are two sprites/texts/" // &
               "particles called " // repr_str(sname), snode)
          cycle
        end if
        call dyn_dict_set(seen, sname, dyn_bool(.true.))
        ext_in = dyn_dict()
        call vfield(snode, sprops, [character(12) :: "at", "pos", &
                                   "position"], v)
        call dyn_dict_set(ext_in, "at", v)
        call vfield(snode, sprops, [character(12) :: "size"], v)
        call dyn_dict_set(ext_in, "size", v)
        call vfield(snode, sprops, [character(12) :: "color", &
             "colour", "color_raw"], v)
        call dyn_dict_set(ext_in, "color", v)
        ! DISPATCH(ext_sprites_text): extract_sprite +
        ! validate_sprite (E301 messages).
        call dispatch_ext_sprite(ext_in, snode, ext_out)
        call dyn_dict_set(ext_out, "name", dyn_str(sname))
        call dyn_list_push(wb_list, ext_out)
      end do
      if (dyn_list_len(wb_list) > 0) &
        call dyn_dict_set(waveb, "sprites", wb_list)
      ! Texts (share the sprite name set, per validate.py).
      wb_list = dyn_list()
      do k = 1, dyn_list_len(vs%text_nodes)
        snode = dyn_list_at(vs%text_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          sname = v%s
        else
          sname = "text" // istr(int(dyn_list_len(wb_list), &
               int64) + 1_int64)
        end if
        if (dyn_dict_has(seen, sname)) then
          call verrn("E201", "there are two sprites/texts/" // &
               "particles called " // repr_str(sname), snode)
          cycle
        end if
        call dyn_dict_set(seen, sname, dyn_bool(.true.))
        ext_in = dyn_dict()
        call vfield(snode, sprops, [character(12) :: "content", &
                                   "text"], v)
        call dyn_dict_set(ext_in, "content", v)
        call vfield(snode, sprops, [character(12) :: "at", "pos", &
                                   "position"], v)
        call dyn_dict_set(ext_in, "at", v)
        call vfield(snode, sprops, [character(12) :: "size"], v)
        call dyn_dict_set(ext_in, "size", v)
        call vfield(snode, sprops, [character(12) :: "color", &
             "colour", "color_raw"], v)
        call dyn_dict_set(ext_in, "color", v)
        ! DISPATCH(ext_sprites_text): extract_text +
        ! validate_text (E301 messages).
        call dispatch_ext_text(ext_in, snode, ext_out)
        call dyn_dict_set(ext_out, "name", dyn_str(sname))
        call dyn_list_push(wb_list, ext_out)
      end do
      if (dyn_list_len(wb_list) > 0) &
        call dyn_dict_set(waveb, "texts", wb_list)
  end subroutine val_waveb_sprites

  subroutine val_waveb_particles(waveb)
    type(dyn), intent(inout) :: waveb
    type(dyn) :: wb_list, ext_in, snode, sprops, v
    character(:), allocatable :: sname
    integer :: k, j
      ! Particles (no shared name check in validate.py).
      wb_list = dyn_list()
      do k = 1, dyn_list_len(vs%particles_nodes)
        snode = dyn_list_at(vs%particles_nodes, k)
        sprops = props_of(snode)
        call vfield(snode, sprops, [character(12) :: "name", &
                                   "id"], v)
        if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
          sname = v%s
        else
          sname = "particles" // istr(int(dyn_list_len(wb_list), &
               int64) + 1_int64)
        end if
        ext_in = dyn_dict()
        do j = 1, 8
          block
            character(12) :: pkeys(8)
            pkeys = [character(12) :: "at", "count", "life", &
                     "speed", "size", "spread", "gravity", "seed"]
            call vfield(snode, sprops, [character(12) :: &
                         pkeys(j)], v)
            if (v%kind /= DYN_K_NULL) &
              call dyn_dict_set(ext_in, trim(pkeys(j)), v)
          end block
        end do
        call vfield(snode, sprops, [character(12) :: "color", &
             "colour", "color_raw"], v)
        if (v%kind /= DYN_K_NULL) &
          call dyn_dict_set(ext_in, "color", v)
        ! DISPATCH(ext_particles): extract_particles +
        ! validate_particles (E301 messages).
        call dispatch_ext_particles(ext_in, snode)
        call dyn_dict_set(ext_in, "name", dyn_str(sname))
        call dyn_list_push(wb_list, ext_in)
      end do
      if (dyn_list_len(wb_list) > 0) &
        call dyn_dict_set(waveb, "particles", wb_list)
  end subroutine val_waveb_particles

end module f3dc_val_sprites
