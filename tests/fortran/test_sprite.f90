program test_sprite
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use material_3d
    use sprite_3d
    use test_assert
    implicit none

    type(vec3) :: center, cam_pos, cam_opp, cam_top, view_dir
    type(vec3) :: right, up2, corner(4)
    type(Mesh) :: sprite
    type(Camera) :: cam
    type(FrameBuffer) :: fb
    type(Material) :: mat
    type(mat4) :: identity
    real(dp) :: tol, expected_dist
    integer :: i, n_red

    tol = 1.0e-9_dp
    center = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    cam_pos = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
    identity = mat4_identity()

    ! ---- basis orthonormality: default camera ----
    view_dir = vec3_normalize(vec3_sub(center, cam_pos))
    call sprite_basis(center, cam_pos, right, up2)
    call assert_real_close(1.0_dp, vec3_norm(right), tol, &
        'basis (default cam): right is unit length')
    call assert_real_close(1.0_dp, vec3_norm(up2), tol, &
        'basis (default cam): up2 is unit length')
    call assert_real_close(1.0_dp, vec3_norm(view_dir), tol, &
        'basis (default cam): view_dir is unit length')
    call assert_real_close(0.0_dp, vec3_dot(right, up2), tol, &
        'basis (default cam): right . up2 ~ 0')
    call assert_real_close(0.0_dp, vec3_dot(right, view_dir), tol, &
        'basis (default cam): right . view_dir ~ 0')
    call assert_real_close(0.0_dp, vec3_dot(up2, view_dir), tol, &
        'basis (default cam): up2 . view_dir ~ 0')

    ! ---- basis orthonormality: degenerate camera directly above ----
    ! view_dir = (0,-1,0) is parallel to the (0,1,0) up hint, so the
    ! (1,0,0) fallback hint must be used.
    cam_top = vec3_create(0.0_dp, 10.0_dp, 0.0_dp)
    view_dir = vec3_normalize(vec3_sub(center, cam_top))
    call sprite_basis(center, cam_top, right, up2)
    call assert_real_close(1.0_dp, vec3_norm(right), tol, &
        'basis (cam above): right is unit length')
    call assert_real_close(1.0_dp, vec3_norm(up2), tol, &
        'basis (cam above): up2 is unit length')
    call assert_real_close(1.0_dp, vec3_norm(view_dir), tol, &
        'basis (cam above): view_dir is unit length')
    call assert_real_close(0.0_dp, vec3_dot(right, up2), tol, &
        'basis (cam above): right . up2 ~ 0')
    call assert_real_close(0.0_dp, vec3_dot(right, view_dir), tol, &
        'basis (cam above): right . view_dir ~ 0')
    call assert_real_close(0.0_dp, vec3_dot(up2, view_dir), tol, &
        'basis (cam above): up2 . view_dir ~ 0')

    ! ---- build: structure, colour, normals ----
    call sprite_build_mesh(center, 2.0_dp, [255, 0, 0], cam_pos, sprite)
    call assert_int_eq(2, sprite%num_triangles, 'sprite mesh has 2 triangles')
    call assert_true(all(sprite%triangles(1)%color == [255, 0, 0]), &
        'sprite triangle 1 colour is (255,0,0)')
    call assert_true(all(sprite%triangles(2)%color == [255, 0, 0]), &
        'sprite triangle 2 colour is (255,0,0)')
    view_dir = vec3_normalize(vec3_sub(center, cam_pos))
    call assert_vec3_close(vec3_negate(view_dir), sprite%triangles(1)%normal, tol, &
        'sprite triangle 1 normal is -view_dir (facing camera)')
    call assert_vec3_close(vec3_negate(view_dir), sprite%triangles(2)%normal, tol, &
        'sprite triangle 2 normal is -view_dir (facing camera)')

    ! ---- quad geometry: the 4 distinct corners ----
    ! Triangles are [a,b,c] and [a,c,d], so the distinct corners are
    ! tri1 v1, tri1 v2, tri1 v3 and tri2 v3.
    corner(1) = sprite%triangles(1)%v(1)
    corner(2) = sprite%triangles(1)%v(2)
    corner(3) = sprite%triangles(1)%v(3)
    corner(4) = sprite%triangles(2)%v(3)
    expected_dist = 2.0_dp / sqrt(2.0_dp)
    do i = 1, 4
        call assert_real_close(expected_dist, &
            vec3_norm(vec3_sub(corner(i), center)), tol, &
            'quad corner is exactly size/sqrt(2) from center')
        call assert_real_close(0.0_dp, &
            vec3_dot(vec3_sub(corner(i), center), view_dir), tol, &
            'quad corner lies in plane perpendicular to view_dir')
    end do

    ! ---- real-renderer visibility: default camera ----
    ! framebuffer_render_mesh is the renderer wrapper using
    ! material_default() (lambert, per-triangle colour); also exercise
    ! framebuffer_render_mesh_mat with material_default() explicitly.
    mat = material_default()
    call assert_true(mat%use_tri_color, 'material_default uses per-triangle colour')
    call camera_init(cam, cam_pos, center, 60.0_dp, 64.0_dp / 48.0_dp, &
                     0.1_dp, 100.0_dp)
    call framebuffer_init(fb, 64, 48)
    call framebuffer_render_mesh(fb, sprite, identity, cam, &
                                 vec3_create(-0.5_dp, -1.0_dp, -0.7_dp))
    n_red = count_red(fb)
    write(*, '(A, I0)') '       red-ish pixels (default cam): ', n_red
    call assert_true(n_red > 50, &
        'sprite renders > 50 red-ish pixels from default camera')

    call framebuffer_init(fb, 64, 48)
    call framebuffer_render_mesh_mat(fb, sprite, identity, cam, &
                                     vec3_create(-0.5_dp, -1.0_dp, -0.7_dp), mat)
    n_red = count_red(fb)
    write(*, '(A, I0)') '       red-ish pixels (render_mesh_mat): ', n_red
    call assert_true(n_red > 50, &
        'sprite renders > 50 red-ish pixels via render_mesh_mat/material_default')

    ! ---- billboard property: camera on the opposite side ----
    cam_opp = vec3_create(-3.0_dp, 2.5_dp, -4.0_dp)
    call sprite_build_mesh(center, 2.0_dp, [255, 0, 0], cam_opp, sprite)
    call assert_int_eq(2, sprite%num_triangles, &
        'rebuilt sprite (opposite cam) still has 2 triangles')
    call camera_init(cam, cam_opp, center, 60.0_dp, 64.0_dp / 48.0_dp, &
                     0.1_dp, 100.0_dp)
    call framebuffer_init(fb, 64, 48)
    call framebuffer_render_mesh(fb, sprite, identity, cam, &
                                 vec3_create(-0.5_dp, -1.0_dp, -0.7_dp))
    n_red = count_red(fb)
    write(*, '(A, I0)') '       red-ish pixels (opposite cam): ', n_red
    call assert_true(n_red > 50, &
        'sprite renders > 50 red-ish pixels from opposite camera (billboard)')

    call free_mesh(sprite)
    call test_summary()

contains

    ! Red-ish = clearly red-dominant and not the (25,25,35) background.
    ! Lambert shading with the default light leaves the sprite's red
    ! channel well above its (zero) green/blue channels.
    function count_red(fb_in) result(n)
        type(FrameBuffer), intent(in) :: fb_in
        integer :: n, px, py
        n = 0
        do py = 1, fb_in%height
            do px = 1, fb_in%width
                if (fb_in%pixels(1, px, py) > 50 .and. &
                    fb_in%pixels(1, px, py) > fb_in%pixels(2, px, py) + 20 .and. &
                    fb_in%pixels(1, px, py) > fb_in%pixels(3, px, py) + 20) then
                    n = n + 1
                end if
            end do
        end do
    end function count_red

end program test_sprite
