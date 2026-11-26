program test_stickman_rig
    use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
    use math_3d
    use mesh_3d
    use char_figure_3d
    use test_assert
    implicit none

    type(figure_props) :: props, kid, tallp, hp
    type(figure_pose) :: pose
    type(figure_identity) :: ident
    type(Mesh) :: msh
    real(dp) :: uv(2, N_JOINTS)
    type(vec3) :: w(N_JOINTS), root0, cam_z, cam_x
    real(dp) :: s150, c150, exp_u, exp_v
    integer :: i, k
    logical :: finite_ok

    props = props_from_spec('', 0.0_dp, .false.)
    root0 = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    cam_z = vec3_create(0.0_dp, 1.5_dp, 10.0_dp)
    cam_x = vec3_create(10.0_dp, 0.0_dp, 0.0_dp)

    ! ---- channel / joint vocabulary ----
    call assert_true(trim(figure_channel_name(CH_ARM_R_UPPER)) == &
                     'arm.r.upper', 'channel 10 is arm.r.upper')
    call assert_true(trim(figure_channel_name(CH_FACE_EXPR)) == &
                     'face.expr', 'channel 16 is face.expr')
    call assert_true(trim(figure_joint_name(J_FOOT_R)) == 'foot.R', &
                     'joint 16 is foot.R')

    ! ---- FK at rest: feet on the ground, head top at H0 ----
    pose = pose_rest(0.0_dp)
    uv = figure_fk(pose, props)
    call assert_real_close(0.0_dp, uv(2, J_FOOT_L), 1.0e-12_dp, &
                           'rest: left foot at v = 0')
    call assert_real_close(0.0_dp, uv(2, J_FOOT_R), 1.0e-12_dp, &
                           'rest: right foot at v = 0')
    call assert_real_close(-0.11_dp, uv(1, J_FOOT_L), 1.0e-12_dp, &
                           'rest: left foot at u = -hip_half')
    call assert_real_close(0.11_dp, uv(1, J_FOOT_R), 1.0e-12_dp, &
                           'rest: right foot at u = +hip_half')
    call assert_real_close(FIGURE_H0, uv(2, J_HEAD) + props%head_r, &
                           1.0e-12_dp, 'rest: head top at H0 = 1.83')
    call assert_real_close(FIGURE_H0, figure_total_height(props), &
                           1.0e-12_dp, 'adult total height is H0')

    ! ---- known-angle pose: arm.r.upper = 150 deg ----
    ! d(150) = (sin150, -cos150) = (0.5, +sqrt(3)/2): the arm points
    ! up-right.  shoulder.R = (0.19, 1.45); elbow = shoulder +
    ! 0.30*d; hand = elbow + 0.28*d.
    pose = pose_rest(0.0_dp)
    pose%ch(CH_ARM_R_UPPER) = 150.0_dp
    uv = figure_fk(pose, props)
    s150 = sin(deg2rad(150.0_dp))
    c150 = -cos(deg2rad(150.0_dp))
    exp_u = 0.19_dp + 0.30_dp * s150
    exp_v = 1.45_dp + 0.30_dp * c150
    call assert_real_close(exp_u, uv(1, J_ELBOW_R), 1.0e-9_dp, &
                           'arm 150: elbow u')
    call assert_real_close(exp_v, uv(2, J_ELBOW_R), 1.0e-9_dp, &
                           'arm 150: elbow v')
    call assert_real_close(exp_u + 0.28_dp * s150, uv(1, J_HAND_R), &
                           1.0e-9_dp, 'arm 150: hand u')
    call assert_real_close(exp_v + 0.28_dp * c150, uv(2, J_HAND_R), &
                           1.0e-9_dp, 'arm 150: hand v')
    call assert_true(uv(1, J_HAND_R) > uv(1, J_SHOULDER_R) .and. &
                     uv(2, J_HAND_R) > uv(2, J_SHOULDER_R), &
                     'arm 150: hand is up-right of the shoulder')

    ! ---- kid proportions: ~0.62 * H0 tall, bigger relative head ----
    kid = props_from_spec('kid', 0.0_dp, .false.)
    call assert_real_close(0.62_dp * 0.45_dp, kid%thigh, 1.0e-12_dp, &
                           'kid: thigh scaled by 0.62')
    call assert_real_close(0.806_dp * 0.16_dp, kid%head_r, &
                           1.0e-12_dp, 'kid: head_r scaled by 0.806')
    call assert_real_close(0.62_dp * 1.51_dp + 2.0_dp * 0.806_dp * &
                           0.16_dp, figure_total_height(kid), &
                           1.0e-12_dp, 'kid: exact total height')
    call assert_true(abs(figure_total_height(kid) - 0.62_dp * &
                     FIGURE_H0) < 0.1_dp, &
                     'kid: height is approximately 0.62 * H0')
    call assert_true(kid%head_r / figure_total_height(kid) > &
                     props%head_r / FIGURE_H0, &
                     'kid: head is relatively bigger than adult')

    ! ---- tall proportions ----
    tallp = props_from_spec('tall', 0.0_dp, .false.)
    call assert_real_close(1.12_dp * 0.45_dp, tallp%thigh, &
                           1.0e-12_dp, 'tall: thigh scaled by 1.12')
    call assert_real_close(1.05_dp * 0.16_dp, tallp%head_r, &
                           1.0e-12_dp, 'tall: head_r scaled by 1.05')

    ! ---- height override is exact ----
    hp = props_from_spec('', 2.0_dp, .true.)
    call assert_real_close(2.0_dp, figure_total_height(hp), &
                           1.0e-12_dp, 'height 2: total height exact')
    call assert_real_close(0.45_dp * 2.0_dp / FIGURE_H0, hp%thigh, &
                           1.0e-12_dp, 'height 2: thigh uniformly scaled')
    hp = props_from_spec('kid', 1.0_dp, .true.)
    call assert_real_close(1.0_dp, figure_total_height(hp), &
                           1.0e-12_dp, &
                           'kid + height 1: total height exact')

    ! ---- billboard: camera on +Z keeps the plane in XY ----
    pose = pose_rest(0.0_dp)
    w = figure_joints_world(pose, props, root0, cam_z)
    call assert_vec3_close(w(J_HIP_R), &
                           vec3_create(0.11_dp, 0.9_dp, 0.0_dp), &
                           1.0e-12_dp, &
                           'billboard +Z cam: hip.R in the XY plane')
    call assert_real_close(0.0_dp, w(J_FOOT_L)%y, 1.0e-12_dp, &
                           'billboard +Z cam: foot on the ground')

    ! ---- billboard: camera on +X turns the plane to face +X ----
    ! f = (1,0,0); right = cross(up, f) = (0,0,-1), so a joint at
    ! u = +0.11 lands at world z = -0.11 with x = root x.
    w = figure_joints_world(pose, props, root0, cam_x)
    call assert_vec3_close(w(J_HIP_R), &
                           vec3_create(0.0_dp, 0.9_dp, -0.11_dp), &
                           1.0e-12_dp, &
                           'billboard +X cam: hip.R faces +X')
    call assert_true(all(abs(w(:)%x) < 1.0e-12_dp), &
                     'billboard +X cam: all joints share the plane x')

    ! ---- root.face = 90 rotates the facing within the convention ----
    ! Camera on +Z (right = (1,0,0)); rotating right about Y by 90
    ! degrees gives right = (0,0,-1), so hip.R lands at z = -0.11.
    pose = pose_rest(0.0_dp)
    pose%ch(CH_ROOT_FACE) = 90.0_dp
    w = figure_joints_world(pose, props, root0, cam_z)
    call assert_vec3_close(w(J_HIP_R), &
                           vec3_create(0.0_dp, 0.9_dp, -0.11_dp), &
                           1.0e-12_dp, &
                           'root.face 90: hip.R rotated to -Z')

    ! ---- degenerate camera (directly overhead) falls back safely ----
    w = figure_joints_world(pose_rest(0.0_dp), props, root0, &
                            vec3_create(0.0_dp, 10.0_dp, 0.0_dp))
    call assert_vec3_close(w(J_HIP_R), &
                           vec3_create(0.11_dp, 0.9_dp, 0.0_dp), &
                           1.0e-12_dp, &
                           'overhead camera: fallback facing +Z')

    ! ---- mesh build: default figure ----
    ident = figure_identity()
    call figure_build_mesh(pose_rest(0.0_dp), props, ident, &
                           [70, 120, 200], cam_z, msh)
    write(*, '(A, I0)') 'default figure triangles: ', &
        msh%num_triangles
    call assert_true(msh%num_triangles > 0, 'mesh: triangles built')
    call assert_true(msh%num_triangles <= 1100, &
                     'mesh: triangle count within budget (<= 1100)')
    finite_ok = .true.
    do i = 1, msh%num_triangles
        do k = 1, 3
            if (.not. ieee_is_finite(msh%triangles(i)%v(k)%x) .or. &
                .not. ieee_is_finite(msh%triangles(i)%v(k)%y) .or. &
                .not. ieee_is_finite(msh%triangles(i)%v(k)%z)) &
                finite_ok = .false.
        end do
        if (msh%triangles(i)%material_id /= 1) finite_ok = .false.
    end do
    call assert_true(finite_ok, &
                     'mesh: all vertices finite, all BASIC material')
    call free_mesh(msh)

    ! ---- mesh build: fully dressed figure stays in budget ----
    ident = figure_identity()
    ident%hair = 'bun'
    ident%holds = 'stick'
    ident%n_wears = 3
    ident%wears(1)%item = 'dress'
    ident%wears(1)%color = [240, 200, 60]
    ident%wears(2)%item = 'hat'
    ident%wears(2)%color = [200, 60, 60]
    ident%wears(3)%item = 'glasses'
    ident%wears(3)%color = [25, 25, 25]
    call figure_build_mesh(pose_rest(1.0_dp), props, ident, &
                           [70, 120, 200], cam_z, msh)
    write(*, '(A, I0)') 'dressed figure triangles: ', &
        msh%num_triangles
    call assert_true(msh%num_triangles > 0 .and. &
                     msh%num_triangles <= 1100, &
                     'mesh: dressed figure within budget')
    finite_ok = .true.
    do i = 1, msh%num_triangles
        do k = 1, 3
            if (.not. ieee_is_finite(msh%triangles(i)%v(k)%x) .or. &
                .not. ieee_is_finite(msh%triangles(i)%v(k)%y) .or. &
                .not. ieee_is_finite(msh%triangles(i)%v(k)%z)) &
                finite_ok = .false.
        end do
    end do
    call assert_true(finite_ok, 'mesh: dressed vertices finite')
    call free_mesh(msh)

    call test_summary()

end program test_stickman_rig
