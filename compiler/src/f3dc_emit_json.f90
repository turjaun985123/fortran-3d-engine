! f3dc_emit_json.f90 -- JSON emission for the native Forge3D
! compiler.  Port of tools/f3dc/emit_json.py (seat B13); contract:
! compiler/DESIGN.md.  Free subroutines only.
!
! Interface mapping: Python takes the typed IR object and calls
! ir_nodes.to_dict(ir).  The Fortran pipeline scene dyn is the RAW
! scene (it still carries pipeline-only keys such as "base_dir" and
! a null "source_map"), so emit_json_v2 routes its input through
! f3dc_ir's ir_to_dict -- exactly Python's to_dict call -- before
! stamping/serialising.  emit_json_legacy reads the raw scene dyn
! directly, as emit_json.py's legacy path reads IR attributes.
!
! Dialects:
! * v2     -- to_dict + {"format": "forge3d-scene", "version": 2},
!             json.dumps(indent=1, sort_keys=True) (ensure_ascii
!             default True, no trailing newline).
! * legacy -- {"triangles": [{"id", "v", "color"}]}, json.dumps
!             (indent=1) in insertion order.  Only prim 'cube'
!             (tessellated, transform applied) and 'tris' (raw,
!             untransformed) are emitted; every other primitive --
!             which is where ALL ext_* extension primitives land in
!             this dialect -- is skipped with one W202 warning per
!             object through the error bag (EXT DISPATCH POINT:
!             emit_json.py has no ext_* hook; the skip IS the
!             extension boundary).
module f3dc_emit_json
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use f3dc_dyn
  use f3dc_str, only: fmt_real
  use f3dc_emit_common, only: json_dumps, palette_face
  use f3dc_ir, only: ir_to_dict
  use f3dc_errors, only: error_bag_t, error_bag_add, make_diagnostic
  implicit none
  private

  public :: FORMAT_NAME, FORMAT_VERSION
  public :: emit_json_v2, emit_json, emit_json_legacy

  character(len=*), parameter :: FORMAT_NAME = "forge3d-scene"
  integer, parameter :: FORMAT_VERSION = 2

  real(real64), parameter :: PI = acos(-1.0_real64)
  ! _CUBE_FACES from emit_json.py (0-based corner triples).
  integer, parameter :: CUBE_FACES(3, 12) = reshape([ &
    0, 2, 1,  0, 3, 2,  1, 6, 5,  1, 2, 6, &
    5, 7, 4,  5, 6, 7,  4, 3, 0,  4, 7, 3, &
    3, 6, 2,  3, 7, 6,  4, 1, 5,  4, 0, 1], [3, 12])

contains

  ! ------------------------------------------------------------------
  ! v2 -- native IR dump
  ! ------------------------------------------------------------------

  !> emit_json.emit_json_v2: stamped, deterministic v2 JSON.
  subroutine emit_json_v2(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    type(dyn) :: data
    data = ir_to_dict(ir)
    call dyn_dict_set(data, "format", dyn_str(FORMAT_NAME))
    call dyn_dict_set(data, "version", dyn_int(int(FORMAT_VERSION, int64)))
    call json_dumps(data, .true., .true., 1, text)
    call dyn_free(data)
  end subroutine emit_json_v2

  !> emit_json.emit_json: alias for the v2 dialect.
  subroutine emit_json(ir, text)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    call emit_json_v2(ir, text)
  end subroutine emit_json

  ! ------------------------------------------------------------------
  ! Small helpers mirroring emit_json.py
  ! ------------------------------------------------------------------

  !> float(v) for a dyn scalar; ok=.false. when Python would raise.
  subroutine dyn_to_real(v, x, ok)
    type(dyn), intent(in) :: v
    real(real64), intent(out) :: x
    logical, intent(out) :: ok
    integer :: ios
    ok = .true.
    x = 0.0_real64
    select case (v%kind)
    case (DYN_K_INT)
      x = real(v%i, real64)
    case (DYN_K_REAL)
      x = v%r
    case (DYN_K_BOOL)
      if (v%b) then
        x = 1.0_real64
      else
        x = 0.0_real64
      end if
    case (DYN_K_STR)
      if (allocated(v%s)) then
        read (v%s, *, iostat=ios) x
        if (ios /= 0) ok = .false.
      else
        ok = .false.
      end if
    case default
      ok = .false.
    end select
  end subroutine dyn_to_real

  !> int(v) for a dyn scalar (Python int(): truncation toward zero
  !! for floats).  Non-numeric values yield 0 (Python would raise;
  !! valid IR never reaches that path).
  integer(int64) function dyn_to_int(v) result(out)
    type(dyn), intent(in) :: v
    real(real64) :: x
    logical :: ok
    select case (v%kind)
    case (DYN_K_INT)
      out = v%i
    case (DYN_K_BOOL)
      if (v%b) then
        out = 1_int64
      else
        out = 0_int64
      end if
    case (DYN_K_REAL)
      out = int(v%r, int64)
    case default
      call dyn_to_real(v, x, ok)
      if (ok) then
        out = int(x, int64)
      else
        out = 0_int64
      end if
    end select
  end function dyn_to_int

  !> emit_json._vec3: None -> default; scalar -> [v]*3; else the
  !! first three components as floats.  `value` is the already
  !! fetched dyn (dyn_null + present flag mirror Python None).
  subroutine vec3_of(value, present, default, out)
    type(dyn), intent(in) :: value
    logical, intent(in) :: present
    real(real64), intent(in) :: default(3)
    real(real64), intent(out) :: out(3)
    type(dyn) :: item
    integer :: i
    logical :: ok
    if (.not. present .or. value%kind == DYN_K_NULL) then
      out = default
      return
    end if
    if (value%kind == DYN_K_INT .or. value%kind == DYN_K_REAL .or. &
        value%kind == DYN_K_BOOL) then
      call dyn_to_real(value, out(1), ok)
      out = out(1)
      return
    end if
    if (value%kind == DYN_K_LIST) then
      do i = 1, 3
        item = dyn_list_at(value, i)
        call dyn_to_real(item, out(i), ok)
        if (.not. ok) out(i) = 0.0_real64
      end do
      return
    end if
    out = default
  end subroutine vec3_of

  !> Fetch obj[key] as a vec3 with the Python getattr chain:
  !! primary key, else fallback key, else the default.
  subroutine obj_vec3(obj, key, fallback_key, default, out)
    type(dyn), intent(in) :: obj
    character(len=*), intent(in) :: key, fallback_key
    real(real64), intent(in) :: default(3)
    real(real64), intent(out) :: out(3)
    type(dyn) :: v
    ! Python: _vec3(getattr(obj, key, None), getattr(obj, fb, default))
    ! -- a present-but-None primary falls through to the fallback.
    if (dyn_dict_has(obj, key)) then
      v = dyn_dict_get(obj, key)
      if (v%kind /= DYN_K_NULL) then
        call vec3_of(v, .true., default, out)
        return
      end if
    end if
    if (len(fallback_key) > 0 .and. dyn_dict_has(obj, fallback_key)) then
      v = dyn_dict_get(obj, fallback_key)
      call vec3_of(v, .true., default, out)
    else
      out = default
    end if
  end subroutine obj_vec3

  ! 3x3 matrix helpers.  Matrices are stored m(row, col) exactly as
  ! written in emit_json.py (the reshape lists below are the matrix
  ! columns).
  !
  ! BIT-EXACTNESS: emit_json.py sums products with Python's built-in
  ! sum(), which since Python 3.12 uses Neumaier compensated
  ! summation for floats -- NOT naive left-to-right addition.  The
  ! difference is observable (1 ulp on hello-cube's legacy output),
  ! so both helpers route through py_sum3 below, a statement-by-
  ! statement mirror of CPython's float sum algorithm.  Products
  ! are formed and stored (hence rounded) before summing, exactly
  ! as the Python generator materialises each product.
  function py_sum3(t) result(s)
    real(real64), intent(in) :: t(3)
    real(real64) :: s, comp, x, new_s
    integer :: k
    s = 0.0_real64
    comp = 0.0_real64
    do k = 1, 3
      x = t(k)
      new_s = s + x
      if (abs(s) >= abs(x)) then
        comp = comp + ((s - new_s) + x)
      else
        comp = comp + ((x - new_s) + s)
      end if
      s = new_s
    end do
    s = s + comp
  end function py_sum3

  subroutine mat_mul(a, b, out)
    real(real64), intent(in) :: a(3, 3), b(3, 3)
    real(real64), intent(out) :: out(3, 3)
    integer :: i, j, k
    real(real64) :: t(3)
    do i = 1, 3
      do j = 1, 3
        do k = 1, 3
          t(k) = a(i, k) * b(k, j)
        end do
        out(i, j) = py_sum3(t)
      end do
    end do
  end subroutine mat_mul

  subroutine mat_vec(m, v, out)
    real(real64), intent(in) :: m(3, 3), v(3)
    real(real64), intent(out) :: out(3)
    integer :: i, k
    real(real64) :: t(3)
    do i = 1, 3
      do k = 1, 3
        t(k) = m(i, k) * v(k)
      end do
      out(i) = py_sum3(t)
    end do
  end subroutine mat_vec

  ! Rotation matrices built from the same row definitions as
  ! emit_json.py (reshape fills column by column).
  subroutine rot_x(deg, m)
    real(real64), intent(in) :: deg
    real(real64), intent(out) :: m(3, 3)
    real(real64) :: c, s, rad
    rad = deg * (PI / 180.0_real64)
    c = cos(rad)
    s = sin(rad)
    m = reshape([1.0_real64, 0.0_real64, 0.0_real64, &
                 0.0_real64, c, s, &
                 0.0_real64, -s, c], [3, 3])
  end subroutine rot_x

  subroutine rot_y(deg, m)
    real(real64), intent(in) :: deg
    real(real64), intent(out) :: m(3, 3)
    real(real64) :: c, s, rad
    rad = deg * (PI / 180.0_real64)
    c = cos(rad)
    s = sin(rad)
    m = reshape([c, 0.0_real64, -s, &
                 0.0_real64, 1.0_real64, 0.0_real64, &
                 s, 0.0_real64, c], [3, 3])
  end subroutine rot_y

  subroutine rot_z(deg, m)
    real(real64), intent(in) :: deg
    real(real64), intent(out) :: m(3, 3)
    real(real64) :: c, s, rad
    rad = deg * (PI / 180.0_real64)
    c = cos(rad)
    s = sin(rad)
    m = reshape([c, s, 0.0_real64, &
                 -s, c, 0.0_real64, &
                 0.0_real64, 0.0_real64, 1.0_real64], [3, 3])
  end subroutine rot_z

  !> emit_json._transform: scale -> Rz -> Rx -> Ry -> translate
  !! (Fortran compose order T*Ry*Rx*Rz*S).
  subroutine transform_point(obj, point, out)
    type(dyn), intent(in) :: obj
    real(real64), intent(in) :: point(3)
    real(real64), intent(out) :: out(3)
    real(real64) :: scale(3), rotate(3), pos(3), scaled(3)
    real(real64) :: rx(3, 3), ry(3, 3), rz(3, 3), tmp(3, 3), rot(3, 3)
    integer :: i
    call obj_vec3(obj, "scale", "", [1.0_real64, 1.0_real64, 1.0_real64], scale)
    call obj_vec3(obj, "rotate", "rotation", &
                  [0.0_real64, 0.0_real64, 0.0_real64], rotate)
    call obj_vec3(obj, "pos", "position", &
                  [0.0_real64, 0.0_real64, 0.0_real64], pos)
    do i = 1, 3
      scaled(i) = point(i) * scale(i)
    end do
    call rot_x(rotate(1), rx)
    call rot_y(rotate(2), ry)
    call rot_z(rotate(3), rz)
    call mat_mul(rx, rz, tmp)
    call mat_mul(ry, tmp, rot)
    call mat_vec(rot, scaled, out)
    do i = 1, 3
      out(i) = out(i) + pos(i)
    end do
  end subroutine transform_point

  ! ------------------------------------------------------------------
  ! W202 warning (emit_json._warn_w202)
  ! ------------------------------------------------------------------

  !> Python repr() of a string, for the %r slots of the W202
  !! message.  Single quotes unless the string contains a single
  !! quote and no double quote; backslash, the quote char, \n \r
  !! \t and other C0 controls / DEL are escaped (\xXX).  Non-ASCII
  !! bytes pass through (Python repr keeps printable Unicode).
  function py_repr_str(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    character(len=1) :: q
    integer :: i, b
    character(len=4) :: hexbuf
    character(len=*), parameter :: HEXD = "0123456789abcdef"
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
        hexbuf = "\x" // HEXD(b / 16 + 1:b / 16 + 1) // &
                 HEXD(mod(b, 16) + 1:mod(b, 16) + 1)
        out = out // hexbuf
      else
        out = out // s(i:i)
      end if
    end do
    out = out // q
  end function py_repr_str


  !> Python repr() of a dyn value for the W202 %r slots (str, int,
  !! real, bool and None covered; containers fall back to their
  !! string form -- valid IR always carries str name/prim here).
  function py_repr_dyn(v, present, default_str) result(out)
    type(dyn), intent(in) :: v
    logical, intent(in) :: present
    character(len=*), intent(in) :: default_str
    character(len=:), allocatable :: out
    if (.not. present) then
      out = py_repr_str(default_str)
      return
    end if
    select case (v%kind)
    case (DYN_K_STR)
      if (allocated(v%s)) then
        out = py_repr_str(v%s)
      else
        out = py_repr_str("")
      end if
    case (DYN_K_INT)
      block
        character(len=32) :: buf
        write (buf, "(I0)") v%i
        out = trim(buf)
      end block
    case (DYN_K_REAL)
      out = fmt_real(v%r)
    case (DYN_K_BOOL)
      if (v%b) then
        out = "True"
      else
        out = "False"
      end if
    case (DYN_K_NULL)
      out = "None"
    case default
      out = py_repr_str(default_str)
    end select
  end function py_repr_dyn

  subroutine warn_w202(bag, obj)
    type(error_bag_t), intent(inout), optional :: bag
    type(dyn), intent(in) :: obj
    character(len=:), allocatable :: message
    type(dyn) :: v
    logical :: has_name, has_prim
    if (.not. present(bag)) return
    has_name = dyn_dict_has(obj, "name")
    if (has_name) v = dyn_dict_get(obj, "name")
    block
      character(len=:), allocatable :: name_r, prim_r
      name_r = py_repr_dyn(v, has_name, "?")
      has_prim = dyn_dict_has(obj, "prim")
      if (has_prim) v = dyn_dict_get(obj, "prim")
      prim_r = py_repr_dyn(v, has_prim, "?")
      message = "legacy JSON emit: skipping object " // name_r // &
                " with unsupported primitive " // prim_r // &
                " (only 'cube' and 'tris' can be flattened to legacy triangles)"
    end block
    call error_bag_add(bag, make_diagnostic("W202", "warning", message))
  end subroutine warn_w202

  ! ------------------------------------------------------------------
  ! Legacy v1 -- triangle sources
  ! ------------------------------------------------------------------

  !> Append one triangle (verts dyn list-of-3-lists, color dyn list
  !! of 3 ints) to the accumulator with the next sequential id.
  subroutine push_triangle(tris, verts, color)
    type(dyn), intent(inout) :: tris
    type(dyn), intent(in) :: verts, color
    type(dyn) :: tri
    tri = dyn_dict()
    call dyn_dict_set(tri, "id", &
                      dyn_int(int(dyn_list_len(tris) + 1, int64)))
    call dyn_dict_set(tri, "v", verts)
    call dyn_dict_set(tri, "color", color)
    call dyn_list_push(tris, tri)
    call dyn_free(tri)
  end subroutine push_triangle

  !> A colour spec -> dyn list of 3 dyn_int via Python int(c).
  subroutine color_to_ints(color, out)
    type(dyn), intent(in) :: color
    type(dyn), intent(out) :: out
    type(dyn) :: item
    integer :: i
    out = dyn_list()
    if (color%kind == DYN_K_LIST) then
      do i = 1, dyn_list_len(color)
        item = dyn_list_at(color, i)
        call dyn_list_push(out, dyn_int(dyn_to_int(item)))
      end do
    end if
  end subroutine color_to_ints

  !> emit_json._tris_triangles: raw triangles, NO transform.
  subroutine tris_triangles(obj, tris)
    type(dyn), intent(in) :: obj
    type(dyn), intent(inout) :: tris
    type(dyn) :: raw, obj_color, tri, verts, color, first, first0
    logical :: has_color, has_raw
    integer :: i

    has_raw = dyn_dict_has(obj, "triangles")
    if (has_raw) then
      raw = dyn_dict_get(obj, "triangles")
      if (raw%kind == DYN_K_NULL) has_raw = .false.
    end if
    if (.not. has_raw .and. dyn_dict_has(obj, "tris")) then
      raw = dyn_dict_get(obj, "tris")
      has_raw = raw%kind /= DYN_K_NULL
    end if
    if (.not. has_raw) return
    if (raw%kind /= DYN_K_LIST) return
    obj_color = dyn_dict_get(obj, "color")

    do i = 1, dyn_list_len(raw)
      tri = dyn_list_at(raw, i)
      verts = dyn_null()
      color = dyn_null()
      has_color = .false.
      if (tri%kind == DYN_K_DICT) then
        if (dyn_dict_has(tri, "v")) then
          verts = dyn_dict_get(tri, "v")
        else if (dyn_dict_has(tri, "verts")) then
          verts = dyn_dict_get(tri, "verts")
        else if (dyn_dict_has(tri, "vertices")) then
          verts = dyn_dict_get(tri, "vertices")
        end if
        if (dyn_dict_has(tri, "color")) then
          color = dyn_dict_get(tri, "color")
          has_color = color%kind /= DYN_K_NULL
        else if (dyn_dict_has(tri, "c")) then
          color = dyn_dict_get(tri, "c")
          has_color = color%kind /= DYN_K_NULL
        end if
      else if (tri%kind == DYN_K_LIST .and. dyn_list_len(tri) == 2) then
        first = dyn_list_at(tri, 1)
        if (first%kind == DYN_K_LIST .and. dyn_list_len(first) > 0) then
          first0 = dyn_list_at(first, 1)
          if (first0%kind == DYN_K_LIST) then
            verts = first
            color = dyn_list_at(tri, 2)
            has_color = color%kind /= DYN_K_NULL
          else
            verts = tri
          end if
        else
          verts = tri
        end if
      else
        verts = tri
      end if
      if (verts%kind /= DYN_K_LIST) cycle
      if (dyn_list_len(verts) /= 3) cycle
      if (.not. has_color) then
        if (obj_color%kind /= DYN_K_NULL) then
          color = obj_color
          has_color = .true.
        end if
      end if
      block
        type(dyn) :: vcopy, cints
        vcopy = dyn_copy(verts)
        if (has_color) then
          call color_to_ints(color, cints)
        else
          ! _DEFAULT_COLOR = (255, 255, 255)
          cints = dyn_list()
          call dyn_list_push(cints, dyn_int(255_int64))
          call dyn_list_push(cints, dyn_int(255_int64))
          call dyn_list_push(cints, dyn_int(255_int64))
        end if
        call push_triangle(tris, vcopy, cints)
        call dyn_free(vcopy)
        call dyn_free(cints)
      end block
    end do
  end subroutine tris_triangles

  !> emit_json._cube_triangles: tessellated, transform applied.
  subroutine cube_triangles(obj, tris)
    type(dyn), intent(in) :: obj
    type(dyn), intent(inout) :: tris
    type(dyn) :: size3, size_v, obj_color, verts, vlist, cints, item
    real(real64) :: half(3), h, corners(3, 8), pt(3), out3(3)
    integer :: f, cidx, i
    logical :: ok

    if (dyn_dict_has(obj, "size3")) then
      size3 = dyn_dict_get(obj, "size3")
    else
      size3 = dyn_null()
    end if
    if (size3%kind == DYN_K_LIST) then
      do i = 1, 3
        item = dyn_list_at(size3, i)
        call dyn_to_real(item, half(i), ok)
        half(i) = half(i) * 0.5_real64
      end do
    else
      if (dyn_dict_has(obj, "size")) then
        size_v = dyn_dict_get(obj, "size")
        call dyn_to_real(size_v, h, ok)
        if (.not. ok) h = 2.0_real64
      else
        h = 2.0_real64
      end if
      h = h * 0.5_real64
      half = [h, h, h]
    end if
    ! corners p1..p8 in create_cube order (column per corner)
    corners = reshape([ &
      -half(1), -half(2), -half(3),   half(1), -half(2), -half(3), &
       half(1),  half(2), -half(3),  -half(1),  half(2), -half(3), &
      -half(1), -half(2),  half(3),   half(1), -half(2),  half(3), &
       half(1),  half(2),  half(3),  -half(1),  half(2),  half(3)], &
      [3, 8])
    obj_color = dyn_dict_get(obj, "color")
    do f = 1, 12
      if (obj_color%kind /= DYN_K_NULL) then
        call color_to_ints(obj_color, cints)
      else
        block
          integer :: rgb(3)
          logical :: found
          call palette_face((f - 1) / 2, rgb, found)
          cints = dyn_list()
          do i = 1, 3
            call dyn_list_push(cints, dyn_int(int(rgb(i), int64)))
          end do
        end block
      end if
      verts = dyn_list()
      do i = 1, 3
        cidx = CUBE_FACES(i, f) + 1
        pt = corners(:, cidx)
        call transform_point(obj, pt, out3)
        vlist = dyn_list()
        call dyn_list_push(vlist, dyn_real(out3(1)))
        call dyn_list_push(vlist, dyn_real(out3(2)))
        call dyn_list_push(vlist, dyn_real(out3(3)))
        call dyn_list_push(verts, vlist)
        call dyn_free(vlist)
      end do
      call push_triangle(tris, verts, cints)
      call dyn_free(verts)
      call dyn_free(cints)
    end do
  end subroutine cube_triangles

  ! ------------------------------------------------------------------
  ! Legacy v1 -- scene
  ! ------------------------------------------------------------------

  !> emit_json.emit_json_legacy(ir, bag=None).
  subroutine emit_json_legacy(ir, text, bag)
    type(dyn), intent(in) :: ir
    character(len=:), allocatable, intent(out) :: text
    type(error_bag_t), intent(inout), optional :: bag
    type(dyn) :: objects, obj, tris, root, prim_v
    character(len=:), allocatable :: prim
    integer :: i

    tris = dyn_list()
    objects = dyn_dict_get(ir, "objects")
    if (objects%kind == DYN_K_LIST) then
      do i = 1, dyn_list_len(objects)
        obj = dyn_list_at(objects, i)
        prim_v = dyn_dict_get(obj, "prim")
        if (prim_v%kind == DYN_K_STR .and. allocated(prim_v%s)) then
          prim = prim_v%s
        else
          prim = ""
        end if
        block
          character(len=:), allocatable :: low
          integer :: j, b
          low = prim
          do j = 1, len(low)
            b = iachar(low(j:j))
            if (b >= 65 .and. b <= 90) low(j:j) = achar(b + 32)
          end do
          prim = low
        end block
        if (prim == "tris") then
          call tris_triangles(obj, tris)
        else if (prim == "cube") then
          call cube_triangles(obj, tris)
        else
          if (present(bag)) call warn_w202(bag, obj)
        end if
        call dyn_free(obj)
      end do
    end if
    root = dyn_dict()
    call dyn_dict_set(root, "triangles", tris)
    call json_dumps(root, .false., .true., 1, text)
    call dyn_free(root)
    call dyn_free(tris)
  end subroutine emit_json_legacy

end module f3dc_emit_json
