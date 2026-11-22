! test_lighting.f90 -- tests for lighting_3d (src/lighting.f90):
! attenuation, spot cone, point/directional shading, the load-bearing
! legacy-equivalence case (v1: intensity = ambient + (1-ambient)*diffuse
! with ambient = 0.25), basic-mode bypass, and shadow_factor behaviour.
program test_lighting
    use math_3d
    use material_pbr_3d
    use lighting_3d
    use test_assert
    implicit none

    type(Light3) :: dir_light, pt_light, spot_light
    type(LightSet) :: lights, empty_lights
    type(MaterialPBR) :: lambert, basic, phong
    type(vec3) :: n_up, origin, cam_above, frag_dir
    integer :: base(3), rgb(3), expected(3), k
    real(dp) :: f, theta

    base = [200, 100, 50]
    n_up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
    origin = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    cam_above = vec3_create(0.0_dp, 5.0_dp, 0.0_dp)

    lambert%mode = 0
    basic%mode = 1
    phong%mode = 2

    ! ---- type defaults ----
    call assert_int_eq(dir_light%kind, 0, 'Light3 default kind is directional')
    call assert_real_close(dir_light%intensity, 1.0_dp, 1.0e-12_dp, &
        'Light3 default intensity 1')
    call assert_real_close(dir_light%decay, 2.0_dp, 1.0e-12_dp, 'Light3 default decay 2')
    call assert_real_close(dir_light%distance, 0.0_dp, 1.0e-12_dp, &
        'Light3 default distance 0 (no cutoff)')
    call assert_real_close(dir_light%angle_deg, 45.0_dp, 1.0e-12_dp, &
        'Light3 default spot angle 45')
    call assert_true(all(dir_light%color == 255), 'Light3 default color white')
    call assert_real_close(lights%ambient, 0.25_dp, 1.0e-12_dp, &
        'LightSet default ambient 0.25')
    call assert_true(all(lights%ambient_color == 255), 'LightSet default ambient color white')

    ! ---- light_attenuation ----
    call assert_real_close(light_attenuation(1.0_dp, 0.0_dp, 2.0_dp), 1.0_dp, &
        1.0e-12_dp, 'attenuation dist 1 decay 2 = 1')
    call assert_real_close(light_attenuation(2.0_dp, 0.0_dp, 2.0_dp), 0.25_dp, &
        1.0e-12_dp, 'attenuation dist 2 decay 2 = 0.25')
    call assert_real_close(light_attenuation(2.0_dp, 0.0_dp, 0.0_dp), 1.0_dp, &
        1.0e-12_dp, 'attenuation decay 0 = 1 (no falloff)')
    call assert_real_close(light_attenuation(7.0_dp, 0.0_dp, 0.0_dp), 1.0_dp, &
        1.0e-12_dp, 'attenuation decay 0 = 1 at any distance (no cutoff)')
    call assert_real_close(light_attenuation(0.5_dp, 0.0_dp, 2.0_dp), 1.0_dp, &
        1.0e-12_dp, 'attenuation capped at 1 for dist < 1')
    call assert_real_close(light_attenuation(3.0_dp, 2.0_dp, 2.0_dp), 0.0_dp, &
        1.0e-12_dp, 'attenuation beyond cutoff distance = 0')
    call assert_real_close(light_attenuation(2.0_dp, 2.0_dp, 2.0_dp), 0.0_dp, &
        1.0e-12_dp, 'attenuation at cutoff distance = 0')
    call assert_real_close(light_attenuation(1.0_dp, 2.0_dp, 0.0_dp), 0.87890625_dp, &
        1.0e-12_dp, 'attenuation smooth cutoff inside distance (decay 0)')
    call assert_real_close(light_attenuation(2.0_dp, 4.0_dp, 2.0_dp), 0.2197265625_dp, &
        1.0e-12_dp, 'attenuation falloff times smooth cutoff')

    ! ---- spot_factor ----
    spot_light%kind = 2
    spot_light%angle_deg = 45.0_dp
    spot_light%penumbra = 0.5_dp
    spot_light%spot_dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)

    f = spot_factor(spot_light, vec3_create(0.0_dp, -1.0_dp, 0.0_dp))
    call assert_real_close(f, 1.0_dp, 1.0e-12_dp, 'spot factor on axis = 1')

    f = spot_factor(spot_light, vec3_create(0.0_dp, 1.0_dp, 0.0_dp))
    call assert_real_close(f, 0.0_dp, 1.0e-12_dp, 'spot factor behind light = 0')

    f = spot_factor(spot_light, vec3_create(1.0_dp, 0.0_dp, 0.0_dp))
    call assert_real_close(f, 0.0_dp, 1.0e-12_dp, 'spot factor at 90 degrees = 0')

    ! penumbra midpoint: inner = 22.5 deg, outer = 45 deg, angle = 33.75 deg
    theta = deg2rad(33.75_dp)
    frag_dir = vec3_create(sin(theta), -cos(theta), 0.0_dp)
    f = spot_factor(spot_light, frag_dir)
    call assert_true(f > 0.0_dp .and. f < 1.0_dp, 'spot penumbra midpoint in (0,1)')
    call assert_real_close(f, 0.5_dp, 1.0e-9_dp, 'spot penumbra midpoint = smoothstep 0.5')

    spot_light%penumbra = 0.0_dp
    theta = deg2rad(30.0_dp)
    f = spot_factor(spot_light, vec3_create(sin(theta), -cos(theta), 0.0_dp))
    call assert_real_close(f, 1.0_dp, 1.0e-12_dp, 'spot hard edge: inside cone = 1')
    theta = deg2rad(60.0_dp)
    f = spot_factor(spot_light, vec3_create(sin(theta), -cos(theta), 0.0_dp))
    call assert_real_close(f, 0.0_dp, 1.0e-12_dp, 'spot hard edge: outside cone = 0')

    pt_light%kind = 1
    f = spot_factor(pt_light, vec3_create(0.0_dp, 1.0_dp, 0.0_dp))
    call assert_real_close(f, 1.0_dp, 1.0e-12_dp, 'spot factor is 1 for non-spot lights')

    ! ---- legacy equivalence: one directional, intensity 1, white, ----
    ! ---- ambient 0.25, lambert, shadow 1                             ----
    allocate(lights%items(1))
    lights%items(1)%kind = 0
    lights%items(1)%dir = vec3_create(0.0_dp, -2.0_dp, 0.0_dp) ! travels -Y (non-unit on purpose)

    rgb = shade_rgb(base, n_up, origin, cam_above, lights, lambert, 1.0_dp)
    expected = int(real(base, dp) * (0.25_dp + 0.75_dp * 1.0_dp))
    do k = 1, 3
        call assert_true(abs(rgb(k) - expected(k)) <= 1, &
            'legacy equivalence diffuse=1 within +/-1')
    end do
    call assert_true(all(rgb == base), 'legacy diffuse=1 gives base colour exactly')

    ! diffuse = 0.5: L = (0, 0.5, sqrt(0.75)), light travels along -L
    lights%items(1)%dir = vec3_create(0.0_dp, -0.5_dp, -sqrt(0.75_dp))
    rgb = shade_rgb(base, n_up, origin, cam_above, lights, lambert, 1.0_dp)
    expected = int(real(base, dp) * (0.25_dp + 0.75_dp * 0.5_dp))
    do k = 1, 3
        call assert_true(abs(rgb(k) - expected(k)) <= 1, &
            'legacy equivalence diffuse=0.5 within +/-1')
    end do

    ! diffuse = 0: light travels +Y, away from the +Y normal
    lights%items(1)%dir = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
    rgb = shade_rgb(base, n_up, origin, cam_above, lights, lambert, 1.0_dp)
    expected = int(real(base, dp) * 0.25_dp)
    do k = 1, 3
        call assert_true(abs(rgb(k) - expected(k)) <= 1, &
            'legacy equivalence diffuse=0 within +/-1')
    end do

    ! ---- point light above / behind ----
    base = [80, 120, 200]
    pt_light%kind = 1
    pt_light%pos = vec3_create(0.0_dp, 1.0_dp, 0.0_dp) ! dist 1: attenuation 1
    lights%items(1) = pt_light
    rgb = shade_rgb(base, n_up, origin, cam_above, lights, lambert, 1.0_dp)
    call assert_true(all(rgb == base), 'point light directly above +Y normal: full diffuse')

    pt_light%pos = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
    lights%items(1) = pt_light
    rgb = shade_rgb(base, n_up, origin, cam_above, lights, lambert, 1.0_dp)
    call assert_true(all(rgb == [20, 30, 50]), 'point light behind: ambient only')

    ! ---- no lights allocated: ambient only, ambient colour tints ----
    rgb = shade_rgb(base, n_up, origin, cam_above, empty_lights, lambert, 1.0_dp)
    call assert_true(all(rgb == [20, 30, 50]), 'empty light set: ambient only')
    empty_lights%ambient_color = [255, 0, 0]
    rgb = shade_rgb(base, n_up, origin, cam_above, empty_lights, lambert, 1.0_dp)
    call assert_true(all(rgb == [20, 0, 0]), 'ambient colour tints the ambient term')

    ! ---- basic mode ignores lights and shadow ----
    pt_light%pos = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
    lights%items(1) = pt_light
    rgb = shade_rgb(base, n_up, origin, cam_above, lights, basic, 0.0_dp)
    call assert_true(all(rgb == base), 'basic mode returns base unchanged (lights+shadow ignored)')

    ! ---- shadow_factor 0: diffuse + specular killed, ambient kept ----
    rgb = shade_rgb(base, n_up, origin, cam_above, lights, phong, 0.0_dp)
    call assert_true(all(rgb == [20, 30, 50]), 'shadow 0 kills diffuse+specular, keeps ambient')

    rgb = shade_rgb(base, n_up, origin, cam_above, lights, lambert, 0.0_dp)
    call assert_true(all(rgb == [20, 30, 50]), 'shadow 0 kills diffuse, keeps ambient')

    ! ---- phong specular actually adds light when unshadowed ----
    rgb = shade_rgb(base, n_up, origin, cam_above, lights, phong, 1.0_dp)
    call assert_true(rgb(1) > base(1), 'phong specular adds above the lambert result')

    call test_summary()
end program test_lighting
