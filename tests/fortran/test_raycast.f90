program test_raycast
    use math_3d
    use mesh_3d
    use raycast_3d
    use test_assert
    implicit none

    type(Mesh) :: cube
    type(mat4) :: identity, rot45
    type(RayHit) :: hit, fresh
    type(vec3) :: origin, dir, v1, v2, v3, expected_point
    real(dp) :: t, u, v, s45, c45, t_expected
    logical :: ok

    identity = mat4_identity()
    call create_cube(cube, 2.0_dp)   ! spans -1..1 on every axis

    ! ---- default RayHit is a miss ----
    call assert_false(fresh%hit, 'default RayHit is no hit')
    call assert_int_eq(0, fresh%tri_index, 'default RayHit tri_index is 0')
    call assert_real_close(fresh%t, 0.0_dp, 1.0e-12_dp, 'default RayHit t is 0')

    ! ---- ray down -Z onto the front (z = +1) face ----
    origin = vec3_create(0.0_dp, 0.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, -1.0_dp)
    call ray_cast_mesh(origin, dir, cube, identity, hit)
    call assert_true(hit%hit, 'ray from (0,0,5) down -Z hits the cube')
    call assert_real_close(hit%t, 4.0_dp, 1.0e-12_dp, 'front hit t == 4')
    call assert_real_close(hit%point%z, 1.0_dp, 1.0e-12_dp, 'front hit point z == 1')
    call assert_vec3_close(hit%point, vec3_create(0.0_dp, 0.0_dp, 1.0_dp), &
                           1.0e-12_dp, 'front hit point is (0,0,1)')
    call assert_true(hit%tri_index == 5 .or. hit%tri_index == 6, &
                     'front hit is a north-face triangle (5 or 6)')
    call assert_real_close(sum(hit%bary), 1.0_dp, 1.0e-12_dp, 'front hit bary sums to 1')
    call assert_true(all(hit%bary >= 0.0_dp) .and. all(hit%bary <= 1.0_dp), &
                     'front hit bary weights in [0,1]')

    ! ---- ray down -X onto the east (x = +1) face ----
    origin = vec3_create(5.0_dp, 0.0_dp, 0.0_dp)
    dir = vec3_create(-1.0_dp, 0.0_dp, 0.0_dp)
    call ray_cast_mesh(origin, dir, cube, identity, hit)
    call assert_true(hit%hit, 'ray from (5,0,0) down -X hits the cube')
    call assert_real_close(hit%t, 4.0_dp, 1.0e-12_dp, 'east hit t == 4')
    call assert_real_close(hit%point%x, 1.0_dp, 1.0e-12_dp, 'east hit point x == 1')
    call assert_true(hit%tri_index == 3 .or. hit%tri_index == 4, &
                     'east hit is an east-face triangle (3 or 4)')

    ! ---- unnormalised dir: t is in dir units ----
    origin = vec3_create(0.0_dp, 0.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, -2.0_dp)
    call ray_cast_mesh(origin, dir, cube, identity, hit)
    call assert_true(hit%hit, 'ray with dir (0,0,-2) hits the cube')
    call assert_real_close(hit%t, 2.0_dp, 1.0e-12_dp, 'unnormalised dir hit t == 2 (dir units)')
    call assert_real_close(hit%point%z, 1.0_dp, 1.0e-12_dp, 'unnormalised dir hit point z == 1')

    ! ---- missing ray ----
    origin = vec3_create(5.0_dp, 5.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
    call ray_cast_mesh(origin, dir, cube, identity, hit)
    call assert_false(hit%hit, 'ray from (5,5,5) along +Y misses the cube')
    call assert_int_eq(0, hit%tri_index, 'miss leaves tri_index 0')
    call assert_real_close(hit%t, 0.0_dp, 1.0e-12_dp, 'miss leaves t 0')

    ! ---- ray pointing away from the cube ----
    origin = vec3_create(0.0_dp, 0.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
    call ray_cast_mesh(origin, dir, cube, identity, hit)
    call assert_false(hit%hit, 'ray from (0,0,5) along +Z (away) misses')

    ! ---- ray from inside the cube: smallest positive t wins ----
    ! From the centre down -Z the exit face is z = -1 at t = 1; the
    ! entry-side face behind the ray (t = -1) must not be reported.
    origin = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, -1.0_dp)
    call ray_cast_mesh(origin, dir, cube, identity, hit)
    call assert_true(hit%hit, 'ray from inside the cube hits')
    call assert_real_close(hit%t, 1.0_dp, 1.0e-12_dp, 'inside hit t == 1 (smallest positive)')
    call assert_real_close(hit%point%z, -1.0_dp, 1.0e-12_dp, 'inside hit point z == -1')

    ! ---- rotated model: 45 degrees about Y, ray down -Z ----
    ! The z = +1 face rotates to the plane n.w = 1 with
    ! n = (sin45, 0, cos45).  For a ray from (0.5, 0, 5) along -Z:
    !   s45*0.5 + c45*(5 - t) = 1  ->  t = 5 - (1 - 0.5*s45)/c45.
    rot45 = mat4_rotate_y(deg2rad(45.0_dp))
    s45 = sin(PI / 4.0_dp)
    c45 = cos(PI / 4.0_dp)
    t_expected = 5.0_dp - (1.0_dp - 0.5_dp * s45) / c45
    origin = vec3_create(0.5_dp, 0.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, -1.0_dp)
    call ray_cast_mesh(origin, dir, cube, rot45, hit)
    call assert_true(hit%hit, 'rotated cube: ray down -Z hits')
    call assert_true(hit%t > 0.0_dp, 'rotated cube: hit t > 0')
    call assert_real_close(hit%t, t_expected, 1.0e-6_dp, 'rotated cube: t matches rotated face plane')
    expected_point = vec3_create(0.5_dp, 0.0_dp, 5.0_dp - t_expected)
    call assert_vec3_close(hit%point, expected_point, 1.0e-6_dp, &
                           'rotated cube: point matches expected hit point')
    call assert_vec3_close(hit%point, vec3_add(origin, vec3_scale(dir, hit%t)), &
                           1.0e-12_dp, 'rotated cube: point == origin + t*dir')

    ! ---- ray_triangle direct: centroid of a known triangle ----
    v1 = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    v2 = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
    v3 = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
    origin = vec3_create(1.0_dp / 3.0_dp, 1.0_dp / 3.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, -1.0_dp)
    ok = ray_triangle(origin, dir, v1, v2, v3, t, u, v)
    call assert_true(ok, 'ray_triangle: centroid ray hits')
    call assert_real_close(t, 5.0_dp, 1.0e-12_dp, 'ray_triangle: centroid t == 5')
    call assert_real_close(u, 1.0_dp / 3.0_dp, 1.0e-12_dp, 'ray_triangle: u == 1/3')
    call assert_real_close(v, 1.0_dp / 3.0_dp, 1.0e-12_dp, 'ray_triangle: v == 1/3')
    call assert_real_close(1.0_dp - u - v, 1.0_dp / 3.0_dp, 1.0e-12_dp, &
                           'ray_triangle: bary (1-u-v) == 1/3')

    ! ---- ray_triangle: parallel ray misses ----
    origin = vec3_create(1.0_dp / 3.0_dp, 1.0_dp / 3.0_dp, 1.0_dp)
    dir = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
    ok = ray_triangle(origin, dir, v1, v2, v3, t, u, v)
    call assert_false(ok, 'ray_triangle: parallel ray misses')
    call assert_real_close(t, 0.0_dp, 1.0e-12_dp, 'ray_triangle: parallel miss leaves t 0')

    ! ---- ray_triangle: ray landing outside the triangle misses ----
    origin = vec3_create(2.0_dp, 2.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, -1.0_dp)
    ok = ray_triangle(origin, dir, v1, v2, v3, t, u, v)
    call assert_false(ok, 'ray_triangle: ray outside triangle misses')

    ! ---- ray_triangle: backface is accepted (both windings) ----
    origin = vec3_create(1.0_dp / 3.0_dp, 1.0_dp / 3.0_dp, -5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
    ok = ray_triangle(origin, dir, v1, v2, v3, t, u, v)
    call assert_true(ok, 'ray_triangle: backface ray hits (both windings accepted)')
    call assert_real_close(t, 5.0_dp, 1.0e-12_dp, 'ray_triangle: backface t == 5')

    ! ---- ray_triangle: triangle behind the ray misses ----
    origin = vec3_create(1.0_dp / 3.0_dp, 1.0_dp / 3.0_dp, 5.0_dp)
    dir = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
    ok = ray_triangle(origin, dir, v1, v2, v3, t, u, v)
    call assert_false(ok, 'ray_triangle: triangle behind ray misses')

    call free_mesh(cube)
    call test_summary()

end program test_raycast
