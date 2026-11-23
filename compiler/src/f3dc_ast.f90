! f3dc_ast.f90 -- typed AST layer for the native Forge3D compiler
! (v3.0 Phase 6 / C1).
!
! ---------------------------------------------------------------------
! DESIGN: statement structure typed, props bag retained.
!
!   The parser (f3dc_parser) builds every statement as a dyn DICT
!   whose keys are the Python node's __dict__ keys.  This module
!   raises that untyped dict tree into a typed one:
!
!     * STATEMENT STRUCTURE IS TYPED.  An ast_stmt carries, as real
!       Fortran components, the fields every statement form shares:
!       the class tag (kind), the statement name, the animation /
!       reference target, the source line, and the statement's
!       children (group members / repeat templates) as a recursive
!       allocatable array of ast_stmt.  An ast_program is a growable
!       array of ast_stmt (capacity doubling, append_ast_stmt).
!
!     * THE PROPS BAG IS RETAINED.  Each statement's per-statement
!       properties stay in a dyn dict component named props -- the
!       "props bag" -- exactly the dict the parser built under the
!       node's "props" key.  This is the same pattern as the IR's
!       extension bag (f3dc_ir's ir_object%ext / ir_scene%ext, the
!       "extensions" dict): the typed core covers the stable,
!       universal structure, and the bag carries the open set of
!       extension keys (object geometry props, animation props,
!       Wave B/C/E extras, future statement vocabularies) without
!       forcing a core-type change for every new key.  Typed access
!       to the bag goes through ast_stmt_get_str / _get_num /
!       _get_bool (with caller defaults) and the matching setters.
!
!     * A FIELDS BAG KEEPS THE CONVERSION LOSSLESS.  Statement forms
!       differ in their remaining top-level keys (an ObjectStmt's
!       prim / color_raw / colour, a SceneStmt's width / height /
!       bg, a LightStmt's direction / intensity, a RepeatStmt's
!       mode / count, an OutputStmt's path / format / still, ...).
!       Those keys are retained verbatim in a second dyn dict, the
!       fields bag, so ast_program_from_dyn and ast_program_to_dyn
!       are structural inverses over the real node fields: a dyn
!       program lowered and raised again has the same statements,
!       the same keys and the same values (dict KEY ORDER may
!       differ: extracted keys are re-appended by dyn_dict_set,
!       which is unobservable to every dict consumer).
!
! ---------------------------------------------------------------------
! Node shapes mirrored (from f3dc_parser's _make call sites and
! f3dc_desugar's is_node signatures; field names are copied exactly):
!
!   Program      statements, span, stmts, source, source_name,
!                errors
!   ObjectStmt   prim, name, color_raw, props, span, primitive,
!                type, kind, colour, color, colour_raw, line,
!                + the props spread (at, size, rotate, ...)
!   SceneStmt    name, width, height, bg, span, size, background,
!                colour, color, fog, tonemap, shadow, antialias,
!                [shading], props, line
!   CameraStmt   pos, target, up, fov, near, far, span, at,
!                position, look, props, line
!   LightStmt    kind, direction, color, intensity, span, type,
!                mode, dir, from_, position, target, strength,
!                colour, props, line
!   GroupStmt    name, props, body (always the empty list), span,
!                children, objects, statements, line
!                -> children are read from "children" (objects /
!                   statements are aliases of the same list)
!   RepeatStmt   mode, a, b, obj, span, kind, count, rows, cols,
!                grid, object, props, line
!                -> children are read from "obj" (object is its
!                   alias; the value is one statement dict or a
!                   list of them)
!   AnimStmt     kind, target, props, span, verb, motion, action,
!                line, axis, speed, duration, fps, ease, loop
!   LoadStmt     path, name, props, span, file, line, + props spread
!   ImportStmt   import_path, name, props, span, line
!   ControlsStmt kind, props, span, mode, type, autorotate, min,
!                max, line
!   OutputStmt   kind, path, format, width, height, span, mode,
!                fmt, file, size, still, frames, fps, duration,
!                props, line
!   others       (sprite / particles / filter / shader / morph /
!                bone / skin / instance / text / keys / keyframe):
!                name and/or target + props + span + line, plus
!                form-specific keys retained in the fields bag.
!
! The class tag in ast_stmt%kind is derived with the same key
! signatures f3dc_desugar's is_node uses (documented at
! classify_stmt below); a node matching no signature is "generic"
! and still round-trips exactly through its fields bag.
!
! Fortran traps honoured throughout: .and. / .or. do NOT
! short-circuit, so every indexing or dereference guard is a nested
! if, never a compound condition; no procedure here is pure with an
! intent(out) dummy; dyn-to-dyn copies always go through dyn_assign
! / dyn_copy, never bare intrinsic assignment (which would alias
! allocatable components); string building uses plain assignment
! of whole values, never self-concatenation.
! No type-bound procedures are used anywhere (flang build rule).
module f3dc_ast
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, &
                      dyn_assign, dyn_dict_get, dyn_dict_set, &
                      dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
                      dyn_dict_remove, dyn_list_push, dyn_list_len, &
                      dyn_list_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, &
                      DYN_K_REAL, DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real
  implicit none
  private

  public :: ast_stmt, ast_program
  public :: append_ast_stmt, append_ast_child
  public :: ast_stmt_from_dyn, ast_stmt_to_dyn
  public :: ast_program_from_dyn, ast_program_to_dyn
  public :: ast_stmt_copy, ast_program_init
  public :: ast_stmt_has_prop, ast_stmt_get_prop, ast_stmt_set_prop
  public :: ast_stmt_get_str, ast_stmt_get_num, ast_stmt_get_bool
  public :: ast_stmt_set_str, ast_stmt_set_num, ast_stmt_set_bool

  !> One typed statement.  The recursive children component mirrors
  !! how f3dc_dyn's dyn does it: an allocatable array of the type
  !! itself (F2003 recursive allocatable component).
  type :: ast_stmt
    character(len=32) :: kind = ""        !< class tag (classify_stmt)
    character(len=:), allocatable :: name    !< "name" (str or absent)
    character(len=:), allocatable :: target  !< "target" (str or absent)
    logical :: has_name = .false.    !< "name" key present on the node
    logical :: has_target = .false.  !< "target" key present
    logical :: has_line = .false.    !< "line" key present
    integer :: line = 0              !< "line" (1-based source line)
    logical :: has_props = .false.   !< "props" key present
    type(dyn) :: props               !< PROPS BAG: the "props" dict
    type(dyn) :: fields              !< FIELDS BAG: every other
                                     !! top-level key, verbatim
    character(len=32) :: child_key = ""  !< "children" / "obj" /
                                         !! "body" / "" (no children)
    logical :: child_was_list = .true.   !< child key held a list
    integer :: n_children = 0
    integer :: cap_children = 0
    type(ast_stmt), allocatable :: children(:)
  end type ast_stmt

  !> A typed program: the parser Program node's "statements" list
  !! as a growable array, plus its retained program-level fields.
  type :: ast_program
    integer :: n = 0
    integer :: cap = 0
    type(ast_stmt), allocatable :: stmts(:)
    character(len=:), allocatable :: source       !< "source"
    character(len=:), allocatable :: source_name  !< "source_name"
    logical :: has_source = .false.
    logical :: has_source_name = .false.
    logical :: has_stmts_alias = .false.  !< "stmts" alias present
    type(dyn) :: fields  !< FIELDS BAG: "span", "errors" and any
                         !! other program-level key, verbatim
  end type ast_program

contains

  ! ==================================================================
  ! Small helpers
  ! ==================================================================

  !> The string inside a dyn_str ("" when it is not a string).
  function str_of(v) result(out)
    type(dyn), intent(in) :: v
    character(len=:), allocatable :: out
    if (v%kind == DYN_K_STR) then
      if (allocated(v%s)) then
        out = v%s
        return
      end if
    end if
    out = ""
  end function str_of

  !> ASCII lower-case copy (for the bool-word parsing below).
  function ast_lower(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i, c
    allocate (character(len=len(s)) :: out)
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (c >= iachar("A") .and. c <= iachar("Z")) then
        out(i:i) = achar(c + 32)
      else
        out(i:i) = s(i:i)
      end if
    end do
  end function ast_lower

  !> A dyn rendered as text for ast_stmt_get_str: strings verbatim,
  !! ints / reals via f3dc_str's formatters, bools as true/false;
  !! anything else reports ok = .false. (caller uses its default).
  subroutine dyn_to_text(v, out, ok)
    type(dyn), intent(in) :: v
    character(len=:), allocatable, intent(out) :: out
    logical, intent(out) :: ok
    ok = .true.
    select case (v%kind)
    case (DYN_K_STR)
      out = str_of(v)
    case (DYN_K_INT)
      out = trim(fmt_int(v%i))
    case (DYN_K_REAL)
      out = trim(fmt_real(v%r))
    case (DYN_K_BOOL)
      if (v%b) then
        out = "true"
      else
        out = "false"
      end if
    case default
      ok = .false.
      out = ""
    end select
  end subroutine dyn_to_text

  ! ==================================================================
  ! Class tag (mirrors f3dc_desugar's is_node key signatures)
  !
  !   ObjectStmt   has "prim"
  !   GroupStmt    has "children"
  !   RepeatStmt   has "obj" + "mode"
  !   AnimStmt     has "verb"
  !   ImportStmt   has "import_path"
  !   ControlsStmt has "autorotate"
  !   OutputStmt   has "still", or kind+path+format+width+height+mode
  !   SceneStmt    has "bg" + "width", no "prim", no "kind"
  !   CameraStmt   has "fov" + "pos" + "target"
  !   LightStmt    has "direction" + "intensity" + "kind"
  !   LoadStmt     has "path" + "file", no "kind"
  !   KeyframeStmt has "time" + "target" + "pos" (parse_key shape)
  !   anything else -> "generic" (fields bag keeps its exact shape)
  ! ==================================================================
  function classify_stmt(node) result(tag)
    type(dyn), intent(in) :: node
    character(len=32) :: tag
    tag = "generic"
    if (node%kind /= DYN_K_DICT) return
    if (dyn_dict_has(node, "import_path")) then
      tag = "import"
      return
    end if
    if (dyn_dict_has(node, "prim")) then
      tag = "object"
      return
    end if
    if (dyn_dict_has(node, "children")) then
      tag = "group"
      return
    end if
    if (dyn_dict_has(node, "obj")) then
      if (dyn_dict_has(node, "mode")) then
        tag = "repeat"
        return
      end if
    end if
    if (dyn_dict_has(node, "verb")) then
      tag = "anim"
      return
    end if
    if (dyn_dict_has(node, "autorotate")) then
      tag = "controls"
      return
    end if
    if (dyn_dict_has(node, "still")) then
      tag = "output"
      return
    end if
    if (dyn_dict_has(node, "bg")) then
      if (dyn_dict_has(node, "width")) then
        if (.not. dyn_dict_has(node, "kind")) then
          tag = "scene"
          return
        end if
      end if
    end if
    if (dyn_dict_has(node, "fov")) then
      if (dyn_dict_has(node, "pos")) then
        if (dyn_dict_has(node, "target")) then
          tag = "camera"
          return
        end if
      end if
    end if
    if (dyn_dict_has(node, "direction")) then
      if (dyn_dict_has(node, "intensity")) then
        if (dyn_dict_has(node, "kind")) then
          tag = "light"
          return
        end if
      end if
    end if
    if (dyn_dict_has(node, "path")) then
      if (dyn_dict_has(node, "file")) then
        if (.not. dyn_dict_has(node, "kind")) then
          tag = "load"
          return
        end if
      end if
    end if
    if (dyn_dict_has(node, "kind")) then
      if (dyn_dict_has(node, "path")) then
        if (dyn_dict_has(node, "format")) then
          if (dyn_dict_has(node, "width")) then
            if (dyn_dict_has(node, "height")) then
              if (dyn_dict_has(node, "mode")) then
                tag = "output"
                return
              end if
            end if
          end if
        end if
      end if
    end if
    if (dyn_dict_has(node, "time")) then
      if (dyn_dict_has(node, "target")) then
        if (dyn_dict_has(node, "pos")) then
          tag = "keyframe"
          return
        end if
      end if
    end if
  end function classify_stmt

  ! ==================================================================
  ! Deep copy (dyn components via dyn_copy; children recursively)
  ! ==================================================================

  recursive function ast_stmt_copy(src) result(out)
    type(ast_stmt), intent(in) :: src
    type(ast_stmt) :: out
    integer :: k
    out%kind = src%kind
    if (allocated(src%name)) out%name = src%name
    if (allocated(src%target)) out%target = src%target
    out%has_name = src%has_name
    out%has_target = src%has_target
    out%has_line = src%has_line
    out%line = src%line
    out%has_props = src%has_props
    call dyn_assign(out%props, dyn_copy(src%props))
    call dyn_assign(out%fields, dyn_copy(src%fields))
    out%child_key = src%child_key
    out%child_was_list = src%child_was_list
    out%n_children = src%n_children
    out%cap_children = src%n_children
    if (src%n_children > 0) then
      allocate (out%children(src%n_children))
      do k = 1, src%n_children
        out%children(k) = ast_stmt_copy(src%children(k))
      end do
    else
      allocate (out%children(0))
    end if
  end function ast_stmt_copy

  ! ==================================================================
  ! Growable arrays (capacity doubling)
  ! ==================================================================

  subroutine ast_program_init(prog)
    type(ast_program), intent(out) :: prog
    prog%n = 0
    prog%cap = 0
    allocate (prog%stmts(0))
    prog%has_source = .false.
    prog%has_source_name = .false.
    prog%has_stmts_alias = .false.
    call dyn_assign(prog%fields, dyn_dict())
  end subroutine ast_program_init

  !> Append one statement to an ast_program, doubling the backing
  !! array when full (4, 8, 16, ...), deep-copying the statement.
  subroutine append_ast_stmt(prog, stmt)
    type(ast_program), intent(inout) :: prog
    type(ast_stmt), intent(in) :: stmt
    type(ast_stmt), allocatable :: tmp(:)
    integer :: k, newcap
    if (.not. allocated(prog%stmts)) then
      allocate (prog%stmts(0))
      prog%n = 0
      prog%cap = 0
    end if
    if (prog%n >= prog%cap) then
      newcap = max(4, 2 * prog%cap)
      allocate (tmp(newcap))
      do k = 1, prog%n
        tmp(k) = ast_stmt_copy(prog%stmts(k))
      end do
      call move_alloc(tmp, prog%stmts)
      prog%cap = newcap
    end if
    prog%n = prog%n + 1
    prog%stmts(prog%n) = ast_stmt_copy(stmt)
  end subroutine append_ast_stmt

  !> Append one child statement to an ast_stmt, doubling the
  !! children array when full, deep-copying the child.  The first
  !! append to a childless statement adopts "children" as its
  !! child key (the GroupStmt spelling).
  subroutine append_ast_child(stmt, child)
    type(ast_stmt), intent(inout) :: stmt
    type(ast_stmt), intent(in) :: child
    type(ast_stmt), allocatable :: tmp(:)
    integer :: k, newcap
    if (.not. allocated(stmt%children)) then
      allocate (stmt%children(0))
      stmt%n_children = 0
      stmt%cap_children = 0
    end if
    if (stmt%n_children >= stmt%cap_children) then
      newcap = max(4, 2 * stmt%cap_children)
      allocate (tmp(newcap))
      do k = 1, stmt%n_children
        tmp(k) = ast_stmt_copy(stmt%children(k))
      end do
      call move_alloc(tmp, stmt%children)
      stmt%cap_children = newcap
    end if
    stmt%n_children = stmt%n_children + 1
    stmt%children(stmt%n_children) = ast_stmt_copy(child)
    if (stmt%child_key == "") then
      stmt%child_key = "children"
      stmt%child_was_list = .true.
    end if
  end subroutine append_ast_child

  ! ==================================================================
  ! Props bag: typed accessors
  ! ==================================================================

  !> Raw props-bag lookup: found is .true. when the bag is a dict
  !! holding key (the value may still be dyn_null, exactly as a
  !! parser-built props dict stores explicit nulls).
  subroutine ast_stmt_get_prop(stmt, key, val, found)
    type(ast_stmt), intent(in) :: stmt
    character(len=*), intent(in) :: key
    type(dyn), intent(out) :: val
    logical, intent(out) :: found
    found = .false.
    val = dyn_null()
    if (stmt%props%kind /= DYN_K_DICT) return
    if (.not. dyn_dict_has(stmt%props, key)) return
    call dyn_assign(val, dyn_dict_get(stmt%props, key))
    found = .true.
  end subroutine ast_stmt_get_prop

  logical function ast_stmt_has_prop(stmt, key)
    type(ast_stmt), intent(in) :: stmt
    character(len=*), intent(in) :: key
    ast_stmt_has_prop = .false.
    if (stmt%props%kind /= DYN_K_DICT) return
    ast_stmt_has_prop = dyn_dict_has(stmt%props, key)
  end function ast_stmt_has_prop

  !> Write into the props bag (creating it as a dict when the
  !! statement did not carry one, and marking it present).
  subroutine ast_stmt_set_prop(stmt, key, val)
    type(ast_stmt), intent(inout) :: stmt
    character(len=*), intent(in) :: key
    type(dyn), intent(in) :: val
    if (stmt%props%kind /= DYN_K_DICT) &
      call dyn_assign(stmt%props, dyn_dict())
    call dyn_dict_set(stmt%props, key, val)
    stmt%has_props = .true.
  end subroutine ast_stmt_set_prop

  !> String prop: a dyn_str verbatim; an int / real / bool rendered
  !! as text; a missing key, a stored null or any other kind yields
  !! the caller's default.
  function ast_stmt_get_str(stmt, key, default) result(out)
    type(ast_stmt), intent(in) :: stmt
    character(len=*), intent(in) :: key, default
    character(len=:), allocatable :: out
    type(dyn) :: v
    logical :: found, ok
    call ast_stmt_get_prop(stmt, key, v, found)
    if (.not. found) then
      out = default
      return
    end if
    call dyn_to_text(v, out, ok)
    if (.not. ok) out = default
  end function ast_stmt_get_str

  !> Numeric prop as real64: ints widen, reals pass through, bools
  !! count 1/0, numeric strings parse; anything else (including a
  !! missing key or a stored null) yields the caller's default.
  function ast_stmt_get_num(stmt, key, default) result(out)
    type(ast_stmt), intent(in) :: stmt
    character(len=*), intent(in) :: key
    real(real64), intent(in) :: default
    real(real64) :: out
    type(dyn) :: v
    logical :: found
    integer :: ios
    real(real64) :: parsed
    call ast_stmt_get_prop(stmt, key, v, found)
    if (.not. found) then
      out = default
      return
    end if
    select case (v%kind)
    case (DYN_K_INT)
      out = real(v%i, real64)
    case (DYN_K_REAL)
      out = v%r
    case (DYN_K_BOOL)
      out = merge(1.0_real64, 0.0_real64, v%b)
    case (DYN_K_STR)
      out = default
      if (allocated(v%s)) then
        read (v%s, *, iostat=ios) parsed
        if (ios == 0) out = parsed
      end if
    case default
      out = default
    end select
  end function ast_stmt_get_num

  !> Boolean prop: bools verbatim, numbers by /= 0, the strings
  !! true/yes/on/1 and false/no/off/0 (any case) by word; anything
  !! else (including a missing key or a stored null) yields the
  !! caller's default.
  function ast_stmt_get_bool(stmt, key, default) result(out)
    type(ast_stmt), intent(in) :: stmt
    character(len=*), intent(in) :: key
    logical, intent(in) :: default
    logical :: out
    type(dyn) :: v
    logical :: found
    character(len=:), allocatable :: word
    call ast_stmt_get_prop(stmt, key, v, found)
    if (.not. found) then
      out = default
      return
    end if
    select case (v%kind)
    case (DYN_K_BOOL)
      out = v%b
    case (DYN_K_INT)
      out = v%i /= 0_int64
    case (DYN_K_REAL)
      out = v%r /= 0.0_real64
    case (DYN_K_STR)
      out = default
      word = ast_lower(str_of(v))
      if (word == "true" .or. word == "yes" .or. word == "on" &
          .or. word == "1") then
        out = .true.
      else if (word == "false" .or. word == "no" .or. &
               word == "off" .or. word == "0") then
        out = .false.
      end if
    case default
      out = default
    end select
  end function ast_stmt_get_bool

  subroutine ast_stmt_set_str(stmt, key, val)
    type(ast_stmt), intent(inout) :: stmt
    character(len=*), intent(in) :: key, val
    call ast_stmt_set_prop(stmt, key, dyn_str(val))
  end subroutine ast_stmt_set_str

  subroutine ast_stmt_set_num(stmt, key, val)
    type(ast_stmt), intent(inout) :: stmt
    character(len=*), intent(in) :: key
    real(real64), intent(in) :: val
    call ast_stmt_set_prop(stmt, key, dyn_real(val))
  end subroutine ast_stmt_set_num

  subroutine ast_stmt_set_bool(stmt, key, val)
    type(ast_stmt), intent(inout) :: stmt
    character(len=*), intent(in) :: key
    logical, intent(in) :: val
    call ast_stmt_set_prop(stmt, key, dyn_bool(val))
  end subroutine ast_stmt_set_bool

  ! ==================================================================
  ! Statement conversion: dyn node <-> ast_stmt
  ! ==================================================================

  !> Raise one parser dyn statement dict into an ast_stmt.
  !!
  !! Extracted into typed components: the class tag (classify_stmt),
  !! "name", "target", "line", the "props" bag, and the children
  !! (from "children" for a group, from "obj" for a repeat, from a
  !! non-empty dict "body" list otherwise).  Every remaining key --
  !! including "span" and the alias keys not used as the child
  !! source -- is retained verbatim in the fields bag.
  recursive function ast_stmt_from_dyn(node) result(stmt)
    type(dyn), intent(in) :: node
    type(ast_stmt) :: stmt
    type(dyn) :: v, child_list, elem
    integer :: k, nchild
    logical :: take_body

    stmt%kind = "generic"
    call dyn_assign(stmt%props, dyn_dict())
    call dyn_assign(stmt%fields, dyn_dict())
    allocate (stmt%children(0))
    if (node%kind /= DYN_K_DICT) return

    stmt%kind = classify_stmt(node)

    ! --- name / target / line -------------------------------------
    if (dyn_dict_has(node, "name")) then
      stmt%has_name = .true.
      v = dyn_dict_get(node, "name")
      if (v%kind == DYN_K_STR) then
        if (allocated(v%s)) stmt%name = v%s
      end if
    end if
    if (dyn_dict_has(node, "target")) then
      stmt%has_target = .true.
      v = dyn_dict_get(node, "target")
      if (v%kind == DYN_K_STR) then
        if (allocated(v%s)) stmt%target = v%s
      end if
    end if
    if (dyn_dict_has(node, "line")) then
      v = dyn_dict_get(node, "line")
      if (v%kind == DYN_K_INT) then
        stmt%has_line = .true.
        stmt%line = int(v%i)
      else if (v%kind == DYN_K_REAL) then
        stmt%has_line = .true.
        stmt%line = int(v%r)
      end if
    end if

    ! --- props bag --------------------------------------------------
    if (dyn_dict_has(node, "props")) then
      v = dyn_dict_get(node, "props")
      if (v%kind == DYN_K_DICT) then
        stmt%has_props = .true.
        call dyn_assign(stmt%props, dyn_copy(v))
      end if
    end if

    ! --- children ---------------------------------------------------
    ! GroupStmt: "children" (its "objects" / "statements" aliases
    ! are dropped here and rebuilt by ast_stmt_to_dyn).
    ! RepeatStmt: "obj" (its "object" alias likewise), holding one
    ! statement dict or a list of them.
    ! Otherwise: a "body" list of statement dicts when non-empty
    ! (a GroupStmt's "body" is always empty, so it stays a field).
    if (dyn_dict_has(node, "children")) then
      v = dyn_dict_get(node, "children")
      if (v%kind == DYN_K_LIST) then
        stmt%child_key = "children"
        stmt%child_was_list = .true.
        call dyn_assign(child_list, dyn_copy(v))
      end if
    end if
    if (stmt%child_key == "") then
      if (dyn_dict_has(node, "obj")) then
        v = dyn_dict_get(node, "obj")
        if (v%kind == DYN_K_LIST) then
          stmt%child_key = "obj"
          stmt%child_was_list = .true.
          call dyn_assign(child_list, dyn_copy(v))
        else if (v%kind == DYN_K_DICT) then
          stmt%child_key = "obj"
          stmt%child_was_list = .false.
          child_list = dyn_list()
          call dyn_list_push(child_list, v)
        end if
      end if
    end if
    if (stmt%child_key == "") then
      take_body = .false.
      if (dyn_dict_has(node, "body")) then
        v = dyn_dict_get(node, "body")
        if (v%kind == DYN_K_LIST) then
          if (dyn_list_len(v) > 0) then
            elem = dyn_list_at(v, 1)
            if (elem%kind == DYN_K_DICT) take_body = .true.
          end if
        end if
      end if
      if (take_body) then
        stmt%child_key = "body"
        stmt%child_was_list = .true.
        call dyn_assign(child_list, dyn_copy(v))
      end if
    end if
    if (stmt%child_key /= "") then
      nchild = dyn_list_len(child_list)
      deallocate (stmt%children)
      allocate (stmt%children(max(1, nchild)))
      stmt%n_children = nchild
      stmt%cap_children = max(1, nchild)
      do k = 1, nchild
        elem = dyn_list_at(child_list, k)
        stmt%children(k) = ast_stmt_from_dyn(elem)
      end do
    end if

    ! --- fields bag: everything not extracted -----------------------
    call dyn_assign(stmt%fields, dyn_copy(node))
    if (stmt%has_name) call dyn_dict_remove(stmt%fields, "name")
    if (stmt%has_target) &
      call dyn_dict_remove(stmt%fields, "target")
    if (stmt%has_line) call dyn_dict_remove(stmt%fields, "line")
    if (stmt%has_props) call dyn_dict_remove(stmt%fields, "props")
    select case (trim(stmt%child_key))
    case ("children")
      call dyn_dict_remove(stmt%fields, "children")
      call dyn_dict_remove(stmt%fields, "objects")
      call dyn_dict_remove(stmt%fields, "statements")
    case ("obj")
      call dyn_dict_remove(stmt%fields, "obj")
      call dyn_dict_remove(stmt%fields, "object")
    case ("body")
      call dyn_dict_remove(stmt%fields, "body")
    end select
  end function ast_stmt_from_dyn

  !> Lower one ast_stmt back into a parser-shaped dyn statement
  !! dict: the fields bag first (its keys keep their relative
  !! order), then the extracted name / target / line / props /
  !! children written back under their real key names, with the
  !! parser's alias keys rebuilt (a group's children also under
  !! "objects" and "statements"; a repeat's template(s) also
  !! under "object").  Structural inverse of ast_stmt_from_dyn.
  recursive function ast_stmt_to_dyn(stmt) result(node)
    type(ast_stmt), intent(in) :: stmt
    type(dyn) :: node
    type(dyn) :: child_list, elem
    integer :: k

    if (stmt%fields%kind == DYN_K_DICT) then
      call dyn_assign(node, dyn_copy(stmt%fields))
    else
      call dyn_assign(node, dyn_dict())
    end if
    if (stmt%has_name) then
      if (allocated(stmt%name)) then
        call dyn_dict_set(node, "name", dyn_str(stmt%name))
      else
        call dyn_dict_set(node, "name", dyn_null())
      end if
    end if
    if (stmt%has_target) then
      if (allocated(stmt%target)) then
        call dyn_dict_set(node, "target", dyn_str(stmt%target))
      else
        call dyn_dict_set(node, "target", dyn_null())
      end if
    end if
    if (stmt%has_line) &
      call dyn_dict_set(node, "line", dyn_int(int(stmt%line, int64)))
    if (stmt%has_props) &
      call dyn_dict_set(node, "props", dyn_copy(stmt%props))
    if (stmt%child_key /= "") then
      child_list = dyn_list()
      do k = 1, stmt%n_children
        elem = ast_stmt_to_dyn(stmt%children(k))
        call dyn_list_push(child_list, elem)
      end do
      select case (trim(stmt%child_key))
      case ("children")
        call dyn_dict_set(node, "children", dyn_copy(child_list))
        call dyn_dict_set(node, "objects", dyn_copy(child_list))
        call dyn_dict_set(node, "statements", dyn_copy(child_list))
      case ("obj")
        if (stmt%child_was_list) then
          call dyn_dict_set(node, "obj", dyn_copy(child_list))
          call dyn_dict_set(node, "object", dyn_copy(child_list))
        else
          if (stmt%n_children > 0) then
            elem = dyn_list_at(child_list, 1)
          else
            elem = dyn_null()
          end if
          call dyn_dict_set(node, "obj", dyn_copy(elem))
          call dyn_dict_set(node, "object", dyn_copy(elem))
        end if
      case ("body")
        call dyn_dict_set(node, "body", dyn_copy(child_list))
      end select
    end if
  end function ast_stmt_to_dyn

  ! ==================================================================
  ! Program conversion: dyn Program node <-> ast_program
  ! ==================================================================

  !> Raise a parser (or desugar) dyn Program node into an
  !! ast_program: "statements" (falling back to its "stmts" alias)
  !! becomes the typed statement array; "source" / "source_name"
  !! are extracted; every other program-level key ("span",
  !! "errors", and anything a later stage adds) is retained
  !! verbatim in the program fields bag.  A non-dict input yields
  !! an empty program.
  function ast_program_from_dyn(dyn_program) result(prog)
    type(dyn), intent(in) :: dyn_program
    type(ast_program) :: prog
    type(dyn) :: v, elem
    type(ast_stmt) :: stmt
    integer :: k, nstmt

    call ast_program_init(prog)
    if (dyn_program%kind /= DYN_K_DICT) return

    ! Program fields bag first (extraction removes keys below).
    call dyn_assign(prog%fields, dyn_copy(dyn_program))
    call dyn_dict_remove(prog%fields, "statements")
    call dyn_dict_remove(prog%fields, "stmts")

    if (dyn_dict_has(dyn_program, "source")) then
      prog%has_source = .true.
      v = dyn_dict_get(dyn_program, "source")
      if (v%kind == DYN_K_STR) then
        if (allocated(v%s)) prog%source = v%s
      end if
      call dyn_dict_remove(prog%fields, "source")
    end if
    if (dyn_dict_has(dyn_program, "source_name")) then
      prog%has_source_name = .true.
      v = dyn_dict_get(dyn_program, "source_name")
      if (v%kind == DYN_K_STR) then
        if (allocated(v%s)) prog%source_name = v%s
      end if
      call dyn_dict_remove(prog%fields, "source_name")
    end if
    prog%has_stmts_alias = dyn_dict_has(dyn_program, "stmts")

    v = dyn_dict_get(dyn_program, "statements")
    if (v%kind /= DYN_K_LIST) &
      v = dyn_dict_get(dyn_program, "stmts")
    if (v%kind == DYN_K_LIST) then
      nstmt = dyn_list_len(v)
      do k = 1, nstmt
        elem = dyn_list_at(v, k)
        stmt = ast_stmt_from_dyn(elem)
        call append_ast_stmt(prog, stmt)
      end do
    end if
  end function ast_program_from_dyn

  !> Lower an ast_program back into a dyn Program node: the
  !! program fields bag (span / errors / ...) first, then
  !! "statements" rebuilt from the typed array, its "stmts" alias
  !! when the source node carried one, and "source" /
  !! "source_name" when present.  Structural inverse of
  !! ast_program_from_dyn.
  function ast_program_to_dyn(prog) result(dyn_program)
    type(ast_program), intent(in) :: prog
    type(dyn) :: dyn_program
    type(dyn) :: stmts, elem
    integer :: k

    if (prog%fields%kind == DYN_K_DICT) then
      call dyn_assign(dyn_program, dyn_copy(prog%fields))
    else
      call dyn_assign(dyn_program, dyn_dict())
    end if
    stmts = dyn_list()
    do k = 1, prog%n
      elem = ast_stmt_to_dyn(prog%stmts(k))
      call dyn_list_push(stmts, elem)
    end do
    call dyn_dict_set(dyn_program, "statements", dyn_copy(stmts))
    if (prog%has_stmts_alias) &
      call dyn_dict_set(dyn_program, "stmts", dyn_copy(stmts))
    if (prog%has_source) then
      if (allocated(prog%source)) then
        call dyn_dict_set(dyn_program, "source", &
                          dyn_str(prog%source))
      else
        call dyn_dict_set(dyn_program, "source", dyn_str(""))
      end if
    end if
    if (prog%has_source_name) then
      if (allocated(prog%source_name)) then
        call dyn_dict_set(dyn_program, "source_name", &
                          dyn_str(prog%source_name))
      else
        call dyn_dict_set(dyn_program, "source_name", dyn_str(""))
      end if
    end if
  end function ast_program_to_dyn

end module f3dc_ast
