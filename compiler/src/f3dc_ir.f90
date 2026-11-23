! f3dc_ir.f90 -- Typed IR (ir_version=1) for the native Forge3D
! compiler.  Port of tools/f3dc/ir_nodes.py (read in full).
! Port contract: compiler/DESIGN.md.
!
! v3.0 Phase 6 (C1): IR nodes are REAL DERIVED TYPES -- ir_camera,
! ir_light, ir_object, ir_anim, ir_output, ir_scene below, one type
! per node kind, with typed fields for every core field.  dyn DICTS
! survive only at the JSON / pipeline boundary: the converters
! ir_scene_from_dict / ir_scene_to_dict (plus per-node *_from_dict /
! *_to_dict) translate between a boundary dyn dict and the typed
! scene, and ir_to_dict / ir_from_dict / ir_to_json / ir_from_json
! are implemented on top of them, so there is exactly one code path
! that knows the field inventory.  The legacy dyn constructors
! (ir_camera_make & friends) are kept as boundary constructors for
! the pipeline stages that still pass dyn scenes (validate, desugar,
! emit_fortran); they build the same dicts they always did.
!
! Leaf fidelity: Python mirrors int-valued fields as dyn_int and
! float-valued fields as dyn_real, and JSON text distinguishes 60
! from 60.0, so scalar leaves are carried by the typed ir_scalar /
! ir_vec3 / ir_text types (kind tag + value), NOT collapsed to one
! Fortran numeric type.  Extension data -- the per-object and
! per-scene "extensions" dicts (Phase 4 material slots under
! extensions%material, Wave B/C/E extras, raw_props, geometry, ...)
! -- rides in the typed nodes' `ext` member: a retained dyn dict,
! documented as the EXTENSION BAG.  It is opaque to the IR layer by
! design (extensions register new keys without changing the core
! types); the core fields are never stored in it.  Two further dyn
! payloads are retained verbatim, also by design: an object's
! `triangles` (an arbitrary nested vertex payload, not IR structure)
! and a scene's `source_map` (an arbitrary JSON value).
!
! Boundary dict keys are exactly the Python dataclass field names,
! in declaration order; vec3 / colour tuples are dyn lists, None is
! dyn_null (e.g. IRCamera.fov defaults to the REAL 60.0 here,
! whereas desugar's DEFAULT_CAMERA carries the INT 60).
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
                      dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, &
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
  ! C1 typed IR: node types, leaf types, boundary converters.
  public :: ir_scalar, ir_vec3, ir_text
  public :: ir_camera, ir_light, ir_object, ir_anim, ir_output, &
            ir_scene
  public :: ir_scalar_from_dyn, ir_scalar_to_dyn
  public :: ir_vec3_from_dyn, ir_vec3_to_dyn
  public :: ir_camera_from_dict, ir_camera_to_dict
  public :: ir_light_from_dict, ir_light_to_dict
  public :: ir_object_from_dict, ir_object_to_dict
  public :: ir_anim_from_dict, ir_anim_to_dict
  public :: ir_output_from_dict, ir_output_to_dict
  public :: ir_scene_from_dict, ir_scene_to_dict
  public :: ir_camera_typed_default, ir_light_typed_default, &
            ir_object_typed_default, ir_anim_typed_default, &
            ir_output_typed_default, ir_scene_typed_default

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

  ! ------------------------------------------------------------------
  ! C1 typed IR -- leaf types
  ! ------------------------------------------------------------------

  !> One scalar leaf with its Python type fidelity preserved: kind
  !! is a DYN_K_* tag for the scalar kinds (NULL/BOOL/INT/REAL/STR);
  !! the matching component carries the value.  A non-scalar dyn
  !! (list/dict) in a scalar slot is malformed IR; it is retained
  !! verbatim in `raw` (has_raw) so the boundary converters stay
  !! lossless even then -- no valid scene ever takes that path.
  type :: ir_scalar
    integer :: kind = DYN_K_NULL
    integer(int64) :: i = 0_int64
    real(real64) :: r = 0.0_real64
    logical :: b = .false.
    character(len=:), allocatable :: s
    logical :: has_raw = .false.
    type(dyn) :: raw
  end type ir_scalar

  !> A vec3 / colour triple: three ir_scalar components.  A value
  !! that is not a 3-element list (including null, for the
  !! list-or-None fields) is retained verbatim in `raw` (has_raw).
  type :: ir_vec3
    type(ir_scalar) :: c(3)
    logical :: has_raw = .false.
    type(dyn) :: raw
  end type ir_vec3

  !> A text field.  `present` distinguishes an absent key (the
  !! canonical serialiser emits null for the direct-get fields) from
  !! a present string; defaulted text fields are always present once
  !! converted (the default is applied at conversion time, exactly
  !! as ir_from_dict applies it).
  type :: ir_text
    character(len=:), allocatable :: s
    logical :: present = .false.
  end type ir_text

  ! ------------------------------------------------------------------
  ! C1 typed IR -- node types (field order = dataclass field order)
  ! ------------------------------------------------------------------

  type :: ir_camera
    type(ir_vec3) :: pos, target, up
    type(ir_scalar) :: fov, near, far
  end type ir_camera

  type :: ir_light
    type(ir_text) :: kind
    type(ir_vec3) :: direction, color
    type(ir_scalar) :: intensity
  end type ir_light

  type :: ir_object
    type(ir_text) :: name, prim
    type(ir_vec3) :: color
    type(ir_vec3) :: pos, rotate, scale
    type(ir_scalar) :: size
    type(ir_vec3) :: size3
    type(ir_scalar) :: radius, height, segments
    type(ir_text) :: detail
    ! Optional keys, carried only when present on the boundary dict
    ! (validate sets them only for explicitly determined values):
    logical :: has_shading = .false.
    type(ir_scalar) :: shading
    logical :: has_mirror = .false.
    type(ir_scalar) :: mirror
    logical :: capped = .true.
    type(ir_text) :: material
    type(dyn) :: triangles     !< verbatim vertex payload (see header)
    type(ir_scalar) :: source_file
    type(dyn) :: ext           !< EXTENSION BAG: the "extensions" dict
  end type ir_object

  type :: ir_anim
    type(ir_text) :: kind, target, axis
    type(ir_scalar) :: speed, duration, fps
    type(ir_text) :: ease, loop
  end type ir_anim

  type :: ir_output
    type(ir_text) :: kind
    type(ir_scalar) :: path, format, width, height
  end type ir_output

  type :: ir_scene
    type(ir_text) :: name
    type(ir_scalar) :: width, height
    type(ir_vec3) :: bg
    type(ir_camera) :: camera
    type(ir_light), allocatable :: lights(:)
    type(ir_object), allocatable :: objects(:)
    type(ir_anim), allocatable :: animations(:)
    type(ir_output), allocatable :: outputs(:)
    type(dyn) :: ext           !< EXTENSION BAG: the "extensions" dict
    logical :: has_source_map = .false.
    type(dyn) :: source_map    !< verbatim JSON value (see header)
  end type ir_scene

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
  !! Public behaviour is unchanged: hooks still receive and return
  !! boundary dyn scenes.  Internally the dispatch crosses the typed
  !! layer (C1): the scene is converted dyn -> typed -> dyn before
  !! the first hook and dyn -> typed -> dyn again after the last
  !! one, so hooks always see a canonical, fully-defaulted scene
  !! dict.  With an empty registry this is the identity, exactly as
  !! before (the scene is not touched at all).
  subroutine ir_apply_extensions(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    type(dyn) :: work
    integer :: k
    if (n_registry == 0) return
    work = ir_scene_to_dict(ir_scene_from_dict(scene))
    do k = 1, n_registry
      if (associated(registry(k)%fn)) &
        call registry(k)%fn(work, bag)
    end do
    scene = ir_scene_to_dict(ir_scene_from_dict(work))
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
  ! C1 boundary converters: dyn dict <-> typed IR
  !
  ! Reading semantics mirror ir_from_dict (the canonical-dict
  ! reader): list_or_default / str_or / str_of defaults, dict-or-
  ! empty extensions, source_map kept only when present and
  ! non-null.  On every VALID scene these coincide with the old
  ! ir_to_dict reading (dget_or defaults + direct gets), because
  ! validate only ever produces fully-typed fields; the residual
  ! divergences are the malformed-input ones already documented for
  ! ir_from_dict (a non-string in a string slot reads as the
  ! default, a non-list in a vec3 slot reads as the default, a
  ! non-bool "capped" reads as .true.).
  ! ==================================================================

  function ir_scalar_from_dyn(v) result(s)
    type(dyn), intent(in) :: v
    type(ir_scalar) :: s
    s%kind = v%kind
    s%i = v%i
    s%r = v%r
    s%b = v%b
    if (allocated(v%s)) s%s = v%s
    if (v%kind == DYN_K_LIST .or. v%kind == DYN_K_DICT) then
      s%has_raw = .true.
      s%raw = dyn_copy(v)
    end if
  end function ir_scalar_from_dyn

  function ir_scalar_to_dyn(s) result(v)
    type(ir_scalar), intent(in) :: s
    type(dyn) :: v
    if (s%has_raw) then
      v = dyn_copy(s%raw)
      return
    end if
    select case (s%kind)
    case (DYN_K_BOOL)
      v = dyn_bool(s%b)
    case (DYN_K_INT)
      v = dyn_int(s%i)
    case (DYN_K_REAL)
      v = dyn_real(s%r)
    case (DYN_K_STR)
      if (allocated(s%s)) then
        v = dyn_str(s%s)
      else
        v = dyn_str("")
      end if
    case default
      v = dyn_null()
    end select
  end function ir_scalar_to_dyn

  !> Any dyn value as an ir_vec3: a 3-element list becomes three
  !! typed components; anything else is retained verbatim (raw).
  function ir_vec3_from_dyn(v) result(t)
    type(dyn), intent(in) :: v
    type(ir_vec3) :: t
    integer :: k
    if (v%kind == DYN_K_LIST .and. dyn_list_len(v) == 3) then
      do k = 1, 3
        t%c(k) = ir_scalar_from_dyn(dyn_list_at(v, k))
      end do
    else
      t%has_raw = .true.
      t%raw = dyn_copy(v)
    end if
  end function ir_vec3_from_dyn

  function ir_vec3_to_dyn(t) result(v)
    type(ir_vec3), intent(in) :: t
    type(dyn) :: v
    integer :: k
    if (t%has_raw) then
      v = dyn_copy(t%raw)
      return
    end if
    v = dyn_list()
    do k = 1, 3
      call dyn_list_push(v, ir_scalar_to_dyn(t%c(k)))
    end do
  end function ir_vec3_to_dyn

  !> Scalar field: dget_or semantics (default only when absent).
  function scalar_field(d, key, def) result(s)
    type(dyn), intent(in) :: d, def
    character(len=*), intent(in) :: key
    type(ir_scalar) :: s
    s = ir_scalar_from_dyn(dget_or(d, key, def))
  end function scalar_field

  !> Scalar field taken directly (dyn_dict_get; null when absent).
  function scalar_direct(d, key) result(s)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(ir_scalar) :: s
    s = ir_scalar_from_dyn(dyn_dict_get(d, key))
  end function scalar_direct

  !> Vec3 field with list_or_default semantics.
  function vec3_field(d, key, def) result(t)
    type(dyn), intent(in) :: d, def
    character(len=*), intent(in) :: key
    type(ir_vec3) :: t
    t = ir_vec3_from_dyn(list_or_default(d, key, def))
  end function vec3_field

  !> Vec3-or-null field with list_or_null semantics.
  function vec3_or_null(d, key) result(t)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(ir_vec3) :: t
    t = ir_vec3_from_dyn(list_or_null(dyn_dict_get(d, key)))
  end function vec3_or_null

  !> Defaulted text field (str_or semantics; always present after).
  function text_field(d, key, def) result(t)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key, def
    type(ir_text) :: t
    t%s = str_or(d, key, def)
    t%present = .true.
  end function text_field

  !> Direct text field (str_of semantics; present tracks the key).
  function text_direct(d, key) result(t)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    type(ir_text) :: t
    t%s = str_of(d, key)
    t%present = dyn_dict_has(d, key)
  end function text_direct

  function text_to_dyn(t) result(v)
    type(ir_text), intent(in) :: t
    type(dyn) :: v
    if (.not. t%present) then
      v = dyn_null()
    else if (allocated(t%s)) then
      v = dyn_str(t%s)
    else
      v = dyn_str("")
    end if
  end function text_to_dyn

  !> The extensions dict of a boundary dict ({} when absent or not
  !! a dict, exactly as ir_from_dict / ir_to_dict read it).
  function ext_bag_of(d) result(ext)
    type(dyn), intent(in) :: d
    type(dyn) :: ext
    ext = dyn_dict_get(d, "extensions")
    if (ext%kind /= DYN_K_DICT) ext = dyn_dict()
  end function ext_bag_of

  ! ------------------------------------------------------------------
  ! Per-node converters
  ! ------------------------------------------------------------------

  function ir_camera_from_dict(d) result(cam)
    type(dyn), intent(in) :: d
    type(ir_camera) :: cam
    type(dyn) :: dd
    if (d%kind == DYN_K_DICT) then
      call dyn_assign(dd, d)
    else
      dd = dyn_dict()
    end if
    cam%pos = vec3_field(dd, "pos", ir_vec3_mixed( &
      dyn_int(3_int64), dyn_real(2.5_real64), dyn_int(4_int64)))
    cam%target = vec3_field(dd, "target", ir_vec3_ints(0, 0, 0))
    cam%up = vec3_field(dd, "up", ir_vec3_ints(0, 1, 0))
    cam%fov = scalar_field(dd, "fov", dyn_real(60.0_real64))
    cam%near = scalar_field(dd, "near", dyn_real(0.1_real64))
    cam%far = scalar_field(dd, "far", dyn_real(100.0_real64))
  end function ir_camera_from_dict

  function ir_camera_to_dict(cam) result(d)
    type(ir_camera), intent(in) :: cam
    type(dyn) :: d
    d = dyn_dict()
    call dset(d, "pos", json_safe(ir_vec3_to_dyn(cam%pos)))
    call dset(d, "target", json_safe(ir_vec3_to_dyn(cam%target)))
    call dset(d, "up", json_safe(ir_vec3_to_dyn(cam%up)))
    call dset(d, "fov", ir_scalar_to_dyn(cam%fov))
    call dset(d, "near", ir_scalar_to_dyn(cam%near))
    call dset(d, "far", ir_scalar_to_dyn(cam%far))
  end function ir_camera_to_dict

  function ir_light_from_dict(d) result(light)
    type(dyn), intent(in) :: d
    type(ir_light) :: light
    light%kind = text_field(d, "kind", "directional")
    light%direction = vec3_field(d, "direction", ir_vec3_mixed( &
      dyn_real(-0.5_real64), dyn_int(-1_int64), &
      dyn_real(-0.7_real64)))
    light%color = vec3_field(d, "color", ir_vec3_ints(255, 255, 255))
    light%intensity = scalar_field(d, "intensity", &
                                   dyn_real(1.0_real64))
  end function ir_light_from_dict

  function ir_light_to_dict(light) result(d)
    type(ir_light), intent(in) :: light
    type(dyn) :: d
    d = dyn_dict()
    call dset(d, "kind", text_to_dyn(light%kind))
    call dset(d, "direction", json_safe(ir_vec3_to_dyn( &
                                         light%direction)))
    call dset(d, "color", json_safe(ir_vec3_to_dyn(light%color)))
    call dset(d, "intensity", ir_scalar_to_dyn(light%intensity))
  end function ir_light_to_dict

  function ir_object_from_dict(d) result(obj)
    type(dyn), intent(in) :: d
    type(ir_object) :: obj
    type(dyn) :: capv, tri
    obj%name = text_direct(d, "name")
    obj%prim = text_direct(d, "prim")
    obj%color = vec3_or_null(d, "color")
    obj%pos = vec3_field(d, "pos", ir_vec3_ints(0, 0, 0))
    obj%rotate = vec3_field(d, "rotate", ir_vec3_ints(0, 0, 0))
    obj%scale = vec3_field(d, "scale", ir_vec3_ints(1, 1, 1))
    obj%size = scalar_field(d, "size", dyn_real(2.0_real64))
    obj%size3 = vec3_or_null(d, "size3")
    obj%radius = scalar_direct(d, "radius")
    obj%height = scalar_direct(d, "height")
    obj%segments = scalar_direct(d, "segments")
    obj%detail = text_field(d, "detail", "med")
    obj%has_shading = dyn_dict_has(d, "shading")
    if (obj%has_shading) &
      obj%shading = ir_scalar_from_dyn(dyn_dict_get(d, "shading"))
    obj%has_mirror = dyn_dict_has(d, "mirror")
    if (obj%has_mirror) &
      obj%mirror = ir_scalar_from_dyn(dyn_dict_get(d, "mirror"))
    obj%capped = .true.
    if (dyn_dict_has(d, "capped")) then
      capv = dyn_dict_get(d, "capped")
      if (capv%kind == DYN_K_BOOL) obj%capped = capv%b
    end if
    obj%material = text_field(d, "material", "lambert")
    tri = dyn_dict_get(d, "triangles")
    if (tri%kind /= DYN_K_NULL) tri = restore_triangles(tri)
    call dyn_assign(obj%triangles, tri)
    obj%source_file = scalar_direct(d, "source_file")
    obj%ext = ext_bag_of(d)
  end function ir_object_from_dict

  !> Canonical object dict, key order exactly as ir_to_dict emits:
  !! shading / mirror sit between detail and capped, carried only
  !! when present.
  function ir_object_to_dict(obj) result(d)
    type(ir_object), intent(in) :: obj
    type(dyn) :: d
    d = dyn_dict()
    call dset(d, "name", text_to_dyn(obj%name))
    call dset(d, "prim", text_to_dyn(obj%prim))
    call dset(d, "color", json_safe(ir_vec3_to_dyn(obj%color)))
    call dset(d, "pos", json_safe(ir_vec3_to_dyn(obj%pos)))
    call dset(d, "rotate", json_safe(ir_vec3_to_dyn(obj%rotate)))
    call dset(d, "scale", json_safe(ir_vec3_to_dyn(obj%scale)))
    call dset(d, "size", ir_scalar_to_dyn(obj%size))
    call dset(d, "size3", json_safe(ir_vec3_to_dyn(obj%size3)))
    call dset(d, "radius", ir_scalar_to_dyn(obj%radius))
    call dset(d, "height", ir_scalar_to_dyn(obj%height))
    call dset(d, "segments", ir_scalar_to_dyn(obj%segments))
    call dset(d, "detail", text_to_dyn(obj%detail))
    if (obj%has_shading) &
      call dset(d, "shading", ir_scalar_to_dyn(obj%shading))
    if (obj%has_mirror) &
      call dset(d, "mirror", ir_scalar_to_dyn(obj%mirror))
    call dset(d, "capped", dyn_bool(obj%capped))
    call dset(d, "material", text_to_dyn(obj%material))
    call dset(d, "triangles", json_safe(dyn_copy(obj%triangles)))
    call dset(d, "source_file", ir_scalar_to_dyn(obj%source_file))
    call dset(d, "extensions", json_safe(dyn_copy(obj%ext)))
  end function ir_object_to_dict

  function ir_anim_from_dict(d) result(anim)
    type(dyn), intent(in) :: d
    type(ir_anim) :: anim
    anim%kind = text_direct(d, "kind")
    anim%target = text_direct(d, "target")
    anim%axis = text_field(d, "axis", "y")
    anim%speed = scalar_field(d, "speed", dyn_real(90.0_real64))
    anim%duration = scalar_field(d, "duration", dyn_real(5.0_real64))
    anim%fps = scalar_field(d, "fps", dyn_int(30_int64))
    anim%ease = text_field(d, "ease", "linear")
    anim%loop = text_field(d, "loop", "forever")
  end function ir_anim_from_dict

  function ir_anim_to_dict(anim) result(d)
    type(ir_anim), intent(in) :: anim
    type(dyn) :: d
    d = dyn_dict()
    call dset(d, "kind", text_to_dyn(anim%kind))
    call dset(d, "target", text_to_dyn(anim%target))
    call dset(d, "axis", text_to_dyn(anim%axis))
    call dset(d, "speed", ir_scalar_to_dyn(anim%speed))
    call dset(d, "duration", ir_scalar_to_dyn(anim%duration))
    call dset(d, "fps", ir_scalar_to_dyn(anim%fps))
    call dset(d, "ease", text_to_dyn(anim%ease))
    call dset(d, "loop", text_to_dyn(anim%loop))
  end function ir_anim_to_dict

  function ir_output_from_dict(d) result(outp)
    type(dyn), intent(in) :: d
    type(ir_output) :: outp
    outp%kind = text_field(d, "kind", "render")
    outp%path = scalar_direct(d, "path")
    outp%format = scalar_direct(d, "format")
    outp%width = scalar_direct(d, "width")
    outp%height = scalar_direct(d, "height")
  end function ir_output_from_dict

  function ir_output_to_dict(outp) result(d)
    type(ir_output), intent(in) :: outp
    type(dyn) :: d
    d = dyn_dict()
    call dset(d, "kind", text_to_dyn(outp%kind))
    call dset(d, "path", ir_scalar_to_dyn(outp%path))
    call dset(d, "format", ir_scalar_to_dyn(outp%format))
    call dset(d, "width", ir_scalar_to_dyn(outp%width))
    call dset(d, "height", ir_scalar_to_dyn(outp%height))
  end function ir_output_to_dict

  ! ------------------------------------------------------------------
  ! Scene converter pair (the C1 boundary)
  ! ------------------------------------------------------------------

  function ir_scene_from_dict(d) result(scene)
    type(dyn), intent(in) :: d
    type(ir_scene) :: scene
    type(dyn) :: dd, item
    integer :: k, n
    if (d%kind == DYN_K_DICT) then
      call dyn_assign(dd, d)
    else
      dd = dyn_dict()
    end if
    scene%name = text_field(dd, "name", "untitled")
    scene%width = scalar_field(dd, "width", dyn_int(640_int64))
    scene%height = scalar_field(dd, "height", dyn_int(480_int64))
    scene%bg = vec3_field(dd, "bg", ir_vec3_ints(25, 25, 35))
    scene%camera = ir_camera_from_dict(dyn_dict_get(dd, "camera"))
    item = dyn_dict_get(dd, "lights")
    n = 0
    if (item%kind == DYN_K_LIST) n = dyn_list_len(item)
    allocate (scene%lights(n))
    do k = 1, n
      scene%lights(k) = ir_light_from_dict(dyn_list_at(item, k))
    end do
    item = dyn_dict_get(dd, "objects")
    n = 0
    if (item%kind == DYN_K_LIST) n = dyn_list_len(item)
    allocate (scene%objects(n))
    do k = 1, n
      scene%objects(k) = ir_object_from_dict(dyn_list_at(item, k))
    end do
    item = dyn_dict_get(dd, "animations")
    n = 0
    if (item%kind == DYN_K_LIST) n = dyn_list_len(item)
    allocate (scene%animations(n))
    do k = 1, n
      scene%animations(k) = ir_anim_from_dict(dyn_list_at(item, k))
    end do
    item = dyn_dict_get(dd, "outputs")
    n = 0
    if (item%kind == DYN_K_LIST) n = dyn_list_len(item)
    allocate (scene%outputs(n))
    do k = 1, n
      scene%outputs(k) = ir_output_from_dict(dyn_list_at(item, k))
    end do
    scene%ext = ext_bag_of(dd)
    scene%has_source_map = .false.
    if (dyn_dict_has(dd, "source_map")) then
      item = dyn_dict_get(dd, "source_map")
      if (item%kind /= DYN_K_NULL) then
        scene%has_source_map = .true.
        call dyn_assign(scene%source_map, item)
      end if
    end if
  end function ir_scene_from_dict

  !> Canonical scene dict: ir_version first, dataclass field order,
  !! source_map appended only when set -- byte-for-byte the dict
  !! the old dyn ir_to_dict produced for every valid scene.
  function ir_scene_to_dict(scene) result(data)
    type(ir_scene), intent(in) :: scene
    type(dyn) :: data
    type(dyn) :: arr
    integer :: k
    data = dyn_dict()
    call dset(data, "ir_version", dyn_int(int(IR_VERSION, int64)))
    call dset(data, "name", text_to_dyn(scene%name))
    call dset(data, "width", ir_scalar_to_dyn(scene%width))
    call dset(data, "height", ir_scalar_to_dyn(scene%height))
    call dset(data, "bg", json_safe(ir_vec3_to_dyn(scene%bg)))
    call dset(data, "camera", ir_camera_to_dict(scene%camera))
    arr = dyn_list()
    if (allocated(scene%lights)) then
      do k = 1, size(scene%lights)
        call dyn_list_push(arr, ir_light_to_dict(scene%lights(k)))
      end do
    end if
    call dset(data, "lights", arr)
    arr = dyn_list()
    if (allocated(scene%objects)) then
      do k = 1, size(scene%objects)
        call dyn_list_push(arr, ir_object_to_dict(scene%objects(k)))
      end do
    end if
    call dset(data, "objects", arr)
    arr = dyn_list()
    if (allocated(scene%animations)) then
      do k = 1, size(scene%animations)
        call dyn_list_push(arr, ir_anim_to_dict(scene%animations(k)))
      end do
    end if
    call dset(data, "animations", arr)
    arr = dyn_list()
    if (allocated(scene%outputs)) then
      do k = 1, size(scene%outputs)
        call dyn_list_push(arr, ir_output_to_dict(scene%outputs(k)))
      end do
    end if
    call dset(data, "outputs", arr)
    call dset(data, "extensions", json_safe(dyn_copy(scene%ext)))
    if (scene%has_source_map) &
      call dset(data, "source_map", json_safe(dyn_copy( &
                                               scene%source_map)))
  end function ir_scene_to_dict

  !> One typed object back to a RAW object dict (ir_object_make key
  !! order; shading/mirror appended after "extensions", as
  !! ir_from_dict has always emitted them).
  function typed_object_to_raw_dict(o) result(sub)
    type(ir_object), intent(in) :: o
    type(dyn) :: sub
    sub = dyn_dict()
    call dset(sub, "name", text_to_dyn(o%name))
    call dset(sub, "prim", text_to_dyn(o%prim))
    call dset(sub, "color", ir_vec3_to_dyn(o%color))
    call dset(sub, "pos", ir_vec3_to_dyn(o%pos))
    call dset(sub, "rotate", ir_vec3_to_dyn(o%rotate))
    call dset(sub, "scale", ir_vec3_to_dyn(o%scale))
    call dset(sub, "size", ir_scalar_to_dyn(o%size))
    call dset(sub, "size3", ir_vec3_to_dyn(o%size3))
    call dset(sub, "radius", ir_scalar_to_dyn(o%radius))
    call dset(sub, "height", ir_scalar_to_dyn(o%height))
    call dset(sub, "segments", ir_scalar_to_dyn(o%segments))
    call dset(sub, "detail", text_to_dyn(o%detail))
    call dset(sub, "capped", dyn_bool(o%capped))
    call dset(sub, "material", text_to_dyn(o%material))
    call dset(sub, "triangles", dyn_copy(o%triangles))
    call dset(sub, "source_file", ir_scalar_to_dyn(o%source_file))
    call dset(sub, "extensions", dyn_copy(o%ext))
    if (o%has_shading) &
      call dset(sub, "shading", ir_scalar_to_dyn(o%shading))
    if (o%has_mirror) &
      call dset(sub, "mirror", ir_scalar_to_dyn(o%mirror))
  end function typed_object_to_raw_dict

  !> Typed scene back to a RAW scene dict (the ir_scene_make key
  !! order ir_from_dict has always produced: object shading/mirror
  !! appended after "extensions", a trailing null-free source_map
  !! only when set).  Private: used by ir_from_dict only.
  function typed_scene_to_raw_dict(scene) result(d)
    type(ir_scene), intent(in) :: scene
    type(dyn) :: d
    type(dyn) :: arr
    integer :: k
    d = dyn_dict()
    call dset(d, "name", text_to_dyn(scene%name))
    call dset(d, "width", ir_scalar_to_dyn(scene%width))
    call dset(d, "height", ir_scalar_to_dyn(scene%height))
    call dset(d, "bg", ir_vec3_to_dyn(scene%bg))
    call dset(d, "camera", ir_camera_to_dict(scene%camera))
    arr = dyn_list()
    if (allocated(scene%lights)) then
      do k = 1, size(scene%lights)
        call dyn_list_push(arr, ir_light_to_dict(scene%lights(k)))
      end do
    end if
    call dset(d, "lights", arr)
    arr = dyn_list()
    if (allocated(scene%objects)) then
      do k = 1, size(scene%objects)
        call dyn_list_push(arr, &
                           typed_object_to_raw_dict(scene%objects(k)))
      end do
    end if
    call dset(d, "objects", arr)
    arr = dyn_list()
    if (allocated(scene%animations)) then
      do k = 1, size(scene%animations)
        call dyn_list_push(arr, ir_anim_to_dict(scene%animations(k)))
      end do
    end if
    call dset(d, "animations", arr)
    arr = dyn_list()
    if (allocated(scene%outputs)) then
      do k = 1, size(scene%outputs)
        call dyn_list_push(arr, ir_output_to_dict(scene%outputs(k)))
      end do
    end if
    call dset(d, "outputs", arr)
    call dset(d, "extensions", dyn_copy(scene%ext))
    if (scene%has_source_map) &
      call ir_scene_set_source_map(d, dyn_copy(scene%source_map))
  end function typed_scene_to_raw_dict

  ! ------------------------------------------------------------------
  ! Typed defaults (the dyn *_default constructors, crossed over)
  ! ------------------------------------------------------------------

  function ir_camera_typed_default() result(cam)
    type(ir_camera) :: cam
    cam = ir_camera_from_dict(ir_camera_default())
  end function ir_camera_typed_default

  function ir_light_typed_default() result(light)
    type(ir_light) :: light
    light = ir_light_from_dict(ir_light_default())
  end function ir_light_typed_default

  function ir_object_typed_default(name, prim) result(obj)
    character(len=*), intent(in) :: name, prim
    type(ir_object) :: obj
    obj = ir_object_from_dict(ir_object_default(name, prim))
  end function ir_object_typed_default

  function ir_anim_typed_default(kind, target) result(anim)
    character(len=*), intent(in) :: kind, target
    type(ir_anim) :: anim
    anim = ir_anim_from_dict(ir_anim_default(kind, target))
  end function ir_anim_typed_default

  function ir_output_typed_default() result(outp)
    type(ir_output) :: outp
    outp = ir_output_from_dict(ir_output_default())
  end function ir_output_typed_default

  function ir_scene_typed_default() result(scene)
    type(ir_scene) :: scene
    scene = ir_scene_from_dict(ir_scene_default())
  end function ir_scene_typed_default

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
  !! C1: this is now a thin boundary wrapper -- the field inventory
  !! lives in the typed converters (ir_scene_from_dict /
  !! ir_scene_to_dict below); the dyn dict is crossed into the typed
  !! scene and back, so dyn and typed consumers can never drift.
  function ir_to_dict(scene) result(data)
    type(dyn), intent(in) :: scene
    type(dyn) :: data
    data = ir_scene_to_dict(ir_scene_from_dict(scene))
  end function ir_to_dict

  !> from_dict(d): rebuild a scene dyn from to_dict output, with
  !! exactly the Python defaults.  (Python raises TypeError for a
  !! non-dict and KeyError for a missing object name/prim; here a
  !! non-dict yields a default scene and missing keys yield null --
  !! malformed-input divergence, noted in the report.)
  !! C1: implemented via the typed converters -- the canonical dict
  !! is crossed into an ir_scene and back out as a raw scene dict
  !! (typed_scene_to_raw_dict mirrors the old key order exactly,
  !! including shading/mirror appended after "extensions").
  function ir_from_dict(d) result(scene)
    type(dyn), intent(in) :: d
    type(dyn) :: scene
    if (d%kind /= DYN_K_DICT) then
      scene = ir_scene_default()
      return
    end if
    scene = typed_scene_to_raw_dict(ir_scene_from_dict(d))
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
