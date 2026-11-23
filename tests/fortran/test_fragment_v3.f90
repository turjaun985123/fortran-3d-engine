! test_fragment_v3.f90 -- tests for fragment_v3_3d (src/fragment_v3.f90),
! the v3.0 single fragment stage that collapses the legacy
! renderer's _mat / _env / _shader paths.
!
! Phase 3 update: the lit stages no longer delegate to shade_rgb.
! The v3 model is energy-conserving Lambert (BRDF albedo/pi against
! irradiance pi*intensity*colour, so per-light diffuse matches the
! legacy scale) + GGX specular, per-light shadow factors via
! shadow_v3_3d, and hemisphere ambient (sky = ambient colour,
! ground = 0.3 * sky, mix by n.y).  The legacy (1 - ambient)
! weighting is RETIRED on the v3 path, so a fully lit up-facing
! fragment is (1 + ambient) x the legacy value: at ambient 0.25
! that is a factor 1.25, and several Phase 2 expectations below
! changed by exactly that factor (each is flagged in its message).
! Down-facing fragments now get 0.3 x the old flat ambient
! (hemisphere ground), a zero normal 0.65 x.  Results are real32
! linear with NO quantisation and NO clamp (HDR values > 1 are
! asserted directly).
!
! Scenes are built in-program (no scene_load): a ground-plane object
! and one coloured object under a key directional light travelling
! -Y (so L = +Y and an up normal gives diffuse exactly 1), ambient
! 0.25 -- the legacy-equivalence configuration of lighting.f90.
! Base colour (0.8, 0.4, 0.2).
program test_fragment_v3
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d
    use camera_3d
    use material_3d
    use material_pbr_3d
    use lighting_3d
    use shader_3d
    use scene_3d
    use shadow_v3_3d
    use fragment_v3_3d
    use test_assert
    implicit none

    real(real32) :: rgb(3), rgb_front(3), rgb_away(3), rgb_exp(3)
    type(frag_in) :: fin
    integer :: k

    ! Scenes used below.
    type(Scene) :: sc        ! plain: legacy light fields only
    type(Scene) :: sc_tex    ! object 2 carries a 2x2 checker texture
    type(Scene) :: sc_sh     ! shader defs 1='0.75', 2='u', 3='v'
    type(Scene) :: sc_env    ! object 2 is a standard (PBR) material
    type(Scene) :: sc_fog    ! linear fog 0..10, white
    type(Scene) :: sc_multi  ! LightSet with dir + point light
    type(Scene) :: sc_amb    ! ambient 0 (sc) variants built inline
    type(Scene) :: sc_pbr    ! standard PBR: GGX roughness / metal tests
    type(Scene) :: sc_hdr    ! intensity-3 light (HDR test)
    type(Scene) :: sc_hemi   ! light intensity 0: hemisphere ambient only
    type(Scene) :: sc_sh2    ! two directional lights + cube occluder

    real(real32) :: rgb2(3), rgb3(3)
    type(mat4) :: models_sh(2)
    real(real32) :: fA, fB
    real(dp) :: unshad, shad_exp

    ! Cross-check fixtures (lighting_3d called directly).
    type(LightSet) :: lights
    type(MaterialPBR) :: pbr_lam
    integer :: base_i(3), lit_i(3)

    logical :: ok
    character(len=256) :: errmsg
    character(len=16) :: toks(1)
    type(ShaderProg) :: prog

    ! ----------------------------------------------------------------
    ! Scene builders
    ! ----------------------------------------------------------------
    call build_base_scene(sc)
    call build_base_scene(sc_tex)
    call build_base_scene(sc_sh)
    call build_base_scene(sc_env)
    call build_base_scene(sc_fog)
    call build_base_scene(sc_multi)

    ! Checker texture on sc_tex object 2: 2x2, top row red/green,
    ! bottom row blue/white (texture_3d: v=1 is the TOP row).
    associate (o => sc_tex%objects(2))
        o%tex%w = 2
        o%tex%h = 2
        allocate(o%tex%pixels(3, 2, 2))
        o%tex%pixels(:, 1, 1) = [255, 0, 0]      ! top-left red
        o%tex%pixels(:, 2, 1) = [0, 255, 0]      ! top-right green
        o%tex%pixels(:, 1, 2) = [0, 0, 255]      ! bottom-left blue
        o%tex%pixels(:, 2, 2) = [255, 255, 255]  ! bottom-right white
        o%tex%loaded = .true.
    end associate

    ! Shader defs for sc_sh.
    allocate(sc_sh%shader_defs(3))
    sc_sh%shader_defs(1)%name = 'const75'
    toks(1) = '0.75'
    call shader_parse(toks, prog, ok, errmsg)
    call assert_true(ok, 'shader_parse 0.75 ok')
    sc_sh%shader_defs(1)%prog = prog
    sc_sh%shader_defs(2)%name = 'passu'
    toks(1) = 'u'
    call shader_parse(toks, prog, ok, errmsg)
    call assert_true(ok, 'shader_parse u ok')
    sc_sh%shader_defs(2)%prog = prog
    sc_sh%shader_defs(3)%name = 'passv'
    toks(1) = 'v'
    call shader_parse(toks, prog, ok, errmsg)
    call assert_true(ok, 'shader_parse v ok')
    sc_sh%shader_defs(3)%prog = prog

    ! sc_env object 2 becomes a standard PBR material (smooth, low
    ! roughness so the GGX highlight is strong when n = v = L).
    sc_env%objects(2)%mat_name = 'standard'
    sc_env%objects(2)%pbr = pbr_standard([0.5_dp, 0.5_dp, 0.5_dp], &
                                         0.0_dp, 0.05_dp)

    ! Fog scene: camera looks -Z from (0,0,5); origin is at view
    ! depth 5, fog near 0 / far 10 -> factor exactly 0.5 there.
    sc_fog%fog_mode = 1
    sc_fog%fog_near = 0.0_dp
    sc_fog%fog_far = 10.0_dp
    sc_fog%fog_color = [255, 255, 255]

    ! Multi-light scene: sc%lights as scene_load would assemble it,
    ! plus a decay-0 point light 2 units above the origin.
    allocate(sc_multi%lights%items(2))
    sc_multi%lights%ambient = sc_multi%ambient
    sc_multi%lights%ambient_color = [255, 255, 255]
    sc_multi%lights%items(1) = Light3()
    sc_multi%lights%items(1)%kind = 0
    sc_multi%lights%items(1)%dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
    sc_multi%lights%items(2) = Light3()
    sc_multi%lights%items(2)%kind = 1
    sc_multi%lights%items(2)%pos = vec3_create(0.0_dp, 2.0_dp, 0.0_dp)
    sc_multi%lights%items(2)%decay = 0.0_dp
    sc_multi%lights%items(2)%distance = 0.0_dp

    ! Default fragment: origin, up normal, base (0.8, 0.4, 0.2),
    ! coloured object 2.
    fin%wp = [0.0_real32, 0.0_real32, 0.0_real32]
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    fin%uv = [0.0_real32, 0.0_real32]
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]
    fin%mat_id = 0
    fin%obj_id = 2
    fin%shader_id = 0
    fin%backface = .false.

    ! ----------------------------------------------------------------
    ! (a) Diffuse response: Lambert factor vs the key light
    ! ----------------------------------------------------------------
    call frag_shade(fin, sc, rgb_front)
    ! Phase 3: (1 - ambient) retired -> fully lit up-facing result
    ! is base * (1 + ambient) = base * 1.25 (was base * 1 in Phase 2).
    call assert_real_close(real(rgb_front(1), dp), 0.8_dp * 1.25_dp, &
        0.005_dp, '(a) facing light: R == base * 1.25 (Phase 3 exposure)')
    call assert_real_close(real(rgb_front(2), dp), 0.4_dp * 1.25_dp, &
        0.005_dp, '(a) facing light: G == base * 1.25 (Phase 3 exposure)')
    call assert_real_close(real(rgb_front(3), dp), 0.2_dp * 1.25_dp, &
        0.005_dp, '(a) facing light: B == base * 1.25 (Phase 3 exposure)')

    fin%nrm = [0.0_real32, -1.0_real32, 0.0_real32]
    call frag_shade(fin, sc, rgb_away)
    do k = 1, 3
        call assert_true(rgb_front(k) > rgb_away(k), &
            '(a) facing fragment brighter than facing-away, per channel')
    end do

    ! 60 degrees off the light: diffuse = 0.5.  Phase 3 total =
    ! direct 0.5 + hemisphere ambient 0.25 * mix(n.y=0.5) where
    ! mix = 0.3 + 0.7 * 0.75 = 0.825 -> 0.5 + 0.20625 = 0.70625
    ! (Phase 2 legacy value was 0.625).
    fin%nrm = [0.0_real32, 0.5_real32, real(sqrt(0.75_dp), real32)]
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), 0.8_dp * 0.70625_dp, &
        0.01_dp, '(a) diffuse 0.5: R == base * 0.70625 (Phase 3)')
    call assert_real_close(real(rgb(2), dp), 0.4_dp * 0.70625_dp, &
        0.01_dp, '(a) diffuse 0.5: G == base * 0.70625 (Phase 3)')
    call assert_real_close(real(rgb(3), dp), 0.2_dp * 0.70625_dp, &
        0.01_dp, '(a) diffuse 0.5: B == base * 0.70625 (Phase 3)')

    ! Unnormalised interpolated normal must shade like its direction.
    fin%nrm = [0.0_real32, 3.0_real32, 0.0_real32]
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), real(rgb_front(1), dp), &
        0.005_dp, '(a) normal (0,3,0) shades as (0,1,0)')

    ! Cross-check against lighting_3d's shade_rgb computed directly
    ! (the frozen legacy helper), same inputs.  Phase 2 asserted
    ! equality within 1/255; Phase 3's documented exposure delta at
    ! this configuration is exactly (1 + ambient) = 1.25, so the
    ! assertion is now v3 == 1.25 * legacy (per channel, tol 0.01).
    allocate(lights%items(1))
    lights%ambient = 0.25_dp
    lights%ambient_color = [255, 255, 255]
    lights%items(1) = Light3()
    lights%items(1)%kind = 0
    lights%items(1)%dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
    pbr_lam = pbr_default()
    base_i = [204, 102, 51]
    lit_i = shade_rgb(base_i, vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                      vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                      vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
                      lights, pbr_lam, 1.0_dp)
    do k = 1, 3
        call assert_true(abs(real(rgb_front(k), dp) - &
                             1.25_dp * real(lit_i(k), dp) &
                             / 255.0_dp) <= 0.01_dp, &
            '(a) frag_shade == 1.25 * shade_rgb (Phase 3 exposure delta)')
    end do

    ! ----------------------------------------------------------------
    ! (b) Ambient floor
    ! ----------------------------------------------------------------
    ! Facing away: diffuse 0, result = hemisphere ambient only.
    ! Phase 3: a DOWN-facing normal samples the hemisphere GROUND
    ! colour = 0.3 * sky, so the floor is ambient * 0.3 * base
    ! (Phase 2 asserted the flat ambient * base).
    call assert_real_close(real(rgb_away(1), dp), 0.8_dp * 0.075_dp, &
        0.01_dp, '(b) back-facing R == ambient * 0.3 * base (hemi ground)')
    call assert_real_close(real(rgb_away(2), dp), 0.4_dp * 0.075_dp, &
        0.01_dp, '(b) back-facing G == ambient * 0.3 * base (hemi ground)')
    call assert_real_close(real(rgb_away(3), dp), 0.2_dp * 0.075_dp, &
        0.01_dp, '(b) back-facing B == ambient * 0.3 * base (hemi ground)')
    call assert_true(all(rgb_away > 0.0_real32), &
        '(b) ambient floor keeps a back-facing fragment non-black')

    ! Zero normal (degenerate interpolation): no diffuse anywhere;
    ! the hemisphere mix sits at t = 0.5 -> 0.65 * sky, so the
    ! floor is ambient * 0.65 * base (Phase 2: flat ambient * base).
    fin%nrm = [0.0_real32, 0.0_real32, 0.0_real32]
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), 0.8_dp * 0.1625_dp, &
        0.01_dp, '(b) zero normal: hemisphere mid ambient only')

    ! Ambient = 0 removes the floor entirely.
    sc_amb = sc
    sc_amb%ambient = 0.0_dp
    if (allocated(sc_amb%lights%items)) &
        deallocate(sc_amb%lights%items)
    fin%nrm = [0.0_real32, -1.0_real32, 0.0_real32]
    call frag_shade(fin, sc_amb, rgb)
    call assert_true(all(abs(rgb) < 1.0e-6_real32), &
        '(b) ambient 0 + facing away == black')

    ! Basic material (mat_id 1, no object) is unlit: even facing
    ! away it returns the base colour (legacy _mat mode 1).
    fin%obj_id = 0
    fin%mat_id = 1
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), 0.8_dp, 0.005_dp, &
        '(b) basic material unlit: R == base facing away')
    call assert_real_close(real(rgb(2), dp), 0.4_dp, 0.005_dp, &
        '(b) basic material unlit: G == base facing away')
    fin%mat_id = 0
    fin%obj_id = 2

    ! ----------------------------------------------------------------
    ! Shared accumulation: a second (point) light adds its diffuse
    ! through the same accumulation loop -- grey 0.4 base.  Phase 3
    ! (unweighted lights): (0.25 ambient + 1 dir + 1 point) * 0.4
    ! = 0.9 (Phase 2, with the (1 - ambient) weighting, was 0.7).
    ! ----------------------------------------------------------------
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    fin%col = [0.4_real32, 0.4_real32, 0.4_real32]
    call frag_shade(fin, sc_multi, rgb)
    call assert_real_close(real(rgb(1), dp), 0.9_dp, 0.01_dp, &
        'multi-light: dir + point diffuse accumulate (0.9, Phase 3)')
    call frag_shade(fin, sc, rgb_exp)
    call assert_real_close(real(rgb_exp(1), dp), 0.5_dp, 0.005_dp, &
        'multi-light control: dir only gives 0.5 (Phase 3)')
    call assert_true(rgb(1) > rgb_exp(1), &
        'multi-light result brighter than single-light control')
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]

    ! ----------------------------------------------------------------
    ! (c) Texture stage: checker squares replace the base colour
    ! ----------------------------------------------------------------
    ! fin%col is grey here on purpose: the legacy env rule replaces
    ! it with the texel.  Normal faces the light (lit factor 1.25
    ! in Phase 3, see below).
    fin%obj_id = 2
    fin%col = [0.5_real32, 0.5_real32, 0.5_real32]
    ! Phase 3: the fragment faces the light with an up normal, so
    ! the lit factor is (1 + ambient) = 1.25 and a texel channel of
    ! 1 comes out at 1.25 (Phase 2 asserted 1.0).
    fin%uv = [0.25_real32, 0.75_real32]  ! top-left: red
    call frag_shade(fin, sc_tex, rgb)
    call assert_real_close(real(rgb(1), dp), 1.25_dp, 0.005_dp, &
        '(c) checker TL: R == 1.25 (red texel, Phase 3 exposure)')
    call assert_real_close(real(rgb(2), dp), 0.0_dp, 0.005_dp, &
        '(c) checker TL: G == 0 (red texel)')
    call assert_real_close(real(rgb(3), dp), 0.0_dp, 0.005_dp, &
        '(c) checker TL: B == 0 (red texel)')
    fin%uv = [0.75_real32, 0.75_real32]  ! top-right: green
    call frag_shade(fin, sc_tex, rgb)
    call assert_real_close(real(rgb(1), dp), 0.0_dp, 0.005_dp, &
        '(c) checker TR: R == 0 (green texel)')
    call assert_real_close(real(rgb(2), dp), 1.25_dp, 0.005_dp, &
        '(c) checker TR: G == 1.25 (green texel, Phase 3 exposure)')
    fin%uv = [0.25_real32, 0.25_real32]  ! bottom-left: blue
    call frag_shade(fin, sc_tex, rgb)
    call assert_real_close(real(rgb(3), dp), 1.25_dp, 0.005_dp, &
        '(c) checker BL: B == 1.25 (blue texel, Phase 3 exposure)')
    call assert_real_close(real(rgb(1), dp), 0.0_dp, 0.005_dp, &
        '(c) checker BL: R == 0 (blue texel)')
    fin%uv = [0.75_real32, 0.25_real32]  ! bottom-right: white
    call frag_shade(fin, sc_tex, rgb)
    call assert_true(all(rgb > 0.99_real32), &
        '(c) checker BR: white texel on all channels')
    call assert_real_close(real(rgb(1), dp), 1.25_dp, 0.005_dp, &
        '(c) checker BR: R == 1.25 (white texel, Phase 3 exposure)')
    ! Same UV on the untextured scene keeps the grey base: the
    ! texture (not the UV alone) drives the difference.
    fin%uv = [0.25_real32, 0.75_real32]
    call frag_shade(fin, sc, rgb_exp)
    call assert_real_close(real(rgb_exp(1), dp), 0.625_dp, 0.005_dp, &
        '(c) control: no texture -> grey base * 1.25, not red texel')
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]
    fin%uv = [0.0_real32, 0.0_real32]

    ! ----------------------------------------------------------------
    ! (d) Custom shader stage: dispatch + RPN inputs
    ! ----------------------------------------------------------------
    fin%shader_id = 1  ! constant 0.75, ignores base colour entirely
    call frag_shade(fin, sc_sh, rgb)
    do k = 1, 3
        call assert_real_close(real(rgb(k), dp), 0.75_dp, 0.005_dp, &
            '(d) constant shader: every channel == 0.75')
    end do
    call assert_true(abs(real(rgb(1), dp) - 0.8_dp) > 0.01_dp, &
        '(d) shader output is NOT the lit base colour (dispatch won)')

    fin%shader_id = 2  ! 'u': every channel = fin%uv(1)
    fin%uv = [0.3_real32, 0.7_real32]
    call frag_shade(fin, sc_sh, rgb)
    call assert_real_close(real(rgb(1), dp), 0.3_dp, 0.005_dp, &
        '(d) u shader: R == u')
    call assert_real_close(real(rgb(3), dp), 0.3_dp, 0.005_dp, &
        '(d) u shader: B == u')
    fin%shader_id = 3  ! 'v'
    call frag_shade(fin, sc_sh, rgb)
    call assert_real_close(real(rgb(2), dp), 0.7_dp, 0.005_dp, &
        '(d) v shader: G == v')
    fin%shader_id = 0
    fin%uv = [0.0_real32, 0.0_real32]

    ! Out-of-range shader id with no bound object program: identity
    ! fallback returns the (fog-free, unlit) base colour -- here the
    ! fragment faces the light, so compare against rgb_front's base.
    fin%shader_id = 99
    fin%obj_id = 0
    call frag_shade(fin, sc_sh, rgb)
    call assert_real_close(real(rgb(1), dp), 0.8_dp, 0.005_dp, &
        '(d) unknown shader id: identity fallback returns base R')
    fin%shader_id = 0
    fin%obj_id = 2

    ! ----------------------------------------------------------------
    ! (e) Env stage: standard PBR material
    ! ----------------------------------------------------------------
    ! Camera sits at (0,0,5) in the base scene; put the fragment on
    ! the view axis with wp = (0,0,0) and use a dedicated scene whose
    ! camera is above, so n = v = L = +Y and the GGX highlight of the
    ! rough-0.05 standard material lands at full strength.
    call build_base_scene(sc_env)  ! rebuild resets objects; redo std
    sc_env%objects(2)%mat_name = 'standard'
    sc_env%objects(2)%pbr = pbr_standard([0.5_dp, 0.5_dp, 0.5_dp], &
                                         0.0_dp, 0.05_dp)
    call camera_init(sc_env%cam, vec3_create(0.0_dp, 5.0_dp, 0.0_dp), &
                     vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 60.0_dp, &
                     1.0_dp, 0.1_dp, 100.0_dp)
    fin%col = [0.5_real32, 0.5_real32, 0.5_real32]
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    call frag_shade(fin, sc_env, rgb)

    ! Hand-computed Phase 3 GGX value for n = v = L = +Y,
    ! roughness 0.05, dielectric (F0 = 0.04):
    !   alpha = 0.05^2, D = 1 / (pi * alpha^2) = 50929.58, G = 1,
    !   spec = D * G * F0 * pi / (4 * ndotv) = 1600.0 per channel.
    ! Plus diffuse 0.5 and hemisphere ambient 0.5 * 0.25 = 0.125:
    ! total 1600.625.  (Phase 2 compared against shade_rgb within
    ! 1/255; that quantised legacy helper is no longer the v3
    ! reference, and the old "> 0.9 saturates" assertion is now an
    ! HDR assertion: the value is NOT clamped to 1.)
    do k = 1, 3
        call assert_real_close(real(rgb(k), dp), 1600.625_dp, 16.0_dp, &
            '(e) env GGX peak == hand-computed 1600.625 (1% tol)')
    end do

    ! Direction: the same fragment through the plain material stage
    ! (lambert object, same base) is base * 1.25 in Phase 3; the
    ! env stage's GGX highlight must exceed it by orders of
    ! magnitude and survive unclamped (HDR).
    call frag_shade(fin, sc, rgb_exp)
    call assert_real_close(real(rgb_exp(1), dp), 0.625_dp, 0.01_dp, &
        '(e) material-stage control == base * 1.25 (Phase 3)')
    call assert_true(rgb(1) > rgb_exp(1) + 0.3_real32, &
        '(e) env GGX highlight brighter than material stage by > 0.3')
    call assert_true(rgb(1) > 100.0_real32, &
        '(e) env highlight is HDR (> 100, NOT clamped to 1)')
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]

    ! ----------------------------------------------------------------
    ! (f) Backface flip
    ! ----------------------------------------------------------------
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    fin%backface = .true.
    call frag_shade(fin, sc, rgb)
    do k = 1, 3
        call assert_real_close(real(rgb(k), dp), &
            real(rgb_away(k), dp), 0.005_dp, &
            '(f) backface up-normal == flipped (away) result')
    end do
    call assert_true(rgb(1) < rgb_front(1), &
        '(f) backface result darker than the front-face result')
    fin%backface = .false.
    fin%nrm = [0.0_real32, -1.0_real32, 0.0_real32]
    fin%backface = .true.
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), real(rgb_front(1), dp), &
        0.005_dp, '(f) backface down-normal == front-face result')
    fin%backface = .false.

    ! ----------------------------------------------------------------
    ! Fog post-stage: linear fog at view depth 5 of 0..10 mixes the
    ! lit colour halfway to white.  Phase 3 lit colour is
    ! (1.0, 0.5, 0.25) -> mix -> (1.0, 0.75, 0.625)
    ! (Phase 2 asserted (0.9, 0.7, 0.6) from lit (0.8, 0.4, 0.2)).
    ! ----------------------------------------------------------------
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    fin%wp = [0.0_real32, 0.0_real32, 0.0_real32]
    call frag_shade(fin, sc_fog, rgb)
    call assert_real_close(real(rgb(1), dp), 1.0_dp, 0.01_dp, &
        'fog linear f=0.5: R == mix(1.0, white)')
    call assert_real_close(real(rgb(2), dp), 0.75_dp, 0.01_dp, &
        'fog linear f=0.5: G == mix(0.5, white)')
    call assert_real_close(real(rgb(3), dp), 0.625_dp, 0.01_dp, &
        'fog linear f=0.5: B == mix(0.25, white)')
    ! At the camera position the view depth is 0 <= near: no fog.
    fin%wp = [0.0_real32, 0.0_real32, 5.0_real32]
    call frag_shade(fin, sc_fog, rgb)
    call assert_real_close(real(rgb(1), dp), 1.0_dp, 0.005_dp, &
        'fog at camera depth: colour unchanged')
    fin%wp = [0.0_real32, 0.0_real32, 0.0_real32]

    ! ================================================================
    ! Phase 3 additions
    ! ================================================================

    ! ----------------------------------------------------------------
    ! (g) GGX roughness response: same aligned fragment (n = v = L)
    ! on a standard material; roughness 0.05 peaks at ~1600 (see
    ! (e)), roughness 0.5 gives D = 1/(pi * 0.0625) = 5.093,
    ! spec = 5.093 * 0.04 * pi/4 = 0.16, total 0.5 + 0.125 + 0.16
    ! = 0.785.  Specular must DECREASE as roughness increases.
    ! ----------------------------------------------------------------
    call build_base_scene(sc_pbr)
    call camera_init(sc_pbr%cam, vec3_create(0.0_dp, 5.0_dp, 0.0_dp), &
                     vec3_create(0.0_dp, 0.0_dp, 0.0_dp), 60.0_dp, &
                     1.0_dp, 0.1_dp, 100.0_dp)
    fin%obj_id = 2
    fin%col = [0.5_real32, 0.5_real32, 0.5_real32]
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    sc_pbr%objects(2)%pbr = pbr_standard([0.5_dp, 0.5_dp, 0.5_dp], &
                                         0.0_dp, 0.05_dp)
    call frag_shade(fin, sc_pbr, rgb2)   ! smooth
    sc_pbr%objects(2)%pbr = pbr_standard([0.5_dp, 0.5_dp, 0.5_dp], &
                                         0.0_dp, 0.5_dp)
    call frag_shade(fin, sc_pbr, rgb3)   ! rough
    call assert_true(rgb2(1) > 100.0_real32, &
        '(g) GGX rough 0.05: strong specular peak (> 100)')
    call assert_true(rgb2(1) < 1.0e6_real32, &
        '(g) GGX rough 0.05: specular peak is finite (< 1e6)')
    call assert_real_close(real(rgb3(1), dp), 0.785_dp, 0.03_dp, &
        '(g) GGX rough 0.5: total == hand-computed 0.785')
    call assert_true(rgb3(1) < rgb2(1) * 0.01_real32, &
        '(g) specular decreases as roughness increases (100x drop)')

    ! ----------------------------------------------------------------
    ! (h) Metal vs dielectric F0: ambient 0, aligned fragment,
    ! base (0.8, 0.4, 0.2), roughness 0.05.  D * pi / 4 = 40000.
    ! Metal (metalness 1): diffuse is 0 and F0 = base colour, so
    ! the total is pure tinted specular (32000, 16000, 8000).
    ! Dielectric: F0 = 0.04 grey -> spec 1600 on every channel,
    ! plus untinted diffuse (0.8, 0.4, 0.2): channel DIFFERENCES
    ! stay exactly the diffuse differences (spec adds equally).
    ! ----------------------------------------------------------------
    sc_pbr%ambient = 0.0_dp
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]
    sc_pbr%objects(2)%pbr = pbr_standard([0.8_dp, 0.4_dp, 0.2_dp], &
                                         1.0_dp, 0.05_dp)
    call frag_shade(fin, sc_pbr, rgb2)   ! metal
    call assert_real_close(real(rgb2(1), dp) / real(rgb2(2), dp), &
        2.0_dp, 0.05_dp, '(h) metal specular tinted: R/G == 2 (base ratio)')
    call assert_real_close(real(rgb2(2), dp) / real(rgb2(3), dp), &
        2.0_dp, 0.05_dp, '(h) metal specular tinted: G/B == 2 (base ratio)')
    call assert_real_close(real(rgb2(1), dp), 32000.0_dp, 320.0_dp, &
        '(h) metal R == 40000 * base R (1% tol)')
    sc_pbr%objects(2)%pbr = pbr_standard([0.8_dp, 0.4_dp, 0.2_dp], &
                                         0.0_dp, 0.05_dp)
    call frag_shade(fin, sc_pbr, rgb3)   ! dielectric
    call assert_real_close(real(rgb3(1), dp) - real(rgb3(2), dp), &
        0.4_dp, 0.05_dp, &
        '(h) dielectric specular untinted: R-G == diffuse diff 0.4')
    call assert_real_close(real(rgb3(1), dp), 1600.8_dp, 16.0_dp, &
        '(h) dielectric R == 1600 spec + 0.8 diffuse (1% tol)')
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]

    ! ----------------------------------------------------------------
    ! (i) HDR: intensity-3 directional light head-on, white lambert
    ! base: total = 3 (direct) + 0.25 (hemisphere sky ambient)
    ! = 3.25 per channel, NOT clamped to 1.
    ! ----------------------------------------------------------------
    call build_base_scene(sc_hdr)
    sc_hdr%light_intensity = 3.0_dp
    fin%obj_id = 2
    fin%col = [1.0_real32, 1.0_real32, 1.0_real32]
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    call frag_shade(fin, sc_hdr, rgb)
    call assert_true(rgb(1) > 1.0_real32, &
        '(i) HDR: intensity-3 light gives R > 1 (no clamp)')
    call assert_real_close(real(rgb(1), dp), 3.25_dp, 0.05_dp, &
        '(i) HDR: R == 3.25 (direct 3 + ambient 0.25)')
    call assert_true(all(rgb > 1.0_real32), &
        '(i) HDR: all channels exceed 1')

    ! ----------------------------------------------------------------
    ! (j) Hemisphere ambient: light intensity 0 isolates the
    ! ambient term.  Up-facing: ambient * sky = 0.25 * base;
    ! down-facing: ambient * ground = 0.25 * 0.3 * base.
    ! ----------------------------------------------------------------
    call build_base_scene(sc_hemi)
    sc_hemi%light_intensity = 0.0_dp
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    call frag_shade(fin, sc_hemi, rgb2)
    fin%nrm = [0.0_real32, -1.0_real32, 0.0_real32]
    call frag_shade(fin, sc_hemi, rgb3)
    call assert_real_close(real(rgb2(1), dp), 0.8_dp * 0.25_dp, &
        0.005_dp, '(j) hemisphere: up-facing R == ambient * base (sky)')
    call assert_real_close(real(rgb3(1), dp), 0.8_dp * 0.075_dp, &
        0.005_dp, '(j) hemisphere: down-facing R == 0.3 * ambient * base')
    call assert_true(rgb2(1) > rgb3(1) * 3.0_real32, &
        '(j) hemisphere: up-facing ambient > 3x down-facing')
    call assert_real_close(real(rgb2(2), dp) / real(rgb3(2), dp), &
        1.0_dp / 0.3_dp, 0.05_dp, &
        '(j) hemisphere: up/down ambient ratio == 1/0.3')

    ! ----------------------------------------------------------------
    ! (k) Energy sanity (white furnace-ish): a fully lit white
    ! diffuse (lambert) surface under a unit white light must not
    ! exceed the documented bound 1 + ambient = 1.25 (direct 1.0
    ! from the pi-normalised Lambert + full sky ambient 0.25).
    ! ----------------------------------------------------------------
    fin%col = [1.0_real32, 1.0_real32, 1.0_real32]
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    call frag_shade(fin, sc, rgb)
    call assert_true(all(rgb <= 1.2501_real32), &
        '(k) energy: white diffuse under unit light <= bound 1.25')
    call assert_real_close(real(rgb(1), dp), 1.25_dp, 0.005_dp, &
        '(k) energy: white diffuse total == 1.25 exactly at bound')
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]

    ! ----------------------------------------------------------------
    ! (l) Per-light shadow independence (fragment level, REAL
    ! shadow_v3 module): two directional lights, ambient 0.
    !   A: dir (0,-1,0) -> L = +Y,        ndl_A = 1
    !   B: dir (-1,-1,0)/sqrt2 -> L_B,    ndl_B = 1/sqrt2
    ! A size-1 cube occluder sits at (0, 2.5, 0): it blocks A's
    ! vertical rays to the origin fragment but not B's (B's ray
    ! toward the light passes x = y, clearing the cube's x <= 0.5
    ! span for y >= 1.5).  Grey 0.5 lambert base, so the direct
    ! total is 0.5 * (fA * 1 + fB / sqrt2): the shadowed total
    ! must equal that identity with the module's OWN factors --
    ! light A's shadowing removes exactly A's share and leaves
    ! B's untouched.
    ! ----------------------------------------------------------------
    call build_base_scene(sc_sh2)
    sc_sh2%ambient = 0.0_dp
    sc_sh2%shadow_mode = 1  ! shadow_v3_build is a no-op at mode 0
    allocate(sc_sh2%lights%items(2))
    sc_sh2%lights%ambient = 0.0_dp
    sc_sh2%lights%ambient_color = [255, 255, 255]
    sc_sh2%lights%items(1) = Light3()
    sc_sh2%lights%items(1)%kind = 0
    sc_sh2%lights%items(1)%dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
    sc_sh2%lights%items(2) = Light3()
    sc_sh2%lights%items(2)%kind = 0
    sc_sh2%lights%items(2)%dir = vec3_create(-sqrt(0.5_dp), &
                                             -sqrt(0.5_dp), 0.0_dp)
    ! Object 2 becomes the occluder cube above the origin.
    sc_sh2%objects(2)%prim = 'cube'
    sc_sh2%objects(2)%dim_size = 1.0_dp
    sc_sh2%objects(2)%pos = vec3_create(0.0_dp, 2.5_dp, 0.0_dp)
    call scene_build_object_mesh(sc_sh2%objects(1))
    call scene_build_object_mesh(sc_sh2%objects(2))
    models_sh(1) = mat4_compose_trs(sc_sh2%objects(1)%pos, &
                                    sc_sh2%objects(1)%rot_deg, &
                                    sc_sh2%objects(1)%scl)
    models_sh(2) = mat4_compose_trs(sc_sh2%objects(2)%pos, &
                                    sc_sh2%objects(2)%rot_deg, &
                                    sc_sh2%objects(2)%scl)
    fin%obj_id = 1
    fin%col = [0.5_real32, 0.5_real32, 0.5_real32]
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    fin%wp = [0.0_real32, 0.0_real32, 0.0_real32]

    unshad = 0.5_dp * (1.0_dp + sqrt(0.5_dp))
    call shadow_v3_clear()
    call frag_shade(fin, sc_sh2, rgb)
    call assert_real_close(real(rgb(1), dp), unshad, 0.01_dp, &
        '(l) no shadow maps built: total == 0.5*(1 + 1/sqrt2)')

    call shadow_v3_build(sc_sh2, models_sh)
    fA = shadow_v3_factor(1, fin%wp, fin%nrm)
    fB = shadow_v3_factor(2, fin%wp, fin%nrm)
    call frag_shade(fin, sc_sh2, rgb)
    shad_exp = 0.5_dp * (real(fA, dp) + real(fB, dp) * sqrt(0.5_dp))
    call assert_real_close(real(rgb(1), dp), shad_exp, 0.01_dp, &
        '(l) shadowed total == 0.5*(fA + fB/sqrt2): per-light identity')
    call assert_true(fA < 0.5_real32, &
        '(l) occluder shadows light A at the origin (fA < 0.5)')
    call assert_true(fB > 0.9_real32, &
        '(l) light B unshadowed at the origin (fB > 0.9)')
    call assert_true(real(rgb(1), dp) < unshad - 0.2_dp, &
        '(l) shadowing A removes (most of) exactly A share')
    call shadow_v3_clear()
    fin%obj_id = 2
    fin%wp = [0.0_real32, 0.0_real32, 0.0_real32]

    call test_summary()

contains

    ! Ground plane (object 1, white lambert) + coloured object 2
    ! (lambert, colour carried by fin%col at shade time; its PBR
    ! record is the pbr_from_material view scene_build_object_mesh
    ! would build).  Camera at (0,0,5) looking at the origin; key
    ! light travels -Y at intensity 1, white; ambient 0.25.  The
    ! LightSet is deliberately left unallocated so fragment_v3 must
    ! rebuild it from the legacy fields, as scene_load does.
    subroutine build_base_scene(s)
        type(Scene), intent(out) :: s
        s = Scene()
        call camera_init(s%cam, vec3_create(0.0_dp, 0.0_dp, 5.0_dp), &
                         vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                         60.0_dp, 1.0_dp, 0.1_dp, 100.0_dp)
        s%light_dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
        s%light_color = [255, 255, 255]
        s%light_intensity = 1.0_dp
        s%ambient = 0.25_dp
        allocate(s%objects(2))
        s%n_objects = 2
        s%cap_objects = 2
        s%objects(1)%name = 'ground'
        s%objects(1)%prim = 'plane'
        s%objects(1)%mat_name = 'lambert'
        s%objects(1)%mat = material_lambert([1.0_dp, 1.0_dp, 1.0_dp], &
                                            .false.)
        s%objects(1)%pbr = pbr_from_material(s%objects(1)%mat, &
                                             0.0_dp, 1.0_dp)
        s%objects(2)%name = 'coloured'
        s%objects(2)%prim = 'cube'
        s%objects(2)%mat_name = 'lambert'
        s%objects(2)%mat = material_lambert([0.8_dp, 0.4_dp, 0.2_dp], &
                                            .false.)
        s%objects(2)%pbr = pbr_from_material(s%objects(2)%mat, &
                                             0.0_dp, 1.0_dp)
    end subroutine build_base_scene

end program test_fragment_v3
