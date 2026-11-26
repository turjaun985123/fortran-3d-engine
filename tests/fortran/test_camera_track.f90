! test_camera_track.f90 -- Wave 3 slice S4: camera track
! evaluation in timeline_eval_3d (mirror of evalCamera in
! runtime/f3d-timeline.js): componentwise lerp eased by the
! segment END key, clamped outside the keyed range, and
! found=.false. when the span has no camera track.
program test_camera_track
    use, intrinsic :: iso_fortran_env, only: real64
    use timeline_eval_3d
    use timeline_ir_3d
    use test_assert
    implicit none

    type(film_state) :: state
    real(real64) :: pos(3), tgt(3), fov
    logical :: found

    call base_state(state, .true.)
    call film_eval_camera(state, 1, 24, pos, tgt, fov, found)
    call assert_true(found, 'camera track found')
    call assert_real_close(pos(1), 5.0_real64, 1.0e-12_real64, &
        'camera midpoint lerp x (smooth p=0.5 -> 0.5)')
    call assert_real_close(tgt(2), 1.0_real64, 1.0e-12_real64, &
        'camera midpoint target y')
    call assert_real_close(fov, 50.0_real64, 1.0e-12_real64, &
        'camera midpoint fov')

    ! Ease effect: 'in' at p=0.5 eases to 0.25, not 0.5.
    state%tl%tracks(1)%keys(2)%ease = 'in'
    call film_eval_camera(state, 1, 24, pos, tgt, fov, found)
    call assert_real_close(pos(1), 2.5_real64, 1.0e-12_real64, &
        'camera ease-in bends the midpoint')

    ! Clamp beyond both ends.
    call film_eval_camera(state, 1, 99, pos, tgt, fov, found)
    call assert_real_close(pos(1), 10.0_real64, 1.0e-12_real64, &
        'camera clamps past the last key')
    call assert_real_close(fov, 40.0_real64, 1.0e-12_real64, &
        'camera fov clamps past the last key')
    call film_eval_camera(state, 1, -5, pos, tgt, fov, found)
    call assert_real_close(pos(1), 0.0_real64, 1.0e-12_real64, &
        'camera clamps before the first key')

    ! No camera track -> found=.false.
    call base_state(state, .false.)
    call film_eval_camera(state, 1, 24, pos, tgt, fov, found)
    call assert_false(found, 'no camera track: found is false')

    call test_summary()

contains

    subroutine base_state(state, with_cam)
        type(film_state), intent(out) :: state
        logical, intent(in) :: with_cam
        state = film_state()
        state%tl%fps_num = 24
        state%tl%fps_den = 1
        allocate(state%tl%scenes(1))
        state%tl%n_scenes = 1
        state%tl%scenes(1)%id = 's1'
        state%tl%scenes(1)%start_frame = 0
        state%tl%scenes(1)%duration_frames = 48
        state%tl%scenes(1)%end_frame = 48
        if (with_cam) then
            allocate(state%tl%tracks(1))
            state%tl%n_tracks = 1
            state%tl%tracks(1)%kind = 'camera'
            state%tl%tracks(1)%scene = 's1'
            allocate(state%tl%tracks(1)%keys(2))
            state%tl%tracks(1)%n_keys = 2
            state%tl%tracks(1)%keys(1)%frame = 0
            state%tl%tracks(1)%keys(1)%ease = 'linear'
            state%tl%tracks(1)%keys(1)%pos = [0.0_real64, &
                0.0_real64, 10.0_real64]
            state%tl%tracks(1)%keys(1)%has_pos = .true.
            state%tl%tracks(1)%keys(1)%target = [0.0_real64, &
                0.0_real64, 0.0_real64]
            state%tl%tracks(1)%keys(1)%has_target = .true.
            state%tl%tracks(1)%keys(1)%fov = 60.0_real64
            state%tl%tracks(1)%keys(1)%has_fov = .true.
            state%tl%tracks(1)%keys(2)%frame = 48
            state%tl%tracks(1)%keys(2)%ease = 'smooth'
            state%tl%tracks(1)%keys(2)%pos = [10.0_real64, &
                0.0_real64, 10.0_real64]
            state%tl%tracks(1)%keys(2)%has_pos = .true.
            state%tl%tracks(1)%keys(2)%target = [0.0_real64, &
                2.0_real64, 0.0_real64]
            state%tl%tracks(1)%keys(2)%has_target = .true.
            state%tl%tracks(1)%keys(2)%fov = 40.0_real64
            state%tl%tracks(1)%keys(2)%has_fov = .true.
        else
            allocate(state%tl%tracks(0))
            state%tl%n_tracks = 0
        end if
        allocate(state%chars(0))
        allocate(state%spans(1))
    end subroutine base_state

end program test_camera_track
