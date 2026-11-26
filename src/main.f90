program main
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use scene_3d
    use animation_3d
    use keyframe_3d, only: key_eval_q
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
    use timeline_ir_3d, only: tl_timeline, read_timeline
    use timeline_eval_3d, only: film_state, film_load, film_eval_pose, &
        film_eval_camera, film_transition, film_span_at, film_fps
    use char_figure_3d, only: figure_pose, figure_build_mesh, &
        CH_ROOT_X, CH_ROOT_Z
    use camera_3d, only: camera_init
    use material_3d, only: material_basic
    use material_pbr_3d, only: pbr_from_material
    use, intrinsic :: iso_fortran_env, only: error_unit, int64
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
    real(dp) :: k_pos(3), k_scale3(3)
    type(quat) :: k_quat
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
    ! v3.0 Phase 8: binary PPM (P6) output state.  The flag wins
    ! over the FORGE3D_BINARY_PPM environment variable, which wins
    ! over the default (.false. = the historic P3 ASCII PPM).
    logical :: binary_ppm
    character(len=64) :: bin_env_val
    integer :: bin_env_len, bin_env_status
    ! v3.0 Phase 8: '--video <file.mp4>' state (scene mode only;
    ! single-image renders are unaffected).
    logical :: has_video
    character(len=1024) :: video_file
    character(len=1024) :: arg_token
    integer :: scan_i, scene_arg_idx
    ! v3.0 Phase 9: write-failure detection state.  failed_frames
    ! counts frame writes that failed after frame 1 (a failed
    ! first frame is fatal immediately; see the frame loop).
    integer :: failed_frames
    logical :: frame_write_ok
    ! Wave 3 film mode (slice S4): a .timeline.json argument without
    ! --report renders the film; fstate is the loaded film, fb2 the
    ! transition-blend framebuffer.
    type(film_state) :: fstate
    logical :: film_mode, report_flag
    type(FrameBuffer) :: fb2
    ! v3.0 Phase 9: resource limits (see the parsing block below).
    ! FORGE3D_MAX_FRAMES     -- max frames in one render
    !                           (default 100000)
    ! FORGE3D_MAX_RESOLUTION -- max width*height in pixels
    !                           (default 268435456 = 16384x16384)
    ! There is no usage/help text in this file, so these two
    ! variables are documented here and at their parsing block.
    integer :: max_frames_limit
    integer(int64) :: max_pixels_limit, scene_pixels, lim_val64
    character(len=64) :: lim_env_val
    integer :: lim_env_len, lim_env_status, lim_ios

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

    ! Binary PPM selection: same flag > env > default pattern as
    ! the renderer above.  Accepted env values are 1/true/yes/on
    ! and 0/false/no/off (lower or upper case for the words).
    binary_ppm = .false.
    bin_env_val = ''
    call get_environment_variable('FORGE3D_BINARY_PPM', bin_env_val, &
                                  length=bin_env_len, &
                                  status=bin_env_status)
    if (bin_env_status == 0) then
        if (bin_env_len > 0) then
            select case (trim(bin_env_val(1:min(bin_env_len, 64))))
            case ('1', 'true', 'TRUE', 'yes', 'YES', 'on', 'ON')
                binary_ppm = .true.
            case ('0', 'false', 'FALSE', 'no', 'NO', 'off', 'OFF')
                binary_ppm = .false.
            case default
                write(error_unit, '(A)') &
                    'error: unknown FORGE3D_BINARY_PPM value "' &
                    // trim(bin_env_val(1:min(bin_env_len, 64))) &
                    // '" (expected 1/0, true/false, yes/no, on/off)'
                stop 2
            end select
        end if
    end if

    ! Resource limits (v3.0 Phase 9): same env > default pattern
    ! as FORGE3D_BINARY_PPM above.  Both values must be positive
    ! integers; an unparsable or non-positive value is a clear
    ! error, exit 2.  The guards themselves run before rendering
    ! (below, and in the scene branch once n_frames / the scene
    ! resolution are known) and also exit 2 when exceeded.
    max_frames_limit = 100000
    lim_env_val = ''
    call get_environment_variable('FORGE3D_MAX_FRAMES', &
                                  lim_env_val, length=lim_env_len, &
                                  status=lim_env_status)
    if (lim_env_status == 0) then
        if (lim_env_len > 0) then
            read(lim_env_val(1:min(lim_env_len, 64)), *, &
                 iostat=lim_ios) lim_val64
            if (lim_ios /= 0) then
                write(error_unit, '(A)') &
                    'error: unknown FORGE3D_MAX_FRAMES value "' &
                    // trim(lim_env_val(1:min(lim_env_len, 64))) &
                    // '" (expected a positive integer)'
                stop 2
            end if
            if (lim_val64 < 1_int64) then
                write(error_unit, '(A)') &
                    'error: FORGE3D_MAX_FRAMES must be >= 1, got "' &
                    // trim(lim_env_val(1:min(lim_env_len, 64))) &
                    // '"'
                stop 2
            end if
            max_frames_limit = &
                int(min(lim_val64, 2147483647_int64))
        end if
    end if
    max_pixels_limit = 268435456_int64
    lim_env_val = ''
    call get_environment_variable('FORGE3D_MAX_RESOLUTION', &
                                  lim_env_val, length=lim_env_len, &
                                  status=lim_env_status)
    if (lim_env_status == 0) then
        if (lim_env_len > 0) then
            read(lim_env_val(1:min(lim_env_len, 64)), *, &
                 iostat=lim_ios) lim_val64
            if (lim_ios /= 0) then
                write(error_unit, '(A)') &
                    'error: unknown FORGE3D_MAX_RESOLUTION ' &
                    // 'value "' &
                    // trim(lim_env_val(1:min(lim_env_len, 64))) &
                    // '" (expected a positive integer, max ' &
                    // 'width*height pixels)'
                stop 2
            end if
            if (lim_val64 < 1_int64) then
                write(error_unit, '(A)') &
                    'error: FORGE3D_MAX_RESOLUTION must be ' &
                    // '>= 1, got "' &
                    // trim(lim_env_val(1:min(lim_env_len, 64))) &
                    // '"'
                stop 2
            end if
            max_pixels_limit = lim_val64
        end if
    end if

    ! Scan the remaining arguments for '--binary-ppm' and
    ! '--video <file>' (either may appear before or after the
    ! scene path); the first non-flag argument is the scene path.
    ! Note: .and./.or. do not short-circuit, so bounds are tested
    ! with nested ifs, never combined with an indexed access.
    has_video = .false.
    film_mode = .false.
    report_flag = .false.
    video_file = ''
    scene_arg_idx = 0
    scan_i = arg_offset + 1
    do while (scan_i <= nargs)
        call get_command_argument(scan_i, arg_token)
        if (trim(arg_token) == '--binary-ppm') then
            binary_ppm = .true.
        else if (trim(arg_token) == '--report') then
            report_flag = .true.
        else if (trim(arg_token) == '--video') then
            if (scan_i == nargs) then
                write(error_unit, '(A)') &
                    'error: --video requires a value (file.mp4)'
                stop 2
            end if
            call get_command_argument(scan_i + 1, video_file)
            has_video = .true.
            scan_i = scan_i + 1
        else
            if (scene_arg_idx == 0) scene_arg_idx = scan_i
        end if
        scan_i = scan_i + 1
    end do

    if (scene_arg_idx == 0) then
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

        ! v3.0 Phase 9: resource-limit guard (the demo is a
        ! single frame, so only the resolution limit can bite).
        scene_pixels = int(width, int64) * int(height, int64)
        if (scene_pixels > max_pixels_limit) then
            write(error_unit, '(A, I0, A, I0, A)') &
                'error: resolution ', scene_pixels, &
                ' pixels exceeds FORGE3D_MAX_RESOLUTION limit ' &
                // 'of ', max_pixels_limit, ' pixels'
            stop 2
        end if

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

        ! 7. Save output PPM image (P6 instead of P3 only when
        ! --binary-ppm / FORGE3D_BINARY_PPM selected it; the
        ! default call below is the unchanged regression anchor)
        print *, '[+] Writing image to ', trim(output_file), '...'
        ! v3.0 Phase 9: a failed write here is fatal (stop 1) --
        ! the engine must never exit 0 with its frame missing.
        ! The binary writer reports its own iostat status; the
        ! shared framebuffer_save_ppm has no status return, so
        ! its result is wrapped with check_written_file (see the
        ! limitation note on that function).
        if (binary_ppm) then
            call save_ppm_binary(fb, output_file, frame_write_ok)
        else
            call framebuffer_save_ppm(fb, output_file)
            frame_write_ok = check_written_file(output_file)
        end if
        if (.not. frame_write_ok) stop 1

        ! 8. Export 3D Mesh for Interactive Web / 3D Viewers
        ! The exporters in mesh_3d likewise return no status, so
        ! they get the same existence/size wrap as above.
        print *, '[+] Exporting scene.json and model.obj...'
        call export_mesh_json(cube, 'scene.json')
        if (.not. check_written_file('scene.json')) stop 1
        call export_mesh_obj(cube, 'model.obj')
        if (.not. check_written_file('model.obj')) stop 1

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
        call get_command_argument(scene_arg_idx, scene_path)

        ! Timeline IR (Wave 2, slice A4): a .timeline.json argument
        ! is NOT a scene -- load it with the typed, version-gated
        ! reader (timeline_ir_3d), print a short report, and exit.
        ! There is no evaluation or rendering yet (Wave 3); every
        ! other path, including the legacy demo, is untouched.
        block
            integer :: plen
            type(tl_timeline) :: tlrep
            logical :: tok
            character(len=1024) :: terr
            integer :: note_i
            plen = len_trim(scene_path)
            if (plen > 14 .and. &
                scene_path(plen - 13:plen) == '.timeline.json' &
                .and. .not. report_flag) then
                ! Wave 3: film render mode (see run_film below).
                film_mode = .true.
            else if (plen > 14 .and. &
                scene_path(plen - 13:plen) == '.timeline.json') then
                call read_timeline(trim(scene_path), tlrep, tok, terr)
                if (.not. tok) then
                    write(error_unit, '(A)') 'error: ' // trim(terr)
                    stop 1
                end if
                print *, '[+] Timeline IR: ', trim(tlrep%name)
                write(*, '(A, I0, A, I0, A, I0, A)') &
                    '    fps ', tlrep%fps_num, '/', tlrep%fps_den, &
                    ', duration ', tlrep%duration_frames, ' frames'
                write(*, '(A, I0, A, I0, A, I0, A, I0, A, I0)') &
                    '    characters ', tlrep%n_characters, &
                    ', scenes ', tlrep%n_scenes, &
                    ', tracks ', tlrep%n_tracks, &
                    ', dialogue ', tlrep%n_dialogue, &
                    ', markers ', tlrep%n_markers
                if (tlrep%n_skipped_tracks > 0) &
                    write(*, '(A, I0, A)') '    skipped tracks: ', &
                        tlrep%n_skipped_tracks, &
                        ' (unknown kind, see notes)'
                do note_i = 1, tlrep%n_notes
                    write(*, '(A, A)') '    note: ', &
                        trim(tlrep%notes(note_i))
                end do
                stop
            end if
        end block

        if (film_mode) then
            call run_film()
            stop
        end if

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

        ! v3.0 Phase 9: resource-limit guards, evaluated before
        ! any rendering (and before the framebuffer is allocated).
        ! Exceeding either limit is a clear stderr error, exit 2.
        if (n_frames > max_frames_limit) then
            write(error_unit, '(A, I0, A, I0, A)') &
                'error: scene requires ', n_frames, &
                ' frames, exceeding the FORGE3D_MAX_FRAMES ' &
                // 'limit of ', max_frames_limit, ' frames'
            stop 2
        end if
        scene_pixels = int(sc%width, int64) &
                       * int(sc%height, int64)
        if (scene_pixels < 1_int64) then
            write(error_unit, '(A, I0, A, I0, A)') &
                'error: scene resolution ', sc%width, 'x', &
                sc%height, ' is not a positive size'
            stop 2
        end if
        if (scene_pixels > max_pixels_limit) then
            write(error_unit, '(A, I0, A, I0, A)') &
                'error: scene resolution ', scene_pixels, &
                ' pixels exceeds the FORGE3D_MAX_RESOLUTION ' &
                // 'limit of ', max_pixels_limit, ' pixels'
            stop 2
        end if
        failed_frames = 0

        ! Frame timing (v3.0 Phase 5, M3): the scene-level fps
        ! wins, then the first animation's fps, default 30.
        fps_r = 30.0_dp
        if (sc%n_anims > 0) fps_r = real(sc%anims(1)%fps, dp)
        if (sc%fps > 0) fps_r = real(sc%fps, dp)
        if (fps_r <= 0.0_dp) fps_r = 30.0_dp

        call framebuffer_init(fb, sc%width, sc%height)
        allocate(models(max(1, n_objects)))

        do frame_i = 1, n_frames
            t_sec = real(frame_i - 1, dp) / fps_r

            call render_scene_frame(sc, t_sec, fb, models)

            ! Frame 1 (frame 0 in t) always lands in sc%output_file.
            ! v3.0 Phase 9: a failed FIRST frame is fatal
            ! immediately (the specific error was already printed
            ! by save_frame_image / its helpers).
            if (frame_i == 1) then
                call save_frame_image(fb, trim(sc%output_file), &
                                      frame_write_ok)
                if (.not. frame_write_ok) stop 1
            end if

            ! Multi-frame renders also write every frame, frame 1 included,
            ! as '<base>_0001.ppm', '<base>_0002.ppm', ... (P03 pattern).
            ! v3.0 Phase 9: later-frame failures are counted, not
            ! immediately fatal, so the run reports how many frames
            ! were lost (see the failed_frames check after the
            ! loop, which exits stop 1 before any video assembly);
            ! a numbered frame-1 failure is still a first-frame
            ! failure and is fatal at once.
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
                call save_frame_image(fb, trim(numbered_file), &
                                      frame_write_ok)
                if (.not. frame_write_ok) then
                    failed_frames = failed_frames + 1
                    if (frame_i == 1) stop 1
                end if
            end if
        end do

        ! v3.0 Phase 9: any counted write failure makes the whole
        ! render a failure -- report the count and exit nonzero
        ! instead of the historic silent exit 0 with frames
        ! missing (e.g. on a full filesystem).
        if (failed_frames > 0) then
            write(error_unit, '(A, I0, A)') 'error: ', &
                failed_frames, &
                ' frame(s) failed to write; render incomplete'
            stop 1
        end if

        ! v3.0 Phase 8: '--video <file.mp4>' -- assemble the
        ! numbered frame files just written into a video with
        ! ffmpeg (see assemble_video below; shared with film
        ! mode).  Only multi-frame renders reach here; single-
        ! image renders are unaffected.  A missing or failing
        ! ffmpeg never changes the exit code, and the frame
        ! files are kept; a missing ffmpeg is a LOUD warning
        ! naming the exact assembly command (Wave 5, X3).
        if (has_video .and. n_frames > 1) &
            call assemble_video(trim(sc%output_file), fps_r)

        print *, '============================================'
        print *, ' Scene rendering completed!'
        print *, '   Scene:   ', trim(scene_path)
        print *, '   Objects: ', n_objects
        print *, '   Frames:  ', n_frames
        print *, '   Output:  ', trim(sc%output_file)
        print *, '============================================'
    end if

contains


    ! Wave 3 (S4): one scene frame rendered into fb_arg -- the
    ! per-frame body of the scene-mode loop (object loop + waveb +
    ! deferred/immediate dispatch), extracted VERBATIM from main's
    ! frame loop so scene mode stays byte-identical; frame SAVING
    ! stays caller-side.  When fstate_arg is present (film mode),
    ! the film evaluation (camera track + figure meshes for bound
    ! characters) runs before the object loop, and film-owned
    ! objects skip the keyframe-track branch (their pose comes
    ! from the timeline); the SceneAnim delta branch still applies
    ! (anim_eval is a no-op for unknown kinds such as "walk"/"wave",
    ! verified in animation.f90's default case).
    subroutine render_scene_frame(sc_arg, t_arg, fb_arg, models_arg, &
                                  fstate_arg, span_idx, gframe)
        type(Scene), intent(inout) :: sc_arg
        real(dp), intent(in) :: t_arg
        type(FrameBuffer), intent(inout) :: fb_arg
        type(mat4), intent(inout) :: models_arg(:)
        type(film_state), intent(inout), optional :: fstate_arg
        integer, intent(in), optional :: span_idx, gframe
        type(mat4) :: model
        type(vec3) :: pos_v, rot_v, scl_v
        real(dp) :: d_rot(3), d_pos(3), a_rot(3), a_pos(3), a_scale
        real(dp) :: scale_factor
        integer :: obj_i, anim_i, track_i, ti, li
        integer :: n_objects
        real(dp) :: k_pos(3), k_scale3(3)
        type(quat) :: k_quat
        type(vec3) :: sh_pos, sh_tgt, extents_v
        real(dp) :: extents(3)
        real(dp) :: sh_near, sh_far, sh_rad, sh_d
        logical, allocatable :: film_owned(:)
        real(dp) :: fc_pos(3), fc_tgt(3), fc_fov, fc_root(3), &
                    fc_rot(3), fc_scl(3)
        logical :: fc_found
        integer :: fc_ci, fc_oi
        type(figure_pose) :: fc_pose, fc_local
        type(vec3) :: fc_cam

        n_objects = sc_arg%n_objects
        allocate(film_owned(max(1, n_objects)))
        film_owned = .false.
            call framebuffer_clear(fb_arg, sc_arg%bg(1), sc_arg%bg(2), sc_arg%bg(3))

            ! Wave 3 film eval (only when a film state is passed):
            ! camera track first, then per-character figure meshes,
            ! BEFORE the object loop below.
            if (present(fstate_arg)) then
                call film_eval_camera(fstate_arg, span_idx, gframe, &
                    fc_pos, fc_tgt, fc_fov, fc_found)
                if (fc_found) then
                    call camera_init(sc_arg%cam, &
                        vec3_create(fc_pos(1), fc_pos(2), fc_pos(3)), &
                        vec3_create(fc_tgt(1), fc_tgt(2), fc_tgt(3)), &
                        fc_fov, &
                        real(sc_arg%width, dp) / &
                            real(max(1, sc_arg%height), dp), &
                        sc_arg%cam%near_plane, sc_arg%cam%far_plane)
                end if
                if (sc_arg%ortho) then
                    sc_arg%cam%proj_matrix = ortho_proj_from_size( &
                        sc_arg%ortho_size, &
                        real(sc_arg%width, dp) / &
                            real(max(1, sc_arg%height), dp), &
                        sc_arg%cam%near_plane, sc_arg%cam%far_plane)
                end if
                do fc_ci = 1, fstate_arg%tl%n_characters
                    if (.not. fstate_arg%spans(span_idx)%loaded) cycle
                    if (.not. fstate_arg%spans(span_idx)%mapped(fc_ci)) cycle
                    fc_oi = fstate_arg%spans(span_idx)%obj_idx(fc_ci)
                    call film_eval_pose(fstate_arg, span_idx, fc_ci, &
                        gframe, fc_pose, fc_root, fc_rot, fc_scl)
                    fc_local = fc_pose
                    fc_local%ch(CH_ROOT_X:CH_ROOT_Z) = 0.0_dp
                    fc_cam = vec3_create( &
                        sc_arg%cam%position%x - fc_root(1), &
                        sc_arg%cam%position%y - fc_root(2), &
                        sc_arg%cam%position%z - fc_root(3))
                    call free_mesh(sc_arg%objects(fc_oi)%mesh)
                    call figure_build_mesh(fc_local, &
                        fstate_arg%chars(fc_ci)%props, &
                        fstate_arg%chars(fc_ci)%identity, &
                        fstate_arg%chars(fc_ci)%base_color, &
                        fc_cam, sc_arg%objects(fc_oi)%mesh)
                    sc_arg%objects(fc_oi)%pos = vec3_create( &
                        fc_root(1), fc_root(2), fc_root(3))
                    sc_arg%objects(fc_oi)%rot_deg = vec3_create( &
                        fc_rot(1), fc_rot(2), fc_rot(3))
                    sc_arg%objects(fc_oi)%scl = vec3_create( &
                        fc_scl(1), fc_scl(2), fc_scl(3))
                    film_owned(fc_oi) = .true.
                end do
            end if


            do obj_i = 1, n_objects
                ! Wave B: a keyframe track targeting this object
                ! REPLACES its base pose and closed-form animations
                ! for this frame (absolute pos/rot/scale from the
                ! track).  v3.0 Phase 5 (M2): evaluation is
                ! key_eval_q -- rotation SLERPs between the keys'
                ! quaternions (Euler is only the authored form)
                ! and scale is per-axis.
                track_i = 0
                if (allocated(sc_arg%tracks)) then
                    do ti = 1, sc_arg%n_tracks
                        if (trim(sc_arg%tracks(ti)%target) == &
                            trim(sc_arg%objects(obj_i)%name)) then
                            track_i = ti
                            exit
                        end if
                    end do
                end if
                if (track_i > 0 .and. .not. film_owned(obj_i)) then
                    call key_eval_q(sc_arg%tracks(track_i), t_arg, &
                                    k_pos, k_quat, k_scale3)
                    model = mat4_mult( &
                        mat4_translation(k_pos(1), k_pos(2), &
                                         k_pos(3)), &
                        mat4_mult(quat_to_mat4(k_quat), &
                                  mat4_scale(k_scale3(1), &
                                             k_scale3(2), &
                                             k_scale3(3))))
                    if (sc_arg%has_env .or. use_v3) then
                        models_arg(obj_i) = model
                    else if (sc_arg%objects(obj_i)%has_shader) then
                        ! Wave E (C2): custom shader path.
                        call framebuffer_render_mesh_shader(fb_arg, &
                            sc_arg%objects(obj_i)%mesh, model, sc_arg%cam, &
                            sc_arg%light_dir, sc_arg%objects(obj_i)%mat, &
                            sc_arg%ambient, sc_arg%objects(obj_i)%shader_prog, &
                            t_arg)
                    else
                        call framebuffer_render_mesh_mat(fb_arg, &
                            sc_arg%objects(obj_i)%mesh, model, sc_arg%cam, &
                            sc_arg%light_dir, sc_arg%objects(obj_i)%mat, &
                            sc_arg%ambient)
                    end if
                    cycle
                end if
                ! Accumulate animation deltas for this object: animations
                ! target it by name, or target 'all'.
                d_rot = 0.0_dp
                d_pos = 0.0_dp
                scale_factor = 1.0_dp
                if (allocated(sc_arg%anims)) then
                    do anim_i = 1, sc_arg%n_anims
                        if (trim(sc_arg%anims(anim_i)%target) == &
                            trim(sc_arg%objects(obj_i)%name) .or. &
                            trim(sc_arg%anims(anim_i)%target) == 'all') then
                            call anim_eval(sc_arg%anims(anim_i)%kind, t_arg, &
                                           sc_arg%anims(anim_i)%speed, &
                                           sc_arg%anims(anim_i)%duration, &
                                           sc_arg%anims(anim_i)%axis, &
                                           sc_arg%anims(anim_i)%loop, &
                                           sc_arg%anims(anim_i)%ease, &
                                           a_rot, a_pos, a_scale)
                            d_rot = d_rot + a_rot
                            d_pos = d_pos + a_pos
                            scale_factor = scale_factor * a_scale
                        end if
                    end do
                end if

                pos_v = vec3_create(sc_arg%objects(obj_i)%pos%x + d_pos(1), &
                                    sc_arg%objects(obj_i)%pos%y + d_pos(2), &
                                    sc_arg%objects(obj_i)%pos%z + d_pos(3))
                rot_v = vec3_create(sc_arg%objects(obj_i)%rot_deg%x + d_rot(1), &
                                    sc_arg%objects(obj_i)%rot_deg%y + d_rot(2), &
                                    sc_arg%objects(obj_i)%rot_deg%z + d_rot(3))
                scl_v = vec3_create(sc_arg%objects(obj_i)%scl%x * scale_factor, &
                                    sc_arg%objects(obj_i)%scl%y * scale_factor, &
                                    sc_arg%objects(obj_i)%scl%z * scale_factor)
                model = mat4_compose_trs(pos_v, rot_v, scl_v)

                if (sc_arg%has_env .or. use_v3) then
                    models_arg(obj_i) = model
                else if (sc_arg%objects(obj_i)%has_shader) then
                    ! Wave E (C2): custom shader path.
                    call framebuffer_render_mesh_shader(fb_arg, &
                        sc_arg%objects(obj_i)%mesh, model, sc_arg%cam, &
                        sc_arg%light_dir, sc_arg%objects(obj_i)%mat, sc_arg%ambient, &
                        sc_arg%objects(obj_i)%shader_prog, t_arg)
                else
                    call framebuffer_render_mesh_mat(fb_arg, &
                        sc_arg%objects(obj_i)%mesh, model, sc_arg%cam, &
                        sc_arg%light_dir, sc_arg%objects(obj_i)%mat, sc_arg%ambient)
                end if
            end do

            ! Wave B entities on the plain path (the env path renders
            ! them after its object loop, before fog/tonemap).
            ! v3 note: sprites/text/particles are not part of the v3
            ! visibility-buffer path yet (Phase 2 limitation).
            if (.not. use_v3 .and. .not. sc_arg%has_env) &
                call render_waveb(sc_arg, fb_arg, t_arg)

            ! v3.0 Phase 2: the v3 renderer draws all scene objects
            ! in one deferred pass from the per-frame models; the
            ! env shadow/fog/tonemap block below is legacy-only.
            if (use_v3) call v3_render_scene_fb(fb_arg, sc_arg, models_arg)

            if (sc_arg%has_env .and. .not. use_v3) then
                ! Wave A: shadow map from the first shadow-casting
                ! light (spot/point position, else the directional
                ! placed opposite its direction), then env rendering,
                ! then fog / tonemapping post passes.
                if (sc_arg%shadow_mode > 0) then
                    sh_pos = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
                    sh_tgt = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
                    sh_near = 0.5_dp
                    sh_far = 80.0_dp
                    if (allocated(sc_arg%lights%items)) then
                        do li = 1, size(sc_arg%lights%items)
                            if (sc_arg%lights%items(li)%kind == 2 .or. &
                                sc_arg%lights%items(li)%kind == 1) then
                                sh_pos = sc_arg%lights%items(li)%pos
                                if (sc_arg%lights%items(li)%kind == 2) &
                                    sh_tgt = vec3_add(sh_pos, &
                                        sc_arg%lights%items(li)%spot_dir)
                                exit
                            end if
                        end do
                        if (li > size(sc_arg%lights%items)) then
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
                                    sc_arg%objects(li))
                                sh_rad = max(sh_rad, &
                                    vec3_norm(sc_arg%objects(li)%pos) &
                                    + 0.5_dp * sqrt(extents(1)**2 &
                                    + extents(2)**2 + extents(3)**2))
                            end do
                            sh_d = sh_rad + 10.0_dp
                            sh_pos = vec3_scale( &
                                vec3_normalize(sc_arg%light_dir), -sh_d)
                            sh_near = max(0.5_dp, sh_d - sh_rad &
                                          - 5.0_dp)
                            sh_far = sh_d + sh_rad + 5.0_dp
                        end if
                    end if
                    call shadow_begin(smap, sh_pos, sh_tgt, &
                                      sc_arg%shadow_size, 60.0_dp, &
                                      sh_near, sh_far)
                    do obj_i = 1, n_objects
                        call shadow_add_mesh(smap, &
                            sc_arg%objects(obj_i)%mesh, models_arg(obj_i))
                    end do
                    call shadow_end(smap)
                end if

                do obj_i = 1, n_objects
                    if (sc_arg%objects(obj_i)%has_shader) then
                        ! Wave E (C2): a shader-bound object renders
                        ! through the shader path even in env scenes
                        ! (its shader replaces env shading for that
                        ! object; fog/tonemap still apply after).
                        call framebuffer_render_mesh_shader(fb_arg, &
                            sc_arg%objects(obj_i)%mesh, models_arg(obj_i), &
                            sc_arg%cam, sc_arg%light_dir, &
                            sc_arg%objects(obj_i)%mat, sc_arg%ambient, &
                            sc_arg%objects(obj_i)%shader_prog, t_arg)
                        cycle
                    end if
                    extents = object_extents(sc_arg%objects(obj_i))
                    call framebuffer_render_mesh_env(fb_arg, &
                        sc_arg%objects(obj_i)%mesh, models_arg(obj_i), sc_arg%cam, &
                        sc_arg%lights, sc_arg%objects(obj_i)%pbr, &
                        sc_arg%objects(obj_i)%tex, &
                        trim(sc_arg%objects(obj_i)%prim), extents, smap, &
                        sc_arg%shadow_mode)
                end do

                ! Wave B entities (before fog/tonemap so the post
                ! passes treat them like everything else).
                call render_waveb(sc_arg, fb_arg, t_arg)

                if (sc_arg%fog_mode == 1) then
                    call fog_apply(fb_arg, 1, sc_arg%fog_near, sc_arg%fog_far, &
                                   sc_arg%fog_color, sc_arg%cam%near_plane, &
                                   sc_arg%cam%far_plane)
                else if (sc_arg%fog_mode == 2) then
                    call fog_apply(fb_arg, 2, sc_arg%fog_density, 0.0_dp, &
                                   sc_arg%fog_color, sc_arg%cam%near_plane, &
                                   sc_arg%cam%far_plane)
                end if
                if (sc_arg%tonemap_mode /= 0) &
                    call tonemap_apply(fb_arg, sc_arg%tonemap_mode, &
                                       sc_arg%tonemap_exposure)
            end if

            ! Wave C: post-processing chain (row 30), applied last
            ! on both render paths, in .scene file order.
            ! v3.0 Phase 3: on the v3 path 'bloom' is excluded here
            ! -- post_v3_3d already applied true float bloom inside
            ! v3_quantize_to_fb, and running the legacy 8-bit bloom
            ! approximation as well would double-apply it.  The
            ! other chain entries still run on the framebuffer.
            if (sc_arg%n_post > 0) then
                if (use_v3) then
                    filt_n_post = 0
                    do post_i = 1, sc_arg%n_post
                        post_lc = sc_arg%post_names(post_i)
                        do lc_i = 1, len_trim(post_lc)
                            if (post_lc(lc_i:lc_i) >= 'A' .and. &
                                post_lc(lc_i:lc_i) <= 'Z') &
                                post_lc(lc_i:lc_i) = &
                                    char(ichar(post_lc(lc_i:lc_i)) + 32)
                        end do
                        if (trim(post_lc) == 'bloom') cycle
                        filt_n_post = filt_n_post + 1
                        filt_post_names(filt_n_post) = &
                            sc_arg%post_names(post_i)
                        filt_post_amounts(filt_n_post) = &
                            sc_arg%post_amounts(post_i)
                    end do
                    if (filt_n_post > 0) &
                        call post_apply_chain(fb_arg, filt_post_names, &
                                              filt_post_amounts, &
                                              filt_n_post)
                else
                    call post_apply_chain(fb_arg, sc_arg%post_names, &
                                          sc_arg%post_amounts, sc_arg%n_post)
                end if
            end if

        deallocate(film_owned)
    end subroutine render_scene_frame


    ! Wave 3 (S4): film render mode -- the argument was a
    ! .timeline.json without --report.  Loads the film (timeline +
    ! span scenes + cast mapping), prints the film notes, then
    ! renders duration_frames frames: each global frame renders
    ! its span's scene (film-evaluated by render_scene_frame) at
    ! the timeline fps; fade/dissolve transitions blend the
    ! previous span's last-frame render pixel-wise post-render.
    subroutine run_film()
        integer :: gf, si, psi, ci, oi, nf, note_i, x, y, c
        real(dp) :: fps_f, t_local, alpha, pa, ca
        logical :: in_tr, noted_slide
        character(len=256) :: film_output
        character(len=1024) :: numbered, base_n, ext_n
        integer :: dotp
        type(mat4), allocatable :: models2(:)
        integer :: prev_frame
        character(len=32) :: tr_kind

        call film_load(trim(scene_path), fstate, ok, errmsg)
        if (.not. ok) then
            write(error_unit, '(A)') 'error: ' // trim(errmsg)
            stop 1
        end if
        print *, '[+] Film: ', trim(fstate%tl%name)
        write(*, '(A, I0, A, I0, A, I0, A)') &
            '    fps ', fstate%tl%fps_num, '/', fstate%tl%fps_den, &
            ', duration ', fstate%tl%duration_frames, ' frames'
        do note_i = 1, fstate%n_notes
            write(*, '(A, A)') '    note: ', trim(fstate%notes(note_i))
        end do
        if (fstate%n_unresolved > 0) &
            write(*, '(A, I0, A)') '    unmapped tracks: ', &
                fstate%n_unresolved, ' (reported, not approximated)'

        ! Bound character objects: unlit per-tri-colour material so
        ! the v3 path shades the figure flat (set_object_material
        ! equivalent for 'basic').
        do si = 1, fstate%tl%n_scenes
            if (.not. fstate%spans(si)%loaded) cycle
            do ci = 1, fstate%tl%n_characters
                if (.not. fstate%spans(si)%mapped(ci)) cycle
                oi = fstate%spans(si)%obj_idx(ci)
                fstate%spans(si)%sc%objects(oi)%mat_name = 'basic'
                fstate%spans(si)%sc%objects(oi)%mat = &
                    material_basic([1.0_dp, 1.0_dp, 1.0_dp])
                fstate%spans(si)%sc%objects(oi)%mat%use_tri_color = &
                    .true.
                fstate%spans(si)%sc%objects(oi)%pbr = &
                    pbr_from_material( &
                        fstate%spans(si)%sc%objects(oi)%mat, &
                        0.0_dp, 1.0_dp)
            end do
        end do

        nf = fstate%tl%duration_frames
        if (nf > max_frames_limit) then
            write(error_unit, '(A, I0, A, I0, A)') &
                'error: film requires ', nf, &
                ' frames, exceeding the FORGE3D_MAX_FRAMES ' &
                // 'limit of ', max_frames_limit, ' frames'
            stop 2
        end if
        fps_f = film_fps(fstate)
        film_output = 'output_render.ppm'
        do si = 1, fstate%tl%n_scenes
            if (fstate%spans(si)%loaded) then
                film_output = fstate%spans(si)%sc%output_file
                exit
            end if
        end do
        ! Framebuffer sized to the first loaded span.
        do si = 1, fstate%tl%n_scenes
            if (fstate%spans(si)%loaded) then
                call framebuffer_init(fb, &
                    fstate%spans(si)%sc%width, &
                    fstate%spans(si)%sc%height)
                call framebuffer_init(fb2, &
                    fstate%spans(si)%sc%width, &
                    fstate%spans(si)%sc%height)
                exit
            end if
        end do
        noted_slide = .false.
        failed_frames = 0
        do gf = 0, nf - 1
            si = film_span_at(fstate, gf)
            if (si == 0 .or. .not. fstate%spans(si)%loaded) then
                call framebuffer_clear(fb, 0, 0, 0)
            else
                if (fb%width /= fstate%spans(si)%sc%width .or. &
                    fb%height /= fstate%spans(si)%sc%height) then
                    call framebuffer_init(fb, &
                        fstate%spans(si)%sc%width, &
                        fstate%spans(si)%sc%height)
                    call framebuffer_init(fb2, &
                        fstate%spans(si)%sc%width, &
                        fstate%spans(si)%sc%height)
                end if
                t_local = real(gf - &
                    fstate%tl%scenes(si)%start_frame, dp) / fps_f
                if (allocated(models)) deallocate(models)
                allocate(models(max(1, &
                    fstate%spans(si)%sc%n_objects)))
                call render_scene_frame(fstate%spans(si)%sc, &
                    t_local, fb, models, fstate, si, gf)
                ! Transitions (fade/dissolve blend; slide/wipe and
                ! cut render as a plain cut).
                call film_transition(fstate, gf, si, in_tr, psi, alpha)
                if (in_tr) then
                    tr_kind = &
                        fstate%tl%scenes(si)%transition_kind
                    if (trim(tr_kind) == 'fade' .or. &
                        trim(tr_kind) == 'dissolve') then
                        if (psi >= 1 .and. &
                            fstate%spans(psi)%loaded) then
                            prev_frame = &
                                fstate%tl%scenes(psi)%end_frame - 1
                            allocate(models2(max(1, &
                                fstate%spans(psi)%sc%n_objects)))
                            call render_scene_frame( &
                                fstate%spans(psi)%sc, &
                                real(prev_frame - &
                                    fstate%tl%scenes(psi)%start_frame, &
                                    dp) / fps_f, &
                                fb2, models2, fstate, psi, prev_frame)
                            deallocate(models2)
                            do y = 1, fb%height
                                do x = 1, fb%width
                                    do c = 1, 3
                                        pa = real(fb2%pixels(c, x, y), dp)
                                        ca = real(fb%pixels(c, x, y), dp)
                                        if (trim(tr_kind) == 'dissolve') then
                                            ca = pa * (1.0_dp - alpha) &
                                                 + ca * alpha
                                        else if (alpha < 0.5_dp) then
                                            ca = pa * (1.0_dp - 2.0_dp * alpha)
                                        else
                                            ca = ca * (2.0_dp * alpha - 1.0_dp)
                                        end if
                                        fb%pixels(c, x, y) = &
                                            min(255, max(0, nint(ca)))
                                    end do
                                end do
                            end do
                        end if
                    else if ((trim(tr_kind) == 'slide' .or. &
                              trim(tr_kind) == 'wipe') .and. &
                             .not. noted_slide) then
                        write(error_unit, '(A)') 'note: film ' &
                            // 'transition "' // trim(tr_kind) &
                            // '" rendered as cut (slide/wipe are ' &
                            // 'not blended in v1)'
                        noted_slide = .true.
                    end if
                end if
            end if
            ! Saving mirrors scene mode: frame 1 -> base file; when
            ! nf > 1 every frame also lands in <base>_NNNN.<ext>.
            if (gf == 0) then
                call save_frame_image(fb, trim(film_output), &
                                      frame_write_ok)
                if (.not. frame_write_ok) stop 1
            end if
            if (nf > 1) then
                dotp = index(trim(film_output), '.', back=.true.)
                if (dotp > 1) then
                    base_n = film_output(1:dotp - 1)
                    ext_n = film_output(dotp:)
                else
                    base_n = trim(film_output)
                    ext_n = ''
                end if
                write(numbered, '(A, A, I4.4, A)') trim(base_n), &
                    '_', gf + 1, trim(ext_n)
                call save_frame_image(fb, trim(numbered), &
                                      frame_write_ok)
                if (.not. frame_write_ok) then
                    failed_frames = failed_frames + 1
                    if (gf == 0) stop 1
                end if
            end if
        end do
        if (failed_frames > 0) then
            write(error_unit, '(A, I0, A)') 'error: ', &
                failed_frames, &
                ' frame(s) failed to write; render incomplete'
            stop 1
        end if
        ! Wave 5 (X3): '--video <file.mp4>' for films -- before
        ! this, film mode ignored has_video entirely and exited 0
        ! with no video and no message (silent success-without-
        ! video).  Assemble the numbered frames just written at
        ! the FILM fps, through the same helper as scene mode;
        ! transitions are already rendered into those frames by
        ! the film loop above, so they are in the video too.
        if (has_video .and. nf > 1) &
            call assemble_video(trim(film_output), fps_f)
        print *, '============================================'
        print *, ' Film rendering completed!'
        print *, '   Film:    ', trim(fstate%tl%name)
        print *, '   Frames:  ', nf
        print *, '   Output:  ', trim(film_output)
        print *, '============================================'
    end subroutine run_film

    ! v3.0 Phase 8 / Wave 5 (X3): assemble the numbered frame
    ! files for output_file_arg ('<base>_NNNN<ext>', frame 1 also
    ! in the un-numbered base file) into video_file (the global
    ! --video value) with ffmpeg: image2 demuxer over the
    ! '<base>_%04d<ext>' pattern at fps_arg, libx264 / yuv420p.
    ! Failure contract (documented, ANIM-PLAN 4.5 + Wave 5):
    !   * ffmpeg ABSENT from PATH: frames-only, exit code
    !     unchanged (0 on an otherwise successful render), but
    !     NEVER silent -- a loud stderr warning names ffmpeg,
    !     states the frame files are kept, and prints the exact
    !     assembly command the user can run after installing it.
    !   * ffmpeg present but FAILING: frames kept + a stderr
    !     note, exit code unchanged (the Phase-8 design).
    ! Callers invoke this only for multi-frame renders whose
    ! frames all wrote successfully (write failures stop 1
    ! before assembly, in both scene and film mode).
    subroutine assemble_video(output_file_arg, fps_arg)
        character(len=*), intent(in) :: output_file_arg
        real(dp), intent(in) :: fps_arg
        character(len=1024) :: pat, bname, ename
        character(len=2048) :: cmd
        integer :: dpos, st, cst, fi
        logical :: failed

        dpos = index(trim(output_file_arg), '.', back=.true.)
        if (dpos > 1) then
            bname = output_file_arg(1:dpos - 1)
            ename = output_file_arg(dpos:)
        else
            bname = trim(output_file_arg)
            ename = ''
        end if
        write(pat, '(A, A, A)') trim(bname), '_%04d', trim(ename)
        fi = max(1, nint(fps_arg))
        write(cmd, '(A, I0, A, A, A, A, A)') &
            'ffmpeg -y -framerate ', fi, &
            ' -f image2 -i ''', trim(pat), &
            ''' -c:v libx264 -pix_fmt yuv420p ''', &
            trim(video_file), ''''
        st = 0
        cst = 0
        call execute_command_line('ffmpeg -version > /dev/null 2>&1', &
            wait=.true., exitstat=st, cmdstat=cst)
        failed = .false.
        if (cst /= 0) failed = .true.
        if (st /= 0) failed = .true.
        if (failed) then
            write(error_unit, '(A)') &
                'warning: --video: ffmpeg not found on PATH; ' &
                // 'no video written to "' // trim(video_file) // '"'
            write(error_unit, '(A)') &
                'warning: --video: frame files kept ("' &
                // trim(pat) // '" plus the un-numbered base file)'
            write(error_unit, '(A)') &
                'warning: --video: install ffmpeg, then assemble ' &
                // 'the kept frames with: ' // trim(cmd)
            return
        end if
        st = 0
        cst = 0
        call execute_command_line(trim(cmd), wait=.true., &
            exitstat=st, cmdstat=cst)
        failed = .false.
        if (cst /= 0) failed = .true.
        if (st /= 0) failed = .true.
        if (failed) then
            write(error_unit, '(A)') &
                'note: --video: ffmpeg failed; frame ' &
                // 'files kept, no video written to "' &
                // trim(video_file) // '"'
        end if
    end subroutine assemble_video

    ! v3.0 Phase 8: binary PPM (P6) writer.  The shared PPM write
    ! point in renderer_3d (framebuffer_save_ppm, reached via
    ! framebuffer_save_image) writes P3 ASCII only and is outside
    ! this slice, so main routes .ppm writes here instead when
    ! binary_ppm is set: header "P6\n<w> <h>\n255\n" followed by
    ! the raw RGB bytes, written with access='stream' so no
    ! record markers intervene.
    ! v3.0 Phase 9: every open / write / close below carries an
    ! iostat; the first failure sets ok_out = .false., prints
    ! 'error: failed to write <file> (...)' to stderr, and the
    ! caller decides between stop 1 (first frame / single image)
    ! and counting the loss (later animation frames).
    subroutine save_ppm_binary(fb_arg, filename, ok_out)
        type(FrameBuffer), intent(in) :: fb_arg
        character(len=*), intent(in) :: filename
        logical, intent(out) :: ok_out
        integer :: u, x, y, ios, close_ios
        character(len=32) :: dim_buf

        ok_out = .false.
        open(newunit=u, file=filename, status='replace', &
             action='write', access='stream', form='unformatted', &
             iostat=ios)
        if (ios /= 0) then
            write(error_unit, '(A, A, A, I0, A)') &
                'error: failed to write "', trim(filename), &
                '" (open failed, iostat ', ios, ')'
            return
        end if
        write(u, iostat=ios) 'P6' // char(10)
        if (ios == 0) then
            write(dim_buf, '(I0, 1X, I0)') fb_arg%width, &
                fb_arg%height
            write(u, iostat=ios) trim(dim_buf) // char(10)
        end if
        if (ios == 0) write(u, iostat=ios) '255' // char(10)
        do y = 1, fb_arg%height
            if (ios /= 0) exit
            do x = 1, fb_arg%width
                if (ios /= 0) exit
                write(u, iostat=ios) char(min(255, max(0, &
                    fb_arg%pixels(1, x, y))))
                if (ios == 0) write(u, iostat=ios) &
                    char(min(255, max(0, &
                        fb_arg%pixels(2, x, y))))
                if (ios == 0) write(u, iostat=ios) &
                    char(min(255, max(0, &
                        fb_arg%pixels(3, x, y))))
            end do
        end do
        close(u, iostat=close_ios)
        if (ios == 0) ios = close_ios
        if (ios /= 0) then
            write(error_unit, '(A, A, A, I0, A)') &
                'error: failed to write "', trim(filename), &
                '" (write/close failed, iostat ', ios, ')'
            return
        end if
        ok_out = .true.
    end subroutine save_ppm_binary

    ! v3.0 Phase 9: existence/size wrap for writers that return
    ! no status.  LIMITATION (documented, not hidden): the shared
    ! writers framebuffer_save_image / framebuffer_save_ppm /
    ! framebuffer_save_png in renderer_3d (and png_save_file in
    ! png_write_3d behind them) and the export_mesh_json /
    ! export_mesh_obj exporters in mesh_3d take no status
    ! argument and their internal open/write statements carry no
    ! iostat, so this file cannot see their errors directly.
    ! What can be checked at the call level is done here: after
    ! the call the file must exist and be non-empty.  A mid-write
    ! failure that leaves a non-empty partial file behind (disk
    ! filling up part-way through a frame) is NOT detectable this
    ! way; fixing that requires a status return from the shared
    ! writers themselves, which are outside this slice.
    function check_written_file(filename) result(chk_ok)
        character(len=*), intent(in) :: filename
        logical :: chk_ok
        logical :: chk_exists
        integer :: chk_ios, chk_size

        chk_ok = .false.
        chk_exists = .false.
        chk_size = 0
        inquire(file=trim(filename), exist=chk_exists, &
                size=chk_size, iostat=chk_ios)
        if (chk_ios == 0) then
            if (chk_exists) then
                if (chk_size > 0) chk_ok = .true.
            end if
        end if
        if (.not. chk_ok) then
            write(error_unit, '(A, A, A)') &
                'error: failed to write "', trim(filename), &
                '" (file missing or empty after write)'
        end if
    end function check_written_file

    ! True when filename ends in '.png' (case-insensitive), the
    ! same dispatch rule framebuffer_save_image uses.  The length
    ! test and the substring access are nested, not combined:
    ! .and. does not short-circuit.
    function is_png_filename(filename) result(is_png)
        character(len=*), intent(in) :: filename
        logical :: is_png
        integer :: n, i, c
        character(len=4) :: ext

        is_png = .false.
        n = len_trim(filename)
        if (n >= 4) then
            ext = filename(n - 3:n)
            do i = 1, 4
                c = ichar(ext(i:i))
                if (c >= ichar('A') .and. c <= ichar('Z')) &
                    ext(i:i) = char(c - ichar('A') + ichar('a'))
            end do
            if (ext == '.png') is_png = .true.
        end if
    end function is_png_filename

    ! Frame-write dispatch for the scene paths: PNG outputs are
    ! unaffected by --binary-ppm and always go to the shared
    ! framebuffer_save_image; .ppm outputs go to the P6 writer
    ! when binary_ppm is set, else to the same shared writer
    ! (which writes the historic P3 for them).
    ! v3.0 Phase 9: ok_out reports the write result to the
    ! caller (see save_ppm_binary / check_written_file).  The
    ! shared-writer branch is wrapped with the existence/size
    ! check because framebuffer_save_image returns no status;
    ! see the limitation note on check_written_file.
    subroutine save_frame_image(fb_arg, filename, ok_out)
        type(FrameBuffer), intent(in) :: fb_arg
        character(len=*), intent(in) :: filename
        logical, intent(out) :: ok_out

        integer :: pu, pios

        ok_out = .false.
        if (binary_ppm) then
            if (.not. is_png_filename(filename)) then
                call save_ppm_binary(fb_arg, filename, ok_out)
                return
            end if
        end if
        ! Wave 5 (X3): pre-flight writability probe.  The shared
        ! writer carries no iostat, so an unwritable target (bad
        ! directory, read-only location) used to abort the whole
        ! program inside renderer_3d with a Fortran runtime error
        ! before check_written_file could run.  Probe the open
        ! here instead: on failure, report a clean diagnostic and
        ! let the caller stop 1 (first frame) or count the loss
        ! (later frames).  The probe creates/truncates the file;
        ! the shared writer immediately rewrites it in full.
        open(newunit=pu, file=trim(filename), status='replace', &
             action='write', iostat=pios)
        if (pios /= 0) then
            write(error_unit, '(A, A, A, I0, A)') &
                'error: failed to write "', trim(filename), &
                '" (open failed, iostat ', pios, ')'
            return
        end if
        close(pu)
        call framebuffer_save_image(fb_arg, filename)
        ok_out = check_written_file(filename)
    end subroutine save_frame_image

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
