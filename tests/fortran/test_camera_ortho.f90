! test_camera_ortho.f90 -- tests for camera_ortho_3d (Wave C seat B78).
!
! Engine depth convention asserted here (verified from src/math_3d.f90
! mat4_perspective and src/renderer.f90 depth usage): view space looks
! down -z, near plane at view z = -near, far plane at view z = -far;
! NDC z is in [-1, 1] with near -> -1 and far -> +1, and the renderer
! keeps the smallest depth, so -1 is closest.
program test_camera_ortho
    use math_3d
    use camera_ortho_3d
    use test_assert
    implicit none

    real(dp), parameter :: tol = 1.0e-12_dp
    type(mat4) :: p, p_wide, p_narrow, p_big
    type(CameraOrtho) :: cam
    type(vec3) :: eye, target, got, a, b

    ! ---- centre maps to NDC origin ----
    ! Symmetric box [-4,4] x [-3,3], near 1, far 11: frustum centre in
    ! view space is (0, 0, -(1+11)/2) = (0,0,-6).
    p = mat4_ortho(-4.0_dp, 4.0_dp, -3.0_dp, 3.0_dp, 1.0_dp, 11.0_dp)
    got = mat4_transform_vec3(p, vec3_create(0.0_dp, 0.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), got, tol, &
        'mat4_ortho centre maps to NDC origin')

    ! Asymmetric box: centre of [0,10] x [0,10] is (5,5).
    p = mat4_ortho(0.0_dp, 10.0_dp, 0.0_dp, 10.0_dp, 1.0_dp, 11.0_dp)
    got = mat4_transform_vec3(p, vec3_create(5.0_dp, 5.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), got, tol, &
        'mat4_ortho asymmetric centre maps to NDC origin')

    ! ---- corners map to (+-1, +-1) ----
    p = mat4_ortho(-4.0_dp, 4.0_dp, -3.0_dp, 3.0_dp, 1.0_dp, 11.0_dp)
    got = mat4_transform_vec3(p, vec3_create(4.0_dp, 3.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(1.0_dp, 1.0_dp, 0.0_dp), got, tol, &
        'mat4_ortho right/top corner maps to (+1,+1)')
    got = mat4_transform_vec3(p, vec3_create(-4.0_dp, -3.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(-1.0_dp, -1.0_dp, 0.0_dp), got, tol, &
        'mat4_ortho left/bottom corner maps to (-1,-1)')
    got = mat4_transform_vec3(p, vec3_create(-4.0_dp, 3.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(-1.0_dp, 1.0_dp, 0.0_dp), got, tol, &
        'mat4_ortho left/top corner maps to (-1,+1)')
    got = mat4_transform_vec3(p, vec3_create(4.0_dp, -3.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(1.0_dp, -1.0_dp, 0.0_dp), got, tol, &
        'mat4_ortho right/bottom corner maps to (+1,-1)')

    ! ---- depth: near -> -1, far -> +1 (engine convention) ----
    got = mat4_transform_vec3(p, vec3_create(0.0_dp, 0.0_dp, -1.0_dp), .true.)
    call assert_real_close(-1.0_dp, got%z, tol, &
        'mat4_ortho near plane (view z=-near) maps to NDC z -1')
    got = mat4_transform_vec3(p, vec3_create(0.0_dp, 0.0_dp, -11.0_dp), .true.)
    call assert_real_close(1.0_dp, got%z, tol, &
        'mat4_ortho far plane (view z=-far) maps to NDC z +1')

    ! ---- ortho property: x/y independent of view-z, only depth changes ----
    a = mat4_transform_vec3(p, vec3_create(2.0_dp, 1.5_dp, -2.0_dp), .true.)
    b = mat4_transform_vec3(p, vec3_create(2.0_dp, 1.5_dp, -9.0_dp), .true.)
    call assert_real_close(a%x, b%x, tol, &
        'ortho x is independent of view-z (defining property)')
    call assert_real_close(a%y, b%y, tol, &
        'ortho y is independent of view-z (defining property)')
    call assert_true(abs(a%z - b%z) > 0.5_dp, &
        'ortho points at different view-z differ in depth')
    call assert_true(b%z > a%z, &
        'ortho farther point (more negative view-z) has larger NDC z')

    ! ---- ortho_proj_from_size: aspect widens the x-range ----
    ! size 4 -> half_h 2; aspect 1 -> half_w 2, aspect 2 -> half_w 4.
    p_narrow = ortho_proj_from_size(4.0_dp, 1.0_dp, 1.0_dp, 11.0_dp)
    p_wide   = ortho_proj_from_size(4.0_dp, 2.0_dp, 1.0_dp, 11.0_dp)
    got = mat4_transform_vec3(p_narrow, vec3_create(2.0_dp, 2.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(1.0_dp, 1.0_dp, 0.0_dp), got, tol, &
        'ortho_proj_from_size aspect 1: (size/2, size/2) maps to (+1,+1)')
    got = mat4_transform_vec3(p_wide, vec3_create(4.0_dp, 2.0_dp, -6.0_dp), .true.)
    call assert_vec3_close(vec3_create(1.0_dp, 1.0_dp, 0.0_dp), got, tol, &
        'ortho_proj_from_size aspect 2 widens x-range: x=4 maps to +1')
    got = mat4_transform_vec3(p_wide, vec3_create(2.0_dp, 0.0_dp, -6.0_dp), .true.)
    call assert_real_close(0.5_dp, got%x, tol, &
        'ortho_proj_from_size aspect 2: x=2 maps to NDC x 0.5')
    ! y-range is set by size alone and does not change with aspect.
    got = mat4_transform_vec3(p_wide, vec3_create(0.0_dp, 2.0_dp, -6.0_dp), .true.)
    call assert_real_close(1.0_dp, got%y, tol, &
        'ortho_proj_from_size aspect does not change y-range')

    ! ---- size scales linearly ----
    ! Doubling size halves the NDC coordinate of a fixed point.
    p_big = ortho_proj_from_size(8.0_dp, 1.0_dp, 1.0_dp, 11.0_dp)
    a = mat4_transform_vec3(p_narrow, vec3_create(1.0_dp, 1.0_dp, -6.0_dp), .true.)
    b = mat4_transform_vec3(p_big,    vec3_create(1.0_dp, 1.0_dp, -6.0_dp), .true.)
    call assert_real_close(0.5_dp, a%x, tol, &
        'ortho_proj_from_size size 4: x=1 maps to NDC x 0.5')
    call assert_real_close(a%x * 0.5_dp, b%x, tol, &
        'ortho_proj_from_size doubling size halves NDC x (linear scaling)')
    call assert_real_close(a%y * 0.5_dp, b%y, tol, &
        'ortho_proj_from_size doubling size halves NDC y (linear scaling)')

    ! ortho_proj_from_size agrees with the equivalent explicit mat4_ortho.
    p = ortho_proj_from_size(4.0_dp, 2.0_dp, 1.0_dp, 11.0_dp)
    p_big = mat4_ortho(-4.0_dp, 4.0_dp, -2.0_dp, 2.0_dp, 1.0_dp, 11.0_dp)
    call assert_true(all(abs(p%m - p_big%m) <= tol), &
        'ortho_proj_from_size matches explicit mat4_ortho(-4,4,-2,2,1,11)')

    ! ---- camera_ortho_init mirrors camera_init ----
    eye = vec3_create(0.0_dp, 0.0_dp, 5.0_dp)
    target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    call camera_ortho_init(cam, eye, target, 4.0_dp, 2.0_dp, 0.1_dp, 100.0_dp)
    call assert_vec3_close(eye, cam%position, tol, 'camera_ortho_init stores position')
    call assert_vec3_close(target, cam%target, tol, 'camera_ortho_init stores target')
    call assert_vec3_close(vec3_create(0.0_dp, 1.0_dp, 0.0_dp), cam%up, tol, &
        'camera_ortho_init sets up to (0,1,0)')
    call assert_real_close(4.0_dp, cam%size, tol, 'camera_ortho_init stores size')
    call assert_real_close(2.0_dp, cam%aspect_ratio, tol, &
        'camera_ortho_init stores aspect_ratio')
    call assert_real_close(0.1_dp, cam%near_plane, tol, &
        'camera_ortho_init stores near_plane')
    call assert_real_close(100.0_dp, cam%far_plane, tol, &
        'camera_ortho_init stores far_plane')
    call assert_true(camera_ortho_is_valid(cam), &
        'camera_ortho_is_valid true for defaults')

    ! View matrix maps eye to origin (same as perspective camera).
    got = mat4_transform_vec3(cam%view_matrix, eye, .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), got, 1.0e-9_dp, &
        'camera_ortho view matrix maps eye to (0,0,0)')

    ! Combined view*proj: target (origin, 5 units ahead of the eye) is
    ! centred in x/y; a world point 2 right / 2 up from the target sits
    ! at NDC (0.5, 1) for size 4 / aspect 2.
    got = mat4_transform_vec3(mat4_mult(cam%proj_matrix, cam%view_matrix), &
                              vec3_create(2.0_dp, 2.0_dp, 0.0_dp), .true.)
    call assert_real_close(0.5_dp, got%x, 1.0e-9_dp, &
        'camera_ortho mvp: world (2,2,0) maps to NDC x 0.5')
    call assert_real_close(1.0_dp, got%y, 1.0e-9_dp, &
        'camera_ortho mvp: world (2,2,0) maps to NDC y +1')

    ! camera_ortho_set_size / set_aspect rebuild the projection.
    call camera_ortho_set_size(cam, 8.0_dp)
    call assert_real_close(8.0_dp, cam%size, tol, 'camera_ortho_set_size stores size')
    call assert_real_close(0.125_dp, cam%proj_matrix%m(1, 1), tol, &
        'camera_ortho_set_size updates proj m(1,1) to 2/(size*aspect)')
    call camera_ortho_set_aspect(cam, 1.0_dp)
    call assert_real_close(0.25_dp, cam%proj_matrix%m(2, 2), tol, &
        'camera_ortho_set_aspect leaves proj m(2,2) at 2/size')
    call assert_real_close(0.25_dp, cam%proj_matrix%m(1, 1), tol, &
        'camera_ortho_set_aspect updates proj m(1,1) to 2/(size*aspect)')

    call test_summary()

end program test_camera_ortho
