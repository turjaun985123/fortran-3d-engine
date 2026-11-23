! geo_tube.f90 -- tube swept along a polyline path.
!
! Frame choice: PARALLEL TRANSPORT (documented per seat spec).
!   An initial frame is built at the first path point from an
!   arbitrary reference axis that is not parallel to the first
!   tangent (the coordinate axis with the smallest |component| of
!   that tangent, so the projection below is always well
!   conditioned).  Each subsequent frame is obtained by rotating
!   the previous frame's normal by the rotation that takes the
!   previous tangent to the current tangent (Rodrigues' formula
!   about axis = t_prev x t_cur), then re-orthogonalising against
!   the current tangent; the binormal is b = t x n.  Parallel
!   transport introduces no twist of its own, so on a straight
!   path every ring frame is identical and on a gently curving
!   path frames vary only as much as the tangent itself turns --
!   rings never twist or flip.  (A fixed-up Frenet frame, by
!   contrast, flips when the path passes near the up direction.)
!
! Geometry / counts:
!   seg = max(3, segments) vertices per ring, one ring per point.
!   Side triangles  = (npts-1) * seg * 2
!   End caps        = seg triangle-fan triangles at each end
!                     (start-cap normals along -t_start, end-cap
!                     normals along +t_end, i.e. both outward)
!   Total           = (npts-1)*seg*2 + 2*seg
!   radius <= 0 is guarded to 0.2.  npts < 2 gives an empty mesh
!   (num_triangles == 0).  All triangles are white and carry a
!   compute_triangle_normal normal, as in mesh_3d's create_torus.
module geo_tube_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: create_tube

contains

    subroutine create_tube(m, radius, segments, pts_flat, npts)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        real(dp), intent(in) :: pts_flat(*)
        integer, intent(in) :: npts
        integer :: seg, i, k, k2, idx, total
        real(dp) :: r, theta, cth, sth
        type(vec3), allocatable :: pts(:), tang(:), nrm(:), bin(:)
        type(vec3), allocatable :: ring(:, :)
        type(vec3) :: a, b, c, dd, cen, axis_ref, n_prev
        type(vec3) :: rot_axis, t_prev, t_cur
        real(dp) :: cosang, sinang

        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = 0
        if (npts < 2) return

        r = radius
        if (r <= 0.0_dp) r = 0.2_dp
        seg = max(3, segments)

        allocate(pts(npts), tang(npts), nrm(npts), bin(npts))
        allocate(ring(seg, npts))
        do i = 1, npts
            pts(i) = vec3_create(pts_flat(3 * (i - 1) + 1), &
                                 pts_flat(3 * (i - 1) + 2), &
                                 pts_flat(3 * (i - 1) + 3))
        end do

        ! ---- tangents: forward / central / backward differences ----
        do i = 1, npts
            if (i == 1) then
                tang(i) = vec3_sub(pts(2), pts(1))
            else if (i == npts) then
                tang(i) = vec3_sub(pts(npts), pts(npts - 1))
            else
                tang(i) = vec3_sub(pts(i + 1), pts(i - 1))
            end if
            if (vec3_norm(tang(i)) > 1.0e-12_dp) then
                tang(i) = vec3_normalize(tang(i))
            else if (i > 1) then
                tang(i) = tang(i - 1)   ! duplicate point: keep direction
            else
                tang(i) = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
            end if
        end do

        ! ---- initial frame from a non-parallel arbitrary axis ----
        if (abs(tang(1)%x) <= abs(tang(1)%y) .and. &
            abs(tang(1)%x) <= abs(tang(1)%z)) then
            axis_ref = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
        else if (abs(tang(1)%y) <= abs(tang(1)%z)) then
            axis_ref = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        else
            axis_ref = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
        end if
        nrm(1) = vec3_normalize(vec3_sub(axis_ref, &
            vec3_scale(tang(1), vec3_dot(axis_ref, tang(1)))))
        bin(1) = vec3_cross(tang(1), nrm(1))

        ! ---- parallel transport along the polyline ----
        do i = 2, npts
            t_prev = tang(i - 1)
            t_cur = tang(i)
            n_prev = nrm(i - 1)
            cosang = max(-1.0_dp, min(1.0_dp, vec3_dot(t_prev, t_cur)))
            rot_axis = vec3_cross(t_prev, t_cur)
            sinang = vec3_norm(rot_axis)
            if (sinang <= 1.0e-12_dp) then
                if (cosang < 0.0_dp) then
                    ! 180-degree turn: flip the normal, keep binormal axis.
                    nrm(i) = vec3_negate(n_prev)
                else
                    nrm(i) = n_prev
                end if
            else
                rot_axis = vec3_scale(rot_axis, 1.0_dp / sinang)
                ! Rodrigues rotation of n_prev about rot_axis.
                nrm(i) = vec3_add( &
                    vec3_add(vec3_scale(n_prev, cosang), &
                             vec3_scale(vec3_cross(rot_axis, n_prev), sinang)), &
                    vec3_scale(rot_axis, vec3_dot(rot_axis, n_prev) * (1.0_dp - cosang)))
            end if
            ! Re-orthogonalise against the current tangent and normalise.
            nrm(i) = vec3_sub(nrm(i), vec3_scale(t_cur, vec3_dot(nrm(i), t_cur)))
            if (vec3_norm(nrm(i)) > 1.0e-12_dp) then
                nrm(i) = vec3_normalize(nrm(i))
            else
                nrm(i) = n_prev
            end if
            bin(i) = vec3_cross(t_cur, nrm(i))
        end do

        ! ---- rings ----
        do i = 1, npts
            do k = 1, seg
                theta = 2.0_dp * PI * real(k - 1, dp) / real(seg, dp)
                cth = cos(theta)
                sth = sin(theta)
                ring(k, i) = vec3_add(pts(i), vec3_scale( &
                    vec3_add(vec3_scale(nrm(i), cth), vec3_scale(bin(i), sth)), r))
            end do
        end do

        total = (npts - 1) * seg * 2 + 2 * seg
        m%num_triangles = total
        allocate(m%triangles(total))
        idx = 0

        ! ---- sides: (a,b,c) / (a,c,d), outward winding ----
        do i = 1, npts - 1
            do k = 1, seg
                k2 = mod(k, seg) + 1
                a = ring(k, i)
                b = ring(k2, i)
                c = ring(k2, i + 1)
                dd = ring(k, i + 1)
                idx = idx + 1
                m%triangles(idx)%v = [a, b, c]
                m%triangles(idx)%normal = compute_triangle_normal(a, b, c)
                ! Vertex normal = radial direction from the path point
                ! of the vertex's ring (the parallel-transport frame
                ! direction the ring vertex was built from).
                call tri_set_smooth(m%triangles(idx), &
                    vec3_normalize(vec3_sub(a, pts(i))), &
                    vec3_normalize(vec3_sub(b, pts(i))), &
                    vec3_normalize(vec3_sub(c, pts(i + 1))))
                m%triangles(idx)%color = [255, 255, 255]
                idx = idx + 1
                m%triangles(idx)%v = [a, c, dd]
                m%triangles(idx)%normal = compute_triangle_normal(a, c, dd)
                call tri_set_smooth(m%triangles(idx), &
                    vec3_normalize(vec3_sub(a, pts(i))), &
                    vec3_normalize(vec3_sub(c, pts(i + 1))), &
                    vec3_normalize(vec3_sub(dd, pts(i + 1))))
                m%triangles(idx)%color = [255, 255, 255]
            end do
        end do

        ! ---- start cap fan: centre pts(1), winding gives -tang(1) ----
        cen = pts(1)
        do k = 1, seg
            k2 = mod(k, seg) + 1
            a = ring(k, 1)
            b = ring(k2, 1)
            idx = idx + 1
            m%triangles(idx)%v = [cen, b, a]
            m%triangles(idx)%normal = compute_triangle_normal(cen, b, a)
            m%triangles(idx)%vn = [m%triangles(idx)%normal, &
                                   m%triangles(idx)%normal, &
                                   m%triangles(idx)%normal]
            m%triangles(idx)%color = [255, 255, 255]
        end do

        ! ---- end cap fan: centre pts(npts), winding gives +tang(npts) ----
        cen = pts(npts)
        do k = 1, seg
            k2 = mod(k, seg) + 1
            a = ring(k, npts)
            b = ring(k2, npts)
            idx = idx + 1
            m%triangles(idx)%v = [cen, a, b]
            m%triangles(idx)%normal = compute_triangle_normal(cen, a, b)
            m%triangles(idx)%vn = [m%triangles(idx)%normal, &
                                   m%triangles(idx)%normal, &
                                   m%triangles(idx)%normal]
            m%triangles(idx)%color = [255, 255, 255]
        end do

        m%num_triangles = idx
        deallocate(pts, tang, nrm, bin, ring)
    end subroutine create_tube

end module geo_tube_3d
