! lighting.f90 -- multi-light shading for the Fortran CPU renderer.
!
! Module lighting_3d provides:
!   * Light3        -- one directional / point / spot light.
!   * LightSet      -- an allocatable array of lights plus an ambient term.
!   * light_attenuation(dist, distance, decay)
!   * spot_factor(light, to_frag_dir)
!   * shade_rgb(base_rgb, normal, world_pos, cam_pos, lights, mat, &
!               shadow_factor)
!
! Legacy compatibility (load-bearing)
! ------------------------------------
! The v1 renderer (renderer.f90, framebuffer_render_mesh_mat) shades a
! single directional light as
!
!     intensity = ambient + (1 - ambient) * diffuse
!     rgb       = int(base * intensity)          ambient default 0.25
!
! shade_rgb reproduces that EXACTLY (within integer rounding) for one
! directional light of intensity 1, white colour, ambient = 0.25, a
! lambert material and shadow_factor = 1.  To do so the summed diffuse
! contributions are weighted by (1 - ambient):
!
!     rgb = base * ambient * ambient_color/255
!         + (1 - ambient) * sum_i base * diffuse_i * atten_i * spot_i
!                                 * shadow * intensity_i * color_i/255
!         + 255 * sum_i spec_i * atten_i * spot_i * shadow
!                       * intensity_i * color_i/255
!
! With a single such light this collapses to the legacy formula.  The
! specular term (from material_pbr_3d's pbr_specular) is NOT weighted by
! (1 - ambient), matching v1 phong, where spec was added unscaled on top
! of the lambert intensity.  pbr_specular returns 0 for lambert/basic
! materials, so the legacy lambert path is untouched by it.
!
! Note on the B56 API as landed: pbr_specular is the 5-argument primary
! pbr_specular(normal, view_dir, light_dir, mat, base_rgb) with the base
! colour (real 0..1) passed explicitly -- it is needed for the metal F0
! term -- so shade_rgb passes base_rgb/255 rather than using the 4-arg
! pbr_specular_simple wrapper (which would substitute mat%color, not
! the caller's actual base colour).  light_dir is L, the unit direction
! TOWARDS the light, matching B56's ndotl = dot(n, light_dir) usage.
!
! Attenuation model (point / spot lights)
! ---------------------------------------
!     a = 1 / max(dist, 1e-4)**decay, capped at 1
! The cap keeps very close lights from blowing out (dist < 1 would
! otherwise give a > 1 for decay > 0); at dist = 1, decay = 2, a = 1.
! decay = 0 disables falloff (a = 1 before any cutoff).  When
! distance > 0 a Three.js-style smooth cutoff is multiplied in:
!     cutoff = clamp(1 - (dist/distance)**4, 0, 1)**2
! so a = 0 at and beyond dist = distance, with a smooth approach.
! Directional lights are never attenuated.
!
! Spot cone
! ---------
! spot_factor compares the angle between the light's spot_dir and the
! direction from the light to the fragment against the outer cone
! angle_deg: 1 at or inside the inner cone angle_deg*(1-penumbra),
! 0 at or outside the outer cone, and a smoothstep in between.
! Non-spot lights always return 1.
!
! Basic materials (mat%mode == 1) are unlit: shade_rgb returns base_rgb
! unchanged; shadow and fog do NOT apply here (the caller handles fog).
module lighting_3d
    use math_3d, only: dp, vec3, vec3_sub, vec3_dot, &
                       vec3_norm, vec3_normalize, vec3_negate, rad2deg
    use material_pbr_3d, only: MaterialPBR, pbr_specular
    implicit none
    private
    public :: Light3, LightSet
    public :: light_attenuation, spot_factor, shade_rgb

    type :: Light3
        integer :: kind = 0              ! 0 directional, 1 point, 2 spot
        type(vec3) :: dir                ! directional: direction light travels
        type(vec3) :: pos                ! point/spot: position
        integer :: color(3) = [255, 255, 255]
        real(dp) :: intensity = 1.0_dp
        real(dp) :: distance = 0.0_dp    ! 0 = no cutoff (point/spot)
        real(dp) :: decay = 2.0_dp
        real(dp) :: angle_deg = 45.0_dp  ! spot: outer cone angle
        real(dp) :: penumbra = 0.0_dp    ! spot: 0..1 soft edge fraction
        type(vec3) :: spot_dir           ! spot: direction the cone points
    end type Light3

    type :: LightSet
        type(Light3), allocatable :: items(:)
        real(dp) :: ambient = 0.25_dp
        integer :: ambient_color(3) = [255, 255, 255]
    end type LightSet

contains

    pure function clamp_real(x, lo, hi) result(r)
        real(dp), intent(in) :: x, lo, hi
        real(dp) :: r
        r = min(max(x, lo), hi)
    end function clamp_real

    ! Distance falloff for point/spot lights; see the module header for
    ! the exact model (inverse-power, capped at 1, smooth cutoff).
    pure function light_attenuation(dist, distance, decay) result(a)
        real(dp), intent(in) :: dist, distance, decay
        real(dp) :: a
        real(dp) :: d, cutoff

        d = max(dist, 0.0_dp)
        ! decay = 0 needs no special case: x**0 = 1 for the (positive)
        ! clamped distance, giving a = 1 before any cutoff.
        a = min(1.0_dp / (max(d, 1.0e-4_dp) ** decay), 1.0_dp)
        if (distance > 0.0_dp) then
            cutoff = clamp_real(1.0_dp - (d / distance) ** 4, 0.0_dp, 1.0_dp)
            a = a * cutoff * cutoff
        end if
    end function light_attenuation

    ! Spot cone factor: 1 inside the inner cone, smoothstep to 0 at the
    ! outer cone, 1 for non-spot lights.  to_frag_dir is the direction
    ! from the light towards the fragment (need not be normalised).
    ! A spot light with a zero spot_dir has no defined cone axis and
    ! contributes a factor of 0.
    pure function spot_factor(light, to_frag_dir) result(f)
        type(Light3), intent(in) :: light
        type(vec3), intent(in) :: to_frag_dir
        real(dp) :: f
        real(dp) :: cos_ang, ang_deg, outer, inner, pen, t
        type(vec3) :: axis, frag

        if (light%kind /= 2) then
            f = 1.0_dp
            return
        end if
        if (vec3_norm(light%spot_dir) <= 1.0e-12_dp .or. &
            vec3_norm(to_frag_dir) <= 1.0e-12_dp) then
            f = 0.0_dp
            return
        end if

        axis = vec3_normalize(light%spot_dir)
        frag = vec3_normalize(to_frag_dir)
        cos_ang = clamp_real(vec3_dot(axis, frag), -1.0_dp, 1.0_dp)
        ang_deg = rad2deg(acos(cos_ang))

        outer = max(light%angle_deg, 0.0_dp)
        if (outer <= 0.0_dp) then
            f = 0.0_dp
            return
        end if
        pen = clamp_real(light%penumbra, 0.0_dp, 1.0_dp)
        inner = outer * (1.0_dp - pen)

        if (ang_deg <= inner) then
            f = 1.0_dp
        else if (ang_deg >= outer) then
            f = 0.0_dp
        else
            t = (outer - ang_deg) / (outer - inner)
            f = t * t * (3.0_dp - 2.0_dp * t)
        end if
    end function spot_factor

    ! Shade one fragment.  base_rgb is the integer base colour (0..255);
    ! the material's own color field is not used here -- the caller folds
    ! material/texture colour into base_rgb.  Returns integer RGB clamped
    ! to 0..255 (truncating conversion, as in the v1 renderer).
    !
    ! shadow_factor (clamped to 0..1) multiplies every light's diffuse
    ! and specular contribution but never the ambient term, so a fully
    ! shadowed fragment keeps exactly its ambient colour.
    ! The light_dir passed to pbr_specular is L, the unit direction
    ! TOWARDS the light.
    pure function shade_rgb(base_rgb, normal, world_pos, cam_pos, lights, mat, shadow_factor) result(rgb)
        integer, intent(in) :: base_rgb(3)
        type(vec3), intent(in) :: normal, world_pos, cam_pos
        type(LightSet), intent(in) :: lights
        type(MaterialPBR), intent(in) :: mat
        real(dp), intent(in) :: shadow_factor
        integer :: rgb(3)

        type(vec3) :: n, view_dir, l_dir, to_light
        real(dp) :: base_real(3), base01(3), accum(3), spec_rgb(3)
        real(dp) :: shadow, dist, atten, spotf, diffuse, weight
        integer :: i, k

        if (mat%mode == 1) then
            ! basic: unlit, base colour as-is (shadow/fog handled by caller)
            rgb = min(255, max(0, base_rgb))
            return
        end if

        shadow = clamp_real(shadow_factor, 0.0_dp, 1.0_dp)
        n = vec3_normalize(normal)
        view_dir = vec3_normalize(vec3_sub(cam_pos, world_pos))

        do k = 1, 3
            base_real(k) = real(base_rgb(k), dp)
            base01(k) = base_real(k) / 255.0_dp
            accum(k) = lights%ambient * base_real(k) * &
                       (real(lights%ambient_color(k), dp) / 255.0_dp)
        end do

        ! (1 - ambient) weights the diffuse sum so the single-directional
        ! case reproduces the legacy intensity formula exactly.
        weight = 1.0_dp - lights%ambient

        if (allocated(lights%items)) then
            do i = 1, size(lights%items)
                select case (lights%items(i)%kind)
                case (1, 2) ! point / spot
                    to_light = vec3_sub(lights%items(i)%pos, world_pos)
                    dist = vec3_norm(to_light)
                    if (dist <= 1.0e-12_dp) cycle ! light at fragment: no defined L
                    l_dir = vec3_normalize(to_light)
                    atten = light_attenuation(dist, lights%items(i)%distance, &
                                               lights%items(i)%decay)
                    ! direction from light to fragment is -L
                    spotf = spot_factor(lights%items(i), vec3_negate(l_dir))
                case default ! 0 directional (unknown kinds act directional)
                    l_dir = vec3_normalize(vec3_negate(lights%items(i)%dir))
                    atten = 1.0_dp
                    spotf = 1.0_dp
                end select

                diffuse = max(0.0_dp, vec3_dot(n, l_dir)) * atten * spotf * &
                          shadow * lights%items(i)%intensity
                spec_rgb = pbr_specular(n, view_dir, l_dir, mat, base01)

                do k = 1, 3
                    accum(k) = accum(k) &
                        + weight * base_real(k) * diffuse * &
                          (real(lights%items(i)%color(k), dp) / 255.0_dp) &
                        + spec_rgb(k) * atten * spotf * shadow * &
                          lights%items(i)%intensity * &
                          (real(lights%items(i)%color(k), dp) / 255.0_dp) * 255.0_dp
                end do
            end do
        end if

        do k = 1, 3
            rgb(k) = int(min(255.0_dp, max(0.0_dp, accum(k))))
        end do
    end function shade_rgb

end module lighting_3d
