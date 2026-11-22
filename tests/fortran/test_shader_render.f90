program test_shader_render
    ! Wave E (C2) custom-shader renderer path:
    ! framebuffer_render_mesh_shader must let a user RPN shader
    ! (shader_3d, seat E02 contract) change pixels per-pixel, while
    ! the identity shader `c` reproduces the unlit flat render.
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use material_3d
    use shader_3d
    use test_assert
    implicit none

    type(Camera) :: cam
    type(FrameBuffer) :: fb_ref, fb_a, fb_b, fb_c, fb_d
    type(Mesh) :: cube
    type(Material) :: mat
    type(ShaderProg) :: prog
    type(mat4) :: model_matrix
    type(vec3) :: light_dir
    logical :: ok
    character(len=128) :: errmsg
    integer :: cx, cy, x, y, k
    integer :: n_covered, n_bad, n_diff_centre, n_distinct
    integer :: distinct(3, 512)
    logical :: is_new, centre_differs
    character(len=16) :: toks_a(1), toks_b(1), toks_c(1)
    character(len=16) :: toks_d(10)

    ! Same camera / pose as test_camera_renderer so the cube
    ! covers the frame centre with known face colours.
    call camera_init(cam, vec3_create(3.0_dp, 2.5_dp, 4.0_dp), &
                     vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 60.0_dp, &
                     64.0_dp / 48.0_dp, 0.1_dp, 100.0_dp)
    call create_cube(cube, 2.0_dp)
    model_matrix = mat4_mult(mat4_rotate_y(deg2rad(35.0_dp)), &
                             mat4_rotate_x(deg2rad(20.0_dp)))
    light_dir = vec3_create(-0.5_dp, -1.0_dp, -0.7_dp)

    ! Unlit, per-triangle colour: the flat reference for (a).
    mat = material_lambert([1.0_dp, 1.0_dp, 1.0_dp], .true.)
    mat%mode = 1
    call framebuffer_init(fb_ref, 64, 48)
    call framebuffer_render_mesh_mat(fb_ref, cube, model_matrix, &
                                     cam, light_dir, mat)
    cx = 32; cy = 24
    call assert_true(.not. (fb_ref%pixels(1, cx, cy) == 25 .and. &
                            fb_ref%pixels(2, cx, cy) == 25 .and. &
                            fb_ref%pixels(3, cx, cy) == 35), &
        'reference flat render covers centre pixel')

    ! ---- (a) expr `c`: identity == unlit flat render ----
    toks_a(1) = 'c'
    call shader_parse(toks_a, prog, ok, errmsg)
    call assert_true(ok, 'shader_parse accepts expr c')
    call framebuffer_init(fb_a, 64, 48)
    call framebuffer_render_mesh_shader(fb_a, cube, model_matrix, &
        cam, light_dir, mat, 0.25_dp, prog, 0.0_dp)
    do k = 1, 3
        call assert_int_eq(fb_ref%pixels(k, cx, cy), &
                           fb_a%pixels(k, cx, cy), &
            'shader c centre pixel channel == face colour (flat ref)')
    end do
    n_bad = 0
    do y = 1, 48
        do x = 1, 64
            if (any(fb_a%pixels(:, x, y) /= fb_ref%pixels(:, x, y))) &
                n_bad = n_bad + 1
        end do
    end do
    call assert_int_eq(0, n_bad, &
        'shader c render identical to unlit flat render everywhere')

    ! ---- (b) expr `0.5`: every covered pixel == 128 ----
    toks_b(1) = '0.5'
    call shader_parse(toks_b, prog, ok, errmsg)
    call assert_true(ok, 'shader_parse accepts constant 0.5')
    call framebuffer_init(fb_b, 64, 48)
    call framebuffer_render_mesh_shader(fb_b, cube, model_matrix, &
        cam, light_dir, mat, 0.25_dp, prog, 0.0_dp)
    n_covered = 0; n_bad = 0
    do y = 1, 48
        do x = 1, 64
            if (fb_b%z_buffer(x, y) < 1.0e9_dp) then
                n_covered = n_covered + 1
                if (any(fb_b%pixels(:, x, y) /= 128)) n_bad = n_bad + 1
            end if
        end do
    end do
    call assert_true(n_covered > 0, 'shader 0.5 render covers pixels')
    call assert_int_eq(0, n_bad, &
        'shader 0.5: every covered pixel == 128 on all channels')

    ! ---- (c) expr `0`: covered pixels black, differs from (a) ----
    toks_c(1) = '0'
    call shader_parse(toks_c, prog, ok, errmsg)
    call assert_true(ok, 'shader_parse accepts constant 0')
    call framebuffer_init(fb_c, 64, 48)
    call framebuffer_render_mesh_shader(fb_c, cube, model_matrix, &
        cam, light_dir, mat, 0.25_dp, prog, 0.0_dp)
    n_covered = 0; n_bad = 0
    do y = 1, 48
        do x = 1, 64
            if (fb_c%z_buffer(x, y) < 1.0e9_dp) then
                n_covered = n_covered + 1
                if (any(fb_c%pixels(:, x, y) /= 0)) n_bad = n_bad + 1
            end if
        end do
    end do
    call assert_true(n_covered > 0, 'shader 0 render covers pixels')
    call assert_int_eq(0, n_bad, 'shader 0: every covered pixel black')
    n_diff_centre = 0
    do k = 1, 3
        if (fb_c%pixels(k, cx, cy) /= fb_a%pixels(k, cx, cy)) &
            n_diff_centre = n_diff_centre + 1
    end do
    centre_differs = n_diff_centre > 0
    call assert_true(centre_differs, &
        'shader 0 centre differs from shader c (user code changes pixels)')

    ! ---- (d) checker: step(0.5, fract((x+y)*2)) * c in RPN ----
    toks_d(1) = '0.5';   toks_d(2) = 'x';    toks_d(3) = 'y'
    toks_d(4) = '+';     toks_d(5) = '2';    toks_d(6) = '*'
    toks_d(7) = 'fract'; toks_d(8) = 'step'; toks_d(9) = 'c'
    toks_d(10) = '*'
    call shader_parse(toks_d, prog, ok, errmsg)
    call assert_true(ok, 'shader_parse accepts checker RPN')
    call framebuffer_init(fb_d, 64, 48)
    call framebuffer_render_mesh_shader(fb_d, cube, model_matrix, &
        cam, light_dir, mat, 0.25_dp, prog, 0.0_dp)
    n_covered = 0; n_distinct = 0
    do y = 1, 48
        do x = 1, 64
            if (fb_d%z_buffer(x, y) < 1.0e9_dp) then
                n_covered = n_covered + 1
                is_new = .true.
                do k = 1, n_distinct
                    if (all(distinct(:, k) == fb_d%pixels(:, x, y))) then
                        is_new = .false.
                        exit
                    end if
                end do
                if (is_new .and. n_distinct < 512) then
                    n_distinct = n_distinct + 1
                    distinct(:, n_distinct) = fb_d%pixels(:, x, y)
                end if
            end if
        end do
    end do
    call assert_true(n_covered > 0, 'checker render covers pixels')
    call assert_true(n_distinct >= 2, &
        'checker shader yields at least two distinct covered values')

    call free_mesh(cube)
    call test_summary()

end program test_shader_render
