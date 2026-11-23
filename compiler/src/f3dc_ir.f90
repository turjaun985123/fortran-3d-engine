! f3dc_ir.f90 -- frozen Typed IR (ir_version=1) for the native Forge3D
! compiler.  Port of tools/f3dc/ir_nodes.py (read in full).
! Port contract: compiler/DESIGN.md.
!
! IR nodes are dyn DICTS (module f3dc_dyn) whose keys are exactly the
! Python dataclass field names, in declaration order; vec3 / colour
! tuples are dyn lists, None is dyn_null, and int-valued fields stay
! dyn_int while float-valued fields stay dyn_real (the Python types
! are mirrored exactly -- e.g. IRCamera.fov defaults to the REAL 60.0
! here, whereas desugar's DEFAULT_CAMERA carries the INT 60).
!
! Mirror map (ir_nodes.py -> this module):
!   IR_VERSION            -> IR_VERSION parameter (= 1)
!   IRCamera/IRLight/IRObject/IRAnim/IROutput/IRScene (dataclasses)
!                         -> ir_camera_default / ir_camera_make,
!                            ir_light_default / ir_light_make,
!                            ir_object_default / ir_object_make,
!                            ir_anim_default / ir_anim_make,
!                            ir_output_default / ir_output_make,
!                            ir_scene_default / ir_scene_make
!                            (each returns a fresh dyn dict)
!   NAMED_COLORS          -> ir_named_color(name, rgb, found)
!   PALETTE_FACES         -> ir_palette_face(idx, rgb, found), 1-based
!                            in mesh.f90 face order (south, east,
!                            north, west, top, bottom)
!   EXTENSION_REGISTRY / register_extension / apply_extensions
!                         -> ir_register_extension / ir_apply_extensions
!                            (+ ir_extension_count / _name_at /
!                            ir_clear_extensions); see HOOKS below.
!   parse_color           -> ir_parse_color (bag form) and
!                            ir_parse_color_nobag (the Python bag=None
!                            form, which raises ValueError there)
!   _json_safe            -> json_safe (identity on dyn, see note)
!   _restore_triangles    -> restore_triangles (identity, see note)
!   to_dict / from_dict   -> ir_to_dict / ir_from_dict
!   to_json / from_json   -> ir_to_json / ir_from_json
!   json.dumps itself     -> ir_json_write (dyn -> JSON text, Python
!                            separators / ensure_ascii escaping)
!   json.loads            -> ir_json_parse (JSON text -> dyn)
!
! NOTE on tuple/list: dyn has a single list kind, so Python's
! tuple->list conversion in _json_safe and the list->tuple restoration
! in _restore_triangles are both the identity on dyn values (a deep
! copy); the JSON text produced is identical either way.
!
! HOOKS (extension dispatch): ir_nodes.py keeps a process-global
! EXTENSION_REGISTRY mapping names to callables fn(scene, bag) (with a
! one-argument fn(scene) fallback on TypeError) that may mutate the
! scene or return a replacement.  Fortran procedure pointers take one
! fixed signature, so the registry here stores pointers to
! subroutines with the abstract interface ir_ext_iface(scene, bag):
! scene is intent(inout), so "return a replacement scene" is expressed
! by assigning the replacement to scene, and the one-argument fallback
! collapses into the same signature (an extension that ignores bag
! simply does not use it).  Registration order is preserved and
! re-registering a name replaces its procedure in place, exactly like
! Python dict assignment.  Core paths work with an empty registry
! (ir_apply_extensions is then the identity); a future f3dc_ext_*.f90
! module registers by calling ir_register_extension from its own
! register subroutine, which the driver / validate stage invokes.
! No type-bound procedures are used anywhere (flang build rule).
module f3dc_ir
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, &
                      dyn_dict_get, dyn_dict_set, dyn_dict_has, &
                      dyn_dict_len, dyn_dict_key_at, &
                      dyn_dict_value_at, &
                      dyn_list_push, dyn_list_len, dyn_list_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real, to_lower, &
                      str_builder, sb_init, sb_add, sb_text
  use f3dc_errors, only: error_bag_t, diagnostic_t, make_diagnostic, &
                         error_bag_add, json_escape
  implicit none
  private

  public :: IR_VERSION
  public :: ir_ext_iface
  public :: ir_register_extension, ir_apply_extensions
  public :: ir_extension_count, ir_extension_name_at, &
            ir_clear_extensions
  public :: ir_named_color, ir_palette_face, ir_named_color_count, &
            ir_named_color_name_at
  public :: ir_vec3_ints, ir_vec3_mixed
  public :: ir_camera_default, ir_camera_make
  public :: ir_light_default, ir_light_make
  public :: ir_object_default, ir_object_make
  public :: ir_anim_default, ir_anim_make
  public :: ir_output_default, ir_output_make
  public :: ir_scene_default, ir_scene_make, ir_scene_set_source_map
  public :: ir_parse_color, ir_parse_color_nobag
  public :: ir_to_dict, ir_from_dict, ir_to_json, ir_from_json
  public :: ir_json_write, ir_json_parse

  integer, parameter :: IR_VERSION = 1

  ! ------------------------------------------------------------------
  ! Extension registry (see HOOKS in the header)
  ! ------------------------------------------------------------------

  abstract interface
    !> Extension procedure: fn(scene, bag); mutate scene in place or
    !! assign a replacement scene to it (Python's return value).
    subroutine ir_ext_iface(scene, bag)
      import :: dyn, error_bag_t
      type(dyn), intent(inout) :: scene
      type(error_bag_t), intent(inout) :: bag
    end subroutine ir_ext_iface
  end interface

  type :: ext_entry
    character(len=:), allocatable :: name
    procedure(ir_ext_iface), pointer, nopass :: fn => null()
  end type ext_entry

  type(ext_entry), allocatable :: registry(:)
  integer :: n_registry = 0

  !> State of the JSON parser (json.loads port; see ir_json_parse).
  type :: json_parser
    character(len=:), allocatable :: s
    integer :: pos = 1
    logical :: ok = .true.
  end type json_parser

  ! ------------------------------------------------------------------
  ! NAMED_COLORS (ir_nodes.py): name -> (r, g, b), dict order kept.
  ! ------------------------------------------------------------------
  integer, parameter :: N_COLORS = 13
  character(len=8), parameter :: COLOR_NAMES(N_COLORS) = [ &
    "red     ", "green   ", "blue    ", "yellow  ", "magenta ", &
    "cyan    ", "orange  ", "purple  ", "pink    ", "white   ", &
    "black   ", "gray    ", "grey    "]
  integer, parameter :: COLOR_RGB(3, N_COLORS) = reshape([ &
    220, 60, 60,    60, 220, 60,    60, 100, 240,  240, 220, 50, &
    200, 80, 220,   60, 220, 220,   240, 140, 40,  140, 80, 200, &
    240, 150, 190,  240, 240, 240,  20, 20, 25,    140, 140, 145, &
    140, 140, 145], [3, N_COLORS])
  ! PALETTE_FACES indices into COLOR_NAMES/RGB, mesh.f90 face order:
  ! south red, east green, north blue, west yellow, top magenta,
  ! bottom cyan.
  integer, parameter :: PALETTE_IDX(6) = [1, 2, 3, 4, 5, 6]

contains

  ! ==================================================================
  ! Small helpers
  ! ==================================================================

  !> dyn list of three dyn_ints (a Python int tuple).
  function ir_vec3_ints(a, b, c) result(v)
    integer, intent(in) :: a, b, c
    type(dyn) :: v
    v = dyn_list()
    call dyn_list_push(v, dyn_int(int(a, int64)))
    call dyn_list_push(v, dyn_int(int(b, int64)))
    call dyn_list_push(v, dyn_int(int(c, int64)))
  end function ir_vec3_ints

  !> dyn list holding the three values as given (mixed int/real tuple).
  function ir_vec3_mixed(a, b, c) result(v)
    type(dyn), intent(in) :: a, b, c
    type(dyn) :: v
    v = dyn_list()
    call dyn_list_push(v, a)
    call dyn_list_push(v, b)
    call dyn_list_push(v, c)
  end function ir_vec3_mixed

  !> dict get with a default when the key is absent (Python .get with
  !! a default; a stored null is returned as-is, as in Python).
  function dget_or(d, key, def) result(v)
    type(dyn), intent(in) :: d, def
    character(len=*), intent(in) :: key
    type(dyn) :: v
    if (dyn_dict_has(d, key)) then
      v = dyn_dict_get(d, key)
    else
      v = dyn_copy(def)
    end if
  end function dget_or

  subroutine dset(d, key, val)
    type(dyn), intent(inout) :: d
    character(len=*), intent(in) :: key
    type(dyn), intent(in) :: val
    call dyn_dict_set(d, key, val)
  end subroutine dset

  ! ==================================================================
  ! Extension registry
  ! ==================================================================

  !> register_extension(name, fn): insert, or replace in place when
  !! the name is already registered (Python dict semantics).
  subroutine ir_register_extension(name, fn)
    character(len=*), intent(in) :: name
    procedure(ir_ext_iface) :: fn
    type(ext_entry), allocatable :: tmp(:)
    integer :: k
    do k = 1, n_registry
      if (allocated(registry(k)%name)) then
        if (len(registry(k)%name) == len(name) .and. &
            registry(k)%name == name) then
          registry(k)%fn => fn
          return
        end if
      end if
    end do
    if (.not. allocated(registry)) allocate (registry(0))
    if (n_registry >= size(registry)) then
      allocate (tmp(max(4, 2 * size(registry))))
      do k = 1, n_registry
        if (allocated(registry(k)%name)) tmp(k)%name = registry(k)%name
        tmp(k)%fn => registry(k)%fn
      end do
      call move_alloc(tmp, registry)
    end if
    n_registry = n_registry + 1
    registry(n_registry)%name = name
    registry(n_registry)%fn => fn
  end subroutine ir_register_extension

  !> apply_extensions(scene, bag): run every registered extension in
  !! registration order; each may mutate or replace scene in place.
  subroutine ir_apply_extensions(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    integer :: k
    do k = 1, n_registry
      if (associated(registry(k)%fn)) &
        call registry(k)%fn(scene, bag)
    end do
  end subroutine ir_apply_extensions

  pure integer function ir_extension_count()
    ir_extension_count = n_registry
  end function ir_extension_count

  function ir_extension_name_at(idx) result(out)
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > n_registry) then
      out = ""
    else if (allocated(registry(idx)%name)) then
      out = registry(idx)%name
    else
      out = ""
    end if
  end function ir_extension_name_at

  !> Test support: empty the registry (Python tests rebind
  !! EXTENSION_REGISTRY; no Python runtime counterpart is required).
  subroutine ir_clear_extensions()
    if (allocated(registry)) deallocate (registry)
    n_registry = 0
  end subroutine ir_clear_extensions

  ! ==================================================================
  ! Colours
  ! ==================================================================

  pure integer function ir_named_color_count()
    ir_named_color_count = N_COLORS
  end function ir_named_color_count

  function ir_named_color_name_at(idx) result(out)
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > N_COLORS) then
      out = ""
    else
      out = trim(COLOR_NAMES(idx))
    end if
  end function ir_named_color_name_at

  !> NAMED_COLORS lookup (exact key, as in Python; parse_color does
  !! the case-folding).  rgb is a dyn list of 3 dyn_ints on success.
  subroutine ir_named_color(name, rgb, found)
    character(len=*), intent(in) :: name
    type(dyn), intent(out) :: rgb
    logical, intent(out) :: found
    integer :: k
    found = .false.
    rgb = dyn_null()
    do k = 1, N_COLORS
      if (trim(COLOR_NAMES(k)) == name) then
        rgb = ir_vec3_ints(COLOR_RGB(1, k), COLOR_RGB(2, k), &
                           COLOR_RGB(3, k))
        found = .true.
        return
      end if
    end do
  end subroutine ir_named_color

  !> PALETTE_FACES(idx), idx 1..6 in mesh.f90 face order.
  subroutine ir_palette_face(idx, rgb, found)
    integer, intent(in) :: idx
    type(dyn), intent(out) :: rgb
    logical, intent(out) :: found
    integer :: k
    found = .false.
    rgb = dyn_null()
    if (idx < 1 .or. idx > 6) return
    k = PALETTE_IDX(idx)
    rgb = ir_vec3_ints(COLOR_RGB(1, k), COLOR_RGB(2, k), &
                       COLOR_RGB(3, k))
    found = .true.
  end subroutine ir_palette_face

  ! ==================================================================
  ! Node constructors (dataclass field order = dyn key order)
  ! ==================================================================

  function ir_camera_default() result(cam)
    type(dyn) :: cam
    cam = ir_camera_make( &
      ir_vec3_mixed(dyn_int(3_int64), dyn_real(2.5_real64), &
                    dyn_int(4_int64)), &
      ir_vec3_ints(0, 0, 0), ir_vec3_ints(0, 1, 0), &
      dyn_real(60.0_real64), dyn_real(0.1_real64), &
      dyn_real(100.0_real64))
  end function ir_camera_default

  function ir_camera_make(pos, target, up, fov, near, far) result(cam)
    type(dyn), intent(in) :: pos, target, up, fov, near, far
    type(dyn) :: cam
    cam = dyn_dict()
    call dset(cam, "pos", pos)
    call dset(cam, "target", target)
    call dset(cam, "up", up)
    call dset(cam, "fov", fov)
    call dset(cam, "near", near)
    call dset(cam, "far", far)
  end function ir_camera_make

  function ir_light_default() result(light)
    type(dyn) :: light
    light = ir_light_make("directional", &
      ir_vec3_mixed(dyn_real(-0.5_real64), dyn_int(-1_int64), &
                    dyn_real(-0.7_real64)), &
      ir_vec3_ints(255, 255, 255), dyn_real(1.0_real64))
  end function ir_light_default

  function ir_light_make(kind, direction, color, intensity) result(light)
    character(len=*), intent(in) :: kind
    type(dyn), intent(in) :: direction, color, intensity
    type(dyn) :: light
    light = dyn_dict()
    call dset(light, "kind", dyn_str(kind))
    call dset(light, "direction", direction)
    call dset(light, "color", color)
    call dset(light, "intensity", intensity)
  end function ir_light_make

  function ir_object_default(name, prim) result(obj)
    character(len=*), intent(in) :: name, prim
    type(dyn) :: obj
    obj = ir_object_make(name, prim, dyn_null(), &
      ir_vec3_ints(0, 0, 0), ir_vec3_ints(0, 0, 0), &
      ir_vec3_ints(1, 1, 1), dyn_real(2.0_real64), dyn_null(), &
      dyn_null(), dyn_null(), dyn_null(), "med", .true., "lambert", &
      dyn_null(), dyn_null(), dyn_dict())
  end function ir_object_default

  function ir_object_make(name, prim, color, pos, rotate, scale, &
                          size, size3, radius, height, segments, &
                          detail, capped, material, triangles, &
                          source_file, extensions) result(obj)
    character(len=*), intent(in) :: name, prim, detail, material
    type(dyn), intent(in) :: color, pos, rotate, scale, size, size3, &
                             radius, height, segments, triangles, &
                             source_file, extensions
    logical, intent(in) :: capped
    type(dyn) :: obj
    obj = dyn_dict()
    call dset(obj, "name", dyn_str(name))
    call dset(obj, "prim", dyn_str(prim))
    call dset(obj, "color", color)
    call dset(obj, "pos", pos)
    call dset(obj, "rotate", rotate)
    call dset(obj, "scale", scale)
    call dset(obj, "size", size)
    call dset(obj, "size3", size3)
    call dset(obj, "radius", radius)
    call dset(obj, "height", height)
    call dset(obj, "segments", segments)
    call dset(obj, "detail", dyn_str(detail))
    call dset(obj, "capped", dyn_bool(capped))
    call dset(obj, "material", dyn_str(material))
    call dset(obj, "triangles", triangles)
    call dset(obj, "source_file", source_file)
    call dset(obj, "extensions", extensions)
  end function ir_object_make

  function ir_anim_default(kind, target) result(anim)
    character(len=*), intent(in) :: kind, target
    type(dyn) :: anim
    anim = ir_anim_make(kind, target, "y", dyn_real(90.0_real64), &
                        dyn_real(5.0_real64), dyn_int(30_int64), &
                        "linear", "forever")
  end function ir_anim_default

  function ir_anim_make(kind, target, axis, speed, duration, fps, &
                        ease, loop) result(anim)
    character(len=*), intent(in) :: kind, target, axis, ease, loop
    type(dyn), intent(in) :: speed, duration, fps
    type(dyn) :: anim
    anim = dyn_dict()
    call dset(anim, "kind", dyn_str(kind))
    call dset(anim, "target", dyn_str(target))
    call dset(anim, "axis", dyn_str(axis))
    call dset(anim, "speed", speed)
    call dset(anim, "duration", duration)
    call dset(anim, "fps", fps)
    call dset(anim, "ease", dyn_str(ease))
    call dset(anim, "loop", dyn_str(loop))
  end function ir_anim_make

  function ir_output_default() result(out_node)
    type(dyn) :: out_node
    out_node = ir_output_make("render", dyn_null(), dyn_null(), &
                              dyn_null(), dyn_null())
  end function ir_output_default

  function ir_output_make(kind, path, format, width, height) &
      result(out_node)
    character(len=*), intent(in) :: kind
    type(dyn), intent(in) :: path, format, width, height
    type(dyn) :: out_node
    out_node = dyn_dict()
    call dset(out_node, "kind", dyn_str(kind))
    call dset(out_node, "path", path)
    call dset(out_node, "format", format)
    call dset(out_node, "width", width)
    call dset(out_node, "height", height)
  end function ir_output_make

  function ir_scene_default() result(scene)
    type(dyn) :: scene
    scene = ir_scene_make("untitled", dyn_int(640_int64), &
      dyn_int(480_int64), ir_vec3_ints(25, 25, 35), &
      ir_camera_default(), dyn_list(), dyn_list(), dyn_list(), &
      dyn_list(), dyn_dict())
  end function ir_scene_default

  function ir_scene_make(name, width, height, bg, camera, lights, &
                         objects, animations, outputs, extensions) &
      result(scene)
    character(len=*), intent(in) :: name
    type(dyn), intent(in) :: width, height, bg, camera, lights, &
                             objects, animations, outputs, extensions
    type(dyn) :: scene
    scene = dyn_dict()
    call dset(scene, "name", dyn_str(name))
    call dset(scene, "width", width)
    call dset(scene, "height", height)
    call dset(scene, "bg", bg)
    call dset(scene, "camera", camera)
    call dset(scene, "lights", lights)
    call dset(scene, "objects", objects)
    call dset(scene, "animations", animations)
    call dset(scene, "outputs", outputs)
    call dset(scene, "extensions", extensions)
  end function ir_scene_make

  !> scene.source_map = value (Python attribute assignment; the key
  !! lands last, matching the dataclass field order, and to_dict only
  !! serialises it when it is not null).
  subroutine ir_scene_set_source_map(scene, value)
    type(dyn), intent(inout) :: scene
    type(dyn), intent(in) :: value
    call dyn_dict_set(scene, "source_map", value)
  end subroutine ir_scene_set_source_map

  ! ==================================================================
  ! parse_color (ir_nodes.py) + _report_e202
  ! ==================================================================

  !> Python repr() of a dyn value, for the E202 message ("unknown
  !! color %r").  Strings use repr quoting; a dyn list renders in
  !! Python list style (dyn conflates tuple/list -- see header).
  recursive function repr_dyn(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    type(str_builder) :: sb
    integer :: k
    select case (v%kind)
    case (DYN_K_NULL)
      out = "None"
    case (DYN_K_BOOL)
      if (v%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = trim(fmt_int(v%i))
    case (DYN_K_REAL)
      out = trim(fmt_real(v%r))
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = repr_str(v%s)
      else
        out = "''"
      end if
    case (DYN_K_LIST)
      ! Dyn lists stand for Python tuples in this compiler (every
      ! vec3 / colour triple is a tuple in the AST), so repr renders
      ! tuple style; a genuine Python list input would print with
      ! brackets there -- the one place the conflation shows.
      call sb_init(sb)
      call sb_add(sb, "(")
      do k = 1, dyn_list_len(v)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, repr_dyn(dyn_list_at(v, k)))
      end do
      if (dyn_list_len(v) == 1) call sb_add(sb, ",")
      call sb_add(sb, ")")
      out = sb_text(sb)
    case (DYN_K_DICT)
      call sb_init(sb)
      call sb_add(sb, "{")
      do k = 1, dyn_dict_len(v)
        if (k > 1) call sb_add(sb, ", ")
        call sb_add(sb, repr_str(dyn_dict_key_at(v, k)) // ": " // &
              repr_dyn(dyn_dict_value_at(v, k)))
      end do
      call sb_add(sb, "}")
      out = sb_text(sb)
    case default
      out = "None"
    end select
  end function repr_dyn

  !> Python repr(str): single quotes unless the string contains a
  !! single quote and no double quote; backslash / quote / control
  !! characters escaped (ASCII subset of CPython's repr).
  function repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out, body
    type(str_builder) :: sb
    character(len=1) :: quote
    integer :: i, c
    if (index(s, "'") > 0 .and. index(s, '"') == 0) then
      quote = '"'
    else
      quote = "'"
    end if
    call sb_init(sb)
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (s(i:i) == quote .or. c == 92) then
        call sb_add(sb, "\" // s(i:i))
      else if (c == 10) then
        call sb_add(sb, "\n")
      else if (c == 13) then
        call sb_add(sb, "\r")
      else if (c == 9) then
        call sb_add(sb, "\t")
      else if (c < 32 .or. c == 127) then
        block
          character(len=8) :: hb
          write (hb, "(A,Z2.2)") "\x", c
          call sb_add(sb, trim(hb))
        end block
      else
        call sb_add(sb, s(i:i))
      end if
    end do
    body = sb_text(sb)
    out = quote // body // quote
  end function repr_str

  !> _report_e202 against the real ErrorBag: Diagnostic(code=E202,
  !! severity=error, message, span=None, help=...).  Dyn values carry
  !! no spans (the parser stores span as null), so the diagnostic is
  !! span-less, matching a Python span of None.
  subroutine report_e202(bag, raw)
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(in) :: raw
    call error_bag_add(bag, make_diagnostic( &
      "E202", "error", "unknown color " // repr_dyn(raw), &
      why="", help="use a named color, #rrggbb, or rgb(r,g,b)"))
  end subroutine report_e202

  !> Strip ASCII whitespace from both ends (Python str.strip covers
  !! Unicode spaces too; colour text is ASCII in practice).
  function strip_ws(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: a, b
    a = 1
    b = len(s)
    do while (a <= b)
      if (.not. is_ascii_ws(s(a:a))) exit
      a = a + 1
    end do
    do while (b >= a)
      if (.not. is_ascii_ws(s(b:b))) exit
      b = b - 1
    end do
    if (a > b) then
      out = ""
    else
      out = s(a:b)
    end if
  end function strip_ws

  pure logical function is_ascii_ws(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    is_ascii_ws = (c == 32 .or. (c >= 9 .and. c <= 13))
  end function is_ascii_ws

  pure integer function hex_val(ch)
    character(len=1), intent(in) :: ch
    integer :: c
    c = iachar(ch)
    if (c >= iachar("0") .and. c <= iachar("9")) then
      hex_val = c - iachar("0")
    else if (c >= iachar("a") .and. c <= iachar("f")) then
      hex_val = c - iachar("a") + 10
    else if (c >= iachar("A") .and. c <= iachar("F")) then
      hex_val = c - iachar("A") + 10
    else
      hex_val = -1
    end if
  end function hex_val

  !> Match ^#([0-9a-fA-F]{6})$ on the stripped text.
  subroutine match_hex(text, rgb, ok)
    character(len=*), intent(in) :: text
    type(dyn), intent(out) :: rgb
    logical, intent(out) :: ok
    integer :: vals(3), i, hi, lo
    ok = .false.
    rgb = dyn_null()
    if (len(text) /= 7) return
    if (text(1:1) /= "#") return
    do i = 1, 3
      hi = hex_val(text(2 * i:2 * i))
      lo = hex_val(text(2 * i + 1:2 * i + 1))
      if (hi < 0 .or. lo < 0) return
      vals(i) = hi * 16 + lo
    end do
    rgb = ir_vec3_ints(vals(1), vals(2), vals(3))
    ok = .true.
  end subroutine match_hex

  !> Match ^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\)$ with
  !! re.IGNORECASE on the stripped text.  \d / \s are the ASCII
  !! subsets here (Python re on str also matches Unicode digits /
  !! spaces -- a pathological-input divergence, noted in the report).
  subroutine match_rgb(text, rgb, ok)
    character(len=*), intent(in) :: text
    type(dyn), intent(out) :: rgb
    logical, intent(out) :: ok
    character(len=:), allocatable :: low
    integer :: pos, vals(3), part, ndig, v
    ok = .false.
    rgb = dyn_null()
    low = to_lower(text)
    if (len(low) < 4) return
    if (low(1:4) /= "rgb(") return
    pos = 5
    do part = 1, 3
      do while (pos <= len(low))
        if (.not. is_ascii_ws(low(pos:pos))) exit
        pos = pos + 1
      end do
      ndig = 0
      v = 0
      do while (pos <= len(low) .and. ndig < 4)
        if (low(pos:pos) < "0" .or. low(pos:pos) > "9") exit
        v = v * 10 + (iachar(low(pos:pos)) - iachar("0"))
        ndig = ndig + 1
        pos = pos + 1
      end do
      if (ndig == 0 .or. ndig > 3) return
      vals(part) = v
      do while (pos <= len(low))
        if (.not. is_ascii_ws(low(pos:pos))) exit
        pos = pos + 1
      end do
      if (part < 3) then
        if (pos > len(low)) return
        if (low(pos:pos) /= ",") return
        pos = pos + 1
      end if
    end do
    if (pos > len(low)) return
    if (low(pos:pos) /= ")") return
    pos = pos + 1
    if (pos /= len(low) + 1) return
    rgb = ir_vec3_ints(vals(1), vals(2), vals(3))
    ok = .true.
  end subroutine match_rgb

  !> Shared body of parse_color once a bag is known to exist.
  subroutine parse_color_impl(raw, bag, result, is_null)
    type(dyn), intent(in) :: raw
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: result
    logical, intent(out) :: is_null
    type(dyn) :: item
    character(len=:), allocatable :: text
    logical :: ok, in_range
    integer :: k
    result = dyn_null()
    is_null = .true.
    if (raw%kind == DYN_K_NULL) return
    if (raw%kind == DYN_K_LIST) then
      in_range = dyn_list_len(raw) == 3
      if (in_range) then
        do k = 1, 3
          item = dyn_list_at(raw, k)
          if (item%kind /= DYN_K_INT) in_range = .false.
          if (item%kind == DYN_K_INT) then
            if (item%i < 0_int64 .or. item%i > 255_int64) &
              in_range = .false.
          end if
        end do
      end if
      if (in_range) then
        result = dyn_list()
        do k = 1, 3
          call dyn_list_push(result, dyn_list_at(raw, k))
        end do
        is_null = .false.
      else
        call report_e202(bag, raw)
      end if
      return
    end if
    if (raw%kind /= DYN_K_STR) then
      call report_e202(bag, raw)
      return
    end if
    if (allocated(raw%s)) then
      text = strip_ws(raw%s)
    else
      text = ""
    end if
    call ir_named_color(to_lower(text), result, ok)
    if (ok) then
      is_null = .false.
      return
    end if
    call match_hex(text, result, ok)
    if (ok) then
      is_null = .false.
      return
    end if
    call match_rgb(text, result, ok)
    if (ok) then
      in_range = .true.
      do k = 1, 3
        item = dyn_list_at(result, k)
        if (item%i < 0_int64 .or. item%i > 255_int64) &
          in_range = .false.
      end do
      if (in_range) then
        is_null = .false.
      else
        result = dyn_null()
        call report_e202(bag, raw)
      end if
      return
    end if
    call report_e202(bag, raw)
  end subroutine parse_color_impl

  !> parse_color(raw, bag, span=None): result is a dyn list of three
  !! dyn_ints, or null (is_null=.true.) for None input and for any
  !! unknown / malformed / out-of-range colour (E202 reported).
  subroutine ir_parse_color(raw, bag, result, is_null)
    type(dyn), intent(in) :: raw
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(out) :: result
    logical, intent(out) :: is_null
    call parse_color_impl(raw, bag, result, is_null)
  end subroutine ir_parse_color

  !> parse_color with bag=None: Python returns None for None input
  !! and raises ValueError("E202: unknown color %r") for anything
  !! else unparseable; raised=.true. mirrors that raise (message in
  !! raised_msg).  Valid colours return normally.
  subroutine ir_parse_color_nobag(raw, result, is_null, raised, &
                                  raised_msg)
    type(dyn), intent(in) :: raw
    type(dyn), intent(out) :: result
    logical, intent(out) :: is_null, raised
    character(len=:), allocatable, intent(out) :: raised_msg
    type(error_bag_t) :: scratch
    integer :: before
    result = dyn_null()
    is_null = .true.
    raised = .false.
    raised_msg = ""
    if (raw%kind == DYN_K_NULL) return
    before = 0
    call parse_color_impl(raw, scratch, result, is_null)
    if (scratch%n > before .and. is_null) then
      raised = .true.
      raised_msg = "E202: unknown color " // repr_dyn(raw)
      result = dyn_null()
    end if
  end subroutine ir_parse_color_nobag

  ! ==================================================================
  ! Serialisation: to_dict / from_dict / to_json / from_json
  ! ==================================================================

  !> _json_safe: tuples become lists recursively.  Dyn has only
  !! lists, so this is a deep copy (see the header note).
  recursive function json_safe(v) result(out)
    type(dyn), intent(in) :: v
    type(dyn) :: out
    out = dyn_copy(v)
  end function json_safe

  !> _restore_triangles: leaf triples become tuples in Python; in
  !! dyn they are already lists, so this is a deep copy.
  recursive function restore_triangles(v) result(out)
    type(dyn), intent(in) :: v
    type(dyn) :: out
    out = dyn_copy(v)
  end function restore_triangles

  !> Tuple-or-None field as a fresh dyn list copy (or null).
  function list_or_null(v) result(out)
    type(dyn), intent(in) :: v
    type(dyn) :: out
    if (v%kind == DYN_K_NULL) then
      out = dyn_null()
    else
      out = dyn_copy(v)
    end if
  end function list_or_null

  !> to_dict(scene): JSON-safe dict stamped ir_version: 1, keys in
  !! exactly the Python order; source_map appended only when set.
  function ir_to_dict(scene) result(data)
    type(dyn), intent(in) :: scene
    type(dyn) :: data
    type(dyn) :: cam, sub, arr, item
    integer :: k
    data = dyn_dict()
    call dset(data, "ir_version", dyn_int(int(IR_VERSION, int64)))
    call dset(data, "name", dget_or(scene, "name", &
                                    dyn_str("untitled")))
    call dset(data, "width", dget_or(scene, "width", &
                                     dyn_int(640_int64)))
    call dset(data, "height", dget_or(scene, "height", &
                                      dyn_int(480_int64)))
    call dset(data, "bg", json_safe(dget_or(scene, "bg", &
                                            ir_vec3_ints(25, 25, 35))))
    cam = dget_or(scene, "camera", ir_camera_default())
    sub = dyn_dict()
    call dset(sub, "pos", json_safe(dget_or(cam, "pos", &
      ir_vec3_mixed(dyn_int(3_int64), dyn_real(2.5_real64), &
                    dyn_int(4_int64)))))
    call dset(sub, "target", json_safe(dget_or(cam, "target", &
                                               ir_vec3_ints(0, 0, 0))))
    call dset(sub, "up", json_safe(dget_or(cam, "up", &
                                           ir_vec3_ints(0, 1, 0))))
    call dset(sub, "fov", dget_or(cam, "fov", &
                                  dyn_real(60.0_real64)))
    call dset(sub, "near", dget_or(cam, "near", &
                                   dyn_real(0.1_real64)))
    call dset(sub, "far", dget_or(cam, "far", &
                                  dyn_real(100.0_real64)))
    call dset(data, "camera", sub)
    ! lights
    arr = dyn_list()
    item = dget_or(scene, "lights", dyn_list())
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: light, lsub
          light = dyn_list_at(item, k)
          lsub = dyn_dict()
          call dset(lsub, "kind", dget_or(light, "kind", &
                                          dyn_str("directional")))
          call dset(lsub, "direction", json_safe(dget_or( &
            light, "direction", ir_vec3_mixed( &
              dyn_real(-0.5_real64), dyn_int(-1_int64), &
              dyn_real(-0.7_real64)))))
          call dset(lsub, "color", json_safe(dget_or( &
            light, "color", ir_vec3_ints(255, 255, 255))))
          call dset(lsub, "intensity", dget_or(light, "intensity", &
                                               dyn_real(1.0_real64)))
          call dyn_list_push(arr, lsub)
        end block
      end do
    end if
    call dset(data, "lights", arr)
    ! objects
    arr = dyn_list()
    item = dget_or(scene, "objects", dyn_list())
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: obj, osub, ext
          obj = dyn_list_at(item, k)
          osub = dyn_dict()
          call dset(osub, "name", dyn_dict_get(obj, "name"))
          call dset(osub, "prim", dyn_dict_get(obj, "prim"))
          call dset(osub, "color", json_safe(list_or_null( &
            dyn_dict_get(obj, "color"))))
          call dset(osub, "pos", json_safe(dget_or(obj, "pos", &
                                                   ir_vec3_ints(0, 0, 0))))
          call dset(osub, "rotate", json_safe(dget_or( &
            obj, "rotate", ir_vec3_ints(0, 0, 0))))
          call dset(osub, "scale", json_safe(dget_or( &
            obj, "scale", ir_vec3_ints(1, 1, 1))))
          call dset(osub, "size", dget_or(obj, "size", &
                                          dyn_real(2.0_real64)))
          call dset(osub, "size3", json_safe(list_or_null( &
            dyn_dict_get(obj, "size3"))))
          call dset(osub, "radius", dyn_dict_get(obj, "radius"))
          call dset(osub, "height", dyn_dict_get(obj, "height"))
          call dset(osub, "segments", dyn_dict_get(obj, "segments"))
          call dset(osub, "detail", dget_or(obj, "detail", &
                                            dyn_str("med")))
          ! P1: "shading" is carried only when the IR object has it
          ! (validate sets it only for explicitly determined values),
          ! so objects without it serialise byte-identically.
          if (dyn_dict_has(obj, "shading")) &
            call dset(osub, "shading", dyn_dict_get(obj, "shading"))
          ! P3: "mirror" likewise carried only when present.
          if (dyn_dict_has(obj, "mirror")) &
            call dset(osub, "mirror", dyn_dict_get(obj, "mirror"))
          call dset(osub, "capped", dget_or(obj, "capped", &
                                            dyn_bool(.true.)))
          call dset(osub, "material", dget_or(obj, "material", &
                                              dyn_str("lambert")))
          call dset(osub, "triangles", json_safe( &
            dyn_dict_get(obj, "triangles")))
          call dset(osub, "source_file", &
                    dyn_dict_get(obj, "source_file"))
          ext = dyn_dict_get(obj, "extensions")
          if (ext%kind /= DYN_K_DICT) ext = dyn_dict()
          call dset(osub, "extensions", json_safe(ext))
          call dyn_list_push(arr, osub)
        end block
      end do
    end if
    call dset(data, "objects", arr)
    ! animations
    arr = dyn_list()
    item = dget_or(scene, "animations", dyn_list())
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: anim, asub
          anim = dyn_list_at(item, k)
          asub = dyn_dict()
          call dset(asub, "kind", dyn_dict_get(anim, "kind"))
          call dset(asub, "target", dyn_dict_get(anim, "target"))
          call dset(asub, "axis", dget_or(anim, "axis", &
                                          dyn_str("y")))
          call dset(asub, "speed", dget_or(anim, "speed", &
                                           dyn_real(90.0_real64)))
          call dset(asub, "duration", dget_or(anim, "duration", &
                                              dyn_real(5.0_real64)))
          call dset(asub, "fps", dget_or(anim, "fps", &
                                         dyn_int(30_int64)))
          call dset(asub, "ease", dget_or(anim, "ease", &
                                          dyn_str("linear")))
          call dset(asub, "loop", dget_or(anim, "loop", &
                                          dyn_str("forever")))
          call dyn_list_push(arr, asub)
        end block
      end do
    end if
    call dset(data, "animations", arr)
    ! outputs
    arr = dyn_list()
    item = dget_or(scene, "outputs", dyn_list())
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: outp, psub
          outp = dyn_list_at(item, k)
          psub = dyn_dict()
          call dset(psub, "kind", dget_or(outp, "kind", &
                                          dyn_str("render")))
          call dset(psub, "path", dyn_dict_get(outp, "path"))
          call dset(psub, "format", dyn_dict_get(outp, "format"))
          call dset(psub, "width", dyn_dict_get(outp, "width"))
          call dset(psub, "height", dyn_dict_get(outp, "height"))
          call dyn_list_push(arr, psub)
        end block
      end do
    end if
    call dset(data, "outputs", arr)
    block
      type(dyn) :: ext
      ext = dyn_dict_get(scene, "extensions")
      if (ext%kind /= DYN_K_DICT) ext = dyn_dict()
      call dset(data, "extensions", json_safe(ext))
    end block
    if (dyn_dict_has(scene, "source_map")) then
      item = dyn_dict_get(scene, "source_map")
      if (item%kind /= DYN_K_NULL) &
        call dset(data, "source_map", json_safe(item))
    end if
  end function ir_to_dict

  !> from_dict(d): rebuild a scene dyn from to_dict output, with
  !! exactly the Python defaults.  (Python raises TypeError for a
  !! non-dict and KeyError for a missing object name/prim; here a
  !! non-dict yields a default scene and missing keys yield null --
  !! malformed-input divergence, noted in the report.)
  function ir_from_dict(d) result(scene)
    type(dyn), intent(in) :: d
    type(dyn) :: scene
    type(dyn) :: cam_d, cam, arr, item
    integer :: k
    if (d%kind /= DYN_K_DICT) then
      scene = ir_scene_default()
      return
    end if
    cam_d = dyn_dict_get(d, "camera")
    if (cam_d%kind /= DYN_K_DICT) cam_d = dyn_dict()
    cam = ir_camera_make( &
      list_or_default(cam_d, "pos", ir_vec3_mixed( &
        dyn_int(3_int64), dyn_real(2.5_real64), dyn_int(4_int64))), &
      list_or_default(cam_d, "target", ir_vec3_ints(0, 0, 0)), &
      list_or_default(cam_d, "up", ir_vec3_ints(0, 1, 0)), &
      dget_or(cam_d, "fov", dyn_real(60.0_real64)), &
      dget_or(cam_d, "near", dyn_real(0.1_real64)), &
      dget_or(cam_d, "far", dyn_real(100.0_real64)))
    ! lights
    arr = dyn_list()
    item = dyn_dict_get(d, "lights")
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: light
          light = dyn_list_at(item, k)
          call dyn_list_push(arr, ir_light_make( &
            str_or(light, "kind", "directional"), &
            list_or_default(light, "direction", ir_vec3_mixed( &
              dyn_real(-0.5_real64), dyn_int(-1_int64), &
              dyn_real(-0.7_real64))), &
            list_or_default(light, "color", &
                            ir_vec3_ints(255, 255, 255)), &
            dget_or(light, "intensity", dyn_real(1.0_real64))))
        end block
      end do
    end if
    scene = dyn_dict()
    call dset(scene, "name", dyn_str(str_or(d, "name", "untitled")))
    call dset(scene, "width", dget_or(d, "width", &
                                      dyn_int(640_int64)))
    call dset(scene, "height", dget_or(d, "height", &
                                       dyn_int(480_int64)))
    call dset(scene, "bg", list_or_default(d, "bg", &
                                           ir_vec3_ints(25, 25, 35)))
    call dset(scene, "camera", cam)
    call dset(scene, "lights", arr)
    ! objects
    arr = dyn_list()
    item = dyn_dict_get(d, "objects")
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: obj, tri, ext
          logical :: capped
          obj = dyn_list_at(item, k)
          tri = dyn_dict_get(obj, "triangles")
          if (tri%kind /= DYN_K_NULL) tri = restore_triangles(tri)
          ext = dyn_dict_get(obj, "extensions")
          if (ext%kind /= DYN_K_DICT) ext = dyn_dict()
          capped = .true.
          if (dyn_dict_has(obj, "capped")) then
            block
              type(dyn) :: capv
              capv = dyn_dict_get(obj, "capped")
              if (capv%kind == DYN_K_BOOL) capped = capv%b
            end block
          end if
          block
            type(dyn) :: new_obj
            new_obj = ir_object_make( &
              str_of(obj, "name"), str_of(obj, "prim"), &
              list_or_null(dyn_dict_get(obj, "color")), &
              list_or_default(obj, "pos", ir_vec3_ints(0, 0, 0)), &
              list_or_default(obj, "rotate", ir_vec3_ints(0, 0, 0)), &
              list_or_default(obj, "scale", ir_vec3_ints(1, 1, 1)), &
              dget_or(obj, "size", dyn_real(2.0_real64)), &
              list_or_null(dyn_dict_get(obj, "size3")), &
              dyn_dict_get(obj, "radius"), &
              dyn_dict_get(obj, "height"), &
              dyn_dict_get(obj, "segments"), &
              str_or(obj, "detail", "med"), capped, &
              str_or(obj, "material", "lambert"), tri, &
              dyn_dict_get(obj, "source_file"), ext)
            if (dyn_dict_has(obj, "shading")) &
              call dset(new_obj, "shading", &
                        dyn_dict_get(obj, "shading"))
            if (dyn_dict_has(obj, "mirror")) &
              call dset(new_obj, "mirror", &
                        dyn_dict_get(obj, "mirror"))
            call dyn_list_push(arr, new_obj)
          end block
        end block
      end do
    end if
    call dset(scene, "objects", arr)
    ! animations
    arr = dyn_list()
    item = dyn_dict_get(d, "animations")
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: anim
          anim = dyn_list_at(item, k)
          call dyn_list_push(arr, ir_anim_make( &
            str_of(anim, "kind"), str_of(anim, "target"), &
            str_or(anim, "axis", "y"), &
            dget_or(anim, "speed", dyn_real(90.0_real64)), &
            dget_or(anim, "duration", dyn_real(5.0_real64)), &
            dget_or(anim, "fps", dyn_int(30_int64)), &
            str_or(anim, "ease", "linear"), &
            str_or(anim, "loop", "forever")))
        end block
      end do
    end if
    call dset(scene, "animations", arr)
    ! outputs
    arr = dyn_list()
    item = dyn_dict_get(d, "outputs")
    if (item%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(item)
        block
          type(dyn) :: outp
          outp = dyn_list_at(item, k)
          call dyn_list_push(arr, ir_output_make( &
            str_or(outp, "kind", "render"), &
            dyn_dict_get(outp, "path"), &
            dyn_dict_get(outp, "format"), &
            dyn_dict_get(outp, "width"), &
            dyn_dict_get(outp, "height")))
        end block
      end do
    end if
    call dset(scene, "outputs", arr)
    block
      type(dyn) :: ext
      ext = dyn_dict_get(d, "extensions")
      if (ext%kind /= DYN_K_DICT) ext = dyn_dict()
      call dset(scene, "extensions", ext)
    end block
    if (dyn_dict_has(d, "source_map")) then
      item = dyn_dict_get(d, "source_map")
      if (item%kind /= DYN_K_NULL) &
        call ir_scene_set_source_map(scene, item)
    end if
  end function ir_from_dict

  !> Value for key when it is a list, else the default (Python
  !! tuple(d.get(key, default)) -- a present non-sequence would raise
  !! in Python; the default is used here instead).
  function list_or_default(d, key, def) result(v)
    type(dyn), intent(in) :: d, def
    character(len=*), intent(in) :: key
    type(dyn) :: v
    v = dyn_dict_get(d, key)
    if (v%kind == DYN_K_LIST) then
      v = dyn_copy(v)
    else if (.not. dyn_dict_has(d, key)) then
      v = dyn_copy(def)
    else
      v = dyn_copy(def)
    end if
  end function list_or_default

  !> String field with default (Python d.get(key, default) on a str
  !! field; a stored null also falls back here -- Python would keep
  !! the None, a malformed-input-only divergence).
  function str_or(d, key, def) result(v)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key, def
    character(len=:), allocatable :: v
    type(dyn) :: raw
    raw = dyn_dict_get(d, key)
    if (raw%kind == DYN_K_STR .and. allocated(raw%s)) then
      v = raw%s
    else
      v = def
    end if
  end function str_or

  !> Required string field (Python obj["name"]): "" when absent.
  function str_of(d, key) result(v)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    character(len=:), allocatable :: v
    type(dyn) :: raw
    raw = dyn_dict_get(d, key)
    if (raw%kind == DYN_K_STR .and. allocated(raw%s)) then
      v = raw%s
    else
      v = ""
    end if
  end function str_of

  ! ==================================================================
  ! JSON writing (json.dumps semantics) and parsing (json.loads)
  ! ==================================================================

  !> Serialise a dyn value exactly as Python json.dumps(value) does:
  !! indent < 0 -> default separators (", ", ": "); indent >= 0 ->
  !! pretty with that many spaces per level.  Strings are escaped
  !! with ensure_ascii=True (f3dc_errors.json_escape); numbers use
  !! fmt_int / fmt_real (Python repr rules).
  function ir_json_write(v, indent) result(out)
    type(dyn), intent(in) :: v
    integer, intent(in) :: indent
    character(len=:), allocatable :: out
    out = ""
    call json_write_rec(v, indent, 0, out)
  end function ir_json_write

  recursive subroutine json_write_rec(v, indent, level, out)
    type(dyn), intent(in) :: v
    integer, intent(in) :: indent, level
    character(len=:), allocatable, intent(inout) :: out
    integer :: k, n
    character(len=:), allocatable :: pad_in, pad_out
    type(str_builder) :: sb
    ! Builder mirrors `out` (seed / flush / re-seed around the
    ! recursive child calls), as in f3dc_emit_common.dump_rec.
    call sb_init(sb)
    if (allocated(out)) call sb_add(sb, out)
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
      ! json.dumps spells non-finite values NaN/Infinity/-Infinity.
      if (v%r /= v%r) then
        call sb_add(sb, "NaN")
      else if (.not. (abs(v%r) <= huge(v%r))) then
        if (v%r > 0.0_real64) then
          call sb_add(sb, "Infinity")
        else
          call sb_add(sb, "-Infinity")
        end if
      else
        call sb_add(sb, trim(fmt_real(v%r)))
      end if
    case (DYN_K_STR)
      if (allocated(v%s)) then
        call sb_add(sb, '"' // json_escape(v%s) // '"')
      else
        call sb_add(sb, '""')
      end if
    case (DYN_K_LIST)
      n = dyn_list_len(v)
      if (n == 0) then
        call sb_add(sb, "[]")
        out = sb_text(sb)
        return
      end if
      call sb_add(sb, "[")
      do k = 1, n
        if (k > 1) then
          if (indent >= 0) then
            call sb_add(sb, ",")
          else
            call sb_add(sb, ", ")
          end if
        end if
        if (indent >= 0) then
          pad_in = repeat(" ", indent * (level + 1))
          call sb_add(sb, achar(10) // pad_in)
        end if
        out = sb_text(sb)
        call json_write_rec(dyn_list_at(v, k), indent, level + 1, out)
        call sb_init(sb)
        if (allocated(out)) call sb_add(sb, out)
      end do
      if (indent >= 0) then
        pad_out = repeat(" ", indent * level)
        call sb_add(sb, achar(10) // pad_out)
      end if
      call sb_add(sb, "]")
    case (DYN_K_DICT)
      n = dyn_dict_len(v)
      if (n == 0) then
        call sb_add(sb, "{}")
        out = sb_text(sb)
        return
      end if
      call sb_add(sb, "{")
      do k = 1, n
        if (k > 1) then
          if (indent >= 0) then
            call sb_add(sb, ",")
          else
            call sb_add(sb, ", ")
          end if
        end if
        if (indent >= 0) then
          pad_in = repeat(" ", indent * (level + 1))
          call sb_add(sb, achar(10) // pad_in)
        end if
        call sb_add(sb, '"' // json_escape(dyn_dict_key_at(v, k)) // '"')
        if (indent >= 0) then
          call sb_add(sb, ": ")
        else
          call sb_add(sb, ": ")
        end if
        out = sb_text(sb)
        call json_write_rec(dyn_dict_value_at(v, k), indent, &
                            level + 1, out)
        call sb_init(sb)
        if (allocated(out)) call sb_add(sb, out)
      end do
      if (indent >= 0) then
        pad_out = repeat(" ", indent * level)
        call sb_add(sb, achar(10) // pad_out)
      end if
      call sb_add(sb, "}")
    case default
      call sb_add(sb, "null")
    end select
    out = sb_text(sb)
  end subroutine json_write_rec

  !> to_json(scene, indent=...): json.dumps(to_dict(scene)).
  !! indent < 0 mirrors a bare to_json(scene) call (no kwargs).
  function ir_to_json(scene, indent) result(out)
    type(dyn), intent(in) :: scene
    integer, intent(in) :: indent
    character(len=:), allocatable :: out
    out = ir_json_write(ir_to_dict(scene), indent)
  end function ir_to_json

  ! ------------------------------------------------------------------
  ! JSON parser (json.loads subset, full JSON grammar)
  ! ------------------------------------------------------------------

  !> Parse JSON text into a dyn (json.loads).  ok=.false. on any
  !! syntax error (Python raises JSONDecodeError).  Numbers without
  !! '.'/'e' become dyn_int (int64 range; Python ints are unbounded
  !! -- overflow falls back to dyn_real, noted in the report), other
  !! numbers become dyn_real.
  subroutine ir_json_parse(text, value, ok)
    character(len=*), intent(in) :: text
    type(dyn), intent(out) :: value
    logical, intent(out) :: ok
    type(json_parser) :: p
    p%s = text
    p%pos = 1
    p%ok = .true.
    call json_skip_ws(p)
    call json_parse_value(p, value)
    call json_skip_ws(p)
    if (p%pos <= len(p%s)) p%ok = .false.
    ok = p%ok
    if (.not. ok) value = dyn_null()
  end subroutine ir_json_parse

  subroutine json_skip_ws(p)
    type(json_parser), intent(inout) :: p
    integer :: c
    do while (p%pos <= len(p%s))
      c = iachar(p%s(p%pos:p%pos))
      if (c == 32 .or. c == 9 .or. c == 10 .or. c == 13) then
        p%pos = p%pos + 1
      else
        exit
      end if
    end do
  end subroutine json_skip_ws

  recursive subroutine json_parse_value(p, value)
    type(json_parser), intent(inout) :: p
    type(dyn), intent(out) :: value
    character(len=1) :: ch
    value = dyn_null()
    if (.not. p%ok) return
    if (p%pos > len(p%s)) then
      p%ok = .false.
      return
    end if
    ch = p%s(p%pos:p%pos)
    select case (ch)
    case ("{")
      call json_parse_object(p, value)
    case ("[")
      call json_parse_array(p, value)
    case ('"')
      block
        character(len=:), allocatable :: str
        call json_parse_string(p, str)
        if (p%ok) value = dyn_str(str)
      end block
    case ("t")
      if (json_eat(p, "true")) then
        value = dyn_bool(.true.)
      else
        p%ok = .false.
      end if
    case ("f")
      if (json_eat(p, "false")) then
        value = dyn_bool(.false.)
      else
        p%ok = .false.
      end if
    case ("n")
      if (json_eat(p, "null")) then
        value = dyn_null()
      else
        p%ok = .false.
      end if
    case default
      call json_parse_number(p, value)
    end select
  end subroutine json_parse_value

  logical function json_eat(p, word)
    type(json_parser), intent(inout) :: p
    character(len=*), intent(in) :: word
    json_eat = .false.
    if (p%pos + len(word) - 1 > len(p%s)) return
    if (p%s(p%pos:p%pos + len(word) - 1) /= word) return
    p%pos = p%pos + len(word)
    json_eat = .true.
  end function json_eat

  recursive subroutine json_parse_object(p, value)
    type(json_parser), intent(inout) :: p
    type(dyn), intent(out) :: value
    character(len=:), allocatable :: key
    type(dyn) :: item
    value = dyn_dict()
    p%pos = p%pos + 1
    call json_skip_ws(p)
    if (p%pos <= len(p%s)) then
      if (p%s(p%pos:p%pos) == "}") then
        p%pos = p%pos + 1
        return
      end if
    end if
    do
      call json_skip_ws(p)
      if (p%pos > len(p%s)) then
        p%ok = .false.
        return
      end if
      if (p%s(p%pos:p%pos) /= '"') then
        p%ok = .false.
        return
      end if
      call json_parse_string(p, key)
      if (.not. p%ok) return
      call json_skip_ws(p)
      if (p%pos > len(p%s)) then
        p%ok = .false.
        return
      end if
      if (p%s(p%pos:p%pos) /= ":") then
        p%ok = .false.
        return
      end if
      p%pos = p%pos + 1
      call json_skip_ws(p)
      call json_parse_value(p, item)
      if (.not. p%ok) return
      call dyn_dict_set(value, key, item)
      call json_skip_ws(p)
      if (p%pos > len(p%s)) then
        p%ok = .false.
        return
      end if
      if (p%s(p%pos:p%pos) == ",") then
        p%pos = p%pos + 1
        cycle
      end if
      if (p%s(p%pos:p%pos) == "}") then
        p%pos = p%pos + 1
        return
      end if
      p%ok = .false.
      return
    end do
  end subroutine json_parse_object

  recursive subroutine json_parse_array(p, value)
    type(json_parser), intent(inout) :: p
    type(dyn), intent(out) :: value
    type(dyn) :: item
    value = dyn_list()
    p%pos = p%pos + 1
    call json_skip_ws(p)
    if (p%pos <= len(p%s)) then
      if (p%s(p%pos:p%pos) == "]") then
        p%pos = p%pos + 1
        return
      end if
    end if
    do
      call json_skip_ws(p)
      call json_parse_value(p, item)
      if (.not. p%ok) return
      call dyn_list_push(value, item)
      call json_skip_ws(p)
      if (p%pos > len(p%s)) then
        p%ok = .false.
        return
      end if
      if (p%s(p%pos:p%pos) == ",") then
        p%pos = p%pos + 1
        cycle
      end if
      if (p%s(p%pos:p%pos) == "]") then
        p%pos = p%pos + 1
        return
      end if
      p%ok = .false.
      return
    end do
  end subroutine json_parse_array

  !> Parse a JSON string starting at the opening quote; advances pos
  !! past the closing quote.  \u escapes are decoded to code points
  !! and re-encoded as UTF-8 (surrogate pairs combined; a lone
  !! surrogate is encoded as its raw value -- Python keeps a lone
  !! surrogate character, which has no UTF-8 form).
  subroutine json_parse_string(p, out)
    type(json_parser), intent(inout) :: p
    character(len=:), allocatable, intent(out) :: out
    type(str_builder) :: sb
    integer :: cp, hi, lo, save
    call sb_init(sb)
    p%pos = p%pos + 1  ! opening quote
    do while (p%pos <= len(p%s))
      if (p%s(p%pos:p%pos) == '"') then
        p%pos = p%pos + 1
        out = sb_text(sb)
        return
      end if
      if (p%s(p%pos:p%pos) == "\") then
        p%pos = p%pos + 1
        if (p%pos > len(p%s)) then
          p%ok = .false.
          out = sb_text(sb)
          return
        end if
        select case (p%s(p%pos:p%pos))
        case ('"')
          call sb_add(sb, '"')
          p%pos = p%pos + 1
        case ("\")
          call sb_add(sb, "\")
          p%pos = p%pos + 1
        case ("/")
          call sb_add(sb, "/")
          p%pos = p%pos + 1
        case ("b")
          call sb_add(sb, achar(8))
          p%pos = p%pos + 1
        case ("f")
          call sb_add(sb, achar(12))
          p%pos = p%pos + 1
        case ("n")
          call sb_add(sb, achar(10))
          p%pos = p%pos + 1
        case ("r")
          call sb_add(sb, achar(13))
          p%pos = p%pos + 1
        case ("t")
          call sb_add(sb, achar(9))
          p%pos = p%pos + 1
        case ("u")
          call json_parse_hex4(p, cp)
          if (.not. p%ok) then
            out = sb_text(sb)
            return
          end if
          if (cp >= 55296 .and. cp <= 56319) then
            save = p%pos
            if (p%pos + 1 <= len(p%s)) then
              if (p%s(p%pos:p%pos + 1) == "\u") then
                p%pos = p%pos + 1
                call json_parse_hex4(p, lo)
                if (.not. p%ok) then
                  out = sb_text(sb)
                  return
                end if
                if (lo >= 56320 .and. lo <= 57343) then
                  hi = cp
                  cp = 65536 + (hi - 55296) * 1024 + (lo - 56320)
                else
                  p%pos = save
                end if
              end if
            end if
          end if
          call sb_add(sb, utf8_encode(cp))
        case default
          p%ok = .false.
          out = sb_text(sb)
          return
        end select
        cycle
      end if
      if (iachar(p%s(p%pos:p%pos)) < 32) then
        p%ok = .false.
        out = sb_text(sb)
        return
      end if
      call sb_add(sb, p%s(p%pos:p%pos))
      p%pos = p%pos + 1
    end do
    p%ok = .false.
    out = sb_text(sb)
  end subroutine json_parse_string

  !> Consume 'u' + 4 hex digits (pos is at the 'u').
  subroutine json_parse_hex4(p, cp)
    type(json_parser), intent(inout) :: p
    integer, intent(out) :: cp
    integer :: k, v
    cp = 0
    if (p%pos + 4 > len(p%s)) then
      p%ok = .false.
      return
    end if
    do k = 1, 4
      v = hex_val(p%s(p%pos + k:p%pos + k))
      if (v < 0) then
        p%ok = .false.
        return
      end if
      cp = cp * 16 + v
    end do
    p%pos = p%pos + 5
  end subroutine json_parse_hex4

  !> Encode one Unicode code point as UTF-8 bytes.
  function utf8_encode(cp) result(out)
    integer, intent(in) :: cp
    character(len=:), allocatable :: out
    if (cp < 128) then
      allocate (character(len=1) :: out)
      out(1:1) = achar(cp)
    else if (cp < 2048) then
      allocate (character(len=2) :: out)
      out(1:1) = achar(192 + cp / 64)
      out(2:2) = achar(128 + mod(cp, 64))
    else if (cp < 65536) then
      allocate (character(len=3) :: out)
      out(1:1) = achar(224 + cp / 4096)
      out(2:2) = achar(128 + mod(cp / 64, 64))
      out(3:3) = achar(128 + mod(cp, 64))
    else
      allocate (character(len=4) :: out)
      out(1:1) = achar(240 + cp / 262144)
      out(2:2) = achar(128 + mod(cp / 4096, 64))
      out(3:3) = achar(128 + mod(cp / 64, 64))
      out(4:4) = achar(128 + mod(cp, 64))
    end if
  end function utf8_encode

  subroutine json_parse_number(p, value)
    type(json_parser), intent(inout) :: p
    type(dyn), intent(out) :: value
    integer :: start, ios
    logical :: is_real
    character(len=:), allocatable :: tok
    integer(int64) :: iv
    real(real64) :: rv
    value = dyn_null()
    start = p%pos
    is_real = .false.
    if (p%pos <= len(p%s)) then
      if (p%s(p%pos:p%pos) == "-") p%pos = p%pos + 1
    end if
    do while (p%pos <= len(p%s))
      select case (p%s(p%pos:p%pos))
      case ("0":"9")
        p%pos = p%pos + 1
      case (".", "e", "E", "+", "-")
        if (p%s(p%pos:p%pos) == "." .or. &
            p%s(p%pos:p%pos) == "e" .or. &
            p%s(p%pos:p%pos) == "E") is_real = .true.
        p%pos = p%pos + 1
      case default
        exit
      end select
    end do
    if (p%pos == start) then
      p%ok = .false.
      return
    end if
    tok = p%s(start:p%pos - 1)
    if (is_real) then
      read (tok, *, iostat=ios) rv
      if (ios /= 0) then
        p%ok = .false.
        return
      end if
      value = dyn_real(rv)
    else
      read (tok, *, iostat=ios) iv
      if (ios == 0) then
        value = dyn_int(iv)
      else
        read (tok, *, iostat=ios) rv
        if (ios /= 0) then
          p%ok = .false.
          return
        end if
        value = dyn_real(rv)
      end if
    end if
  end subroutine json_parse_number

  !> from_json(text): parse JSON, then from_dict.  ok=.false. when
  !! the text is not valid JSON or does not decode to an object
  !! (Python raises JSONDecodeError / TypeError there).
  subroutine ir_from_json(text, scene, ok)
    character(len=*), intent(in) :: text
    type(dyn), intent(out) :: scene
    logical, intent(out) :: ok
    type(dyn) :: data
    call ir_json_parse(text, data, ok)
    if (.not. ok) then
      scene = dyn_null()
      return
    end if
    if (data%kind /= DYN_K_DICT) then
      ok = .false.
      scene = dyn_null()
      return
    end if
    scene = ir_from_dict(data)
  end subroutine ir_from_json

end module f3dc_ir
