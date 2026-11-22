! geo_lathe.f90 -- lathe (surface of revolution) mesh builder.
!
! Revolves a 2D profile around the Y axis.  pts_flat is a flat array of
! real(dp) of length 2*npts holding (x, y) pairs in profile order
! (bottom -> top typical), where x is the radius (>= 0) and y is the
! height.  Negative radii are clamped to 0.
!
! Vertices: for profile point i and step j (theta = 2*PI*(j-1)/seg),
!   (x*cos(theta), y, x*sin(theta)).
!
! Triangle count is EXACTLY (npts-1)*seg*2, where seg = max(3, segments):
! every quad between consecutive profile points is emitted as 2
! triangles, with no exceptions.  In particular, quads touching a
! profile point with radius 0 still emit both triangles even though
! they are degenerate (zero area, zero normal via
! compute_triangle_normal / vec3_normalize).  Count stability is the
! contract: callers can rely on the count regardless of the profile.
!
! If npts < 2 the result is an empty mesh (num_triangles == 0).
module geo_lathe_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: create_lathe

contains

    subroutine create_lathe(m, segments, pts_flat, npts)
        type(Mesh), intent(inout) :: m
        integer, intent(in) :: segments
        integer, intent(in) :: npts
        real(dp), intent(in) :: pts_flat(2 * npts)
        integer :: seg, i, j, j2, idx
        real(dp) :: r_lo, r_hi, y_lo, y_hi
        type(vec3) :: a, b, c, d

        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = 0

        if (npts < 2) return

        seg = max(3, segments)
        m%num_triangles = (npts - 1) * seg * 2
        allocate(m%triangles(m%num_triangles))
        idx = 0
        do i = 1, npts - 1
            r_lo = max(0.0_dp, pts_flat(2 * i - 1))
            y_lo = pts_flat(2 * i)
            r_hi = max(0.0_dp, pts_flat(2 * i + 1))
            y_hi = pts_flat(2 * i + 2)
            do j = 1, seg
                j2 = mod(j, seg) + 1
                a = lathe_point(r_lo, y_lo, seg, j)
                b = lathe_point(r_lo, y_lo, seg, j2)
                c = lathe_point(r_hi, y_hi, seg, j2)
                d = lathe_point(r_hi, y_hi, seg, j)
                ! Same winding pattern as create_cylinder's side quads.
                idx = idx + 1
                m%triangles(idx)%v = [a, c, b]
                m%triangles(idx)%normal = compute_triangle_normal( &
                    m%triangles(idx)%v(1), m%triangles(idx)%v(2), &
                    m%triangles(idx)%v(3))
                m%triangles(idx)%color = [255, 255, 255]
                idx = idx + 1
                m%triangles(idx)%v = [a, d, c]
                m%triangles(idx)%normal = compute_triangle_normal( &
                    m%triangles(idx)%v(1), m%triangles(idx)%v(2), &
                    m%triangles(idx)%v(3))
                m%triangles(idx)%color = [255, 255, 255]
            end do
        end do
        m%num_triangles = idx
    end subroutine create_lathe

    pure function lathe_point(radius, y, seg, j) result(p)
        real(dp), intent(in) :: radius, y
        integer, intent(in) :: seg, j
        type(vec3) :: p
        real(dp) :: theta
        theta = 2.0_dp * PI * real(j - 1, dp) / real(seg, dp)
        p = vec3_create(radius * cos(theta), y, radius * sin(theta))
    end function lathe_point

end module geo_lathe_3d
