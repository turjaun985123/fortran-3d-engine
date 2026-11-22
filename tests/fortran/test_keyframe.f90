program test_keyframe
    use math_3d, only: dp
    use keyframe_3d
    use test_assert
    implicit none

    type(KeyFrame) :: kf
    type(KeyTrack) :: track, smooth_track, empty_track, single_track
    real(dp) :: pos(3), rot_deg(3), scale

    ! ---- frozen defaults ----
    call assert_real_close(0.0_dp, kf%time, 1.0e-12_dp, 'default KeyFrame time is 0')
    call assert_real_close(1.0_dp, kf%scale, 1.0e-12_dp, 'default KeyFrame scale is 1')
    call assert_true(kf%ease == 'linear', 'default KeyFrame ease is linear')
    call assert_real_close(0.0_dp, track%duration, 1.0e-12_dp, &
        'default KeyTrack duration is 0 (use last key time)')
    call assert_true(track%loop == 'once', 'default KeyTrack loop is once')
    call assert_false(allocated(track%keys), 'default KeyTrack has no keys allocated')

    ! ---- two-key linear track: (0,0,0) -> (4,2,0) over 0..2 s ----
    ! Second key also carries rot y 0 -> 90 and scale 1 -> 2.
    allocate(track%keys(2))
    track%keys(1)%time = 0.0_dp
    track%keys(1)%pos = [0.0_dp, 0.0_dp, 0.0_dp]
    track%keys(1)%rot_deg = [0.0_dp, 0.0_dp, 0.0_dp]
    track%keys(1)%scale = 1.0_dp
    track%keys(2)%time = 2.0_dp
    track%keys(2)%pos = [4.0_dp, 2.0_dp, 0.0_dp]
    track%keys(2)%rot_deg = [0.0_dp, 90.0_dp, 0.0_dp]
    track%keys(2)%scale = 2.0_dp
    track%keys(2)%ease = 'linear'

    call key_eval(track, 0.0_dp, pos, rot_deg, scale)
    call assert_real_close(0.0_dp, pos(1), 1.0e-12_dp, 'linear t=0 pos x is 0')
    call assert_real_close(0.0_dp, pos(2), 1.0e-12_dp, 'linear t=0 pos y is 0')
    call assert_real_close(0.0_dp, pos(3), 1.0e-12_dp, 'linear t=0 pos z is 0')

    call key_eval(track, 1.0_dp, pos, rot_deg, scale)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, 'linear t=1 midpoint pos x is 2')
    call assert_real_close(1.0_dp, pos(2), 1.0e-12_dp, 'linear t=1 midpoint pos y is 1')
    call assert_real_close(0.0_dp, pos(3), 1.0e-12_dp, 'linear t=1 midpoint pos z is 0')
    call assert_real_close(0.0_dp, rot_deg(1), 1.0e-12_dp, 'linear t=1 rot x is 0')
    call assert_real_close(45.0_dp, rot_deg(2), 1.0e-12_dp, 'rot lerp 0->90 at mid is 45')
    call assert_real_close(0.0_dp, rot_deg(3), 1.0e-12_dp, 'linear t=1 rot z is 0')
    call assert_real_close(1.5_dp, scale, 1.0e-12_dp, 'scale lerp 1->2 at mid is 1.5')

    call key_eval(track, 2.0_dp, pos, rot_deg, scale)
    call assert_real_close(4.0_dp, pos(1), 1.0e-12_dp, 'linear t=2 pos x is 4')
    call assert_real_close(2.0_dp, pos(2), 1.0e-12_dp, 'linear t=2 pos y is 2')
    call assert_real_close(0.0_dp, pos(3), 1.0e-12_dp, 'linear t=2 pos z is 0')

    ! ---- once: t past the end clamps to the end pose ----
    call key_eval(track, 5.0_dp, pos, rot_deg, scale)
    call assert_real_close(4.0_dp, pos(1), 1.0e-12_dp, 'once clamp t=5 pos x is end 4')
    call assert_real_close(2.0_dp, pos(2), 1.0e-12_dp, 'once clamp t=5 pos y is end 2')
    call assert_real_close(0.0_dp, pos(3), 1.0e-12_dp, 'once clamp t=5 pos z is end 0')
    call assert_real_close(2.0_dp, scale, 1.0e-12_dp, 'once clamp t=5 scale is end 2')

    ! ---- smooth ease on the end key ----
    ! smooth(p) = p*p*(3-2p): smooth(0.5) = 0.5, smooth(0.25) = 0.15625.
    smooth_track = track
    smooth_track%keys(2)%ease = 'smooth'
    call key_eval(smooth_track, 1.0_dp, pos, rot_deg, scale)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, &
        'smooth at p=0.5 gives same midpoint pos x 2')
    call key_eval(smooth_track, 0.5_dp, pos, rot_deg, scale)
    call assert_real_close(4.0_dp * 0.15625_dp, pos(1), 1.0e-12_dp, &
        'smooth at p=0.25 pos x is 4*0.15625')
    call assert_real_close(2.0_dp * 0.15625_dp, pos(2), 1.0e-12_dp, &
        'smooth at p=0.25 pos y is 2*0.15625')

    ! ---- forever: t=3 on D=2 wraps to te=1 (midpoint) ----
    track%loop = 'forever'
    call key_eval(track, 3.0_dp, pos, rot_deg, scale)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, 'forever t=3 wraps to midpoint pos x 2')
    call assert_real_close(1.0_dp, pos(2), 1.0e-12_dp, 'forever t=3 wraps to midpoint pos y 1')

    ! ---- pingpong: t=3 on D=2 folds to te=1; t=2 is the end pose ----
    track%loop = 'pingpong'
    call key_eval(track, 3.0_dp, pos, rot_deg, scale)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, 'pingpong t=3 folds to midpoint pos x 2')
    call key_eval(track, 2.0_dp, pos, rot_deg, scale)
    call assert_real_close(4.0_dp, pos(1), 1.0e-12_dp, 'pingpong t=2 is end pose pos x 4')
    track%loop = 'once'

    ! ---- before the first key: first key at t=1 -> first pose ----
    deallocate(track%keys)
    allocate(track%keys(2))
    track%keys(1)%time = 1.0_dp
    track%keys(1)%pos = [2.0_dp, 0.0_dp, 0.0_dp]
    track%keys(1)%rot_deg = [0.0_dp, 0.0_dp, 0.0_dp]
    track%keys(1)%scale = 1.0_dp
    track%keys(2)%time = 3.0_dp
    track%keys(2)%pos = [6.0_dp, 0.0_dp, 0.0_dp]
    track%keys(2)%rot_deg = [0.0_dp, 0.0_dp, 0.0_dp]
    track%keys(2)%scale = 1.0_dp
    call key_eval(track, 0.0_dp, pos, rot_deg, scale)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, &
        'before first key (t=0, first key at 1) gives first pose pos x 2')

    ! ---- empty track -> identity pose ----
    call key_eval(empty_track, 1.0_dp, pos, rot_deg, scale)
    call assert_real_close(0.0_dp, pos(1), 1.0e-12_dp, 'empty track pos x is 0')
    call assert_real_close(0.0_dp, pos(2), 1.0e-12_dp, 'empty track pos y is 0')
    call assert_real_close(0.0_dp, pos(3), 1.0e-12_dp, 'empty track pos z is 0')
    call assert_real_close(0.0_dp, rot_deg(2), 1.0e-12_dp, 'empty track rot y is 0')
    call assert_real_close(1.0_dp, scale, 1.0e-12_dp, 'empty track scale is 1')

    ! ---- D <= 0 (single key at t=0) -> first key's pose ----
    allocate(single_track%keys(1))
    single_track%keys(1)%time = 0.0_dp
    single_track%keys(1)%pos = [3.0_dp, 3.0_dp, 3.0_dp]
    single_track%keys(1)%scale = 1.0_dp
    call key_eval(single_track, 1.0_dp, pos, rot_deg, scale)
    call assert_real_close(3.0_dp, pos(1), 1.0e-12_dp, 'D<=0 gives first key pose pos x 3')

    ! ---- duration override: duration=4, last key at t=2 ----
    deallocate(track%keys)
    allocate(track%keys(2))
    track%keys(1)%time = 0.0_dp
    track%keys(1)%pos = [0.0_dp, 0.0_dp, 0.0_dp]
    track%keys(1)%rot_deg = [0.0_dp, 0.0_dp, 0.0_dp]
    track%keys(1)%scale = 1.0_dp
    track%keys(2)%time = 2.0_dp
    track%keys(2)%pos = [4.0_dp, 2.0_dp, 0.0_dp]
    track%keys(2)%rot_deg = [0.0_dp, 0.0_dp, 0.0_dp]
    track%keys(2)%scale = 2.0_dp
    track%duration = 4.0_dp
    track%loop = 'once'
    call key_eval(track, 3.0_dp, pos, rot_deg, scale)
    call assert_real_close(4.0_dp, pos(1), 1.0e-12_dp, &
        'duration override once t=3 (te=3 >= last key) gives last pose pos x 4')
    call assert_real_close(2.0_dp, scale, 1.0e-12_dp, &
        'duration override once t=3 gives last pose scale 2')
    track%loop = 'forever'
    call key_eval(track, 5.0_dp, pos, rot_deg, scale)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, &
        'duration override forever t=5 D=4 wraps to te=1 midpoint pos x 2')

    call test_summary()

end program test_keyframe
