! scene_json.f90 -- Forge3D JSON scene reader (v3.0 Phase 1, ADR-3).
!
! Module scene_json_3d: the typed reader for the versioned, keyed
! scene format the compiler emits next to every .scene file:
!
!   build/<name>.json   { "format": "forge3d-scene", "ir_version": 1,
!                         "width", "height", "bg", "camera", "lights",
!                         "objects", "animations", "outputs",
!                         "extensions" }
!
! scene_load_json fills the SAME Scene type as the v1 text reader
! (scene_3d's scene_load in scene.f90), with the same defaults, so a
! scene loaded either way renders identically wherever the JSON
! actually carries the data.  The .scene v1 text format stays the
! legacy path and is untouched; this module is purely additive.
!
! Parsing goes through the shared typed JSON parser
! (json_reader_3d, src/json_reader.f90) -- no text scanning here.
!
! scene_3d's append_* / scene_trim_storage / set_object_material
! helpers are private to that module, so this module carries local
! equivalents (j_append_*, j_trim_storage, j_set_material) with
! byte-for-byte the same semantics (capacity doubling, trimmed on
! return; material built via material_from_name / pbr_from_material
! exactly as scene.f90's set_object_material).  Mesh building itself
! IS shared: j builds each object through the public
! scene_build_object_mesh, so per-primitive defaults cannot drift.
!
! Known format gaps (JSON carries less than the .scene text; see
! docs/SCENE-FORMAT.md for the full table):
!   * Point/spot lights: the JSON light object carries only
!     kind/direction/color/intensity, and for point/spot lights
!     "direction" holds the light POSITION (the IR serialiser drops
!     position/target/distance/decay/angle/penumbra).  The reader
!     therefore uses the documented defaults for the missing fields
!     (distance 0, decay 2, angle 45, penumbra 0, spot direction
!     (0,-1,0)) unless a future emitter adds the optional keys
!     position/at, target/look, distance, decay, angle, penumbra,
!     all of which this reader already honours when present.
!   * "load" objects: "source_file" is relative to the .f3d source
!     (e.g. "../model.obj"); the JSON carries no base_dir, so
!     resolution follows the v1 rule (cwd, then the scene file's own
!     directory) and can miss where the .scene path (which the
!     emitter rewrites to an absolute path) succeeds.
!   * Frame count is not stored in the JSON; it is re-derived with
!     the emitter's own rule (see j_frame_count).
module scene_json_3d
    use, intrinsic :: iso_fortran_env, only: int64
    use math_3d
    use mesh_3d, only: Mesh, Triangle, free_mesh, &
                        compute_triangle_normal
    use camera_3d, only: camera_init, camera_update_matrices
    use material_3d, only: material_from_name, material_id_from_name
    use material_pbr_3d, only: MaterialPBR, MAT_STANDARD, &
                               pbr_from_material
    use texture_3d, only: texture_load_ppm
    use lighting_3d, only: Light3, LightSet
    use particles_3d, only: particle_system_init
    use keyframe_3d, only: KeyFrame, KeyTrack
    use shader_3d, only: ShaderProg, shader_parse
    use skinning_3d, only: morph_apply, skin_apply
    use scene_3d
    use json_reader_3d
    implicit none
    private
    public :: scene_load_json

    integer, parameter :: JK_NULL = 0, JK_BOOL = 1, JK_NUM = 2, &
                          JK_STR = 3, JK_ARR = 4, JK_OBJ = 5

contains

    ! ------------------------------------------------------------------
    ! Small helpers
    ! ------------------------------------------------------------------

    function j_lower(s) result(out)
        character(len=*), intent(in) :: s
        character(len=len(s)) :: out
        integer :: i, c
        out = s
        do i = 1, len_trim(s)
            c = iachar(s(i:i))
            if (c >= iachar('A') .and. c <= iachar('Z')) &
                out(i:i) = achar(c + 32)
        end do
    end function j_lower

    ! Read a whole file into an allocated string (stream access, so
    ! no record-length or line-length limits apply).
    subroutine j_read_file(path, text, ok, errmsg)
        character(len=*), intent(in) :: path
        character(len=:), allocatable, intent(out) :: text
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        integer :: u, ios
        integer(int64) :: fsize
        ok = .false.
        errmsg = ''
        inquire(file=trim(path), size=fsize, iostat=ios)
        if (ios /= 0 .or. fsize <= 0) then
            errmsg = 'scene_load_json: cannot open file: ' // trim(path)
            return
        end if
        open(newunit=u, file=trim(path), status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) then
            errmsg = 'scene_load_json: cannot open file: ' // trim(path)
            return
        end if
        allocate(character(len=int(fsize)) :: text)
        read(u, iostat=ios) text
        close(u)
        if (ios /= 0) then
            errmsg = 'scene_load_json: cannot read file: ' // trim(path)
            deallocate(text)
            return
        end if
        ok = .true.
    end subroutine j_read_file

    ! Directory part of a path ('' when there is no '/').
    function j_dir_of(path) result(dir)
        character(len=*), intent(in) :: path
        character(len=512) :: dir
        integer :: slash
        dir = ''
        slash = index(trim(path), '/', back=.true.)
        if (slash > 1) dir = path(1:slash - 1)
    end function j_dir_of

    ! Same rule as scene.f90's resolve_scene_path: absolute paths and
    ! paths that exist relative to the cwd win; otherwise try the
    ! scene file's own directory.
    function j_resolve_path(dir, path) result(res)
        character(len=*), intent(in) :: dir, path
        character(len=256) :: res
        logical :: ex
        res = trim(path)
        if (len_trim(path) == 0) return
        if (path(1:1) == '/') return
        inquire(file=trim(path), exist=ex)
        if (ex) return
        if (len_trim(dir) > 0) res = trim(dir) // '/' // trim(path)
    end function j_resolve_path

    ! Object field lookup: child node index (0) + found flag.
    subroutine j_get(doc, node, key, child, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        integer, intent(out) :: child
        logical, intent(out) :: found
        child = 0
        found = .false.
        if (node <= 0) return
        if (json_kind(doc, node) /= JK_OBJ) return
        call json_obj_get(doc, node, key, child, found)
        if (.not. found) child = 0
    end subroutine j_get

    ! Numeric object field; present means "key exists and is a JSON
    ! number" (null / missing / wrong type all count as absent, which
    ! is exactly how the emitter's null-valued keys must behave).
    function j_num_field(doc, node, key, def, was_present) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        real(dp), intent(in) :: def
        logical, intent(out), optional :: was_present
        real(dp) :: v
        integer :: child
        logical :: found
        v = def
        if (present(was_present)) was_present = .false.
        call j_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= JK_NUM) return
        v = json_num(doc, child, def)
        if (present(was_present)) was_present = .true.
    end function j_num_field

    function j_int_field(doc, node, key, def, was_present) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        integer, intent(in) :: def
        logical, intent(out), optional :: was_present
        integer :: v
        integer :: child
        logical :: found
        v = def
        if (present(was_present)) was_present = .false.
        call j_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= JK_NUM) return
        v = json_int(doc, child, def)
        if (present(was_present)) was_present = .true.
    end function j_int_field

    ! String object field into a fixed buffer ('' when absent/null).
    function j_str_field(doc, node, key) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        character(len=512) :: v
        integer :: child
        logical :: found
        character(len=:), allocatable :: s
        v = ''
        call j_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= JK_STR) return
        s = json_str(doc, child)
        if (allocated(s)) v = s
    end function j_str_field

    logical function j_has_str(doc, node, key)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        integer :: child
        logical :: found
        call j_get(doc, node, key, child, found)
        j_has_str = found .and. json_kind(doc, child) == JK_STR
    end function j_has_str

    ! vec3 from a JSON array field; missing components fall back to
    ! the matching component of def, a missing/null field to def.
    function j_vec3_field(doc, node, key, def) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        type(vec3), intent(in) :: def
        type(vec3) :: v
        integer :: child, elem, k
        logical :: found
        real(dp) :: comp(3)
        v = def
        call j_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= JK_ARR) return
        comp = [def%x, def%y, def%z]
        do k = 1, min(3, json_arr_len(doc, child))
            call json_arr_at(doc, child, k, elem)
            comp(k) = json_num(doc, elem, comp(k))
        end do
        v = vec3_create(comp(1), comp(2), comp(3))
    end function j_vec3_field

    ! vec3 directly from an array NODE (for point lists / vertices).
    function j_vec3_node(doc, node, ncomp) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        integer, intent(in) :: ncomp  ! 2 or 3 components expected
        type(vec3) :: v
        integer :: elem, k
        real(dp) :: comp(3)
        comp = 0.0_dp
        if (json_kind(doc, node) == JK_ARR) then
            do k = 1, min(3, json_arr_len(doc, node))
                call json_arr_at(doc, node, k, elem)
                comp(k) = json_num(doc, elem, 0.0_dp)
            end do
        end if
        if (ncomp == 2) comp(3) = 0.0_dp
        v = vec3_create(comp(1), comp(2), comp(3))
    end function j_vec3_node

    ! RGB triple from a JSON array field (ints); def when absent.
    function j_color_field(doc, node, key, def) result(c)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        integer, intent(in) :: def(3)
        integer :: c(3)
        integer :: child, elem, k
        logical :: found
        c = def
        call j_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= JK_ARR) return
        do k = 1, min(3, json_arr_len(doc, child))
            call json_arr_at(doc, child, k, elem)
            c(k) = json_int(doc, elem, c(k))
        end do
    end function j_color_field

    function j_color_node(doc, node, def) result(c)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        integer, intent(in) :: def(3)
        integer :: c(3)
        integer :: elem, k
        c = def
        if (json_kind(doc, node) /= JK_ARR) return
        do k = 1, min(3, json_arr_len(doc, node))
            call json_arr_at(doc, node, k, elem)
            c(k) = json_int(doc, elem, c(k))
        end do
    end function j_color_node

    ! ------------------------------------------------------------------
    ! Local equivalents of scene_3d's private storage helpers
    ! (identical capacity-doubling semantics; see the module header).
    ! ------------------------------------------------------------------

    subroutine j_append_object(sc, obj)
        type(Scene), intent(inout) :: sc
        type(SceneObject), intent(in) :: obj
        type(SceneObject), allocatable :: tmp(:)
        integer :: new_cap
        if (sc%n_objects >= sc%cap_objects) then
            new_cap = max(8, 2 * sc%cap_objects)
            allocate(tmp(new_cap))
            if (sc%n_objects > 0) &
                tmp(1:sc%n_objects) = sc%objects(1:sc%n_objects)
            if (allocated(sc%objects)) deallocate(sc%objects)
            call move_alloc(tmp, sc%objects)
            sc%cap_objects = new_cap
        end if
        sc%n_objects = sc%n_objects + 1
        sc%objects(sc%n_objects) = obj
    end subroutine j_append_object

    subroutine j_append_anim(sc, anim)
        type(Scene), intent(inout) :: sc
        type(SceneAnim), intent(in) :: anim
        type(SceneAnim), allocatable :: tmp(:)
        integer :: new_cap
        if (sc%n_anims >= sc%cap_anims) then
            new_cap = max(8, 2 * sc%cap_anims)
            allocate(tmp(new_cap))
            if (sc%n_anims > 0) &
                tmp(1:sc%n_anims) = sc%anims(1:sc%n_anims)
            if (allocated(sc%anims)) deallocate(sc%anims)
            call move_alloc(tmp, sc%anims)
            sc%cap_anims = new_cap
        end if
        sc%n_anims = sc%n_anims + 1
        sc%anims(sc%n_anims) = anim
    end subroutine j_append_anim

    subroutine j_append_sprite(sc, sp)
        type(Scene), intent(inout) :: sc
        type(SceneSprite), intent(in) :: sp
        type(SceneSprite), allocatable :: tmp(:)
        integer :: new_cap
        if (sc%n_sprites >= sc%cap_sprites) then
            new_cap = max(8, 2 * sc%cap_sprites)
            allocate(tmp(new_cap))
            if (sc%n_sprites > 0) &
                tmp(1:sc%n_sprites) = sc%sprites(1:sc%n_sprites)
            if (allocated(sc%sprites)) deallocate(sc%sprites)
            call move_alloc(tmp, sc%sprites)
            sc%cap_sprites = new_cap
        end if
        sc%n_sprites = sc%n_sprites + 1
        sc%sprites(sc%n_sprites) = sp
    end subroutine j_append_sprite

    subroutine j_append_text(sc, tx)
        type(Scene), intent(inout) :: sc
        type(SceneText), intent(in) :: tx
        type(SceneText), allocatable :: tmp(:)
        integer :: new_cap
        if (sc%n_texts >= sc%cap_texts) then
            new_cap = max(8, 2 * sc%cap_texts)
            allocate(tmp(new_cap))
            if (sc%n_texts > 0) &
                tmp(1:sc%n_texts) = sc%texts(1:sc%n_texts)
            if (allocated(sc%texts)) deallocate(sc%texts)
            call move_alloc(tmp, sc%texts)
            sc%cap_texts = new_cap
        end if
        sc%n_texts = sc%n_texts + 1
        sc%texts(sc%n_texts) = tx
    end subroutine j_append_text

    subroutine j_append_parts(sc, pa)
        type(Scene), intent(inout) :: sc
        type(SceneParticles), intent(in) :: pa
        type(SceneParticles), allocatable :: tmp(:)
        integer :: new_cap
        if (sc%n_parts >= sc%cap_parts) then
            new_cap = max(8, 2 * sc%cap_parts)
            allocate(tmp(new_cap))
            if (sc%n_parts > 0) &
                tmp(1:sc%n_parts) = sc%parts(1:sc%n_parts)
            if (allocated(sc%parts)) deallocate(sc%parts)
            call move_alloc(tmp, sc%parts)
            sc%cap_parts = new_cap
        end if
        sc%n_parts = sc%n_parts + 1
        sc%parts(sc%n_parts) = pa
    end subroutine j_append_parts

    subroutine j_append_track(sc, tr)
        type(Scene), intent(inout) :: sc
        type(KeyTrack), intent(in) :: tr
        type(KeyTrack), allocatable :: tmp(:)
        integer :: new_cap
        if (sc%n_tracks >= sc%cap_tracks) then
            new_cap = max(8, 2 * sc%cap_tracks)
            allocate(tmp(new_cap))
            if (sc%n_tracks > 0) &
                tmp(1:sc%n_tracks) = sc%tracks(1:sc%n_tracks)
            if (allocated(sc%tracks)) deallocate(sc%tracks)
            call move_alloc(tmp, sc%tracks)
            sc%cap_tracks = new_cap
        end if
        sc%n_tracks = sc%n_tracks + 1
        sc%tracks(sc%n_tracks) = tr
    end subroutine j_append_track

    subroutine j_append_key(track, kf, n_keys)
        type(KeyTrack), intent(inout) :: track
        type(KeyFrame), intent(in) :: kf
        integer, intent(inout) :: n_keys
        type(KeyFrame), allocatable :: tmp(:)
        integer :: cap, new_cap
        cap = 0
        if (allocated(track%keys)) cap = size(track%keys)
        if (n_keys >= cap) then
            new_cap = max(4, 2 * cap)
            allocate(tmp(new_cap))
            if (n_keys > 0) tmp(1:n_keys) = track%keys(1:n_keys)
            if (allocated(track%keys)) deallocate(track%keys)
            call move_alloc(tmp, track%keys)
        end if
        n_keys = n_keys + 1
        track%keys(n_keys) = kf
    end subroutine j_append_key

    subroutine j_trim_key_track(track, n_keys)
        type(KeyTrack), intent(inout) :: track
        integer, intent(in) :: n_keys
        type(KeyFrame), allocatable :: tmp(:)
        if (.not. allocated(track%keys)) return
        if (n_keys <= 0) then
            deallocate(track%keys)
            return
        end if
        if (size(track%keys) == n_keys) return
        allocate(tmp(n_keys))
        tmp(1:n_keys) = track%keys(1:n_keys)
        call move_alloc(tmp, track%keys)
    end subroutine j_trim_key_track

    ! Mirror of scene.f90's scene_trim_storage.
    subroutine j_trim_storage(sc)
        type(Scene), intent(inout) :: sc
        type(SceneObject), allocatable :: tmp_obj(:)
        type(SceneAnim), allocatable :: tmp_anim(:)
        type(SceneSprite), allocatable :: tmp_spr(:)
        type(SceneText), allocatable :: tmp_txt(:)
        type(SceneParticles), allocatable :: tmp_prt(:)
        type(KeyTrack), allocatable :: tmp_trk(:)

        if (allocated(sc%objects)) then
            if (sc%n_objects <= 0) then
                deallocate(sc%objects)
            else if (size(sc%objects) /= sc%n_objects) then
                allocate(tmp_obj(sc%n_objects))
                tmp_obj = sc%objects(1:sc%n_objects)
                call move_alloc(tmp_obj, sc%objects)
            end if
        end if
        sc%cap_objects = sc%n_objects
        if (allocated(sc%anims)) then
            if (sc%n_anims <= 0) then
                deallocate(sc%anims)
            else if (size(sc%anims) /= sc%n_anims) then
                allocate(tmp_anim(sc%n_anims))
                tmp_anim = sc%anims(1:sc%n_anims)
                call move_alloc(tmp_anim, sc%anims)
            end if
        end if
        sc%cap_anims = sc%n_anims
        if (allocated(sc%sprites)) then
            if (sc%n_sprites <= 0) then
                deallocate(sc%sprites)
            else if (size(sc%sprites) /= sc%n_sprites) then
                allocate(tmp_spr(sc%n_sprites))
                tmp_spr = sc%sprites(1:sc%n_sprites)
                call move_alloc(tmp_spr, sc%sprites)
            end if
        end if
        sc%cap_sprites = sc%n_sprites
        if (allocated(sc%texts)) then
            if (sc%n_texts <= 0) then
                deallocate(sc%texts)
            else if (size(sc%texts) /= sc%n_texts) then
                allocate(tmp_txt(sc%n_texts))
                tmp_txt = sc%texts(1:sc%n_texts)
                call move_alloc(tmp_txt, sc%texts)
            end if
        end if
        sc%cap_texts = sc%n_texts
        if (allocated(sc%parts)) then
            if (sc%n_parts <= 0) then
                deallocate(sc%parts)
            else if (size(sc%parts) /= sc%n_parts) then
                allocate(tmp_prt(sc%n_parts))
                tmp_prt = sc%parts(1:sc%n_parts)
                call move_alloc(tmp_prt, sc%parts)
            end if
        end if
        sc%cap_parts = sc%n_parts
        if (allocated(sc%tracks)) then
            if (sc%n_tracks <= 0) then
                deallocate(sc%tracks)
            else if (size(sc%tracks) /= sc%n_tracks) then
                allocate(tmp_trk(sc%n_tracks))
                tmp_trk = sc%tracks(1:sc%n_tracks)
                call move_alloc(tmp_trk, sc%tracks)
            end if
        end if
        sc%cap_tracks = sc%n_tracks
    end subroutine j_trim_storage

    ! Mirror of scene.f90's set_object_material (private there).
    subroutine j_set_material(obj)
        type(SceneObject), intent(inout) :: obj
        real(dp) :: rgb(3)
        logical :: use_tri
        integer :: i, mid
        if (obj%color(1) == -1) then
            use_tri = .true.
            rgb = [1.0_dp, 1.0_dp, 1.0_dp]
        else
            use_tri = .false.
            rgb = [real(obj%color(1), dp) / 255.0_dp, &
                   real(obj%color(2), dp) / 255.0_dp, &
                   real(obj%color(3), dp) / 255.0_dp]
        end if
        obj%mat = material_from_name(trim(obj%mat_name), rgb, use_tri)
        if (trim(obj%mat_name) == 'standard') obj%mat%name = 'standard'
        obj%pbr = pbr_from_material(obj%mat, 0.0_dp, 1.0_dp)
        mid = material_id_from_name(trim(obj%mat_name))
        if (allocated(obj%mesh%triangles)) then
            do i = 1, obj%mesh%num_triangles
                obj%mesh%triangles(i)%material_id = mid
            end do
        end if
    end subroutine j_set_material

    ! ------------------------------------------------------------------
    ! Frame count: the JSON stores no frame count, so re-derive it
    ! with the emitter's own rule (f3dc_emit_fortran frame_count):
    ! 1 for a still (no animations, or a "still" output), else
    ! max(1, max over animations of round(duration * fps)).
    ! ------------------------------------------------------------------
    function j_frame_count(doc, root) result(frames)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: root
        integer :: frames
        integer :: anims, anim, outs, outp, child, i, n
        logical :: found, is_still
        real(dp) :: dur, fps
        frames = 1
        call j_get(doc, root, 'animations', anims, found)
        if (.not. found) return
        if (json_kind(doc, anims) /= JK_ARR) return
        if (json_arr_len(doc, anims) == 0) return
        is_still = .false.
        call j_get(doc, root, 'outputs', outs, found)
        if (found .and. json_kind(doc, outs) == JK_ARR) then
            n = json_arr_len(doc, outs)
            do i = 1, n
                call json_arr_at(doc, outs, i, outp)
                if (j_lower(trim(j_str_field(doc, outp, 'kind'))) &
                    == 'still') is_still = .true.
                if (j_lower(trim(j_str_field(doc, outp, 'format'))) &
                    == 'still') is_still = .true.
                if (j_lower(trim(j_str_field(doc, outp, 'mode'))) &
                    == 'still') is_still = .true.
                call j_get(doc, outp, 'still', child, found)
                if (found .and. json_kind(doc, child) == JK_BOOL) then
                    if (json_bool(doc, child, .false.)) is_still = .true.
                end if
            end do
        end if
        if (is_still) return
        n = json_arr_len(doc, anims)
        do i = 1, n
            call json_arr_at(doc, anims, i, anim)
            dur = j_num_field(doc, anim, 'duration', 5.0_dp)
            fps = j_num_field(doc, anim, 'fps', 30.0_dp)
            frames = max(frames, nint(dur * fps))
        end do
        frames = max(1, frames)
    end function j_frame_count

    ! Output path: the first "render" output's path (the emitter's
    ! render_output / output_path rule), else the first output's,
    ! else the v1 default.
    function j_output_path(doc, root) result(p)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: root
        character(len=256) :: p
        integer :: outs, outp, i, n
        logical :: found
        character(len=512) :: cand
        p = 'output_render.ppm'
        call j_get(doc, root, 'outputs', outs, found)
        if (.not. found) return
        if (json_kind(doc, outs) /= JK_ARR) return
        n = json_arr_len(doc, outs)
        do i = 1, n
            call json_arr_at(doc, outs, i, outp)
            if (j_lower(trim(j_str_field(doc, outp, 'kind'))) &
                /= 'render') cycle
            cand = j_str_field(doc, outp, 'path')
            if (len_trim(cand) > 0) then
                p = trim(cand)
                return
            end if
        end do
        do i = 1, n
            call json_arr_at(doc, outs, i, outp)
            cand = j_str_field(doc, outp, 'path')
            if (len_trim(cand) > 0) then
                p = trim(cand)
                return
            end if
        end do
    end function j_output_path

    ! ------------------------------------------------------------------
    ! One explicit triangle (prim "tris"): two emitter shapes exist.
    !   array form: [ [r,g,b], [[x,y,z],[x,y,z],[x,y,z]] ]
    !   dict form:  { "color": [r,g,b], "v": [[..],[..],[..]] }
    ! (the dict form is what the .legacy.json sidecar carries; the
    ! reader accepts both so either artifact loads).
    ! ------------------------------------------------------------------
    subroutine j_fill_triangle(doc, tnode, def_color, tri)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: tnode
        integer, intent(in) :: def_color(3)
        type(Triangle), intent(out) :: tri
        integer :: cnode, vnode, vtx, k
        logical :: found
        tri = Triangle()
        tri%color = def_color
        if (json_kind(doc, tnode) == JK_ARR) then
            if (json_arr_len(doc, tnode) >= 1) then
                call json_arr_at(doc, tnode, 1, cnode)
                tri%color = j_color_node(doc, cnode, def_color)
            end if
            if (json_arr_len(doc, tnode) >= 2) then
                call json_arr_at(doc, tnode, 2, vnode)
                if (json_kind(doc, vnode) == JK_ARR) then
                    do k = 1, min(3, json_arr_len(doc, vnode))
                        call json_arr_at(doc, vnode, k, vtx)
                        tri%v(k) = j_vec3_node(doc, vtx, 3)
                    end do
                end if
            end if
        else if (json_kind(doc, tnode) == JK_OBJ) then
            block
                integer :: alt(3)
                logical :: has_c
                tri%color = j_color_field(doc, tnode, 'color', &
                                          def_color)
                call j_get(doc, tnode, 'color', cnode, has_c)
                if (.not. has_c) then
                    alt = j_color_field(doc, tnode, 'colour', &
                                        def_color)
                    tri%color = alt
                end if
            end block
            vnode = 0
            call j_get(doc, tnode, 'v', vnode, found)
            if (.not. found) call j_get(doc, tnode, 'verts', vnode, &
                                         found)
            if (.not. found) call j_get(doc, tnode, 'vertices', &
                                         vnode, found)
            if (.not. found) call j_get(doc, tnode, 'points', vnode, &
                                         found)
            if (found .and. json_kind(doc, vnode) == JK_ARR) then
                do k = 1, min(3, json_arr_len(doc, vnode))
                    call json_arr_at(doc, vnode, k, vtx)
                    tri%v(k) = j_vec3_node(doc, vtx, 3)
                end do
            end if
        end if
        tri%normal = compute_triangle_normal(tri%v(1), tri%v(2), &
                                             tri%v(3))
        tri%vn = [tri%normal, tri%normal, tri%normal]
    end subroutine j_fill_triangle

    ! Point list for tube/lathe/extrude from an array-of-points node.
    subroutine j_fill_points(doc, pnode, ncomp, obj)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: pnode
        integer, intent(in) :: ncomp
        type(SceneObject), intent(inout) :: obj
        integer :: pt, k, n
        if (pnode <= 0) return
        if (json_kind(doc, pnode) /= JK_ARR) return
        n = json_arr_len(doc, pnode)
        if (n <= 0) return
        if (allocated(obj%pts)) deallocate(obj%pts)
        allocate(obj%pts(n))
        obj%n_pts = n
        do k = 1, n
            call json_arr_at(doc, pnode, k, pt)
            obj%pts(k) = j_vec3_node(doc, pt, ncomp)
        end do
    end subroutine j_fill_points

    ! ------------------------------------------------------------------
    ! The loader
    ! ------------------------------------------------------------------
    subroutine scene_load_json(path, sc, ok, errmsg)
        character(len=*), intent(in) :: path
        type(Scene), intent(inout) :: sc
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg

        type(json_doc) :: doc
        character(len=:), allocatable :: text
        integer :: root, child, node, arr, i, n
        logical :: found
        character(len=512) :: scene_dir, sval
        ! Scene-level values
        type(vec3) :: cam_pos, cam_tgt, cam_up
        real(dp) :: aspect, fov, nearp, farp
        ! Lights collected on the side (point/spot), like scene_load.
        type(Light3), allocatable :: extra(:)
        integer :: n_extra, cap_extra
        type(Light3) :: lt
        ! Keyframe key counts while loading (trimmed at the end).
        integer :: key_counts(4096)
        ! Wave E pending lists (resolved after the read, as in v1).
        character(len=64) :: bind_obj(256), bind_shader(256)
        integer :: n_binds
        character(len=64) :: morph_obj(256), morph_kind(256)
        real(dp) :: morph_factor(256)
        integer :: n_morphs
        character(len=64) :: skin_obj(256), skin_bone(256)
        integer :: n_skins

        ok = .false.
        errmsg = ''
        n_extra = 0
        cap_extra = 0
        key_counts = 0
        n_binds = 0
        n_morphs = 0
        n_skins = 0
        scene_dir = j_dir_of(path)

        call j_read_file(path, text, ok, errmsg)
        if (.not. ok) return
        call json_parse(text, doc, ok, errmsg)
        deallocate(text)
        if (.not. ok) then
            errmsg = 'scene_load_json: JSON parse failed in ' // &
                     trim(path) // ': ' // trim(errmsg)
            return
        end if
        root = doc%root
        if (root <= 0 .or. json_kind(doc, root) /= JK_OBJ) then
            errmsg = 'scene_load_json: root is not a JSON object: ' &
                     // trim(path)
            ok = .false.
            call json_free(doc)
            return
        end if

        ! ---- format / version gate (ADR-3) ----
        sval = j_str_field(doc, root, 'format')
        if (trim(sval) /= 'forge3d-scene') then
            errmsg = 'scene_load_json: not a forge3d-scene file ' // &
                     '(format="' // trim(sval) // '"): ' // trim(path)
            ok = .false.
            call json_free(doc)
            return
        end if
        block
            integer :: ver
            logical :: has_ver
            ver = j_int_field(doc, root, 'ir_version', -1, has_ver)
            if (.not. has_ver) then
                errmsg = 'scene_load_json: missing ir_version: ' &
                         // trim(path)
                ok = .false.
                call json_free(doc)
                return
            end if
            if (ver /= 1) then
                write(sval, '(I0)') ver
                errmsg = 'scene_load_json: unsupported ir_version ' &
                         // trim(sval) // ' (this reader accepts 1): ' &
                         // trim(path)
                ok = .false.
                call json_free(doc)
                return
            end if
        end block

        ! ---- reset to format defaults (mirrors scene_load) ----
        call scene_free(sc)
        sc = Scene()
        cam_pos = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
        cam_tgt = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        cam_up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        aspect = real(sc%width, dp) / real(sc%height, dp)
        call camera_init(sc%cam, cam_pos, cam_tgt, 60.0_dp, aspect, &
                         0.1_dp, 100.0_dp)

        ! ---- size / bg ----
        sc%width = j_int_field(doc, root, 'width', sc%width)
        sc%height = j_int_field(doc, root, 'height', sc%height)
        sc%bg = j_color_field(doc, root, 'bg', sc%bg)

        ! ---- camera ----
        call j_get(doc, root, 'camera', node, found)
        if (found .and. json_kind(doc, node) == JK_OBJ) then
            cam_pos = j_vec3_field(doc, node, 'pos', cam_pos)
            if (.not. j_has_str(doc, node, 'pos')) &
                cam_pos = j_vec3_field(doc, node, 'position', cam_pos)
            cam_tgt = j_vec3_field(doc, node, 'target', cam_tgt)
            cam_up = j_vec3_field(doc, node, 'up', cam_up)
            fov = j_num_field(doc, node, 'fov', 60.0_dp)
            nearp = j_num_field(doc, node, 'near', 0.1_dp)
            farp = j_num_field(doc, node, 'far', 100.0_dp)
            if (sc%height > 0) then
                aspect = real(sc%width, dp) / real(sc%height, dp)
            else
                aspect = 1.0_dp
            end if
            call camera_init(sc%cam, cam_pos, cam_tgt, fov, aspect, &
                             nearp, farp)
            sc%cam%up = cam_up
            call camera_update_matrices(sc%cam)
        end if

        ! ---- lights ----
        call j_get(doc, root, 'lights', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                sval = j_lower(trim(j_str_field(doc, node, 'kind')))
                select case (trim(sval))
                case ('ambient')
                    sc%ambient = j_num_field(doc, node, 'intensity', &
                                             sc%ambient)
                case ('directional')
                    sc%light_dir = j_vec3_field(doc, node, &
                        'direction', sc%light_dir)
                    sc%light_color = j_color_field(doc, node, &
                        'color', sc%light_color)
                    sc%light_intensity = j_num_field(doc, node, &
                        'intensity', sc%light_intensity)
                    sc%has_dir_light = .true.
                case ('point', 'spot')
                    lt = Light3()
                    if (trim(sval) == 'point') then
                        lt%kind = 1
                    else
                        lt%kind = 2
                    end if
                    ! Position: an explicit position/at key wins;
                    ! otherwise the IR serialiser has folded the
                    ! position into "direction" (see module header).
                    lt%pos = j_vec3_field(doc, node, 'direction', &
                        vec3_create(0.0_dp, 0.0_dp, 0.0_dp))
                    block
                        integer :: pnode
                        logical :: pfound
                        call j_get(doc, node, 'position', pnode, &
                                   pfound)
                        if (.not. pfound) &
                            call j_get(doc, node, 'at', pnode, pfound)
                        if (pfound .and. &
                            json_kind(doc, pnode) == JK_ARR) &
                            lt%pos = j_vec3_node(doc, pnode, 3)
                    end block
                    lt%dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
                    lt%spot_dir = lt%dir
                    if (lt%kind == 2) then
                        ! Spot direction: target/look when present,
                        ! else an explicit dir key (only meaningful
                        ! alongside a separate position key), else
                        ! the (0,-1,0) default -- the current JSON
                        ! does not carry the spot target at all.
                        block
                            type(vec3) :: tgt
                            logical :: has_tgt, has_pos
                            has_tgt = .false.
                            tgt = j_vec3_field(doc, node, 'target', &
                                               lt%pos)
                            call j_get(doc, node, 'target', child, &
                                       has_tgt)
                            if (.not. has_tgt) &
                                call j_get(doc, node, 'look', child, &
                                           has_tgt)
                            if (has_tgt) then
                                tgt = j_vec3_field(doc, node, 'look', &
                                                   tgt)
                                if (vec3_norm(vec3_sub(tgt, lt%pos)) &
                                    > 0.0_dp) then
                                    lt%spot_dir = vec3_normalize( &
                                        vec3_sub(tgt, lt%pos))
                                    lt%dir = lt%spot_dir
                                end if
                            else
                                call j_get(doc, node, 'position', &
                                           child, has_pos)
                                if (has_pos) then
                                    lt%spot_dir = j_vec3_field( &
                                        doc, node, 'direction', &
                                        lt%spot_dir)
                                    lt%dir = lt%spot_dir
                                end if
                            end if
                        end block
                    end if
                    lt%color = j_color_field(doc, node, 'color', &
                                             lt%color)
                    lt%intensity = j_num_field(doc, node, &
                        'intensity', lt%intensity)
                    lt%distance = j_num_field(doc, node, 'distance', &
                                              0.0_dp)
                    lt%decay = j_num_field(doc, node, 'decay', 2.0_dp)
                    lt%angle_deg = j_num_field(doc, node, 'angle', &
                                               45.0_dp)
                    lt%penumbra = j_num_field(doc, node, 'penumbra', &
                                              0.0_dp)
                    if (n_extra >= cap_extra) then
                        block
                            type(Light3), allocatable :: tmp(:)
                            integer :: new_cap
                            new_cap = max(8, 2 * cap_extra)
                            allocate(tmp(new_cap))
                            if (n_extra > 0) &
                                tmp(1:n_extra) = extra(1:n_extra)
                            if (allocated(extra)) deallocate(extra)
                            call move_alloc(tmp, extra)
                            cap_extra = new_cap
                        end block
                    end if
                    n_extra = n_extra + 1
                    extra(n_extra) = lt
                    sc%has_env = .true.
                case default
                    print *, 'scene_json: warning: unknown light ', &
                        'kind "', trim(sval), '": skipped'
                end select
            end do
        end if

        ! ---- frames / output (derived; see j_frame_count) ----
        sc%frames = j_frame_count(doc, root)
        sc%output_file = j_output_path(doc, root)

        ! ---- objects ----
        call j_get(doc, root, 'objects', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                call j_load_object(doc, node, scene_dir, sc)
            end do
        end if

        ! ---- animations ----
        call j_get(doc, root, 'animations', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                block
                    type(SceneAnim) :: anim
                    anim = SceneAnim()
                    anim%kind = j_lower(trim(j_str_field(doc, node, &
                                                         'kind')))
                    if (len_trim(anim%kind) == 0) anim%kind = 'spin'
                    anim%target = trim(j_str_field(doc, node, &
                                                   'target'))
                    if (len_trim(anim%target) == 0) anim%target = 'all'
                    anim%axis = j_lower(trim(j_str_field(doc, node, &
                                                         'axis')))
                    if (len_trim(anim%axis) == 0) anim%axis = 'y'
                    anim%speed = j_num_field(doc, node, 'speed', &
                                             90.0_dp)
                    anim%duration = j_num_field(doc, node, &
                        'duration', 5.0_dp)
                    anim%fps = j_int_field(doc, node, 'fps', 30)
                    anim%ease = j_lower(trim(j_str_field(doc, node, &
                                                         'ease')))
                    if (len_trim(anim%ease) == 0) anim%ease = 'linear'
                    anim%loop = j_lower(trim(j_str_field(doc, node, &
                                                         'loop')))
                    if (len_trim(anim%loop) == 0) anim%loop = 'forever'
                    call j_append_anim(sc, anim)
                end block
            end do
        end if

        ! ---- extensions: env / waveb / wavec / wavee ----
        call j_get(doc, root, 'extensions', node, found)
        if (found .and. json_kind(doc, node) == JK_OBJ) then
            call j_load_env(doc, node, sc)
            call j_load_waveb(doc, node, sc, key_counts)
            call j_load_wavec(doc, node, sc)
            call j_load_wavee(doc, node, sc, bind_obj, bind_shader, &
                              n_binds, morph_obj, morph_kind, &
                              morph_factor, n_morphs, skin_obj, &
                              skin_bone, n_skins)
        end if

        ! Wave E resolution (binds/morphs/skins), mirroring v1.
        call j_resolve_wavee(sc, bind_obj, bind_shader, n_binds, &
                             morph_obj, morph_kind, morph_factor, &
                             n_morphs, skin_obj, skin_bone, n_skins)

        ! ---- trim storage, assemble LightSet (mirrors scene_load) --
        if (allocated(sc%tracks)) then
            do i = 1, sc%n_tracks
                if (i <= 4096) call j_trim_key_track(sc%tracks(i), &
                                                     key_counts(i))
            end do
        end if
        call j_trim_storage(sc)

        if (allocated(sc%lights%items)) deallocate(sc%lights%items)
        allocate(sc%lights%items(1 + n_extra))
        lt = Light3()
        lt%kind = 0
        lt%dir = sc%light_dir
        lt%spot_dir = sc%light_dir
        lt%pos = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        lt%color = sc%light_color
        lt%intensity = sc%light_intensity
        sc%lights%items(1) = lt
        do i = 1, n_extra
            sc%lights%items(1 + i) = extra(i)
        end do
        if (allocated(extra)) deallocate(extra)
        sc%lights%ambient = sc%ambient
        sc%lights%ambient_color = [255, 255, 255]
        if (allocated(sc%objects)) then
            do i = 1, sc%n_objects
                if (sc%objects(i)%tex%loaded .or. &
                    trim(sc%objects(i)%mat_name) == 'standard') &
                    sc%has_env = .true.
            end do
        end if
        if (allocated(sc%objects)) then
            do i = 1, sc%n_objects
                if (trim(sc%objects(i)%prim) == 'tris') &
                    call j_set_material(sc%objects(i))
            end do
        end if

        call json_free(doc)
        ok = .true.
        errmsg = ''
    end subroutine scene_load_json

    ! ------------------------------------------------------------------
    ! One object entry.
    ! ------------------------------------------------------------------
    subroutine j_load_object(doc, node, scene_dir, sc)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: scene_dir
        type(Scene), intent(inout) :: sc
        type(SceneObject) :: obj
        integer :: child, sub, tnode, i, n
        logical :: found, has_size
        character(len=512) :: sval

        obj = SceneObject()
        obj%prim = j_lower(trim(j_str_field(doc, node, 'prim')))
        if (len_trim(obj%prim) == 0) then
            sval = j_str_field(doc, node, 'primitive')
            obj%prim = j_lower(trim(sval))
        end if
        if (len_trim(obj%prim) == 0) obj%prim = 'cube'
        obj%name = trim(j_str_field(doc, node, 'name'))
        if (len_trim(obj%name) == 0) obj%name = 'object'
        obj%mat_name = j_lower(trim(j_str_field(doc, node, &
                                                'material')))
        if (len_trim(obj%mat_name) == 0) obj%mat_name = 'lambert'
        obj%pos = j_vec3_field(doc, node, 'pos', obj%pos)
        obj%rot_deg = j_vec3_field(doc, node, 'rotate', obj%rot_deg)
        obj%scl = j_vec3_field(doc, node, 'scale', obj%scl)

        if (trim(obj%prim) == 'tris') then
            ! v1 'tris' objects keep the palette sentinel colour;
            ! per-triangle colours live in the triangles themselves.
            obj%color = [-1, -1, -1]
            call j_get(doc, node, 'source_file', child, found)
            if (found .and. json_kind(doc, child) == JK_STR) &
                obj%source_path = trim(j_str_field(doc, node, &
                                                   'source_file'))
            call j_get(doc, node, 'triangles', tnode, found)
            n = 0
            if (found .and. json_kind(doc, tnode) == JK_ARR) &
                n = json_arr_len(doc, tnode)
            obj%mesh%num_triangles = n
            allocate(obj%mesh%triangles(max(1, n)))
            do i = 1, n
                call json_arr_at(doc, tnode, i, sub)
                call j_fill_triangle(doc, sub, [255, 255, 255], &
                                     obj%mesh%triangles(i))
            end do
            obj%tri_filled = n
            call j_append_object(sc, obj)
            call free_mesh(obj%mesh)
            if (allocated(obj%pts)) deallocate(obj%pts)
            return
        end if

        ! Colour: absent/null keeps the SceneObject default
        ! [-1,-1,-1] palette sentinel, exactly as a colour-less
        ! .scene object line behaves in the v1 reader.
        obj%color = j_color_field(doc, node, 'color', obj%color)

        ! Dimensions: null means "missing" in this format, exactly
        ! the -1 / 0 sentinels of the .scene text.
        obj%dim_size = j_num_field(doc, node, 'size', -1.0_dp, &
                                   has_size)
        if (.not. has_size) then
            ! size3 fallback, mirroring the emitter's scalar_of
            ! chain (first element when it is a list).
            call j_get(doc, node, 'size3', child, found)
            if (found) then
                if (json_kind(doc, child) == JK_NUM) then
                    obj%dim_size = json_num(doc, child, -1.0_dp)
                else if (json_kind(doc, child) == JK_ARR .and. &
                         json_arr_len(doc, child) >= 1) then
                    call json_arr_at(doc, child, 1, sub)
                    obj%dim_size = json_num(doc, sub, -1.0_dp)
                end if
            end if
        end if
        obj%dim_radius = j_num_field(doc, node, 'radius', -1.0_dp)
        obj%dim_height = j_num_field(doc, node, 'height', -1.0_dp)
        obj%segments = j_int_field(doc, node, 'segments', 0)

        sval = j_str_field(doc, node, 'shading')
        if (len_trim(sval) > 0) obj%shading = j_lower(trim(sval))
        sval = j_str_field(doc, node, 'mirror')
        select case (j_lower(trim(sval)))
        case ('x')
            obj%mirror = 1
        case ('y')
            obj%mirror = 2
        case ('z')
            obj%mirror = 3
        end select

        ! Geometry point lists (tube/lathe/extrude): the canonical
        ! home is extensions.geometry.{path|points|shape}; the v1
        ! fallback (extensions.<key> directly) is honoured too.
        block
            integer :: ext, geom, pnode
            logical :: ef, gf, pf
            character(len=8) :: key
            integer :: ncomp
            pnode = 0
            pf = .false.
            select case (trim(obj%prim))
            case ('tube')
                key = 'path'
                ncomp = 3
            case ('lathe')
                key = 'points'
                ncomp = 2
            case ('extrude')
                key = 'shape'
                ncomp = 2
            case default
                key = ''
                ncomp = 0
            end select
            if (ncomp > 0) then
                call j_get(doc, node, 'extensions', ext, ef)
                if (ef .and. json_kind(doc, ext) == JK_OBJ) then
                    call j_get(doc, ext, 'geometry', geom, gf)
                    if (gf .and. json_kind(doc, geom) == JK_OBJ) &
                        call j_get(doc, geom, trim(key), pnode, pf)
                    if (.not. pf) &
                        call j_get(doc, ext, trim(key), pnode, pf)
                end if
                if (pf) call j_fill_points(doc, pnode, ncomp, obj)
            end if
        end block

        if (trim(obj%prim) == 'load') then
            sval = j_str_field(doc, node, 'source_file')
            if (len_trim(sval) == 0) sval = j_str_field(doc, node, &
                                                        'path')
            if (len_trim(sval) == 0) sval = j_str_field(doc, node, &
                                                        'file')
            if (len_trim(sval) == 0) sval = 'model.obj'
            obj%source_path = j_resolve_path(scene_dir, trim(sval))
        end if

        call scene_build_object_mesh(obj)

        ! Per-object PBR / texture (the .scene 'objmat' line's data
        ! lives in extensions.material in the JSON).
        block
            integer :: ext, mat
            logical :: ef, mf, tex_ok
            call j_get(doc, node, 'extensions', ext, ef)
            if (ef .and. json_kind(doc, ext) == JK_OBJ) then
                call j_get(doc, ext, 'material', mat, mf)
                if (mf .and. json_kind(doc, mat) == JK_OBJ) then
                    associate (o => obj)
                        o%pbr%metalness = j_num_field(doc, mat, &
                            'metalness', 0.0_dp)
                        o%pbr%roughness = j_num_field(doc, mat, &
                            'roughness', 1.0_dp)
                        o%pbr%specular = j_num_field(doc, mat, &
                            'specular', 0.5_dp)
                        o%pbr%shininess = j_num_field(doc, mat, &
                            'shininess', 32.0_dp)
                        if (trim(o%mat_name) == 'standard') &
                            o%pbr%mode = MAT_STANDARD
                        sval = j_str_field(doc, mat, 'texture')
                        if (len_trim(sval) > 0) then
                            o%texture_path = j_resolve_path( &
                                scene_dir, trim(sval))
                            call texture_load_ppm( &
                                trim(o%texture_path), o%tex, tex_ok)
                            if (.not. tex_ok) print *, &
                                'scene_json: warning: cannot load ', &
                                'texture ', trim(o%texture_path)
                        end if
                    end associate
                    sc%has_env = .true.
                end if
            end if
        end block

        call j_append_object(sc, obj)
        call free_mesh(obj%mesh)
        if (allocated(obj%pts)) deallocate(obj%pts)
    end subroutine j_load_object

    ! ------------------------------------------------------------------
    ! extensions.env: fog / tonemap / shadow (mirrors the v1 lines).
    ! ------------------------------------------------------------------
    subroutine j_load_env(doc, exts, sc)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: exts
        type(Scene), intent(inout) :: sc
        integer :: env, sub
        logical :: found
        character(len=512) :: sval
        call j_get(doc, exts, 'env', env, found)
        if (.not. found) return
        if (json_kind(doc, env) /= JK_OBJ) return

        call j_get(doc, env, 'fog', sub, found)
        if (found .and. json_kind(doc, sub) == JK_OBJ) then
            sval = j_lower(trim(j_str_field(doc, sub, 'mode')))
            select case (trim(sval))
            case ('linear')
                sc%fog_mode = 1
                sc%fog_near = j_num_field(doc, sub, 'near', &
                                          sc%fog_near)
                sc%fog_far = j_num_field(doc, sub, 'far', &
                                         sc%fog_far)
                sc%fog_color = j_color_field(doc, sub, 'color', &
                                             sc%fog_color)
                sc%has_env = .true.
            case ('exp2', 'exp', 'fogexp2')
                sc%fog_mode = 2
                sc%fog_density = j_num_field(doc, sub, 'density', &
                                             sc%fog_density)
                sc%fog_color = j_color_field(doc, sub, 'color', &
                                             sc%fog_color)
                sc%has_env = .true.
            case ('none', 'off', '')
                sc%fog_mode = 0
            case default
                print *, 'scene_json: warning: unknown fog mode "', &
                    trim(sval), '": ignored'
            end select
        end if

        call j_get(doc, env, 'tonemap', sub, found)
        if (found .and. json_kind(doc, sub) == JK_OBJ) then
            sval = j_lower(trim(j_str_field(doc, sub, 'mode')))
            select case (trim(sval))
            case ('reinhard')
                sc%tonemap_mode = 1
            case ('aces', 'acesfilmic', 'aces_filmic')
                sc%tonemap_mode = 2
            case default
                sc%tonemap_mode = 0
            end select
            sc%tonemap_exposure = j_num_field(doc, sub, 'exposure', &
                                              sc%tonemap_exposure)
            if (sc%tonemap_mode /= 0) sc%has_env = .true.
        end if

        call j_get(doc, env, 'shadow', sub, found)
        if (found .and. json_kind(doc, sub) == JK_OBJ) then
            sval = j_lower(trim(j_str_field(doc, sub, 'mode')))
            select case (trim(sval))
            case ('on')
                sc%shadow_mode = 1
            case ('soft')
                sc%shadow_mode = 2
            case default
                sc%shadow_mode = 0
            end select
            sc%shadow_size = j_int_field(doc, sub, 'size', &
                                         sc%shadow_size)
            if (sc%shadow_mode /= 0) sc%has_env = .true.
        end if

        ! v3.0 Phase 2: SSAA factor; the emitter carries the key
        ! only when the .f3d source set `antialias`, so an absent
        ! key keeps the Scene default of 1.
        sc%antialias = j_int_field(doc, env, 'antialias', &
                                   sc%antialias)
    end subroutine j_load_env

    ! ------------------------------------------------------------------
    ! extensions.waveb: sprites / texts / particles / key tracks.
    ! ------------------------------------------------------------------
    subroutine j_load_waveb(doc, exts, sc, key_counts)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: exts
        type(Scene), intent(inout) :: sc
        integer, intent(inout) :: key_counts(:)
        integer :: wb, arr, node, i, n
        logical :: found
        call j_get(doc, exts, 'waveb', wb, found)
        if (.not. found) return
        if (json_kind(doc, wb) /= JK_OBJ) return

        call j_get(doc, wb, 'sprites', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                block
                    type(SceneSprite) :: spr
                    spr = SceneSprite()
                    spr%name = trim(j_str_field(doc, node, 'name'))
                    spr%pos = j_vec3_field(doc, node, 'at', spr%pos)
                    spr%pos = j_vec3_field(doc, node, 'pos', spr%pos)
                    spr%size = j_num_field(doc, node, 'size', &
                                           spr%size)
                    spr%color = j_color_field(doc, node, 'color', &
                                              spr%color)
                    call j_append_sprite(sc, spr)
                end block
            end do
        end if

        call j_get(doc, wb, 'texts', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                block
                    type(SceneText) :: txt
                    character(len=512) :: sval
                    txt = SceneText()
                    txt%name = trim(j_str_field(doc, node, 'name'))
                    txt%pos = j_vec3_field(doc, node, 'at', txt%pos)
                    txt%pos = j_vec3_field(doc, node, 'pos', txt%pos)
                    txt%size = j_num_field(doc, node, 'size', &
                                           txt%size)
                    txt%color = j_color_field(doc, node, 'color', &
                                              txt%color)
                    sval = j_str_field(doc, node, 'content')
                    if (len_trim(sval) == 0) &
                        sval = j_str_field(doc, node, 'text')
                    txt%content = trim(sval)
                    call j_append_text(sc, txt)
                end block
            end do
        end if

        call j_get(doc, wb, 'particles', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                block
                    type(SceneParticles) :: prt
                    prt = SceneParticles()
                    prt%name = trim(j_str_field(doc, node, 'name'))
                    call particle_system_init(prt%sys)
                    prt%sys%origin = j_vec3_field(doc, node, &
                        'origin', prt%sys%origin)
                    prt%sys%origin = j_vec3_field(doc, node, 'at', &
                        prt%sys%origin)
                    prt%sys%origin = j_vec3_field(doc, node, 'pos', &
                        prt%sys%origin)
                    prt%sys%count = j_int_field(doc, node, 'count', &
                                                prt%sys%count)
                    prt%sys%life = j_num_field(doc, node, 'life', &
                                               prt%sys%life)
                    prt%sys%speed = j_num_field(doc, node, 'speed', &
                                                prt%sys%speed)
                    prt%sys%size = j_num_field(doc, node, 'size', &
                                               prt%sys%size)
                    prt%sys%color = j_color_field(doc, node, &
                        'color', prt%sys%color)
                    prt%sys%spread = j_num_field(doc, node, &
                        'spread', prt%sys%spread)
                    prt%sys%gravity = j_num_field(doc, node, &
                        'gravity', prt%sys%gravity)
                    prt%sys%seed = j_int_field(doc, node, 'seed', &
                                               prt%sys%seed)
                    call j_append_parts(sc, prt)
                end block
            end do
        end if

        ! Key tracks: "keys" is an OBJECT keyed by target name, so
        ! enumerate its children (child%s is the target, the child
        ! node itself is the track object).
        block
            integer :: keys_node, tnode, karr, knode, nk, c
            logical :: kfound
            call j_get(doc, wb, 'keys', keys_node, kfound)
            if (kfound .and. json_kind(doc, keys_node) == JK_OBJ) then
                c = doc%nodes(keys_node)%first_child
                do while (c /= 0)
                    tnode = c
                    c = doc%nodes(c)%next_sibling
                    if (json_kind(doc, tnode) /= JK_OBJ) cycle
                    block
                        type(KeyTrack) :: trk
                        type(KeyFrame) :: kf
                        integer :: nkeys, ki
                        trk = KeyTrack()
                        if (allocated(doc%nodes(tnode)%s)) &
                            trk%target = doc%nodes(tnode)%s
                        trk%duration = j_num_field(doc, tnode, &
                            'duration', trk%duration)
                        trk%loop = trim(j_str_field(doc, tnode, &
                                                    'loop'))
                        if (len_trim(trk%loop) == 0) trk%loop = 'once'
                        call j_append_track(sc, trk)
                        if (allocated(trk%keys)) deallocate(trk%keys)
                        nkeys = 0
                        call j_get(doc, tnode, 'keys', karr, kfound)
                        if (kfound .and. &
                            json_kind(doc, karr) == JK_ARR) then
                            nk = json_arr_len(doc, karr)
                            do ki = 1, nk
                                call json_arr_at(doc, karr, ki, &
                                                 knode)
                                if (json_kind(doc, knode) /= &
                                    JK_OBJ) cycle
                                kf = KeyFrame()
                                kf%time = j_num_field(doc, knode, &
                                    'time', kf%time)
                                block
                                    type(vec3) :: pv, rv
                                    pv = j_vec3_field(doc, knode, &
                                        'pos', vec3_create( &
                                            kf%pos(1), kf%pos(2), &
                                            kf%pos(3)))
                                    kf%pos = [pv%x, pv%y, pv%z]
                                    rv = j_vec3_field(doc, knode, &
                                        'rot', vec3_create( &
                                            kf%rot_deg(1), &
                                            kf%rot_deg(2), &
                                            kf%rot_deg(3)))
                                    kf%rot_deg = [rv%x, rv%y, rv%z]
                                end block
                                kf%scale = j_num_field(doc, knode, &
                                    'scale', kf%scale)
                                kf%ease = trim(j_str_field(doc, &
                                    knode, 'ease'))
                                if (len_trim(kf%ease) == 0) &
                                    kf%ease = 'linear'
                                call j_append_key( &
                                    sc%tracks(sc%n_tracks), kf, &
                                    nkeys)
                            end do
                        end if
                        if (sc%n_tracks >= 1 .and. &
                            sc%n_tracks <= size(key_counts)) &
                            key_counts(sc%n_tracks) = nkeys
                    end block
                end do
            end if
        end block
    end subroutine j_load_waveb

    ! ------------------------------------------------------------------
    ! extensions.wavec: ortho camera / post chain / instances.
    ! ------------------------------------------------------------------
    subroutine j_load_wavec(doc, exts, sc)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: exts
        type(Scene), intent(inout) :: sc
        integer :: wc, sub, arr, node, i, n
        logical :: found
        character(len=512) :: sval
        call j_get(doc, exts, 'wavec', wc, found)
        if (.not. found) return
        if (json_kind(doc, wc) /= JK_OBJ) return

        call j_get(doc, wc, 'camera', sub, found)
        if (found .and. json_kind(doc, sub) == JK_OBJ) then
            sval = j_lower(trim(j_str_field(doc, sub, 'type')))
            if (trim(sval) == 'ortho') then
                sc%ortho = .true.
                sc%ortho_size = j_num_field(doc, sub, 'size', &
                                            sc%ortho_size)
            end if
        end if

        call j_get(doc, wc, 'post', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                if (sc%n_post >= 16) cycle
                sc%n_post = sc%n_post + 1
                sc%post_names(sc%n_post) = trim(j_str_field(doc, &
                    node, 'name'))
                sc%post_amounts(sc%n_post) = j_num_field(doc, node, &
                    'amount', 0.0_dp)
            end do
        end if

        call j_get(doc, wc, 'instances', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                block
                    integer :: src_idx, cnode
                    logical :: sfound
                    type(SceneObject) :: iobj
                    real(dp) :: s
                    src_idx = scene_find_object(sc, &
                        trim(j_str_field(doc, node, 'source')))
                    if (src_idx <= 0) then
                        print *, 'scene_json: warning: instance ', &
                            'of unknown object ', &
                            trim(j_str_field(doc, node, 'source')), &
                            ': skipped'
                        cycle
                    end if
                    iobj = sc%objects(src_idx)
                    iobj%name = trim(j_str_field(doc, node, 'name'))
                    iobj%pos = j_vec3_field(doc, node, 'pos', &
                                            iobj%pos)
                    iobj%rot_deg = j_vec3_field(doc, node, 'rot', &
                                                iobj%rot_deg)
                    ! Scale: scalar (uniform, as in v1) or a list
                    ! whose first element v1 uses.
                    s = iobj%scl%x
                    call j_get(doc, node, 'scale', cnode, sfound)
                    if (sfound) then
                        if (json_kind(doc, cnode) == JK_NUM) then
                            s = json_num(doc, cnode, s)
                        else if (json_kind(doc, cnode) == JK_ARR &
                                 .and. json_arr_len(doc, cnode) >= 1) &
                            then
                            block
                                integer :: e0
                                call json_arr_at(doc, cnode, 1, e0)
                                s = json_num(doc, e0, s)
                            end block
                        end if
                        iobj%scl = vec3_create(s, s, s)
                    end if
                    call j_append_object(sc, iobj)
                end block
            end do
        end if
    end subroutine j_load_wavec

    ! ------------------------------------------------------------------
    ! extensions.wavee: shader defs / bones stored on the Scene;
    ! bindings / morphs / skins collected as pending (resolved by
    ! j_resolve_wavee once every object exists, as in v1).
    ! ------------------------------------------------------------------
    subroutine j_load_wavee(doc, exts, sc, bind_obj, bind_shader, &
                            n_binds, morph_obj, morph_kind, &
                            morph_factor, n_morphs, skin_obj, &
                            skin_bone, n_skins)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: exts
        type(Scene), intent(inout) :: sc
        character(len=*), intent(inout) :: bind_obj(:), bind_shader(:)
        integer, intent(inout) :: n_binds
        character(len=*), intent(inout) :: morph_obj(:), &
                                           morph_kind(:)
        real(dp), intent(inout) :: morph_factor(:)
        integer, intent(inout) :: n_morphs
        character(len=*), intent(inout) :: skin_obj(:), skin_bone(:)
        integer, intent(inout) :: n_skins
        integer :: we, arr, node, i, n, k
        logical :: found
        call j_get(doc, exts, 'wavee', we, found)
        if (.not. found) return
        if (json_kind(doc, we) /= JK_OBJ) return

        ! Shader definitions: [{name, rpn: [token, ...]}]
        call j_get(doc, we, 'shaders', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            if (n > 0) then
                if (allocated(sc%shader_defs)) &
                    deallocate(sc%shader_defs)
                allocate(sc%shader_defs(n))
                block
                    integer :: kept, rnode, enode, ntok
                    character(len=64) :: rtoks(512)
                    type(ShaderProg) :: prog
                    logical :: pok
                    character(len=256) :: perr
                    kept = 0
                    do i = 1, n
                        call json_arr_at(doc, arr, i, node)
                        if (json_kind(doc, node) /= JK_OBJ) cycle
                        rtoks = ''
                        ntok = 0
                        call j_get(doc, node, 'rpn', rnode, found)
                        if (found .and. &
                            json_kind(doc, rnode) == JK_ARR) then
                            ntok = min(json_arr_len(doc, rnode), 512)
                            do k = 1, ntok
                                call json_arr_at(doc, rnode, k, enode)
                                rtoks(k) = trim(json_str(doc, enode))
                            end do
                        end if
                        if (ntok <= 0) cycle
                        call shader_parse(rtoks(1:ntok), prog, pok, &
                                          perr)
                        if (.not. pok) then
                            print *, 'scene_json: warning: shader ', &
                                '"', trim(j_str_field(doc, node, &
                                'name')), '" does not parse: ', &
                                trim(perr)
                            cycle
                        end if
                        kept = kept + 1
                        sc%shader_defs(kept)%name = &
                            trim(j_str_field(doc, node, 'name'))
                        sc%shader_defs(kept)%prog = prog
                    end do
                    if (kept < n) then
                        ! Leave spare defs unnamed -- they can never
                        ! match a binding lookup by name.
                        do i = kept + 1, n
                            sc%shader_defs(i)%name = ''
                        end do
                    end if
                end block
            end if
        end if

        ! Bones: [{name, at: [x,y,z], rotate: [x,y,z], radius}]
        call j_get(doc, we, 'bones', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            if (n > 0) then
                if (allocated(sc%bones)) deallocate(sc%bones)
                allocate(sc%bones(n))
                do i = 1, n
                    call json_arr_at(doc, arr, i, node)
                    if (json_kind(doc, node) /= JK_OBJ) cycle
                    sc%bones(i)%name = trim(j_str_field(doc, node, &
                                                        'name'))
                    sc%bones(i)%pivot = j_vec3_field(doc, node, &
                        'at', sc%bones(i)%pivot)
                    sc%bones(i)%pivot = j_vec3_field(doc, node, &
                        'pos', sc%bones(i)%pivot)
                    sc%bones(i)%rot_deg = j_vec3_field(doc, node, &
                        'rotate', sc%bones(i)%rot_deg)
                    sc%bones(i)%rot_deg = j_vec3_field(doc, node, &
                        'rot', sc%bones(i)%rot_deg)
                    sc%bones(i)%radius = j_num_field(doc, node, &
                        'radius', sc%bones(i)%radius)
                end do
            end if
        end if

        ! Bindings: an object {object_name: shader_name}.
        block
            integer :: bnode, c
            logical :: bfound
            call j_get(doc, we, 'bindings', bnode, bfound)
            if (bfound .and. json_kind(doc, bnode) == JK_OBJ) then
                c = doc%nodes(bnode)%first_child
                do while (c /= 0)
                    if (n_binds < size(bind_obj)) then
                        n_binds = n_binds + 1
                        if (allocated(doc%nodes(c)%s)) &
                            bind_obj(n_binds) = doc%nodes(c)%s
                        bind_shader(n_binds) = &
                            trim(json_str(doc, c))
                    end if
                    c = doc%nodes(c)%next_sibling
                end do
            end if
        end block

        ! Morphs: [{target, kind, factor}]
        call j_get(doc, we, 'morphs', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                if (n_morphs >= size(morph_obj)) cycle
                n_morphs = n_morphs + 1
                morph_obj(n_morphs) = trim(j_str_field(doc, node, &
                                                       'target'))
                morph_kind(n_morphs) = trim(j_str_field(doc, node, &
                                                        'kind'))
                morph_factor(n_morphs) = j_num_field(doc, node, &
                    'factor', 0.0_dp)
            end do
        end if

        ! Skins: [{target, bone}]
        call j_get(doc, we, 'skins', arr, found)
        if (found .and. json_kind(doc, arr) == JK_ARR) then
            n = json_arr_len(doc, arr)
            do i = 1, n
                call json_arr_at(doc, arr, i, node)
                if (json_kind(doc, node) /= JK_OBJ) cycle
                if (n_skins >= size(skin_obj)) cycle
                n_skins = n_skins + 1
                skin_obj(n_skins) = trim(j_str_field(doc, node, &
                                                     'target'))
                skin_bone(n_skins) = trim(j_str_field(doc, node, &
                                                      'bone'))
            end do
        end if
    end subroutine j_load_wavee

    subroutine j_resolve_wavee(sc, bind_obj, bind_shader, n_binds, &
                               morph_obj, morph_kind, morph_factor, &
                               n_morphs, skin_obj, skin_bone, n_skins)
        type(Scene), intent(inout) :: sc
        character(len=*), intent(in) :: bind_obj(:), bind_shader(:)
        integer, intent(in) :: n_binds
        character(len=*), intent(in) :: morph_obj(:), morph_kind(:)
        real(dp), intent(in) :: morph_factor(:)
        integer, intent(in) :: n_morphs
        character(len=*), intent(in) :: skin_obj(:), skin_bone(:)
        integer, intent(in) :: n_skins
        integer :: i, j, oi, bi
        type(Mesh) :: new_mesh
        do i = 1, n_binds
            oi = scene_find_object(sc, trim(bind_obj(i)))
            if (oi == 0) then
                print *, 'scene_json: warning: shaderbind for ', &
                    'unknown object ', trim(bind_obj(i))
                cycle
            end if
            bi = 0
            if (allocated(sc%shader_defs)) then
                do j = 1, size(sc%shader_defs)
                    if (trim(sc%shader_defs(j)%name) == &
                        trim(bind_shader(i))) then
                        bi = j
                        exit
                    end if
                end do
            end if
            if (bi == 0) then
                print *, 'scene_json: warning: shaderbind names ', &
                    'unknown shader ', trim(bind_shader(i))
                cycle
            end if
            sc%objects(oi)%has_shader = .true.
            sc%objects(oi)%shader_name = trim(bind_shader(i))
            sc%objects(oi)%shader_prog = sc%shader_defs(bi)%prog
        end do
        do i = 1, n_morphs
            oi = scene_find_object(sc, trim(morph_obj(i)))
            if (oi == 0) then
                print *, 'scene_json: warning: morph for unknown ', &
                    'object ', trim(morph_obj(i))
                cycle
            end if
            call morph_apply(sc%objects(oi)%mesh, &
                             trim(morph_kind(i)), morph_factor(i), &
                             new_mesh)
            call free_mesh(sc%objects(oi)%mesh)
            sc%objects(oi)%mesh = new_mesh
            call free_mesh(new_mesh)
        end do
        do i = 1, n_skins
            oi = scene_find_object(sc, trim(skin_obj(i)))
            if (oi == 0) then
                print *, 'scene_json: warning: skin for unknown ', &
                    'object ', trim(skin_obj(i))
                cycle
            end if
            bi = 0
            if (allocated(sc%bones)) then
                do j = 1, size(sc%bones)
                    if (trim(sc%bones(j)%name) == &
                        trim(skin_bone(i))) then
                        bi = j
                        exit
                    end if
                end do
            end if
            if (bi == 0) then
                print *, 'scene_json: warning: skin names unknown ', &
                    'bone ', trim(skin_bone(i))
                cycle
            end if
            call skin_apply(sc%objects(oi)%mesh, &
                            sc%bones(bi)%pivot, &
                            sc%bones(bi)%rot_deg, &
                            sc%bones(bi)%radius, new_mesh)
            call free_mesh(sc%objects(oi)%mesh)
            sc%objects(oi)%mesh = new_mesh
            call free_mesh(new_mesh)
        end do
    end subroutine j_resolve_wavee

end module scene_json_3d
