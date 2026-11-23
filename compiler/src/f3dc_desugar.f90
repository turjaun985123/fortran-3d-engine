! f3dc_desugar.f90 -- desugar pass for the native Forge3D compiler.
! Port of tools/f3dc/desugar.py (read in full, 693 lines).
! Port contract: compiler/DESIGN.md.
!
!   desugar(program, bag, base_dir) -> a NEW, flattened Program (dyn dict):
!     1. GroupStmt expansion: group transform props composed into
!        each child, named children prefixed "group.name", the group
!        statement itself disappears.
!     2. RepeatStmt expansion: repeat / grid / ring layouts, copies
!        auto-named name_1..name_n (unnamed: prim+i); expansion past
!        10,000 placements is E820.
!     3. Defaults injection: missing scene/camera/light statements
!        (one W101 warning each), object at/rotate defaults (a lone
!        object gets the demo pose 20,35,0), auto-names prim+index,
!        animation target resolution (None/it/last -> most recent
!        object) + animation defaults, a missing output becomes
!        render, an empty program gains a default cube.
!
! AST nodes are dyn DICTS as built by f3dc_parser (keys = the Python
! nodes' __dict__ keys).  Python duck-typing (isinstance / type name)
! is mirrored by is_node(), which recognises each node kind by its
! distinctive key signature (documented at is_node).  Python
! attribute access is mirrored by get_attr (synonym list, then the
! props dict, skipping stored nulls exactly like _get) and set_attr
! (first existing synonym key, else the first synonym, like _set).
! Because dyn values are copies, a nested props dict is read out,
! mutated, and written back with set_props; the write-back keeps the
! "props" key position, so the observable result matches Python's
! in-place dict mutation.
!
! Mirror map (desugar.py -> this module):
!   MAX_PLACEMENTS / DEFAULT_SCENE / DEFAULT_CAMERA / DEFAULT_LIGHT /
!   DEMO_POSE / ANIM_DEFAULTS -> the desugar_* table functions below
!     (values and Python types mirrored exactly: DEFAULT_CAMERA fov
!     is the INT 60, light intensity the REAL 1.0, etc.)
!   _get / _set / _props        -> get_attr / set_attr / props_of +
!                                  set_props
!   _is                         -> is_node
!   _make_diagnostic / _emit / _warn -> emit_diag / warn_diag (the
!     real ErrorBag's add(Diagnostic) is the first interface Python's
!     _emit successfully uses; dyn spans are null, so diagnostics are
!     span-less, matching a Python span of None)
!   _make for the injected nodes -> make_default_scene / _camera /
!     _light / _object / _output / make_program: these reproduce the
!     exact __dict__ shape Python's _make produces for each dataclass
!     (e.g. an injected SceneStmt has ONLY name/width/height/bg/span;
!     an injected LightStmt gains a trailing "dir" attribute because
!     _make setattr's the unconsumed dir= field next to direction=)
!   _vec3 / _add / _scale_mul   -> vec3_norm / vec_add / scale_mul
!     (Python numeric promotion preserved: int op int stays dyn_int,
!     any real operand makes a dyn_real -- repeat offsets are reals,
!     so expanded positions print as 0.0 / -3.0, not 0 / -3)
!   _apply_group / _expand_group -> apply_group / expand_group
!   _repeat_mode / _grid_dims / _expand_repeat -> same names
!   desugar                     -> desugar
!
! HOOKS: desugar.py contains NO extension dispatch (grep-verified:
! no ext_* reference); group/repeat expansion is closed.  The only
! extension registry in this pair of modules is f3dc_ir's
! (ir_register_extension / ir_apply_extensions).  Nothing in the
! desugar pass needs registering, and no hook is stubbed here.
! No type-bound procedures are used anywhere (flang build rule).
module f3dc_desugar
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, dyn_assign, &
                      dyn_dict_get, dyn_dict_set, dyn_dict_has, &
                      dyn_dict_len, dyn_dict_key_at, &
                      dyn_list_push, dyn_list_len, dyn_list_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: char_list, char_list_append, char_list_len, &
                      char_list_at, char_list_clear, fmt_int, to_lower, &
                      str_split, str_join, path_dirname, str_builder, &
                      sb_init, sb_add, sb_text, sb_len
  use f3dc_errors, only: error_bag_t, make_diagnostic, error_bag_add, &
                         error_bag_error_count
  use f3dc_parser, only: f3dc_parse
  use f3dc_ast, only: ast_program, ast_program_from_dyn, &
                      ast_program_to_dyn
  implicit none
  private

  public :: desugar
  public :: desugar_program_ast
  public :: desugar_max_placements, desugar_default_scene, &
            desugar_default_camera, desugar_default_light, &
            desugar_demo_pose, desugar_anim_defaults
  public :: get_attr, set_attr, props_of, set_props, is_node
  public :: vec_add, scale_mul, apply_group, expand_group, &
            repeat_mode, grid_dims, expand_repeat

  integer(int64), parameter :: MAX_PLACEMENTS = 10000_int64

  !> Growable array of dyn statements (the working statement lists).
  type :: dyn_arr
    type(dyn), allocatable :: items(:)
    integer :: n = 0
    integer :: cap = 0
  end type dyn_arr

  !> Per-prim auto-name counters (Python dict prim -> count).
  type :: prim_counters
    character(len=256) :: keys(256)
    integer :: vals(256) = 0
    integer :: n = 0
  end type prim_counters

contains

  ! ==================================================================
  ! Defaults tables (desugar.py module constants)
  ! ==================================================================

  integer(int64) function desugar_max_placements()
    desugar_max_placements = MAX_PLACEMENTS
  end function desugar_max_placements

  !> DEFAULT_SCENE = {"width": 640, "height": 480, "bg": "#191923"}
  function desugar_default_scene() result(d)
    type(dyn) :: d
    d = dyn_dict()
    call dyn_dict_set(d, "width", dyn_int(640_int64))
    call dyn_dict_set(d, "height", dyn_int(480_int64))
    call dyn_dict_set(d, "bg", dyn_str("#191923"))
  end function desugar_default_scene

  !> DEFAULT_CAMERA: pos (3, 2.5, 4), target (0,0,0), up (0,1,0),
  !! fov 60 (int), near 0.1, far 100 (int).
  function desugar_default_camera() result(d)
    type(dyn) :: d
    d = dyn_dict()
    call dyn_dict_set(d, "pos", vec3_mixed(dyn_int(3_int64), &
                                           dyn_real(2.5_real64), &
                                           dyn_int(4_int64)))
    call dyn_dict_set(d, "target", vec3_ints(0, 0, 0))
    call dyn_dict_set(d, "up", vec3_ints(0, 1, 0))
    call dyn_dict_set(d, "fov", dyn_int(60_int64))
    call dyn_dict_set(d, "near", dyn_real(0.1_real64))
    call dyn_dict_set(d, "far", dyn_int(100_int64))
  end function desugar_default_camera

  !> DEFAULT_LIGHT: kind directional, dir (-0.5, -1, -0.7),
  !! intensity 1.0 (real).
  function desugar_default_light() result(d)
    type(dyn) :: d
    d = dyn_dict()
    call dyn_dict_set(d, "kind", dyn_str("directional"))
    call dyn_dict_set(d, "dir", vec3_mixed(dyn_real(-0.5_real64), &
                                           dyn_int(-1_int64), &
                                           dyn_real(-0.7_real64)))
    call dyn_dict_set(d, "intensity", dyn_real(1.0_real64))
  end function desugar_default_light

  !> DEMO_POSE = (20, 35, 0)
  function desugar_demo_pose() result(d)
    type(dyn) :: d
    d = vec3_ints(20, 35, 0)
  end function desugar_demo_pose

  !> ANIM_DEFAULTS in dict order: axis, speed, duration, fps, ease.
  function desugar_anim_defaults() result(d)
    type(dyn) :: d
    d = dyn_dict()
    call dyn_dict_set(d, "axis", dyn_str("y"))
    call dyn_dict_set(d, "speed", dyn_int(90_int64))
    call dyn_dict_set(d, "duration", dyn_int(5_int64))
    call dyn_dict_set(d, "fps", dyn_int(30_int64))
    call dyn_dict_set(d, "ease", dyn_str("linear"))
  end function desugar_anim_defaults

  ! ==================================================================
  ! Small dyn helpers
  ! ==================================================================

  function vec3_ints(a, b, c) result(v)
    integer, intent(in) :: a, b, c
    type(dyn) :: v
    v = dyn_list()
    call dyn_list_push(v, dyn_int(int(a, int64)))
    call dyn_list_push(v, dyn_int(int(b, int64)))
    call dyn_list_push(v, dyn_int(int(c, int64)))
  end function vec3_ints

  function vec3_mixed(a, b, c) result(v)
    type(dyn), intent(in) :: a, b, c
    type(dyn) :: v
    v = dyn_list()
    call dyn_list_push(v, a)
    call dyn_list_push(v, b)
    call dyn_list_push(v, c)
  end function vec3_mixed

  !> Python truthiness of a dyn value.
  pure logical function is_truthy(v)
    type(dyn), intent(in) :: v
    select case (v%kind)
    case (DYN_K_NULL)
      is_truthy = .false.
    case (DYN_K_BOOL)
      is_truthy = v%b
    case (DYN_K_INT)
      is_truthy = v%i /= 0_int64
    case (DYN_K_REAL)
      is_truthy = v%r /= 0.0_real64
    case (DYN_K_STR)
      is_truthy = allocated(v%s)
      if (is_truthy) is_truthy = len(v%s) > 0
    case (DYN_K_LIST)
      is_truthy = v%n_items > 0
    case (DYN_K_DICT)
      is_truthy = v%n_entries > 0
    case default
      is_truthy = .false.
    end select
  end function is_truthy

  !> The string inside a dyn_str ("" when it is not a string).
  function str_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_STR .and. allocated(v%s)) then
      out = v%s
    else
      out = ""
    end if
  end function str_of

  !> Python int(value): truncation toward zero for reals.
  function to_int64(v) result(n)
    type(dyn), intent(in) :: v
    integer(int64) :: n
    integer :: ios
    real(real64) :: rv
    select case (v%kind)
    case (DYN_K_INT)
      n = v%i
    case (DYN_K_BOOL)
      n = merge(1_int64, 0_int64, v%b)
    case (DYN_K_REAL)
      if (abs(v%r) >= 9.0e18_real64) then
        n = huge(0_int64)
        if (v%r < 0.0_real64) n = -huge(0_int64)
      else
        n = int(v%r, int64)
      end if
    case (DYN_K_STR)
      n = 0_int64
      if (allocated(v%s)) then
        read (v%s, *, iostat=ios) n
        if (ios /= 0) then
          read (v%s, *, iostat=ios) rv
          if (ios == 0) n = int(rv, int64)
        end if
      end if
    case default
      n = 0_int64
    end select
  end function to_int64

  function to_real64(v) result(r)
    type(dyn), intent(in) :: v
    real(real64) :: r
    select case (v%kind)
    case (DYN_K_INT)
      r = real(v%i, real64)
    case (DYN_K_REAL)
      r = v%r
    case (DYN_K_BOOL)
      r = merge(1.0_real64, 0.0_real64, v%b)
    case default
      r = 0.0_real64
    end select
  end function to_real64

  pure logical function is_number(v)
    type(dyn), intent(in) :: v
    is_number = v%kind == DYN_K_INT .or. v%kind == DYN_K_REAL .or. &
                v%kind == DYN_K_BOOL
  end function is_number

  !> Python a + b for numbers: int+int stays int, else real.
  function num_add(a, b) result(out)
    type(dyn), intent(in) :: a, b
    type(dyn) :: out
    if (a%kind == DYN_K_INT .and. b%kind == DYN_K_INT) then
      out = dyn_int(a%i + b%i)
    else
      out = dyn_real(to_real64(a) + to_real64(b))
    end if
  end function num_add

  !> Python a * b for numbers: int*int stays int, else real.
  function num_mul(a, b) result(out)
    type(dyn), intent(in) :: a, b
    type(dyn) :: out
    if (a%kind == DYN_K_INT .and. b%kind == DYN_K_INT) then
      out = dyn_int(a%i * b%i)
    else
      out = dyn_real(to_real64(a) * to_real64(b))
    end if
  end function num_mul

  ! ==================================================================
  ! dyn_arr helpers
  ! ==================================================================

  subroutine arr_push(arr, val)
    type(dyn_arr), intent(inout) :: arr
    type(dyn), intent(in) :: val
    type(dyn), allocatable :: tmp(:)
    integer :: k
    if (arr%n >= arr%cap) then
      allocate (tmp(max(4, 2 * arr%cap)))
      do k = 1, arr%n
        tmp(k) = dyn_copy(arr%items(k))
      end do
      call move_alloc(tmp, arr%items)
      arr%cap = size(arr%items)
    end if
    arr%n = arr%n + 1
    arr%items(arr%n) = dyn_copy(val)
  end subroutine arr_push

  subroutine arr_extend(dst, src)
    type(dyn_arr), intent(inout) :: dst
    type(dyn_arr), intent(in) :: src
    integer :: k
    do k = 1, src%n
      call arr_push(dst, src%items(k))
    end do
  end subroutine arr_extend

  subroutine arr_insert(arr, idx, val)
    type(dyn_arr), intent(inout) :: arr
    integer, intent(in) :: idx
    type(dyn), intent(in) :: val
    integer :: k
    call arr_push(arr, val)  ! grow / append a scratch slot
    do k = arr%n - 1, idx, -1
      arr%items(k + 1) = dyn_copy(arr%items(k))
    end do
    arr%items(idx) = dyn_copy(val)
  end subroutine arr_insert

  subroutine arr_from_list(arr, v)
    type(dyn_arr), intent(inout) :: arr
    type(dyn), intent(in) :: v
    integer :: k
    arr%n = 0
    if (v%kind == DYN_K_LIST) then
      do k = 1, dyn_list_len(v)
        call arr_push(arr, dyn_list_at(v, k))
      end do
    end if
  end subroutine arr_from_list

  function arr_to_list(arr) result(v)
    type(dyn_arr), intent(in) :: arr
    type(dyn) :: v
    integer :: k
    v = dyn_list()
    do k = 1, arr%n
      call dyn_list_push(v, arr%items(k))
    end do
  end function arr_to_list

  ! ==================================================================
  ! _get / _set / _props (duck-typed field access)
  ! ==================================================================

  !> The _SYNONYMS table of desugar.py, in priority order.
  subroutine syn_for(key, syns, n)
    character(len=*), intent(in) :: key
    character(len=32), intent(out) :: syns(8)
    integer, intent(out) :: n
    syns = ""
    n = 1
    syns(1) = key
    select case (key)
    case ("statements")
      syns(1:4) = ["statements", "body      ", "stmts     ", &
                   "lines     "]
      n = 4
    case ("children")
      syns(1:5) = ["children  ", "body      ", "statements", &
                   "members   ", "objects   "]
      n = 5
    case ("props")
      syns(1:2) = ["props     ", "properties"]
      n = 2
    case ("prim")
      syns(1:4) = ["prim      ", "primitive ", "kind      ", &
                   "type      "]
      n = 4
    case ("kind")
      syns(1:6) = ["kind      ", "type      ", "mode      ", &
                   "action    ", "motion    ", "verb      "]
      n = 6
    case ("mode")
      syns(1:4) = ["mode      ", "kind      ", "type      ", &
                   "pattern   "]
      n = 4
    case ("target")
      syns(1:2) = ["target    ", "target_nam"]
      syns(2) = "target_name"
      n = 2
    case ("pos")
      syns(1:3) = ["pos       ", "position  ", "at        "]
      n = 3
    case ("dir")
      syns(1:2) = ["dir       ", "direction "]
      n = 2
    case ("bg")
      syns(1:4) = ["bg        ", "background", "bg_color  ", &
                   "background"]
      syns(4) = "background_color"
      n = 4
    case ("width")
      syns(1:2) = ["width     ", "w         "]
      n = 2
    case ("height")
      syns(1:2) = ["height    ", "h         "]
      n = 2
    case ("count")
      syns(1:4) = ["count     ", "n         ", "times     ", &
                   "repeat_cou"]
      syns(4) = "repeat_count"
      n = 4
    case ("body1")
      syns(1:8) = ["body      ", "obj       ", "object    ", &
                   "child     ", "stmt      ", "statement ", &
                   "template  ", "object_stm"]
      syns(8) = "object_stmt"
      n = 8
    end select
  end subroutine syn_for

  !> _get(obj, key, default): first synonym attribute that exists
  !! and is not None, else the props-dict entry for key, else
  !! found=.false. (the caller substitutes its default).
  subroutine get_attr(obj, key, val, found)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: key
    type(dyn), intent(out) :: val
    logical, intent(out) :: found
    character(len=32) :: syns(8)
    integer :: n, i
    type(dyn) :: v, props
    found = .false.
    val = dyn_null()
    call syn_for(key, syns, n)
    do i = 1, n
      if (dyn_dict_has(obj, trim(syns(i)))) then
        v = dyn_dict_get(obj, trim(syns(i)))
        if (v%kind /= DYN_K_NULL) then
          call dyn_assign(val, v)
          found = .true.
          return
        end if
      end if
    end do
    props = dyn_dict_get(obj, "props")
    if (props%kind == DYN_K_DICT .and. dyn_dict_has(props, key)) then
      v = dyn_dict_get(props, key)
      if (v%kind /= DYN_K_NULL) then
        call dyn_assign(val, v)
        found = .true.
      end if
    end if
  end subroutine get_attr

  !> _set(obj, key, value): write via the first synonym key that
  !! exists, else create the first synonym key.
  subroutine set_attr(obj, key, val)
    type(dyn), intent(inout) :: obj
    character(len=*), intent(in) :: key
    type(dyn), intent(in) :: val
    character(len=32) :: syns(8)
    integer :: n, i
    call syn_for(key, syns, n)
    do i = 1, n
      if (dyn_dict_has(obj, trim(syns(i)))) then
        call dyn_dict_set(obj, trim(syns(i)), val)
        return
      end if
    end do
    call dyn_dict_set(obj, trim(syns(1)), val)
  end subroutine set_attr

  !> _props(stmt, create): the node's props dict (a copy; write back
  !! with set_props).  An absent / non-dict props yields {}.
  subroutine props_of(node, props)
    type(dyn), intent(in) :: node
    type(dyn), intent(out) :: props
    props = dyn_dict_get(node, "props")
    if (props%kind /= DYN_K_DICT) props = dyn_dict()
  end subroutine props_of

  subroutine set_props(node, props)
    type(dyn), intent(inout) :: node
    type(dyn), intent(in) :: props
    call dyn_dict_set(node, "props", props)
  end subroutine set_props

  !> Raw key presence + value (Python getattr(stmt, key, None) /
  !! dict .get semantics used in several places).
  subroutine raw_get(node, key, val, present)
    type(dyn), intent(in) :: node
    character(len=*), intent(in) :: key
    type(dyn), intent(out) :: val
    logical, intent(out) :: present
    present = dyn_dict_has(node, key)
    val = dyn_dict_get(node, key)
  end subroutine raw_get

  ! ==================================================================
  ! _is: node-kind recognition by key signature.
  !
  !   ObjectStmt  has "prim"
  !   SceneStmt   has "bg" + "width", no "prim", no "kind"
  !               (parser nodes also carry fog/tonemap/shadow keys;
  !               the injected default carries only the dataclass
  !               fields -- both shapes satisfy this signature)
  !   CameraStmt  has "fov" + "pos" + "target"
  !   LightStmt   has "direction" + "intensity" + "kind"
  !   GroupStmt   has "children"
  !   RepeatStmt  has "obj" + "mode"
  !   AnimStmt    has "verb"
  !   LoadStmt    has "path" + "file", no "kind"
  !   ImportStmt  has "import_path" (v2.0 P3, parser-only node:
  !               desugar expands it away before validate runs)
  !   ControlsStmt has "autorotate"
  !   OutputStmt  has "still" (parser shape), or the injected shape
  !               kind+path+format+width+height with "mode"
  ! ==================================================================
  logical function is_node(stmt, name)
    type(dyn), intent(in) :: stmt
    character(len=*), intent(in) :: name
    is_node = .false.
    if (stmt%kind /= DYN_K_DICT) return
    select case (name)
    case ("ObjectStmt")
      is_node = dyn_dict_has(stmt, "prim")
    case ("SceneStmt")
      is_node = dyn_dict_has(stmt, "bg") .and. &
                dyn_dict_has(stmt, "width") .and. &
                .not. dyn_dict_has(stmt, "prim") .and. &
                .not. dyn_dict_has(stmt, "kind")
    case ("CameraStmt")
      is_node = dyn_dict_has(stmt, "fov") .and. &
                dyn_dict_has(stmt, "pos") .and. &
                dyn_dict_has(stmt, "target")
    case ("LightStmt")
      is_node = dyn_dict_has(stmt, "direction") .and. &
                dyn_dict_has(stmt, "intensity") .and. &
                dyn_dict_has(stmt, "kind")
    case ("GroupStmt")
      is_node = dyn_dict_has(stmt, "children")
    case ("ImportStmt")
      is_node = dyn_dict_has(stmt, "import_path")
    case ("RepeatStmt")
      is_node = dyn_dict_has(stmt, "obj") .and. &
                dyn_dict_has(stmt, "mode")
    case ("AnimStmt")
      is_node = dyn_dict_has(stmt, "verb")
    case ("LoadStmt")
      is_node = dyn_dict_has(stmt, "path") .and. &
                dyn_dict_has(stmt, "file") .and. &
                .not. dyn_dict_has(stmt, "kind")
    case ("ControlsStmt")
      is_node = dyn_dict_has(stmt, "autorotate")
    case ("OutputStmt")
      is_node = dyn_dict_has(stmt, "still") .or. &
        (dyn_dict_has(stmt, "kind") .and. &
         dyn_dict_has(stmt, "path") .and. &
         dyn_dict_has(stmt, "format") .and. &
         dyn_dict_has(stmt, "width") .and. &
         dyn_dict_has(stmt, "height") .and. &
         dyn_dict_has(stmt, "mode"))
    case default
      is_node = .false.
    end select
  end function is_node

  ! ==================================================================
  ! Diagnostics (_make_diagnostic / _emit / _warn)
  ! ==================================================================

  subroutine emit_diag(bag, code, severity, message)
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: code, severity, message
    call error_bag_add(bag, make_diagnostic(code, severity, message))
  end subroutine emit_diag

  subroutine warn_diag(bag, code, message)
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: code, message
    call emit_diag(bag, code, "warning", message)
  end subroutine warn_diag

  ! ==================================================================
  ! _make equivalents for the injected nodes (exact __dict__ shapes)
  ! ==================================================================

  !> SceneStmt(name=None, width=640, height=480, bg="#191923",
  !! span=span0): _make's props= field is dropped (SceneStmt has no
  !! props field), so the node carries only the dataclass fields.
  function make_default_scene(span) result(node)
    type(dyn), intent(in) :: span
    type(dyn) :: node
    node = dyn_dict()
    call dyn_dict_set(node, "name", dyn_null())
    call dyn_dict_set(node, "width", dyn_int(640_int64))
    call dyn_dict_set(node, "height", dyn_int(480_int64))
    call dyn_dict_set(node, "bg", dyn_str("#191923"))
    call dyn_dict_set(node, "span", span)
  end function make_default_scene

  !> CameraStmt(pos, target, up, fov, near, far, span=span0) with
  !! DEFAULT_CAMERA values (props= dropped, as above).
  function make_default_camera(span) result(node)
    type(dyn), intent(in) :: span
    type(dyn) :: node, cam
    cam = desugar_default_camera()
    node = dyn_dict()
    call dyn_dict_set(node, "pos", dyn_dict_get(cam, "pos"))
    call dyn_dict_set(node, "target", dyn_dict_get(cam, "target"))
    call dyn_dict_set(node, "up", dyn_dict_get(cam, "up"))
    call dyn_dict_set(node, "fov", dyn_dict_get(cam, "fov"))
    call dyn_dict_set(node, "near", dyn_dict_get(cam, "near"))
    call dyn_dict_set(node, "far", dyn_dict_get(cam, "far"))
    call dyn_dict_set(node, "span", span)
  end function make_default_camera

  !> LightStmt(kind, direction=dir, color=None default, intensity,
  !! span) plus the trailing "dir" attribute _make setattr's.
  function make_default_light(span) result(node)
    type(dyn), intent(in) :: span
    type(dyn) :: node, light
    light = desugar_default_light()
    node = dyn_dict()
    call dyn_dict_set(node, "kind", dyn_dict_get(light, "kind"))
    call dyn_dict_set(node, "direction", dyn_dict_get(light, "dir"))
    call dyn_dict_set(node, "color", dyn_null())
    call dyn_dict_set(node, "intensity", &
                      dyn_dict_get(light, "intensity"))
    call dyn_dict_set(node, "span", span)
    call dyn_dict_set(node, "dir", dyn_dict_get(light, "dir"))
  end function make_default_light

  !> ObjectStmt(prim="cube", name=None, color_raw=None default,
  !! props={"size": 2}, span=span0) -- the empty-program cube.
  function make_default_object(span) result(node)
    type(dyn), intent(in) :: span
    type(dyn) :: node, props
    props = dyn_dict()
    call dyn_dict_set(props, "size", dyn_int(2_int64))
    node = dyn_dict()
    call dyn_dict_set(node, "prim", dyn_str("cube"))
    call dyn_dict_set(node, "name", dyn_null())
    call dyn_dict_set(node, "color_raw", dyn_null())
    call dyn_dict_set(node, "props", props)
    call dyn_dict_set(node, "span", span)
  end function make_default_object

  !> OutputStmt(kind="render", span=span0); the remaining dataclass
  !! fields default to None and props= is dropped.
  function make_default_output(span) result(node)
    type(dyn), intent(in) :: span
    type(dyn) :: node
    node = dyn_dict()
    call dyn_dict_set(node, "kind", dyn_str("render"))
    call dyn_dict_set(node, "path", dyn_null())
    call dyn_dict_set(node, "format", dyn_null())
    call dyn_dict_set(node, "width", dyn_null())
    call dyn_dict_set(node, "height", dyn_null())
    call dyn_dict_set(node, "span", span)
  end function make_default_output

  !> Program(statements=stmts, span=span0): the rebuilt root carries
  !! only the two dataclass fields (the parser's stmts / source /
  !! errors extras do not survive a Python desugar either).
  function make_program(stmts_list, span) result(node)
    type(dyn), intent(in) :: stmts_list, span
    type(dyn) :: node
    node = dyn_dict()
    call dyn_dict_set(node, "statements", stmts_list)
    call dyn_dict_set(node, "span", span)
  end function make_program

  ! ==================================================================
  ! Vec helpers (_vec3 / _add / _scale_mul)
  ! ==================================================================

  !> _vec3(value, default): None -> default; a number -> (v, v, v);
  !! a sequence -> its first three items, padded from default.
  !! (A string value would become a tuple of characters in Python;
  !! that pathological case yields the default here.)
  function vec3_norm(v, d1, d2, d3) result(out)
    type(dyn), intent(in) :: v, d1, d2, d3
    type(dyn) :: out
    type(dyn) :: item
    integer :: i
    out = dyn_list()
    if (v%kind == DYN_K_NULL) then
      call dyn_list_push(out, d1)
      call dyn_list_push(out, d2)
      call dyn_list_push(out, d3)
    else if (is_number(v)) then
      call dyn_list_push(out, v)
      call dyn_list_push(out, v)
      call dyn_list_push(out, v)
    else if (v%kind == DYN_K_LIST) then
      do i = 1, 3
        if (i <= dyn_list_len(v)) then
          item = dyn_list_at(v, i)
          call dyn_list_push(out, item)
        else
          select case (i)
          case (1)
            call dyn_list_push(out, d1)
          case (2)
            call dyn_list_push(out, d2)
          case (3)
            call dyn_list_push(out, d3)
          end select
        end if
      end do
    else
      call dyn_list_push(out, d1)
      call dyn_list_push(out, d2)
      call dyn_list_push(out, d3)
    end if
  end function vec3_norm

  !> _add(a, b): componentwise addition of _vec3(a) and _vec3(b).
  function vec_add(a, b) result(out)
    type(dyn), intent(in) :: a, b
    type(dyn) :: out, av, bv
    type(dyn) :: zero
    integer :: i
    zero = dyn_int(0_int64)
    av = vec3_norm(a, zero, zero, zero)
    bv = vec3_norm(b, zero, zero, zero)
    out = dyn_list()
    do i = 1, 3
      call dyn_list_push(out, num_add(dyn_list_at(av, i), &
                                      dyn_list_at(bv, i)))
    end do
  end function vec_add

  !> _scale_mul(a, b): scalar*scalar, else componentwise on vec3s
  !! with (1, 1, 1) defaults.
  function scale_mul(a, b) result(out)
    type(dyn), intent(in) :: a, b
    type(dyn) :: out, av, bv
    type(dyn) :: one
    integer :: i
    if (is_number(a) .and. is_number(b)) then
      out = num_mul(a, b)
      return
    end if
    one = dyn_int(1_int64)
    av = vec3_norm(a, one, one, one)
    bv = vec3_norm(b, one, one, one)
    out = dyn_list()
    do i = 1, 3
      call dyn_list_push(out, num_mul(dyn_list_at(av, i), &
                                      dyn_list_at(bv, i)))
    end do
  end function scale_mul

  ! ==================================================================
  ! Group expansion (_apply_group / _expand_group)
  ! ==================================================================

  subroutine apply_group(child, g_name, g_has_name, g_props)
    type(dyn), intent(inout) :: child
    character(len=*), intent(in) :: g_name
    logical, intent(in) :: g_has_name
    type(dyn), intent(in) :: g_props
    type(dyn) :: props, g_at, base, nv
    logical :: nf
    character(len=:), allocatable :: name
    call props_of(child, props)
    if (dyn_dict_has(g_props, "at") .or. &
        dyn_dict_has(g_props, "pos")) then
      if (dyn_dict_has(g_props, "at")) then
        g_at = dyn_dict_get(g_props, "at")
      else
        g_at = dyn_dict_get(g_props, "pos")
      end if
      if (dyn_dict_has(props, "at")) then
        base = dyn_dict_get(props, "at")
      else if (dyn_dict_has(props, "pos")) then
        base = dyn_dict_get(props, "pos")
      else
        base = vec3_ints(0, 0, 0)
      end if
      call dyn_dict_set(props, "at", vec_add(g_at, base))
    end if
    if (dyn_dict_has(g_props, "rotate") .or. &
        dyn_dict_has(g_props, "rot")) then
      if (dyn_dict_has(g_props, "rotate")) then
        g_at = dyn_dict_get(g_props, "rotate")
      else
        g_at = dyn_dict_get(g_props, "rot")
      end if
      if (dyn_dict_has(props, "rotate")) then
        base = dyn_dict_get(props, "rotate")
      else if (dyn_dict_has(props, "rot")) then
        base = dyn_dict_get(props, "rot")
      else
        base = vec3_ints(0, 0, 0)
      end if
      call dyn_dict_set(props, "rotate", vec_add(g_at, base))
    end if
    if (dyn_dict_has(g_props, "scale")) then
      if (dyn_dict_has(props, "scale")) then
        call dyn_dict_set(props, "scale", &
          scale_mul(dyn_dict_get(g_props, "scale"), &
                    dyn_dict_get(props, "scale")))
      else
        call dyn_dict_set(props, "scale", &
                          dyn_dict_get(g_props, "scale"))
      end if
    end if
    ! P3: a group header's `mirror x|y|z` is inherited by children
    ! that do not carry their own mirror (the child's own axis
    ! wins; mirror is a single-axis prop, so there is no compose).
    if (dyn_dict_has(g_props, "mirror") .and. &
        .not. dyn_dict_has(props, "mirror")) then
      call dyn_dict_set(props, "mirror", &
                        dyn_dict_get(g_props, "mirror"))
    end if
    call set_props(child, props)
    call get_attr(child, "name", nv, nf)
    if (nf .and. is_truthy(nv) .and. g_has_name) then
      name = str_of(nv)
      if (nv%kind == DYN_K_STR) &
        call set_attr(child, "name", &
                      dyn_str(g_name // "." // name))
    end if
  end subroutine apply_group

  !> The repeat/group template held under a body1 synonym: returns
  !! the template list, whether it was a list, and the source key
  !! ("" when it came from the props fallback / was absent).
  subroutine get_body1(node, tpls, was_list, src_key, has)
    type(dyn), intent(in) :: node
    type(dyn_arr), intent(inout) :: tpls
    logical, intent(out) :: was_list, has
    character(len=:), allocatable, intent(out) :: src_key
    character(len=32) :: syns(8)
    integer :: n, i
    type(dyn) :: v
    has = .false.
    was_list = .false.
    src_key = ""
    tpls%n = 0
    call syn_for("body1", syns, n)
    do i = 1, n
      if (dyn_dict_has(node, trim(syns(i)))) then
        v = dyn_dict_get(node, trim(syns(i)))
        if (v%kind /= DYN_K_NULL) then
          src_key = trim(syns(i))
          has = .true.
          if (v%kind == DYN_K_LIST) then
            was_list = .true.
            call arr_from_list(tpls, v)
          else
            call arr_push(tpls, v)
          end if
          return
        end if
      end if
    end do
  end subroutine get_body1

  !> Write templates back into a repeat node after in-place edits,
  !! syncing the obj/object alias pair (in Python both attributes
  !! reference the one object, so an edit shows through both).
  subroutine set_body1(node, tpls, was_list, src_key)
    type(dyn), intent(inout) :: node
    type(dyn_arr), intent(in) :: tpls
    logical, intent(in) :: was_list
    character(len=*), intent(in) :: src_key
    type(dyn) :: v
    if (len(src_key) == 0) return
    if (was_list) then
      v = arr_to_list(tpls)
    else
      if (tpls%n < 1) return
      v = dyn_copy(tpls%items(1))
    end if
    call dyn_dict_set(node, src_key, v)
    if (src_key == "obj" .and. dyn_dict_has(node, "object")) &
      call dyn_dict_set(node, "object", v)
    if (src_key == "object" .and. dyn_dict_has(node, "obj")) &
      call dyn_dict_set(node, "obj", v)
  end subroutine set_body1

  !> Apply a group's transform/prefix to a repeat statement's
  !! templates (the repeat itself is expanded later, in the main
  !! desugar loop, so only its templates are touched here).
  subroutine apply_group_to_repeat(child, g_name, g_has_name, g_props)
    type(dyn), intent(inout) :: child
    character(len=*), intent(in) :: g_name
    logical, intent(in) :: g_has_name
    type(dyn), intent(in) :: g_props
    type(dyn_arr) :: tpls
    logical :: was_list, has_body
    character(len=:), allocatable :: src_key
    integer :: j
    type(dyn) :: tpl
    tpls%n = 0
    tpls%cap = 0
    call get_body1(child, tpls, was_list, src_key, has_body)
    if (.not. has_body) return
    do j = 1, tpls%n
      tpl = dyn_copy(tpls%items(j))
      if (tpl%kind /= DYN_K_NULL) then
        call apply_group(tpl, g_name, g_has_name, g_props)
        tpls%items(j) = dyn_copy(tpl)
      end if
    end do
    call set_body1(child, tpls, was_list, src_key)
  end subroutine apply_group_to_repeat

  !> v2.0 P3: retarget an animation statement at a sibling of the
  !! same group: an explicit target that names one of the group's
  !! own statements (the `known` list, pre-prefix names for direct
  !! children / post-inner-expansion names for a nested group's
  !! output) gains the group prefix, exactly like a name does.
  !! Targets of it/last/None keep the step-3b resolution, and a
  !! target naming nothing in the group is left alone (it refers
  !! to a statement outside the group).
  subroutine prefix_anim_target(node, g_name, g_has_name, known)
    type(dyn), intent(inout) :: node
    character(len=*), intent(in) :: g_name
    logical, intent(in) :: g_has_name
    type(char_list), intent(in) :: known
    type(dyn) :: tv
    logical :: tf
    character(len=:), allocatable :: t, low
    if (.not. g_has_name) return
    if (.not. is_node(node, "AnimStmt")) return
    call get_attr(node, "target", tv, tf)
    if (.not. tf .or. tv%kind /= DYN_K_STR) return
    t = str_of(tv)
    if (len(t) == 0) return
    low = to_lower(t)
    if (low == "it" .or. low == "last") return
    if (.not. name_in(known, t)) return
    call set_attr(node, "target", dyn_str(g_name // "." // t))
  end subroutine prefix_anim_target

  !> The truthy string "name" attributes of a statement list.
  subroutine collect_names(stmts, names)
    type(dyn_arr), intent(in) :: stmts
    type(char_list), intent(inout) :: names
    integer :: k
    type(dyn) :: nv
    logical :: nf
    call char_list_clear(names)
    do k = 1, stmts%n
      call get_attr(stmts%items(k), "name", nv, nf)
      if (nf .and. is_truthy(nv) .and. nv%kind == DYN_K_STR) &
        call char_list_append(names, str_of(nv))
    end do
  end subroutine collect_names

  recursive subroutine expand_group(stmt, out)
    type(dyn), intent(in) :: stmt
    type(dyn_arr), intent(inout) :: out
    type(dyn) :: nv, g_props, cv, child
    logical :: nf, cf
    character(len=:), allocatable :: g_name
    logical :: g_has_name
    type(dyn_arr) :: children, sub
    type(char_list) :: sib_names, sub_names
    integer :: k, j
    call get_attr(stmt, "name", nv, nf)
    g_has_name = nf .and. is_truthy(nv) .and. nv%kind == DYN_K_STR
    g_name = str_of(nv)
    call props_of(stmt, g_props)
    call get_attr(stmt, "children", cv, cf)
    children%n = 0
    children%cap = 0
    if (.not. cf) then
      ! no children: expands to nothing
    else if (cv%kind == DYN_K_LIST) then
      call arr_from_list(children, cv)
    else
      call arr_push(children, cv)
    end if
    call collect_names(children, sib_names)
    do k = 1, children%n
      child = dyn_copy(children%items(k))
      if (is_node(child, "GroupStmt")) then
        ! Nested group (reachable from import expansion and repeat
        ! templates; the parser itself allows one level in source):
        ! expand the inner group first, then compose THIS group's
        ! props/prefix over its output, so names double-prefix
        ! (outer.inner.name) and transforms accumulate.
        sub%n = 0
        sub%cap = 0
        call expand_group(child, sub)
        call collect_names(sub, sub_names)
        do j = 1, sub%n
          child = dyn_copy(sub%items(j))
          if (is_node(child, "RepeatStmt")) then
            call apply_group_to_repeat(child, g_name, g_has_name, &
                                       g_props)
            call arr_push(out, child)
            cycle
          end if
          call apply_group(child, g_name, g_has_name, g_props)
          call prefix_anim_target(child, g_name, g_has_name, &
                                  sub_names)
          call arr_push(out, child)
        end do
        cycle
      end if
      if (is_node(child, "RepeatStmt")) then
        call apply_group_to_repeat(child, g_name, g_has_name, g_props)
        call arr_push(out, child)
        cycle
      end if
      call apply_group(child, g_name, g_has_name, g_props)
      call prefix_anim_target(child, g_name, g_has_name, sib_names)
      call arr_push(out, child)
    end do
  end subroutine expand_group

  ! ==================================================================
  ! Repeat / grid / ring expansion (_repeat_mode / _grid_dims /
  ! _expand_repeat)
  ! ==================================================================

  function repeat_mode(stmt) result(mode)
    type(dyn), intent(in) :: stmt
    character(len=:), allocatable :: mode
    type(dyn) :: v, props
    logical :: found
    character(len=:), allocatable :: low
    call get_attr(stmt, "mode", v, found)
    if (found .and. v%kind == DYN_K_STR) then
      low = to_lower(str_of(v))
      if (low == "repeat" .or. low == "grid" .or. low == "ring") then
        mode = low
        return
      end if
    end if
    call props_of(stmt, props)
    if (dyn_dict_has(props, "mode")) then
      v = dyn_dict_get(props, "mode")
      if (v%kind == DYN_K_STR) then
        mode = to_lower(str_of(v))
        return
      end if
    end if
    call get_attr(stmt, "a", v, found)
    if (found) then
      mode = "grid"
      return
    end if
    call get_attr(stmt, "b", v, found)
    if (found) then
      mode = "grid"
      return
    end if
    call get_attr(stmt, "count", v, found)
    if (found .and. v%kind == DYN_K_LIST) then
      mode = "grid"
      return
    end if
    mode = "repeat"
  end function repeat_mode

  !> One _grid_dims fallback chain: raw-or-_get, then the
  !! nx/cols/x-style synonym chain (first truthy wins, else the last
  !! value), then the props fallback.  which=1 -> a-chain
  !! (nx/cols/x, props a/nx), which=2 -> b-chain (nz/rows/z, props
  !! b/nz).
  subroutine grid_chain(stmt, which, val)
    type(dyn), intent(in) :: stmt
    integer, intent(in) :: which
    type(dyn), intent(out) :: val
    type(dyn) :: raw, v, props
    logical :: present, found
    character(len=8) :: k_main, k1, k2, k3, p_main, p_alt
    if (which == 1) then
      k_main = "a"; k1 = "nx"; k2 = "cols"; k3 = "x"
      p_main = "a"; p_alt = "nx"
    else
      k_main = "b"; k1 = "nz"; k2 = "rows"; k3 = "z"
      p_main = "b"; p_alt = "nz"
    end if
    call raw_get(stmt, trim(k_main), raw, present)
    if (present .and. is_truthy(raw)) then
      call dyn_assign(val, raw)
    else
      call get_attr(stmt, trim(k_main), val, found)
      if (.not. found) val = dyn_null()
    end if
    if (.not. is_truthy(val)) then
      call get_attr(stmt, trim(k1), v, found)
      if (found .and. is_truthy(v)) then
        call dyn_assign(val, v)
      else
        call get_attr(stmt, trim(k2), v, found)
        if (found .and. is_truthy(v)) then
          call dyn_assign(val, v)
        else
          call get_attr(stmt, trim(k3), val, found)
          if (.not. found) val = dyn_null()
        end if
      end if
    end if
    if (.not. is_truthy(val)) then
      call props_of(stmt, props)
      if (dyn_dict_has(props, trim(p_main))) then
        val = dyn_dict_get(props, trim(p_main))
      else if (dyn_dict_has(props, trim(p_alt))) then
        val = dyn_dict_get(props, trim(p_alt))
      else
        val = dyn_int(1_int64)
      end if
    end if
  end subroutine grid_chain

  subroutine grid_dims(stmt, ga, gb)
    type(dyn), intent(in) :: stmt
    integer(int64), intent(out) :: ga, gb
    type(dyn) :: v
    call grid_chain(stmt, 1, v)
    if (v%kind == DYN_K_NULL) then
      ga = 1_int64  ! Python int(None) raises; unreachable for
                    ! parser-built grid nodes (see report)
    else
      ga = to_int64(v)
    end if
    call grid_chain(stmt, 2, v)
    if (v%kind == DYN_K_NULL) then
      gb = 1_int64
    else
      gb = to_int64(v)
    end if
  end subroutine grid_dims

  subroutine expand_repeat(stmt, bag, budget, out, used)
    type(dyn), intent(in) :: stmt
    type(error_bag_t), intent(inout) :: bag
    integer(int64), intent(in) :: budget
    type(dyn_arr), intent(inout) :: out
    integer(int64), intent(out) :: used
    character(len=:), allocatable :: mode, src_key
    type(dyn_arr) :: tpls, templates, flat, sub
    logical :: was_list, has_body
    type(dyn) :: rprops, tp, v, spacing, radius, sx, sz
    type(dyn) :: size_val, size_num, eff
    integer(int64) :: ga, gb, total, placements
    integer :: k, i, total_i
    mode = repeat_mode(stmt)
    tpls%n = 0
    tpls%cap = 0
    call get_body1(stmt, tpls, was_list, src_key, has_body)
    templates%n = 0
    templates%cap = 0
    if (has_body) then
      do k = 1, tpls%n
        if (tpls%items(k)%kind /= DYN_K_NULL) &
          call arr_push(templates, tpls%items(k))
      end do
    end if
    used = 0_int64
    if (templates%n == 0) return
    ! A grouped template flattens first, then is repeated.
    flat%n = 0
    flat%cap = 0
    do k = 1, templates%n
      if (is_node(templates%items(k), "GroupStmt")) then
        sub%n = 0
        sub%cap = 0
        call expand_group(dyn_copy(templates%items(k)), sub)
        call arr_extend(flat, sub)
      else
        call arr_push(flat, templates%items(k))
      end if
    end do
    ! Repeat-level props: the templates' props merged in order, then
    ! the repeat statement's own props win.
    rprops = dyn_dict()
    do k = 1, flat%n
      call props_of(flat%items(k), tp)
      call merge_props(rprops, tp)
    end do
    call props_of(stmt, tp)
    call merge_props(rprops, tp)
    if (mode == "grid") then
      call grid_dims(stmt, ga, gb)
      total = ga * gb
    else
      ga = 0_int64
      gb = 0_int64
      block
        type(dyn) :: raw
        logical :: present, found
        call raw_get(stmt, "a", raw, present)
        if (present .and. is_truthy(raw)) then
          total = to_int64(raw)
        else
          call get_attr(stmt, "count", v, found)
          if (.not. found) v = dyn_int(1_int64)
          if (is_truthy(v)) then
            total = to_int64(v)
          else
            total = 1_int64
          end if
        end if
      end block
    end if
    placements = total * int(flat%n, int64)
    if (placements > budget) then
      call emit_diag(bag, "E820", "error", &
        "expansion of " // trim(fmt_int(placements)) // &
        " placements would exceed the " // &
        trim(fmt_int(MAX_PLACEMENTS)) // "-placement limit")
      do k = 1, flat%n
        call arr_push(out, flat%items(k))
      end do
      used = int(flat%n, int64)
      return
    end if
    ! Spacing: explicit prop wins; else 1.5x the template size (2).
    spacing = dyn_dict_get(rprops, "spacing")
    if (spacing%kind == DYN_K_NULL) then
      size_val = dyn_null()
      do k = 1, flat%n
        call props_of(flat%items(k), tp)
        if (dyn_dict_has(tp, "size")) &
          size_val = dyn_dict_get(tp, "size")
      end do
      if (size_val%kind == DYN_K_LIST) then
        if (dyn_list_len(size_val) > 0) then
          size_num = dyn_list_at(size_val, 1)
        else
          size_num = dyn_int(2_int64)
        end if
      else
        call dyn_assign(size_num, size_val)
      end if
      if (size_num%kind == DYN_K_NULL) then
        eff = dyn_int(2_int64)
      else
        call dyn_assign(eff, size_num)
      end if
      spacing = num_mul(eff, dyn_real(1.5_real64))
    end if
    if (spacing%kind == DYN_K_LIST) then
      if (dyn_list_len(spacing) == 0) then
        sx = dyn_int(0_int64)  ! Python raises IndexError; guard
        sz = dyn_int(0_int64)
      else
        sx = dyn_list_at(spacing, 1)
        if (dyn_list_len(spacing) > 2) then
          sz = dyn_list_at(spacing, 3)
        else
          sz = dyn_list_at(spacing, dyn_list_len(spacing))
        end if
      end if
    else
      call dyn_assign(sx, spacing)
      call dyn_assign(sz, spacing)
    end if
    radius = dyn_dict_get(rprops, "radius")
    if (radius%kind == DYN_K_NULL) radius = dyn_real(5.0_real64)
    total_i = int(total)
    do k = 1, flat%n
      block
        type(dyn) :: tpl, clone, cprops, nv, pv, base_raw, base_at
        type(dyn) :: off, rot_raw, rot, new_rot, zero
        logical :: nf, pf, base_name_ok
        character(len=:), allocatable :: base_name, prim_str
        real(real64) :: ang, theta
        logical :: is_ring
        tpl = dyn_copy(flat%items(k))
        call get_attr(tpl, "name", nv, nf)
        base_name_ok = nf .and. is_truthy(nv) .and. &
                       nv%kind == DYN_K_STR
        base_name = str_of(nv)
        call get_attr(tpl, "prim", pv, pf)
        if (pf .and. pv%kind == DYN_K_STR) then
          prim_str = str_of(pv)
        else if (pf .and. pv%kind == DYN_K_INT) then
          prim_str = trim(fmt_int(pv%i))
        else
          prim_str = "object"
        end if
        is_ring = (mode == "ring")
        zero = dyn_int(0_int64)
        do i = 0, total_i - 1
          clone = dyn_copy(tpl)
          call props_of(clone, cprops)
          if (dyn_dict_has(cprops, "at")) then
            base_raw = dyn_dict_get(cprops, "at")
          else if (dyn_dict_has(cprops, "pos")) then
            base_raw = dyn_dict_get(cprops, "pos")
          else
            base_raw = vec3_ints(0, 0, 0)
          end if
          base_at = vec3_norm(base_raw, zero, zero, zero)
          off = dyn_list()
          ang = 0.0_real64
          if (mode == "repeat") then
            call dyn_list_push(off, num_mul(dyn_real( &
              real(i, real64) - &
              (real(total, real64) - 1.0_real64) / 2.0_real64), sx))
            call dyn_list_push(off, zero)
            call dyn_list_push(off, zero)
          else if (mode == "grid") then
            block
              integer :: col, row
              if (ga == 0_int64) then
                col = 0
                row = 0  ! Python raises ZeroDivisionError; guard
              else
                col = mod(i, int(ga))
                row = i / int(ga)
              end if
              call dyn_list_push(off, num_mul(dyn_real( &
                real(col, real64) - &
                (real(ga, real64) - 1.0_real64) / 2.0_real64), sx))
              call dyn_list_push(off, zero)
              call dyn_list_push(off, num_mul(dyn_real( &
                real(row, real64) - &
                (real(gb, real64) - 1.0_real64) / 2.0_real64), sz))
            end block
          else  ! ring: XZ circle, placement 0 at +Z
            if (total /= 0_int64) then
              ang = 360.0_real64 * real(i, real64) / &
                    real(total, real64)
            else
              ang = 0.0_real64
            end if
            theta = ang * (acos(-1.0_real64) / 180.0_real64)
            call dyn_list_push(off, &
              num_mul(radius, dyn_real(sin(theta))))
            call dyn_list_push(off, zero)
            call dyn_list_push(off, &
              num_mul(radius, dyn_real(cos(theta))))
          end if
          call dyn_dict_set(cprops, "at", vec_add(base_at, off))
          if (is_ring) then
            if (dyn_dict_has(cprops, "rotate")) then
              rot_raw = dyn_dict_get(cprops, "rotate")
            else if (dyn_dict_has(cprops, "rot")) then
              rot_raw = dyn_dict_get(cprops, "rot")
            else
              rot_raw = vec3_ints(0, 0, 0)
            end if
            rot = vec3_norm(rot_raw, zero, zero, zero)
            new_rot = dyn_list()
            call dyn_list_push(new_rot, dyn_list_at(rot, 1))
            call dyn_list_push(new_rot, &
              num_add(dyn_list_at(rot, 2), dyn_real(ang)))
            call dyn_list_push(new_rot, dyn_list_at(rot, 3))
            call dyn_dict_set(cprops, "rotate", new_rot)
          end if
          call set_props(clone, cprops)
          if (base_name_ok) then
            call set_attr(clone, "name", dyn_str(base_name // "_" // &
                          trim(fmt_int(int(i + 1, int64)))))
          else
            call set_attr(clone, "name", dyn_str(prim_str // &
                          trim(fmt_int(int(i + 1, int64)))))
          end if
          call arr_push(out, clone)
        end do
      end block
    end do
    used = placements
  end subroutine expand_repeat

  !> dict.update: copy every key of src into dst (existing keys keep
  !! their position, new keys append -- Python dict order).
  subroutine merge_props(dst, src)
    type(dyn), intent(inout) :: dst
    type(dyn), intent(in) :: src
    integer :: k
    character(len=:), allocatable :: key
    do k = 1, dyn_dict_len(src)
      key = dyn_dict_key_at(src, k)
      call dyn_dict_set(dst, key, dyn_dict_get(src, key))
    end do
  end subroutine merge_props

  ! ==================================================================
  ! Import expansion (v2.0 P3-A)
  !
  !   import "parts/fin.f3d" as fin at 0 1 0
  !
  ! desugar resolves the path against the importing file's
  ! directory, reads + parses the part with f3dc_parse (the part's
  ! own path as source name, so its diagnostics point at the part),
  ! recursively expands any imports inside it, and wraps the result
  ! in a synthetic group node (name = the `as` name, props = the
  ! import line's props) that the ordinary expand_group machinery
  ! then prefixes/composes like a hand-written group.
  !
  ! Rules:
  !   - Paths are relative; absolute paths are E103.
  !   - The lexically canonicalised resolved path must stay inside
  !     the ROOT base_dir tree (the directory of the top-level .f3d
  !     file); escaping it via ".." is E103.  (Containment is
  !     lexical: symlinks are not resolved.)
  !   - A missing/unreadable part is E501.
  !   - A part must not contain scene / camera / render / export
  !     statements (E103, checked recursively through its groups).
  !   - Cycles are E504 with the chain of canonical paths.  The
  !     expansion stack is seeded with the root file's own path
  !     (the program's source_name) when it is known.
  !   - Every distinct part file read is recorded once, in
  !     first-read order, in the output program's "_import_deps"
  !     dyn list (canonical resolved path strings) for the future
  !     preview watcher.  The key is only present when at least one
  !     import was read, and no emitter reads it, so it never
  !     appears in any emitted artifact.
  ! ==================================================================

  !> Lexical path canonicalisation: split on "/", drop "" and "."
  !! components, resolve ".." against earlier components (kept
  !! only as leading ".." of a relative path).  "" canonicalises
  !! to "."; an absolute path keeps its leading "/".
  function canon_path(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    type(char_list) :: parts, comps, tmp
    logical :: absolute
    character(len=:), allocatable :: c
    integer :: i, j
    absolute = .false.
    if (len(path) > 0) absolute = path(1:1) == "/"
    call str_split(path, "/", parts)
    do i = 1, char_list_len(parts)
      c = char_list_at(parts, i)
      if (c == "" .or. c == ".") cycle
      if (c == "..") then
        if (char_list_len(comps) > 0) then
          if (char_list_at(comps, char_list_len(comps)) /= "..") then
            call char_list_clear(tmp)
            do j = 1, char_list_len(comps) - 1
              call char_list_append(tmp, char_list_at(comps, j))
            end do
            comps = tmp
            cycle
          end if
        end if
        if (.not. absolute) call char_list_append(comps, "..")
        cycle
      end if
      call char_list_append(comps, c)
    end do
    out = str_join(comps, "/")
    if (absolute) then
      out = "/" // out
    else if (len(out) == 0) then
      out = "."
    end if
  end function canon_path

  !> dir // "/" // rel (no double slash, empty dir passes rel).
  function join_dir(dir, rel) result(out)
    character(len=*), intent(in) :: dir, rel
    character(len=:), allocatable :: out
    if (len(dir) == 0) then
      out = rel
    else if (dir(len(dir):len(dir)) == "/") then
      out = dir // rel
    else
      out = dir // "/" // rel
    end if
  end function join_dir

  !> Is canonical `resolved` inside the canonical root directory?
  logical function path_contained(resolved, root)
    character(len=*), intent(in) :: resolved, root
    if (root == "/") then
      path_contained = .false.
      if (len(resolved) > 0) path_contained = resolved(1:1) == "/"
    else if (root == ".") then
      block
        logical :: is_parent
        is_parent = .false.
        if (len(resolved) >= 3) is_parent = resolved(1:3) == "../"
        path_contained = .not. (resolved == ".." .or. is_parent)
      end block
    else
      path_contained = .false.
      if (len(resolved) > len(root) + 1) &
        path_contained = resolved(1:len(root) + 1) == root // "/"
    end if
  end function path_contained

  !> Whole-file read (same stream-read shape as the CLI's read_file).
  subroutine read_text_file(path, text, ok)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: text
    logical, intent(out) :: ok
    integer :: unit, ios, sz
    logical :: there
    ok = .false.
    inquire (file=path, exist=there, size=sz)
    if (.not. there) then
      text = ""
      return
    end if
    open (newunit=unit, file=path, access="stream", &
          form="unformatted", status="old", iostat=ios)
    if (ios /= 0) then
      text = ""
      return
    end if
    allocate (character(len=max(sz, 0)) :: text)
    if (sz > 0) read (unit, iostat=ios) text
    close (unit)
    ok = (ios == 0)
  end subroutine read_text_file

  !> A synthetic group node with the parser's group_node shape.
  function make_synth_group(name, props, children_list, line_no) &
      result(node)
    character(len=*), intent(in) :: name
    type(dyn), intent(in) :: props, children_list
    integer(int64), intent(in) :: line_no
    type(dyn) :: node
    node = dyn_dict()
    call dyn_dict_set(node, "name", dyn_str(name))
    call dyn_dict_set(node, "props", dyn_copy(props))
    call dyn_dict_set(node, "body", dyn_list())
    call dyn_dict_set(node, "span", dyn_null())
    call dyn_dict_set(node, "children", dyn_copy(children_list))
    call dyn_dict_set(node, "objects", dyn_copy(children_list))
    call dyn_dict_set(node, "statements", dyn_copy(children_list))
    call dyn_dict_set(node, "line", dyn_int(line_no))
  end function make_synth_group

  !> Part restriction walk: scene/camera/output statements are
  !! forbidden in an imported part (groups are walked through).
  recursive subroutine check_part(stmts, resolved, bag, bad)
    type(dyn_arr), intent(in) :: stmts
    character(len=*), intent(in) :: resolved
    type(error_bag_t), intent(inout) :: bag
    logical, intent(out) :: bad
    integer :: k
    type(dyn) :: node, cv, kv
    logical :: cf
    type(dyn_arr) :: kids
    character(len=:), allocatable :: kind
    bad = .false.
    do k = 1, stmts%n
      call dyn_assign(node, stmts%items(k))
      kind = ""
      if (is_node(node, "SceneStmt")) then
        kind = "scene"
      else if (is_node(node, "CameraStmt")) then
        kind = "camera"
      else if (is_node(node, "OutputStmt")) then
        kv = dyn_dict_get(node, "kind")
        if (kv%kind == DYN_K_STR) then
          kind = str_of(kv)
        else
          kind = "render"
        end if
      end if
      if (len(kind) > 0) then
        call emit_diag(bag, "E103", "error", &
          "imported part '" // resolved // "' must not contain a '" &
          // kind // "' statement (parts define objects, groups " &
          // "and animations only)")
        bad = .true.
        return
      end if
      if (is_node(node, "GroupStmt")) then
        call get_attr(node, "children", cv, cf)
        kids%n = 0
        kids%cap = 0
        if (cf .and. cv%kind == DYN_K_LIST) &
          call arr_from_list(kids, cv)
        call check_part(kids, resolved, bag, bad)
        if (bad) return
      end if
    end do
  end subroutine check_part

  !> Expand one import statement into a synthetic group appended
  !! to `out` (or nothing, after recording the diagnostic).
  recursive subroutine expand_one_import(node, cur_dir, root_canon, &
                                         stack, bag, deps, &
                                         deps_seen, out)
    type(dyn), intent(in) :: node
    character(len=*), intent(in) :: cur_dir, root_canon
    type(char_list), intent(in) :: stack
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(inout) :: deps
    type(char_list), intent(inout) :: deps_seen
    type(dyn_arr), intent(inout) :: out
    character(len=:), allocatable :: path_str, as_name, resolved
    character(len=:), allocatable :: text, chain
    type(str_builder) :: sb_chain
    type(dyn) :: iprops, part_prog, pv, lv
    logical :: pf, rok, bad
    type(dyn_arr) :: part_stmts, sub_out
    type(char_list) :: stack2
    integer :: nerr0, i
    path_str = str_of(dyn_dict_get(node, "import_path"))
    as_name = str_of(dyn_dict_get(node, "name"))
    call props_of(node, iprops)
    if (len(path_str) > 0) then
     if (path_str(1:1) == "/") then
      call emit_diag(bag, "E103", "error", &
        "import '" // path_str // "': absolute paths are not " &
        // "allowed (give a path relative to the importing file)")
      return
     end if
    end if
    resolved = canon_path(join_dir(cur_dir, path_str))
    if (.not. path_contained(resolved, root_canon)) then
      call emit_diag(bag, "E103", "error", &
        "import '" // path_str // "' resolves to '" // resolved &
        // "', which is outside the project directory '" &
        // root_canon // "'")
      return
    end if
    if (name_in(stack, resolved)) then
      call sb_init(sb_chain)
      do i = 1, char_list_len(stack)
        if (i > 1) call sb_add(sb_chain, " -> ")
        call sb_add(sb_chain, char_list_at(stack, i))
      end do
      if (sb_len(sb_chain) > 0) call sb_add(sb_chain, " -> ")
      call sb_add(sb_chain, resolved)
      chain = sb_text(sb_chain)
      call emit_diag(bag, "E504", "error", &
                     "import cycle: " // chain)
      return
    end if
    call read_text_file(resolved, text, rok)
    if (.not. rok) then
      call emit_diag(bag, "E501", "error", &
        "could not load import '" // path_str // "' (looked for " &
        // resolved // ")")
      return
    end if
    if (.not. name_in(deps_seen, resolved)) then
      call char_list_append(deps_seen, resolved)
      call dyn_list_push(deps, dyn_str(resolved))
    end if
    nerr0 = error_bag_error_count(bag)
    call f3dc_parse(text, resolved, bag, part_prog)
    if (error_bag_error_count(bag) > nerr0) return
    part_stmts%n = 0
    part_stmts%cap = 0
    call get_attr(part_prog, "statements", pv, pf)
    if (pf .and. pv%kind == DYN_K_LIST) &
      call arr_from_list(part_stmts, pv)
    call check_part(part_stmts, resolved, bag, bad)
    if (bad) return
    stack2 = stack
    call char_list_append(stack2, resolved)
    sub_out%n = 0
    sub_out%cap = 0
    call expand_imports(part_stmts, path_dirname(resolved), &
                        root_canon, stack2, bag, deps, deps_seen, &
                        sub_out)
    lv = dyn_dict_get(node, "line")
    call arr_push(out, make_synth_group(as_name, iprops, &
                                        arr_to_list(sub_out), &
                                        to_int64(lv)))
  end subroutine expand_one_import

  !> Replace every import statement in a statement list by its
  !! synthetic group, in source order, recursing into group bodies
  !! (whose imports belong to the same file, hence the same
  !! cur_dir).  All other statements pass through untouched.
  recursive subroutine expand_imports(stmts_in, cur_dir, root_canon, &
                                      stack, bag, deps, deps_seen, &
                                      out)
    type(dyn_arr), intent(in) :: stmts_in
    character(len=*), intent(in) :: cur_dir, root_canon
    type(char_list), intent(in) :: stack
    type(error_bag_t), intent(inout) :: bag
    type(dyn), intent(inout) :: deps
    type(char_list), intent(inout) :: deps_seen
    type(dyn_arr), intent(inout) :: out
    integer :: k
    type(dyn) :: node, cv, sub_list
    logical :: cf
    type(dyn_arr) :: kids, sub
    do k = 1, stmts_in%n
      node = dyn_copy(stmts_in%items(k))
      if (is_node(node, "ImportStmt")) then
        call expand_one_import(node, cur_dir, root_canon, stack, &
                               bag, deps, deps_seen, out)
      else if (is_node(node, "GroupStmt")) then
        call get_attr(node, "children", cv, cf)
        if (cf .and. cv%kind == DYN_K_LIST) then
          kids%n = 0
          kids%cap = 0
          call arr_from_list(kids, cv)
          sub%n = 0
          sub%cap = 0
          call expand_imports(kids, cur_dir, root_canon, stack, &
                              bag, deps, deps_seen, sub)
          sub_list = arr_to_list(sub)
          call dyn_dict_set(node, "children", dyn_copy(sub_list))
          call dyn_dict_set(node, "objects", dyn_copy(sub_list))
          call dyn_dict_set(node, "statements", dyn_copy(sub_list))
        end if
        call arr_push(out, node)
      else
        call arr_push(out, node)
      end if
    end do
  end subroutine expand_imports

  ! ==================================================================
  ! The pass (desugar)
  ! ==================================================================

  subroutine counter_inc(pc, prim, new_val)
    type(prim_counters), intent(inout) :: pc
    character(len=*), intent(in) :: prim
    integer, intent(out) :: new_val
    integer :: k
    do k = 1, pc%n
      if (trim(pc%keys(k)) == prim) then
        pc%vals(k) = pc%vals(k) + 1
        new_val = pc%vals(k)
        return
      end if
    end do
    if (pc%n < 256) then
      pc%n = pc%n + 1
      pc%keys(pc%n) = prim
      pc%vals(pc%n) = 1
      new_val = 1
    else
      new_val = 1  ! prim-name overflow guard (unreachable in practice)
    end if
  end subroutine counter_inc

  subroutine counter_set(pc, prim, v)
    type(prim_counters), intent(inout) :: pc
    character(len=*), intent(in) :: prim
    integer, intent(in) :: v
    integer :: k
    do k = 1, pc%n
      if (trim(pc%keys(k)) == prim) then
        pc%vals(k) = v
        return
      end if
    end do
    if (pc%n < 256) then
      pc%n = pc%n + 1
      pc%keys(pc%n) = prim
      pc%vals(pc%n) = v
    end if
  end subroutine counter_set

  integer function counter_get(pc, prim)
    type(prim_counters), intent(in) :: pc
    character(len=*), intent(in) :: prim
    integer :: k
    counter_get = 0
    do k = 1, pc%n
      if (trim(pc%keys(k)) == prim) then
        counter_get = pc%vals(k)
        return
      end if
    end do
  end function counter_get

  logical function name_in(list, name)
    type(char_list), intent(in) :: list
    character(len=*), intent(in) :: name
    integer :: k
    character(len=:), allocatable :: item
    name_in = .false.
    do k = 1, char_list_len(list)
      item = char_list_at(list, k)
      if (len(item) == len(name) .and. item == name) then
        name_in = .true.
        return
      end if
    end do
  end function name_in

  logical function any_node(stmts, name)
    type(dyn_arr), intent(in) :: stmts
    character(len=*), intent(in) :: name
    integer :: k
    any_node = .false.
    do k = 1, stmts%n
      if (is_node(stmts%items(k), name)) then
        any_node = .true.
        return
      end if
    end do
  end function any_node

  !> desugar(program, bag, base_dir) -> new Program.  In Fortran the
  !! input is not mutated (Python deep-copies it first, with the
  !! same effect) and bag is required (pass a scratch bag for
  !! Python's bag=None).  base_dir is the directory of the .f3d
  !! file the program came from (v2.0 P3: import statements are
  !! resolved against it; it is also the containment root).
  subroutine desugar(program_in, bag, base_dir, program_out)
    type(dyn), intent(in) :: program_in
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: base_dir
    type(dyn), intent(out) :: program_out
    type(dyn) :: work, v, span0, import_deps
    type(dyn_arr) :: stmts, flat, expanded, injected
    logical :: found, was_empty
    integer(int64) :: budget, used
    integer :: k
    work = dyn_copy(program_in)
    import_deps = dyn_list()
    stmts%n = 0
    stmts%cap = 0
    call get_attr(work, "statements", v, found)
    if (found .and. v%kind == DYN_K_LIST) &
      call arr_from_list(stmts, v)
    ! span0 = work.span or (first statement's span)
    span0 = dyn_null()
    block
      type(dyn) :: sv
      logical :: sf
      call raw_get(work, "span", sv, sf)
      if (sf .and. sv%kind /= DYN_K_NULL) then
        call dyn_assign(span0, sv)
      else if (stmts%n > 0) then
        call raw_get(stmts%items(1), "span", sv, sf)
        if (sf .and. sv%kind /= DYN_K_NULL) call dyn_assign(span0, sv)
      end if
    end block
    was_empty = (stmts%n == 0)

    ! 0. Expand import statements (v2.0 P3), in source order, before
    ! group/repeat expansion: each import becomes a synthetic group
    ! node that step 1 expands like a hand-written group.
    block
      type(dyn_arr) :: imp_out
      type(char_list) :: stack, deps_seen
      type(dyn) :: sv
      logical :: sf
      character(len=:), allocatable :: root_canon
      root_canon = canon_path(base_dir)
      call raw_get(work, "source_name", sv, sf)
      if (.not. sf .or. sv%kind /= DYN_K_STR) &
        call raw_get(work, "source", sv, sf)
      if (sf .and. sv%kind == DYN_K_STR .and. &
          len(str_of(sv)) > 0) &
        call char_list_append(stack, canon_path(str_of(sv)))
      imp_out%n = 0
      imp_out%cap = 0
      call expand_imports(stmts, base_dir, root_canon, stack, bag, &
                          import_deps, deps_seen, imp_out)
      call move_alloc(imp_out%items, stmts%items)
      stmts%n = imp_out%n
      stmts%cap = imp_out%cap
      imp_out%n = 0
      imp_out%cap = 0
    end block

    ! 1-2. Expand groups and repeats, in source order.
    flat%n = 0
    flat%cap = 0
    budget = MAX_PLACEMENTS
    do k = 1, stmts%n
      if (is_node(stmts%items(k), "GroupStmt")) then
        call expand_group(stmts%items(k), flat)
      else if (is_node(stmts%items(k), "RepeatStmt")) then
        expanded%n = 0
        expanded%cap = 0
        call expand_repeat(stmts%items(k), bag, budget, expanded, &
                           used)
        budget = budget - used
        call arr_extend(flat, expanded)
      else
        call arr_push(flat, stmts%items(k))
      end if
    end do

    ! Empty program: inject the demo cube.
    if (was_empty .and. .not. any_node(flat, "ObjectStmt")) then
      call arr_insert(flat, 1, make_default_object(span0))
      call warn_diag(bag, "W101", &
                     "empty program: injecting a default cube")
    end if

    ! 3a. Object defaults + auto-names.
    block
      logical :: single
      type(char_list) :: used_names
      type(prim_counters) :: counters
      integer :: n_obj, cnt
      type(dyn) :: node, props, nv, pv
      logical :: nf, pf, present
      character(len=:), allocatable :: prim_str, candidate
      n_obj = 0
      do k = 1, flat%n
        if (is_node(flat%items(k), "ObjectStmt")) n_obj = n_obj + 1
      end do
      single = (n_obj == 1)
      do k = 1, flat%n
        call get_attr(flat%items(k), "name", nv, nf)
        if (nf .and. is_truthy(nv) .and. nv%kind == DYN_K_STR) &
          call char_list_append(used_names, str_of(nv))
      end do
      counters%n = 0
      do k = 1, flat%n
        if (.not. is_node(flat%items(k), "ObjectStmt")) cycle
        node = dyn_copy(flat%items(k))
        call props_of(node, props)
        if (.not. dyn_dict_has(props, "at") .and. &
            .not. dyn_dict_has(props, "pos")) then
          call get_attr(node, "pos", nv, nf)
          if (.not. nf) &
            call dyn_dict_set(props, "at", vec3_ints(0, 0, 0))
        end if
        if (.not. dyn_dict_has(props, "rotate") .and. &
            .not. dyn_dict_has(props, "rot")) then
          call raw_get(node, "rotate", nv, present)
          if (.not. present .or. nv%kind == DYN_K_NULL) then
            if (single) then
              call dyn_dict_set(props, "rotate", &
                                desugar_demo_pose())
            else
              call dyn_dict_set(props, "rotate", vec3_ints(0, 0, 0))
            end if
          end if
        end if
        call set_props(node, props)
        call get_attr(node, "name", nv, nf)
        if (.not. (nf .and. is_truthy(nv))) then
          call get_attr(node, "prim", pv, pf)
          if (pf .and. pv%kind == DYN_K_STR) then
            prim_str = str_of(pv)
          else if (pf .and. pv%kind == DYN_K_INT) then
            prim_str = trim(fmt_int(pv%i))
          else
            prim_str = "object"
          end if
          call counter_inc(counters, prim_str, cnt)
          candidate = prim_str // trim(fmt_int(int(cnt, int64)))
          do while (name_in(used_names, candidate))
            cnt = counter_get(counters, prim_str) + 1
            call counter_set(counters, prim_str, cnt)
            candidate = prim_str // trim(fmt_int(int(cnt, int64)))
          end do
          call char_list_append(used_names, candidate)
          call set_attr(node, "name", dyn_str(candidate))
        end if
        flat%items(k) = dyn_copy(node)
      end do
    end block

    ! 3b. Animation target resolution + defaults.
    block
      character(len=:), allocatable :: last_object
      logical :: has_last
      type(dyn) :: node, props, nv, kv
      logical :: nf, kf, present
      has_last = .false.
      last_object = ""
      do k = 1, flat%n
        node = dyn_copy(flat%items(k))
        if (is_node(node, "ObjectStmt") .or. &
            is_node(node, "LoadStmt")) then
          call get_attr(node, "name", nv, nf)
          if (nf .and. is_truthy(nv) .and. &
              nv%kind == DYN_K_STR) then
            last_object = str_of(nv)
            has_last = .true.
          end if
          cycle
        end if
        if (.not. is_node(node, "AnimStmt")) cycle
        call props_of(node, props)
        call get_attr(node, "target", nv, nf)
        if (.not. nf .and. dyn_dict_has(props, "target")) then
          nv = dyn_dict_get(props, "target")
          nf = nv%kind /= DYN_K_NULL
        end if
        if (.not. nf .or. (nv%kind == DYN_K_STR .and. &
            (to_lower(str_of(nv)) == "it" .or. &
             to_lower(str_of(nv)) == "last"))) then
          if (has_last) &
            call set_attr(node, "target", dyn_str(last_object))
        end if
        ! ANIM_DEFAULTS, in dict order.
        call anim_default(node, props, "axis", dyn_str("y"))
        call anim_default(node, props, "speed", dyn_int(90_int64))
        call anim_default(node, props, "duration", dyn_int(5_int64))
        call anim_default(node, props, "fps", dyn_int(30_int64))
        call anim_default(node, props, "ease", dyn_str("linear"))
        call get_attr(node, "kind", kv, kf)
        if (kf .and. kv%kind == DYN_K_STR) then
          if (to_lower(str_of(kv)) == "spin" .and. &
              .not. dyn_dict_has(props, "loop")) then
            call raw_get(node, "loop", nv, present)
            if (.not. present .or. nv%kind == DYN_K_NULL) &
              call dyn_dict_set(props, "loop", dyn_str("forever"))
          end if
        end if
        call set_props(node, props)
        flat%items(k) = dyn_copy(node)
      end do
    end block

    ! 3c. Inject missing scene / camera / light statements.
    injected%n = 0
    injected%cap = 0
    if (.not. any_node(flat, "SceneStmt")) then
      call arr_push(injected, make_default_scene(span0))
      call warn_diag(bag, "W101", &
        "no scene statement: injecting default scene " // &
        "640x480 bg #191923")
    end if
    if (.not. any_node(flat, "CameraStmt")) then
      call arr_push(injected, make_default_camera(span0))
      call warn_diag(bag, "W101", &
        "no camera statement: injecting default camera at " // &
        "(3, 2.5, 4) looking at (0, 0, 0), fov 60")
    end if
    if (.not. any_node(flat, "LightStmt")) then
      call arr_push(injected, make_default_light(span0))
      call warn_diag(bag, "W101", &
        "no light statement: injecting default directional light " // &
        "dir (-0.5, -1, -0.7) intensity 1.0")
    end if
    block
      type(dyn_arr) :: merged
      merged%n = 0
      merged%cap = 0
      call arr_extend(merged, injected)
      call arr_extend(merged, flat)
      call move_alloc(merged%items, flat%items)
      flat%n = merged%n
      flat%cap = merged%cap
      merged%n = 0
      merged%cap = 0
    end block

    ! 3d. Missing output defaults to a plain render.
    if (.not. any_node(flat, "OutputStmt")) &
      call arr_push(flat, make_default_output(span0))

    program_out = make_program(arr_to_list(flat), span0)
    ! v2.0 P3: dependency record for the future preview watcher
    ! (see the import-expansion section header).  Only present when
    ! at least one part file was read; no emitter reads this key.
    if (dyn_list_len(import_deps) > 0) &
      call dyn_dict_set(program_out, "_import_deps", import_deps)
  end subroutine desugar

  ! ==================================================================
  ! Typed AST entry (v3.0 Phase 6 / C1)
  !
  !   desugar_program_ast is the typed twin of desugar above: it
  !   lowers the typed ast_program to the dyn dict shape desugar
  !   works on (ast_program_to_dyn), runs the unchanged dyn pass,
  !   and raises the flattened result back to a typed ast_program
  !   (ast_program_from_dyn).  No desugaring logic lives here, so
  !   the typed and dyn entries can never drift apart.  base_dir
  !   plays exactly the role it plays for desugar (import paths
  !   resolve against it; it is also the containment root), and
  !   diagnostics land in bag exactly as desugar leaves them.
  !   ok is .true. when the pass added no error diagnostics to
  !   bag (warnings, e.g. the W101 default-injection notes, do not
  !   clear it); on .false. ast_out still carries the converted
  !   result, mirroring desugar, which always returns a program.
  ! ==================================================================

  subroutine desugar_program_ast(ast_in, bag, base_dir, ast_out, ok)
    type(ast_program), intent(in) :: ast_in
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: base_dir
    type(ast_program), intent(out) :: ast_out
    logical, intent(out) :: ok
    type(dyn) :: dyn_in, dyn_out
    integer :: nerr0
    nerr0 = error_bag_error_count(bag)
    call dyn_assign(dyn_in, ast_program_to_dyn(ast_in))
    call desugar(dyn_in, bag, base_dir, dyn_out)
    ast_out = ast_program_from_dyn(dyn_out)
    ok = error_bag_error_count(bag) == nerr0
  end subroutine desugar_program_ast

  !> One ANIM_DEFAULTS entry: set props[key] when the key is absent
  !! from props and the node's own attribute is None.
  subroutine anim_default(node, props, key, value)
    type(dyn), intent(in) :: node
    type(dyn), intent(inout) :: props
    character(len=*), intent(in) :: key
    type(dyn), intent(in) :: value
    type(dyn) :: raw
    logical :: present
    if (dyn_dict_has(props, key)) return
    call raw_get(node, key, raw, present)
    if (present .and. raw%kind /= DYN_K_NULL) return
    call dyn_dict_set(props, key, value)
  end subroutine anim_default

end module f3dc_desugar
