! test_shadow_v3.f90 -- tests for shadow_v3_3d (src/shadow_v3.f90),
! the v3.0 Phase 3 per-light shadow maps.
!
! Geometry shared by most scenes: a 20x20 ground plane at y = -1 and
! a 2x2x2 occluder cube centred at (0, 1, 0) (x,z in [-1,1], y in
! [0,2]).  Receivers sit on the ground (normal +Y) unless noted.
program test_shadow_v3
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d
    use camera_3d
    use lighting_3d
    use scene_3d
    use shadow_v3_3d
    use test_assert
    implicit none

    type(Scene) :: sc
    type(mat4) :: models(2)
    real(real32) :: f, f2, keep(6)
    real(real32) :: up3(3)

    up3 = [0.0_real32, 1.0_real32, 0.0_real32]

    ! ----------------------------------------------------------------
    ! Factor before any build: fully lit, and bad indices are lit.
    ! ----------------------------------------------------------------
    call shadow_v3_clear()
    f = shadow_v3_factor(1, [0.0_real32, -1.0_real32, 0.0_real32], up3)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        'pre-build: factor == 1 (no maps built)')
    f = shadow_v3_factor(0, [0.0_real32, -1.0_real32, 0.0_real32], up3)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        'pre-build: index 0 == 1')
    f = shadow_v3_factor(99, [0.0_real32, -1.0_real32, 0.0_real32], up3)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        'pre-build: index 99 == 1')

    ! ----------------------------------------------------------------
    ! (a) One directional light straight down: shadow under the cube.
    ! ----------------------------------------------------------------
    call make_geo_scene(sc, models)
    sc%shadow_mode = 1
    sc%shadow_size = 128
    sc%shadow_pcf = 1
    allocate(sc%lights%items(1))
    sc%lights%items(1) = dir_light([0.0_dp, -1.0_dp, 0.0_dp])
    call shadow_v3_build(sc, models)
    call assert_int_eq(128, shadow_v3_map_size, &
        '(a) map size follows sc%shadow_size (128)')

    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 0.0_dp, 1.0e-6_dp, &
        '(a) point under cube (light down) fully shadowed == 0')
    f = fac_at(1, 5.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(a) point beside cube fully lit == 1')
    f = fac_at(1, -5.0_dp, -1.0_dp, 3.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(a) far ground point lit == 1')
    f = fac_at(1, 0.9_dp, -1.0_dp, 0.9_dp)
    call assert_true(f < 0.01_real32, &
        '(a) point near cube corner still shadowed')
    ! Receiver ON the occluder top face: self-shadow must not acne.
    f = shadow_v3_factor(1, [0.0_real32, 2.0_real32, 0.0_real32], up3)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(a) cube top face is lit (no self-acne)')
    ! Receiver on the lit ground with an unnormalised normal.
    f = shadow_v3_factor(1, [5.0_real32, -1.0_real32, 0.0_real32], &
                         [0.0_real32, 7.0_real32, 0.0_real32])
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(a) unnormalised normal handled')
    ! A point far outside the fitted frustum is lit by rule.
    f = fac_at(1, 100.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(a) point outside shadow frustum == 1')
    call scene_free(sc)

    ! ----------------------------------------------------------------
    ! (b) TWO-LIGHT INDEPENDENCE (the L1 regression test).
    ! L1 travels (0,-1,0): footprint x,z in [-1,1].
    ! L2 travels (1,-1,0)/sqrt(2): footprint shifted +x, approx
    ! x in [1,4] at z = 0.  P_a = (-0.5,-1,0) is in L1's footprint
    ! only; P_b = (2.5,-1,0) is in L2's footprint only.
    ! ----------------------------------------------------------------
    call make_geo_scene(sc, models)
    sc%shadow_mode = 1
    sc%shadow_size = 256
    allocate(sc%lights%items(2))
    sc%lights%items(1) = dir_light([0.0_dp, -1.0_dp, 0.0_dp])
    sc%lights%items(2) = dir_light([1.0_dp, -1.0_dp, 0.0_dp])
    call shadow_v3_build(sc, models)

    f = fac_at(1, -0.5_dp, -1.0_dp, 0.0_dp)
    call assert_true(f < 0.01_real32, &
        '(b) L1: point A shadowed from light 1')
    f2 = fac_at(2, -0.5_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f2, dp), 1.0_dp, 1.0e-6_dp, &
        '(b) L2: point A lit from light 2 (independence)')
    f = fac_at(2, 2.5_dp, -1.0_dp, 0.0_dp)
    call assert_true(f < 0.01_real32, &
        '(b) L2: point B shadowed from light 2')
    f2 = fac_at(1, 2.5_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f2, dp), 1.0_dp, 1.0e-6_dp, &
        '(b) L1: point B lit from light 1 (independence, vice versa)')
    f = fac_at(1, 6.0_dp, -1.0_dp, 6.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(b) both-lit point: light 1 == 1')
    f = fac_at(2, 6.0_dp, -1.0_dp, 6.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(b) both-lit point: light 2 == 1')
    ! Swapping build order of queries must not change answers.
    keep(1) = fac_at(2, -0.5_dp, -1.0_dp, 0.0_dp)
    keep(2) = fac_at(1, -0.5_dp, -1.0_dp, 0.0_dp)
    call assert_true(keep(1) == 1.0_real32 .and. keep(2) == 0.0_real32, &
        '(b) query order does not matter (factor is read-only)')

    ! ----------------------------------------------------------------
    ! (f, part 1) Build twice with the same shape: identical factors
    ! (persistent allocation, no leak / no state corruption).
    ! ----------------------------------------------------------------
    keep(1) = fac_at(1, -0.5_dp, -1.0_dp, 0.0_dp)
    keep(2) = fac_at(2, -0.5_dp, -1.0_dp, 0.0_dp)
    keep(3) = fac_at(1, 2.5_dp, -1.0_dp, 0.0_dp)
    keep(4) = fac_at(2, 2.5_dp, -1.0_dp, 0.0_dp)
    keep(5) = fac_at(1, 6.0_dp, -1.0_dp, 6.0_dp)
    keep(6) = fac_at(2, 0.0_dp, -1.0_dp, 0.0_dp)
    call shadow_v3_build(sc, models)
    call assert_true(fac_at(1, -0.5_dp, -1.0_dp, 0.0_dp) == keep(1), &
        '(f) rebuild: factor 1/A identical')
    call assert_true(fac_at(2, -0.5_dp, -1.0_dp, 0.0_dp) == keep(2), &
        '(f) rebuild: factor 2/A identical')
    call assert_true(fac_at(1, 2.5_dp, -1.0_dp, 0.0_dp) == keep(3), &
        '(f) rebuild: factor 1/B identical')
    call assert_true(fac_at(2, 2.5_dp, -1.0_dp, 0.0_dp) == keep(4), &
        '(f) rebuild: factor 2/B identical')
    call assert_true(fac_at(1, 6.0_dp, -1.0_dp, 6.0_dp) == keep(5), &
        '(f) rebuild: factor 1/far identical')
    call assert_true(fac_at(2, 0.0_dp, -1.0_dp, 0.0_dp) == keep(6), &
        '(f) rebuild: factor 2/centre identical')

    ! ----------------------------------------------------------------
    ! (e) PCF: soft mode at the shadow boundary x = 1 (cube edge for
    ! the straight-down light) is strictly between hard 0 and 1.
    ! ----------------------------------------------------------------
    f = fac_at(1, 1.0_dp, -1.0_dp, 0.0_dp)   ! still mode 1 (hard)
    call assert_true(f == 0.0_real32 .or. f == 1.0_real32, &
        '(e) hard mode at boundary is binary (0 or 1)')
    sc%shadow_mode = 2
    sc%shadow_pcf = 2
    call shadow_v3_build(sc, models)
    f = fac_at(1, 1.0_dp, -1.0_dp, 0.0_dp)
    call assert_true(f > 0.0_real32 .and. f < 1.0_real32, &
        '(e) soft PCF at boundary strictly between 0 and 1')
    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 0.0_dp, 1.0e-6_dp, &
        '(e) soft PCF deep in shadow still == 0')
    f = fac_at(1, 5.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(e) soft PCF deep in light still == 1')
    ! Hard mode must ignore shadow_pcf (radius forced to 0).
    sc%shadow_mode = 1
    sc%shadow_pcf = 3
    call shadow_v3_build(sc, models)
    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 0.0_dp, 1.0e-6_dp, &
        '(e) hard mode with pcf=3: centre still binary 0')
    f = fac_at(1, 5.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(e) hard mode with pcf=3: lit point still binary 1')

    ! ----------------------------------------------------------------
    ! (f, part 2) shadow_mode = 0 builds nothing: all factors 1.
    ! ----------------------------------------------------------------
    sc%shadow_mode = 0
    call shadow_v3_build(sc, models)
    call assert_real_close(real(fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp), dp), &
        1.0_dp, 1.0e-6_dp, '(f) mode 0: shadowed point == 1')
    call assert_real_close(real(fac_at(2, 2.5_dp, -1.0_dp, 0.0_dp), dp), &
        1.0_dp, 1.0e-6_dp, '(f) mode 0: second light == 1')
    call assert_real_close(real(fac_at(1, 5.0_dp, -1.0_dp, 0.0_dp), dp), &
        1.0_dp, 1.0e-6_dp, '(f) mode 0: lit point == 1')
    call scene_free(sc)

    ! ----------------------------------------------------------------
    ! (c) Spot light at (0,5,0) pointing down, half-angle 45 deg.
    ! ----------------------------------------------------------------
    call make_geo_scene(sc, models)
    sc%shadow_mode = 1
    sc%shadow_size = 256
    allocate(sc%lights%items(1))
    sc%lights%items(1) = Light3()
    sc%lights%items(1)%kind = 2
    sc%lights%items(1)%pos = vec3_create(0.0_dp, 5.0_dp, 0.0_dp)
    sc%lights%items(1)%spot_dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
    sc%lights%items(1)%dir = sc%lights%items(1)%spot_dir
    sc%lights%items(1)%angle_deg = 45.0_dp
    sc%lights%items(1)%distance = 0.0_dp
    sc%lights%items(1)%decay = 0.0_dp
    call shadow_v3_build(sc, models)
    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_true(f < 0.01_real32, &
        '(c) spot: point under cube inside cone shadowed')
    f = fac_at(1, 4.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(c) spot: point inside cone but past cube shadow lit')
    f = fac_at(1, 10.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(c) spot: point outside cone unaffected == 1 (documented)')
    f = fac_at(1, 0.0_dp, -1.0_dp, 4.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(c) spot: inside cone, off-axis in z, lit == 1')
    call scene_free(sc)

    ! ----------------------------------------------------------------
    ! (d) Point light at (0,3,0); cube between it and the receiver
    ! below exercises the -Y cube face; side receivers use +/-X.
    ! ----------------------------------------------------------------
    call make_geo_scene(sc, models)
    sc%shadow_mode = 1
    sc%shadow_size = 256
    allocate(sc%lights%items(1))
    sc%lights%items(1) = Light3()
    sc%lights%items(1)%kind = 1
    sc%lights%items(1)%pos = vec3_create(0.0_dp, 3.0_dp, 0.0_dp)
    sc%lights%items(1)%distance = 0.0_dp
    sc%lights%items(1)%decay = 0.0_dp
    call shadow_v3_build(sc, models)
    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_true(f < 0.01_real32, &
        '(d) point: receiver below occluder shadowed (-Y face)')
    f = fac_at(1, 5.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(d) point: +X side receiver lit (+X face)')
    f = fac_at(1, -5.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(d) point: -X side receiver lit (-X face)')
    f = shadow_v3_factor(1, [5.0_real32, 3.0_real32, 0.0_real32], up3)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(d) point: receiver level with light, nothing between == 1')
    f = fac_at(1, 0.0_dp, -1.0_dp, 5.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        '(d) point: +Z side receiver lit (+Z face)')
    call scene_free(sc)

    ! ----------------------------------------------------------------
    ! Map-size clamp: a too-small request clamps to 64 and still
    ! produces a working map; clear() returns factors to 1.
    ! ----------------------------------------------------------------
    call make_geo_scene(sc, models)
    sc%shadow_mode = 1
    sc%shadow_size = 32
    allocate(sc%lights%items(1))
    sc%lights%items(1) = dir_light([0.0_dp, -1.0_dp, 0.0_dp])
    call shadow_v3_build(sc, models)
    call assert_int_eq(64, shadow_v3_map_size, &
        'clamp: shadow_size 32 clamps up to 64')
    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_true(f < 0.01_real32, &
        'clamp: 64px map still shadows under the cube')
    call shadow_v3_clear()
    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        'clear: factor back to 1 after shadow_v3_clear')
    call assert_int_eq(0, shadow_v3_map_size, &
        'clear: map size reset to 0')
    call scene_free(sc)

    ! Legacy-fields-only scene (no LightSet): build must synthesise
    ! the single directional light from sc%light_dir, as fragment_v3
    ! does.
    call make_geo_scene(sc, models)
    sc%shadow_mode = 1
    sc%shadow_size = 128
    sc%light_dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
    call shadow_v3_build(sc, models)
    f = fac_at(1, 0.0_dp, -1.0_dp, 0.0_dp)
    call assert_true(f < 0.01_real32, &
        'legacy fields: synthesised dir light shadows under cube')
    f = fac_at(1, 5.0_dp, -1.0_dp, 0.0_dp)
    call assert_real_close(real(f, dp), 1.0_dp, 1.0e-6_dp, &
        'legacy fields: synthesised dir light leaves side lit')
    call shadow_v3_clear()
    call scene_free(sc)

    call test_summary()

contains

    function dir_light(d) result(lt)
        real(dp), intent(in) :: d(3)
        type(Light3) :: lt
        lt = Light3()
        lt%kind = 0
        lt%dir = vec3_create(d(1), d(2), d(3))
        lt%spot_dir = lt%dir
    end function dir_light

    function fac_at(li, x, y, z) result(f)
        integer, intent(in) :: li
        real(dp), intent(in) :: x, y, z
        real(real32) :: f
        f = shadow_v3_factor(li, [real(x, real32), real(y, real32), &
                                  real(z, real32)], &
                             [0.0_real32, 1.0_real32, 0.0_real32])
    end function fac_at

    ! Ground plane (20x20 at y=-1) + cube (2^3 at (0,1,0)); models
    ! composed exactly as the renderer receives them.
    subroutine make_geo_scene(s, m)
        type(Scene), intent(out) :: s
        type(mat4), intent(out) :: m(2)
        s = Scene()
        call camera_init(s%cam, vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
                         vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                         60.0_dp, 1.0_dp, 0.1_dp, 100.0_dp)
        allocate(s%objects(2))
        s%n_objects = 2
        s%cap_objects = 2
        s%objects(1)%name = 'ground'
        s%objects(1)%prim = 'plane'
        s%objects(1)%dim_size = 20.0_dp
        s%objects(1)%pos = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
        call scene_build_object_mesh(s%objects(1))
        s%objects(2)%name = 'cube'
        s%objects(2)%prim = 'cube'
        s%objects(2)%dim_size = 2.0_dp
        s%objects(2)%pos = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        call scene_build_object_mesh(s%objects(2))
        m(1) = mat4_compose_trs(s%objects(1)%pos, s%objects(1)%rot_deg, &
                                s%objects(1)%scl)
        m(2) = mat4_compose_trs(s%objects(2)%pos, s%objects(2)%rot_deg, &
                                s%objects(2)%scl)
    end subroutine make_geo_scene

end program test_shadow_v3
