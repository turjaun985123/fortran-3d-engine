program test_geo_capsule
    use math_3d
    use mesh_3d
    use geo_capsule_3d
    use test_assert
    implicit none

    type(Mesh) :: msh
    type(vec3) :: v, e1, e2
    integer :: i, k
    real(dp) :: radius, height, hh, max_y, dist, radial
    logical :: bound_ok, normals_ok, no_degen_ok

    radius = 0.8_dp
    height = 2.0_dp
    hh = height * 0.5_dp

    ! ---- exact counts: seg=16 -> hr=4 -> 2*16 + 2*16*(2*4-1) = 256 ----
    call create_capsule(msh, radius, height, 16)
    call assert_int_eq(256, msh%num_triangles, 'capsule segments=16 has 256 triangles')
    call assert_true(allocated(msh%triangles), 'capsule segments=16 is allocated')

    ! ---- exact counts: seg=8 -> hr=2 -> 2*8 + 2*8*(2*2-1) = 64 ----
    call create_capsule(msh, radius, height, 8)
    call assert_int_eq(64, msh%num_triangles, 'capsule segments=8 has 64 triangles')

    ! ---- geometry checks on the seg=16 capsule ----
    call create_capsule(msh, radius, height, 16)

    bound_ok = .true.
    normals_ok = .true.
    no_degen_ok = .true.
    max_y = 0.0_dp
    do i = 1, msh%num_triangles
        if (abs(vec3_norm(msh%triangles(i)%normal) - 1.0_dp) > 1.0e-6_dp) &
            normals_ok = .false.
        e1 = vec3_sub(msh%triangles(i)%v(2), msh%triangles(i)%v(1))
        e2 = vec3_sub(msh%triangles(i)%v(3), msh%triangles(i)%v(1))
        if (vec3_norm(vec3_cross(e1, e2)) <= 1.0e-12_dp) no_degen_ok = .false.
        do k = 1, 3
            v = msh%triangles(i)%v(k)
            max_y = max(max_y, abs(v%y))
            if (v%y > hh) then
                ! Top cap: distance from the top cap centre (0, hh, 0).
                dist = sqrt(v%x * v%x + (v%y - hh) * (v%y - hh) + v%z * v%z)
                if (dist > radius + 1.0e-6_dp) bound_ok = .false.
            else if (v%y < -hh) then
                ! Bottom cap: distance from the bottom cap centre (0, -hh, 0).
                dist = sqrt(v%x * v%x + (v%y + hh) * (v%y + hh) + v%z * v%z)
                if (dist > radius + 1.0e-6_dp) bound_ok = .false.
            else
                ! Mid-section: radial distance from the Y axis.
                radial = sqrt(v%x * v%x + v%z * v%z)
                if (radial > radius + 1.0e-6_dp) bound_ok = .false.
            end if
        end do
    end do
    call assert_true(bound_ok, 'capsule vertices satisfy the capsule bound')
    call assert_real_close(height * 0.5_dp + radius, max_y, 1.0e-6_dp, &
        'capsule max |y| == height/2 + radius')
    call assert_true(normals_ok, 'capsule normals are all unit length')
    call assert_true(no_degen_ok, 'capsule has no degenerate triangles')

    call free_mesh(msh)

    call test_summary()

end program test_geo_capsule
