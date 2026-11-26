! f3dc_val_timeline.f90 -- Forge3D validator, timeline section
! (ANIM Wave 1, ANIM-PLAN SS2.3).  Registered in validate_program
! after "outputs" (it needs the render duration/fps the outputs
! section parses) and before "env".
!
! Everything here runs on the RESOLVED stream desugar produces
! (SS2.2): plain AnimStmts carrying fields-bag `start`, `duration`
! and `channel` (body|face); camera moves as keys tracks for the
! pseudo-target "@camera"; dialogue nodes (marker "say") carrying
! absolute start/duration and an `estimated` flag when their
! duration was estimated.  The validator never sees a `then`.
!
! Checks (SS2.4): E207 overlapping actions, E208 timeline overrun,
! E209 unknown character, E210 camera follow target missing,
! E211 dialogue for undefined character, W203 unused action,
! W204 dialogue duration estimated.  (E206/E212/E213 are raised in
! desugar; their code-table entries live in f3dc_errors.)
!
! Builds: ir_anim `start` per animation (val_anim populates it
! first; this section guarantees it on the resolved stream), the
! "dialogue" scene extension ([{speaker, text, start, duration}])
! and the "camera_track" scene extension (build_tracks-shaped,
! for "@camera"), both via set_scene_extension -- zero emitter
! dispatch changes.
!
! Provenance notes (integration contract with the desugar slice):
!  * with-exemption (E207): cues joined by `with` are exempt.
!    Primary stamp: a `with_group` fields key shared by every cue
!    of one with-group.  Fallback, when no stamp is present: a cue
!    whose `timing` field is "with" (or which carries a true
!    `with` flag) and which shares the other cue's exact start is
!    treated as with-joined to it.
!  * W203: actiondefs do not survive desugar, so usage info can
!    only arrive as provenance: this section reads an
!    `unused_actions` (or `_unused_actions`) list field stamped
!    by desugar on any resolved node it can see (anim / dialogue /
!    output / object / keys nodes).  When no stamp exists the
!    warning simply cannot fire yet -- see the wave report.
module f3dc_val_timeline
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, &
       dyn_real, dyn_str, dyn_list, dyn_dict, dyn_copy, &
       dyn_assign, dyn_list_push, dyn_list_len, dyn_list_at, &
       dyn_dict_get, dyn_dict_set, dyn_dict_has, dyn_dict_len, &
       dyn_dict_key_at, dyn_dict_value_at, dyn_list_set_at, &
       DYN_K_NULL, &
       DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, &
       DYN_K_LIST, DYN_K_DICT
  use f3dc_val_common
  use f3dc_str, only: to_lower, char_list, char_list_len, &
       char_list_at
  use f3dc_ext_keys, only: build_tracks, validate_tracks
  implicit none
  private
  public :: val_sec_timeline

  ! One resolved cue (from an AnimStmt) or dialogue line, with
  ! absolute timing, for the overlap / overrun checks.
  type :: cue_t
    character(:), allocatable :: target, kind, channel
    character(:), allocatable :: with_group, timing
    logical :: has_with = .false.
    real(real64) :: start = 0.0_real64
    real(real64) :: dur = 5.0_real64
    type(dyn) :: node
  end type cue_t

contains

  !> True when `nm` is provided by the scene: a name in the walk's
  !! name table (objects, loads, sprites/texts, and -- per the
  !! SS2.2 contract -- the character's emitted named group object,
  !! which registers the character's name there) or an IR object
  !! built by the objects section.
  logical function name_provided(nm)
    character(*), intent(in) :: nm
    type(dyn) :: obj, nv
    integer :: k
    name_provided = .false.
    if (len(nm) == 0) return
    if (dyn_dict_has(vs%names, nm)) then
      name_provided = .true.
      return
    end if
    do k = 1, dyn_list_len(vs%ir_objects)
      obj = dyn_list_at(vs%ir_objects, k)
      nv = dyn_dict_get(obj, "name")
      if (nv%kind == DYN_K_STR) then
        if (nv%s == nm) then
          name_provided = .true.
          return
        end if
      end if
    end do
  end function name_provided


  !> True when `nm` is a defined CHARACTER (E211: only characters
  !! speak; an object name is not sufficient).  Post-desugar a
  !! character is a named placeholder object whose props carry
  !! character=.true. (desugar step 0.5b), and vs%names maps the
  !! name to that node -- so the marker decides.  When the name
  !! table holds no node payload for the name, fall back to mere
  !! provision (name_provided) rather than guessing.
  logical function speaker_is_character(nm)
    character(*), intent(in) :: nm
    type(dyn) :: node, props, v
    speaker_is_character = .false.
    if (.not. dyn_dict_has(vs%names, nm)) return
    node = dyn_dict_get(vs%names, nm)
    if (node%kind /= DYN_K_DICT) then
      speaker_is_character = .true.
      return
    end if
    props = props_of(node)
    v = dyn_dict_get(props, "character")
    if (v%kind == DYN_K_BOOL) then
      speaker_is_character = v%b
    else if (v%kind == DYN_K_NULL) then
      ! A real object node with no character marker: an object,
      ! not a character.
      speaker_is_character = .false.
    else
      speaker_is_character = .true.
    end if
  end function speaker_is_character


  !> The with-exemption for E207 (see the header note).
  logical function pair_with_exempt(a, b)
    type(cue_t), intent(in) :: a, b
    pair_with_exempt = .false.
    if (allocated(a%with_group) .and. allocated(b%with_group)) then
      if (len(a%with_group) > 0 .and. &
          a%with_group == b%with_group) then
        pair_with_exempt = .true.
        return
      end if
    end if
    if (a%start == b%start) then
      if (a%has_with .or. b%has_with) pair_with_exempt = .true.
      if (allocated(a%timing) .and. allocated(b%timing)) then
        if (a%timing == "with" .or. b%timing == "with") &
          pair_with_exempt = .true.
      end if
    end if
  end function pair_with_exempt


  subroutine collect_cues(cues, n_cues)
    type(cue_t), allocatable, intent(out) :: cues(:)
    integer, intent(out) :: n_cues
    type(dyn) :: node, props, v
    integer :: k
    real(real64) :: x
    logical :: has
    allocate (cues(max(1, dyn_list_len(vs%anim_nodes))))
    n_cues = 0
    do k = 1, dyn_list_len(vs%anim_nodes)
      node = dyn_list_at(vs%anim_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "start"], v)
      call get_num(v, x, has)
      if (.not. has) cycle  ! legacy anim: not a timeline cue
      n_cues = n_cues + 1
      cues(n_cues)%node = dyn_copy(node)
      cues(n_cues)%start = x
      call vfield(node, props, [character(12) :: "duration"], v)
      call get_num(v, x, has)
      if (has) cues(n_cues)%dur = x
      call vfield(node, props, [character(12) :: "kind", &
           "motion", "action", "type"], v)
      if (v%kind == DYN_K_NULL) then
        cues(n_cues)%kind = ""
      else
        cues(n_cues)%kind = to_lower(strip_ws(py_str(v)))
      end if
      call vfield(node, props, [character(12) :: "target", &
           "target_name", "object", "name"], v)
      if (v%kind == DYN_K_NULL) then
        cues(n_cues)%target = ""
      else
        cues(n_cues)%target = py_str(v)
      end if
      call vfield(node, props, [character(12) :: "channel"], v)
      if (v%kind == DYN_K_STR .and. len(v%s) > 0) then
        cues(n_cues)%channel = to_lower(v%s)
      else
        cues(n_cues)%channel = "body"
      end if
      call vfield(node, props, [character(12) :: "with_group"], v)
      if (v%kind /= DYN_K_NULL) then
        cues(n_cues)%with_group = py_str(v)
      else
        cues(n_cues)%with_group = ""
      end if
      call vfield(node, props, [character(12) :: "timing"], v)
      if (v%kind == DYN_K_STR) then
        cues(n_cues)%timing = to_lower(v%s)
      else
        cues(n_cues)%timing = ""
      end if
      call vfield(node, props, [character(12) :: "with"], v)
      cues(n_cues)%has_with = (v%kind == DYN_K_BOOL .and. v%b)
    end do
  end subroutine collect_cues


  !> Dialogue survivors: vs%dialogue_nodes (collected by
  !! classify_node), plus -- defensively -- any "say"-marked node
  !! that still landed in vs%text_nodes; those are pruned from
  !! text_nodes here so the Wave B text handling never sees them
  !! (this section runs before waveb).
  subroutine collect_dialogue(dlines, n_dlines)
    type(cue_t), allocatable, intent(out) :: dlines(:)
    integer, intent(out) :: n_dlines
    type(dyn) :: node, props, v, kept
    integer :: k
    real(real64) :: x
    logical :: has
    allocate (dlines(max(1, dyn_list_len(vs%dialogue_nodes) + &
                         dyn_list_len(vs%text_nodes))))
    n_dlines = 0
    do k = 1, dyn_list_len(vs%dialogue_nodes)
      call add_dialogue(dyn_list_at(vs%dialogue_nodes, k), &
                        dlines, n_dlines)
    end do
    kept = dyn_list()
    do k = 1, dyn_list_len(vs%text_nodes)
      node = dyn_list_at(vs%text_nodes, k)
      if (dyn_dict_has(node, "say")) then
        call add_dialogue(node, dlines, n_dlines)
      else
        call dyn_list_push(kept, node)
      end if
    end do
    if (dyn_list_len(kept) /= dyn_list_len(vs%text_nodes)) &
      call dyn_assign(vs%text_nodes, kept)
  end subroutine collect_dialogue


  subroutine add_dialogue(node, dlines, n_dlines)
    type(dyn), intent(in) :: node
    type(cue_t), intent(inout) :: dlines(:)
    integer, intent(inout) :: n_dlines
    type(dyn) :: props, v
    real(real64) :: x
    logical :: has
    n_dlines = n_dlines + 1
    props = props_of(node)
    dlines(n_dlines)%node = dyn_copy(node)
    dlines(n_dlines)%channel = "voice"
    dlines(n_dlines)%kind = "say"
    call vfield(node, props, [character(12) :: "speaker"], v)
    if (v%kind == DYN_K_NULL) then
      dlines(n_dlines)%target = ""
    else
      dlines(n_dlines)%target = py_str(v)
    end if
    call vfield(node, props, [character(12) :: "start"], v)
    call get_num(v, x, has)
    if (has) dlines(n_dlines)%start = x
    call vfield(node, props, [character(12) :: "duration"], v)
    call get_num(v, x, has)
    if (has) dlines(n_dlines)%dur = x
    dlines(n_dlines)%with_group = ""
    dlines(n_dlines)%timing = ""
  end subroutine add_dialogue


  !> E207 for one cue list (anim cues, or dialogue lines).
  subroutine check_overlaps(cues, n_cues)
    type(cue_t), intent(in) :: cues(:)
    integer, intent(in) :: n_cues
    integer :: i, j, a, b
    real(real64) :: a_end, b_end
    do i = 1, n_cues
      do j = i + 1, n_cues
        if (cues(i)%target /= cues(j)%target) cycle
        if (len(cues(i)%target) == 0) cycle
        if (cues(i)%channel /= cues(j)%channel) cycle
        a_end = cues(i)%start + cues(i)%dur
        b_end = cues(j)%start + cues(j)%dur
        if (.not. (cues(i)%start < b_end .and. &
                   cues(j)%start < a_end)) cycle
        if (pair_with_exempt(cues(i), cues(j))) cycle
        ! Report with the earlier cue first (plan SS2.4 example).
        if (cues(i)%start <= cues(j)%start) then
          a = i; b = j
        else
          a = j; b = i
        end if
        call verr_full("E207", &
             "'" // cues(b)%target // "' is already doing '" // &
             cues(a)%kind // "' from " // rstr(cues(a)%start) // &
             "s to " // rstr(cues(a)%start + cues(a)%dur) // &
             "s, so '" // cues(b)%kind // "' cannot start at " // &
             rstr(cues(b)%start) // "s", cues(b)%node, &
             "two " // cues(a)%channel // " actions on the same " // &
             "character cannot overlap", &
             "start '" // cues(b)%kind // "' with 'after " // &
             cues(a)%kind // "', or join it with 'with' if they " // &
             "should play together")
      end do
    end do
  end subroutine check_overlaps


  !> The "@camera" keys track: build_tracks-shaped data for the
  !! pseudo-target, built exactly the way val_waveb_keys builds
  !! ordinary tracks but filtered to "@camera" (which that section
  !! now skips).  Returns the track's end time via cam_end.
  subroutine build_camera_track(cam_end, has_cam)
    real(real64), intent(out) :: cam_end
    logical, intent(out) :: has_cam
    type(dyn) :: headers, raw_keys, tracks, track, snode, sprops, v
    type(dyn) :: hdr, dv, entry, kv2, klist, key
    type(char_list) :: errs
    integer :: k, i
    real(real64) :: dur, tnum, tv(3)
    logical :: has_dur, has3, has_n
    cam_end = 0.0_real64
    has_cam = .false.
    headers = dyn_dict()
    do k = 1, dyn_list_len(vs%keys_header_nodes)
      snode = dyn_list_at(vs%keys_header_nodes, k)
      sprops = props_of(snode)
      call vfield(snode, sprops, [character(12) :: "target"], v)
      if (v%kind /= DYN_K_STR .or. v%s /= "@camera") cycle
      has_cam = .true.
      hdr = dyn_dict()
      call vfield(snode, sprops, [character(12) :: "duration"], dv)
      call get_num(dv, dur, has_dur)
      if (has_dur) then
        call dyn_dict_set(hdr, "duration", dyn_real(dur))
      else
        call dyn_dict_set(hdr, "duration", dyn_null())
      end if
      call vfield(snode, sprops, [character(12) :: "loop"], dv)
      call dyn_dict_set(hdr, "loop", dv)
      call vfield(snode, sprops, [character(12) :: "fps"], dv)
      call get_num(dv, dur, has_dur)
      if (has_dur) call dyn_dict_set(hdr, "fps", dyn_real(dur))
      call dyn_dict_set(headers, "@camera", hdr)
    end do
    raw_keys = dyn_list()
    do k = 1, dyn_list_len(vs%key_nodes)
      snode = dyn_list_at(vs%key_nodes, k)
      sprops = props_of(snode)
      call vfield(snode, sprops, [character(12) :: "target"], v)
      if (v%kind /= DYN_K_STR .or. v%s /= "@camera") cycle
      has_cam = .true.
      entry = dyn_dict()
      call dyn_dict_set(entry, "target", v)
      call vfield(snode, sprops, [character(12) :: "time"], kv2)
      call get_num(kv2, tnum, has_n)
      if (has_n) then
        call dyn_dict_set(entry, "time", dyn_real(tnum))
      else
        call dyn_dict_set(entry, "time", dyn_real(0.0_real64))
      end if
      call vfield(snode, sprops, [character(12) :: "pos", &
                                     "position"], kv2)
      call get_vec3(kv2, tv, has3)
      if (has3) call dyn_dict_set(entry, "pos", vec3_dyn(tv))
      call vfield(snode, sprops, [character(12) :: "rot", &
                                     "rotate"], kv2)
      call get_vec3(kv2, tv, has3)
      if (has3) call dyn_dict_set(entry, "rot", vec3_dyn(tv))
      call vfield(snode, sprops, [character(12) :: "scale"], kv2)
      call get_num(kv2, tnum, has_n)
      if (has_n) call dyn_dict_set(entry, "scale", dyn_real(tnum))
      call vfield(snode, sprops, [character(12) :: "ease"], kv2)
      if (kv2%kind /= DYN_K_NULL) &
        call dyn_dict_set(entry, "ease", &
             dyn_str(to_lower(py_str(kv2))))
      call dyn_list_push(raw_keys, entry)
    end do
    if (.not. has_cam) return
    call build_tracks(headers, raw_keys, tracks)
    errs = char_list()
    call validate_tracks(tracks, errs)
    do i = 1, char_list_len(errs)
      call verr("E201", char_list_at(errs, i))
    end do
    if (.not. dyn_dict_has(tracks, "@camera")) return
    track = dyn_dict_get(tracks, "@camera")
    call set_scene_extension("camera_track", track)
    dv = dyn_dict_get(track, "duration")
    call get_num(dv, dur, has_dur)
    if (has_dur) cam_end = dur
    klist = dyn_dict_get(track, "keys")
    do i = 1, dyn_list_len(klist)
      key = dyn_list_at(klist, i)
      call get_num(dyn_dict_get(key, "time"), tnum, has_n)
      if (has_n) cam_end = max(cam_end, tnum)
    end do
  end subroutine build_camera_track


  !> E210: a `follow` name on any resolved node (cammoves arrive
  !! as keys, so the follow name rides the keys header / key /
  !! anim fields) that nothing provides.
  subroutine check_follow_targets()
    type(dyn) :: seen
    integer :: lst
    seen = dyn_dict()
    do lst = 1, 4
      block
        type(dyn) :: nodes, node, props, v
        integer :: k
        select case (lst)
        case (1); call dyn_assign(nodes, vs%keys_header_nodes)
        case (2); call dyn_assign(nodes, vs%key_nodes)
        case (3); call dyn_assign(nodes, vs%anim_nodes)
        case (4); call dyn_assign(nodes, vs%dialogue_nodes)
        end select
        do k = 1, dyn_list_len(nodes)
          node = dyn_list_at(nodes, k)
          props = props_of(node)
          call vfield(node, props, [character(12) :: "follow"], v)
          if (v%kind /= DYN_K_STR .or. len(v%s) == 0) cycle
          if (dyn_dict_has(seen, v%s)) cycle
          call dyn_dict_set(seen, v%s, dyn_bool(.true.))
          if (name_provided(v%s)) cycle
          call verr_full("E210", &
               "camera follows " // repr_str(v%s) // &
               ", but no character or object is called that", &
               node, &
               "a camera follow target must be a defined " // &
               "character or an object in the scene", &
               "define the character first, or fix the name " // &
               "after 'camera follows'")
        end do
      end block
    end do
  end subroutine check_follow_targets


  !> W203 from desugar's `unused_actions` provenance stamp (see
  !! the header note): a list of action names on any visible node.
  subroutine check_unused_actions()
    type(dyn) :: seen
    integer :: lst
    seen = dyn_dict()
    do lst = 1, 5
      block
        type(dyn) :: nodes, node, props, v, item
        integer :: k, m
        character(16) :: keys(2)
        keys = [character(16) :: "unused_actions", &
                "_unused_actions"]
        select case (lst)
        case (1); call dyn_assign(nodes, vs%anim_nodes)
        case (2); call dyn_assign(nodes, vs%dialogue_nodes)
        case (3); call dyn_assign(nodes, vs%output_nodes)
        case (4); call dyn_assign(nodes, vs%object_nodes)
        case (5); call dyn_assign(nodes, vs%keys_header_nodes)
        end select
        do k = 1, dyn_list_len(nodes)
          node = dyn_list_at(nodes, k)
          props = props_of(node)
          do m = 1, 2
            call vfield(node, props, &
                 [character(16) :: keys(m)], v)
            if (v%kind /= DYN_K_LIST) cycle
            block
              integer :: q
              do q = 1, dyn_list_len(v)
                item = dyn_list_at(v, q)
                if (item%kind /= DYN_K_STR) cycle
                if (dyn_dict_has(seen, item%s)) cycle
                call dyn_dict_set(seen, item%s, dyn_bool(.true.))
                call vwarn_full("W203", &
                     "action " // repr_str(item%s) // &
                     " is defined but never used", node, &
                     "no cue in the film uses this action", &
                     "use it in a cue, like '<who> does " // &
                     item%s // "', or remove the definition")
              end do
            end block
          end do
        end do
      end block
    end do
  end subroutine check_unused_actions


  subroutine val_sec_timeline()
    type(cue_t), allocatable :: cues(:), dlines(:)
    integer :: n_cues, n_dlines, k
    type(dyn) :: node, props, v, ext_list, entry
    real(real64) :: max_end, cam_end, explicit_dur, x
    logical :: has_cam, has_explicit, has
    ! Legacy fast path: nothing timeline-shaped survived desugar,
    ! so this section is a no-op and legacy scenes are untouched.
    if (.not. program_is_film()) return

    call collect_cues(cues, n_cues)
    call collect_dialogue(dlines, n_dlines)

    ! ---- E209: cue targets nothing provides ---------------------
    do k = 1, n_cues
      if (len(cues(k)%target) == 0) cycle
      if (cues(k)%target == "all" .or. cues(k)%target == "it" &
          .or. cues(k)%target == "last") cycle
      if (name_provided(cues(k)%target)) cycle
      call verr_full("E209", &
           "cue targets " // repr_str(cues(k)%target) // &
           ", but no character definition or object provides " // &
           "that name", cues(k)%node, &
           "a cue can only act on a character defined with " // &
           "'character' or an object/group in the scene", &
           "define the character first, or fix the name in " // &
           "the cue")
    end do

    ! ---- E207: same target + same channel overlap ---------------
    call check_overlaps(cues, n_cues)
    call check_overlaps(dlines, n_dlines)

    ! ---- dialogue: E211, W204, and the "dialogue" extension -----
    ext_list = dyn_list()
    do k = 1, n_dlines
      ! dyn_assign, not intrinsic assignment: copying a dyn out
      ! of a stored cue_t component with `=` aliases its nested
      ! allocatables under gfortran and double-frees at scope
      ! exit (the codebase's dyn-copy rule, f3dc_ast header).
      call dyn_assign(node, dlines(k)%node)
      props = props_of(node)
      if (len(dlines(k)%target) > 0) then
        ! caption/title lines are narrator text: their "speaker"
        ! is the caption/title keyword itself, never a character.
        if (dlines(k)%target /= "caption" .and. &
            dlines(k)%target /= "title" .and. &
            .not. speaker_is_character(dlines(k)%target)) then
          call verr_full("E211", &
               "dialogue is spoken by " // &
               repr_str(dlines(k)%target) // &
               ", but no character is called that", node, &
               "only characters speak; an object name is not " // &
               "sufficient for dialogue", &
               "add a 'character " // dlines(k)%target // &
               " ...' line, or change the speaker")
        end if
      end if
      call vfield(node, props, [character(12) :: "estimated", &
           "duration_estimated"], v)
      if (v%kind == DYN_K_BOOL .and. v%b) then
        call vwarn_full("W204", &
             "dialogue duration estimated: " // &
             repr_str(dlines(k)%target) // "'s line at " // &
             rstr(dlines(k)%start) // "s is given " // &
             rstr(dlines(k)%dur) // "s to be read", node, &
             "the line had no written duration, so the " // &
             "compiler estimated the reading time", &
             "write 'for N seconds' on the line to fix its " // &
             "duration")
      end if
      entry = dyn_dict()
      call dyn_dict_set(entry, "speaker", &
           dyn_str(dlines(k)%target))
      call vfield(node, props, [character(12) :: "content", &
           "text"], v)
      if (v%kind == DYN_K_STR) then
        call dyn_dict_set(entry, "text", v)
      else
        call dyn_dict_set(entry, "text", dyn_str(""))
      end if
      call dyn_dict_set(entry, "start", dyn_real(dlines(k)%start))
      call dyn_dict_set(entry, "duration", &
           dyn_real(dlines(k)%dur))
      call dyn_list_push(ext_list, entry)
    end do
    if (dyn_list_len(ext_list) > 0) &
      call set_scene_extension("dialogue", ext_list)

    ! ---- camera: E210 + the "camera_track" extension ------------
    call check_follow_targets()
    call build_camera_track(cam_end, has_cam)

    ! ---- W203: unused actiondefs (provenance permitting) --------
    call check_unused_actions()

    ! ---- E208: timeline overrun vs the EXPLICIT render duration -
    has_explicit = .false.
    explicit_dur = 0.0_real64
    do k = 1, dyn_list_len(vs%output_nodes)
      node = dyn_list_at(vs%output_nodes, k)
      props = props_of(node)
      call vfield(node, props, [character(12) :: "duration"], v)
      call get_num(v, x, has)
      if (has) then
        explicit_dur = x
        has_explicit = .true.
        exit
      end if
    end do
    if (has_explicit) then
      max_end = 0.0_real64
      do k = 1, n_cues
        max_end = max(max_end, cues(k)%start + cues(k)%dur)
      end do
      do k = 1, n_dlines
        max_end = max(max_end, dlines(k)%start + dlines(k)%dur)
      end do
      if (has_cam) max_end = max(max_end, cam_end)
      if (max_end > explicit_dur) then
        call verr("E208", &
             "the timeline runs to " // rstr(max_end) // &
             "s, but the scene renders only " // &
             rstr(explicit_dur) // "s")
      end if
    end if

    ! ---- ir_anim `start` guarantee ------------------------------
    ! val_anim already populated it; when the IR list lines up
    ! 1:1 with the anim nodes (same order), stamp any resolved
    ! start it missed.
    if (dyn_list_len(vs%ir_anims) == dyn_list_len(vs%anim_nodes)) &
      then
      block
        integer :: m
        type(dyn) :: anode, aprops, av, ir_anim
        real(real64) :: sx
        logical :: shas
        do m = 1, dyn_list_len(vs%anim_nodes)
          anode = dyn_list_at(vs%anim_nodes, m)
          aprops = props_of(anode)
          call vfield(anode, aprops, [character(12) :: "start"], &
                      av)
          call get_num(av, sx, shas)
          if (.not. shas .or. sx == 0.0_real64) cycle
          ir_anim = dyn_list_at(vs%ir_anims, m)
          if (.not. dyn_dict_has(ir_anim, "start")) then
            call dyn_dict_set(ir_anim, "start", dyn_real(sx))
            call dyn_list_set_at(vs%ir_anims, m, ir_anim)
          end if
        end do
      end block
    end if
  end subroutine val_sec_timeline

end module f3dc_val_timeline
