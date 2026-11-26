! f3dc_emit_timeline.f90 -- Forge3D Timeline IR emitter
! (ANIM Wave 2, slice B1; docs/TIMELINE-FORMAT.md / ADR-5).
!
! `f3dc build` emits build/<name>.timeline.json whenever the
! source contains animation authoring beyond a still: film mode,
! or any scene with animations / keys tracks / dialogue.  No
! timeline content anywhere -> no file (absence = still).
!
! Data flow: the CLI calls tl_add_scene once per built scene
! (per chunk, for multi-scene files) with the scene IR and the
! validator's per-scene fragment (f3dc_val_timeline's
! timeline_fragment side channel -- the data that does not
! survive into the scene IR: film header, character declarations,
! authored cue params, raw "@camera" keys).  tl_finalize then
! aggregates ALL accumulated scenes, in order, into ONE timeline
! document.  The CLI owns the file write and the file name.
!
! Canonical time is integer frames: frame = round(seconds *
! fps_num / fps_den), fps gcd-reduced.  Sentence-verb action cues
! are emitted with "resolved": false and NO keys -- resolving
! them to joint keys is Wave 3 plugin work (ANIM-PLAN SS3.4);
! hosts must report such spans as unmapped, never approximate.
!
! Serialisation is this module's own writer (not json_dumps):
! alphabetical object keys at every level, compact separators,
! and the TIMELINE-FORMAT float rule -- fmt_num_real (shortest
! round-trip digits via f3dc_str's fmt_real) PLUS whole-valued
! reals as JSON integers and -0.0 normalised to 0, which the raw
! json_real path does not do.  No timestamps or generated ids
! anywhere: same source + same compiler -> byte-identical file.
module f3dc_emit_timeline
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
       dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, &
       dyn_list_push, dyn_list_len, dyn_list_at, dyn_list_set_at, &
       dyn_dict_get, &
       dyn_dict_set, dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
       dyn_dict_value_at, DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, &
       DYN_K_REAL, DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, to_lower, str_builder, sb_init, &
       sb_add, sb_text
  use f3dc_emit_common, only: fmt_num_real, sha256_file_hex, &
       named_color
  use f3dc_plugins, only: plugin_rig, plugin_verb_channel, &
       ease_canonical
  implicit none
  private
  public :: tl_reset, tl_add_scene, tl_finalize

  ! Accumulated per-scene records: {name, scene_file,
  ! scene_ir_version, frag}.  Module state mirrors the CLI's
  ! build recursion: a top-level build resets, chunk sub-builds
  ! append, the top level finalizes.
  type(dyn) :: acc_scenes

contains

  ! ----------------------------------------------------------------
  ! Accumulation
  ! ----------------------------------------------------------------

  subroutine tl_reset()
    acc_scenes = dyn_list()
  end subroutine tl_reset

  !> Record one built scene (one chunk) for the timeline.
  subroutine tl_add_scene(ir, frag, scene_file)
    type(dyn), intent(in) :: ir, frag
    character(*), intent(in) :: scene_file
    type(dyn) :: rec, v
    if (acc_scenes%kind /= DYN_K_LIST) acc_scenes = dyn_list()
    rec = dyn_dict()
    v = dyn_dict_get(ir, "name")
    if (v%kind == DYN_K_STR) then
      call dyn_dict_set(rec, "name", v)
    else
      call dyn_dict_set(rec, "name", dyn_str(""))
    end if
    v = dyn_dict_get(ir, "ir_version")
    if (v%kind == DYN_K_INT) then
      call dyn_dict_set(rec, "scene_ir_version", v)
    else if (v%kind == DYN_K_REAL) then
      call dyn_dict_set(rec, "scene_ir_version", &
           dyn_int(int(v%r, int64)))
    else
      call dyn_dict_set(rec, "scene_ir_version", dyn_int(1_int64))
    end if
    call dyn_dict_set(rec, "scene_file", dyn_str(scene_file))
    if (frag%kind == DYN_K_DICT) then
      call dyn_dict_set(rec, "frag", dyn_copy(frag))
    else
      call dyn_dict_set(rec, "frag", dyn_dict())
    end if
    call dyn_list_push(acc_scenes, rec)
  end subroutine tl_add_scene

  ! ----------------------------------------------------------------
  ! Small dyn helpers
  ! ----------------------------------------------------------------

  function dget(d, key) result(v)
    type(dyn), intent(in) :: d
    character(*), intent(in) :: key
    type(dyn) :: v
    v = dyn_copy(dyn_dict_get(d, key))
  end function dget

  function dstr(d, key, default) result(out)
    type(dyn), intent(in) :: d
    character(*), intent(in) :: key, default
    character(:), allocatable :: out
    type(dyn) :: v
    v = dyn_dict_get(d, key)
    if (v%kind == DYN_K_STR) then
      out = v%s
    else
      out = default
    end if
  end function dstr

  subroutine dnum(d, key, x, has)
    type(dyn), intent(in) :: d
    character(*), intent(in) :: key
    real(real64), intent(out) :: x
    logical, intent(out) :: has
    type(dyn) :: v
    v = dyn_dict_get(d, key)
    has = .true.
    x = 0.0_real64
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
    case (DYN_K_REAL)
      x = v%r
    case default
      has = .false.
    end select
  end subroutine dnum

  !> The Timeline IR id slug of a source name (TIMELINE-FORMAT
  !! ID rules; twin of the copy in f3dc_val_timeline).
  function tl_slug(name) result(out)
    character(*), intent(in) :: name
    character(:), allocatable :: out
    integer :: i, c
    logical :: pending_dash
    out = ""
    pending_dash = .false.
    do i = 1, len(name)
      c = iachar(name(i:i))
      if (c >= iachar("A") .and. c <= iachar("Z")) c = c + 32
      if ((c >= iachar("a") .and. c <= iachar("z")) .or. &
          (c >= iachar("0") .and. c <= iachar("9"))) then
        if (pending_dash .and. len(out) > 0) out = out // "-"
        pending_dash = .false.
        out = out // achar(c)
      else
        pending_dash = .true.
      end if
    end do
  end function tl_slug

  integer(int64) function gcd64(a, b) result(g)
    integer(int64), intent(in) :: a, b
    integer(int64) :: x, y, t
    x = abs(a)
    y = abs(b)
    do while (y /= 0_int64)
      t = mod(x, y)
      x = y
      y = t
    end do
    g = max(x, 1_int64)
  end function gcd64

  ! ----------------------------------------------------------------
  ! Finalize: aggregate all accumulated scenes into one document.
  !
  ! FALLBACK_NAME names the timeline when no film title exists
  ! and there is more than one scene (the build stem, passed by
  ! the CLI).  SOURCE_PATH is hashed into generator.source_sha256
  ! when readable (content-derived; determinism-safe).
  ! ERR is non-empty on a slug collision -- the caller reports it
  ! as a compile error and no file is written.
  ! ----------------------------------------------------------------
  subroutine tl_finalize(fallback_name, tool_version, source_base, &
                         source_path, text, has_timeline, err)
    character(*), intent(in) :: fallback_name, tool_version
    character(*), intent(in) :: source_base, source_path
    character(:), allocatable, intent(out) :: text
    logical, intent(out) :: has_timeline
    character(:), allocatable, intent(out) :: err
    type(dyn) :: doc, chars, spans, tracks, dlgs, gen, fpsd
    type(dyn) :: rec, frag, v
    integer :: ns, i, k
    integer(int64) :: fps_num, fps_den
    real(real64) :: rate
    integer(int64) :: cursor, total_frames
    character(:), allocatable :: top_name
    logical :: any_content
    text = ""
    err = ""
    has_timeline = .false.
    if (acc_scenes%kind /= DYN_K_LIST) return
    ns = dyn_list_len(acc_scenes)
    if (ns == 0) return

    ! ---- fps: film header first; else the first scene's render
    ! fps; else a keys-track fps; else the first anim's fps; else
    ! the compiler's anim default (30).  (Non-film choice, slice
    ! B1: the render fps the validator resolved, in that order.)
    rate = 0.0_real64
    do i = 1, ns
      frag = dget(dyn_list_at(acc_scenes, i), "frag")
      call dnum(frag, "film_fps", rate, any_content)
      if (any_content) exit
      rate = 0.0_real64
    end do
    if (rate <= 0.0_real64) then
      do i = 1, ns
        frag = dget(dyn_list_at(acc_scenes, i), "frag")
        call dnum(frag, "render_fps", rate, any_content)
        if (any_content) exit
        rate = 0.0_real64
      end do
    end if
    if (rate <= 0.0_real64) then
      do i = 1, ns
        frag = dget(dyn_list_at(acc_scenes, i), "frag")
        v = dget(frag, "keys_tracks")
        if (v%kind /= DYN_K_DICT) cycle
        do k = 1, dyn_dict_len(v)
          call dnum(dyn_dict_value_at(v, k), "fps", rate, &
                    any_content)
          if (any_content) exit
        end do
        if (rate > 0.0_real64) exit
      end do
    end if
    if (rate <= 0.0_real64) then
      do i = 1, ns
        frag = dget(dyn_list_at(acc_scenes, i), "frag")
        v = dget(frag, "anims")
        if (dyn_list_len(v) > 0) then
          call dnum(dyn_list_at(v, 1), "fps", rate, any_content)
          if (any_content) exit
        end if
      end do
    end if
    if (rate <= 0.0_real64) rate = 30.0_real64
    if (rate == floor(rate) .and. abs(rate) < 9.0e15_real64) then
      fps_num = int(rate, int64)
      fps_den = 1_int64
    else
      fps_num = nint(rate * 1000.0_real64, int64)
      fps_den = 1000_int64
    end if
    block
      integer(int64) :: g
      g = gcd64(fps_num, fps_den)
      fps_num = fps_num / g
      fps_den = fps_den / g
    end block

    ! ---- top-level name: film title, else the single scene's
    ! name, else the caller's fallback (the build stem).
    top_name = ""
    do i = 1, ns
      frag = dget(dyn_list_at(acc_scenes, i), "frag")
      if (dyn_dict_has(frag, "film_title")) then
        top_name = dstr(frag, "film_title", "")
        exit
      end if
    end do
    if (len(top_name) == 0) then
      if (ns == 1) then
        top_name = dstr(dyn_list_at(acc_scenes, 1), "name", &
                        fallback_name)
      else
        top_name = fallback_name
      end if
    end if

    ! ---- character union (film-level; first declaration wins)
    chars = dyn_list()
    block
      type(dyn) :: centry
      character(:), allocatable :: cname, cid, seen_nm
      integer :: j, m
      logical :: seen
      do i = 1, ns
        frag = dget(dyn_list_at(acc_scenes, i), "frag")
        v = dget(frag, "characters")
        do j = 1, dyn_list_len(v)
          centry = dyn_list_at(v, j)
          cname = dstr(centry, "name", "")
          if (len(cname) == 0) cycle
          cid = tl_slug(cname)
          seen = .false.
          do m = 1, dyn_list_len(chars)
            seen_nm = dstr(dyn_list_at(chars, m), "name", "")
            if (seen_nm == cname) seen = .true.
            if (dstr(dyn_list_at(chars, m), "id", "") == cid &
                .and. seen_nm /= cname) then
              err = "characters '" // seen_nm // "' and '" // &
                    cname // "' both become the timeline id '" &
                    // cid // "'"
              return
            end if
          end do
          if (seen) cycle
          call dyn_list_push(chars, &
               build_character(centry, cid))
        end do
      end do
    end block

    ! ---- scene spans + tracks + dialogue, in timeline order
    spans = dyn_list()
    tracks = dyn_list()
    dlgs = dyn_list()
    cursor = 0_int64
    any_content = .false.
    do i = 1, ns
      rec = dyn_list_at(acc_scenes, i)
      frag = dget(rec, "frag")
      call build_scene(rec, frag, fps_num, fps_den, &
                       cursor, spans, tracks, dlgs, any_content, &
                       err)
      if (len(err) > 0) return
    end do
    total_frames = cursor
    if (.not. any_content) return
    has_timeline = .true.

    ! ---- dialogue ids, in timeline order
    block
      type(dyn) :: d
      integer :: j
      do j = 1, dyn_list_len(dlgs)
        d = dyn_list_at(dlgs, j)
        call dyn_dict_set(d, "id", &
             dyn_str("d" // trim(fmt_int(int(j, int64)))))
        call dyn_list_set_at(dlgs, j, d)
      end do
    end block

    ! ---- sort tracks by (scene, kind, character/target, start)
    call sort_tracks(tracks)

    ! ---- assemble
    doc = dyn_dict()
    call dyn_dict_set(doc, "format", dyn_str("forge3d-timeline"))
    call dyn_dict_set(doc, "ir_version", dyn_int(1_int64))
    call dyn_dict_set(doc, "name", dyn_str(top_name))
    fpsd = dyn_dict()
    call dyn_dict_set(fpsd, "num", dyn_int(fps_num))
    call dyn_dict_set(fpsd, "den", dyn_int(fps_den))
    call dyn_dict_set(doc, "fps", fpsd)
    call dyn_dict_set(doc, "duration_frames", &
         dyn_int(total_frames))
    gen = dyn_dict()
    call dyn_dict_set(gen, "tool", dyn_str("f3dc"))
    call dyn_dict_set(gen, "version", dyn_str(tool_version))
    call dyn_dict_set(gen, "source", dyn_str(source_base))
    block
      character(:), allocatable :: hex
      logical :: ok
      call sha256_file_hex(source_path, hex, ok)
      if (ok) call dyn_dict_set(gen, "source_sha256", &
                                dyn_str(hex))
    end block
    call dyn_dict_set(doc, "generator", gen)
    call dyn_dict_set(doc, "characters", chars)
    call dyn_dict_set(doc, "scenes", spans)
    call dyn_dict_set(doc, "tracks", tracks)
    call dyn_dict_set(doc, "dialogue", dlgs)
    call dyn_dict_set(doc, "markers", dyn_list())
    block
      type(str_builder) :: sb
      call sb_init(sb)
      call write_value(sb, doc)
      text = sb_text(sb)
    end block
  end subroutine tl_finalize

  !> One Character record from a fragment character entry.
  function build_character(centry, cid) result(rec)
    type(dyn), intent(in) :: centry
    character(*), intent(in) :: cid
    type(dyn) :: rec
    type(dyn) :: cprops, v, rig, props_out
    character(:), allocatable :: pid, cname
    logical :: found
    integer :: rgb(3), m
    rec = dyn_dict()
    cname = dstr(centry, "name", "")
    pid = dstr(centry, "plugin", "")
    call dyn_dict_set(rec, "id", dyn_str(cid))
    call dyn_dict_set(rec, "name", dyn_str(cname))
    call dyn_dict_set(rec, "plugin", dyn_str(pid))
    ! Colour: the resolved IR colour when the fragment carries
    ! one; else the named colour of the declaration.
    v = dget(centry, "color")
    rgb = 0
    if (v%kind == DYN_K_LIST .and. dyn_list_len(v) >= 3) then
      do m = 1, 3
        block
          real(real64) :: x
          logical :: has
          call dnum_at(v, m, x, has)
          if (has) rgb(m) = nint(x)
        end block
      end do
    else
      cprops = dget(centry, "char_props")
      block
        character(:), allocatable :: cname2
        cname2 = dstr(cprops, "colour", "")
        if (len(cname2) == 0) cname2 = dstr(cprops, "color", "")
        call named_color(to_lower(cname2), rgb, found)
        if (.not. found) rgb = [255, 255, 255]
      end block
    end if
    block
      type(dyn) :: carr
      carr = dyn_list()
      do m = 1, 3
        call dyn_list_push(carr, dyn_int(int(rgb(m), int64)))
      end do
      call dyn_dict_set(rec, "color", carr)
    end block
    ! Rig: asked of the plugin registry, never hardcoded here.
    call plugin_rig(pid, rig, found)
    if (found) then
      call dyn_dict_set(rec, "rig", rig)
    else
      call dyn_dict_set(rec, "rig", dyn_dict())
    end if
    ! Proportions: the plugin-vocabulary proportion props the
    ! declaration carries ("proportions" / "height").
    cprops = dget(centry, "char_props")
    props_out = dyn_dict()
    if (dyn_dict_has(cprops, "proportions")) &
      call dyn_dict_set(props_out, "proportions", &
           dyn_copy(dyn_dict_get(cprops, "proportions")))
    if (dyn_dict_has(cprops, "height")) &
      call dyn_dict_set(props_out, "height", &
           dyn_copy(dyn_dict_get(cprops, "height")))
    if (dyn_dict_len(props_out) > 0) &
      call dyn_dict_set(rec, "proportions", props_out)
    ! Voice, when a voice prop exists.
    v = dyn_dict_get(cprops, "voice")
    if (v%kind == DYN_K_STR) then
      block
        type(dyn) :: voice
        voice = dyn_dict()
        call dyn_dict_set(voice, "speaker", v)
        call dyn_dict_set(rec, "voice", voice)
      end block
    else if (v%kind == DYN_K_DICT) then
      block
        type(dyn) :: voice, sv
        sv = dyn_dict_get(v, "speaker")
        if (sv%kind == DYN_K_STR) then
          voice = dyn_dict()
          call dyn_dict_set(voice, "speaker", sv)
          call dyn_dict_set(rec, "voice", voice)
        end if
      end block
    end if
  end function build_character

  !> The "frame" int of a key dict (-1 when absent).
  integer(int64) function frame_of(d) result(fr)
    type(dyn), intent(in) :: d
    type(dyn) :: v
    v = dyn_dict_get(d, "frame")
    if (v%kind == DYN_K_INT) then
      fr = v%i
    else
      fr = -1_int64
    end if
  end function frame_of

  subroutine dnum_at(list, idx, x, has)
    type(dyn), intent(in) :: list
    integer, intent(in) :: idx
    real(real64), intent(out) :: x
    logical, intent(out) :: has
    type(dyn) :: v
    v = dyn_list_at(list, idx)
    has = .true.
    x = 0.0_real64
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
    case (DYN_K_REAL)
      x = v%r
    case default
      has = .false.
    end select
  end subroutine dnum_at

  !> Is NAME one of this scene's declared characters?  Returns
  !! its timeline id via CID when true.
  logical function scene_character(frag, name, cid)
    type(dyn), intent(in) :: frag
    character(*), intent(in) :: name
    character(:), allocatable, intent(out) :: cid
    type(dyn) :: v
    integer :: j
    scene_character = .false.
    cid = ""
    v = dget(frag, "characters")
    do j = 1, dyn_list_len(v)
      if (dstr(dyn_list_at(v, j), "name", "") == name) then
        scene_character = .true.
        cid = tl_slug(name)
        return
      end if
    end do
  end function scene_character

  !> The plugin id of a character declared in FRAG ("" if none).
  function scene_character_plugin(frag, name) result(pid)
    type(dyn), intent(in) :: frag
    character(*), intent(in) :: name
    character(:), allocatable :: pid
    type(dyn) :: v
    integer :: j
    pid = ""
    v = dget(frag, "characters")
    do j = 1, dyn_list_len(v)
      if (dstr(dyn_list_at(v, j), "name", "") == name) then
        pid = dstr(dyn_list_at(v, j), "plugin", "")
        return
      end if
    end do
  end function scene_character_plugin

  ! ----------------------------------------------------------------
  ! Per-scene span / tracks / dialogue construction.  CURSOR is
  ! the running timeline frame offset (in/out).  Frames are
  ! computed as round(seconds * fps_num / fps_den); spans and
  ! cues are widened to end_frame > start_frame when rounding
  ! would collapse them (TIMELINE-FORMAT: half-open spans are
  ! never empty).
  ! ----------------------------------------------------------------
  subroutine build_scene(rec, frag, fps_num, fps_den, &
                         cursor, spans, tracks, dlgs, &
                         any_content, err)
    type(dyn), intent(in) :: rec, frag
    integer(int64), intent(in) :: fps_num, fps_den
    integer(int64), intent(inout) :: cursor
    type(dyn), intent(inout) :: spans, tracks, dlgs
    logical, intent(inout) :: any_content
    character(:), allocatable, intent(inout) :: err
    type(dyn) :: span, bindings, v, anim, trk
    character(:), allocatable :: sname, sid, cid
    integer(int64) :: start_frame, dur_frames
    real(real64) :: dur_sec, x, y
    integer :: j, m
    logical :: has, is_char
    sname = dstr(rec, "name", "")
    sid = tl_slug(sname)
    ! Scene id collision across chunks (distinct names, one id).
    do j = 1, dyn_list_len(spans)
      if (dstr(dyn_list_at(spans, j), "id", "") == sid .and. &
          dstr(dyn_list_at(spans, j), "name", "") /= sname) then
        err = "scenes '" // &
              dstr(dyn_list_at(spans, j), "name", "") // &
              "' and '" // sname // &
              "' both become the timeline scene id '" // sid // "'"
        return
      end if
    end do

    ! ---- scene duration (seconds): the render's explicit
    ! duration wins (D2); else the timeline content defines it.
    dur_sec = 0.0_real64
    call dnum(frag, "render_duration", x, has)
    if (has) then
      dur_sec = x
    else
      v = dget(frag, "anims")
      do j = 1, dyn_list_len(v)
        anim = dyn_list_at(v, j)
        call dnum(anim, "_start", x, has)
        if (.not. has) x = 0.0_real64
        call dnum(anim, "duration", y, has)
        if (.not. has) y = 0.0_real64
        dur_sec = max(dur_sec, x + y)
      end do
      v = dget(frag, "dialogue")
      do j = 1, dyn_list_len(v)
        anim = dyn_list_at(v, j)
        call dnum(anim, "start", x, has)
        if (.not. has) x = 0.0_real64
        call dnum(anim, "duration", y, has)
        if (.not. has) y = 0.0_real64
        dur_sec = max(dur_sec, x + y)
      end do
      v = dget(frag, "camera_keys")
      do j = 1, dyn_list_len(v)
        call dnum(dyn_list_at(v, j), "time", x, has)
        if (has) dur_sec = max(dur_sec, x)
      end do
      v = dget(frag, "keys_tracks")
      if (v%kind == DYN_K_DICT) then
        do j = 1, dyn_dict_len(v)
          trk = dyn_dict_value_at(v, j)
          block
            real(real64) :: tfps, tend
            logical :: has_fps
            call dnum(trk, "fps", tfps, has_fps)
            if (.not. has_fps) tfps = 0.0_real64
            call dnum(trk, "duration", tend, has)
            if (.not. has) tend = 0.0_real64
            if (tfps > 0.0_real64) tend = tend / tfps
            dur_sec = max(dur_sec, tend)
            block
              type(dyn) :: klist, key
              integer :: q
              klist = dget(trk, "keys")
              do q = 1, dyn_list_len(klist)
                key = dyn_list_at(klist, q)
                call dnum(key, "time", tend, has)
                if (.not. has) cycle
                if (tfps > 0.0_real64) tend = tend / tfps
                dur_sec = max(dur_sec, tend)
              end do
            end block
          end block
        end do
      end if
    end if
    start_frame = cursor
    dur_frames = nint(dur_sec * real(fps_num, real64) / &
                      real(fps_den, real64), int64)
    if (dur_frames < 0_int64) dur_frames = 0_int64
    cursor = cursor + dur_frames

    ! ---- content test (emission rule)
    block
      logical :: content
      content = .false.
      v = dget(frag, "is_film")
      if (v%kind == DYN_K_BOOL .and. v%b) content = .true.
      if (dyn_list_len(dget(frag, "anims")) > 0) content = .true.
      if (dyn_list_len(dget(frag, "dialogue")) > 0) &
        content = .true.
      if (dyn_list_len(dget(frag, "camera_keys")) > 0) &
        content = .true.
      v = dget(frag, "keys_tracks")
      if (v%kind == DYN_K_DICT .and. dyn_dict_len(v) > 0) &
        content = .true.
      if (content) any_content = .true.
    end block

    ! ---- span + bindings
    span = dyn_dict()
    call dyn_dict_set(span, "id", dyn_str(sid))
    call dyn_dict_set(span, "name", dyn_str(sname))
    call dyn_dict_set(span, "scene_file", &
         dyn_str(dstr(rec, "scene_file", "")))
    call dyn_dict_set(span, "scene_ir_version", &
         dyn_copy(dyn_dict_get(rec, "scene_ir_version")))
    call dyn_dict_set(span, "start_frame", dyn_int(start_frame))
    call dyn_dict_set(span, "duration_frames", dyn_int(dur_frames))
    bindings = dyn_dict()
    v = dget(frag, "characters")
    do j = 1, dyn_list_len(v)
      block
        character(:), allocatable :: nm2
        nm2 = dstr(dyn_list_at(v, j), "name", "")
        if (len(nm2) > 0) &
          call dyn_dict_set(bindings, tl_slug(nm2), dyn_str(nm2))
      end block
    end do
    call dyn_dict_set(span, "bindings", bindings)
    ! SceneSpan "transition" (slice B3): the fragment's captured
    ! scene transition (validator side channel), written as
    ! {kind, duration_frames} per TIMELINE-FORMAT -- seconds ->
    ! frames with the same nint rounding as the spans.  `cut`
    ! never reaches the fragment, so absence here = cut.
    v = dget(frag, "transition")
    if (v%kind == DYN_K_DICT) then
      block
        type(dyn) :: trec
        character(:), allocatable :: tkind
        real(real64) :: tdur
        logical :: has_dur
        tkind = dstr(v, "kind", "")
        if (len(tkind) > 0 .and. tkind /= "cut") then
          call dnum(v, "duration", tdur, has_dur)
          if (.not. has_dur) tdur = 0.0_real64
          trec = dyn_dict()
          call dyn_dict_set(trec, "kind", dyn_str(tkind))
          call dyn_dict_set(trec, "duration_frames", &
               dyn_int(nint(tdur * real(fps_num, real64) / &
                            real(fps_den, real64), int64)))
          call dyn_dict_set(span, "transition", trec)
        end if
      end block
    end if
    call dyn_list_push(spans, span)

    ! ---- tracks: actions + verbs from the resolved anims
    v = dget(frag, "anims")
    do j = 1, dyn_list_len(v)
      anim = dyn_list_at(v, j)
      block
        character(:), allocatable :: tgt, kind, ch
        real(real64) :: st, du
        logical :: has_start, found
        integer(int64) :: sf, ef
        type(dyn) :: t, params
        tgt = dstr(anim, "target", "")
        kind = dstr(anim, "kind", "")
        call dnum(anim, "_start", st, has_start)
        if (.not. has_start) st = 0.0_real64
        block
          type(dyn) :: hv
          hv = dyn_dict_get(anim, "_has_start")
          has_start = (hv%kind == DYN_K_BOOL .and. hv%b)
        end block
        call dnum(anim, "duration", du, has)
        if (.not. has) du = 0.0_real64
        sf = start_frame + nint(st * real(fps_num, real64) / &
                                real(fps_den, real64), int64)
        ef = start_frame + nint((st + du) * &
                                real(fps_num, real64) / &
                                real(fps_den, real64), int64)
        if (ef <= sf) ef = sf + 1_int64
        is_char = scene_character(frag, tgt, cid)
        t = dyn_dict()
        if (has_start .and. is_char) then
          ! Character cue -> "action" track, unresolved (Wave 3
          ! resolves sentence verbs to joint keys).
          call dyn_dict_set(t, "kind", dyn_str("action"))
          call dyn_dict_set(t, "scene", dyn_str(sid))
          call dyn_dict_set(t, "character", dyn_str(cid))
          call dyn_dict_set(t, "action", dyn_str(kind))
          ch = dstr(anim, "_channel", "")
          if (len(ch) == 0) then
            call plugin_verb_channel( &
                 scene_character_plugin(frag, tgt), kind, ch, &
                 found)
            if (.not. found) ch = "body"
          end if
          call dyn_dict_set(t, "channel", dyn_str(ch))
          call dyn_dict_set(t, "start_frame", dyn_int(sf))
          call dyn_dict_set(t, "end_frame", dyn_int(ef))
          params = dget(anim, "params")
          if (params%kind == DYN_K_DICT .and. &
              dyn_dict_len(params) > 0) &
            call dyn_dict_set(t, "params", params)
          call dyn_dict_set(t, "resolved", dyn_bool(.false.))
        else
          ! Scene-object animation -> "verb" track (the IR form
          ! of the scene formats' animations[]).
          call dyn_dict_set(t, "kind", dyn_str("verb"))
          call dyn_dict_set(t, "scene", dyn_str(sid))
          call dyn_dict_set(t, "target", dyn_str(tgt))
          call dyn_dict_set(t, "verb", dyn_str(kind))
          call dyn_dict_set(t, "start_frame", dyn_int(sf))
          call dyn_dict_set(t, "end_frame", dyn_int(ef))
          params = dget(anim, "params")
          if (params%kind /= DYN_K_DICT) params = dyn_dict()
          block
            character(8) :: pkeys(4)
            integer :: q
            pkeys = [character(8) :: "axis", "speed", "ease", &
                     "loop"]
            do q = 1, 4
              if (dyn_dict_has(anim, trim(pkeys(q)))) &
                call dyn_dict_set(params, trim(pkeys(q)), &
                     dyn_copy(dyn_dict_get(anim, &
                             trim(pkeys(q)))))
            end do
          end block
          if (dyn_dict_len(params) > 0) &
            call dyn_dict_set(t, "params", params)
        end if
        call dyn_list_push(tracks, t)
      end block
    end do

    ! ---- tracks: pose_keys from the keys tracks
    v = dget(frag, "keys_tracks")
    if (v%kind == DYN_K_DICT) then
      do j = 1, dyn_dict_len(v)
        block
          character(:), allocatable :: tgt
          type(dyn) :: trk2, t, keys_out, klist, key, nk
          real(real64) :: tfps
          logical :: has_fps
          integer :: q
          tgt = dyn_dict_key_at(v, j)
          trk2 = dyn_dict_value_at(v, j)
          call dnum(trk2, "fps", tfps, has_fps)
          if (.not. has_fps) tfps = 0.0_real64
          klist = dget(trk2, "keys")
          keys_out = dyn_list()
          do q = 1, dyn_list_len(klist)
            key = dyn_list_at(klist, q)
            nk = dyn_dict()
            block
              real(real64) :: tm
              logical :: has_t
              integer(int64) :: fr
              call dnum(key, "time", tm, has_t)
              if (.not. has_t) tm = 0.0_real64
              if (tfps > 0.0_real64) tm = tm / tfps
              fr = start_frame + nint(tm * &
                   real(fps_num, real64) / real(fps_den, real64), &
                   int64)
              call dyn_dict_set(nk, "frame", dyn_int(fr))
            end block
            if (dyn_dict_has(key, "pos")) &
              call dyn_dict_set(nk, "pos", &
                   dyn_copy(dyn_dict_get(key, "pos")))
            if (dyn_dict_has(key, "rot")) &
              call dyn_dict_set(nk, "rot_deg", &
                   dyn_copy(dyn_dict_get(key, "rot")))
            if (dyn_dict_has(key, "scale")) &
              call dyn_dict_set(nk, "scale", &
                   dyn_copy(dyn_dict_get(key, "scale")))
            call dyn_dict_set(nk, "ease", dyn_str(ease_canonical( &
                 dstr(key, "ease", "linear"))))
            ! Equal frames after rounding: keep the LAST key.
            if (dyn_list_len(keys_out) > 0) then
              block
                type(dyn) :: prev
                prev = dyn_list_at(keys_out, &
                                   dyn_list_len(keys_out))
                if (frame_of(prev) == frame_of(nk)) then
                  call dyn_list_set_at(keys_out, &
                       dyn_list_len(keys_out), nk)
                else
                  call dyn_list_push(keys_out, nk)
                end if
              end block
            else
              call dyn_list_push(keys_out, nk)
            end if
          end do
          if (dyn_list_len(keys_out) == 0) cycle
          ! The first key's ease is emitted as "linear" (spec).
          block
            type(dyn) :: first
            first = dyn_list_at(keys_out, 1)
            call dyn_dict_set(first, "ease", dyn_str("linear"))
            call dyn_list_set_at(keys_out, 1, first)
          end block
          t = dyn_dict()
          call dyn_dict_set(t, "kind", dyn_str("pose_keys"))
          call dyn_dict_set(t, "scene", dyn_str(sid))
          is_char = scene_character(frag, tgt, cid)
          if (is_char) then
            call dyn_dict_set(t, "character", dyn_str(cid))
          else
            call dyn_dict_set(t, "target", dyn_str(tgt))
          end if
          call dyn_dict_set(t, "keys", keys_out)
          call dyn_list_push(tracks, t)
        end block
      end do
    end if

    ! ---- track: camera from the raw "@camera" keys
    v = dget(frag, "camera_keys")
    if (dyn_list_len(v) > 0) then
      block
        type(dyn) :: t, keys_out, key, nk
        integer :: q
        keys_out = dyn_list()
        do q = 1, dyn_list_len(v)
          key = dyn_list_at(v, q)
          nk = dyn_dict()
          block
            real(real64) :: tm
            logical :: has_t
            integer(int64) :: fr
            call dnum(key, "time", tm, has_t)
            if (.not. has_t) tm = 0.0_real64
            fr = start_frame + nint(tm * real(fps_num, real64) / &
                                    real(fps_den, real64), int64)
            call dyn_dict_set(nk, "frame", dyn_int(fr))
          end block
          if (dyn_dict_has(key, "pos")) &
            call dyn_dict_set(nk, "pos", &
                 dyn_copy(dyn_dict_get(key, "pos")))
          if (dyn_dict_has(key, "look")) &
            call dyn_dict_set(nk, "target", &
                 dyn_copy(dyn_dict_get(key, "look")))
          if (dyn_dict_has(key, "fov")) &
            call dyn_dict_set(nk, "fov", &
                 dyn_copy(dyn_dict_get(key, "fov")))
          call dyn_dict_set(nk, "ease", dyn_str(ease_canonical( &
               dstr(key, "ease", "linear"))))
          if (dyn_list_len(keys_out) > 0) then
            block
              type(dyn) :: prev
              prev = dyn_list_at(keys_out, dyn_list_len(keys_out))
              if (frame_of(prev) == frame_of(nk)) then
                call dyn_list_set_at(keys_out, &
                     dyn_list_len(keys_out), nk)
              else
                call dyn_list_push(keys_out, nk)
              end if
            end block
          else
            call dyn_list_push(keys_out, nk)
          end if
        end do
        if (dyn_list_len(keys_out) > 0) then
          block
            type(dyn) :: first
            first = dyn_list_at(keys_out, 1)
            call dyn_dict_set(first, "ease", dyn_str("linear"))
            call dyn_list_set_at(keys_out, 1, first)
          end block
          t = dyn_dict()
          call dyn_dict_set(t, "kind", dyn_str("camera"))
          call dyn_dict_set(t, "scene", dyn_str(sid))
          call dyn_dict_set(t, "keys", keys_out)
          call dyn_list_push(tracks, t)
        end if
      end block
    end if

    ! ---- dialogue cues (narrator caption/title lines are NOT
    ! dialogue cues in v1 -- TIMELINE-FORMAT, Dialogue cue).
    v = dget(frag, "dialogue")
    do j = 1, dyn_list_len(v)
      anim = dyn_list_at(v, j)
      block
        character(:), allocatable :: spk, txt
        real(real64) :: st, du
        integer(int64) :: sf, ef
        type(dyn) :: d
        spk = dstr(anim, "speaker", "")
        txt = dstr(anim, "text", "")
        if (spk == "caption" .or. spk == "title") cycle
        if (len(txt) == 0) cycle  ! never emit an empty-text cue
        call dnum(anim, "start", st, has)
        if (.not. has) st = 0.0_real64
        call dnum(anim, "duration", du, has)
        if (.not. has) du = 0.0_real64
        sf = start_frame + nint(st * real(fps_num, real64) / &
                                real(fps_den, real64), int64)
        ef = start_frame + nint((st + du) * &
                                real(fps_num, real64) / &
                                real(fps_den, real64), int64)
        if (ef <= sf) ef = sf + 1_int64
        d = dyn_dict()
        call dyn_dict_set(d, "scene", dyn_str(sid))
        call dyn_dict_set(d, "start_frame", dyn_int(sf))
        call dyn_dict_set(d, "end_frame", dyn_int(ef))
        call dyn_dict_set(d, "speaker", dyn_str(tl_slug(spk)))
        call dyn_dict_set(d, "text", dyn_str(txt))
        call dyn_list_push(dlgs, d)
      end block
    end do
  end subroutine build_scene

  ! ----------------------------------------------------------------
  ! Track ordering: (scene, kind, character/target, start_frame)
  ! -- insertion sort over the track list with string keys.
  ! ----------------------------------------------------------------
  subroutine sort_tracks(tracks)
    type(dyn), intent(inout) :: tracks
    integer :: n, i, j
    type(dyn) :: a, b
    n = dyn_list_len(tracks)
    do i = 2, n
      a = dyn_list_at(tracks, i)
      j = i - 1
      do while (j >= 1)
        b = dyn_list_at(tracks, j)
        if (.not. track_less(a, b)) exit
        call dyn_list_set_at(tracks, j + 1, b)
        j = j - 1
      end do
      call dyn_list_set_at(tracks, j + 1, a)
    end do
  end subroutine sort_tracks

  logical function track_less(a, b) result(less)
    type(dyn), intent(in) :: a, b
    character(:), allocatable :: ka, kb
    ka = track_key(a)
    kb = track_key(b)
    less = str_less(ka, kb)
  end function track_less

  function track_key(t) result(key)
    type(dyn), intent(in) :: t
    character(:), allocatable :: key, who
    integer(int64) :: sf
    type(dyn) :: v
    who = dstr(t, "character", "")
    if (len(who) == 0) who = dstr(t, "target", "")
    v = dyn_dict_get(t, "start_frame")
    if (v%kind == DYN_K_INT) then
      sf = v%i
    else
      ! Keyed tracks carry no start_frame: their sort frame is
      ! their first key's frame (0 when keyless).
      sf = 0_int64
      v = dget(t, "keys")
      if (dyn_list_len(v) > 0) then
        v = dyn_dict_get(dyn_list_at(v, 1), "frame")
        if (v%kind == DYN_K_INT) sf = v%i
      end if
    end if
    ! Zero-padded frame keeps the string key order numeric.
    block
      character(len=32) :: buf
      character(:), allocatable :: digits
      integer :: q
      digits = trim(fmt_int(sf))
      if (sf >= 0_int64) then
        do q = 1, 20 - len(digits)
          digits = "0" // digits
        end do
      end if
      write (buf, '(A)') digits
      key = dstr(t, "scene", "") // achar(1) // &
            dstr(t, "kind", "") // achar(1) // who // achar(1) &
            // trim(buf)
    end block
  end function track_key

  ! Byte-wise string less-than (Fortran's padded compare is not
  ! byte order for strings containing characters below space,
  ! which the track key uses as separators).
  pure logical function str_less(a, b) result(less)
    character(*), intent(in) :: a, b
    integer :: i, ca, cb
    less = .false.
    do i = 1, min(len(a), len(b))
      ca = iachar(a(i:i))
      cb = iachar(b(i:i))
      if (ca /= cb) then
        less = ca < cb
        return
      end if
    end do
    less = len(a) < len(b)
  end function str_less

  ! ----------------------------------------------------------------
  ! Serialisation: alphabetical keys at every level, compact
  ! separators, TIMELINE-FORMAT float rule via fmt_num_real,
  ! string escaping exactly as the existing JSON emitter's raw
  ! path (quote / backslash / control < 0x20 escaped, UTF-8 bytes
  ! pass through).
  ! ----------------------------------------------------------------
  recursive subroutine write_value(sb, v)
    type(str_builder), intent(inout) :: sb
    type(dyn), intent(in) :: v
    integer :: i
    select case (v%kind)
    case (DYN_K_NULL)
      call sb_add(sb, "null")
    case (DYN_K_BOOL)
      if (v%b) then
        call sb_add(sb, "true")
      else
        call sb_add(sb, "false")
      end if
    case (DYN_K_INT)
      call sb_add(sb, trim(fmt_int(v%i)))
    case (DYN_K_REAL)
      call sb_add(sb, fmt_num_real(v%r))
    case (DYN_K_STR)
      call sb_add(sb, '"' // escape_str(v%s) // '"')
    case (DYN_K_LIST)
      call sb_add(sb, "[")
      do i = 1, dyn_list_len(v)
        if (i > 1) call sb_add(sb, ",")
        call write_value(sb, dyn_list_at(v, i))
      end do
      call sb_add(sb, "]")
    case (DYN_K_DICT)
      block
        character(len=:), allocatable :: keys(:)
        integer :: nk, a, b
        character(:), allocatable :: tmp
        nk = dyn_dict_len(v)
        allocate (character(len=256) :: keys(max(nk, 1)))
        do i = 1, nk
          keys(i) = dyn_dict_key_at(v, i)
        end do
        do a = 2, nk
          tmp = trim(keys(a))
          b = a - 1
          do while (b >= 1)
            if (.not. str_less(tmp, trim(keys(b)))) exit
            keys(b + 1) = keys(b)
            b = b - 1
          end do
          keys(b + 1) = tmp
        end do
        call sb_add(sb, "{")
        do i = 1, nk
          if (i > 1) call sb_add(sb, ",")
          call sb_add(sb, '"' // escape_str(trim(keys(i))) // '"')
          call sb_add(sb, ":")
          call write_value(sb, dyn_copy(dyn_dict_get(v, &
                           trim(keys(i)))))
        end do
        call sb_add(sb, "}")
      end block
    case default
      call sb_add(sb, "null")
    end select
  end subroutine write_value

  function escape_str(s) result(out)
    character(*), intent(in) :: s
    character(:), allocatable :: out
    type(str_builder) :: sb
    integer :: i, b
    character(len=6) :: uesc
    character(len=*), parameter :: HD = "0123456789abcdef"
    call sb_init(sb)
    do i = 1, len(s)
      b = iachar(s(i:i))
      select case (b)
      case (34)
        call sb_add(sb, '\"')
      case (92)
        call sb_add(sb, '\\')
      case (8)
        call sb_add(sb, '\b')
      case (12)
        call sb_add(sb, '\f')
      case (10)
        call sb_add(sb, '\n')
      case (13)
        call sb_add(sb, '\r')
      case (9)
        call sb_add(sb, '\t')
      case (0:7, 11, 14:31)
        uesc = "\u00" // HD(b / 16 + 1:b / 16 + 1) // &
               HD(mod(b, 16) + 1:mod(b, 16) + 1)
        call sb_add(sb, trim(uesc))
      case default
        call sb_add(sb, s(i:i))
      end select
    end do
    out = sb_text(sb)
  end function escape_str

end module f3dc_emit_timeline
