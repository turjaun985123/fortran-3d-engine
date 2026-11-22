program test_camera_renderer
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use material_3d
    use test_assert
    use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
    implicit none

    type(Camera) :: cam, bad_cam
    type(FrameBuffer) :: fb, fb_basic, fb_lamb
    type(Mesh) :: cube
    type(Material) :: mat_red_basic, mat_red_lamb
    type(mat4) :: model_matrix
    type(vec3) :: eye, target, light_dir, got
    real(dp) :: old_m11, expected_m11
    logical :: ok, exists
    integer :: fsize, cx, cy, x, y, i, ndistinct, n_nonbg, n_red_exact
    integer :: n_basic_diff, n_lamb_diff
    integer :: distinct(3, 64 * 48), found
    logical :: is_new, all_red, lamb_differs, lamb_shaded
    character(len=*), parameter :: ppm_path = '/tmp/test_camera_renderer.ppm'

    ! ---- camera_init stores fields ----
    eye = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
    target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
    call camera_init(cam, eye, target, 60.0_dp, 64.0_dp / 48.0_dp, 0.1_dp, 100.0_dp)
    call assert_vec3_close(eye, cam%position, 1.0e-12_dp, 'camera_init stores position')
    call assert_vec3_close(target, cam%target, 1.0e-12_dp, 'camera_init stores target')
    call assert_vec3_close(vec3_create(0.0_dp, 1.0_dp, 0.0_dp), cam%up, &
        1.0e-12_dp, 'camera_init sets up to (0,1,0)')
    call assert_real_close(60.0_dp, cam%fov_deg, 1.0e-12_dp, 'camera_init stores fov_deg')
    call assert_real_close(64.0_dp / 48.0_dp, cam%aspect_ratio, 1.0e-12_dp, &
        'camera_init stores aspect_ratio')
    call assert_real_close(0.1_dp, cam%near_plane, 1.0e-12_dp, 'camera_init stores near_plane')
    call assert_real_close(100.0_dp, cam%far_plane, 1.0e-12_dp, 'camera_init stores far_plane')

    ! ---- view matrix maps eye to origin ----
    got = mat4_transform_vec3(cam%view_matrix, eye, .true.)
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), got, 1.0e-9_dp, &
        'view matrix maps eye to (0,0,0)')

    ! ---- camera_is_valid ----
    call assert_true(camera_is_valid(cam), 'camera_is_valid true for defaults')
    call camera_init(bad_cam, eye, target, 200.0_dp, 1.0_dp, 0.1_dp, 100.0_dp)
    call assert_false(camera_is_valid(bad_cam), 'camera_is_valid false for fov 200')

    ! ---- camera_init_checked invalid ----
    call camera_init_checked(bad_cam, eye, target, 200.0_dp, 1.0_dp, 0.1_dp, 100.0_dp, ok)
    call assert_false(ok, 'camera_init_checked invalid fov gives ok false')
    call assert_true(all(ieee_is_finite(bad_cam%view_matrix%m)), &
        'camera_init_checked invalid gives finite view matrix')
    call assert_true(all(ieee_is_finite(bad_cam%proj_matrix%m)), &
        'camera_init_checked invalid gives finite proj matrix')

    ! ---- camera_set_aspect updates proj m(1,1) ----
    old_m11 = cam%proj_matrix%m(1, 1)
    call camera_set_aspect(cam, 1.0_dp)
    call assert_real_close(1.0_dp, cam%aspect_ratio, 1.0e-12_dp, &
        'camera_set_aspect stores new aspect')
    call assert_true(abs(cam%proj_matrix%m(1, 1) - old_m11) > 1.0e-9_dp, &
        'camera_set_aspect changes proj m(1,1)')
    expected_m11 = 1.0_dp / (1.0_dp * tan(deg2rad(60.0_dp) * 0.5_dp))
    call assert_real_close(expected_m11, cam%proj_matrix%m(1, 1), 1.0e-12_dp, &
        'camera_set_aspect proj m(1,1) matches 1/(aspect*tan(fov/2))')
    call camera_set_aspect(cam, 64.0_dp / 48.0_dp)

    ! ---- framebuffer_init / clear ----
    call framebuffer_init(fb, 64, 48)
    call assert_int_eq(64, fb%width, 'framebuffer_init width 64')
    call assert_int_eq(48, fb%height, 'framebuffer_init height 48')
    call assert_int_eq(25, fb%pixels(1, 1, 1), 'fb pixel (1,1) R == bg 25')
    call assert_int_eq(25, fb%pixels(2, 1, 1), 'fb pixel (1,1) G == bg 25')
    call assert_int_eq(35, fb%pixels(3, 1, 1), 'fb pixel (1,1) B == bg 35')
    call assert_true(fb%z_buffer(1, 1) > 1.0e9_dp, 'fb z_buffer huge after init')
    call framebuffer_clear(fb, 10, 20, 30)
    call assert_int_eq(10, fb%pixels(1, 1, 1), 'fb clear sets pixel (1,1) R')
    call assert_int_eq(20, fb%pixels(2, 1, 1), 'fb clear sets pixel (1,1) G')
    call assert_int_eq(30, fb%pixels(3, 1, 1), 'fb clear sets pixel (1,1) B')
    call assert_true(fb%z_buffer(1, 1) > 1.0e9_dp, 'fb z_buffer huge after clear')
    call framebuffer_clear(fb, 25, 25, 35)

    ! ---- legacy render: cube demo pose covers centre, >=3 colours ----
    call create_cube(cube, 2.0_dp)
    model_matrix = mat4_mult(mat4_rotate_y(deg2rad(35.0_dp)), &
                             mat4_rotate_x(deg2rad(20.0_dp)))
    light_dir = vec3_create(-0.5_dp, -1.0_dp, -0.7_dp)
    call framebuffer_render_mesh(fb, cube, model_matrix, cam, light_dir)
    cx = 32; cy = 24
    call assert_true(.not. (fb%pixels(1, cx, cy) == 25 .and. &
                            fb%pixels(2, cx, cy) == 25 .and. &
                            fb%pixels(3, cx, cy) == 35), &
        'legacy render centre pixel is not bg (cube covers centre)')
    ndistinct = 0
    do y = 1, fb%height
        do x = 1, fb%width
            is_new = .true.
            do i = 1, ndistinct
                if (distinct(1, i) == fb%pixels(1, x, y) .and. &
                    distinct(2, i) == fb%pixels(2, x, y) .and. &
                    distinct(3, i) == fb%pixels(3, x, y)) then
                    is_new = .false.
                    exit
                end if
            end do
            if (is_new) then
                ndistinct = ndistinct + 1
                distinct(:, ndistinct) = fb%pixels(:, x, y)
            end if
        end do
    end do
    found = ndistinct
    call assert_true(found >= 3, 'legacy render has at least 3 distinct colours')

    ! ---- material basic red: non-bg pixels are exactly (255,0,0) ----
    call framebuffer_init(fb_basic, 64, 48)
    mat_red_basic = material_basic([1.0_dp, 0.0_dp, 0.0_dp])
    call framebuffer_render_mesh_mat(fb_basic, cube, model_matrix, cam, light_dir, mat_red_basic)
    n_nonbg = 0; n_red_exact = 0; all_red = .true.
    do y = 1, fb_basic%height
        do x = 1, fb_basic%width
            if (.not. (fb_basic%pixels(1, x, y) == 25 .and. &
                       fb_basic%pixels(2, x, y) == 25 .and. &
                       fb_basic%pixels(3, x, y) == 35)) then
                n_nonbg = n_nonbg + 1
                if (fb_basic%pixels(1, x, y) == 255 .and. &
                    fb_basic%pixels(2, x, y) == 0 .and. &
                    fb_basic%pixels(3, x, y) == 0) then
                    n_red_exact = n_red_exact + 1
                else
                    all_red = .false.
                end if
            end if
        end do
    end do
    call assert_true(n_nonbg > 0, 'basic red render has non-bg pixels')
    call assert_true(n_red_exact >= 1, 'basic red render has a pixel exactly (255,0,0)')
    call assert_true(all_red, 'basic red render all non-bg pixels are (255,0,0)')

    ! ---- lambert red differs from basic (shading applied) ----
    call framebuffer_init(fb_lamb, 64, 48)
    mat_red_lamb = material_lambert([1.0_dp, 0.0_dp, 0.0_dp], .false.)
    call framebuffer_render_mesh_mat(fb_lamb, cube, model_matrix, cam, light_dir, mat_red_lamb)
    lamb_differs = .false.; lamb_shaded = .false.
    n_basic_diff = 0; n_lamb_diff = 0
    do y = 1, fb_lamb%height
        do x = 1, fb_lamb%width
            if (any(fb_lamb%pixels(:, x, y) /= fb_basic%pixels(:, x, y))) then
                lamb_differs = .true.
                n_lamb_diff = n_lamb_diff + 1
            end if
            if (.not. (fb_lamb%pixels(1, x, y) == 25 .and. &
                       fb_lamb%pixels(2, x, y) == 25 .and. &
                       fb_lamb%pixels(3, x, y) == 35)) then
                if (fb_lamb%pixels(1, x, y) < 255) lamb_shaded = .true.
            end if
        end do
    end do
    n_basic_diff = n_lamb_diff
    call assert_true(lamb_differs, 'lambert red render differs from basic red')
    call assert_true(lamb_shaded, 'lambert red is shaded (some non-bg R < 255)')

    ! ---- PPM save: file exists with size > 0 ----
    call framebuffer_save_ppm(fb, ppm_path)
    inquire(file=ppm_path, exist=exists, size=fsize)
    call assert_true(exists, 'PPM file exists after framebuffer_save_ppm')
    call assert_true(fsize > 0, 'PPM file size > 0')

    call free_mesh(cube)
    call test_summary()

end program test_camera_renderer
