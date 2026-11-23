! scene.f90 -- Forge3D .scene reader (seat B23, module scene_3d).
!
! Parses exactly the text format emitted by the native compiler's
! emit_scene_text (compiler/src/f3dc_emit_fortran.f90):
!   forge3d-scene 1
!   # <header stamp lines start with '#': skipped anywhere>
!   size W H
!   bg R G B
!   camera px py pz tx ty tz ux uy uz fov near far
!   light directional dx dy dz R G B intensity
!   light ambient intensity
!   frames N
!   fps N                      (v3.0 Phase 5, optional; scene timeline)
!   output PATH
!   object PRIM NAME MATERIAL CR CG CB px py pz rx ry rz sx sy sz &
!          SIZE RADIUS HEIGHT SEGMENTS
!   tris NAME COUNT            (followed by COUNT 'tri ...' lines)
!   tri R G B x1 y1 z1 x2 y2 z2 x3 y3 z3
!   loadobj NAME MATERIAL R G B px py pz rx ry rz sx sy sz PATH
!   anim KIND TARGET AXIS SPEED DURATION FPS EASE LOOP
!   objtex NAME SLOT PATH        (v3.0 Phase 4, optional; SLOT in
!          normal | mr | emissive | occlusion -- an extra PBR
!          texture slot for a previously defined object)
!   objalpha NAME MODE CUTOFF OPACITY   (v3.0 Phase 4, optional;
!          MODE 0 opaque / 1 mask / 2 blend, CUTOFF + OPACITY reals)
!   objemissive NAME R G B       (v3.0 Phase 4, optional; reals
!          0..1, same float style as the objmat line)
! Colour -1 -1 -1 is the per-face palette sentinel (use_tri material).
! Missing size/radius/height arrive as -1, missing segments as 0; the
! per-primitive defaults below mirror the emitter's _build_call
! equivalent in compiler/src/f3dc_emit_fortran.f90.
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
    ! Wave D (coordinator integration): row-7 geometry modules.
    use geo_flat_3d, only: create_circle, create_ring
    use geo_capsule_3d, only: create_capsule
    use geo_tube_3d, only: create_tube
    use geo_lathe_3d, only: create_lathe
    use geo_extrude_3d, only: create_extrude
    use geo_poly_3d, only: create_tetrahedron, create_octahedron, &
        create_icosahedron, create_dodecahedron
    use geo_torusknot_3d, only: create_torusknot
    ! Wave E (coordinator integration): C2 shader programs + C1
    ! skinning/morph application.
    use shader_3d, only: ShaderProg, shader_parse
    use skinning_3d, only: morph_apply, skin_apply
    implicit none
    private
    public :: SceneObject, SceneAnim, Scene
    public :: SceneSprite, SceneText, SceneParticles
    public :: scene_load, scene_free, scene_find_object, scene_build_object_mesh

    ! Wave D: raised 40 -> 256 so tube/lathe/extrude object lines can
    ! carry long point lists as trailing tokens (21+).
    !
    ! v3.0 Phase 9 (S1): 256 is no longer a CAP.  It is only the
    ! INITIAL capacity of the heap-allocated token scratch below
    ! (module variable 'tokens'), which scene_load doubles whenever
    ! a line carries more tokens, so no .scene line can silently
    ! lose tokens any more.  The scratch is owned by this module,
    ! reused across loads, and released by scene_free.
    integer, parameter :: TOKENS_INITIAL_CAP = 256
    ! Documented format limit: one token is at most TOKEN_LEN
    ! characters.  This is safe because every field a token can
    ! feed is itself at most this long in the format: names and
    ! material/shader/bone names are len=64, SceneText content and
    ! Scene%output_file are len=256, and every path passes through
    ! resolve_scene_path, whose result is len=256 by contract (the
    ! len=512 path fields in SceneObject are only ever assigned
    ! from that len=256 result).  A longer token is therefore not
    ! representable anywhere in the format; scene_load now warns
    ! on stderr when one is truncated to TOKEN_LEN instead of
    ! truncating it silently (see count_line_tokens use below).
    integer, parameter :: TOKEN_LEN = 256
    character(len=TOKEN_LEN), allocatable :: tokens(:)
    integer :: tokens_cap = 0

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
        ! Wave D: point list from trailing object-line tokens (21+).
        ! tube: (x,y,z) per point; lathe/extrude: (x,y) with z = 0.
        type(vec3), allocatable :: pts(:)
        integer :: n_pts = 0
        ! Wave A (coordinator integration): PBR + texture per object.
        type(MaterialPBR) :: pbr
        type(TextureImage) :: tex
        character(len=512) :: texture_path = ''
        ! v3.0 Phase 4: extra PBR texture slots (normal / metallic-
        ! roughness / emissive / occlusion maps) + their source
        ! paths, set by the optional 'objtex' .scene lines and
        ! loaded by the post-pass at the end of scene_load.  Empty
        ! paths / unloaded textures are the legacy-equivalent
        ! default: the legacy renderer never reads them.
        type(TextureImage) :: tex_normal
        type(TextureImage) :: tex_mr
        type(TextureImage) :: tex_emissive
        type(TextureImage) :: tex_occl
        character(len=512) :: normal_path = ''
        character(len=512) :: mr_path = ''
        character(len=512) :: emissive_map_path = ''
        character(len=512) :: occl_path = ''
        ! P1: optional trailing 'shading smooth|flat' on the object
        ! line. '' = builder default (curved builders are smooth,
        ! flat builders are flat); see scene_build_object_mesh.
        character(len=8) :: shading = ''
        ! P3: optional trailing 'mirror x|y|z' on the object line.
        ! Axis code: 0 = none, 1 = x, 2 = y, 3 = z.  Applied in
        ! scene_build_object_mesh (see the transform-order note
        ! there).
        integer :: mirror = 0
        ! Wave E (coordinator integration): C2 custom shader binding.
        ! has_shader routes this object through
        ! framebuffer_render_mesh_shader in main.
        logical :: has_shader = .false.
        character(len=64) :: shader_name = ''
        type(ShaderProg) :: shader_prog
    end type SceneObject

    ! Wave E: a named compiled shader definition (C2).
    type :: SceneShaderDef
        character(len=64) :: name = ''
        type(ShaderProg) :: prog
    end type SceneShaderDef

    ! Wave E: a named skinning bone (C1).
    type :: SceneBone
        character(len=64) :: name = ''
        type(vec3) :: pivot = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        type(vec3) :: rot_deg = vec3(0.0_dp, 0.0_dp, 0.0_dp)
        real(dp) :: radius = 2.0_dp
    end type SceneBone

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
        ! v3.0 Phase 5 (M3): scene-level timeline rate from the
        ! optional v1 'fps N' line; 0 = unset.  main's fallback
        ! chain (scene fps -> first anim fps -> 30) is wired by the
        ! coordinator at integration; this field is additive and
        ! defaults to 0, so existing scenes are unaffected.
        integer :: fps = 0
        ! v3.0 Phase 2: SSAA factor for the v3 renderer (1 = off).
        ! The legacy renderer ignores this field entirely; the .scene
        ! line is optional and defaults to 1, so frozen-path scenes
        ! are unaffected.
        integer :: antialias = 1
        character(len=256) :: output_file = 'output_render.ppm'
        type(SceneObject), allocatable :: objects(:)
        type(SceneAnim), allocatable :: anims(:)
        ! S2 (v3.0 Phase 0): capacity-doubling storage for the
        ! append_* arrays below.  n_* is the live element count and
        ! cap_* the allocated capacity (size of the array); every
        ! reader must iterate 1..n_*, never 1..size(...).  During
        ! scene_load the arrays may carry spare capacity; scene_load
        ! trims them back to exact size before returning (see
        ! scene_trim_storage), so size() once again equals the count
        ! for any code outside the load path.
        integer :: n_objects = 0
        integer :: cap_objects = 0
        integer :: n_anims = 0
        integer :: cap_anims = 0
        integer :: n_sprites = 0
        integer :: cap_sprites = 0
        integer :: n_texts = 0
        integer :: cap_texts = 0
        integer :: n_parts = 0
        integer :: cap_parts = 0
        integer :: n_tracks = 0
        integer :: cap_tracks = 0
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
        ! v3.0 Phase 3: PCF kernel radius for the v3 per-light
        ! shadow maps (0 = single tap).  Legacy path ignores it.
        integer :: shadow_pcf = 1
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
        ! Wave E (coordinator integration): shader defs + bones.
        type(SceneShaderDef), allocatable :: shader_defs(:)
        type(SceneBone), allocatable :: bones(:)
    end type Scene

contains

    ! ------------------------------------------------------------------
    ! Small parsing helpers
    ! ------------------------------------------------------------------

    ! Count the whitespace (space / tab) separated tokens in a
    ! line, and the length of the longest one, using exactly
    ! split_line's tokenisation.  scene_load (Phase 9 S1) counts
    ! first so it can grow the token scratch BEFORE splitting;
    ! split_line's own clamp to size(tokens) is then unreachable
    ! from the reader and remains only as a defensive bound for
    ! any other caller.
    subroutine count_line_tokens(line, ncount, longest)
        character(len=*), intent(in) :: line
        integer, intent(out) :: ncount, longest
        integer :: i, n, start
        logical :: in_tok
        ncount = 0
        longest = 0
        n = len_trim(line)
        in_tok = .false.
        start = 1
        do i = 1, n
            if (line(i:i) == ' ' .or. line(i:i) == achar(9)) then
                if (in_tok) then
                    ncount = ncount + 1
                    longest = max(longest, i - start)
                    in_tok = .false.
                end if
            else if (.not. in_tok) then
                in_tok = .true.
                start = i
            end if
        end do
        if (in_tok) then
            ncount = ncount + 1
            longest = max(longest, n - start + 1)
        end if
    end subroutine count_line_tokens

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
    ! Growable-array appends (S2, v3.0 Phase 0: capacity doubling)
    !
    ! Each append used to deep-copy the whole array (O(N^2) to load
    ! N elements).  Now an append only copies when the array is full,
    ! growing to twice the capacity (amortised O(1) per append); the
    ! live count lives in the Scene's n_* fields and the capacity in
    ! cap_* (== size of the array).  Array assignment of these types
    ! deep-copies allocatable parts (meshes, point lists, keys), in
    ! the grow step exactly as the old code did on every append.
    ! ------------------------------------------------------------------

    subroutine append_object(sc, obj)
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
    end subroutine append_object

    subroutine append_anim(sc, anim)
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
    end subroutine append_anim

    subroutine append_sprite(sc, sp)
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
    end subroutine append_sprite

    subroutine append_text(sc, tx)
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
    end subroutine append_text

    subroutine append_parts(sc, pa)
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
    end subroutine append_parts

    subroutine append_track(sc, tr)
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
    end subroutine append_track

    ! KeyTrack (keyframe_3d) has no count field of its own and
    ! key_eval reads size(track%keys), so the caller (scene_load)
    ! owns the key count: it passes n_keys in/out here and trims the
    ! keys back to exact size with trim_key_track before the scene
    ! is handed out (see scene_load).  Growth is the same
    ! capacity-doubling as the Scene arrays above.
    subroutine append_key(track, kf, n_keys)
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
    end subroutine append_key

    ! Reallocate one track's keys to exactly n_keys elements
    ! (deallocate when zero), undoing append_key's spare capacity.
    subroutine trim_key_track(track, n_keys)
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
    end subroutine trim_key_track

    ! Trim every Scene append_* array back to its live count and
    ! reset cap_* to match, so after scene_load size(array) equals
    ! the count again for any reader outside the load path.  A count
    ! of zero deallocates, matching the pre-S2 state of a scene that
    ! never appended that kind of element.
    subroutine scene_trim_storage(sc)
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
    end subroutine scene_trim_storage

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
        do i = 1, sc%n_objects
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
            do i = 1, sc%n_objects
                call free_mesh(sc%objects(i)%mesh)
                call texture_free(sc%objects(i)%tex)
                call texture_free(sc%objects(i)%tex_normal)
                call texture_free(sc%objects(i)%tex_mr)
                call texture_free(sc%objects(i)%tex_emissive)
                call texture_free(sc%objects(i)%tex_occl)
                if (allocated(sc%objects(i)%pts)) &
                    deallocate(sc%objects(i)%pts)
            end do
            deallocate(sc%objects)
        end if
        if (allocated(sc%lights%items)) deallocate(sc%lights%items)
        if (allocated(sc%anims)) deallocate(sc%anims)
        if (allocated(sc%sprites)) deallocate(sc%sprites)
        if (allocated(sc%texts)) deallocate(sc%texts)
        if (allocated(sc%parts)) deallocate(sc%parts)
        if (allocated(sc%tracks)) then
            do i = 1, sc%n_tracks
                if (allocated(sc%tracks(i)%keys)) &
                    deallocate(sc%tracks(i)%keys)
            end do
            deallocate(sc%tracks)
        end if
        ! S2: storage is empty again; counts and capacities reset
        ! (the deallocations above already freed any spare capacity).
        sc%n_objects = 0; sc%cap_objects = 0
        sc%n_anims = 0; sc%cap_anims = 0
        sc%n_sprites = 0; sc%cap_sprites = 0
        sc%n_texts = 0; sc%cap_texts = 0
        sc%n_parts = 0; sc%cap_parts = 0
        sc%n_tracks = 0; sc%cap_tracks = 0
        if (allocated(sc%shader_defs)) deallocate(sc%shader_defs)
        if (allocated(sc%bones)) deallocate(sc%bones)
        ! Phase 9 S1: release the heap token scratch owned by this
        ! module (grown by scene_load; see TOKENS_INITIAL_CAP).
        ! scene_load re-allocates it at its initial capacity on the
        ! next load, after its own scene_free reset call.
        if (allocated(tokens)) deallocate(tokens)
        tokens_cap = 0
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

    ! v3.0 Phase 4: load one extra PBR texture slot from its stored
    ! path (no-op for an empty path or an already-loaded slot).
    ! srgb_flag records the map's colour space on the texture:
    ! colour/emissive maps .true., data maps (normal / metallic-
    ! roughness / occlusion) .false.  The flag is set BEFORE
    ! texture_build_mips, which decodes by tex%srgb.  Loading goes
    ! through texture_load (PNG/PPM dispatch, Phase 4).
    subroutine load_pbr_slot(path, tex, srgb_flag)
        character(len=*), intent(in) :: path
        type(TextureImage), intent(inout) :: tex
        logical, intent(in) :: srgb_flag
        logical :: ok
        if (len_trim(path) == 0) return
        if (tex%loaded) return
        call texture_load(trim(path), tex, ok)
        if (.not. ok) then
            print *, 'scene: warning: cannot load texture ', &
                trim(path)
            return
        end if
        tex%srgb = srgb_flag
        call texture_build_mips(tex)
    end subroutine load_pbr_slot

    subroutine scene_build_object_mesh(obj)
        type(SceneObject), intent(inout) :: obj
        real(dp) :: sz, rad, hgt
        integer :: seg
        logical :: lok
        integer :: ti, tk

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
        case ('circle')
            if (rad <= 0.0_dp) rad = 1.0_dp
            if (seg <= 0) seg = 32
            call create_circle(obj%mesh, rad, seg)
        case ('ring')
            ! RADIUS = outer, SIZE = inner.
            if (rad <= 0.0_dp) rad = 1.0_dp
            if (sz <= 0.0_dp) sz = 0.5_dp
            if (seg <= 0) seg = 32
            call create_ring(obj%mesh, sz, rad, seg)
        case ('capsule')
            if (rad <= 0.0_dp) rad = 0.5_dp
            if (hgt <= 0.0_dp) hgt = 2.0_dp
            if (seg <= 0) seg = 16
            call create_capsule(obj%mesh, rad, hgt, seg)
        case ('tube')
            if (rad <= 0.0_dp) rad = 0.2_dp
            if (seg <= 0) seg = 12
            block
                real(dp), allocatable :: flat(:)
                integer :: k
                allocate(flat(3 * max(1, obj%n_pts)))
                do k = 1, obj%n_pts
                    flat(3*k-2) = obj%pts(k)%x
                    flat(3*k-1) = obj%pts(k)%y
                    flat(3*k)   = obj%pts(k)%z
                end do
                call create_tube(obj%mesh, rad, seg, flat, obj%n_pts)
                deallocate(flat)
            end block
        case ('lathe')
            if (seg <= 0) seg = 24
            block
                real(dp), allocatable :: flat(:)
                integer :: k
                allocate(flat(2 * max(1, obj%n_pts)))
                do k = 1, obj%n_pts
                    flat(2*k-1) = obj%pts(k)%x
                    flat(2*k)   = obj%pts(k)%y
                end do
                call create_lathe(obj%mesh, seg, flat, obj%n_pts)
                deallocate(flat)
            end block
        case ('extrude')
            ! HEIGHT = depth.
            if (hgt <= 0.0_dp) hgt = 0.5_dp
            block
                real(dp), allocatable :: flat(:)
                integer :: k
                allocate(flat(2 * max(1, obj%n_pts)))
                do k = 1, obj%n_pts
                    flat(2*k-1) = obj%pts(k)%x
                    flat(2*k)   = obj%pts(k)%y
                end do
                call create_extrude(obj%mesh, hgt, flat, obj%n_pts)
                deallocate(flat)
            end block
        case ('tetrahedron')
            if (rad <= 0.0_dp) rad = 1.0_dp
            call create_tetrahedron(obj%mesh, rad)
        case ('octahedron')
            if (rad <= 0.0_dp) rad = 1.0_dp
            call create_octahedron(obj%mesh, rad)
        case ('icosahedron')
            if (rad <= 0.0_dp) rad = 1.0_dp
            call create_icosahedron(obj%mesh, rad)
        case ('dodecahedron')
            if (rad <= 0.0_dp) rad = 1.0_dp
            call create_dodecahedron(obj%mesh, rad)
        case ('torusknot')
            if (rad <= 0.0_dp) rad = 1.0_dp
            if (sz <= 0.0_dp) sz = rad * 0.3_dp
            if (seg <= 0) seg = 48
            call create_torusknot(obj%mesh, rad, sz, seg, &
                                  max(6, seg / 4))
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
        ! P1 shading override (only when the object line carried an
        ! explicit 'shading' token; '' keeps the builder default).
        !   flat:   force every triangle flat -- smooth off and the
        !           per-vertex normals reset to the face normal.
        !   smooth: on curved prims only, mark every triangle smooth;
        !           the vn are already the builders' analytic vertex
        !           normals.  Flat prims have no smooth normals to
        !           apply, so they are left exactly as built.
        if (allocated(obj%mesh%triangles)) then
            if (trim(obj%shading) == 'flat') then
                do ti = 1, obj%mesh%num_triangles
                    obj%mesh%triangles(ti)%smooth = .false.
                    do tk = 1, 3
                        obj%mesh%triangles(ti)%vn(tk) = &
                            obj%mesh%triangles(ti)%normal
                    end do
                end do
            else if (trim(obj%shading) == 'smooth') then
                select case (trim(obj%prim))
                case ('sphere', 'cylinder', 'cone', 'capsule', &
                      'tube', 'lathe', 'torus', 'torusknot')
                    do ti = 1, obj%mesh%num_triangles
                        obj%mesh%triangles(ti)%smooth = .true.
                    end do
                case default
                    continue  ! flat prim: leave as built
                end select
            end if
        end if
        ! P3 mirror (only when the object line carried a valid
        ! 'mirror x|y|z' token; mirror = 0 keeps the built mesh
        ! untouched, bit-identical).
        !
        ! Transform order: the object's world transform is composed
        ! in main from mat4_compose_trs, i.e.
        !   model = T * Ry * Rx * Rz * S
        ! and the mirror must act in LOCAL space BEFORE that scale /
        ! rotation / translation, giving an effective
        !   model = T * Ry * Rx * Rz * S * REFLECT,
        ! a reflection across the named axis through the object's
        ! local origin.  This routine owns the local mesh (there is
        ! no model matrix here -- main composes it per frame), so
        ! REFLECT is applied to the built local mesh itself via
        ! mesh_add_transformed, which is exactly REFLECT * p for
        ! every local vertex p and therefore identical to composing
        ! it into the model matrix.  Doing it here (rather than in
        ! main's model) also keeps the renderer's screen-space
        ! backface culling correct: the reflection matrix has
        ! negative determinant, and mesh_add_transformed swaps
        ! vertices 2/3 of each triangle for such matrices, so the
        ! stored mesh keeps the unmirrored winding convention and
        ! main's positive-determinant model renders it normally.
        if (obj%mirror /= 0 .and. allocated(obj%mesh%triangles) &
            .and. obj%mesh%num_triangles > 0) then
            block
                type(Mesh) :: refl_mesh
                call mesh_add_transformed(refl_mesh, obj%mesh, &
                    mat4_reflect_axis(obj%mirror), .false., &
                    [0, 0, 0], 0)
                call free_mesh(obj%mesh)
                obj%mesh%num_triangles = refl_mesh%num_triangles
                call move_alloc(refl_mesh%triangles, &
                                obj%mesh%triangles)
            end block
        end if
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
        ! Phase 9 S1: the len=256 result is a genuine format limit
        ! (see TOKEN_LEN); a dir+path that cannot fit is truncated
        ! by the assignment into res below, so warn on stderr
        ! instead of truncating silently.
        if (len_trim(dir) > 0) then
            if (len_trim(dir) + 1 + len_trim(path) > len(res)) then
                write(0, *) 'scene: warning: resolved path longer ', &
                    'than 256 characters, truncated: ', trim(path)
            end if
        end if
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
        ! Phase 9 S1 audit of reader caps: the 2048-char line buffer
        ! is a genuine format limit (the longest legitimate line,
        ! a tube/lathe point list or a shaderdef, is bounded by the
        ! token storage below, not by any emitter line); a line
        ! that fills it completely is warned about on stderr in
        ! the read loop instead of being silently truncated.
        character(len=2048) :: line
        ! Phase 9 S1: 'tokens' is the module-owned heap scratch
        ! declared at module scope (initial capacity
        ! TOKENS_INITIAL_CAP, doubled on demand in the read loop,
        ! freed by scene_free).  tok_tmp is the grow-step buffer.
        character(len=TOKEN_LEN), allocatable :: tok_tmp(:)
        integer :: ntok_raw, longest_tok, new_tok_cap
        type(SceneObject) :: obj
        type(SceneAnim) :: anim
        type(SceneSprite) :: spr
        type(SceneText) :: txt
        type(SceneParticles) :: prt
        type(KeyTrack) :: trk
        type(KeyFrame) :: kf
        integer :: cur_track  ! track index receiving 'key' lines
        ! S2: per-track key counts while loading (append_key grows
        ! keys with spare capacity; counts live here until the keys
        ! are trimmed to exact size after the read loop).
        ! Phase 9 S1: was a fixed key_counts(4096), which silently
        ! stopped recording keys beyond track 4096; now heap
        ! storage, doubled whenever the track count outgrows it
        ! (see the 'keys' case), and freed at the end of the load.
        integer, allocatable :: key_counts(:)
        integer :: cap_key_counts
        type(vec3) :: cam_pos, cam_tgt, cam_up
        real(dp) :: aspect
        integer :: cur_tris  ! object index receiving 'tri' lines, 0 = none
        ! Wave A locals
        character(len=512) :: scene_dir
        ! Phase 9 S1: was extra_lights(32); point/spot lights past
        ! 32 fell through to warn_line and were dropped.  Now heap
        ! storage doubled on demand (cap_extra), freed after the
        ! LightSet assembly below.
        type(Light3), allocatable :: extra_lights(:)
        integer :: cap_extra
        type(Light3) :: lt
        integer :: n_extra, slash, oi
        logical :: tex_ok
        ! Wave E locals: shader defs are parsed in-line; bindings,
        ! morphs and skins are PENDING (they name objects/bones that
        ! may be defined later in the file) and resolved after the
        ! read loop, before the LightSet assembly.
        ! Phase 9 S1: def_list(64), bone_list(64) and the pending
        ! bind/morph/skin lists (256 each) silently dropped every
        ! entry past their fixed size (a bare 'if (n < cap)' with
        ! no else).  All are now heap storage doubled on demand
        ! (cap_*), freed at the end of the load after resolution.
        type(SceneShaderDef), allocatable :: def_list(:)
        integer :: n_defs, cap_defs
        type(SceneBone), allocatable :: bone_list(:)
        integer :: n_bones, cap_bones
        character(len=64), allocatable :: bind_obj(:), bind_shader(:)
        integer :: n_binds, cap_binds
        character(len=64), allocatable :: morph_obj(:)
        character(len=32), allocatable :: morph_kind(:)
        real(dp), allocatable :: morph_factor(:)
        integer :: n_morphs, cap_morphs
        character(len=64), allocatable :: skin_obj(:), skin_bone(:)
        integer :: n_skins, cap_skins
        ! Phase 9 S1: was rtoks(512), silently capping a shaderdef
        ! at 512 RPN tokens; now allocated per line at exactly the
        ! token count the line declares (bounded by ntok).
        character(len=64), allocatable :: rtoks(:)
        type(ShaderProg) :: tmp_prog
        logical :: parse_ok
        character(len=256) :: parse_err
        integer :: j, bi
        type(Mesh) :: new_mesh
        logical :: cam_degen_warned

        ok = .true.
        cam_degen_warned = .false.
        errmsg = ''
        cur_tris = 0
        cur_track = 0
        cap_key_counts = 0
        n_extra = 0
        cap_extra = 0
        n_defs = 0
        cap_defs = 0
        n_bones = 0
        cap_bones = 0
        n_binds = 0
        cap_binds = 0
        n_morphs = 0
        cap_morphs = 0
        n_skins = 0
        cap_skins = 0
        scene_dir = ''
        slash = index(trim(path), '/', back=.true.)
        if (slash > 1) scene_dir = path(1:slash - 1)

        ! Reset to format defaults.
        call scene_free(sc)
        sc = Scene()
        ! Phase 9 S1: scene_free just released the token scratch;
        ! allocate it at its initial capacity (grown x2 in the
        ! read loop when a line has more tokens).
        allocate(tokens(TOKENS_INITIAL_CAP))
        tokens_cap = TOKENS_INITIAL_CAP
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
            ! Phase 9 S1: a line that fills the 2048-char buffer
            ! exactly may have been truncated by the read; warn on
            ! stderr (kept cap, see the line declaration) instead
            ! of parsing a silently shortened line.
            if (len_trim(line) == len(line)) then
                write(0, *) 'scene: warning: line ', lineno, &
                    ' reaches the 2048-character line limit and ', &
                    'may have been truncated'
            end if
            ! Phase 9 S1: grow the token scratch (x2) BEFORE
            ! splitting, so split_line never clamps a long line.
            call count_line_tokens(line, ntok_raw, longest_tok)
            if (longest_tok > TOKEN_LEN) then
                write(0, *) 'scene: warning: line ', lineno, &
                    ' has a token longer than 256 characters ', &
                    '(documented format limit); it will be ', &
                    'truncated'
            end if
            if (ntok_raw > tokens_cap) then
                new_tok_cap = tokens_cap
                do while (new_tok_cap < ntok_raw)
                    new_tok_cap = 2 * new_tok_cap
                end do
                allocate(tok_tmp(new_tok_cap))
                tok_tmp = ''
                call move_alloc(tok_tmp, tokens)
                tokens_cap = new_tok_cap
            end if
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
                    ! M1 diagnostic (v3.0 Phase 5): a degenerate
                    ! camera (eye == target, or up parallel to the
                    ! view direction) silently took mat4_look_at's
                    ! fallback up; warn once per load, located at
                    ! the camera line.  Warning only -- the camera
                    ! built above is unchanged.
                    if (.not. cam_degen_warned .and. &
                        camera_view_status(cam_pos, cam_tgt, &
                            cam_up) == CAMERA_VIEW_DEGENERATE) then
                        cam_degen_warned = .true.
                        print *, 'scene: warning: degenerate ', &
                            'camera at line ', lineno, &
                            ': eye == target or up parallel to ', &
                            'the view direction'
                    end if
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
                         trim(tokens(2)) == 'point') then
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
                    if (n_extra >= cap_extra) then
                        block
                            type(Light3), allocatable :: tmp_lights(:)
                            integer :: new_cap
                            new_cap = max(8, 2 * cap_extra)
                            allocate(tmp_lights(new_cap))
                            if (n_extra > 0) &
                                tmp_lights(1:n_extra) = &
                                    extra_lights(1:n_extra)
                            if (allocated(extra_lights)) &
                                deallocate(extra_lights)
                            call move_alloc(tmp_lights, extra_lights)
                            cap_extra = new_cap
                        end block
                    end if
                    n_extra = n_extra + 1
                    extra_lights(n_extra) = lt
                    sc%has_env = .true.
                else if (ntok >= 16 .and. &
                         trim(tokens(2)) == 'spot') then
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
                    if (n_extra >= cap_extra) then
                        block
                            type(Light3), allocatable :: tmp_lights(:)
                            integer :: new_cap
                            new_cap = max(8, 2 * cap_extra)
                            allocate(tmp_lights(new_cap))
                            if (n_extra > 0) &
                                tmp_lights(1:n_extra) = &
                                    extra_lights(1:n_extra)
                            if (allocated(extra_lights)) &
                                deallocate(extra_lights)
                            call move_alloc(tmp_lights, extra_lights)
                            cap_extra = new_cap
                        end block
                    end if
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
            case ('shadow_pcf')
                ! shadow_pcf N (v3.0 Phase 3; v3 path only)
                if (ntok >= 2) sc%shadow_pcf = tok_int(tokens, 2)
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
                        ! v3.0 Phase 4: magic-sniffing dispatch
                        ! (PPM loads exactly as texture_load_ppm
                        ! did; PNG base textures now load too).
                        call texture_load(trim(o%texture_path), &
                                          o%tex, tex_ok)
                        if (.not. tex_ok) print *, &
                            'scene: warning: cannot load texture ', &
                            trim(o%texture_path)
                    end if
                end associate
                sc%has_env = .true.
            case ('objtex')
                ! objtex NAME SLOT PATH   (v3.0 Phase 4; SLOT in
                ! normal | mr | emissive | occlusion).  Only the
                ! resolved path is stored here; the texture itself
                ! is loaded by the post-pass after the read loop
                ! (see below), exactly like %texture_path feeds
                ! %tex.  Unknown slots / objects warn, never crash
                ! (the unknown-line behaviour of this reader).
                if (ntok < 4) then
                    call warn_line(lineno, line)
                    cycle
                end if
                oi = scene_find_object(sc, trim(tokens(2)))
                if (oi == 0) then
                    call warn_line(lineno, line)
                    cycle
                end if
                associate (o => sc%objects(oi))
                    select case (trim(tokens(3)))
                    case ('normal')
                        o%normal_path = resolve_scene_path( &
                            scene_dir, trim(tokens(4)))
                    case ('mr')
                        o%mr_path = resolve_scene_path( &
                            scene_dir, trim(tokens(4)))
                    case ('emissive')
                        o%emissive_map_path = resolve_scene_path( &
                            scene_dir, trim(tokens(4)))
                    case ('occlusion')
                        o%occl_path = resolve_scene_path( &
                            scene_dir, trim(tokens(4)))
                    case default
                        call warn_line(lineno, line)
                    end select
                end associate
            case ('objalpha')
                ! objalpha NAME MODE CUTOFF OPACITY  (v3.0 Phase 4;
                ! MODE integer 0/1/2, CUTOFF and OPACITY reals).
                if (ntok < 5) then
                    call warn_line(lineno, line)
                    cycle
                end if
                oi = scene_find_object(sc, trim(tokens(2)))
                if (oi == 0) then
                    call warn_line(lineno, line)
                    cycle
                end if
                associate (o => sc%objects(oi))
                    o%pbr%alpha_mode = tok_int(tokens, 3)
                    o%pbr%alpha_cutoff = tok_real(tokens, 4)
                    o%pbr%opacity = tok_real(tokens, 5)
                end associate
                sc%has_env = .true.
            case ('objemissive')
                ! objemissive NAME R G B  (v3.0 Phase 4; reals
                ! 0..1, the objmat float style).
                if (ntok < 5) then
                    call warn_line(lineno, line)
                    cycle
                end if
                oi = scene_find_object(sc, trim(tokens(2)))
                if (oi == 0) then
                    call warn_line(lineno, line)
                    cycle
                end if
                associate (o => sc%objects(oi))
                    o%pbr%emissive = [tok_real(tokens, 3), &
                                      tok_real(tokens, 4), &
                                      tok_real(tokens, 5)]
                end associate
                sc%has_env = .true.
            case ('frames')
                if (ntok >= 2) sc%frames = tok_int(tokens, 2)
            case ('fps')
                ! fps N -- v3.0 Phase 5 scene-level timeline rate
                ! (additive; absent = Scene%fps stays 0 = unset).
                if (ntok >= 2) sc%fps = tok_int(tokens, 2)
            case ('antialias')
                if (ntok >= 2) sc%antialias = tok_int(tokens, 2)
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
                ! P1: optional trailing 'shading smooth|flat' at the
                ! END of the object line, after all numeric/point
                ! tokens.  Scan the trailing tokens (21+) for the
                ! literal word 'shading'; everything from that token
                ! on is NOT part of any point list, so tube/lathe
                ! point lists are parsed only up to it.
                block
                    integer :: k, sidx, midx
                    sidx = 0
                    midx = 0
                    do k = 21, ntok
                        if (sidx == 0 .and. &
                            trim(tokens(k)) == 'shading') sidx = k
                        if (midx == 0 .and. &
                            trim(tokens(k)) == 'mirror') midx = k
                    end do
                    ! P3: trailing 'mirror x|y|z' token pair, scanned
                    ! the same way as 'shading'.  An unknown axis
                    ! value warns and leaves mirror = 0, mirroring
                    ! the unknown-shading-value behaviour below.
                    if (midx > 0) then
                        if (midx < ntok) then
                            select case (trim(tokens(midx + 1)))
                            case ('x')
                                obj%mirror = 1
                            case ('y')
                                obj%mirror = 2
                            case ('z')
                                obj%mirror = 3
                            case default
                                print *, 'scene: warning: unknown ', &
                                    'mirror value "', &
                                    trim(tokens(midx + 1)), &
                                    '" for object ', trim(obj%name), &
                                    ': ignored'
                            end select
                        else
                            print *, 'scene: warning: mirror ', &
                                'without a value for object ', &
                                trim(obj%name), ': ignored'
                        end if
                    end if
                    if (sidx > 0) then
                        if (sidx < ntok) then
                            if (trim(tokens(sidx + 1)) == 'smooth' &
                                .or. trim(tokens(sidx + 1)) == &
                                     'flat') then
                                obj%shading = trim(tokens(sidx + 1))
                            else
                                print *, 'scene: warning: unknown ', &
                                    'shading value "', &
                                    trim(tokens(sidx + 1)), &
                                    '" for object ', trim(obj%name), &
                                    ': ignored'
                            end if
                        else
                            print *, 'scene: warning: shading ', &
                                'without a value for object ', &
                                trim(obj%name), ': ignored'
                        end if
                    end if
                    ! Wave D: trailing point tokens (21+) for tube
                    ! (x,y,z triples) and lathe/extrude (x,y pairs),
                    ! bounded by the first modifier token ('shading'
                    ! or 'mirror') when present.
                    block
                        integer :: step, ntok_pts
                        ntok_pts = ntok
                        if (sidx > 0) ntok_pts = min(ntok_pts, sidx - 1)
                        if (midx > 0) ntok_pts = min(ntok_pts, midx - 1)
                        if (ntok_pts > 20) then
                            if (trim(obj%prim) == 'tube') then
                                step = 3
                            else
                                step = 2
                            end if
                            obj%n_pts = (ntok_pts - 20) / step
                            if (obj%n_pts > 0) then
                                allocate(obj%pts(obj%n_pts))
                                do k = 1, obj%n_pts
                                    obj%pts(k)%x = &
                                        tok_real(tokens, 20 + (k-1)*step + 1)
                                    obj%pts(k)%y = &
                                        tok_real(tokens, 20 + (k-1)*step + 2)
                                    if (step == 3) then
                                        obj%pts(k)%z = &
                                            tok_real(tokens, 20 + k*step)
                                    else
                                        obj%pts(k)%z = 0.0_dp
                                    end if
                                end do
                            end if
                        end if
                    end block
                end block
                call scene_build_object_mesh(obj)
                call append_object(sc, obj)
                call free_mesh(obj%mesh)
                if (allocated(obj%pts)) deallocate(obj%pts)
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
                cur_tris = sc%n_objects
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
                ! Phase 9 S1: SceneText%content is len=256, a
                ! genuine format limit (rest_after_tokens returns
                ! len=256 too); a content that fills it exactly may
                ! have been truncated, so warn on stderr.
                if (len_trim(txt%content) == len(txt%content)) then
                    write(0, *) 'scene: warning: text content at ', &
                        'line ', lineno, ' reaches the ', &
                        '256-character limit and may have been ', &
                        'truncated'
                end if
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
                ! keys TARGET DURATION LOOP NKEYS [fps FPS]
                ! (5 tokens; the optional Phase 5 token pair makes
                ! key times/duration FRAME NUMBERS for this track)
                if (ntok < 5) then
                    call warn_line(lineno, line)
                    cycle
                end if
                trk = KeyTrack()
                trk%target = trim(tokens(2))
                trk%duration = tok_real(tokens, 3)
                trk%loop = trim(tokens(4))
                if (ntok >= 7 .and. trim(tokens(6)) == 'fps') &
                    trk%fps = tok_real(tokens, 7)
                call append_track(sc, trk)
                if (allocated(trk%keys)) deallocate(trk%keys)
                cur_track = sc%n_tracks
                ! Phase 9 S1: grow key_counts (x2) to the track
                ! count; nested ifs because .and. does not
                ! short-circuit and key_counts may be unallocated.
                if (cur_track >= 1) then
                    if (cur_track > cap_key_counts) then
                        block
                            integer, allocatable :: tmp_counts(:)
                            integer :: new_cap
                            new_cap = max(64, 2 * cap_key_counts)
                            do while (new_cap < cur_track)
                                new_cap = 2 * new_cap
                            end do
                            allocate(tmp_counts(new_cap))
                            tmp_counts = 0
                            if (cap_key_counts > 0) &
                                tmp_counts(1:cap_key_counts) = &
                                    key_counts(1:cap_key_counts)
                            if (allocated(key_counts)) &
                                deallocate(key_counts)
                            call move_alloc(tmp_counts, key_counts)
                            cap_key_counts = new_cap
                        end block
                    end if
                    key_counts(cur_track) = 0
                end if
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
                ! v3.0 Phase 5: rotation is authored as Euler
                ! (above, the storage form) and stored ALSO as a
                ! quaternion, the runtime interpolation form used
                ! by key_eval_q (authored-as-Euler / stored-as-
                ! quaternion per the Phase 5 plan).
                kf%rot_quat = quat_from_euler(vec3_create( &
                    kf%rot_deg(1), kf%rot_deg(2), kf%rot_deg(3)))
                kf%has_quat = .true.
                ! Nested ifs: .and. does not short-circuit, so
                ! key_counts(cur_track) must only be indexed once
                ! cur_track is known to be within its capacity.
                if (cur_track >= 1) then
                    if (cur_track <= cap_key_counts) then
                        call append_key(sc%tracks(cur_track), kf, &
                                        key_counts(cur_track))
                    end if
                end if
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
                ! Phase 9 S1: the 16-entry chain is a genuine
                ! format limit -- Scene%post_names/post_amounts are
                ! fixed (16) fields of the Scene type that main
                ! reads directly -- so the cap stays, but hitting
                ! it now warns on stderr instead of silently
                ! dropping the filter.
                if (sc%n_post < 16) then
                    sc%n_post = sc%n_post + 1
                    sc%post_names(sc%n_post) = trim(tokens(2))
                    sc%post_amounts(sc%n_post) = tok_real(tokens, 3)
                else
                    write(0, *) 'scene: warning: post chain is ', &
                        'full (16 filters, format limit); ', &
                        'ignoring post at line ', lineno
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
            case ('shaderdef')
                ! shaderdef NAME NTOK tok1 ... tokN (Wave E, C2).
                ! Phase 9 S1: RPN tokens are bounded only by the
                ! (growable) tokens on the line; rtoks is allocated
                ! per line at exactly the declared count.
                if (ntok < 3) then
                    call warn_line(lineno, line)
                    cycle
                end if
                count = max(0, min(tok_int(tokens, 3), ntok - 3))
                if (allocated(rtoks)) deallocate(rtoks)
                allocate(rtoks(max(1, count)))
                rtoks = ''
                do j = 1, count
                    rtoks(j) = trim(tokens(3 + j))
                end do
                call shader_parse(rtoks(1:max(1, count)), tmp_prog, &
                                  parse_ok, parse_err)
                deallocate(rtoks)
                if (.not. parse_ok) then
                    call warn_line(lineno, line)
                    cycle
                end if
                if (n_defs >= cap_defs) then
                    block
                        type(SceneShaderDef), allocatable :: tmp_defs(:)
                        integer :: new_cap
                        new_cap = max(8, 2 * cap_defs)
                        allocate(tmp_defs(new_cap))
                        if (n_defs > 0) &
                            tmp_defs(1:n_defs) = def_list(1:n_defs)
                        if (allocated(def_list)) deallocate(def_list)
                        call move_alloc(tmp_defs, def_list)
                        cap_defs = new_cap
                    end block
                end if
                n_defs = n_defs + 1
                def_list(n_defs)%name = trim(tokens(2))
                def_list(n_defs)%prog = tmp_prog
            case ('shaderbind')
                ! shaderbind OBJ SHADER (Wave E, C2; pending).
                if (ntok < 3) then
                    call warn_line(lineno, line)
                    cycle
                end if
                if (n_binds >= cap_binds) then
                    block
                        character(len=64), allocatable :: tmp_o(:), &
                            tmp_s(:)
                        integer :: new_cap
                        new_cap = max(8, 2 * cap_binds)
                        allocate(tmp_o(new_cap))
                        allocate(tmp_s(new_cap))
                        if (n_binds > 0) then
                            tmp_o(1:n_binds) = bind_obj(1:n_binds)
                            tmp_s(1:n_binds) = bind_shader(1:n_binds)
                        end if
                        if (allocated(bind_obj)) deallocate(bind_obj)
                        if (allocated(bind_shader)) &
                            deallocate(bind_shader)
                        call move_alloc(tmp_o, bind_obj)
                        call move_alloc(tmp_s, bind_shader)
                        cap_binds = new_cap
                    end block
                end if
                n_binds = n_binds + 1
                bind_obj(n_binds) = trim(tokens(2))
                bind_shader(n_binds) = trim(tokens(3))
            case ('morph')
                ! morph OBJ KIND FACTOR (Wave E, C1; pending).
                if (ntok < 4) then
                    call warn_line(lineno, line)
                    cycle
                end if
                if (n_morphs >= cap_morphs) then
                    block
                        character(len=64), allocatable :: tmp_o(:)
                        character(len=32), allocatable :: tmp_k(:)
                        real(dp), allocatable :: tmp_f(:)
                        integer :: new_cap
                        new_cap = max(8, 2 * cap_morphs)
                        allocate(tmp_o(new_cap))
                        allocate(tmp_k(new_cap))
                        allocate(tmp_f(new_cap))
                        if (n_morphs > 0) then
                            tmp_o(1:n_morphs) = morph_obj(1:n_morphs)
                            tmp_k(1:n_morphs) = morph_kind(1:n_morphs)
                            tmp_f(1:n_morphs) = &
                                morph_factor(1:n_morphs)
                        end if
                        if (allocated(morph_obj)) deallocate(morph_obj)
                        if (allocated(morph_kind)) &
                            deallocate(morph_kind)
                        if (allocated(morph_factor)) &
                            deallocate(morph_factor)
                        call move_alloc(tmp_o, morph_obj)
                        call move_alloc(tmp_k, morph_kind)
                        call move_alloc(tmp_f, morph_factor)
                        cap_morphs = new_cap
                    end block
                end if
                n_morphs = n_morphs + 1
                morph_obj(n_morphs) = trim(tokens(2))
                morph_kind(n_morphs) = trim(tokens(3))
                morph_factor(n_morphs) = tok_real(tokens, 4)
            case ('bone')
                ! bone NAME px py pz rx ry rz radius (Wave E, C1).
                if (ntok < 9) then
                    call warn_line(lineno, line)
                    cycle
                end if
                if (n_bones >= cap_bones) then
                    block
                        type(SceneBone), allocatable :: tmp_bones(:)
                        integer :: new_cap
                        new_cap = max(8, 2 * cap_bones)
                        allocate(tmp_bones(new_cap))
                        if (n_bones > 0) &
                            tmp_bones(1:n_bones) = bone_list(1:n_bones)
                        if (allocated(bone_list)) deallocate(bone_list)
                        call move_alloc(tmp_bones, bone_list)
                        cap_bones = new_cap
                    end block
                end if
                n_bones = n_bones + 1
                bone_list(n_bones)%name = trim(tokens(2))
                bone_list(n_bones)%pivot = tok_vec3(tokens, 3)
                bone_list(n_bones)%rot_deg = tok_vec3(tokens, 6)
                bone_list(n_bones)%radius = tok_real(tokens, 9)
            case ('skin')
                ! skin OBJ BONENAME (Wave E, C1; pending).
                if (ntok < 3) then
                    call warn_line(lineno, line)
                    cycle
                end if
                if (n_skins >= cap_skins) then
                    block
                        character(len=64), allocatable :: tmp_o(:), &
                            tmp_b(:)
                        integer :: new_cap
                        new_cap = max(8, 2 * cap_skins)
                        allocate(tmp_o(new_cap))
                        allocate(tmp_b(new_cap))
                        if (n_skins > 0) then
                            tmp_o(1:n_skins) = skin_obj(1:n_skins)
                            tmp_b(1:n_skins) = skin_bone(1:n_skins)
                        end if
                        if (allocated(skin_obj)) deallocate(skin_obj)
                        if (allocated(skin_bone)) deallocate(skin_bone)
                        call move_alloc(tmp_o, skin_obj)
                        call move_alloc(tmp_b, skin_bone)
                        cap_skins = new_cap
                    end block
                end if
                n_skins = n_skins + 1
                skin_obj(n_skins) = trim(tokens(2))
                skin_bone(n_skins) = trim(tokens(3))
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

        ! Wave E: resolve pending shader bindings, morphs and skins
        ! now that every object/bone/definition exists. Unknown
        ! names are skipped with a printed warning, never a crash
        ! (the compiler rejects them first with E201; this guards
        ! hand-written .scene files).
        if (n_defs > 0) then
            allocate(sc%shader_defs(n_defs))
            do i = 1, n_defs
                sc%shader_defs(i) = def_list(i)
            end do
        end if
        if (n_bones > 0) then
            allocate(sc%bones(n_bones))
            do i = 1, n_bones
                sc%bones(i) = bone_list(i)
            end do
        end if
        do i = 1, n_binds
            oi = scene_find_object(sc, trim(bind_obj(i)))
            if (oi == 0) then
                print *, 'scene: warning: shaderbind for unknown ', &
                    'object ', trim(bind_obj(i))
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
                print *, 'scene: warning: shaderbind names unknown ', &
                    'shader ', trim(bind_shader(i))
                cycle
            end if
            sc%objects(oi)%has_shader = .true.
            sc%objects(oi)%shader_name = trim(bind_shader(i))
            sc%objects(oi)%shader_prog = sc%shader_defs(bi)%prog
        end do
        do i = 1, n_morphs
            oi = scene_find_object(sc, trim(morph_obj(i)))
            if (oi == 0) then
                print *, 'scene: warning: morph for unknown object ', &
                    trim(morph_obj(i))
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
                print *, 'scene: warning: skin for unknown object ', &
                    trim(skin_obj(i))
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
                print *, 'scene: warning: skin names unknown bone ', &
                    trim(skin_bone(i))
                cycle
            end if
            call skin_apply(sc%objects(oi)%mesh, &
                            sc%bones(bi)%pivot, sc%bones(bi)%rot_deg, &
                            sc%bones(bi)%radius, new_mesh)
            call free_mesh(sc%objects(oi)%mesh)
            sc%objects(oi)%mesh = new_mesh
            call free_mesh(new_mesh)
        end do

        ! Phase 9 S1 audit, verified here: object/anim/sprite/
        ! text/particle/track counts and per-track keyframes were
        ! already capacity-doubling (Phase 0 S2 append_* above);
        ! per-object point lists and 'tris' triangle arrays are
        ! allocated at exactly the count the line declares, and
        ! shader_defs/bones/LightSet items are allocated at exactly
        ! n_defs/n_bones/1 + n_extra below.  No other fixed-size
        ! array remains in the reader path.
        !
        ! S2: loading is done -- trim every capacity-doubled array
        ! back to its live count (per-track keys first, then the
        ! Scene arrays) so size() equals the count again for all
        ! readers outside the load path (key_eval reads
        ! size(track%keys); main reads the Scene arrays).
        if (allocated(sc%tracks)) then
            do i = 1, sc%n_tracks
                ! Nested if: key_counts(i) is only indexed once i
                ! is known to be within its (grown) capacity.
                if (i <= cap_key_counts) then
                    call trim_key_track(sc%tracks(i), key_counts(i))
                end if
            end do
        end if
        call scene_trim_storage(sc)

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
            do i = 1, sc%n_objects
                if (sc%objects(i)%tex%loaded .or. &
                    trim(sc%objects(i)%mat_name) == 'standard') &
                    sc%has_env = .true.
            end do
        end if

        ! Materials for 'tris' objects (their colours live per-triangle).
        if (allocated(sc%objects)) then
            do i = 1, sc%n_objects
                if (trim(sc%objects(i)%prim) == 'tris') &
                    call set_object_material(sc%objects(i))
            end do
        end if

        ! v3.0 Phase 4: texture-slot loading post-pass.  The
        ! 'objtex' lines only stored resolved paths (mirroring how
        ! %texture_path feeds %tex); load them now that every
        ! object exists.  The emissive map is a colour map (sRGB);
        ! normal / metallic-roughness / occlusion maps are linear
        ! data (no sRGB decode).
        if (allocated(sc%objects)) then
            do i = 1, sc%n_objects
                associate (o => sc%objects(i))
                    if (o%tex%loaded) call texture_build_mips(o%tex)
                    call load_pbr_slot(o%normal_path, o%tex_normal, &
                                       .false.)
                    call load_pbr_slot(o%mr_path, o%tex_mr, .false.)
                    call load_pbr_slot(o%emissive_map_path, &
                                       o%tex_emissive, .true.)
                    call load_pbr_slot(o%occl_path, o%tex_occl, &
                                       .false.)
                end associate
            end do
        end if

        ! Phase 9 S1: release every load-local heap array grown
        ! above (their contents have been copied into the Scene by
        ! the resolution passes and the LightSet assembly).  The
        ! token scratch is NOT freed here: it is module-owned and
        ! is released by scene_free (see TOKENS_INITIAL_CAP).
        if (allocated(key_counts)) deallocate(key_counts)
        if (allocated(extra_lights)) deallocate(extra_lights)
        if (allocated(def_list)) deallocate(def_list)
        if (allocated(bone_list)) deallocate(bone_list)
        if (allocated(bind_obj)) deallocate(bind_obj)
        if (allocated(bind_shader)) deallocate(bind_shader)
        if (allocated(morph_obj)) deallocate(morph_obj)
        if (allocated(morph_kind)) deallocate(morph_kind)
        if (allocated(morph_factor)) deallocate(morph_factor)
        if (allocated(skin_obj)) deallocate(skin_obj)
        if (allocated(skin_bone)) deallocate(skin_bone)
        if (allocated(rtoks)) deallocate(rtoks)
    contains
        subroutine warn_line(ln, text)
            integer, intent(in) :: ln
            character(len=*), intent(in) :: text
            print *, 'scene: warning: skipping line ', ln, ': ', &
                trim(text)
        end subroutine warn_line
    end subroutine scene_load

end module scene_3d
