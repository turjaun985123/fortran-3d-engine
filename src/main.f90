program main
    use math_3d
    use mesh_3d
    use camera_3d
    use renderer_3d
    use scene_3d
    use animation_3d
    use shadow_3d
    use fog_3d
    use tonemapping_3d
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

    nargs = command_argument_count()

    if (nargs == 0) then
        ! ================================================================
        ! Legacy demo: no command argument.
        ! This path is the byte-for-byte regression anchor -- do not
        ! change its prints, files or rendering calls.
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
        call framebuffer_render_mesh(fb, cube, model_matrix, cam, light_dir)

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
        call get_command_argument(1, scene_path)

        call scene_load(trim(scene_path), sc, ok, errmsg)
        if (.not. ok) then
            write(*, '(A)') 'error: cannot load scene: ' // trim(errmsg)
            stop 1
        end if

        n_frames = max(1, sc%frames)
        if (allocated(sc%objects)) then
            n_objects = size(sc%objects)
        else
            n_objects = 0
        end if

        ! Frame timing comes from the first animation's fps (default 30).
        fps_r = 30.0_dp
        if (allocated(sc%anims)) then
            if (size(sc%anims) > 0) fps_r = real(sc%anims(1)%fps, dp)
        end if
        if (fps_r <= 0.0_dp) fps_r = 30.0_dp

        call framebuffer_init(fb, sc%width, sc%height)
        if (sc%has_env) allocate(models(max(1, n_objects)))

        do frame_i = 1, n_frames
            t_sec = real(frame_i - 1, dp) / fps_r

            call framebuffer_clear(fb, sc%bg(1), sc%bg(2), sc%bg(3))

            do obj_i = 1, n_objects
                ! Accumulate animation deltas for this object: animations
                ! target it by name, or target 'all'.
                d_rot = 0.0_dp
                d_pos = 0.0_dp
                scale_factor = 1.0_dp
                if (allocated(sc%anims)) then
                    do anim_i = 1, size(sc%anims)
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

                if (sc%has_env) then
                    models(obj_i) = model
                else
                    call framebuffer_render_mesh_mat(fb, &
                        sc%objects(obj_i)%mesh, model, sc%cam, &
                        sc%light_dir, sc%objects(obj_i)%mat, sc%ambient)
                end if
            end do

            if (sc%has_env) then
                ! Wave A: shadow map from the first shadow-casting
                ! light (spot/point position, else the directional
                ! placed opposite its direction), then env rendering,
                ! then fog / tonemapping post passes.
                if (sc%shadow_mode > 0) then
                    sh_pos = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
                    sh_tgt = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
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
                        if (li > size(sc%lights%items)) &
                            sh_pos = vec3_scale( &
                                vec3_normalize(sc%light_dir), -30.0_dp)
                    end if
                    call shadow_begin(smap, sh_pos, sh_tgt, &
                                      sc%shadow_size, 60.0_dp, 0.5_dp, &
                                      80.0_dp)
                    do obj_i = 1, n_objects
                        call shadow_add_mesh(smap, &
                            sc%objects(obj_i)%mesh, models(obj_i))
                    end do
                    call shadow_end(smap)
                end if

                do obj_i = 1, n_objects
                    extents = object_extents(sc%objects(obj_i))
                    call framebuffer_render_mesh_env(fb, &
                        sc%objects(obj_i)%mesh, models(obj_i), sc%cam, &
                        sc%lights, sc%objects(obj_i)%pbr, &
                        sc%objects(obj_i)%tex, &
                        trim(sc%objects(obj_i)%prim), extents, smap, &
                        sc%shadow_mode)
                end do

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

            ! Frame 1 (frame 0 in t) always lands in sc%output_file.
            if (frame_i == 1) call framebuffer_save_ppm(fb, trim(sc%output_file))

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
                call framebuffer_save_ppm(fb, trim(numbered_file))
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
