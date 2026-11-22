program test_geo_torusknot
    use math_3d
    use mesh_3d
    use geo_torusknot_3d
    use test_assert
    implicit none

    type(Mesh) :: msh
    integer :: i, k
    real(dp) :: radius, tube, max_r, max_dev, max_ndev, min_area, area
    real(dp) :: dist
    type(vec3) :: centre0, e1, e2, cr
    logical :: finite_ok

    radius = 2.0_dp
    tube = 0.15_dp

    ! ---- exact count: seg 48, tseg 12 -> 48*12*2 = 1152 ----
    call create_torusknot(msh, radius, tube, 48, 12)
    call assert_int_eq(1152, msh%num_triangles, &
        'torusknot (48,12) has exactly 1152 triangles')
    call assert_true(allocated(msh%triangles), 'torusknot mesh is allocated')

    ! ---- no NaNs / finite, bounds, unit normals, no degenerate tris ----
    finite_ok = .true.
    max_r = 0.0_dp
    max_ndev = 0.0_dp
    min_area = huge(1.0_dp)
    do i = 1, msh%num_triangles
        do k = 1, 3
            if (.not. is_finite(msh%triangles(i)%v(k))) finite_ok = .false.
            max_r = max(max_r, vec3_norm(msh%triangles(i)%v(k)))
        end do
        if (.not. is_finite(msh%triangles(i)%normal)) finite_ok = .false.
        max_ndev = max(max_ndev, &
            abs(vec3_norm(msh%triangles(i)%normal) - 1.0_dp))
        e1 = vec3_sub(msh%triangles(i)%v(2), msh%triangles(i)%v(1))
        e2 = vec3_sub(msh%triangles(i)%v(3), msh%triangles(i)%v(1))
        cr = vec3_cross(e1, e2)
        area = 0.5_dp * vec3_norm(cr)
        min_area = min(min_area, area)
    end do
    call assert_true(finite_ok, 'torusknot has no NaN/Inf vertices or normals')
    call assert_true(max_r <= radius * 1.6_dp, &
        'torusknot all verts within radius*1.6 of origin')
    call assert_real_close(0.0_dp, max_ndev, 1.0e-6_dp, &
        'torusknot normals are unit length')
    call assert_true(min_area > 1.0e-8_dp, &
        'torusknot has no degenerate triangles')

    ! ---- tube cross-section at tubular step 0 ----
    ! Centreline at u=0: (radius*(2+cos 0)/2, 0, radius*sin 0/2)
    !                  = (1.5*radius, 0, 0).
    ! In the construction order the first 2*tseg triangles have v(1)
    ! equal to the ring-0 vertices (each twice); every such vertex must
    ! lie at distance tube from the centreline point.
    centre0 = vec3_create(1.5_dp * radius, 0.0_dp, 0.0_dp)
    max_dev = 0.0_dp
    do i = 1, 2 * 12
        dist = vec3_norm(vec3_sub(msh%triangles(i)%v(1), centre0))
        max_dev = max(max_dev, abs(dist - tube))
    end do
    call assert_real_close(0.0_dp, max_dev, 1.0e-4_dp, &
        'torusknot step-0 verts at distance tube from centreline at u=0')

    ! ---- colour: white ----
    call assert_int_eq(255, msh%triangles(1)%color(1), &
        'torusknot tri 1 colour R==255')
    call assert_int_eq(255, msh%triangles(1)%color(2), &
        'torusknot tri 1 colour G==255')
    call assert_int_eq(255, msh%triangles(1)%color(3), &
        'torusknot tri 1 colour B==255')

    ! ---- clamps: segments=2 -> seg 8, tube_segments=1 -> tseg 3 ----
    call create_torusknot(msh, radius, tube, 2, 1)
    call assert_int_eq(48, msh%num_triangles, &
        'torusknot clamped (8,3) has 48 triangles')

    ! ---- guards: radius<=0 -> 1.0, tube<=0 -> radius*0.3, still finite ----
    call create_torusknot(msh, -1.0_dp, -1.0_dp, 48, 12)
    call assert_int_eq(1152, msh%num_triangles, &
        'torusknot guarded inputs keep exact count')
    finite_ok = .true.
    max_r = 0.0_dp
    do i = 1, msh%num_triangles
        do k = 1, 3
            if (.not. is_finite(msh%triangles(i)%v(k))) finite_ok = .false.
            max_r = max(max_r, vec3_norm(msh%triangles(i)%v(k)))
        end do
    end do
    call assert_true(finite_ok, 'torusknot guarded mesh is finite')
    ! Guarded radius 1.0 with tube 0.3: bound is 1.5*1.0 + 0.3 = 1.8.
    call assert_true(max_r <= 1.8_dp + 1.0e-9_dp, &
        'torusknot guarded mesh within 1.5*radius + tube of origin')

    call free_mesh(msh)
    call test_summary()

contains

    pure logical function is_finite(v)
        use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
        type(vec3), intent(in) :: v
        is_finite = ieee_is_finite(v%x) .and. ieee_is_finite(v%y) &
            .and. ieee_is_finite(v%z)
    end function is_finite

end program test_geo_torusknot
