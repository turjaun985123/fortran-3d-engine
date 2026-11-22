program test_material_pbr
    use math_3d, only: dp, vec3, vec3_create
    use material_3d, only: Material, material_phong, material_lambert
    use material_pbr_3d
    use test_assert
    implicit none

    type(MaterialPBR) :: p, def
    type(Material) :: mat
    real(dp) :: f0(3), f(3), spec(3)
    type(vec3) :: n, v, l

    n = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
    v = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)
    l = vec3_create(0.0_dp, 0.0_dp, 1.0_dp)

    ! ---- defaults ----
    def = pbr_default()
    call assert_real_close(0.0_dp, def%metalness, 1.0e-12_dp, 'defaults metalness 0')
    call assert_real_close(1.0_dp, def%roughness, 1.0e-12_dp, 'defaults roughness 1')
    p = pbr_standard([1.0_dp, 0.0_dp, 0.0_dp], 0.0_dp, 1.0_dp)
    call assert_int_eq(MAT_STANDARD, p%mode, 'pbr_standard mode is MAT_STANDARD (3)')
    call assert_int_eq(3, MAT_STANDARD, 'MAT_STANDARD == 3')
    call assert_false(p%use_tri_color, 'pbr_standard use_tri_color false')

    ! ---- base_f0 ----
    p = pbr_standard([1.0_dp, 0.0_dp, 0.0_dp], 0.0_dp, 0.5_dp)
    f0 = base_f0(p, [1.0_dp, 0.0_dp, 0.0_dp])
    call assert_real_close(0.04_dp, f0(1), 1.0e-12_dp, 'F0 dielectric R = 0.04 at metalness 0')
    call assert_real_close(0.04_dp, f0(2), 1.0e-12_dp, 'F0 dielectric G = 0.04 at metalness 0')
    call assert_real_close(0.04_dp, f0(3), 1.0e-12_dp, 'F0 dielectric B = 0.04 at metalness 0')
    p = pbr_standard([1.0_dp, 0.0_dp, 0.0_dp], 1.0_dp, 0.5_dp)
    f0 = base_f0(p, [1.0_dp, 0.0_dp, 0.0_dp])
    call assert_real_close(1.0_dp, f0(1), 1.0e-12_dp, 'F0 metal R = base colour at metalness 1')
    call assert_real_close(0.0_dp, f0(2), 1.0e-12_dp, 'F0 metal G = base colour at metalness 1')
    call assert_real_close(0.0_dp, f0(3), 1.0e-12_dp, 'F0 metal B = base colour at metalness 1')

    ! ---- Fresnel ----
    f = fresnel_schlick(1.0_dp, [0.04_dp, 0.04_dp, 0.04_dp])
    call assert_real_close(0.04_dp, f(1), 1.0e-12_dp, 'Fresnel at cos=1 returns f0')
    f = fresnel_schlick(0.0_dp, [0.04_dp, 0.04_dp, 0.04_dp])
    call assert_real_close(1.0_dp, f(1), 1.0e-9_dp, 'Fresnel at cos=0 returns ~1 (R)')
    call assert_real_close(1.0_dp, f(2), 1.0e-9_dp, 'Fresnel at cos=0 returns ~1 (G)')
    call assert_real_close(1.0_dp, f(3), 1.0e-9_dp, 'Fresnel at cos=0 returns ~1 (B)')

    ! ---- GGX ----
    call assert_true(ggx_distribution(1.0_dp, 0.2_dp) > ggx_distribution(1.0_dp, 0.8_dp), &
        'GGX D(1, rough .2) > D(1, rough .8)')
    call assert_true(ggx_distribution(1.0_dp, 0.5_dp) > ggx_distribution(0.5_dp, 0.5_dp), &
        'GGX peaks at ndoth=1')
    call assert_true(ggx_distribution(1.0_dp, 0.5_dp) > 0.0_dp, 'GGX positive at ndoth=1')

    ! ---- specular: zero when light behind ----
    p = pbr_standard([1.0_dp, 1.0_dp, 1.0_dp], 0.0_dp, 0.5_dp)
    spec = pbr_specular(n, v, vec3_create(0.0_dp, 0.0_dp, -1.0_dp), p, [1.0_dp, 1.0_dp, 1.0_dp])
    call assert_real_close(0.0_dp, spec(1), 1.0e-12_dp, 'specular zero when light behind (R)')
    call assert_real_close(0.0_dp, spec(2), 1.0e-12_dp, 'specular zero when light behind (G)')
    call assert_real_close(0.0_dp, spec(3), 1.0e-12_dp, 'specular zero when light behind (B)')

    ! ---- specular: standard aligned is positive & finite ----
    spec = pbr_specular(n, v, l, p, [1.0_dp, 1.0_dp, 1.0_dp])
    call assert_true(spec(1) > 0.0_dp, 'standard specular positive when aligned')
    call assert_true(spec(1) < 1.0e4_dp, 'standard specular finite/clamped')

    ! ---- metal red tint ----
    p = pbr_standard([1.0_dp, 0.0_dp, 0.0_dp], 1.0_dp, 0.3_dp)
    spec = pbr_specular(n, v, l, p, [1.0_dp, 0.0_dp, 0.0_dp])
    call assert_true(spec(1) > spec(2), 'metal red base gives red-tinted spec (r>g)')
    call assert_true(spec(1) > spec(3), 'metal red base gives red-tinted spec (r>b)')
    spec = pbr_specular_simple(n, v, l, p)
    call assert_true(spec(1) > spec(2), 'pbr_specular_simple wrapper red tint (r>g)')

    ! ---- phong mode ----
    mat = material_phong([1.0_dp, 1.0_dp, 1.0_dp], 32.0_dp)
    p = pbr_from_material(mat, 0.0_dp, 1.0_dp)
    call assert_int_eq(2, p%mode, 'pbr_from_material preserves phong mode')
    spec = pbr_specular(n, v, l, p, [1.0_dp, 1.0_dp, 1.0_dp])
    call assert_true(spec(1) > 0.0_dp, 'phong mode positive spec for aligned reflect/view')

    ! ---- lambert gives zero specular ----
    mat = material_lambert([1.0_dp, 1.0_dp, 1.0_dp], .true.)
    p = pbr_from_material(mat, 0.0_dp, 1.0_dp)
    spec = pbr_specular(n, v, l, p, [1.0_dp, 1.0_dp, 1.0_dp])
    call assert_real_close(0.0_dp, spec(1), 1.0e-12_dp, 'lambert mode specular zero')

    ! ---- from_material: name standard -> MAT_STANDARD ----
    mat = material_lambert([0.5_dp, 0.5_dp, 0.5_dp], .true.)
    mat%name = 'standard'
    p = pbr_from_material(mat, 0.25_dp, 0.75_dp)
    call assert_int_eq(MAT_STANDARD, p%mode, 'from_material name=standard sets MAT_STANDARD')
    call assert_real_close(0.25_dp, p%metalness, 1.0e-12_dp, 'from_material copies metalness arg')
    call assert_real_close(0.75_dp, p%roughness, 1.0e-12_dp, 'from_material copies roughness arg')
    call assert_real_close(0.5_dp, p%color(1), 1.0e-12_dp, 'from_material copies colour')

    call test_summary()
end program test_material_pbr
