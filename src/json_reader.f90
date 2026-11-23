! json_reader.f90 -- shared JSON parser for the Forge3D engine
! (v3.0 Phase 1, finding G2).  Module json_reader_3d.
!
! One proper JSON parser for the whole engine, replacing the ad-hoc
! text scanners the loaders used before.  Full JSON: objects, arrays,
! strings with all escapes (including \uXXXX -> UTF-8, with surrogate
! pairs), numbers, true / false / null and insignificant whitespace.
!
! Storage model (node pool):
!   A document is a flat pool of json_node values (doc%nodes), grown
!   by capacity doubling -- there are no fixed caps on the number of
!   nodes or children.  doc%n is the number of live nodes and doc%root
!   the pool index (1-based) of the root value; 0 means "no node".
!   Children of an array or object are chained through first_child /
!   next_sibling; every child points back through parent.
!
!   OBJECT CHILDREN: the children of an object node are the member
!   VALUE nodes, and each such child's `s` component holds the member
!   KEY (not the value).  That is the documented convention of this
!   API: iterate an object's children and read the key from child%s,
!   the value from the child's kind/num/b/first_child.  One refinement
!   is needed so string values are not lost: when an object member's
!   value is itself a string, the member node's `s` still holds the
!   key, and the string value is kept in a hidden extra node chained
!   as the member's first_child.  json_str() resolves this
!   transparently -- json_str(doc, member) returns the member's string
!   value -- so callers never need to know about the hidden node.
!   (String elements of arrays, and a string root, hold their value
!   directly in `s`, as usual.)
!
! Numbers are stored as real64; json_int rounds via nint and clamps
! to the default-integer range.
!
! Errors: json_parse returns ok=.false. and an errmsg carrying the
! 1-based byte offset at which parsing failed.
module json_reader_3d
    use, intrinsic :: iso_fortran_env, only: real64, int64
    implicit none
    private

    public :: json_doc, json_node
    public :: json_parse, json_free
    public :: json_kind, json_num, json_int, json_bool, json_str
    public :: json_obj_get, json_obj_count, json_arr_len, json_arr_at

    ! Node kinds (values of json_node%kind / json_kind()).
    integer, parameter :: K_NULL = 0
    integer, parameter :: K_BOOL = 1
    integer, parameter :: K_NUM  = 2
    integer, parameter :: K_STR  = 3
    integer, parameter :: K_ARR  = 4
    integer, parameter :: K_OBJ  = 5

    type, public :: json_node
        integer :: kind = 0          ! 0 null, 1 bool, 2 num, 3 str, 4 arr, 5 obj
        logical :: b = .false.
        real(real64) :: num = 0.0_real64
        character(len=:), allocatable :: s  ! string value; for obj children: the key
        integer :: first_child = 0, next_sibling = 0, parent = 0
    end type json_node

    type, public :: json_doc
        type(json_node), allocatable :: nodes(:)  ! node pool, capacity-doubling
        integer :: n = 0
        integer :: root = 0
    end type json_doc

    ! Parser cursor (module state; json_parse is not re-entrant, which
    ! is fine for the engine's single-threaded loaders).
    character(len=:), allocatable :: p_text
    integer :: p_pos, p_len
    character(len=256) :: p_err

contains

    ! ----------------------------------------------------------------
    ! Pool management
    ! ----------------------------------------------------------------

    subroutine pool_init(doc)
        type(json_doc), intent(inout) :: doc
        if (allocated(doc%nodes)) deallocate(doc%nodes)
        allocate(doc%nodes(64))
        doc%n = 0
        doc%root = 0
    end subroutine pool_init

    function pool_add(doc) result(idx)
        type(json_doc), intent(inout) :: doc
        integer :: idx
        type(json_node), allocatable :: tmp(:)
        integer :: cap, new_cap
        cap = 0
        if (allocated(doc%nodes)) cap = size(doc%nodes)
        if (doc%n >= cap) then
            new_cap = max(64, 2 * cap)
            allocate(tmp(new_cap))
            if (doc%n > 0) tmp(1:doc%n) = doc%nodes(1:doc%n)
            if (allocated(doc%nodes)) deallocate(doc%nodes)
            call move_alloc(tmp, doc%nodes)
        end if
        doc%n = doc%n + 1
        idx = doc%n
        doc%nodes(idx) = json_node()
    end function pool_add

    subroutine pool_link(doc, parent, child)
        type(json_doc), intent(inout) :: doc
        integer, intent(in) :: parent, child
        integer :: last
        doc%nodes(child)%parent = parent
        if (doc%nodes(parent)%first_child == 0) then
            doc%nodes(parent)%first_child = child
        else
            last = doc%nodes(parent)%first_child
            do while (doc%nodes(last)%next_sibling /= 0)
                last = doc%nodes(last)%next_sibling
            end do
            doc%nodes(last)%next_sibling = child
        end if
    end subroutine pool_link

    subroutine json_free(doc)
        type(json_doc), intent(inout) :: doc
        if (allocated(doc%nodes)) deallocate(doc%nodes)
        doc%n = 0
        doc%root = 0
    end subroutine json_free

    ! ----------------------------------------------------------------
    ! Parser
    ! ----------------------------------------------------------------

    subroutine set_err(msg)
        character(len=*), intent(in) :: msg
        character(len=32) :: off
        write(off, '(I0)') p_pos
        p_err = trim(msg) // ' at byte offset ' // trim(off)
    end subroutine set_err

    subroutine skip_ws()
        do while (p_pos <= p_len)
            select case (p_text(p_pos:p_pos))
            case (' ', char(9), char(10), char(13))
                p_pos = p_pos + 1
            case default
                exit
            end select
        end do
    end subroutine skip_ws

    ! Append the UTF-8 encoding of code point cp to buf (grown in
    ! place); nbuf tracks the used length.
    subroutine utf8_append(buf, nbuf, cp)
        character(len=:), allocatable, intent(inout) :: buf
        integer, intent(inout) :: nbuf
        integer, intent(in) :: cp
        character(len=:), allocatable :: tmp
        integer :: need, cap
        if (cp < 128) then
            need = 1
        else if (cp < 2048) then
            need = 2
        else if (cp < 65536) then
            need = 3
        else
            need = 4
        end if
        cap = 0
        if (allocated(buf)) cap = len(buf)
        if (nbuf + need > cap) then
            allocate(character(len=max(32, 2 * cap, nbuf + need)) :: tmp)
            if (nbuf > 0) tmp(1:nbuf) = buf(1:nbuf)
            if (allocated(buf)) deallocate(buf)
            call move_alloc(tmp, buf)
        end if
        if (need == 1) then
            buf(nbuf + 1:nbuf + 1) = achar(cp)
        else if (need == 2) then
            buf(nbuf + 1:nbuf + 1) = achar(192 + cp / 64)
            buf(nbuf + 2:nbuf + 2) = achar(128 + mod(cp, 64))
        else if (need == 3) then
            buf(nbuf + 1:nbuf + 1) = achar(224 + cp / 4096)
            buf(nbuf + 2:nbuf + 2) = achar(128 + mod(cp / 64, 64))
            buf(nbuf + 3:nbuf + 3) = achar(128 + mod(cp, 64))
        else
            buf(nbuf + 1:nbuf + 1) = achar(240 + cp / 262144)
            buf(nbuf + 2:nbuf + 2) = achar(128 + mod(cp / 4096, 64))
            buf(nbuf + 3:nbuf + 3) = achar(128 + mod(cp / 64, 64))
            buf(nbuf + 4:nbuf + 4) = achar(128 + mod(cp, 64))
        end if
        nbuf = nbuf + need
    end subroutine utf8_append

    ! Read exactly 4 hex digits at the cursor; advance past them.
    subroutine parse_hex4(cp, ok)
        integer, intent(out) :: cp
        logical, intent(out) :: ok
        integer :: i, v
        cp = 0
        ok = .false.
        if (p_pos + 3 > p_len) return
        do i = 0, 3
            select case (p_text(p_pos + i:p_pos + i))
            case ('0':'9')
                v = iachar(p_text(p_pos + i:p_pos + i)) - iachar('0')
            case ('a':'f')
                v = iachar(p_text(p_pos + i:p_pos + i)) - iachar('a') + 10
            case ('A':'F')
                v = iachar(p_text(p_pos + i:p_pos + i)) - iachar('A') + 10
            case default
                return
            end select
            cp = cp * 16 + v
        end do
        p_pos = p_pos + 4
        ok = .true.
    end subroutine parse_hex4

    ! True when the cursor sits on a "\u" escape prefix (bounds-safe).
    logical function has_low_surrogate_prefix() result(r)
        r = .false.
        if (p_pos + 1 > p_len) return
        if (p_text(p_pos:p_pos) /= '\') return
        if (p_text(p_pos + 1:p_pos + 1) /= 'u') return
        r = .true.
    end function has_low_surrogate_prefix

    ! Parse a string literal (cursor at the opening quote) into a
    ! freshly allocated decoded string.  ok=.false. on bad input.
    subroutine parse_string(out, ok)
        character(len=:), allocatable, intent(out) :: out
        logical, intent(out) :: ok
        character(len=:), allocatable :: buf
        integer :: nbuf, cp, cp2
        logical :: hok
        ok = .false.
        allocate(character(len=32) :: buf)
        nbuf = 0
        p_pos = p_pos + 1  ! opening quote
        do while (p_pos <= p_len)
            select case (p_text(p_pos:p_pos))
            case ('"')
                p_pos = p_pos + 1
                allocate(character(len=nbuf) :: out)
                if (nbuf > 0) out = buf(1:nbuf)
                deallocate(buf)
                ok = .true.
                return
            case ('\')
                p_pos = p_pos + 1
                if (p_pos > p_len) exit
                select case (p_text(p_pos:p_pos))
                case ('"')
                    call utf8_append(buf, nbuf, iachar('"'))
                    p_pos = p_pos + 1
                case ('\')
                    call utf8_append(buf, nbuf, iachar('\'))
                    p_pos = p_pos + 1
                case ('/')
                    call utf8_append(buf, nbuf, iachar('/'))
                    p_pos = p_pos + 1
                case ('b')
                    call utf8_append(buf, nbuf, 8)
                    p_pos = p_pos + 1
                case ('f')
                    call utf8_append(buf, nbuf, 12)
                    p_pos = p_pos + 1
                case ('n')
                    call utf8_append(buf, nbuf, 10)
                    p_pos = p_pos + 1
                case ('r')
                    call utf8_append(buf, nbuf, 13)
                    p_pos = p_pos + 1
                case ('t')
                    call utf8_append(buf, nbuf, 9)
                    p_pos = p_pos + 1
                case ('u')
                    p_pos = p_pos + 1
                    call parse_hex4(cp, hok)
                    if (.not. hok) then
                        call set_err('invalid \u escape')
                        deallocate(buf)
                        return
                    end if
                    ! Surrogate pair: D800-DBFF followed by \uDC00-DFFF.
                    if (cp >= 55296 .and. cp <= 56319) then
                        if (has_low_surrogate_prefix()) then
                            p_pos = p_pos + 2
                            call parse_hex4(cp2, hok)
                            if (.not. hok) then
                                call set_err('invalid low surrogate')
                                deallocate(buf)
                                return
                            end if
                            if (cp2 >= 56320 .and. cp2 <= 57343) then
                                cp = 65536 + (cp - 55296) * 1024 + (cp2 - 56320)
                            else
                                cp = 65533  ! unpaired: replacement char
                            end if
                        else
                            cp = 65533
                        end if
                    else if (cp >= 56320 .and. cp <= 57343) then
                        cp = 65533  ! lone low surrogate
                    end if
                    call utf8_append(buf, nbuf, cp)
                case default
                    call set_err('invalid escape in string')
                    deallocate(buf)
                    return
                end select
            case default
                ! Raw byte: UTF-8 input passes through byte-exact;
                ! control characters below 0x20 are invalid JSON.
                if (iachar(p_text(p_pos:p_pos)) < 32) then
                    call set_err('control character in string')
                    deallocate(buf)
                    return
                end if
                block
                    character(len=:), allocatable :: tmp2
                    integer :: cap2
                    cap2 = 0
                    if (allocated(buf)) cap2 = len(buf)
                    if (nbuf + 1 > cap2) then
                        allocate(character(len=max(32, 2 * cap2)) :: tmp2)
                        if (nbuf > 0) tmp2(1:nbuf) = buf(1:nbuf)
                        call move_alloc(tmp2, buf)
                    end if
                    buf(nbuf + 1:nbuf + 1) = p_text(p_pos:p_pos)
                    nbuf = nbuf + 1
                end block
                p_pos = p_pos + 1
            end select
        end do
        call set_err('unterminated string')
        deallocate(buf)
    end subroutine parse_string

    ! Parse a number literal into real64.
    subroutine parse_number(val, ok)
        real(real64), intent(out) :: val
        logical, intent(out) :: ok
        integer :: start, ios
        ok = .false.
        val = 0.0_real64
        start = p_pos
        if (p_pos <= p_len) then
            if (p_text(p_pos:p_pos) == '-') p_pos = p_pos + 1
        end if
        if (p_pos > p_len) then
            call set_err('bad number')
            return
        end if
        if (p_text(p_pos:p_pos) == '0') then
            p_pos = p_pos + 1
        else if (p_text(p_pos:p_pos) >= '1' .and. p_text(p_pos:p_pos) <= '9') then
            do while (p_pos <= p_len)
                if (p_text(p_pos:p_pos) >= '0' .and. p_text(p_pos:p_pos) <= '9') then
                    p_pos = p_pos + 1
                else
                    exit
                end if
            end do
        else
            call set_err('bad number')
            return
        end if
        if (p_pos <= p_len) then
          if (p_text(p_pos:p_pos) == '.') then
            p_pos = p_pos + 1
            if (p_pos > p_len) then
                call set_err('bad number fraction')
                return
            end if
            if (p_text(p_pos:p_pos) < '0' .or. &
                p_text(p_pos:p_pos) > '9') then
                call set_err('bad number fraction')
                return
            end if
            do while (p_pos <= p_len)
                if (p_text(p_pos:p_pos) >= '0' .and. p_text(p_pos:p_pos) <= '9') then
                    p_pos = p_pos + 1
                else
                    exit
                end if
            end do
          end if
        end if
        if (p_pos <= p_len) then
          if (p_text(p_pos:p_pos) == 'e' .or. &
              p_text(p_pos:p_pos) == 'E') then
            p_pos = p_pos + 1
            if (p_pos <= p_len) then
                if (p_text(p_pos:p_pos) == '+' .or. &
                    p_text(p_pos:p_pos) == '-') p_pos = p_pos + 1
            end if
            if (p_pos > p_len) then
                call set_err('bad number exponent')
                return
            end if
            if (p_text(p_pos:p_pos) < '0' .or. &
                p_text(p_pos:p_pos) > '9') then
                call set_err('bad number exponent')
                return
            end if
            do while (p_pos <= p_len)
                if (p_text(p_pos:p_pos) >= '0' .and. p_text(p_pos:p_pos) <= '9') then
                    p_pos = p_pos + 1
                else
                    exit
                end if
            end do
          end if
        end if
        read(p_text(start:p_pos - 1), *, iostat=ios) val
        if (ios /= 0) then
            call set_err('bad number')
            return
        end if
        ok = .true.
    end subroutine parse_number

    ! True when the next len(word) bytes equal word (bounds-safe).
    logical function lit_at(word) result(r)
        character(len=*), intent(in) :: word
        r = .false.
        if (p_pos + len(word) - 1 > p_len) return
        r = (p_text(p_pos:p_pos + len(word) - 1) == word)
    end function lit_at

    recursive subroutine parse_value(doc, idx, ok)
        type(json_doc), intent(inout) :: doc
        integer, intent(out) :: idx
        logical, intent(out) :: ok
        character(len=:), allocatable :: str, key
        integer :: child, val_idx, hidden
        real(real64) :: num
        logical :: vok
        ok = .false.
        idx = 0
        call skip_ws()
        if (p_pos > p_len) then
            call set_err('unexpected end of input')
            return
        end if
        select case (p_text(p_pos:p_pos))
        case ('{')
            idx = pool_add(doc)
            doc%nodes(idx)%kind = K_OBJ
            p_pos = p_pos + 1
            call skip_ws()
            if (p_pos <= p_len) then
                if (p_text(p_pos:p_pos) == '}') then
                    p_pos = p_pos + 1
                    ok = .true.
                    return
                end if
            end if
            do
                call skip_ws()
                if (p_pos > p_len) then
                    call set_err('expected object key string')
                    return
                end if
                if (p_text(p_pos:p_pos) /= '"') then
                    call set_err('expected object key string')
                    return
                end if
                call parse_string(key, vok)
                if (.not. vok) return
                call skip_ws()
                if (p_pos > p_len) then
                    call set_err('expected ":" after object key')
                    deallocate(key)
                    return
                end if
                if (p_text(p_pos:p_pos) /= ':') then
                    call set_err('expected ":" after object key')
                    deallocate(key)
                    return
                end if
                p_pos = p_pos + 1
                call parse_value(doc, val_idx, vok)
                if (.not. vok) then
                    deallocate(key)
                    return
                end if
                ! Member convention: the value node's s holds the key.
                if (doc%nodes(val_idx)%kind == K_STR) then
                    ! Keep the string value in a hidden child node so
                    ! the member node's s can hold the key (see header).
                    hidden = pool_add(doc)
                    doc%nodes(hidden)%kind = K_STR
                    call move_alloc(doc%nodes(val_idx)%s, &
                                    doc%nodes(hidden)%s)
                    doc%nodes(val_idx)%first_child = hidden
                    doc%nodes(hidden)%parent = val_idx
                else if (allocated(doc%nodes(val_idx)%s)) then
                    deallocate(doc%nodes(val_idx)%s)
                end if
                allocate(character(len=len(key)) :: doc%nodes(val_idx)%s)
                doc%nodes(val_idx)%s = key
                deallocate(key)
                call pool_link(doc, idx, val_idx)
                call skip_ws()
                if (p_pos > p_len) then
                    call set_err('unterminated object')
                    return
                end if
                if (p_text(p_pos:p_pos) == ',') then
                    p_pos = p_pos + 1
                    cycle
                else if (p_text(p_pos:p_pos) == '}') then
                    p_pos = p_pos + 1
                    exit
                else
                    call set_err('expected "," or "}" in object')
                    return
                end if
            end do
            ok = .true.
        case ('[')
            idx = pool_add(doc)
            doc%nodes(idx)%kind = K_ARR
            p_pos = p_pos + 1
            call skip_ws()
            if (p_pos <= p_len) then
                if (p_text(p_pos:p_pos) == ']') then
                    p_pos = p_pos + 1
                    ok = .true.
                    return
                end if
            end if
            do
                call parse_value(doc, child, vok)
                if (.not. vok) return
                call pool_link(doc, idx, child)
                call skip_ws()
                if (p_pos > p_len) then
                    call set_err('unterminated array')
                    return
                end if
                if (p_text(p_pos:p_pos) == ',') then
                    p_pos = p_pos + 1
                    cycle
                else if (p_text(p_pos:p_pos) == ']') then
                    p_pos = p_pos + 1
                    exit
                else
                    call set_err('expected "," or "]" in array')
                    return
                end if
            end do
            ok = .true.
        case ('"')
            call parse_string(str, vok)
            if (.not. vok) return
            idx = pool_add(doc)
            doc%nodes(idx)%kind = K_STR
            call move_alloc(str, doc%nodes(idx)%s)
            ok = .true.
        case ('t')
            if (lit_at('true')) then
                p_pos = p_pos + 4
                idx = pool_add(doc)
                doc%nodes(idx)%kind = K_BOOL
                doc%nodes(idx)%b = .true.
                ok = .true.
            else
                call set_err('invalid literal')
            end if
        case ('f')
            if (lit_at('false')) then
                p_pos = p_pos + 5
                idx = pool_add(doc)
                doc%nodes(idx)%kind = K_BOOL
                doc%nodes(idx)%b = .false.
                ok = .true.
            else
                call set_err('invalid literal')
            end if
        case ('n')
            if (lit_at('null')) then
                p_pos = p_pos + 4
                idx = pool_add(doc)
                doc%nodes(idx)%kind = K_NULL
                ok = .true.
            else
                call set_err('invalid literal')
            end if
        case ('-', '0':'9')
            call parse_number(num, vok)
            if (.not. vok) return
            idx = pool_add(doc)
            doc%nodes(idx)%kind = K_NUM
            doc%nodes(idx)%num = num
            ok = .true.
        case default
            call set_err('unexpected character')
        end select
    end subroutine parse_value

    subroutine json_parse(text, doc, ok, errmsg)
        character(len=*), intent(in) :: text
        type(json_doc), intent(inout) :: doc
        logical, intent(out) :: ok
        character(len=*), intent(out) :: errmsg
        logical :: vok
        ok = .false.
        errmsg = ''
        call json_free(doc)
        call pool_init(doc)
        if (allocated(p_text)) deallocate(p_text)
        allocate(character(len=len(text)) :: p_text)
        p_text = text
        p_len = len(text)
        p_pos = 1
        p_err = ''
        call parse_value(doc, doc%root, vok)
        if (.not. vok) then
            errmsg = trim(p_err)
            call json_free(doc)
            if (allocated(p_text)) deallocate(p_text)
            return
        end if
        call skip_ws()
        if (p_pos <= p_len) then
            call set_err('trailing characters after document')
            errmsg = trim(p_err)
            call json_free(doc)
            if (allocated(p_text)) deallocate(p_text)
            return
        end if
        if (allocated(p_text)) deallocate(p_text)
        ok = .true.
    end subroutine json_parse

    ! ----------------------------------------------------------------
    ! Accessors
    ! ----------------------------------------------------------------

    logical function valid(doc, i)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        valid = allocated(doc%nodes) .and. i >= 1 .and. i <= doc%n
    end function valid

    function json_kind(doc, i) result(k)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        integer :: k
        k = -1
        if (valid(doc, i)) k = doc%nodes(i)%kind
    end function json_kind

    function json_num(doc, i, def) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        real(real64), intent(in) :: def
        real(real64) :: v
        v = def
        if (valid(doc, i)) then
            if (doc%nodes(i)%kind == K_NUM) v = doc%nodes(i)%num
        end if
    end function json_num

    function json_int(doc, i, def) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        integer, intent(in) :: def
        integer :: v
        real(real64) :: r
        v = def
        if (valid(doc, i)) then
            if (doc%nodes(i)%kind == K_NUM) then
                r = doc%nodes(i)%num
                if (r >= real(-huge(v) - 1, real64) .and. &
                    r <= real(huge(v), real64)) then
                    v = nint(r)
                else if (r > 0.0_real64) then
                    v = huge(v)
                else
                    v = -huge(v) - 1
                end if
            end if
        end if
    end function json_int

    function json_bool(doc, i, def) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        logical, intent(in) :: def
        logical :: v
        v = def
        if (valid(doc, i)) then
            if (doc%nodes(i)%kind == K_BOOL) v = doc%nodes(i)%b
        end if
    end function json_bool

    function json_str(doc, i) result(v)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        character(len=:), allocatable :: v
        integer :: h
        allocate(character(len=0) :: v)
        if (.not. valid(doc, i)) return
        if (doc%nodes(i)%kind /= K_STR) return
        ! Object member with a string value: s holds the key and the
        ! value lives in the hidden first child (see header).
        if (doc%nodes(i)%parent /= 0) then
            if (valid(doc, doc%nodes(i)%parent)) then
                if (doc%nodes(doc%nodes(i)%parent)%kind == K_OBJ) then
                    h = doc%nodes(i)%first_child
                    if (h /= 0) then
                        if (valid(doc, h) .and. allocated(doc%nodes(h)%s)) then
                            deallocate(v)
                            allocate(character(len=len(doc%nodes(h)%s)) :: v)
                            v = doc%nodes(h)%s
                        end if
                    end if
                    return
                end if
            end if
        end if
        if (allocated(doc%nodes(i)%s)) then
            deallocate(v)
            allocate(character(len=len(doc%nodes(i)%s)) :: v)
            v = doc%nodes(i)%s
        end if
    end function json_str

    subroutine json_obj_get(doc, i, key, child, found)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        character(len=*), intent(in) :: key
        integer, intent(out) :: child
        logical, intent(out) :: found
        integer :: c
        child = 0
        found = .false.
        if (.not. valid(doc, i)) return
        if (doc%nodes(i)%kind /= K_OBJ) return
        c = doc%nodes(i)%first_child
        do while (c /= 0)
            if (allocated(doc%nodes(c)%s)) then
                if (doc%nodes(c)%s == key) then
                    child = c
                    found = .true.
                    return
                end if
            end if
            c = doc%nodes(c)%next_sibling
        end do
    end subroutine json_obj_get

    function json_obj_count(doc, i) result(n)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        integer :: n, c
        n = 0
        if (.not. valid(doc, i)) return
        if (doc%nodes(i)%kind /= K_OBJ) return
        c = doc%nodes(i)%first_child
        do while (c /= 0)
            n = n + 1
            c = doc%nodes(c)%next_sibling
        end do
    end function json_obj_count

    function json_arr_len(doc, i) result(n)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i
        integer :: n, c
        n = 0
        if (.not. valid(doc, i)) return
        if (doc%nodes(i)%kind /= K_ARR) return
        c = doc%nodes(i)%first_child
        do while (c /= 0)
            n = n + 1
            c = doc%nodes(c)%next_sibling
        end do
    end function json_arr_len

    subroutine json_arr_at(doc, i, k, child)
        type(json_doc), intent(in) :: doc
        integer, intent(in) :: i, k
        integer, intent(out) :: child
        integer :: c, j
        child = 0
        if (.not. valid(doc, i)) return
        if (doc%nodes(i)%kind /= K_ARR) return
        if (k < 1) return
        c = doc%nodes(i)%first_child
        j = 1
        do while (c /= 0)
            if (j == k) then
                child = c
                return
            end if
            j = j + 1
            c = doc%nodes(c)%next_sibling
        end do
    end subroutine json_arr_at

end module json_reader_3d
