! sprite.f90 -- camera-facing billboard quads (sprites).
!
! A sprite is a 2-triangle quad centred at a world position that always
! faces the camera: its plane is perpendicular to the view direction
! from the camera to the centre, so it rasterises identically (up to
! perspective scaling) from any viewing direction -- the billboard
! property.
!
! Basis (frozen by the master plan):
!   view_dir = normalize(center - cam_pos)
!   up_hint  = (0,1,0), or (1,0,0) when view_dir is near-parallel to
!              (0,1,0) (|dot| > 0.999), where the cross product below
!              would degenerate
!   right    = normalize(cross(up_hint, view_dir))
!   up2      = cross(view_dir, right)
! right / up2 / view_dir are then an orthonormal set and the corners are
!   center +/- right*(size/2) +/- up2*(size/2).
!
! Winding: with the corners labelled
!   a = center - right*h - up2*h      b = center + right*h - up2*h
!   c = center + right*h + up2*h      d = center - right*h + up2*h
! (h = size/2) the triangles are [a,b,c] and [a,c,d].  Note that
! `right` as defined above points to screen-left (it is the negative of
! the look-at camera's right vector) while up2 points to screen-up, so
! this ordering -- not create_plane's [a,c,b]/[a,d,c] pattern -- is the
! one whose projected screen-space cross product
!   (sx2-sx1)*(sy3-sy1) - (sy2-sy1)*(sx3-sx1)
! is > 0 for a camera in front, i.e. the winding renderer_3d keeps
! (verified by the real-renderer assertions in test_sprite.f90).
! The stored per-triangle normal is -view_dir, facing the camera.
module sprite_3d
    use math_3d
    use mesh_3d
    implicit none
    private
    public :: sprite_build_mesh, sprite_basis

contains

    ! Orthonormal billboard basis for a sprite at center seen from
    ! cam_pos: right and up2 span the sprite plane, both perpendicular
    ! to the view direction normalize(center - cam_pos).
    pure subroutine sprite_basis(center, cam_pos, right, up2)
        type(vec3), intent(in) :: center, cam_pos
        type(vec3), intent(out) :: right, up2

        type(vec3) :: view_dir, up_hint

        view_dir = vec3_normalize(vec3_sub(center, cam_pos))
        up_hint = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        if (abs(vec3_dot(view_dir, up_hint)) > 0.999_dp) then
            up_hint = vec3_create(1.0_dp, 0.0_dp, 0.0_dp)
        end if
        right = vec3_normalize(vec3_cross(up_hint, view_dir))
        up2 = vec3_normalize(vec3_cross(view_dir, right))
    end subroutine sprite_basis

    ! Build a 2-triangle billboard Mesh centred at center with side
    ! size, facing cam_pos, coloured color_rgb on both triangles.
    subroutine sprite_build_mesh(center, size, color_rgb, cam_pos, m)
        type(vec3), intent(in) :: center, cam_pos
        real(dp), intent(in) :: size
        integer, intent(in) :: color_rgb(3)
        type(Mesh), intent(inout) :: m

        type(vec3) :: right, up2, view_dir, a, b, c, d
        real(dp) :: h
        integer :: i

        call sprite_basis(center, cam_pos, right, up2)
        view_dir = vec3_normalize(vec3_sub(center, cam_pos))
        h = size * 0.5_dp

        a = vec3_add(vec3_sub(center, vec3_scale(right, h)), &
                     vec3_scale(up2, -h))
        b = vec3_add(vec3_add(center, vec3_scale(right, h)), &
                     vec3_scale(up2, -h))
        c = vec3_add(vec3_add(center, vec3_scale(right, h)), &
                     vec3_scale(up2, h))
        d = vec3_add(vec3_sub(center, vec3_scale(right, h)), &
                     vec3_scale(up2, h))

        if (allocated(m%triangles)) deallocate(m%triangles)
        m%num_triangles = 2
        allocate(m%triangles(2))
        m%triangles(1)%v = [a, b, c]
        m%triangles(2)%v = [a, c, d]
        do i = 1, 2
            m%triangles(i)%normal = vec3_negate(view_dir)
            m%triangles(i)%color = color_rgb
            m%triangles(i)%material_id = 0
        end do
    end subroutine sprite_build_mesh

end module sprite_3d
