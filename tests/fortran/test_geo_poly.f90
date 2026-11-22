program test_geo_poly
    use math_3d
    use mesh_3d
    use geo_poly_3d
    use test_assert
    implicit none

    type(Mesh) :: msh

    ! ---- tetrahedron: 4 tris, radius 2.0, uniform edges ----
    call create_tetrahedron(msh, 2.0_dp)
    call assert_int_eq(4, msh%num_triangles, 'tetrahedron has 4 triangles')
    call check_solid(msh, 2.0_dp, 'tetrahedron', .true.)

    ! ---- octahedron: 8 tris, radius 1.5, uniform edges ----
    call create_octahedron(msh, 1.5_dp)
    call assert_int_eq(8, msh%num_triangles, 'octahedron has 8 triangles')
    call check_solid(msh, 1.5_dp, 'octahedron', .true.)

    ! ---- icosahedron: 20 tris, radius 2.5, uniform edges ----
    call create_icosahedron(msh, 2.5_dp)
    call assert_int_eq(20, msh%num_triangles, 'icosahedron has 20 triangles')
    call check_solid(msh, 2.5_dp, 'icosahedron', .true.)

    ! ---- dodecahedron: 36 tris (12 pentagons x 3 fan), radius 1.25 ----
    ! No edge-uniformity check: fan triangles contain pentagon diagonals.
    call create_dodecahedron(msh, 1.25_dp)
    call assert_int_eq(36, msh%num_triangles, 'dodecahedron has 36 triangles')
    call check_solid(msh, 1.25_dp, 'dodecahedron', .false.)

    ! ---- radius guard: radius <= 0 falls back to 1.0 ----
    call create_tetrahedron(msh, 0.0_dp)
    call assert_int_eq(4, msh%num_triangles, 'tetrahedron radius=0 has 4 triangles')
    call assert_real_close(1.0_dp, vec3_norm(msh%triangles(1)%v(1)), &
        1.0e-7_dp, 'tetrahedron radius=0 guard puts vertex at radius 1')
    call create_octahedron(msh, -3.0_dp)
    call assert_real_close(1.0_dp, vec3_norm(msh%triangles(1)%v(1)), &
        1.0e-7_dp, 'octahedron radius<0 guard puts vertex at radius 1')

    call free_mesh(msh)
    call test_summary()

contains

    subroutine check_solid(m, radius, name, uniform_edges)
        type(Mesh), intent(in) :: m
        real(dp), intent(in) :: radius
        character(len=*), intent(in) :: name
        logical, intent(in) :: uniform_edges
        integer :: i, k
        type(vec3) :: centroid
        real(dp) :: edge_len, edge_min, edge_max

        edge_min = huge(1.0_dp)
        edge_max = 0.0_dp
        do i = 1, m%num_triangles
            do k = 1, 3
                call assert_real_close(radius, vec3_norm(m%triangles(i)%v(k)), &
                    1.0e-7_dp, name//' vertex lies at circumradius')
            end do
            centroid = vec3_scale(vec3_add(vec3_add(m%triangles(i)%v(1), &
                m%triangles(i)%v(2)), m%triangles(i)%v(3)), 1.0_dp / 3.0_dp)
            call assert_true(vec3_dot(m%triangles(i)%normal, centroid) > 0.0_dp, &
                name//' face normal points outward')
            call assert_real_close(1.0_dp, vec3_norm(m%triangles(i)%normal), &
                1.0e-6_dp, name//' face normal is unit length')
            if (uniform_edges) then
                do k = 1, 3
                    edge_len = vec3_norm(vec3_sub(m%triangles(i)%v(mod(k, 3) + 1), &
                                                  m%triangles(i)%v(k)))
                    edge_min = min(edge_min, edge_len)
                    edge_max = max(edge_max, edge_len)
                end do
            end if
        end do
        if (uniform_edges) then
            call assert_true(edge_max - edge_min <= 1.0e-4_dp, &
                name//' all edges have equal length')
        end if
    end subroutine check_solid

end program test_geo_poly
