! geo_tube.f90 -- tube swept along a polyline path.
!
! Frame choice: PARALLEL TRANSPORT (see the legacy notes retained in
! build_tube_data: initial frame from the least-aligned axis,
! Rodrigues rotation between tangents, re-orthogonalisation; rings
! never twist or flip).
!
! Geometry / counts:
!   seg = max(3, segments) vertices per ring, one ring per point.
!   Side triangles  = (npts-1) * seg * 2
!   End caps        = seg triangle-fan triangles at each end
!   Total           = (npts-1)*seg*2 + 2*seg
!   radius <= 0 is guarded to 0.2.  npts < 2 gives an empty mesh.
!
! Phase 1 indexed form: side rings are shared along the tube
! (npts rings of seg+1 verts; the +1 is the UV-seam duplicate; a ring
! vertex's radial normal is the same for both adjacent bands, so
! sharing is exact).  Each end cap splits its centre + ring (cap
! verts carry the flat cap normal, not the radial side normal).
!   n_verts = npts*(seg+1) + 2*(seg+2), n_tris as above.
! UV: side u = (k-1)/seg around, v = cumulative path-length fraction;
! caps are planar discs in the ring frame (centre (0.5, 0.5)).
module geo_tube_3d
    use math_3d
    use mesh_3d
    use mesh_data_3d
    implicit none
    private
    public :: create_tube, build_tube_data

contains

    subroutine build_tube_data(md, radius, segments, pts_flat, npts)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        real(dp), intent(in) :: pts_flat(*)
        integer, intent(in) :: npts
        integer :: seg, i, k, t, cen_s, cen_e, ring_s, ring_e
        real(dp) :: r, theta, cth, sth
        type(vec3), allocatable :: pts(:), tang(:), nrm(:), bin(:)
        type(vec3), allocatable :: ring(:, :)
        type(vec3) :: a, b, c, dd, axis_ref, n_prev
        type(vec3) :: rot_axis, t_prev, t_cur
        real(dp) :: cosang, sinang
        real(dp), allocatable :: cumlen(:)
        real(dp) :: total_len, vfrac

        if (npts < 2) then
            call mesh_data_alloc(md, 0, 0)
            call mesh_data_finalize(md)
            return
        end if

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

        allocate(cumlen(npts))
        cumlen(1) = 0.0_dp
        do i = 2, npts
            cumlen(i) = cumlen(i - 1) + vec3_norm(vec3_sub(pts(i), &
                                                           pts(i - 1)))
        end do
        total_len = cumlen(npts)

        call mesh_data_alloc(md, npts * (seg + 1) + 2 * (seg + 2), &
                             (npts - 1) * seg * 2 + 2 * seg)
        ! Side ring verts.
        do i = 1, npts
            if (total_len > 0.0_dp) then
                vfrac = cumlen(i) / total_len
            else
                vfrac = real(i - 1, dp) / real(npts - 1, dp)
            end if
            do k = 1, seg + 1
                a = ring(mod(k - 1, seg) + 1, i)
                call mesh_data_put_vertex(md, (i - 1) * (seg + 1) + k, &
                    a, vec3_normalize(vec3_sub(a, pts(i))), &
                    [real(k - 1, dp) / real(seg, dp), vfrac])
            end do
        end do
        ! Cap verts: start centre + ring, end centre + ring.
        cen_s = npts * (seg + 1) + 1
        ring_s = cen_s + 1
        cen_e = ring_s + seg + 1
        ring_e = cen_e + 1
        call mesh_data_put_vertex(md, cen_s, pts(1), &
            vec3_negate(tang(1)), [0.5_dp, 0.5_dp])
        call mesh_data_put_vertex(md, cen_e, pts(npts), tang(npts), &
            [0.5_dp, 0.5_dp])
        do k = 1, seg + 1
            theta = 2.0_dp * PI * real(mod(k - 1, seg), dp) / &
                    real(seg, dp)
            a = ring(mod(k - 1, seg) + 1, 1)
            call mesh_data_put_vertex(md, ring_s + k - 1, a, &
                vec3_negate(tang(1)), &
                [0.5_dp + 0.5_dp * cos(theta), &
                 0.5_dp + 0.5_dp * sin(theta)])
            a = ring(mod(k - 1, seg) + 1, npts)
            call mesh_data_put_vertex(md, ring_e + k - 1, a, &
                tang(npts), &
                [0.5_dp + 0.5_dp * cos(theta), &
                 0.5_dp + 0.5_dp * sin(theta)])
        end do

        t = 0
        ! ---- sides: (a,b,c) / (a,c,d), outward winding ----
        do i = 1, npts - 1
            do k = 1, seg
                a = ring(k, i)
                b = ring(mod(k, seg) + 1, i)
                c = ring(mod(k, seg) + 1, i + 1)
                dd = ring(k, i + 1)
                t = t + 1
                call mesh_data_put_tri(md, t, (i - 1) * (seg + 1) + k, &
                    (i - 1) * (seg + 1) + k + 1, i * (seg + 1) + k + 1, &
                    compute_triangle_normal(a, b, c), .true., &
                    [255, 255, 255])
                t = t + 1
                call mesh_data_put_tri(md, t, (i - 1) * (seg + 1) + k, &
                    i * (seg + 1) + k + 1, i * (seg + 1) + k, &
                    compute_triangle_normal(a, c, dd), .true., &
                    [255, 255, 255])
            end do
        end do
        ! ---- start cap fan: centre pts(1), winding gives -tang(1) ----
        do k = 1, seg
            a = ring(k, 1)
            b = ring(mod(k, seg) + 1, 1)
            t = t + 1
            call mesh_data_put_tri(md, t, cen_s, ring_s + k, &
                ring_s + k - 1, compute_triangle_normal(pts(1), b, a), &
                .false., [255, 255, 255])
        end do
        ! ---- end cap fan: centre pts(npts), winding gives +tang ----
        do k = 1, seg
            a = ring(k, npts)
            b = ring(mod(k, seg) + 1, npts)
            t = t + 1
            call mesh_data_put_tri(md, t, cen_e, ring_e + k - 1, &
                ring_e + k, compute_triangle_normal(pts(npts), a, b), &
                .false., [255, 255, 255])
        end do

        deallocate(pts, tang, nrm, bin, ring, cumlen)
        call mesh_data_finalize(md)
    end subroutine build_tube_data

    subroutine create_tube(m, radius, segments, pts_flat, npts)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius
        integer, intent(in) :: segments
        real(dp), intent(in) :: pts_flat(*)
        integer, intent(in) :: npts
        type(mesh_data) :: md
        call build_tube_data(md, radius, segments, pts_flat, npts)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_tube

end module geo_tube_3d
