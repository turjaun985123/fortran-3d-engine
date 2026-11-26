! f3dc_emit_js.f90 -- JS emission for the native Forge3D compiler.
! Port of tools/f3dc/emit_js.py (seat B14); contract:
! compiler/DESIGN.md.  Free subroutines only.
!
! Output shape (byte-exact with emit_js.py):
!   1. the "//" header stamp from f3dc_emit_common (sha256 of the
!      v2 scene dict's canonical JSON),
!   2. a window shim line,
!   3. window.F3D_SCENE = <compact JSON>;
!   4. the fixed bootstrap block.
!
! Interface mapping: Python takes the typed IR object; _v2_dict()
! round-trips emit_json_v2's text through json.loads, so the dict
! the payload serialises is the v2 dict (to_dict + format/version)
! IN SORTED KEY ORDER.  The Fortran pipeline scene dyn is the RAW
! scene (with pipeline-only keys such as "base_dir"), so emit_js
! builds the v2 dict through f3dc_ir's ir_to_dict -- exactly
! Python's to_dict call -- stamps format/version, and serialises
! it compactly with sorted keys: identical bytes to the Python
! pipeline path (cli.py always passes an IR object).  Python's
! dict-input branch of _v2_dict (verbatim dict, insertion order)
! is NOT mirrored; see the report.
!
! EXT DISPATCH POINTS: emit_js.py has none -- scene "extensions"
! are opaque data serialised verbatim inside the payload, and all
! rendering lives in runtime/f3d.js (B28), which is never emitted
! here.  Sidecar JS from ext_* modules is produced by cli/driver
! layers, not by this emitter.
module f3dc_emit_js
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn
  use f3dc_str, only: str_replace
  use f3dc_emit_common, only: header_stamp, json_dumps, NL
  use f3dc_emit_json, only: FORMAT_NAME, FORMAT_VERSION
  use f3dc_ir, only: ir_scene, ir_scene_from_dict, ir_scene_to_dict
  use f3dc_val_timeline, only: timeline_fragment
  implicit none
  private

  public :: emit_js
  ! C1: typed entry point (the dyn emit_js below is a wrapper that
  ! converts once via ir_scene_from_dict and delegates).
  public :: emit_js_typed
  ! Wave 4 S2: the compiled-viewer timeline descriptor (ANIM-PLAN
  ! SS4.4), shared with f3dc_emit_html (which inlines the
  ! f3d-timeline.js evaluator exactly when this reports one).
  public :: emit_js_timeline_descriptor

contains

  ! ==================================================================
  ! Wave 4 S2: timeline descriptor for the compiled viewer.
  !
  ! ANIM-PLAN SS4.4: "The compiler emits a `timeline` object
  ! (duration, fps, frames) into the compiled viewer -- no new
  ! route needed for transport."  The descriptor rides INSIDE the
  ! scene blob (window.F3D_SCENE = {..., "timeline": {...}}), as a
  ! sibling key next to the scene data the runtime's create()
  ! already receives, so the runtime slice can surface it as
  ! api.timeline from the same argument it is handed today.
  !
  ! Values mirror the Timeline IR's canonical ones
  ! (docs/TIMELINE-FORMAT.md): fps is the reduced rational
  ! {num, den} and duration_frames / frames are integer frames;
  ! duration_seconds is a convenience derived FROM the frames
  ! (frames * den / num), never the other way round.
  !
  ! The fps / duration / content rules below are a per-scene
  ! mirror of f3dc_emit_timeline's tl_finalize + build_scene,
  ! applied to the validator's per-scene fragment
  ! (f3dc_val_timeline's timeline_fragment side channel -- the
  ! same data tl_add_scene consumes): fps = film header, else
  ! render fps, else first keys-track fps, else first anim fps,
  ! else 30; duration = the render's explicit duration, else the
  ! latest end among anims / dialogue / camera keys / keys
  ! tracks; content = film mode, or any anims / dialogue /
  ! camera keys / keys tracks.  A compiled viewer is a
  ! SINGLE-scene viewer (multi-scene builds emit one HTML per
  ! chunk), so the descriptor describes THIS scene's span: for
  ! examples/anim-golden.f3d that is 28 frames (stage) and 20
  ! frames (leap) at the film's 24/1 fps, matching the spans of
  ! build/anim-golden.timeline.json (48 frames total).
  !
  ! No timeline content -> HAS=.false. and the caller adds NO
  ! bytes: stills stay byte-identical.  The fragment is guarded
  ! by scene name: when the fragment's scene_name and the
  ! scene's "name" are both known and differ, the fragment
  ! belongs to another program (stale module state in a caller
  ! that emits without re-validating) and no descriptor is
  ! produced.
  ! ==================================================================

  !> Numeric field of a dict (int or real), emit_timeline's dnum.
  subroutine tl_dnum(d, key, x, has)
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
  end subroutine tl_dnum

  integer(int64) function tl_gcd(a, b) result(g)
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
  end function tl_gcd

  subroutine emit_js_timeline_descriptor(scene, tl, has)
    type(dyn), intent(in) :: scene
    type(dyn), intent(out) :: tl
    logical, intent(out) :: has
    type(dyn) :: frag, v, lst, trk, fpsd
    real(real64) :: rate, dur_sec, x, y
    integer(int64) :: fps_num, fps_den, g, frames
    integer :: i, k, q
    logical :: hn, content
    has = .false.
    tl = dyn_null()
    frag = timeline_fragment()
    if (frag%kind /= DYN_K_DICT) return
    ! Stale-fragment guard (see header): both names known and
    ! different -> not this scene's fragment.
    v = dyn_dict_get(scene, "name")
    if (v%kind == DYN_K_STR) then
      if (len(v%s) > 0) then
        lst = dyn_dict_get(frag, "scene_name")
        if (lst%kind == DYN_K_STR) then
          if (len(lst%s) > 0 .and. lst%s /= v%s) return
        end if
      end if
    end if
    ! ---- content test (emit_timeline build_scene's rule)
    content = .false.
    v = dyn_dict_get(frag, "is_film")
    if (v%kind == DYN_K_BOOL .and. v%b) content = .true.
    if (dyn_list_len(dyn_dict_get(frag, "anims")) > 0) &
      content = .true.
    if (dyn_list_len(dyn_dict_get(frag, "dialogue")) > 0) &
      content = .true.
    if (dyn_list_len(dyn_dict_get(frag, "camera_keys")) > 0) &
      content = .true.
    v = dyn_dict_get(frag, "keys_tracks")
    if (v%kind == DYN_K_DICT .and. dyn_dict_len(v) > 0) &
      content = .true.
    if (.not. content) return
    ! ---- fps (tl_finalize's resolution order, one scene)
    rate = 0.0_real64
    call tl_dnum(frag, "film_fps", rate, hn)
    if (.not. hn) rate = 0.0_real64
    if (rate <= 0.0_real64) then
      call tl_dnum(frag, "render_fps", rate, hn)
      if (.not. hn) rate = 0.0_real64
    end if
    if (rate <= 0.0_real64) then
      v = dyn_dict_get(frag, "keys_tracks")
      if (v%kind == DYN_K_DICT) then
        do k = 1, dyn_dict_len(v)
          call tl_dnum(dyn_dict_value_at(v, k), "fps", rate, hn)
          if (hn) exit
          rate = 0.0_real64
        end do
      end if
    end if
    if (rate <= 0.0_real64) then
      lst = dyn_dict_get(frag, "anims")
      if (dyn_list_len(lst) > 0) then
        call tl_dnum(dyn_list_at(lst, 1), "fps", rate, hn)
        if (.not. hn) rate = 0.0_real64
      end if
    end if
    if (rate <= 0.0_real64) rate = 30.0_real64
    if (rate == floor(rate) .and. abs(rate) < 9.0e15_real64) then
      fps_num = int(rate, int64)
      fps_den = 1_int64
    else
      fps_num = nint(rate * 1000.0_real64, int64)
      fps_den = 1000_int64
    end if
    g = tl_gcd(fps_num, fps_den)
    fps_num = fps_num / g
    fps_den = fps_den / g
    ! ---- duration in seconds (build_scene's rule, one scene)
    dur_sec = 0.0_real64
    call tl_dnum(frag, "render_duration", x, hn)
    if (hn) then
      dur_sec = x
    else
      lst = dyn_dict_get(frag, "anims")
      do i = 1, dyn_list_len(lst)
        call tl_dnum(dyn_list_at(lst, i), "_start", x, hn)
        if (.not. hn) x = 0.0_real64
        call tl_dnum(dyn_list_at(lst, i), "duration", y, hn)
        if (.not. hn) y = 0.0_real64
        dur_sec = max(dur_sec, x + y)
      end do
      lst = dyn_dict_get(frag, "dialogue")
      do i = 1, dyn_list_len(lst)
        call tl_dnum(dyn_list_at(lst, i), "start", x, hn)
        if (.not. hn) x = 0.0_real64
        call tl_dnum(dyn_list_at(lst, i), "duration", y, hn)
        if (.not. hn) y = 0.0_real64
        dur_sec = max(dur_sec, x + y)
      end do
      lst = dyn_dict_get(frag, "camera_keys")
      do i = 1, dyn_list_len(lst)
        call tl_dnum(dyn_list_at(lst, i), "time", x, hn)
        if (hn) dur_sec = max(dur_sec, x)
      end do
      v = dyn_dict_get(frag, "keys_tracks")
      if (v%kind == DYN_K_DICT) then
        do k = 1, dyn_dict_len(v)
          trk = dyn_dict_value_at(v, k)
          block
            real(real64) :: tfps, tend
            logical :: has_fps
            type(dyn) :: klist
            call tl_dnum(trk, "fps", tfps, has_fps)
            if (.not. has_fps) tfps = 0.0_real64
            call tl_dnum(trk, "duration", tend, hn)
            if (.not. hn) tend = 0.0_real64
            if (tfps > 0.0_real64) tend = tend / tfps
            dur_sec = max(dur_sec, tend)
            klist = dyn_dict_get(trk, "keys")
            do q = 1, dyn_list_len(klist)
              call tl_dnum(dyn_list_at(klist, q), "time", tend, &
                           hn)
              if (.not. hn) cycle
              if (tfps > 0.0_real64) tend = tend / tfps
              dur_sec = max(dur_sec, tend)
            end do
          end block
        end do
      end if
    end if
    frames = nint(dur_sec * real(fps_num, real64) / &
                  real(fps_den, real64), int64)
    if (frames < 0_int64) frames = 0_int64
    ! ---- assemble {duration, duration_frames,
    ! duration_seconds, fps, frames}; key order in the payload
    ! is json_dumps' sorted order, as for every other key of
    ! the scene blob.  "duration" is the ANIM-PLAN SS4.4 name
    ! for the seconds value; "duration_seconds" is the explicit
    ! alias of the same number (the runtime reads "duration"
    ! first, then frames/fps).
    tl = dyn_dict()
    call dyn_dict_set(tl, "duration_frames", dyn_int(frames))
    call dyn_dict_set(tl, "frames", dyn_int(frames))
    fpsd = dyn_dict()
    call dyn_dict_set(fpsd, "num", dyn_int(fps_num))
    call dyn_dict_set(fpsd, "den", dyn_int(fps_den))
    call dyn_dict_set(tl, "fps", fpsd)
    call dyn_dict_set(tl, "duration", &
         dyn_real(real(frames, real64) * real(fps_den, real64) / &
                  real(fps_num, real64)))
    call dyn_dict_set(tl, "duration_seconds", &
         dyn_real(real(frames, real64) * real(fps_den, real64) / &
                  real(fps_num, real64)))
    has = .true.
  end subroutine emit_js_timeline_descriptor

  !> The fixed bootstrap text of emit_js.py (_BOOTSTRAP), ending
  !! with a trailing newline.
  function bootstrap_text() result(out)
    character(len=:), allocatable :: out
    out = &
      ";(function () {" // NL // &
      "  try {" // NL // &
      "    if (typeof window === ""undefined"" || typeof document === ""undefined"") return;" // NL // &
      "    var run = function () {" // NL // &
      "      try {" // NL // &
      "        if (typeof window.F3D === ""undefined"" || !window.F3D) return;" // NL // &
      "        if (typeof window.F3D.auto !== ""function"") return;" // NL // &
      "        if (typeof document.querySelector !== ""function"") return;" // NL // &
      "        if (!document.querySelector(""f3d-view, canvas#f3d-canvas"")) return;" // NL // &
      "        window.F3D.auto(window.F3D_SCENE);" // NL // &
      "      } catch (e) {}" // NL // &
      "    };" // NL // &
      "    if (typeof document !== ""undefined"" && document.readyState === ""loading"" &&" // NL // &
      "        typeof document.addEventListener === ""function"") {" // NL // &
      "      document.addEventListener(""DOMContentLoaded"", run);" // NL // &
      "    } else if (typeof document !== ""undefined"" &&" // NL // &
      "               (document.readyState === ""interactive"" ||" // NL // &
      "                document.readyState === ""complete"")) {" // NL // &
      "      run();" // NL // &
      "    } else if (typeof document !== ""undefined"" &&" // NL // &
      "               typeof document.addEventListener === ""function"") {" // NL // &
      "      document.addEventListener(""DOMContentLoaded"", run);" // NL // &
      "    }" // NL // &
      "  } catch (e) {}" // NL // &
      "})();" // NL
  end function bootstrap_text

  !> emit_js._compact_json: js_json, then make the text safe to
  !! inline: "</" -> "<\/" and U+2028/U+2029 -> literal escapes.
  subroutine compact_json(data, out)
    type(dyn), intent(in) :: data
    character(len=:), allocatable, intent(out) :: out
    character(len=:), allocatable :: text
    ! The payload must carry the v2 dict in sorted key order (the
    ! Python json.loads round-trip order); json_dumps with
    ! sort_keys gives exactly that, compact + ensure_ascii=False.
    call json_dumps(data, .true., .false., 0, text)
    out = str_replace(text, "</", "<\/")
    out = str_replace(out, achar(226) // achar(128) // achar(168), &
                      "\u2028")
    out = str_replace(out, achar(226) // achar(128) // achar(169), &
                      "\u2029")
  end subroutine compact_json


  !> emit_js.emit_js (typed, C1).
  !! source_name resolution mirrors Python: explicit argument,
  !! else the typed scene's "name" when non-empty, else "scene".
  subroutine emit_js_typed(scene, text, source_name)
    type(ir_scene), intent(in) :: scene
    character(len=:), allocatable, intent(out) :: text
    character(len=*), intent(in), optional :: source_name
    type(dyn) :: data
    character(len=:), allocatable :: src, payload, header

    data = ir_scene_to_dict(scene)
    call dyn_dict_set(data, "format", dyn_str(FORMAT_NAME))
    call dyn_dict_set(data, "version", &
                      dyn_int(int(FORMAT_VERSION, int64)))

    ! Wave 4 S2: the timeline descriptor as a sibling key of the
    ! scene blob (see emit_js_timeline_descriptor).  Added BEFORE
    ! the header stamp + serialisation so the payload hash covers
    ! it, exactly like format/version; absent for stills, whose
    ! payload (and hash) stay byte-identical.
    block
      type(dyn) :: tl
      logical :: has_tl
      call emit_js_timeline_descriptor(data, tl, has_tl)
      if (has_tl) call dyn_dict_set(data, "timeline", tl)
    end block

    if (present(source_name)) then
      if (len(source_name) > 0) then
        src = source_name
      end if
    end if
    if (.not. allocated(src)) then
      if (scene%name%present .and. allocated(scene%name%s)) then
        if (len(scene%name%s) > 0) src = scene%name%s
      end if
    end if
    if (.not. allocated(src)) src = "scene"

    call compact_json(data, payload)
    call header_stamp(src, header, obj=data, comment="//")
    text = header // NL // &
           'if (typeof window === "undefined" && typeof globalThis !== "undefined")' // &
           " { var window = globalThis; }" // NL // &
           "window.F3D_SCENE = " // payload // ";" // NL // &
           bootstrap_text()
    call dyn_free(data)
  end subroutine emit_js_typed

  !> emit_js.emit_js(ir, source_name=None): dyn boundary wrapper
  !! (old signature; converts once via ir_scene_from_dict).
  subroutine emit_js(ir, text, source_name)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    character(len=*), intent(in), optional :: source_name
    if (present(source_name)) then
      call emit_js_typed(ir_scene_from_dict(ir), text, source_name)
    else
      call emit_js_typed(ir_scene_from_dict(ir), text)
    end if
  end subroutine emit_js

end module f3dc_emit_js
