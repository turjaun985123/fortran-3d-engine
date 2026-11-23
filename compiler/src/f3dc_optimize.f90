! f3dc_optimize.f90 -- optimization passes O1-O7 for the native
! Forge3D compiler.  Port of tools/f3dc/optimize.py (read in full).
!
! Contract: no pass may change the rendered image.  Passes run in
! registry order over a deep copy of the input scene; the caller's
! scene is never modified.  optimize never fails: degenerate objects
! are dropped with W5xx warnings, never errors.
!
! Entry point (mirrors Python  optimize(scene, bag, level=1)):
!
!   subroutine optimize(scene_in, bag, level, scene_out)
!     type(dyn), intent(in)           :: scene_in
!     type(error_bag_t), intent(inout):: bag
!     integer, intent(in), optional   :: level   ! <=0: unmodified copy
!     type(dyn), intent(out)          :: scene_out
!
! IR is dyn dicts with the ir_nodes.py keys (scene: objects,
! animations, extensions, ...; object: name, prim, color, pos, rotate,
! scale, size, ..., triangles, extensions).  The Python module is
! duck-typed (transform/params dicts, prim/kind aliases, ...); every
! alias chain is mirrored here exactly, in the same lookup order.
!
! Pass registry: register_pass(name, fn) with fn a procedure matching
! pass_iface (scene, bag).  Re-registering a name replaces it in
! place, preserving order (Python register_pass).
!
! Known divergences from the Python (reported, never silent):
!  * _warn: with the real Python ErrorBag, duck-typing lands on
!    bag.add(message) with the bare message *string* (ErrorBag.add
!    type-checks nothing), so a raw str ends up in bag.diagnostics.
!    A Fortran error_bag_t cannot hold a bare string; this port adds
!    a proper warning diagnostic (code, "warning", message, no span).
!    The scene.extensions["optimize_warnings"] copy -- the one that
!    reaches the IR JSON -- is byte-identical either way.
!  * Registry passes must match the 2-argument pass_iface; Python
!    also accepts 1-argument pass functions via inspect.signature.
!  * _freeze equality: Python dict-key hashing makes int 1, float 1.0
!    and True the same dedup key; freeze_eq mirrors that numeric
!    unification, but an int64 beyond 2**53 compared against a float
!    is compared in real64 (Python compares exactly).
!  * _is_zero_area computes the cross product in real64; Python ints
!    are arbitrary precision, so gigantic integer vertices could
!    differ in the last ulp (real scenes carry floats).
!  * _tri_points: a non-numeric vertex coordinate makes Python raise
!    TypeError out of optimize; this port treats the triangle as
!    unresolvable and keeps it (optimize must not fail).
module f3dc_optimize
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn, only: dyn, dyn_null, dyn_bool, dyn_int, dyn_real, &
                      dyn_str, dyn_list, dyn_dict, dyn_copy, &
                      dyn_list_push, dyn_list_len, dyn_list_at, &
                      dyn_list_set_at, dyn_dict_set, dyn_dict_get, &
                      dyn_dict_has, dyn_dict_len, dyn_dict_key_at, &
                      DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, &
                      DYN_K_STR, DYN_K_LIST, DYN_K_DICT
  use f3dc_str, only: fmt_int, fmt_real, to_lower
  use f3dc_errors, only: error_bag_t, make_diagnostic, error_bag_add
  implicit none
  private

  public :: optimize, register_pass, pass_iface
  public :: pass_count, pass_name_at, get_default_color
  public :: W_DROPPED_OBJECT, W_DEGENERATE_TRI

  !> Warning codes (optimize.py module constants).
  character(len=*), parameter :: W_DROPPED_OBJECT = "W510"
  character(len=*), parameter :: W_DEGENERATE_TRI = "W511"

  !> Signature of a pass: mutates scene in place (the Python passes
  !! return the scene they mutated; in-place is equivalent here
  !! because optimize works on its own deep copy).
  abstract interface
    subroutine pass_iface(scene, bag)
      import :: dyn, error_bag_t
      type(dyn), intent(inout) :: scene
      type(error_bag_t), intent(inout) :: bag
    end subroutine pass_iface
  end interface

  type :: pass_entry
    character(len=:), allocatable :: name
    procedure(pass_iface), pointer, nopass :: fn => null()
  end type pass_entry

  type(pass_entry), allocatable :: pass_registry(:)
  integer :: n_passes = 0
  logical :: registry_ready = .false.

contains

  ! ------------------------------------------------------------------
  ! Small field-access helpers (mirror _get/_set/_extensions)
  ! ------------------------------------------------------------------

  !> Python _get(obj, *names, default=None): value of the first name
  !! PRESENT in the dict (a present null counts as present), else
  !! found=.false.  Non-dict obj -> never found.
  subroutine mget(obj, val, found, n1, n2, n3, n4, n5, n6)
    type(dyn), intent(in) :: obj
    type(dyn), intent(out) :: val
    logical, intent(out) :: found
    character(len=*), intent(in) :: n1
    character(len=*), intent(in), optional :: n2, n3, n4, n5, n6
    val = dyn_null()
    found = .false.
    if (obj%kind /= DYN_K_DICT) return
    if (dyn_dict_has(obj, n1)) then
      val = dyn_dict_get(obj, n1); found = .true.; return
    end if
    if (present(n2)) then
      if (dyn_dict_has(obj, n2)) then
        val = dyn_dict_get(obj, n2); found = .true.; return
      end if
    end if
    if (present(n3)) then
      if (dyn_dict_has(obj, n3)) then
        val = dyn_dict_get(obj, n3); found = .true.; return
      end if
    end if
    if (present(n4)) then
      if (dyn_dict_has(obj, n4)) then
        val = dyn_dict_get(obj, n4); found = .true.; return
      end if
    end if
    if (present(n5)) then
      if (dyn_dict_has(obj, n5)) then
        val = dyn_dict_get(obj, n5); found = .true.; return
      end if
    end if
    if (present(n6)) then
      if (dyn_dict_has(obj, n6)) then
        val = dyn_dict_get(obj, n6); found = .true.; return
      end if
    end if
  end subroutine mget

  !> Python truthiness of a dyn value.
  pure logical function py_truthy(d)
    type(dyn), intent(in) :: d
    select case (d%kind)
    case (DYN_K_NULL)
      py_truthy = .false.
    case (DYN_K_BOOL)
      py_truthy = d%b
    case (DYN_K_INT)
      py_truthy = d%i /= 0_int64
    case (DYN_K_REAL)
      py_truthy = d%r /= 0.0_real64
    case (DYN_K_STR)
      py_truthy = allocated(d%s)
      if (py_truthy) py_truthy = len(d%s) > 0
    case (DYN_K_LIST)
      py_truthy = d%n_items > 0
    case (DYN_K_DICT)
      py_truthy = d%n_entries > 0
    case default
      py_truthy = .false.
    end select
  end function py_truthy

  !> Numeric value with Python isinstance(v, (int, float)) semantics
  !! (bool IS an int in Python): ok=.false. for non-numbers.
  subroutine num_value(d, x, ok)
    type(dyn), intent(in) :: d
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    ok = .true.
    select case (d%kind)
    case (DYN_K_BOOL)
      x = merge(1.0_real64, 0.0_real64, d%b)
    case (DYN_K_INT)
      x = real(d%i, real64)
    case (DYN_K_REAL)
      x = d%r
    case default
      x = 0.0_real64
      ok = .false.
    end select
  end subroutine num_value

  !> Python _vec3: null -> none; a number -> 1-element list; a list ->
  !! itself; anything else -> none.  (Emptiness is the caller's
  !! concern: Python's `or` chain treats () as missing.)
  subroutine vec3_of(d, out, has)
    type(dyn), intent(in) :: d
    type(dyn), intent(out) :: out
    logical, intent(out) :: has
    real(real64) :: x
    logical :: ok
    has = .false.
    out = dyn_null()
    call num_value(d, x, ok)
    if (ok) then
      ! (value,) -- the element keeps its Python type (bool stays bool).
      out = dyn_list()
      call dyn_list_push(out, dyn_copy(d))
      has = .true.
      return
    end if
    if (d%kind == DYN_K_LIST) then
      out = dyn_copy(d)
      has = .true.
    end if
  end subroutine vec3_of

  ! ------------------------------------------------------------------
  ! Python repr() for dyn values (warning messages must byte-match)
  ! ------------------------------------------------------------------

  !> CPython repr of a string: single quotes unless the string holds
  !! a single quote and no double quote; backslash/quote/control
  !! escapes.  Bytes >= 128 pass through (CPython would escape only
  !! non-printable code points; scene names are ASCII in practice).
  function py_repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    character :: q
    integer :: i, b
    character(len=4) :: hexbuf
    if (index(s, "'") > 0 .and. index(s, '"') == 0) then
      q = '"'
    else
      q = "'"
    end if
    out = q
    do i = 1, len(s)
      b = iachar(s(i:i))
      if (s(i:i) == "\") then
        out = out // "\\"
      else if (s(i:i) == q) then
        out = out // "\" // q
      else if (b == 10) then
        out = out // "\n"
      else if (b == 13) then
        out = out // "\r"
      else if (b == 9) then
        out = out // "\t"
      else if (b < 32 .or. b == 127) then
        write (hexbuf, "(A,Z2.2)") "\x", b
        out = out // trim(hexbuf)
      else
        out = out // s(i:i)
      end if
    end do
    out = out // q
  end function py_repr_str

  !> Python repr(value) for a dyn value.
  recursive function py_repr(d) result(out)
    type(dyn), intent(in) :: d
    character(len=:), allocatable :: out
    integer :: k
    character(len=:), allocatable :: key
    select case (d%kind)
    case (DYN_K_NULL)
      out = "None"
    case (DYN_K_BOOL)
      if (d%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_INT)
      out = trim(fmt_int(d%i))
    case (DYN_K_REAL)
      out = trim(fmt_real(d%r))
    case (DYN_K_STR)
      if (allocated(d%s)) then
        out = py_repr_str(d%s)
      else
        out = py_repr_str("")
      end if
    case (DYN_K_LIST)
      out = "["
      do k = 1, d%n_items
        if (k > 1) out = out // ", "
        out = out // py_repr(d%items(k))
      end do
      out = out // "]"
    case (DYN_K_DICT)
      out = "{"
      do k = 1, d%n_entries
        if (k > 1) out = out // ", "
        key = dyn_dict_key_at(d, k)
        out = out // py_repr_str(key) // ": " // py_repr(d%dvals(k))
      end do
      out = out // "}"
    case default
      out = "None"
    end select
  end function py_repr

  !> Python repr of a tuple (the _vec3 result in O1's message):
  !! "(a, b, c)", with the trailing comma for a 1-tuple.
  function py_repr_tuple(d) result(out)
    type(dyn), intent(in) :: d
    character(len=:), allocatable :: out
    integer :: k
    out = "("
    if (d%kind == DYN_K_LIST) then
      do k = 1, d%n_items
        if (k > 1) out = out // ", "
        out = out // py_repr(d%items(k))
      end do
      if (d%n_items == 1) out = out // ","
    end if
    out = out // ")"
  end function py_repr_tuple

  ! ------------------------------------------------------------------
  ! Warnings: _warn (bag) + _record_warning (scene.extensions)
  ! ------------------------------------------------------------------

  !> Python _warn with the real ErrorBag lands on add(message) with a
  !! bare string (see module header); this port adds a proper warning
  !! diagnostic instead.  Never raises.
  subroutine opt_warn(bag, code, message)
    type(error_bag_t), intent(inout) :: bag
    character(len=*), intent(in) :: code, message
    call error_bag_add(bag, make_diagnostic(code, "warning", message))
  end subroutine opt_warn

  !> Fetch owner's extensions dict as a modifiable copy.
  !! ok=.false. mirrors Python _extensions() returning None (an
  !! extensions value that is present, non-null and not a dict).
  !! created=.true. when the dict was absent/null and store_ext will
  !! create it, exactly like Python.
  subroutine get_ext(owner, ext, ok)
    type(dyn), intent(in) :: owner
    type(dyn), intent(out) :: ext
    logical, intent(out) :: ok
    type(dyn) :: v
    logical :: found
    ok = .false.
    ext = dyn_null()
    call mget(owner, v, found, "extensions")
    if (found .and. v%kind == DYN_K_DICT) then
      ext = dyn_copy(v)
      ok = .true.
    else if (.not. found .or. v%kind == DYN_K_NULL) then
      ext = dyn_dict()
      ok = .true.
    end if
  end subroutine get_ext

  subroutine store_ext(owner, ext)
    type(dyn), intent(inout) :: owner
    type(dyn), intent(in) :: ext
    call dyn_dict_set(owner, "extensions", ext)
  end subroutine store_ext

  subroutine record_warning(scene, code, message)
    type(dyn), intent(inout) :: scene
    character(len=*), intent(in) :: code, message
    type(dyn) :: ext, warns
    logical :: ok, found
    call get_ext(scene, ext, ok)
    if (.not. ok) return
    call mget(ext, warns, found, "optimize_warnings")
    if (.not. found .or. warns%kind /= DYN_K_LIST) warns = dyn_list()
    call dyn_list_push(warns, dyn_str(code // ": " // message))
    call dyn_dict_set(ext, "optimize_warnings", warns)
    call store_ext(scene, ext)
  end subroutine record_warning

  ! ------------------------------------------------------------------
  ! Scene objects access (Python _objects/_set_objects)
  ! ------------------------------------------------------------------

  !> The scene's objects as a list copy (empty list when the key is
  !! absent or null; a non-list value is treated as empty -- Python
  !! would raise TypeError from list(value), see header).
  function scene_objects(scene) result(objs)
    type(dyn), intent(in) :: scene
    type(dyn) :: objs
    type(dyn) :: v
    logical :: found
    call mget(scene, v, found, "objects")
    if (found .and. v%kind == DYN_K_LIST) then
      objs = dyn_copy(v)
    else
      objs = dyn_list()
    end if
  end function scene_objects

  ! ------------------------------------------------------------------
  ! _freeze equality (O2 dedup keys)
  ! ------------------------------------------------------------------

  !> Equality of two values under Python _freeze canonicalisation:
  !! dicts unordered, sequences ordered, atoms with numeric
  !! unification (1 == 1.0 == True as dict keys), strings exact.
  recursive function freeze_eq(a, b) result(eq)
    type(dyn), intent(in) :: a, b
    logical :: eq
    integer :: k, hit
    character(len=:), allocatable :: key
    logical :: a_num, b_num
    real(real64) :: xa, xb
    eq = .false.
    if (a%kind == DYN_K_DICT .or. b%kind == DYN_K_DICT) then
      if (a%kind /= DYN_K_DICT .or. b%kind /= DYN_K_DICT) return
      if (a%n_entries /= b%n_entries) return
      eq = .true.
      do k = 1, a%n_entries
        key = dyn_dict_key_at(a, k)
        if (.not. dyn_dict_has(b, key)) then
          eq = .false.
          return
        end if
        hit = 0
        block
          integer :: j
          do j = 1, b%n_entries
            if (dyn_dict_key_at(b, j) == key) then
              hit = j
              exit
            end if
          end do
        end block
        if (.not. freeze_eq(a%dvals(k), b%dvals(hit))) then
          eq = .false.
          return
        end if
      end do
      return
    end if
    if (a%kind == DYN_K_LIST .or. b%kind == DYN_K_LIST) then
      if (a%kind /= DYN_K_LIST .or. b%kind /= DYN_K_LIST) return
      if (a%n_items /= b%n_items) return
      eq = .true.
      do k = 1, a%n_items
        if (.not. freeze_eq(a%items(k), b%items(k))) then
          eq = .false.
          return
        end if
      end do
      return
    end if
    ! Atoms.
    call num_value(a, xa, a_num)
    call num_value(b, xb, b_num)
    if (a_num .or. b_num) then
      if (.not. (a_num .and. b_num)) return
      if (is_int_like(a) .and. is_int_like(b)) then
        eq = int_like_value(a) == int_like_value(b)
      else
        eq = xa == xb  ! NaN /= NaN, as in Python
      end if
      return
    end if
    if (a%kind /= b%kind) return
    select case (a%kind)
    case (DYN_K_NULL)
      eq = .true.
    case (DYN_K_STR)
      if (allocated(a%s) .and. allocated(b%s)) then
        eq = len(a%s) == len(b%s) .and. a%s == b%s
      else
        eq = .not. allocated(a%s) .and. .not. allocated(b%s)
      end if
    case default
      eq = .false.
    end select
  end function freeze_eq

  pure logical function is_int_like(d)
    type(dyn), intent(in) :: d
    is_int_like = d%kind == DYN_K_INT .or. d%kind == DYN_K_BOOL
  end function is_int_like

  pure integer(int64) function int_like_value(d)
    type(dyn), intent(in) :: d
    if (d%kind == DYN_K_BOOL) then
      int_like_value = merge(1_int64, 0_int64, d%b)
    else
      int_like_value = d%i
    end if
  end function int_like_value

  ! ------------------------------------------------------------------
  ! O1 -- drop degenerate objects
  ! ------------------------------------------------------------------

  subroutine pass_o1_drop(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    type(dyn) :: objs, kept, obj, transform, params, cand, sel, size
    type(dyn) :: name_v
    logical :: found, has_sel, sz_found, isnum
    integer :: i, k
    real(real64) :: x, comp
    logical :: zero_comp
    character(len=:), allocatable :: msg
    objs = scene_objects(scene)
    kept = dyn_list()
    do i = 1, dyn_list_len(objs)
      obj = dyn_list_at(objs, i)
      call mget(obj, transform, found, "transform")
      if (.not. found) transform = dyn_null()
      call mget(obj, params, found, "params")
      if (.not. found) params = dyn_null()
      ! scale = _vec3(transform.scale) or _vec3(obj.scale)
      !         or _vec3(params.scale)   (empty tuple is falsy)
      has_sel = .false.
      sel = dyn_null()
      call mget(transform, cand, found, "scale")
      if (found) call pick_vec3(cand, sel, has_sel)
      if (.not. has_sel) then
        call mget(obj, cand, found, "scale")
        if (found) call pick_vec3(cand, sel, has_sel)
      end if
      if (.not. has_sel) then
        call mget(params, cand, found, "scale")
        if (found) call pick_vec3(cand, sel, has_sel)
      end if
      ! size = obj.size, else params.size
      call mget(obj, size, sz_found, "size")
      if (.not. sz_found) call mget(params, size, sz_found, "size")
      call mget(obj, name_v, found, "name", "id")
      if (.not. found) name_v = dyn_str("?")
      if (has_sel) then
        zero_comp = .false.
        do k = 1, sel%n_items
          call num_value(sel%items(k), comp, isnum)
          if (isnum .and. comp == 0.0_real64) zero_comp = .true.
        end do
        if (zero_comp) then
          msg = "dropped object " // py_repr(name_v) // &
                ": zero scale component in " // py_repr_tuple(sel)
          call opt_warn(bag, W_DROPPED_OBJECT, msg)
          call record_warning(scene, W_DROPPED_OBJECT, msg)
          cycle
        end if
      end if
      if (sz_found) then
        call num_value(size, x, isnum)
        if (isnum .and. x <= 0.0_real64) then
          msg = "dropped object " // py_repr(name_v) // ": size " // &
                py_repr(size) // " <= 0"
          call opt_warn(bag, W_DROPPED_OBJECT, msg)
          call record_warning(scene, W_DROPPED_OBJECT, msg)
          cycle
        end if
      end if
      call dyn_list_push(kept, obj)
    end do
    call dyn_dict_set(scene, "objects", kept)
  end subroutine pass_o1_drop

  !> One step of the Python `or` chain over _vec3 results.
  subroutine pick_vec3(cand, sel, has_sel)
    type(dyn), intent(in) :: cand
    type(dyn), intent(inout) :: sel
    logical, intent(inout) :: has_sel
    type(dyn) :: v
    logical :: has
    call vec3_of(cand, v, has)
    if (has .and. dyn_list_len(v) > 0) then
      sel = dyn_copy(v)
      has_sel = .true.
    end if
  end subroutine pick_vec3

  ! ------------------------------------------------------------------
  ! O2 -- dedup candidates (record only, never remove)
  ! ------------------------------------------------------------------

  subroutine pass_o2_dedup(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    type(dyn) :: objs, seen, obj, key, v, ext
    integer :: i, j, extra
    logical :: found, dup, ok
    objs = scene_objects(scene)
    seen = dyn_list()
    extra = 0
    do i = 1, dyn_list_len(objs)
      obj = dyn_list_at(objs, i)
      key = dyn_list()
      call mget(obj, v, found, "prim", "kind", "primitive")
      if (.not. found) v = dyn_null()
      call dyn_list_push(key, v)
      call mget(obj, v, found, "params")
      if (.not. found) v = dyn_null()
      call dyn_list_push(key, v)
      call mget(obj, v, found, "transform")
      if (.not. found) v = dyn_null()
      call dyn_list_push(key, v)
      call mget(obj, v, found, "color")
      if (.not. found) v = dyn_null()
      call dyn_list_push(key, v)
      call mget(obj, v, found, "material", "material_ref")
      if (.not. found) v = dyn_null()
      call dyn_list_push(key, v)
      dup = .false.
      do j = 1, dyn_list_len(seen)
        if (freeze_eq(key, dyn_list_at(seen, j))) then
          dup = .true.
          exit
        end if
      end do
      if (dup) then
        extra = extra + 1
      else
        call dyn_list_push(seen, key)
      end if
    end do
    call get_ext(scene, ext, ok)
    if (ok) then
      call dyn_dict_set(ext, "dedup_candidates", dyn_int(int(extra, int64)))
      call store_ext(scene, ext)
    end if
  end subroutine pass_o2_dedup

  ! ------------------------------------------------------------------
  ! O3 -- degenerate-triangle cull for compat 'tris' objects
  ! ------------------------------------------------------------------

  !> Resolve one raw-triangle item to a point; ok=.false. when the
  !! item is not a 3-sequence of numbers (Python would raise in
  !! _is_zero_area for non-numbers -- see header divergence note).
  subroutine point_of(item, pt, ok)
    type(dyn), intent(in) :: item
    real(real64), intent(out) :: pt(3)
    logical, intent(out) :: ok
    integer :: k
    logical :: isnum
    ok = .false.
    if (item%kind /= DYN_K_LIST .or. item%n_items /= 3) return
    do k = 1, 3
      call num_value(item%items(k), pt(k), isnum)
      if (.not. isnum) return
    end do
    ok = .true.
  end subroutine point_of

  !> Python _tri_points: resolve a triangle to 3 points.
  subroutine tri_points(tri, verts, has_verts, pts, ok)
    type(dyn), intent(in) :: tri, verts
    logical, intent(in) :: has_verts
    real(real64), intent(out) :: pts(3, 3)
    logical, intent(out) :: ok
    type(dyn) :: raw, item, v
    logical :: found, pok
    integer :: k, idx
    ok = .false.
    raw = dyn_null()
    found = .false.
    if (tri%kind == DYN_K_DICT) then
      call mget(tri, raw, found, "v", "verts", "vertices", "indices")
    else if (tri%kind == DYN_K_LIST) then
      raw = dyn_copy(tri)
      found = .true.
    else
      call mget(tri, raw, found, "v", "verts", "vertices", "indices")
      ! Non-dict dyn values have no fields, so a/b/c cannot exist;
      ! the Python a/b/c branch is unreachable for dyn values.
    end if
    if (.not. found) return
    if (raw%kind /= DYN_K_LIST .or. raw%n_items /= 3) return
    do k = 1, 3
      item = dyn_list_at(raw, k)
      if (item%kind == DYN_K_LIST) then
        call point_of(item, pts(:, k), pok)
        if (.not. pok) return
      else if (item%kind == DYN_K_INT .or. item%kind == DYN_K_BOOL) then
        idx = int(int_like_value(item))
        if (.not. has_verts .or. verts%kind /= DYN_K_LIST) return
        if (idx < 0 .or. idx >= verts%n_items) return
        v = dyn_list_at(verts, idx + 1)
        call point_of(v, pts(:, k), pok)
        if (.not. pok) return
      else
        return
      end if
    end do
    ok = .true.
  end subroutine tri_points

  !> Python _is_zero_area: cross product exactly zero.
  pure logical function is_zero_area(pts)
    real(real64), intent(in) :: pts(3, 3)
    real(real64) :: ux, uy, uz, vx, vy, vz, cx, cy, cz
    ux = pts(1, 2) - pts(1, 1); uy = pts(2, 2) - pts(2, 1)
    uz = pts(3, 2) - pts(3, 1)
    vx = pts(1, 3) - pts(1, 1); vy = pts(2, 3) - pts(2, 1)
    vz = pts(3, 3) - pts(3, 1)
    cx = uy * vz - uz * vy
    cy = uz * vx - ux * vz
    cz = ux * vy - uy * vx
    is_zero_area = cx == 0.0_real64 .and. cy == 0.0_real64 .and. &
                   cz == 0.0_real64
  end function is_zero_area

  subroutine pass_o3_degenerate_cull(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    type(dyn) :: objs, obj, prim, tris, verts, kept, tri, tris_v
    integer :: i, k, dropped
    logical :: prim_found, tris_found, verts_found, is_tris, any3
    logical :: ok, scene_changed
    real(real64) :: pts(3, 3)
    character(len=:), allocatable :: msg, num
    objs = scene_objects(scene)
    dropped = 0
    scene_changed = .false.
    do i = 1, dyn_list_len(objs)
      obj = dyn_list_at(objs, i)
      call mget(obj, tris, tris_found, "tris", "triangles")
      if (.not. tris_found) cycle
      call mget(obj, prim, prim_found, "prim", "kind", "primitive")
      is_tris = .false.
      if (prim_found .and. prim%kind == DYN_K_STR) then
        if (allocated(prim%s)) is_tris = to_lower(prim%s) == "tris"
      end if
      if (.not. is_tris) then
        if (.not. prim_found .or. prim%kind == DYN_K_NULL) then
          any3 = .false.
          if (tris%kind == DYN_K_LIST) then
            do k = 1, tris%n_items
              tri = dyn_list_at(tris, k)
              if (tri%kind == DYN_K_LIST .and. tri%n_items == 3) then
                block
                  type(dyn) :: first_el
                  first_el = dyn_list_at(tri, 1)
                  if (first_el%kind == DYN_K_LIST) any3 = .true.
                end block
              end if
            end do
          end if
          is_tris = any3
        end if
      end if
      if (.not. is_tris) cycle
      if (tris%kind /= DYN_K_LIST) cycle
      call mget(obj, verts, verts_found, "verts", "vertices")
      if (.not. verts_found) verts = dyn_null()
      kept = dyn_list()
      do k = 1, tris%n_items
        tri = dyn_list_at(tris, k)
        call tri_points(tri, verts, verts_found, pts, ok)
        if (ok .and. is_zero_area(pts)) then
          dropped = dropped + 1
          cycle
        end if
        call dyn_list_push(kept, tri)
      end do
      if (dyn_list_len(kept) /= tris%n_items) then
        call mget(obj, tris_v, tris_found, "tris")
        if (tris_found .and. tris_v%kind /= DYN_K_NULL) then
          call dyn_dict_set(obj, "tris", kept)
        else
          call dyn_dict_set(obj, "triangles", kept)
        end if
        call dyn_list_set_at(objs, i, obj)
        scene_changed = .true.
      end if
    end do
    if (scene_changed) call dyn_dict_set(scene, "objects", objs)
    if (dropped > 0) then
      num = trim(fmt_int(int(dropped, int64)))
      msg = "dropped " // num // " zero-area triangle(s) from " // &
            "'tris' objects"
      call opt_warn(bag, W_DEGENERATE_TRI, msg)
      call record_warning(scene, W_DEGENERATE_TRI, msg)
    end if
  end subroutine pass_o3_degenerate_cull

  ! ------------------------------------------------------------------
  ! O4 -- static backface cull: NO-OP in v1 (documented, never faked)
  ! ------------------------------------------------------------------

  subroutine pass_o4_static_backface(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    ! Deliberately nothing: facing is a function of the camera and
    ! the proof machinery does not exist in v1 (optimize.py docstring).
    if (.false.) print *, scene%kind, bag%n
  end subroutine pass_o4_static_backface

  ! ------------------------------------------------------------------
  ! O5 -- palette / default colour normalisation (identity)
  ! ------------------------------------------------------------------

  !> DEFAULT_COLOR = (200, 200, 205) as a dyn list of ints.
  subroutine get_default_color(d)
    type(dyn), intent(out) :: d
    d = dyn_list()
    call dyn_list_push(d, dyn_int(200_int64))
    call dyn_list_push(d, dyn_int(200_int64))
    call dyn_list_push(d, dyn_int(205_int64))
  end subroutine get_default_color

  subroutine pass_o5_palette(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    type(dyn) :: objs, obj, color, prim, defc
    integer :: i
    logical :: found, changed
    if (bag%n < 0) return  ! bag unused in this pass
    objs = scene_objects(scene)
    changed = .false.
    do i = 1, dyn_list_len(objs)
      obj = dyn_list_at(objs, i)
      call mget(obj, color, found, "color")
      ! _get(obj, "color", default=_MISSING) is not None  ->  skip:
      ! explicit colour, or no colour field at all.
      if (.not. found) cycle
      if (color%kind /= DYN_K_NULL) cycle
      call mget(obj, prim, found, "prim", "kind", "primitive")
      if (found .and. prim%kind == DYN_K_STR) then
        if (allocated(prim%s)) then
          if (to_lower(prim%s) == "cube") cycle
        end if
      end if
      call get_default_color(defc)
      call dyn_dict_set(obj, "color", defc)
      call dyn_list_set_at(objs, i, obj)
      changed = .true.
    end do
    if (changed) call dyn_dict_set(scene, "objects", objs)
  end subroutine pass_o5_palette

  ! ------------------------------------------------------------------
  ! O6 -- transform bake (informational annotation only)
  ! ------------------------------------------------------------------

  subroutine pass_o6_transform_bake(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    type(dyn) :: targets, anims, anim, t, objs, obj, name_v, own
    type(dyn) :: transform, params, rotate, vec, ext, baked
    integer :: i, k
    logical :: found, has_vec, ok, changed, in_targets
    if (bag%n < 0) return  ! bag unused in this pass
    ! _animated_targets(scene)
    targets = dyn_list()
    call mget(scene, anims, found, "animations", "anims", "timeline")
    if (found .and. anims%kind == DYN_K_LIST) then
      do i = 1, anims%n_items
        anim = dyn_list_at(anims, i)
        call mget(anim, t, found, "target", "target_name", "object", &
                  "object_name", "name")
        if (found .and. t%kind /= DYN_K_NULL) &
          call dyn_list_push(targets, t)
      end do
    end if
    objs = scene_objects(scene)
    changed = .false.
    do i = 1, dyn_list_len(objs)
      obj = dyn_list_at(objs, i)
      call mget(obj, name_v, found, "name", "id")
      if (.not. found) name_v = dyn_null()
      call mget(obj, own, found, "animations", "animation")
      if (found .and. py_truthy(own)) cycle
      if (name_v%kind /= DYN_K_NULL) then
        in_targets = .false.
        do k = 1, dyn_list_len(targets)
          if (freeze_eq(name_v, dyn_list_at(targets, k))) then
            in_targets = .true.
            exit
          end if
        end do
        if (in_targets) cycle
      end if
      call mget(obj, transform, found, "transform")
      if (.not. found) transform = dyn_null()
      call mget(obj, params, found, "params")
      if (.not. found) params = dyn_null()
      rotate = dyn_null()
      call mget(transform, rotate, found, "rotate", "rotation")
      if (.not. found) call mget(obj, rotate, found, "rotate", "rotation")
      if (.not. found) &
        call mget(params, rotate, found, "rotate", "rotation")
      call vec3_of(rotate, vec, has_vec)
      call get_ext(obj, ext, ok)
      if (.not. ok) cycle
      if (has_vec .and. dyn_list_len(vec) > 0) then
        baked = dyn_copy(vec)
      else
        baked = dyn_list()
        call dyn_list_push(baked, dyn_int(0_int64))
        call dyn_list_push(baked, dyn_int(0_int64))
        call dyn_list_push(baked, dyn_int(0_int64))
      end if
      call dyn_dict_set(ext, "baked_rotation_deg", baked)
      call store_ext(obj, ext)
      call dyn_list_set_at(objs, i, obj)
      changed = .true.
    end do
    if (changed) call dyn_dict_set(scene, "objects", objs)
  end subroutine pass_o6_transform_bake

  ! ------------------------------------------------------------------
  ! O7 -- JS depth-sort hint
  ! ------------------------------------------------------------------

  subroutine pass_o7_depth_sort_hint(scene, bag)
    type(dyn), intent(inout) :: scene
    type(error_bag_t), intent(inout) :: bag
    type(dyn) :: ext
    logical :: ok
    if (bag%n < 0) return  ! bag unused in this pass
    call get_ext(scene, ext, ok)
    if (ok) then
      call dyn_dict_set(ext, "depth_sort", dyn_bool(.true.))
      call store_ext(scene, ext)
    end if
  end subroutine pass_o7_depth_sort_hint

  ! ------------------------------------------------------------------
  ! Pass registry (Python PASSES / register_pass)
  ! ------------------------------------------------------------------

  subroutine register_pass(name, fn)
    character(len=*), intent(in) :: name
    procedure(pass_iface) :: fn
    type(pass_entry), allocatable :: tmp(:)
    integer :: i, cap
    call ensure_registry()
    call ensure_registry_storage()
    do i = 1, n_passes
      if (allocated(pass_registry(i)%name)) then
        if (len(pass_registry(i)%name) == len(name) .and. &
            pass_registry(i)%name == name) then
          pass_registry(i)%fn => fn
          return
        end if
      end if
    end do
    cap = 0
    if (allocated(pass_registry)) cap = size(pass_registry)
    if (n_passes >= cap) then
      allocate (tmp(max(8, 2 * cap)))
      do i = 1, n_passes
        tmp(i)%name = pass_registry(i)%name
        tmp(i)%fn => pass_registry(i)%fn
      end do
      call move_alloc(tmp, pass_registry)
    end if
    n_passes = n_passes + 1
    pass_registry(n_passes)%name = name
    pass_registry(n_passes)%fn => fn
  end subroutine register_pass

  subroutine ensure_registry_storage()
    if (.not. allocated(pass_registry)) allocate (pass_registry(8))
  end subroutine ensure_registry_storage

  subroutine ensure_registry()
    if (registry_ready) return
    registry_ready = .true.
    call register_pass("O1-drop", pass_o1_drop)
    call register_pass("O2-dedup", pass_o2_dedup)
    call register_pass("O3-degenerate-cull", pass_o3_degenerate_cull)
    call register_pass("O4-static-backface", pass_o4_static_backface)
    call register_pass("O5-palette", pass_o5_palette)
    call register_pass("O6-transform-bake", pass_o6_transform_bake)
    call register_pass("O7-depth-sort-hint", pass_o7_depth_sort_hint)
  end subroutine ensure_registry

  integer function pass_count()
    call ensure_registry()
    pass_count = n_passes
  end function pass_count

  function pass_name_at(idx) result(name)
    integer, intent(in) :: idx
    character(len=:), allocatable :: name
    call ensure_registry()
    if (idx < 1 .or. idx > n_passes) then
      name = ""
    else
      name = pass_registry(idx)%name
    end if
  end function pass_name_at

  ! ------------------------------------------------------------------
  ! Entry point (Python optimize)
  ! ------------------------------------------------------------------

  !> Apply the safe O1-O7 passes; returns a deep copy, input intact.
  !! level <= 0 returns an unmodified deep copy.
  subroutine optimize(scene_in, bag, level, scene_out)
    type(dyn), intent(in) :: scene_in
    type(error_bag_t), intent(inout) :: bag
    integer, intent(in), optional :: level
    type(dyn), intent(out) :: scene_out
    integer :: lv, k
    lv = 1
    if (present(level)) lv = level
    scene_out = dyn_copy(scene_in)
    if (lv < 1) return
    call ensure_registry()
    do k = 1, n_passes
      call pass_registry(k)%fn(scene_out, bag)
    end do
  end subroutine optimize

end module f3dc_optimize
