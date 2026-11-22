program test_fog
    use math_3d, only: dp
    use renderer_3d, only: FrameBuffer, framebuffer_init
    use fog_3d
    use test_assert
    implicit none

    real(dp) :: near, far, f_prev, f_cur, d, z
    integer :: i, blended(3)
    integer :: fog_rgb(3)
    type(FrameBuffer) :: fb
    real(dp), parameter :: cam_near = 1.0_dp, cam_far = 100.0_dp
    real(dp), parameter :: depths(5) = [1.0_dp, 2.0_dp, 5.0_dp, 37.5_dp, 100.0_dp]

    near = 5.0_dp
    far = 50.0_dp
    fog_rgb = [200, 210, 220]

    ! ---- fog_factor_linear: endpoints, midpoint, clamping ----
    call assert_real_close(0.0_dp, fog_factor_linear(near, near, far), 1.0e-12_dp, &
        'linear fog factor is 0 at dist == near')
    call assert_real_close(0.0_dp, fog_factor_linear(1.0_dp, near, far), 1.0e-12_dp, &
        'linear fog factor is 0 below near')
    call assert_real_close(0.0_dp, fog_factor_linear(-3.0_dp, near, far), 1.0e-12_dp, &
        'linear fog factor is 0 for negative dist (clamped)')
    call assert_real_close(1.0_dp, fog_factor_linear(far, near, far), 1.0e-12_dp, &
        'linear fog factor is 1 at dist == far')
    call assert_real_close(1.0_dp, fog_factor_linear(500.0_dp, near, far), 1.0e-12_dp, &
        'linear fog factor is 1 beyond far (clamped)')
    call assert_real_close(0.5_dp, fog_factor_linear(0.5_dp * (near + far), near, far), &
        1.0e-12_dp, 'linear fog factor is 0.5 at (near+far)/2')
    call assert_real_close(0.25_dp, fog_factor_linear(near + 0.25_dp * (far - near), &
        near, far), 1.0e-12_dp, 'linear fog factor is 0.25 at quarter point')

    ! linear monotonicity
    f_prev = fog_factor_linear(0.0_dp, near, far)
    do i = 1, 20
        f_cur = fog_factor_linear(real(i, dp) * 5.0_dp, near, far)
        call assert_true(f_cur >= f_prev, 'linear fog factor is non-decreasing')
        f_prev = f_cur
    end do

    ! ---- fog_factor_exp2: endpoints, known value, monotonicity ----
    call assert_real_close(0.0_dp, fog_factor_exp2(0.0_dp, 0.05_dp), 1.0e-12_dp, &
        'exp2 fog factor is 0 at dist 0')
    call assert_real_close(1.0_dp, fog_factor_exp2(100.0_dp, 0.1_dp), 1.0e-12_dp, &
        'exp2 fog factor is ~1 at large dist')
    ! density*dist = 0.5 -> 1 - exp(-0.25) = 0.22119921692859512...
    call assert_real_close(0.22119921692859512_dp, fog_factor_exp2(10.0_dp, 0.05_dp), &
        1.0e-12_dp, 'exp2 fog factor matches 1-exp(-(density*dist)^2) at 0.5')
    f_prev = fog_factor_exp2(0.0_dp, 0.03_dp)
    do i = 1, 20
        f_cur = fog_factor_exp2(real(i, dp) * 5.0_dp, 0.03_dp)
        call assert_true(f_cur > f_prev, 'exp2 fog factor is strictly increasing')
        call assert_true(f_cur >= 0.0_dp .and. f_cur <= 1.0_dp, &
            'exp2 fog factor stays within [0,1]')
        f_prev = f_cur
    end do

    ! ---- view_distance_from_ndc: endpoints + round-trip ----
    call assert_real_close(cam_near, view_distance_from_ndc(-1.0_dp, cam_near, cam_far), &
        1.0e-9_dp, 'view distance at z=-1 is near')
    call assert_real_close(cam_far, view_distance_from_ndc(1.0_dp, cam_near, cam_far), &
        1.0e-9_dp, 'view distance at z=+1 is far')
    ! Forward perspective mapping (inverse of view_distance_from_ndc):
    !   z = (far + near - 2*near*far/d) / (far - near)
    do i = 1, size(depths)
        d = depths(i)
        z = (cam_far + cam_near - 2.0_dp * cam_near * cam_far / d) / (cam_far - cam_near)
        call assert_real_close(d, view_distance_from_ndc(z, cam_near, cam_far), &
            1.0e-9_dp, 'view distance round-trips through perspective formula')
    end do

    ! ---- fog_blend: f = 0, f = 1, midpoint ----
    blended = fog_blend([0, 100, 200], fog_rgb, 0.0_dp)
    call assert_int_eq(0, blended(1), 'blend f=0 keeps R')
    call assert_int_eq(100, blended(2), 'blend f=0 keeps G')
    call assert_int_eq(200, blended(3), 'blend f=0 keeps B')
    blended = fog_blend([0, 100, 200], fog_rgb, 1.0_dp)
    call assert_int_eq(200, blended(1), 'blend f=1 gives fog R')
    call assert_int_eq(210, blended(2), 'blend f=1 gives fog G')
    call assert_int_eq(220, blended(3), 'blend f=1 gives fog B')
    blended = fog_blend([0, 100, 200], [200, 200, 200], 0.5_dp)
    call assert_int_eq(100, blended(1), 'blend f=0.5 midpoint R')
    call assert_int_eq(150, blended(2), 'blend f=0.5 midpoint G')
    call assert_int_eq(200, blended(3), 'blend f=0.5 midpoint B')

    ! ---- fog_apply (linear) on a hand-built 4x3 framebuffer ----
    ! Camera planes 1..100; fog near 5, fog far 50.
    call framebuffer_init(fb, 4, 3)
    ! (1,1): background pixel -- z stays at the 1e10 sentinel.
    fb%pixels(:, 1, 1) = [25, 25, 35]
    ! (2,1): covered at view depth 2 (<= fog near) -> ~unchanged.
    fb%pixels(:, 2, 1) = [10, 20, 30]
    fb%z_buffer(2, 1) = ndc_from_depth(2.0_dp)
    ! (3,1): covered at view depth 50 (>= fog far) -> fog colour exactly.
    fb%pixels(:, 3, 1) = [10, 20, 30]
    fb%z_buffer(3, 1) = ndc_from_depth(50.0_dp)
    ! (4,1): covered at view depth 27.5 (fog midpoint) -> halfway blend.
    fb%pixels(:, 4, 1) = [0, 100, 200]
    fb%z_buffer(4, 1) = ndc_from_depth(27.5_dp)

    call fog_apply(fb, 1, near, far, fog_rgb, cam_near, cam_far)

    call assert_int_eq(25, fb%pixels(1, 1, 1), 'fog_apply leaves background R unchanged')
    call assert_int_eq(25, fb%pixels(2, 1, 1), 'fog_apply leaves background G unchanged')
    call assert_int_eq(35, fb%pixels(3, 1, 1), 'fog_apply leaves background B unchanged')
    call assert_int_eq(10, fb%pixels(1, 2, 1), 'fog_apply near pixel R unchanged')
    call assert_int_eq(20, fb%pixels(2, 2, 1), 'fog_apply near pixel G unchanged')
    call assert_int_eq(30, fb%pixels(3, 2, 1), 'fog_apply near pixel B unchanged')
    call assert_int_eq(200, fb%pixels(1, 3, 1), 'fog_apply far pixel R is fog colour')
    call assert_int_eq(210, fb%pixels(2, 3, 1), 'fog_apply far pixel G is fog colour')
    call assert_int_eq(220, fb%pixels(3, 3, 1), 'fog_apply far pixel B is fog colour')
    ! midpoint: (0,100,200) halfway to (200,210,220) = (100,155,210)
    call assert_int_eq(100, fb%pixels(1, 4, 1), 'fog_apply mid pixel R halfway to fog')
    call assert_int_eq(155, fb%pixels(2, 4, 1), 'fog_apply mid pixel G halfway to fog')
    call assert_int_eq(210, fb%pixels(3, 4, 1), 'fog_apply mid pixel B halfway to fog')
    ! untouched rows remain background
    call assert_int_eq(25, fb%pixels(1, 1, 3), 'fog_apply leaves other bg pixels unchanged')

    ! ---- fog_apply (exp2): far pixel converges to fog colour ----
    call framebuffer_init(fb, 4, 3)
    fb%pixels(:, 1, 1) = [0, 0, 0]
    fb%z_buffer(1, 1) = ndc_from_depth(100.0_dp)
    call fog_apply(fb, 2, 0.1_dp, 0.0_dp, fog_rgb, cam_near, cam_far)
    call assert_int_eq(200, fb%pixels(1, 1, 1), 'fog_apply exp2 far pixel R is fog colour')
    call assert_int_eq(210, fb%pixels(2, 1, 1), 'fog_apply exp2 far pixel G is fog colour')
    call assert_int_eq(220, fb%pixels(3, 1, 1), 'fog_apply exp2 far pixel B is fog colour')
    call assert_int_eq(25, fb%pixels(1, 2, 2), 'fog_apply exp2 leaves background unchanged')

    ! ---- fog_apply: unknown mode is a no-op ----
    call framebuffer_init(fb, 4, 3)
    fb%pixels(:, 1, 1) = [10, 20, 30]
    fb%z_buffer(1, 1) = ndc_from_depth(50.0_dp)
    call fog_apply(fb, 99, near, far, fog_rgb, cam_near, cam_far)
    call assert_int_eq(10, fb%pixels(1, 1, 1), 'fog_apply unknown mode leaves R unchanged')
    call assert_int_eq(20, fb%pixels(2, 1, 1), 'fog_apply unknown mode leaves G unchanged')
    call assert_int_eq(30, fb%pixels(3, 1, 1), 'fog_apply unknown mode leaves B unchanged')

    call test_summary()

contains

    ! Forward perspective mapping: NDC z for a view depth d under the
    ! test camera planes (inverse of view_distance_from_ndc).
    pure function ndc_from_depth(d) result(z)
        real(dp), intent(in) :: d
        real(dp) :: z
        z = (cam_far + cam_near - 2.0_dp * cam_near * cam_far / d) / (cam_far - cam_near)
    end function ndc_from_depth

end program test_fog
