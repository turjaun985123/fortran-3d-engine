module geo_extrude_3d
    use math_3d
    use mesh_3d
    use mesh_data_3d
    implicit none
    private
    public :: create_extrude, build_extrude_data

contains

    ! Extrude a 2D polygon footprint upward into a prism.
    !
    !   pts_flat(2*i-1), pts_flat(2*i) = (x, y) of footprint point i
    !   shape (x, y) maps to world (x, 0, y): the footprint lies on the
    !   XZ ground plane and is extruded along +Y by depth.
    !   depth <= 0 is replaced by 0.5; 0 < depth < 0.01 is raised to 0.01.
    !   npts < 3 (or a too-short pts_flat) yields an empty mesh.
    !
    ! Winding: either CW or CCW input is accepted (see the legacy
    ! signed-area normalisation in the code -- the normalised order
    ! gives outward faces).  Caps are triangle fans from point 0
    ! (exact for convex / point-0-star-shaped polygons).
    !
    ! Triangle count is exactly 4*npts - 4 (caps 2*(npts-2), sides
    ! npts*2), layout: top caps, bottom caps, sides -- as legacy.
    !
    ! Phase 1 indexed form (flat-shaded, so shading groups split):
    ! top cap npts verts, bottom cap npts verts, and 4 verts per side
    ! edge (side normals differ per edge):
    !   n_verts = 6*npts, n_tris = 4*npts - 4.
    ! UV: caps planar over the footprint bounds; sides u = cumulative
    ! edge-length fraction, v = 0 at the bottom, 1 at the top.
    subroutine build_extrude_data(md, depth, pts_flat, npts)
        type(mesh_data), intent(out) :: md
        real(dp), intent(in) :: depth
        real(dp), intent(in) :: pts_flat(:)
        integer, intent(in) :: npts
        real(dp) :: d, area2
        type(vec3), allocatable :: bot(:), top(:)
        integer :: i, i2, t, k, src, vb
        logical :: reversed
        real(dp) :: bmin(2), bmax(2), span(2), perim, u0, u1, elen
        type(vec3) :: fn
        real(dp), allocatable :: cumlen(:)

        if (npts < 3 .or. size(pts_flat) < 2 * npts) then
            call mesh_data_alloc(md, 0, 0)
            call mesh_data_finalize(md)
            return
        end if

        if (depth <= 0.0_dp) then
            d = 0.5_dp
        else if (depth < 0.01_dp) then
            d = 0.01_dp
        else
            d = depth
        end if

        ! Twice the signed area in the shape (x, y) plane.
        area2 = 0.0_dp
        do i = 1, npts
            i2 = mod(i, npts) + 1
            area2 = area2 + pts_flat(2 * i - 1) * pts_flat(2 * i2) &
                          - pts_flat(2 * i2 - 1) * pts_flat(2 * i)
        end do
        reversed = area2 > 0.0_dp

        allocate(bot(npts), top(npts))
        do i = 1, npts
            if (reversed .and. i > 1) then
                src = npts - i + 2
            else
                src = i
            end if
            bot(i) = vec3_create(pts_flat(2 * src - 1), 0.0_dp, &
                                 pts_flat(2 * src))
            top(i) = vec3_create(pts_flat(2 * src - 1), d, &
                                 pts_flat(2 * src))
        end do

        bmin = [minval(bot(:)%x), minval(bot(:)%z)]
        bmax = [maxval(bot(:)%x), maxval(bot(:)%z)]
        span = bmax - bmin
        allocate(cumlen(npts + 1))
        cumlen(1) = 0.0_dp
        do i = 1, npts
            i2 = mod(i, npts) + 1
            elen = sqrt((bot(i2)%x - bot(i)%x)**2 + &
                        (bot(i2)%z - bot(i)%z)**2)
            cumlen(i + 1) = cumlen(i) + elen
        end do
        perim = cumlen(npts + 1)

        call mesh_data_alloc(md, 6 * npts, 4 * npts - 4)
        ! Top cap verts (normal +Y), bottom cap verts (-Y).
        do i = 1, npts
            call mesh_data_put_vertex(md, i, top(i), &
                vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                planar_uv(top(i), bmin, span))
            call mesh_data_put_vertex(md, npts + i, bot(i), &
                vec3_create(0.0_dp, -1.0_dp, 0.0_dp), &
                planar_uv(bot(i), bmin, span))
        end do
        ! Side verts: 4 per edge [bot_i, bot_i2, top_i2, top_i].
        do i = 1, npts
            i2 = mod(i, npts) + 1
            vb = 2 * npts + (i - 1) * 4
            fn = compute_triangle_normal(bot(i), bot(i2), top(i2))
            if (perim > 0.0_dp) then
                u0 = cumlen(i) / perim
                u1 = cumlen(i + 1) / perim
            else
                u0 = real(i - 1, dp) / real(npts, dp)
                u1 = real(i, dp) / real(npts, dp)
            end if
            call mesh_data_put_vertex(md, vb + 1, bot(i), fn, [u0, 0.0_dp])
            call mesh_data_put_vertex(md, vb + 2, bot(i2), fn, [u1, 0.0_dp])
            call mesh_data_put_vertex(md, vb + 3, top(i2), fn, [u1, 1.0_dp])
            call mesh_data_put_vertex(md, vb + 4, top(i), fn, [u0, 1.0_dp])
        end do

        t = 0
        ! Top cap fan from point 0 (faces +Y for the normalised order).
        do k = 2, npts - 1
            t = t + 1
            call mesh_data_put_tri(md, t, 1, k, k + 1, &
                compute_triangle_normal(top(1), top(k), top(k + 1)), &
                .false., [255, 255, 255])
        end do
        ! Bottom cap fan from point 0, reversed winding (faces -Y).
        do k = 2, npts - 1
            t = t + 1
            call mesh_data_put_tri(md, t, npts + 1, npts + k + 1, &
                npts + k, &
                compute_triangle_normal(bot(1), bot(k + 1), bot(k)), &
                .false., [255, 255, 255])
        end do
        ! Sides: one quad (two triangles) per footprint edge.
        do i = 1, npts
            vb = 2 * npts + (i - 1) * 4
            i2 = mod(i, npts) + 1
            t = t + 1
            call mesh_data_put_tri(md, t, vb + 1, vb + 2, vb + 3, &
                compute_triangle_normal(bot(i), bot(i2), top(i2)), &
                .false., [255, 255, 255])
            t = t + 1
            call mesh_data_put_tri(md, t, vb + 1, vb + 3, vb + 4, &
                compute_triangle_normal(bot(i), top(i2), top(i)), &
                .false., [255, 255, 255])
        end do

        deallocate(bot, top, cumlen)
        call mesh_data_finalize(md)
    end subroutine build_extrude_data

    subroutine create_extrude(m, depth, pts_flat, npts)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: depth
        real(dp), intent(in) :: pts_flat(:)
        integer, intent(in) :: npts
        type(mesh_data) :: md
        call build_extrude_data(md, depth, pts_flat, npts)
        call mesh_data_to_triangles(md, m)
        call mesh_data_free(md)
    end subroutine create_extrude

    pure function planar_uv(p, bmin, span) result(uv)
        type(vec3), intent(in) :: p
        real(dp), intent(in) :: bmin(2), span(2)
        real(dp) :: uv(2)
        if (span(1) > 0.0_dp) then
            uv(1) = (p%x - bmin(1)) / span(1)
        else
            uv(1) = 0.5_dp
        end if
        if (span(2) > 0.0_dp) then
            uv(2) = (p%z - bmin(2)) / span(2)
        else
            uv(2) = 0.5_dp
        end if
    end function planar_uv

end module geo_extrude_3d
