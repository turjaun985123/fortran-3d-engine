! timeline_ir.f90 -- Forge3D Timeline IR reader (Animation Compiler
! Wave 2, slice A4; ANIM-PLAN section 3, ADR-5).
!
! Module timeline_ir_3d: the typed, exact-version reader for the
! Timeline IR artifact the compiler emits next to a scene JSON:
!
!   build/<name>.timeline.json
!     { "format": "forge3d-timeline", "ir_version": 1,
!       "name", "fps": {"num", "den"}, "duration_frames",
!       "generator", "characters", "scenes", "tracks",
!       "dialogue", "markers" }
!
! It follows the ADR-3 pattern of scene_json_3d (src/scene_json.f90):
! a typed derived-type tree filled from the shared JSON parser
! (json_reader_3d, src/json_reader.f90) -- no text scanning here.
! This module is purely additive: it renders nothing, evaluates
! nothing (evaluation is Wave 3), and touches no legacy path.
!
! Reader obligations implemented here (ANIM-PLAN 3.6 / 3.7, ADR-5):
!   * format must be exactly "forge3d-timeline"; a missing or
!     different format is an error NAMING what was found.
!   * ir_version must be present and exactly 1 (exact-version
!     reader); any other version is an error NAMING the version
!     found.  Missing format / ir_version is an error, never a
!     default.
!   * Unknown keys are tolerated (ignored) at every level.
!   * Unknown track kinds are SKIPPED with a diagnostic note
!     recorded on the result (tl%n_skipped_tracks + tl%notes) --
!     never a crash, never a silent drop.
!   * Unknown ease names fall back to "linear" WITH a diagnostic
!     note (ANIM-PLAN 3.4); the closed ease registry is
!     linear/smooth/in/out/cubic-in/cubic-out/cubic-in-out/hold
!     plus the parameterised bezier(x1,y1,x2,y2) form.
!   * Integer frame sanity: frames are >= 0, every span has
!     end >= start (dialogue cues end > start, per 3.3), fps
!     num/den are positive, and a scene span may not run past the
!     timeline duration (the one duration consistency that is
!     checkable from the document alone).
!   * "t_seconds" floats are informational only and are never read
!     (3.2: frame values win).  Dialogue text is byte-verbatim
!     UTF-8 from the parser; no normalisation anywhere.
!
! Required fields (absence is an error): root format, ir_version,
! name, fps{num,den}, duration_frames; per character: id; per scene
! span: id, scene_file, start_frame, duration_frames; per track:
! kind; per action/pose/camera key: frame; per dialogue cue: id,
! start_frame, end_frame, text; per marker: frame.  Everything else
! is optional and defaults as documented on the types below.
!
! Track key storage (v1): keys are stored generically as tl_key
! values -- frame + ease + the union of the v1 key shapes:
!   channel + value_deg        (action keys, 3.5)
!   pos + rot_deg + scale      (pose_keys)
!   pos + target + fov         (camera keys)
! A key sets has_* flags for exactly the shapes its JSON carried,
! so no data is invented and none is dropped for known kinds.
!
! Implementation note: bindings{} and params{} are JSON objects
! whose KEYS are data (character ids / parameter names).
! json_reader_3d exposes no key-enumeration accessor, so those two
! objects are walked through the parser's documented node-pool
! convention (an object node's children are its member values, and
! each member node's `s` holds the member key -- see the
! json_reader.f90 header).  All other access goes through the
! public json_* accessors, exactly as in scene_json.f90.
module timeline_ir_3d
    use, intrinsic :: iso_fortran_env, only: real64, int64
    use json_reader_3d
    implicit none
    private

    public :: tl_kv, tl_character, tl_wear, tl_scene_span, tl_key, tl_track
    public :: tl_dialogue_cue, tl_marker, tl_timeline
    public :: read_timeline, timeline_free
    public :: TL_IR_VERSION, TL_MAX_NOTES

    integer, parameter :: TL_IR_VERSION = 1
    ! Diagnostic notes are capped; the skipped-track COUNT is not
    ! (it keeps counting even after the note log fills).
    integer, parameter :: TL_MAX_NOTES = 64

    integer, parameter :: TK_NULL = 0, TK_BOOL = 1, TK_NUM = 2, &
                          TK_STR = 3, TK_ARR = 4, TK_OBJ = 5

    ! One key/value pair (scene bindings, track params).  Param
    ! values are stored in their text form (numbers via a plain
    ! decimal rendering, booleans as true/false): params are
    ! provenance in v1 (3.4), the resolved keys are normative.
    type, public :: tl_kv
        character(len=:), allocatable :: key
        character(len=:), allocatable :: value
    end type tl_kv

    type, public :: tl_character
        character(len=:), allocatable :: id
        character(len=:), allocatable :: name        ! '' if absent
        integer :: color(3) = 0                      ! 0-255 per channel
        logical :: has_color = .false.
        character(len=:), allocatable :: plugin      ! plugin id, '' if absent
        character(len=:), allocatable :: rig_kind    ! rig.kind, '' if absent
        character(len=:), allocatable :: rig_topology
        character(len=:), allocatable :: voice_speaker  ! voice.speaker
        ! Wave 3 (additive): proportions{} + identity{} records,
        ! consumed by the engine film evaluator (timeline_eval_3d).
        character(len=:), allocatable :: proportions_word  ! '' if absent
        logical :: has_height = .false.
        real(real64) :: height = 0.0_real64
        character(len=:), allocatable :: id_head   ! identity.head
        character(len=:), allocatable :: id_hair   ! identity.hair
        character(len=:), allocatable :: id_face   ! identity.face
        character(len=:), allocatable :: id_holds  ! identity.holds
        type(tl_wear), allocatable :: wears(:)     ! identity.wears
        integer :: n_wears = 0
    end type tl_character

    ! One identity.wears entry: {item, colour} (colour name verbatim).
    type, public :: tl_wear
        character(len=:), allocatable :: item
        character(len=:), allocatable :: colour
    end type tl_wear

    type, public :: tl_scene_span
        character(len=:), allocatable :: id
        character(len=:), allocatable :: name
        character(len=:), allocatable :: scene_file
        integer :: scene_ir_version = -1   ! -1 = not pinned in file
        integer :: start_frame = 0
        integer :: duration_frames = 0
        integer :: end_frame = 0           ! start + duration (derived)
        type(tl_kv), allocatable :: bindings(:)
        integer :: n_bindings = 0
        ! Wave 3 (additive): transition{} record (kind +
        ! duration_frames); absent = cut (TIMELINE-FORMAT).
        logical :: has_transition = .false.
        character(len=:), allocatable :: transition_kind
        integer :: transition_duration_frames = 0
    end type tl_scene_span

    ! One resolved key; see the module header for the shape union.
    type, public :: tl_key
        integer :: frame = 0
        character(len=:), allocatable :: channel     ! action keys
        character(len=:), allocatable :: ease        ! 'linear' if absent
        logical :: has_value_deg = .false.
        real(real64) :: value_deg = 0.0_real64
        ! Wave 3 (additive): plain "value" (non-angle channels,
        ! e.g. root.x / face.expr action keys).
        logical :: has_value = .false.
        real(real64) :: value = 0.0_real64
        logical :: has_pos = .false.
        real(real64) :: pos(3) = 0.0_real64
        logical :: has_rot = .false.
        real(real64) :: rot_deg(3) = 0.0_real64
        logical :: has_scale = .false.
        real(real64) :: scale = 1.0_real64
        real(real64) :: scale3(3) = 1.0_real64  ! when scale was [x,y,z]
        logical :: has_target = .false.
        real(real64) :: target(3) = 0.0_real64
        logical :: has_fov = .false.
        real(real64) :: fov = 0.0_real64
    end type tl_key

    type, public :: tl_track
        character(len=:), allocatable :: kind
        character(len=:), allocatable :: scene       ! scene span id
        character(len=:), allocatable :: character   ! character id
        character(len=:), allocatable :: target      ! scene-object name
        logical :: has_start = .false.
        integer :: start_frame = 0
        logical :: has_end = .false.
        integer :: end_frame = 0
        character(len=:), allocatable :: action      ! action tracks: symbol
        logical :: has_resolved = .false.
        logical :: resolved = .true.                 ! action: resolved flag
        character(len=:), allocatable :: verb        ! verb tracks: verb name
        logical :: has_visible = .false.
        logical :: visible = .true.                  ! visibility tracks
        type(tl_kv), allocatable :: params(:)
        integer :: n_params = 0
        type(tl_key), allocatable :: keys(:)
        integer :: n_keys = 0
    end type tl_track

    type, public :: tl_dialogue_cue
        character(len=:), allocatable :: id
        character(len=:), allocatable :: scene
        integer :: start_frame = 0
        integer :: end_frame = 0
        character(len=:), allocatable :: speaker     ! character id
        character(len=:), allocatable :: text        ! byte-verbatim UTF-8
    end type tl_dialogue_cue

    type, public :: tl_marker
        integer :: frame = 0
        character(len=:), allocatable :: name
        character(len=:), allocatable :: kind        ! 'beat' | 'chapter'
    end type tl_marker

    type, public :: tl_timeline
        character(len=:), allocatable :: name
        integer :: fps_num = 0
        integer :: fps_den = 0
        integer :: duration_frames = 0
        ! Provenance only (generator{}), all '' when absent.
        character(len=:), allocatable :: gen_tool
        character(len=:), allocatable :: gen_version
        character(len=:), allocatable :: gen_source
        type(tl_character), allocatable :: characters(:)
        integer :: n_characters = 0
        type(tl_scene_span), allocatable :: scenes(:)
        integer :: n_scenes = 0
        type(tl_track), allocatable :: tracks(:)
        integer :: n_tracks = 0
        type(tl_dialogue_cue), allocatable :: dialogue(:)
        integer :: n_dialogue = 0
        type(tl_marker), allocatable :: markers(:)
        integer :: n_markers = 0
        ! Diagnostics recorded while reading (unknown track kinds,
        ! unknown ease names).  Never a substitute for ok/errmsg:
        ! hard problems are errors, these are the skippable kind.
        integer :: n_skipped_tracks = 0
        integer :: n_notes = 0
        character(len=512) :: notes(TL_MAX_NOTES) = ''
    end type tl_timeline

contains

    ! ------------------------------------------------------------------
    ! Small helpers (mirroring scene_json.f90's j_* helpers)
    ! ------------------------------------------------------------------

    subroutine t_read_file(path, text, ok, errmsg)
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
            errmsg = 'read_timeline: cannot open file: ' // trim(path)
            return
        end if
        open(newunit=u, file=trim(path), status='old', action='read', &
             access='stream', form='unformatted', iostat=ios)
        if (ios /= 0) then
            errmsg = 'read_timeline: cannot open file: ' // trim(path)
            return
        end if
        allocate(character(len=int(fsize)) :: text)
        read(u, iostat=ios) text
        close(u)
        if (ios /= 0) then
            errmsg = 'read_timeline: cannot read file: ' // trim(path)
            deallocate(text)
            return
        end if
        ok = .true.
    end subroutine t_read_file

    subroutine t_get(doc, node, key, child, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        integer, intent(out) :: child
        logical, intent(out) :: found
        child = 0
        found = .false.
        if (node <= 0) return
        if (json_kind(doc, node) /= TK_OBJ) return
        call json_obj_get(doc, node, key, child, found)
        if (.not. found) child = 0
    end subroutine t_get

    ! String field into an allocatable ('' + found=.false. when the
    ! key is absent or not a JSON string).
    subroutine t_str(doc, node, key, out, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        character(len=:), allocatable, intent(out) :: out
        logical, intent(out) :: found
        integer :: child
        logical :: f
        allocate(character(len=0) :: out)
        found = .false.
        call t_get(doc, node, key, child, f)
        if (.not. f) return
        if (json_kind(doc, child) /= TK_STR) return
        deallocate(out)
        out = json_str(doc, child)
        found = .true.
    end subroutine t_str

    function t_int(doc, node, key, def, was_present) result(v)
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
        call t_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= TK_NUM) return
        v = json_int(doc, child, def)
        if (present(was_present)) was_present = .true.
    end function t_int

    function t_num(doc, node, key, def, was_present) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        real(real64), intent(in) :: def
        logical, intent(out), optional :: was_present
        real(real64) :: v
        integer :: child
        logical :: found
        v = def
        if (present(was_present)) was_present = .false.
        call t_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= TK_NUM) return
        v = json_num(doc, child, def)
        if (present(was_present)) was_present = .true.
    end function t_num

    function t_bool(doc, node, key, def, was_present) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        logical, intent(in) :: def
        logical, intent(out), optional :: was_present
        logical :: v
        integer :: child
        logical :: found
        v = def
        if (present(was_present)) was_present = .false.
        call t_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= TK_BOOL) return
        v = json_bool(doc, child, def)
        if (present(was_present)) was_present = .true.
    end function t_bool

    ! vec3 from a JSON array field; missing components keep def.
    subroutine t_vec3(doc, node, key, v, was_present)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        character(len=*), intent(in) :: key
        real(real64), intent(inout) :: v(3)
        logical, intent(out) :: was_present
        integer :: child, elem, k
        logical :: found
        was_present = .false.
        call t_get(doc, node, key, child, found)
        if (.not. found) return
        if (json_kind(doc, child) /= TK_ARR) return
        do k = 1, min(3, json_arr_len(doc, child))
            call json_arr_at(doc, child, k, elem)
            v(k) = json_num(doc, elem, v(k))
        end do
        was_present = .true.
    end subroutine t_vec3

    subroutine add_note(tl, msg)
        type(tl_timeline), intent(inout) :: tl
        character(len=*), intent(in) :: msg
        if (tl%n_notes < TL_MAX_NOTES) then
            tl%n_notes = tl%n_notes + 1
            tl%notes(tl%n_notes) = msg
        end if
    end subroutine add_note

    ! Plain decimal rendering of a JSON number for tl_kv values.
    function num_text(x) result(s)
        real(real64), intent(in) :: x
        character(len=:), allocatable :: s
        character(len=64) :: buf
        logical :: is_int
        is_int = .false.
        if (abs(x) < 1.0e15_real64) then
            if (abs(x - real(nint(x), real64)) == 0.0_real64) &
                is_int = .true.
        end if
        if (is_int) then
            write(buf, '(I0)') nint(x)
        else
            write(buf, '(G24.16)') x
            buf = adjustl(buf)
        end if
        allocate(character(len=len_trim(buf)) :: s)
        s = trim(buf)
    end function num_text

    ! Walk an object's members (see the header note on why this uses
    ! the node pool directly) into key/value pairs.  String values
    ! are taken verbatim; numbers/booleans in text form; nested
    ! values (objects/arrays) are stored as '' -- they carry no v1
    ! meaning in bindings/params.
    subroutine t_kv_object(doc, node, pairs, n_pairs)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        type(tl_kv), allocatable, intent(out) :: pairs(:)
        integer, intent(out) :: n_pairs
        integer :: c, i
        character(len=:), allocatable :: sval
        n_pairs = 0
        if (node <= 0) return
        if (json_kind(doc, node) /= TK_OBJ) return
        n_pairs = json_obj_count(doc, node)
        allocate(pairs(max(1, n_pairs)))
        c = doc%nodes(node)%first_child
        i = 0
        do while (c /= 0 .and. i < n_pairs)
            i = i + 1
            if (allocated(doc%nodes(c)%s)) then
                allocate(character(len=len(doc%nodes(c)%s)) :: &
                         pairs(i)%key)
                pairs(i)%key = doc%nodes(c)%s
            else
                allocate(character(len=0) :: pairs(i)%key)
            end if
            select case (json_kind(doc, c))
            case (TK_STR)
                sval = json_str(doc, c)
                allocate(character(len=len(sval)) :: pairs(i)%value)
                pairs(i)%value = sval
                deallocate(sval)
            case (TK_NUM)
                pairs(i)%value = num_text(json_num(doc, c, 0.0_real64))
            case (TK_BOOL)
                if (json_bool(doc, c, .false.)) then
                    allocate(character(len=4) :: pairs(i)%value)
                    pairs(i)%value = 'true'
                else
                    allocate(character(len=5) :: pairs(i)%value)
                    pairs(i)%value = 'false'
                end if
            case default
                allocate(character(len=0) :: pairs(i)%value)
            end select
            c = doc%nodes(c)%next_sibling
        end do
        n_pairs = i
    end subroutine t_kv_object

    logical function known_track_kind(kind) result(r)
        character(len=*), intent(in) :: kind
        select case (trim(kind))
        case ('action', 'pose_keys', 'camera', 'verb', 'visibility')
            r = .true.
        case default
            r = .false.
        end select
    end function known_track_kind

    logical function known_ease(ease) result(r)
        character(len=*), intent(in) :: ease
        select case (trim(ease))
        case ('linear', 'smooth', 'in', 'out', 'cubic-in', &
              'cubic-out', 'cubic-in-out', 'hold')
            r = .true.
        case default
            r = .false.
            if (len_trim(ease) > 7) then
                if (ease(1:7) == 'bezier(') r = .true.
            end if
        end select
    end function known_ease

    ! ------------------------------------------------------------------
    ! Per-element parsers.  Each sets ok=.false. + errmsg on a hard
    ! (required-field / sanity) failure; skippable problems are
    ! handled by the caller / via add_note.
    ! ------------------------------------------------------------------

    subroutine parse_character(doc, node, ch, ok, errmsg)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        type(tl_character), intent(out) :: ch
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        integer :: sub, elem, k
        logical :: found, present
        real(real64) :: col(3)
        ok = .false.
        errmsg = ''
        ch = tl_character()
        if (json_kind(doc, node) /= TK_OBJ) then
            errmsg = 'read_timeline: character entry is not an object'
            return
        end if
        call t_str(doc, node, 'id', ch%id, found)
        if (.not. found .or. len_trim(ch%id) == 0) then
            errmsg = 'read_timeline: character missing required "id"'
            return
        end if
        call t_str(doc, node, 'name', ch%name, found)
        ! color: [r,g,b] numbers (0-255 in the excerpt; stored as-is)
        call t_get(doc, node, 'color', sub, found)
        if (found .and. json_kind(doc, sub) == TK_ARR) then
            col = 0.0_real64
            do k = 1, min(3, json_arr_len(doc, sub))
                call json_arr_at(doc, sub, k, elem)
                col(k) = json_num(doc, elem, col(k))
            end do
            ch%color = nint(col)
            ch%has_color = .true.
        end if
        ! Plugin id: "plugin": "stickman" (string form), or an
        ! object form "plugin": {"id": ...}; both name the plugin
        ! that owns this character's rig/actions (ANIM-PLAN 8).
        call t_get(doc, node, 'plugin', sub, found)
        if (found) then
            if (json_kind(doc, sub) == TK_STR) then
                ch%plugin = json_str(doc, sub)
            else if (json_kind(doc, sub) == TK_OBJ) then
                call t_str(doc, sub, 'id', ch%plugin, present)
            else
                allocate(character(len=0) :: ch%plugin)
            end if
        else
            call t_str(doc, node, 'plugin_id', ch%plugin, present)
        end if
        if (.not. allocated(ch%plugin)) &
            allocate(character(len=0) :: ch%plugin)
        ! rig {kind, topology}
        call t_get(doc, node, 'rig', sub, found)
        if (found .and. json_kind(doc, sub) == TK_OBJ) then
            call t_str(doc, sub, 'kind', ch%rig_kind, present)
            call t_str(doc, sub, 'topology', ch%rig_topology, present)
        else
            allocate(character(len=0) :: ch%rig_kind)
            allocate(character(len=0) :: ch%rig_topology)
        end if
        ! voice {speaker}
        call t_get(doc, node, 'voice', sub, found)
        if (found .and. json_kind(doc, sub) == TK_OBJ) then
            call t_str(doc, sub, 'speaker', ch%voice_speaker, present)
        else
            allocate(character(len=0) :: ch%voice_speaker)
        end if
        ! proportions {proportions: word, height: n} (Wave 3, additive)
        allocate(character(len=0) :: ch%proportions_word)
        call t_get(doc, node, 'proportions', sub, found)
        if (found .and. json_kind(doc, sub) == TK_OBJ) then
            deallocate(ch%proportions_word)
            call t_str(doc, sub, 'proportions', ch%proportions_word, &
                       present)
            if (.not. allocated(ch%proportions_word)) &
                allocate(character(len=0) :: ch%proportions_word)
            ch%height = t_num(doc, sub, 'height', 0.0_real64, &
                              ch%has_height)
        end if
        ! identity {head, hair, face, wears:[{item,colour}], holds}
        call t_get(doc, node, 'identity', sub, found)
        if (found .and. json_kind(doc, sub) == TK_OBJ) then
            call t_str(doc, sub, 'head', ch%id_head, present)
            call t_str(doc, sub, 'hair', ch%id_hair, present)
            call t_str(doc, sub, 'face', ch%id_face, present)
            call t_str(doc, sub, 'holds', ch%id_holds, present)
            block
                integer :: warr, wnode, wi
                logical :: wfound
                call t_get(doc, sub, 'wears', warr, wfound)
                if (wfound .and. json_kind(doc, warr) == TK_ARR) then
                    ch%n_wears = json_arr_len(doc, warr)
                    allocate(ch%wears(max(1, ch%n_wears)))
                    do wi = 1, ch%n_wears
                        call json_arr_at(doc, warr, wi, wnode)
                        if (json_kind(doc, wnode) == TK_OBJ) then
                            call t_str(doc, wnode, 'item', &
                                       ch%wears(wi)%item, present)
                            call t_str(doc, wnode, 'colour', &
                                       ch%wears(wi)%colour, present)
                            if (.not. allocated(ch%wears(wi)%colour)) &
                                call t_str(doc, wnode, 'color', &
                                           ch%wears(wi)%colour, present)
                        else if (json_kind(doc, wnode) == TK_STR) then
                            ch%wears(wi)%item = json_str(doc, wnode)
                            allocate(character(len=0) :: &
                                     ch%wears(wi)%colour)
                        else
                            allocate(character(len=0) :: &
                                     ch%wears(wi)%item)
                            allocate(character(len=0) :: &
                                     ch%wears(wi)%colour)
                        end if
                        if (.not. allocated(ch%wears(wi)%item)) &
                            allocate(character(len=0) :: &
                                     ch%wears(wi)%item)
                        if (.not. allocated(ch%wears(wi)%colour)) &
                            allocate(character(len=0) :: &
                                     ch%wears(wi)%colour)
                    end do
                end if
            end block
        end if
        if (.not. allocated(ch%id_head)) &
            allocate(character(len=0) :: ch%id_head)
        if (.not. allocated(ch%id_hair)) &
            allocate(character(len=0) :: ch%id_hair)
        if (.not. allocated(ch%id_face)) &
            allocate(character(len=0) :: ch%id_face)
        if (.not. allocated(ch%id_holds)) &
            allocate(character(len=0) :: ch%id_holds)
        if (.not. allocated(ch%wears)) allocate(ch%wears(0))
        ok = .true.
    end subroutine parse_character

    subroutine parse_scene_span(doc, node, tl, sp, ok, errmsg)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        type(tl_timeline), intent(in) :: tl
        type(tl_scene_span), intent(out) :: sp
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        integer :: sub
        logical :: found, has_start, has_dur
        character(len=64) :: nbuf
        ok = .false.
        errmsg = ''
        sp = tl_scene_span()
        if (json_kind(doc, node) /= TK_OBJ) then
            errmsg = 'read_timeline: scene entry is not an object'
            return
        end if
        call t_str(doc, node, 'id', sp%id, found)
        if (.not. found .or. len_trim(sp%id) == 0) then
            errmsg = 'read_timeline: scene span missing required "id"'
            return
        end if
        call t_str(doc, node, 'name', sp%name, found)
        call t_str(doc, node, 'scene_file', sp%scene_file, found)
        if (.not. found .or. len_trim(sp%scene_file) == 0) then
            errmsg = 'read_timeline: scene span "' // trim(sp%id) // &
                     '" missing required "scene_file"'
            return
        end if
        sp%scene_ir_version = t_int(doc, node, 'scene_ir_version', -1)
        sp%start_frame = t_int(doc, node, 'start_frame', -1, has_start)
        sp%duration_frames = t_int(doc, node, 'duration_frames', -1, &
                                   has_dur)
        if (.not. has_start .or. .not. has_dur) then
            errmsg = 'read_timeline: scene span "' // trim(sp%id) // &
                     '" missing required start_frame/duration_frames'
            return
        end if
        if (sp%start_frame < 0 .or. sp%duration_frames < 0) then
            write(nbuf, '(I0, A, I0)') sp%start_frame, '/', &
                sp%duration_frames
            errmsg = 'read_timeline: scene span "' // trim(sp%id) // &
                     '" has negative start/duration (' // &
                     trim(nbuf) // ')'
            return
        end if
        sp%end_frame = sp%start_frame + sp%duration_frames
        if (tl%duration_frames >= 0 .and. &
            sp%end_frame > tl%duration_frames) then
            write(nbuf, '(I0, A, I0)') sp%end_frame, ' > ', &
                tl%duration_frames
            errmsg = 'read_timeline: scene span "' // trim(sp%id) // &
                     '" ends past the timeline duration (' // &
                     trim(nbuf) // ')'
            return
        end if
        call t_get(doc, node, 'bindings', sub, found)
        if (found) then
            call t_kv_object(doc, sub, sp%bindings, sp%n_bindings)
        else
            allocate(sp%bindings(0))
            sp%n_bindings = 0
        end if
        ! transition {kind, duration_frames} (Wave 3, additive)
        allocate(character(len=0) :: sp%transition_kind)
        call t_get(doc, node, 'transition', sub, found)
        if (found .and. json_kind(doc, sub) == TK_OBJ) then
            deallocate(sp%transition_kind)
            call t_str(doc, sub, 'kind', sp%transition_kind, has_start)
            if (.not. allocated(sp%transition_kind)) &
                allocate(character(len=0) :: sp%transition_kind)
            sp%transition_duration_frames = &
                t_int(doc, sub, 'duration_frames', 0)
            sp%has_transition = len_trim(sp%transition_kind) > 0
        end if
        ok = .true.
    end subroutine parse_scene_span

    subroutine parse_key(doc, node, key, ok, errmsg)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        type(tl_key), intent(out) :: key
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        integer :: sub, elem
        logical :: found, has_frame
        real(real64) :: v3(3)
        character(len=64) :: nbuf
        ok = .false.
        errmsg = ''
        key = tl_key()
        if (json_kind(doc, node) /= TK_OBJ) then
            errmsg = 'read_timeline: track key is not an object'
            return
        end if
        key%frame = t_int(doc, node, 'frame', -1, has_frame)
        if (.not. has_frame) then
            errmsg = 'read_timeline: track key missing required "frame"'
            return
        end if
        if (key%frame < 0) then
            write(nbuf, '(I0)') key%frame
            errmsg = 'read_timeline: track key has negative frame ' &
                     // trim(nbuf)
            return
        end if
        call t_str(doc, node, 'channel', key%channel, found)
        call t_str(doc, node, 'ease', key%ease, found)
        if (.not. found) then
            deallocate(key%ease)
            allocate(character(len=6) :: key%ease)
            key%ease = 'linear'
        end if
        key%value_deg = t_num(doc, node, 'value_deg', 0.0_real64, &
                              key%has_value_deg)
        key%value = t_num(doc, node, 'value', 0.0_real64, &
                          key%has_value)
        v3 = 0.0_real64
        call t_vec3(doc, node, 'pos', v3, key%has_pos)
        if (key%has_pos) key%pos = v3
        v3 = 0.0_real64
        call t_vec3(doc, node, 'rot_deg', v3, key%has_rot)
        if (.not. key%has_rot) call t_vec3(doc, node, 'rot', v3, &
                                           key%has_rot)
        if (key%has_rot) key%rot_deg = v3
        ! scale: scalar, or [x,y,z] (scalar view = x component)
        call t_get(doc, node, 'scale', sub, found)
        if (found) then
            if (json_kind(doc, sub) == TK_NUM) then
                key%scale = json_num(doc, sub, 1.0_real64)
                key%scale3 = key%scale
                key%has_scale = .true.
            else if (json_kind(doc, sub) == TK_ARR) then
                v3 = 1.0_real64
                block
                    integer :: k
                    do k = 1, min(3, json_arr_len(doc, sub))
                        call json_arr_at(doc, sub, k, elem)
                        v3(k) = json_num(doc, elem, v3(k))
                    end do
                end block
                key%scale3 = v3
                key%scale = v3(1)
                key%has_scale = .true.
            end if
        end if
        v3 = 0.0_real64
        call t_vec3(doc, node, 'target', v3, key%has_target)
        if (key%has_target) key%target = v3
        key%fov = t_num(doc, node, 'fov', 0.0_real64, key%has_fov)
        ok = .true.
    end subroutine parse_key

    subroutine parse_track(doc, node, tl, trk, ok, errmsg)
        type(json_doc), intent(inout) :: doc
        integer, intent(in) :: node
        type(tl_timeline), intent(inout) :: tl
        type(tl_track), intent(out) :: trk
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        integer :: sub, elem, i
        logical :: found
        character(len=64) :: nbuf
        ok = .false.
        errmsg = ''
        trk = tl_track()
        if (json_kind(doc, node) /= TK_OBJ) then
            errmsg = 'read_timeline: track entry is not an object'
            return
        end if
        call t_str(doc, node, 'kind', trk%kind, found)
        call t_str(doc, node, 'scene', trk%scene, found)
        call t_str(doc, node, 'character', trk%character, found)
        ! Scene-object target: "target" (string form) or "object".
        call t_get(doc, node, 'target', sub, found)
        if (found .and. json_kind(doc, sub) == TK_STR) then
            trk%target = json_str(doc, sub)
        else
            call t_str(doc, node, 'object', trk%target, found)
        end if
        trk%start_frame = t_int(doc, node, 'start_frame', 0, &
                                trk%has_start)
        trk%end_frame = t_int(doc, node, 'end_frame', 0, trk%has_end)
        call t_str(doc, node, 'action', trk%action, found)
        trk%resolved = t_bool(doc, node, 'resolved', .true., &
                              trk%has_resolved)
        call t_str(doc, node, 'verb', trk%verb, found)
        trk%visible = t_bool(doc, node, 'visible', .true., &
                             trk%has_visible)
        if (trk%has_start .and. trk%start_frame < 0) then
            errmsg = 'read_timeline: track "' // trim(trk%kind) // &
                     '" has a negative start_frame'
            return
        end if
        if (trk%has_start .and. trk%has_end .and. &
            trk%end_frame < trk%start_frame) then
            write(nbuf, '(I0, A, I0)') trk%end_frame, ' < ', &
                trk%start_frame
            errmsg = 'read_timeline: track "' // trim(trk%kind) // &
                     '" has end_frame < start_frame (' // &
                     trim(nbuf) // ')'
            return
        end if
        call t_get(doc, node, 'params', sub, found)
        if (found) then
            call t_kv_object(doc, sub, trk%params, trk%n_params)
        else
            allocate(trk%params(0))
            trk%n_params = 0
        end if
        call t_get(doc, node, 'keys', sub, found)
        if (found) then
            if (json_kind(doc, sub) /= TK_ARR) then
                errmsg = 'read_timeline: track "' // trim(trk%kind) &
                         // '" has a non-array "keys"'
                return
            end if
            trk%n_keys = json_arr_len(doc, sub)
            allocate(trk%keys(max(1, trk%n_keys)))
            do i = 1, trk%n_keys
                call json_arr_at(doc, sub, i, elem)
                call parse_key(doc, elem, trk%keys(i), ok, errmsg)
                if (.not. ok) return
                ! Unknown ease: linear + diagnostic (3.4), never silent.
                if (.not. known_ease(trk%keys(i)%ease)) then
                    call add_note(tl, 'track "' // trim(trk%kind) // &
                        '": unknown ease "' // &
                        trim(trk%keys(i)%ease) // &
                        '" treated as linear')
                    trk%keys(i)%ease = 'linear'
                end if
            end do
            ! Derive a missing span from the keys (first..last frame).
            if (trk%n_keys > 0) then
                if (.not. trk%has_start) then
                    trk%start_frame = trk%keys(1)%frame
                    trk%has_start = .true.
                end if
                if (.not. trk%has_end) then
                    trk%end_frame = trk%keys(trk%n_keys)%frame
                    trk%has_end = .true.
                end if
                if (trk%end_frame < trk%start_frame) then
                    errmsg = 'read_timeline: track "' // &
                             trim(trk%kind) // &
                             '" key frames run backwards ' // &
                             '(end_frame < start_frame)'
                    return
                end if
            end if
        else
            allocate(trk%keys(0))
            trk%n_keys = 0
        end if
        ok = .true.
    end subroutine parse_track

    subroutine parse_dialogue(doc, node, cue, ok, errmsg)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        type(tl_dialogue_cue), intent(out) :: cue
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        logical :: found, has_start, has_end
        character(len=64) :: nbuf
        ok = .false.
        errmsg = ''
        cue = tl_dialogue_cue()
        if (json_kind(doc, node) /= TK_OBJ) then
            errmsg = 'read_timeline: dialogue entry is not an object'
            return
        end if
        call t_str(doc, node, 'id', cue%id, found)
        if (.not. found .or. len_trim(cue%id) == 0) then
            errmsg = 'read_timeline: dialogue cue missing required "id"'
            return
        end if
        call t_str(doc, node, 'scene', cue%scene, found)
        call t_str(doc, node, 'speaker', cue%speaker, found)
        call t_str(doc, node, 'text', cue%text, found)
        if (.not. found) then
            errmsg = 'read_timeline: dialogue cue "' // trim(cue%id) &
                     // '" missing required "text"'
            return
        end if
        cue%start_frame = t_int(doc, node, 'start_frame', -1, has_start)
        cue%end_frame = t_int(doc, node, 'end_frame', -1, has_end)
        if (.not. has_start .or. .not. has_end) then
            errmsg = 'read_timeline: dialogue cue "' // trim(cue%id) &
                     // '" missing required start_frame/end_frame'
            return
        end if
        if (cue%start_frame < 0) then
            errmsg = 'read_timeline: dialogue cue "' // trim(cue%id) &
                     // '" has a negative start_frame'
            return
        end if
        if (cue%end_frame <= cue%start_frame) then
            write(nbuf, '(I0, A, I0)') cue%end_frame, ' <= ', &
                cue%start_frame
            errmsg = 'read_timeline: dialogue cue "' // trim(cue%id) &
                     // '" has end_frame <= start_frame (' // &
                     trim(nbuf) // ')'
            return
        end if
        ok = .true.
    end subroutine parse_dialogue

    subroutine parse_marker(doc, node, mk, ok, errmsg)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: node
        type(tl_marker), intent(out) :: mk
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        logical :: found, has_frame
        ok = .false.
        errmsg = ''
        mk = tl_marker()
        if (json_kind(doc, node) /= TK_OBJ) then
            errmsg = 'read_timeline: marker entry is not an object'
            return
        end if
        mk%frame = t_int(doc, node, 'frame', -1, has_frame)
        if (.not. has_frame) then
            errmsg = 'read_timeline: marker missing required "frame"'
            return
        end if
        if (mk%frame < 0) then
            errmsg = 'read_timeline: marker has a negative frame'
            return
        end if
        call t_str(doc, node, 'name', mk%name, found)
        call t_str(doc, node, 'kind', mk%kind, found)
        ok = .true.
    end subroutine parse_marker

    ! ------------------------------------------------------------------
    ! Public API
    ! ------------------------------------------------------------------

    subroutine timeline_free(tl)
        type(tl_timeline), intent(inout) :: tl
        tl = tl_timeline()
    end subroutine timeline_free

    ! read_timeline(path, tl, ok, errmsg) -- load and validate a
    ! .timeline.json file into the typed tl_timeline tree.  On
    ! ok=.false., errmsg names the problem (and, for the format /
    ! version gates, the value found) and tl is reset to empty.
    subroutine read_timeline(path, tl, ok, errmsg)
        character(len=*), intent(in) :: path
        type(tl_timeline), intent(out) :: tl
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg

        type(json_doc) :: doc
        character(len=:), allocatable :: text
        character(len=:), allocatable :: sval
        integer :: root, node, elem, i, n, slot
        logical :: found, has_ver, has_fps
        integer :: ver
        character(len=64) :: nbuf

        ok = .false.
        errmsg = ''
        tl = tl_timeline()

        call t_read_file(path, text, ok, errmsg)
        if (.not. ok) return
        call json_parse(text, doc, ok, errmsg)
        deallocate(text)
        if (.not. ok) then
            errmsg = 'read_timeline: JSON parse failed in ' // &
                     trim(path) // ': ' // trim(errmsg)
            return
        end if
        root = doc%root
        if (root <= 0 .or. json_kind(doc, root) /= TK_OBJ) then
            errmsg = 'read_timeline: root is not a JSON object: ' &
                     // trim(path)
            ok = .false.
            call json_free(doc)
            return
        end if

        ! From here to the end, success must be earned: json_parse
        ! left ok=.true., so reset it and set it only after every
        ! gate and section below has passed.
        ok = .false.

        ! ---- format gate (ADR-5 rule 4: missing is an error) ----
        call t_get(doc, root, 'format', node, found)
        if (.not. found) then
            errmsg = 'read_timeline: missing "format" (expected ' &
                     // '"forge3d-timeline"): ' // trim(path)
            call json_free(doc)
            return
        end if
        if (json_kind(doc, node) /= TK_STR) then
            errmsg = 'read_timeline: "format" is not a string ' &
                     // '(expected "forge3d-timeline"): ' // trim(path)
            call json_free(doc)
            return
        end if
        sval = json_str(doc, node)
        if (sval /= 'forge3d-timeline') then
            errmsg = 'read_timeline: not a forge3d-timeline file ' &
                     // '(format="' // sval // '"): ' // trim(path)
            call json_free(doc)
            return
        end if
        deallocate(sval)

        ! ---- version gate (exact-version reader, ADR-5) ----
        ver = t_int(doc, root, 'ir_version', -1, has_ver)
        if (.not. has_ver) then
            errmsg = 'read_timeline: missing ir_version: ' // trim(path)
            call json_free(doc)
            return
        end if
        if (ver /= TL_IR_VERSION) then
            write(nbuf, '(I0)') ver
            errmsg = 'read_timeline: unsupported ir_version ' &
                     // trim(nbuf) // ' (this reader accepts ' &
                     // '1): ' // trim(path)
            call json_free(doc)
            return
        end if

        ! ---- header: name / fps / duration (all required) ----
        call t_str(doc, root, 'name', tl%name, found)
        if (.not. found) then
            errmsg = 'read_timeline: missing required "name": ' &
                     // trim(path)
            call json_free(doc)
            return
        end if
        call t_get(doc, root, 'fps', node, has_fps)
        if (.not. has_fps .or. json_kind(doc, node) /= TK_OBJ) then
            errmsg = 'read_timeline: missing required "fps" ' &
                     // '{num, den}: ' // trim(path)
            call json_free(doc)
            return
        end if
        tl%fps_num = t_int(doc, node, 'num', 0)
        tl%fps_den = t_int(doc, node, 'den', 0)
        if (tl%fps_num <= 0 .or. tl%fps_den <= 0) then
            write(nbuf, '(I0, A, I0)') tl%fps_num, '/', tl%fps_den
            errmsg = 'read_timeline: fps must be a positive ' &
                     // 'rational, got ' // trim(nbuf) // ': ' &
                     // trim(path)
            call json_free(doc)
            return
        end if
        tl%duration_frames = t_int(doc, root, 'duration_frames', -1, &
                                   found)
        if (.not. found) then
            errmsg = 'read_timeline: missing required ' &
                     // '"duration_frames": ' // trim(path)
            call json_free(doc)
            return
        end if
        if (tl%duration_frames < 0) then
            errmsg = 'read_timeline: duration_frames is negative: ' &
                     // trim(path)
            call json_free(doc)
            return
        end if

        ! ---- generator (provenance only; tolerated absent) ----
        call t_get(doc, root, 'generator', node, found)
        if (found .and. json_kind(doc, node) == TK_OBJ) then
            call t_str(doc, node, 'tool', tl%gen_tool, found)
            call t_str(doc, node, 'version', tl%gen_version, found)
            call t_str(doc, node, 'source', tl%gen_source, found)
        end if
        if (.not. allocated(tl%gen_tool)) &
            allocate(character(len=0) :: tl%gen_tool)
        if (.not. allocated(tl%gen_version)) &
            allocate(character(len=0) :: tl%gen_version)
        if (.not. allocated(tl%gen_source)) &
            allocate(character(len=0) :: tl%gen_source)

        ! ---- characters ----
        call t_get(doc, root, 'characters', node, found)
        if (found) then
            if (json_kind(doc, node) /= TK_ARR) then
                errmsg = 'read_timeline: "characters" is not ' &
                         // 'an array: ' // trim(path)
                call json_free(doc)
                return
            end if
            n = json_arr_len(doc, node)
            tl%n_characters = n
            allocate(tl%characters(max(1, n)))
            do i = 1, n
                call json_arr_at(doc, node, i, elem)
                call parse_character(doc, elem, tl%characters(i), &
                                     ok, errmsg)
                if (.not. ok) then
                    call json_free(doc)
                    tl = tl_timeline()
                    return
                end if
            end do
        else
            allocate(tl%characters(0))
        end if

        ! ---- scenes ----
        call t_get(doc, root, 'scenes', node, found)
        if (found) then
            if (json_kind(doc, node) /= TK_ARR) then
                errmsg = 'read_timeline: "scenes" is not an ' &
                         // 'array: ' // trim(path)
                call json_free(doc)
                return
            end if
            n = json_arr_len(doc, node)
            tl%n_scenes = n
            allocate(tl%scenes(max(1, n)))
            do i = 1, n
                call json_arr_at(doc, node, i, elem)
                call parse_scene_span(doc, elem, tl, tl%scenes(i), &
                                      ok, errmsg)
                if (.not. ok) then
                    call json_free(doc)
                    tl = tl_timeline()
                    return
                end if
            end do
        else
            allocate(tl%scenes(0))
        end if

        ! ---- tracks (unknown kinds skipped with a diagnostic) ----
        call t_get(doc, root, 'tracks', node, found)
        if (found) then
            if (json_kind(doc, node) /= TK_ARR) then
                errmsg = 'read_timeline: "tracks" is not an ' &
                         // 'array: ' // trim(path)
                call json_free(doc)
                return
            end if
            n = json_arr_len(doc, node)
            ! First pass: count the kinds this reader implements.
            tl%n_tracks = 0
            do i = 1, n
                call json_arr_at(doc, node, i, elem)
                call t_str(doc, elem, 'kind', sval, found)
                if (.not. found) then
                    errmsg = 'read_timeline: track entry missing ' &
                             // 'required "kind": ' // trim(path)
                    call json_free(doc)
                    tl = tl_timeline()
                    return
                end if
                if (known_track_kind(sval)) then
                    tl%n_tracks = tl%n_tracks + 1
                else
                    tl%n_skipped_tracks = tl%n_skipped_tracks + 1
                    call add_note(tl, 'skipped unknown track kind "' &
                                  // sval // '"')
                end if
                deallocate(sval)
            end do
            allocate(tl%tracks(max(1, tl%n_tracks)))
            slot = 0
            do i = 1, n
                call json_arr_at(doc, node, i, elem)
                call t_str(doc, elem, 'kind', sval, found)
                if (known_track_kind(sval)) then
                    slot = slot + 1
                    call parse_track(doc, elem, tl, &
                                     tl%tracks(slot), ok, errmsg)
                    if (.not. ok) then
                        call json_free(doc)
                        tl = tl_timeline()
                        return
                    end if
                end if
                deallocate(sval)
            end do
        else
            allocate(tl%tracks(0))
        end if

        ! ---- dialogue ----
        call t_get(doc, root, 'dialogue', node, found)
        if (found) then
            if (json_kind(doc, node) /= TK_ARR) then
                errmsg = 'read_timeline: "dialogue" is not an ' &
                         // 'array: ' // trim(path)
                call json_free(doc)
                return
            end if
            n = json_arr_len(doc, node)
            tl%n_dialogue = n
            allocate(tl%dialogue(max(1, n)))
            do i = 1, n
                call json_arr_at(doc, node, i, elem)
                call parse_dialogue(doc, elem, tl%dialogue(i), &
                                    ok, errmsg)
                if (.not. ok) then
                    call json_free(doc)
                    tl = tl_timeline()
                    return
                end if
            end do
        else
            allocate(tl%dialogue(0))
        end if

        ! ---- markers ----
        call t_get(doc, root, 'markers', node, found)
        if (found) then
            if (json_kind(doc, node) /= TK_ARR) then
                errmsg = 'read_timeline: "markers" is not an ' &
                         // 'array: ' // trim(path)
                call json_free(doc)
                return
            end if
            n = json_arr_len(doc, node)
            tl%n_markers = n
            allocate(tl%markers(max(1, n)))
            do i = 1, n
                call json_arr_at(doc, node, i, elem)
                call parse_marker(doc, elem, tl%markers(i), ok, errmsg)
                if (.not. ok) then
                    call json_free(doc)
                    tl = tl_timeline()
                    return
                end if
            end do
        else
            allocate(tl%markers(0))
        end if

        call json_free(doc)
        ok = .true.
        errmsg = ''
    end subroutine read_timeline

end module timeline_ir_3d
