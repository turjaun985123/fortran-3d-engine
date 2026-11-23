module geo_capsule_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: create_capsule

contains

    ! Capsule along Y, centred at the origin: a cylindrical mid-section
    ! of length `height` with a hemispherical cap at each end.
    !   seg = max(4, segments) rounded UP to a multiple of 4
    !   hr  = seg / 4                     (hemisphere bands)
    ! Each hemisphere = seg (pole fan) + 2*seg*(hr-1) (bands), and the
    ! cylinder side = 2*seg, so the total is exactly
    !   2*seg + 2*seg*(2*hr-1)
    ! triangles.  E.g. segments=16 -> hr=4 -> 256; segments=8 -> hr=2 -> 64.
    ! Hemisphere profile: angles from 0 to pi/2 in hr steps, measured
    ! from the pole (0) to the equator (pi/2, the end of the cylinder).
    ! Guards: radius <= 0 -> 0.5, height < 0 -> 0.
    subroutine create_capsule(m, radius, height, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        integer :: seg, hr, i, i2, j, j2, idx, total
        real(dp) :: r, h, hh
        type(vec3) :: top_pole, bot_pole, a, b, c, d
        type(vec3) :: b1, b2, t1, t2

        if (allocated(m%triangles)) deallocate(m%triangles)

        r = radius
        if (r <= 0.0_dp) r = 0.5_dp
        h = height
        if (h < 0.0_dp) h = 0.0_dp
        hh = h * 0.5_dp

        seg = max(4, segments)
        if (mod(seg, 4) /= 0) seg = (seg / 4 + 1) * 4
        hr = seg / 4

        total = 2 * seg + 2 * seg * (2 * hr - 1)
        m%num_triangles = total
        allocate(m%triangles(total))
        idx = 0

        top_pole = vec3_create(0.0_dp, hh + r, 0.0_dp)
        bot_pole = vec3_create(0.0_dp, -hh - r, 0.0_dp)

        ! ---- Top hemisphere: pole fan (ring j=1) ----
        do i = 1, seg
            i2 = mod(i, seg) + 1
            a = capsule_top_point(r, hh, seg, hr, 1, i)
            b = capsule_top_point(r, hh, seg, hr, 1, i2)
            idx = idx + 1
            m%triangles(idx)%v = [top_pole, b, a]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            call tri_set_smooth(m%triangles(idx), capsule_top_vn(top_pole, hh), &
                                capsule_top_vn(b, hh), capsule_top_vn(a, hh))
            m%triangles(idx)%color = [255, 255, 255]
        end do

        ! ---- Top hemisphere: bands j=1 .. hr-1 ----
        do j = 1, hr - 1
            j2 = j + 1
            do i = 1, seg
                i2 = mod(i, seg) + 1
                a = capsule_top_point(r, hh, seg, hr, j, i)
                b = capsule_top_point(r, hh, seg, hr, j, i2)
                c = capsule_top_point(r, hh, seg, hr, j2, i2)
                d = capsule_top_point(r, hh, seg, hr, j2, i)
                idx = idx + 1
                m%triangles(idx)%v = [a, b, c]
                m%triangles(idx)%normal = compute_triangle_normal( &
                    m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
                call tri_set_smooth(m%triangles(idx), capsule_top_vn(a, hh), &
                                    capsule_top_vn(b, hh), capsule_top_vn(c, hh))
                m%triangles(idx)%color = [255, 255, 255]
                idx = idx + 1
                m%triangles(idx)%v = [a, c, d]
                m%triangles(idx)%normal = compute_triangle_normal( &
                    m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
                call tri_set_smooth(m%triangles(idx), capsule_top_vn(a, hh), &
                                    capsule_top_vn(c, hh), capsule_top_vn(d, hh))
                m%triangles(idx)%color = [255, 255, 255]
            end do
        end do

        ! ---- Cylinder side ----
        do i = 1, seg
            i2 = mod(i, seg) + 1
            b1 = capsule_top_point(r, hh, seg, hr, hr, i)
            b2 = capsule_top_point(r, hh, seg, hr, hr, i2)
            t1 = b1
            t2 = b2
            b1%y = -hh
            b2%y = -hh
            idx = idx + 1
            m%triangles(idx)%v = [b1, t2, b2]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            call tri_set_smooth(m%triangles(idx), capsule_radial_vn(b1), &
                                capsule_radial_vn(t2), capsule_radial_vn(b2))
            m%triangles(idx)%color = [255, 255, 255]
            idx = idx + 1
            m%triangles(idx)%v = [b1, t1, t2]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            call tri_set_smooth(m%triangles(idx), capsule_radial_vn(b1), &
                                capsule_radial_vn(t1), capsule_radial_vn(t2))
            m%triangles(idx)%color = [255, 255, 255]
        end do

        ! ---- Bottom hemisphere: bands j=1 .. hr-1 ----
        ! Ring j is the lower (poleward) ring, ring j+1 the upper one,
        ! so the winding is the mirror of the top bands.
        do j = 1, hr - 1
            j2 = j + 1
            do i = 1, seg
                i2 = mod(i, seg) + 1
                a = capsule_bot_point(r, hh, seg, hr, j, i)
                b = capsule_bot_point(r, hh, seg, hr, j, i2)
                c = capsule_bot_point(r, hh, seg, hr, j2, i2)
                d = capsule_bot_point(r, hh, seg, hr, j2, i)
                idx = idx + 1
                m%triangles(idx)%v = [d, c, b]
                m%triangles(idx)%normal = compute_triangle_normal( &
                    m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
                call tri_set_smooth(m%triangles(idx), capsule_bot_vn(d, hh), &
                                    capsule_bot_vn(c, hh), capsule_bot_vn(b, hh))
                m%triangles(idx)%color = [255, 255, 255]
                idx = idx + 1
                m%triangles(idx)%v = [d, b, a]
                m%triangles(idx)%normal = compute_triangle_normal( &
                    m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
                call tri_set_smooth(m%triangles(idx), capsule_bot_vn(d, hh), &
                                    capsule_bot_vn(b, hh), capsule_bot_vn(a, hh))
                m%triangles(idx)%color = [255, 255, 255]
            end do
        end do

        ! ---- Bottom hemisphere: pole fan (ring j=1) ----
        do i = 1, seg
            i2 = mod(i, seg) + 1
            a = capsule_bot_point(r, hh, seg, hr, 1, i)
            b = capsule_bot_point(r, hh, seg, hr, 1, i2)
            idx = idx + 1
            m%triangles(idx)%v = [bot_pole, a, b]
            m%triangles(idx)%normal = compute_triangle_normal( &
                m%triangles(idx)%v(1), m%triangles(idx)%v(2), m%triangles(idx)%v(3))
            call tri_set_smooth(m%triangles(idx), capsule_bot_vn(bot_pole, hh), &
                                capsule_bot_vn(a, hh), capsule_bot_vn(b, hh))
            m%triangles(idx)%color = [255, 255, 255]
        end do

        m%num_triangles = idx
    end subroutine create_capsule

    ! Vertex normal on the top hemisphere: direction from the
    ! hemisphere centre (0, hh, 0) to the vertex, normalised.
    pure function capsule_top_vn(p, hh) result(n)
        type(vec3), intent(in) :: p
        real(dp), intent(in) :: hh
        type(vec3) :: n
        n = vec3_normalize(vec3_sub(p, vec3_create(0.0_dp, hh, 0.0_dp)))
    end function capsule_top_vn

    ! Vertex normal on the bottom hemisphere: centre (0, -hh, 0).
    pure function capsule_bot_vn(p, hh) result(n)
        type(vec3), intent(in) :: p
        real(dp), intent(in) :: hh
        type(vec3) :: n
        n = vec3_normalize(vec3_sub(p, vec3_create(0.0_dp, -hh, 0.0_dp)))
    end function capsule_bot_vn

    ! Vertex normal on the cylindrical barrel: radial (away from Y axis).
    pure function capsule_radial_vn(p) result(n)
        type(vec3), intent(in) :: p
        type(vec3) :: n
        n = vec3_normalize(vec3_create(p%x, 0.0_dp, p%z))
    end function capsule_radial_vn

    ! Point on ring j (1..hr) of the top hemisphere: the profile angle
    ! phi runs from 0 at the pole to pi/2 at the equator in hr steps.
    pure function capsule_top_point(r, hh, seg, hr, j, i) result(p)
        real(dp), intent(in) :: r, hh
        integer, intent(in) :: seg, hr, j, i
        type(vec3) :: p
        real(dp) :: phi, theta
        phi = 0.5_dp * PI * real(j, dp) / real(hr, dp)
        theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
        p = vec3_create(r * sin(phi) * cos(theta), &
                        hh + r * cos(phi), &
                        r * sin(phi) * sin(theta))
    end function capsule_top_point

    ! Mirror of capsule_top_point about y=0 (cap centre at y=-hh).
    pure function capsule_bot_point(r, hh, seg, hr, j, i) result(p)
        real(dp), intent(in) :: r, hh
        integer, intent(in) :: seg, hr, j, i
        type(vec3) :: p
        real(dp) :: phi, theta
        phi = 0.5_dp * PI * real(j, dp) / real(hr, dp)
        theta = 2.0_dp * PI * real(i - 1, dp) / real(seg, dp)
        p = vec3_create(r * sin(phi) * cos(theta), &
                        -hh - r * cos(phi), &
                        r * sin(phi) * sin(theta))
    end function capsule_bot_point

end module geo_capsule_3d
