program test_geo_tube
    use, intrinsic :: ieee_arithmetic, only: ieee_is_nan
    use math_3d
    use mesh_3d
    use geo_tube_3d
    use test_assert
    implicit none

    type(Mesh) :: msh
    real(dp) :: straight(6), lpath(9), one_pt(3)
    integer :: side_tris

    straight = [0.0_dp, 0.0_dp, 0.0_dp, &
                2.0_dp, 0.0_dp, 0.0_dp]
    lpath = [0.0_dp, 0.0_dp, 0.0_dp, &
             1.0_dp, 0.0_dp, 0.0_dp, &
             1.0_dp, 1.0_dp, 0.0_dp]
    one_pt = [0.0_dp, 0.0_dp, 0.0_dp]

    ! ---- straight 2-point path, seg 8: 8*2 sides + 16 caps = 32 ----
    call create_tube(msh, 0.5_dp, 8, straight, 2)
    call assert_int_eq(32, msh%num_triangles, &
        'tube straight seg=8 has 8*2+16=32 triangles')
    side_tris = 16
    call check_mesh(msh, straight, 2, 0.5_dp, side_tris, 'straight')
    ! Start cap (first cap tri) normal opposes the +X start tangent;
    ! end cap (last tri) normal follows the +X end tangent.
    call assert_true(vec3_dot(msh%triangles(side_tris + 1)%normal, &
        vec3_create(1.0_dp, 0.0_dp, 0.0_dp)) < 0.0_dp, &
        'straight start-cap normal opposes start tangent')
    call assert_true(vec3_dot(msh%triangles(msh%num_triangles)%normal, &
        vec3_create(1.0_dp, 0.0_dp, 0.0_dp)) > 0.0_dp, &
        'straight end-cap normal follows end tangent (outward)')
    ! Cap centres sit exactly at the path ends.
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        msh%triangles(side_tris + 1)%v(1), 1.0e-12_dp, &
        'straight start-cap centre is the first path point')
    call assert_vec3_close(vec3_create(2.0_dp, 0.0_dp, 0.0_dp), &
        msh%triangles(msh%num_triangles)%v(1), 1.0e-12_dp, &
        'straight end-cap centre is the last path point')

    ! ---- 3-point L path, seg 8: (3-1)*8*2 sides + 16 caps = 48 ----
    call create_tube(msh, 0.3_dp, 8, lpath, 3)
    call assert_int_eq(48, msh%num_triangles, &
        'tube L-path seg=8 has 32+16=48 triangles')
    side_tris = 32
    call check_mesh(msh, lpath, 3, 0.3_dp, side_tris, 'L-path')
    call assert_true(vec3_dot(msh%triangles(side_tris + 1)%normal, &
        vec3_create(1.0_dp, 0.0_dp, 0.0_dp)) < 0.0_dp, &
        'L-path start-cap normal opposes start tangent')
    call assert_true(vec3_dot(msh%triangles(msh%num_triangles)%normal, &
        vec3_create(0.0_dp, 1.0_dp, 0.0_dp)) > 0.0_dp, &
        'L-path end-cap normal follows end tangent (outward)')

    ! ---- npts < 2 gives an empty mesh ----
    call create_tube(msh, 0.5_dp, 8, one_pt, 1)
    call assert_int_eq(0, msh%num_triangles, 'tube npts=1 has 0 triangles')
    call create_tube(msh, 0.5_dp, 8, one_pt, 0)
    call assert_int_eq(0, msh%num_triangles, 'tube npts=0 has 0 triangles')

    ! ---- radius <= 0 guarded to 0.2 ----
    call create_tube(msh, 0.0_dp, 8, straight, 2)
    call assert_int_eq(32, msh%num_triangles, &
        'tube radius=0 still has 32 triangles')
    call check_mesh(msh, straight, 2, 0.2_dp, 16, 'radius-guard')

    ! ---- segments clamped to at least 3: (2-1)*3*2 + 2*3 = 12 ----
    call create_tube(msh, 0.5_dp, 2, straight, 2)
    call assert_int_eq(12, msh%num_triangles, &
        'tube segments=2 clamped to seg=3 has 12 triangles')
    call check_mesh(msh, straight, 2, 0.5_dp, 6, 'seg-clamp')

    call free_mesh(msh)
    call test_summary()

contains

    ! For every side triangle: all vertices are ring vertices, so the
    ! distance from each vertex to its nearest path point must equal
    ! radius (path segment lengths here are 1 and 2, both >> radius,
    ! so the nearest path point is the ring's own centre).
    ! For every triangle: no NaNs, unit normal, non-degenerate.
    subroutine check_mesh(m, pts_flat, npts, radius, n_side, label)
        type(Mesh), intent(in) :: m
        real(dp), intent(in) :: pts_flat(*), radius
        integer, intent(in) :: npts, n_side
        character(len=*), intent(in) :: label
        integer :: t, k, j
        type(vec3) :: v, pj, e1, e2
        real(dp) :: dmin, area2
        logical :: no_nan, unit_ok, nondeg

        no_nan = .true.
        unit_ok = .true.
        nondeg = .true.
        do t = 1, m%num_triangles
            do k = 1, 3
                v = m%triangles(t)%v(k)
                if (ieee_is_nan(v%x) .or. ieee_is_nan(v%y) .or. ieee_is_nan(v%z)) no_nan = .false.
            end do
            v = m%triangles(t)%normal
            if (ieee_is_nan(v%x) .or. ieee_is_nan(v%y) .or. ieee_is_nan(v%z)) no_nan = .false.
            if (abs(vec3_norm(m%triangles(t)%normal) - 1.0_dp) > 1.0e-6_dp) &
                unit_ok = .false.
            e1 = vec3_sub(m%triangles(t)%v(2), m%triangles(t)%v(1))
            e2 = vec3_sub(m%triangles(t)%v(3), m%triangles(t)%v(1))
            area2 = vec3_norm(vec3_cross(e1, e2))
            if (area2 <= 1.0e-10_dp) nondeg = .false.
        end do
        call assert_true(no_nan, label//' tube has no NaN vertices or normals')
        call assert_true(unit_ok, label//' tube normals are unit length')
        call assert_true(nondeg, label//' tube has no degenerate triangles')

        do t = 1, n_side
            do k = 1, 3
                v = m%triangles(t)%v(k)
                dmin = huge(1.0_dp)
                do j = 1, npts
                    pj = vec3_create(pts_flat(3 * (j - 1) + 1), &
                                     pts_flat(3 * (j - 1) + 2), &
                                     pts_flat(3 * (j - 1) + 3))
                    dmin = min(dmin, vec3_norm(vec3_sub(v, pj)))
                end do
                call assert_real_close(radius, dmin, 1.0e-5_dp, &
                    label//' ring vertex is at distance radius from its path point')
            end do
        end do
    end subroutine check_mesh

end program test_geo_tube
