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
!
! Phase 1 indexed form: a (seg+1) x (tseg+1) grid -- the +1 row and
! column are seam duplicates (the frame at the seam is frame 1 by
! the holonomy correction, so the duplicates carry identical
! position/normal with u or v = 1 instead of 0).
!   n_verts = (seg+1)*(tseg+1), n_tris = 2*seg*tseg.
! UV: u along the centreline, v around the tube.  Vertex normals are
! the frame radial directions (position - centreline point).
module geo_torusknot_3d
    use math_3d
    use mesh_3d, only: Mesh, Triangle, compute_triangle_normal, &
                       mesh_data_to_triangles
    use mesh_data_3d
    implicit none
    private
    public :: create_torusknot, build_torusknot_data

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

    subroutine build_torusknot_data(md, radius, tube, segments, &
                                    tube_segments)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius, tube
        integer, intent(in) :: segments, tube_segments
        integer :: seg, tseg, i, j, i2, j2, t, rb, rb2
        real(dp) :: rad, tb, u, phi, hol, frac, ang, ca, sa
        type(vec3), allocatable :: centre(:), tangent(:), normal(:), &
                                   binormal(:)
        type(vec3), allocatable :: ring(:, :)
        type(vec3) :: a, b, c, d, arb, n_end, tmp

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

        ! Parallel transport: project the previous normal onto the
        ! plane perpendicular to the new tangent and renormalise.
        do i = 2, seg
            tmp = vec3_sub(normal(i - 1), &
                vec3_scale(tangent(i), vec3_dot(normal(i - 1), &
                                                tangent(i))))
            if (vec3_norm(tmp) <= 1.0e-12_dp) then
                arb = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
                if (abs(vec3_dot(arb, tangent(i))) > 0.9_dp) &
                    arb = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
                tmp = vec3_sub(arb, &
                    vec3_scale(tangent(i), vec3_dot(arb, tangent(i))))
            end if
            normal(i) = vec3_normalize(tmp)
        end do

        ! Holonomy correction, distributed evenly over all steps.
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
                tmp = vec3_add(vec3_scale(normal(i), cos(ang)), &
                    vec3_scale(vec3_cross(tangent(i), normal(i)), &
                               sin(ang)))
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

        call mesh_data_alloc(md, (seg + 1) * (tseg + 1), seg * tseg * 2)
        do i = 1, seg + 1
            rb = (i - 1) * (tseg + 1)
            i2 = mod(i - 1, seg) + 1
            do j = 1, tseg + 1
                j2 = mod(j - 1, tseg) + 1
                a = ring(i2, j2)
                call mesh_data_put_vertex(md, rb + j, a, &
                    vec3_normalize(vec3_sub(a, centre(i2))), &
                    [real(i - 1, dp) / real(seg, dp), &
                     real(j - 1, dp) / real(tseg, dp)])
            end do
        end do
        t = 0
        do i = 1, seg
            rb = (i - 1) * (tseg + 1)
            rb2 = i * (tseg + 1)
            do j = 1, tseg
                a = ring(i, j)
                b = ring(mod(i, seg) + 1, j)
                c = ring(mod(i, seg) + 1, mod(j, tseg) + 1)
                d = ring(i, mod(j, tseg) + 1)
                t = t + 1
                call mesh_data_put_tri(md, t, rb + j, rb + j + 1, &
                    rb2 + j + 1, compute_triangle_normal(a, d, c), &
                    .true., [255, 255, 255])
                t = t + 1
                call mesh_data_put_tri(md, t, rb + j, rb2 + j + 1, &
                    rb2 + j, compute_triangle_normal(a, c, b), &
                    .true., [255, 255, 255])
            end do
        end do

        deallocate(centre, tangent, normal, binormal, ring)
        call mesh_data_finalize(md)
    end subroutine build_torusknot_data

    subroutine create_torusknot(m, radius, tube, segments, tube_segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, tube
        integer, intent(in) :: segments, tube_segments
        type(mesh_data) :: md
        call build_torusknot_data(md, radius, tube, segments, &
                                  tube_segments)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_torusknot

end module geo_torusknot_3d
