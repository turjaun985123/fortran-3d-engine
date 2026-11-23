! json_parse.f90 -- small JSON DOM parser (module json_parse).
!
! Sufficient to read the Forge3D native-test data files
! (corpus.json ~914 KB, examples.json, cli_battery.json) and the
! preview server's /__version and /__status responses.
!
! Supports: objects, arrays, strings with \" \\ \/ \b \f \n \r \t
! and \uXXXX escapes (including surrogate pairs, encoded to UTF-8),
! numbers (integer part exposed as int64), true / false / null.
!
! The DOM lives in a single node pool; parsing a new document
! replaces the previous one.  Nodes are referenced by integer
! index (0 = none).  Children of an object/array are traversed in
! document order through the helpers below.

module json_parse
  use iso_fortran_env, only: int64
  implicit none
  private

  integer, parameter, public :: JNULL = 0, JBOOL = 1, JNUM = 2, &
                                JSTR = 3, JARR = 4, JOBJ = 5

  public :: json_parse_text, json_kind, json_child_count, &
            json_child_at, json_get, json_has, json_key_at, &
            json_as_string, json_as_int, json_as_bool

  type :: jnode
    integer :: kind = JNULL
    logical :: bval = .false.
    integer(int64) :: ival = 0_int64
    character(len=:), allocatable :: sval
    character(len=:), allocatable :: key
    integer :: first_child = 0
    integer :: next_sibling = 0
  end type jnode

  type(jnode), allocatable, save :: pool(:)
  integer, save :: pool_n = 0

  character(len=:), allocatable, save :: src_text
  integer, save :: pos = 1
  logical, save :: parse_error = .false.

  ! Scratch byte buffer used while decoding a string literal.
  character(len=1), allocatable, save :: sbuf(:)
  integer, save :: sbuf_n = 0, sbuf_cap = 0

contains

  ! ---------------------------------------------------------------
  subroutine json_parse_text(text, root, ok)
    character(len=*), intent(in) :: text
    integer, intent(out) :: root
    logical, intent(out) :: ok
    if (allocated(pool)) deallocate(pool)
    allocate(pool(1024))
    pool_n = 0
    if (allocated(src_text)) deallocate(src_text)
    allocate(character(len=len(text)) :: src_text)
    src_text = text
    pos = 1
    parse_error = .false.
    root = parse_value()
    ok = .not. parse_error
  end subroutine json_parse_text

  ! ---------------------------------------------------------------
  integer function json_kind(idx)
    integer, intent(in) :: idx
    if (idx < 1 .or. idx > pool_n) then
      json_kind = JNULL
    else
      json_kind = pool(idx)%kind
    end if
  end function json_kind

  integer function json_child_count(idx)
    integer, intent(in) :: idx
    integer :: c
    json_child_count = 0
    if (idx < 1 .or. idx > pool_n) return
    c = pool(idx)%first_child
    do while (c /= 0)
      json_child_count = json_child_count + 1
      c = pool(c)%next_sibling
    end do
  end function json_child_count

  integer function json_child_at(idx, i)
    integer, intent(in) :: idx, i
    integer :: c, k
    json_child_at = 0
    if (idx < 1 .or. idx > pool_n) return
    c = pool(idx)%first_child
    k = 1
    do while (c /= 0)
      if (k == i) then
        json_child_at = c
        return
      end if
      k = k + 1
      c = pool(c)%next_sibling
    end do
  end function json_child_at

  subroutine json_get(idx, key, child)
    integer, intent(in) :: idx
    character(len=*), intent(in) :: key
    integer, intent(out) :: child
    integer :: c
    child = 0
    if (idx < 1 .or. idx > pool_n) return
    c = pool(idx)%first_child
    do while (c /= 0)
      if (allocated(pool(c)%key)) then
        if (pool(c)%key == key) then
          child = c
          return
        end if
      end if
      c = pool(c)%next_sibling
    end do
  end subroutine json_get

  logical function json_has(idx, key)
    integer, intent(in) :: idx
    character(len=*), intent(in) :: key
    integer :: child
    call json_get(idx, key, child)
    json_has = (child /= 0)
  end function json_has

  subroutine json_key_at(idx, i, key)
    integer, intent(in) :: idx, i
    character(len=:), allocatable, intent(out) :: key
    integer :: c
    c = json_child_at(idx, i)
    if (c == 0) then
      allocate(character(len=0) :: key)
      return
    end if
    if (allocated(pool(c)%key)) then
      allocate(character(len=len(pool(c)%key)) :: key)
      key = pool(c)%key
    else
      allocate(character(len=0) :: key)
    end if
  end subroutine json_key_at

  subroutine json_as_string(idx, s)
    integer, intent(in) :: idx
    character(len=:), allocatable, intent(out) :: s
    if (idx < 1 .or. idx > pool_n) then
      allocate(character(len=0) :: s)
      return
    end if
    if (allocated(pool(idx)%sval)) then
      allocate(character(len=len(pool(idx)%sval)) :: s)
      s = pool(idx)%sval
    else
      allocate(character(len=0) :: s)
    end if
  end subroutine json_as_string

  integer(int64) function json_as_int(idx)
    integer, intent(in) :: idx
    json_as_int = 0_int64
    if (idx < 1 .or. idx > pool_n) return
    json_as_int = pool(idx)%ival
  end function json_as_int

  logical function json_as_bool(idx)
    integer, intent(in) :: idx
    json_as_bool = .false.
    if (idx < 1 .or. idx > pool_n) return
    json_as_bool = pool(idx)%bval
  end function json_as_bool

  ! ---------------------------------------------------------------
  ! Pool management
  ! ---------------------------------------------------------------
  subroutine pool_grow()
    type(jnode), allocatable :: np(:)
    integer :: newcap
    newcap = max(1024, 2 * size(pool))
    allocate(np(newcap))
    if (pool_n > 0) np(1:pool_n) = pool(1:pool_n)
    deallocate(pool)
    call move_alloc(np, pool)
  end subroutine pool_grow

  integer function new_node()
    if (.not. allocated(pool)) then
      allocate(pool(1024))
      pool_n = 0
    end if
    if (pool_n >= size(pool)) call pool_grow()
    pool_n = pool_n + 1
    new_node = pool_n
    pool(new_node)%kind = JNULL
    pool(new_node)%bval = .false.
    pool(new_node)%ival = 0_int64
    if (allocated(pool(new_node)%sval)) deallocate(pool(new_node)%sval)
    if (allocated(pool(new_node)%key)) deallocate(pool(new_node)%key)
    pool(new_node)%first_child = 0
    pool(new_node)%next_sibling = 0
  end function new_node

  subroutine append_child(parent, child)
    integer, intent(in) :: parent, child
    integer :: last
    pool(child)%next_sibling = 0
    if (pool(parent)%first_child == 0) then
      pool(parent)%first_child = child
    else
      last = pool(parent)%first_child
      do while (pool(last)%next_sibling /= 0)
        last = pool(last)%next_sibling
      end do
      pool(last)%next_sibling = child
    end if
  end subroutine append_child

  ! ---------------------------------------------------------------
  ! Parser internals
  ! ---------------------------------------------------------------
  subroutine skip_ws()
    character(len=1) :: c
    do while (pos <= len(src_text))
      c = src_text(pos:pos)
      if (c == ' ' .or. c == char(9) .or. c == char(10) .or. &
          c == char(13)) then
        pos = pos + 1
      else
        exit
      end if
    end do
  end subroutine skip_ws

  recursive function parse_value() result(idx)
    integer :: idx
    character(len=1) :: c
    call skip_ws()
    idx = 0
    if (pos > len(src_text)) then
      parse_error = .true.
      return
    end if
    c = src_text(pos:pos)
    select case (c)
    case ('{')
      idx = parse_object()
    case ('[')
      idx = parse_array()
    case ('"')
      idx = new_node()
      pool(idx)%kind = JSTR
      call parse_string_raw(pool(idx)%sval)
    case ('t')
      idx = new_node()
      pool(idx)%kind = JBOOL
      pool(idx)%bval = .true.
      if (src_text(pos:min(pos + 3, len(src_text))) == 'true') then
        pos = pos + 4
      else
        parse_error = .true.
      end if
    case ('f')
      idx = new_node()
      pool(idx)%kind = JBOOL
      pool(idx)%bval = .false.
      if (src_text(pos:min(pos + 4, len(src_text))) == 'false') then
        pos = pos + 5
      else
        parse_error = .true.
      end if
    case ('n')
      idx = new_node()
      pool(idx)%kind = JNULL
      if (src_text(pos:min(pos + 3, len(src_text))) == 'null') then
        pos = pos + 4
      else
        parse_error = .true.
      end if
    case default
      idx = parse_number()
    end select
  end function parse_value

  recursive function parse_object() result(idx)
    integer :: idx, child
    character(len=:), allocatable :: kstr
    idx = new_node()
    pool(idx)%kind = JOBJ
    pos = pos + 1  ! consume '{'
    call skip_ws()
    if (pos <= len(src_text)) then
      if (src_text(pos:pos) == '}') then
        pos = pos + 1
        return
      end if
    end if
    do
      call skip_ws()
      if (pos > len(src_text) .or. src_text(pos:pos) /= '"') then
        parse_error = .true.
        return
      end if
      call parse_string_raw(kstr)
      call skip_ws()
      if (pos > len(src_text) .or. src_text(pos:pos) /= ':') then
        parse_error = .true.
        return
      end if
      pos = pos + 1
      child = parse_value()
      if (child == 0) then
        parse_error = .true.
        return
      end if
      allocate(character(len=len(kstr)) :: pool(child)%key)
      pool(child)%key = kstr
      if (allocated(kstr)) deallocate(kstr)
      call append_child(idx, child)
      call skip_ws()
      if (pos > len(src_text)) then
        parse_error = .true.
        return
      end if
      if (src_text(pos:pos) == ',') then
        pos = pos + 1
      else if (src_text(pos:pos) == '}') then
        pos = pos + 1
        exit
      else
        parse_error = .true.
        return
      end if
    end do
  end function parse_object

  recursive function parse_array() result(idx)
    integer :: idx, child
    idx = new_node()
    pool(idx)%kind = JARR
    pos = pos + 1  ! consume '['
    call skip_ws()
    if (pos <= len(src_text)) then
      if (src_text(pos:pos) == ']') then
        pos = pos + 1
        return
      end if
    end if
    do
      child = parse_value()
      if (child == 0) then
        parse_error = .true.
        return
      end if
      call append_child(idx, child)
      call skip_ws()
      if (pos > len(src_text)) then
        parse_error = .true.
        return
      end if
      if (src_text(pos:pos) == ',') then
        pos = pos + 1
      else if (src_text(pos:pos) == ']') then
        pos = pos + 1
        exit
      else
        parse_error = .true.
        return
      end if
    end do
  end function parse_array

  function parse_number() result(idx)
    integer :: idx
    integer :: start, i
    logical :: neg
    integer(int64) :: val
    idx = new_node()
    pool(idx)%kind = JNUM
    start = pos
    neg = .false.
    if (pos <= len(src_text)) then
      if (src_text(pos:pos) == '-') then
        neg = .true.
        pos = pos + 1
      end if
    end if
    val = 0_int64
    do while (pos <= len(src_text))
      if (src_text(pos:pos) >= '0' .and. src_text(pos:pos) <= '9') then
        val = val * 10_int64 + int(iachar(src_text(pos:pos)) - 48, int64)
        pos = pos + 1
      else
        exit
      end if
    end do
    ! Skip any fraction / exponent; only the integer part is exposed.
    do while (pos <= len(src_text))
      if (src_text(pos:pos) == '.' .or. src_text(pos:pos) == 'e' .or. &
          src_text(pos:pos) == 'E' .or. src_text(pos:pos) == '+' .or. &
          src_text(pos:pos) == '-' .or. &
          (src_text(pos:pos) >= '0' .and. src_text(pos:pos) <= '9')) then
        pos = pos + 1
      else
        exit
      end if
    end do
    if (pos == start) parse_error = .true.
    if (neg) val = -val
    pool(idx)%ival = val
    i = idx  ! silence any unused-variable style concerns
  end function parse_number

  ! ---------------------------------------------------------------
  ! String decoding (pos is at the opening quote on entry).
  ! ---------------------------------------------------------------
  subroutine sbuf_reset()
    sbuf_n = 0
    if (.not. allocated(sbuf)) then
      allocate(sbuf(256))
      sbuf_cap = 256
    end if
  end subroutine sbuf_reset

  subroutine sbuf_push(c)
    character(len=1), intent(in) :: c
    character(len=1), allocatable :: nb(:)
    integer :: newcap
    if (sbuf_n >= sbuf_cap) then
      newcap = max(256, 2 * sbuf_cap)
      allocate(nb(newcap))
      if (sbuf_n > 0) nb(1:sbuf_n) = sbuf(1:sbuf_n)
      deallocate(sbuf)
      call move_alloc(nb, sbuf)
      sbuf_cap = newcap
    end if
    sbuf_n = sbuf_n + 1
    sbuf(sbuf_n) = c
  end subroutine sbuf_push

  subroutine sbuf_result(s)
    character(len=:), allocatable, intent(out) :: s
    integer :: i
    allocate(character(len=sbuf_n) :: s)
    do i = 1, sbuf_n
      s(i:i) = sbuf(i)
    end do
  end subroutine sbuf_result

  subroutine append_utf8(cp)
    integer, intent(in) :: cp
    if (cp < 128) then
      call sbuf_push(achar(cp))
    else if (cp < 2048) then
      call sbuf_push(achar(192 + cp / 64))
      call sbuf_push(achar(128 + mod(cp, 64)))
    else if (cp < 65536) then
      call sbuf_push(achar(224 + cp / 4096))
      call sbuf_push(achar(128 + mod(cp / 64, 64)))
      call sbuf_push(achar(128 + mod(cp, 64)))
    else
      call sbuf_push(achar(240 + cp / 262144))
      call sbuf_push(achar(128 + mod(cp / 4096, 64)))
      call sbuf_push(achar(128 + mod(cp / 64, 64)))
      call sbuf_push(achar(128 + mod(cp, 64)))
    end if
  end subroutine append_utf8

  integer function hex4()
    integer :: i, v, d
    hex4 = 0
    do i = 1, 4
      if (pos > len(src_text)) then
        parse_error = .true.
        return
      end if
      v = iachar(src_text(pos:pos))
      if (v >= 48 .and. v <= 57) then
        d = v - 48
      else if (v >= 97 .and. v <= 102) then
        d = v - 87
      else if (v >= 65 .and. v <= 70) then
        d = v - 55
      else
        parse_error = .true.
        return
      end if
      hex4 = hex4 * 16 + d
      pos = pos + 1
    end do
  end function hex4

  subroutine parse_string_raw(s)
    character(len=:), allocatable, intent(out) :: s
    character(len=1) :: c
    integer :: cp, lo
    call sbuf_reset()
    pos = pos + 1  ! consume opening quote
    do while (pos <= len(src_text))
      c = src_text(pos:pos)
      if (c == '"') then
        pos = pos + 1
        call sbuf_result(s)
        return
      else if (c == '\') then
        pos = pos + 1
        if (pos > len(src_text)) then
          parse_error = .true.
          exit
        end if
        c = src_text(pos:pos)
        pos = pos + 1
        select case (c)
        case ('"')
          call sbuf_push('"')
        case ('\')
          call sbuf_push('\')
        case ('/')
          call sbuf_push('/')
        case ('b')
          call sbuf_push(char(8))
        case ('f')
          call sbuf_push(char(12))
        case ('n')
          call sbuf_push(char(10))
        case ('r')
          call sbuf_push(char(13))
        case ('t')
          call sbuf_push(char(9))
        case ('u')
          cp = hex4()
          if (cp >= 55296 .and. cp <= 56319) then
            ! High surrogate: expect a following \uXXXX low surrogate.
            if (pos + 1 <= len(src_text)) then
              if (src_text(pos:pos) == '\' .and. &
                  src_text(pos + 1:pos + 1) == 'u') then
                pos = pos + 2
                lo = hex4()
                cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
              end if
            end if
          end if
          call append_utf8(cp)
        case default
          parse_error = .true.
          call sbuf_push(c)
        end select
      else
        call sbuf_push(c)
        pos = pos + 1
      end if
    end do
    parse_error = .true.
    call sbuf_result(s)
  end subroutine parse_string_raw

end module json_parse
