! fragment_v3.f90 -- Forge3D v3.0: the ONE fragment stage.
!
! Module fragment_v3_3d collapses the legacy renderer's three
! per-object shading paths (renderer.f90: framebuffer_render_mesh_mat,
! framebuffer_render_mesh_env, framebuffer_render_mesh_shader -- the
! plain framebuffer_render_mesh is a thin wrapper over _mat) into a
! single entry point, frag_shade, called once per pixel by the v3
! visibility-buffer rasterizer (renderer_v3).  The three legacy
! behaviours survive as three STAGES behind that one entry point:
!
!   1. shader stage  (fin%shader_id > 0) -- UNCHANGED in Phase 3.
!        Mirrors framebuffer_render_mesh_shader / draw_triangle_shader
!        in renderer.f90: the scene's RPN program (shader_3d) is
!        evaluated once per channel with c = that channel of the base
!        colour, r/g/b = the full base colour, x/y/z = world position,
!        u/v = texture coordinates, ndl = the Lambert term against the
!        scene's key directional light, t = time.  The result is
!        clamped to 0..1 and NOT pre-scaled by ambient/intensity (the
!        legacy shader path deliberately leaves lighting to the
!        program; that is what makes the identity shader `c` reproduce
!        the unlit flat render).  This stage defines its own colour
!        semantics, so Phase 3's lighting rewrite does not touch it.
!        Two deliberate v3 differences from the legacy path, both
!        forced by the pinned frag_shade API:
!          * u/v are the fragment's interpolated texture coordinates
!            (fin%uv).  The legacy path passed the second/third
!            BARYCENTRIC weights as u/v -- a quirk, not a UV.
!          * t is 0: frag_in carries no time and frag_shade takes no
!            time argument, so time-animated shaders are frozen at
!            t = 0 until the API grows a time field.
!   2. env stage     (object's PBR material is MAT_STANDARD, or the
!                     object carries a loaded texture)
!        Trigger mirror: scene_load routes a scene to the env path
!        when any object has a loaded texture or mat_name 'standard'
!        (scene.f90, end of scene_load); per fragment the same two
!        conditions on the fragment's own object select this stage.
!        When a texture is loaded the base colour is REPLACED by
!        texture_3d's nearest/repeat sample at fin%uv (the legacy
!        env path ignores the material/triangle colour for textured
!        objects in exactly this way).  Lighting is the Phase 3
!        model below.
!   3. material stage (everything else)
!        The object's PBR record, which scene_build_object_mesh
!        derived from the legacy Material via pbr_from_material
!        (metalness 0, roughness 1), so mode 0 = lambert, mode 1 =
!        basic (unlit), mode 2 = phong.  With no object, that same
!        PBR view is synthesised from fin%mat_id (legacy material
!        ids: 0 lambert, 1 basic, 2 phong, 3 standard) and fin%col.
!        The genuine per-pixel (vs legacy per-triangle) difference:
!        the normal is the interpolated fin%nrm and the view
!        direction uses fin%wp, not the triangle face normal /
!        centroid.
!
! =====================================================================
! Phase 3 lighting model (stages 2+3; replaces the Phase 2 delegation
! to lighting_3d's shade_rgb -- ADR-1 freezes shade_rgb itself, other
! callers depend on it, so the v3 model is implemented locally here)
! =====================================================================
! All accumulation is real32 linear (ADR-4); there is NO 8-bit
! quantisation anywhere on this path (the Phase 2 /255 round-trip
! through shade_rgb's integer return is gone) and NO output clamp:
! with an intense light the result exceeds 1.0 (HDR) and tone mapping
! is the post pipeline's job.
!
! Per light i (directional / point / spot with lighting.f90's
! LightSet semantics: light_attenuation for distance/decay,
! spot_factor for the cone -- those two pure helpers are reused
! verbatim, they do not quantise):
!
!   L     = unit direction towards the light
!   ndl   = max(0, n . L)
!   sfac  = shadow_v3_factor(i, wp, n)        (per-light, L1 fix)
!   diff  = albedo * (1 - metalness if MAT_STANDARD else 1)
!           * ndl * atten * spot * sfac * intensity * light_colour
!   spec  = GGX (below) * atten * spot * sfac * intensity * colour
!
! Lambert convention (energy-conserving form, exposure-matched):
! the diffuse BRDF is f_d = albedo / pi and each light's irradiance
! is defined as E = pi * intensity * (colour/255), so the pi factors
! cancel and the diffuse radiance is albedo * ndl * intensity *
! colour -- exactly the per-light diffuse scale the legacy formula
! used BEFORE its (1 - ambient) weighting.  Phase 3 retires that
! weighting on the v3 path (docs/V3-PLAN.md Phase 3), and the flat
! ambient term is replaced by hemisphere ambient (below), so the
! overall exposure delta vs legacy at the reference configuration
! (ambient 0.25, one unit white directional, up-facing white
! surface) is: legacy 1.00 -> v3 1.25, i.e. a factor (1 + ambient);
! in general v3 = legacy + ambient * albedo for a fully lit
! up-facing fragment, and multi-light sums grow by the same
! retirement (each light now contributes unweighted).
!
! GGX specular (MAT_STANDARD only), Cook-Torrance form:
!   H = normalize(V + L);  alpha = roughness^2 (roughness clamped
!   to [0.05, 1], the ggx_distribution convention in material_pbr);
!   D = alpha^2 / (pi * (ndoth^2 * (alpha^2 - 1) + 1)^2)
!       (Trowbridge-Reitz)
!   G = G1(ndotv) * G1(ndotl),  G1(x) = x / (x*(1-k) + k),
!       k = (roughness + 1)^2 / 8   (Smith via Schlick-GGX)
!   F = F0 + (1 - F0) * (1 - vdoth)^5   (Schlick)
!   F0 = mix(0.04, albedo, metalness)   (dielectrics 0.04, metals
!       tinted by the base colour -- the base_f0 convention)
!   spec = D * G * F / (4 * ndotv * ndl) * E * ndl
!        = D * G * F * pi / (4 * ndotv) * intensity * colour * ...
! Unlike material_pbr_3d's pbr_specular, the result is NOT passed
! through a 1e4 clamp: the HDR pipeline wants the true highlight
! value (at roughness 0.05 head-on, D alone is ~5.1e4 and the
! dielectric specular peak is ~1.6e3 for a unit light).
! The math is factored locally (real32) rather than calling
! pbr_specular because pbr_specular omits the irradiance factor
! (pi * ndl) and applies that clamp; its D/F0 conventions are
! followed exactly.
!
! Phong materials (mode 2) keep the LEGACY specular scale on
! purpose: factor = specular * max(0, R . V)^shininess with
! R = 2*ndl*n - L, added as factor * atten * spot * sfac *
! intensity * colour (no pi, no ndl weighting) -- byte-for-byte
! the scale shade_rgb gave them, so phong scenes do not change
! brightness under the v3 lighting rewrite.
!
! Hemisphere ambient (replaces the flat ambient term):
!   sky    = lights%ambient_color / 255   (the scene's ambient
!          colour; scene_load and effective_lights both set it to
!          white -- there is no dedicated hemi pair in Scene)
!   ground = 0.3 * sky                    (documented derivation)
!   t      = 0.5 + 0.5 * n.y              (world up is +Y)
!   amb    = albedo * lights%ambient * mix(ground, sky, t)
! An up-facing fragment therefore receives exactly the legacy flat
! ambient; a down-facing one receives 0.3x it; a zero normal gets
! t = 0.5 (0.65x).  Shadows never touch the ambient term.
!
! Shadows (L1 fix): shadow_v3_3d's shadow_v3_factor is queried
! PER LIGHT inside the accumulation and multiplies only that
! light's diffuse + specular.  The renderer builds the maps first
! (shadow_v3_build, not this module's job); with no maps built the
! factor is 1 (fully lit).  The index passed is the light's index
! in the effective LightSet, which IS sc%lights when the scene
! carries one (the pinned indexing), and 1 for the single
! directional light effective_lights rebuilds from the legacy
! fields of a hand-built scene.
!
! Shared post-stage: fog.  The legacy paths apply fog as a
! framebuffer post-pass (main.f90 calls fog_apply after the env
! loop; fog.f90).  Per fragment the same factors are applied here:
! linear f = clamp((dist - near) / (far - near)) and exp2
! f = 1 - exp(-(density * dist)**2), colour mixed towards
! sc%fog_color.  dist is the VIEW depth, dot(wp - cam_pos, forward)
! with forward = normalize(cam_target - cam_pos) -- the same view-
! axis depth fog_3d reconstructs from NDC depth
! (view_distance_from_ndc), not the Euclidean distance.  The factor
! formulas are restated locally (two lines each) rather than by
! using fog_3d, because fog_3d depends on the legacy renderer_3d
! FrameBuffer and the v3 pipeline must not pull the frozen renderer
! in.  The legacy fog_blend rounds to integers; here the mix is
! done in float.
!
! Backface: fin%backface negates the interpolated normal before
! any lighting, giving two-sided lighting.  The legacy paths never
! see backfaces (screen-space winding culling in every
! rasteriser), so there is no legacy behaviour to mirror; this is
! the v3 double-sided rule (Phase 2 R4).
!
! Colour: inputs are linear RGB 0..1; the output is linear RGB
! real32, NOT clamped above (HDR, see above) and floored at 0.
module fragment_v3_3d
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d, only: dp, vec3, vec3_create, vec3_sub, vec3_dot, &
                       vec3_norm, vec3_normalize, vec3_negate
    use scene_3d, only: Scene
    use material_pbr_3d, only: MaterialPBR, MAT_STANDARD, pbr_default
    use lighting_3d, only: Light3, LightSet, light_attenuation, &
                           spot_factor
    use shadow_v3_3d, only: shadow_v3_factor
    use texture_3d, only: texture_sample
    use shader_3d, only: ShaderProg, shader_eval
    implicit none
    private
    public :: frag_in, frag_shade

    type, public :: frag_in
       real(real32) :: wp(3)      ! world position
       real(real32) :: nrm(3)     ! interpolated normal (not yet normalized)
       real(real32) :: uv(2)
       real(real32) :: col(3)     ! base colour 0..1
       integer :: mat_id = 0
       integer :: obj_id = 0      ! scene object index, 0 = none
       integer :: shader_id = 0   ! custom shader def index, 0 = none
       logical :: backface = .false.
    end type frag_in

    real(real32), parameter :: PI32 = 3.14159265_real32

contains

    subroutine frag_shade(fin, sc, rgb)
        type(frag_in), intent(in) :: fin
        type(Scene), intent(in) :: sc        ! from scene_3d (src/scene.f90)
        real(real32), intent(out) :: rgb(3)  ! linear RGB out (HDR: may exceed 1)

        type(vec3) :: wp, n
        real(dp) :: base01(3), out01(3)
        type(MaterialPBR) :: pbr
        logical :: has_obj, is_env
        integer :: k

        wp = vec3_create(real(fin%wp(1), dp), real(fin%wp(2), dp), &
                         real(fin%wp(3), dp))
        n = vec3_create(real(fin%nrm(1), dp), real(fin%nrm(2), dp), &
                        real(fin%nrm(3), dp))
        ! Two-sided lighting: flip BEFORE any stage's lighting.
        if (fin%backface) n = vec3_negate(n)

        do k = 1, 3
            base01(k) = clamp01d(real(fin%col(k), dp))
        end do

        has_obj = fin%obj_id >= 1 .and. allocated(sc%objects) .and. &
                  fin%obj_id <= sc%n_objects

        ! ---- Stage dispatch: ONE entry point, three stages. ----
        if (fin%shader_id > 0) then
            call shade_shader_stage(fin, sc, wp, n, base01, out01)
        else
            ! Env trigger (mirrors the scene_load env routing, per
            ! object): standard PBR material or a loaded texture.
            is_env = .false.
            if (has_obj) then
                if (sc%objects(fin%obj_id)%pbr%mode == MAT_STANDARD &
                    .or. sc%objects(fin%obj_id)%tex%loaded) &
                    is_env = .true.
            end if

            ! Nested ifs, not .and.: Fortran does not short-circuit,
            ! and obj_id may be 0 here (is_env is false then).
            if (is_env) then
                if (sc%objects(fin%obj_id)%tex%loaded) then
                    ! Legacy env rule: a loaded texture REPLACES the
                    ! base colour (nearest neighbour, REPEAT wrap, as
                    ! texture_sample defines).
                    block
                        integer :: tex_rgb(3)
                        tex_rgb = texture_sample( &
                            sc%objects(fin%obj_id)%tex, &
                            real(fin%uv(1), dp), real(fin%uv(2), dp))
                        do k = 1, 3
                            base01(k) = real(tex_rgb(k), dp) / 255.0_dp
                        end do
                    end block
                end if
            end if

            ! Both lit stages share shade_lit; the stage difference
            ! is only WHICH PBR record and base colour feed it:
            !   env stage      -> the object's full PBR record
            !                     (metalness/roughness from objmat).
            !   material stage -> also the object's PBR record, which
            !                     scene_build_object_mesh derived from
            !                     the legacy Material via
            !                     pbr_from_material (metalness 0,
            !                     roughness 1).
            ! With no object, synthesise that same PBR view from
            ! fin%mat_id (legacy material ids: 0 lambert, 1 basic,
            ! 2 phong, 3 standard -- material_id_from_name plus
            ! MAT_STANDARD) and fin%col.
            if (has_obj) then
                pbr = sc%objects(fin%obj_id)%pbr
            else
                pbr = pbr_default()
                pbr%color = base01
                pbr%use_tri_color = .false.
                if (fin%mat_id >= 0 .and. fin%mat_id <= 3) &
                    pbr%mode = fin%mat_id
            end if
            call shade_lit(sc, base01, n, wp, pbr, out01)
        end if

        ! ---- Shared post-stage: fog (see header). ----
        call apply_fog(sc, wp, out01)

        do k = 1, 3
            ! HDR: floor at 0 only -- NO upper clamp on the v3 path
            ! (tone mapping lives in the post pipeline).
            rgb(k) = real(max(out01(k), 0.0_dp), real32)
        end do
    end subroutine frag_shade

    ! ------------------------------------------------------------------
    ! Stage 1: custom RPN shader (legacy _shader path).
    ! Program resolution: fin%shader_id indexes sc%shader_defs
    ! (1-based, the SceneShaderDef list scene_load builds); when that
    ! index is out of range, fall back to the fragment object's own
    ! bound program (SceneObject%shader_prog, set by the same
    ! scene_load shaderbind resolution); when neither exists the
    ! stage is the identity (base colour), matching shader_3d's
    ! empty-program rule.
    ! ------------------------------------------------------------------
    subroutine shade_shader_stage(fin, sc, wp, n, base01, out01)
        type(frag_in), intent(in) :: fin
        type(Scene), intent(in) :: sc
        type(vec3), intent(in) :: wp, n
        real(dp), intent(in) :: base01(3)
        real(dp), intent(out) :: out01(3)

        type(ShaderProg) :: prog
        logical :: have_prog
        type(vec3) :: l_dir
        real(dp) :: ndl, val
        integer :: k

        have_prog = .false.
        if (allocated(sc%shader_defs)) then
            if (fin%shader_id >= 1 .and. &
                fin%shader_id <= size(sc%shader_defs)) then
                prog = sc%shader_defs(fin%shader_id)%prog
                have_prog = .true.
            end if
        end if
        if (.not. have_prog .and. fin%obj_id >= 1 .and. &
            allocated(sc%objects) .and. &
            fin%obj_id <= sc%n_objects) then
            if (sc%objects(fin%obj_id)%has_shader) then
                prog = sc%objects(fin%obj_id)%shader_prog
                have_prog = .true.
            end if
        end if
        if (.not. have_prog) then
            out01 = base01
            return
        end if

        ! ndl mirrors draw_triangle_shader's per-triangle diffuse:
        ! max(0, dot(normal, -normalize(light_dir))) with the scene's
        ! key directional light -- here with the fragment's
        ! interpolated (and possibly backface-flipped) normal.
        l_dir = vec3_normalize(vec3_negate(sc%light_dir))
        if (vec3_norm(n) > 1.0e-12_dp) then
            ndl = max(0.0_dp, vec3_dot(vec3_normalize(n), l_dir))
        else
            ndl = 0.0_dp
        end if

        ! One evaluation per channel, c = that channel, exactly as
        ! draw_triangle_shader loops k = 1..3 over shader_eval.
        ! t = 0 (no time in the pinned API; see header).
        do k = 1, 3
            val = shader_eval(prog, base01(k), &
                              base01(1), base01(2), base01(3), &
                              wp%x, wp%y, wp%z, &
                              real(fin%uv(1), dp), &
                              real(fin%uv(2), dp), &
                              ndl, 0.0_dp)
            out01(k) = clamp01d(val)
        end do
    end subroutine shade_shader_stage

    ! ------------------------------------------------------------------
    ! Stages 2+3 shared light accumulation: the Phase 3 v3 lighting
    ! model documented in the module header (energy-conserving
    ! Lambert + GGX, per-light shadow factors, hemisphere ambient),
    ! accumulated in real32 throughout -- no shade_rgb, no /255
    ! round-trip, no clamp.  base01 / n / wp arrive as dp (the
    ! shader stage's types); they are narrowed to real32 once here
    ! and everything below is real32.
    ! ------------------------------------------------------------------
    subroutine shade_lit(sc, base01, n, wp, pbr, out01)
        type(Scene), intent(in) :: sc
        real(dp), intent(in) :: base01(3)
        type(vec3), intent(in) :: n, wp
        type(MaterialPBR), intent(in) :: pbr
        real(dp), intent(out) :: out01(3)

        type(LightSet) :: lights
        real(real32) :: base(3), wp32(3), nrm32(3), accum(3)
        integer :: k

        do k = 1, 3
            base(k) = real(clamp01d(base01(k)), real32)
        end do
        wp32 = [real(wp%x, real32), real(wp%y, real32), &
                real(wp%z, real32)]
        nrm32 = [real(n%x, real32), real(n%y, real32), &
                 real(n%z, real32)]

        if (pbr%mode == 1) then
            ! basic: unlit, base colour as-is (legacy _mat mode 1;
            ! shadow/ambient do not apply).
            accum = base
        else
            call effective_lights(sc, lights)
            call accumulate_v3(sc, lights, base, wp32, nrm32, pbr, &
                               accum)
            if (allocated(lights%items)) deallocate(lights%items)
        end if

        do k = 1, 3
            out01(k) = real(accum(k), dp)
        end do
    end subroutine shade_lit

    ! The Phase 3 accumulation proper.  See the module header for
    ! the equations and conventions.
    subroutine accumulate_v3(sc, lights, base, wp, nrm, pbr, accum)
        type(Scene), intent(in) :: sc
        type(LightSet), intent(in) :: lights
        real(real32), intent(in) :: base(3), wp(3), nrm(3)
        type(MaterialPBR), intent(in) :: pbr
        real(real32), intent(out) :: accum(3)

        real(real32) :: n(3), v(3), cam(3)
        real(real32) :: sky(3), gnd(3), hemi_t, amb
        real(real32) :: metal, kd
        integer :: i, k

        n = normalize3(nrm)
        cam = [real(sc%cam%position%x, real32), &
               real(sc%cam%position%y, real32), &
               real(sc%cam%position%z, real32)]
        v = normalize3(cam - wp)

        ! ---- Hemisphere ambient (never shadowed). ----
        do k = 1, 3
            sky(k) = real(lights%ambient_color(k), real32) / 255.0_real32
            gnd(k) = 0.3_real32 * sky(k)
        end do
        hemi_t = 0.5_real32 + 0.5_real32 * n(2)
        amb = real(lights%ambient, real32)
        do k = 1, 3
            accum(k) = base(k) * amb * &
                       (gnd(k) + (sky(k) - gnd(k)) * hemi_t)
        end do

        metal = real(min(1.0_dp, max(0.0_dp, pbr%metalness)), real32)
        kd = 1.0_real32
        if (pbr%mode == MAT_STANDARD) kd = 1.0_real32 - metal

        if (.not. allocated(lights%items)) return

        do i = 1, size(lights%items)
            call accumulate_light(lights%items(i), i, base, wp, n, v, &
                                  pbr, kd, metal, accum)
        end do
    end subroutine accumulate_v3

    ! One light's diffuse + specular contribution, multiplied by
    ! that light's own shadow factor only (the L1 fix).
    subroutine accumulate_light(lt, light_index, base, wp, n, v, &
                                pbr, kd, metal, accum)
        type(Light3), intent(in) :: lt
        integer, intent(in) :: light_index
        real(real32), intent(in) :: base(3), wp(3), n(3), v(3)
        type(MaterialPBR), intent(in) :: pbr
        real(real32), intent(in) :: kd, metal
        real(real32), intent(inout) :: accum(3)

        real(real32) :: l(3), lcol(3), to_light(3)
        real(real32) :: dist, atten, spotf, sfac, ndl, common
        real(real32) :: spec(3)
        integer :: k

        do k = 1, 3
            lcol(k) = real(lt%color(k), real32) / 255.0_real32
        end do

        select case (lt%kind)
        case (1, 2)  ! point / spot
            to_light = [real(lt%pos%x, real32) - wp(1), &
                        real(lt%pos%y, real32) - wp(2), &
                        real(lt%pos%z, real32) - wp(3)]
            dist = sqrt(dot3(to_light, to_light))
            if (dist <= 1.0e-6_real32) return  ! light at fragment: no L
            l = to_light / dist
            atten = real(light_attenuation(real(dist, dp), &
                                           lt%distance, lt%decay), &
                         real32)
            ! Direction from the light to the fragment is -L.
            spotf = real(spot_factor(lt, vec3_create( &
                -real(l(1), dp), -real(l(2), dp), -real(l(3), dp))), &
                real32)
        case default  ! 0 directional (unknown kinds act directional)
            l = normalize3([-real(lt%dir%x, real32), &
                            -real(lt%dir%y, real32), &
                            -real(lt%dir%z, real32)])
            atten = 1.0_real32
            spotf = 1.0_real32
        end select

        ndl = max(0.0_real32, dot3(n, l))
        if (ndl <= 0.0_real32) return  ! GGX and phong both vanish here

        ! Per-light shadow factor (1 = fully lit; no maps built -> 1).
        sfac = shadow_v3_factor(light_index, wp, n)
        sfac = min(1.0_real32, max(0.0_real32, sfac))

        common = atten * spotf * sfac * real(lt%intensity, real32)

        spec = specular_v3(l, n, v, pbr, base, metal, ndl)

        do k = 1, 3
            accum(k) = accum(k) &
                + base(k) * kd * ndl * common * lcol(k) &
                + spec(k) * common * lcol(k)
        end do
    end subroutine accumulate_light

    ! Specular BRDF times the light's irradiance factor, WITHOUT
    ! the atten/spot/shadow/intensity/colour terms (the caller
    ! applies those via `common` and lcol):
    !   MAT_STANDARD: GGX -- returns D*G*F*pi/(4*ndotv), i.e. the
    !     Cook-Torrance BRDF times E/pi-normalised irradiance with
    !     the ndl of L_o = BRDF * E * ndl already folded in.
    !   mode 2 (phong): the legacy-scale factor
    !     specular * max(0, R.V)^shininess (white, untinted).
    !   anything else: 0.
    function specular_v3(l, n, v, pbr, base, metal, ndl) &
            result(spec)
        real(real32), intent(in) :: l(3), n(3), v(3), base(3)
        type(MaterialPBR), intent(in) :: pbr
        real(real32), intent(in) :: metal, ndl
        real(real32) :: spec(3)

        real(real32) :: h(3), rvec(3)
        real(real32) :: ndotv, ndoth, vdoth, rough, alpha, alpha2
        real(real32) :: dterm, gterm, kg, f0(3), m5, factor
        integer :: k

        spec = 0.0_real32
        if (dot3(v, v) <= 0.0_real32) return  ! camera at fragment

        if (pbr%mode == MAT_STANDARD) then
            ndotv = dot3(n, v)
            if (ndotv <= 0.0_real32) return
            h = normalize3(v + l)
            ndoth = min(1.0_real32, max(0.0_real32, dot3(n, h)))
            vdoth = min(1.0_real32, max(0.0_real32, dot3(v, h)))
            rough = min(1.0_real32, &
                        max(0.05_real32, real(pbr%roughness, real32)))
            alpha = rough * rough
            alpha2 = alpha * alpha
            dterm = alpha2 / (PI32 * &
                (ndoth * ndoth * (alpha2 - 1.0_real32) &
                 + 1.0_real32) ** 2)
            kg = (rough + 1.0_real32) ** 2 / 8.0_real32
            gterm = (ndotv / (ndotv * (1.0_real32 - kg) + kg)) * &
                    (ndl / (ndl * (1.0_real32 - kg) + kg))
            m5 = (1.0_real32 - vdoth) ** 5
            do k = 1, 3
                f0(k) = 0.04_real32 * (1.0_real32 - metal) &
                        + base(k) * metal
                factor = dterm * gterm * &
                         (f0(k) + (1.0_real32 - f0(k)) * m5)
                spec(k) = factor * PI32 / (4.0_real32 * ndotv)
            end do
        else if (pbr%mode == 2) then
            ! Phong, legacy scale (see header): R = 2*ndl*n - L.
            rvec = 2.0_real32 * ndl * n - l
            factor = real(pbr%specular, real32) * &
                max(0.0_real32, dot3(rvec, v)) ** &
                real(pbr%shininess, real32)
            spec = factor
        end if
    end function specular_v3

    pure function dot3(a, b) result(d)
        real(real32), intent(in) :: a(3), b(3)
        real(real32) :: d
        d = a(1) * b(1) + a(2) * b(2) + a(3) * b(3)
    end function dot3

    pure function normalize3(a) result(u)
        real(real32), intent(in) :: a(3)
        real(real32) :: u(3)
        real(real32) :: len
        len = sqrt(dot3(a, a))
        if (len > 1.0e-12_real32) then
            u = a / len
        else
            u = 0.0_real32
        end if
    end function normalize3

    ! The scene's effective LightSet.  A scene built by scene_load
    ! already carries sc%lights (directional first from the legacy
    ! light fields, then point/spot in file order -- scene.f90 end of
    ! scene_load); use it as-is.  A hand-built Scene may carry only
    ! the legacy fields, so rebuild the same one-directional set
    ! scene_load would have assembled.
    subroutine effective_lights(sc, lights)
        type(Scene), intent(in) :: sc
        type(LightSet), intent(out) :: lights

        type(Light3) :: lt

        if (allocated(sc%lights%items)) then
            if (size(sc%lights%items) > 0) then
                lights = sc%lights
                return
            end if
        end if
        lights%ambient = sc%ambient
        lights%ambient_color = [255, 255, 255]
        allocate(lights%items(1))
        lt = Light3()
        lt%kind = 0
        lt%dir = sc%light_dir
        lt%spot_dir = sc%light_dir
        lt%color = sc%light_color
        lt%intensity = sc%light_intensity
        lights%items(1) = lt
    end subroutine effective_lights

    ! ------------------------------------------------------------------
    ! Fog post-stage (legacy fog_3d factors, view-axis depth; see
    ! header for why the formulas are restated, not imported).
    ! ------------------------------------------------------------------
    subroutine apply_fog(sc, wp, rgb01)
        type(Scene), intent(in) :: sc
        type(vec3), intent(in) :: wp
        real(dp), intent(inout) :: rgb01(3)

        type(vec3) :: fwd, rel
        real(dp) :: dist, f
        integer :: k

        if (sc%fog_mode /= 1 .and. sc%fog_mode /= 2) return

        rel = vec3_sub(wp, sc%cam%position)
        fwd = vec3_sub(sc%cam%target, sc%cam%position)
        if (vec3_norm(fwd) > 1.0e-12_dp) then
            dist = vec3_dot(rel, vec3_normalize(fwd))
        else
            dist = vec3_norm(rel)
        end if
        dist = max(0.0_dp, dist)

        select case (sc%fog_mode)
        case (1)  ! linear: fog_factor_linear in fog.f90
            if (sc%fog_far > sc%fog_near) then
                f = (dist - sc%fog_near) / (sc%fog_far - sc%fog_near)
            else if (dist >= sc%fog_far) then
                f = 1.0_dp
            else
                f = 0.0_dp
            end if
        case default  ! 2, exp2: fog_factor_exp2 in fog.f90
            f = 1.0_dp - exp(-(sc%fog_density * dist) ** 2)
        end select
        f = clamp01d(f)

        do k = 1, 3
            rgb01(k) = rgb01(k) * (1.0_dp - f) + &
                       (real(sc%fog_color(k), dp) / 255.0_dp) * f
        end do
    end subroutine apply_fog

    pure function clamp01d(x) result(r)
        real(dp), intent(in) :: x
        real(dp) :: r
        r = min(1.0_dp, max(0.0_dp, x))
    end function clamp01d

end module fragment_v3_3d
