! json_read.f90 -- minimal JSON reader for Forge3D parity_matrix.f90.
!
! Parses a JSON text whose top level is an object mapping string keys to
! values.  Object values have their members captured (string members are
! decoded, including \" \\ \/ \b \f \n \r \t and \uXXXX escapes with
! surrogate pairs, re-encoded as UTF-8; non-string members are captured
! as their raw JSON token text).  Non-object top-level values are noted
! (null vs. other) and skipped with full string/bracket awareness.
!
! This is not a general JSON library: it implements exactly what
! parity_matrix needs to read docs/parity-status.json (which also
! carries a numeric "_baseline_pct" member that must be skipped).
module json_read
  implicit none
  private

  integer, parameter, public :: JR_MAX_ENTRIES = 512
  integer, parameter, public :: JR_MAX_FIELDS  = 64

  type, public :: jr_field
    character(len=:), allocatable :: name
    character(len=:), allocatable :: value   ! decoded if is_string, else raw token
    logical :: is_string = .false.
    logical :: present   = .false.
  end type jr_field

  type, public :: jr_entry
    character(len=:), allocatable :: key
    logical :: is_object = .false.
    logical :: is_null   = .false.
    integer :: nfields   = 0
    type(jr_field) :: fields(JR_MAX_FIELDS)
  end type jr_entry

  type, public :: jr_doc
    logical :: ok = .false.
    logical :: is_object = .false.
    integer :: nentries = 0
    type(jr_entry) :: entries(JR_MAX_ENTRIES)
    character(len=:), allocatable :: error
  end type jr_doc

  public :: jr_parse, jr_find_entry, jr_find_field

  type :: parser
    character(len=:), allocatable :: text
    integer :: pos = 1
    integer :: len = 0
    logical :: err = .false.
  end type parser

contains

  !-- small string helpers ------------------------------------------------

  subroutine str_append(s, chunk)
    character(len=:), allocatable, intent(inout) :: s
    character(len=*), intent(in) :: chunk
    if (allocated(s)) then
      s = s // chunk
    else
      s = chunk
    end if
  end subroutine str_append

  subroutine append_codepoint(s, cp)
    character(len=:), allocatable, intent(inout) :: s
    integer, intent(in) :: cp
    character(len=4) :: buf
    integer :: n
    if (cp < 128) then
      buf(1:1) = achar(cp); n = 1
    else if (cp < 2048) then
      buf(1:1) = achar(192 + cp / 64)
      buf(2:2) = achar(128 + mod(cp, 64)); n = 2
    else if (cp < 65536) then
      buf(1:1) = achar(224 + cp / 4096)
      buf(2:2) = achar(128 + mod(cp / 64, 64))
      buf(3:3) = achar(128 + mod(cp, 64)); n = 3
    else
      buf(1:1) = achar(240 + cp / 262144)
      buf(2:2) = achar(128 + mod(cp / 4096, 64))
      buf(3:3) = achar(128 + mod(cp / 64, 64))
      buf(4:4) = achar(128 + mod(cp, 64)); n = 4
    end if
    call str_append(s, buf(1:n))
  end subroutine append_codepoint

  !-- parser primitives ---------------------------------------------------

  subroutine skip_ws(p)
    type(parser), intent(inout) :: p
    integer :: c
    do while (p%pos <= p%len)
      c = iachar(p%text(p%pos:p%pos))
      if (c == 32 .or. c == 9 .or. c == 10 .or. c == 13) then
        p%pos = p%pos + 1
      else
        exit
      end if
    end do
  end subroutine skip_ws

  function peek(p) result(c)
    type(parser), intent(in) :: p
    character :: c
    if (p%pos <= p%len) then
      c = p%text(p%pos:p%pos)
    else
      c = achar(0)
    end if
  end function peek

  function hexval(c) result(v)
    character, intent(in) :: c
    integer :: v, i
    i = iachar(c)
    if (i >= iachar('0') .and. i <= iachar('9')) then
      v = i - iachar('0')
    else if (i >= iachar('a') .and. i <= iachar('f')) then
      v = i - iachar('a') + 10
    else if (i >= iachar('A') .and. i <= iachar('F')) then
      v = i - iachar('A') + 10
    else
      v = -1
    end if
  end function hexval

  ! Parse a \uXXXX escape; p%pos is just past the 'u'.  Returns codepoint.
  function parse_hex4(p) result(cp)
    type(parser), intent(inout) :: p
    integer :: cp, i, v
    cp = -1
    if (p%pos + 3 > p%len) then
      p%err = .true.
      return
    end if
    cp = 0
    do i = 0, 3
      v = hexval(p%text(p%pos + i:p%pos + i))
      if (v < 0) then
        p%err = .true.
        cp = -1
        return
      end if
      cp = cp * 16 + v
    end do
    p%pos = p%pos + 4
  end function parse_hex4

  ! Parse a JSON string at p%pos (must be '"'); decoded text in out.
  subroutine parse_string(p, out)
    type(parser), intent(inout) :: p
    character(len=:), allocatable, intent(out) :: out
    integer :: c, cp, cp2, start
    out = ""
    if (peek(p) /= '"') then
      p%err = .true.
      return
    end if
    p%pos = p%pos + 1
    do while (p%pos <= p%len)
      c = iachar(p%text(p%pos:p%pos))
      if (c == iachar('"')) then
        p%pos = p%pos + 1
        return
      else if (c == iachar('\')) then
        p%pos = p%pos + 1
        if (p%pos > p%len) then
          p%err = .true.
          return
        end if
        select case (p%text(p%pos:p%pos))
        case ('"')
          call str_append(out, '"'); p%pos = p%pos + 1
        case ('\')
          call str_append(out, '\'); p%pos = p%pos + 1
        case ('/')
          call str_append(out, '/'); p%pos = p%pos + 1
        case ('b')
          call str_append(out, achar(8)); p%pos = p%pos + 1
        case ('f')
          call str_append(out, achar(12)); p%pos = p%pos + 1
        case ('n')
          call str_append(out, achar(10)); p%pos = p%pos + 1
        case ('r')
          call str_append(out, achar(13)); p%pos = p%pos + 1
        case ('t')
          call str_append(out, achar(9)); p%pos = p%pos + 1
        case ('u')
          p%pos = p%pos + 1
          cp = parse_hex4(p)
          if (p%err) return
          if (cp >= 55296 .and. cp <= 56319) then
            ! High surrogate: try to pair with a following \uXXXX low one.
            start = p%pos
            if (p%pos + 5 <= p%len) then
              if (p%text(p%pos:p%pos) == '\' .and. &
                  p%text(p%pos + 1:p%pos + 1) == 'u') then
                p%pos = p%pos + 2
                cp2 = parse_hex4(p)
                if (.not. p%err .and. cp2 >= 56320 .and. cp2 <= 57343) then
                  cp = 65536 + (cp - 55296) * 1024 + (cp2 - 56320)
                else
                  p%err = .false.
                  p%pos = start
                  cp = 65533  ! unpaired surrogate -> replacement char
                end if
              else
                cp = 65533
              end if
            else
              cp = 65533
            end if
          else if (cp >= 56320 .and. cp <= 57343) then
            cp = 65533  ! lone low surrogate
          end if
          call append_codepoint(out, cp)
        case default
          p%err = .true.
          return
        end select
      else
        ! Raw byte (UTF-8 passes through unchanged, as in Python).
        call str_append(out, p%text(p%pos:p%pos))
        p%pos = p%pos + 1
      end if
    end do
    p%err = .true.  ! unterminated string
  end subroutine parse_string

  ! Skip any JSON value; if raw_from/raw_to are present, also report the
  ! source span of the value (excluding surrounding whitespace).
  recursive subroutine skip_value(p, raw_from, raw_to)
    type(parser), intent(inout) :: p
    integer, intent(out), optional :: raw_from, raw_to
    integer :: depth, c
    character(len=:), allocatable :: dummy
    call skip_ws(p)
    if (present(raw_from)) raw_from = p%pos
    if (p%pos > p%len) then
      p%err = .true.
      return
    end if
    select case (peek(p))
    case ('"')
      call parse_string(p, dummy)
    case ('{', '[')
      depth = 0
      do while (p%pos <= p%len)
        c = iachar(p%text(p%pos:p%pos))
        if (c == iachar('"')) then
          call parse_string(p, dummy)
          if (p%err) return
          cycle
        end if
        if (c == iachar('{') .or. c == iachar('[')) depth = depth + 1
        if (c == iachar('}') .or. c == iachar(']')) then
          depth = depth - 1
          p%pos = p%pos + 1
          if (depth == 0) exit
          cycle
        end if
        p%pos = p%pos + 1
      end do
      if (depth /= 0) p%err = .true.
    case default
      ! number / true / false / null token
      do while (p%pos <= p%len)
        c = iachar(p%text(p%pos:p%pos))
        if (c == 32 .or. c == 9 .or. c == 10 .or. c == 13 .or. &
            c == iachar(',') .or. c == iachar('}') .or. c == iachar(']')) exit
        p%pos = p%pos + 1
      end do
    end select
    if (present(raw_to)) raw_to = p%pos - 1
  end subroutine skip_value

  ! Parse an object value into entry%fields.  p%pos is at '{'.
  subroutine parse_object_fields(p, entry)
    type(parser), intent(inout) :: p
    type(jr_entry), intent(inout) :: entry
    character(len=:), allocatable :: fname, fval
    integer :: raw_from, raw_to
    entry%nfields = 0
    p%pos = p%pos + 1  ! consume '{'
    call skip_ws(p)
    if (peek(p) == '}') then
      p%pos = p%pos + 1
      return
    end if
    do
      call skip_ws(p)
      call parse_string(p, fname)
      if (p%err) return
      call skip_ws(p)
      if (peek(p) /= ':') then
        p%err = .true.
        return
      end if
      p%pos = p%pos + 1
      call skip_ws(p)
      if (entry%nfields < JR_MAX_FIELDS) entry%nfields = entry%nfields + 1
      entry%fields(entry%nfields)%name = fname
      entry%fields(entry%nfields)%present = .true.
      if (peek(p) == '"') then
        call parse_string(p, fval)
        if (p%err) return
        entry%fields(entry%nfields)%value = fval
        entry%fields(entry%nfields)%is_string = .true.
      else
        call skip_value(p, raw_from, raw_to)
        if (p%err) return
        if (raw_to >= raw_from) then
          entry%fields(entry%nfields)%value = p%text(raw_from:raw_to)
        else
          entry%fields(entry%nfields)%value = ""
        end if
        entry%fields(entry%nfields)%is_string = .false.
      end if
      call skip_ws(p)
      if (peek(p) == ',') then
        p%pos = p%pos + 1
        cycle
      else if (peek(p) == '}') then
        p%pos = p%pos + 1
        exit
      else
        p%err = .true.
        return
      end if
    end do
  end subroutine parse_object_fields

  !-- public API ------------------------------------------------------------

  subroutine jr_parse(text, doc)
    character(len=*), intent(in) :: text
    type(jr_doc), intent(out) :: doc
    type(parser) :: p
    character(len=:), allocatable :: key
    integer :: save_pos

    doc%ok = .false.
    doc%is_object = .false.
    doc%nentries = 0
    p%text = text
    p%len = len(text)
    p%pos = 1
    p%err = .false.

    call skip_ws(p)
    if (peek(p) /= '{') then
      doc%error = "top level is not a JSON object"
      return
    end if
    doc%is_object = .true.
    p%pos = p%pos + 1
    call skip_ws(p)
    if (peek(p) == '}') then
      doc%ok = .true.
      return
    end if
    do
      call skip_ws(p)
      call parse_string(p, key)
      if (p%err) exit
      call skip_ws(p)
      if (peek(p) /= ':') then
        p%err = .true.
        exit
      end if
      p%pos = p%pos + 1
      call skip_ws(p)
      if (doc%nentries < JR_MAX_ENTRIES) doc%nentries = doc%nentries + 1
      doc%entries(doc%nentries)%key = key
      if (peek(p) == '{') then
        doc%entries(doc%nentries)%is_object = .true.
        call parse_object_fields(p, doc%entries(doc%nentries))
        if (p%err) exit
      else
        save_pos = p%pos
        call skip_value(p)
        if (p%err) exit
        if (p%text(save_pos:min(save_pos + 3, p%len)) == "null") &
          doc%entries(doc%nentries)%is_null = .true.
      end if
      call skip_ws(p)
      if (peek(p) == ',') then
        p%pos = p%pos + 1
        cycle
      else if (peek(p) == '}') then
        p%pos = p%pos + 1
        exit
      else
        p%err = .true.
        exit
      end if
    end do
    if (p%err) then
      doc%error = "invalid JSON"
      doc%nentries = 0
      return
    end if
    doc%ok = .true.
  end subroutine jr_parse

  function jr_find_entry(doc, key) result(idx)
    type(jr_doc), intent(in) :: doc
    character(len=*), intent(in) :: key
    integer :: idx, i
    idx = 0
    do i = 1, doc%nentries
      if (allocated(doc%entries(i)%key)) then
        if (doc%entries(i)%key == key) then
          idx = i
          return
        end if
      end if
    end do
  end function jr_find_entry

  function jr_find_field(entry, name) result(idx)
    type(jr_entry), intent(in) :: entry
    character(len=*), intent(in) :: name
    integer :: idx, i
    idx = 0
    do i = 1, entry%nfields
      if (entry%fields(i)%present) then
        if (allocated(entry%fields(i)%name)) then
          if (entry%fields(i)%name == name) then
            idx = i
            return
          end if
        end if
      end if
    end do
  end function jr_find_field

end module json_read
