! test_renderer_v3.f90 -- v3.0 Phase 2 renderer (renderer_v3_3d).
!
! Covers: (a) single-triangle render, (b) perspective-correct
! interpolation probe (the R1 evidence: legacy has none), (c)
! top-left fill rule on a shared edge, (d) thread determinism
! (1 vs 8 threads, byte-identical buffers), (e) SSAA 2x changes
! edge pixels but not flat interior, (f) a single two-sided quad
! (prim 'plane') visible from behind -- the R4 retirement proof.
program test_renderer_v3
    use, intrinsic :: iso_fortran_env, only: real32, int32
    use math_3d
    use mesh_3d
    use camera_3d
    use scene_3d
    use material_3d
    use material_pbr_3d, only: pbr_from_material
    use renderer_v3_3d
    use renderer_3d, only: FrameBuffer, framebuffer_init
    use post_v3_3d, only: post_v3_apply, post_v3_tonemap_value, &
                          post_v3_srgb, post_v3_linear_to_byte
    use test_assert
    implicit none

    type(Scene) :: sc
    type(v3_buffer) :: vb, vb2
    type(mat4) :: models(1)
    integer :: x, y, cnt, cnt2, ndiff
    ! Phase 3 (post_v3) test state.
    type(FrameBuffer) :: fb3
    real(real32) :: buf3(3, 9, 9), ctl3(3, 9, 9)
    real(real32) :: prev3, cur3
    integer :: i3, b_lo, b_hi
    real(dp) :: mono_in(6)

    models(1) = mat4_identity()

    ! ---------- v3_perspective_interp unit checks ----------
    call assert_real_close( &
        v3_perspective_interp([1.0_dp, 0.0_dp, 0.0_dp], &
                              [0.25_dp, 0.5_dp, 0.75_dp], &
                              [0.5_dp, 0.5_dp, 0.5_dp]), &
        0.25_dp, 1.0e-12_dp, 'persp interp at corner 1 returns attr 1')
    call assert_real_close( &
        v3_perspective_interp([0.0_dp, 1.0_dp, 0.0_dp], &
                              [0.25_dp, 0.5_dp, 0.75_dp], &
                              [0.2_dp, 0.9_dp, 0.4_dp]), &
        0.5_dp, 1.0e-12_dp, 'persp interp at corner 2 returns attr 2')
    call assert_real_close( &
        v3_perspective_interp([1.0_dp/3.0_dp, 1.0_dp/3.0_dp, 1.0_dp/3.0_dp], &
                              [0.0_dp, 0.5_dp, 1.0_dp], &
                              [1.0_dp, 1.0_dp, 1.0_dp]), &
        0.5_dp, 1.0e-12_dp, 'persp interp with equal w equals affine mean')
    ! Unequal w: weights 0.5*1, 0.5*0.25 -> attr biased toward corner 1.
    call assert_real_close( &
        v3_perspective_interp([0.5_dp, 0.5_dp, 0.0_dp], &
                              [0.0_dp, 1.0_dp, 0.0_dp], &
                              [1.0_dp, 0.25_dp, 1.0_dp]), &
        0.2_dp, 1.0e-12_dp, 'persp interp weights by 1/w (0.25/1.25 = 0.2)')
    call assert_true(abs(v3_perspective_interp( &
        [0.5_dp, 0.5_dp, 0.0_dp], [0.0_dp, 1.0_dp, 0.0_dp], &
        [1.0_dp, 0.25_dp, 1.0_dp]) - 0.5_dp) > 0.1_dp, &
        'persp interp differs from affine for unequal w')

    ! ---------- (a) single triangle ----------
    call make_scene(sc, 64, 48)
    call set_object(sc, tri_mesh(), 'tris', &
                    material_from_name('basic', [1.0_dp, 0.0_dp, 0.0_dp], .true.))
    call v3_init(vb, 64, 48)
    call v3_render_scene(vb, sc, models, 1)
    cnt = count(vb%vis_tri /= 0_int32)
    call assert_true(cnt > 100, 'single triangle covers > 100 pixels')
    call assert_true(cnt < 2000, 'single triangle covers < 2000 pixels')
    call assert_int_eq(1, int(vb%vis_tri(32, 24)), &
        'centre pixel won by triangle 1')
    call assert_real_close(real(vb%rgb(1, 32, 24), dp), 1.0_dp, 0.02_dp, &
        'centre pixel R == 1 (basic red, unlit)')
    call assert_real_close(real(vb%rgb(2, 32, 24), dp), 0.0_dp, 0.02_dp, &
        'centre pixel G == 0')
    call assert_real_close(real(vb%rgb(3, 32, 24), dp), 0.0_dp, 0.02_dp, &
        'centre pixel B == 0')
    call assert_int_eq(0, int(vb%vis_tri(2, 2)), 'corner pixel is background')
    call assert_real_close(real(vb%rgb(1, 2, 2), dp), &
        25.0_dp / 255.0_dp, 0.01_dp, 'background pixel keeps scene bg')
    call assert_true(vb%depth(32, 24) > 0.0_real32, &
        'centre pixel depth (1/w) positive')
    call assert_true(vb%depth(2, 2) == 0.0_real32, &
        'background depth stays cleared (0)')
    call assert_true(abs(real(vb%lam(1, 32, 24), dp) &
        + real(vb%lam(2, 32, 24), dp)) <= 1.0_dp, 'lambdas in range')
    call scene_free(sc)
    call v3_free(vb)

    ! ---------- (b) perspective-correctness probe ----------
    call persp_probe()

    ! ---------- (c) fill rule: shared edge covered exactly once ----
    call make_scene(sc, 64, 64)
    call set_object(sc, quad_mesh_z(0.0_dp, .true.), 'tris', &
                    material_from_name('basic', [1.0_dp, 1.0_dp, 1.0_dp], .true.))
    call v3_init(vb, 64, 64)
    call v3_render_scene(vb, sc, models, 1)
    cnt = count(vb%vis_tri /= 0_int32)
    cnt2 = count(vb%cover == 1)
    call assert_true(cnt > 300, 'fill-rule quad covers > 300 pixels')
    call assert_int_eq(cnt, cnt2, &
        'every covered pixel covered exactly once (cover == 1)')
    call assert_int_eq(0, count(vb%cover > 1), &
        'no pixel covered twice (no double-draw on shared edge)')
    call assert_int_eq(0, count(vb%cover == 0 .and. vb%vis_tri /= 0_int32), &
        'no vis pixel without coverage')
    call assert_true(count(vb%vis_tri == 1_int32) > 100, &
        'first quad triangle present')
    call assert_true(count(vb%vis_tri == 2_int32) > 100, &
        'second quad triangle present')
    call scene_free(sc)
    call v3_free(vb)

    ! ---------- (d) thread determinism: 1 vs 8 threads ----------
    call make_scene(sc, 96, 72)
    block
        type(Mesh) :: cube
        call create_cube(cube, 2.0_dp)
        call set_object(sc, cube, 'cube', material_default())
    end block
    sc%objects(1)%rot_deg = vec3_create(20.0_dp, 35.0_dp, 0.0_dp)
    models(1) = mat4_compose_trs(sc%objects(1)%pos, &
                                 sc%objects(1)%rot_deg, &
                                 sc%objects(1)%scl)
    call v3_init(vb, 96, 72)
    call v3_render_scene(vb, sc, models, 1)
    call v3_init(vb2, 96, 72)
    call v3_render_scene(vb2, sc, models, 8)
    ndiff = count(vb%rgb /= vb2%rgb)
    call assert_int_eq(0, ndiff, 'threads 1 vs 8: RGB buffers identical')
    call assert_int_eq(0, count(vb%vis_tri /= vb2%vis_tri), &
        'threads 1 vs 8: visibility buffers identical')
    call assert_int_eq(0, count(vb%depth /= vb2%depth), &
        'threads 1 vs 8: depth buffers identical')
    call assert_int_eq(0, count(vb%lam /= vb2%lam), &
        'threads 1 vs 8: lambda buffers identical')
    call assert_true(count(vb%vis_tri /= 0_int32) > 500, &
        'determinism scene actually renders a cube')
    call scene_free(sc)
    call v3_free(vb)
    call v3_free(vb2)
    models(1) = mat4_identity()

    ! ---------- (e) SSAA 2x ----------
    call make_scene(sc, 64, 48)
    call set_object(sc, tri_mesh(), 'tris', &
                    material_from_name('basic', [1.0_dp, 0.0_dp, 0.0_dp], .true.))
    sc%antialias = 1
    call v3_init(vb, 64, 48)
    call v3_render_scene(vb, sc, models, 1)
    sc%antialias = 2
    call v3_init(vb2, 64, 48)
    call v3_render_scene(vb2, sc, models, 1)
    ndiff = 0
    do y = 1, 48
        do x = 1, 64
            if (any(vb%rgb(:, x, y) /= vb2%rgb(:, x, y))) ndiff = ndiff + 1
        end do
    end do
    call assert_true(ndiff > 0, 'SSAA 2x changes some (edge) pixels vs 1x')
    call assert_true(ndiff < 64 * 48 / 2, 'SSAA 2x leaves most pixels alone')
    call assert_true(all(vb%rgb(:, 32, 24) == vb2%rgb(:, 32, 24)), &
        'SSAA: flat interior pixel unchanged')
    call assert_true(all(vb%rgb(:, 2, 2) == vb2%rgb(:, 2, 2)), &
        'SSAA: background pixel unchanged')
    call scene_free(sc)
    call v3_free(vb)
    call v3_free(vb2)

    ! ---------- (f) double-sided quad from behind (R4) ----------
    call make_scene(sc, 64, 48)
    call set_object(sc, quad_mesh_z(0.0_dp, .false.), 'plane', &
                    material_from_name('basic', [0.0_dp, 1.0_dp, 0.0_dp], .true.))
    ! Camera in front (+z).
    call v3_init(vb, 64, 48)
    call v3_render_scene(vb, sc, models, 1)
    cnt = count(vb%vis_tri /= 0_int32)
    call assert_true(cnt > 200, 'two-sided quad visible from the front')
    ! Camera behind (-z), looking back at the origin.
    call camera_init(sc%cam, vec3_create(0.0_dp, 0.0_dp, -5.0_dp), &
                     vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 60.0_dp, &
                     64.0_dp / 48.0_dp, 0.1_dp, 100.0_dp)
    call v3_init(vb2, 64, 48)
    call v3_render_scene(vb2, sc, models, 1)
    cnt2 = count(vb2%vis_tri /= 0_int32)
    call assert_true(cnt2 > 200, &
        'single two-sided quad visible from BEHIND (no 4-tri workaround)')
    call assert_true( &
        (abs(real(vb2%rgb(2, 32, 24), dp) - 1.0_dp) < 0.02_dp &
         .and. real(vb2%rgb(1, 32, 24), dp) < 0.02_dp) .or. &
        (abs(real(vb2%rgb(1, 32, 24), dp) - 1.0_dp) < 0.02_dp &
         .and. real(vb2%rgb(2, 32, 24), dp) < 0.02_dp), &
        'back view centre pixel is a pure quad colour (red or green half)')
    call assert_true(cnt2 >= cnt - 50 .and. cnt2 <= cnt + 50, &
        'front/back coverage counts agree (same quad, both sides)')
    call scene_free(sc)
    call v3_free(vb)
    call v3_free(vb2)

    ! ================================================================
    ! Phase 3: post_v3 colour/output pipeline
    ! ================================================================
    call make_scene(sc, 64, 48)  ! defaults: tonemap 0, exposure 1, no post
    sc%tonemap_mode = 0
    sc%tonemap_exposure = 1.0_dp
    sc%n_post = 0
    sc%post_names = ''
    sc%post_amounts = 0.0_dp

    ! ---------- (a) sRGB encode: known linear -> known bytes ------
    call assert_int_eq(0, post_v3_linear_to_byte(0.0_real32), &
        'sRGB byte: linear 0.0 -> 0')
    call assert_int_eq(255, post_v3_linear_to_byte(1.0_real32), &
        'sRGB byte: linear 1.0 -> 255')
    call assert_int_eq(188, post_v3_linear_to_byte(0.5_real32), &
        'sRGB byte: linear 0.5 -> 188')
    call assert_int_eq(137, post_v3_linear_to_byte(0.25_real32), &
        'sRGB byte: linear 0.25 -> 137')
    call assert_int_eq(255, post_v3_linear_to_byte(4.0_real32), &
        'sRGB byte: linear > 1 clamps to 255')
    call assert_int_eq(0, post_v3_linear_to_byte(-1.0_real32), &
        'sRGB byte: negative linear clamps to 0')
    call assert_real_close(real(post_v3_srgb(0.5_real32), dp), &
        0.73536_dp, 0.001_dp, 'sRGB float: 0.5 linear -> 0.7354')
    call assert_real_close(real(post_v3_srgb(0.001_real32), dp), &
        0.01292_dp, 0.0001_dp, 'sRGB float: linear segment below 0.0031308')

    ! ---------- (b) Reinhard float stage ---------------------------
    call assert_real_close( &
        real(post_v3_tonemap_value(1, 1.0_real32, 1.0_real32), dp), &
        0.5_dp, 0.001_dp, 'Reinhard: 1.0 -> 0.5 pre-encode')
    call assert_real_close( &
        real(post_v3_tonemap_value(1, 0.0_real32, 1.0_real32), dp), &
        0.0_dp, 0.0001_dp, 'Reinhard: 0.0 -> 0.0')
    buf3 = 0.0_real32
    buf3(:, 5, 5) = 1.0_real32
    sc%tonemap_mode = 1
    call post_v3_apply(buf3, 9, 9, sc)
    call assert_real_close(real(buf3(1, 5, 5), dp), 0.5_dp, 0.001_dp, &
        'Reinhard via post_v3_apply: 1.0 -> 0.5 in the float buffer')
    call assert_int_eq(188, post_v3_linear_to_byte(buf3(1, 5, 5)), &
        'Reinhard 1.0 encoded -> byte 188')

    ! ---------- (c) ACES (Stephen Hill fit) ------------------------
    mono_in = [0.0_dp, 0.25_dp, 0.5_dp, 1.0_dp, 2.0_dp, 4.0_dp]
    prev3 = -1.0_real32
    do i3 = 1, size(mono_in)
        cur3 = post_v3_tonemap_value(2, real(mono_in(i3), real32), &
                                     1.0_real32)
        call assert_true(cur3 > prev3, 'ACES is strictly monotonic')
        prev3 = cur3
    end do
    call assert_true(abs(real(post_v3_tonemap_value( &
        2, 0.5_real32, 1.0_real32), dp) &
        - real(post_v3_tonemap_value(1, 0.5_real32, 1.0_real32), dp)) &
        > 0.02_dp, 'ACES(0.5) differs from Reinhard(0.5)')
    b_hi = post_v3_linear_to_byte(post_v3_tonemap_value( &
        2, 8.0_real32, 1.0_real32))
    call assert_true(b_hi < 255, 'ACES(8.0) encodes below 255 (no hard clip)')
    call assert_true(b_hi > 240, 'ACES(8.0) encodes above 240 (bright)')

    ! ---------- (d) HDR survival ----------------------------------
    ! Construct the float buffer directly: two HDR pixels, 2.0/4.0.
    buf3 = 0.0_real32
    buf3(:, 4, 5) = 2.0_real32
    buf3(:, 6, 5) = 4.0_real32
    call assert_true(buf3(1, 4, 5) > 1.0_real32 &
        .and. buf3(1, 6, 5) > 1.0_real32, &
        'HDR buffer holds values > 1 before post (float stage)')
    sc%tonemap_mode = 2
    call post_v3_apply(buf3, 9, 9, sc)
    b_lo = post_v3_linear_to_byte(buf3(1, 4, 5))
    b_hi = post_v3_linear_to_byte(buf3(1, 6, 5))
    call assert_true(b_lo < 255 .and. b_hi < 255, &
        'ACES maps HDR 2.0 and 4.0 below 255 (highlight not clipped)')
    call assert_true(b_hi > b_lo, &
        'ACES preserves HDR detail: byte(4.0) > byte(2.0), no flat blob')
    ! End-to-end: an HDR pixel through v3_quantize_to_fb (the hook).
    call v3_init(vb, 4, 4)
    vb%rgb = 0.0_real32
    vb%rgb(:, 2, 2) = 4.0_real32
    vb%vis_tri = 1_int32
    sc%tonemap_mode = 2
    sc%tonemap_exposure = 1.0_dp
    sc%n_post = 0
    call framebuffer_init(fb3, 4, 4)
    call v3_quantize_to_fb(vb, sc, fb3)
    call assert_int_eq(245, fb3%pixels(1, 2, 2), &
        'quantize hook: HDR 4.0 through ACES + sRGB -> byte 245')
    call assert_true(fb3%pixels(1, 1, 1) < 255, &
        'quantize hook: black HDR pixel stays below 255')
    deallocate(fb3%pixels, fb3%z_buffer)
    call v3_free(vb)

    ! ---------- (e) bloom ------------------------------------------
    buf3 = 0.0_real32
    buf3(:, 5, 5) = 4.0_real32  ! one super-bright pixel
    ctl3 = buf3
    sc%tonemap_mode = 0
    sc%tonemap_exposure = 1.0_dp
    sc%n_post = 1
    sc%post_names(1) = 'bloom'
    sc%post_amounts(1) = 1.0_dp
    call post_v3_apply(buf3, 9, 9, sc)
    call assert_true(buf3(1, 6, 5) > ctl3(1, 6, 5) + 0.1_real32, &
        'bloom: horizontal neighbour gains energy from bright pixel')
    call assert_true(buf3(1, 5, 6) > ctl3(1, 5, 6) + 0.1_real32, &
        'bloom: vertical neighbour gains energy from bright pixel')
    call assert_true(buf3(1, 5, 5) > ctl3(1, 5, 5), &
        'bloom: bright centre gains additive energy')
    call assert_true(buf3(1, 1, 1) == ctl3(1, 1, 1), &
        'bloom: far corner outside blur radius unchanged')
    ! Control: same buffer, no bloom in the chain -> unchanged.
    sc%n_post = 0
    call post_v3_apply(ctl3, 9, 9, sc)
    call assert_true(ctl3(1, 6, 5) == 0.0_real32 &
        .and. ctl3(1, 5, 5) == 4.0_real32, &
        'no-bloom control buffer is unchanged by post_v3_apply')
    ! Bloom amount 0 -> no change.
    buf3 = 0.0_real32
    buf3(:, 5, 5) = 4.0_real32
    ctl3 = buf3
    sc%n_post = 1
    sc%post_amounts(1) = 0.0_dp
    call post_v3_apply(buf3, 9, 9, sc)
    call assert_true(all(buf3 == ctl3), 'bloom amount 0 -> no change')

    ! ---------- (f) exposure scales monotonically ------------------
    call assert_true(post_v3_linear_to_byte(post_v3_tonemap_value( &
        0, 0.25_real32, 2.0_real32)) &
        > post_v3_linear_to_byte(post_v3_tonemap_value( &
        0, 0.25_real32, 1.0_real32)), &
        'exposure 2x brightens output (mode 0, via bytes)')
    prev3 = -1.0_real32
    do i3 = 1, 4
        cur3 = post_v3_tonemap_value(1, 0.5_real32, &
                                     real(i3, real32) * 0.5_real32)
        call assert_true(cur3 > prev3, &
            'exposure scales Reinhard output monotonically')
        prev3 = cur3
    end do
    call assert_real_close( &
        real(post_v3_tonemap_value(0, 0.25_real32, 2.0_real32), dp), &
        0.5_dp, 0.0001_dp, 'mode 0 is exposure only: 0.25 * 2 = 0.5')
    call scene_free(sc)

    call test_summary()

contains

    subroutine make_scene(s, w, h)
        type(Scene), intent(inout) :: s
        integer, intent(in) :: w, h
        s%width = w
        s%height = h
        s%bg = [25, 25, 35]
        s%antialias = 1
        call camera_init(s%cam, vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
                         vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 60.0_dp, &
                         real(w, dp) / real(h, dp), 0.1_dp, 100.0_dp)
    end subroutine make_scene

    subroutine set_object(s, m, prim, mat)
        type(Scene), intent(inout) :: s
        type(Mesh), intent(in) :: m
        character(len=*), intent(in) :: prim
        type(Material), intent(in) :: mat
        allocate(s%objects(1))
        s%n_objects = 1
        s%cap_objects = 1
        s%objects(1)%prim = prim
        s%objects(1)%name = 'obj1'
        s%objects(1)%mesh = m
        s%objects(1)%mat = mat
        s%objects(1)%pbr = pbr_from_material(mat, 0.0_dp, 1.0_dp)
    end subroutine set_object

    ! One front-facing (positive y-down screen area) red triangle.
    function tri_mesh() result(m)
        type(Mesh) :: m
        allocate(m%triangles(1))
        m%num_triangles = 1
        m%triangles(1)%v(1) = vec3_create(-1.0_dp, -1.0_dp, 0.0_dp)
        m%triangles(1)%v(2) = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        m%triangles(1)%v(3) = vec3_create(1.0_dp, -1.0_dp, 0.0_dp)
        m%triangles(1)%normal = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
        m%triangles(1)%vn = [vec3_create(0.0_dp, 0.0_dp, 1.0_dp), &
                             vec3_create(0.0_dp, 0.0_dp, 1.0_dp), &
                             vec3_create(0.0_dp, 0.0_dp, 1.0_dp)]
        m%triangles(1)%color = [255, 0, 0]
        m%triangles(1)%material_id = 1
        m%triangles(1)%uv = 0.0_dp
    end function tri_mesh

    ! Quad A(-1,-1) B(1,-1) C(1,1) D(-1,1) at depth z, split A-D-C /
    ! A-C-B.  With uvgrad, UVs run (0,0),(1,0),(1,1),(0,1) and the
    ! far edge (C,D) sits at z - 3 (receding) for the persp probe;
    ! without it the quad is flat at z and tri colours differ.
    function quad_mesh_z(z, uvgrad) result(m)
        real(dp), intent(in) :: z
        logical, intent(in) :: uvgrad
        type(Mesh) :: m
        type(vec3) :: a, b, c, d, n
        real(dp) :: zf
        a = vec3_create(-1.0_dp, -1.0_dp, z)
        b = vec3_create(1.0_dp, -1.0_dp, z)
        zf = z
        if (uvgrad) zf = z - 3.0_dp
        c = vec3_create(1.0_dp, 1.0_dp, zf)
        d = vec3_create(-1.0_dp, 1.0_dp, zf)
        n = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
        allocate(m%triangles(2))
        m%num_triangles = 2
        m%triangles(1)%v = [a, d, c]
        m%triangles(2)%v = [a, c, b]
        m%triangles(1)%normal = n
        m%triangles(2)%normal = n
        m%triangles(1)%vn = [n, n, n]
        m%triangles(2)%vn = [n, n, n]
        m%triangles(1)%color = [255, 0, 0]
        m%triangles(2)%color = [0, 255, 0]
        m%triangles(1)%material_id = 1
        m%triangles(2)%material_id = 1
        m%triangles(1)%uv(:, 1) = [0.0_dp, 0.0_dp]
        m%triangles(1)%uv(:, 2) = [0.0_dp, 1.0_dp]
        m%triangles(1)%uv(:, 3) = [1.0_dp, 1.0_dp]
        m%triangles(2)%uv(:, 1) = [0.0_dp, 0.0_dp]
        m%triangles(2)%uv(:, 2) = [1.0_dp, 1.0_dp]
        m%triangles(2)%uv(:, 3) = [1.0_dp, 0.0_dp]
    end function quad_mesh_z

    ! (b) Find the covered pixel where perspective-correct and affine
    ! UV differ most (computed independently here in real64 from the
    ! camera matrices), then check the renderer's interpolated UV
    ! against the perspective value -- and against the affine one.
    subroutine persp_probe()
        type(Scene) :: s2
        type(v3_buffer) :: v2
        type(mat4) :: mvp
        type(vec3) :: corners(4)
        real(dp) :: uv_c(2, 4), scr(2, 4), invw_c(4)
        real(dp) :: p(2), lam(3), den, puv(2), auv(2), best, diff
        integer :: bx, by, t, k, tri_idx(3, 2)
        real(dp) :: buv(2), bauv(2)

        call make_scene(s2, 64, 64)
        call set_object(s2, quad_mesh_z(0.0_dp, .true.), 'tris', &
                        material_from_name('basic', &
                            [1.0_dp, 1.0_dp, 1.0_dp], .true.))
        call v3_init(v2, 64, 64)
        call v3_render_scene(v2, s2, models, 1)
        call assert_true(count(v2%vis_tri /= 0_int32) > 300, &
            'persp probe quad renders')

        corners(1) = vec3_create(-1.0_dp, -1.0_dp, 0.0_dp)
        corners(2) = vec3_create(1.0_dp, -1.0_dp, 0.0_dp)
        corners(3) = vec3_create(1.0_dp, 1.0_dp, -3.0_dp)
        corners(4) = vec3_create(-1.0_dp, 1.0_dp, -3.0_dp)
        uv_c(:, 1) = [0.0_dp, 0.0_dp]
        uv_c(:, 2) = [1.0_dp, 0.0_dp]
        uv_c(:, 3) = [1.0_dp, 1.0_dp]
        uv_c(:, 4) = [0.0_dp, 1.0_dp]
        tri_idx(:, 1) = [1, 4, 3]
        tri_idx(:, 2) = [1, 3, 2]
        mvp = mat4_mult(s2%cam%proj_matrix, s2%cam%view_matrix)
        do k = 1, 4
            block
                type(vec3) :: ndcv
                ndcv = mat4_transform_vec3(mvp, corners(k), .true.)
                scr(1, k) = (ndcv%x + 1.0_dp) * 0.5_dp * 64.0_dp
                scr(2, k) = (1.0_dp - (ndcv%y + 1.0_dp) * 0.5_dp) * 64.0_dp
                invw_c(k) = 1.0_dp / (mvp%m(4, 1) * corners(k)%x &
                            + mvp%m(4, 2) * corners(k)%y &
                            + mvp%m(4, 3) * corners(k)%z + mvp%m(4, 4))
            end block
        end do

        best = -1.0_dp
        bx = 0
        by = 0
        buv = 0.0_dp
        bauv = 0.0_dp
        do y = 1, 64
            do x = 1, 64
                if (v2%vis_tri(x, y) == 0_int32) cycle
                p = [real(x, dp) - 0.5_dp, real(y, dp) - 0.5_dp]
                do t = 1, 2
                    den = (scr(2, tri_idx(2, t)) - scr(2, tri_idx(3, t))) &
                        * (scr(1, tri_idx(1, t)) - scr(1, tri_idx(3, t))) &
                        + (scr(1, tri_idx(3, t)) - scr(1, tri_idx(2, t))) &
                        * (scr(2, tri_idx(1, t)) - scr(2, tri_idx(3, t)))
                    if (abs(den) < 1.0e-12_dp) cycle
                    lam(1) = ((scr(2, tri_idx(2, t)) - scr(2, tri_idx(3, t))) &
                        * (p(1) - scr(1, tri_idx(3, t))) &
                        + (scr(1, tri_idx(3, t)) - scr(1, tri_idx(2, t))) &
                        * (p(2) - scr(2, tri_idx(3, t)))) / den
                    lam(2) = ((scr(2, tri_idx(3, t)) - scr(2, tri_idx(1, t))) &
                        * (p(1) - scr(1, tri_idx(3, t))) &
                        + (scr(1, tri_idx(1, t)) - scr(1, tri_idx(3, t))) &
                        * (p(2) - scr(2, tri_idx(3, t)))) / den
                    lam(3) = 1.0_dp - lam(1) - lam(2)
                    if (minval(lam) < -1.0e-9_dp) cycle
                    do k = 1, 2
                        puv(k) = v3_perspective_interp(lam, &
                            uv_c(k, tri_idx(:, t)), invw_c(tri_idx(:, t)))
                        auv(k) = sum(lam * uv_c(k, tri_idx(:, t)))
                    end do
                    diff = abs(puv(1) - auv(1)) + abs(puv(2) - auv(2))
                    if (diff > best) then
                        best = diff
                        bx = x
                        by = y
                        buv = puv
                        bauv = auv
                    end if
                end do
            end do
        end do
        call assert_true(bx > 0, 'persp probe found a covered pixel')
        call assert_true(best > 0.05_dp, &
            'persp vs affine UV differ materially at probe pixel (> 0.05)')
        call assert_real_close(real(v2%uv_dbg(1, bx, by), dp), buv(1), &
            0.02_dp, 'renderer UV u matches perspective-correct value')
        call assert_real_close(real(v2%uv_dbg(2, bx, by), dp), buv(2), &
            0.02_dp, 'renderer UV v matches perspective-correct value')
        call assert_true(abs(real(v2%uv_dbg(1, bx, by), dp) - bauv(1)) &
            + abs(real(v2%uv_dbg(2, bx, by), dp) - bauv(2)) > 0.03_dp, &
            'renderer UV is NOT the affine value (R1: legacy fails this)')
        call scene_free(s2)
        call v3_free(v2)
    end subroutine persp_probe

end program test_renderer_v3
