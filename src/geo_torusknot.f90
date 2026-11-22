! geo_torusknot.f90 -- classic (p,q) = (2,3) torus knot.
!
! Centreline (binding contract):
!   x = radius * (2 + cos(3u)) * cos(2u) / 2
!   y = radius * (2 + cos(3u)) * sin(2u) / 2
!   z = radius * sin(3u) / 2          for u in [0, 2*pi)
! The tube is swept with parallel-transport frames (no twist flips);
! the holonomy accumulated around the closed curve is distributed
! evenly over all steps so the seam closes without a twist jump.
! Triangle count = seg * tseg * 2 exactly, with
!   seg  = max(8, segments),  tseg = max(3, tube_segments).
! Guards: radius <= 0 -> 1.0, tube <= 0 -> radius * 0.3 (guarded radius).
! Per-triangle normals via compute_triangle_normal; colour white.
module geo_torusknot_3d
    use math_3d
    use mesh_3d, only: Mesh, Triangle, compute_triangle_normal
    implicit none
    private
    public :: create_torusknot

contains

    pure function torusknot_centre(radius, u) result(p)
        real(dp), intent(in) :: radius, u
        type(vec3) :: p
        real(dp) :: rr
        rr = radius * (2.0_dp + cos(3.0_dp * u)) * 0.5_dp
        p = vec3_create(rr * cos(2.0_dp * u), &
                        rr * sin(2.0_dp * u), &
                        radius * sin(3.0_dp * u) * 0.5_dp)
    end function torusknot_centre

    subroutine create_torusknot(m, radius, tube, segments, tube_segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, tube
        integer, intent(in) :: segments, tube_segments
        integer :: seg, tseg, i, j, i2, j2, idx
        real(dp) :: rad, tb, u, phi, hol, frac, ang, ca, sa
        type(vec3), allocatable :: centre(:), tangent(:), normal(:), binormal(:)
        type(vec3), allocatable :: ring(:, :)
        type(vec3) :: a, b, c, d, arb, n_end, tmp

        if (allocated(m%triangles)) deallocate(m%triangles)

        rad = radius
        if (rad <= 0.0_dp) rad = 1.0_dp
        tb = tube
        if (tb <= 0.0_dp) tb = rad * 0.3_dp
        seg = max(8, segments)
        tseg = max(3, tube_segments)

        allocate(centre(seg), tangent(seg), normal(seg), binormal(seg))
        allocate(ring(seg, tseg))

        ! Centreline points and (cyclic central-difference) tangents.
        do i = 1, seg
            u = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
            centre(i) = torusknot_centre(rad, u)
        end do
        do i = 1, seg
            i2 = mod(i, seg) + 1
            j2 = mod(i - 2 + seg, seg) + 1
            tangent(i) = vec3_normalize(vec3_sub(centre(i2), centre(j2)))
        end do

        ! Initial normal: any direction not near-parallel to tangent(1).
        arb = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
        if (abs(vec3_dot(arb, tangent(1))) > 0.9_dp) &
            arb = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
        normal(1) = vec3_normalize(vec3_sub(arb, &
            vec3_scale(tangent(1), vec3_dot(arb, tangent(1)))))

        ! Parallel transport: project the previous normal onto the plane
        ! perpendicular to the new tangent and renormalise (no twist).
        do i = 2, seg
            tmp = vec3_sub(normal(i - 1), &
                vec3_scale(tangent(i), vec3_dot(normal(i - 1), tangent(i))))
            if (vec3_norm(tmp) <= 1.0e-12_dp) then
                ! Degenerate projection: rebuild from an arbitrary axis.
                arb = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
                if (abs(vec3_dot(arb, tangent(i))) > 0.9_dp) &
                    arb = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
                tmp = vec3_sub(arb, &
                    vec3_scale(tangent(i), vec3_dot(arb, tangent(i))))
            end if
            normal(i) = vec3_normalize(tmp)
        end do

        ! Holonomy: transport normal(1) once more around the loop back to
        ! step 1 and measure its signed angle from normal(1) about
        ! tangent(1). Distribute the correction evenly so the frame at
        ! the seam matches frame 1 exactly.
        n_end = vec3_sub(normal(seg), &
            vec3_scale(tangent(1), vec3_dot(normal(seg), tangent(1))))
        if (vec3_norm(n_end) > 1.0e-12_dp) then
            n_end = vec3_normalize(n_end)
            ca = max(-1.0_dp, min(1.0_dp, vec3_dot(normal(1), n_end)))
            sa = vec3_dot(vec3_cross(normal(1), n_end), tangent(1))
            hol = atan2(sa, ca)
        else
            hol = 0.0_dp
        end if
        do i = 1, seg
            frac = real(i - 1, dp) / real(seg, dp)
            ang = -hol * frac
            if (abs(ang) > 0.0_dp) then
                ! Rodrigues rotation of normal(i) about tangent(i); the
                ! normal stays perpendicular to the tangent.
                tmp = vec3_add(vec3_scale(normal(i), cos(ang)), &
                    vec3_scale(vec3_cross(tangent(i), normal(i)), sin(ang)))
                normal(i) = vec3_normalize(tmp)
            end if
            binormal(i) = vec3_cross(tangent(i), normal(i))
        end do

        ! Tube rings.
        do i = 1, seg
            do j = 1, tseg
                phi = 2.0_dp * PI * real(j - 1, dp) / real(tseg, dp)
                ring(i, j) = vec3_add(centre(i), vec3_scale( &
                    vec3_add(vec3_scale(normal(i), cos(phi)), &
                             vec3_scale(binormal(i), sin(phi))), tb))
            end do
        end do

        m%num_triangles = seg * tseg * 2
        allocate(m%triangles(m%num_triangles))
        idx = 0
        do i = 1, seg
            i2 = mod(i, seg) + 1
            do j = 1, tseg
                j2 = mod(j, tseg) + 1
                a = ring(i, j)
                b = ring(i2, j)
                c = ring(i2, j2)
                d = ring(i, j2)
                idx = idx + 1
                m%triangles(idx)%v = [a, d, c]
                m%triangles(idx)%normal = compute_triangle_normal(a, d, c)
                m%triangles(idx)%color = [255, 255, 255]
                idx = idx + 1
                m%triangles(idx)%v = [a, c, b]
                m%triangles(idx)%normal = compute_triangle_normal(a, c, b)
                m%triangles(idx)%color = [255, 255, 255]
            end do
        end do
        m%num_triangles = idx

        deallocate(centre, tangent, normal, binormal, ring)
    end subroutine create_torusknot

end module geo_torusknot_3d
