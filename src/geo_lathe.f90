! geo_lathe.f90 -- lathe (surface of revolution) mesh builder.
!
! Revolves a 2D profile around the Y axis.  pts_flat is a flat array of
! real(dp) of length 2*npts holding (x, y) pairs in profile order
! (bottom -> top typical), where x is the radius (>= 0) and y is the
! height.  Negative radii are clamped to 0.
!
! Triangle count is EXACTLY (npts-1)*seg*2, where seg = max(3, segments):
! every quad between consecutive profile points is emitted as 2
! triangles, with no exceptions (degenerate radius-0 quads included).
! If npts < 2 the result is an empty mesh (num_triangles == 0).
!
! Phase 1 indexed form: vertices are shared WITHIN one profile band
! (two rings of seg+1 verts per band, the +1 is the UV-seam
! duplicate) but split BETWEEN bands: the legacy per-vertex normal
! comes from the band's own profile segment (adjacent bands generally
! assign different normals to the same profile point), so sharing
! across bands would change the legacy shading.
!   n_verts = (npts-1) * 2 * (seg+1), n_tris = (npts-1)*seg*2.
! UV: u = (j-1)/seg around, v = cumulative profile arc length
! fraction (per band: v_lo at the lower ring, v_hi at the upper).
module geo_lathe_3d
    use math_3d
    use mesh_3d
    use mesh_data_3d
    implicit none
    private
    public :: create_lathe, build_lathe_data

contains

    subroutine build_lathe_data(md, segments, pts_flat, npts)
        type(mesh_data), intent(out) :: md
        integer, intent(in) :: segments
        integer, intent(in) :: npts
        real(dp), intent(in) :: pts_flat(2 * npts)
        integer :: seg, i, j, t, base
        real(dp) :: r_lo, r_hi, y_lo, y_hi
        real(dp) :: dr, dy, plen, n2x, n2y, theta
        real(dp), allocatable :: cumlen(:)
        real(dp) :: total_len, v_lo, v_hi
        type(vec3) :: a, b, c, d
        type(vec3) :: na, nb, nc, nd

        if (npts < 2) then
            call mesh_data_alloc(md, 0, 0)
            call mesh_data_finalize(md)
            return
        end if

        seg = max(3, segments)
        allocate(cumlen(npts))
        cumlen(1) = 0.0_dp
        do i = 2, npts
            dr = max(0.0_dp, pts_flat(2 * i - 1)) - &
                 max(0.0_dp, pts_flat(2 * i - 3))
            dy = pts_flat(2 * i) - pts_flat(2 * i - 2)
            cumlen(i) = cumlen(i - 1) + sqrt(dr * dr + dy * dy)
        end do
        total_len = cumlen(npts)

        call mesh_data_alloc(md, (npts - 1) * 2 * (seg + 1), &
                             (npts - 1) * seg * 2)
        t = 0
        do i = 1, npts - 1
            r_lo = max(0.0_dp, pts_flat(2 * i - 1))
            y_lo = pts_flat(2 * i)
            r_hi = max(0.0_dp, pts_flat(2 * i + 1))
            y_hi = pts_flat(2 * i + 2)
            ! 2D profile normal for this segment (legacy formula):
            ! tangent (dr, dy) rotated by -90 degrees -> (dy, -dr).
            dr = r_hi - r_lo
            dy = y_hi - y_lo
            plen = sqrt(dr * dr + dy * dy)
            if (plen > 1.0e-12_dp) then
                n2x = dy / plen
                n2y = -dr / plen
            else
                n2x = 1.0_dp
                n2y = 0.0_dp
            end if
            if (total_len > 0.0_dp) then
                v_lo = cumlen(i) / total_len
                v_hi = cumlen(i + 1) / total_len
            else
                v_lo = real(i - 1, dp) / real(npts - 1, dp)
                v_hi = real(i, dp) / real(npts - 1, dp)
            end if
            base = (i - 1) * 2 * (seg + 1)
            do j = 1, seg + 1
                theta = 2.0_dp * PI * real(mod(j - 1, seg), dp) / &
                        real(seg, dp)
                a = lathe_point(r_lo, y_lo, seg, mod(j - 1, seg) + 1)
                na = lathe_vertex_normal(r_lo, n2x, n2y, dy, theta)
                call mesh_data_put_vertex(md, base + j, a, na, &
                    [real(j - 1, dp) / real(seg, dp), v_lo])
                d = lathe_point(r_hi, y_hi, seg, mod(j - 1, seg) + 1)
                nd = lathe_vertex_normal(r_hi, n2x, n2y, dy, theta)
                call mesh_data_put_vertex(md, base + (seg + 1) + j, d, &
                    nd, [real(j - 1, dp) / real(seg, dp), v_hi])
            end do
            do j = 1, seg
                a = lathe_point(r_lo, y_lo, seg, j)
                b = lathe_point(r_lo, y_lo, seg, mod(j, seg) + 1)
                c = lathe_point(r_hi, y_hi, seg, mod(j, seg) + 1)
                d = lathe_point(r_hi, y_hi, seg, j)
                t = t + 1
                call mesh_data_put_tri(md, t, base + j, &
                    base + (seg + 1) + j + 1, base + j + 1, &
                    compute_triangle_normal(a, c, b), .true., &
                    [255, 255, 255])
                t = t + 1
                call mesh_data_put_tri(md, t, base + j, &
                    base + (seg + 1) + j, base + (seg + 1) + j + 1, &
                    compute_triangle_normal(a, d, c), .true., &
                    [255, 255, 255])
            end do
        end do
        deallocate(cumlen)
        call mesh_data_finalize(md)
    end subroutine build_lathe_data

    subroutine create_lathe(m, segments, pts_flat, npts)
        type(Mesh), intent(inout) :: m
        integer, intent(in) :: segments
        integer, intent(in) :: npts
        real(dp), intent(in) :: pts_flat(2 * npts)
        type(mesh_data) :: md
        call build_lathe_data(md, segments, pts_flat, npts)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_lathe

    ! Vertex normal for a lathe vertex at radius r and azimuth theta,
    ! from the segment's 2D profile normal (n2x, n2y): rotate n2
    ! around Y, vn = (n2x*cos(theta), n2y, n2x*sin(theta)) -- already
    ! unit length when (n2x, n2y) is.  A radius-0 (on-axis) vertex
    ! gets the axis-direction normal (0, +/-1, 0): the sign is the
    ! profile normal's Y component when it has one, otherwise the
    ! profile segment's Y direction (defaulting to +1).
    pure function lathe_vertex_normal(r, n2x, n2y, dy, theta) result(n)
        real(dp), intent(in) :: r, n2x, n2y, dy, theta
        type(vec3) :: n
        real(dp) :: sgn
        if (r <= 0.0_dp) then
            if (abs(n2y) > 1.0e-12_dp) then
                sgn = sign(1.0_dp, n2y)
            else if (abs(dy) > 1.0e-12_dp) then
                sgn = sign(1.0_dp, dy)
            else
                sgn = 1.0_dp
            end if
            n = vec3_create(0.0_dp, sgn, 0.0_dp)
        else
            n = vec3_create(n2x * cos(theta), n2y, n2x * sin(theta))
        end if
    end function lathe_vertex_normal

    pure function lathe_point(radius, y, seg, j) result(p)
        real(dp), intent(in) :: radius, y
        integer, intent(in) :: seg, j
        type(vec3) :: p
        real(dp) :: theta
        theta = 2.0_dp * PI * real(j - 1, dp) / real(seg, dp)
        p = vec3_create(radius * cos(theta), y, radius * sin(theta))
    end function lathe_point

end module geo_lathe_3d
