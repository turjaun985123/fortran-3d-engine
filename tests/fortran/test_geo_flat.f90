program test_geo_flat
    use math_3d
    use mesh_3d
    use geo_flat_3d
    use test_assert
    implicit none

    type(Mesh) :: msh
    real(dp) :: r

    ! ---- circle: seg 16 -> 32 tris (2*seg, double-sided fan) ----
    call create_circle(msh, 2.0_dp, 16)
    call assert_int_eq(32, msh%num_triangles, 'circle seg=16 has 32 triangles')
    call assert_true(allocated(msh%triangles), 'circle result is allocated')
    call check_flat_normals(msh, 'circle')
    call check_no_degenerate(msh, 'circle')
    call check_circle_radii(msh, 2.0_dp, 'circle')
    call check_both_sides(msh, 'circle')

    ! ---- circle: seg clamped to >=3 -> seg 2 gives 6 tris ----
    call create_circle(msh, 1.0_dp, 2)
    call assert_int_eq(6, msh%num_triangles, 'circle seg=2 clamped has 6 triangles')

    ! ---- circle: radius<=0 guarded to 1.0 ----
    call create_circle(msh, 0.0_dp, 8)
    call assert_int_eq(16, msh%num_triangles, 'circle radius=0 seg=8 has 16 triangles')
    call check_circle_radii(msh, 1.0_dp, 'circle radius guard')

    ! ---- ring: seg 16 -> 64 tris (4*seg, double-sided quad strip) ----
    call create_ring(msh, 1.0_dp, 3.0_dp, 16)
    call assert_int_eq(64, msh%num_triangles, 'ring seg=16 has 64 triangles')
    call assert_true(allocated(msh%triangles), 'ring result is allocated')
    call check_flat_normals(msh, 'ring')
    call check_no_degenerate(msh, 'ring')
    call check_ring_radii(msh, 1.0_dp, 3.0_dp, 'ring')
    call check_both_sides(msh, 'ring')

    ! ---- ring: seg clamped to >=3 -> seg 1 gives 12 tris ----
    call create_ring(msh, 0.5_dp, 1.0_dp, 1)
    call assert_int_eq(12, msh%num_triangles, 'ring seg=1 clamped has 12 triangles')

    ! ---- ring: outer<=0 guarded to 1.0, inner clamped to outer*0.99 ----
    call create_ring(msh, 5.0_dp, 0.0_dp, 8)
    call assert_int_eq(32, msh%num_triangles, 'ring outer=0 seg=8 has 32 triangles')
    call check_ring_radii(msh, 0.99_dp, 1.0_dp, 'ring outer/inner guard')
    call check_no_degenerate(msh, 'ring outer/inner guard')

    ! ---- ring: negative inner clamped to 0 is not used for geometry ----
    ! (vertices then lie at 0 or outer; count formula still holds)
    call create_ring(msh, -1.0_dp, 2.0_dp, 8)
    call assert_int_eq(32, msh%num_triangles, 'ring inner<0 seg=8 has 32 triangles')
    r = vec3_norm(msh%triangles(1)%v(2))
    call assert_true(abs(r - 2.0_dp) <= 1.0e-9_dp .or. r <= 1.0e-9_dp, &
        'ring inner<0 tri 1 vertex 2 at centre or outer radius')

    call free_mesh(msh)
    call test_summary()

contains

    ! All normals unit length and exactly +/-Y (x,z ~ 0, |y| ~ 1),
    ! and all vertices in the XZ plane (y == 0).
    subroutine check_flat_normals(m, builder)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: builder
        logical :: ok_norm, ok_unit, ok_plane
        integer :: i, k
        ok_norm = .true.; ok_unit = .true.; ok_plane = .true.
        do i = 1, m%num_triangles
            if (abs(vec3_norm(m%triangles(i)%normal) - 1.0_dp) > 1.0e-6_dp) ok_unit = .false.
            if (abs(m%triangles(i)%normal%x) > 1.0e-6_dp) ok_norm = .false.
            if (abs(m%triangles(i)%normal%z) > 1.0e-6_dp) ok_norm = .false.
            if (abs(abs(m%triangles(i)%normal%y) - 1.0_dp) > 1.0e-6_dp) ok_norm = .false.
            do k = 1, 3
                if (abs(m%triangles(i)%v(k)%y) > 1.0e-12_dp) ok_plane = .false.
            end do
        end do
        call assert_true(ok_unit, builder//' all normals unit length')
        call assert_true(ok_norm, builder//' all normals are +/-Y')
        call assert_true(ok_plane, builder//' all vertices in XZ plane (y=0)')
    end subroutine check_flat_normals

    ! Double-sided: at least one +Y and one -Y normal.
    subroutine check_both_sides(m, builder)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: builder
        logical :: has_pos, has_neg
        integer :: i
        has_pos = .false.; has_neg = .false.
        do i = 1, m%num_triangles
            if (m%triangles(i)%normal%y > 0.5_dp) has_pos = .true.
            if (m%triangles(i)%normal%y < -0.5_dp) has_neg = .true.
        end do
        call assert_true(has_pos, builder//' has +Y facing triangles')
        call assert_true(has_neg, builder//' has -Y facing triangles (double-sided)')
    end subroutine check_both_sides

    ! No degenerate triangles: cross-product magnitude > tol.
    subroutine check_no_degenerate(m, builder)
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: builder
        logical :: ok
        integer :: i
        type(vec3) :: e1, e2, cr
        ok = .true.
        do i = 1, m%num_triangles
            e1 = vec3_sub(m%triangles(i)%v(2), m%triangles(i)%v(1))
            e2 = vec3_sub(m%triangles(i)%v(3), m%triangles(i)%v(1))
            cr = vec3_cross(e1, e2)
            if (vec3_norm(cr) <= 1.0e-12_dp) ok = .false.
        end do
        call assert_true(ok, builder//' has no degenerate triangles')
    end subroutine check_no_degenerate

    ! Circle: every vertex is the centre (|v|~0) or on the rim (|v|~radius),
    ! measured in the XZ plane.
    subroutine check_circle_radii(m, radius, builder)
        type(Mesh), intent(in) :: m
        real(dp), intent(in) :: radius
        character(len=*), intent(in) :: builder
        logical :: ok
        integer :: i, k
        real(dp) :: rad
        ok = .true.
        do i = 1, m%num_triangles
            do k = 1, 3
                rad = sqrt(m%triangles(i)%v(k)%x**2 + m%triangles(i)%v(k)%z**2)
                if (.not. (rad <= 1.0e-9_dp .or. abs(rad - radius) <= 1.0e-9_dp)) ok = .false.
            end do
        end do
        call assert_true(ok, builder//' vertices at centre or rim radius')
    end subroutine check_circle_radii

    ! Ring: every vertex lies at inner or outer radius in the XZ plane.
    subroutine check_ring_radii(m, inner, outer, builder)
        type(Mesh), intent(in) :: m
        real(dp), intent(in) :: inner, outer
        character(len=*), intent(in) :: builder
        logical :: ok
        integer :: i, k
        real(dp) :: rad
        ok = .true.
        do i = 1, m%num_triangles
            do k = 1, 3
                rad = sqrt(m%triangles(i)%v(k)%x**2 + m%triangles(i)%v(k)%z**2)
                if (.not. (abs(rad - inner) <= 1.0e-9_dp .or. &
                            abs(rad - outer) <= 1.0e-9_dp)) ok = .false.
            end do
        end do
        call assert_true(ok, builder//' vertices at inner or outer radius')
    end subroutine check_ring_radii

end program test_geo_flat
