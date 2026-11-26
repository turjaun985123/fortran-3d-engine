! f3dc_val_keys dispatch + Wave B keys part.f90 -- Forge3D validator, keys dispatch + Wave B keys part family
! (split from f3dc_validate.f90, v3.0 Phase 6 C2).  Behaviour
! is frozen: bodies moved verbatim; diagnostics, their order
! and all artifacts are unchanged.
module f3dc_val_keys
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
  use f3dc_ext_keys, only: build_tracks, validate_tracks
  implicit none
  private
  public :: dispatch_ext_keys
  public :: val_waveb_keys

contains

  !> DISPATCH(ext_keys): build_tracks + validate_tracks (E201
  !! messages, span-less in Python).
  subroutine dispatch_ext_keys(headers, raw_keys, tracks)
    type(dyn), intent(in) :: headers, raw_keys
    type(dyn), intent(out) :: tracks
    type(char_list) :: errs
    integer :: i
    call build_tracks(headers, raw_keys, tracks)
    errs = char_list()
    call validate_tracks(tracks, errs)
    do i = 1, char_list_len(errs)
      call verr("E201", char_list_at(errs, i))
    end do
  end subroutine dispatch_ext_keys

  subroutine val_waveb_keys(waveb)
    type(dyn), intent(inout) :: waveb
    type(dyn) :: headers, raw_keys, tracks, snode, sprops, v
    integer :: k
      ! Keyframe tracks: validate.py's own target checks are core;
      ! build_tracks / validate_tracks are the dispatch.
      if (dyn_list_len(vs%keys_header_nodes) > 0 .or. &
          dyn_list_len(vs%key_nodes) > 0) then
        headers = dyn_dict()
        do k = 1, dyn_list_len(vs%keys_header_nodes)
          snode = dyn_list_at(vs%keys_header_nodes, k)
          sprops = props_of(snode)
          call vfield(snode, sprops, [character(12) :: "target"], v)
          ! ANIM Wave 1 (ANIM-PLAN SS2.3): the "@camera" keys
          ! header is the reserved camera pseudo-target emitted by
          ! timeline desugar for camera moves.  It is exempt from
          ! the object-name checks and is NOT built into the waveb
          ! keys extension here; the timeline section owns it and
          ! builds the "camera_track" scene extension from it.
          if (v%kind == DYN_K_STR .and. v%s == "@camera") cycle
          if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
            block
              type(dyn) :: hdr, dv
              real(real64) :: dur
              logical :: has_dur
              hdr = dyn_dict()
              call vfield(snode, sprops, [character(12) :: &
                           "duration"], dv)
              call get_num(dv, dur, has_dur)
              if (has_dur) then
                call dyn_dict_set(hdr, "duration", dyn_real(dur))
              else
                call dyn_dict_set(hdr, "duration", dyn_null())
              end if
              call vfield(snode, sprops, [character(12) :: &
                           "loop"], dv)
              call dyn_dict_set(hdr, "loop", dv)
              ! v3.0 Phase 5 (M3): per-clip fps, forwarded only
              ! when the keys header carries it (zero drift).
              call vfield(snode, sprops, [character(12) :: &
                           "fps"], dv)
              call get_num(dv, dur, has_dur)
              if (has_dur) &
                call dyn_dict_set(hdr, "fps", dyn_real(dur))
              call dyn_dict_set(headers, v%s, hdr)
            end block
          end if
        end do
        raw_keys = dyn_list()
        do k = 1, dyn_list_len(vs%key_nodes)
          snode = dyn_list_at(vs%key_nodes, k)
          sprops = props_of(snode)
          call vfield(snode, sprops, [character(12) :: "target"], v)
          if (v%kind /= DYN_K_STR .or. len(v%s) == 0) then
            call verrn("E201", "'key' needs the name of the " // &
                 "object it animates", snode)
            cycle
          end if
          ! ANIM Wave 1: "@camera" keys belong to the timeline
          ! section (see the header loop above); skip them here so
          ! they neither fail the "no object is called that" check
          ! nor land in the waveb keys extension.
          if (v%s == "@camera") cycle
          if (.not. dyn_dict_has(vs%names, v%s)) then
            call verrn("E201", "key targets " // repr_str(v%s) // &
                 ", but no object is called that", snode)
            cycle
          end if
          block
            type(dyn) :: entry, kv2
            real(real64) :: tv(3), tnum
            logical :: has3, has_n
            entry = dyn_dict()
            call dyn_dict_set(entry, "target", v)
            call vfield(snode, sprops, [character(12) :: "time"], &
                        kv2)
            call get_num(kv2, tnum, has_n)
            if (has_n) then
              call dyn_dict_set(entry, "time", dyn_real(tnum))
            else
              call dyn_dict_set(entry, "time", &
                   dyn_real(0.0_real64))
            end if
            call vfield(snode, sprops, [character(12) :: "pos", &
                                       "position"], kv2)
            call get_vec3(kv2, tv, has3)
            if (has3) call dyn_dict_set(entry, "pos", vec3_dyn(tv))
            call vfield(snode, sprops, [character(12) :: "rot", &
                                       "rotate"], kv2)
            call get_vec3(kv2, tv, has3)
            if (has3) call dyn_dict_set(entry, "rot", vec3_dyn(tv))
            call vfield(snode, sprops, [character(12) :: &
                         "scale"], kv2)
            call get_num(kv2, tnum, has_n)
            if (has_n) &
              call dyn_dict_set(entry, "scale", dyn_real(tnum))
            call vfield(snode, sprops, [character(12) :: &
                         "ease"], kv2)
            if (kv2%kind /= DYN_K_NULL) &
              call dyn_dict_set(entry, "ease", &
                   dyn_str(to_lower(py_str(kv2))))
            call dyn_list_push(raw_keys, entry)
          end block
        end do
        ! DISPATCH(ext_keys): build_tracks + validate_tracks
        ! (E201 messages, span-less).
        call dispatch_ext_keys(headers, raw_keys, tracks)
        if (dyn_dict_len(tracks) > 0) &
          call dyn_dict_set(waveb, "keys", tracks)
      end if
  end subroutine val_waveb_keys

end module f3dc_val_keys
