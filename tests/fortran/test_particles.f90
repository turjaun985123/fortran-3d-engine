program test_particles
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use material_3d
    use particles_3d
    use test_assert
    implicit none

    type(ParticleSystem) :: sys, dflt, gsys, vsys
    type(Mesh) :: pmesh, pmesh2, vmesh
    type(vec3) :: pos, pos_b, centre, cam_pos, vcam_pos
    type(Camera) :: rcam
    type(FrameBuffer) :: fb
    type(Material) :: mat
    type(mat4) :: identity
    real(dp) :: u, u2, scale_out, scale_b, expected_dist
    integer :: i, k, tri, vtx, n_colour
    logical :: all_equal

    ! ---- frozen defaults ----
    call assert_int_eq(100, dflt%count, 'default count is 100')
    call assert_real_close(2.0_dp, dflt%life, 1.0e-12_dp, 'default life is 2.0')
    call assert_real_close(3.0_dp, dflt%speed, 1.0e-12_dp, 'default speed is 3.0')
    call assert_real_close(0.2_dp, dflt%size, 1.0e-12_dp, 'default size is 0.2')
    call assert_real_close(0.5_dp, dflt%spread, 1.0e-12_dp, 'default spread is 0.5')
    call assert_real_close(0.0_dp, dflt%gravity, 1.0e-12_dp, 'default gravity is 0.0')
    call assert_int_eq(1, dflt%seed, 'default seed is 1')
    call assert_int_eq(255, dflt%color(1), 'default colour R is 255')
    call assert_int_eq(180, dflt%color(2), 'default colour G is 180')
    call assert_int_eq(60, dflt%color(3), 'default colour B is 60')
    call assert_vec3_close(vec3_create(0.0_dp, 0.0_dp, 0.0_dp), dflt%origin, &
        1.0e-12_dp, 'default origin is (0,0,0)')

    ! ---- particle_hash01: range + determinism sweep ----
    do i = 0, 49
        do k = 0, 2
            u = particle_hash01(1, i, k)
            call assert_true(u >= 0.0_dp .and. u < 1.0_dp, &
                'hash01 stays in [0,1)')
            u2 = particle_hash01(1, i, k)
            call assert_true(u == u2, 'hash01 is deterministic (same inputs, same value)')
        end do
    end do
    ! A second seed also stays in range.
    do i = 0, 9
        u = particle_hash01(42, i, 1)
        call assert_true(u >= 0.0_dp .and. u < 1.0_dp, &
            'hash01 in [0,1) for seed 42')
    end do

    ! ---- particle_hash01: frozen recipe value ----
    ! Recipe (integer(int64), mod 2^31 at each step), seed=1, i=0, k=0:
    !   x = mod(1*1103515245 + 0 + 0, 2147483648) = 1103515245
    !   x = mod(1103515245*1103515245 + 12345, 2147483648) = 1117964962
    !   hash01 = 1117964962 / 2147483648 = 0.520593003369867801666259765625
    call assert_real_close(0.52059300336986780167_dp, particle_hash01(1, 0, 0), &
        1.0e-12_dp, 'hash01(1,0,0) matches the frozen recipe value')

    ! ---- particle_state: t = 0, i = 1 -> age 0 ----
    call particle_system_init(sys)
    sys%origin = vec3_create(1.0_dp, 2.0_dp, 3.0_dp)
    sys%count = 10
    call particle_state(sys, 1, 0.0_dp, pos, scale_out)
    call assert_vec3_close(sys%origin, pos, 1.0e-12_dp, &
        'particle_state t=0 i=1 pos == origin (age 0)')
    call assert_real_close(1.0_dp, scale_out, 1.0e-12_dp, &
        'particle_state t=0 i=1 scale == 1')

    ! ---- particle_state: age > 0 moves (default gravity 0, vy > 0) ----
    call particle_state(sys, 1, 0.5_dp, pos, scale_out)
    call assert_true(vec3_norm(vec3_sub(pos, sys%origin)) > 0.0_dp, &
        'particle_state at age>0 has moved from origin')
    call assert_true(pos%y > sys%origin%y, &
        'particle_state at age>0 rises (vy positive, gravity 0)')
    call assert_true(scale_out < 1.0_dp .and. scale_out > 0.0_dp, &
        'particle_state at age>0 scale in (0,1)')

    ! ---- particle_state: different i -> different pos ----
    call particle_state(sys, 2, 0.5_dp, pos_b, scale_b)
    call assert_true(abs(pos%x - pos_b%x) > 1.0e-12_dp .or. &
                     abs(pos%y - pos_b%y) > 1.0e-12_dp .or. &
                     abs(pos%z - pos_b%z) > 1.0e-12_dp, &
        'two different i give different pos at same t')

    ! ---- particle_state: opt-in gravity pulls y down ----
    gsys = sys
    gsys%gravity = 9.8_dp
    call particle_state(gsys, 1, 0.5_dp, pos_b, scale_b)
    call assert_true(pos_b%y < pos%y, &
        'gravity > 0 lowers y vs gravity 0 at same t')
    call assert_real_close(scale_out, scale_b, 1.0e-12_dp, &
        'gravity does not change scale_out')

    ! ---- particle_state: life <= 0 -> age 0, scale 0 ----
    gsys = sys
    gsys%life = 0.0_dp
    call particle_state(gsys, 1, 0.5_dp, pos_b, scale_b)
    call assert_real_close(0.0_dp, scale_b, 1.0e-12_dp, &
        'life <= 0 gives scale_out 0')
    call assert_vec3_close(sys%origin, pos_b, 1.0e-12_dp, &
        'life <= 0 gives pos == origin')

    ! ---- particles_build_mesh: count=10 at t=0.5 -> 20 triangles ----
    call particle_system_init(sys)
    sys%count = 10
    cam_pos = vec3_create(3.0_dp, 2.0_dp, 6.0_dp)
    call particles_build_mesh(sys, 0.5_dp, cam_pos, pmesh)
    call assert_int_eq(20, pmesh%num_triangles, &
        'build_mesh count=10 at t=0.5 gives exactly 20 triangles')
    call assert_int_eq(255, pmesh%triangles(1)%color(1), 'quad colour R is sys colour')
    call assert_int_eq(180, pmesh%triangles(1)%color(2), 'quad colour G is sys colour')
    call assert_int_eq(60, pmesh%triangles(1)%color(3), 'quad colour B is sys colour')

    ! ---- corner-to-centre distance for the first particle ----
    ! Quad side = size*scale; corners sit at half-side along both
    ! billboard axes, so |corner - centre| = side*sqrt(2)/2.
    call particle_state(sys, 1, 0.5_dp, centre, scale_out)
    expected_dist = (sys%size * scale_out) * sqrt(2.0_dp) / 2.0_dp
    do tri = 1, 2
        do vtx = 1, 3
            call assert_real_close(expected_dist, &
                vec3_norm(vec3_sub(pmesh%triangles(tri)%v(vtx), centre)), &
                1.0e-9_dp, 'quad corner distance == side*sqrt(2)/2')
        end do
    end do

    ! ---- determinism: build twice at same t -> identical vertices ----
    call particles_build_mesh(sys, 0.5_dp, cam_pos, pmesh2)
    call assert_int_eq(pmesh%num_triangles, pmesh2%num_triangles, &
        'rebuild at same t gives same triangle count')
    do tri = 1, pmesh%num_triangles
        all_equal = .true.
        do vtx = 1, 3
            if (pmesh%triangles(tri)%v(vtx)%x /= pmesh2%triangles(tri)%v(vtx)%x .or. &
                pmesh%triangles(tri)%v(vtx)%y /= pmesh2%triangles(tri)%v(vtx)%y .or. &
                pmesh%triangles(tri)%v(vtx)%z /= pmesh2%triangles(tri)%v(vtx)%z) &
                all_equal = .false.
        end do
        call assert_true(all_equal, 'rebuild at same t: identical vertex coords')
    end do

    call free_mesh(pmesh)
    call free_mesh(pmesh2)

    ! ---- real-renderer visibility (mirrors test_sprite.f90) ----
    ! Regression for the screen-space winding cull: with the old
    ! triangle order ([c_bl,c_tr,c_br]/[c_bl,c_tl,c_tr]) every
    ! particle quad was culled by renderer_3d and a particles scene
    ! rendered 0 particle pixels. The sprite-mirrored winding
    ! ([c_bl,c_br,c_tr]/[c_bl,c_tr,c_tl]) must pass the cull.
    ! Small system: count 10, size 0.5, t = 0.5, camera at
    ! (0,0,12) looking at the cloud centre (0,1.5,0); rendered
    ! through framebuffer_render_mesh_mat with material_default()
    ! (lambert, per-triangle colour) into 128x96 (sprite test's
    ! 64x48 at its size/distance; particle quads are smaller and
    ! farther, so the frame is scaled up 2x, same 4:3 aspect).
    call particle_system_init(vsys)
    vsys%count = 10
    vsys%size = 0.5_dp
    vcam_pos = vec3_create(0.0_dp, 0.0_dp, 12.0_dp)
    call particles_build_mesh(vsys, 0.5_dp, vcam_pos, vmesh)
    call assert_int_eq(20, vmesh%num_triangles, &
        'visibility system count=10 gives 20 triangles')
    mat = material_default()
    call assert_true(mat%use_tri_color, &
        'material_default uses per-triangle colour')
    identity = mat4_identity()
    call camera_init(rcam, vcam_pos, vec3_create(0.0_dp, 1.5_dp, 0.0_dp), &
                     60.0_dp, 128.0_dp / 96.0_dp, 0.1_dp, 100.0_dp)
    call framebuffer_init(fb, 128, 96)
    call framebuffer_render_mesh_mat(fb, vmesh, identity, rcam, &
                                     vec3_create(-0.5_dp, -1.0_dp, -0.7_dp), mat)
    n_colour = count_colour(fb)
    write(*, '(A, I0)') '       colour-carrying pixels (real renderer): ', n_colour
    call assert_true(n_colour > 50, &
        'particles render > 50 colour-carrying pixels via render_mesh_mat/material_default')
    call free_mesh(vmesh)

    call test_summary()

contains

    ! Colour-carrying = carries the system colour (255,180,60):
    ! clearly red-dominant over the (25,25,35) background. Lambert
    ! shading leaves the rendered pixel at ambient intensity
    ! (63,45,15) for these camera-facing quads, which still
    ! satisfies R > 50 and R > B + 20.
    function count_colour(fb_in) result(n)
        type(FrameBuffer), intent(in) :: fb_in
        integer :: n, px, py
        n = 0
        do py = 1, fb_in%height
            do px = 1, fb_in%width
                if (fb_in%pixels(1, px, py) > 50 .and. &
                    fb_in%pixels(1, px, py) > fb_in%pixels(3, px, py) + 20) then
                    n = n + 1
                end if
            end do
        end do
    end function count_colour

end program test_particles
