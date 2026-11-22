! material_pbr.f90 -- PBR (MeshStandardMaterial-equivalent) material.
!
! Parity row 11: `material standard` with metalness/roughness,
! sensible defaults (Three.js MeshStandardMaterial: metalness=0,
! roughness=1), no env-map needed to start.
!
! API:
!   integer, parameter :: MAT_STANDARD = 3
!   type :: MaterialPBR
!   pure function pbr_from_material(mat, metalness, roughness) result(p)
!   pure function pbr_standard(rgb, metalness, roughness) result(p)
!   pure function pbr_default() result(p)
!   pure function fresnel_schlick(cos_theta, f0) result(f)
!   pure function base_f0(p, base_rgb) result(f0)
!   pure function ggx_distribution(ndoth, roughness) result(d)
!   pure function pbr_specular(normal, view_dir, light_dir, p, base_rgb) result(spec)
!   pure function pbr_specular_simple(normal, view_dir, light_dir, p) result(spec)
!
! pbr_specular is the 5-arg primary (base_rgb explicit, needed for
! metal F0). pbr_specular_simple is the 4-arg wrapper for callers
! (e.g. lighting) that do not have a separate base colour: it uses
! p%color as the base colour.
module material_pbr_3d
    use math_3d, only: dp, vec3, vec3_dot, vec3_normalize, vec3_add, &
                       vec3_scale, vec3_sub
    use material_3d, only: Material
    implicit none
    private
    public :: MAT_STANDARD, MaterialPBR
    public :: pbr_from_material, pbr_standard, pbr_default
    public :: fresnel_schlick, base_f0, ggx_distribution
    public :: pbr_specular, pbr_specular_simple

    integer, parameter :: MAT_STANDARD = 3

    real(dp), parameter :: PI_LOCAL = 3.14159265358979323846_dp

    type :: MaterialPBR
        integer :: mode = 0
        real(dp) :: color(3) = [1.0_dp, 1.0_dp, 1.0_dp]
        logical :: use_tri_color = .true.
        real(dp) :: metalness = 0.0_dp
        real(dp) :: roughness = 1.0_dp
        real(dp) :: specular = 0.5_dp
        real(dp) :: shininess = 32.0_dp
    end type MaterialPBR

contains

    pure function clamp01(x) result(r)
        real(dp), intent(in) :: x
        real(dp) :: r
        r = min(max(x, 0.0_dp), 1.0_dp)
    end function clamp01

    pure function clamp_rgb(rgb) result(r)
        real(dp), intent(in) :: rgb(3)
        real(dp) :: r(3)
        r(1) = clamp01(rgb(1)); r(2) = clamp01(rgb(2)); r(3) = clamp01(rgb(3))
    end function clamp_rgb

    pure function clamp_finite(x) result(r)
        real(dp), intent(in) :: x
        real(dp) :: r
        if (x /= x .or. x < 0.0_dp) then
            r = 0.0_dp
        else if (x > 1.0e4_dp) then
            r = 1.0e4_dp
        else
            r = x
        end if
    end function clamp_finite

    pure function pbr_from_material(mat, metalness, roughness) result(p)
        type(Material), intent(in) :: mat
        real(dp), intent(in), optional :: metalness, roughness
        type(MaterialPBR) :: p
        p%mode = mat%mode
        p%color = clamp_rgb(mat%color)
        p%use_tri_color = mat%use_tri_color
        p%specular = mat%specular
        p%shininess = mat%shininess
        p%metalness = 0.0_dp
        p%roughness = 1.0_dp
        if (present(metalness)) p%metalness = clamp01(metalness)
        if (present(roughness)) p%roughness = clamp01(roughness)
        if (trim(mat%name) == 'standard') p%mode = MAT_STANDARD
    end function pbr_from_material

    pure function pbr_standard(rgb, metalness, roughness) result(p)
        real(dp), intent(in) :: rgb(3)
        real(dp), intent(in), optional :: metalness, roughness
        type(MaterialPBR) :: p
        p%mode = MAT_STANDARD
        p%color = clamp_rgb(rgb)
        p%use_tri_color = .false.
        p%metalness = 0.0_dp
        p%roughness = 1.0_dp
        if (present(metalness)) p%metalness = clamp01(metalness)
        if (present(roughness)) p%roughness = clamp01(roughness)
        p%specular = 0.5_dp
        p%shininess = 32.0_dp
    end function pbr_standard

    pure function pbr_default() result(p)
        type(MaterialPBR) :: p
        p%mode = 0
        p%color = [1.0_dp, 1.0_dp, 1.0_dp]
        p%use_tri_color = .true.
        p%metalness = 0.0_dp
        p%roughness = 1.0_dp
        p%specular = 0.5_dp
        p%shininess = 32.0_dp
    end function pbr_default

    pure function fresnel_schlick(cos_theta, f0) result(f)
        real(dp), intent(in) :: cos_theta
        real(dp), intent(in) :: f0(3)
        real(dp) :: f(3)
        real(dp) :: c, m
        c = clamp01(cos_theta)
        m = (1.0_dp - c)**5
        f(1) = f0(1) + (1.0_dp - f0(1)) * m
        f(2) = f0(2) + (1.0_dp - f0(2)) * m
        f(3) = f0(3) + (1.0_dp - f0(3)) * m
    end function fresnel_schlick

    pure function base_f0(p, base_rgb) result(f0)
        type(MaterialPBR), intent(in) :: p
        real(dp), intent(in) :: base_rgb(3)
        real(dp) :: f0(3)
        real(dp) :: base(3), met
        base = clamp_rgb(base_rgb)
        met = clamp01(p%metalness)
        f0(1) = 0.04_dp * (1.0_dp - met) + base(1) * met
        f0(2) = 0.04_dp * (1.0_dp - met) + base(2) * met
        f0(3) = 0.04_dp * (1.0_dp - met) + base(3) * met
    end function base_f0

    pure function ggx_distribution(ndoth, roughness) result(d)
        real(dp), intent(in) :: ndoth, roughness
        real(dp) :: d
        real(dp) :: r, alpha, alpha2, ndoth_c, denom
        r = min(max(roughness, 0.05_dp), 1.0_dp)
        alpha = r * r
        alpha2 = alpha * alpha
        ndoth_c = clamp01(ndoth)
        denom = ndoth_c * ndoth_c * (alpha2 - 1.0_dp) + 1.0_dp
        d = alpha2 / (PI_LOCAL * denom * denom)
        d = clamp_finite(d)
    end function ggx_distribution

    pure function geometry_schlick_ggx(ndotx, roughness) result(g)
        real(dp), intent(in) :: ndotx, roughness
        real(dp) :: g
        real(dp) :: r, k
        if (ndotx <= 0.0_dp) then
            g = 0.0_dp
            return
        end if
        r = min(max(roughness, 0.05_dp), 1.0_dp)
        k = (r + 1.0_dp)**2 / 8.0_dp
        g = ndotx / (ndotx * (1.0_dp - k) + k)
    end function geometry_schlick_ggx

    pure function pbr_specular(normal, view_dir, light_dir, p, base_rgb) result(spec)
        type(vec3), intent(in) :: normal, view_dir, light_dir
        type(MaterialPBR), intent(in) :: p
        real(dp), intent(in) :: base_rgb(3)
        real(dp) :: spec(3)
        type(vec3) :: n, v, l, h, rvec
        real(dp) :: ndotl, ndotv, ndoth, vdoth, dterm, gterm, denom, factor
        real(dp) :: f(3)
        integer :: i

        spec = [0.0_dp, 0.0_dp, 0.0_dp]
        n = vec3_normalize(normal)
        v = vec3_normalize(view_dir)
        l = vec3_normalize(light_dir)
        ndotl = vec3_dot(n, l)
        ndotv = vec3_dot(n, v)
        if (ndotl <= 0.0_dp .or. ndotv <= 0.0_dp) return

        if (p%mode == MAT_STANDARD) then
            h = vec3_normalize(vec3_add(v, l))
            ndoth = clamp01(vec3_dot(n, h))
            vdoth = clamp01(vec3_dot(v, h))
            dterm = ggx_distribution(ndoth, p%roughness)
            gterm = geometry_schlick_ggx(ndotv, p%roughness) * &
                    geometry_schlick_ggx(ndotl, p%roughness)
            f = fresnel_schlick(vdoth, base_f0(p, base_rgb))
            denom = max(4.0_dp * ndotv * ndotl, 1.0e-4_dp)
            do i = 1, 3
                spec(i) = clamp_finite(dterm * gterm * f(i) / denom)
            end do
        else if (p%mode == 2) then
            ! Phong: reflect(-L, n) = 2*(n.L)*n - L
            rvec = vec3_sub(vec3_scale(n, 2.0_dp * ndotl), l)
            factor = p%specular * max(0.0_dp, vec3_dot(rvec, v))**p%shininess
            factor = clamp_finite(factor)
            spec = [factor, factor, factor]
        else
            spec = [0.0_dp, 0.0_dp, 0.0_dp]
        end if
    end function pbr_specular

    pure function pbr_specular_simple(normal, view_dir, light_dir, p) result(spec)
        type(vec3), intent(in) :: normal, view_dir, light_dir
        type(MaterialPBR), intent(in) :: p
        real(dp) :: spec(3)
        spec = pbr_specular(normal, view_dir, light_dir, p, p%color)
    end function pbr_specular_simple

end module material_pbr_3d
