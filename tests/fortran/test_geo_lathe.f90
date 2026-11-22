program test_geo_lathe
    use, intrinsic :: ieee_arithmetic, only: ieee_is_nan
    use math_3d
    use mesh_3d
    use geo_lathe_3d
    use test_assert
    implicit none

    type(Mesh) :: msh
    ! Vase profile, bottom -> top: (radius, y) pairs, y all distinct.
    ! First point has radius 0, so its band contains degenerate tris.
    real(dp) :: vase(8)
    real(dp) :: prof_r(4), prof_y(4)
    real(dp) :: single(2), negprof(4)
    integer :: i, k, t
    logical :: radial_ok, y_ok, normals_ok, no_nan, white_ok
    real(dp) :: radial, cross_norm
    type(vec3) :: v, cr

    vase = [0.0_dp, 0.0_dp, &
            1.0_dp, 0.5_dp, &
            0.6_dp, 1.5_dp, &
            0.9_dp, 2.0_dp]
    prof_r = [0.0_dp, 1.0_dp, 0.6_dp, 0.9_dp]
    prof_y = [0.0_dp, 0.5_dp, 1.5_dp, 2.0_dp]

    ! ---- exact count: (4-1)*12*2 == 72 ----
    call create_lathe(msh, 12, vase, 4)
    call assert_int_eq(72, msh%num_triangles, &
        'lathe vase 4 pts seg=12 has exactly 72 triangles')
    call assert_true(allocated(msh%triangles), 'lathe vase mesh is allocated')
    call assert_int_eq(255, msh%triangles(1)%color(1), 'lathe tri 1 colour R==255')
    call assert_int_eq(255, msh%triangles(1)%color(2), 'lathe tri 1 colour G==255')
    call assert_int_eq(255, msh%triangles(1)%color(3), 'lathe tri 1 colour B==255')

    ! ---- every vertex: radial distance == some profile radius (the one
    !      whose profile y equals the vertex y), y == that profile y ----
    radial_ok = .true.
    y_ok = .true.
    no_nan = .true.
    white_ok = .true.
    do t = 1, msh%num_triangles
        if (any(msh%triangles(t)%color /= [255, 255, 255])) white_ok = .false.
        do k = 1, 3
            v = msh%triangles(t)%v(k)
            if (ieee_is_nan(v%x) .or. ieee_is_nan(v%y) .or. &
                ieee_is_nan(v%z)) no_nan = .false.
            radial = sqrt(v%x * v%x + v%z * v%z)
            i = match_profile(v%y)
            if (i == 0) then
                y_ok = .false.
                radial_ok = .false.
            else if (abs(radial - prof_r(i)) > 1.0e-6_dp) then
                radial_ok = .false.
            end if
        end do
        if (ieee_is_nan(msh%triangles(t)%normal%x) .or. &
            ieee_is_nan(msh%triangles(t)%normal%y) .or. &
            ieee_is_nan(msh%triangles(t)%normal%z)) no_nan = .false.
    end do
    call assert_true(y_ok, 'lathe every vertex y matches a profile y')
    call assert_true(radial_ok, &
        'lathe every vertex radial distance == profile radius (tol 1e-6)')
    call assert_true(no_nan, 'lathe vase has no NaN vertices or normals')
    call assert_true(white_ok, 'lathe all triangles are white')

    ! ---- normals unit where the triangle is non-degenerate ----
    normals_ok = .true.
    do t = 1, msh%num_triangles
        cr = vec3_cross(vec3_sub(msh%triangles(t)%v(2), msh%triangles(t)%v(1)), &
                        vec3_sub(msh%triangles(t)%v(3), msh%triangles(t)%v(1)))
        cross_norm = vec3_norm(cr)
        if (cross_norm > 1.0e-12_dp) then
            if (abs(vec3_norm(msh%triangles(t)%normal) - 1.0_dp) > 1.0e-6_dp) &
                normals_ok = .false.
        end if
    end do
    call assert_true(normals_ok, &
        'lathe normals are unit length where non-degenerate')

    ! Spot-check the geometry directly: some vertex sits at radius 1, y 0.5.
    call assert_real_close(1.0_dp, &
        sqrt(msh%triangles(25)%v(1)%x**2 + msh%triangles(25)%v(1)%z**2), &
        1.0e-6_dp, 'lathe band 2 first vertex radial distance == 1')
    call assert_real_close(0.5_dp, msh%triangles(25)%v(1)%y, 1.0e-6_dp, &
        'lathe band 2 first vertex y == 0.5')

    ! ---- npts < 2 -> empty mesh ----
    single = [1.0_dp, 0.0_dp]
    call create_lathe(msh, 12, single, 1)
    call assert_int_eq(0, msh%num_triangles, 'lathe npts=1 gives empty mesh')

    ! ---- negative radii clamped to 0 ----
    negprof = [-1.0_dp, 0.0_dp, -0.5_dp, 1.0_dp]
    call create_lathe(msh, 8, negprof, 2)
    call assert_int_eq(16, msh%num_triangles, &
        'lathe negative-radius profile 2 pts seg=8 has 16 triangles')
    radial_ok = .true.
    no_nan = .true.
    do t = 1, msh%num_triangles
        do k = 1, 3
            v = msh%triangles(t)%v(k)
            if (sqrt(v%x * v%x + v%z * v%z) > 1.0e-6_dp) radial_ok = .false.
            if (ieee_is_nan(v%x) .or. ieee_is_nan(v%y) .or. &
                ieee_is_nan(v%z)) no_nan = .false.
        end do
    end do
    call assert_true(radial_ok, 'lathe negative radii are clamped to 0')
    call assert_true(no_nan, 'lathe negative-radius profile has no NaNs')

    ! ---- segments clamped: seg = max(3, segments) ----
    call create_lathe(msh, 1, negprof, 2)
    call assert_int_eq(6, msh%num_triangles, &
        'lathe segments=1 clamps to seg=3, 2 pts gives 6 triangles')

    call free_mesh(msh)
    call test_summary()

contains

    integer function match_profile(y) result(idx)
        real(dp), intent(in) :: y
        integer :: q
        idx = 0
        do q = 1, 4
            if (abs(y - prof_y(q)) <= 1.0e-6_dp) idx = q
        end do
    end function match_profile

end program test_geo_lathe
