! geo_poly.f90 -- regular (Platonic) polyhedra centred at the origin.
!
!   radius = circumradius: every vertex lies at distance radius from
!   the origin.  radius <= 0 is guarded to 1.0.
! Triangle counts: tetrahedron 4, octahedron 8, icosahedron 20,
! dodecahedron 36 (12 pentagonal faces x 3 fan triangles).
! All face windings are outward: dot(face normal, face centroid) > 0.
! Per-triangle normals come from compute_triangle_normal and every
! triangle is coloured white [255,255,255], following mesh.f90.
!
! Phase 1 indexed form: the solids are flat-shaded, so each face
! splits its vertices (per-face normals + per-face planar UVs):
!   tetrahedron  4 faces x 3 = 12 verts / 4 tris
!   octahedron   8 faces x 3 = 24 verts / 8 tris
!   icosahedron 20 faces x 3 = 60 verts / 20 tris
!   dodecahedron 36 tris x 3 = 108 verts / 36 tris
! UV: per-face planar projection (mesh_data_face_uv, dominant axis
! of the face normal, extents (2r, 2r, 2r)) -- the same contract
! prim_uv applies to cube/pyramid vertices.
module geo_poly_3d
    use math_3d
    use mesh_3d
    use mesh_data_3d
    implicit none
    private
    public :: create_tetrahedron, create_octahedron, &
              create_icosahedron, create_dodecahedron, &
              build_tetrahedron_data, build_octahedron_data, &
              build_icosahedron_data, build_dodecahedron_data

contains

    ! Shared indexed assembly: one split vertex triple per face.
    subroutine assemble_poly_data(md, p, faces, num_faces, radius)
        type(mesh_data), intent(out) :: md
        type(vec3), intent(in) :: p(:)
        integer, intent(in) :: faces(:, :), num_faces
        real(dp), intent(in) :: radius
        integer :: i, k, ax, sg
        type(vec3) :: fn, fv(3)
        real(dp) :: ext(3), fc

        ext = [2.0_dp * radius, 2.0_dp * radius, 2.0_dp * radius]
        call mesh_data_alloc(md, 3 * num_faces, num_faces)
        do i = 1, num_faces
            fn = compute_triangle_normal(p(faces(1, i)), &
                                         p(faces(2, i)), &
                                         p(faces(3, i)))
            if (abs(fn%x) >= abs(fn%y) .and. &
                abs(fn%x) >= abs(fn%z)) then
                ax = 1
                fc = fn%x
            else if (abs(fn%y) >= abs(fn%z)) then
                ax = 2
                fc = fn%y
            else
                ax = 3
                fc = fn%z
            end if
            sg = 1
            if (fc < 0.0_dp) sg = -1
            do k = 1, 3
                fv(k) = p(faces(k, i))
                call mesh_data_put_vertex(md, (i - 1) * 3 + k, fv(k), &
                    fn, mesh_data_face_uv(fv(k), ext, ax, sg))
            end do
            call mesh_data_put_tri(md, i, (i - 1) * 3 + 1, &
                (i - 1) * 3 + 2, (i - 1) * 3 + 3, fn, .false., &
                [255, 255, 255])
        end do
        call mesh_data_finalize(md)
    end subroutine assemble_poly_data

    pure function guarded_radius(radius) result(r)
        real(dp), intent(in) :: radius
        real(dp) :: r
        r = radius
        if (r <= 0.0_dp) r = 1.0_dp
    end function guarded_radius

    ! Vertices (+-1,+-1,+-1) with an even number of minus signs,
    ! scaled by radius/sqrt(3).  4 triangular faces.
    subroutine build_tetrahedron_data(md, radius)
        type(mesh_data), intent(out) :: md
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
        call assemble_poly_data(md, p, faces, 4, guarded_radius(radius))
    end subroutine build_tetrahedron_data

    subroutine create_tetrahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(mesh_data) :: md
        call build_tetrahedron_data(md, radius)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_tetrahedron

    ! Vertices on the coordinate axes at distance radius.
    ! 8 triangular faces.
    subroutine build_octahedron_data(md, radius)
        type(mesh_data), intent(out) :: md
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
        call assemble_poly_data(md, p, faces, 8, r)
    end subroutine build_octahedron_data

    subroutine create_octahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(mesh_data) :: md
        call build_octahedron_data(md, radius)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_octahedron

    ! Vertices (0,+-1,+-phi), (+-1,+-phi,0), (+-phi,0,+-1) with
    ! phi = (1+sqrt(5))/2, scaled by radius/sqrt(1+phi^2).
    ! 20 triangular faces.
    subroutine build_icosahedron_data(md, radius)
        type(mesh_data), intent(out) :: md
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
        call assemble_poly_data(md, p, faces, 20, guarded_radius(radius))
    end subroutine build_icosahedron_data

    subroutine create_icosahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(mesh_data) :: md
        call build_icosahedron_data(md, radius)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_icosahedron

    ! Vertices (+-1,+-1,+-1), (0,+-1/phi,+-phi), (+-1/phi,+-phi,0),
    ! (+-phi,0,+-1/phi), scaled by radius/sqrt(3).
    ! 12 pentagonal faces, each fanned into 3 triangles -> 36.
    subroutine build_dodecahedron_data(md, radius)
        type(mesh_data), intent(out) :: md
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
        call assemble_poly_data(md, p, faces, 36, guarded_radius(radius))
    end subroutine build_dodecahedron_data

    subroutine create_dodecahedron(m, radius)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        type(mesh_data) :: md
        call build_dodecahedron_data(md, radius)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_dodecahedron

end module geo_poly_3d
