! test_scene_json.f90 -- ADR-3 (v3.0 Phase 1): the typed JSON scene
! reader (scene_json_3d's scene_load_json) must load the compiler's
! keyed, versioned JSON artifact (build/<name>.json, format
! "forge3d-scene", ir_version 1) into the same Scene the v1 text
! reader (scene_load on build/<name>.scene) produces.
!
! The test builds each example with bin/f3dc into a scratch dir
! (.scene-json-test-scratch under the repo root, removed at the end),
! loads BOTH artifacts, and asserts structural equality: dimensions,
! background, camera, lights, frame count, object counts, and per
! object the primitive kind, name, position and point count, plus
! per-example extras (animations, PBR fields, texture, key tracks,
! sprites/texts/particles, ortho/post/instances, wavee bindings).
!
! Where the JSON format by design carries less than the .scene text
! (see docs/SCENE-FORMAT.md), the test asserts the subset that must
! hold and PRINTS each difference as a "DIFFERENCE:" line instead of
! failing: point/spot light cone/falloff fields and spot direction
! (not serialised into the JSON lights array), and the mesh of
! "load" objects (the JSON source_file is .f3d-relative and the
! JSON carries no base_dir to resolve it against).
program test_scene_json
    use math_3d
    use scene_3d
    use scene_json_3d
    use test_assert
    implicit none

    character(len=512) :: env, repo, scratch
    integer :: st

    ! Portable repo location: FORGE3D_ROOT when set, else the
    ! current directory (the test harness runs from the repo root
    ! both locally and in CI).  Never hardcode a home directory --
    ! the original version of this test did, and failed in CI.
    call get_environment_variable('FORGE3D_ROOT', env, status=st)
    if (st == 0 .and. len_trim(env) > 0) then
        repo = trim(env)
    else
        repo = '.'
    end if
    scratch = trim(repo) // '/.scene-json-test-scratch'

    call execute_command_line('rm -rf ' // trim(scratch) // &
        ' && mkdir -p ' // trim(scratch), exitstat=st)
    call assert_true(st == 0, 'scratch dir created')

    call check_example('hello-cube')
    call check_example('multi-object')
    call check_example('materials')
    call check_example('lighting-showcase')
    call check_example('geometries')
    call check_example('waveb-showcase')
    call check_example('post-ortho')
    call check_example('wavee-showcase')
    call check_rejections()

    call execute_command_line('rm -rf ' // trim(scratch), &
                              exitstat=st)
    call test_summary()

contains

    subroutine build_example(name)
        character(len=*), intent(in) :: name
        character(len=1024) :: cmd
        integer :: cst
        cmd = trim(repo) // '/bin/f3dc build ' // trim(repo) // &
              '/examples/' // trim(name) // '.f3d --out ' // &
              trim(scratch) // '/' // trim(name)
        call execute_command_line(trim(cmd), exitstat=cst)
        call assert_true(cst == 0, 'f3dc build ok: ' // trim(name))
    end subroutine build_example

    ! Load both artifacts of one built example and compare.
    subroutine check_example(name)
        character(len=*), intent(in) :: name
        type(Scene) :: a, b
        logical :: ok_a, ok_b
        character(len=256) :: err_a, err_b
        character(len=1024) :: scene_path, json_path
        integer :: i

        call build_example(name)
        scene_path = trim(scratch) // '/' // trim(name) // '/' // &
                     trim(name) // '.scene'
        json_path = trim(scratch) // '/' // trim(name) // '/' // &
                    trim(name) // '.json'
        call scene_load(trim(scene_path), a, ok_a, err_a)
        call scene_load_json(trim(json_path), b, ok_b, err_b)
        call assert_true(ok_a, trim(name) // ': v1 scene_load ok')
        if (.not. ok_b) write(*, '(A, A)') '  json error: ', &
            trim(err_b)
        call assert_true(ok_b, trim(name) // ': scene_load_json ok')
        if (.not. (ok_a .and. ok_b)) then
            call scene_free(a)
            call scene_free(b)
            return
        end if

        call assert_int_eq(a%width, b%width, &
            trim(name) // ': width equal')
        call assert_int_eq(a%height, b%height, &
            trim(name) // ': height equal')
        call assert_true(all(a%bg == b%bg), &
            trim(name) // ': bg equal')
        call assert_vec3_close(a%cam%position, b%cam%position, &
            1.0e-9_dp, trim(name) // ': camera pos equal')
        call assert_vec3_close(a%cam%target, b%cam%target, &
            1.0e-9_dp, trim(name) // ': camera target equal')
        call assert_vec3_close(a%cam%up, b%cam%up, 1.0e-9_dp, &
            trim(name) // ': camera up equal')
        call assert_real_close(a%cam%fov_deg, b%cam%fov_deg, &
            1.0e-9_dp, trim(name) // ': camera fov equal')
        call assert_real_close(a%cam%near_plane, b%cam%near_plane, &
            1.0e-9_dp, trim(name) // ': camera near equal')
        call assert_real_close(a%cam%far_plane, b%cam%far_plane, &
            1.0e-9_dp, trim(name) // ': camera far equal')
        call assert_int_eq(a%frames, b%frames, &
            trim(name) // ': frame count equal')
        call assert_true(trim(a%output_file) == &
            trim(b%output_file), trim(name) // ': output equal')
        call assert_real_close(a%ambient, b%ambient, 1.0e-9_dp, &
            trim(name) // ': ambient equal')
        call assert_real_close(a%light_intensity, &
            b%light_intensity, 1.0e-9_dp, &
            trim(name) // ': directional intensity equal')
        call assert_vec3_close(a%light_dir, b%light_dir, &
            1.0e-9_dp, trim(name) // ': directional dir equal')
        call assert_true(all(a%light_color == b%light_color), &
            trim(name) // ': directional colour equal')

        ! Lights: count and per-light kind must match.  Positions
        ! and intensities of point/spot lights must match too; the
        ! spot direction and cone/falloff fields are NOT in the
        ! JSON (format gap) and are reported, not asserted.
        call assert_true(allocated(a%lights%items) .eqv. &
            allocated(b%lights%items), &
            trim(name) // ': LightSet allocated in both')
        if (allocated(a%lights%items) .and. &
            allocated(b%lights%items)) then
            call assert_int_eq(size(a%lights%items), &
                size(b%lights%items), &
                trim(name) // ': light count equal')
            do i = 1, min(size(a%lights%items), &
                          size(b%lights%items))
                call assert_int_eq(a%lights%items(i)%kind, &
                    b%lights%items(i)%kind, &
                    trim(name) // ': light kind equal')
                call assert_real_close( &
                    a%lights%items(i)%intensity, &
                    b%lights%items(i)%intensity, 1.0e-9_dp, &
                    trim(name) // ': light intensity equal')
                if (a%lights%items(i)%kind /= 0) then
                    call assert_vec3_close(a%lights%items(i)%pos, &
                        b%lights%items(i)%pos, 1.0e-9_dp, &
                        trim(name) // ': point/spot pos equal')
                    if (a%lights%items(i)%kind == 2) &
                        write(*, '(A)') 'DIFFERENCE: ' // &
                            trim(name) // ': spot direction / ' // &
                            'angle / penumbra not serialised ' // &
                            'in JSON lights (v1 spot_dir vs JSON ' // &
                            'default (0,-1,0), angle 45, penumbra 0)'
                end if
            end do
        end if

        ! Environment subset that IS serialised (extensions.env).
        call assert_int_eq(a%fog_mode, b%fog_mode, &
            trim(name) // ': fog mode equal')
        call assert_int_eq(a%tonemap_mode, b%tonemap_mode, &
            trim(name) // ': tonemap mode equal')
        call assert_int_eq(a%shadow_mode, b%shadow_mode, &
            trim(name) // ': shadow mode equal')
        call assert_true(a%ortho .eqv. b%ortho, &
            trim(name) // ': ortho flag equal')
        call assert_real_close(a%ortho_size, b%ortho_size, &
            1.0e-9_dp, trim(name) // ': ortho size equal')
        call assert_int_eq(a%n_post, b%n_post, &
            trim(name) // ': post chain length equal')

        ! Objects: count, then per object prim/name/pos/points.
        call assert_int_eq(a%n_objects, b%n_objects, &
            trim(name) // ': object count equal')
        do i = 1, min(a%n_objects, b%n_objects)
            call assert_true(trim(a%objects(i)%prim) == &
                trim(b%objects(i)%prim), &
                trim(name) // ': object prim equal')
            call assert_true(trim(a%objects(i)%name) == &
                trim(b%objects(i)%name), &
                trim(name) // ': object name equal')
            call assert_vec3_close(a%objects(i)%pos, &
                b%objects(i)%pos, 1.0e-9_dp, &
                trim(name) // ': object pos equal')
            call assert_int_eq(a%objects(i)%n_pts, &
                b%objects(i)%n_pts, &
                trim(name) // ': object point count equal')
            call assert_true(all(a%objects(i)%color == &
                b%objects(i)%color), &
                trim(name) // ': object colour equal')
            if (trim(a%objects(i)%prim) == 'load') then
                write(*, '(A)') 'DIFFERENCE: ' // trim(name) // &
                    ': load object mesh may differ -- JSON ' // &
                    'source_file is .f3d-relative with no ' // &
                    'base_dir in the JSON (v1 .scene path is ' // &
                    'absolute); prim/pos asserted, mesh not'
            else if (trim(a%objects(i)%prim) /= 'tris') then
                call assert_int_eq( &
                    a%objects(i)%mesh%num_triangles, &
                    b%objects(i)%mesh%num_triangles, &
                    trim(name) // ': object mesh size equal')
            else
                call assert_int_eq( &
                    a%objects(i)%mesh%num_triangles, &
                    b%objects(i)%mesh%num_triangles, &
                    trim(name) // ': tris mesh size equal')
            end if
        end do

        ! Animations: count, then per-anim kind/target/speed.
        call assert_int_eq(a%n_anims, b%n_anims, &
            trim(name) // ': anim count equal')
        do i = 1, min(a%n_anims, b%n_anims)
            call assert_true(trim(a%anims(i)%kind) == &
                trim(b%anims(i)%kind), &
                trim(name) // ': anim kind equal')
            call assert_true(trim(a%anims(i)%target) == &
                trim(b%anims(i)%target), &
                trim(name) // ': anim target equal')
            call assert_real_close(a%anims(i)%speed, &
                b%anims(i)%speed, 1.0e-9_dp, &
                trim(name) // ': anim speed equal')
            call assert_int_eq(a%anims(i)%fps, b%anims(i)%fps, &
                trim(name) // ': anim fps equal')
        end do

        ! Wave B/C entity counts.
        call assert_int_eq(a%n_sprites, b%n_sprites, &
            trim(name) // ': sprite count equal')
        call assert_int_eq(a%n_texts, b%n_texts, &
            trim(name) // ': text count equal')
        call assert_int_eq(a%n_parts, b%n_parts, &
            trim(name) // ': particle count equal')
        call assert_int_eq(a%n_tracks, b%n_tracks, &
            trim(name) // ': key track count equal')
        if (a%n_tracks > 0 .and. b%n_tracks > 0) then
            call assert_true( &
                trim(a%tracks(1)%target) == &
                trim(b%tracks(1)%target), &
                trim(name) // ': track target equal')
            call assert_int_eq(size(a%tracks(1)%keys), &
                size(b%tracks(1)%keys), &
                trim(name) // ': track key count equal')
        end if
        if (a%n_texts > 0 .and. b%n_texts > 0) &
            call assert_true(trim(a%texts(1)%content) == &
                trim(b%texts(1)%content), &
                trim(name) // ': text content equal')

        select case (trim(name))
        case ('lighting-showcase')
            ! PBR fields ride in extensions.material (JSON) vs the
            ! objmat line (v1): they must agree per object.
            do i = 1, min(a%n_objects, b%n_objects)
                call assert_real_close(a%objects(i)%pbr%metalness, &
                    b%objects(i)%pbr%metalness, 1.0e-9_dp, &
                    'lighting-showcase: pbr metalness equal')
                call assert_real_close(a%objects(i)%pbr%roughness, &
                    b%objects(i)%pbr%roughness, 1.0e-9_dp, &
                    'lighting-showcase: pbr roughness equal')
            end do
            call assert_true(a%objects(2)%tex%loaded .eqv. &
                b%objects(2)%tex%loaded, &
                'lighting-showcase: checker texture loaded in both')
        case ('wavee-showcase')
            call assert_true(allocated(a%shader_defs) .eqv. &
                allocated(b%shader_defs), &
                'wavee-showcase: shader defs present in both')
            if (allocated(a%shader_defs) .and. &
                allocated(b%shader_defs)) &
                call assert_int_eq(size(a%shader_defs), &
                    size(b%shader_defs), &
                    'wavee-showcase: shader def count equal')
            call assert_true(allocated(a%bones) .eqv. &
                allocated(b%bones), &
                'wavee-showcase: bones present in both')
            do i = 1, min(a%n_objects, b%n_objects)
                call assert_true(a%objects(i)%has_shader .eqv. &
                    b%objects(i)%has_shader, &
                    'wavee-showcase: shader binding equal')
            end do
        end select

        call scene_free(a)
        call scene_free(b)
    end subroutine check_example

    ! Negative cases: every one must fail with ok=.false.
    subroutine check_rejections()
        type(Scene) :: sc
        logical :: ok
        character(len=256) :: errmsg
        integer :: u
        character(len=1024) :: p

        p = trim(scratch) // '/bad-format.json'
        open(newunit=u, file=trim(p), status='replace', &
             action='write')
        write(u, '(A)') '{"format": "something-else", ' // &
                        '"ir_version": 1}'
        close(u)
        call scene_load_json(trim(p), sc, ok, errmsg)
        call assert_false(ok, 'reject: wrong format string')
        call assert_true(len_trim(errmsg) > 0, &
            'reject: wrong format carries an error message')
        call scene_free(sc)

        p = trim(scratch) // '/bad-version.json'
        open(newunit=u, file=trim(p), status='replace', &
             action='write')
        write(u, '(A)') '{"format": "forge3d-scene", ' // &
                        '"ir_version": 99}'
        close(u)
        call scene_load_json(trim(p), sc, ok, errmsg)
        call assert_false(ok, 'reject: unsupported ir_version 99')
        call scene_free(sc)

        p = trim(scratch) // '/malformed.json'
        open(newunit=u, file=trim(p), status='replace', &
             action='write')
        write(u, '(A)') '{"format": "forge3d-scene", '
        close(u)
        call scene_load_json(trim(p), sc, ok, errmsg)
        call assert_false(ok, 'reject: truncated JSON')
        call scene_free(sc)

        call scene_load_json(trim(scratch) // '/no-such-file.json', &
                             sc, ok, errmsg)
        call assert_false(ok, 'reject: missing file')
        call scene_free(sc)
    end subroutine check_rejections

end program test_scene_json
