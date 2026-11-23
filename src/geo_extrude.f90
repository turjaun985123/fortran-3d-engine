module geo_extrude_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: create_extrude

contains

    ! Extrude a 2D polygon footprint upward into a prism.
    !
    !   pts_flat(2*i-1), pts_flat(2*i) = (x, y) of footprint point i
    !   shape (x, y) maps to world (x, 0, y): the footprint lies on the
    !   XZ ground plane and is extruded along +Y by depth.
    !   depth <= 0 is replaced by 0.5; 0 < depth < 0.01 is raised to 0.01.
    !   npts < 3 (or a too-short pts_flat) yields an empty mesh.
    !
    ! Winding: either CW or CCW input is accepted. The signed area of
    ! the footprint is computed and, when it is positive (CCW in the
    ! shape plane), the point order is reversed -- keeping point 0 in
    ! place -- so that the normalised order always gives outward
    ! faces: top cap +Y, bottom cap -Y, sides pointing outward with
    ! horizontal normals.
    !
    ! Caps are triangle fans from point 0. Fan caps are exact for
    ! convex polygons and for polygons star-shaped from point 0
    ! (point 0 can see every other vertex); a general concave polygon
    ! whose kernel does not contain point 0 is not triangulated
    ! correctly by a fan.
    !
    ! Triangle count is exactly 4*npts - 4:
    !   caps  2 * (npts - 2)   (top fan + bottom fan)
    !   sides npts * 2
    ! Layout: top caps first, then bottom caps, then sides.
    subroutine create_extrude(m, depth, pts_flat, npts)
        type(Mesh), intent(inout) :: m
        real(dp), intent(in) :: depth
        real(dp), intent(in) :: pts_flat(:)
        integer, intent(in) :: npts
        real(dp) :: d, area2
        type(vec3), allocatable :: bot(:), top(:)
        integer :: i, i2, idx, k, src
        logical :: reversed

        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = 0

        if (npts < 3) return
        if (size(pts_flat) < 2 * npts) return

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
        ! Positive (CCW) area would make the top fan face -Y in world
        ! (x, 0, y) coordinates, so reverse it; negative stays as is.
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

        m%num_triangles = 4 * npts - 4
        allocate(m%triangles(m%num_triangles))
        idx = 0

        ! Top cap fan from point 0 (faces +Y for the normalised order).
        do k = 2, npts - 1
            idx = idx + 1
            m%triangles(idx)%v = [top(1), top(k), top(k + 1)]
        end do
        ! Bottom cap fan from point 0, reversed winding (faces -Y).
        do k = 2, npts - 1
            idx = idx + 1
            m%triangles(idx)%v = [bot(1), bot(k + 1), bot(k)]
        end do
        ! Sides: one quad (two triangles) per footprint edge.
        do i = 1, npts
            i2 = mod(i, npts) + 1
            idx = idx + 1
            m%triangles(idx)%v = [bot(i), bot(i2), top(i2)]
            idx = idx + 1
            m%triangles(idx)%v = [bot(i), top(i2), top(i)]
        end do

        do i = 1, m%num_triangles
            m%triangles(i)%normal = compute_triangle_normal( &
                m%triangles(i)%v(1), m%triangles(i)%v(2), &
                m%triangles(i)%v(3))
            m%triangles(i)%vn = [m%triangles(i)%normal, m%triangles(i)%normal, m%triangles(i)%normal]
            m%triangles(i)%color = [255, 255, 255]
        end do

        deallocate(bot, top)
    end subroutine create_extrude

end module geo_extrude_3d
