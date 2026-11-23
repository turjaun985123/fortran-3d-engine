! fragment_v3.f90 -- Forge3D v3.0 Phase 2: the ONE fragment stage.
!
! Module fragment_v3_3d collapses the legacy renderer's three
! per-object shading paths (renderer.f90: framebuffer_render_mesh_mat,
! framebuffer_render_mesh_env, framebuffer_render_mesh_shader -- the
! plain framebuffer_render_mesh is a thin wrapper over _mat) into a
! single entry point, frag_shade, called once per pixel by the v3
! visibility-buffer rasterizer (renderer_v3).  The three legacy
! behaviours survive as three STAGES behind that one entry point:
!
!   1. shader stage  (fin%shader_id > 0)
!        Mirrors framebuffer_render_mesh_shader / draw_triangle_shader
!        in renderer.f90: the scene's RPN program (shader_3d) is
!        evaluated once per channel with c = that channel of the base
!        colour, r/g/b = the full base colour, x/y/z = world position,
!        u/v = texture coordinates, ndl = the Lambert term against the
!        scene's key directional light, t = time.  The result is
!        clamped to 0..1 and NOT pre-scaled by ambient/intensity (the
!        legacy shader path deliberately leaves lighting to the
!        program; that is what makes the identity shader `c` reproduce
!        the unlit flat render).
!        Two deliberate v3 differences from the legacy path, both
!        forced by the pinned frag_shade API:
!          * u/v are the fragment's interpolated texture coordinates
!            (fin%uv).  The legacy path passed the second/third
!            BARYCENTRIC weights as u/v (draw_triangle_shader:
!            u_interp = w1, v_interp = w2) -- a quirk, not a UV.
!          * t is 0: frag_in carries no time and frag_shade takes no
!            time argument, so time-animated shaders are frozen at
!            t = 0 until the API grows a time field.
!   2. env stage     (object's PBR material is MAT_STANDARD, or the
!                     object carries a loaded texture)
!        Mirrors framebuffer_render_mesh_env / draw_triangle_env in
!        renderer.f90: per-pixel lighting_3d shade_rgb with the
!        object's MaterialPBR, and -- when a texture is loaded -- the
!        base colour REPLACED by texture_3d's nearest/repeat sample
!        at fin%uv (the legacy env path ignores the material/triangle
!        colour for textured objects in exactly this way).
!        Trigger mirror: scene_load routes a scene to the env path
!        when any object has a loaded texture or mat_name 'standard'
!        (scene.f90, end of scene_load); per fragment the same two
!        conditions on the fragment's own object select this stage.
!   3. material stage (everything else)
!        Mirrors framebuffer_render_mesh_mat: Lambert diffuse with
!        ambient floor intensity = ambient + (1 - ambient) * diffuse,
!        mode 1 (basic) unlit, mode 2 (phong) Lambert + specular.
!        It is evaluated through the SAME shared routine as the env
!        stage (shade_lit below, i.e. lighting_3d's shade_rgb with
!        the object's PBR view of its legacy Material): lighting.f90's
!        header documents that shade_rgb reproduces the _mat formula
!        exactly for the legacy single-directional case, and
!        pbr_specular supplies the phong/standard specular, so there
!        is exactly ONE light-accumulation loop in the v3 pipeline
!        and it lives in lighting_3d.  The genuine per-pixel (vs
!        legacy per-triangle) difference: the normal is the
!        interpolated fin%nrm and the view direction uses fin%wp,
!        not the triangle face normal / centroid.
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
! in.  The legacy fog_blend rounds to integers; here the mix is done
! in float, differing by less than 1/255.
!
! Backface: fin%backface negates the (unnormalised) interpolated
! normal before any lighting, giving two-sided lighting.  The legacy
! paths never see backfaces (screen-space winding culling in every
! rasteriser), so there is no legacy behaviour to mirror; this is
! the v3 double-sided rule (Phase 2 R4).
!
! SHADOW LIMITATION (L1, knowingly carried in Phase 2): the legacy
! env path takes ONE shadow factor for the whole fragment from the
! single shadow map of the key light (draw_triangle_env: shadow_mode
! 1 -> shadow_factor, >= 2 -> shadow_factor_pcf, bias 0.002, applied
! inside shade_rgb to every light).  frag_shade's pinned signature
! receives no ShadowMap and Scene carries none, so no map can be
! queried here and the factor is 1 (fully lit) in Phase 2.  Phase 3
! replaces this with per-light shadow maps; the factor already
! enters through the single sfac argument of shade_lit, so that
! change is local to this module.
!
! Colour: inputs and output are linear RGB 0..1 (real32 at the API
! boundary, per ADR-4's real32 v3 pipeline).  Internally the legacy
! dp helpers are used, and shade_rgb's 0..255 integer return is
! divided back by 255, so lit results carry the legacy 8-bit
! quantisation (truncation) -- matching legacy semantics was the
! Phase 2 brief; Phase 3's linear pipeline retires it.
module fragment_v3_3d
    use, intrinsic :: iso_fortran_env, only: real32
    use math_3d, only: dp, vec3, vec3_create, vec3_sub, vec3_dot, &
                       vec3_norm, vec3_normalize, vec3_negate
    use scene_3d, only: Scene
    use material_pbr_3d, only: MaterialPBR, MAT_STANDARD, pbr_default
    use lighting_3d, only: Light3, LightSet, shade_rgb
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

contains

    subroutine frag_shade(fin, sc, rgb)
        type(frag_in), intent(in) :: fin
        type(Scene), intent(in) :: sc        ! from scene_3d (src/scene.f90)
        real(real32), intent(out) :: rgb(3)  ! linear RGB out

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
            !                     roughness 1), so shade_rgb reproduces
            !                     the _mat lambert/basic/phong modes.
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
            rgb(k) = real(clamp01d(out01(k)), real32)
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
    ! Stages 2+3 shared light accumulation: lighting_3d's shade_rgb
    ! over the scene's effective LightSet.  sfac is the single shadow
    ! factor for the key light (Phase 2: 1 -- see the L1 note in the
    ! header); shade_rgb applies it to every light's diffuse and
    ! specular but never to the ambient term, exactly as the legacy
    ! env path's draw_triangle_env arranged.
    ! ------------------------------------------------------------------
    subroutine shade_lit(sc, base01, n, wp, pbr, out01)
        type(Scene), intent(in) :: sc
        real(dp), intent(in) :: base01(3)
        type(vec3), intent(in) :: n, wp
        type(MaterialPBR), intent(in) :: pbr
        real(dp), intent(out) :: out01(3)

        type(LightSet) :: lights
        integer :: base_rgb(3), lit_rgb(3), k
        real(dp), parameter :: sfac = 1.0_dp  ! L1: Phase 3 per-light maps

        call effective_lights(sc, lights)
        do k = 1, 3
            base_rgb(k) = nint(clamp01d(base01(k)) * 255.0_dp)
        end do
        lit_rgb = shade_rgb(base_rgb, n, wp, sc%cam%position, &
                            lights, pbr, sfac)
        do k = 1, 3
            out01(k) = real(lit_rgb(k), dp) / 255.0_dp
        end do
        if (allocated(lights%items)) deallocate(lights%items)
    end subroutine shade_lit

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
