program main
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use scene_3d
    use animation_3d
    use keyframe_3d, only: key_eval
    use sprite_3d, only: sprite_build_mesh
    use text_render_3d, only: text_build_mesh
    use particles_3d, only: particles_build_mesh
    use material_3d, only: Material, material_default
    use shadow_3d
    use fog_3d
    use tonemapping_3d
    use postprocess_3d, only: post_apply_chain
    use camera_ortho_3d, only: ortho_proj_from_size
    use renderer_v3_3d, only: v3_render_scene_fb
    use, intrinsic :: iso_fortran_env, only: error_unit
    implicit none

    type(Mesh) :: cube
    type(Camera) :: cam
    type(FrameBuffer) :: fb
    type(mat4) :: model_rot_y, model_rot_x, model_matrix
    type(vec3) :: eye, target, light_dir
    integer :: width, height
    character(len=128) :: output_file

    ! Scene-mode state (used only when a .scene path argument is given)
    type(Scene) :: sc
    type(mat4) :: model
    type(vec3) :: pos_v, rot_v, scl_v
    character(len=1024) :: scene_path
    character(len=1024) :: errmsg
    character(len=1024) :: numbered_file, base_name, ext_name
    logical :: ok
    integer :: nargs, frame_i, obj_i, anim_i, n_frames, n_objects, dot_pos
    real(dp) :: fps_r, t_sec, scale_factor
    real(dp) :: d_rot(3), d_pos(3), a_rot(3), a_pos(3), a_scale
    ! Wave A env-path state (scene mode only, when sc%has_env)
    type(ShadowMap) :: smap
    type(mat4), allocatable :: models(:)
    type(vec3) :: sh_pos, sh_tgt
    real(dp) :: extents(3)
    integer :: li
    ! Wave B state (scene mode only)
    integer :: track_i, ti
    real(dp) :: k_pos(3), k_rot(3), k_scale
    real(dp) :: sh_near, sh_far, sh_rad, sh_d
    ! v3.0 Phase 2: renderer selection state.
    character(len=64) :: renderer_name, arg_buf, env_val
    integer :: arg_offset, env_len, env_status
    logical :: use_v3
    ! v3.0 Phase 3: filtered post chain for the v3 path ('bloom' is
    ! owned by post_v3_3d on the float buffer; see the call site).
    character(len=32) :: filt_post_names(16), post_lc
    real(dp) :: filt_post_amounts(16)
    integer :: filt_n_post, post_i, lc_i
    type(Scene) :: demo_sc
    type(mat4), allocatable :: demo_models(:)

    nargs = command_argument_count()

    ! Renderer selection: an optional leading '--renderer v3|legacy'
    ! flag wins over the FORGE3D_RENDERER environment variable;
    ! the default is v3.  An unknown value is a clear error, exit 2.
    renderer_name = 'v3'
    env_val = ''
    call get_environment_variable('FORGE3D_RENDERER', env_val, &
                                  length=env_len, status=env_status)
    if (env_status == 0 .and. env_len > 0) &
        renderer_name = env_val(1:min(env_len, 64))
    arg_offset = 0
    if (nargs >= 1) then
        call get_command_argument(1, arg_buf)
        if (trim(arg_buf) == '--renderer') then
            if (nargs < 2) then
                write(error_unit, '(A)') &
                    'error: --renderer requires a value (v3|legacy)'
                stop 2
            end if
            call get_command_argument(2, renderer_name)
            arg_offset = 2
        end if
    end if
    select case (trim(renderer_name))
    case ('v3')
        use_v3 = .true.
    case ('legacy')
        use_v3 = .false.
    case default
        write(error_unit, '(A)') 'error: unknown --renderer value "' &
            // trim(renderer_name) // '" (expected v3|legacy)'
        stop 2
    end select

    if (nargs - arg_offset == 0) then
        ! ================================================================
        ! Legacy demo: no command argument.
        ! This path is the byte-for-byte regression anchor -- do not
        ! change its prints, files or rendering calls.
        !
        ! LEGACY-COMPAT SIDE EFFECTS (S3, v3.0 Phase 0; ADR-1 legacy
        ! freeze): besides the rendered image (output_render.ppm),
        ! this branch also writes scene.json and model.obj for the
        ! demo cube into the CURRENT WORKING DIRECTORY (step 8
        ! below).  Those two extra files are an intentional legacy
        ! behaviour, preserved exactly under the freeze -- callers
        ! and scripts may rely on them appearing in the CWD.  Do not
        ! remove, rename or relocate them without a ruling that
        ! lifts the freeze for this path.
        ! ================================================================
        width = 640
        height = 480
        output_file = 'output_render.ppm'

        print *, '============================================'
        print *, ' Fortran 3D Graphics Engine '
        print *, '============================================'

        ! 1. Initialize FrameBuffer
        print *, '[+] Initializing FrameBuffer (', width, 'x', height, ')...'
        call framebuffer_init(fb, width, height)

        ! 2. Create 3D geometry
        print *, '[+] Creating 3D Cube Mesh...'
        call create_cube(cube, 2.0_dp)
        print *, '    Triangles loaded:', cube%num_triangles

        ! 3. Set up Camera
        eye = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
        target = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        print *, '[+] Setting up Camera at (3.0, 2.5, 4.0) looking at (0, 0, 0)...'
        call camera_init(cam, eye, target, 60.0_dp, real(width, dp)/real(height, dp), 0.1_dp, 100.0_dp)

        ! 4. Set up Model Transform (rotate the cube slightly)
        model_rot_y = mat4_rotate_y(35.0_dp * PI / 180.0_dp)
        model_rot_x = mat4_rotate_x(20.0_dp * PI / 180.0_dp)
        model_matrix = mat4_mult(model_rot_y, model_rot_x)

        ! 5. Directional light source
        light_dir = vec3_create(-0.5_dp, -1.0_dp, -0.7_dp)

        ! 6. Render
        print *, '[+] Rasterizing mesh to FrameBuffer with Z-buffering & shading...'
        if (use_v3) then
            ! v3 path: the same cube / camera / light / model, via a
            ! one-object scene through renderer_v3_3d.
            demo_sc%width = width
            demo_sc%height = height
            demo_sc%bg = [25, 25, 35]
            demo_sc%cam = cam
            demo_sc%light_dir = light_dir
            demo_sc%ambient = 0.25_dp
            allocate(demo_sc%objects(1))
            demo_sc%n_objects = 1
            demo_sc%cap_objects = 1
            demo_sc%objects(1)%prim = 'cube'
            demo_sc%objects(1)%name = 'cube'
            demo_sc%objects(1)%mesh = cube
            allocate(demo_models(1))
            demo_models(1) = model_matrix
            call v3_render_scene_fb(fb, demo_sc, demo_models)
            deallocate(demo_models)
        else
            call framebuffer_render_mesh(fb, cube, model_matrix, cam, light_dir)
        end if

        ! 7. Save output PPM image
        print *, '[+] Writing image to ', trim(output_file), '...'
        call framebuffer_save_ppm(fb, output_file)

        ! 8. Export 3D Mesh for Interactive Web / 3D Viewers
        print *, '[+] Exporting scene.json and model.obj...'
        call export_mesh_json(cube, 'scene.json')
        call export_mesh_obj(cube, 'model.obj')

        print *, '============================================'
        print *, ' Rendering & Export successfully completed!'
        print *, ' Output files: '
        print *, '   - ', trim(output_file)
        print *, '   - scene.json'
        print *, '   - model.obj'
        print *, '============================================'
    else
        ! ================================================================
        ! Scene mode: one argument = path to a .scene file.
        ! ================================================================
        call get_command_argument(1 + arg_offset, scene_path)

        call scene_load(trim(scene_path), sc, ok, errmsg)
        if (.not. ok) then
            write(*, '(A)') 'error: cannot load scene: ' // trim(errmsg)
            stop 1
        end if

        ! v3.0 Phase 2 hybrid fallback (coordinator integration):
        ! the v3 visibility-buffer path does not draw sprites, text
        ! or particles yet.  Rather than silently dropping them on
        ! the default path, scenes that use them render through the
        ! legacy renderer (with a note on stderr) until v3 covers
        ! them.  Geometry-only scenes are unaffected.
        if (use_v3 .and. (sc%n_sprites > 0 .or. sc%n_texts > 0 &
            .or. sc%n_parts > 0)) then
            write(error_unit, '(A)') 'note: scene uses sprites/' &
                // 'text/particles, which the v3 renderer does ' &
                // 'not draw yet -- rendering with --renderer legacy'
            use_v3 = .false.
        end if

        ! Wave C: orthographic camera (row 3). Replace the
        ! perspective projection with the ortho one; view matrix,
        ! near/far and everything else stay as loaded.
        if (sc%ortho) then
            sc%cam%proj_matrix = ortho_proj_from_size( &
                sc%ortho_size, &
                real(sc%width, dp) / real(max(1, sc%height), dp), &
                sc%cam%near_plane, sc%cam%far_plane)
        end if

        n_frames = max(1, sc%frames)
        ! S2: iterate the live count, not the array allocation size.
        n_objects = sc%n_objects

        ! Frame timing comes from the first animation's fps (default 30).
        fps_r = 30.0_dp
        if (sc%n_anims > 0) fps_r = real(sc%anims(1)%fps, dp)
        if (fps_r <= 0.0_dp) fps_r = 30.0_dp

        call framebuffer_init(fb, sc%width, sc%height)
        if (sc%has_env .or. use_v3) allocate(models(max(1, n_objects)))

        do frame_i = 1, n_frames
            t_sec = real(frame_i - 1, dp) / fps_r

            call framebuffer_clear(fb, sc%bg(1), sc%bg(2), sc%bg(3))

            do obj_i = 1, n_objects
                ! Wave B: a keyframe track targeting this object
                ! REPLACES its base pose and closed-form animations
                ! for this frame (absolute pos/rot/scale from
                ! key_eval; scale is the track's uniform scale).
                track_i = 0
                if (allocated(sc%tracks)) then
                    do ti = 1, sc%n_tracks
                        if (trim(sc%tracks(ti)%target) == &
                            trim(sc%objects(obj_i)%name)) then
                            track_i = ti
                            exit
                        end if
                    end do
                end if
                if (track_i > 0) then
                    call key_eval(sc%tracks(track_i), t_sec, k_pos, &
                                  k_rot, k_scale)
                    pos_v = vec3_create(k_pos(1), k_pos(2), k_pos(3))
                    rot_v = vec3_create(k_rot(1), k_rot(2), k_rot(3))
                    scl_v = vec3_create(k_scale, k_scale, k_scale)
                    model = mat4_compose_trs(pos_v, rot_v, scl_v)
                    if (sc%has_env .or. use_v3) then
                        models(obj_i) = model
                    else if (sc%objects(obj_i)%has_shader) then
                        ! Wave E (C2): custom shader path.
                        call framebuffer_render_mesh_shader(fb, &
                            sc%objects(obj_i)%mesh, model, sc%cam, &
                            sc%light_dir, sc%objects(obj_i)%mat, &
                            sc%ambient, sc%objects(obj_i)%shader_prog, &
                            t_sec)
                    else
                        call framebuffer_render_mesh_mat(fb, &
                            sc%objects(obj_i)%mesh, model, sc%cam, &
                            sc%light_dir, sc%objects(obj_i)%mat, &
                            sc%ambient)
                    end if
                    cycle
                end if
                ! Accumulate animation deltas for this object: animations
                ! target it by name, or target 'all'.
                d_rot = 0.0_dp
                d_pos = 0.0_dp
                scale_factor = 1.0_dp
                if (allocated(sc%anims)) then
                    do anim_i = 1, sc%n_anims
                        if (trim(sc%anims(anim_i)%target) == &
                            trim(sc%objects(obj_i)%name) .or. &
                            trim(sc%anims(anim_i)%target) == 'all') then
                            call anim_eval(sc%anims(anim_i)%kind, t_sec, &
                                           sc%anims(anim_i)%speed, &
                                           sc%anims(anim_i)%duration, &
                                           sc%anims(anim_i)%axis, &
                                           sc%anims(anim_i)%loop, &
                                           sc%anims(anim_i)%ease, &
                                           a_rot, a_pos, a_scale)
                            d_rot = d_rot + a_rot
                            d_pos = d_pos + a_pos
                            scale_factor = scale_factor * a_scale
                        end if
                    end do
                end if

                pos_v = vec3_create(sc%objects(obj_i)%pos%x + d_pos(1), &
                                    sc%objects(obj_i)%pos%y + d_pos(2), &
                                    sc%objects(obj_i)%pos%z + d_pos(3))
                rot_v = vec3_create(sc%objects(obj_i)%rot_deg%x + d_rot(1), &
                                    sc%objects(obj_i)%rot_deg%y + d_rot(2), &
                                    sc%objects(obj_i)%rot_deg%z + d_rot(3))
                scl_v = vec3_create(sc%objects(obj_i)%scl%x * scale_factor, &
                                    sc%objects(obj_i)%scl%y * scale_factor, &
                                    sc%objects(obj_i)%scl%z * scale_factor)
                model = mat4_compose_trs(pos_v, rot_v, scl_v)

                if (sc%has_env .or. use_v3) then
                    models(obj_i) = model
                else if (sc%objects(obj_i)%has_shader) then
                    ! Wave E (C2): custom shader path.
                    call framebuffer_render_mesh_shader(fb, &
                        sc%objects(obj_i)%mesh, model, sc%cam, &
                        sc%light_dir, sc%objects(obj_i)%mat, sc%ambient, &
                        sc%objects(obj_i)%shader_prog, t_sec)
                else
                    call framebuffer_render_mesh_mat(fb, &
                        sc%objects(obj_i)%mesh, model, sc%cam, &
                        sc%light_dir, sc%objects(obj_i)%mat, sc%ambient)
                end if
            end do

            ! Wave B entities on the plain path (the env path renders
            ! them after its object loop, before fog/tonemap).
            ! v3 note: sprites/text/particles are not part of the v3
            ! visibility-buffer path yet (Phase 2 limitation).
            if (.not. use_v3 .and. .not. sc%has_env) &
                call render_waveb(sc, fb, t_sec)

            ! v3.0 Phase 2: the v3 renderer draws all scene objects
            ! in one deferred pass from the per-frame models; the
            ! env shadow/fog/tonemap block below is legacy-only.
            if (use_v3) call v3_render_scene_fb(fb, sc, models)

            if (sc%has_env .and. .not. use_v3) then
                ! Wave A: shadow map from the first shadow-casting
                ! light (spot/point position, else the directional
                ! placed opposite its direction), then env rendering,
                ! then fog / tonemapping post passes.
                if (sc%shadow_mode > 0) then
                    sh_pos = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
                    sh_tgt = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
                    sh_near = 0.5_dp
                    sh_far = 80.0_dp
                    if (allocated(sc%lights%items)) then
                        do li = 1, size(sc%lights%items)
                            if (sc%lights%items(li)%kind == 2 .or. &
                                sc%lights%items(li)%kind == 1) then
                                sh_pos = sc%lights%items(li)%pos
                                if (sc%lights%items(li)%kind == 2) &
                                    sh_tgt = vec3_add(sh_pos, &
                                        sc%lights%items(li)%spot_dir)
                                exit
                            end if
                        end do
                        if (li > size(sc%lights%items)) then
                            ! Directional fallback (Wave B fix, B97):
                            ! fit the shadow frustum to the scene
                            ! bounds. The old fixed placement (30
                            ! units away, near 0.5 / far 80) compressed
                            ! NDC depth so much that the caster->
                            ! receiver gap (~0.00135) fell under the
                            ! 0.002 shadow bias and directional
                            ! shadows vanished; fitting D = R + 10,
                            ! near = D - R - 5, far = D + R + 5 raises
                            ! the gap to ~0.015+ (probe-verified).
                            sh_rad = 2.0_dp
                            do li = 1, n_objects
                                extents = object_extents( &
                                    sc%objects(li))
                                sh_rad = max(sh_rad, &
                                    vec3_norm(sc%objects(li)%pos) &
                                    + 0.5_dp * sqrt(extents(1)**2 &
                                    + extents(2)**2 + extents(3)**2))
                            end do
                            sh_d = sh_rad + 10.0_dp
                            sh_pos = vec3_scale( &
                                vec3_normalize(sc%light_dir), -sh_d)
                            sh_near = max(0.5_dp, sh_d - sh_rad &
                                          - 5.0_dp)
                            sh_far = sh_d + sh_rad + 5.0_dp
                        end if
                    end if
                    call shadow_begin(smap, sh_pos, sh_tgt, &
                                      sc%shadow_size, 60.0_dp, &
                                      sh_near, sh_far)
                    do obj_i = 1, n_objects
                        call shadow_add_mesh(smap, &
                            sc%objects(obj_i)%mesh, models(obj_i))
                    end do
                    call shadow_end(smap)
                end if

                do obj_i = 1, n_objects
                    if (sc%objects(obj_i)%has_shader) then
                        ! Wave E (C2): a shader-bound object renders
                        ! through the shader path even in env scenes
                        ! (its shader replaces env shading for that
                        ! object; fog/tonemap still apply after).
                        call framebuffer_render_mesh_shader(fb, &
                            sc%objects(obj_i)%mesh, models(obj_i), &
                            sc%cam, sc%light_dir, &
                            sc%objects(obj_i)%mat, sc%ambient, &
                            sc%objects(obj_i)%shader_prog, t_sec)
                        cycle
                    end if
                    extents = object_extents(sc%objects(obj_i))
                    call framebuffer_render_mesh_env(fb, &
                        sc%objects(obj_i)%mesh, models(obj_i), sc%cam, &
                        sc%lights, sc%objects(obj_i)%pbr, &
                        sc%objects(obj_i)%tex, &
                        trim(sc%objects(obj_i)%prim), extents, smap, &
                        sc%shadow_mode)
                end do

                ! Wave B entities (before fog/tonemap so the post
                ! passes treat them like everything else).
                call render_waveb(sc, fb, t_sec)

                if (sc%fog_mode == 1) then
                    call fog_apply(fb, 1, sc%fog_near, sc%fog_far, &
                                   sc%fog_color, sc%cam%near_plane, &
                                   sc%cam%far_plane)
                else if (sc%fog_mode == 2) then
                    call fog_apply(fb, 2, sc%fog_density, 0.0_dp, &
                                   sc%fog_color, sc%cam%near_plane, &
                                   sc%cam%far_plane)
                end if
                if (sc%tonemap_mode /= 0) &
                    call tonemap_apply(fb, sc%tonemap_mode, &
                                       sc%tonemap_exposure)
            end if

            ! Wave C: post-processing chain (row 30), applied last
            ! on both render paths, in .scene file order.
            ! v3.0 Phase 3: on the v3 path 'bloom' is excluded here
            ! -- post_v3_3d already applied true float bloom inside
            ! v3_quantize_to_fb, and running the legacy 8-bit bloom
            ! approximation as well would double-apply it.  The
            ! other chain entries still run on the framebuffer.
            if (sc%n_post > 0) then
                if (use_v3) then
                    filt_n_post = 0
                    do post_i = 1, sc%n_post
                        post_lc = sc%post_names(post_i)
                        do lc_i = 1, len_trim(post_lc)
                            if (post_lc(lc_i:lc_i) >= 'A' .and. &
                                post_lc(lc_i:lc_i) <= 'Z') &
                                post_lc(lc_i:lc_i) = &
                                    char(ichar(post_lc(lc_i:lc_i)) + 32)
                        end do
                        if (trim(post_lc) == 'bloom') cycle
                        filt_n_post = filt_n_post + 1
                        filt_post_names(filt_n_post) = &
                            sc%post_names(post_i)
                        filt_post_amounts(filt_n_post) = &
                            sc%post_amounts(post_i)
                    end do
                    if (filt_n_post > 0) &
                        call post_apply_chain(fb, filt_post_names, &
                                              filt_post_amounts, &
                                              filt_n_post)
                else
                    call post_apply_chain(fb, sc%post_names, &
                                          sc%post_amounts, sc%n_post)
                end if
            end if

            ! Frame 1 (frame 0 in t) always lands in sc%output_file.
            if (frame_i == 1) call framebuffer_save_image(fb, trim(sc%output_file))

            ! Multi-frame renders also write every frame, frame 1 included,
            ! as '<base>_0001.ppm', '<base>_0002.ppm', ... (P03 pattern).
            if (n_frames > 1) then
                dot_pos = index(trim(sc%output_file), '.', back=.true.)
                if (dot_pos > 1) then
                    base_name = sc%output_file(1:dot_pos - 1)
                    ext_name = sc%output_file(dot_pos:)
                else
                    base_name = trim(sc%output_file)
                    ext_name = ''
                end if
                write(numbered_file, '(A, A, I4.4, A)') trim(base_name), '_', &
                    frame_i, trim(ext_name)
                call framebuffer_save_image(fb, trim(numbered_file))
            end if
        end do

        print *, '============================================'
        print *, ' Scene rendering completed!'
        print *, '   Scene:   ', trim(scene_path)
        print *, '   Objects: ', n_objects
        print *, '   Frames:  ', n_frames
        print *, '   Output:  ', trim(sc%output_file)
        print *, '============================================'
    end if

contains

    ! Wave B entities (coordinator integration): build each sprite /
    ! text / particle mesh for this frame (billboards face the scene
    ! camera; particles are evaluated at t) and rasterise with the
    ! per-triangle-colour material path under the scene's directional
    ! light. Meshes are built in world space, so the model matrix is
    ! the identity.
    subroutine render_waveb(sc_arg, fb_arg, t_arg)
        type(Scene), intent(in) :: sc_arg
        type(FrameBuffer), intent(inout) :: fb_arg
        real(dp), intent(in) :: t_arg
        type(Mesh) :: tmp_mesh
        type(Material) :: mat_tri
        type(mat4) :: ident
        integer :: wi

        ident = mat4_identity()
        mat_tri = material_default()
        if (allocated(sc_arg%sprites)) then
            do wi = 1, sc_arg%n_sprites
                call sprite_build_mesh(sc_arg%sprites(wi)%pos, &
                    sc_arg%sprites(wi)%size, &
                    sc_arg%sprites(wi)%color, sc_arg%cam%position, &
                    tmp_mesh)
                call framebuffer_render_mesh_mat(fb_arg, tmp_mesh, &
                    ident, sc_arg%cam, sc_arg%light_dir, mat_tri, &
                    sc_arg%ambient)
                call free_mesh(tmp_mesh)
            end do
        end if
        if (allocated(sc_arg%texts)) then
            do wi = 1, sc_arg%n_texts
                call text_build_mesh( &
                    trim(sc_arg%texts(wi)%content), &
                    sc_arg%texts(wi)%pos, sc_arg%texts(wi)%size, &
                    sc_arg%texts(wi)%color, tmp_mesh)
                call framebuffer_render_mesh_mat(fb_arg, tmp_mesh, &
                    ident, sc_arg%cam, sc_arg%light_dir, mat_tri, &
                    sc_arg%ambient)
                call free_mesh(tmp_mesh)
            end do
        end if
        if (allocated(sc_arg%parts)) then
            do wi = 1, sc_arg%n_parts
                call particles_build_mesh(sc_arg%parts(wi)%sys, &
                    t_arg, sc_arg%cam%position, tmp_mesh)
                call framebuffer_render_mesh_mat(fb_arg, tmp_mesh, &
                    ident, sc_arg%cam, sc_arg%light_dir, mat_tri, &
                    sc_arg%ambient)
                call free_mesh(tmp_mesh)
            end do
        end if
    end subroutine render_waveb

    ! Full extents (sx, sy, sz) of a scene object for the texture
    ! module's prim_uv contract; mirrors scene.f90's per-prim defaults.
    function object_extents(obj) result(ext)
        type(SceneObject), intent(in) :: obj
        real(dp) :: ext(3)
        real(dp) :: sz, rad, hgt
        sz = obj%dim_size
        rad = obj%dim_radius
        hgt = obj%dim_height
        select case (trim(obj%prim))
        case ('sphere')
            if (rad <= 0.0_dp) rad = 1.0_dp
            ext = [2.0_dp * rad, 2.0_dp * rad, 2.0_dp * rad]
        case ('cylinder', 'cone')
            if (rad <= 0.0_dp) rad = 1.0_dp
            if (hgt <= 0.0_dp) hgt = 2.0_dp
            ext = [2.0_dp * rad, hgt, 2.0_dp * rad]
        case ('plane')
            if (sz <= 0.0_dp) sz = 4.0_dp
            ext = [sz, 0.0_dp, sz]
        case ('torus')
            if (rad <= 0.0_dp) rad = 1.5_dp
            ext = [2.0_dp * (rad + rad * 0.35_dp), &
                   2.0_dp * rad * 0.35_dp, &
                   2.0_dp * (rad + rad * 0.35_dp)]
        case default  ! cube / box / pyramid / tris / load
            if (sz <= 0.0_dp) sz = 2.0_dp
            if (hgt <= 0.0_dp) hgt = sz
            ext = [sz, hgt, sz]
        end select
    end function object_extents

end program main
