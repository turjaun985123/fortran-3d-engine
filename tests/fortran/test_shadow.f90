program test_shadow
    use math_3d
    use mesh_3d
    use shadow_3d
    use test_assert
    implicit none

    type(ShadowMap) :: smap, empty_map
    type(Mesh) :: cube
    type(mat4) :: identity
    type(vec3) :: light_pos, light_target
    real(dp) :: f

    identity = mat4_identity()

    ! ---- empty / never-built map lights everything ----
    f = shadow_factor(empty_map, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'empty shadow map gives factor 1')
    f = shadow_factor_pcf(empty_map, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'empty shadow map gives PCF factor 1')
    call assert_false(empty_map%ready, 'default ShadowMap is not ready')
    call assert_int_eq(0, empty_map%size, 'default ShadowMap size is 0')

    ! ---- build: cube size 2 at origin, light directly above ----
    ! Light on +Y axis looking at the origin exercises the parallel-up
    ! fallback in shadow_begin (direction (0,-1,0) vs up +Y -> +X).
    light_pos = vec3_create(0.0_dp, 5.0_dp, 0.0_dp)
    light_target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    call create_cube(cube, 2.0_dp)

    call shadow_begin(smap, light_pos, light_target, 64, 60.0_dp, 1.0_dp, 20.0_dp)
    call assert_int_eq(64, smap%size, 'shadow_begin stores size 64')
    call assert_true(allocated(smap%depth), 'shadow_begin allocates depth')
    call assert_false(smap%ready, 'map not ready before shadow_end')
    call assert_true(smap%depth(1, 1) > 1.0e9_dp, 'depth cleared to sentinel at corner')

    ! Not ready yet -> still lit even where the cube will shadow.
    f = shadow_factor(smap, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'factor 1 before shadow_end (not ready)')

    call shadow_add_mesh(smap, cube, identity)
    call shadow_end(smap)
    call assert_true(smap%ready, 'map ready after shadow_end')
    call assert_true(smap%depth(32, 32) < 1.0e9_dp, 'centre depth written by cube')

    ! ---- point directly under the cube centre is shadowed ----
    f = shadow_factor(smap, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'point under cube centre is shadowed (0)')

    ! ---- point 5 units to the side is lit ----
    ! (5,-1.5,0) projects outside the light frustum -> lit by rule.
    f = shadow_factor(smap, vec3_create(5.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'point 5 units to the side is lit (1)')
    ! (3,-1.5,0) is inside the frustum but well outside the cube shadow.
    f = shadow_factor(smap, vec3_create(3.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'in-frustum point outside shadow is lit (1)')

    ! ---- point on the cube's lit top surface is lit ----
    f = shadow_factor(smap, vec3_create(0.0_dp, 1.0_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'point on lit top surface is lit (1)')
    f = shadow_factor_pcf(smap, vec3_create(0.0_dp, 1.0_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'PCF on lit top surface is 1')

    ! ---- PCF deep inside the shadow is 0 ----
    f = shadow_factor_pcf(smap, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'PCF under cube centre is 0')

    ! ---- PCF at the shadow edge is fractional ----
    ! The shadow edge on the ground plane y=-1.5 is NOT at the cube's
    ! geometric edge x=1: shadow maps are a perspective projection from
    ! the light, so the ray from (0,5,0) through the cube's top edge
    ! (1,1,0) (distance 4 from the light) reaches y=-1.5 (distance 6.5)
    ! at x = 6.5/4 = 1.625.  At x=1.60 the sample pixel sits just inside
    ! the shadow and its 3x3 neighbourhood straddles the rasterised
    ! edge, giving a genuinely fractional PCF (measured 3 of 9 taps lit
    ! = 1/3 with this 64x64 map) while the single-tap factor is still 0.
    f = shadow_factor(smap, vec3_create(1.60_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'single tap just inside edge is shadowed')
    f = shadow_factor_pcf(smap, vec3_create(1.60_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_true(f > 0.0_dp .and. f < 1.0_dp, 'PCF at shadow edge is strictly between 0 and 1')
    call assert_real_close(1.0_dp / 3.0_dp, f, 1.0e-12_dp, 'PCF at shadow edge is 1/3 (3 of 9 taps lit)')

    ! ---- default bias argument (omitted) agrees on the centre point ----
    f = shadow_factor(smap, vec3_create(0.0_dp, -1.5_dp, 0.0_dp))
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'factor with default bias still shadows centre')

    ! ---- accumulation: a second caster added to a fresh map also shadows ----
    call shadow_begin(smap, light_pos, light_target, 64, 60.0_dp, 1.0_dp, 20.0_dp)
    call shadow_add_mesh(smap, cube, identity)
    call shadow_add_mesh(smap, cube, mat4_translation(3.0_dp, 0.0_dp, 0.0_dp))
    call shadow_end(smap)
    f = shadow_factor(smap, vec3_create(3.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'second accumulated caster shadows its ground point')
    f = shadow_factor(smap, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(0.0_dp, f, 1.0e-12_dp, 'first caster still shadows after accumulation')

    ! ---- shadow_free resets the map ----
    call shadow_free(smap)
    call assert_int_eq(0, smap%size, 'shadow_free resets size to 0')
    call assert_false(smap%ready, 'shadow_free clears ready')
    call assert_false(allocated(smap%depth), 'shadow_free deallocates depth')
    f = shadow_factor(smap, vec3_create(0.0_dp, -1.5_dp, 0.0_dp), 0.002_dp)
    call assert_real_close(1.0_dp, f, 1.0e-12_dp, 'factor 1 after shadow_free')

    call free_mesh(cube)
    call test_summary()

end program test_shadow
