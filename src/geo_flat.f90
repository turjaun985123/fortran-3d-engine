module geo_flat_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: create_circle, create_ring

contains

    ! Flat disc in the XZ plane (y=0), centre at the origin, facing +Y,
    ! DOUBLE-SIDED like create_plane: a front fan facing +Y plus a
    ! reversed-winding back fan facing -Y, so the winding cull keeps
    ! one fan from each side.
    ! Tri count = 2 * max(3, segments) exactly.
    ! Normals come from each triangle's winding via
    ! compute_triangle_normal (+Y for the front fan, -Y for the back).
    subroutine create_circle(m, radius, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        integer :: seg, i, i2, idx
        real(dp) :: r, theta, theta2
        type(vec3) :: cen, p1, p2

        if (allocated(m%triangles)) deallocate(m%triangles)
        r = radius
        if (r <= 0.0_dp) r = 1.0_dp
        seg = max(3, segments)
        m%num_triangles = 2 * seg
        allocate(m%triangles(m%num_triangles))
        cen = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        idx = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(i2 - 1, dp) / real(seg, dp)
            p1 = vec3_create(r * cos(theta), 0.0_dp, r * sin(theta))
            p2 = vec3_create(r * cos(theta2), 0.0_dp, r * sin(theta2))
            ! Front fan (+Y): [centre, next, current]
            idx = idx + 1
            m%triangles(idx)%v = [cen, p2, p1]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            m%triangles(idx)%color = [255, 255, 255]
            ! Back fan (-Y): reversed winding
            idx = idx + 1
            m%triangles(idx)%v = [cen, p1, p2]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            m%triangles(idx)%color = [255, 255, 255]
        end do
        m%num_triangles = idx
    end subroutine create_circle

    ! Flat annulus in the XZ plane (y=0), centre at the origin,
    ! DOUBLE-SIDED like create_plane: a front quad strip facing +Y
    ! plus a reversed-winding back strip facing -Y.
    ! Tri count = 4 * max(3, segments) exactly
    ! (quad strip 2 tris x 2 sides per segment).
    ! Guards: outer <= 0 -> 1.0; inner clamped to [0, outer*0.99].
    ! Normals come from each triangle's winding via
    ! compute_triangle_normal (+Y front, -Y back).
    subroutine create_ring(m, inner, outer, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: inner, outer
        integer, intent(in) :: segments
        integer :: seg, i, i2, idx
        real(dp) :: ri, ro, theta, theta2
        type(vec3) :: in1, in2, out1, out2

        if (allocated(m%triangles)) deallocate(m%triangles)
        ro = outer
        if (ro <= 0.0_dp) ro = 1.0_dp
        ri = inner
        if (ri < 0.0_dp) ri = 0.0_dp
        if (ri > ro * 0.99_dp) ri = ro * 0.99_dp
        seg = max(3, segments)
        m%num_triangles = 4 * seg
        allocate(m%triangles(m%num_triangles))
        idx = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            theta2 = 2.0_dp * PI * real(i2 - 1, dp) / real(seg, dp)
            in1 = vec3_create(ri * cos(theta), 0.0_dp, ri * sin(theta))
            in2 = vec3_create(ri * cos(theta2), 0.0_dp, ri * sin(theta2))
            out1 = vec3_create(ro * cos(theta), 0.0_dp, ro * sin(theta))
            out2 = vec3_create(ro * cos(theta2), 0.0_dp, ro * sin(theta2))
            ! Front quad (+Y)
            idx = idx + 1
            m%triangles(idx)%v = [in1, out2, out1]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            m%triangles(idx)%color = [255, 255, 255]
            idx = idx + 1
            m%triangles(idx)%v = [in1, in2, out2]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            m%triangles(idx)%color = [255, 255, 255]
            ! Back quad (-Y): reversed winding
            idx = idx + 1
            m%triangles(idx)%v = [in1, out1, out2]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            m%triangles(idx)%color = [255, 255, 255]
            idx = idx + 1
            m%triangles(idx)%v = [in1, out2, in2]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            m%triangles(idx)%color = [255, 255, 255]
        end do
        m%num_triangles = idx
    end subroutine create_ring

end module geo_flat_3d
