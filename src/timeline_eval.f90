! timeline_eval.f90 -- Forge3D Timeline IR film evaluator
! (Animation Compiler Wave 3, slice S4; ANIM-PLAN 4.2/4.6).
!
! Module timeline_eval_3d: loads a .timeline.json (timeline_ir_3d)
! plus every referenced scene, maps the cast onto scene objects,
! and evaluates -- as pure functions of an integer frame -- the
! stickman figure pose (channel blending), the camera track, the
! dialogue interval lookup and scene transitions.
!
! The scalar/channel semantics MIRROR runtime/f3d-timeline.js
! exactly (evalScalarKeys / evalChannels / evalCamera /
! evalPoseKeys / activeDialogue there):
!   * segment progress is eased by the END key's ease; 'hold'
!     holds the segment's start value (ease_value in animation_3d
!     does not know 'hold', so it is special-cased here, exactly
!     as the JS ease('hold', p) = 0 does);
!   * values clamp to the end keys outside the keyed range;
!   * action instances covering a frame (start <= f < end) blend
!     with trapezoid weights (ramp = min(6, span/4) frames):
!     numeric channels get (sum w*v + w_rest*rest) /
!     max(1, sum w + w_rest), w_rest = max(0, 1 - sum w);
!     face.expr takes the covering instance with the largest
!     weight, else the declared rest expression;
!   * rest pose: angles 0; face.expr from identity.face; root
!     from the character's pose_keys track, else the bound
!     object's base position;
!   * dialogue cues are live on the half-open [start, end).
!
! Unmapped data is reported, never faked (reader obligations):
! unknown plugin, a missing scene binding, a binding naming no
! scene object, a failed scene load and unresolved action tracks
! all land in film_state%notes and the character is skipped.
module timeline_eval_3d
    use, intrinsic :: iso_fortran_env, only: real64
    use math_3d, only: dp, vec3, vec3_create, quat, quat_to_euler
    use scene_3d, only: Scene, scene_load, scene_find_object
    use scene_json_3d, only: scene_load_json
    use timeline_ir_3d
    use char_figure_3d
    use keyframe_3d, only: KeyTrack, KeyFrame, key_eval_q
    use animation_3d, only: ease_value
    implicit none
    private

    public :: film_state, film_span, film_char_info
    public :: film_load, film_free, film_span_at, film_fps
    public :: film_eval_pose, film_eval_camera, film_dialogue_at
    public :: film_transition
    public :: film_eval_scalar, film_trap_weight, film_named_color
    public :: film_expr_code
    public :: FILM_MAX_NOTES

    integer, parameter :: FILM_MAX_NOTES = 128

    ! Per-scene-span runtime state.
    type :: film_span
        type(Scene) :: sc
        logical :: loaded = .false.
        ! obj_idx(char_idx) = scene object index, 0 = unmapped.
        integer, allocatable :: obj_idx(:)
        logical, allocatable :: mapped(:)
    end type film_span

    ! Per-character precomputed figure data (from the IR record).
    type :: film_char_info
        type(figure_props) :: props
        type(figure_identity) :: identity
        integer :: base_color(3) = [255, 255, 255]
        real(dp) :: rest_expr = 0.0_dp
        logical :: known_plugin = .false.
    end type film_char_info

    type :: film_state
        type(tl_timeline) :: tl
        character(len=1024) :: dir = ''   ! timeline file directory
        type(film_span), allocatable :: spans(:)
        type(film_char_info), allocatable :: chars(:)
        integer :: n_unresolved = 0
        integer :: n_notes = 0
        character(len=512) :: notes(FILM_MAX_NOTES) = ''
    end type film_state

contains

    subroutine film_add_note(state, msg)
        type(film_state), intent(inout) :: state
        character(len=*), intent(in) :: msg
        if (state%n_notes < FILM_MAX_NOTES) then
            state%n_notes = state%n_notes + 1
            state%notes(state%n_notes) = msg
        end if
    end subroutine film_add_note

    real(dp) function film_fps(state) result(r)
        type(film_state), intent(in) :: state
        if (state%tl%fps_den > 0) then
            r = real(state%tl%fps_num, dp) / real(state%tl%fps_den, dp)
        else
            r = 24.0_dp
        end if
    end function film_fps

    ! Mirror of named_color in compiler/src/f3dc_emit_common.f90
    ! (~line 1014; NAMED_RGB table there): src/ has no name table,
    ! so this is the engine-side copy. Keys are lower-case.
    subroutine film_named_color(name, rgb, found)
        character(len=*), intent(in) :: name
        integer, intent(out) :: rgb(3)
        logical, intent(out) :: found
        character(len=32) :: key
        integer :: i
        key = ''
        do i = 1, min(len_trim(name), 32)
            key(i:i) = name(i:i)
            if (key(i:i) >= 'A' .and. key(i:i) <= 'Z') &
                key(i:i) = char(ichar(key(i:i)) + 32)
        end do
        found = .true.
        select case (trim(key))
        case ('red');     rgb = [220, 60, 60]
        case ('green');   rgb = [60, 220, 60]
        case ('blue');    rgb = [60, 100, 240]
        case ('yellow');  rgb = [240, 220, 50]
        case ('magenta'); rgb = [200, 80, 220]
        case ('cyan');    rgb = [60, 220, 220]
        case ('orange');  rgb = [240, 140, 40]
        case ('purple');  rgb = [140, 80, 200]
        case ('pink');    rgb = [240, 150, 190]
        case ('white');   rgb = [240, 240, 240]
        case ('black');   rgb = [20, 20, 25]
        case ('gray', 'grey'); rgb = [140, 140, 145]
        case default
            rgb = [255, 255, 255]
            found = .false.
        end select
    end subroutine film_named_color

    ! Face name -> face.expr code (mirror of expr_code_of in
    ! compiler/src/f3dc_emit_timeline.f90).
    real(dp) function film_expr_code(name) result(code)
        character(len=*), intent(in) :: name
        select case (trim(name))
        case ('happy');      code = 1.0_dp
        case ('sad');        code = 2.0_dp
        case ('determined'); code = 3.0_dp
        case ('surprised');  code = 4.0_dp
        case default;        code = 0.0_dp
        end select
    end function film_expr_code

    ! Trapezoid weight of one action instance over [start, end)
    ! (mirror of trapWeight in runtime/f3d-timeline.js).
    real(dp) function film_trap_weight(start_f, end_f, frame) &
            result(w)
        integer, intent(in) :: start_f, end_f, frame
        real(dp) :: span, ramp
        span = real(end_f - start_f, dp)
        if (span <= 0.0_dp) then
            w = 1.0_dp
            return
        end if
        ramp = min(6.0_dp, span / 4.0_dp)
        if (ramp <= 0.0_dp) then
            w = 1.0_dp
            return
        end if
        w = min(real(frame - start_f, dp) / ramp, &
                real(end_f - frame, dp) / ramp, 1.0_dp)
        w = max(0.0_dp, min(1.0_dp, w))
    end function film_trap_weight

    ! Scalar key evaluation (mirror of evalScalarKeys in
    ! runtime/f3d-timeline.js): clamp outside the key range;
    ! inside, segment progress eased by the END key's ease, with
    ! 'hold' returning the segment's start value.
    real(dp) function film_eval_scalar(frames, values, eases, n, &
                                       frame) result(v)
        integer, intent(in) :: n, frame
        integer, intent(in) :: frames(n)
        real(dp), intent(in) :: values(n)
        character(len=*), intent(in) :: eases(n)
        integer :: i
        real(dp) :: p
        v = 0.0_dp
        if (n <= 0) return
        if (frame <= frames(1)) then
            v = values(1)
            return
        end if
        if (frame >= frames(n)) then
            v = values(n)
            return
        end if
        do i = 1, n - 1
            if (frames(i) <= frame .and. frame < frames(i + 1)) then
                if (trim(eases(i + 1)) == 'hold') then
                    v = values(i)
                    return
                end if
                if (frames(i + 1) > frames(i)) then
                    p = real(frame - frames(i), dp) / &
                        real(frames(i + 1) - frames(i), dp)
                else
                    p = 0.0_dp
                end if
                v = values(i) + (values(i + 1) - values(i)) * &
                    ease_value(trim(eases(i + 1)), p)
                return
            end if
        end do
        v = values(n)
    end function film_eval_scalar

    ! ----------------------------------------------------------------
    ! Loading
    ! ----------------------------------------------------------------

    subroutine film_load(timeline_path, state, ok, errmsg)
        character(len=*), intent(in) :: timeline_path
        type(film_state), intent(out) :: state
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        integer :: si, ci, bi, slash, i
        character(len=1024) :: scene_path, serr
        logical :: sok

        ok = .false.
        errmsg = ''
        state = film_state()
        call read_timeline(trim(timeline_path), state%tl, ok, errmsg)
        if (.not. ok) return

        ! Directory of the timeline file (scene_file resolves
        ! relative to it).
        slash = index(trim(timeline_path), '/', back=.true.)
        if (slash > 0) then
            state%dir = timeline_path(1:slash - 1)
        else
            state%dir = ''
        end if

        ! Reader diagnostics carry into the film notes.
        do i = 1, state%tl%n_notes
            call film_add_note(state, trim(state%tl%notes(i)))
        end do
        if (state%tl%n_skipped_tracks > 0) &
            state%n_unresolved = state%n_unresolved + &
                                 state%tl%n_skipped_tracks

        ! ---- per-character figure data ----
        allocate(state%chars(max(1, state%tl%n_characters)))
        do ci = 1, state%tl%n_characters
            call build_char_info(state, ci)
        end do

        ! ---- per-span scenes + bindings ----
        allocate(state%spans(max(1, state%tl%n_scenes)))
        do si = 1, state%tl%n_scenes
            allocate(state%spans(si)%obj_idx( &
                max(1, state%tl%n_characters)))
            allocate(state%spans(si)%mapped( &
                max(1, state%tl%n_characters)))
            state%spans(si)%obj_idx = 0
            state%spans(si)%mapped = .false.
            if (len_trim(state%dir) > 0) then
                scene_path = trim(state%dir) // '/' // &
                    trim(state%tl%scenes(si)%scene_file)
            else
                scene_path = trim(state%tl%scenes(si)%scene_file)
            end if
            i = len_trim(scene_path)
            if (i > 5 .and. scene_path(i - 4:i) == '.json') then
                call scene_load_json(trim(scene_path), &
                    state%spans(si)%sc, sok, serr)
            else
                call scene_load(trim(scene_path), &
                    state%spans(si)%sc, sok, serr)
            end if
            if (.not. sok) then
                call film_add_note(state, 'scene "' // &
                    trim(state%tl%scenes(si)%id) // &
                    '" failed to load (' // trim(serr) // &
                    '); span skipped')
                cycle
            end if
            state%spans(si)%loaded = .true.
            do ci = 1, state%tl%n_characters
                if (.not. state%chars(ci)%known_plugin) cycle
                ! Find this character's binding in the span.
                bi = 0
                do i = 1, state%tl%scenes(si)%n_bindings
                    if (trim(state%tl%scenes(si)%bindings(i)%key) &
                        == trim(state%tl%characters(ci)%id)) then
                        bi = i
                        exit
                    end if
                end do
                if (bi == 0) then
                    call film_add_note(state, 'character "' // &
                        trim(state%tl%characters(ci)%id) // '" has no binding in scene "' &
                        // trim(state%tl%scenes(si)%id) // &
                        '" (off-stage); skipped')
                    cycle
                end if
                state%spans(si)%obj_idx(ci) = scene_find_object( &
                    state%spans(si)%sc, &
                    trim(state%tl%scenes(si)%bindings(bi)%value))
                if (state%spans(si)%obj_idx(ci) <= 0) then
                    call film_add_note(state, 'character "' // &
                        trim(state%tl%characters(ci)%id) // '" binding "' // &
                        trim(state%tl%scenes(si)%bindings(bi)%value) &
                        // '" not found in scene "' // &
                        trim(state%tl%scenes(si)%id) // '"; skipped')
                    state%spans(si)%obj_idx(ci) = 0
                    cycle
                end if
                state%spans(si)%mapped(ci) = .true.
            end do
        end do

        ! Unresolved action tracks are unmapped, never approximated.
        do i = 1, state%tl%n_tracks
            if (trim(state%tl%tracks(i)%kind) == 'action' .and. &
                state%tl%tracks(i)%has_resolved .and. &
                .not. state%tl%tracks(i)%resolved) then
                state%n_unresolved = state%n_unresolved + 1
                call film_add_note(state, 'action "' // &
                    trim(state%tl%tracks(i)%action) // &
                    '" (character "' // &
                    trim(state%tl%tracks(i)%character) // &
                    '") is unresolved; reported unmapped')
            end if
        end do
        ok = .true.
    end subroutine film_load

    subroutine build_char_info(state, ci)
        type(film_state), intent(inout) :: state
        integer, intent(in) :: ci
        integer :: wi, rgb(3)
        logical :: found
        state%chars(ci)%known_plugin = .false.
        if (allocated(state%tl%characters(ci)%plugin)) &
            state%chars(ci)%known_plugin = trim(state%tl%characters(ci)%plugin) == 'stickman'
        if (.not. state%chars(ci)%known_plugin) then
            call film_add_note(state, 'character "' // trim(state%tl%characters(ci)%id) &
                // '" has unknown plugin "' // trim(state%tl%characters(ci)%plugin) // &
                '"; figure skipped')
        end if
        if (state%tl%characters(ci)%has_color) state%chars(ci)%base_color = state%tl%characters(ci)%color
        state%chars(ci)%props = props_from_spec(trim(state%tl%characters(ci)%proportions_word), &
            state%tl%characters(ci)%height, state%tl%characters(ci)%has_height, state%chars(ci)%base_color)
        ! Identity mapping: IR identity -> figure_identity.
        if (len_trim(state%tl%characters(ci)%id_head) > 0) &
            state%chars(ci)%identity%head_style = trim(state%tl%characters(ci)%id_head)
        state%chars(ci)%identity%hair = trim(state%tl%characters(ci)%id_hair)
        state%chars(ci)%identity%holds = trim(state%tl%characters(ci)%id_holds)
        state%chars(ci)%rest_expr = film_expr_code(state%tl%characters(ci)%id_face)
        block
            integer :: nw
            nw = 0
            do wi = 1, state%tl%characters(ci)%n_wears
                if (nw >= FIG_MAX_WEARS) exit
                nw = nw + 1
                state%chars(ci)%identity%wears(nw)%item = &
                    trim(state%tl%characters(ci)%wears(wi)%item)
                call film_named_color(state%tl%characters(ci)%wears(wi)%colour, rgb, found)
                state%chars(ci)%identity%wears(nw)%color = rgb
            end do
            state%chars(ci)%identity%n_wears = nw
        end block
    end subroutine build_char_info

    subroutine film_free(state)
        type(film_state), intent(inout) :: state
        state = film_state()
    end subroutine film_free

    ! Span index covering a global frame (half-open), 0 if none.
    integer function film_span_at(state, frame) result(si)
        type(film_state), intent(in) :: state
        integer, intent(in) :: frame
        integer :: i
        si = 0
        do i = 1, state%tl%n_scenes
            if (state%tl%scenes(i)%start_frame <= frame .and. &
                frame < state%tl%scenes(i)%end_frame) then
                si = i
                return
            end if
        end do
    end function film_span_at

    ! ----------------------------------------------------------------
    ! Pose evaluation
    ! ----------------------------------------------------------------

    ! The character's pose_keys track for a span (0 = none).
    integer function find_pose_track(state, span_idx, char_idx) &
            result(ti)
        type(film_state), intent(in) :: state
        integer, intent(in) :: span_idx, char_idx
        integer :: i
        ti = 0
        do i = 1, state%tl%n_tracks
            if (trim(state%tl%tracks(i)%kind) /= 'pose_keys') cycle
            if (.not. allocated(state%tl%tracks(i)%character)) cycle
            if (trim(state%tl%tracks(i)%character) /= &
                trim(state%tl%characters(char_idx)%id)) cycle
            if (len_trim(state%tl%tracks(i)%scene) > 0 .and. &
                trim(state%tl%tracks(i)%scene) /= &
                trim(state%tl%scenes(span_idx)%id)) cycle
            ti = i
            return
        end do
    end function find_pose_track

    ! Evaluate one numeric channel for a character at a frame,
    ! blending every covering action instance (JS evalChannels).
    subroutine eval_channel(state, span_idx, char_idx, frame, &
                            chan_idx, rest_val, val, is_expr, found_any)
        type(film_state), intent(in) :: state
        integer, intent(in) :: span_idx, char_idx, frame, chan_idx
        real(dp), intent(in) :: rest_val
        real(dp), intent(out) :: val
        logical, intent(in) :: is_expr
        logical, intent(out) :: found_any
        character(len=16) :: cname
        integer :: ti, ki, nk, st, en
        real(dp) :: sum_w, sum_wv, w, v, w_rest, best_w, best_v
        integer, allocatable :: kframes(:)
        real(dp), allocatable :: kvals(:)
        character(len=32), allocatable :: keases(:)

        cname = figure_channel_name(chan_idx)
        sum_w = 0.0_dp
        sum_wv = 0.0_dp
        best_w = -1.0_dp
        best_v = rest_val
        found_any = .false.
        do ti = 1, state%tl%n_tracks
            if (trim(state%tl%tracks(ti)%kind) /= 'action') cycle
            if (state%tl%tracks(ti)%has_resolved .and. &
                .not. state%tl%tracks(ti)%resolved) cycle
            if (.not. allocated(state%tl%tracks(ti)%character)) cycle
            if (trim(state%tl%tracks(ti)%character) /= &
                trim(state%tl%characters(char_idx)%id)) cycle
            if (span_idx >= 1 .and. span_idx <= state%tl%n_scenes) then
                if (len_trim(state%tl%tracks(ti)%scene) > 0 .and. &
                    trim(state%tl%tracks(ti)%scene) /= &
                    trim(state%tl%scenes(span_idx)%id)) cycle
            end if
            ! Collect this track's keys for the channel.
            nk = 0
            do ki = 1, state%tl%tracks(ti)%n_keys
                if (.not. allocated(state%tl%tracks(ti)%keys(ki)%channel)) cycle
                if (trim(state%tl%tracks(ti)%keys(ki)%channel) &
                    == trim(cname)) nk = nk + 1
            end do
            if (nk == 0) cycle
            allocate(kframes(nk), kvals(nk), keases(nk))
            nk = 0
            do ki = 1, state%tl%tracks(ti)%n_keys
                if (.not. allocated(state%tl%tracks(ti)%keys(ki)%channel)) cycle
                if (trim(state%tl%tracks(ti)%keys(ki)%channel) &
                    /= trim(cname)) cycle
                nk = nk + 1
                kframes(nk) = state%tl%tracks(ti)%keys(ki)%frame
                if (state%tl%tracks(ti)%keys(ki)%has_value) then
                    kvals(nk) = state%tl%tracks(ti)%keys(ki)%value
                else if (state%tl%tracks(ti)%keys(ki)%has_value_deg) then
                    kvals(nk) = state%tl%tracks(ti)%keys(ki)%value_deg
                else
                    kvals(nk) = 0.0_dp
                end if
                keases(nk) = trim(state%tl%tracks(ti)%keys(ki)%ease)
            end do
            st = state%tl%tracks(ti)%start_frame
            en = state%tl%tracks(ti)%end_frame
            if (.not. state%tl%tracks(ti)%has_start) st = kframes(1)
            if (.not. state%tl%tracks(ti)%has_end) en = kframes(nk)
            if (st <= frame .and. frame < en) then
                w = film_trap_weight(st, en, frame)
                v = film_eval_scalar(kframes, kvals, keases, nk, frame)
                sum_w = sum_w + w
                sum_wv = sum_wv + w * v
                if (w > best_w) then
                    best_w = w
                    best_v = v
                end if
                found_any = .true.
            end if
            deallocate(kframes, kvals, keases)
        end do
        if (is_expr) then
            val = best_v
        else if (.not. found_any) then
            val = rest_val
        else
            w_rest = max(0.0_dp, 1.0_dp - sum_w)
            val = (sum_wv + w_rest * rest_val) / &
                  max(1.0_dp, sum_w + w_rest)
        end if
    end subroutine eval_channel

    ! film_eval_pose: the figure pose for one character at a global
    ! frame, plus the object transform from its pose_keys track.
    ! pose root channels hold the FINAL root (pose_keys root blended
    ! with root.x/y/z action channels); root_world is the same root
    ! as a vector; obj_rot_deg / obj_scale come from pose_keys.
    subroutine film_eval_pose(state, span_idx, char_idx, frame, &
                              pose, root_world, obj_rot_deg, obj_scale)
        type(film_state), intent(in) :: state
        integer, intent(in) :: span_idx, char_idx, frame
        type(figure_pose), intent(out) :: pose
        real(dp), intent(out) :: root_world(3), obj_rot_deg(3), &
                                 obj_scale(3)
        integer :: ti, ci
        type(KeyTrack) :: kt
        real(dp) :: k_pos(3), k_s3(3), rest(16), v
        type(quat) :: k_q
        type(vec3) :: eul
        logical :: found_any, have_pose

        root_world = 0.0_dp
        obj_rot_deg = 0.0_dp
        obj_scale = 1.0_dp
        pose = pose_rest(state%chars(char_idx)%rest_expr)

        ! Rest root / object transform from pose_keys (key_eval_q;
        ! KeyTrack fps = timeline fps, key times = frames, evaluated
        ! at t = frame / fps).
        ti = find_pose_track(state, span_idx, char_idx)
        have_pose = .false.
        if (ti > 0) then
          if (state%tl%tracks(ti)%n_keys > 0) then
            have_pose = .true.
            kt%target = trim(state%tl%characters(char_idx)%id)
            kt%fps = film_fps(state)
            kt%loop = 'once'
            kt%duration = 0.0_dp
            allocate(kt%keys(state%tl%tracks(ti)%n_keys))
            do ci = 1, state%tl%tracks(ti)%n_keys
                kt%keys(ci)%time = &
                    real(state%tl%tracks(ti)%keys(ci)%frame, dp)
                if (state%tl%tracks(ti)%keys(ci)%has_pos) &
                    kt%keys(ci)%pos = state%tl%tracks(ti)%keys(ci)%pos
                if (state%tl%tracks(ti)%keys(ci)%has_rot) &
                    kt%keys(ci)%rot_deg = &
                        state%tl%tracks(ti)%keys(ci)%rot_deg
                if (state%tl%tracks(ti)%keys(ci)%has_scale) then
                    kt%keys(ci)%scale = &
                        state%tl%tracks(ti)%keys(ci)%scale
                    kt%keys(ci)%scale3 = &
                        state%tl%tracks(ti)%keys(ci)%scale3
                    kt%keys(ci)%has_scale3 = .true.
                end if
                kt%keys(ci)%ease = &
                    trim(state%tl%tracks(ti)%keys(ci)%ease)
            end do
            call key_eval_q(kt, real(frame, dp) / film_fps(state), &
                            k_pos, k_q, k_s3)
            root_world = k_pos
            eul = quat_to_euler(k_q)
            obj_rot_deg = [eul%x, eul%y, eul%z]
            obj_scale = k_s3
            deallocate(kt%keys)
          end if
        end if
        if (.not. have_pose) then
          if (span_idx >= 1 .and. span_idx <= state%tl%n_scenes) then
            if (state%spans(span_idx)%loaded) then
              if (state%spans(span_idx)%mapped(char_idx)) then
                block
                    integer :: oi
                    oi = state%spans(span_idx)%obj_idx(char_idx)
                    root_world = [ &
                        state%spans(span_idx)%sc%objects(oi)%pos%x, &
                        state%spans(span_idx)%sc%objects(oi)%pos%y, &
                        state%spans(span_idx)%sc%objects(oi)%pos%z]
                    obj_rot_deg = [ &
                        state%spans(span_idx)%sc%objects(oi)%rot_deg%x, &
                        state%spans(span_idx)%sc%objects(oi)%rot_deg%y, &
                        state%spans(span_idx)%sc%objects(oi)%rot_deg%z]
                    obj_scale = [ &
                        state%spans(span_idx)%sc%objects(oi)%scl%x, &
                        state%spans(span_idx)%sc%objects(oi)%scl%y, &
                        state%spans(span_idx)%sc%objects(oi)%scl%z]
                end block
              end if
            end if
          end if
        end if

        ! Rest channels: angles 0, face.expr declared, root = the
        ! pose_keys root, root.face rest = pose rot yaw.
        rest = 0.0_dp
        rest(CH_ROOT_X) = root_world(1)
        rest(CH_ROOT_Y) = root_world(2)
        rest(CH_ROOT_Z) = root_world(3)
        rest(CH_ROOT_FACE) = obj_rot_deg(2)
        rest(CH_FACE_EXPR) = state%chars(char_idx)%rest_expr
        do ci = 1, 16
            call eval_channel(state, span_idx, char_idx, frame, ci, &
                              rest(ci), v, ci == CH_FACE_EXPR, &
                              found_any)
            pose%ch(ci) = v
        end do
        root_world = pose%ch(CH_ROOT_X:CH_ROOT_Z)
    end subroutine film_eval_pose

    ! ----------------------------------------------------------------
    ! Camera
    ! ----------------------------------------------------------------

    subroutine film_eval_camera(state, span_idx, frame, cam_pos, &
                                cam_target, fov, found)
        type(film_state), intent(in) :: state
        integer, intent(in) :: span_idx, frame
        real(dp), intent(out) :: cam_pos(3), cam_target(3), fov
        logical, intent(out) :: found
        integer :: ti, ki, nk, comp
        integer, allocatable :: kframes(:)
        real(dp), allocatable :: kvals(:)
        character(len=32), allocatable :: keases(:)
        found = .false.
        cam_pos = 0.0_dp
        cam_target = 0.0_dp
        fov = 60.0_dp
        if (span_idx < 1 .or. span_idx > state%tl%n_scenes) return
        ti = 0
        do ki = 1, state%tl%n_tracks
            if (trim(state%tl%tracks(ki)%kind) /= 'camera') cycle
            if (len_trim(state%tl%tracks(ki)%scene) > 0 .and. &
                trim(state%tl%tracks(ki)%scene) /= &
                trim(state%tl%scenes(span_idx)%id)) cycle
            ti = ki
            exit
        end do
        if (ti == 0) return
        if (state%tl%tracks(ti)%n_keys == 0) return
        nk = state%tl%tracks(ti)%n_keys
        allocate(kframes(nk), kvals(nk), keases(nk))
        do ki = 1, nk
            kframes(ki) = state%tl%tracks(ti)%keys(ki)%frame
            keases(ki) = trim(state%tl%tracks(ti)%keys(ki)%ease)
        end do
        do comp = 1, 3
            do ki = 1, nk
                if (state%tl%tracks(ti)%keys(ki)%has_pos) then
                    kvals(ki) = state%tl%tracks(ti)%keys(ki)%pos(comp)
                else
                    kvals(ki) = 0.0_dp
                end if
            end do
            cam_pos(comp) = film_eval_scalar(kframes, kvals, keases, &
                                             nk, frame)
            do ki = 1, nk
                if (state%tl%tracks(ti)%keys(ki)%has_target) then
                    kvals(ki) = &
                        state%tl%tracks(ti)%keys(ki)%target(comp)
                else
                    kvals(ki) = 0.0_dp
                end if
            end do
            cam_target(comp) = film_eval_scalar(kframes, kvals, &
                                                keases, nk, frame)
        end do
        do ki = 1, nk
            if (state%tl%tracks(ti)%keys(ki)%has_fov) then
                kvals(ki) = state%tl%tracks(ti)%keys(ki)%fov
            else
                kvals(ki) = 60.0_dp
            end if
        end do
        fov = film_eval_scalar(kframes, kvals, keases, nk, frame)
        deallocate(kframes, kvals, keases)
        found = .true.
    end subroutine film_eval_camera

    ! ----------------------------------------------------------------
    ! Dialogue + transitions
    ! ----------------------------------------------------------------

    ! Active dialogue cues at a frame (half-open [start, end)).
    subroutine film_dialogue_at(state, frame, cues_out, n)
        type(film_state), intent(in) :: state
        integer, intent(in) :: frame
        type(tl_dialogue_cue), allocatable, intent(out) :: cues_out(:)
        integer, intent(out) :: n
        integer :: i
        n = 0
        do i = 1, state%tl%n_dialogue
            if (state%tl%dialogue(i)%start_frame <= frame .and. &
                frame < state%tl%dialogue(i)%end_frame) n = n + 1
        end do
        allocate(cues_out(max(1, n)))
        n = 0
        do i = 1, state%tl%n_dialogue
            if (state%tl%dialogue(i)%start_frame <= frame .and. &
                frame < state%tl%dialogue(i)%end_frame) then
                n = n + 1
                cues_out(n) = state%tl%dialogue(i)
            end if
        end do
    end subroutine film_dialogue_at

    ! Transition state at a global frame: when the frame lies in
    ! the opening window of span_idx (and span_idx is not the
    ! first span), in_transition is true, prev_span_idx is the
    ! previous span, and alpha = (local_frame + 0.5) / duration.
    subroutine film_transition(state, frame, span_idx, in_transition, &
                               prev_span_idx, alpha)
        type(film_state), intent(in) :: state
        integer, intent(in) :: frame, span_idx
        logical, intent(out) :: in_transition
        integer, intent(out) :: prev_span_idx
        real(dp), intent(out) :: alpha
        integer :: local_f, dur
        in_transition = .false.
        prev_span_idx = 0
        alpha = 0.0_dp
        if (span_idx < 2 .or. span_idx > state%tl%n_scenes) return
        if (.not. state%tl%scenes(span_idx)%has_transition) return
        dur = state%tl%scenes(span_idx)%transition_duration_frames
        if (dur <= 0) return
        local_f = frame - state%tl%scenes(span_idx)%start_frame
        if (local_f < 0 .or. local_f >= dur) return
        in_transition = .true.
        prev_span_idx = span_idx - 1
        alpha = (real(local_f, dp) + 0.5_dp) / real(dur, dp)
    end subroutine film_transition

end module timeline_eval_3d
