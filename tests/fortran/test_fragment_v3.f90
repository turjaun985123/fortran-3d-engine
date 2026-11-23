! test_fragment_v3.f90 -- tests for fragment_v3_3d (src/fragment_v3.f90),
! the v3.0 Phase 2 single fragment stage that collapses the legacy
! renderer's _mat / _env / _shader paths.
!
! Scenes are built in-program (no scene_load): a ground-plane object
! and one coloured object under a key directional light travelling
! -Y (so L = +Y and an up normal gives diffuse exactly 1), ambient
! 0.25 -- the legacy-equivalence configuration of lighting.f90.
! Base colour (0.8, 0.4, 0.2) = (204, 102, 51)/255 is chosen so the
! legacy 8-bit quantisation inside shade_rgb is exact for the
! intensities asserted below.
program test_fragment_v3
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d
    use camera_3d
    use material_3d
    use material_pbr_3d
    use lighting_3d
    use shader_3d
    use scene_3d
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

    ! Cross-check fixtures (lighting_3d called directly).
    type(LightSet) :: lights
    type(MaterialPBR) :: pbr_lam, pbr_std
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
    call assert_real_close(real(rgb_front(1), dp), 0.8_dp, 0.005_dp, &
        '(a) facing light: R == base (intensity 1)')
    call assert_real_close(real(rgb_front(2), dp), 0.4_dp, 0.005_dp, &
        '(a) facing light: G == base (intensity 1)')
    call assert_real_close(real(rgb_front(3), dp), 0.2_dp, 0.005_dp, &
        '(a) facing light: B == base (intensity 1)')

    fin%nrm = [0.0_real32, -1.0_real32, 0.0_real32]
    call frag_shade(fin, sc, rgb_away)
    do k = 1, 3
        call assert_true(rgb_front(k) > rgb_away(k), &
            '(a) facing fragment brighter than facing-away, per channel')
    end do

    ! 60 degrees off the light: diffuse = 0.5, intensity =
    ! 0.25 + 0.75 * 0.5 = 0.625 (the legacy _mat formula).
    fin%nrm = [0.0_real32, 0.5_real32, real(sqrt(0.75_dp), real32)]
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), 0.8_dp * 0.625_dp, 0.01_dp, &
        '(a) diffuse 0.5: R == base * 0.625 (legacy Lambert factor)')
    call assert_real_close(real(rgb(2), dp), 0.4_dp * 0.625_dp, 0.01_dp, &
        '(a) diffuse 0.5: G == base * 0.625 (legacy Lambert factor)')
    call assert_real_close(real(rgb(3), dp), 0.2_dp * 0.625_dp, 0.01_dp, &
        '(a) diffuse 0.5: B == base * 0.625 (legacy Lambert factor)')

    ! Unnormalised interpolated normal must shade like its direction.
    fin%nrm = [0.0_real32, 3.0_real32, 0.0_real32]
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), real(rgb_front(1), dp), &
        0.005_dp, '(a) normal (0,3,0) shades as (0,1,0)')

    ! Cross-check against lighting_3d's shade_rgb computed directly
    ! (the helper the legacy env path uses), same inputs.
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
        call assert_true(abs(real(rgb_front(k), dp) * 255.0_dp - &
                             real(lit_i(k), dp)) <= 1.0_dp, &
            '(a) frag_shade == direct shade_rgb within 1/255')
    end do

    ! ----------------------------------------------------------------
    ! (b) Ambient floor
    ! ----------------------------------------------------------------
    ! Facing away: diffuse 0, result = ambient * base exactly (the
    ! legacy formula's floor; rgb_away was computed above).
    call assert_real_close(real(rgb_away(1), dp), 0.8_dp * 0.25_dp, &
        0.01_dp, '(b) back-facing R == ambient * base')
    call assert_real_close(real(rgb_away(2), dp), 0.4_dp * 0.25_dp, &
        0.01_dp, '(b) back-facing G == ambient * base')
    call assert_real_close(real(rgb_away(3), dp), 0.2_dp * 0.25_dp, &
        0.01_dp, '(b) back-facing B == ambient * base')
    call assert_true(all(rgb_away > 0.0_real32), &
        '(b) ambient floor keeps a back-facing fragment non-black')

    ! Zero normal (degenerate interpolation): no diffuse anywhere,
    ! the ambient floor still applies.
    fin%nrm = [0.0_real32, 0.0_real32, 0.0_real32]
    call frag_shade(fin, sc, rgb)
    call assert_real_close(real(rgb(1), dp), 0.8_dp * 0.25_dp, 0.01_dp, &
        '(b) zero normal: ambient floor only')

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
    ! through the same shade_rgb loop -- grey 0.4 base:
    ! (0.25 ambient + 0.75 * 1 dir + 0.75 * 1 point) * 0.4 = 0.7.
    ! ----------------------------------------------------------------
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    fin%col = [0.4_real32, 0.4_real32, 0.4_real32]
    call frag_shade(fin, sc_multi, rgb)
    call assert_real_close(real(rgb(1), dp), 0.7_dp, 0.01_dp, &
        'multi-light: dir + point diffuse accumulate (0.7)')
    call frag_shade(fin, sc, rgb_exp)
    call assert_real_close(real(rgb_exp(1), dp), 0.4_dp, 0.005_dp, &
        'multi-light control: dir only gives the base 0.4')
    call assert_true(rgb(1) > rgb_exp(1), &
        'multi-light result brighter than single-light control')
    fin%col = [0.8_real32, 0.4_real32, 0.2_real32]

    ! ----------------------------------------------------------------
    ! (c) Texture stage: checker squares replace the base colour
    ! ----------------------------------------------------------------
    ! fin%col is grey here on purpose: the legacy env rule replaces
    ! it with the texel.  Normal faces the light, so intensity = 1
    ! and the output is the texel itself.
    fin%obj_id = 2
    fin%col = [0.5_real32, 0.5_real32, 0.5_real32]
    fin%uv = [0.25_real32, 0.75_real32]  ! top-left: red
    call frag_shade(fin, sc_tex, rgb)
    call assert_real_close(real(rgb(1), dp), 1.0_dp, 0.005_dp, &
        '(c) checker TL: R == 1 (red texel)')
    call assert_real_close(real(rgb(2), dp), 0.0_dp, 0.005_dp, &
        '(c) checker TL: G == 0 (red texel)')
    call assert_real_close(real(rgb(3), dp), 0.0_dp, 0.005_dp, &
        '(c) checker TL: B == 0 (red texel)')
    fin%uv = [0.75_real32, 0.75_real32]  ! top-right: green
    call frag_shade(fin, sc_tex, rgb)
    call assert_real_close(real(rgb(1), dp), 0.0_dp, 0.005_dp, &
        '(c) checker TR: R == 0 (green texel)')
    call assert_real_close(real(rgb(2), dp), 1.0_dp, 0.005_dp, &
        '(c) checker TR: G == 1 (green texel)')
    fin%uv = [0.25_real32, 0.25_real32]  ! bottom-left: blue
    call frag_shade(fin, sc_tex, rgb)
    call assert_real_close(real(rgb(3), dp), 1.0_dp, 0.005_dp, &
        '(c) checker BL: B == 1 (blue texel)')
    call assert_real_close(real(rgb(1), dp), 0.0_dp, 0.005_dp, &
        '(c) checker BL: R == 0 (blue texel)')
    fin%uv = [0.75_real32, 0.25_real32]  ! bottom-right: white
    call frag_shade(fin, sc_tex, rgb)
    call assert_true(all(rgb > 0.99_real32), &
        '(c) checker BR: white texel on all channels')
    ! Same UV on the untextured scene keeps the grey base: the
    ! texture (not the UV alone) drives the difference.
    fin%uv = [0.25_real32, 0.75_real32]
    call frag_shade(fin, sc, rgb_exp)
    call assert_real_close(real(rgb_exp(1), dp), 0.5_dp, 0.005_dp, &
        '(c) control: no texture -> grey base, not red texel')
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

    ! Hand-computed env contribution: shade_rgb directly with the
    ! standard PBR record (what draw_triangle_env calls per pixel).
    pbr_std = pbr_standard([0.5_dp, 0.5_dp, 0.5_dp], 0.0_dp, 0.05_dp)
    base_i = [128, 128, 128]  ! nint(0.5 * 255) as shade_lit computes
    lit_i = shade_rgb(base_i, vec3_create(0.0_dp, 1.0_dp, 0.0_dp), &
                      vec3_create(0.0_dp, 0.0_dp, 0.0_dp), &
                      vec3_create(0.0_dp, 5.0_dp, 0.0_dp), &
                      lights, pbr_std, 1.0_dp)
    do k = 1, 3
        call assert_true(abs(real(rgb(k), dp) * 255.0_dp - &
                             real(lit_i(k), dp)) <= 1.0_dp, &
            '(e) env stage == direct shade_rgb(standard PBR) within 1/255')
    end do

    ! Direction: the same fragment through the plain material stage
    ! (lambert object, same base) is just the base at intensity 1;
    ! the env stage's GGX highlight must exceed it clearly.
    call frag_shade(fin, sc, rgb_exp)
    call assert_real_close(real(rgb_exp(1), dp), 0.5_dp, 0.01_dp, &
        '(e) material-stage control == base 0.5 at intensity 1')
    call assert_true(rgb(1) > rgb_exp(1) + 0.3_real32, &
        '(e) env GGX highlight brighter than material stage by > 0.3')
    call assert_true(rgb(1) > 0.9_real32, &
        '(e) env highlight saturates the channel (> 0.9)')
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
    ! lit colour halfway to white: (0.8,0.4,0.2) -> (0.9,0.7,0.6).
    ! ----------------------------------------------------------------
    fin%nrm = [0.0_real32, 1.0_real32, 0.0_real32]
    fin%wp = [0.0_real32, 0.0_real32, 0.0_real32]
    call frag_shade(fin, sc_fog, rgb)
    call assert_real_close(real(rgb(1), dp), 0.9_dp, 0.01_dp, &
        'fog linear f=0.5: R == mix(0.8, white)')
    call assert_real_close(real(rgb(2), dp), 0.7_dp, 0.01_dp, &
        'fog linear f=0.5: G == mix(0.4, white)')
    call assert_real_close(real(rgb(3), dp), 0.6_dp, 0.01_dp, &
        'fog linear f=0.5: B == mix(0.2, white)')
    ! At the camera position the view depth is 0 <= near: no fog.
    fin%wp = [0.0_real32, 0.0_real32, 5.0_real32]
    call frag_shade(fin, sc_fog, rgb)
    call assert_real_close(real(rgb(1), dp), 0.8_dp, 0.005_dp, &
        'fog at camera depth: colour unchanged')
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
