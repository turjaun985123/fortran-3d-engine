! test_timeline_eval.f90 -- Wave 3 slice S4: scalar channel
! evaluation + action blending in timeline_eval_3d, mirroring
! runtime/f3d-timeline.js semantics (evalScalarKeys/evalChannels).
!
! Coverage: linear midpoint, hold step, clamp outside the key
! range; two full-weight constant tracks blending to the mean;
! trapezoid edge weight; face.expr largest-weight rule; fps
! independence (same timeline at 15/24/30 fps gives identical
! channel values at shared absolute times); pose_keys root
! override via key_eval_q; one file-based case over the committed
! fixture tests/fixtures/sample.timeline.json.
program test_timeline_eval
    use, intrinsic :: iso_fortran_env, only: real64
    use timeline_eval_3d
    use timeline_ir_3d
    use char_figure_3d, only: figure_pose, CH_ARM_R_UPPER, &
        CH_TORSO, CH_FACE_EXPR, CH_ROOT_X
    use test_assert
    implicit none

    call check_scalar()
    call check_blending()
    call check_trapezoid_edge()
    call check_face_expr()
    call check_fps_independence()
    call check_pose_keys()
    call check_file_case()
    call test_summary()

contains

    subroutine check_scalar()
        integer :: fr(2)
        real(real64) :: va(2)
        character(len=32) :: ea(2)
        fr = [0, 10]
        va = [0.0_real64, 100.0_real64]
        ea = [character(len=32) :: 'linear', 'linear']
        call assert_real_close(film_eval_scalar(fr, va, ea, 2, 5), &
            50.0_real64, 1.0e-12_real64, 'scalar linear midpoint')
        call assert_real_close(film_eval_scalar(fr, va, ea, 2, -3), &
            0.0_real64, 1.0e-12_real64, 'scalar clamps below range')
        call assert_real_close(film_eval_scalar(fr, va, ea, 2, 99), &
            100.0_real64, 1.0e-12_real64, 'scalar clamps above range')
        ea(2) = 'hold'
        call assert_real_close(film_eval_scalar(fr, va, ea, 2, 5), &
            0.0_real64, 1.0e-12_real64, 'hold keeps start value')
        call assert_real_close(film_eval_scalar(fr, va, ea, 2, 10), &
            100.0_real64, 1.0e-12_real64, 'hold steps at end key')
        ea(2) = 'smooth'
        call assert_real_close(film_eval_scalar(fr, va, ea, 2, 5), &
            50.0_real64, 1.0e-12_real64, 'smooth midpoint is 0.5')
    end subroutine check_scalar

    ! One character 'mira', one scene 's1'; caller fills tracks.
    subroutine base_state(state, n_tracks)
        type(film_state), intent(out) :: state
        integer, intent(in) :: n_tracks
        state = film_state()
        state%tl%fps_num = 24
        state%tl%fps_den = 1
        state%tl%duration_frames = 48
        allocate(state%tl%characters(1))
        state%tl%n_characters = 1
        state%tl%characters(1)%id = 'mira'
        state%tl%characters(1)%name = 'mira'
        state%tl%characters(1)%plugin = 'stickman'
        allocate(state%tl%scenes(1))
        state%tl%n_scenes = 1
        state%tl%scenes(1)%id = 's1'
        state%tl%scenes(1)%start_frame = 0
        state%tl%scenes(1)%duration_frames = 48
        state%tl%scenes(1)%end_frame = 48
        allocate(state%tl%tracks(n_tracks))
        state%tl%n_tracks = n_tracks
        allocate(state%chars(1))
        allocate(state%spans(1))
        state%spans(1)%loaded = .false.
        allocate(state%spans(1)%obj_idx(1))
        allocate(state%spans(1)%mapped(1))
        state%spans(1)%mapped = .false.
    end subroutine base_state

    subroutine const_track(state, ti, channel, value, st, en, &
                           use_value)
        type(film_state), intent(inout) :: state
        integer, intent(in) :: ti, st, en
        character(len=*), intent(in) :: channel
        real(real64), intent(in) :: value
        logical, intent(in) :: use_value
        state%tl%tracks(ti)%kind = 'action'
        state%tl%tracks(ti)%scene = 's1'
        state%tl%tracks(ti)%character = 'mira'
        state%tl%tracks(ti)%action = 'test'
        state%tl%tracks(ti)%start_frame = st
        state%tl%tracks(ti)%has_start = .true.
        state%tl%tracks(ti)%end_frame = en
        state%tl%tracks(ti)%has_end = .true.
        allocate(state%tl%tracks(ti)%keys(1))
        state%tl%tracks(ti)%n_keys = 1
        state%tl%tracks(ti)%keys(1)%frame = st
        state%tl%tracks(ti)%keys(1)%channel = channel
        state%tl%tracks(ti)%keys(1)%ease = 'linear'
        if (use_value) then
            state%tl%tracks(ti)%keys(1)%value = value
            state%tl%tracks(ti)%keys(1)%has_value = .true.
        else
            state%tl%tracks(ti)%keys(1)%value_deg = value
            state%tl%tracks(ti)%keys(1)%has_value_deg = .true.
        end if
    end subroutine const_track

    subroutine check_blending()
        type(film_state) :: state
        type(figure_pose) :: pose
        real(real64) :: root(3), rot(3), scl(3)
        call base_state(state, 2)
        call const_track(state, 1, 'arm.r.upper', 10.0_real64, &
                         0, 48, .false.)
        call const_track(state, 2, 'arm.r.upper', 20.0_real64, &
                         0, 48, .false.)
        call film_eval_pose(state, 1, 1, 24, pose, root, rot, scl)
        call assert_real_close(pose%ch(CH_ARM_R_UPPER), &
            15.0_real64, 1.0e-12_real64, &
            'two full-weight tracks 10/20 blend to 15')
    end subroutine check_blending

    subroutine check_trapezoid_edge()
        type(film_state) :: state
        type(figure_pose) :: pose
        real(real64) :: root(3), rot(3), scl(3)
        call base_state(state, 1)
        call const_track(state, 1, 'arm.r.upper', 20.0_real64, &
                         0, 48, .false.)
        ! Frame 3 is halfway up the 6-frame ramp: w = 0.5, so the
        ! value is (0.5*20 + 0.5*rest 0) / 1 = 10.
        call film_eval_pose(state, 1, 1, 3, pose, root, rot, scl)
        call assert_real_close(pose%ch(CH_ARM_R_UPPER), &
            10.0_real64, 1.0e-12_real64, &
            'trapezoid edge: half weight at frame 3')
        call assert_real_close(film_trap_weight(0, 48, 24), &
            1.0_real64, 1.0e-12_real64, 'trap weight 1 mid-span')
        call assert_real_close(film_trap_weight(0, 48, 0), &
            0.0_real64, 1.0e-12_real64, 'trap weight 0 at start')
    end subroutine check_trapezoid_edge

    subroutine check_face_expr()
        type(film_state) :: state
        type(figure_pose) :: pose
        real(real64) :: root(3), rot(3), scl(3)
        call base_state(state, 2)
        state%chars(1)%rest_expr = 0.0_real64
        call const_track(state, 1, 'face.expr', 1.0_real64, &
                         0, 30, .true.)
        call const_track(state, 2, 'face.expr', 2.0_real64, &
                         24, 48, .true.)
        ! Frame 29: track 1 weight (30-29)/6 = 1/6, track 2 weight
        ! (29-24)/6 = 5/6 -> the larger weight (expr 2) wins.
        call film_eval_pose(state, 1, 1, 29, pose, root, rot, scl)
        call assert_real_close(pose%ch(CH_FACE_EXPR), &
            2.0_real64, 1.0e-12_real64, &
            'face.expr: largest weight wins')
        ! Frame 10: only track 1 covers -> expr 1.
        call film_eval_pose(state, 1, 1, 10, pose, root, rot, scl)
        call assert_real_close(pose%ch(CH_FACE_EXPR), &
            1.0_real64, 1.0e-12_real64, &
            'face.expr: single covering track')
        ! Frame 40: only track 2 covers -> expr 2; frame 47 in
        ! range; a frame with no coverage would give rest (0).
        call film_eval_pose(state, 1, 1, 40, pose, root, rot, scl)
        call assert_real_close(pose%ch(CH_FACE_EXPR), &
            2.0_real64, 1.0e-12_real64, &
            'face.expr: second track alone')
    end subroutine check_face_expr

    subroutine fps_state(state, fps)
        type(film_state), intent(out) :: state
        integer, intent(in) :: fps
        call base_state(state, 1)
        state%tl%fps_num = fps
        state%tl%fps_den = 1
        state%tl%tracks(1)%kind = 'action'
        state%tl%tracks(1)%scene = 's1'
        state%tl%tracks(1)%character = 'mira'
        state%tl%tracks(1)%start_frame = 0
        state%tl%tracks(1)%has_start = .true.
        state%tl%tracks(1)%end_frame = 2 * fps
        state%tl%tracks(1)%has_end = .true.
        allocate(state%tl%tracks(1)%keys(2))
        state%tl%tracks(1)%n_keys = 2
        state%tl%tracks(1)%keys(1)%frame = 0
        state%tl%tracks(1)%keys(1)%channel = 'torso'
        state%tl%tracks(1)%keys(1)%ease = 'linear'
        state%tl%tracks(1)%keys(1)%value_deg = 0.0_real64
        state%tl%tracks(1)%keys(1)%has_value_deg = .true.
        state%tl%tracks(1)%keys(2)%frame = 2 * fps
        state%tl%tracks(1)%keys(2)%channel = 'torso'
        state%tl%tracks(1)%keys(2)%ease = 'linear'
        state%tl%tracks(1)%keys(2)%value_deg = 40.0_real64
        state%tl%tracks(1)%keys(2)%has_value_deg = .true.
    end subroutine fps_state

    subroutine check_fps_independence()
        type(film_state) :: s15, s24, s30
        type(figure_pose) :: p15, p24, p30
        real(real64) :: root(3), rot(3), scl(3)
        call fps_state(s15, 15)
        call fps_state(s24, 24)
        call fps_state(s30, 30)
        ! t = 1.0 s is frame fps in each timeline; the torso key
        ! pair spans 2 s, 0 -> 40 deg, so all three give 20 deg.
        ! (At t=1s the trapezoid weight is 1 in all three, so the
        ! blend denominator is exactly the weight sum.)
        call film_eval_pose(s15, 1, 1, 15, p15, root, rot, scl)
        call film_eval_pose(s24, 1, 1, 24, p24, root, rot, scl)
        call film_eval_pose(s30, 1, 1, 30, p30, root, rot, scl)
        call assert_real_close(p15%ch(CH_TORSO), 20.0_real64, &
            1.0e-9_real64, 'fps 15: torso at t=1s is 20')
        call assert_real_close(p24%ch(CH_TORSO), 20.0_real64, &
            1.0e-9_real64, 'fps 24: torso at t=1s is 20')
        call assert_real_close(p30%ch(CH_TORSO), 20.0_real64, &
            1.0e-9_real64, 'fps 30: torso at t=1s is 20')
        call assert_real_close(p15%ch(CH_TORSO) - p30%ch(CH_TORSO), &
            0.0_real64, 1.0e-9_real64, 'fps independence 15 vs 30')
    end subroutine check_fps_independence

    subroutine check_pose_keys()
        type(film_state) :: state
        type(figure_pose) :: pose
        real(real64) :: root(3), rot(3), scl(3)
        call base_state(state, 1)
        state%tl%tracks(1)%kind = 'pose_keys'
        state%tl%tracks(1)%scene = 's1'
        state%tl%tracks(1)%character = 'mira'
        allocate(state%tl%tracks(1)%keys(2))
        state%tl%tracks(1)%n_keys = 2
        state%tl%tracks(1)%keys(1)%frame = 0
        state%tl%tracks(1)%keys(1)%ease = 'linear'
        state%tl%tracks(1)%keys(1)%pos = [1.0_real64, 2.0_real64, &
                                          3.0_real64]
        state%tl%tracks(1)%keys(1)%has_pos = .true.
        state%tl%tracks(1)%keys(1)%rot_deg = [0.0_real64, &
            -20.0_real64, 0.0_real64]
        state%tl%tracks(1)%keys(1)%has_rot = .true.
        state%tl%tracks(1)%keys(2)%frame = 48
        state%tl%tracks(1)%keys(2)%ease = 'linear'
        state%tl%tracks(1)%keys(2)%pos = [4.0_real64, 2.0_real64, &
                                          3.0_real64]
        state%tl%tracks(1)%keys(2)%has_pos = .true.
        state%tl%tracks(1)%keys(2)%rot_deg = [0.0_real64, &
            -35.0_real64, 0.0_real64]
        state%tl%tracks(1)%keys(2)%has_rot = .true.
        call film_eval_pose(state, 1, 1, 24, pose, root, rot, scl)
        call assert_real_close(root(1), 2.5_real64, &
            1.0e-9_real64, 'pose_keys root override x at midpoint')
        call assert_real_close(root(2), 2.0_real64, &
            1.0e-9_real64, 'pose_keys root y')
        call assert_real_close(pose%ch(CH_ROOT_X), 2.5_real64, &
            1.0e-9_real64, 'pose root channel follows pose_keys')
        call assert_real_close(scl(1), 1.0_real64, &
            1.0e-9_real64, 'pose_keys default scale 1')
    end subroutine check_pose_keys

    subroutine check_file_case()
        type(film_state) :: state
        type(figure_pose) :: pose
        real(real64) :: root(3), rot(3), scl(3)
        logical :: ok
        character(len=1024) :: errmsg, env, path
        integer :: st
        call get_environment_variable('FORGE3D_ROOT', env, status=st)
        if (st /= 0 .or. len_trim(env) == 0) env = '.'
        path = trim(env) // '/tests/fixtures/sample.timeline.json'
        call film_load(trim(path), state, ok, errmsg)
        call assert_true(ok, 'film_load sample fixture: ' // &
                         trim(errmsg))
        if (.not. ok) return
        call assert_true(state%n_notes >= 1, &
            'missing span scene reported as a film note')
        ! Mira's wave at frame 36 sits exactly on the -150 key.
        call film_eval_pose(state, 1, 1, 36, pose, root, rot, scl)
        call assert_real_close(pose%ch(CH_ARM_R_UPPER), &
            -150.0_real64, 1.0e-9_real64, &
            'file case: wave key at frame 36')
    end subroutine check_file_case

end program test_timeline_eval
