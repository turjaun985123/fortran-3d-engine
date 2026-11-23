program test_keyframe
    use, intrinsic :: ieee_arithmetic, only: ieee_is_nan
    use math_3d, only: dp, vec3, quat, vec3_create, quat_from_euler, &
        quat_to_euler, quat_slerp, quat_dot, quat_inverse, &
        quat_multiply, quat_from_axis_angle, quat_rotate_vec3, &
        quat_negate, deg2rad, rad2deg
    use keyframe_3d
    use animation_3d, only: ease_value
    use scene_3d, only: Scene, scene_load
    use test_assert
    implicit none

    type(KeyFrame) :: kf
    type(KeyTrack) :: track, smooth_track, empty_track, single_track
    real(dp) :: pos(3), rot_deg(3), scale
    ! v3.0 Phase 5 locals
    type(KeyTrack) :: q_track
    type(quat) :: qa, qb, qmid, qexp, qr
    real(dp) :: s3(3), qn, half_ang, sh
    type(vec3) :: eu, axis_v
    type(Scene) :: sc5
    logical :: ok5
    character(len=256) :: errmsg5
    integer :: u5
    character(len=*), parameter :: path5 = '/tmp/test_keyframe_p5.scene'

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

    ! ================================================================
    ! v3.0 Phase 5: additive fields, key_eval_q, fps, new easings
    ! ================================================================

    ! ---- Phase 5 defaults ----
    call assert_false(kf%has_quat, 'default KeyFrame has_quat is false')
    call assert_false(kf%has_scale3, 'default KeyFrame has_scale3 is false')
    call assert_real_close(1.0_dp, kf%rot_quat%w, 1.0e-12_dp, &
        'default KeyFrame rot_quat is identity (w=1)')
    call assert_real_close(0.0_dp, kf%rot_quat%x, 1.0e-12_dp, &
        'default KeyFrame rot_quat x is 0')
    call assert_real_close(1.0_dp, kf%scale3(2), 1.0e-12_dp, &
        'default KeyFrame scale3 is 1 per axis')
    call assert_real_close(0.0_dp, track%fps, 1.0e-12_dp, &
        'default KeyTrack fps is 0 (legacy seconds)')

    ! ---- (e) easing: cubic + bezier ----
    call assert_real_close(0.125_dp, ease_value('cubic-in', 0.5_dp), &
        1.0e-12_dp, 'cubic-in(0.5) = 0.125')
    call assert_real_close(0.875_dp, ease_value('cubic-out', 0.5_dp), &
        1.0e-12_dp, 'cubic-out(0.5) = 0.875')
    call assert_real_close(0.0625_dp, ease_value('cubic-in-out', 0.25_dp), &
        1.0e-12_dp, 'cubic-in-out(0.25) = 0.0625')
    call assert_real_close(0.5_dp, ease_value('cubic-in-out', 0.5_dp), &
        1.0e-12_dp, 'cubic-in-out(0.5) = 0.5')
    call assert_real_close(0.5_dp, &
        ease_value('bezier(0.42,0,0.58,1)', 0.5_dp), 1.0e-6_dp, &
        'bezier(0.42,0,0.58,1) at 0.5 = 0.5 (CSS ease-in-out)')
    call assert_real_close(0.3_dp, ease_value('bezier(0,0,1,1)', 0.3_dp), &
        1.0e-9_dp, 'bezier(0,0,1,1) is linear')
    call assert_real_close(0.3_dp, ease_value('bezier(1,2)', 0.3_dp), &
        1.0e-12_dp, 'malformed bezier falls back to linear')
    call assert_real_close(0.3_dp, ease_value('bezier(x,y,z,w)', 0.3_dp), &
        1.0e-12_dp, 'non-numeric bezier falls back to linear')

    ! ---- (a) gimbal lock: pitch-90 keys through key_eval_q ----
    ! Keys (0,90,0) -> (90,90,90): pitch sits at the Euler gimbal
    ! singularity for the whole segment.  Euler lerp (key_eval)
    ! still produces numbers here, but its path swings yaw/roll
    ! through the degenerate extraction; the slerp path must stay
    ! a smooth, finite, normalised rotation and its midpoint must
    ! be the true halfway rotation (checked against an independent
    ! axis-angle construction, not against quat_slerp itself).
    qa = quat_from_euler(vec3_create(0.0_dp, 90.0_dp, 0.0_dp))
    qb = quat_from_euler(vec3_create(90.0_dp, 90.0_dp, 90.0_dp))
    allocate(q_track%keys(2))
    q_track%keys(1)%time = 0.0_dp
    q_track%keys(1)%rot_deg = [0.0_dp, 90.0_dp, 0.0_dp]
    q_track%keys(1)%rot_quat = qa
    q_track%keys(1)%has_quat = .true.
    q_track%keys(2)%time = 2.0_dp
    q_track%keys(2)%rot_deg = [90.0_dp, 90.0_dp, 90.0_dp]
    q_track%keys(2)%rot_quat = qb
    q_track%keys(2)%has_quat = .true.
    q_track%keys(2)%ease = 'linear'
    call key_eval_q(q_track, 1.0_dp, pos, qmid, s3)
    call assert_true(.not. (ieee_is_nan(qmid%x) .or. &
        ieee_is_nan(qmid%y) .or. ieee_is_nan(qmid%z) .or. &
        ieee_is_nan(qmid%w)), &
        'gimbal midpoint quat has no NaN components')
    qn = sqrt(qmid%x**2 + qmid%y**2 + qmid%z**2 + qmid%w**2)
    call assert_real_close(1.0_dp, qn, 1.0e-12_dp, &
        'gimbal midpoint quat is normalised')
    call assert_real_close(abs(quat_dot(qmid, qa)), &
        abs(quat_dot(qmid, qb)), 1.0e-9_dp, &
        'gimbal midpoint is equidistant from both end rotations')
    qr = quat_multiply(quat_inverse(qa), qb)
    if (qr%w < 0.0_dp) qr = quat_negate(qr)
    half_ang = rad2deg(2.0_dp * acos(min(1.0_dp, qr%w)))
    sh = sin(0.5_dp * deg2rad(half_ang))
    axis_v = vec3_create(qr%x / sh, qr%y / sh, qr%z / sh)
    qexp = quat_multiply(qa, quat_from_axis_angle(axis_v, half_ang / 2.0_dp))
    call assert_vec3_close(quat_rotate_vec3(qmid, &
        vec3_create(1.0_dp, 0.0_dp, 0.0_dp)), &
        quat_rotate_vec3(qexp, vec3_create(1.0_dp, 0.0_dp, 0.0_dp)), &
        1.0e-9_dp, 'gimbal midpoint rotates x-axis like the axis-angle halfway')
    call assert_vec3_close(quat_rotate_vec3(qmid, &
        vec3_create(0.0_dp, 1.0_dp, 0.0_dp)), &
        quat_rotate_vec3(qexp, vec3_create(0.0_dp, 1.0_dp, 0.0_dp)), &
        1.0e-9_dp, 'gimbal midpoint rotates y-axis like the axis-angle halfway')
    call assert_vec3_close(quat_rotate_vec3(qmid, &
        vec3_create(0.0_dp, 0.0_dp, 1.0_dp)), &
        quat_rotate_vec3(qexp, vec3_create(0.0_dp, 0.0_dp, 1.0_dp)), &
        1.0e-9_dp, 'gimbal midpoint rotates z-axis like the axis-angle halfway')
    deallocate(q_track%keys)

    ! ---- (b) 350 -> 10 yaw wrap: slerp takes the short way ----
    allocate(q_track%keys(2))
    q_track%keys(1)%time = 0.0_dp
    q_track%keys(1)%rot_deg = [0.0_dp, 350.0_dp, 0.0_dp]
    q_track%keys(1)%rot_quat = &
        quat_from_euler(vec3_create(0.0_dp, 350.0_dp, 0.0_dp))
    q_track%keys(1)%has_quat = .true.
    q_track%keys(2)%time = 2.0_dp
    q_track%keys(2)%rot_deg = [0.0_dp, 10.0_dp, 0.0_dp]
    q_track%keys(2)%rot_quat = &
        quat_from_euler(vec3_create(0.0_dp, 10.0_dp, 0.0_dp))
    q_track%keys(2)%has_quat = .true.
    q_track%keys(2)%ease = 'linear'
    call key_eval_q(q_track, 1.0_dp, pos, qmid, s3)
    eu = quat_to_euler(qmid)
    call assert_real_close(0.0_dp, eu%y, 1.0e-6_dp, &
        '350->10 slerp midpoint yaw is 0 (shortest path)')
    call assert_real_close(0.0_dp, eu%x, 1.0e-6_dp, &
        '350->10 slerp midpoint pitch is 0')
    call assert_real_close(0.0_dp, eu%z, 1.0e-6_dp, &
        '350->10 slerp midpoint roll is 0')
    ! Frozen contrast: legacy Euler lerp goes the long way.
    call key_eval(q_track, 1.0_dp, pos, rot_deg, scale)
    call assert_real_close(180.0_dp, rot_deg(2), 1.0e-12_dp, &
        'frozen key_eval Euler lerp 350->10 midpoint yaw is 180')
    deallocate(q_track%keys)

    ! ---- (c) per-axis scale ----
    allocate(q_track%keys(2))
    q_track%keys(1)%time = 0.0_dp
    q_track%keys(1)%scale3 = [1.0_dp, 2.0_dp, 3.0_dp]
    q_track%keys(1)%has_scale3 = .true.
    q_track%keys(2)%time = 2.0_dp
    q_track%keys(2)%scale3 = [3.0_dp, 2.0_dp, 1.0_dp]
    q_track%keys(2)%has_scale3 = .true.
    q_track%keys(2)%ease = 'linear'
    call key_eval_q(q_track, 1.0_dp, pos, qmid, s3)
    call assert_real_close(2.0_dp, s3(1), 1.0e-12_dp, 'scale3 midpoint x is 2')
    call assert_real_close(2.0_dp, s3(2), 1.0e-12_dp, 'scale3 midpoint y is 2')
    call assert_real_close(2.0_dp, s3(3), 1.0e-12_dp, 'scale3 midpoint z is 2')
    ! Mixed: uniform key (no scale3) broadcasts against a scale3 key.
    q_track%keys(1)%has_scale3 = .false.
    q_track%keys(1)%scale = 2.0_dp
    q_track%keys(2)%scale3 = [4.0_dp, 4.0_dp, 4.0_dp]
    call key_eval_q(q_track, 1.0_dp, pos, qmid, s3)
    call assert_real_close(3.0_dp, s3(1), 1.0e-12_dp, &
        'uniform-vs-scale3 midpoint x is 3 (broadcast)')
    deallocate(q_track%keys)

    ! ---- (d) per-clip fps: keys at frames 0 and 10, fps=10 ----
    allocate(q_track%keys(2))
    q_track%fps = 10.0_dp
    q_track%keys(1)%time = 0.0_dp
    q_track%keys(1)%pos = [0.0_dp, 0.0_dp, 0.0_dp]
    q_track%keys(2)%time = 10.0_dp
    q_track%keys(2)%pos = [4.0_dp, 2.0_dp, 0.0_dp]
    q_track%keys(2)%ease = 'linear'
    call key_eval_q(q_track, 0.5_dp, pos, qmid, s3)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, &
        'fps=10: key_eval_q at t=0.5s is the frame-5 midpoint pos x 2')
    call key_eval(q_track, 0.5_dp, pos, rot_deg, scale)
    call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, &
        'fps=10: key_eval at t=0.5s is the frame-5 midpoint pos x 2')
    call key_eval(q_track, 1.0_dp, pos, rot_deg, scale)
    call assert_real_close(4.0_dp, pos(1), 1.0e-12_dp, &
        'fps=10: key_eval at t=1.0s is the last key pos x 4')
    deallocate(q_track%keys)
    q_track%fps = 0.0_dp

    ! ---- (d2) scene level: 'fps N' header + 'keys ... fps F' ----
    ! Also proves the authoring conversion end to end: the loaded
    ! keys carry has_quat, and the 350->10 wrap evaluates to yaw 0.
    open(newunit=u5, file=path5, status='replace', action='write')
    write(u5, '(A)') 'forge3d-scene 1'
    write(u5, '(A)') 'size 64 48'
    write(u5, '(A)') 'fps 24'
    write(u5, '(A)') 'frames 1'
    write(u5, '(A)') 'output p5.ppm'
    write(u5, '(A)') 'object cube obj0 lambert 200 80 80 0 0 0 0 0 0 1 1 1 1 -1 -1 0'
    write(u5, '(A)') 'keys obj0 0 once 2 fps 10'
    write(u5, '(A)') 'key 0 0 0 0 0 350 0 1 linear'
    write(u5, '(A)') 'key 10 4 0 0 0 10 0 1 linear'
    close(u5)
    call scene_load(path5, sc5, ok5, errmsg5)
    call assert_true(ok5, 'scene_load of Phase 5 scene succeeds')
    call assert_int_eq(24, sc5%fps, 'scene fps header line reads 24')
    call assert_int_eq(1, sc5%n_tracks, 'Phase 5 scene has 1 track')
    if (sc5%n_tracks == 1) then
        call assert_real_close(10.0_dp, sc5%tracks(1)%fps, 1.0e-12_dp, &
            'keys line fps token reads 10')
        call assert_true(sc5%tracks(1)%keys(1)%has_quat, &
            'loaded key 1 has_quat (authoring conversion ran)')
        call assert_true(sc5%tracks(1)%keys(2)%has_quat, &
            'loaded key 2 has_quat (authoring conversion ran)')
        call key_eval_q(sc5%tracks(1), 0.5_dp, pos, qmid, s3)
        call assert_real_close(2.0_dp, pos(1), 1.0e-12_dp, &
            'loaded fps track at t=0.5s is midpoint pos x 2')
        eu = quat_to_euler(qmid)
        call assert_real_close(0.0_dp, eu%y, 1.0e-6_dp, &
            'loaded 350->10 track slerp midpoint yaw is 0')
    end if

    call test_summary()

end program test_keyframe
