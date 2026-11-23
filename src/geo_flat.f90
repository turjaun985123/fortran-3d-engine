module geo_flat_3d
    use math_3d
    use mesh_3d
    use mesh_data_3d
    implicit none
    private
    public :: create_circle, create_ring, build_circle_data, build_ring_data

contains

    ! Flat disc in the XZ plane (y=0), facing +Y, DOUBLE-SIDED like
    ! create_plane: a front fan (+Y) plus a reversed back fan (-Y).
    ! Indexed (Phase 1): front centre + ring and back centre + ring
    ! are split (opposite normals), ring verts are shared by all fan
    ! triangles of their side (planar UVs need no seam duplicate).
    !   n_verts = 2*(seg+1), n_tris = 2*seg, seg = max(3, segments).
    ! UV: planar, u = x/(2r)+0.5, v = z/(2r)+0.5, centre (0.5, 0.5).
    subroutine build_circle_data(md, radius, segments)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        integer :: seg, i, i2, t, bc
        real(dp) :: r, theta, theta2
        type(vec3) :: cen, p1, p2, up, dn

        r = radius
        if (r <= 0.0_dp) r = 1.0_dp
        seg = max(3, segments)
        cen = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        dn = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
        call mesh_data_alloc(md, 2 * (seg + 1), 2 * seg)
        call mesh_data_put_vertex(md, 1, cen, up, [0.5_dp, 0.5_dp])
        bc = seg + 2
        call mesh_data_put_vertex(md, bc, cen, dn, [0.5_dp, 0.5_dp])
        do i = 1, seg
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            p1 = vec3_create(r * cos(theta), 0.0_dp, r * sin(theta))
            call mesh_data_put_vertex(md, 1 + i, p1, up, &
                [p1%x / (2.0_dp * r) + 0.5_dp, &
                 p1%z / (2.0_dp * r) + 0.5_dp])
            call mesh_data_put_vertex(md, bc + i, p1, dn, &
                [p1%x / (2.0_dp * r) + 0.5_dp, &
                 p1%z / (2.0_dp * r) + 0.5_dp])
        end do
        t = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(i2 - 1, dp) / real(seg, dp)
            p1 = vec3_create(r * cos(theta), 0.0_dp, r * sin(theta))
            p2 = vec3_create(r * cos(theta2), 0.0_dp, r * sin(theta2))
            t = t + 1
            call mesh_data_put_tri(md, t, 1, 1 + i2, 1 + i, &
                compute_triangle_normal(cen, p2, p1), .false., &
                [255, 255, 255])
            t = t + 1
            call mesh_data_put_tri(md, t, bc, bc + i, bc + i2, &
                compute_triangle_normal(cen, p1, p2), .false., &
                [255, 255, 255])
        end do
        call mesh_data_finalize(md)
    end subroutine build_circle_data

    subroutine create_circle(m, radius, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        type(mesh_data) :: md
        call build_circle_data(md, radius, segments)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_circle

    ! Flat annulus in the XZ plane (y=0), DOUBLE-SIDED: front quad
    ! strip (+Y) plus reversed back strip (-Y).  Indexed (Phase 1):
    ! inner + outer rings per side, shared along the strip.
    !   n_verts = 4*seg, n_tris = 4*seg, seg = max(3, segments).
    ! Guards: outer <= 0 -> 1.0; inner clamped to [0, outer*0.99].
    ! UV: planar over the outer disc, u = x/(2*outer)+0.5, v likewise.
    subroutine build_ring_data(md, inner, outer, segments)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: inner, outer
        integer, intent(in) :: segments
        integer :: seg, i, i2, t
        real(dp) :: ri, ro, theta, theta2
        type(vec3) :: in1, in2, out1, out2, up, dn
        integer :: fi, fo, bi, bo

        ro = outer
        if (ro <= 0.0_dp) ro = 1.0_dp
        ri = inner
        if (ri < 0.0_dp) ri = 0.0_dp
        if (ri > ro * 0.99_dp) ri = ro * 0.99_dp
        seg = max(3, segments)
        up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        dn = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
        call mesh_data_alloc(md, 4 * seg, 4 * seg)
        do i = 1, seg
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            in1 = vec3_create(ri * cos(theta), 0.0_dp, ri * sin(theta))
            out1 = vec3_create(ro * cos(theta), 0.0_dp, ro * sin(theta))
            call mesh_data_put_vertex(md, i, in1, up, &
                [in1%x / (2.0_dp * ro) + 0.5_dp, &
                 in1%z / (2.0_dp * ro) + 0.5_dp])
            call mesh_data_put_vertex(md, seg + i, out1, up, &
                [out1%x / (2.0_dp * ro) + 0.5_dp, &
                 out1%z / (2.0_dp * ro) + 0.5_dp])
            call mesh_data_put_vertex(md, 2 * seg + i, in1, dn, &
                [in1%x / (2.0_dp * ro) + 0.5_dp, &
                 in1%z / (2.0_dp * ro) + 0.5_dp])
            call mesh_data_put_vertex(md, 3 * seg + i, out1, dn, &
                [out1%x / (2.0_dp * ro) + 0.5_dp, &
                 out1%z / (2.0_dp * ro) + 0.5_dp])
        end do
        t = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(i2 - 1, dp) / real(seg, dp)
            in1 = vec3_create(ri * cos(theta), 0.0_dp, ri * sin(theta))
            in2 = vec3_create(ri * cos(theta2), 0.0_dp, ri * sin(theta2))
            out1 = vec3_create(ro * cos(theta), 0.0_dp, ro * sin(theta))
            out2 = vec3_create(ro * cos(theta2), 0.0_dp, ro * sin(theta2))
            fi = i
            fo = seg + i
            bi = 2 * seg + i
            bo = 3 * seg + i
            t = t + 1
            call mesh_data_put_tri(md, t, fi, seg + i2, fo, &
                compute_triangle_normal(in1, out2, out1), .false., &
                [255, 255, 255])
            t = t + 1
            call mesh_data_put_tri(md, t, fi, i2, seg + i2, &
                compute_triangle_normal(in1, in2, out2), .false., &
                [255, 255, 255])
            t = t + 1
            call mesh_data_put_tri(md, t, bi, bo, 3 * seg + i2, &
                compute_triangle_normal(in1, out1, out2), .false., &
                [255, 255, 255])
            t = t + 1
            call mesh_data_put_tri(md, t, bi, 3 * seg + i2, 2 * seg + i2, &
                compute_triangle_normal(in1, out2, in2), .false., &
                [255, 255, 255])
        end do
        call mesh_data_finalize(md)
    end subroutine build_ring_data

    subroutine create_ring(m, inner, outer, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: inner, outer
        integer, intent(in) :: segments
        type(mesh_data) :: md
        call build_ring_data(md, inner, outer, segments)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_ring

end module geo_flat_3d
