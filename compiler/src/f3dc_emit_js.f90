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
  use, intrinsic :: iso_fortran_env, only: int64
  use f3dc_dyn
  use f3dc_str, only: str_replace
  use f3dc_emit_common, only: header_stamp, json_dumps, NL
  use f3dc_emit_json, only: FORMAT_NAME, FORMAT_VERSION
  use f3dc_ir, only: ir_scene, ir_scene_from_dict, ir_scene_to_dict
  implicit none
  private

  public :: emit_js
  ! C1: typed entry point (the dyn emit_js below is a wrapper that
  ! converts once via ir_scene_from_dict and delegates).
  public :: emit_js_typed

contains

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
