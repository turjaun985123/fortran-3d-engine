! test_text_render.f90 -- tests for text_render_3d (Wave B seat B68):
! the frozen 5x7 font contract (charset indices, integer(8) masks,
! bit layout) and text-as-geometry (triangle counts, bounds, width).
program test_text_render
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use material_3d
    use text_render_3d
    use test_assert
    implicit none

    type(Mesh) :: msh, other_m
    type(Camera) :: cam
    type(FrameBuffer) :: fb
    type(Material) :: mat
    type(mat4) :: identity
    integer(8) :: mask_a, mask_dot
    integer :: rgb(3), i, k, n_lit
    logical :: in_bounds, all_plus_z

    rgb = [10, 20, 30]

    ! ---- charset indices ----
    call assert_int_eq(0, text_glyph_index(' '), 'index of space == 0')
    call assert_int_eq(1, text_glyph_index('A'), 'index of A == 1')
    call assert_int_eq(26, text_glyph_index('Z'), 'index of Z == 26')
    call assert_int_eq(27, text_glyph_index('0'), 'index of 0 == 27')
    call assert_int_eq(36, text_glyph_index('9'), 'index of 9 == 36')
    call assert_int_eq(37, text_glyph_index('.'), 'index of . == 37')
    call assert_int_eq(38, text_glyph_index('!'), 'index of ! == 38')
    call assert_int_eq(39, text_glyph_index('?'), 'index of ? == 39')
    call assert_int_eq(40, text_glyph_index('-'), 'index of - == 40')
    call assert_int_eq(41, text_glyph_index(':'), 'index of : == 41')
    call assert_int_eq(42, text_glyph_index("'"), "index of ' == 42")
    call assert_int_eq(text_glyph_index('A'), text_glyph_index('a'), &
        'index of a == index of A (lowercase uppercased)')
    call assert_int_eq(text_glyph_index('Z'), text_glyph_index('z'), &
        'index of z == index of Z (lowercase uppercased)')
    call assert_int_eq(39, text_glyph_index('#'), 'unknown # maps to ? index 39')
    call assert_int_eq(39, text_glyph_index('@'), 'unknown @ maps to ? index 39')

    ! ---- masks: exact frozen values ----
    call assert_true(text_glyph_mask(0) == 0_8, 'mask of space == 0')
    call assert_true(text_glyph_mask(text_glyph_index(' ')) == 0_8, &
        'mask via index of space == 0')
    mask_a = text_glyph_mask(text_glyph_index('A'))
    call assert_true(mask_a == 15621670449_8, 'mask of A == 15621670449')
    call assert_true(text_glyph_mask(text_glyph_index('B')) == 32801506878_8, &
        'mask of B == 32801506878')
    call assert_true(text_glyph_mask(text_glyph_index('0')) == 15623448110_8, &
        'mask of 0 == 15623448110')
    call assert_true(text_glyph_mask(99) == text_glyph_mask(39), &
        'out-of-range mask index gives ? mask')

    ! 'A' top row (row 0) is columns 1,2,3 on and 0,4 off, asserted
    ! via the mask bits directly: bit (34 - (0*5 + col)).
    call assert_false(btest(mask_a, 34), 'A row 0 col 0 bit is off')
    call assert_true(btest(mask_a, 33), 'A row 0 col 1 bit is on')
    call assert_true(btest(mask_a, 32), 'A row 0 col 2 bit is on')
    call assert_true(btest(mask_a, 31), 'A row 0 col 3 bit is on')
    call assert_false(btest(mask_a, 30), 'A row 0 col 4 bit is off')
    ! 'A' bottom row (row 6) is #...#: bits (34 - (6*5 + col)).
    call assert_true(btest(mask_a, 4), 'A row 6 col 0 bit is on')
    call assert_false(btest(mask_a, 3), 'A row 6 col 1 bit is off')
    call assert_true(btest(mask_a, 0), 'A row 6 col 4 bit is on')

    ! ---- build: "A" triangle count == 2 * popcount(mask A) ----
    call text_build_mesh('A', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        7.0_dp, rgb, msh)
    call assert_int_eq(2 * int(popcnt(mask_a)), msh%num_triangles, &
        'build "A" triangles == 2 * popcount(mask A)')
    call assert_true(allocated(msh%triangles), 'build "A" mesh is allocated')
    call assert_int_eq(msh%num_triangles, size(msh%triangles), &
        'build "A" triangle array is allocated exactly')

    ! Colour and +Z normal on every triangle of "A".
    call assert_int_eq(10, msh%triangles(1)%color(1), 'build "A" tri 1 colour R == 10')
    call assert_int_eq(20, msh%triangles(1)%color(2), 'build "A" tri 1 colour G == 20')
    call assert_int_eq(30, msh%triangles(1)%color(3), 'build "A" tri 1 colour B == 30')
    all_plus_z = .true.
    do i = 1, msh%num_triangles
        if (abs(msh%triangles(i)%normal%x) > 1.0e-12_dp .or. &
            abs(msh%triangles(i)%normal%y) > 1.0e-12_dp .or. &
            abs(msh%triangles(i)%normal%z - 1.0_dp) > 1.0e-12_dp) &
            all_plus_z = .false.
    end do
    call assert_true(all_plus_z, 'build "A" all normals are (0,0,1)')

    ! Positions: "A" at origin, size 7 -> every vertex within
    ! x in [0,5], y in [0,7], z == 0.
    in_bounds = .true.
    do i = 1, msh%num_triangles
        do k = 1, 3
            if (msh%triangles(i)%v(k)%x < 0.0_dp .or. &
                msh%triangles(i)%v(k)%x > 5.0_dp .or. &
                msh%triangles(i)%v(k)%y < 0.0_dp .or. &
                msh%triangles(i)%v(k)%y > 7.0_dp .or. &
                abs(msh%triangles(i)%v(k)%z) > 1.0e-12_dp) in_bounds = .false.
        end do
    end do
    call assert_true(in_bounds, 'build "A" size 7 vertices within x[0,5] y[0,7] z==0')

    ! ---- ".." counts add (each '.' is counted twice) ----
    mask_dot = text_glyph_mask(text_glyph_index('.'))
    call text_build_mesh('..', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        7.0_dp, rgb, other_m)
    call assert_int_eq(4 * int(popcnt(mask_dot)), other_m%num_triangles, &
        'build ".." triangles == 2 chars * 2 tris * popcount(mask .)')

    ! ---- empty and space-only text ----
    call text_build_mesh('', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        7.0_dp, rgb, other_m)
    call assert_int_eq(0, other_m%num_triangles, 'build "" has 0 triangles')
    call text_build_mesh(' ', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        7.0_dp, rgb, other_m)
    call assert_int_eq(0, other_m%num_triangles, 'build " " has 0 triangles')

    ! ---- lowercase builds the same geometry as uppercase ----
    call text_build_mesh('a', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        7.0_dp, rgb, other_m)
    call assert_int_eq(msh%num_triangles, other_m%num_triangles, &
        'build "a" triangle count == build "A" triangle count')

    ! ---- unknown character builds the '?' glyph ----
    call text_build_mesh('#', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        7.0_dp, rgb, other_m)
    call assert_int_eq(2 * int(popcnt(text_glyph_mask(39))), &
        other_m%num_triangles, 'build "#" triangles == 2 * popcount(mask ?)')

    ! ---- origin offset shifts the geometry ----
    call text_build_mesh('A', vec3_create(10.0_dp, 20.0_dp, 3.0_dp), &
        7.0_dp, rgb, other_m)
    in_bounds = .true.
    do i = 1, other_m%num_triangles
        do k = 1, 3
            if (other_m%triangles(i)%v(k)%x < 10.0_dp .or. &
                other_m%triangles(i)%v(k)%x > 15.0_dp .or. &
                other_m%triangles(i)%v(k)%y < 20.0_dp .or. &
                other_m%triangles(i)%v(k)%y > 27.0_dp .or. &
                abs(other_m%triangles(i)%v(k)%z - 3.0_dp) > 1.0e-12_dp) &
                in_bounds = .false.
        end do
    end do
    call assert_true(in_bounds, &
        'build "A" at (10,20,3) vertices within x[10,15] y[20,27] z==3')

    ! ---- text_width ----
    call assert_real_close(11.0_dp, text_width('AB', 7.0_dp), 1.0e-12_dp, &
        'text_width("AB", 7) == 11')
    call assert_real_close(5.0_dp, text_width('A', 7.0_dp), 1.0e-12_dp, &
        'text_width("A", 7) == 5')
    call assert_real_close(0.0_dp, text_width('', 7.0_dp), 1.0e-12_dp, &
        'text_width("", 7) == 0')
    call assert_real_close(22.0_dp, text_width('AB', 14.0_dp), 1.0e-12_dp, &
        'text_width("AB", 14) == 22')

    ! ---- real-renderer visibility (regression: winding cull) ----
    ! Mirrors test_sprite.f90: render the built mesh with the REAL
    ! renderer (framebuffer_render_mesh / _mat + material_default)
    ! from the front (+Z side) and count lit pixels.  The glyph
    ! quads' winding must survive renderer_3d's screen-space
    ! backface cull; with the old order this rendered 0 pixels.
    identity = mat4_identity()
    mat = material_default()
    call assert_true(mat%use_tri_color, 'material_default uses per-triangle colour')
    call text_build_mesh('FORGE', vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
        3.0_dp, [255, 0, 0], other_m)
    call camera_init(cam, vec3_create(0.0_dp, 0.0_dp, 12.0_dp), &
                     vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 60.0_dp, &
                     64.0_dp / 48.0_dp, 0.1_dp, 100.0_dp)
    call framebuffer_init(fb, 64, 48)
    call framebuffer_render_mesh(fb, other_m, identity, cam, &
                                 vec3_create(-0.5_dp, -1.0_dp, -0.7_dp))
    n_lit = count_lit(fb)
    write(*, '(A, I0)') '       lit pixels (render_mesh, "FORGE" size 3): ', n_lit
    call assert_true(n_lit > 50, &
        'text renders > 50 lit pixels from front camera (render_mesh)')

    call framebuffer_init(fb, 64, 48)
    call framebuffer_render_mesh_mat(fb, other_m, identity, cam, &
                                     vec3_create(-0.5_dp, -1.0_dp, -0.7_dp), mat)
    n_lit = count_lit(fb)
    write(*, '(A, I0)') '       lit pixels (render_mesh_mat): ', n_lit
    call assert_true(n_lit > 50, &
        'text renders > 50 lit pixels via render_mesh_mat/material_default')

    call free_mesh(msh)
    call free_mesh(other_m)

    call test_summary()

contains

    ! Lit = colour-carrying, i.e. not the (25,25,35) background that
    ! framebuffer_init clears to.
    function count_lit(fb_in) result(n)
        type(FrameBuffer), intent(in) :: fb_in
        integer :: n, px, py
        n = 0
        do py = 1, fb_in%height
            do px = 1, fb_in%width
                if (fb_in%pixels(1, px, py) /= 25 .or. &
                    fb_in%pixels(2, px, py) /= 25 .or. &
                    fb_in%pixels(3, px, py) /= 35) then
                    n = n + 1
                end if
            end do
        end do
    end function count_lit

end program test_text_render
