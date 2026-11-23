! f3dc_str.f90 -- string helpers, growable lists, path helpers, and the
! byte-parity number formatters (fmt_int / fmt_real) for the native
! Forge3D compiler.  Port contract: compiler/DESIGN.md.
!
! Conventions:
!   * All strings are character(len=:), allocatable.
!   * Index-returning helpers are 1-based, 0 = not found (Fortran style).
!   * fmt_real reproduces Python repr(float) exactly (see DESIGN.md).
module f3dc_str
  use, intrinsic :: iso_fortran_env, only: int64, real64
  use, intrinsic :: ieee_arithmetic, only: ieee_is_nan, ieee_is_finite, &
                                           ieee_is_negative
  implicit none
  private

  public :: str_box
  public :: char_list, real_list, int_list
  public :: char_list_append, char_list_len, char_list_at, char_list_clear
  public :: real_list_append, real_list_len, real_list_at, real_list_clear
  public :: int_list_append, int_list_len, int_list_at, int_list_clear
  public :: str_concat, str_concat3, str_eq, str_eq_trim
  public :: starts_with, ends_with
  public :: to_lower, to_upper
  public :: str_split, str_join, str_contains, str_replace
  public :: str_index, str_last_index, str_count
  public :: str_repeat, str_pad_left
  public :: path_basename, path_stem, path_dirname, path_extension
  public :: fmt_int, fmt_real

  !> Boxed string: element type for arrays of allocatable strings.
  type :: str_box
    character(len=:), allocatable :: s
  end type str_box

  !> Growable list of strings.
  type :: char_list
    type(str_box), allocatable :: items(:)
    integer :: n = 0
    integer :: cap = 0
  end type char_list

  !> Growable list of real64.
  type :: real_list
    real(real64), allocatable :: items(:)
    integer :: n = 0
    integer :: cap = 0
  end type real_list

  !> Growable list of int64.
  type :: int_list
    integer(int64), allocatable :: items(:)
    integer :: n = 0
    integer :: cap = 0
  end type int_list

contains

  ! ------------------------------------------------------------------
  ! Growable lists
  ! ------------------------------------------------------------------

  subroutine char_list_append(list, value)
    type(char_list), intent(inout) :: list
    character(len=*), intent(in) :: value
    type(str_box), allocatable :: tmp(:)
    integer :: newcap, i
    if (list%n >= list%cap) then
      newcap = max(4, 2 * list%cap)
      allocate (tmp(newcap))
      do i = 1, list%n
        if (allocated(list%items(i)%s)) tmp(i)%s = list%items(i)%s
      end do
      call move_alloc(tmp, list%items)
      list%cap = newcap
    end if
    list%n = list%n + 1
    list%items(list%n)%s = value
  end subroutine char_list_append

  pure integer function char_list_len(list)
    type(char_list), intent(in) :: list
    char_list_len = list%n
  end function char_list_len

  !> 1-based element access; "" when out of range.
  function char_list_at(list, idx) result(out)
    type(char_list), intent(in) :: list
    integer, intent(in) :: idx
    character(len=:), allocatable :: out
    if (idx < 1 .or. idx > list%n) then
      out = ""
    else if (allocated(list%items(idx)%s)) then
      out = list%items(idx)%s
    else
      out = ""
    end if
  end function char_list_at

  subroutine char_list_clear(list)
    type(char_list), intent(inout) :: list
    if (allocated(list%items)) deallocate (list%items)
    list%n = 0
    list%cap = 0
  end subroutine char_list_clear

  subroutine real_list_append(list, value)
    type(real_list), intent(inout) :: list
    real(real64), intent(in) :: value
    real(real64), allocatable :: tmp(:)
    integer :: newcap
    if (list%n >= list%cap) then
      newcap = max(4, 2 * list%cap)
      allocate (tmp(newcap))
      if (list%n > 0) tmp(1:list%n) = list%items(1:list%n)
      call move_alloc(tmp, list%items)
      list%cap = newcap
    end if
    list%n = list%n + 1
    list%items(list%n) = value
  end subroutine real_list_append

  pure integer function real_list_len(list)
    type(real_list), intent(in) :: list
    real_list_len = list%n
  end function real_list_len

  !> 1-based element access; 0.0 when out of range.
  pure real(real64) function real_list_at(list, idx)
    type(real_list), intent(in) :: list
    integer, intent(in) :: idx
    if (idx < 1 .or. idx > list%n) then
      real_list_at = 0.0_real64
    else
      real_list_at = list%items(idx)
    end if
  end function real_list_at

  subroutine real_list_clear(list)
    type(real_list), intent(inout) :: list
    if (allocated(list%items)) deallocate (list%items)
    list%n = 0
    list%cap = 0
  end subroutine real_list_clear

  subroutine int_list_append(list, value)
    type(int_list), intent(inout) :: list
    integer(int64), intent(in) :: value
    integer(int64), allocatable :: tmp(:)
    integer :: newcap
    if (list%n >= list%cap) then
      newcap = max(4, 2 * list%cap)
      allocate (tmp(newcap))
      if (list%n > 0) tmp(1:list%n) = list%items(1:list%n)
      call move_alloc(tmp, list%items)
      list%cap = newcap
    end if
    list%n = list%n + 1
    list%items(list%n) = value
  end subroutine int_list_append

  pure integer function int_list_len(list)
    type(int_list), intent(in) :: list
    int_list_len = list%n
  end function int_list_len

  !> 1-based element access; 0 when out of range.
  pure integer(int64) function int_list_at(list, idx)
    type(int_list), intent(in) :: list
    integer, intent(in) :: idx
    if (idx < 1 .or. idx > list%n) then
      int_list_at = 0_int64
    else
      int_list_at = list%items(idx)
    end if
  end function int_list_at

  subroutine int_list_clear(list)
    type(int_list), intent(inout) :: list
    if (allocated(list%items)) deallocate (list%items)
    list%n = 0
    list%cap = 0
  end subroutine int_list_clear

  ! ------------------------------------------------------------------
  ! Basic string helpers
  ! ------------------------------------------------------------------

  function str_concat(a, b) result(out)
    character(len=*), intent(in) :: a, b
    character(len=:), allocatable :: out
    out = a // b
  end function str_concat

  function str_concat3(a, b, c) result(out)
    character(len=*), intent(in) :: a, b, c
    character(len=:), allocatable :: out
    out = a // b // c
  end function str_concat3

  !> Exact equality of the full (unpadded) strings.
  pure logical function str_eq(a, b)
    character(len=*), intent(in) :: a, b
    str_eq = (len(a) == len(b)) .and. (a == b)
  end function str_eq

  !> Trim-based equality: trailing blanks ignored on both sides.
  pure logical function str_eq_trim(a, b)
    character(len=*), intent(in) :: a, b
    str_eq_trim = (len_trim(a) == len_trim(b)) .and. &
                  (a(1:len_trim(a)) == b(1:len_trim(b)))
  end function str_eq_trim

  pure logical function starts_with(s, prefix)
    character(len=*), intent(in) :: s, prefix
    if (len(prefix) > len(s)) then
      starts_with = .false.
    else
      starts_with = (s(1:len(prefix)) == prefix)
    end if
  end function starts_with

  pure logical function ends_with(s, suffix)
    character(len=*), intent(in) :: s, suffix
    if (len(suffix) > len(s)) then
      ends_with = .false.
    else
      ends_with = (s(len(s) - len(suffix) + 1:len(s)) == suffix)
    end if
  end function ends_with

  function to_lower(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i, c
    allocate (character(len=len(s)) :: out)
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (c >= iachar("A") .and. c <= iachar("Z")) then
        out(i:i) = achar(c - iachar("A") + iachar("a"))
      else
        out(i:i) = s(i:i)
      end if
    end do
  end function to_lower

  function to_upper(s) result(out)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: out
    integer :: i, c
    allocate (character(len=len(s)) :: out)
    do i = 1, len(s)
      c = iachar(s(i:i))
      if (c >= iachar("a") .and. c <= iachar("z")) then
        out(i:i) = achar(c - iachar("a") + iachar("A"))
      else
        out(i:i) = s(i:i)
      end if
    end do
  end function to_upper

  !> First 1-based index of needle in s, 0 when absent (index helper).
  pure integer function str_index(s, needle)
    character(len=*), intent(in) :: s, needle
    str_index = index(s, needle)
  end function str_index

  !> Last 1-based index of needle in s, 0 when absent.
  pure integer function str_last_index(s, needle)
    character(len=*), intent(in) :: s, needle
    str_last_index = index(s, needle, back=.true.)
  end function str_last_index

  pure logical function str_contains(s, needle)
    character(len=*), intent(in) :: s, needle
    str_contains = index(s, needle) > 0
  end function str_contains

  !> Number of non-overlapping occurrences of needle in s.
  pure integer function str_count(s, needle)
    character(len=*), intent(in) :: s, needle
    integer :: pos, cnt
    cnt = 0
    if (len(needle) == 0) then
      str_count = 0
      return
    end if
    pos = 1
    do while (pos <= len(s))
      if (index(s(pos:), needle) == 0) exit
      pos = pos + index(s(pos:), needle) + len(needle) - 1
      cnt = cnt + 1
    end do
    str_count = cnt
  end function str_count

  function str_repeat(s, count) result(out)
    character(len=*), intent(in) :: s
    integer, intent(in) :: count
    character(len=:), allocatable :: out
    integer :: i
    allocate (character(len=len(s) * max(0, count)) :: out)
    do i = 1, max(0, count)
      out((i - 1) * len(s) + 1:i * len(s)) = s
    end do
  end function str_repeat

  !> Left-pad with blanks to width (no truncation), like Fortran adjust.
  function str_pad_left(s, width) result(out)
    character(len=*), intent(in) :: s
    integer, intent(in) :: width
    character(len=:), allocatable :: out
    if (len(s) >= width) then
      out = s
    else
      out = repeat(" ", width - len(s)) // s
    end if
  end function str_pad_left

  !> Split s on every occurrence of sep (Python str.split(sep) semantics:
  !! empty fields are kept; an empty separator splits into characters,
  !! matching Python only in the non-empty-sep case -- see report).
  subroutine str_split(s, sep, parts)
    character(len=*), intent(in) :: s, sep
    type(char_list), intent(inout) :: parts
    integer :: start, hit
    call char_list_clear(parts)
    if (len(sep) == 0) then
      block
        integer :: i
        do i = 1, len(s)
          call char_list_append(parts, s(i:i))
        end do
      end block
      return
    end if
    start = 1
    do
      if (start > len(s)) then
        call char_list_append(parts, "")
        exit
      end if
      hit = index(s(start:), sep)
      if (hit == 0) then
        call char_list_append(parts, s(start:))
        exit
      end if
      call char_list_append(parts, s(start:start + hit - 2))
      start = start + hit - 1 + len(sep)
      if (start > len(s) + 1) exit
      if (start == len(s) + 1) then
        call char_list_append(parts, "")
        exit
      end if
    end do
  end subroutine str_split

  !> Join list elements with sep between them (Python sep.join).
  function str_join(parts, sep) result(out)
    type(char_list), intent(in) :: parts
    character(len=*), intent(in) :: sep
    character(len=:), allocatable :: out
    integer :: i, total
    total = 0
    do i = 1, parts%n
      total = total + len(char_list_at(parts, i))
    end do
    if (parts%n > 1) total = total + len(sep) * (parts%n - 1)
    allocate (character(len=total) :: out)
    block
      integer :: pos
      pos = 1
      do i = 1, parts%n
        block
          character(len=:), allocatable :: piece
          piece = char_list_at(parts, i)
          if (len(piece) > 0) out(pos:pos + len(piece) - 1) = piece
          pos = pos + len(piece)
          if (i < parts%n) then
            if (len(sep) > 0) out(pos:pos + len(sep) - 1) = sep
            pos = pos + len(sep)
          end if
        end block
      end do
    end block
  end function str_join

  !> Replace every non-overlapping occurrence of old with new
  !! (Python str.replace with no count limit).
  function str_replace(s, old, new) result(out)
    character(len=*), intent(in) :: s, old, new
    character(len=:), allocatable :: out
    integer :: pos, hit
    out = ""
    if (len(old) == 0) then
      out = s
      return
    end if
    pos = 1
    do while (pos <= len(s))
      hit = index(s(pos:), old)
      if (hit == 0) then
        out = out // s(pos:)
        return
      end if
      if (hit > 1) out = out // s(pos:pos + hit - 2)
      out = out // new
      pos = pos + hit - 1 + len(old)
    end do
  end function str_replace

  ! ------------------------------------------------------------------
  ! Path helpers ('/' separator, mirroring pathlib on POSIX)
  ! ------------------------------------------------------------------

  !> Everything after the last '/' (the whole string when there is none).
  function path_basename(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    integer :: slash
    slash = index(path, "/", back=.true.)
    if (slash == 0) then
      out = path
    else
      out = path(slash + 1:)
    end if
  end function path_basename

  !> Everything before the last '/', or "." when there is none
  !! (pathlib Path.parent semantics for a bare file name).
  function path_dirname(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    integer :: slash
    slash = index(path, "/", back=.true.)
    if (slash == 0) then
      out = "."
    else if (slash == 1) then
      out = "/"
    else
      out = path(1:slash - 1)
    end if
  end function path_dirname

  !> Final suffix including the dot (pathlib Path.suffix), "" when the
  !! basename has no dot or starts with its only dot.
  function path_extension(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    character(len=:), allocatable :: base
    integer :: dot
    base = path_basename(path)
    dot = index(base, ".", back=.true.)
    if (dot <= 1) then
      out = ""
    else
      out = base(dot:)
    end if
  end function path_extension

  !> Basename without its final suffix (pathlib Path.stem).
  function path_stem(path) result(out)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: out
    character(len=:), allocatable :: base, ext
    base = path_basename(path)
    ext = path_extension(path)
    if (len(ext) == 0) then
      out = base
    else
      out = base(1:len(base) - len(ext))
    end if
  end function path_stem

  ! ------------------------------------------------------------------
  ! Number formatting -- byte parity with Python
  ! ------------------------------------------------------------------

  !> Python str(int) for int64.
  function fmt_int(x) result(out)
    integer(int64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=32) :: buf
    integer :: n
    write (buf, "(I0)") x
    n = len_trim(buf)
    out = buf(1:n)
  end function fmt_int

  !> Python repr(float) exactly, per DESIGN.md:
  !! shortest round-tripping digit string; fixed notation for
  !! -4 <= decimal_exp < 16 with ".0" appended for integral values,
  !! else scientific d.dddde<sign>XX (exponent >= 2 digits, sign always).
  !! decimal_exp here is the exponent of the first significant digit
  !! (value = d.ddd * 10**decimal_exp).
  function fmt_real(x) result(out)
    real(real64), intent(in) :: x
    character(len=:), allocatable :: out
    character(len=64) :: buf, fmtstr
    character(len=32) :: digits
    integer :: p, ndig, dec_exp, ios, i, j, epos
    real(real64) :: back
    integer(int64) :: xbits, bbits
    logical :: neg

    if (ieee_is_nan(x)) then
      out = "nan"
      return
    end if
    if (.not. ieee_is_finite(x)) then
      if (ieee_is_negative(x)) then
        out = "-inf"
      else
        out = "inf"
      end if
      return
    end if
    if (x == 0.0_real64) then
      if (ieee_is_negative(x)) then
        out = "-0.0"
      else
        out = "0.0"
      end if
      return
    end if

    neg = ieee_is_negative(x)
    xbits = transfer(x, 0_int64)

    ! Find the shortest correctly-rounded digit string that round-trips.
    digits = ""
    ndig = 17
    dec_exp = 0
    do p = 1, 17
      write (fmtstr, "(A,I0,A,I0,A)") "(ES", p + 12, ".", p - 1, "E3)"
      write (buf, fmtstr) x
      read (buf, *, iostat=ios) back
      if (ios /= 0) cycle
      bbits = transfer(back, 0_int64)
      if (bbits == xbits) then
        ndig = p
        ! Parse mantissa digits and exponent out of buf.
        epos = index(buf, "E")
        digits = ""
        j = 0
        do i = 1, epos - 1
          if (buf(i:i) >= "0" .and. buf(i:i) <= "9") then
            j = j + 1
            digits(j:j) = buf(i:i)
          end if
        end do
        read (buf(epos + 1:), *) dec_exp
        exit
      end if
    end do
    if (digits(1:1) == " ") then
      ! No precision round-tripped (should not happen for real64 at 17).
      write (fmtstr, "(A)") "(ES25.16E3)"
      write (buf, fmtstr) x
      epos = index(buf, "E")
      digits = ""
      j = 0
      do i = 1, epos - 1
        if (buf(i:i) >= "0" .and. buf(i:i) <= "9") then
          j = j + 1
          digits(j:j) = buf(i:i)
        end if
      end do
      ndig = 17
      read (buf(epos + 1:), *) dec_exp
    end if
    ! Trailing zeros in the digit string carry no information (the
    ! shortest search already ran, but a 17-digit fallback may pad).
    do while (ndig > 1 .and. digits(ndig:ndig) == "0")
      ndig = ndig - 1
    end do

    out = render_python_float(neg, digits(1:ndig), ndig, dec_exp)
  end function fmt_real

  !> Render sign + digit string + decimal exponent in Python repr style.
  function render_python_float(neg, digits, ndig, dec_exp) result(out)
    logical, intent(in) :: neg
    character(len=*), intent(in) :: digits
    integer, intent(in) :: ndig, dec_exp
    character(len=:), allocatable :: out, body
    character(len=16) :: ebuf
    integer :: i

    if (dec_exp >= -4 .and. dec_exp < 16) then
      if (dec_exp >= 0) then
        if (ndig > dec_exp + 1) then
          ! Digits on both sides of the point.
          body = digits(1:dec_exp + 1) // "." // digits(dec_exp + 2:ndig)
        else
          ! Integral value: zero-pad, then append ".0".
          body = digits(1:ndig) // repeat("0", dec_exp + 1 - ndig) // ".0"
        end if
      else
        body = "0." // repeat("0", -dec_exp - 1) // digits(1:ndig)
      end if
    else
      if (ndig > 1) then
        body = digits(1:1) // "." // digits(2:ndig)
      else
        body = digits(1:1)
      end if
      if (dec_exp >= 0) then
        write (ebuf, "(A,I0)") "e+", dec_exp
      else
        write (ebuf, "(A,I0)") "e-", -dec_exp
      end if
      ! Python pads the exponent to at least two digits.
      i = index(ebuf, "e")
      block
        character(len=:), allocatable :: enum
        enum = ebuf(i + 2:len_trim(ebuf))
        if (len(enum) < 2) enum = "0" // enum
        body = body // ebuf(1:i + 1) // enum
      end block
    end if
    if (neg) then
      out = "-" // body
    else
      out = body
    end if
  end function render_python_float

end module f3dc_str
