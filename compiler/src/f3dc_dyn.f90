! f3dc_dyn.f90 -- the dyn dynamic-value type for the native Forge3D
! compiler.  Port contract: compiler/DESIGN.md.
!
! dyn mirrors the Python values the compiler stages pass around:
! AST and IR nodes are dyn DICTS with the same keys the Python
! dataclasses serialise to.
!
! Kind tags: 0 null, 1 bool, 2 int(int64), 3 real(real64),
!            4 string, 5 list, 6 dict(string -> dyn).
!
! Indexing: lists and dict entries are addressed 1-based (Fortran
! style); dict lookup is by key string.  This module is standalone:
! it depends on nothing outside the Fortran standard library.
module f3dc_dyn
  use, intrinsic :: iso_fortran_env, only: int64, real64
  implicit none
  private

  public :: dyn, dyn_str_box
  public :: DYN_K_NULL, DYN_K_BOOL, DYN_K_INT, DYN_K_REAL, DYN_K_STR, DYN_K_LIST, &
            DYN_K_DICT
  public :: dyn_null, dyn_bool, dyn_int, dyn_real, dyn_str, dyn_list, &
            dyn_dict
  public :: dyn_is_null, dyn_kind
  public :: dyn_dict_get, dyn_dict_set, dyn_dict_has, dyn_dict_len, &
            dyn_dict_key_at, dyn_dict_value_at, dyn_dict_remove
  public :: dyn_list_push, dyn_list_len, dyn_list_at, dyn_list_set_at
  public :: dyn_copy, dyn_assign, dyn_equal, dyn_free

  integer, parameter :: DYN_K_NULL = 0
  integer, parameter :: DYN_K_BOOL = 1
  integer, parameter :: DYN_K_INT = 2
  integer, parameter :: DYN_K_REAL = 3
  integer, parameter :: DYN_K_STR = 4
  integer, parameter :: DYN_K_LIST = 5
  integer, parameter :: DYN_K_DICT = 6

  !> Boxed string, used for dict keys (parallel to dyn_dict values).
  type :: dyn_str_box
    character(len=:), allocatable :: s
  end type dyn_str_box

  !> The universal value.  Recursive allocatable components are
  !! F2003-legal and accepted by flang-18.
  type :: dyn
    integer :: kind = DYN_K_NULL
    logical :: b = .false.
    integer(int64) :: i = 0_int64
    real(real64) :: r = 0.0_real64
    character(len=:), allocatable :: s
    ! list payload (kind == DYN_K_LIST), n_items entries used
    type(dyn), allocatable :: items(:)
    integer :: n_items = 0
    ! dict payload (kind == DYN_K_DICT): keys(k) <-> dvals(k), n_entries used
    type(dyn_str_box), allocatable :: keys(:)
    type(dyn), allocatable :: dvals(:)
    integer :: n_entries = 0
  end type dyn

contains

  ! ------------------------------------------------------------------
  ! Constructors
  ! ------------------------------------------------------------------

  pure type(dyn) function dyn_null()
    dyn_null%kind = DYN_K_NULL
  end function dyn_null

  pure type(dyn) function dyn_bool(v)
    logical, intent(in) :: v
    dyn_bool%kind = DYN_K_BOOL
    dyn_bool%b = v
  end function dyn_bool

  pure type(dyn) function dyn_int(v)
    integer(int64), intent(in) :: v
    dyn_int%kind = DYN_K_INT
    dyn_int%i = v
  end function dyn_int

  pure type(dyn) function dyn_real(v)
    real(real64), intent(in) :: v
    dyn_real%kind = DYN_K_REAL
    dyn_real%r = v
  end function dyn_real

  type(dyn) function dyn_str(v)
    character(len=*), intent(in) :: v
    dyn_str%kind = DYN_K_STR
    dyn_str%s = v
  end function dyn_str

  pure type(dyn) function dyn_list()
    dyn_list%kind = DYN_K_LIST
    dyn_list%n_items = 0
  end function dyn_list

  pure type(dyn) function dyn_dict()
    dyn_dict%kind = DYN_K_DICT
    dyn_dict%n_entries = 0
  end function dyn_dict

  pure integer function dyn_kind(d)
    type(dyn), intent(in) :: d
    dyn_kind = d%kind
  end function dyn_kind

  pure logical function dyn_is_null(d)
    type(dyn), intent(in) :: d
    dyn_is_null = (d%kind == DYN_K_NULL)
  end function dyn_is_null

  ! ------------------------------------------------------------------
  ! Deep copy / free
  ! ------------------------------------------------------------------

  !> Deep copy: the result shares no storage with the source.
  recursive type(dyn) function dyn_copy(src) result(out)
    type(dyn), intent(in) :: src
    integer :: k
    out%kind = src%kind
    out%b = src%b
    out%i = src%i
    out%r = src%r
    if (allocated(src%s)) out%s = src%s
    out%n_items = src%n_items
    if (allocated(src%items)) then
      allocate (out%items(size(src%items)))
      do k = 1, src%n_items
        out%items(k) = dyn_copy(src%items(k))
      end do
    end if
    out%n_entries = src%n_entries
    if (allocated(src%keys)) then
      allocate (out%keys(size(src%keys)))
      allocate (out%dvals(size(src%dvals)))
      do k = 1, src%n_entries
        if (allocated(src%keys(k)%s)) out%keys(k)%s = src%keys(k)%s
        out%dvals(k) = dyn_copy(src%dvals(k))
      end do
    end if
  end function dyn_copy

  !> Deep-copy assignment through an explicit procedure (intrinsic
  !! assignment of dyn also deep-copies allocatable components, but
  !! this form is unambiguous at call sites that alias).
  recursive subroutine dyn_assign(dst, src)
    type(dyn), intent(inout) :: dst
    type(dyn), intent(in) :: src
    call dyn_free(dst)
    dst = dyn_copy(src)
  end subroutine dyn_assign

  recursive subroutine dyn_free(d)
    type(dyn), intent(inout) :: d
    integer :: k
    if (allocated(d%s)) deallocate (d%s)
    if (allocated(d%items)) then
      do k = 1, d%n_items
        call dyn_free(d%items(k))
      end do
      deallocate (d%items)
    end if
    if (allocated(d%keys)) deallocate (d%keys)
    if (allocated(d%dvals)) then
      do k = 1, d%n_entries
        call dyn_free(d%dvals(k))
      end do
      deallocate (d%dvals)
    end if
    d%kind = DYN_K_NULL
    d%n_items = 0
    d%n_entries = 0
  end subroutine dyn_free

  ! ------------------------------------------------------------------
  ! Lists
  ! ------------------------------------------------------------------

  recursive subroutine dyn_list_push(d, value)
    type(dyn), intent(inout) :: d
    type(dyn), intent(in) :: value
    type(dyn), allocatable :: tmp(:)
    integer :: cap, newcap, k
    if (d%kind /= DYN_K_LIST) then
      call dyn_free(d)
      d = dyn_list()
    end if
    cap = 0
    if (allocated(d%items)) cap = size(d%items)
    if (d%n_items >= cap) then
      newcap = max(4, 2 * cap)
      allocate (tmp(newcap))
      do k = 1, d%n_items
        tmp(k) = dyn_copy(d%items(k))
      end do
      call move_alloc(tmp, d%items)
    end if
    d%n_items = d%n_items + 1
    d%items(d%n_items) = dyn_copy(value)
  end subroutine dyn_list_push

  pure integer function dyn_list_len(d)
    type(dyn), intent(in) :: d
    if (d%kind == DYN_K_LIST) then
      dyn_list_len = d%n_items
    else
      dyn_list_len = 0
    end if
  end function dyn_list_len

  !> 1-based element access (deep copy out); dyn_null when out of range
  !! or d is not a list.
  recursive type(dyn) function dyn_list_at(d, idx) result(out)
    type(dyn), intent(in) :: d
    integer, intent(in) :: idx
    if (d%kind /= DYN_K_LIST .or. idx < 1 .or. idx > d%n_items) then
      out = dyn_null()
    else
      out = dyn_copy(d%items(idx))
    end if
  end function dyn_list_at

  recursive subroutine dyn_list_set_at(d, idx, value)
    type(dyn), intent(inout) :: d
    integer, intent(in) :: idx
    type(dyn), intent(in) :: value
    if (d%kind /= DYN_K_LIST) return
    if (idx < 1 .or. idx > d%n_items) return
    call dyn_free(d%items(idx))
    d%items(idx) = dyn_copy(value)
  end subroutine dyn_list_set_at

  ! ------------------------------------------------------------------
  ! Dicts
  ! ------------------------------------------------------------------

  !> Index (1-based) of key in d, 0 when absent / not a dict.
  pure integer function dyn_dict_find(d, key)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    integer :: k
    dyn_dict_find = 0
    if (d%kind /= DYN_K_DICT) return
    do k = 1, d%n_entries
      if (allocated(d%keys(k)%s)) then
        if (len(d%keys(k)%s) == len(key) .and. d%keys(k)%s == key) then
          dyn_dict_find = k
          return
        end if
      end if
    end do
  end function dyn_dict_find

  pure logical function dyn_dict_has(d, key)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    dyn_dict_has = dyn_dict_find(d, key) > 0
  end function dyn_dict_has

  pure integer function dyn_dict_len(d)
    type(dyn), intent(in) :: d
    if (d%kind == DYN_K_DICT) then
      dyn_dict_len = d%n_entries
    else
      dyn_dict_len = 0
    end if
  end function dyn_dict_len

  !> Value for key (deep copy out); dyn_null when absent.  Use
  !! dyn_dict_has to distinguish "absent" from a stored null.
  recursive type(dyn) function dyn_dict_get(d, key) result(out)
    type(dyn), intent(in) :: d
    character(len=*), intent(in) :: key
    integer :: k
    k = dyn_dict_find(d, key)
    if (k == 0) then
      out = dyn_null()
    else
      out = dyn_copy(d%dvals(k))
    end if
  end function dyn_dict_get

  !> Insert or replace key -> value (deep copy in).  Insertion order
  !! is preserved, mirroring Python dict ordering.
  recursive subroutine dyn_dict_set(d, key, value)
    type(dyn), intent(inout) :: d
    character(len=*), intent(in) :: key
    type(dyn), intent(in) :: value
    type(dyn_str_box), allocatable :: nkeys(:)
    type(dyn), allocatable :: nvals(:)
    integer :: cap, newcap, k, hit
    if (d%kind /= DYN_K_DICT) then
      call dyn_free(d)
      d = dyn_dict()
    end if
    hit = dyn_dict_find(d, key)
    if (hit > 0) then
      call dyn_free(d%dvals(hit))
      d%dvals(hit) = dyn_copy(value)
      return
    end if
    cap = 0
    if (allocated(d%keys)) cap = size(d%keys)
    if (d%n_entries >= cap) then
      newcap = max(4, 2 * cap)
      allocate (nkeys(newcap))
      allocate (nvals(newcap))
      do k = 1, d%n_entries
        if (allocated(d%keys(k)%s)) nkeys(k)%s = d%keys(k)%s
        nvals(k) = dyn_copy(d%dvals(k))
      end do
      call move_alloc(nkeys, d%keys)
      call move_alloc(nvals, d%dvals)
    end if
    d%n_entries = d%n_entries + 1
    d%keys(d%n_entries)%s = key
    d%dvals(d%n_entries) = dyn_copy(value)
  end subroutine dyn_dict_set

  !> Remove key if present (order of the remaining keys preserved).
  recursive subroutine dyn_dict_remove(d, key)
    type(dyn), intent(inout) :: d
    character(len=*), intent(in) :: key
    integer :: k, hit
    hit = dyn_dict_find(d, key)
    if (hit == 0) return
    call dyn_free(d%dvals(hit))
    do k = hit, d%n_entries - 1
      if (allocated(d%keys(k + 1)%s)) then
        d%keys(k)%s = d%keys(k + 1)%s
      else if (allocated(d%keys(k)%s)) then
        deallocate (d%keys(k)%s)
      end if
      d%dvals(k) = dyn_copy(d%dvals(k + 1))
    end do
    d%n_entries = d%n_entries - 1
  end subroutine dyn_dict_remove

  !> Key at 1-based position idx (insertion order); "" out of range.
  function dyn_dict_key_at(d, idx) result(out)
    type(dyn), intent(in) :: d
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (d%kind /= DYN_K_DICT .or. idx < 1 .or. idx > d%n_entries) then
      out = ""
    else if (allocated(d%keys(idx)%s)) then
      out = d%keys(idx)%s
    else
      out = ""
    end if
  end function dyn_dict_key_at

  !> Value at 1-based position idx (deep copy out); dyn_null out of range.
  recursive type(dyn) function dyn_dict_value_at(d, idx) result(out)
    type(dyn), intent(in) :: d
    integer, intent(in) :: idx
    if (d%kind /= DYN_K_DICT .or. idx < 1 .or. idx > d%n_entries) then
      out = dyn_null()
    else
      out = dyn_copy(d%dvals(idx))
    end if
  end function dyn_dict_value_at

  ! ------------------------------------------------------------------
  ! Structural equality (Python == semantics)
  ! ------------------------------------------------------------------

  !> Deep structural equality.  Kinds must match (an int never equals
  !! a real, mirroring the DESIGN rule that Python types are mirrored
  !! exactly -- note Python itself has 1 == 1.0, but dyn values carry
  !! the emitter's type distinction, so kind-strict is the parity-safe
  !! choice and is reported as such).  Dict equality is unordered, as
  !! in Python.  Real equality is Fortran == (so -0.0 == 0.0 and
  !! NaN /= NaN, exactly as in Python).
  recursive function dyn_equal(a, b) result(eq)
    type(dyn), intent(in) :: a, b
    logical :: eq
    integer :: k, hit
    eq = .false.
    if (a%kind /= b%kind) return
    select case (a%kind)
    case (DYN_K_NULL)
      eq = .true.
    case (DYN_K_BOOL)
      eq = (a%b .eqv. b%b)
    case (DYN_K_INT)
      eq = (a%i == b%i)
    case (DYN_K_REAL)
      eq = (a%r == b%r)
    case (DYN_K_STR)
      if (allocated(a%s) .and. allocated(b%s)) then
        eq = (len(a%s) == len(b%s)) .and. (a%s == b%s)
      else
        eq = (.not. allocated(a%s)) .and. (.not. allocated(b%s))
      end if
    case (DYN_K_LIST)
      if (a%n_items /= b%n_items) return
      eq = .true.
      do k = 1, a%n_items
        if (.not. dyn_equal(a%items(k), b%items(k))) then
          eq = .false.
          return
        end if
      end do
    case (DYN_K_DICT)
      if (a%n_entries /= b%n_entries) return
      eq = .true.
      do k = 1, a%n_entries
        if (.not. allocated(a%keys(k)%s)) cycle
        hit = dyn_dict_find(b, a%keys(k)%s)
        if (hit == 0) then
          eq = .false.
          return
        end if
        if (.not. dyn_equal(a%dvals(k), b%dvals(hit))) then
          eq = .false.
          return
        end if
      end do
    case default
      eq = .false.
    end select
  end function dyn_equal

end module f3dc_dyn
