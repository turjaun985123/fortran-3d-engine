module geo_capsule_3d
    use math_3d
    use mesh_3d
    use mesh_data_3d
    implicit none
    private
    public :: create_capsule, build_capsule_data

contains

    ! Capsule along Y, centred at the origin: a cylindrical mid-section
    ! of length `height` with a hemispherical cap at each end.
    !   seg = max(4, segments) rounded UP to a multiple of 4
    !   hr  = seg / 4                     (hemisphere bands)
    ! Triangle count is exactly 2*seg + 2*seg*(2*hr-1) (as the legacy
    ! soup).  E.g. segments=16 -> hr=4 -> 256; segments=8 -> hr=2 -> 64.
    ! Guards: radius <= 0 -> 0.5, height < 0 -> 0.
    !
    ! Indexed (Phase 1): 2*seg pole verts (one per fan segment) +
    ! 2*hr profile rings of seg+1 verts (the +1 is the UV-seam
    ! duplicate).  Ring order top to bottom: top hemisphere rings
    ! j=1..hr (j=hr is the +hh equator), bottom hemisphere rings
    ! bj=hr..1 (bj=hr is the -hh equator, bj=1 nearest the pole).
    ! The equator rings are shared between hemisphere bands and the
    ! barrel: their analytic normals agree there (hemisphere normal
    ! at the equator IS the radial barrel normal).
    !   n_verts = 2*seg + 2*hr*(seg+1)
    ! UV: u = (i-1)/seg around, v by profile arc length from the
    ! bottom pole (v=0) to the top pole (v=1).
    subroutine build_capsule_data(md, radius, height, segments)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        integer :: seg, hr, i, j, t, jr, bj, off, off1, pole_b
        real(dp) :: r, h, hh, arc_len, v, phi
        type(vec3) :: top_pole, bot_pole, a, b, c, d
        type(vec3) :: b1, b2, t1, t2, p

        r = radius
        if (r <= 0.0_dp) r = 0.5_dp
        h = height
        if (h < 0.0_dp) h = 0.0_dp
        hh = h * 0.5_dp

        seg = max(4, segments)
        if (mod(seg, 4) /= 0) seg = (seg / 4 + 1) * 4
        hr = seg / 4

        call mesh_data_alloc(md, 2 * seg + 2 * hr * (seg + 1), &
                             2 * seg + 2 * seg * (2 * hr - 1))
        top_pole = vec3_create(0.0_dp, hh + r, 0.0_dp)
        bot_pole = vec3_create(0.0_dp, -hh - r, 0.0_dp)
        arc_len = PI * r + h

        ! Pole duplicates (v = 1 top, v = 0 bottom).
        pole_b = seg + 2 * hr * (seg + 1)
        do i = 1, seg
            call mesh_data_put_vertex(md, i, top_pole, &
                capsule_top_vn(top_pole, hh), &
                [(real(i, dp) - 0.5_dp) / real(seg, dp), 1.0_dp])
            call mesh_data_put_vertex(md, pole_b + i, bot_pole, &
                capsule_bot_vn(bot_pole, hh), &
                [(real(i, dp) - 0.5_dp) / real(seg, dp), 0.0_dp])
        end do
        ! Profile rings jr = 1..2*hr.
        do jr = 1, 2 * hr
            off = seg + (jr - 1) * (seg + 1)
            if (jr <= hr) then
                phi = 0.5_dp * PI * real(jr, dp) / real(hr, dp)
                if (arc_len > 0.0_dp) then
                    v = 1.0_dp - (r * phi) / arc_len
                else
                    v = 1.0_dp
                end if
            else
                bj = 2 * hr - jr + 1
                phi = 0.5_dp * PI * real(bj, dp) / real(hr, dp)
                if (arc_len > 0.0_dp) then
                    v = 1.0_dp - (0.5_dp * PI * r + h + &
                                  r * (0.5_dp * PI - phi)) / arc_len
                else
                    v = 0.0_dp
                end if
            end if
            do i = 1, seg + 1
                if (jr <= hr) then
                    p = capsule_top_point(r, hh, seg, hr, jr, &
                                          mod(i - 1, seg) + 1)
                    call mesh_data_put_vertex(md, off + i, p, &
                        capsule_top_vn(p, hh), &
                        [real(i - 1, dp) / real(seg, dp), v])
                else
                    bj = 2 * hr - jr + 1
                    p = capsule_bot_point(r, hh, seg, hr, bj, &
                                          mod(i - 1, seg) + 1)
                    call mesh_data_put_vertex(md, off + i, p, &
                        capsule_bot_vn(p, hh), &
                        [real(i - 1, dp) / real(seg, dp), v])
                end if
            end do
        end do

        t = 0
        ! ---- Top hemisphere: pole fan (ring j=1) ----
        do i = 1, seg
            a = capsule_top_point(r, hh, seg, hr, 1, i)
            b = capsule_top_point(r, hh, seg, hr, 1, mod(i, seg) + 1)
            t = t + 1
            call mesh_data_put_tri(md, t, i, seg + i + 1, seg + i, &
                compute_triangle_normal(top_pole, b, a), .true., &
                [255, 255, 255])
        end do
        ! ---- Top hemisphere: bands j=1..hr-1 ----
        do j = 1, hr - 1
            off = seg + (j - 1) * (seg + 1)
            off1 = off + seg + 1
            do i = 1, seg
                a = capsule_top_point(r, hh, seg, hr, j, i)
                b = capsule_top_point(r, hh, seg, hr, j, &
                                      mod(i, seg) + 1)
                c = capsule_top_point(r, hh, seg, hr, j + 1, &
                                      mod(i, seg) + 1)
                d = capsule_top_point(r, hh, seg, hr, j + 1, i)
                t = t + 1
                call mesh_data_put_tri(md, t, off + i, off + i + 1, &
                    off1 + i + 1, compute_triangle_normal(a, b, c), &
                    .true., [255, 255, 255])
                t = t + 1
                call mesh_data_put_tri(md, t, off + i, off1 + i + 1, &
                    off1 + i, compute_triangle_normal(a, c, d), &
                    .true., [255, 255, 255])
            end do
        end do
        ! ---- Cylinder side: top equator ring hr, bottom ring hr+1 --
        off = seg + hr * (seg + 1)          ! bottom equator offset
        off1 = seg + (hr - 1) * (seg + 1)   ! top equator offset
        do i = 1, seg
            b1 = capsule_top_point(r, hh, seg, hr, hr, i)
            b2 = capsule_top_point(r, hh, seg, hr, hr, mod(i, seg) + 1)
            t1 = b1
            t2 = b2
            b1%y = -hh
            b2%y = -hh
            t = t + 1
            call mesh_data_put_tri(md, t, off + i, off1 + i + 1, &
                off + i + 1, compute_triangle_normal(b1, t2, b2), &
                .true., [255, 255, 255])
            t = t + 1
            call mesh_data_put_tri(md, t, off + i, off1 + i, &
                off1 + i + 1, compute_triangle_normal(b1, t1, t2), &
                .true., [255, 255, 255])
        end do
        ! ---- Bottom hemisphere: bands j=1..hr-1 ----
        ! Ring j is the lower (poleward) ring, ring j+1 the upper one.
        do j = 1, hr - 1
            off = seg + (2 * hr - j) * (seg + 1)      ! bot ring j
            off1 = seg + (2 * hr - j - 1) * (seg + 1) ! bot ring j+1
            do i = 1, seg
                a = capsule_bot_point(r, hh, seg, hr, j, i)
                b = capsule_bot_point(r, hh, seg, hr, j, &
                                      mod(i, seg) + 1)
                c = capsule_bot_point(r, hh, seg, hr, j + 1, &
                                      mod(i, seg) + 1)
                d = capsule_bot_point(r, hh, seg, hr, j + 1, i)
                t = t + 1
                call mesh_data_put_tri(md, t, off1 + i, off1 + i + 1, &
                    off + i + 1, compute_triangle_normal(d, c, b), &
                    .true., [255, 255, 255])
                t = t + 1
                call mesh_data_put_tri(md, t, off1 + i, off + i + 1, &
                    off + i, compute_triangle_normal(d, b, a), &
                    .true., [255, 255, 255])
            end do
        end do
        ! ---- Bottom hemisphere: pole fan (ring j=1) ----
        off = seg + (2 * hr - 1) * (seg + 1)
        do i = 1, seg
            a = capsule_bot_point(r, hh, seg, hr, 1, i)
            b = capsule_bot_point(r, hh, seg, hr, 1, mod(i, seg) + 1)
            t = t + 1
            call mesh_data_put_tri(md, t, pole_b + i, off + i, &
                off + i + 1, compute_triangle_normal(bot_pole, a, b), &
                .true., [255, 255, 255])
        end do
        call mesh_data_finalize(md)
    end subroutine build_capsule_data

    subroutine create_capsule(m, radius, height, segments)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: radius, height
        integer, intent(in) :: segments
        type(mesh_data) :: md
        call build_capsule_data(md, radius, height, segments)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
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
