! geo_poly.f90 -- regular (Platonic) polyhedra centred at the origin.
!
!   radius = circumradius: every vertex lies at distance radius from
!   the origin.  radius <= 0 is guarded to 1.0.
! Triangle counts: tetrahedron 4, octahedron 8, icosahedron 20,
! dodecahedron 36 (12 pentagonal faces x 3 fan triangles).
! All face windings are outward: dot(face normal, face centroid) > 0.
! Per-triangle normals come from compute_triangle_normal and every
! triangle is coloured white [255,255,255], following mesh.f90.
module geo_poly_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: create_tetrahedron, create_octahedron, &
              create_icosahedron, create_dodecahedron

contains

    ! Shared assembly: deallocate-then-allocate, white, winding normals.
    subroutine assemble_poly(m, p, faces, num_faces)
        type(Mesh), intent(inout) :: m
        type(vec3), intent(in) :: p(:)
        integer, intent(in) :: faces(:, :), num_faces
        integer :: i

        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = num_faces
        allocate(m%triangles(num_faces))
        do i = 1, num_faces
            m%triangles(i)%v = [p(faces(1, i)), p(faces(2, i)), p(faces(3, i))]
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), m%triangles(i)%v(3))
            m%triangles(i)%vn = [m%triangles(i)%normal, m%triangles(i)%normal, m%triangles(i)%normal]
            m%triangles(i)%color = [255, 255, 255]
        end do
    end subroutine assemble_poly

    pure function guarded_radius(radius) result(r)
        real(dp), intent(in) :: radius
        real(dp) :: r
        r = radius
        if (r <= 0.0_dp) r = 1.0_dp
    end function guarded_radius

    ! Vertices (+-1,+-1,+-1) with an even number of minus signs,
    ! scaled by radius/sqrt(3).  4 triangular faces.
    subroutine create_tetrahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(vec3) :: p(4)
        integer :: faces(3, 4)
        real(dp) :: s

        s = guarded_radius(radius) / sqrt(3.0_dp)
        p(1) = vec3_create( s,  s,  s)
        p(2) = vec3_create( s, -s, -s)
        p(3) = vec3_create(-s,  s, -s)
        p(4) = vec3_create(-s, -s,  s)

        faces = reshape([ &
            1, 2, 3,   &
            1, 4, 2,   &
            1, 3, 4,   &
            2, 4, 3], [3, 4])
        call assemble_poly(m, p, faces, 4)
    end subroutine create_tetrahedron

    ! Vertices on the coordinate axes at distance radius.
    ! 8 triangular faces.
    subroutine create_octahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(vec3) :: p(6)
        integer :: faces(3, 8)
        real(dp) :: r

        r = guarded_radius(radius)
        p(1) = vec3_create( r, 0.0_dp, 0.0_dp)
        p(2) = vec3_create(-r, 0.0_dp, 0.0_dp)
        p(3) = vec3_create(0.0_dp,  r, 0.0_dp)
        p(4) = vec3_create(0.0_dp, -r, 0.0_dp)
        p(5) = vec3_create(0.0_dp, 0.0_dp,  r)
        p(6) = vec3_create(0.0_dp, 0.0_dp, -r)

        faces = reshape([ &
            1, 3, 5,   &
            3, 2, 5,   &
            2, 4, 5,   &
            4, 1, 5,   &
            3, 1, 6,   &
            2, 3, 6,   &
            4, 2, 6,   &
            1, 4, 6], [3, 8])
        call assemble_poly(m, p, faces, 8)
    end subroutine create_octahedron

    ! Vertices (0,+-1,+-phi), (+-1,+-phi,0), (+-phi,0,+-1) with
    ! phi = (1+sqrt(5))/2, scaled by radius/sqrt(1+phi^2).
    ! 20 triangular faces.
    subroutine create_icosahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(vec3) :: p(12)
        integer :: faces(3, 20)
        real(dp) :: phi, s

        phi = (1.0_dp + sqrt(5.0_dp)) * 0.5_dp
        s = guarded_radius(radius) / sqrt(1.0_dp + phi * phi)
        p(1)  = vec3_create(-s,  s * phi, 0.0_dp)
        p(2)  = vec3_create( s,  s * phi, 0.0_dp)
        p(3)  = vec3_create(-s, -s * phi, 0.0_dp)
        p(4)  = vec3_create( s, -s * phi, 0.0_dp)
        p(5)  = vec3_create(0.0_dp, -s,  s * phi)
        p(6)  = vec3_create(0.0_dp,  s,  s * phi)
        p(7)  = vec3_create(0.0_dp, -s, -s * phi)
        p(8)  = vec3_create(0.0_dp,  s, -s * phi)
        p(9)  = vec3_create( s * phi, 0.0_dp, -s)
        p(10) = vec3_create( s * phi, 0.0_dp,  s)
        p(11) = vec3_create(-s * phi, 0.0_dp, -s)
        p(12) = vec3_create(-s * phi, 0.0_dp,  s)

        faces = reshape([ &
            1, 12, 6,    &
            1, 6, 2,     &
            1, 2, 8,     &
            1, 8, 11,    &
            1, 11, 12,   &
            2, 6, 10,    &
            6, 12, 5,    &
            12, 11, 3,   &
            11, 8, 7,    &
            8, 2, 9,     &
            4, 10, 5,    &
            4, 5, 3,     &
            4, 3, 7,     &
            4, 7, 9,     &
            4, 9, 10,    &
            5, 10, 6,    &
            3, 5, 12,    &
            7, 3, 11,    &
            9, 7, 8,     &
            10, 9, 2], [3, 20])
        call assemble_poly(m, p, faces, 20)
    end subroutine create_icosahedron

    ! Vertices (+-1,+-1,+-1), (0,+-1/phi,+-phi), (+-1/phi,+-phi,0),
    ! (+-phi,0,+-1/phi), scaled by radius/sqrt(3).
    ! 12 pentagonal faces, each fanned into 3 triangles -> 36.
    subroutine create_dodecahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(vec3) :: p(20)
        integer :: pent(5, 12), faces(3, 36)
        real(dp) :: phi, inv_phi, s
        integer :: i, t, idx

        phi = (1.0_dp + sqrt(5.0_dp)) * 0.5_dp
        inv_phi = 1.0_dp / phi
        s = guarded_radius(radius) / sqrt(3.0_dp)
        p(1)  = vec3_create( s,  s,  s)
        p(2)  = vec3_create( s,  s, -s)
        p(3)  = vec3_create( s, -s,  s)
        p(4)  = vec3_create( s, -s, -s)
        p(5)  = vec3_create(-s,  s,  s)
        p(6)  = vec3_create(-s,  s, -s)
        p(7)  = vec3_create(-s, -s,  s)
        p(8)  = vec3_create(-s, -s, -s)
        p(9)  = vec3_create(0.0_dp,  s * inv_phi,  s * phi)
        p(10) = vec3_create(0.0_dp,  s * inv_phi, -s * phi)
        p(11) = vec3_create(0.0_dp, -s * inv_phi,  s * phi)
        p(12) = vec3_create(0.0_dp, -s * inv_phi, -s * phi)
        p(13) = vec3_create( s * inv_phi,  s * phi, 0.0_dp)
        p(14) = vec3_create( s * inv_phi, -s * phi, 0.0_dp)
        p(15) = vec3_create(-s * inv_phi,  s * phi, 0.0_dp)
        p(16) = vec3_create(-s * inv_phi, -s * phi, 0.0_dp)
        p(17) = vec3_create( s * phi, 0.0_dp,  s * inv_phi)
        p(18) = vec3_create( s * phi, 0.0_dp, -s * inv_phi)
        p(19) = vec3_create(-s * phi, 0.0_dp,  s * inv_phi)
        p(20) = vec3_create(-s * phi, 0.0_dp, -s * inv_phi)

        ! Pentagons in outward (counter-clockwise seen from outside)
        ! cyclic order.
        pent = reshape([ &
            6, 10, 12, 8, 20,    &
            2, 10, 6, 15, 13,    &
            5, 15, 6, 20, 19,    &
            5, 19, 7, 11, 9,     &
            3, 11, 7, 16, 14,    &
            7, 19, 20, 8, 16,    &
            3, 14, 4, 18, 17,    &
            2, 18, 4, 12, 10,    &
            4, 14, 16, 8, 12,    &
            1, 17, 18, 2, 13,    &
            1, 9, 11, 3, 17,     &
            1, 13, 15, 5, 9], [5, 12])

        idx = 0
        do i = 1, 12
            do t = 1, 3
                idx = idx + 1
                faces(1, idx) = pent(1, i)
                faces(2, idx) = pent(t + 1, i)
                faces(3, idx) = pent(t + 2, i)
            end do
        end do
        call assemble_poly(m, p, faces, 36)
    end subroutine create_dodecahedron

end module geo_poly_3d
