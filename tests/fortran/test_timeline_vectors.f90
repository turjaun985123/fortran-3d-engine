! test_timeline_vectors.f90 -- Wave 3 Slice S5: shared timeline
! test vectors, Fortran consumer.
!
! Reads tests/fixtures/timeline_vectors.json (the SAME file the JS
! consumer tests/compiler/test_timeline_vectors_js.js asserts) and
! drives the REAL engine entry points, one kind per fixture case:
!   channel_eval -> film_eval_scalar (timeline_eval_3d)
!   blend        -> film_eval_pose over a directly constructed
!                   film_state (the eval_channel trapezoid blend)
!   pose_keys    -> key_eval_q (keyframe_3d; the fps case carries
!                   KeyTrack%fps = 12 and is probed at t in seconds)
!   camera       -> film_eval_camera over a constructed film_state
!   fk           -> props_from_spec + figure_fk (char_figure_3d)
!   dialogue     -> film_dialogue_at over a constructed film_state
!
! Tolerances mirror the JS consumer: 1e-9 for scalars / positions
! / joints, 1e-12 for quaternions (sign-aligned, q ~ -q).
!
! Fixture path: argv(1) if given, else the repo-relative default
! (the suite runs test programs from the repo root).
program test_timeline_vectors
    use, intrinsic :: iso_fortran_env, only: real64
    use math_3d, only: dp, quat, quat_dot, quat_create
    use json_reader_3d
    use timeline_eval_3d
    use timeline_ir_3d, only: tl_dialogue_cue
    use char_figure_3d
    use keyframe_3d, only: KeyTrack, key_eval_q
    use test_assert
    implicit none

    integer, parameter :: TK_NUM = 2, TK_STR = 3, TK_ARR = 4

    character(len=512) :: path
    character(len=:), allocatable :: text
    type(json_doc) :: doc
    logical :: ok
    character(len=256) :: errmsg
    integer :: ncases, i
    integer :: n_ce, n_bl, n_pk, n_cam, n_fk, n_di

    if (command_argument_count() >= 1) then
        call get_command_argument(1, path)
    else
        path = 'tests/fixtures/timeline_vectors.json'
    end if

    call read_text_file(trim(path), text, ok)
    call assert_true(ok, 'fixture file readable: ' // trim(path))
    if (.not. ok) call test_summary()

    call json_parse(text, doc, ok, errmsg)
    call assert_true(ok, 'fixture JSON parses')
    if (.not. ok) then
        write(*, '(A)') '       parse error: ' // trim(errmsg)
        call test_summary()
    end if
    call assert_int_eq(TK_ARR, json_kind(doc, doc%root), &
        'fixture root is a JSON array')

    ncases = json_arr_len(doc, doc%root)
    call assert_int_eq(26, ncases, 'fixture case count is 26')

    n_ce = 0; n_bl = 0; n_pk = 0; n_cam = 0; n_fk = 0; n_di = 0
    do i = 1, ncases
        call run_case(doc, i, n_ce, n_bl, n_pk, n_cam, n_fk, n_di)
    end do
    call assert_int_eq(8, n_ce, 'fixture channel_eval cases seen')
    call assert_int_eq(3, n_bl, 'fixture blend cases seen')
    call assert_int_eq(4, n_pk, 'fixture pose_keys cases seen')
    call assert_int_eq(3, n_cam, 'fixture camera cases seen')
    call assert_int_eq(6, n_fk, 'fixture fk cases seen')
    call assert_int_eq(2, n_di, 'fixture dialogue cases seen')
    call json_free(doc)
    call test_summary()

contains

    subroutine run_case(doc, idx, n_ce, n_bl, n_pk, n_cam, n_fk, n_di)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: idx
        integer, intent(inout) :: n_ce, n_bl, n_pk, n_cam, n_fk, n_di
        integer :: obj
        logical :: found
        character(len=:), allocatable :: kind, name
        call json_arr_at(doc, doc%root, idx, obj)
        call get_str_field(doc, obj, 'name', name, found)
        if (.not. found) name = '?'
        call get_str_field(doc, obj, 'kind', kind, found)
        if (.not. found) kind = '?'
        select case (trim(kind))
        case ('channel_eval')
            n_ce = n_ce + 1
            call case_channel_eval(doc, obj, trim(name))
        case ('blend')
            n_bl = n_bl + 1
            call case_blend(doc, obj, trim(name))
        case ('pose_keys')
            n_pk = n_pk + 1
            call case_pose_keys(doc, obj, trim(name))
        case ('camera')
            n_cam = n_cam + 1
            call case_camera(doc, obj, trim(name))
        case ('fk')
            n_fk = n_fk + 1
            call case_fk(doc, obj, trim(name))
        case ('dialogue')
            n_di = n_di + 1
            call case_dialogue(doc, obj, trim(name))
        case default
            call assert_true(.false., &
                'fixture case has a known kind: ' // trim(name))
        end select
    end subroutine run_case

    ! ---------------------------------------------------------------
    ! channel_eval: film_eval_scalar directly.
    ! ---------------------------------------------------------------
    subroutine case_channel_eval(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        real(dp), allocatable :: fnum(:), values(:)
        character(len=32), allocatable :: eases(:)
        integer, allocatable :: frames(:)
        integer :: n, frame, i
        real(dp) :: expected, v
        logical :: found
        call get_num_arr(doc, obj, 'frames', fnum, n)
        call get_num_arr(doc, obj, 'values', values, n)
        call get_str_arr(doc, obj, 'eases', eases, n)
        allocate(frames(n))
        do i = 1, n
            frames(i) = nint(fnum(i))
        end do
        call get_int_field(doc, obj, 'frame', frame, found)
        call get_num_field(doc, obj, 'expected', expected, found)
        v = film_eval_scalar(frames, values, eases, n, frame)
        call assert_real_close(v, expected, 1.0e-9_dp, &
            'fixture ' // name // ': film_eval_scalar')
    end subroutine case_channel_eval

    ! ---------------------------------------------------------------
    ! Shared film_state scaffold (mirrors test_timeline_eval.f90):
    ! one character 'mira', one scene span 's1', caller fills tracks.
    ! ---------------------------------------------------------------
    subroutine base_state(state, n_tracks)
        type(film_state), intent(out) :: state
        integer, intent(in) :: n_tracks
        state = film_state()
        state%tl%fps_num = 24
        state%tl%fps_den = 1
        state%tl%duration_frames = 96
        allocate(state%tl%characters(1))
        state%tl%n_characters = 1
        state%tl%characters(1)%id = 'mira'
        state%tl%characters(1)%name = 'mira'
        state%tl%characters(1)%plugin = 'stickman'
        allocate(state%tl%scenes(1))
        state%tl%n_scenes = 1
        state%tl%scenes(1)%id = 's1'
        state%tl%scenes(1)%start_frame = 0
        state%tl%scenes(1)%duration_frames = 96
        state%tl%scenes(1)%end_frame = 96
        allocate(state%tl%tracks(n_tracks))
        state%tl%n_tracks = n_tracks
        allocate(state%chars(1))
        allocate(state%spans(1))
        state%spans(1)%loaded = .false.
        allocate(state%spans(1)%obj_idx(1))
        allocate(state%spans(1)%mapped(1))
        state%spans(1)%mapped = .false.
    end subroutine base_state

    integer function channel_index(channel) result(idx)
        character(len=*), intent(in) :: channel
        integer :: i
        idx = 0
        do i = 1, N_CHANNELS
            if (trim(figure_channel_name(i)) == trim(channel)) then
                idx = i
                return
            end if
        end do
    end function channel_index

    ! Fill one action track of a constructed state from a fixture
    ! track object {start, end, frames[], values[], eases[]}.
    subroutine fill_action_track(state, ti, tnode, doc, channel)
        type(film_state), intent(inout) :: state
        integer, intent(in) :: ti, tnode
        type(json_doc), intent(in) :: doc
        character(len=*), intent(in) :: channel
        real(dp), allocatable :: fnum(:), values(:)
        character(len=32), allocatable :: eases(:)
        integer :: nk, ki, st, en
        logical :: found
        call get_int_field(doc, tnode, 'start', st, found)
        call get_int_field(doc, tnode, 'end', en, found)
        call get_num_arr(doc, tnode, 'frames', fnum, nk)
        call get_num_arr(doc, tnode, 'values', values, nk)
        call get_str_arr(doc, tnode, 'eases', eases, nk)
        state%tl%tracks(ti)%kind = 'action'
        state%tl%tracks(ti)%scene = 's1'
        state%tl%tracks(ti)%character = 'mira'
        state%tl%tracks(ti)%action = 'vec'
        state%tl%tracks(ti)%start_frame = st
        state%tl%tracks(ti)%has_start = .true.
        state%tl%tracks(ti)%end_frame = en
        state%tl%tracks(ti)%has_end = .true.
        allocate(state%tl%tracks(ti)%keys(nk))
        state%tl%tracks(ti)%n_keys = nk
        do ki = 1, nk
            state%tl%tracks(ti)%keys(ki)%frame = nint(fnum(ki))
            state%tl%tracks(ti)%keys(ki)%channel = trim(channel)
            state%tl%tracks(ti)%keys(ki)%ease = trim(eases(ki))
            state%tl%tracks(ti)%keys(ki)%value = values(ki)
            state%tl%tracks(ti)%keys(ki)%has_value = .true.
        end do
    end subroutine fill_action_track

    ! ---------------------------------------------------------------
    ! blend: film_eval_pose (eval_channel) over a constructed state.
    ! ---------------------------------------------------------------
    subroutine case_blend(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        type(film_state) :: state
        type(figure_pose) :: pose
        real(dp) :: root(3), rot(3), scl(3), rest, expected
        integer :: tnode, tracks_node, ntr, ti, frame, ci
        character(len=:), allocatable :: channel
        logical :: found
        call get_str_field(doc, obj, 'channel', channel, found)
        call get_num_field(doc, obj, 'rest', rest, found)
        call get_num_field(doc, obj, 'expected', expected, found)
        call get_int_field(doc, obj, 'frame', frame, found)
        call json_obj_get(doc, obj, 'tracks', tracks_node, found)
        call assert_true(found, 'fixture ' // name // ': tracks key')
        ntr = json_arr_len(doc, tracks_node)
        call base_state(state, ntr)
        state%chars(1)%rest_expr = rest
        do ti = 1, ntr
            call json_arr_at(doc, tracks_node, ti, tnode)
            call fill_action_track(state, ti, tnode, doc, &
                                   trim(channel))
        end do
        ci = channel_index(trim(channel))
        call assert_true(ci > 0, 'fixture ' // name // &
                         ': channel is a rig channel')
        call film_eval_pose(state, 1, 1, frame, pose, root, rot, scl)
        call assert_real_close(pose%ch(ci), expected, 1.0e-9_dp, &
            'fixture ' // name // ': blended channel value')
    end subroutine case_blend

    ! ---------------------------------------------------------------
    ! pose_keys: key_eval_q directly (fps conversion included).
    ! ---------------------------------------------------------------
    subroutine case_pose_keys(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        type(KeyTrack) :: kt
        type(quat) :: q
        real(dp) :: pos(3), s3(3), exp_pos(3), exp_s3(3), exp_q(4)
        real(dp) :: t, fps_v
        integer :: knode, keys_node, nk, ki, frame
        character(len=:), allocatable :: ease_s
        logical :: found, has_fps, has_t
        call json_obj_get(doc, obj, 'keys', keys_node, found)
        nk = json_arr_len(doc, keys_node)
        kt%target = 'mira'
        kt%loop = 'once'
        kt%duration = 0.0_dp
        call get_num_field(doc, obj, 'fps', fps_v, has_fps)
        if (has_fps) then
            kt%fps = fps_v
        else
            kt%fps = 0.0_dp
        end if
        allocate(kt%keys(nk))
        do ki = 1, nk
            call json_arr_at(doc, keys_node, ki, knode)
            call get_int_field(doc, knode, 'frame', frame, found)
            kt%keys(ki)%time = real(frame, dp)
            call get_num_arr3(doc, knode, 'pos', kt%keys(ki)%pos, &
                              found)
            call get_num_arr3(doc, knode, 'rot_deg', &
                              kt%keys(ki)%rot_deg, found)
            call get_str_field(doc, knode, 'ease', ease_s, found)
            if (found) kt%keys(ki)%ease = trim(ease_s)
            call get_num_arr3(doc, knode, 'scale3', &
                              kt%keys(ki)%scale3, found)
            if (found) kt%keys(ki)%has_scale3 = .true.
        end do
        call get_num_field(doc, obj, 't_seconds', t, has_t)
        if (.not. has_t) then
            call get_int_field(doc, obj, 'frame', frame, found)
            t = real(frame, dp)
        end if
        call key_eval_q(kt, t, pos, q, s3)
        call get_num_arr3(doc, obj, 'expected_pos', exp_pos, found)
        call get_num_arr3(doc, obj, 'expected_scale3', exp_s3, found)
        block
            real(dp), allocatable :: qarr(:)
            integer :: nq
            call get_num_arr(doc, obj, 'expected_quat', qarr, nq)
            exp_q = qarr(1:4)
        end block
        do ki = 1, 3
            call assert_real_close(pos(ki), exp_pos(ki), 1.0e-9_dp, &
                'fixture ' // name // ': key_eval_q pos')
            call assert_real_close(s3(ki), exp_s3(ki), 1.0e-9_dp, &
                'fixture ' // name // ': key_eval_q scale3')
        end do
        call assert_quat_close(q, &
            quat_create(exp_q(1), exp_q(2), exp_q(3), exp_q(4)), &
            'fixture ' // name // ': key_eval_q quat')
        deallocate(kt%keys)
    end subroutine case_pose_keys

    subroutine assert_quat_close(q, qe, msg)
        type(quat), intent(in) :: q, qe
        character(len=*), intent(in) :: msg
        type(quat) :: e
        e = qe
        if (quat_dot(q, qe) < 0.0_dp) then
            e%x = -qe%x; e%y = -qe%y; e%z = -qe%z; e%w = -qe%w
        end if
        call assert_real_close(q%x, e%x, 1.0e-12_dp, msg // ' [x]')
        call assert_real_close(q%y, e%y, 1.0e-12_dp, msg // ' [y]')
        call assert_real_close(q%z, e%z, 1.0e-12_dp, msg // ' [z]')
        call assert_real_close(q%w, e%w, 1.0e-12_dp, msg // ' [w]')
    end subroutine assert_quat_close

    ! ---------------------------------------------------------------
    ! camera: film_eval_camera over a constructed state.
    ! ---------------------------------------------------------------
    subroutine case_camera(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        type(film_state) :: state
        real(dp) :: cp(3), ct(3), fov, exp_pos(3), exp_tgt(3), exp_fov
        integer :: knode, keys_node, nk, ki, frame, kframe
        character(len=:), allocatable :: ease_s
        logical :: found, cfound
        call base_state(state, 1)
        state%tl%tracks(1)%kind = 'camera'
        state%tl%tracks(1)%scene = 's1'
        call json_obj_get(doc, obj, 'keys', keys_node, found)
        nk = json_arr_len(doc, keys_node)
        allocate(state%tl%tracks(1)%keys(nk))
        state%tl%tracks(1)%n_keys = nk
        do ki = 1, nk
            call json_arr_at(doc, keys_node, ki, knode)
            call get_int_field(doc, knode, 'frame', kframe, found)
            state%tl%tracks(1)%keys(ki)%frame = kframe
            call get_str_field(doc, knode, 'ease', ease_s, found)
            if (found) state%tl%tracks(1)%keys(ki)%ease = &
                trim(ease_s)
            call get_num_arr3(doc, knode, 'pos', &
                state%tl%tracks(1)%keys(ki)%pos, found)
            state%tl%tracks(1)%keys(ki)%has_pos = found
            call get_num_arr3(doc, knode, 'target', &
                state%tl%tracks(1)%keys(ki)%target, found)
            state%tl%tracks(1)%keys(ki)%has_target = found
            call get_num_field(doc, knode, 'fov', &
                state%tl%tracks(1)%keys(ki)%fov, found)
            state%tl%tracks(1)%keys(ki)%has_fov = found
        end do
        call get_int_field(doc, obj, 'frame', frame, found)
        call film_eval_camera(state, 1, frame, cp, ct, fov, cfound)
        call assert_true(cfound, 'fixture ' // name // &
                         ': camera track found')
        call get_num_arr3(doc, obj, 'expected_pos', exp_pos, found)
        call get_num_arr3(doc, obj, 'expected_target', exp_tgt, found)
        call get_num_field(doc, obj, 'expected_fov', exp_fov, found)
        do ki = 1, 3
            call assert_real_close(cp(ki), exp_pos(ki), 1.0e-9_dp, &
                'fixture ' // name // ': camera pos')
            call assert_real_close(ct(ki), exp_tgt(ki), 1.0e-9_dp, &
                'fixture ' // name // ': camera target')
        end do
        call assert_real_close(fov, exp_fov, 1.0e-9_dp, &
            'fixture ' // name // ': camera fov')
    end subroutine case_camera

    ! ---------------------------------------------------------------
    ! fk: props_from_spec + figure_fk.
    ! ---------------------------------------------------------------
    integer function joint_index(jname) result(idx)
        character(len=*), intent(in) :: jname
        select case (trim(jname))
        case ('hip');        idx = J_HIP_C
        case ('head');       idx = J_HEAD
        case ('neck');       idx = J_NECK
        case ('shoulder.l'); idx = J_SHOULDER_L
        case ('shoulder.r'); idx = J_SHOULDER_R
        case ('elbow.l');    idx = J_ELBOW_L
        case ('elbow.r');    idx = J_ELBOW_R
        case ('hand.l');     idx = J_HAND_L
        case ('hand.r');     idx = J_HAND_R
        case ('hip.l');      idx = J_HIP_L
        case ('hip.r');      idx = J_HIP_R
        case ('knee.l');     idx = J_KNEE_L
        case ('knee.r');     idx = J_KNEE_R
        case ('foot.l');     idx = J_FOOT_L
        case ('foot.r');     idx = J_FOOT_R
        case default;        idx = 0
        end select
    end function joint_index

    subroutine case_fk(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        type(figure_props) :: props
        type(figure_pose) :: pose
        real(dp) :: uv(2, N_JOINTS), height, val, exp_uv(2)
        integer :: pcnode, pcs_node, np, pi, chnode, checks_node, &
                   nc, ci2, child
        character(len=:), allocatable :: word, chan, jname
        logical :: found, has_height
        call get_str_field(doc, obj, 'proportions', word, found)
        has_height = .false.
        height = 0.0_dp
        call json_obj_get(doc, obj, 'height', child, found)
        if (found .and. json_kind(doc, child) == TK_NUM) then
            has_height = .true.
            height = json_num(doc, child, 0.0_dp)
        end if
        props = props_from_spec(trim(word), height, has_height)
        pose = pose_rest(0.0_dp)
        call json_obj_get(doc, obj, 'pose_channels', pcs_node, found)
        np = json_arr_len(doc, pcs_node)
        do pi = 1, np
            call json_arr_at(doc, pcs_node, pi, pcnode)
            call get_str_field(doc, pcnode, 'channel', chan, found)
            call get_num_field(doc, pcnode, 'value', val, found)
            ci2 = channel_index(trim(chan))
            call assert_true(ci2 > 0, 'fixture ' // name // &
                ': pose channel is a rig channel')
            if (ci2 > 0) pose%ch(ci2) = val
        end do
        uv = figure_fk(pose, props)
        call json_obj_get(doc, obj, 'checks', checks_node, found)
        nc = json_arr_len(doc, checks_node)
        do pi = 1, nc
            call json_arr_at(doc, checks_node, pi, chnode)
            call get_str_field(doc, chnode, 'joint', jname, found)
            block
                real(dp), allocatable :: uvarr(:)
                integer :: nuv
                call get_num_arr(doc, chnode, 'uv', uvarr, nuv)
                exp_uv = uvarr(1:2)
            end block
            ci2 = joint_index(trim(jname))
            call assert_true(ci2 > 0, 'fixture ' // name // &
                ': joint is a figure joint: ' // trim(jname))
            if (ci2 <= 0) cycle
            call assert_real_close(uv(1, ci2), exp_uv(1), 1.0e-9_dp, &
                'fixture ' // name // ': joint ' // trim(jname) // ' u')
            call assert_real_close(uv(2, ci2), exp_uv(2), 1.0e-9_dp, &
                'fixture ' // name // ': joint ' // trim(jname) // ' v')
        end do
    end subroutine case_fk

    ! ---------------------------------------------------------------
    ! dialogue: film_dialogue_at over a constructed state.
    ! ---------------------------------------------------------------
    subroutine case_dialogue(doc, obj, name)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: name
        type(film_state) :: state
        type(tl_dialogue_cue), allocatable :: cues_out(:)
        integer :: qnode, cues_node, nq, qi, frame, exp_count, n
        character(len=:), allocatable :: sval, exp_speaker
        logical :: found
        state = film_state()
        call json_obj_get(doc, obj, 'cues', cues_node, found)
        nq = json_arr_len(doc, cues_node)
        allocate(state%tl%dialogue(max(1, nq)))
        state%tl%n_dialogue = nq
        do qi = 1, nq
            call json_arr_at(doc, cues_node, qi, qnode)
            state%tl%dialogue(qi)%id = 'd'
            state%tl%dialogue(qi)%scene = 's1'
            call get_int_field(doc, qnode, 'start', &
                state%tl%dialogue(qi)%start_frame, found)
            call get_int_field(doc, qnode, 'end', &
                state%tl%dialogue(qi)%end_frame, found)
            call get_str_field(doc, qnode, 'speaker', sval, found)
            if (found) state%tl%dialogue(qi)%speaker = sval
            call get_str_field(doc, qnode, 'text', sval, found)
            if (found) state%tl%dialogue(qi)%text = sval
        end do
        call get_int_field(doc, obj, 'frame', frame, found)
        call get_int_field(doc, obj, 'expected_count', exp_count, &
                           found)
        call film_dialogue_at(state, frame, cues_out, n)
        call assert_int_eq(n, exp_count, &
            'fixture ' // name // ': live cue count')
        if (exp_count > 0 .and. n > 0) then
            call get_str_field(doc, obj, 'expected_speaker', &
                               exp_speaker, found)
            call assert_true(found .and. &
                trim(cues_out(1)%speaker) == trim(exp_speaker), &
                'fixture ' // name // ': live cue speaker')
        end if
    end subroutine case_dialogue

    ! ---------------------------------------------------------------
    ! JSON helpers (mirroring test_math_quat.f90's helpers).
    ! ---------------------------------------------------------------

    subroutine get_num_field(doc, obj, key, val, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        real(dp), intent(out) :: val
        logical, intent(out) :: found
        integer :: child
        val = 0.0_dp
        call json_obj_get(doc, obj, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= TK_NUM) then
            found = .false.
            return
        end if
        val = json_num(doc, child, 0.0_dp)
    end subroutine get_num_field

    subroutine get_int_field(doc, obj, key, val, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        integer, intent(out) :: val
        logical, intent(out) :: found
        real(dp) :: rv
        val = 0
        call get_num_field(doc, obj, key, rv, found)
        if (found) val = nint(rv)
    end subroutine get_int_field

    subroutine get_str_field(doc, obj, key, val, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        character(len=:), allocatable, intent(out) :: val
        logical, intent(out) :: found
        integer :: child
        call json_obj_get(doc, obj, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= TK_STR) then
            found = .false.
            return
        end if
        val = json_str(doc, child)
    end subroutine get_str_field

    subroutine get_num_arr(doc, obj, key, vals, n)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        real(dp), allocatable, intent(out) :: vals(:)
        integer, intent(out) :: n
        integer :: child, el, k
        logical :: found
        n = 0
        allocate(vals(0))
        call json_obj_get(doc, obj, key, child, found)
        if (.not. found) then
            call assert_true(.false., 'fixture key present: ' // key)
            return
        end if
        n = json_arr_len(doc, child)
        deallocate(vals)
        allocate(vals(max(1, n)))
        do k = 1, n
            call json_arr_at(doc, child, k, el)
            vals(k) = json_num(doc, el, 0.0_dp)
        end do
    end subroutine get_num_arr

    subroutine get_num_arr3(doc, obj, key, vals, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        real(dp), intent(out) :: vals(3)
        logical, intent(out) :: found
        integer :: child, el, k
        vals = 0.0_dp
        call json_obj_get(doc, obj, key, child, found)
        if (.not. found) return
        if (json_arr_len(doc, child) /= 3) then
            found = .false.
            return
        end if
        do k = 1, 3
            call json_arr_at(doc, child, k, el)
            vals(k) = json_num(doc, el, 0.0_dp)
        end do
    end subroutine get_num_arr3

    subroutine get_str_arr(doc, obj, key, vals, n)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: obj
        character(len=*), intent(in) :: key
        character(len=32), allocatable, intent(out) :: vals(:)
        integer, intent(out) :: n
        integer :: child, el, k
        logical :: found
        character(len=:), allocatable :: s
        n = 0
        allocate(vals(0))
        call json_obj_get(doc, obj, key, child, found)
        if (.not. found) then
            call assert_true(.false., 'fixture key present: ' // key)
            return
        end if
        n = json_arr_len(doc, child)
        deallocate(vals)
        allocate(vals(max(1, n)))
        do k = 1, n
            call json_arr_at(doc, child, k, el)
            s = json_str(doc, el)
            vals(k) = s
            deallocate(s)
        end do
    end subroutine get_str_arr

    subroutine read_text_file(path, text, ok)
        character(len=*), intent(in) :: path
        character(len=:), allocatable, intent(out) :: text
        logical, intent(out) :: ok
        integer :: u, ios, sz
        ok = .false.
        open(newunit=u, file=path, status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) return
        inquire(unit=u, size=sz)
        if (sz <= 0) then
            close(u)
            return
        end if
        allocate(character(len=sz) :: text)
        read(u, iostat=ios) text
        close(u)
        if (ios /= 0) return
        ok = .true.
    end subroutine read_text_file

end program test_timeline_vectors
