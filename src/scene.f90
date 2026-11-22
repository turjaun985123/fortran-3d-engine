! scene.f90 -- Forge3D .scene reader (seat B23, module scene_3d).
!
! Parses exactly the text format emitted by
! tools/f3dc/emit_fortran.py:emit_scene_text:
!   forge3d-scene 1
!   # <header stamp lines start with '#': skipped anywhere>
!   size W H
!   bg R G B
!   camera px py pz tx ty tz ux uy uz fov near far
!   light directional dx dy dz R G B intensity
!   light ambient intensity
!   frames N
!   output PATH
!   object PRIM NAME MATERIAL CR CG CB px py pz rx ry rz sx sy sz &
!          SIZE RADIUS HEIGHT SEGMENTS
!   tris NAME COUNT            (followed by COUNT 'tri ...' lines)
!   tri R G B x1 y1 z1 x2 y2 z2 x3 y3 z3
!   loadobj NAME MATERIAL R G B px py pz rx ry rz sx sy sz PATH
!   anim KIND TARGET AXIS SPEED DURATION FPS EASE LOOP
! Colour -1 -1 -1 is the per-face palette sentinel (use_tri material).
! Missing size/radius/height arrive as -1, missing segments as 0; the
! per-primitive defaults below mirror emit_fortran.py:_build_call.
! Unknown lines are skipped with a printed warning, never a crash.
module scene_3d
    use math_3d
    use mesh_3d
    use camera_3d
    use material_3d
    use material_pbr_3d
    use texture_3d
    use lighting_3d
    use obj_loader, only: load_obj
    use sprite_3d, only: sprite_build_mesh
    use text_render_3d, only: text_build_mesh
    use particles_3d, only: ParticleSystem, particle_system_init
    use keyframe_3d, only: KeyFrame, KeyTrack
    implicit none
    private
    public :: SceneObject, SceneAnim, Scene
    public :: SceneSprite, SceneText, SceneParticles
    public :: scene_load, scene_free, scene_find_object, scene_build_object_mesh

    integer, parameter :: MAX_TOKENS = 40

    type :: SceneObject
        character(len=64) :: name = ''
        character(len=64) :: prim = ''
        character(len=64) :: mat_name = 'lambert'
        type(Mesh) :: mesh
        type(Material) :: mat
        type(vec3) :: pos = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        type(vec3) :: rot_deg = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        type(vec3) :: scl = vec3(1.0_dp, 1.0_dp, 1.0_dp)
        integer :: color(3) = [-1, -1, -1]  ! -1 = palette (per-tri colours)
        real(dp) :: dim_size = -1.0_dp      ! raw SIZE field (-1 = missing)
        real(dp) :: dim_radius = -1.0_dp    ! raw RADIUS field
        real(dp) :: dim_height = -1.0_dp    ! raw HEIGHT field
        integer :: segments = 0             ! raw SEGMENTS field (0 = missing)
        character(len=256) :: source_path = ''  ! loadobj PATH
        integer :: tri_filled = 0           ! tri lines consumed (prim 'tris')
        ! Wave A (coordinator integration): PBR + texture per object.
        type(MaterialPBR) :: pbr
        type(TextureImage) :: tex
        character(len=512) :: texture_path = ''
    end type SceneObject

    type :: SceneAnim
        character(len=32) :: kind = ''
        character(len=64) :: target = ''
        character(len=8) :: axis = 'y'      ! 1-char axis, stored as string
        real(dp) :: speed = 0.0_dp
        real(dp) :: duration = 0.0_dp
        integer :: fps = 30
        character(len=32) :: ease = 'linear'
        character(len=32) :: loop = 'forever'
    end type SceneAnim

    ! Wave B entities (coordinator integration). Sprites/texts/
    ! particles are stored as parameters; their meshes are built per
    ! frame in main (billboards need the camera, particles need t).
    type :: SceneSprite
        character(len=64) :: name = ''
        type(vec3) :: pos = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        real(dp) :: size = 1.0_dp
        integer :: color(3) = [255, 255, 255]
    end type SceneSprite

    type :: SceneText
        character(len=64) :: name = ''
        type(vec3) :: pos = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        real(dp) :: size = 1.0_dp
        integer :: color(3) = [255, 255, 255]
        character(len=256) :: content = ''
    end type SceneText

    type :: SceneParticles
        character(len=64) :: name = ''
        type(ParticleSystem) :: sys
    end type SceneParticles

    type :: Scene
        integer :: width = 640
        integer :: height = 480
        integer :: bg(3) = [25, 25, 35]
        type(Camera) :: cam
        type(vec3) :: light_dir = vec3(-0.5_dp, -1.0_dp, -0.7_dp)
        integer :: light_color(3) = [255, 255, 255]
        real(dp) :: light_intensity = 1.0_dp
        real(dp) :: ambient = 0.25_dp
        integer :: frames = 1
        character(len=256) :: output_file = 'output_render.ppm'
        type(SceneObject), allocatable :: objects(:)
        type(SceneAnim), allocatable :: anims(:)
        ! Wave A environment (coordinator integration). has_env gates
        ! main's env render path; default scenes never set it, so the
        ! legacy render stays byte-identical.
        type(LightSet) :: lights
        logical :: has_env = .false.
        logical :: has_dir_light = .false.
        integer :: fog_mode = 0             ! 0 none, 1 linear, 2 exp2
        real(dp) :: fog_near = 0.0_dp
        real(dp) :: fog_far = 100.0_dp
        real(dp) :: fog_density = 0.05_dp
        integer :: fog_color(3) = [255, 255, 255]
        integer :: tonemap_mode = 0         ! 0 none, 1 reinhard, 2 aces
        real(dp) :: tonemap_exposure = 1.0_dp
        integer :: shadow_mode = 0          ! 0 off, 1 on (hard), 2 soft
        integer :: shadow_size = 512
        ! Wave B entities (coordinator integration).
        type(SceneSprite), allocatable :: sprites(:)
        type(SceneText), allocatable :: texts(:)
        type(SceneParticles), allocatable :: parts(:)
        type(KeyTrack), allocatable :: tracks(:)
        ! Wave C (coordinator integration): ortho camera + post chain.
        ! Defaults keep earlier-wave scenes byte-identical.
        logical :: ortho = .false.
        real(dp) :: ortho_size = 5.0_dp
        integer :: n_post = 0
        character(len=32) :: post_names(16) = ''
        real(dp) :: post_amounts(16) = 0.0_dp
    end type Scene

contains

    ! ------------------------------------------------------------------
    ! Small parsing helpers
    ! ------------------------------------------------------------------

    ! Split a line into whitespace (space / tab) separated tokens.
    subroutine split_line(line, tokens, ntok)
        character(len=*), intent(in) :: line
        character(len=*), intent(out) :: tokens(:)
        integer, intent(out) :: ntok
        integer :: i, n, start
        logical :: in_tok

        tokens = ''
        ntok = 0
        n = len_trim(line)
        in_tok = .false.
        start = 1
        do i = 1, n
            if (line(i:i) == ' ' .or. line(i:i) == achar(9)) then
                if (in_tok) then
                    ntok = ntok + 1
                    if (ntok <= size(tokens)) tokens(ntok) = line(start:i - 1)
                    in_tok = .false.
                end if
            else if (.not. in_tok) then
                in_tok = .true.
                start = i
            end if
        end do
        if (in_tok) then
            ntok = ntok + 1
            if (ntok <= size(tokens)) tokens(ntok) = line(start:n)
        end if
        if (ntok > size(tokens)) ntok = size(tokens)
    end subroutine split_line

    subroutine parse_real(token, val, okp)
        character(len=*), intent(in) :: token
        real(dp), intent(out) :: val
        logical, intent(out) :: okp
        integer :: ios
        read(token, *, iostat=ios) val
        okp = (ios == 0)
        if (.not. okp) val = 0.0_dp
    end subroutine parse_real

    subroutine parse_int(token, val, okp)
        character(len=*), intent(in) :: token
        integer, intent(out) :: val
        logical, intent(out) :: okp
        integer :: ios
        real(dp) :: rval
        read(token, *, iostat=ios) val
        if (ios /= 0) then
            ! Tolerate '16.0'-style segment/count fields.
            read(token, *, iostat=ios) rval
            if (ios == 0) val = int(rval)
        end if
        okp = (ios == 0)
        if (.not. okp) val = 0
    end subroutine parse_int

    function tok_real(tokens, i) result(v)
        character(len=*), intent(in) :: tokens(:)
        integer, intent(in) :: i
        real(dp) :: v
        logical :: okp
        call parse_real(tokens(i), v, okp)
    end function tok_real

    function tok_int(tokens, i) result(v)
        character(len=*), intent(in) :: tokens(:)
        integer, intent(in) :: i
        integer :: v
        logical :: okp
        call parse_int(tokens(i), v, okp)
    end function tok_int

    function tok_vec3(tokens, i) result(v)
        character(len=*), intent(in) :: tokens(:)
        integer, intent(in) :: i
        type(vec3) :: v
        v = vec3_create(tok_real(tokens, i), tok_real(tokens, i + 1), &
                        tok_real(tokens, i + 2))
    end function tok_vec3

    ! ------------------------------------------------------------------
    ! Growable-array appends (deep-copy assignment of allocatable parts)
    ! ------------------------------------------------------------------

    subroutine append_object(sc, obj)
        type(Scene), intent(inout) :: sc
        type(SceneObject), intent(in) :: obj
        type(SceneObject), allocatable :: tmp(:)
        integer :: n
        n = 0
        if (allocated(sc%objects)) n = size(sc%objects)
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = sc%objects(1:n)
        tmp(n + 1) = obj
        if (allocated(sc%objects)) deallocate(sc%objects)
        call move_alloc(tmp, sc%objects)
    end subroutine append_object

    subroutine append_anim(sc, anim)
        type(Scene), intent(inout) :: sc
        type(SceneAnim), intent(in) :: anim
        type(SceneAnim), allocatable :: tmp(:)
        integer :: n
        n = 0
        if (allocated(sc%anims)) n = size(sc%anims)
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = sc%anims(1:n)
        tmp(n + 1) = anim
        if (allocated(sc%anims)) deallocate(sc%anims)
        call move_alloc(tmp, sc%anims)
    end subroutine append_anim

    subroutine append_sprite(sc, sp)
        type(Scene), intent(inout) :: sc
        type(SceneSprite), intent(in) :: sp
        type(SceneSprite), allocatable :: tmp(:)
        integer :: n
        n = 0
        if (allocated(sc%sprites)) n = size(sc%sprites)
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = sc%sprites(1:n)
        tmp(n + 1) = sp
        if (allocated(sc%sprites)) deallocate(sc%sprites)
        call move_alloc(tmp, sc%sprites)
    end subroutine append_sprite

    subroutine append_text(sc, tx)
        type(Scene), intent(inout) :: sc
        type(SceneText), intent(in) :: tx
        type(SceneText), allocatable :: tmp(:)
        integer :: n
        n = 0
        if (allocated(sc%texts)) n = size(sc%texts)
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = sc%texts(1:n)
        tmp(n + 1) = tx
        if (allocated(sc%texts)) deallocate(sc%texts)
        call move_alloc(tmp, sc%texts)
    end subroutine append_text

    subroutine append_parts(sc, pa)
        type(Scene), intent(inout) :: sc
        type(SceneParticles), intent(in) :: pa
        type(SceneParticles), allocatable :: tmp(:)
        integer :: n
        n = 0
        if (allocated(sc%parts)) n = size(sc%parts)
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = sc%parts(1:n)
        tmp(n + 1) = pa
        if (allocated(sc%parts)) deallocate(sc%parts)
        call move_alloc(tmp, sc%parts)
    end subroutine append_parts

    subroutine append_track(sc, tr)
        type(Scene), intent(inout) :: sc
        type(KeyTrack), intent(in) :: tr
        type(KeyTrack), allocatable :: tmp(:)
        integer :: n
        n = 0
        if (allocated(sc%tracks)) n = size(sc%tracks)
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = sc%tracks(1:n)
        tmp(n + 1) = tr
        if (allocated(sc%tracks)) deallocate(sc%tracks)
        call move_alloc(tmp, sc%tracks)
    end subroutine append_track

    subroutine append_key(track, kf)
        type(KeyTrack), intent(inout) :: track
        type(KeyFrame), intent(in) :: kf
        type(KeyFrame), allocatable :: tmp(:)
        integer :: n
        n = 0
        if (allocated(track%keys)) n = size(track%keys)
        allocate(tmp(n + 1))
        if (n > 0) tmp(1:n) = track%keys(1:n)
        tmp(n + 1) = kf
        if (allocated(track%keys)) deallocate(track%keys)
        call move_alloc(tmp, track%keys)
    end subroutine append_key

    ! The text after the first N whitespace-separated tokens of a
    ! line (for the 'text' scene line, whose content is the rest of
    ! the line, spaces included). '' when the line has <= N tokens.
    function rest_after_tokens(line, ntok_skip) result(rest)
        character(len=*), intent(in) :: line
        integer, intent(in) :: ntok_skip
        character(len=256) :: rest
        integer :: i, n, seen
        logical :: in_tok
        rest = ''
        n = len_trim(line)
        seen = 0
        in_tok = .false.
        do i = 1, n
            if (line(i:i) == ' ' .or. line(i:i) == achar(9)) then
                in_tok = .false.
            else if (.not. in_tok) then
                in_tok = .true.
                seen = seen + 1
                if (seen == ntok_skip + 1) then
                    rest = line(i:)
                    return
                end if
            end if
        end do
    end function rest_after_tokens

    integer function scene_find_object(sc, name) result(idx)
        type(Scene), intent(in) :: sc
        character(len=*), intent(in) :: name
        integer :: i
        idx = 0
        if (.not. allocated(sc%objects)) return
        do i = 1, size(sc%objects)
            if (trim(sc%objects(i)%name) == trim(name)) then
                idx = i
                return
            end if
        end do
    end function scene_find_object

    subroutine scene_free(sc)
        type(Scene), intent(inout) :: sc
        integer :: i
        if (allocated(sc%objects)) then
            do i = 1, size(sc%objects)
                call free_mesh(sc%objects(i)%mesh)
                call texture_free(sc%objects(i)%tex)
            end do
            deallocate(sc%objects)
        end if
        if (allocated(sc%lights%items)) deallocate(sc%lights%items)
        if (allocated(sc%anims)) deallocate(sc%anims)
        if (allocated(sc%sprites)) deallocate(sc%sprites)
        if (allocated(sc%texts)) deallocate(sc%texts)
        if (allocated(sc%parts)) deallocate(sc%parts)
        if (allocated(sc%tracks)) then
            do i = 1, size(sc%tracks)
                if (allocated(sc%tracks(i)%keys)) &
                    deallocate(sc%tracks(i)%keys)
            end do
            deallocate(sc%tracks)
        end if
    end subroutine scene_free

    ! ------------------------------------------------------------------
    ! Mesh construction for one object (mesh builders from mesh_3d)
    ! ------------------------------------------------------------------

    subroutine set_object_material(obj)
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
    end subroutine set_object_material

    subroutine scene_build_object_mesh(obj)
        type(SceneObject), intent(inout) :: obj
        real(dp) :: sz, rad, hgt
        integer :: seg
        logical :: lok

        sz = obj%dim_size
        rad = obj%dim_radius
        hgt = obj%dim_height
        seg = obj%segments

        select case (trim(obj%prim))
        case ('cube')
            if (sz <= 0.0_dp) sz = 2.0_dp
            call create_cube(obj%mesh, sz)
        case ('box')
            if (sz <= 0.0_dp) sz = 2.0_dp
            call create_box(obj%mesh, sz, sz, sz)
        case ('sphere')
            if (rad <= 0.0_dp) rad = 1.0_dp
            if (seg <= 0) seg = 16
            call create_sphere(obj%mesh, rad, seg)
        case ('cylinder')
            if (rad <= 0.0_dp) rad = 1.0_dp
            if (hgt <= 0.0_dp) hgt = 2.0_dp
            if (seg <= 0) seg = 16
            call create_cylinder(obj%mesh, rad, hgt, seg, .true.)
        case ('cone')
            if (rad <= 0.0_dp) rad = 1.0_dp
            if (hgt <= 0.0_dp) hgt = 2.0_dp
            if (seg <= 0) seg = 16
            call create_cone(obj%mesh, rad, hgt, seg, .true.)
        case ('plane')
            if (sz <= 0.0_dp) sz = 4.0_dp
            call create_plane(obj%mesh, sz, sz)
        case ('pyramid')
            if (sz <= 0.0_dp) sz = 2.0_dp
            if (hgt <= 0.0_dp) hgt = 2.0_dp
            call create_pyramid(obj%mesh, sz, hgt)
        case ('torus')
            if (rad <= 0.0_dp) rad = 1.5_dp
            if (seg <= 0) seg = 24
            call create_torus(obj%mesh, rad, rad * 0.35_dp, seg, &
                              max(6, seg / 2))
        case ('tris')
            ! Mesh was allocated/filled from the 'tri' lines by scene_load.
            continue
        case ('load')
            call load_obj(trim(obj%source_path), obj%mesh, lok)
            if (.not. lok) then
                print *, 'scene: warning: load_obj failed for ', &
                    trim(obj%source_path)
                obj%mesh%num_triangles = 0
            end if
        case default
            print *, 'scene: warning: unknown prim "', trim(obj%prim), &
                '" for object ', trim(obj%name), ': cube fallback'
            if (sz <= 0.0_dp) sz = 2.0_dp
            call create_cube(obj%mesh, sz)
        end select
        call set_object_material(obj)
    end subroutine scene_build_object_mesh

    ! Fill the transform/material/dimension fields shared by the
    ! 'object' (base = token index of CR) parsing path.
    subroutine fill_common(obj, tokens, base)
        type(SceneObject), intent(inout) :: obj
        character(len=*), intent(in) :: tokens(:)
        integer, intent(in) :: base  ! token index of CR
        obj%color = [tok_int(tokens, base), tok_int(tokens, base + 1), &
                     tok_int(tokens, base + 2)]
        obj%pos = tok_vec3(tokens, base + 3)
        obj%rot_deg = tok_vec3(tokens, base + 6)
        obj%scl = tok_vec3(tokens, base + 9)
    end subroutine fill_common

    ! ------------------------------------------------------------------
    ! The loader
    ! ------------------------------------------------------------------

    ! Resolve a path from a .scene file: absolute paths and paths that
    ! exist relative to the cwd win; otherwise try the .scene file's own
    ! directory (Wave A fix for the v1 loadobj rough edge — paths in a
    ! scene belong to the scene, not to wherever the engine runs).
    function resolve_scene_path(dir, path) result(res)
        character(len=*), intent(in) :: dir, path
        character(len=256) :: res
        logical :: ex
        res = trim(path)
        if (len_trim(path) == 0) return
        if (path(1:1) == '/') return
        inquire(file=trim(path), exist=ex)
        if (ex) return
        if (len_trim(dir) > 0) res = trim(dir) // '/' // trim(path)
    end function resolve_scene_path

    subroutine scene_load(path, sc, ok, errmsg)
        character(len=*), intent(in) :: path
        type(Scene), intent(inout) :: sc
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg

        integer :: u, ios, ntok, lineno, count, i
        character(len=2048) :: line
        character(len=256) :: tokens(MAX_TOKENS)
        type(SceneObject) :: obj
        type(SceneAnim) :: anim
        type(SceneSprite) :: spr
        type(SceneText) :: txt
        type(SceneParticles) :: prt
        type(KeyTrack) :: trk
        type(KeyFrame) :: kf
        integer :: cur_track  ! track index receiving 'key' lines
        type(vec3) :: cam_pos, cam_tgt, cam_up
        real(dp) :: aspect
        integer :: cur_tris  ! object index receiving 'tri' lines, 0 = none
        ! Wave A locals
        character(len=512) :: scene_dir
        type(Light3) :: extra_lights(32)
        type(Light3) :: lt
        integer :: n_extra, slash, oi
        logical :: tex_ok

        ok = .true.
        errmsg = ''
        cur_tris = 0
        cur_track = 0
        n_extra = 0
        scene_dir = ''
        slash = index(trim(path), '/', back=.true.)
        if (slash > 1) scene_dir = path(1:slash - 1)

        ! Reset to format defaults.
        call scene_free(sc)
        sc = Scene()
        cam_pos = vec3_create(3.0_dp, 2.5_dp, 4.0_dp)
        cam_tgt = vec3_create(0.0_dp, 0.0_dp, 0.0_dp)
        cam_up = vec3_create(0.0_dp, 1.0_dp, 0.0_dp)
        aspect = real(sc%width, dp) / real(sc%height, dp)
        call camera_init(sc%cam, cam_pos, cam_tgt, 60.0_dp, aspect, &
                         0.1_dp, 100.0_dp)

        open(newunit=u, file=trim(path), status='old', action='read', &
             iostat=ios)
        if (ios /= 0) then
            ok = .false.
            errmsg = 'scene_load: cannot open file: ' // trim(path)
            return
        end if

        lineno = 0
        do
            read(u, '(A)', iostat=ios) line
            if (ios /= 0) exit
            lineno = lineno + 1
            if (len_trim(line) == 0) cycle
            if (line(1:1) == '#') cycle  ! header stamps / comments
            call split_line(line, tokens, ntok)
            if (ntok == 0) cycle
            if (tokens(1)(1:1) == '#') cycle

            select case (trim(tokens(1)))
            case ('forge3d-scene')
                continue  ! version line; format 1 is what we parse
            case ('size')
                if (ntok >= 3) then
                    sc%width = tok_int(tokens, 2)
                    sc%height = tok_int(tokens, 3)
                else
                    call warn_line(lineno, line)
                end if
            case ('bg')
                if (ntok >= 4) then
                    sc%bg = [tok_int(tokens, 2), tok_int(tokens, 3), &
                                tok_int(tokens, 4)]
                else
                    call warn_line(lineno, line)
                end if
            case ('camera')
                if (ntok >= 13) then
                    cam_pos = tok_vec3(tokens, 2)
                    cam_tgt = tok_vec3(tokens, 5)
                    cam_up = tok_vec3(tokens, 8)
                    if (sc%height > 0) then
                        aspect = real(sc%width, dp) / &
                                 real(sc%height, dp)
                    else
                        aspect = 1.0_dp
                    end if
                    call camera_init(sc%cam, cam_pos, cam_tgt, &
                                     tok_real(tokens, 11), aspect, &
                                     tok_real(tokens, 12), &
                                     tok_real(tokens, 13))
                    sc%cam%up = cam_up
                    call camera_update_matrices(sc%cam)
                else
                    call warn_line(lineno, line)
                end if
            case ('light')
                if (ntok >= 2 .and. trim(tokens(2)) == 'ambient') then
                    if (ntok >= 3) sc%ambient = tok_real(tokens, 3)
                else if (ntok >= 9 .and. &
                         trim(tokens(2)) == 'directional') then
                    sc%light_dir = tok_vec3(tokens, 3)
                    sc%light_color = [tok_int(tokens, 6), &
                                         tok_int(tokens, 7), &
                                         tok_int(tokens, 8)]
                    sc%light_intensity = tok_real(tokens, 9)
                    sc%has_dir_light = .true.
                else if (ntok >= 11 .and. &
                         trim(tokens(2)) == 'point' .and. &
                         n_extra < 32) then
                    ! light point px py pz R G B intensity distance decay
                    lt = Light3()
                    lt%kind = 1
                    lt%pos = tok_vec3(tokens, 3)
                    lt%dir = vec3_create(0.0_dp, -1.0_dp, 0.0_dp)
                    lt%spot_dir = lt%dir
                    lt%color = [tok_int(tokens, 6), tok_int(tokens, 7), &
                                tok_int(tokens, 8)]
                    lt%intensity = tok_real(tokens, 9)
                    lt%distance = tok_real(tokens, 10)
                    lt%decay = tok_real(tokens, 11)
                    n_extra = n_extra + 1
                    extra_lights(n_extra) = lt
                    sc%has_env = .true.
                else if (ntok >= 16 .and. &
                         trim(tokens(2)) == 'spot' .and. &
                         n_extra < 32) then
                    ! light spot px py pz dx dy dz R G B intensity
                    !            distance decay angle penumbra
                    lt = Light3()
                    lt%kind = 2
                    lt%pos = tok_vec3(tokens, 3)
                    lt%spot_dir = tok_vec3(tokens, 6)
                    lt%dir = lt%spot_dir
                    lt%color = [tok_int(tokens, 9), tok_int(tokens, 10), &
                                tok_int(tokens, 11)]
                    lt%intensity = tok_real(tokens, 12)
                    lt%distance = tok_real(tokens, 13)
                    lt%decay = tok_real(tokens, 14)
                    lt%angle_deg = tok_real(tokens, 15)
                    lt%penumbra = tok_real(tokens, 16)
                    n_extra = n_extra + 1
                    extra_lights(n_extra) = lt
                    sc%has_env = .true.
                else
                    call warn_line(lineno, line)
                end if
            case ('fog')
                ! fog linear near far R G B | fog exp2 density R G B
                if (ntok >= 7 .and. trim(tokens(2)) == 'linear') then
                    sc%fog_mode = 1
                    sc%fog_near = tok_real(tokens, 3)
                    sc%fog_far = tok_real(tokens, 4)
                    sc%fog_color = [tok_int(tokens, 5), &
                                    tok_int(tokens, 6), &
                                    tok_int(tokens, 7)]
                    sc%has_env = .true.
                else if (ntok >= 6 .and. trim(tokens(2)) == 'exp2') then
                    sc%fog_mode = 2
                    sc%fog_density = tok_real(tokens, 3)
                    sc%fog_color = [tok_int(tokens, 4), &
                                    tok_int(tokens, 5), &
                                    tok_int(tokens, 6)]
                    sc%has_env = .true.
                else if (ntok >= 2 .and. trim(tokens(2)) == 'none') then
                    sc%fog_mode = 0
                else
                    call warn_line(lineno, line)
                end if
            case ('tonemap')
                ! tonemap MODE EXPOSURE
                if (ntok >= 2) then
                    select case (trim(tokens(2)))
                    case ('reinhard')
                        sc%tonemap_mode = 1
                    case ('aces')
                        sc%tonemap_mode = 2
                    case default
                        sc%tonemap_mode = 0
                    end select
                    if (ntok >= 3) &
                        sc%tonemap_exposure = tok_real(tokens, 3)
                    if (sc%tonemap_mode /= 0) sc%has_env = .true.
                else
                    call warn_line(lineno, line)
                end if
            case ('shadow')
                ! shadow MODE SIZE (on|soft|off)
                if (ntok >= 2) then
                    select case (trim(tokens(2)))
                    case ('on')
                        sc%shadow_mode = 1
                    case ('soft')
                        sc%shadow_mode = 2
                    case default
                        sc%shadow_mode = 0
                    end select
                    if (ntok >= 3) sc%shadow_size = tok_int(tokens, 3)
                    if (sc%shadow_mode /= 0) sc%has_env = .true.
                else
                    call warn_line(lineno, line)
                end if
            case ('objmat')
                ! objmat NAME MATERIAL METALNESS ROUGHNESS SPECULAR
                !        SHININESS TEXTURE('-' = none)   (8 tokens)
                if (ntok < 8) then
                    call warn_line(lineno, line)
                    cycle
                end if
                oi = scene_find_object(sc, trim(tokens(2)))
                if (oi == 0) then
                    call warn_line(lineno, line)
                    cycle
                end if
                associate (o => sc%objects(oi))
                    o%mat_name = trim(tokens(3))
                    call set_object_material(o)
                    o%pbr%metalness = tok_real(tokens, 4)
                    o%pbr%roughness = tok_real(tokens, 5)
                    o%pbr%specular = tok_real(tokens, 6)
                    o%pbr%shininess = tok_real(tokens, 7)
                    if (trim(tokens(3)) == 'standard') &
                        o%pbr%mode = MAT_STANDARD
                    if (trim(tokens(8)) /= '-') then
                        o%texture_path = resolve_scene_path( &
                            scene_dir, trim(tokens(8)))
                        call texture_load_ppm(trim(o%texture_path), &
                                              o%tex, tex_ok)
                        if (.not. tex_ok) print *, &
                            'scene: warning: cannot load texture ', &
                            trim(o%texture_path)
                    end if
                end associate
                sc%has_env = .true.
            case ('frames')
                if (ntok >= 2) sc%frames = tok_int(tokens, 2)
            case ('output')
                if (ntok >= 2) sc%output_file = trim(tokens(2))
            case ('object')
                ! object PRIM NAME MATERIAL CR CG CB pos rot scl
                !        SIZE RADIUS HEIGHT SEGMENTS   (20 tokens)
                if (ntok < 20) then
                    call warn_line(lineno, line)
                    cycle
                end if
                obj = SceneObject()
                obj%prim = trim(tokens(2))
                obj%name = trim(tokens(3))
                obj%mat_name = trim(tokens(4))
                call fill_common(obj, tokens, 5)
                obj%dim_size = tok_real(tokens, 17)
                obj%dim_radius = tok_real(tokens, 18)
                obj%dim_height = tok_real(tokens, 19)
                obj%segments = tok_int(tokens, 20)
                call scene_build_object_mesh(obj)
                call append_object(sc, obj)
                call free_mesh(obj%mesh)
                cur_tris = 0
            case ('tris')
                if (ntok < 3) then
                    call warn_line(lineno, line)
                    cycle
                end if
                obj = SceneObject()
                obj%prim = 'tris'
                obj%name = trim(tokens(2))
                count = max(0, tok_int(tokens, 3))
                ! Wave B: optional transform tail (tokens 4..12:
                ! pos rot scl) for placed glTF loads.
                if (ntok >= 12) then
                    obj%pos = tok_vec3(tokens, 4)
                    obj%rot_deg = tok_vec3(tokens, 7)
                    obj%scl = tok_vec3(tokens, 10)
                end if
                obj%mesh%num_triangles = count
                if (allocated(obj%mesh%triangles)) &
                    deallocate(obj%mesh%triangles)
                allocate(obj%mesh%triangles(max(1, count)))
                call append_object(sc, obj)
                call free_mesh(obj%mesh)
                cur_tris = size(sc%objects)
            case ('tri')
                if (ntok < 13 .or. cur_tris == 0) then
                    call warn_line(lineno, line)
                    cycle
                end if
                associate (o => sc%objects(cur_tris))
                    if (o%tri_filled < o%mesh%num_triangles) then
                        i = o%tri_filled + 1
                        o%tri_filled = i
                        o%mesh%triangles(i)%color = &
                            [tok_int(tokens, 2), tok_int(tokens, 3), &
                             tok_int(tokens, 4)]
                        o%mesh%triangles(i)%v(1) = tok_vec3(tokens, 5)
                        o%mesh%triangles(i)%v(2) = tok_vec3(tokens, 8)
                        o%mesh%triangles(i)%v(3) = tok_vec3(tokens, 11)
                        o%mesh%triangles(i)%normal = &
                            compute_triangle_normal( &
                                o%mesh%triangles(i)%v(1), &
                                o%mesh%triangles(i)%v(2), &
                                o%mesh%triangles(i)%v(3))
                    else
                        call warn_line(lineno, line)
                    end if
                end associate
            case ('loadobj')
                ! loadobj NAME MATERIAL R G B pos rot scl PATH (16 tokens)
                if (ntok < 16) then
                    call warn_line(lineno, line)
                    cycle
                end if
                obj = SceneObject()
                obj%prim = 'load'
                obj%name = trim(tokens(2))
                obj%mat_name = trim(tokens(3))
                call fill_common(obj, tokens, 4)
                obj%source_path = resolve_scene_path(scene_dir, &
                                                     trim(tokens(16)))
                call scene_build_object_mesh(obj)
                call append_object(sc, obj)
                call free_mesh(obj%mesh)
                cur_tris = 0
            case ('sprite')
                ! sprite NAME PX PY PZ SIZE R G B   (9 tokens)
                if (ntok < 9) then
                    call warn_line(lineno, line)
                    cycle
                end if
                spr = SceneSprite()
                spr%name = trim(tokens(2))
                spr%pos = tok_vec3(tokens, 3)
                spr%size = tok_real(tokens, 6)
                spr%color = [tok_int(tokens, 7), tok_int(tokens, 8), &
                             tok_int(tokens, 9)]
                call append_sprite(sc, spr)
                cur_tris = 0
            case ('text')
                ! text NAME PX PY PZ SIZE R G B CONTENT...
                ! CONTENT is the rest of the raw line (spaces kept).
                if (ntok < 9) then
                    call warn_line(lineno, line)
                    cycle
                end if
                txt = SceneText()
                txt%name = trim(tokens(2))
                txt%pos = tok_vec3(tokens, 3)
                txt%size = tok_real(tokens, 6)
                txt%color = [tok_int(tokens, 7), tok_int(tokens, 8), &
                             tok_int(tokens, 9)]
                txt%content = rest_after_tokens(line, 9)
                call append_text(sc, txt)
                cur_tris = 0
            case ('particles')
                ! particles NAME PX PY PZ COUNT LIFE SPEED SIZE
                !           R G B SPREAD GRAVITY SEED   (15 tokens)
                if (ntok < 15) then
                    call warn_line(lineno, line)
                    cycle
                end if
                prt = SceneParticles()
                prt%name = trim(tokens(2))
                call particle_system_init(prt%sys)
                prt%sys%origin = tok_vec3(tokens, 3)
                prt%sys%count = tok_int(tokens, 6)
                prt%sys%life = tok_real(tokens, 7)
                prt%sys%speed = tok_real(tokens, 8)
                prt%sys%size = tok_real(tokens, 9)
                prt%sys%color = [tok_int(tokens, 10), &
                                 tok_int(tokens, 11), &
                                 tok_int(tokens, 12)]
                prt%sys%spread = tok_real(tokens, 13)
                prt%sys%gravity = tok_real(tokens, 14)
                prt%sys%seed = tok_int(tokens, 15)
                call append_parts(sc, prt)
                cur_tris = 0
            case ('keys')
                ! keys TARGET DURATION LOOP NKEYS   (5 tokens)
                if (ntok < 5) then
                    call warn_line(lineno, line)
                    cycle
                end if
                trk = KeyTrack()
                trk%target = trim(tokens(2))
                trk%duration = tok_real(tokens, 3)
                trk%loop = trim(tokens(4))
                call append_track(sc, trk)
                if (allocated(trk%keys)) deallocate(trk%keys)
                cur_track = size(sc%tracks)
                cur_tris = 0
            case ('key')
                ! key TIME PX PY PZ RX RY RZ SCALE EASE  (10 tokens)
                if (ntok < 10 .or. cur_track == 0) then
                    call warn_line(lineno, line)
                    cycle
                end if
                kf = KeyFrame()
                kf%time = tok_real(tokens, 2)
                kf%pos = [tok_real(tokens, 3), tok_real(tokens, 4), &
                          tok_real(tokens, 5)]
                kf%rot_deg = [tok_real(tokens, 6), &
                              tok_real(tokens, 7), &
                              tok_real(tokens, 8)]
                kf%scale = tok_real(tokens, 9)
                kf%ease = trim(tokens(10))
                call append_key(sc%tracks(cur_track), kf)
            case ('ortho')
                ! ortho SIZE -- Wave C orthographic camera (row 3).
                if (ntok < 2) then
                    call warn_line(lineno, line)
                    cycle
                end if
                sc%ortho = .true.
                sc%ortho_size = tok_real(tokens, 2)
            case ('post')
                ! post NAME AMOUNT -- Wave C filter chain (row 30),
                ! applied in file order by main after rendering.
                if (ntok < 3) then
                    call warn_line(lineno, line)
                    cycle
                end if
                if (sc%n_post < 16) then
                    sc%n_post = sc%n_post + 1
                    sc%post_names(sc%n_post) = trim(tokens(2))
                    sc%post_amounts(sc%n_post) = tok_real(tokens, 3)
                end if
            case ('instance')
                ! instance NEW SOURCE PX PY PZ RX RY RZ SCALE
                ! Wave C true instancing (row 22): a copy of the
                ! named object's built mesh/pose template with its
                ! own placement; shares the source geometry build.
                if (ntok < 10) then
                    call warn_line(lineno, line)
                    cycle
                end if
                block
                    integer :: src_idx
                    type(SceneObject) :: iobj
                    src_idx = scene_find_object(sc, trim(tokens(3)))
                    if (src_idx <= 0) then
                        call warn_line(lineno, line)
                    else
                        iobj = sc%objects(src_idx)
                        iobj%name = trim(tokens(2))
                        iobj%pos = tok_vec3(tokens, 4)
                        iobj%rot_deg = tok_vec3(tokens, 7)
                        iobj%scl = vec3_create(tok_real(tokens, 10), &
                                               tok_real(tokens, 10), &
                                               tok_real(tokens, 10))
                        call append_object(sc, iobj)
                    end if
                end block
            case ('anim')
                ! anim KIND TARGET AXIS SPEED DURATION FPS EASE LOOP
                if (ntok < 9) then
                    call warn_line(lineno, line)
                    cycle
                end if
                anim = SceneAnim()
                anim%kind = trim(tokens(2))
                anim%target = trim(tokens(3))
                anim%axis = trim(tokens(4))
                anim%speed = tok_real(tokens, 5)
                anim%duration = tok_real(tokens, 6)
                anim%fps = tok_int(tokens, 7)
                anim%ease = trim(tokens(8))
                anim%loop = trim(tokens(9))
                call append_anim(sc, anim)
            case default
                call warn_line(lineno, line)
            end select
        end do
        close(u)

        ! Wave A: assemble the unified LightSet (directional first,
        ! built from the legacy fields so defaults match v1 exactly,
        ! then any point/spot lights in file order).
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
            sc%lights%items(1 + i) = extra_lights(i)
        end do
        sc%lights%ambient = sc%ambient
        sc%lights%ambient_color = [255, 255, 255]
        ! Any object carrying an objmat/texture/standard material also
        ! routes the scene through the env path.
        if (allocated(sc%objects)) then
            do i = 1, size(sc%objects)
                if (sc%objects(i)%tex%loaded .or. &
                    trim(sc%objects(i)%mat_name) == 'standard') &
                    sc%has_env = .true.
            end do
        end if

        ! Materials for 'tris' objects (their colours live per-triangle).
        if (allocated(sc%objects)) then
            do i = 1, size(sc%objects)
                if (trim(sc%objects(i)%prim) == 'tris') &
                    call set_object_material(sc%objects(i))
            end do
        end if
    contains
        subroutine warn_line(ln, text)
            integer, intent(in) :: ln
            character(len=*), intent(in) :: text
            print *, 'scene: warning: skipping line ', ln, ': ', &
                trim(text)
        end subroutine warn_line
    end subroutine scene_load

end module scene_3d
